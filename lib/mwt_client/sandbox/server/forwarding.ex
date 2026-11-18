defmodule MWTClient.Sandbox.Server.Forwarding do
  @moduledoc """
  The server's part in showing the VM's servers on this machine: a
  `MWTClient.Sandbox.Forwarder` runs exactly while the VM does, the VM's
  reports of what listens in it reach it through here, and what it forwards
  is kept in the state's `ports` for the pages and for `mwt ports`.

  The VM reports with `mwt ports --watch`, which its boot script starts:
  every 2 seconds it reads what listens on `MWTClient.Sandbox.Ports.range/0`,
  and sends it when it changed, and
  once a minute anyway, so a restarted MWT hears it again. The last report
  is kept here, so a forwarder started later (the VM started again, the
  previous one crashed) starts from it.

  Tests have no VM, so no forwarder unless their config asks for one:
  `config :mwt_client, MWTClient.Sandbox.Forwarder, enabled: true, tunnel:
  module, opts: [...]`, and `restart_after:` (milliseconds) for how soon a
  crashed forwarder is started again.
  """

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.{Forwarder, Msb, Ports, Sockets}
  alias MWTClient.Sandbox.Server.State

  @restart_after 5_000

  @doc "What the state's `ports` holds before any forwarder ran."
  def initial, do: %{status: :off, ports: [], listeners: nil, reported_at: nil}

  @doc "The VM's address on this machine (`MWTClient.Sandbox.Ports.address/1`)."
  def address(state), do: Ports.address(Accounts.id(state.username))

  @doc "The state's `ports` as the pages see it: what is forwarded, and where."
  def view(state) do
    state.ports
    |> Map.delete(:listeners)
    |> Map.put(:address, address(state))
  end

  @doc """
  Starts a forwarder when the VM runs and none does, and stops it when the
  VM doesn't. Called whenever the VM's record changes.
  """
  def sync(state) do
    # Not while the firewall holds the VM isolated: its servers stay in it.
    wanted? =
      enabled?() and state.vm.status == :running and
        not MWTClient.Sandbox.Server.Firewall.isolated?(state)

    cond do
      wanted? and is_nil(state.forwarder) -> start(state)
      not wanted? and not is_nil(state.forwarder) -> stop(state)
      true -> state
    end
  end

  @doc """
  A report from the VM of what listens in it (`MWTClient.Sandbox.Ports.parse/1`),
  kept, and given to the forwarder when one runs.
  """
  def reported(state, report) do
    listeners = Ports.parse(report)
    if state.forwarder, do: Forwarder.listening(state.forwarder, listeners)

    State.change(state, :ports, fn state ->
      %{state.ports | listeners: listeners, reported_at: State.now()}
    end)
  end

  @doc "What the forwarder says it forwards."
  def forwarded(state, snapshot),
    do: State.change(state, :ports, &Map.merge(&1.ports, snapshot))

  @doc "The forwarder crashed: say so, and start another in a while."
  def crashed(state, reason) do
    Logger.warning("port forwarding stopped: #{inspect(reason)}", system: :sandbox)

    restart_after =
      Keyword.get(Application.get_env(:mwt_client, Forwarder, []), :restart_after, @restart_after)

    Process.send_after(self(), :sync_forwarder, restart_after)

    state
    |> Map.put(:forwarder, nil)
    |> State.change(:ports, &%{&1.ports | status: {:error, "Port forwarding stopped"}, ports: []})
  end

  defp start(state) do
    config = Application.get_env(:mwt_client, Forwarder, [])
    Sockets.ensure_host!(state.username)

    {:ok, pid} =
      Forwarder.start_link(
        Keyword.merge(Keyword.get(config, :opts, []),
          report_to: self(),
          address: address(state),
          tunnel: Keyword.get(config, :tunnel, Forwarder.SSH),
          tunnel_opts: %{
            launcher: Msb.launcher(state.username),
            vm: state.vm.name,
            key: Path.join(state.dir, "forward_key"),
            # Never in the folder the VM's bubble mounts: whoever reaches the
            # control socket can add listeners on this machine.
            control: Sockets.host_path(state.username, "forward.sock")
          }
        )
      )

    if state.ports.listeners, do: Forwarder.listening(pid, state.ports.listeners)

    state
    |> Map.put(:forwarder, pid)
    |> State.change(:ports, &%{&1.ports | status: :connecting, ports: []})
  end

  defp stop(state) do
    Process.unlink(state.forwarder)
    Process.exit(state.forwarder, :shutdown)

    # A VM that stops listens to nothing: its next start reports afresh.
    state
    |> Map.put(:forwarder, nil)
    |> State.change(:ports, fn _ -> initial() end)
  end

  defp enabled? do
    config = Application.get_env(:mwt_client, Forwarder, [])
    Keyword.get_lazy(config, :enabled, &State.external?/0)
  end

  @doc """
  What `mwt ports` prints: where the VM's servers open on the user's
  machine, and what isn't forwarded, with why.
  """
  def text(state) do
    %{status: status, ports: ports, address: address} = view(state)
    {forwarded, others} = Enum.split_with(ports, &(&1.status == :forwarded))

    head =
      case status do
        :off -> "Forwarding is off: the VM isn't running under MWT."
        :connecting -> "Forwarding is starting; ask again in a few seconds."
        :waiting -> "Forwarding is ready; this VM hasn't said what listens in it yet."
        {:error, message} -> "Forwarding has a problem: #{message}"
        :on when ports == [] -> "Nothing listens on ports #{Ports.range_text()} in this VM yet."
        :on -> nil
      end

    forwarded_text =
      if forwarded != [],
        do:
          "Open on the user's machine, at this VM's address there (#{address}), same port:\n\n" <>
            Enum.map_join(forwarded, "\n", fn entry ->
              "- #{entry.port}: #{Ports.url(address, entry.port)}#{about(entry)}"
            end)

    others_text =
      if others != [],
        do:
          "Not forwarded:\n\n" <>
            Enum.map_join(others, "\n", fn entry ->
              reason =
                case entry.status do
                  {:skipped, reason} -> reason
                  :pending -> "Starting"
                end

              "- #{entry.port}#{about(entry)}: #{reason}"
            end)

    footer =
      "A server you start in the VM on a port from #{Ports.range_text()} opens there by itself, " <>
        "on any address in the VM (127.0.0.1 included). Other ports stay in the VM. " <>
        "The user opens the URL in their browser."

    [head, forwarded_text, others_text, footer]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp about(entry) do
    slot =
      case Ports.slot(entry.cwd) do
        {project, slot} -> "#{slot} of #{project}"
        nil -> nil
      end

    case Enum.reject([entry.process, slot], &is_nil/1) do
      [] -> ""
      words -> " (" <> Enum.join(words, ", ") <> ")"
    end
  end
end
