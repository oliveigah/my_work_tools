defmodule MWTClient.QAProbes.VM.CopyBackHardlinkProbeTest do
  # QA probe: two names of one file in from-vm (a hard link) pass the list
  # check, but the VM's tar sends the second as a link entry, which the
  # reader refuses: nothing of from-vm comes, for a reason that names no
  # file and no rule.
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{CopyBack, Guest, Workspace}

  setup do
    base = Path.join(System.tmp_dir!(), "qa-copy-back-#{System.unique_integer([:positive])}")
    root = Path.join(base, "home/mwt-vm")
    vm = Path.join(base, "vm")
    File.mkdir_p!(Workspace.from_vm(root))
    File.chmod!(Workspace.from_vm(root), 0o555)
    File.mkdir_p!(vm <> Workspace.vm_store())

    on_exit(fn ->
      System.cmd("chmod", ["-R", "u+w", base])
      File.rm_rf!(base)
    end)

    %{
      root: root,
      here: Workspace.from_vm(root),
      store: vm <> Workspace.vm_store(),
      guest: Guest.local(vm),
      dir: Path.join(base, "data")
    }
  end

  test "a hard link in from-vm lands nothing", context do
    File.write!(Path.join(context.store, "report.pdf"), "%PDF-1.7 report\n")
    File.write!(Path.join(context.store, "notes.md"), "notes\n")
    File.ln!(Path.join(context.store, "report.pdf"), Path.join(context.store, "report-final.pdf"))

    assert :ok =
             CopyBack.check(%{
               "report.pdf" => {:file, 16, 0},
               "report-final.pdf" => {:file, 16, 0}
             })

    {record, nil} =
      CopyBack.run(CopyBack.new("vm-test"), context.guest, context.root, dir: context.dir)

    IO.puts(
      "\nPROBE: error = #{inspect(record.status.error)}; here = #{inspect(File.ls!(context.here))}"
    )

    assert record.status.error =~ "never asks for"
    assert File.ls!(context.here) == []
  end
end
