defmodule MWTClientWeb.SandboxWayOfWorkingLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Instructions

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "your way of working: empty until written, then in what agents are told", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    block = Path.join(Sandbox.snapshot(username).inbox, "agents-block.md")

    assert has_element?(view, "#way-of-working-text")
    refute render(element(view, "#way-of-working-text")) =~ "Building blocks"
    assert File.read!(block) == Instructions.block()

    # The example fills the field only, also as an event for the field itself,
    # which reaches it over typing the server never saw.
    example = Instructions.way_of_working_example()
    view |> element("#way-of-working-example") |> render_click()

    assert render(element(view, "#way-of-working-text")) =~
             "A component per job the operation needs, named for that job."

    assert_push_event(view, "way_of_working_fill", %{text: ^example})
    assert Sandbox.snapshot(username).settings.way_of_working == ""

    # Again, with the field already holding it on the server's side.
    view |> element("#way-of-working-example") |> render_click()
    assert_push_event(view, "way_of_working_fill", %{text: ^example})

    view
    |> form("#way-of-working-form", way: %{text: "Keep answers short.\r\n"})
    |> render_submit()

    assert has_element?(view, "#notices", "Your way of working is saved")
    assert Sandbox.snapshot(username).settings.way_of_working == "Keep answers short."
    assert File.read!(block) == Instructions.block(way_of_working: "Keep answers short.")

    view |> form("#way-of-working-form", way: %{text: ""}) |> render_submit()

    assert has_element?(view, "#notices", "Your way of working is cleared")
    assert File.read!(block) == Instructions.block()
  end

  test "a text too long to read in every session is refused, and kept in the field", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    long = String.duplicate("a", 20_001)

    view |> form("#way-of-working-form", way: %{text: long}) |> render_submit()

    assert has_element?(view, "#way-of-working-error", "under 20,000 characters")
    assert render(element(view, "#way-of-working-text")) =~ long
    assert Sandbox.snapshot(username).settings.way_of_working == ""

    # The refusal was of that text: the example in its place clears it.
    view |> element("#way-of-working-example") |> render_click()
    refute has_element?(view, "#way-of-working-error")
  end
end
