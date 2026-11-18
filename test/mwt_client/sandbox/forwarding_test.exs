defmodule MWTClient.Sandbox.ForwardingTest do
  # Not async: forwarding is turned on, with a fake tunnel, through the
  # application env.
  use ExUnit.Case, async: false

  alias MWTClient.FakeTunnel
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Forwarder, Ports, Server}
  alias MWTClient.Sandbox.Server.State
  alias MWTClient.Vault.Store

  setup do
    agent = FakeTunnel.agent()

    for {module, value} <- [
          {Forwarder,
           [enabled: true, tunnel: FakeTunnel, restart_after: 300, opts: [reconnect_every: 20]]},
          {FakeTunnel, [test: self(), agent: agent]}
        ] do
      Application.put_env(:mwt_client, module, value)
      on_exit(fn -> Application.delete_env(:mwt_client, module) end)
    end

    context = MWTClient.VaultHelpers.unlocked_identity("ports")
    pid = GenServer.whereis(Store.via(Server, context.username))
    Map.merge(context, %{server: pid, agent: agent})
  end

  # The VM's record changes as checking it would say.
  defp vm(server, status) do
    :sys.replace_state(server, fn state ->
      State.change(state, :vm, &%{&1.vm | exists?: true, status: status})
    end)
  end

  defp ports(username), do: Sandbox.snapshot(username).ports

  defp until(fun) do
    Enum.find_value(1..200, fn _ ->
      fun.() || (Process.sleep(10) && nil)
    end) || flunk("never happened")
  end

  test "while the VM runs, what it reports listening opens at its address here", %{
    username: username,
    server: server
  } do
    address = Ports.address(MWTClient.Accounts.id(username))
    assert %{status: :off, address: ^address, ports: []} = ports(username)

    vm(server, :running)
    assert_receive {:tunnel, :open, _ref, opts}
    assert opts.vm == Server.vm_name(username)
    assert opts.launcher =~ "/sandbox/bin/msb"

    # The SSH control socket, through which anyone can add listeners here,
    # is in MWT's own folder, which no bubble mounts.
    assert Path.dirname(opts.control) == MWTClient.Sandbox.Sockets.host_dir(username)
    refute String.starts_with?(opts.control, MWTClient.Sandbox.Sockets.dir(username) <> "/")
    until(fn -> ports(username).status == :waiting end)

    report =
      FakeTunnel.report([
        {"127.0.0.1", 4101, "beam.smp", "/work/app.wt/slot-1"},
        {"0.0.0.0", 22, "sshd"}
      ])

    # The VM's watcher, through the channel.
    assert Channel.answer("ports", %{"report" => report}, username) == {0, "ok"}
    assert_receive {:tunnel, :forward, ^address, 4101, "127.0.0.1"}

    # Only the range is listed: sshd's 22 stays in the VM, unmentioned.
    until(fn ->
      match?(%{status: :on, ports: [%{port: 4101, status: :forwarded}]}, ports(username))
    end)

    # What an agent hears from `mwt ports`.
    {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "- 4101: http://#{address}:4101 (beam.smp, slot-1 of app)"
    refute text =~ "sshd"
    refute text =~ "Not forwarded"
    assert text =~ "on a port from 4100 to 4199"

    # And what host.md says about it.
    host = Server.call(username, :host_text)
    assert host =~ "on a port from 4100 to 4199"
    assert host =~ "http://#{address}:4100"

    # A VM listening only outside the range has nothing to show.
    report = FakeTunnel.report([{"0.0.0.0", 22, "sshd"}, {"127.0.0.1", 39_801, "beam.smp"}])
    assert Channel.answer("ports", %{"report" => report}, username) == {0, "ok"}
    assert_receive {:tunnel, :cancel, ^address, 4101, "127.0.0.1"}
    until(fn -> match?(%{status: :on, ports: []}, ports(username)) end)
    {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "Nothing listens on ports 4100 to 4199 in this VM yet."

    # The VM stops: its forwards end, and what it said goes with it.
    vm(server, :stopped)
    assert_receive {:tunnel, :close, _ref}
    assert %{status: :off, ports: []} = ports(username)
    {0, text} = Channel.answer("ports", %{}, username)
    assert text =~ "Forwarding is off"
  end

  test "a forwarder started after the VM reported starts from that report", %{
    username: username,
    server: server
  } do
    report = FakeTunnel.report([{"127.0.0.1", 4102, "beam.smp"}])
    assert {0, "ok"} = Channel.answer("ports", %{"report" => report}, username)

    vm(server, :running)
    assert_receive {:tunnel, :forward, _address, 4102, "127.0.0.1"}
  end

  test "a forwarder that crashes is started again", %{username: username, server: server} do
    vm(server, :running)
    assert_receive {:tunnel, :open, _ref, _opts}
    forwarder = :sys.get_state(server).forwarder

    ref = Process.monitor(forwarder)
    Process.exit(forwarder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^forwarder, :killed}

    until(fn -> match?({:error, "Port forwarding stopped"}, ports(username).status) end)
    assert_receive {:tunnel, :open, _ref, _opts}, 1_000
    assert :sys.get_state(server).forwarder not in [nil, forwarder]
  end
end
