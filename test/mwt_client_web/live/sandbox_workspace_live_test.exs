defmodule MWTClientWeb.SandboxWorkspaceLiveTest do
  @moduledoc """
  The workspace on the Overview: where it is, each half's last sync, a
  file of yours held back from the VM, and its buttons.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Guest, Server, Workspace}

  @shape "ghp_" <> String.duplicate("s", 36)

  setup %{conn: conn} do
    context = sign_in(conn)
    vm = Path.join(Workspace.home(context.username), "vm")
    File.mkdir_p!(vm)
    MWTClient.StandIns.put_guest(context.username, Guest.local(vm))
    server = MWTClient.Vault.Store.whereis(Server, context.username)

    :sys.replace_state(server, fn state ->
      %{
        state
        | vm: %{state.vm | status: :running, exists?: true, started_at: DateTime.utc_now()},
          vm_record: %{id: "vm-ui", copied: true, created_at: nil}
      }
    end)

    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", Workspace.home(context.username)]) end)
    Map.merge(context, %{vm: vm, root: Path.join(Workspace.home(context.username), "mwt-vm")})
  end

  defp wait(username), do: Server.call(username, {:sync_shares_wait, :all}, 10_000)

  test "before the first sync it says when it is made; then where it is, and each half",
       %{conn: conn, username: username, root: root} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-empty", "Made at the first sync")

    {:ok, _} = wait(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-root", root)
    assert has_element?(view, "#overview-workspace-to-vm-state", "Synced just now")
    assert has_element?(view, "#overview-workspace-from-vm-state", "Synced just now")
    assert view |> element("#overview-workspace-open") |> render_click()
  end

  test "Sync takes both halves", %{conn: conn, username: username, root: root, vm: vm} do
    {:ok, _} = wait(username)
    File.write!(Path.join(vm <> Workspace.vm_store(), "report.md"), "# Report\n")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    view |> element("#overview-workspace-sync") |> render_click()
    {:ok, _} = Server.call(username, {:sync_shares_wait, []}, 10_000)

    assert File.read!(Path.join(Workspace.from_vm(root), "report.md")) == "# Report\n"
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-from-vm-state", "1 copied here")
  end

  test "a file held back is named, and goes once you send it",
       %{conn: conn, username: username, root: root, vm: vm} do
    {:ok, _} = wait(username)
    file = Path.join(Workspace.to_vm(root), "token.txt")
    File.write!(file, "key=#{@shape}\n")
    File.touch!(file, {{2020, 1, 1}, {0, 0, 0}})
    {:ok, _} = wait(username)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-held-0", "token.txt")
    assert has_element?(view, "#overview-workspace-held-0", "a GitHub token")
    refute File.exists?(vm <> file)

    view |> element("#overview-workspace-release-0") |> render_click()
    {:ok, _} = Server.call(username, {:sync_shares_wait, []}, 10_000)
    assert File.read!(vm <> file) == "key=#{@shape}\n"
  end

  test "off, it says nothing of the VM comes", %{conn: conn, username: username} do
    {:ok, _} = wait(username)
    {:ok, _} = Sandbox.turn_off(username, "workspace")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-from-vm-state", "nothing comes here")
  end

  test "a folder MWT didn't make is named, and left alone", %{
    conn: conn,
    username: username,
    root: root
  } do
    File.mkdir_p!(Path.join(root, "mine"))
    {:ok, _} = wait(username)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-workspace-error", "move it away")
    refute has_element?(view, "#overview-workspace-sync")
    assert File.ls!(root) == ["mine"]
  end
end
