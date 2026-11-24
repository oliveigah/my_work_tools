defmodule MWTClientWeb.PlacesLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Places

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "the tool switcher goes back to the page each tool was left on", %{conn: conn} do
    {:ok, sandbox, _html} = live(conn, ~p"/tools/sandbox/grants")
    # The tool open goes to its first page.
    assert has_element?(sandbox, ~s(#tool-switch-sandbox[href="/tools/sandbox"]))

    {:ok, flashcards, _html} = live(conn, ~p"/tools/flashcards/settings")
    assert has_element?(flashcards, ~s(#tool-switch-sandbox[href="/tools/sandbox/grants"]))
    # A tool never opened goes to its first page.
    assert has_element?(flashcards, ~s(#tool-switch-notes[href="/tools/notes"]))

    {:ok, tools, _html} = live(conn, ~p"/tools")
    assert has_element?(tools, ~s(#tool-switch-flashcards[href="/tools/flashcards/settings"]))
    assert has_element?(tools, ~s(#tool-flashcards[href="/tools/flashcards/settings"]))
    assert has_element?(tools, ~s(#tool-sandbox[href="/tools/sandbox/grants"]))
  end

  test "a page with its query comes back whole", %{conn: conn, username: username} do
    {:ok, _view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=network")

    assert Places.paths(username)[:sandbox] == "/tools/sandbox/settings?tab=network"
  end

  test "pages that aren't tools aren't remembered", %{conn: conn, username: username} do
    {:ok, _view, _html} = live(conn, ~p"/storage")
    {:ok, _view, _html} = live(conn, ~p"/tools")

    assert Places.paths(username) == %{}
  end

  test "the sandbox keeps its filters and searches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=all")
    view |> element("#grant-search") |> render_change(%{"term" => "github"})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=all")
    assert has_element?(view, ~s(#grant-search-term[value="github"]))
    assert has_element?(view, "#clear-grant-search")
  end

  test "the grants enabled on startup stay open once opened", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")
    refute has_element?(view, "#enabled-startup-list")
    view |> element("#enabled-startup-toggle") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")
    assert has_element?(view, "#enabled-startup-list")
  end
end
