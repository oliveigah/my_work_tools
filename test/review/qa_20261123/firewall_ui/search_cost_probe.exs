defmodule MWTClient.QAProbes.FirewallUI.SearchCostTest do
  @moduledoc """
  Probe: what one search keystroke and one stats tick cost on a journal of
  300,000 events (a few days of a busy VM; far under the 5 GB rule).
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag timeout: 300_000

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Event
  alias MWTClient.Storage.Journal

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-search")
  end

  test "search and figures on 300k events", %{username: username} do
    now = DateTime.utc_now()

    for i <- 1..300_000 do
      Journal.record(
        username,
        Event.row(%Event{
          id: "event-#{i}",
          at: DateTime.add(now, -div(i, 10), :second),
          outcome: if(rem(i, 3) == 0, do: :read, else: :lookup),
          summary: "Read by MWT, no credential in it",
          host: "host#{rem(i, 500)}.example.com",
          method: "GET",
          path: "/v1/packages/#{i}",
          up: 900,
          down: 20_000
        })
      )
    end

    :ok = Journal.flush(username)
    week = DateTime.add(now, -7 * 86_400, :second)

    time = fn label, fun ->
      {us, result} = :timer.tc(fun)
      IO.puts("#{label}: #{div(us, 1000)} ms")
      result
    end

    IO.puts("")

    time.("events, no search      ", fn -> Sandbox.events(username, %{since: week, limit: 51}) end)

    time.("events, rare word      ", fn ->
      Sandbox.events(username, %{since: week, q: "zzz-none", limit: 51})
    end)

    time.("stats, no search       ", fn -> Sandbox.event_stats(username, %{since: week}) end)

    time.("stats, rare word       ", fn ->
      Sandbox.event_stats(username, %{since: week, q: "zzz-none"})
    end)

    time.("threads                ", fn -> Sandbox.event_threads(username, %{since: week}) end)
  end
end
