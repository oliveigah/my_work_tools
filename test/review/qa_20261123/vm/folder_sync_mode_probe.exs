defmodule MWTClient.QAProbes.VM.FolderSyncModeProbeTest do
  # QA probe: a chmod made while the VM was stopped (or MWT restarted)
  # never reaches the VM's copy, since a whole comparison looks only at
  # kind, size and mtime, and the change-time stamps live in memory only.
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{FolderSync, Guest, ShareMounts}

  @old {{2020, 1, 1}, {0, 0, 0}}

  setup do
    root = Path.join(System.tmp_dir!(), "qa-fsync-#{System.unique_integer([:positive])}")
    share = Path.join(root, "host/scripts")
    vm = Path.join(root, "vm")
    data = Path.join(root, "data")
    File.mkdir_p!(share)
    File.mkdir_p!(vm)
    on_exit(fn -> File.rm_rf!(root) end)

    %{share: share, guest: Guest.local(vm), copy: vm <> ShareMounts.store(share), data: data}
  end

  defp sync(context, record) do
    record =
      FolderSync.sync(record, context.guest, context.data, now: System.os_time(:second) + 10)

    assert record.status.error == nil
    record
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "chmod +x while the VM is stopped never reaches the copy", context do
    script = Path.join(context.share, "deploy.sh")
    File.write!(script, "#!/bin/sh\necho hi\n")
    File.chmod!(script, 0o644)
    File.touch!(script, @old)

    # The VM runs: first sync.
    first = sync(context, FolderSync.new(context.share, "vm-1"))
    assert mode(Path.join(context.copy, "deploy.sh")) == 0o644

    # Within one running MWT and VM, a chmod is caught (ctime moved).
    File.chmod!(script, 0o755)
    second = sync(context, first)
    assert mode(Path.join(context.copy, "deploy.sh")) == 0o755

    # Now the same while the VM was stopped: chmod -x, then the next start
    # syncs with a new record (ShareSync.reset/1), compared whole.
    File.chmod!(script, 0o644)
    _ = second
    third = sync(context, FolderSync.new(context.share, "vm-1"))

    IO.puts(
      "\nPROBE: host mode #{Integer.to_string(mode(script), 8)}, VM copy mode " <>
        Integer.to_string(mode(Path.join(context.copy, "deploy.sh")), 8) <>
        ", sent #{third.status.sent}"
    )

    # And a later sync of the same run doesn't catch it either.
    fourth = sync(context, third)
    assert fourth.status.sent == 0
    assert mode(Path.join(context.copy, "deploy.sh")) == 0o755
    assert mode(script) == 0o644
  end
end
