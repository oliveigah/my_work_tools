defmodule MWTClient.Sandbox.EventStatsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Event, EventStats}

  @now ~U[2026-11-15 12:00:00Z]

  defp event(seconds_ago, outcome, attrs \\ %{}) do
    struct!(
      Event,
      Map.merge(
        %{
          id: "event-#{System.unique_integer([:positive])}",
          at: DateTime.add(@now, -seconds_ago, :second),
          outcome: outcome,
          summary: "#{outcome}"
        },
        attrs
      )
    )
  end

  # Newest first, as the server keeps them.
  defp events do
    [
      event(5, :tunnel, %{host: "api.github.com", up: 100, down: 2_000}),
      event(10, :swapped, %{host: "api.github.com", up: 50, down: 500}),
      event(20, :blocked, %{host: "10.0.0.5", port: 22}),
      event(30, :tunnel, %{host: "hex.pm", up: 10, down: 90_000}),
      event(40, :lookup, %{host: "hex.pm"}),
      event(50, :grant),
      event(700, :violation, %{host: "paste.example.net"})
    ]
  end

  test "counts every group, whichever is chosen" do
    stats = EventStats.summarize(events(), "blocked", nil, @now)

    assert stats.groups == %{
             "all" => 7,
             "traffic" => 2,
             "credentials" => 1,
             "blocked" => 2,
             "lookups" => 1,
             "changes" => 1,
             "commands" => 0,
             "firewall" => 0
           }

    assert stats.total == 2
  end

  test "adds up the bytes of the group chosen" do
    assert %{up: 160, down: 92_500, total: 7} = EventStats.summarize(events(), "all", nil, @now)
    assert %{up: 110, down: 92_000} = EventStats.summarize(events(), "traffic", nil, @now)
  end

  test "ranks the busiest destinations, with credentials and blocks" do
    assert [
             %{host: "api.github.com", count: 2, credentials: 1, blocked: 0, bytes: 2_650},
             %{host: "hex.pm", count: 2, credentials: 0, blocked: 0},
             %{host: "10.0.0.5", count: 1, blocked: 1},
             %{host: "paste.example.net", count: 1, blocked: 1}
           ] = EventStats.summarize(events(), "all", nil, @now).hosts
  end

  test "the timeline covers at least 15 minutes, in bars of whole steps" do
    timeline = EventStats.summarize(events(), "all", nil, @now).timeline

    assert timeline.step == 15
    assert length(timeline.buckets) == 61
    assert timeline.from == ~U[2026-11-15 11:45:00Z]
    assert Enum.all?(timeline.buckets, &(rem(DateTime.to_unix(&1.at), 15) == 0))

    # Every event in the window falls in one bar, in its series.
    assert timeline.buckets |> Enum.map(& &1.total) |> Enum.sum() == 7

    last = List.last(timeline.buckets)
    assert last.at == ~U[2026-11-15 12:00:00Z]
    assert %{counts: %{traffic: 1, credentials: 1}} = Enum.at(timeline.buckets, -2)
    assert timeline.peak == 2
  end

  test "the timeline reaches back to the oldest event kept, in fewer bars as it grows" do
    oldest = DateTime.add(@now, -3 * 3600, :second)
    timeline = EventStats.timeline(events(), oldest, @now)

    assert timeline.step == 300
    assert length(timeline.buckets) <= 61
    assert DateTime.compare(timeline.from, oldest) != :gt
  end

  test "a group chosen leaves its own series in the timeline" do
    timeline = EventStats.summarize(events(), "blocked", nil, @now).timeline
    counts = Enum.map(timeline.buckets, & &1.counts)

    assert counts |> Enum.map(& &1.blocked) |> Enum.sum() == 2
    assert counts |> Enum.map(&(&1.traffic + &1.credentials + &1.other)) |> Enum.sum() == 0
  end

  test "nothing to show is still a timeline" do
    stats = EventStats.summarize([], "all", nil, @now)
    assert %{total: 0, hosts: [], timeline: %{peak: 0}} = stats
    assert stats.timeline.buckets != []
  end
end
