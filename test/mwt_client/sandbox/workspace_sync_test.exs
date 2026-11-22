defmodule MWTClient.Sandbox.WorkspaceSyncTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Server, Workspace}
  alias MWTClient.StandIns
  alias MWTClient.Vault.Store

  @value "ghp_real_value_0123456789"
  @shape "ghp_" <> String.duplicate("s", 36)

  # The workspace of an identity whose VM, a folder of this machine, runs.
  setup do
    context = MWTClient.VaultHelpers.unlocked_identity("workspace-sync")
    vm = Path.join(Workspace.home(context.username), "vm")
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

    assert {:ok, _} = wait(context.username, :all)
    root = Path.join(Workspace.home(context.username), "mwt-vm")
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", Workspace.home(context.username)]) end)

    Map.merge(context, %{
      vm: vm,
      pid: pid,
      root: root,
      to_vm: Workspace.to_vm(root),
      from_vm: Workspace.from_vm(root)
    })
  end

  defp wait(username, which),
    do: Server.call(username, {:sync_shares_wait, which}, 10_000)

  defp in_vm(context, path), do: context.vm <> path

  defp from_the_vm(context, name, bytes) do
    path = Path.join(context.vm <> Workspace.vm_store(), name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  # A file of yours in to-vm, old enough to be settled.
  defp for_the_vm(context, name, bytes) do
    path = Path.join(context.to_vm, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})
  end

  test "the first sync makes the workspace; each sync takes both halves", context do
    assert File.dir?(context.to_vm)
    assert {:ok, root} = Workspace.locate(context.username)
    assert root == context.root
    assert Sandbox.snapshot(context.username).workspace.root == context.root

    for_the_vm(context, "result.json", ~s({"ok":true}))
    from_the_vm(context, "entry.yaml", "key: value\n")

    assert {:ok, statuses} = wait(context.username, :all)
    assert File.read!(in_vm(context, Path.join(context.to_vm, "result.json"))) == ~s({"ok":true})
    assert File.read!(Path.join(context.from_vm, "entry.yaml")) == "key: value\n"
    assert %{written: 1, error: nil} = statuses[context.from_vm]

    view = Sandbox.snapshot(context.username).workspace
    assert view.from_vm.status.written == 1
    assert view.to_vm.status.synced_at

    # What it brought is in the workspace grant's activity.
    assert Enum.any?(
             Sandbox.events(context.username),
             &(&1.grant_id == "workspace" and &1.summary =~ "from-vm copied onto your machine")
           )
  end

  test "the VM's shells and mwt host name it", context do
    profile = Path.join(:sys.get_state(context.pid).dir, "inbox/profile.sh")
    assert File.read!(profile) =~ "export MWT_WORKSPACE='#{context.root}'"

    {0, text} = Channel.answer("host", %{}, context.username)
    assert text =~ "## The workspace"
    assert text =~ context.from_vm
  end

  test "off, nothing of from-vm comes; to-vm still goes", context do
    {:ok, _} = Sandbox.turn_off(context.username, "workspace")
    from_the_vm(context, "entry.yaml", "key: value\n")
    for_the_vm(context, "result.json", "{}")

    assert {:ok, statuses} = wait(context.username, :all)
    assert statuses[context.from_vm].error =~ "Workspace: write to your machine is off"
    refute File.exists?(Path.join(context.from_vm, "entry.yaml"))
    assert File.read!(in_vm(context, Path.join(context.to_vm, "result.json"))) == "{}"
    refute Sandbox.snapshot(context.username).workspace.on?
  end

  test "isolated, nothing of from-vm comes", context do
    :ok = Sandbox.firewall_isolate(context.username)
    from_the_vm(context, "entry.yaml", "key: value\n")

    assert {:ok, statuses} = wait(context.username, :all)
    assert statuses[context.from_vm].error =~ "isolated"
    refute File.exists?(Path.join(context.from_vm, "entry.yaml"))
  end

  test "a real value in from-vm lands nothing, and the firewall hears", context do
    {:ok, _grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "source" => "stored",
        "value" => @value
      })

    from_the_vm(context, "fine.txt", "fine")
    from_the_vm(context, "leak.txt", "the token: #{@value}\n")

    assert {:ok, statuses} = wait(context.username, :all)
    assert statuses[context.from_vm].error =~ "leak.txt holds GitHub's real value"
    assert File.ls!(context.from_vm) == []
    assert %{rule: :real_value} = Sandbox.firewall(context.username).firewall.isolated
    refute Enum.any?(Sandbox.events(context.username), &(inspect(&1) =~ @value))
  end

  test "a file of to-vm shaped like a credential is held back, until you let it go", context do
    for_the_vm(context, "token.txt", "key=#{@shape}\n")
    for_the_vm(context, "fine.txt", "fine")
    shown = in_vm(context, Path.join(context.to_vm, "token.txt"))

    assert {:ok, statuses} = wait(context.username, :all)
    assert [%{path: "token.txt", why: why}] = statuses[context.to_vm].held
    assert why =~ "a GitHub token, line 1"
    refute File.exists?(shown)
    assert File.exists?(in_vm(context, Path.join(context.to_vm, "fine.txt")))

    # Held again at the next sync, then let go as it is.
    assert {:ok, statuses} = wait(context.username, [context.to_vm])
    assert [%{path: "token.txt"}] = statuses[context.to_vm].held

    assert :ok = Sandbox.release_held(context.username, "token.txt")
    assert {:ok, statuses} = wait(context.username, [context.to_vm])
    assert statuses[context.to_vm].held == []
    assert File.read!(shown) == "key=#{@shape}\n"
  end

  describe "mwt sync" do
    test "a path in a half syncs that half", context do
      from_the_vm(context, "entry.yaml", "x")

      ask = %{"path" => Path.join(context.from_vm, "entry.yaml")}
      assert {0, text} = Channel.answer("sync", ask, context.username)

      assert text ==
               "#{context.from_vm}: copied onto the user's machine, 1 written; 1 files there, read-only there."

      for_the_vm(context, "result.json", "{}")
      assert {0, text} = Channel.answer("sync", %{"path" => context.to_vm}, context.username)
      assert text =~ ~r"^#{context.to_vm}: up to date, \d+ sent"
    end

    test "with the workspace grant off, the rest still syncs, and it says why", context do
      {:ok, _} = Sandbox.turn_off(context.username, "workspace")
      for_the_vm(context, "result.json", "{}")

      assert {1, text} = Channel.answer("sync", %{}, context.username)
      assert text =~ "#{context.to_vm}: up to date"
      assert text =~ "#{context.from_vm}: not copied. Workspace: write to your machine is off"

      assert {1, text} = Channel.answer("sync", %{"path" => context.from_vm}, context.username)
      assert text =~ "Workspace: write to your machine is off"
    end
  end
end
