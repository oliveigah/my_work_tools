defmodule MWTClient.Sandbox.FolderSyncTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{FolderSync, Guest}

  @old {{2020, 1, 1}, {0, 0, 0}}

  # A shared folder with plain files, a link, an empty folder and a git
  # repository holding a secret; a folder standing in for the VM's disk.
  setup do
    root = Path.join(System.tmp_dir!(), "folder-sync-#{System.unique_integer([:positive])}")
    share = Path.join(root, "host/shared")
    vm = Path.join(root, "vm")
    data = Path.join(root, "data")

    put(share, "notes/todo.md", "plan\n")
    put(share, "readme.txt", "hello\n")
    File.mkdir_p!(Path.join(share, "empty"))
    File.ln_s!("notes/todo.md", Path.join(share, "latest"))
    put(share, "app/mix.exs", "code\n")
    put(share, "app/.env", "SECRET=1\n")
    {_, 0} = System.cmd("git", ["-C", Path.join(share, "app"), "init", "-q"])
    File.mkdir_p!(vm)

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      share: share,
      guest: Guest.local(vm),
      copy: vm <> share,
      vm: vm,
      data: data,
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
  defp sync(context, record \\ nil) do
    record =
      FolderSync.sync(record || context.record, context.guest, context.data,
        now: System.os_time(:second) + 10
      )

    assert record.status.error == nil
    record
  end

  defp tree(dir) do
    Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  test "copies everything but the repository, and links as links", context do
    record = sync(context)

    assert record.status.error == nil
    assert record.status.trees == ["app"]
    assert record.status.files == 2
    assert tree(context.copy) == ["empty", "latest", "notes", "notes/todo.md", "readme.txt"]
    assert File.read!(Path.join(context.copy, "notes/todo.md")) == "plan\n"
    assert {:ok, "notes/todo.md"} = File.read_link(Path.join(context.copy, "latest"))
    refute File.exists?(Path.join(context.copy, "app"))
  end

  test "a look with nothing changed changes nothing", context do
    record = sync(context)
    {:ok, before} = File.stat(Path.join(context.copy, "readme.txt"))

    record = sync(context, record)
    {:ok, again} = File.stat(Path.join(context.copy, "readme.txt"))

    assert again.inode == before.inode
    assert record.status.rescued == 0
  end

  test "your edits, additions and deletions reach the copy", context do
    record = sync(context)

    put(context.share, "readme.txt", "hello again\n")
    put(context.share, "notes/new.md", "new\n")
    File.rm!(Path.join(context.share, "notes/todo.md"))
    File.rm_rf!(Path.join(context.share, "empty"))
    record = sync(context, record)

    assert record.status.error == nil
    assert File.read!(Path.join(context.copy, "readme.txt")) == "hello again\n"
    assert tree(context.copy) == ["latest", "notes", "notes/new.md", "readme.txt"]
    assert record.status.rescued == 0
  end

  test "a file changed in the last seconds is sent again, even at the same size and time",
       context do
    record = sync(context)

    path = Path.join(context.share, "readme.txt")
    File.write!(path, "HELLO\n")
    File.touch!(path, @old)

    # A look now: the file changed under 2 s ago, so it is sent.
    record = FolderSync.sync(record, context.guest, context.data)

    assert File.read!(Path.join(context.copy, "readme.txt")) == "HELLO\n"
    assert record.status.rescued == 0
  end

  test "what the VM changed is set aside before your change replaces it", context do
    record = sync(context)

    File.write!(Path.join(context.copy, "readme.txt"), "the VM's edit\n")
    put(context.share, "readme.txt", "yours, longer\n")
    record = sync(context, record)

    assert File.read!(Path.join(context.copy, "readme.txt")) == "yours, longer\n"
    assert record.status.rescued == 1
    assert record.status.rescued_to =~ Path.join(context.vm, ".rescued")
    assert File.read!(Path.join(record.status.rescued_to, "readme.txt")) == "the VM's edit\n"
  end

  test "a whole comparison puts the copy right, setting the VM's changes aside", context do
    record = sync(context)

    File.write!(Path.join(context.copy, "notes/mine.md"), "added in the VM\n")
    File.write!(Path.join(context.copy, "readme.txt"), "edited in the VM\n")
    File.rm!(Path.join(context.copy, "notes/todo.md"))

    # As at a start of the VM, or 5 minutes on.
    record = sync(context, %{record | checked_at: nil})

    assert File.read!(Path.join(context.copy, "readme.txt")) == "hello\n"
    assert File.read!(Path.join(context.copy, "notes/todo.md")) == "plan\n"
    refute File.exists?(Path.join(context.copy, "notes/mine.md"))
    assert record.status.rescued == 2

    assert tree(record.status.rescued_to) == ["notes", "notes/mine.md", "readme.txt"]
  end

  test "a folder that becomes a repository is no longer touched", context do
    record = sync(context)
    {_, 0} = System.cmd("git", ["-C", Path.join(context.share, "notes"), "init", "-q"])
    File.write!(Path.join(context.copy, "notes/todo.md"), "the VM's edit\n")

    record = sync(context, %{record | checked_at: nil})

    assert record.status.trees == ["app", "notes"]
    assert File.read!(Path.join(context.copy, "notes/todo.md")) == "the VM's edit\n"
    refute File.exists?(Path.join(context.copy, "notes/.git"))
    assert record.status.rescued == 0
  end

  test "an excluded repository already in the VM is never removed or rescued", context do
    put(context.copy, "app/.git/config", "keep this repository\n")
    put(context.copy, "app/.env", "keep this file\n")
    put(context.copy, "app/subdir/work.txt", "the VM's work\n")
    # A similarly named path still follows the host.
    put(context.copy, "app-old", "no longer on the host\n")

    record = sync(context)

    assert tree(Path.join(context.copy, "app")) == [
             ".env",
             ".git",
             ".git/config",
             "subdir",
             "subdir/work.txt"
           ]

    assert File.read!(Path.join(context.copy, "app/.env")) == "keep this file\n"
    refute File.exists?(Path.join(context.copy, "app-old"))
    assert record.status.rescued == 1
    refute File.exists?(Path.join(record.status.rescued_to, "app"))

    record = sync(context, %{record | checked_at: nil})
    assert File.read!(Path.join(context.copy, "app/subdir/work.txt")) == "the VM's work\n"
    assert record.status.rescued == 1
  end

  test "excluding a previously copied folder also forgets what was sent inside it", context do
    record = sync(context)
    assert Map.has_key?(record.sent, "notes/todo.md")
    {_, 0} = System.cmd("git", ["-C", Path.join(context.share, "notes"), "init", "-q"])

    record = sync(context, record)

    refute Map.has_key?(record.sent, "notes")
    refute Map.has_key?(record.sent, "notes/todo.md")
    assert File.read!(Path.join(context.copy, "notes/todo.md")) == "plan\n"
    assert record.status.rescued == 0
  end

  test "a folder replaced by a file, and a file by a folder", context do
    record = sync(context)

    File.rm_rf!(Path.join(context.share, "notes"))
    put(context.share, "notes", "now a file\n")
    File.rm!(Path.join(context.share, "readme.txt"))
    put(context.share, "readme.txt/inside.txt", "now a folder\n")
    record = sync(context, record)

    assert record.status.error == nil
    assert File.read!(Path.join(context.copy, "notes")) == "now a file\n"
    assert File.read!(Path.join(context.copy, "readme.txt/inside.txt")) == "now a folder\n"
    assert record.status.rescued == 0
  end

  test "after a restart of MWT, a change the VM made is still told from yours", context do
    sync(context)
    File.write!(Path.join(context.copy, "readme.txt"), "the VM's edit\n")
    put(context.share, "readme.txt", "yours, longer\n")

    # A new record: what was sent comes from the file kept for this VM.
    record = sync(context, FolderSync.new(context.share, "vm-1"))

    assert File.read!(Path.join(context.copy, "readme.txt")) == "yours, longer\n"
    assert record.status.rescued == 1
  end

  test "a new VM starts from nothing", context do
    sync(context)
    File.rm_rf!(context.copy)

    record = sync(context, FolderSync.new(context.share, "vm-2"))

    assert tree(context.copy) == ["empty", "latest", "notes", "notes/todo.md", "readme.txt"]
    assert record.status.rescued == 0
  end

  test "a repository shared itself is a project: nothing is copied", context do
    app = Path.join(context.share, "app")
    record = FolderSync.sync(FolderSync.new(app, "vm-1"), context.guest, context.data)

    assert record.status.project?
    refute File.exists?(context.vm <> app)
  end

  test "a folder inside a repository is never copied", context do
    lib = Path.join(context.share, "app/lib")
    File.mkdir_p!(lib)
    record = FolderSync.sync(FolderSync.new(lib, "vm-1"), context.guest, context.data)

    assert record.status.error =~ "inside the git working tree"
    refute File.exists?(context.vm <> lib)
  end

  test "a file is replaced whole, by a rename, and the staging folder never shows", context do
    record = sync(context)
    {:ok, before} = File.stat(Path.join(context.copy, "readme.txt"))

    put(context.share, "readme.txt", "hello again\n")
    put(context.share, "fresh/deep/new.txt", "new\n")
    File.chmod!(Path.join(context.share, "fresh"), 0o700)
    record = sync(context, record)

    {:ok, again} = File.stat(Path.join(context.copy, "readme.txt"))
    assert again.inode != before.inode
    assert File.read!(Path.join(context.copy, "readme.txt")) == "hello again\n"
    assert File.read!(Path.join(context.copy, "fresh/deep/new.txt")) == "new\n"
    assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(context.copy, "fresh"))
    assert Bitwise.band(mode, 0o777) == 0o700
    refute File.exists?(Path.join(context.copy, ".mwt-incoming"))

    # A send cut short leaves its staging folder: the next whole comparison
    # neither lists it nor sets it aside.
    File.mkdir_p!(Path.join(context.copy, ".mwt-incoming/readme.txt"))
    record = sync(context, %{record | checked_at: nil})
    assert record.status.rescued == 0
  end

  test "a folder of MWT's own is copied whole where it is told, the VM's changes replaced",
       context do
    # Inside a repository here (a home kept in git), and holding one.
    inbox = Path.join(context.share, "app/inbox")
    put(inbox, "bin/mwt", "#!/bin/sh\n")
    put(inbox, "grants.md", "none\n")
    put(inbox, "keep/.git", "gitdir: elsewhere\n")
    copy = context.vm <> "/mnt/mwt"

    record =
      sync(context, FolderSync.new(inbox, "vm-1", to: "/mnt/mwt", kind: :mwt))

    assert tree(copy) == ["bin", "bin/mwt", "grants.md", "keep", "keep/.git"]

    File.write!(Path.join(copy, "grants.md"), "the VM's own\n")
    File.write!(Path.join(copy, "planted"), "x\n")
    put(inbox, "grants.md", "one grant\n")
    record = sync(context, %{record | checked_at: nil})

    assert File.read!(Path.join(copy, "grants.md")) == "one grant\n"
    refute File.exists?(Path.join(copy, "planted"))
    assert record.status.rescued == 0
    refute File.exists?(Path.join(context.vm, ".rescued"))
  end

  test "into a place just made empty, everything goes with a plain tar, then looks go on",
       context do
    inbox = Path.join(context.share, "notes")
    copy = context.vm <> "/mnt/mwt"
    record = FolderSync.new(inbox, "vm-1", to: "/mnt/mwt", kind: :mwt)

    record =
      FolderSync.sync(record, context.guest, context.data,
        fresh: true,
        now: System.os_time(:second) + 10,
        clock: 1_000
      )

    assert record.status.error == nil
    assert record.checked_at == 1_000
    assert tree(copy) == ["todo.md"]

    put(inbox, "todo.md", "plan, longer\n")
    assert sync(context, record).status.error == nil
    assert File.read!(Path.join(copy, "todo.md")) == "plan, longer\n"
  end

  test "a folder sent once goes whole into an empty place", context do
    assert :ok = FolderSync.copy(context.share, context.guest, "/root/.optmem/memory.incoming")

    copied =
      tree(context.vm <> "/root/.optmem/memory.incoming")
      |> Enum.reject(&String.starts_with?(&1, "app/.git/"))

    assert copied == [
             "app",
             "app/.env",
             "app/.git",
             "app/mix.exs",
             "empty",
             "latest",
             "notes",
             "notes/todo.md",
             "readme.txt"
           ]

    assert {:error, "The folder isn't there."} =
             FolderSync.copy(Path.join(context.share, "gone"), context.guest, "/x")
  end

  test "the VM's list is read as plain relative paths only" do
    output =
      Enum.join(
        [
          ["f", "5", "1577836800.0000000000", "", "a/b.txt"],
          ["d", "4096", "1577836800.5", "", "a"],
          ["l", "3", "1577836800.0", "a/b.txt", "c"],
          ["f", "1", "1.0", "", "../escape"],
          ["f", "1", "1.0", "", "/etc/passwd"]
        ]
        |> List.flatten(),
        <<0>>
      ) <> <<0>>

    assert FolderSync.parse_list(output) ==
             {:ok,
              %{
                "a/b.txt" => {:file, 5, 1_577_836_800},
                "a" => :dir,
                "c" => {:link, "a/b.txt"}
              }}
  end
end
