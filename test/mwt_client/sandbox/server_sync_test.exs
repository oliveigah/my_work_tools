defmodule MWTClient.Sandbox.ServerSyncTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{FolderSync, Server}
  alias MWTClient.Sandbox.Server.Machine
  alias MWTClient.Vault.Store

  setup do
    context = MWTClient.VaultHelpers.unlocked_identity("server-sync")
    folder = Path.join(System.tmp_dir!(), "server-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)
    {:ok, _} = Sandbox.add_share(context.username, folder)
    pid = GenServer.whereis(Store.via(Server, context.username))
    Map.merge(context, %{folder: folder, pid: pid})
  end

  test "a VM with live mounts is left alone until recreated", context do
    for record <- [%{id: "legacy-vm"}, %{id: "legacy-vm", copied: false}] do
      :sys.replace_state(context.pid, fn state ->
        %{
          state
          | vm: %{state.vm | status: :running, exists?: true},
            vm_record: record,
            sync: %{}
        }
      end)

      send(context.pid, :sync)
      folder = context.folder
      assert %{^folder => status} = Sandbox.snapshot(context.username).sync
      assert status.error =~ "Recreate the VM"
      assert status.synced_at == nil
      assert status.rescued == 0
      refute :sync in Map.values(:sys.get_state(context.pid).tasks)
    end
  end

  test "a start clears the old delay and compares the copy again", context do
    state = delayed(context)
    result = Machine.finished(state, {:vm, :start}, {:ok, "", nil})

    assert result.vm.status == :running
    assert result.sync_after == nil
    assert result.sync == %{}
    assert_receive :sync
  end

  test "a recreate clears the old delay and starts the new VM's copy", context do
    state = delayed(context)

    done = %{
      result: {:ok, ""},
      spec: 123,
      ref: "box:1",
      record: %{id: "new-vm", copied: true},
      snapshots: [],
      taken: nil,
      booted: nil,
      options: %{home: :keep, cache: :keep, seed_memory: false}
    }

    result = Machine.finished(state, {:vm, :create}, done)

    assert result.vm_record.id == "new-vm"
    assert result.sync_after == nil
    assert result.sync == %{}
    assert_receive :sync
  end

  test "noticing a VM started outside MWT also clears the old delay", context do
    state = delayed(context)
    state = %{state | vm: %{state.vm | status: :stopped, started_at: nil}}
    result = Machine.finished(state, :check, %{status: {:ok, :running}, image?: true})

    assert result.sync_after == nil
    assert result.sync == %{}
    assert_receive :sync
  end

  test "a late copy from before a recreate or restart cannot restore the old delay", context do
    state = delayed(context)
    previous = DateTime.add(state.vm.started_at, -60, :second)
    records = %{context.folder => FolderSync.new(context.folder, "old-vm")}

    for {vm, started_at} <- [{"old-vm", state.vm.started_at}, {"vm-test", previous}] do
      result =
        Machine.finished(state, :sync, %{
          vm: vm,
          started_at: started_at,
          records: records,
          took: 90_000
        })

      assert result.sync == state.sync
      assert result.sync_after == state.sync_after
    end
  end

  test "a copy from before the layout check is ignored after a code reload", context do
    state = delayed(context)
    result = Machine.finished(state, :sync, %{records: %{}, took: 90_000})

    assert result.sync == state.sync
    assert result.sync_after == state.sync_after
  end

  defp delayed(context) do
    state = :sys.get_state(context.pid)

    %{
      state
      | vm: %{state.vm | status: :running, started_at: DateTime.utc_now()},
        vm_record: %{id: "vm-test", copied: true},
        sync: %{context.folder => FolderSync.new(context.folder, "vm-test")},
        sync_after: System.monotonic_time(:millisecond) + 180_000
    }
  end
end
