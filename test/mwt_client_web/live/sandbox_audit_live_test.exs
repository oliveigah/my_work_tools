defmodule MWTClientWeb.SandboxAuditLiveTest do
  @moduledoc """
  The activity log's audit: each action's line says how it was decided,
  and opens what decided it read-only, the card or the grant as it was;
  the log filters by who or what decided.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn, "audit-live")
  end

  defp request(host, headers \\ []) do
    %{
      host: host,
      method: "GET",
      path: "/x",
      headers: [{"host", host} | headers],
      body: "",
      exchange: "exchange-" <> Integer.to_string(System.unique_integer([:positive]))
    }
  end

  test "a line opens to one audit card: outcome, who decided, why, and links to know more",
       %{conn: conn, username: username} do
    assert {:forward, _, _} = Server.call(username, {:authorize, request("example.com")})
    [event | _] = Enum.filter(Sandbox.events(username, %{limit: 20}), &(&1.host == "example.com"))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    render_hook(view, "open_event", %{"id" => event.id})

    assert has_element?(view, "#event-audit-outcome-#{event.id}", "Allowed")
    assert has_element?(view, "#event-decided-by-#{event.id}", "Auto-approve")
    assert has_element?(view, "#event-audit-because-#{event.id}", "starts on with Auto-approve")
    assert has_element?(view, "#event-audit-#{event.id}", "Audit")

    assert has_element?(
             view,
             "#event-audit-grant-#{event.id}[href='/tools/sandbox/grants/internet']"
           )

    refute has_element?(view, "#event-audit-changed-#{event.id}")

    # The grant changed since: the card says so, and links to its changes.
    {:ok, _} = Sandbox.set_except(username, "internet", ["paste.example.com"])
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    render_hook(view, "open_event", %{"id" => event.id})

    assert has_element?(
             view,
             "#event-audit-changed-#{event.id}[href='/tools/sandbox/activity?group=changes&grant=internet']"
           )
  end

  test "a card you decided opens read-only, with what you chose; the log filters by you",
       %{conn: conn, username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The API",
        "hosts" => "api.github.com",
        "value" => "ghp_real_value_0123456789"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)

    task =
      Task.async(fn ->
        Server.call(
          username,
          {:authorize,
           request("api.github.com", [{"authorization", "token #{grant.placeholder}"}])},
          :infinity
        )
      end)

    card =
      Enum.find_value(1..200, fn _ ->
        case Sandbox.snapshot(username).waiting do
          [card | _] -> card
          [] -> Process.sleep(10) && nil
        end
      end)

    :ok = Sandbox.decide(username, card.id, :deny)
    Task.await(task)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity")
    view |> form("#activity-filters", %{decided: "you"}) |> render_change()

    [event] =
      Enum.filter(Sandbox.events(username, %{decided: "you"}), &(&1.decision[:card] == card.id))

    render_hook(view, "open_event", %{"id" => event.id})
    assert has_element?(view, "#event-decided-by-#{event.id}", "You, on a card")
    assert has_element?(view, "#event-audit-outcome-#{event.id}", "Not allowed")

    # The card opens on the Approvals page, as it was decided, read-only.
    {:ok, view, _html} =
      view |> element("#event-audit-card-#{event.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(view, "#kept-card #kept-approval-#{card.id}")
    assert has_element?(view, "#kept-choice-#{card.id}", "You denied")
    refute has_element?(view, "#kept-card footer button")
  end
end
