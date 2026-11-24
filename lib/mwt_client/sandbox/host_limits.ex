defmodule MWTClient.Sandbox.HostLimits do
  @moduledoc """
  Which hosts of a network the VM may reach at all, whatever its grants
  say: a network's own limits (`MWTClient.Sandbox.Network`), set on its
  page as What MWT reads is (`MWTClient.Sandbox.Reading`). Pure.

    * **`default`**: what a host on neither list gets, `:reachable` or
      `:blocked`. Reachable with a few blocked is a block list; blocked
      with a few reachable is the only hosts the VM may ever reach there.
    * **`rules`**: hosts you listed, each `%{host, blocked?}`
      (`MWTClient.Sandbox.HostRules`). An entry `example.com` covers that
      name and every name under it (`*.example.com` the same); of two that
      cover a host, the one naming it most exactly decides, so one host
      under a blocked domain can stay reachable, or the other way round.

  A limit only takes away: a host it leaves reachable still needs a grant
  that is on (`MWTClient.Sandbox.Policy`). It names hosts, never
  addresses: a connection is judged by the name it is for, once its first
  bytes say it, or the names MWT's DNS answered for its address.

  Only you change it, from MWT's pages.
  """

  alias MWTClient.Sandbox.HostRules

  @limit 500

  defstruct default: :reachable, rules: []

  @type rule :: %{host: String.t(), blocked?: boolean()}
  @type t :: %__MODULE__{default: :reachable | :blocked, rules: [rule()]}

  @doc "Limits as a network starts: every host reachable."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Saved limits brought up to date with this code; nil (none saved) is new."
  @spec upgrade(t() | map() | nil) :: t()
  def upgrade(nil), do: new()
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))

  @doc """
  Whether `host` is blocked: by the entry naming it most exactly, or the
  default. A use with no name (an address alone) is judged by the
  default.

      iex> alias MWTClient.Sandbox.HostLimits
      iex> {:ok, limits} = HostLimits.put(HostLimits.new(), "paste.example", true)
      iex> {HostLimits.blocked?(limits, "api.paste.example"), HostLimits.blocked?(limits, "github.com")}
      {true, false}
      iex> {:ok, only} = HostLimits.put(%HostLimits{default: :blocked}, "github.com", false)
      iex> {HostLimits.blocked?(only, "api.github.com"), HostLimits.blocked?(only, "pypi.org")}
      {false, true}
  """
  @spec blocked?(t(), String.t() | nil) :: boolean()
  def blocked?(%__MODULE__{} = limits, host) do
    case rule(limits, host && String.downcase(host)) do
      %{blocked?: blocked?} -> blocked?
      nil -> limits.default == :blocked
    end
  end

  @doc """
  Whether any of `names` may be blocked: a connection to an address these
  names share is held until its first bytes say which one it is for.
  """
  @spec any_blocked?(t(), [String.t()]) :: boolean()
  def any_blocked?(%__MODULE__{default: :blocked}, _names), do: true
  def any_blocked?(%__MODULE__{} = limits, names), do: Enum.any?(names, &blocked?(limits, &1))

  @doc "Whether the limits take anything away: a host blocked by default or by an entry."
  @spec any?(t()) :: boolean()
  def any?(%__MODULE__{default: default, rules: rules}),
    do: default == :blocked or Enum.any?(rules, & &1.blocked?)

  @doc "The entry naming `host` most exactly, or nil."
  @spec rule(t(), String.t() | nil) :: rule() | nil
  def rule(%__MODULE__{rules: rules}, host), do: HostRules.rule(rules, host)

  @doc """
  `host` listed as blocked or reachable, replacing an entry for the same
  names: a host is on one list at most. `{:error, message}` for one that
  can't be an entry (`MWTClient.Sandbox.HostRules.entry/1`).
  """
  @spec put(t(), String.t(), boolean()) :: {:ok, t()} | {:error, String.t()}
  def put(%__MODULE__{} = limits, host, blocked?) when is_boolean(blocked?) do
    with {:ok, rules} <- HostRules.put(limits.rules, %{host: host, blocked?: blocked?}, @limit),
         do: {:ok, %{limits | rules: rules}}
  end

  @doc "The entry for exactly this host gone: it then follows a wider entry, or the default."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = limits, host),
    do: %{limits | rules: HostRules.remove(limits.rules, host)}

  @doc "Sets what a host on neither list gets."
  @spec set_default(t(), :reachable | :blocked) :: t()
  def set_default(%__MODULE__{} = limits, default) when default in [:reachable, :blocked],
    do: %{limits | default: default}

  @doc "The hosts on each list, sorted: `{blocked, reachable}`."
  @spec lists(t()) :: {[String.t()], [String.t()]}
  def lists(%__MODULE__{rules: rules}) do
    {blocked, reachable} =
      rules
      |> Enum.sort_by(&String.trim_leading(&1.host, "*."))
      |> Enum.split_with(& &1.blocked?)

    {Enum.map(blocked, & &1.host), Enum.map(reachable, & &1.host)}
  end
end
