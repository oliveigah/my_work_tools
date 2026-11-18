defmodule MWTClient.Sandbox.FolderSyncBoundsTest do
  # What the VM's side prints is the VM's to decide: root there puts its own
  # `sh`, `find` or `tar` on msb exec's PATH. A guest whose `stream` words
  # flood stands in for such a VM.
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{FolderSync, Guest}

  @old {{2020, 1, 1}, {0, 0, 0}}

  setup do
    root = Path.join(System.tmp_dir!(), "folder-bounds-#{System.unique_integer([:positive])}")
    share = Path.join(root, "share")
    vm = Path.join(root, "vm")
    File.mkdir_p!(Path.join(share, "d"))
    File.write!(Path.join(share, "d/a.txt"), "a")
    File.touch!(Path.join(share, "d/a.txt"), @old)
    File.mkdir_p!(vm)
    on_exit(fn -> File.rm_rf!(root) end)
    %{share: share, vm: vm, guest: Guest.local(vm), data: Path.join(root, "data")}
  end

  defp flooding(guest, match, flood) do
    %{
      guest
      | stream: fn
          ["bash", "-c", script | _] = words ->
            if script =~ match, do: ["sh", "-c", flood], else: words

          words ->
            words
        end
    }
  end

  # Runs `fun` in a process killed the moment it holds more than `mib` MiB,
  # binaries included: what MWT takes in, whatever else runs meanwhile.
  defp within(mib, fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(mib * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        exit({:done, fun.()})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:done, result}} -> result
      {:DOWN, ^ref, :process, ^pid, :killed} -> flunk("it took in more than #{mib} MiB")
    end
  end

  test "a VM printing without end while a copy is prepared fails the look, briefly", context do
    # The first look sends the folder into an empty place; the next one,
    # after a change, prepares the VM's side first.
    record = FolderSync.sync(FolderSync.new(context.share, "vm-1"), context.guest, context.data)
    assert record.status.error == nil
    File.write!(Path.join(context.share, "d/b.txt"), "b")
    File.touch!(Path.join(context.share, "d/b.txt"), @old)

    hostile = flooding(context.guest, "aside()", "yes 'it never ends'")

    record =
      within(16, fn ->
        FolderSync.sync(record, hostile, context.data, now: System.os_time(:second) + 10)
      end)

    assert record.status.error =~
             "The VM's copy couldn't be prepared: it printed more than 64 KiB"

    assert byte_size(record.status.error) < 4 * 1024
  end

  # Their first 64 KiB are all that is written, here as on disk
  # (`MWTClient.Sandbox.BoundedTest`).
  test "a VM's errors without end are cut", context do
    hostile = %{context.guest | stream: fn _words -> ["sh", "-c", "yes err >&2; exit 1"] end}

    assert {:error, text} = within(16, fn -> FolderSync.read(hostile, ["find", "."], 1024) end)
    assert text =~ ~r/\Aerr\nerr\n/
    assert byte_size(text) < 4 * 1024
  end

  test "a VM's output past what is asked is an error, and the command stops", context do
    hostile = %{context.guest | stream: fn _words -> ["yes"] end}
    assert FolderSync.read(hostile, ["find", "."], 1024) == {:error, "it is more than 1024 bytes"}
  end

  test "a list holding more records than a copy may is refused, not parsed whole" do
    record = <<"d", 0, 0, 0, 0>>
    list = for i <- 1..1_001, into: "", do: record <> "p#{i}" <> <<0>>

    assert {:ok, have} = FolderSync.parse_list(list, 1_001)
    assert map_size(have) == 1_001
    assert FolderSync.parse_list(list, 1_000) == {:error, :too_many}
  end

  test "a list's paths are copied out of it, so it isn't held with them" do
    list = <<"f", 0, "1", 0, "1.0", 0, 0, "a/b.txt", 0>>
    assert {:ok, %{"a/b.txt" => {:file, 1, 1}} = have} = FolderSync.parse_list(list)
    [path] = Map.keys(have)
    assert :binary.referenced_byte_size(path) == byte_size(path)
  end
end
