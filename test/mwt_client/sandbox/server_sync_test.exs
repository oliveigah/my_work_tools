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

      assert :ok = Sandbox.sync_shares(context.username, :all)
      folder = context.folder
      assert %{^folder => %{status: status}} = Sandbox.snapshot(context.username).sync
      assert status.error =~ "Recreate the VM"
      assert status.synced_at == nil
      refute :sync in Map.values(:sys.get_state(context.pid).tasks)
    end
  end

  test "a start forgets the old copy and syncs every share", context do
    state = running(context)
    result = Machine.finished(state, {:vm, :start}, {:ok, "", nil})

    assert result.vm.status == :running
    assert result.sync_due == :all
    assert result.sync == %{}
    assert_receive :sync
  end

  test "a recreate syncs every share into the new VM", context do
    state = running(context)

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
    assert result.sync_due == :all
    assert result.sync == %{}
    assert_receive :sync
  end

  test "noticing a VM started outside MWT also syncs every share", context do
    state = running(context)
    state = %{state | vm: %{state.vm | status: :stopped, started_at: nil}}
    result = Machine.finished(state, :check, %{status: {:ok, :running}, image?: true})

    assert result.sync_due == :all
    assert result.sync == %{}
    assert_receive :sync
  end

  test "a late sync from before a recreate or restart is dropped", context do
    state = running(context)
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
    end
  end

  test "a sync from before a code reload is dropped", context do
    state = running(context)
    result = Machine.finished(state, :sync, %{records: %{}, took: 90_000})

    assert result.sync == state.sync
  end

  defp running(context) do
    state = :sys.get_state(context.pid)

    %{
      state
      | vm: %{state.vm | status: :running, started_at: DateTime.utc_now()},
        vm_record: %{id: "vm-test", copied: true},
        sync: %{context.folder => FolderSync.new(context.folder, "vm-test")}
    }
  end
end
