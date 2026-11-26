defmodule MWTClientWeb.SandboxActivityLiveTest do
  @moduledoc """
  The activity log's figures: counts on the groups, the timeline,
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

  test "is called Activity log, and says it is live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#sandbox-nav-activity", "Activity log")
    assert has_element?(view, "#activity-header", "Activity log")
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
    assert has_element?(view, "#event-event-a1 details", "↑ 100 · ↓ 4,000 bytes")
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
    assert has_element?(view, "#event-event-a1 summary", "Cert refused")

    view |> element("#event-dont-read-event-a1") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == [%{host: "pinned.example", read?: false}]

    # Its line now offers the other way, and What MWT reads lists it.
    assert has_element?(view, "#event-read-event-a1")
    view |> element("#activity-reading-open") |> render_click()
    assert has_element?(view, "#activity-reading-unread-pinned-example")
  end

  test "each event says what it means: hovered, in the legend, and opened", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    assert has_element?(
             view,
             "#event-event-a1 summary span[title*='as bytes, unread']",
             "Not read"
           )

    # Opened, the line says it once, by its badge: no row repeats it.
    refute has_element?(view, "#event-meaning-event-a1")

    # The legend has every outcome, in the filters' groups.
    for {group, outcomes} <- Event.groups(), outcome <- outcomes do
      assert has_element?(view, "#activity-legend-#{group}-group")
      assert has_element?(view, "#activity-legend-outcome-#{outcome}[data-group=#{group}]")
    end
  end

  test "what MWT reads opens from the header: two lists, and what a host on neither gets", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    # Not on the page until asked for.
    refute has_element?(view, "#activity-reading")
    view |> element("#activity-reading-open") |> render_click()
    assert has_element?(view, "#activity-reading-read-empty")
    assert has_element?(view, "#activity-reading-unread-empty")
    assert has_element?(view, "#activity-reading-default--every_host[aria-checked=true]")

    # Added to a list: an address is refused, and stays in its field; a
    # host is taken, and the fields empty.
    view
    |> form("#activity-reading-unread-form", reading: %{host: "10.0.0.5"})
    |> render_submit()

    assert MWTClient.Sandbox.reading(username).rules == []
    assert has_element?(view, "#activity-reading-unread-host-0")

    view
    |> form("#activity-reading-unread-form", reading: %{host: "*.pinned.example"})
    |> render_submit()

    assert MWTClient.Sandbox.reading(username).rules == [
             %{host: "*.pinned.example", read?: false}
           ]

    assert has_element?(view, "#activity-reading-unread-any-pinned-example")
    assert has_element?(view, "#activity-reading-unread-count", "1")
    refute has_element?(view, "#activity-reading-unread-host-0")

    # Moved to the other list, by its arrow or by adding it there.
    view |> element("#activity-reading-unread-any-pinned-example-move") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == [%{host: "*.pinned.example", read?: true}]
    assert has_element?(view, "#activity-reading-read-any-pinned-example")
    refute has_element?(view, "#activity-reading-unread-any-pinned-example")

    view
    |> form("#activity-reading-unread-form", reading: %{host: "*.pinned.example"})
    |> render_submit()

    assert MWTClient.Sandbox.reading(username).rules == [
             %{host: "*.pinned.example", read?: false}
           ]

    view |> element("#activity-reading-unread-any-pinned-example-remove") |> render_click()
    assert MWTClient.Sandbox.reading(username).rules == []

    view |> element("#activity-reading-default--token_hosts") |> render_click()
    assert MWTClient.Sandbox.reading(username).default == :token_hosts

    # Closed, it is gone again; the header says hosts on neither list
    # aren't read.
    view |> element("#activity-reading-done") |> render_click()
    refute has_element?(view, "#activity-reading")
    assert has_element?(view, "#activity-reading-open-default", "others not read")
  end

  test "a busiest destination switches whether its host is read", %{
    conn: conn,
    username: username
  } do
    traffic(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    # hex.pm is read, one click passes it; an address names nothing to
    # read, and has no switch.
    toggle = "#activity-hosts button[phx-click=reading_put][phx-value-host='hex.pm']"
    assert has_element?(view, toggle, "read")

    refute has_element?(
             view,
             "#activity-hosts button[phx-click=reading_put][phx-value-host='10.0.0.5']"
           )

    view |> element(toggle) |> render_click()
    refute MWTClient.Sandbox.Reading.read?(MWTClient.Sandbox.reading(username), "hex.pm")
    assert has_element?(view, toggle, "not read")
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

  # The sandbox handles what was sent to it before, and the page what the
  # sandbox told it since.
  defp settled(username, view) do
    _ = :sys.get_state(GenServer.whereis(MWTClient.Vault.Store.via(Server, username)))
    render(view)
  end

  # A request's call, as the proxy runs one: alive until it is told to end.
  defp call_process do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "a running request's line is marked and shows its request; once it ends, the response and how long it took",
       %{conn: conn, username: username} do
    alias MWTClient.Sandbox
    alias MWTClient.Sandbox.Exchange

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Activity credential",
        "purpose" => "Redact the current value",
        "hosts" => "api.anthropic.com",
        "env" => "QA_TOKEN",
        "value" => "first-synthetic-test-value"
      })

    current_value = "rotated-synthetic-test-value"

    request =
      Exchange.request(%{
        method: "POST",
        host: "api.anthropic.com",
        path: "/v1/messages",
        headers: [{"content-type", "application/json"}, {"x-qa", current_value}],
        body: ~s({"stream":true})
      })

    Server.cast(
      username,
      {:began, "exchange-running", call_process(), Exchange.new(request, nil, nil)}
    )

    put_events(username, [
      event(1, :read, "api.anthropic.com", %{
        method: "POST",
        path: "/v1/messages",
        exchange_id: "exchange-running"
      })
    ])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#event-running-event-a1[data-since]")

    :ok = Sandbox.set_value(username, grant.id, current_value)

    # Opened while it runs: the request as MWT read it, the response to come.
    render_hook(view, "open_event", %{"id" => "event-a1"})
    assert has_element?(view, "#event-running-event-a1")
    assert has_element?(view, "#event-request-event-a1", ~s("stream"))
    assert has_element?(view, "#event-request-event-a1", "real credential withheld by MWT")
    refute has_element?(view, "#event-request-event-a1", current_value)
    assert has_element?(view, "#event-response-running-event-a1", "Still running")

    response =
      Exchange.capture()
      |> Exchange.capture("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
      |> Exchange.capture("event: message_stop\n\n")
      |> Exchange.response(nil)

    # The request ends: the sandbox keeps it, and the open line reads it.
    Server.cast(
      username,
      {:exchange, "exchange-running", %{request: request, response: response}}
    )

    settled(username, view)

    refute has_element?(view, "#event-running-event-a1")
    assert has_element?(view, "#event-response-status-event-a1", "200 OK")
    assert has_element?(view, "#event-request-event-a1", "real credential withheld by MWT")
    refute has_element?(view, "#event-request-event-a1", current_value)
    assert has_element?(view, "#event-event-a1 summary", ~r/\d+(\.\d)? m?s\b/)

    # The journal keeps how long it took.
    :ok = MWTClient.Storage.Journal.flush(username)

    assert [%Event{ms: ms}] =
             Sandbox.events(username, %{q: "api.anthropic.com", group: "traffic"})

    assert is_integer(ms)
  end

  test "a request whose call ends first stops running, and keeps the request as MWT read it", %{
    conn: conn,
    username: username
  } do
    alias MWTClient.Sandbox.Exchange

    call = call_process()

    unfinished =
      Exchange.new(
        Exchange.request(%{
          method: "POST",
          host: "api.anthropic.com",
          path: "/v1/messages",
          headers: [{"content-type", "application/json"}],
          body: ~s({"model":"m"})
        }),
        nil,
        nil
      )

    Server.cast(username, {:began, "exchange-cut", call, unfinished})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    # Its line comes while the page is open, marked running.
    Server.cast(
      username,
      {:log,
       %{
         outcome: :read,
         summary: "POST api.anthropic.com/v1/messages",
         host: "api.anthropic.com",
         method: "POST",
         path: "/v1/messages",
         exchange_id: "exchange-cut"
       }}
    )

    settled(username, view)
    [event] = MWTClient.Sandbox.events(username, %{q: "api.anthropic.com"})
    assert has_element?(view, "#event-running-#{event.id}")
    render_hook(view, "open_event", %{"id" => event.id})
    assert has_element?(view, "#event-response-running-#{event.id}")

    ref = Process.monitor(call)
    send(call, :stop)
    assert_receive {:DOWN, ^ref, :process, ^call, _reason}
    settled(username, view)

    refute has_element?(view, "#event-running-#{event.id}")
    assert has_element?(view, "#event-request-#{event.id}", ~s("model"))
    assert has_element?(view, "#event-response-note-#{event.id}", "only the request is kept")
  end

  test "a line opens to its details: an edited grant says what changed, and what it is", %{
    conn: conn,
    username: username
  } do
    fields = %{
      "kind" => "token",
      "name" => "GitHub",
      "purpose" => "The GitHub API",
      "hosts" => "api.github.com",
      "env" => "GH_TOKEN",
      "value" => "ghp_real_value_0123456789"
    }

    {:ok, grant} = MWTClient.Sandbox.create_grant(username, fields)

    {:ok, _edited} =
      MWTClient.Sandbox.update_grant(
        username,
        grant.id,
        Map.put(fields, "hosts", "api.github.com\nuploads.github.com")
      )

    [edited | _] = MWTClient.Sandbox.events(username, %{q: "edited"})
    assert edited.detailed?

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    line = "#event-#{edited.id}"

    # Read when it opens, as a request's content is.
    assert has_element?(view, "#{line} details[data-read=no]")
    render_hook(view, "open_event", %{"id" => edited.id})

    assert has_element?(view, "#event-details-#{edited.id}", "What changed")
    assert has_element?(view, "#event-details-#{edited.id}", "uploads.github.com")
    refute render(view) =~ "ghp_real_value_0123456789"

    json =
      view
      |> element("#event-json-#{edited.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> Jason.decode!()

    assert Enum.any?(json["details"], &(&1["section"] == "What changed"))
  end

  test "an agent's words show apart, and the word filter finds what only the details say", %{
    conn: conn,
    username: username
  } do
    alias MWTClient.Sandbox.EventDetails

    Server.cast(
      username,
      {:log,
       %{
         outcome: :command,
         summary: "A command · you ran it",
         details: [
           EventDetails.section("Command", [{"Script", {:code, "kubectl rollout status"}}]),
           EventDetails.agent("In the agent's words", [{"Why", "to see the rollout"}])
         ]
       }}
    )

    _ = :sys.get_state(GenServer.whereis(MWTClient.Vault.Store.via(Server, username)))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")

    view |> form("#activity-filters", %{q: "rollout status"}) |> render_change()
    [event] = MWTClient.Sandbox.events(username, %{q: "rollout status"})
    assert has_element?(view, "#activity-log #event-#{event.id}")

    render_hook(view, "open_event", %{"id" => event.id})

    assert has_element?(
             view,
             "#event-details-#{event.id} section[data-by=agent]",
             "to see the rollout"
           )

    assert has_element?(
             view,
             "#event-details-#{event.id} section[data-by=mwt]",
             "kubectl rollout status"
           )
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

  @tag :capture_log
  test "events the journal couldn't keep show as a gap in the log", %{
    conn: conn,
    username: username
  } do
    rename = fn from, to ->
      MWTClient.Storage.run(
        username,
        :journal,
        & &1.query!("ALTER TABLE #{from} RENAME TO #{to}")
      )
    end

    MWTClient.Storage.Journal.flush(username)
    rename.("events", "events_away")
    MWTClient.Storage.Journal.record(username, Event.row(event(1, :tunnel, "lost.example")))
    for _try <- 1..5, do: MWTClient.Storage.Journal.flush(username)
    rename.("events_away", "events")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    assert has_element?(view, "#activity-table", "1 event of the activity log wasn't kept")
    assert has_element?(view, "#activity-table", "Not kept")
    refute has_element?(view, "#activity-table", "lost.example")
  end
end
