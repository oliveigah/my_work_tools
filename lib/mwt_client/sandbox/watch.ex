defmodule MWTClient.Sandbox.Watch do
  @moduledoc """
  The firewall's windows for what the network path sees: names looked up,
  connections, hosts, a tunnel's bytes, what a scanner found. One process
  per unlocked identity, doing nothing else, so a busy
  `MWTClient.Sandbox.Server` never makes a lookup, a connection or a
  tunnel wait (QA L12).

  Each observation is checked against the firewall's settings in the view
  the server published (`MWTClient.Sandbox.Gate`), by the same pure rules
  (`MWTClient.Sandbox.Firewall.check/4`), and answered `:pass`, `:block`,
  `:isolate` or `:isolated`. What it finds goes to the server as a cast,
  to be logged and notified.

  A finding that isolates acts here first, at once: the VM is marked
  isolated in the view (`Gate.trip/2`), so every decision after refuses,
  and every connection the proxy holds is closed. The server is told, and
  does the rest (the incident, approvals refused, grants off, you
  notified); this never calls it, so neither can wait on the other.

  What the server sees itself (asks, commands, MWT's tools, the VM's
  processes) it checks in its own windows
  (`MWTClient.Sandbox.Server.Firewall`).

  A watch that isn't running answers `:isolated`: nothing passes unwatched.
  """

  use GenServer

  alias MWTClient.Sandbox.{Firewall, Gate, Server}
  alias MWTClient.Vault.Store

  @prune_every 30_000

  @doc "Starts the watch of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Checks what the network path saw: `:pass`, `:block`, `:isolate` or
  `:isolated`. Anything but `:pass` means: refuse, or cut. `timeout` is how
  long to wait for the answer (5 seconds; a tunnel's report waits as long
  as it takes).
  """
  @spec observe(String.t(), Firewall.observation(), timeout()) ::
          :pass | :block | :isolate | :isolated
  def observe(username, observation, timeout \\ 5_000) do
    GenServer.call(Store.via(__MODULE__, username), {:observe, observation}, timeout)
  catch
    :exit, _not_running -> :isolated
  end

  @impl true
  def init(username) do
    {:ok, _} = :timer.send_interval(@prune_every, :prune)
    {:ok, %{username: username, watch: Firewall.watch()}}
  end

  @impl true
  def handle_call({:observe, observation}, {caller, _tag}, state) do
    view = Gate.view(state.username)

    if Gate.isolated?(state.username, view) do
      Gate.refused(state.username)
      {:reply, :isolated, state}
    else
      now = System.monotonic_time(:millisecond)
      {watch, findings} = Firewall.check(view.firewall, state.watch, observation, now)
      state = %{state | watch: watch}
      if findings != [], do: Server.cast(state.username, {:firewall_found, findings})

      case Firewall.worst(findings) do
        nil -> {:reply, :pass, state}
        %{action: :alert} -> {:reply, :pass, state}
        %{action: :block} -> {:reply, :block, state}
        %{action: :isolate} = finding -> {:reply, isolate(state, finding, caller), state}
      end
    end
  end

  @impl true
  def handle_info(:prune, state),
    do:
      {:noreply,
       %{state | watch: Firewall.prune(state.watch, System.monotonic_time(:millisecond))}}

  # The mark first, so nothing decided from now on passes; then every
  # connection but the caller's, which closes itself on the answer.
  defp isolate(state, finding, caller) do
    Gate.trip(state.username, finding)

    for {pid, _} <- connections(state.username), pid != caller, do: Process.exit(pid, :kill)

    Server.cast(state.username, {:firewall_isolate, finding})
    :isolate
  end

  defp connections(username) do
    Registry.lookup(MWTClient.Sandbox.Connections, username)
  rescue
    ArgumentError -> []
  end
end
