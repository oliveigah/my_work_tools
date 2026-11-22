defmodule MWTClientWeb.SandboxHandoffsListLiveTest do
  # The list of the Handoffs page: its pages and its search. The records
  # are put in the sandbox as they are, with no git work behind them, since
  # the list only reads them; what a handoff shows and how it lands is in
  # sandbox_handoffs_live_test.exs.
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.{Handoff, Server}

  setup %{conn: conn}, do: sign_in(conn)

  # A handoff as the sandbox keeps it; the last one put is listed first.
  defp keep(username, id, fields \\ []) do
    handoff =
      struct!(
        %Handoff{
          id: id,
          title: "Task #{id}",
          agent: "claude",
          project: "app",
          repo: "/home/me/app",
          onto: "main",
          base_branch: "main",
          source: %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "task-#{id}"},
          head: String.duplicate("a", 40),
          opened_at: ~U[2026-11-20 10:00:00Z],
          body: "Done.",
          timeline: [%{at: ~U[2026-11-20 10:00:00Z], kind: :opened, text: "claude handed it off"}]
        },
        fields
      )

    :ok = Server.call(username, {:put_handoff, handoff, "put by the test"})
    handoff
  end

  defp shown(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#handoff-list > li[id^=handoff-row-]")
    |> Enum.map(fn row ->
      ["handoff-row-" <> id] = LazyHTML.attribute(row, "id")
      String.to_integer(id)
    end)
  end

  test "a long list shows a page at a time, the newest first", %{conn: conn, username: username} do
    for id <- 1..45, do: keep(username, id)
    for id <- 46..48, do: keep(username, id, status: :closed)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert shown(view) == Enum.to_list(45..26//-1)
    assert has_element?(view, "#handoffs-filter-open", "45 Waiting to land")
    assert has_element?(view, "#handoffs-pages-shown", "1–20 of 45")
    assert has_element?(view, "#handoffs-page-prev[disabled]")
    assert has_element?(view, "#handoffs-page-3")
    refute has_element?(view, "#handoffs-page-4")

    view |> element("#handoffs-page-next") |> render_click()
    assert shown(view) == Enum.to_list(25..6//-1)
    assert has_element?(view, "#handoffs-pages-shown", "21–40 of 45")
    assert has_element?(view, "#handoffs-page-2[aria-current=page]")

    view |> element("#handoffs-page-3") |> render_click()
    assert shown(view) == Enum.to_list(5..1//-1)
    assert has_element?(view, "#handoffs-pages-shown", "41–45 of 45")
    assert has_element?(view, "#handoffs-page-next[disabled]")

    # The other half starts from its first page, and one page needs no pager.
    view |> element("#handoffs-filter-closed") |> render_click()
    assert shown(view) == [48, 47, 46]
    refute has_element?(view, "#handoffs-pages")

    # A page asked for that isn't there shows the last there is.
    view |> element("#handoffs-filter-open") |> render_click()
    render_click(view, "handoffs_page", %{"page" => "9"})
    assert has_element?(view, "#handoffs-pages-shown", "41–45 of 45")
    render_click(view, "handoffs_page", %{"page" => "two"})
    assert has_element?(view, "#handoffs-pages-shown", "41–45 of 45")
  end

  test "a search finds handoffs holding every word typed, in both halves", %{
    conn: conn,
    username: username
  } do
    keep(username, 1, title: "Fix the login timeout", body: "Raised the session timeout.")

    keep(username, 2,
      title: "Speed up the suite",
      body: "First line.\nThe login tests now run async.",
      status: :closed
    )

    keep(username, 3,
      title: "Rework the proxy page",
      thread: "Proxy thread",
      timeline: [
        %{at: ~U[2026-11-20 10:00:00Z], kind: :opened, text: "claude handed it off"},
        %{
          at: ~U[2026-11-20 11:00:00Z],
          kind: :sent_back,
          text: "You sent it back",
          note: "Keep the login form as it is"
        }
      ],
      status: :sent_back
    )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert shown(view) == [3, 1]

    view |> form("#handoff-search", %{"term" => "LOGIN"}) |> render_change()
    assert shown(view) == [3, 1]
    assert has_element?(view, "#handoffs-filter-open", "2 Waiting to land")
    assert has_element?(view, "#handoffs-filter-closed", "1 Landed or closed")
    # The words around it where the row doesn't show them: in the history's
    # note; a match in the title alone needs none.
    assert has_element?(view, "#handoff-snippet-3 mark", "login")
    assert has_element?(view, "#handoff-snippet-3", "Keep the")
    refute has_element?(view, "#handoff-snippet-1")

    # Every word, wherever each is: one in the title, one in the notes.
    view |> form("#handoff-search", %{"term" => "login  session"}) |> render_change()
    assert shown(view) == [1]
    assert has_element?(view, "#handoff-snippet-1 mark", "session")
    assert has_element?(view, "#handoffs-filter-closed", "0 Landed or closed")

    # The other half keeps the search.
    view |> form("#handoff-search", %{"term" => "login async"}) |> render_change()
    assert shown(view) == []

    assert has_element?(
             view,
             "#handoffs-empty",
             "No handoff waiting to land mentions “login async”."
           )

    view |> element("#handoffs-filter-closed") |> render_click()
    assert shown(view) == [2]
    assert has_element?(view, "#handoff-snippet-2", "The login tests now run async.")

    view |> form("#handoff-search", %{"term" => "#3"}) |> render_change()
    assert has_element?(view, "#handoffs-empty", "No handoff landed or closed mentions “#3”.")

    view |> element("#handoff-search-clear") |> render_click()
    assert shown(view) == [2]
    refute has_element?(view, "#handoff-search-clear")
  end

  test "a new search starts from its first page", %{conn: conn, username: username} do
    for id <- 1..30, do: keep(username, id, body: if(rem(id, 2) == 0, do: "even", else: "odd"))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    view |> element("#handoffs-page-2") |> render_click()
    assert has_element?(view, "#handoffs-pages-shown", "21–30 of 30")

    view |> form("#handoff-search", %{"term" => "even"}) |> render_change()
    assert shown(view) == Enum.to_list(30..2//-2)
    refute has_element?(view, "#handoffs-pages")
  end

  test "back from a handoff is where the list was left", %{conn: conn, username: username} do
    for id <- 1..25, do: keep(username, id, status: :closed, body: "landed work")
    keep(username, 26)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?filter=closed")
    view |> form("#handoff-search", %{"term" => "landed"}) |> render_change()
    view |> element("#handoffs-page-2") |> render_click()
    assert shown(view) == Enum.to_list(5..1//-1)

    view |> element("#handoff-row-3 a") |> render_click()
    assert_patch(view, ~p"/tools/sandbox/handoffs?id=3")
    assert has_element?(view, "#handoff-title", "Task 3")

    view |> element("#handoff-back") |> render_click()
    assert_patch(view, ~p"/tools/sandbox/handoffs?filter=closed")
    assert shown(view) == Enum.to_list(5..1//-1)
    assert has_element?(view, "#handoff-search-term[value=landed]")
  end

  test "the archived show only when included, then between the days asked", %{
    conn: conn,
    username: username
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ago = &DateTime.add(now, -&1, :day)
    day = &(&1 |> ago.() |> DateTime.to_date() |> Date.to_iso8601())

    keep(username, 1, status: :accepted, updated_at: ago.(120), body: "the old pool")
    keep(username, 2, status: :closed, updated_at: ago.(45), body: "the old pool")
    keep(username, 3, status: :accepted, updated_at: ago.(5), body: "the new pool")
    # Waiting since long ago: never archived.
    keep(username, 4, opened_at: ago.(200))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?filter=closed")
    assert shown(view) == [3]
    assert has_element?(view, "#handoffs-filter-closed", "1 Landed or closed")
    assert has_element?(view, "#handoffs-archived-hint")
    refute has_element?(view, "#handoff-days")

    view |> form("#handoff-search", %{"archived" => "true"}) |> render_change()
    assert shown(view) == [3, 2, 1]
    assert has_element?(view, "#handoffs-filter-closed", "3 Landed or closed")
    assert has_element?(view, "#handoff-archived-2", "Archived")
    refute has_element?(view, "#handoff-archived-3")
    refute has_element?(view, "#handoffs-archived-hint")

    # Between two days, both included.
    view
    |> form("#handoff-search", %{"archived" => "true", "from" => day.(130), "to" => day.(40)})
    |> render_change()

    assert shown(view) == [2, 1]

    view
    |> form("#handoff-search", %{
      "archived" => "true",
      "from" => day.(130),
      "to" => day.(40),
      "term" => "pool"
    })
    |> render_change()

    assert shown(view) == [2, 1]
    assert has_element?(view, "#handoff-snippet-1 mark", "pool")

    view |> element("#handoffs-filter-open") |> render_click()
    assert shown(view) == []

    view
    |> form("#handoff-search", %{"term" => "", "archived" => "true", "from" => "", "to" => ""})
    |> render_change()

    assert shown(view) == [4]

    # Left out again: the line is back at a month.
    view |> form("#handoff-search", %{"archived" => "false"}) |> render_change()
    view |> element("#handoffs-filter-closed") |> render_click()
    assert shown(view) == [3]
  end
end
