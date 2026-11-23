defmodule MWTClient.QAProbes.FirewallUI.OverviewCountsTest do
  @moduledoc """
  Probes: the Overview's "Last hour" is counted over the newest 500 events
  of any kind; the Firewall page's "Found lately" lists setting changes
  as findings.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Event, Gate}
  alias MWTClient.Storage.Journal

  @moduletag :capture_log

  setup %{conn: conn}, do: sign_in(conn, "qa-overview")

  test "Last hour: 40 blocked 20 minutes ago, then 600 lookups", %{conn: conn, username: username} do
    now = DateTime.utc_now()

    for i <- 1..40 do
      Journal.record(
        username,
        Event.row(%Event{
          id: "event-b#{i}",
          at: DateTime.add(now, -1200, :second),
          outcome: :blocked,
          summary: "Private address with no network grant on",
          host: "10.0.0.#{i}"
        })
      )

      Journal.record(
        username,
        Event.row(%Event{
          id: "event-t#{i}",
          at: DateTime.add(now, -1200, :second),
          outcome: :tunnel,
          summary: "Passed through",
          host: "example.com"
        })
      )
    end

    for i <- 1..600 do
      Journal.record(
        username,
        Event.row(%Event{
          id: "event-l#{i}",
          at: DateTime.add(now, -30, :second),
          outcome: :lookup,
          summary: "Looked up (A)",
          host: "n#{i}.example.org"
        })
      )
    end

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")

    text =
      view |> element("#stat-activity") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

    IO.puts(
      "\nOverview, with 40 blocked and 40 connections 20 min ago: " <>
        String.replace(text, ~r/\s+/, " ")
    )

    assert text =~ "0 blocked"
  end

  test "Found lately fills with setting changes", %{conn: conn, username: username} do
    # A real finding first.
    :refuse = Gate.lookup(username, "dns.google")

    # Then you set a few rules up.
    for {rule, action} <- [
          cpu_hog: :off,
          bulk_reads: :off,
          dns_bypass: :alert,
          cpu_hog: :alert,
          bulk_reads: :alert,
          dns_bypass: :block,
          cpu_hog: :off,
          cpu_hog: :alert
        ] do
      :ok = Sandbox.firewall_set(username, {:action, rule, action})
    end

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")
    shown = view |> element("#firewall-findings") |> render()

    IO.puts(
      "Found lately shows the dns.google finding: #{shown =~ "dns.google"}; setting lines: #{length(String.split(shown, "set to")) - 1}"
    )

    refute shown =~ "dns.google"
  end
end
