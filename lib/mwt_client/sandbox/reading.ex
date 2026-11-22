defmodule MWTClient.Sandbox.Reading do
  @moduledoc """
  Which hosts MWT reads: what you set in What MWT reads, a dialog of the
  activity log (a list of hosts read, one of hosts not read, and what a
  host on neither list gets), saved with the sandbox and published to the network path
  (`MWTClient.Sandbox.Gate.reading/3`). Pure.

    * **`default`**: what MWT does with a host no rule names. `:every_host`,
      it reads every connection it can (`MWTClient.Sandbox.Egress.Driver`);
      `:token_hosts`, only the hosts token grants list, as before
      2026-11-22, the rest passed through as bytes.
    * **`rules`**: hosts you opted in or out, each `%{host, read?}`
      (`MWTClient.Sandbox.HostRules`). An entry `example.com` covers that
      name and every name under it (`*.example.com` the same); of two that
      cover a host, the one naming it most exactly goes (`api.example.com`
      before `example.com`), so one host under a domain can be read while
      the rest aren't, or the other way round.

  A token grant's hosts are read whatever this says: their value goes in
  only so (`Gate.route/5`). Reading still needs a connection MWT can read
  (TLS naming the host, offering HTTP/1.1 or nothing): a rule to read one
  that offers only HTTP/2 changes nothing.

  Only you change it, from MWT's pages: nothing the VM does adds a rule, or
  it could choose what goes unread by failing one handshake.
  """

  alias MWTClient.Sandbox.HostRules

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

  @doc "The rule naming `host` most exactly, or nil (`MWTClient.Sandbox.HostRules`)."
  @spec rule(t(), String.t() | nil) :: rule() | nil
  def rule(%__MODULE__{rules: rules}, host), do: HostRules.rule(rules, host)

  @doc """
  `host` opted in (`read? = true`) or out, replacing a rule for the same
  entry. `{:error, message}` for one that can't be an entry: a host name,
  `*.` before it for the names under it, never an address (MWT reads by
  the name a client asks for).
  """
  @spec put(t(), String.t(), boolean()) :: {:ok, t()} | {:error, String.t()}
  def put(%__MODULE__{} = reading, host, read?) when is_boolean(read?) do
    with {:ok, rules} <- HostRules.put(reading.rules, %{host: host, read?: read?}, @limit),
         do: {:ok, %{reading | rules: rules}}
  end

  @doc "The rule for exactly this entry gone; the host then follows the default, or a wider rule."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = reading, host),
    do: %{reading | rules: HostRules.remove(reading.rules, host)}

  @doc "Sets what MWT does with a host no rule names."
  @spec set_default(t(), :every_host | :token_hosts) :: t()
  def set_default(%__MODULE__{} = reading, default) when default in [:every_host, :token_hosts],
    do: %{reading | default: default}

  @doc "A host as an entry, or why it can't be one (`MWTClient.Sandbox.HostRules.entry/1`)."
  @spec entry(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate entry(text), to: HostRules
end
