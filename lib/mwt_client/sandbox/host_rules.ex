defmodule MWTClient.Sandbox.HostRules do
  @moduledoc """
  A list of entries naming hosts, each saying something about the hosts it
  covers, and which entry speaks for a host: the one naming it most
  exactly. Pure.

  Two lists are made of it, each entry a map with a `host` and what that
  list says:

    * what MWT reads (`MWTClient.Sandbox.Reading`): `%{host, read?}`;
    * what a network grant does with a host's uses (`Grant.host_rules`):
      `%{host, action}`, `:ask`, `:auto` or `:block`.

  An entry is a host name as clients ask for it (TLS's name, HTTP's
  `Host`), never an address: `example.com` covers that name and every name
  under it, `*.example.com` the same. Of two that cover a host, the one
  naming it most exactly speaks (`api.example.com` before `example.com`),
  so one host under a domain can be treated apart from the rest. An entry
  covers every port of its names.
  """

  @typedoc "An entry, and what its list says of the hosts it covers."
  @type rule :: %{required(:host) => String.t(), optional(atom()) => term()}

  @doc """
  A host as an entry: lowercased, a URL's scheme, port and path dropped; or
  why it can't be one.
  """
  @spec entry(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def entry(text) when is_binary(text) do
    host =
      text
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r{\A[a-z][a-z0-9+.-]*://}, "")
      |> String.split(["/", "?", "#"], parts: 2)
      |> hd()
      |> String.replace(~r/:\d+\z/, "")
      |> String.trim_trailing(".")

    cond do
      host == "" ->
        {:error, "Write a host name, like api.example.com or *.example.com."}

      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host))) ->
        {:error, "#{host} is an address: entries are host names, as clients ask for them."}

      byte_size(host) <= 253 and
          host =~
            ~r/\A(\*\.)?[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*\z/ ->
        {:ok, host}

      true ->
        {:error, "#{String.slice(host, 0, 80)} isn't a host name."}
    end
  end

  @doc "The rule naming `host` most exactly, or nil (none covers it, or there is no host)."
  @spec rule([rule()], String.t() | nil) :: rule() | nil
  def rule(_rules, nil), do: nil
  def rule([], _host), do: nil

  def rule(rules, host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    rules
    |> Enum.filter(&covers?(&1.host, host))
    |> Enum.max_by(&exactness(&1.host, host), fn -> nil end)
  end

  @doc """
  `rule` added, replacing the one for the same names (`example.com` and
  `*.example.com` are one entry, written as you wrote it last), its host
  made an entry first (`entry/1`); `{:error, message}` for a host that
  can't be one, or a list already holding `limit` others.
  """
  @spec put([rule()], rule(), pos_integer()) :: {:ok, [rule()]} | {:error, String.t()}
  def put(rules, %{host: host} = rule, limit) do
    with {:ok, entry} <- entry(host) do
      rest = Enum.reject(rules, &same?(&1.host, entry))

      if length(rest) >= limit,
        do: {:error, "At most #{limit} hosts."},
        else: {:ok, rest ++ [%{rule | host: entry}]}
    end
  end

  @doc "The rule for this entry gone, with or without its `*.`; its hosts then follow a wider rule, or none."
  @spec remove([rule()], String.t()) :: [rule()]
  def remove(rules, host) do
    entry = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    Enum.reject(rules, &same?(&1.host, entry))
  end

  # Two entries covering the same names.
  defp same?(one, other), do: String.trim_leading(one, "*.") == String.trim_leading(other, "*.")

  @doc "Whether `entry` covers `host`, lowercase: the name itself, or a name under it."
  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(entry, host) do
    name = String.trim_leading(entry, "*.")
    host == name or String.ends_with?(host, "." <> name)
  end

  # The name itself before a domain above it, a longer name before a shorter.
  defp exactness(entry, host) do
    name = String.trim_leading(entry, "*.")
    {host == name, byte_size(name)}
  end
end
