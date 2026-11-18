defmodule MWTClientWeb.VersionsLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Flashcards.Library, as: Flashcards
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note

  @vm {:agent, :vm, %{agent: "claude", thread: nil}}

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "a note's versions show who replaced them, what restoring changes, and restore", %{
    conn: conn,
    username: username
  } do
    {:ok, note} = Notes.save(username, Note.new_id(), %{title: "Plan", body: "mine\nkept"})
    {:ok, _} = Notes.update(username, note.id, %{body: "the agent's\nkept"}, by: @vm)

    {:ok, view, _html} = live(conn, ~p"/tools/notes?id=#{note.id}")
    refute has_element?(view, "#note-versions")

    view |> element("#note-versions-button") |> render_click()
    assert has_element?(view, "#note-versions-1", "Before claude in the VM changed it")

    view |> element("#note-versions-1") |> render_click()
    assert has_element?(view, "#note-versions-diff", "- the agent's")
    assert has_element?(view, "#note-versions-diff", "+ mine")

    view |> element("#note-versions-restore") |> render_click()
    assert {:ok, %{body: "mine\nkept", version: 3}} = Notes.get(username, note.id)
    assert has_element?(view, "#note-versions-2", "Before you restored an earlier one")

    view |> element("#note-versions-close") |> render_click()
    refute has_element?(view, "#note-versions")
  end

  test "a note with no earlier versions says when they are kept", %{
    conn: conn,
    username: username
  } do
    {:ok, note} = Notes.save(username, Note.new_id(), %{body: "new"})
    {:ok, view, _html} = live(conn, ~p"/tools/notes?id=#{note.id}")

    view |> element("#note-versions-button") |> render_click()
    assert has_element?(view, "#note-versions-empty")
  end

  test "an agent's change to the note open shows up in its versions", %{
    conn: conn,
    username: username
  } do
    {:ok, note} = Notes.save(username, Note.new_id(), %{body: "mine"})
    {:ok, view, _html} = live(conn, ~p"/tools/notes?id=#{note.id}")
    view |> element("#note-versions-button") |> render_click()

    {:ok, _} = Notes.update(username, note.id, %{body: "theirs"}, by: {:agent, :local})

    assert render(view) =~ "Before an agent on this machine changed it"
  end

  test "a diagram's versions count what restoring changes, and restore it", %{
    conn: conn,
    username: username
  } do
    {:ok, diagram} =
      Diagrams.save(username, Diagram.new_id(), %{title: "Flow", elements: [box("a")]})

    {:ok, _} =
      Diagrams.update(username, diagram.id, %{elements: [box("a", 50), box("b")]}, by: @vm)

    {:ok, view, _html} = live(conn, ~p"/tools/diagrams?id=#{diagram.id}")
    view |> element("#diagram-versions-button") |> render_click()
    view |> element("#diagram-versions-1") |> render_click()

    assert has_element?(view, "#diagram-versions-diff", "1 element removed, 1 element moved")

    view |> element("#diagram-versions-restore") |> render_click()
    assert {:ok, %{elements: [%{"id" => "a", "x" => 0}]}} = Diagrams.get(username, diagram.id)
    assert_push_event(view, "diagram:load", %{elements: [%{"id" => "a"}]})
  end

  test "a card's versions show the fields restoring changes, and restore it", %{
    conn: conn,
    username: username
  } do
    {:ok, [{:created, card}]} = Flashcards.create(username, [%{front: "Why?", back: "Because."}])
    {:ok, _} = Flashcards.update(username, card.id, %{back: "No idea."}, by: @vm)

    {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards?id=#{card.id}")
    view |> element("#card-versions-button") |> render_click()
    view |> element("#card-versions-1") |> render_click()

    assert has_element?(view, "#card-versions-diff", "No idea.")
    assert has_element?(view, "#card-versions-diff", "Because.")

    view |> element("#card-versions-restore") |> render_click()
    assert {:ok, %{back: "Because."}} = Flashcards.get(username, card.id)
  end

  defp box(id, x \\ 0),
    do: %{
      "id" => id,
      "type" => "rectangle",
      "x" => x,
      "y" => 0,
      "width" => 10,
      "height" => 10
    }
end
