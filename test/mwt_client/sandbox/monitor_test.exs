defmodule MWTClient.Sandbox.MonitorTest do
  # The guest and /proc in the application's environment are global.
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox.{Monitor, Server, Sockets}
  alias MWTClient.Sandbox.Monitor.Host
  alias MWTClient.Vault.Store

  @started ~U[2026-11-14 10:00:00Z]

  setup context do
    identity = MWTClient.VaultHelpers.unlocked_identity("monitor")
    test = self()

    # Stands in for the VM: each exec waits for the test to answer it.
    guest = %{
      exec: fn words ->
        send(test, {:exec, self(), words})

        receive do
          {:answer, answer} -> answer
        after
          5_000 -> {:error, "the test didn't answer"}
        end
      end
    }

    proc_root = Path.join(context.tmp_dir, "proc")
    File.mkdir_p!(proc_root)
    Application.put_env(:mwt_client, Monitor, guest: guest, proc_root: proc_root)
    on_exit(fn -> Application.delete_env(:mwt_client, Monitor) end)
    :ok = Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.topic(identity.username))

    Map.merge(identity, %{monitor: Store.whereis(Monitor, identity.username), proc: proc_root})
  end

  @moduletag :tmp_dir

  defp output(busy, uptime) do
    """
    @stat
    cpu  #{busy} 0 0 #{10_000 - busy + uptime * 100} 0 0 0 0 0 0
    cpu0 0 0 0 0 0 0 0 0 0 0
    @uptime
    #{uptime}.00 0.00
    @loadavg
    0.10 0.20 0.30 1/50 99
    @meminfo
    MemTotal:        1000000 kB
    MemFree:          500000 kB
    MemAvailable:     800000 kB
    Buffers:               0 kB
    Cached:           200000 kB
    Shmem:                 0 kB
    SReclaimable:          0 kB
    @net
      eth0: #{uptime * 10} 0 0 0 0 0 0 0 #{uptime * 20} 0 0 0 0 0 0 0
    @df
    /dev/vde 1000 100 900 10% /work
    @conf
    4096
    100
    @procs
    1\t#{busy}\t0\t10\t1\tinit
    @end
    """
  end

  defp vm(username, status, started_at \\ @started) do
    pid = Store.whereis(Server, username)

    :sys.replace_state(
      pid,
      &%{&1 | vm: %{&1.vm | exists?: true, status: status, started_at: started_at}}
    )
  end

  # A tick, the exec it makes answered, and the result taken in.
  defp sample(monitor, answer) do
    send(monitor, :tick)
    assert_receive {:exec, task, ["sh", "-c", _script, "mwt-monitor", "/proc"]}
    send(task, {:answer, answer})
    settle(monitor)
  end

  # Waits for the sampling task, then for the monitor to take its result.
  defp settle(monitor) do
    case :sys.get_state(monitor) do
      %{task: %Task{pid: pid}} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        :sys.get_state(monitor)

      state ->
        state
    end
  end

  test "is empty at first, and for a locked identity", %{username: username} do
    assert Monitor.snapshot(username) == %{
             latest: nil,
             history: [],
             error: nil,
             interval_ms: 5_000
           }

    assert Monitor.snapshot("nobody-unlocked").latest == nil
  end

  test "reads nothing while the VM isn't running", %{username: username, monitor: monitor} do
    send(monitor, :tick)
    settle(monitor)

    refute_received {:exec, _, _}
    refute_received {:sandbox_monitor, _}
    assert Monitor.snapshot(username).latest == nil
  end

  test "samples a running VM, with rates from the second sample on",
       %{username: username, monitor: monitor} do
    vm(username, :running)

    sample(monitor, {:ok, output(1_000, 100)})
    assert_received {:sandbox_monitor, %{latest: first, history: [_], error: nil}}
    assert first.cpu == nil
    assert first.cpus == 1
    assert first.memory.used == 300_000 * 1024
    assert first.host == nil

    sample(monitor, {:ok, output(1_250, 105)})
    assert_received {:sandbox_monitor, %{latest: second, history: [one, two]}}
    # 500 more ticks, 250 of them busy.
    assert second.cpu == 50.0
    assert second.network.rx_rate == 10.0
    assert [%{name: "init", cpu: 50.0}] = second.processes
    assert {one.cpu, two.cpu} == {nil, 50.0}

    assert Monitor.snapshot(username) == %{
             latest: second,
             history: [one, two],
             error: nil,
             interval_ms: 5_000
           }
  end

  test "a VM started again starts its rates again", %{username: username, monitor: monitor} do
    vm(username, :running)
    sample(monitor, {:ok, output(1_000, 100)})
    sample(monitor, {:ok, output(1_250, 105)})

    vm(username, :running, DateTime.add(@started, 3_600))
    sample(monitor, {:ok, output(1_500, 110)})

    assert %{latest: %{cpu: nil}, history: [_, _, _]} = Monitor.snapshot(username)
  end

  test "a failure is kept until a sample succeeds", %{username: username, monitor: monitor} do
    vm(username, :running)
    sample(monitor, {:ok, output(1_000, 100)})

    sample(monitor, {:error, "msb exec failed"})
    assert_received {:sandbox_monitor, %{error: "msb exec failed", latest: %{}}}

    sample(monitor, {:ok, "cut sh"})
    assert %{error: "Reading the VM failed: cut sh"} = Monitor.snapshot(username)

    sample(monitor, {:ok, output(1_250, 105)})
    assert %{error: nil, latest: %{cpu: 50.0}} = Monitor.snapshot(username)
  end

  test "a tick while a sample runs is skipped", %{username: username, monitor: monitor} do
    vm(username, :running)
    send(monitor, :tick)
    assert_receive {:exec, task, _}

    send(monitor, :tick)
    send(monitor, :tick)
    _ = :sys.get_state(monitor)
    refute_received {:exec, _, _}

    send(task, {:answer, {:ok, output(1_000, 100)}})
    settle(monitor)
    assert %{latest: %{}, history: [_]} = Monitor.snapshot(username)
  end

  test "a stopped VM has no latest sample; its history stays",
       %{username: username, monitor: monitor} do
    vm(username, :running)
    sample(monitor, {:ok, output(1_000, 100)})
    assert_received {:sandbox_monitor, _}

    vm(username, :stopped, nil)
    send(monitor, :tick)
    settle(monitor)

    refute_received {:exec, _, _}
    assert_received {:sandbox_monitor, %{latest: nil, history: [_]}}
  end

  test "what the VM costs this machine, from its bubble down",
       %{username: username, monitor: monitor, proc: proc} do
    stat = fn pid, ppid, ticks, rss ->
      File.mkdir_p!(Path.join(proc, "#{pid}"))

      File.write!(
        Path.join([proc, "#{pid}", "stat"]),
        "#{pid} (vm (x)) S #{ppid} 1 1 0 -1 0 0 0 0 0 #{ticks} 0 0 0 20 0 1 0 #{pid} 0 #{rss} 0\n"
      )
    end

    stat.(700, 1, 10, 100)
    stat.(701, 700, 20, 1_000)
    stat.(800, 1, 999, 99_999)

    Sockets.ensure_host!(username)
    pid_file = Sockets.host_path(username, "bubble.pid")
    File.write!(pid_file, "700\n")
    on_exit(fn -> File.rm(pid_file) end)

    vm(username, :running)
    sample(monitor, {:ok, output(1_000, 100)})

    %{page_size: page} = Host.constants()
    assert %{latest: %{host: %{rss: rss, cpu: nil, cores: cores}}} = Monitor.snapshot(username)
    assert rss == 1_100 * page
    assert cores == Host.cores()

    stat.(701, 700, 520, 1_000)
    sample(monitor, {:ok, output(1_250, 105)})

    assert %{latest: %{host: %{cpu: cpu}}, history: [_, %{host_cpu: cpu}]} =
             Monitor.snapshot(username)

    assert cpu > 0
  end
end
