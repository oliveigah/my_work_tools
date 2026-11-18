defmodule MWTClient.Sandbox.SpaceTest do
  @moduledoc "What the VM takes on this machine, and giving it back, for the Storage page."
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Disks, Server, Snapshot}
  alias MWTClient.Vault.Store

  setup do
    identity = MWTClient.VaultHelpers.unlocked_identity("space")
    pid = Store.whereis(Server, identity.username)
    Map.merge(identity, %{pid: pid, folders: :sys.get_state(pid).folders})
  end

  test "each disk's size and what it takes, reclaimed while the VM is stopped", %{
    username: username,
    folders: folders
  } do
    assert %{status: :stopped, disks: [], snapshots: []} = Sandbox.space(username)

    :ok = Disks.ensure!(folders, %{home: 1, cache: 1, work: 1, memory: 1})

    assert %{disks: [%{name: :home, size: size, used: used} | _] = disks} =
             Sandbox.space(username)

    assert Enum.map(disks, & &1.name) == Disks.names()
    assert size == 1024 * 1024 * 1024 and used < size

    :ok = Sandbox.subscribe(username)
    assert Sandbox.reclaim_space(username) == :ok
    assert_receive {:sandbox_event, %{summary: "Disk space reclaimed" <> _}}, 30_000

    assert %{busy: nil, reclaimed: [{:home, %{before: _, after: _}} | _] = reclaimed} =
             Sandbox.space(username)

    assert Enum.map(reclaimed, &elem(&1, 0)) == Disks.names()
  end

  test "reclaiming waits for the VM to stop", %{username: username, pid: pid} do
    :sys.replace_state(pid, &%{&1 | vm: %{&1.vm | status: :running}})
    assert Sandbox.reclaim_space(username) == {:error, :running}
  end

  test "a copy of Home is listed with what it takes, and deleted", %{
    username: username,
    pid: pid,
    folders: folders
  } do
    snapshot = %Snapshot{
      id: "20261116T120000-abcdef",
      tag: "2026-11-16.1",
      taken_at: DateTime.utc_now()
    }

    File.mkdir_p!(folders.snapshots)
    File.write!(Disks.snapshot_path(folders, snapshot.id), "home")
    :sys.replace_state(pid, &%{&1 | snapshots: [snapshot]})

    assert %{snapshots: [%{id: id, used: _}]} = Sandbox.space(username)
    assert id == snapshot.id

    assert Sandbox.delete_snapshot(username, id) == :ok
    refute File.exists?(Disks.snapshot_path(folders, id))
    assert %{snapshots: []} = Sandbox.space(username)
    assert Sandbox.delete_snapshot(username, id) == {:error, :not_found}
  end
end
