defmodule MWTClient.Sandbox.FolderSyncUnsentTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{FolderSync, Guest, ShareMounts}

  @old {{2020, 1, 1}, {0, 0, 0}}

  # A shared folder of documents, one of them an office suite's lock file;
  # a folder standing in for the VM's disk.
  setup do
    root =
      Path.join(System.tmp_dir!(), "folder-sync-unsent-#{System.unique_integer([:positive])}")

    share = Path.join(root, "host/docs")
    vm = Path.join(root, "vm")
    for n <- 1..20, do: put(share, "doc#{n}.txt", "doc #{n}\n")
    put(share, "report.odt", "report\n")
    put(share, "~lock.report.odt#", "lock\n")
    File.mkdir_p!(vm)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      share: share,
      lock: Path.join(share, "~lock.report.odt#"),
      guest: Guest.local(vm),
      copy: vm <> ShareMounts.store(share),
      data: Path.join(root, "data"),
      record: FolderSync.new(share, "vm-1")
    }
  end

  # Files written with a time long past, so none is still settling.
  defp put(dir, path, text) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    File.touch!(path, @old)
  end

  # As a look a few seconds on: nothing written here is still settling.
  defp sync(context, record, opts \\ []) do
    FolderSync.sync(
      record,
      context.guest,
      context.data,
      Keyword.merge([now: System.os_time(:second) + 10], opts)
    )
  end

  test "a file gone after the scan stays out of the sync, which sends the rest", context do
    # Called once the folder was scanned, before anything is sent: as the
    # office suite removing its lock file meanwhile.
    hold = fn _share, path, _full ->
      if path == "report.odt", do: File.rm!(context.lock)
      nil
    end

    first = sync(context, context.record, hold: hold)

    assert first.status.error == nil
    assert first.status.sent == 21
    assert first.status.unread == []
    assert File.read!(Path.join(context.copy, "report.odt")) == "report\n"
    refute File.exists?(Path.join(context.copy, "~lock.report.odt#"))

    # Nothing goes twice; the lock file, which the VM never had, is no
    # removal either.
    again = sync(context, first)
    assert {again.status.error, again.status.sent, again.status.removed} == {nil, 0, 0}
  end

  test "a file the VM has, changed and then gone before the send, goes from the copy",
       context do
    first = sync(context, context.record)
    assert File.exists?(Path.join(context.copy, "~lock.report.odt#"))

    put(context.share, "~lock.report.odt#", "lock, taken again\n")

    hold = fn _share, path, _full ->
      if path == "~lock.report.odt#", do: File.rm!(context.lock)
      nil
    end

    gone = sync(context, first, hold: hold)
    assert {gone.status.error, gone.status.sent} == {nil, 0}
    # Unsure in the VM now: the one sync more removes it.
    assert gone.status.unsettled == 1

    settled = sync(context, gone)
    assert {settled.status.sent, settled.status.removed} == {0, 1}
    refute File.exists?(Path.join(context.copy, "~lock.report.odt#"))
  end

  test "a file gone while the host's tar sends: the rest arrive, and stay sent", context do
    # The send starts as soon as the VM's side is given: the lock file goes
    # then, after it was found readable, before tar reaches it.
    guest = %{
      context.guest
      | stream: fn words ->
          if ".mwt-incoming" in words and File.exists?(context.lock), do: File.rm!(context.lock)
          words
        end
    }

    first =
      FolderSync.sync(context.record, guest, context.data, now: System.os_time(:second) + 10)

    assert first.status.error == nil
    assert first.status.sent == 21
    assert File.read!(Path.join(context.copy, "doc20.txt")) == "doc 20\n"
    assert File.read!(Path.join(context.copy, "report.odt")) == "report\n"
    # Changed while it was sent: one sync more takes it for removed.
    assert first.status.unsettled == 1

    again = sync(context, first)
    assert again.status.error == nil
    assert again.status.sent == 0
    refute File.exists?(Path.join(context.copy, "~lock.report.odt#"))

    assert sync(context, again).status.removed == 0
  end

  test "a file this machine won't let MWT read is named, not sent, and tried again", context do
    secret = Path.join(context.share, "secret.txt")
    put(context.share, "secret.txt", "only root reads this\n")
    test = self()

    # Who runs MWT may read everything here (root, in a VM): what an
    # ordinary account gets from a file only root may read.
    refused = fn
      ^secret ->
        send(test, :tried)
        {:error, :eacces}

      _other ->
        :ok
    end

    first = sync(context, context.record, open: refused)

    assert first.status.error == nil
    assert first.status.unread == [%{path: "secret.txt", why: "permission denied"}]
    assert first.status.sent == 22
    # Not being written: no sync more for it.
    assert first.status.unsettled == 0
    refute File.exists?(Path.join(context.copy, "secret.txt"))
    assert_received :tried

    # Each sync tries it again, and sends nothing else twice.
    again = sync(context, first, open: refused)
    assert_received :tried
    assert {again.status.sent, again.status.unread} == {0, first.status.unread}

    # Once it can be read, it goes.
    readable = sync(context, again)
    assert {readable.status.sent, readable.status.unread} == {1, []}
    assert File.read!(Path.join(context.copy, "secret.txt")) == "only root reads this\n"
  end

  test "a file not read is tried again after a restart of MWT too", context do
    secret = Path.join(context.share, "secret.txt")
    put(context.share, "secret.txt", "only root reads this\n")
    refused = fn path -> if path == secret, do: {:error, :eacces}, else: :ok end

    first = sync(context, context.record, open: refused)
    assert first.status.unread != []

    # What a restarted MWT knows: what was sent, kept on disk, and the copy
    # compared whole.
    restarted = sync(context, FolderSync.new(context.share, "vm-1"))
    assert {restarted.status.error, restarted.status.sent} == {nil, 1}
    assert File.read!(Path.join(context.copy, "secret.txt")) == "only root reads this\n"
  end
end
