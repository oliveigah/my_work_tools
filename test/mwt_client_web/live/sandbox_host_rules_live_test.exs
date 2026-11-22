defmodule MWTClientWeb.SandboxHostRulesLiveTest do
  @moduledoc """
  A network grant's host list on its page, the Internet's included: an
  entry added with what it does, changed, and taken off.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox

  setup %{conn: conn} do
    %{conn: conn, username: username} = sign_in(conn, "host-rules-live")
    %{conn: conn, username: username}
  end

  defp rules(username),
    do: Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "internet")).host_rules

  test "the Internet's page adds, changes and takes off a host", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/internet")
    assert has_element?(view, "#grant-host-rules-empty")

    view
    |> form("#grant-host-rule-form", host_rule: %{host: "Paste.example.com", action: "block"})
    |> render_submit()

    assert rules(username) == [%{host: "paste.example.com", action: :block}]
    assert has_element?(view, "#host-rule-paste-example-com")

    view
    |> element("#host-rule-paste-example-com-action-ask")
    |> render_click()

    assert rules(username) == [%{host: "paste.example.com", action: :ask}]

    view |> element("#host-rule-paste-example-com-remove") |> render_click()
    assert rules(username) == []
    assert has_element?(view, "#grant-host-rules-empty")
  end

  test "an address isn't a host, and says so", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/internet")

    html =
      view
      |> form("#grant-host-rule-form", host_rule: %{host: "10.0.0.5", action: "ask"})
      |> render_submit()

    assert html =~ "is an address"
    assert rules(username) == []
  end

  test "a grant that isn't a network grant has no host list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/commands")
    refute has_element?(view, "#grant-host-rules")
  end
end
