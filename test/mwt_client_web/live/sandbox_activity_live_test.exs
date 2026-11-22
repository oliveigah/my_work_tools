defmodule MWTClientWeb.SandboxActivityLiveTest do
  @moduledoc """
  The proxy activity page's figures: counts on the groups, the timeline,
  the busiest destinations, and the live or paused log.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.{Event, Server}

  setup %{conn: conn} do
    sign_in(conn)
  end

  # Newest first, recorded in the journal oldest first, after what the
  # server logged itself.
  defp put_events(username, events) do
    for event <- Enum.reverse(events),
        do: MWTClient.Storage.Journal.record(username, Event.row(event))

    MWTClient.Storage.Journal.flush(username)
  end

  defp event(n, outcome, host, attrs \\ %{}) do
    struct!(
      Event,
      Map.merge(
        %{
          id: "event-a#{n}",
          at: DateTime.add(DateTime.utc_now(), -n, :second),
          outcome: outcome,
          summary: "#{outcome} #{n}",
          host: host
        },
        attrs
      )
    )
  end

  defp traffic(username) do
    put_events(username, [
      event(1, :tunnel, "api.github.com", %{up: 100, down: 4_000, ms: 1_250}),
      event(2, :tunnel, "api.github.com"),
      event(3, :swapped, "api.github.com", %{method: "GET", path: "/user"}),
      event(4, :blocked, "10.0.0.5", %{port: 22}),
      event(5, :tunnel, "hex.pm")
    ])
  end

  test "is called Proxy activity, and says it is live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#sandbox-nav-activity", "Proxy activity")
    assert has_element?(view, "#activity-header", "Proxy activity")
    assert has_element?(view, "#activity-live")
  end

  test "the groups count what each would show", %{conn: conn, username: username} do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    assert has_element?(view, "#activity-group-traffic-count", "3")
    assert has_element?(view, "#activity-group-credentials-count", "1")
    assert has_element?(view, "#activity-group-blocked-count", "1")

    # Choosing one narrows the figures, not the counts.
    view |> form("#activity-filters", %{group: "blocked", q: "", grant: ""}) |> render_change()
    assert has_element?(view, "#activity-total", "1")
    assert has_element?(view, "#activity-group-traffic-count", "3")
  end

  test "the timeline and destinations show what passes the filters", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    assert has_element?(view, "#activity-timeline")
    assert has_element?(view, "#activity-legend-blocked", "1")
    assert has_element?(view, "#activity-host-0", "api.github.com")
    assert has_element?(view, "#activity-host-0", "1 cred")
    assert has_element?(view, "#activity-host-1", "10.0.0.5")
    assert has_element?(view, "#activity-host-1", "1 blocked")
  end

  test "a destination narrows the log to itself, and again clears it", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    view |> element("#activity-host-2") |> render_click()
    assert has_element?(view, "#activity-search[value='hex.pm']")
    assert has_element?(view, "#activity-log #event-event-a5")
    refute has_element?(view, "#activity-log #event-event-a1")
    assert has_element?(view, "#activity-total", "1")

    view |> element("#activity-host-0") |> render_click()
    assert has_element?(view, "#activity-search[value='']")
    assert has_element?(view, "#activity-log #event-event-a1")
  end

  test "a line opens to what MWT recorded about it", %{conn: conn, username: username} do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    assert has_element?(view, "#event-event-a1 summary", "1.3 s")
    assert has_element?(view, "#event-event-a1 details", "100 / 4,000 bytes")
    assert has_element?(view, "#event-event-a3 details", "GET /user")
    assert has_element?(view, "#event-event-a4 details", "10.0.0.5:22")
  end

  test "a connection that failed for being read offers not to read its host again", %{
    conn: conn,
    username: username
  } do
    put_events(username, [
      event(1, :read_failed, "pinned.example", %{
        port: 443,
        summary: "pinned.example: the client refused MWT's certificate · nothing went out"
      })
    ])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#event-event-a1 summary", "Not read")

    view |> element("#event-dont-read-event-a1") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == [%{host: "pinned.example", read?: false}]

    # Its line now offers the other way, and the card lists it.
    assert has_element?(view, "#event-read-event-a1")
    assert has_element?(view, "#activity-reading-rule-pinned-example")
  end

  test "what MWT reads is set on the page: the default, and hosts opted in or out", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#activity-reading-empty")
    assert has_element?(view, "#activity-reading-default-every_host[aria-checked=true]")

    # Added from the card: an address is refused, a host taken.
    view
    |> form("#activity-reading-form", reading: %{host: "10.0.0.5", read: "false"})
    |> render_submit()

    assert MWTClient.Sandbox.reading(username).rules == []

    view
    |> form("#activity-reading-form", reading: %{host: "*.pinned.example", read: "false"})
    |> render_submit()

    assert has_element?(
             view,
             "#activity-reading-rule-any-pinned-example-read-false[aria-checked=true]"
           )

    view |> element("#activity-reading-rule-any-pinned-example-read-true") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == [%{host: "*.pinned.example", read?: true}]

    view |> element("#activity-reading-rule-any-pinned-example-remove") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == []

    # From a busiest destination: hex.pm is read, one click passes it; an
    # address names nothing to read, and has no switch.
    toggle = "#activity-hosts button[phx-click=reading_put][phx-value-host='hex.pm']"
    assert has_element?(view, toggle, "read")

    refute has_element?(
             view,
             "#activity-hosts button[phx-click=reading_put][phx-value-host='10.0.0.5']"
           )

    view |> element(toggle) |> render_click()
    refute MWTClient.Sandbox.Reading.read?(MWTClient.Sandbox.reading(username), "hex.pm")
    assert has_element?(view, toggle, "not read")

    view |> element("#activity-reading-default-token_hosts") |> render_click()
    assert MWTClient.Sandbox.reading(username).default == :token_hosts
  end

  test "a token grant's host offers nothing of the kind: it is read for its value", %{
    conn: conn,
    username: username
  } do
    {:ok, _grant} =
      MWTClient.Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value_0123456789"
      })

    put_events(username, [event(1, :read_failed, "api.github.com", %{port: 443})])
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    refute has_element?(view, "#event-dont-read-event-a1")
    assert has_element?(view, "#event-token-host-event-a1")
  end

  test "a request MWT read opens to what it carried and what came back, to copy as JSON", %{
    conn: conn,
    username: username
  } do
    alias MWTClient.Sandbox.Exchange
    alias MWTClient.Storage.Journal

    put_events(username, [
      event(1, :swapped, "api.github.com", %{
        method: "GET",
        path: "/user",
        exchange_id: "exchange-1"
      }),
      event(2, :tunnel, "hex.pm")
    ])

    request =
      Exchange.request(%{
        method: "GET",
        host: "api.github.com",
        path: "/user",
        headers: [{"authorization", "token ghp_mwt_placeholder"}],
        body: ""
      })

    response =
      Exchange.capture()
      |> Exchange.capture(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 16\r\n\r\n"
      )
      |> Exchange.capture(~s({"login":"octo"}))
      |> Exchange.response(nil)

    Journal.record_exchange(username, "exchange-1", %{request: request, response: response})
    :ok = Journal.flush(username)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    # Read when it opens: the hook asks once.
    assert has_element?(view, "#event-event-a1 [data-read=no]")
    render_hook(view, "open_event", %{"id" => "event-a1"})

    assert has_element?(view, "#event-request-event-a1", "token ghp_mwt_placeholder")
    assert has_element?(view, "#event-response-status-event-a1", "200 OK")
    assert has_element?(view, "#event-response-body-event-a1", "\"login\": \"octo\"")

    json =
      view
      |> element("#event-json-event-a1")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> Jason.decode!()

    assert json["response"]["status"] == 200
    assert json["response"]["body"] == %{"login" => "octo"}
    assert json["request"]["headers"]["authorization"] == "token ghp_mwt_placeholder"
    assert has_element?(view, "#event-copy-event-a1[data-copy-target=event-json-event-a1]")

    # A tunnel was never read: it says so instead.
    assert has_element?(view, "#event-exchange-event-a2", "Passed through as bytes")
  end

  test "new activity updates the figures while the page is open", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    count = fn -> view |> element("#activity-group-blocked-count") |> render() end
    before = count.()

    Server.cast(
      username,
      {:log, %{outcome: :blocked, summary: "refused", host: "192.168.1.9", port: 80}}
    )

    _ = :sys.get_state(GenServer.whereis(MWTClient.Vault.Store.via(Server, username)))
    send(view.pid, :activity_stats)
    refute count.() == before
    assert has_element?(view, "#activity-log li", "192.168.1.9")
  end

  test "an older page says it is paused, and goes back to live", %{
    conn: conn,
    username: username
  } do
    put_events(username, for(n <- 1..60, do: event(n, :tunnel, "h#{n}.example")))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    view |> element("#activity-older") |> render_click()
    assert has_element?(view, "#activity-paused", "page 2")
    refute has_element?(view, "#activity-live")

    view |> element("#activity-paused") |> render_click()
    assert has_element?(view, "#activity-live")
  end
end
