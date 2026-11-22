defmodule MWTClient.Sandbox.Describe do
  @moduledoc """
  Turns an HTTP request into what its approval shows, whichever grant holds
  it: a token grant's, for a placeholder in it, or a network grant's, for
  what it does there (`Driver.Http1.describe/1`). It decides nothing:
  every use waits for you unless an allowance covers it.

    * `title`, `facts` - worked out from the request itself: git's ref
      updates, a GraphQL operation, a REST endpoint.
    * `claims` - text the agent wrote (titles, bodies, messages), kept apart
      so it can never read as a fact.
    * `pattern` - what "allow similar" lets through: the same method and
      endpoint, and for GraphQL the same document; through the same
      carrier (`carried_in/2`). Nil when MWT couldn't tell what the request
      does (a GraphQL document it can't read, or holds only the start of,
      a request it couldn't describe at all): then nothing is similar to
      it, and its card offers no *Allow similar*.

  A body MWT holds only the start of (it reads at most 64 KiB before
  deciding) is said among the facts: what the card shows of it isn't all
  the host gets.

  Only the start of the body is looked at, at most what `Egress` reads before
  asking (64 KiB): enough for git's ref updates, which come before the pack,
  and for GraphQL documents. Git's ref updates are read from the body as the
  host reads it: de-chunked when it is sent chunked (git does for a push
  over 1 MiB), and no further than its `Content-Length`. Where MWT can't read
  them as the host would, the card says so instead of showing none.

  A request on another port than HTTPS's own names it with its host
  (`host:8443`), in the title and in the pattern: a service on another
  port of the same name is another service, and "allow similar" for one
  doesn't cover the other.

  The request is the VM's, bytes of its choosing. So every text that comes
  out shows all it holds (`MWTClient.Sandbox.Shown`), and a request this
  can't make sense of is described by its method and host instead of
  failing: the sandbox's own process runs this.
  """

  require Logger

  alias MWTClient.Sandbox.{Chunked, GraphQL, Shown}

  @type request :: %{
          required(:host) => String.t(),
          optional(:port) => :inet.port_number(),
          required(:method) => String.t(),
          required(:path) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary()
        }

  @type t :: %{
          title: String.t(),
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          pattern: String.t() | nil
        }

  @claim_keys ~w(title body message description name)

  @doc "Describes a request."
  @spec request(request()) :: t()
  def request(%{method: method, path: path} = request) do
    {route, query} = split_query(path)
    plain = plain(request)
    # Plain HTTP names its scheme wherever its host shows, so a card or an
    # allowance for it is never one for the host over HTTPS.
    request =
      %{request | host: if(plain, do: origin(request), else: authority(request))}

    described =
      try do
        cond do
          String.ends_with?(route, "/git-receive-pack") and method == "POST" ->
            push(request, route)

          String.ends_with?(route, "/git-upload-pack") and method == "POST" ->
            fetch(request, route)

          String.ends_with?(route, "/info/refs") ->
            refs(request, route, query)

          route == "/graphql" and method == "POST" ->
            graphql(request)

          method == "POST" and grpc?(request) and route =~ ~r{\A/[^/]+/[^/]+\z} ->
            grpc(request, route)

          true ->
            rest(request, route)
        end
      rescue
        error ->
          Logger.warning("a request could not be described: #{Exception.message(error)}",
            system: :sandbox
          )

          %{
            title: "#{method} #{request.host}#{route}",
            facts: [{"Endpoint", "#{method} #{route}"}],
            claims: [],
            pattern: nil
          }
      end

    %{
      title: Shown.text(described.title),
      facts: Enum.map(described.facts ++ cut(request) ++ plain_facts(plain), &shown/1),
      claims: Enum.map(described.claims, &shown/1),
      pattern: described.pattern && exact(described.pattern <> plain_bound(plain))
    }
  end

  # A request over plain HTTP: the address it goes to, the client's
  # choice, which nothing proves is the host it names. An allowance for it
  # covers that address only: one named the same elsewhere is another.
  defp plain(%{plain?: true, ip: ip, host: host}), do: %{ip: ip, host: host}
  defp plain(_request), do: nil

  defp plain_facts(nil), do: []

  defp plain_facts(%{ip: ip, host: host}),
    do: [{"Plain HTTP", "to #{ip}: nothing proves it is #{host}, only the client says so"}]

  defp plain_bound(nil), do: ""
  defp plain_bound(%{ip: ip}), do: " via " <> ip

  # What the card says of a body MWT holds only the start of.
  defp cut(request) do
    case payload(request) do
      {:ok, data, false} ->
        total =
          case Integer.parse(header(request, "content-length") || "") do
            {n, ""} -> " of #{size(n)}"
            _chunked -> ""
          end

        [{"Body", "only its first #{size(byte_size(data))}#{total} read: the rest isn't shown"}]

      _whole_or_unread ->
        []
    end
  end

  defp size(bytes) when bytes >= 1024 * 1024, do: "#{Float.round(bytes / (1024 * 1024), 1)} MiB"
  defp size(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} KiB"
  defp size(bytes), do: "#{bytes} B"

  @doc """
  A request's description with the header that carries its credential: a
  fact on the card, and part of what "allow similar" lets through, so an
  allowance given to a request with its token in `authorization` doesn't
  cover one sending it in another carrier.

      iex> about = %{title: "GET /user", facts: [], claims: [], pattern: "GET api.github.com/user"}
      iex> MWTClient.Sandbox.Describe.carried_in(about, "authorization")
      %{title: "GET /user", facts: [{"Credential in", "authorization"}], claims: [],
        pattern: "GET api.github.com/user · in authorization"}
  """
  @spec carried_in(t(), String.t()) :: t()
  def carried_in(about, carrier) do
    %{
      about
      | facts: about.facts ++ [{"Credential in", carrier}],
        pattern: about.pattern && about.pattern <> " · in " <> carrier
    }
  end

  defp shown({label, value}), do: {Shown.text(label), Shown.text(value)}

  # A pattern is compared, so two that differ must stay different once they
  # are made safe to show: one that had to change carries a digest of what
  # it was.
  defp exact(pattern) do
    case Shown.text(pattern) do
      ^pattern -> pattern
      changed -> changed <> " · " <> short_digest(pattern)
    end
  end

  defp short_digest(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp push(request, route) do
    repo = repository(route)

    {updates, unread} =
      case push_commands(request) do
        {:ok, updates} ->
          {updates, nil}

        {:cut, updates} ->
          {updates, "more than MWT holds: only the first #{length(updates)} shown"}

        {:error, why} ->
          {[], why}
      end

    title =
      case {updates, unread} do
        {[], nil} -> "Push to #{repo}, no ref updates"
        {[], _unread} -> "Push to #{repo}, refs not read"
        {_some, "more" <> _} -> "Push #{length(updates)}+ refs to #{repo}"
        {[{ref, _old, _new}], nil} -> "Push #{short_ref(ref)} to #{repo}"
        {many, nil} -> "Push #{length(many)} refs to #{repo}"
      end

    %{
      title: title,
      facts:
        [{"Repository", repo}] ++
          Enum.map(updates, fn {ref, old, new} -> {"Ref", "#{ref}  #{update_words(old, new)}"} end) ++
          if(unread, do: [{"Refs not read", unread}], else: []) ++
          client(request),
      claims: [],
      pattern: "POST #{request.host}#{route}"
    }
  end

  # The ref updates of a push, read from its body as the host reads it.
  defp push_commands(request) do
    with :ok <- identity_encoding(request),
         {:ok, body, whole?} <- payload(request) do
      case ref_updates(body) do
        {:ok, updates} -> {:ok, updates}
        {:cut, updates} when not whole? -> {:cut, updates}
        {:cut, _updates} -> {:error, "the body ends before git's list of ref updates does"}
        :error -> {:error, "the body doesn't start with git's ref updates"}
      end
    end
  end

  defp identity_encoding(request) do
    case header(request, "content-encoding") do
      encoding when encoding in [nil, "identity"] -> :ok
      encoding -> {:error, "the body is #{String.slice(encoding, 0, 40)}-encoded"}
    end
  end

  # The body as the host reads it: de-chunked, or no further than its
  # length (bytes after it are the next request), and whether MWT holds
  # all of it.
  @doc """
  Whether MWT holds a request's whole body: one with none, or all its
  `Content-Length` or chunked framing says, as read before deciding (at
  most 64 KiB). False for a body it holds only the start of, or one whose
  framing it can't read.
  """
  @spec whole_body?(request()) :: boolean()
  def whole_body?(request) do
    case payload(request) do
      {:ok, _data, whole?} -> whole?
      {:error, _why} -> false
    end
  end

  # An HTTP/2 stream says whether MWT holds its whole body: it has no
  # framing of its own to tell.
  defp payload(%{body_whole?: whole?, body: body}), do: {:ok, body, whole?}

  defp payload(request) do
    chunked? = (header(request, "transfer-encoding") || "") =~ ~r/chunked/i

    case {chunked?, header(request, "content-length")} do
      {true, _length} ->
        case Chunked.decode(request.body) do
          {:whole, data} -> {:ok, data, true}
          {:cut, data} -> {:ok, data, false}
          :error -> {:error, "its chunked framing isn't one MWT reads as the host would"}
        end

      {false, length} when is_binary(length) ->
        case Integer.parse(length) do
          {n, ""} when n >= 0 ->
            {:ok, binary_part(request.body, 0, min(n, byte_size(request.body))),
             byte_size(request.body) >= n}

          _other ->
            {:error, "its Content-Length isn't a number"}
        end

      {false, nil} ->
        {:ok, "", true}
    end
  end

  defp header(request, name) do
    case List.keyfind(request.headers, name, 0) do
      {_, value} -> String.downcase(String.trim(value))
      nil -> nil
    end
  end

  defp fetch(request, route) do
    %{
      title: "Fetch from #{repository(route)}",
      facts: [{"Repository", repository(route)}] ++ client(request),
      claims: [],
      pattern: "POST #{request.host}#{route}"
    }
  end

  defp refs(request, route, query) do
    service = URI.decode_query(query || "")["service"] || "git-upload-pack"

    %{
      title: "List refs of #{repository(route)}",
      facts: [{"Repository", repository(route)}, {"For", service}] ++ client(request),
      claims: [],
      pattern: "#{request.method} #{request.host}#{route}"
    }
  end

  # The type and the fields come from the operation a server would run
  # (`MWTClient.Sandbox.GraphQL`), not from the start of the text. Its name
  # is the author's, so "allow similar" goes by the whole document: the same
  # document with other variables is similar, another document with the
  # same name is not.
  defp graphql(request) do
    {label, fields, variables, digest} =
      case Jason.decode(request.body) do
        {:ok, %{"query" => document} = body} when is_binary(document) ->
          name = if is_binary(body["operationName"]), do: body["operationName"]
          variables = if is_map(body["variables"]), do: body["variables"], else: %{}

          case GraphQL.selected(document, name) do
            {:ok, operation} ->
              shown = operation.name || List.first(operation.fields)
              label = Enum.join(Enum.reject([operation.kind, shown], &is_nil/1), " ")
              {label, operation.fields, variables, GraphQL.digest(document)}

            :error ->
              {"unknown", [], variables, GraphQL.digest(document)}
          end

        _unreadable ->
          {"unknown", [], %{}, GraphQL.digest(request.body)}
      end

    fields = if fields == [], do: [], else: [{"Fields", Enum.join(fields, ", ")}]

    # A document MWT couldn't read, or holds only the start of, is no
    # pattern: the next one sent the same way could do anything.
    pattern =
      if label != "unknown" and match?({:ok, _data, true}, payload(request)),
        do: "POST #{request.host}/graphql · #{label} · #{digest}"

    %{
      title: "GraphQL #{label} on #{request.host}",
      facts: [{"Operation", label}] ++ fields ++ repository_facts(variables) ++ client(request),
      claims: claims(variables),
      pattern: pattern
    }
  end

  # A gRPC call: its service and method are its path; its body, protobuf
  # without a schema, says nothing MWT can read.
  defp grpc(request, route) do
    [service, call] = route |> String.trim_leading("/") |> String.split("/", parts: 2)

    %{
      title: "gRPC #{service}/#{call} on #{request.host}",
      facts: [{"Call", "#{service}/#{call}"}] ++ client(request),
      claims: [],
      pattern: "gRPC #{request.host}/#{service}/#{call}"
    }
  end

  defp grpc?(request) do
    case header(request, "content-type") do
      nil -> false
      type -> String.starts_with?(String.downcase(type), "application/grpc")
    end
  end

  defp rest(request, route) do
    body_claims =
      case Jason.decode(request.body) do
        {:ok, %{} = json} -> claims(json)
        _ -> []
      end

    %{
      title: "#{request.method} #{request.host}#{route}",
      facts: [{"Endpoint", "#{request.method} #{route}"}] ++ client(request),
      claims: body_claims,
      pattern: "#{request.method} #{request.host}#{route}"
    }
  end

  @doc """
  The host a request went to, with its port when it isn't 443:
  `api.example.com`, `api.example.com:8443`.
  """
  @spec authority(%{required(:host) => String.t(), optional(atom()) => term()}) :: String.t()
  def authority(%{plain?: true, host: host, port: port}) when is_integer(port) and port != 80,
    do: "#{host}:#{port}"

  def authority(%{plain?: true, host: host}), do: host

  def authority(%{host: host, port: port}) when is_integer(port) and port != 443,
    do: "#{host}:#{port}"

  def authority(%{host: host}), do: host

  @doc """
  Where a request goes, as a URL's start: `https://` and its authority, or
  `http://` for one that came as plain HTTP.
  """
  @spec origin(map()) :: String.t()
  def origin(%{plain?: true} = request), do: "http://" <> authority(request)
  def origin(request), do: "https://" <> authority(request)

  @doc """
  The ref updates at the start of a git-receive-pack body (the body as the
  host reads it, de-chunked), as `{ref, old, new}`: pkt-lines of
  `old new ref`, `shallow` lines skipped, ended by a flush. `{:ok, updates}`
  up to the flush; `{:cut, updates}` when the bytes stop before it;
  `:error` when a line isn't one git's receive-pack would take, so nothing
  in a line it would refuse can pass for a ref update.
  """
  @spec ref_updates(binary()) ::
          {:ok | :cut, [{String.t(), String.t(), String.t()}]} | :error
  def ref_updates(body), do: pkt_lines(body, [])

  defp pkt_lines("0000" <> _pack, acc), do: {:ok, Enum.reverse(acc)}

  defp pkt_lines(<<hex::binary-size(4), rest::binary>>, acc) do
    with true <- hex =~ ~r/\A[0-9a-fA-F]{4}\z/,
         size when size > 4 <- String.to_integer(hex, 16) do
      case rest do
        <<line::binary-size(^size - 4), rest::binary>> ->
          case command(line) do
            {:update, update} -> pkt_lines(rest, [update | acc])
            :shallow -> pkt_lines(rest, acc)
            :error -> :error
          end

        _cut ->
          {:cut, Enum.reverse(acc)}
      end
    else
      _ -> :error
    end
  end

  defp pkt_lines(_cut, acc), do: {:cut, Enum.reverse(acc)}

  # A line as receive-pack reads it: up to a NUL (capabilities follow),
  # without one trailing newline.
  defp command(line) do
    line = line |> :binary.split(<<0>>) |> hd() |> String.replace_suffix("\n", "")

    case String.split(line, " ") do
      [old, new, ref] when ref != "" ->
        if object_id?(old) and object_id?(new), do: {:update, {ref, old, new}}, else: :error

      ["shallow", id] ->
        if object_id?(id), do: :shallow, else: :error

      _other ->
        :error
    end
  end

  defp object_id?(id), do: byte_size(id) in [40, 64] and id =~ ~r/\A[0-9a-fA-F]+\z/

  defp update_words(old, new) do
    cond do
      zero?(old) -> "new at #{short(new)}"
      zero?(new) -> "deleted (was #{short(old)})"
      true -> "#{short(old)} → #{short(new)}"
    end
  end

  defp zero?(sha), do: sha != "" and String.trim(sha, "0") == ""
  defp short(sha), do: binary_part(sha, 0, min(7, byte_size(sha)))
  defp short_ref("refs/heads/" <> branch), do: branch
  defp short_ref("refs/tags/" <> tag), do: "tag #{tag}"
  defp short_ref(ref), do: ref

  defp repository_facts(variables) do
    for key <- ["owner", "name", "repo", "repository", "repositoryId"],
        value = deep_get(variables, key),
        is_binary(value),
        do: {key |> String.capitalize(), value}
  end

  # Free text the agent chose: shown as its words, never as facts.
  defp claims(map) do
    for key <- @claim_keys,
        value = deep_get(map, key),
        is_binary(value),
        value != "",
        do: {String.capitalize(key), String.slice(value, 0, 600)}
  end

  defp deep_get(%{} = map, key) do
    Map.get(map, key) || Enum.find_value(Map.values(map), &deep_get(&1, key))
  end

  defp deep_get(_other, _key), do: nil

  defp client(request) do
    case List.keyfind(request.headers, "user-agent", 0) do
      {_, agent} -> [{"Client", String.slice(agent, 0, 80)}]
      nil -> []
    end
  end

  defp repository(route) do
    route
    |> String.split("/", trim: true)
    |> Enum.take(2)
    |> Enum.join("/")
    |> String.trim_trailing(".git")
  end

  defp split_query(path) do
    case String.split(path, "?", parts: 2) do
      [route, query] -> {route, query}
      [route] -> {route, nil}
    end
  end
end
