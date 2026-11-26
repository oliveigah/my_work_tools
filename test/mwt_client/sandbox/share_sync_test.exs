defmodule MWTClient.Sandbox.ShareSyncTest do
  use ExUnit.Case, async: true

  import MWTClient.HandoffsCase, only: [fake_socat!: 1]

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Server, ShareMounts}
  alias MWTClient.Sandbox.Server.Machine
  alias MWTClient.StandIns
  alias MWTClient.Vault.Store

  @old {{2020, 1, 1}, {0, 0, 0}}
  @cli Path.expand("../../../priv/sandbox/mwt-cli", __DIR__)

  # A shared folder, and a folder of this machine standing in for the VM,
  # which runs.
  setup do
    root = Path.join(System.tmp_dir!(), "share-sync-#{System.unique_integer([:positive])}")
    # Before the identity: removed once it has closed, and the sync that
    # adding the share starts has stopped writing into the VM's copy.
    on_exit(fn -> File.rm_rf!(root) end)
    context = MWTClient.VaultHelpers.unlocked_identity("share-sync")
    folder = Path.join(root, "host/docs")
    vm = Path.join(root, "vm")
    put(folder, "plan.md", "plan\n")
    put(folder, "sub/notes.md", "notes\n")
    File.mkdir_p!(vm)

    StandIns.put_guest(context.username, Guest.local(vm))
    pid = Store.whereis(Server, context.username)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | vm: %{state.vm | status: :running, started_at: DateTime.utc_now()},
          vm_record: %{id: "vm-test", copied: true}
      }
    end)

    {:ok, _} = Sandbox.add_share(context.username, folder)
    Map.merge(context, %{root: root, folder: folder, vm: vm, pid: pid})
  end

  defp put(dir, path, text) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    File.touch!(path, @old)
  end

  # What mwt sync asks for: answered once a sync that started after the ask
  # has ended.
  defp wait(context, which),
    do: Server.call(context.username, {:sync_shares_wait, which}, 10_000)

  # Where the VM shows the folder's copy.
  defp shown(context, path \\ ""), do: Path.join(context.vm <> context.folder, path)

  test "a share is synced when added, and shown at its path", context do
    assert {:ok, %{}} = wait(context, [])

    assert File.read!(shown(context, "plan.md")) == "plan\n"
    assert File.read!(shown(context, "sub/notes.md")) == "notes\n"
    assert File.exists?(context.vm <> ShareMounts.store(context.folder))

    # The folder as the last sync found it. Not what it sent, nor whether one
    # runs: the files made for the test were still settling, and the sync
    # that follows up on them may already have come.
    entry = Sandbox.snapshot(context.username).sync[context.folder]
    assert entry.status.synced_at
    assert entry.status.files == 2
  end

  test "a change reaches the VM only when a sync is asked for", context do
    assert {:ok, _} = wait(context, :all)
    put(context.folder, "plan.md", "plan, changed\n")

    # What the timer used to send: nothing is due, so nothing runs.
    send(context.pid, :sync)
    refute :sync in Map.values(:sys.get_state(context.pid).tasks)
    assert File.read!(shown(context, "plan.md")) == "plan\n"

    assert {:ok, %{} = statuses} = wait(context, [context.folder])
    assert %{removed: 0, error: nil} = statuses[context.folder]
    assert statuses[context.folder].sent >= 1
    assert File.read!(shown(context, "plan.md")) == "plan, changed\n"
  end

  test "the Sync button answers at once, and the sync goes on", context do
    assert {:ok, _} = wait(context, [])
    put(context.folder, "new.md", "new\n")

    assert :ok = Sandbox.sync_shares(context.username, :all)
    assert {:ok, _} = wait(context, [])
    assert File.read!(shown(context, "new.md")) == "new\n"
  end

  test "a share no longer shared leaves the VM", context do
    assert {:ok, _} = wait(context, :all)
    store = context.vm <> Path.dirname(ShareMounts.store(context.folder))

    :ok = Sandbox.remove_share(context.username, context.folder)
    assert {:ok, %{}} = wait(context, [])

    refute File.exists?(shown(context))
    refute File.exists?(store)
    refute Map.has_key?(Sandbox.snapshot(context.username).sync, context.folder)
  end

  test "with the VM stopped, a wait is answered at once", context do
    :sys.replace_state(context.pid, &%{&1 | vm: %{&1.vm | status: :stopped}})
    assert {:error, "The VM isn't running."} = wait(context, :all)
  end

  test "a start syncs every share again, comparing each copy whole", context do
    assert {:ok, _} = wait(context, :all)
    File.write!(shown(context, "plan.md"), "planted in the VM\n")

    reset_at = DateTime.utc_now()
    :sys.replace_state(context.pid, &Server.ShareSync.reset/1)
    assert {:ok, %{} = statuses} = wait(context, [])
    assert statuses == %{}

    assert File.read!(shown(context, "plan.md")) == "plan\n"
    # When the copy last changed, not what the last sync sent: the files
    # made for the test were still settling at the first sync, whose
    # follow-up may come after this one and send nothing.
    status = Sandbox.snapshot(context.username).sync[context.folder].status
    assert DateTime.compare(status.changed_at, reset_at) != :lt
  end

  test "a file this machine won't let MWT read is named in the log, once", context do
    assert {:ok, _} = wait(context, :all)
    state = :sys.get_state(context.pid)
    record = state.sync[context.folder]
    unread = [%{path: "sub/secret.md", why: "permission denied"}]

    # A sync whose folder held such a file, as FolderSync tells it: the
    # rest went, that one didn't.
    result = %{
      vm: "vm-test",
      started_at: state.vm.started_at,
      records: %{context.folder => put_in(record.status[:unread], unread)},
      took: 1
    }

    finished = fn -> :sys.replace_state(context.pid, &Machine.finished(&1, :sync, result)) end
    finished.()
    finished.()

    named =
      for event <- Sandbox.events(context.username),
          event.summary =~ "sub/secret.md",
          do: event.summary

    assert [summary] = named
    assert summary =~ "won't let MWT read it"
    assert Sandbox.snapshot(context.username).sync[context.folder].status.unread == unread
  end

  describe "mwt sync" do
    test "syncs every share, or the one holding a path, and says what changed", context do
      put(context.folder, "sub/more.md", "more\n")

      assert {0, text} = Channel.answer("sync", %{}, context.username)
      assert text =~ "#{context.folder}: up to date"
      assert text =~ "read-only here"

      put(context.folder, "sub/more.md", "more, changed\n")
      ask = %{"path" => Path.join(context.folder, "sub/more.md")}
      assert {0, text} = Channel.answer("sync", ask, context.username)
      assert text =~ ~r"^#{context.folder}: up to date, \d+ sent; 3 files, read-only here\.$"
      assert File.read!(shown(context, "sub/more.md")) == "more, changed\n"
    end

    test "a file this machine won't let MWT read is named to the agent", context do
      status = %{
        error: nil,
        sent: 2,
        removed: 0,
        files: 3,
        held: [],
        unread: [%{path: "sub/secret.md", why: "permission denied"}]
      }

      assert {0, text} = Channel.sync_words(%{context.folder => status}, [])
      assert text =~ "#{context.folder}: up to date, 2 sent; 3 files"
      assert text =~ "Not copied, since the user's machine doesn't let MWT read them"
      assert text =~ "sub/secret.md (permission denied)."

      many = for n <- 1..12, do: %{path: "f#{n}", why: "permission denied"}
      {0, text} = Channel.sync_words(%{context.folder => %{status | unread: many}}, [])
      assert text =~ "f10 (permission denied); and 2 more."
      refute text =~ "f11"
    end

    test "a path outside the shares is refused, naming them", context do
      assert {1, text} = Channel.answer("sync", %{"path" => "/etc"}, context.username)
      assert text =~ "/etc isn't in a shared folder"
      assert text =~ context.folder
    end

    test "the grant decides: off, nothing is synced", context do
      assert {:ok, _} = wait(context, :all)
      {:ok, _} = Sandbox.turn_off(context.username, "share-sync")
      put(context.folder, "plan.md", "plan, changed\n")

      assert {1, text} = Channel.answer("sync", %{}, context.username)
      assert text =~ "Shared folders: sync is off"
      assert File.read!(shown(context, "plan.md")) == "plan\n"
    end

    test "the mwt command sends the path as the VM has it", context do
      bin = Path.join(context.root, "bin")
      File.mkdir_p!(bin)
      fake_socat!(bin)

      {out, status} =
        System.cmd("bash", [@cli, "sync", "sub"],
          cd: context.folder,
          env: [
            {"PATH", bin <> ":" <> System.get_env("PATH")},
            {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert out =~ "#{context.folder}: up to date"
      assert File.read!(shown(context, "sub/notes.md")) == "notes\n"
    end
  end
end
