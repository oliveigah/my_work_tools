defmodule MWTClientWeb.StorageLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.HttpClient.{HistoryMetadata, Resources}
  alias MWTClient.Storage.{Backups, Retention}

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp record(username, path) do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: "https://api.example.test" <> path),
      %Req.Response{status: 200, body: "ok"}
    )
  end

  test "lists every kind with its rule and what it holds, from the header", %{
    conn: conn,
    username: username
  } do
    record(username, "/one")
    {:ok, view, _html} = live(conn, ~p"/tools")
    assert has_element?(view, ~s(#storage-link[href="/storage"]))

    {:ok, view, _html} = live(conn, ~p"/storage")
    render_async(view)

    for kind <- Retention.kinds(), do: assert(has_element?(view, "#kind-#{kind.key}"))
    assert has_element?(view, "#kind-http_history-rule", "90 days")
    assert has_element?(view, "#kind-http_history", "1 item")
    assert has_element?(view, "#made-notes", "None")
    assert has_element?(view, "#file-library")
    assert has_element?(view, "#storage-dir")
  end

  test "a rule is changed, refused when it makes no sense, and put back", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/storage")

    view |> element("#edit-http_history") |> render_click()
    view |> form("#rule-form-http_history", rule: %{days: "0"}) |> render_submit()
    assert has_element?(view, "#rule-form-http_history", "must be 1 or more, or off")
    assert Retention.rule(username, "http_history").days == 90

    view |> form("#rule-form-http_history", rule: %{days: "30", gb: "2"}) |> render_submit()
    refute has_element?(view, "#rule-form-http_history")
    assert has_element?(view, "#kind-http_history-rule", "30 days · at most 2 GB")
    assert has_element?(view, "#kind-http_history-changed")
    assert Retention.rule(username, "http_history") == %{days: 30, gb: 2}
    refute Retention.changed?(username, "agent_activity")

    view |> element("#edit-http_history") |> render_click()
    view |> element("#reset-http_history") |> render_click()
    refute has_element?(view, "#kind-http_history-changed")
    refute Retention.changed?(username, "http_history")
  end

  test "versions keep their thinning, with monthly as a switch", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/storage")

    view |> element("#edit-note_versions") |> render_click()

    view
    |> form("#rule-form-note_versions", rule: %{every_days: "30", monthly: "false"})
    |> render_submit()

    assert %{every_days: 30, monthly: false} = Retention.rule(username, "note_versions")
    assert has_element?(view, "#kind-note_versions-rule", "then none")
  end

  test "clearing a kind asks first", %{conn: conn, username: username} do
    record(username, "/one")
    {:ok, view, _html} = live(conn, ~p"/storage")

    view |> element("#clear-http_history") |> render_click()
    assert has_element?(view, "#confirm-clear-http_history")
    assert [_] = Resources.all(username)

    view |> element("#confirm-clear-http_history-yes") |> render_click()
    refute has_element?(view, "#confirm-clear-http_history")
    assert Resources.all(username) == []
  end

  test "checking, backing up and applying the rules report what they did", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/storage")

    # Each reads or copies whole databases, which a full run's load can make
    # take over a second.
    view |> element("#run-check") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#storage-result", "library.db is sound")

    view |> element("#run-backup") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#storage-result", "Backed up as")
    assert [_backup] = Backups.list(username)
    refute has_element?(view, "#storage-last-backup", "None yet")

    view |> element("#run-sweep") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#storage-result", "Nothing was past its rule")
  end

  test "the VM's space, and its own rules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/storage")
    render_async(view)

    assert has_element?(view, "#vm-space")
    assert has_element?(view, "#reclaim[disabled]")
    assert has_element?(view, "#kind-vm_snapshots-rule", "the newest 3")
    refute has_element?(view, "#clear-vm_snapshots")
  end
end
