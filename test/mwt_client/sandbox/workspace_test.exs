defmodule MWTClient.Sandbox.WorkspaceTest do
  use ExUnit.Case, async: true

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.{Guest, Workspace}

  doctest Workspace

  # An identity's home folder of its own (`MWTClient.StandIns`), where the
  # workspace goes.
  setup do
    context = MWTClient.VaultHelpers.unlocked_identity("workspace")
    home = Workspace.home(context.username)
    Map.put(context, :home, home)
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "made at ~/mwt-vm with both halves, its marker, and the VM's half read-only", context do
    root = Path.join(context.home, "mwt-vm")
    assert Workspace.locate(context.username) == :none

    assert {:ok, ^root} = Workspace.ensure(context.username)
    assert File.dir?(Workspace.to_vm(root))
    assert File.dir?(Workspace.from_vm(root))
    assert mode(Workspace.from_vm(root)) == 0o555
    assert File.read!(Workspace.marker(root)) == Accounts.id(context.username) <> "\n"
    assert File.regular?(Path.join(root, ".trackerignore"))

    # Found again as it is, and made again where a half went.
    assert {:ok, ^root} = Workspace.locate(context.username)
    File.rm_rf!(Workspace.to_vm(root))
    assert {:ok, ^root} = Workspace.ensure(context.username)
    assert File.dir?(Workspace.to_vm(root))
  end

  test "a folder MWT didn't make is never taken over", context do
    root = Path.join(context.home, "mwt-vm")
    File.mkdir_p!(Path.join(root, "mine"))
    File.write!(Path.join(root, "mine/notes.txt"), "mine\n")

    assert {:error, {:foreign, ^root}} = Workspace.ensure(context.username)
    assert {:error, {:foreign, ^root}} = Workspace.locate(context.username)
    assert File.ls!(root) == ["mine"]
    assert Workspace.explain({:foreign, root}) =~ "move it away"
  end

  test "a symlink at its path is never followed", context do
    root = Path.join(context.home, "mwt-vm")
    elsewhere = Path.join(context.home, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.ln_s!(elsewhere, root)

    assert {:error, {:foreign, ^root}} = Workspace.ensure(context.username)
    assert File.ls!(elsewhere) == []
  end

  test "another identity's workspace sends this one to ~/mwt-vm-<name>", context do
    taken = Path.join(context.home, "mwt-vm")
    File.mkdir_p!(taken)
    File.write!(Workspace.marker(taken), "another-identity\n")

    [_first, second] = Workspace.candidates(context.home, context.username)
    assert {:ok, ^second} = Workspace.ensure(context.username)
    assert File.read!(Workspace.marker(taken)) == "another-identity\n"
  end

  test "shown in a test's stand-in for the VM: the VM's half on its work disk", context do
    {:ok, root} = Workspace.ensure(context.username)
    vm = Path.join(context.home, "vm")
    File.mkdir_p!(vm)

    assert :ok = Workspace.arrange(Guest.local(vm), root)
    File.write!(Path.join(vm <> Workspace.from_vm(root), "out.txt"), "from the VM\n")
    assert File.read!(Path.join(vm <> Workspace.vm_store(), "out.txt")) == "from the VM\n"

    # Again, it changes nothing.
    assert :ok = Workspace.arrange(Guest.local(vm), root)
  end
end
