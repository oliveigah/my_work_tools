defmodule MWTClient.Sandbox.Attributes do
  @moduledoc """
  What a grant may narrow by beyond its hosts: attributes read from the
  use by whoever reads it, the protocol's driver or the credential's
  adapter, each from what the protocol frames or a request names, never
  from what a query means. A grant names some (`Grant.attributes`, name =>
  patterns), and covers a use only when each matches
  (`MWTClient.Sandbox.Policy`).

  | Name                | Read by          | A use's value                                   |
  | ------------------- | ---------------- | ----------------------------------------------- |
  | `http.method`       | the HTTP driver  | its method                                      |
  | `http.path`         | the HTTP driver  | its path, without the query                     |
  | `grpc.method`       | the gRPC driver  | `Service/Method`, a gRPC call's path            |
  | `graphql.operation` | the GraphQL driver | `query`, `mutation` or `subscription`, and the operation's name |
  | `git.direction`     | the git driver   | `fetch` or `push`                               |
  | `github.repository` | the github adapter (`MWTClient.Sandbox.Adapter.GitHub`) | `owner/name`, from the REST or git path |

  A pattern matches exactly, in any case, or by segment for a path: `*`
  stands for one segment, `**` for any number (`/repos/*/pulls/**`).

  An attribute a use doesn't have (no gRPC method on a REST call) doesn't
  match. One MWT couldn't read (a GraphQL body it holds only the start of,
  a repository a GraphQL query names in its variables) is unknown, and
  counts against the use: a grant that would restrict by it covers the use,
  and one that would allow by it doesn't, unless the grant's *Covers
  requests MWT can't read* is off (`Grant.covers_unread`).
  """

  alias MWTClient.Sandbox.{GraphQL, StrictJson}

  @names ~w(http.method http.path grpc.method graphql.operation git.direction github.repository)

  @doc "Every attribute a grant may narrow by."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  The attributes of a request, as MWT read it: each name with its value,
  `:unknown` when it applies and MWT couldn't read it, absent when it
  doesn't apply.

      iex> MWTClient.Sandbox.Attributes.of(%{method: "GET", host: "api.github.com",
      ...>   path: "/repos/o/r/pulls/3?x=1", headers: [], body: ""})
      %{"http.method" => "GET", "http.path" => "/repos/o/r/pulls/3", "github.repository" => "o/r"}
  """
  @spec of(map()) :: %{String.t() => String.t() | [String.t()] | :unknown}
  def of(request) do
    path = request |> Map.get(:path, "") |> to_string() |> String.split("?", parts: 2) |> hd()

    query =
      request
      |> Map.get(:path, "")
      |> to_string()
      |> String.split("?", parts: 2)
      |> Enum.at(1, "")

    %{"http.method" => String.upcase(to_string(request.method)), "http.path" => path}
    |> put("grpc.method", grpc(request, path))
    |> put("graphql.operation", graphql(request, path))
    |> put("git.direction", git(path, query))
    # What a credential's adapter reads of what the request names: GitHub's
    # repository (`MWTClient.Sandbox.Adapter`).
    |> Map.merge(MWTClient.Sandbox.Adapter.attributes(request))
  end

  defp put(attrs, _name, nil), do: attrs
  defp put(attrs, name, value), do: Map.put(attrs, name, value)

  defp grpc(request, path) do
    type = header(request, "content-type")

    if is_binary(type) and String.starts_with?(String.downcase(type), "application/grpc") and
         Regex.match?(~r{\A/[^/]+/[^/]+\z}, path),
       do: String.trim_leading(path, "/")
  end

  # Both the type and the name, so a pattern can be either: `mutation`,
  # `createIssue`.
  defp graphql(request, path) do
    if String.ends_with?(path, "/graphql") and String.upcase(request.method) == "POST" do
      with {:ok, %{"query" => document} = body} when is_binary(document) <-
             StrictJson.decode(Map.get(request, :body) || ""),
           name = if(is_binary(body["operationName"]), do: body["operationName"]),
           {:ok, operation} <- GraphQL.selected(document, name) do
        Enum.reject([operation.kind, operation.name], &is_nil/1)
      else
        _unreadable -> :unknown
      end
    end
  end

  defp git(path, query) do
    cond do
      String.ends_with?(path, "/git-receive-pack") -> "push"
      String.ends_with?(path, "/git-upload-pack") -> "fetch"
      String.ends_with?(path, "/info/refs") and query =~ "service=git-receive-pack" -> "push"
      String.ends_with?(path, "/info/refs") -> "fetch"
      true -> nil
    end
  end

  defp header(request, name) do
    Enum.find_value(Map.get(request, :headers, []), fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  @doc """
  Whether a use's attributes match a grant's: `true`, `false`, or
  `:unknown` when one it names couldn't be read and the rest match. A
  grant that names none matches every use.

      iex> alias MWTClient.Sandbox.Attributes
      iex> attrs = %{"http.method" => "GET", "http.path" => "/repos/o/r/pulls/3"}
      iex> Attributes.matches?(%{"http.path" => ["/repos/*/*/pulls/*"]}, attrs)
      true
      iex> Attributes.matches?(%{"http.method" => ["POST"]}, attrs)
      false
      iex> Attributes.matches?(%{"github.repository" => ["o/r"]}, Map.put(attrs, "github.repository", :unknown))
      :unknown
  """
  @spec matches?(%{String.t() => [String.t()]}, map()) :: boolean() | :unknown
  def matches?(wanted, attrs) when map_size(wanted) == 0 and is_map(attrs), do: true

  def matches?(wanted, attrs) do
    results =
      for {name, patterns} <- wanted do
        case Map.get(attrs, name) do
          nil ->
            false

          :unknown ->
            :unknown

          value ->
            Enum.any?(List.wrap(value), fn v -> Enum.any?(patterns, &match(name, &1, v)) end)
        end
      end

    cond do
      false in results -> false
      :unknown in results -> :unknown
      true -> true
    end
  end

  defp match("http.path", pattern, value), do: path_match?(segments(pattern), segments(value))

  defp match(_name, pattern, value) do
    if String.contains?(pattern, "*"),
      do:
        path_match?(
          String.split(String.downcase(pattern), "/"),
          String.split(String.downcase(value), "/")
        ),
      else: String.downcase(pattern) == String.downcase(value)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp path_match?([], []), do: true
  defp path_match?(["**"], _rest), do: true
  defp path_match?(["**" | more], rest), do: Enum.any?(tails(rest), &path_match?(more, &1))
  defp path_match?(["*" | more], [_ | rest]), do: path_match?(more, rest)

  defp path_match?([p | more], [s | rest]),
    do: (p == s or String.downcase(p) == String.downcase(s)) and path_match?(more, rest)

  defp path_match?(_pattern, _segments), do: false

  defp tails([]), do: [[]]
  defp tails([_ | rest] = list), do: [list | tails(rest)]

  @doc """
  A grant's attributes from a form's text: one per line, `name = pattern,
  pattern`, or the errors. Names must be known; patterns are words.

      iex> MWTClient.Sandbox.Attributes.parse("http.method = GET, HEAD\\ngithub.repository = o/r")
      {:ok, %{"http.method" => ["GET", "HEAD"], "github.repository" => ["o/r"]}}
  """
  @spec parse(String.t() | nil) :: {:ok, %{String.t() => [String.t()]}} | {:error, String.t()}
  def parse(nil), do: {:ok, %{}}

  def parse(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      with [name, values] <- String.split(line, "=", parts: 2),
           name = String.trim(name),
           true <- name in @names,
           patterns =
             values |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")),
           true <-
             patterns != [] and
               Enum.all?(patterns, &Regex.match?(~r/\A[\w.\/*:@+-]{1,200}\z/u, &1)) do
        {:cont, {:ok, Map.update(acc, name, patterns, &Enum.uniq(&1 ++ patterns))}}
      else
        _ ->
          {:halt,
           {:error,
            "Each line is a name and patterns: name = pattern, pattern. Names: #{Enum.join(@names, ", ")}."}}
      end
    end)
  end

  @doc "A grant's attributes as the form shows them, a line each."
  @spec text(%{String.t() => [String.t()]}) :: String.t()
  def text(attributes),
    do:
      Enum.map_join(attributes, "\n", fn {name, patterns} ->
        "#{name} = #{Enum.join(patterns, ", ")}"
      end)

  @doc "A grant's attributes in words, for agents and cards."
  @spec words(%{String.t() => [String.t()]}) :: String.t()
  def words(attributes),
    do:
      Enum.map_join(attributes, "; ", fn {name, patterns} ->
        "#{name} #{Enum.join(patterns, " or ")}"
      end)
end
