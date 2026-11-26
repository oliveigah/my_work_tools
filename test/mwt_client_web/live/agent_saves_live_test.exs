defmodule MWTClientWeb.AgentSavesLiveTest do
  # What agents in the VM save through MWT's tools, as the open pages show it.
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MWTClient.ToolCallers, only: [allowed: 1]
  alias MWTClient.MCP.Tools

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "malformed HTTP item links keep the editor usable", %{conn: conn} do
    for path <- ["/tools/http?id=123abc", "/tools/http?id=-1", "/tools/http?id[]=1"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#request-form")
    end
  end

  test "agent saves appear in open pages and direct links open the saved item", %{
    conn: conn,
    username: username
  } do
    {:ok, notes_view, _html} = live(conn, ~p"/tools/notes")
    note = create("create_note", %{"title" => "Agent note", "body" => "# Hello"}, username)
    assert has_element?(notes_view, "#note-#{note.id}")
    {:ok, note_link, _html} = live(conn, note.path)
    assert has_element?(note_link, "#note-body-#{note.id}")

    {:ok, diagram_view, _html} = live(conn, ~p"/tools/diagrams")
    diagram = create("create_diagram", %{"title" => "Agent diagram", "elements" => []}, username)
    assert has_element?(diagram_view, "#diagram-#{diagram.id}")
    create("create_diagram", %{"title" => "Newer diagram", "elements" => []}, username)
    {:ok, diagram_link, _html} = live(conn, diagram.path)
    assert has_element?(diagram_link, "#diagram-title[value='Agent diagram']")

    {:ok, http_view, _html} = live(conn, ~p"/tools/http")

    request =
      create(
        "create_http_request",
        %{"url" => "https://example.test/sample", "description" => "Agent sample"},
        username
      )

    assert has_element?(http_view, "#history-#{request.id}", "Saved sample")
    {:ok, request_link, _html} = live(conn, request.path)
    render_async(request_link)
    assert has_element?(request_link, "#request-url[value='https://example.test/sample']")
  end

  test "agent updates refresh the selected note and diagram in open pages", %{
    conn: conn,
    username: username
  } do
    note = create("create_note", %{"title" => "Agent note", "body" => "Old body"}, username)
    {:ok, notes_view, _html} = live(conn, note.path)

    create(
      "update_note",
      %{"id" => note.id, "version" => 1, "title" => "Updated note", "body" => "# Updated body"},
      username
    )

    assert has_element?(notes_view, "#note-#{note.id}", "Updated note")
    assert has_element?(notes_view, "#note-title-#{note.id}[value='Updated note']")
    assert has_element?(notes_view, "#note-body-#{note.id}", "# Updated body")
    assert has_element?(notes_view, "#note-preview h1", "Updated body")

    diagram = create("create_diagram", %{"title" => "Agent diagram", "elements" => []}, username)
    {:ok, diagrams_view, _html} = live(conn, diagram.path)
    id = diagram.id

    elements = [
      %{
        "id" => "updated",
        "type" => "rectangle",
        "x" => 20,
        "y" => 40,
        "width" => 180,
        "height" => 80,
        "text" => "Updated shape"
      }
    ]

    create(
      "update_diagram",
      %{"id" => id, "version" => 1, "title" => "Updated diagram", "elements" => elements},
      username
    )

    assert has_element?(diagrams_view, "#diagram-#{id}", "Updated diagram")
    assert has_element?(diagrams_view, "#diagram-title[value='Updated diagram']")

    assert_push_event(diagrams_view, "diagram:load", %{
      id: ^id,
      elements: [%{"id" => "updated", "text" => "Updated shape"}]
    })
  end

  defp create(name, args, username) do
    {:ok, result} = Tools.call(name, args, allowed(username))
    refute result["isError"]
    result["structuredContent"]
  end
end
