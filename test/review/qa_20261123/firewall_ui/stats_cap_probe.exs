defmodule MWTClient.QAProbes.FirewallUI.StatsCapTest do
  @moduledoc """
  Probe: the activity page's figures (totals, bytes, group counts,
  timeline) are worked out over the newest 20,000 events only, while the
  timeline and its words claim the whole window.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Event
  alias MWTClient.Storage.Journal

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-stats")
  end

  test "a busy day: older traffic vanishes from the figures", %{username: username} do
    now = DateTime.utc_now()
    three_hours_ago = DateTime.add(now, -3 * 3600, :second)
    a_minute_ago = DateTime.add(now, -60, :second)

    # 5,000 requests three hours ago, 1 MiB up each (e.g. an upload).
    for i <- 1..5_000 do
      Journal.record(
        username,
        Event.row(%Event{
          id: "event-old-#{i}",
          at: three_hours_ago,
          outcome: :read,
          summary: "Read by MWT",
          host: "uploads.example.com",
          up: 1_048_576,
          down: 100
        })
      )
    end

    # Then 20,000 lookups in the last minute (an npm install, say).
    for i <- 1..20_000 do
      Journal.record(
        username,
        Event.row(%Event{
          id: "event-new-#{i}",
          at: a_minute_ago,
          outcome: :lookup,
          summary: "registry.npmjs.org",
          host: "registry.npmjs.org"
        })
      )
    end

    day = DateTime.add(now, -86_400, :second)
    all = Sandbox.event_stats(username, %{since: day})
    traffic = Sandbox.event_stats(username, %{since: day, group: "traffic"})
    listed = Sandbox.events(username, %{since: day, group: "traffic", limit: 10})

    IO.puts("""

    events kept in the window: 25,000 (5,000 traffic, 5 GiB up)
    stats all:     total=#{all.total} groups.traffic=#{all.groups["traffic"]} up=#{all.up}
    stats traffic: total=#{traffic.total} up=#{traffic.up} peak=#{traffic.timeline.peak}
    log, traffic group, first page: #{length(listed)} rows
    """)

    assert all.total == 20_000
    assert all.groups["traffic"] == 0
    assert traffic.total == 0 and traffic.up == 0
    assert length(listed) == 10
  end
end
