defmodule MWTClient.Sandbox.ForwarderTest do
  use ExUnit.Case, async: true

  alias MWTClient.FakeTunnel
  alias MWTClient.Sandbox.Forwarder

  # A loopback address nothing else here uses: when a forward fails, the
  # forwarder tries listening on it to find out why.
  @address "127.77.231.17"

  setup do
    %{agent: FakeTunnel.agent()}
  end

  defp start(agent, opts \\ []) do
    start_supervised!(
      {Forwarder,
       Keyword.merge(
         [
           report_to: self(),
           address: @address,
           tunnel: FakeTunnel,
           tunnel_opts: %{test: self(), agent: agent},
           reconnect_every: 20,
           retry_after: 150
         ],
         opts
       )}
    )
  end

  # What the VM reports, as its watcher would.
  defp listening(pid, listeners), do: Forwarder.listening(pid, FakeTunnel.listeners(listeners))

  # Snapshots until one matches.
  defp snapshot(pred, timeout \\ 2_000) do
    receive do
      {:ports, _pid, snapshot} ->
        if pred.(snapshot), do: snapshot, else: snapshot(pred, timeout)
    after
      timeout -> flunk("no matching snapshot")
    end
  end

  defp entry(snapshot, port), do: Enum.find(snapshot.ports, &(&1.port == port))

  test "waits for the VM to say what listens, then forwards it to the same port here", %{
    agent: agent
  } do
    pid = start(agent)
    assert_receive {:ports, _, %{status: :connecting}}
    assert_receive {:tunnel, :open, _ref, _opts}
    snapshot(&(&1.status == :waiting))
    refute_received {:tunnel, :forward, _, _, _}

    listening(pid, [
      {"127.0.0.1", 4100, "beam.smp", "/work/app.wt/slot-1"},
      {"0.0.0.0", 4173, "node"},
      {"[::1]", 4180, "python3"},
      {"0.0.0.0", 4000, "beam.smp"},
      {"127.0.0.1", 39_801, "beam.smp", "/work/app.wt/slot-1"},
      {"0.0.0.0", 80, "nginx"}
    ])

    snapshot = snapshot(&(&1.status == :on))
    assert_received {:tunnel, :forward, @address, 4100, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 4173, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 4180, "::1"}
    refute_received {:tunnel, :forward, _, _, _}

    assert %{status: :forwarded, process: "beam.smp", cwd: "/work/app.wt/slot-1"} =
             entry(snapshot, 4100)

    assert %{status: :forwarded, target: "::1"} = entry(snapshot, 4180)

    # Ports outside the range stay in the VM, and aren't listed.
    assert Enum.map(snapshot.ports, & &1.port) == [4100, 4173, 4180]

    # The same report again changes nothing, and says nothing.
    listening(pid, [
      {"127.0.0.1", 4100, "beam.smp", "/work/app.wt/slot-1"},
      {"0.0.0.0", 4173, "node"},
      {"[::1]", 4180, "python3"},
      {"0.0.0.0", 4000, "beam.smp"},
      {"127.0.0.1", 39_801, "beam.smp", "/work/app.wt/slot-1"},
      {"0.0.0.0", 80, "nginx"}
    ])

    refute_receive {:ports, _, _}, 100
    refute_received {:tunnel, :forward, _, _, _}
  end

  test "a report that comes before the tunnel is up is applied once it is", %{agent: agent} do
    FakeTunnel.set(agent, :open, {:error, "The VM isn't running"})
    pid = start(agent)
    listening(pid, [{"127.0.0.1", 4100, "beam.smp"}])
    assert_receive {:tunnel, :open_failed}
    refute_received {:tunnel, :forward, _, _, _}

    FakeTunnel.set(agent, :open, :ok)
    assert_receive {:tunnel, :forward, @address, 4100, "127.0.0.1"}, 1_000
    snapshot(&(&1.status == :on and entry(&1, 4100).status == :forwarded))
  end

  test "a server that stops loses its forward, and a new one gets one", %{agent: agent} do
    pid = start(agent)
    listening(pid, [{"127.0.0.1", 4100, "beam.smp"}])
    snapshot(&(entry(&1, 4100) && entry(&1, 4100).status == :forwarded))

    listening(pid, [{"127.0.0.1", 4101, "beam.smp"}])
    snapshot = snapshot(&(entry(&1, 4101) != nil))

    assert_received {:tunnel, :cancel, @address, 4100, "127.0.0.1"}
    assert_received {:tunnel, :forward, @address, 4101, "127.0.0.1"}
    assert entry(snapshot, 4100) == nil
  end

  test "a port this machine already holds is listed with why, and tried again later", %{
    agent: agent
  } do
    {:ok, ip} = :inet.parse_address(String.to_charlist(@address))
    port = 4150
    {:ok, taken} = :gen_tcp.listen(port, ip: ip)

    FakeTunnel.set(agent, :fail, %{port => "Port forwarding failed"})
    pid = start(agent)
    listening(pid, [{"127.0.0.1", port, "beam.smp"}])

    snapshot = snapshot(&match?(%{status: {:skipped, _}}, entry(&1, port)))
    assert entry(snapshot, port).status == {:skipped, "Something on this machine already uses it"}
    assert_received {:tunnel, :forward, @address, ^port, "127.0.0.1"}

    # Not on the next report, but again once its wait is over.
    listening(pid, [{"127.0.0.1", port, "beam.smp"}])
    refute_receive {:tunnel, :forward, _, ^port, _}, 50
    :gen_tcp.close(taken)
    FakeTunnel.set(agent, :fail, %{})

    assert_receive {:tunnel, :forward, @address, ^port, "127.0.0.1"}, 1_000
    snapshot(&(entry(&1, port).status == :forwarded))
  end

  test "a forward the tunnel refuses for another reason says what the tunnel said", %{
    agent: agent
  } do
    FakeTunnel.set(agent, :fail, %{4199 => "administratively prohibited"})
    pid = start(agent)
    listening(pid, [{"127.0.0.1", 4199, "beam.smp"}])

    snapshot = snapshot(&match?(%{status: {:skipped, _}}, entry(&1, 4199)))

    assert entry(snapshot, 4199).status ==
             {:skipped, "Couldn't forward it: administratively prohibited"}
  end

  test "when the tunnel closes, its forwards are gone, and come back when it opens again", %{
    agent: agent
  } do
    pid = start(agent)
    assert_receive {:tunnel, :open, ref, _opts}
    listening(pid, [{"127.0.0.1", 4100, "beam.smp"}])
    snapshot(&(&1.status == :on))

    send(pid, {ref, {:data, "client_loop: send disconnect: Broken pipe\n"}})
    send(pid, {ref, {:exit_status, 255}})

    assert %{ports: []} =
             snapshot(
               &(&1.status ==
                   {:error,
                    "The connection to the VM closed (client_loop: send disconnect: Broken pipe)"})
             )

    # The last report is applied again on the new tunnel, without another.
    assert_receive {:tunnel, :open, new_ref, _opts}
    assert new_ref != ref
    snapshot(&(&1.status == :on and entry(&1, 4100).status == :forwarded))
  end

  test "a tunnel that can't open says why and keeps trying", %{agent: agent} do
    FakeTunnel.set(agent, :open, {:error, "MWT's launcher for the VM is missing"})
    start(agent)

    snapshot(&(&1.status == {:error, "MWT's launcher for the VM is missing"}))
    assert_receive {:tunnel, :open_failed}
    assert_receive {:tunnel, :open_failed}

    FakeTunnel.set(agent, :open, :ok)
    assert_receive {:tunnel, :open, _ref, _opts}
    snapshot(&(&1.status == :waiting))
  end

  test "stopping closes the tunnel", %{agent: agent} do
    start(agent)
    assert_receive {:tunnel, :open, ref, _opts}

    stop_supervised!(Forwarder)
    assert_receive {:tunnel, :close, ^ref}
  end
end
