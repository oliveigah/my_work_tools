defmodule MWTClient.Sandbox.Network do
  @moduledoc """
  A network the VM reaches through MWT: a resource of its own, as a
  credential is (`MWTClient.Sandbox.Credential`). It holds what is the
  network's and no grant's:

    * `destinations`, the addresses, ranges and names it is made of
      (`MWTClient.Sandbox.Destinations`); the Internet, built in, is every
      public address, and lists none (`internet: true`);
    * `resolver`, the DNS server that answers its names, nil for this
      machine's own;
    * `anchor`, the interface its addresses are reached through, nil for
      wherever this machine routes them;
    * `limits`, the hosts the VM may never reach there, whatever any grant
      says (`MWTClient.Sandbox.HostLimits`).

  Grants over it (`Grant.network`) give uses of it and say how each is
  approved: one over all of it (`Grant.scope` nil), others over some of
  its destinations, such as one host of the Internet auto-approved while
  the rest ask. Any grant that is on and covers a use gives it, the most
  permissive counting (`MWTClient.Sandbox.Policy`). You lock the network,
  not a grant (`{:network, id}`).

  A network grant holds a copy of its network's fields (`attach/2`), so
  what reads a grant's destinations, resolver or interface reads its
  network's; one over part of it keeps its own destinations.
  """

  alias MWTClient.Sandbox.{Allowance, Grant, HostLimits, HostRules}

  @internet_id "internet"

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    purpose: "",
    destinations: [],
    resolver: nil,
    anchor: nil,
    internet: false,
    preset: nil,
    icon: nil,
    proposal: nil,
    limits: %HostLimits{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          purpose: String.t(),
          destinations: [String.t()],
          resolver: String.t() | nil,
          anchor: String.t() | nil,
          internet: boolean(),
          preset: String.t() | nil,
          icon: String.t() | nil,
          proposal: MWTClient.Sandbox.Grant.proposal() | nil,
          limits: HostLimits.t()
        }

  @doc "The Internet: every public address, built in."
  @spec internet() :: t()
  def internet,
    do: %__MODULE__{
      id: @internet_id,
      name: "Internet",
      purpose: "Every public address on the internet.",
      internet: true
    }

  @doc "The network a network grant is over: its own id for one from before networks."
  @spec id_of(Grant.t()) :: String.t()
  def id_of(%Grant{kind: :network, network: id}) when is_binary(id), do: id
  def id_of(%Grant{internet: true}), do: @internet_id
  def id_of(%Grant{id: id}), do: id

  @doc """
  The entry of a network grant's exceptions (`Grant.except`) that covers
  one of `names`, or nil: a grant leaves out a use that may be for any
  host it excepts, as a network's limits block one (`HostLimits`).

      iex> alias MWTClient.Sandbox.{Grant, Network}
      iex> grant = %Grant{id: "internet", name: "Internet", kind: :network, except: ["paste.example"]}
      iex> {Network.excepted(grant, ["api.paste.example"]), Network.excepted(grant, ["github.com"])}
      {"paste.example", nil}
  """
  @spec excepted(Grant.t(), [String.t() | nil]) :: String.t() | nil
  def excepted(%Grant{kind: :network, except: [_ | _] = except}, names) do
    Enum.find_value(names, fn
      name when is_binary(name) ->
        name = name |> String.downcase() |> String.trim_trailing(".")
        Enum.find(except, &HostRules.covers?(&1, name))

      _none ->
        nil
    end)
  end

  def excepted(%Grant{}, _names), do: nil

  @doc """
  A network grant's exceptions from a form's text, one host a line or
  comma-separated, each as `HostRules.entry/1` writes it, repeats
  dropped; or why one can't be. At most #{200} of them.

      iex> MWTClient.Sandbox.Network.except_entries("https://Paste.Example/x, *.tracker.example, paste.example")
      {:ok, ["paste.example", "*.tracker.example"]}
      iex> MWTClient.Sandbox.Network.except_entries("10.0.0.1")
      {:error, "10.0.0.1 is an address: entries are host names, as clients ask for them."}
  """
  @spec except_entries(String.t() | [String.t()] | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def except_entries(nil), do: {:ok, []}

  def except_entries(text) when is_binary(text),
    do: text |> String.split([",", "\n"]) |> except_entries()

  def except_entries(lines) when is_list(lines) do
    lines
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, done} ->
      case HostRules.entry(line) do
        {:ok, entry} ->
          {:cont,
           {:ok, if(Enum.any?(done, &same_names?(&1, entry)), do: done, else: done ++ [entry])}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, entries} when length(entries) > 200 -> {:error, "At most 200 hosts."}
      result -> result
    end
  end

  defp same_names?(one, other),
    do: String.trim_leading(one, "*.") == String.trim_leading(other, "*.")

  @doc "Whether the grant covers only part of its network (`Grant.scope`)."
  @spec part?(Grant.t()) :: boolean()
  def part?(%Grant{kind: :network, scope: [_ | _]}), do: true
  def part?(%Grant{}), do: false

  @doc "The network a grant from before networks stands for: its own fields."
  @spec of_grant(Grant.t()) :: t()
  def of_grant(%Grant{kind: :network, internet: true}), do: internet()

  def of_grant(%Grant{kind: :network} = grant) do
    %__MODULE__{
      id: id_of(grant),
      name: grant.name,
      purpose: grant.purpose || "",
      destinations: if(grant.internet, do: [], else: grant.destinations),
      resolver: grant.resolver,
      anchor: grant.anchor,
      internet: grant.internet,
      preset: grant.preset,
      icon: grant.icon
    }
  end

  @doc """
  The grant with its network's fields copied in, and `network` naming it:
  the resolver and interface; the destinations too, for one over all of it.
  A grant of another kind is left as it is.
  """
  @spec attach(Grant.t(), t()) :: Grant.t()
  def attach(%Grant{kind: :network} = grant, %__MODULE__{} = network) do
    %{
      grant
      | network: network.id,
        resolver: network.resolver,
        anchor: network.anchor,
        destinations:
          case grant.scope do
            [_ | _] = scope -> scope
            _whole -> network.destinations
          end
    }
  end

  def attach(%Grant{} = grant, _network), do: grant

  @doc "Every network grant with its network's fields copied in."
  @spec attach_all([Grant.t()], [t()]) :: [Grant.t()]
  def attach_all(grants, networks) do
    by_id = Map.new(networks, &{&1.id, &1})

    Enum.map(grants, fn
      %Grant{kind: :network} = grant ->
        case by_id[id_of(grant)] do
          %__MODULE__{} = network -> attach(grant, network)
          nil -> grant
        end

      grant ->
        grant
    end)
  end

  @doc """
  The networks for `grants`, made where a network grant has none yet: each
  from before networks becomes a network and one grant over all of it.
  The entries of a network grant's host list (`Grant.host_rules`, before
  2026-11-24) are moved off it:

    * *Block* and *Ask*, to the network's Blocked list
      (`MWTClient.Sandbox.HostLimits`): nothing that waited for you goes
      unasked;
    * *Auto*, a grant over that host, on and auto-approving as MWT starts.

  Returns the grants, the new ones after the one they came from, and the
  networks.

      iex> alias MWTClient.Sandbox.{Grant, HostLimits, Network}
      iex> internet = %{Grant.internet() | state: :on, host_rules: [
      ...>   %{host: "paste.example", action: :block}, %{host: "api.github.com", action: :auto}]}
      iex> {grants, [net]} = Network.migrate([internet], [])
      iex> {HostLimits.blocked?(net.limits, "paste.example"), Enum.map(grants, &{&1.id, &1.scope})}
      {true, [{"internet", nil}, {"internet-api-github-com", ["*.api.github.com"]}]}
  """
  @spec migrate([Grant.t()], [t()]) :: {[Grant.t()], [t()]}
  def migrate(grants, networks) do
    known = MapSet.new(networks, & &1.id)
    taken = MapSet.new(grants, & &1.id)

    {grants, networks, _taken} =
      Enum.reduce(grants, {[], networks, taken}, fn
        %Grant{kind: :network} = grant, {acc, networks, taken} ->
          network_id = id_of(grant)

          networks =
            if MapSet.member?(known, network_id) or Enum.any?(networks, &(&1.id == network_id)),
              do: networks,
              else: networks ++ [of_grant(grant)]

          rules = grant.host_rules || []
          {autos, blocks} = Enum.split_with(rules, &(&1.action == :auto))
          networks = block_all(networks, network_id, Enum.map(blocks, & &1.host))

          {hosts, taken} =
            Enum.map_reduce(autos, taken, fn %{host: host}, taken ->
              id = free_id("#{grant.id}-#{slug(String.trim_leading(host, "*."))}", taken)
              {host_grant(grant, network_id, host, id), MapSet.put(taken, id)}
            end)

          grant = %{grant | network: network_id, host_rules: []}
          {acc ++ [grant | hosts], networks, taken}

        grant, {acc, networks, taken} ->
          {acc ++ [grant], networks, taken}
      end)

    {attach_all(grants, networks), networks}
  end

  defp block_all(networks, _id, []), do: networks

  defp block_all(networks, id, hosts) do
    Enum.map(networks, fn
      %__MODULE__{id: ^id} = network ->
        limits =
          Enum.reduce(hosts, upgrade_limits(network.limits), fn host, limits ->
            case HostLimits.put(limits, host, true) do
              {:ok, limits} -> limits
              {:error, _not_a_host} -> limits
            end
          end)

        %{network | limits: limits}

      network ->
        network
    end)
  end

  defp upgrade_limits(limits), do: HostLimits.upgrade(limits)

  @doc """
  A grant over one host of `whole`'s network, on and auto-approving as MWT
  starts, under `id`: what a host list's *Auto* was. `entry` is a host as
  `MWTClient.Sandbox.HostRules.entry/1` gives it; it covers its name and
  every name under it, so its scope is `*.` the name.
  """
  @spec host_grant(Grant.t(), String.t(), String.t(), String.t()) :: Grant.t()
  def host_grant(whole, network_id, entry, id) do
    scope = if String.starts_with?(entry, "*."), do: entry, else: "*." <> entry
    host = String.trim_leading(entry, "*.")

    %Grant{
      id: id,
      name: "#{whole.name}: #{host}",
      kind: :network,
      purpose: "Lets through #{host} and the names under it, on #{whole.name}.",
      network: network_id,
      scope: [scope],
      destinations: [scope],
      resolver: whole.resolver,
      anchor: whole.anchor,
      state: :on,
      start: :auto,
      minutes: :until_off,
      allowances: [
        %Allowance{id: "allowance-#{id}", pattern: :all, until: nil, origin: %{kind: :start}}
      ]
    }
  end

  @doc "A free id for a new grant over one host of `whole`'s network."
  @spec host_grant_id(Grant.t(), String.t(), [String.t()]) :: String.t()
  def host_grant_id(whole, entry, taken),
    do: free_id("#{whole.id}-#{slug(String.trim_leading(entry, "*."))}", MapSet.new(taken))

  @doc "A host as an entry of a network's limits, or why it can't be one."
  @spec entry(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate entry(text), to: HostRules

  defp slug(host) do
    case host |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "host"
      slug -> slug
    end
  end

  defp free_id(id, taken) do
    if MapSet.member?(taken, id),
      do:
        Enum.find_value(2..10_000, &(not MapSet.member?(taken, "#{id}-#{&1}") && "#{id}-#{&1}")),
      else: id
  end

  @doc "A network from saved state, missing fields filled."
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved) do
    network = struct(__MODULE__, Map.delete(saved, :__struct__))
    %{network | limits: HostLimits.upgrade(Map.get(saved, :limits))}
  end
end
