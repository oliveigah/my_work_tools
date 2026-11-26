defmodule MWTClient.Sandbox.ServerCrashTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MWTClient.Sandbox.{Bubble, Server, Sockets}
  alias MWTClient.Sandbox.Server.State
  alias MWTClient.Vault.Store

  setup do
    MWTClient.VaultHelpers.unlocked_identity("crash")
  end

  # Stands in for the relay of a running VM: answers the control socket and
  # tells the test what it was asked. After a stop it is gone, as a relay
  # is, having run `stopped` first.
  defp fake_relay(username, stopped \\ fn -> :ok end) do
    path = relay_path(username)
    listen = relay_socket(path)
    test = self()
    spawn_link(fn -> relay(listen, path, test, stopped) end)
    on_exit(fn -> File.rm(path) end)
  end

  defp relay_path(username) do
    Sockets.ensure!(username)
    Sockets.path(username, "control.sock")
  end

  # The relay's control socket, listening, owned by the calling process.
  defp relay_socket(path) do
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :line])

    listen
  end

  defp relay(listen, path, test, stopped) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    word = String.trim(line)
    send(test, {:relay_asked, word})

    if word == "stop" do
      stopped.()
      :gen_tcp.send(socket, "stopped\n")
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      File.rm(path)
    else
      :gen_tcp.send(socket, "running\n")
      :gen_tcp.close(socket)
      relay(listen, path, test, stopped)
    end
  end

  # A VM action under way in the sandbox, as `Machine.vm_task/3` and
  # `Machine.create/3` start one: the VM's status reads as it did before.
  # The task waits where a real one waits on msb, and tells the test.
  defp vm_action(pid, action) do
    test = self()

    :sys.replace_state(pid, fn state ->
      state
      |> State.change(:vm, &%{&1.vm | busy: "Starting…"})
      |> State.task({:vm, action}, fn ->
        send(test, {:acting, self()})

        receive do
          :continue -> {:error, "ended by the test"}
        end
      end)
    end)

    assert_receive {:acting, worker}
    on_exit(fn -> send(worker, :continue) end)
    worker
  end

  # What a bubble looks like on this machine from the moment it is
  # launched until its relay listens: a process with the relay's path in
  # the bubble and the VM's name among its words.
  defp launched_bubble(username) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        args: [
          "-c",
          "while :; do sleep 1; done",
          "/mwt/runtime/bin/mwt-relay",
          "--name",
          Server.vm_name(username)
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    gone = fn -> System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true) end
    on_exit(gone)
    {os_pid, gone}
  end

  test "a crash leaves the VM running for the restarted sandbox", %{username: username} do
    fake_relay(username)
    pid = running_vm(username)
    ref = Process.monitor(pid)

    # No handler matches, so the sandbox crashes as it would on a bug. It
    # saves its state into the database on the way down, which a busy test
    # run can take longer than the default wait over.
    capture_log(fn ->
      GenServer.cast(pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:function_clause, _}}, 2_000
    end)

    # The supervisor has seen the crash and brought the sandbox back.
    MWTClient.VaultHelpers.restarted(Server, username, pid)
    refute_received {:relay_asked, "stop"}
  end

  test "a crash leaves a start under way, and its VM, alone", %{username: username} do
    fake_relay(username)
    pid = Store.whereis(Server, username)
    worker = vm_action(pid, :start)
    ref = Process.monitor(pid)

    capture_log(fn ->
      GenServer.cast(pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:function_clause, _}}, 2_000
    end)

    assert Process.alive?(worker)
    refute_received {:relay_asked, "stop"}
  end

  test "locking stops the VM, cleanly, through its relay", %{username: username} do
    fake_relay(username)
    running_vm(username)
    :ok = Store.close(username)

    assert_received {:relay_asked, "stop"}
  end

  test "locking while a start is under way ends it, and stops the VM it may have started",
       %{username: username} do
    fake_relay(username)
    pid = Store.whereis(Server, username)
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | exists?: true, status: :stopped}})
    worker = vm_action(pid, :start)
    ref = Process.monitor(worker)

    :ok = Store.close(username)

    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_received {:relay_asked, "stop"}
  end

  test "locking during a first create stops the bubble it had just launched",
       %{username: username} do
    pid = Store.whereis(Server, username)
    worker = vm_action(pid, :create)
    {os_pid, gone} = launched_bubble(username)

    # A relay listens only once the create's task has ended, so locking
    # asks it to stop again until it does. This one listens once locking
    # has asked twice, the first time with nothing listening, however long
    # it takes to get there: it closes the other stores and saves the
    # sandbox first. A trace session of its own sees each ask.
    test = self()
    path = relay_path(username)
    on_exit(fn -> File.rm(path) end)

    spawn_link(fn ->
      ref = Process.monitor(worker)
      session = :trace.session_create(:locking_during_create, self(), [])
      _ = :trace.function(session, {Bubble, :stop_by, 3}, true, [:local])
      _ = :trace.process(session, pid, true, [:call])
      send(test, :watching)

      receive do
        {:DOWN, ^ref, :process, ^worker, reason} -> send(test, {:create_ended, reason})
      end

      for _ask <- 1..2 do
        receive do
          {:trace, ^pid, :call, {Bubble, :stop_by, _args}} -> :ok
        end
      end

      :trace.session_destroy(session)
      relay(relay_socket(path), path, test, gone)
    end)

    assert_receive :watching
    :ok = Store.close(username)

    assert_received {:create_ended, :killed}
    assert_received {:relay_asked, "stop"}
    refute bubble?(os_pid)
  end

  test "a bubble whose relay never listens is said to be so, at the deadline",
       %{username: username} do
    launched_bubble(username)
    deadline = System.monotonic_time(:millisecond) + 200

    assert {:error, message} = Bubble.stop_by(username, Server.vm_name(username), deadline)
    assert message =~ "never listened"

    # With no bubble, nothing to wait for.
    other = MWTClient.VaultHelpers.unlocked_identity("crash-other").username
    assert :ok = Bubble.stop_by(other, Server.vm_name(other), deadline + 60_000)
  end

  test "locking with no VM, and nothing under way, asks no relay", %{username: username} do
    fake_relay(username)
    :ok = Store.close(username)
    refute_received {:relay_asked, _word}
  end

  defp bubble?(os_pid) do
    case File.read("/proc/#{os_pid}/cmdline") do
      {:ok, words} -> words =~ "mwt-relay"
      {:error, _gone} -> false
    end
  end

  defp running_vm(username) do
    pid = Store.whereis(Server, username)
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | exists?: true, status: :running}})
    pid
  end
end
