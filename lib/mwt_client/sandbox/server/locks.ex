defmodule MWTClient.Sandbox.Server.Locks do
  @moduledoc """
  The locks in the sandbox server's state: which resources are locked
  (`MWTClient.Sandbox.Resource`), and by whom.

  Two things lock a resource, each apart, and it stays locked while either
  holds: you, with its switch on the Grants page (`:you`), and the
  isolation (`:isolation`), which locks every resource as the firewall
  isolates the VM and lets go of them as you release it. Releasing never
  ends a lock of yours, and unlocking one never ends the isolation's.

  `state.locks` maps each locked resource to its holders, each with when
  it took the lock: `%{{:credential, "github"} => %{you: ~U[…]}}`. A
  resource no one holds isn't in it, so whatever reads the map (the policy,
  the proxy's view, the inbox) asks only whether a resource is there.
  """

  alias MWTClient.Sandbox.Server.State

  @type holder :: :you | :isolation
  @type resource :: MWTClient.Sandbox.Resource.id()
  @type t :: %{resource() => %{optional(holder()) => DateTime.t()}}

  @doc """
  Locks from a saved state: the holders as they were, or, saved before
  the isolation locked anything, each lock yours.

      iex> at = ~U[2026-11-24 10:00:00Z]
      iex> MWTClient.Sandbox.Server.Locks.upgrade(%{:machine => at})
      %{machine: %{you: ~U[2026-11-24 10:00:00Z]}}
      iex> MWTClient.Sandbox.Server.Locks.upgrade(nil)
      %{}
  """
  @spec upgrade(map() | nil) :: t()
  def upgrade(nil), do: %{}

  def upgrade(locks) when is_map(locks) do
    for {resource, held} <- locks, into: %{} do
      case held do
        %DateTime{} = at -> {resource, %{you: at}}
        %{} = holders -> {resource, holders}
      end
    end
  end

  @doc "Every resource there is now: each credential, each network, your machine, MWT's tools."
  @spec resources(map()) :: [resource()]
  def resources(state),
    do:
      MWTClient.Sandbox.Resource.all(
        Map.get(state, :credentials, []),
        Map.get(state, :networks, [])
      )

  @doc "`resource` locked by `holder`, from now; nothing else changes."
  @spec lock(map(), resource(), holder()) :: map()
  def lock(state, resource, holder) do
    now = State.now()

    Map.update(
      state,
      :locks,
      %{resource => %{holder => now}},
      &Map.update(&1, resource, %{holder => now}, fn held -> Map.put_new(held, holder, now) end)
    )
  end

  @doc "`holder`'s lock on `resource` ended; locked still if another holds it."
  @spec unlock(map(), resource(), holder()) :: map()
  def unlock(state, resource, holder) do
    Map.update(state, :locks, %{}, fn locks ->
      case Map.get(locks, resource) do
        nil ->
          locks

        held ->
          left = Map.delete(held, holder)
          if left == %{}, do: Map.delete(locks, resource), else: Map.put(locks, resource, left)
      end
    end)
  end

  @doc "Every resource there is now locked by `holder` (the isolation's)."
  @spec lock_all(map(), holder()) :: map()
  def lock_all(state, holder),
    do: Enum.reduce(resources(state), state, &lock(&2, &1, holder))

  @doc "Every lock `holder` took ended; the others' stay."
  @spec unlock_all(map(), holder()) :: map()
  def unlock_all(state, holder),
    do: Enum.reduce(Map.keys(Map.get(state, :locks, %{})), state, &unlock(&2, &1, holder))

  @doc "Who holds `resource` locked: `[]`, `[:you]`, `[:isolation]` or both."
  @spec holders(t(), resource()) :: [holder()]
  def holders(locks, resource),
    do: locks |> Map.get(resource, %{}) |> Map.keys() |> Enum.sort()
end
