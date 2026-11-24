defmodule MWTClientWeb.SandboxHostRulesLiveTest do
  @moduledoc """
  A network's host limits on its page, the Internet's included
  (`MWTClient.Sandbox.HostLimits`): what a host on neither list gets, and
  the Blocked and Reachable lists, each host added, moved and taken off.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.HostLimits

  setup %{conn: conn} do
    %{conn: conn, username: username} = sign_in(conn, "host-rules-live")
    %{conn: conn, username: username}
  end

  defp limits(username, id \\ "internet"),
    do: Enum.find(Sandbox.snapshot(username).networks, &(&1.id == id)).limits

  test "the Internet's page blocks a host, moves it to Reachable, and takes it off", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/resources/network/internet")
    assert has_element?(view, "#limits-blocked-empty")

    view
    |> form("#limits-blocked-form", limit: %{host: "Paste.example.com"})
    |> render_submit()

    assert HostLimits.lists(limits(username)) == {["paste.example.com"], []}
    assert HostLimits.blocked?(limits(username), "api.paste.example.com")
    assert has_element?(view, "#limits-blocked-paste-example-com")

    view |> element("#limits-blocked-paste-example-com-move") |> render_click()
    assert HostLimits.lists(limits(username)) == {[], ["paste.example.com"]}
    assert has_element?(view, "#limits-reachable-paste-example-com")

    view |> element("#limits-reachable-paste-example-com-remove") |> render_click()
    assert HostLimits.lists(limits(username)) == {[], []}
    assert has_element?(view, "#limits-reachable-empty")
  end

  test "blocked by default, a network reaches only the hosts listed as reachable", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/resources/network/internet")

    view |> element("#limits-default--blocked") |> render_click()

    view
    |> form("#limits-reachable-form", limit: %{host: "github.com"})
    |> render_submit()

    assert HostLimits.blocked?(limits(username), "pypi.org")
    refute HostLimits.blocked?(limits(username), "api.github.com")
    assert has_element?(view, "#resource-limits", "the VM reaches only the hosts listed")
  end

  test "an address isn't a host, and says so", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/resources/network/internet")

    view
    |> form("#limits-blocked-form", limit: %{host: "10.0.0.5"})
    |> render_submit()

    assert render(view) =~ "is an address"
    assert HostLimits.lists(limits(username)) == {[], []}
  end

  test "only a network has host limits", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/resources/machine")
    assert has_element?(view, "#resource-page-machine")
    refute has_element?(view, "#resource-limits")
  end
end
