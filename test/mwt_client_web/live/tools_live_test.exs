defmodule MWTClientWeb.ToolsLiveTest do
  # Exercises the application-wide updater and remembered Git session.
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.VaultHelpers
  alias MWTClient.Updates

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    sign_in(conn)
  end

  test "lists every tool", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-http")
    assert has_element?(view, "#tool-git")
  end

  test "the agent sandbox leads, across the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tools > #tool-sandbox:first-child[data-featured]")
    refute has_element?(view, "#tool-sandbox-waiting")
  end

  test "the title bar offers the theme toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "[data-phx-theme=system]")
    assert has_element?(view, "[data-phx-theme=light]")
    assert has_element?(view, "[data-phx-theme=dark]")
  end

  test "offers to install a newer package once one is picked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#check-updates")
    assert has_element?(view, "#update-from-file[phx-hook]")
    refute has_element?(view, "#update-notice")

    send(
      view.pid,
      {:mwt_update,
       %{status: :ready, package: %{version: "0.7.0", file: "MWT_0.7.0.rpm"}, message: nil}}
    )

    assert has_element?(view, "#update-notice", "Install MWT 0.7.0?")
    assert has_element?(view, "#update-package", "MWT_0.7.0.rpm")
    assert has_element?(view, "#install-update", "Install")
    assert has_element?(view, "#dismiss-update")

    send(
      view.pid,
      {:mwt_update,
       %{status: :installing, package: %{version: "0.7.0", file: "MWT_0.7.0.rpm"}, message: nil}}
    )

    assert has_element?(view, "#update-notice")
    refute has_element?(view, "#install-update")
    assert has_element?(view, "#update-from-file[disabled]")
    assert has_element?(view, "#check-updates[disabled]")
  end

  test "offers a newer release found, and says while it downloads and checks it",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    send(
      view.pid,
      {:mwt_update, %{status: :checking, package: nil, release: nil, message: nil}}
    )

    assert has_element?(view, "#update-notice", "Checking for updates")
    assert has_element?(view, "#check-updates[disabled]")

    send(
      view.pid,
      {:mwt_update,
       %{status: :available, package: nil, release: %{version: "0.8.0"}, message: nil}}
    )

    assert has_element?(view, "#update-notice", "MWT 0.8.0 is available")
    assert has_element?(view, "#install-update", "Install")
    assert has_element?(view, "#dismiss-update")

    send(
      view.pid,
      {:mwt_update,
       %{status: :downloading, package: nil, release: %{version: "0.8.0"}, message: nil}}
    )

    assert has_element?(view, "#update-notice", "Downloading MWT 0.8.0")
    refute has_element?(view, "#install-update")
    refute has_element?(view, "#dismiss-update")

    send(
      view.pid,
      {:mwt_update,
       %{status: :current, package: nil, release: nil, message: "MWT 0.8.0 is the latest."}}
    )

    assert has_element?(view, "#update-notice", "MWT is up to date")
    assert has_element?(view, "#update-current", "MWT 0.8.0 is the latest.")
    refute has_element?(view, "#update-error")
  end

  test "outside the installed app, checking for updates says why it can't",
       %{conn: conn} do
    on_exit(fn -> Updates.dismiss() end)
    {:ok, view, _html} = live(conn, ~p"/tools")

    view |> element("#check-updates") |> render_click()

    assert has_element?(view, "#update-error", "only in the installed desktop app")

    view |> element("#dismiss-update") |> render_click()
    refute has_element?(view, "#update-notice")
  end

  test "outside the installed app, the picker stays shut and the notice says why",
       %{conn: conn} do
    on_exit(fn -> Updates.dismiss() end)
    {:ok, view, _html} = live(conn, ~p"/tools")

    view |> element("#update-from-file") |> render_hook("pick_update", %{})

    # No package type in the reply: the hook opens no picker.
    assert_reply(view, reply)
    assert reply == %{}
    assert has_element?(view, "#update-error", "only in the installed desktop app")

    view |> element("#dismiss-update") |> render_click()
    refute has_element?(view, "#update-notice")
  end

  test "a path without a picker first reads nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    view
    |> element("#update-from-file")
    |> render_hook("select_update", %{"path" => "/etc/hostname"})

    assert %{status: :idle} = Updates.current()
    refute has_element?(view, "#update-notice")
  end

  test "the title bar names every tool and marks the one open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    assert has_element?(view, "#tool-switch-http", "HTTP Client")
    assert has_element?(view, "#tool-switch-git", "Git GUI")
    refute has_element?(view, "#tool-switcher [aria-current]")

    {:ok, git_view, _html} = live(conn, ~p"/tools/git")

    assert has_element?(git_view, "#tool-switch-git[aria-current=page]")
    refute has_element?(git_view, "#tool-switch-http[aria-current]")
  end

  test "opens the HTTP client", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    {:ok, tool_view, _html} =
      view
      |> element("#tool-http")
      |> render_click()
      |> follow_redirect(conn, ~p"/tools/http")

    assert has_element?(tool_view, "#request-form")
  end

  test "the picker is unreachable while locked" do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), ~p"/tools")
  end
end
