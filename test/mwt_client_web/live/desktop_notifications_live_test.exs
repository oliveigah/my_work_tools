defmodule MWTClientWeb.DesktopNotificationsLiveTest do
  @moduledoc """
  Notifications from the pages' side: a click on the desktop brings the
  window forward and opens the approval, which is ringed; the bell counts
  them; the notifications page lists them and turns the desktop on and off.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Notifications
  alias MWTClient.Notifications.Center
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp ask(username) do
    {:ok, approval} =
      Server.call(
        username,
        {:request_access, %{need: "Postgres on 10.0.0.5", reason: "migrate", agent: "claude"}}
      )

    approval
  end

  defp click(username, path, token) do
    Phoenix.PubSub.broadcast(
      MWTClient.PubSub,
      Notifications.topic(username),
      {:desktop_open, path, token}
    )
  end

  test "a click on any page brings the window forward with the token, then opens the approval",
       %{conn: conn, username: username} do
    approval = ask(username)
    path = "/tools/sandbox/approvals?focus=#{approval.id}"
    {:ok, view, _html} = live(conn, ~p"/tools/notes")

    click(username, path, "wayland-token-1")

    assert_push_event(view, "mwt:present-window", %{token: "wayland-token-1"})
    assert_redirect(view, path)
  end

  test "another identity's clicks don't move this one's pages", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/notes")
    click(username <> "-someone-else", "/tools/sandbox/approvals", nil)
    refute_push_event(view, "mwt:present-window", %{})
    assert has_element?(view, "#note-list")
  end

  test "the approval a notification opened is ringed and scrolled to; the others aren't", %{
    conn: conn,
    username: username
  } do
    first = ask(username)

    {:ok, other} =
      Server.call(username, {:request_access, %{need: "Redis", reason: "cache", agent: "codex"}})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals?focus=#{first.id}")

    assert has_element?(view, "#approval-#{first.id}.ring-2[phx-mounted]")
    refute has_element?(view, "#approval-#{other.id}.ring-2")
    refute has_element?(view, "#approval-#{other.id}[phx-mounted]")
  end

  test "the bell counts them on every page, and the page lists each, linking to it", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/notes")
    refute has_element?(view, "#notifications-count")

    approval = ask(username)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#notifications-count", "1")

    {:ok, page, _html} = live(conn, ~p"/notifications")
    assert has_element?(page, "#notification-0", "Claude asks for access you haven't set up")

    assert has_element?(
             page,
             ~s(#notification-0 a[href="/tools/sandbox/approvals?focus=#{approval.id}"])
           )

    :ok = Sandbox.decide(username, approval.id, :decline)
    _ = :sys.get_state(page.pid)
    assert has_element?(page, "#notifications-empty")
    refute has_element?(page, "#notifications-count")
  end

  test "the page turns the desktop and each kind on and off, and says why a test can't be sent here",
       %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/notifications")

    assert has_element?(view, "#notifications-desktop-switch[aria-checked=true]")
    # Tests run without a desktop.
    assert has_element?(view, "#notifications-status", "without a desktop")
    assert has_element?(view, "#notifications-test[disabled]")

    view |> element("#notifications-desktop-switch") |> render_click()
    assert has_element?(view, "#notifications-desktop-switch[aria-checked=false]")
    refute Notifications.settings(username).desktop
    assert has_element?(view, "#notifications-kind-switch-sandbox-handoffs[disabled]")

    view |> element("#notifications-desktop-switch") |> render_click()
    assert Notifications.settings(username).desktop

    view |> element("#notifications-kind-switch-sandbox-handoffs") |> render_click()
    assert has_element?(view, "#notifications-kind-switch-sandbox-handoffs[aria-checked=false]")
    refute Notifications.settings(username).kinds["sandbox.handoffs"]
    assert Notifications.settings(username).kinds["sandbox.approvals"]
  end

  test "a test notification opens the notifications page and goes with it", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/notifications")
    render_click(view, "test", %{})

    assert [%{notice: %{open: "/notifications", scope: ^username, desktop: true}}] =
             Enum.filter(Center.list(), &(&1.key == {username, :test}))

    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    _ = :sys.get_state(Center)
    assert Enum.filter(Center.list(), &(&1.key == {username, :test})) == []
  end
end
