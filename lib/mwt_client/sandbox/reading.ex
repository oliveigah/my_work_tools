defmodule MWTClient.Sandbox.Reading do
  @moduledoc """
  Which hosts the proxy reads: what you set on the Proxy activity page,
  saved with the sandbox and published to the network path
  (`MWTClient.Sandbox.Gate.reading/3`). Pure.

    * **`default`**: what MWT does with a host no rule names. `:every_host`,
      it reads every connection it can (`MWTClient.Sandbox.Egress.Driver`);
      `:token_hosts`, only the hosts token grants list, as before
      2026-11-22, the rest passed through as bytes.
    * **`rules`**: hosts you opted in or out, each `%{host, read?}`. An
      entry `example.com` covers that name and every name under it
      (`*.example.com` the same); of two that cover a host, the one naming
      it most exactly goes (`api.example.com` before `example.com`), so
      one host under a domain can be read while the rest aren't, or the
      other way round.

  A token grant's hosts are read whatever this says: their value goes in
  only so (`Gate.route/5`). Reading still needs a connection MWT can read
  (TLS naming the host, offering HTTP/1.1 or nothing): a rule to read one
  that offers only HTTP/2 changes nothing.

  Only you change it, from MWT's pages: nothing the VM does adds a rule, or
  it could choose what goes unread by failing one handshake.
  """

  @limit 500

  defstruct default: :every_host, rules: []

  @type rule :: %{host: String.t(), read?: boolean()}
  @type t :: %__MODULE__{default: :every_host | :token_hosts, rules: [rule()]}

  @doc "Reading as it starts: every host MWT can, no rule."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "A saved one brought up to date with this code; nil (none saved yet) is a new one."
  @spec upgrade(t() | map() | nil) :: t()
  def upgrade(nil), do: new()
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))

  @doc """
  Whether MWT reads `host`, when it can: by the rule naming it most
  exactly, or the default.
  """
  @spec read?(t(), String.t() | nil) :: boolean()
  def read?(%__MODULE__{} = reading, host) do
    case rule(reading, host) do
      %{read?: read?} -> read?
      nil -> reading.default == :every_host
    end
  end

  @doc "The rule naming `host` most exactly, or nil."
  @spec rule(t(), String.t() | nil) :: rule() | nil
  def rule(_reading, nil), do: nil

  def rule(%__MODULE__{rules: rules}, host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    rules
    |> Enum.filter(&covers?(&1.host, host))
    |> Enum.max_by(&exactness(&1.host, host), fn -> nil end)
  end

  @doc """
  `host` opted in (`read? = true`) or out, replacing a rule for the same
  entry. `{:error, message}` for one that can't be an entry: a host name,
  `*.` before it for the names under it, never an address (MWT reads by
  the name a client asks for).
  """
  @spec put(t(), String.t(), boolean()) :: {:ok, t()} | {:error, String.t()}
  def put(%__MODULE__{} = reading, host, read?) when is_boolean(read?) do
    with {:ok, entry} <- entry(host) do
      rules = Enum.reject(reading.rules, &(&1.host == entry))

      if length(rules) >= @limit,
        do: {:error, "At most #{@limit} hosts."},
        else: {:ok, %{reading | rules: rules ++ [%{host: entry, read?: read?}]}}
    end
  end

  @doc "The rule for exactly this entry gone; the host then follows the default, or a wider rule."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = reading, host) do
    entry = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    %{reading | rules: Enum.reject(reading.rules, &(&1.host == entry))}
  end

  @doc "Sets what MWT does with a host no rule names."
  @spec set_default(t(), :every_host | :token_hosts) :: t()
  def set_default(%__MODULE__{} = reading, default) when default in [:every_host, :token_hosts],
    do: %{reading | default: default}

  @doc "A host as an entry: lowercased, a URL's scheme, port and path dropped; or why it can't be one."
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
        {:error, "#{host} is an address: MWT reads by the name a client asks for."}

      byte_size(host) <= 253 and
          host =~
            ~r/\A(\*\.)?[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*\z/ ->
        {:ok, host}

      true ->
        {:error, "#{String.slice(host, 0, 80)} isn't a host name."}
    end
  end

  defp covers?(entry, host) do
    name = String.trim_leading(entry, "*.")
    host == name or String.ends_with?(host, "." <> name)
  end

  # The name itself before a domain above it, a longer name before a shorter.
  defp exactness(entry, host) do
    name = String.trim_leading(entry, "*.")
    {host == name, byte_size(name)}
  end
end
