defmodule MWTClient.Sandbox.DisksTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Disks, Snapshot}

  @sizes %{home: 1, cache: 1, work: 2, memory: 1}
  @gib 1024 * 1024 * 1024

  setup do
    dir = Path.join(System.tmp_dir!(), "disks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{paths: Disks.paths(dir)}
  end

  # What the image holds, from its superblock, without mounting it: blkid
  # (util-linux) is on every machine that makes disks, `file` isn't.
  defp kind(path) do
    blkid = System.find_executable("blkid") || "/usr/sbin/blkid"
    {text, 0} = System.cmd(blkid, ["-p", "-o", "export", path])

    for line <- String.split(text, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {key, value}
  end

  defp blocks(path) do
    {text, 0} = System.cmd("/usr/sbin/dumpe2fs", ["-h", path], stderr_to_stdout: true)
    [_, count] = Regex.run(~r/^Block count:\s+(\d+)/m, text)
    [_, size] = Regex.run(~r/^Block size:\s+(\d+)/m, text)
    String.to_integer(count) * String.to_integer(size)
  end

  # The image as it is now, to compare with later: a sparse copy, as small
  # as what the image holds.
  defp copy_as_it_is(path) do
    copy = path <> ".as-it-was"
    {_, 0} = System.cmd("cp", ["--sparse=always", path, copy])
    copy
  end

  # Whether two images hold the same bytes, every one of them. cmp reads
  # them outside the BEAM: File.read! of a gigabyte takes seconds, and
  # Erlang's file server, the one process every File call of every test
  # goes through, does nothing else meanwhile. 2 is cmp's trouble: a
  # failure, not a difference.
  defp same_bytes?(a, b) do
    case System.cmd("cmp", ["--silent", a, b]) do
      {_, 0} -> true
      {_, 1} -> false
    end
  end

  test "the tools that make disks are on this machine" do
    assert Disks.missing_tools() == []
  end

  test "each disk is a sparse ext4 image of its size, yours only", %{paths: paths} do
    assert :ok = Disks.ensure!(paths, @sizes)

    for name <- Disks.names() do
      path = Map.fetch!(paths, name)
      assert File.stat!(path).size == @sizes[name] * @gib
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert %{"TYPE" => "ext4", "LABEL" => label} = kind(path)
      assert label == "mwt-#{name}"
      # Sparse: megabytes on this machine, not gigabytes. Where the file
      # system can't zero a range for free (overlayfs, in the VM), mkfs
      # writes the journal out: up to a 32nd of the disk, so a 16th is the
      # most it may take.
      assert Disks.used(path) < div(@sizes[name] * @gib, 16)
    end

    assert Disks.mount_point(:home) == "/root"
    assert Disks.mount_point(:work) == "/work"

    # The VM's memory, inside Home: mounted after it.
    assert Disks.mount_point(:memory) == "/root/.optmem"

    assert Enum.find_index(Disks.names(), &(&1 == :memory)) >
             Enum.find_index(Disks.names(), &(&1 == :home))
  end

  test "reclaiming gives back what files deleted inside a disk still held", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)
    data = Path.join(paths.dir, "data")
    File.write!(data, :crypto.strong_rand_bytes(20 * 1024 * 1024))
    debugfs = System.find_executable("debugfs") || "/usr/sbin/debugfs"

    # Written into the image and deleted again, as the VM would, without
    # mounting it.
    {_, 0} = System.cmd(debugfs, ["-w", "-R", "write #{data} big", paths.home])
    {_, 0} = System.cmd(debugfs, ["-w", "-R", "rm big", paths.home])

    assert %{before: before, after: now} = Disks.reclaim!(paths.home)
    assert before - now > 15 * 1024 * 1024
    assert %{"TYPE" => "ext4"} = kind(paths.home)
  end

  test "a disk that exists is left as it is, and grown when its size grew", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)
    before = copy_as_it_is(paths.cache)

    :ok = Disks.ensure!(paths, %{@sizes | home: 2})

    assert File.stat!(paths.home).size == 2 * @gib
    assert blocks(paths.home) == 2 * @gib
    assert same_bytes?(paths.cache, before)

    # Never smaller.
    :ok = Disks.ensure!(paths, %{@sizes | home: 1})
    assert File.stat!(paths.home).size == 2 * @gib
  end

  test "a disk whose check fails isn't grown, and each start says so again", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)

    # Damaged so that `e2fsck -p` stops and asks for a manual run (exit 4),
    # as a damaged or crafted disk would: its root folder's inode cleared.
    {_, 0} =
      System.cmd("/usr/sbin/debugfs", ["-w", "-R", "clri <2>", paths.home],
        stderr_to_stdout: true
      )

    for _start <- 1..2 do
      assert_raise RuntimeError, ~r/checking .* failed \(4\)/, fn ->
        Disks.ensure!(paths, %{@sizes | home: 2})
      end
    end

    assert File.stat!(paths.home).size == @gib
    assert blocks(paths.home) == @gib
  end

  test "Home is copied whole, put back, and emptied", %{paths: paths} do
    :ok = Disks.ensure!(paths, @sizes)
    # Stands in for what the VM wrote: bytes past the file system's start.
    {:ok, file} = :file.open(paths.home, [:read, :write, :binary])
    :ok = :file.pwrite(file, 512 * 1024 * 1024, "the vm was here")
    :ok = :file.close(file)
    written = copy_as_it_is(paths.home)

    now = ~U[2026-11-13 12:00:00Z]

    assert %Snapshot{id: id, tag: "2026-11-13.1", taken_at: ^now} =
             snapshot = Disks.snapshot!(paths, "2026-11-13.1", now)

    assert id =~ ~r/^20261113T120000-[0-9a-f]{6}$/

    :ok = Disks.empty!(paths.home)
    assert File.stat!(paths.home).size == @gib
    refute same_bytes?(paths.home, written)
    assert %{"TYPE" => "ext4"} = kind(paths.home)

    :ok = Disks.restore!(paths, snapshot)
    assert same_bytes?(paths.home, written)

    :ok = Disks.delete!(paths, snapshot)
    assert_raise RuntimeError, ~r/is gone/, fn -> Disks.restore!(paths, snapshot) end
  end

  test "the newest three snapshots are kept" do
    snapshots =
      for day <- 1..5 do
        {:ok, at, 0} = DateTime.from_iso8601("2026-11-0#{day}T00:00:00Z")
        %Snapshot{id: "s#{day}", tag: nil, taken_at: at}
      end

    assert {kept, removed} = Disks.keep(Enum.shuffle(snapshots))
    assert Enum.map(kept, & &1.id) == ["s5", "s4", "s3"]
    assert Enum.map(removed, & &1.id) == ["s2", "s1"]
  end
end
