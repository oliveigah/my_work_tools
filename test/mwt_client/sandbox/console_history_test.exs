defmodule MWTClient.Sandbox.ConsoleHistoryTest do
  @moduledoc "The console's history: the newest first, the oldest dropped past its runs or its bytes."
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.ConsoleHistory

  doctest ConsoleHistory

  defp run(output) do
    at = ~U[2026-11-25 10:00:00Z]

    %{
      command: "cat x",
      credential: nil,
      status: 0,
      output: output,
      cut: false,
      timed_out: false,
      started_at: at,
      finished_at: at
    }
  end

  test "at most 100 runs: the oldest go first" do
    runs = Enum.reduce(1..105, [], fn _n, runs -> ConsoleHistory.add(runs, run("a")) end)

    assert length(runs) == 100
    assert %{id: 105} = hd(runs)
    assert %{id: 6} = List.last(runs)
  end

  test "at most 8 MiB of output: the oldest go, never the newest" do
    mib = String.duplicate("x", 1024 * 1024)
    runs = Enum.reduce(1..10, [], fn _n, runs -> ConsoleHistory.add(runs, run(mib)) end)

    assert Enum.map(runs, & &1.id) == Enum.to_list(10..3//-1)

    # One run past the budget alone stays.
    assert [%{id: 1}] = ConsoleHistory.add([], run(String.duplicate(mib, 9)))
  end

  test "a run is kept as stopped only when it says so, and nothing else of it is kept" do
    [kept] = ConsoleHistory.add([], run("") |> Map.merge(%{stopped: true, extra: "dropped"}))

    assert kept.stopped
    refute Map.has_key?(kept, :extra)
  end
end
