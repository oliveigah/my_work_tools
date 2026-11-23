defmodule MWTClient.Storage.JournalTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Storage
  alias MWTClient.Storage.Journal
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  defp row(n),
    do: %{id: "e#{n}", at: n, outcome: "tunnel", summary: "conn #{n}", search_text: "conn #{n}"}

  defp written(username) do
    Storage.run(username, :journal, fn repo ->
      repo.query!("SELECT id FROM events ORDER BY seq").rows |> List.flatten()
    end)
  end

  test "rows wait for the next batch, written within a second, in order", %{username: username} do
    pid = Store.whereis(Journal, username)
    :erlang.trace(pid, true, [:receive])

    for n <- 1..3, do: Journal.record(username, row(n))
    _ = :sys.get_state(pid)
    assert written(username) == []

    assert_receive {:trace, ^pid, :receive, :write}, 2_000
    :erlang.trace(pid, false, [:receive])
    _ = :sys.get_state(pid)
    assert written(username) == ~w(e1 e2 e3)
  end

  test "a thousand waiting are written at once, without the timer", %{username: username} do
    for n <- 1..1_000, do: Journal.record(username, row(n))
    _ = :sys.get_state(Store.whereis(Journal, username))

    assert length(written(username)) == 1_000
  end

  test "flush writes what waits, and an id recorded twice is written once", %{username: username} do
    Journal.record(username, row(1))
    Journal.record(username, %{row(1) | summary: "again"})
    :ok = Journal.flush(username)

    assert written(username) == ["e1"]
  end

  test "locking writes what waits; locked, rows are dropped", %{username: username, key: key} do
    Journal.record(username, row(1))
    :ok = Store.close(username)

    assert Journal.record(username, row(2)) == :ok
    assert Journal.flush(username) == :ok

    :ok = Store.open(username, key)
    assert written(username) == ["e1"]
  end

  test "an exchange is kept with each event that names it, and goes with it", %{
    username: username
  } do
    Journal.record(username, Map.put(row(1), :exchange_id, "x1"))
    Journal.record(username, Map.put(row(2), :exchange_id, "x1"))
    Journal.record(username, row(3))
    Journal.record_exchange(username, "x1", %{request: :what_went, response: :what_came})
    # Named by no event: not kept.
    Journal.record_exchange(username, "x2", %{request: :stray, response: nil})

    assert Journal.exchange(username, "e1") == %{request: :what_went, response: :what_came}
    assert Journal.exchange(username, "e2") == %{request: :what_went, response: :what_came}
    assert Journal.exchange(username, "e3") == nil

    count = fn ->
      Storage.run(username, :journal, & &1.query!("SELECT count(*) FROM events_exchanges").rows)
    end

    assert count.() == [[2]]

    Storage.run(username, :journal, & &1.query!("DELETE FROM events WHERE id = 'e1'"))
    assert Journal.exchange(username, "e1") == nil
    assert count.() == [[1]]
  end

  test "an event's details are kept with it, read back, and go with it", %{username: username} do
    details = [%{title: "The ask", by: :mwt, rows: [{"Why", {:text, "to check the deploy"}}]}]

    Journal.record(username, Map.put(row(1), :detailed, 1))
    Journal.record_details(username, "e1", details)
    Journal.record(username, row(2))
    # For an event never recorded: not kept.
    Journal.record_details(username, "e9", details)

    assert Journal.details(username, "e1") == details
    assert Journal.details(username, "e2") == nil
    assert Journal.details(username, "e9") == nil

    count = fn ->
      Storage.run(username, :journal, & &1.query!("SELECT count(*) FROM events_details").rows)
    end

    assert count.() == [[1]]
    Storage.run(username, :journal, & &1.query!("DELETE FROM events WHERE id = 'e1'"))
    assert count.() == [[0]]

    # Clearing the activity takes every event's details too.
    Journal.record(username, Map.put(row(3), :detailed, 1))
    Journal.record_details(username, "e3", details)
    :ok = Journal.flush(username)
    assert count.() == [[1]]
    :ok = MWTClient.Storage.Maintenance.clear(username, "agent_activity")
    assert count.() == [[0]]
  end

  # The journal can't be written while its table is away: every insert
  # fails at once, as one held past the busy timeout fails after it.
  defp unwritable(username),
    do: Storage.run(username, :journal, & &1.query!("ALTER TABLE events RENAME TO events_away"))

  defp writable(username),
    do: Storage.run(username, :journal, & &1.query!("ALTER TABLE events_away RENAME TO events"))

  defp rows_of(username) do
    Storage.run(username, :journal, fn repo ->
      repo.query!("SELECT id, outcome, summary, at FROM events ORDER BY seq").rows
    end)
  end

  @tag :capture_log
  test "a write that fails keeps what waited, in order, and writes it once it can", %{
    username: username
  } do
    Journal.record(username, Map.put(row(1), :exchange_id, "x1"))
    Journal.record_exchange(username, "x1", %{request: :what_went})
    unwritable(username)

    :ok = Journal.flush(username)
    Journal.record(username, row(2))
    :ok = Journal.flush(username)

    writable(username)
    Journal.record(username, row(3))
    :ok = Journal.flush(username)

    assert written(username) == ~w(e1 e2 e3)
    assert Journal.exchange(username, "e1") == %{request: :what_went}
  end

  @tag :capture_log
  test "a journal that stays unwritable drops what waits after five tries, and says so in the log",
       %{username: username} do
    Journal.record(username, %{row(1) | at: 1_763_287_200_000_000})
    Journal.record(username, %{row(2) | at: 1_763_287_230_000_000})
    unwritable(username)

    for _try <- 1..5, do: :ok = Journal.flush(username)
    # Dropped: what waits now is the gap alone.
    assert %{rows: [], lost: %{events: 2}} = :sys.get_state(Store.whereis(Journal, username))

    writable(username)
    Journal.record(username, row(3))
    :ok = Journal.flush(username)

    assert [[_id, "lost", summary, 1_763_287_200_000_000], ["e3" | _]] = rows_of(username)
    assert summary =~ "2 events of the activity log weren't kept"
    assert summary =~ "from 2025-11-16 10:00:00 to 2025-11-16 10:00:30 UTC"
    assert summary =~ "events_away" or summary =~ "no such table"
  end

  @tag :capture_log
  test "while writes fail, what waits is bounded", %{username: username} do
    unwritable(username)
    Journal.record(username, row(0))
    :ok = Journal.flush(username)

    # One failure, then more rows than it keeps: they go, said as a gap.
    for n <- 1..10_001, do: Journal.record(username, row(n))
    state = :sys.get_state(Store.whereis(Journal, username))
    assert state.count < 10_000
    assert state.lost.events > 0

    writable(username)
    :ok = Journal.flush(username)
    assert [[_id, "lost", summary, _at] | _] = rows_of(username)
    assert summary =~ "weren't kept"
  end

  test "16 MiB of exchanges waiting are written at once, without the timer", %{
    username: username
  } do
    Journal.record(username, Map.put(row(1), :exchange_id, "x1"))
    Journal.record_exchange(username, "x1", %{body: :crypto.strong_rand_bytes(17 * 1024 * 1024)})
    _ = :sys.get_state(Store.whereis(Journal, username))

    assert Storage.run(username, :journal, fn repo ->
             repo.query!("SELECT count(*) FROM events_exchanges").rows
           end) == [[1]]
  end
end
