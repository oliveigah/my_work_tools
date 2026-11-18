defmodule MWTClient.Sandbox.CopyLifecycleTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{FolderSync, Guest, Server}
  alias MWTClient.Sandbox.Server.{Copying, Machine, State}
  alias MWTClient.Vault.Store

  @moduletag capture_log: true
  @old {{2020, 1, 1}, {0, 0, 0}}

  setup do
    context = MWTClient.VaultHelpers.unlocked_identity("copy-lifecycle")
    root = Path.join(System.tmp_dir!(), "copy-lifecycle-#{System.unique_integer([:positive])}")
    host = Path.join(root, "host")
    inbox = Path.join(root, "inbox")
    vm = Path.join(root, "vm")
    Enum.each([host, inbox, vm], &File.mkdir_p!/1)
    File.write!(Path.join(host, "readme.txt"), "before\n")
    File.touch!(Path.join(host, "readme.txt"), @old)
    File.write!(Path.join(inbox, "grants.md"), "old grants\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Sandbox.add_share(context.username, host)
    pid = Store.whereis(Server, context.username)
    started_at = DateTime.utc_now()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | vm: %{state.vm | status: :running, started_at: started_at},
          vm_record: %{id: "old-vm", copied: true}
      }
    end)

    Phoenix.PubSub.subscribe(MWTClient.PubSub, State.topic(context.username))

    Map.merge(context, %{
      pid: pid,
      host: host,
      inbox: inbox,
      vm: vm,
      copy: vm <> host,
      guest: Guest.local(vm),
      data: Path.join(root, "data")
    })
  end

  test "a successful copy during OptMem sync is remembered without a false rescue", c do
    before = sync(FolderSync.new(c.host, "old-vm"), c)
    File.write!(Path.join(c.host, "readme.txt"), "after, and longer\n")
    File.touch!(Path.join(c.host, "readme.txt"), @old)
    copied = sync(before, c)
    assert copied.status.rescued == 0

    state = :sys.get_state(c.pid)

    state = %{
      state
      | vm: %{state.vm | busy: "Copying your memory…"},
        sync: %{c.host => before}
    }

    state =
      Machine.finished(state, :sync, %{
        vm: "old-vm",
        started_at: state.vm.started_at,
        records: %{c.host => copied},
        took: 1
      })

    next = sync(state.sync[c.host], c)
    assert next.status.rescued == 0
    assert File.read!(Path.join(c.copy, "readme.txt")) == "after, and longer\n"
    refute File.exists?(Path.join(c.vm, ".rescued"))
  end

  test "replacement waits for shared-folder and inbox copies, leaving new VM files untouched",
       c do
    shared_worker = paused_copy(c, :sync)
    inbox_worker = paused_copy(c, :sync_inbox)
    shared_ref = Process.monitor(shared_worker)
    inbox_ref = Process.monitor(inbox_worker)

    replace_vm(c)
    assert_waiting_for_copies(c)

    # Ticks and inbox writes while waiting must not start any more copies.
    send(c.pid, :sync)
    send(c.pid, :sync_inbox)
    _ = Sandbox.snapshot(c.username)
    tasks = :sys.get_state(c.pid).tasks |> Map.values()
    assert Enum.count(tasks, &(&1 == :sync)) == 1
    assert Enum.count(tasks, &(&1 == :sync_inbox)) == 1
    refute_received :vm_replaced

    # One finished copy isn't enough: /mnt/mwt still has a writer.
    send(shared_worker, :continue)
    assert_receive {:DOWN, ^shared_ref, :process, ^shared_worker, :normal}, 5_000
    assert Sandbox.snapshot(c.username).vm.busy == "Finishing file copies…"
    refute_received :vm_replaced

    send(inbox_worker, :continue)
    assert_receive {:DOWN, ^inbox_ref, :process, ^inbox_worker, :normal}, 5_000
    assert_receive :vm_replaced, 5_000

    assert File.read!(Path.join(c.copy, "new-vm-work.txt")) == "work after recreation\n"
    refute File.exists?(Path.join(c.copy, "readme.txt"))
    assert File.read!(c.vm <> "/mnt/mwt/grants.md") == "new VM grants\n"
    refute File.exists?(Path.join(c.vm, ".rescued"))
  end

  for purpose <- [:sync, :sync_inbox] do
    @purpose purpose
    test "a failed #{@purpose} task releases the lifecycle action", c do
      parent = self()

      :sys.replace_state(c.pid, fn state ->
        State.task(state, @purpose, fn ->
          send(parent, {:copy_paused, self()})

          receive do
            :fail -> raise "copy failed"
          end
        end)
      end)

      assert_receive {:copy_paused, worker}, 5_000
      ref = Process.monitor(worker)
      on_exit(fn -> send(worker, :fail) end)
      replace_vm(c)
      assert_waiting_for_copies(c)
      refute_received :vm_replaced

      send(worker, :fail)

      assert_receive {:DOWN, ^ref, :process, ^worker, {%RuntimeError{message: "copy failed"}, _}},
                     5_000

      assert_receive :vm_replaced, 5_000
    end
  end

  test "an unrelated task does not hold up VM replacement", c do
    parent = self()

    :sys.replace_state(c.pid, fn state ->
      State.task(state, :mirror, fn ->
        send(parent, {:mirror_paused, self()})

        receive do
          :continue -> nil
        end
      end)
    end)

    assert_receive {:mirror_paused, worker}, 5_000
    ref = Process.monitor(worker)
    on_exit(fn -> send(worker, :continue) end)
    replace_vm(c)
    assert_receive :vm_replaced, 5_000
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
  end

  defp sync(record, c) do
    record = FolderSync.sync(record, c.guest, c.data, now: System.os_time(:second) + 10)
    assert record.status.error == nil
    record
  end

  defp paused_copy(c, purpose) do
    parent = self()

    guest = %{
      c.guest
      | stream: fn words ->
          unless Process.get(:copy_released) do
            send(parent, {:copy_paused, purpose, self()})

            receive do
              :continue -> Process.put(:copy_released, true)
            end
          end

          words
        end
    }

    :sys.replace_state(c.pid, fn state ->
      started_at = state.vm.started_at

      State.task(state, purpose, fn ->
        case purpose do
          :sync ->
            records = %{c.host => FolderSync.new(c.host, "old-vm")}

            FolderSync.sync_all(records, guest, c.data)
            |> Map.merge(%{vm: "old-vm", started_at: started_at})

          :sync_inbox ->
            FolderSync.new(c.inbox, "old-vm", to: "/mnt/mwt", kind: :mwt)
            |> FolderSync.sync(guest, c.data)
        end
      end)
    end)

    assert_receive {:copy_paused, ^purpose, worker}, 5_000
    on_exit(fn -> send(worker, :continue) end)
    worker
  end

  # Same ordering as Machine.run_create/1: stop the old VM, drain copies,
  # then replace its filesystem. The local guest exercises the real copy
  # scripts without needing a second kernel.
  defp replace_vm(c) do
    parent = self()

    :sys.replace_state(c.pid, fn state ->
      server = self()
      state = %{state | settings: %{state.settings | shares: []}}
      state = State.change(state, :vm, &%{&1.vm | busy: "Recreating…"})

      State.task(state, {:vm, :create}, fn ->
        :ok = Copying.drain(server)
        File.rm_rf!(c.vm)
        File.mkdir_p!(c.copy)
        File.mkdir_p!(c.vm <> "/mnt/mwt")
        File.write!(Path.join(c.copy, "new-vm-work.txt"), "work after recreation\n")
        File.write!(c.vm <> "/mnt/mwt/grants.md", "new VM grants\n")
        send(parent, :vm_replaced)

        %{
          result: {:ok, ""},
          spec: 123,
          ref: "box:1",
          record: %{id: "new-vm", copied: true},
          snapshots: [],
          taken: nil,
          booted: nil,
          options: %{home: :keep, cache: :keep, seed_memory: false}
        }
      end)
    end)
  end

  defp assert_waiting_for_copies(c) do
    assert_receive {:sandbox_changed, :vm}, 5_000
    assert_receive {:sandbox_changed, :vm}, 5_000
    assert Sandbox.snapshot(c.username).vm.busy == "Finishing file copies…"
  end
end
