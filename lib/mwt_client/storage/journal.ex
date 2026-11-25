defmodule MWTClient.Storage.Journal do
  @moduledoc """
  Writes one identity's agent activity into the `events` table of its
  `journal.db` (`MWTClient.Storage.Migrations.JournalEvents`), many rows
  to a transaction.

  An app hands it rows with `record/2`, which never waits on the disk:
  they are kept here and written once a second, or as soon as 1,000 are
  waiting, whichever comes first. What a request carried and got back
  (`record_exchange/3`) is written after them, with each event that names
  it, so it is kept only when an event does; 16 MiB of them waiting are
  written at once too. What an event says when opened
  (`record_details/3`, `MWTClient.Sandbox.EventDetails`) is written after
  its event, in the same transaction. `flush/1` writes what waits now, so a
  read that follows sees everything recorded before it. Locking writes
  what waits before the databases close.

  `journal.db` runs with `synchronous=NORMAL`: a power cut can lose the
  last second, never the file's consistency.

  A write that fails (the write lock held past SQLite's busy timeout by a
  long delete of the retention rule or a Clear, a full disk) loses
  nothing at once: what waited stays, in its order, and is tried again a
  second later, and at each flush. Retrying is bounded, so a journal
  that can't be written doesn't hold memory without end: after 5
  failures in a row, or past 10,000 rows or 64 MiB of exchanges and
  details waiting, what waits is dropped. The loss is then
  said in the log itself: a row of its own (`outcome` `lost`) saying how
  many events weren't kept, from when to when, and why, written ahead of
  the next batch that goes in, where they would have been. MWT's log
  says each failure as it happens.

  One process per unlocked identity, started by `MWTClient.Storage` after
  the databases.
  """

  use GenServer

  require Logger

  alias MWTClient.Storage
  alias MWTClient.Storage.Usage
  alias MWTClient.Storage.Values
  alias MWTClient.Vault.Store

  @every_ms 1_000
  @batch 1_000
  # Exchanges are up to a few hundred KB each: past this many bytes waiting,
  # they are written at once rather than at the next second.
  @batch_bytes 16 * 1024 * 1024
  @trim_batch 10_000
  # A batch that failed is tried again this many times, holding at most
  # this many events, and bytes of exchanges and details, before it is
  # dropped and the gap logged.
  @tries 5
  @kept_most 10_000
  @kept_bytes 64 * 1024 * 1024
  # How much of a failure's reason the gap's line says: its first line,
  # as SQLite's errors go on with the statement.
  @reason_chars 200

  @columns ~w(id at outcome summary grant_id host port method path up down ms agent thread_id
              thread exchange_id detailed search_text decided_by card_id decision)a

  @typedoc """
  One event, as its columns hold it: `:id`, `:at` (microseconds since
  1970), `:outcome` and `:summary`, the rest optional.
  """
  @type row :: %{required(atom()) => term()}

  @doc false
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc "The columns a row may set."
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc """
  Keeps `row` to be written with the next batch. Dropped when the
  identity is locked: there is no journal to write to.
  """
  @spec record(String.t(), row()) :: :ok
  def record(username, %{} = row) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, row})
    end
  end

  @doc """
  Keeps an exchange (`MWTClient.Sandbox.Exchange`) to be written with the
  next batch, for every event that names `exchange_id`: none, and it isn't
  kept.
  """
  @spec record_exchange(String.t(), String.t(), map()) :: :ok
  def record_exchange(username, exchange_id, exchange) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:exchange, exchange_id, Values.term(exchange)})
    end
  end

  @doc """
  Keeps an event's details (`MWTClient.Sandbox.EventDetails`) to be
  written with the next batch, after the event itself, which is recorded
  first.
  """
  @spec record_details(String.t(), String.t(), list()) :: :ok
  def record_details(username, event_id, details) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:details, event_id, Values.term(details)})
    end
  end

  @doc """
  Keeps a card you decided, or that timed out (`MWTClient.Sandbox.Approval`),
  whole, to be written with the next batch: what a line whose decision
  names it opens, read-only (`MWTClient.Sandbox.Decision`). Kept again
  under the same id, the later one stays.
  """
  @spec record_card(String.t(), String.t(), struct()) :: :ok
  def record_card(username, id, card) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:kept, {:card, id, now(), Values.term(card)}})
    end
  end

  defp now, do: Values.time(DateTime.utc_now())

  @doc "A card kept by `record_card/3`, or nil: never kept, or gone with every line naming it."
  @spec card(String.t(), String.t()) :: struct() | nil
  def card(username, id), do: kept(username, "SELECT card FROM events_cards WHERE id = ?", id)

  defp kept(username, query, id) do
    :ok = flush(username)

    Storage.run(username, :journal, fn repo ->
      case repo.query!(query, [id]).rows do
        [[blob]] -> Values.from_term(blob)
        [] -> nil
      end
    end)
  end

  @doc "The details kept for an event, or nil: none were, or they are gone with it."
  @spec details(String.t(), String.t()) :: list() | nil
  def details(username, event_id) do
    :ok = flush(username)

    Storage.run(username, :journal, fn repo ->
      case repo.query!("SELECT details FROM events_details WHERE event_id = ?", [event_id]).rows do
        [[blob]] -> Values.from_term(blob)
        [] -> nil
      end
    end)
  end

  @doc """
  The exchange kept for an event, or nil: none was, or it is gone with its
  event.
  """
  @spec exchange(String.t(), String.t()) :: map() | nil
  def exchange(username, event_id) do
    :ok = flush(username)

    Storage.run(username, :journal, fn repo ->
      case repo.query!("SELECT exchange FROM events_exchanges WHERE event_id = ?", [event_id]).rows do
        [[blob]] -> Values.from_term(blob)
        [] -> nil
      end
    end)
  end

  @doc "Writes every row waiting now, and returns once they are written."
  @spec flush(String.t()) :: :ok
  def flush(username) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, :infinity)
    end
  end

  @doc """
  Applies the `agent_activity` retention rule (`MWTClient.Storage.Retention`)
  as of `now`: events from before `:days` ago go, then the oldest until
  they take at most `:gb`. In batches, so a sweep never holds the journal
  long. Returns how many went.
  """
  @spec trim(String.t(), map(), DateTime.t()) :: non_neg_integer()
  def trim(username, rule, now) do
    :ok = flush(username)

    by_age =
      case rule[:days] do
        nil -> 0
        days -> delete_before(username, Values.time(DateTime.add(now, -days, :day)), 0)
      end

    by_size = if rule[:gb], do: trim_to(username, rule.gb * 1_000_000_000, 0), else: 0
    if by_age + by_size > 0, do: unnamed_gone(username)
    by_age + by_size
  end

  # The cards no line names any more.
  defp unnamed_gone(username) do
    Storage.run(username, :journal, fn repo ->
      repo.query!(
        "DELETE FROM events_cards WHERE id NOT IN (SELECT card_id FROM events WHERE card_id IS NOT NULL)"
      )
    end)

    :ok
  end

  defp delete_before(username, cutoff, removed) do
    batch =
      Storage.run(username, :journal, fn repo ->
        repo.query!(
          "DELETE FROM events WHERE seq IN (SELECT seq FROM events WHERE at < ? ORDER BY seq LIMIT ?)",
          [cutoff, @trim_batch]
        ).num_rows
      end)

    if batch == @trim_batch,
      do: delete_before(username, cutoff, removed + batch),
      else: removed + batch
  end

  # A few rounds at most: each removes the oldest share the excess is of
  # what the events take, and measures again.
  defp trim_to(_username, _limit, 3), do: 0

  defp trim_to(username, limit, round) do
    bytes =
      if Usage.file_bytes(username, :journal) <= limit,
        do: 0,
        else: Usage.group_bytes(username, :journal, "events")

    if bytes <= limit do
      0
    else
      [[count]] = Storage.run(username, :journal, & &1.query!("SELECT count(*) FROM events").rows)
      excess = ceil(count * (bytes - limit) / bytes) + 1

      [[cutoff]] =
        Storage.run(username, :journal, fn repo ->
          repo.query!(
            "SELECT coalesce(max(at), 0) + 1 FROM (SELECT at FROM events ORDER BY seq LIMIT ?)",
            [
              excess
            ]
          ).rows
        end)

      removed = delete_before(username, cutoff, 0)
      if removed == 0, do: 0, else: removed + trim_to(username, limit, round + 1)
    end
  end

  @impl true
  def init(username) do
    # So that `terminate/2` writes what waits when the identity locks.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       username: username,
       rows: [],
       exchanges: [],
       details: [],
       # Cards to keep, `{:card, id, at, blob}`.
       kept: [],
       count: 0,
       bytes: 0,
       timer: nil,
       # Writes failed in a row, and why the last one did.
       failures: 0,
       failed: nil,
       # What was dropped and not yet said in the log: how many events,
       # exchanges and details, the times of the first and last event,
       # and why.
       lost: nil
     }}
  end

  @impl true
  def handle_cast({:record, row}, state),
    do: waiting(%{state | rows: [row | state.rows], count: state.count + 1})

  def handle_cast({:exchange, exchange_id, {:blob, blob}}, state) do
    waiting(%{
      state
      | exchanges: [{exchange_id, blob} | state.exchanges],
        count: state.count + 1,
        bytes: state.bytes + byte_size(blob)
    })
  end

  def handle_cast({:kept, record}, state) do
    blob = elem(record, tuple_size(record) - 1) |> elem(1)

    waiting(%{
      state
      | kept: [record | state.kept],
        count: state.count + 1,
        bytes: state.bytes + byte_size(blob)
    })
  end

  def handle_cast({:details, event_id, {:blob, blob}}, state) do
    waiting(%{
      state
      | details: [{event_id, blob} | state.details],
        count: state.count + 1,
        bytes: state.bytes + byte_size(blob)
    })
  end

  # While writes fail, a full batch waits for the next try rather than
  # trying again at every row: each try can wait out the busy timeout.
  defp waiting(state) do
    cond do
      state.failures > 0 and over_kept?(state) ->
        {:noreply, state |> drop() |> scheduled()}

      state.failures > 0 ->
        {:noreply, scheduled(state)}

      state.count >= @batch or state.bytes >= @batch_bytes ->
        {:noreply, write(state)}

      true ->
        {:noreply, scheduled(state)}
    end
  end

  defp scheduled(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :write, @every_ms)}

  defp scheduled(state), do: state

  defp over_kept?(state), do: state.count > @kept_most or state.bytes > @kept_bytes

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_info(:write, state), do: {:noreply, write(%{state | timer: nil})}

  @impl true
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp write(%{rows: [], exchanges: [], details: [], kept: [], lost: nil} = state),
    do: cancel(state)

  defp write(state) do
    state = cancel(state)
    rows = Enum.reverse(state.rows)
    exchanges = Enum.reverse(state.exchanges)
    details = Enum.reverse(state.details)
    kept = Enum.reverse(state.kept)

    try do
      Storage.transaction(state.username, :journal, fn repo ->
        if state.lost, do: insert(repo, [lost_row(state.lost)])
        for chunk <- Enum.chunk_every(rows, 40), do: insert(repo, chunk)
        for {exchange_id, blob} <- exchanges, do: insert_exchange(repo, exchange_id, blob)
        for {event_id, blob} <- details, do: insert_details(repo, event_id, blob)
        for record <- kept, do: insert_kept(repo, record)
      end)

      if state.lost do
        Logger.warning("activity log written again; #{state.lost.events} events weren't kept",
          user: state.username,
          system: :storage
        )
      end

      %{
        state
        | rows: [],
          exchanges: [],
          details: [],
          kept: [],
          count: 0,
          bytes: 0,
          failures: 0,
          failed: nil,
          lost: nil
      }
    rescue
      error -> failed(state, length(rows), Exception.message(error))
    end
  end

  # Kept for the next try, in order; dropped once tried enough.
  defp failed(state, events, reason) do
    failures = state.failures + 1

    Logger.error(
      "could not write #{events} activity events (try #{failures} of #{@tries}): #{reason}",
      user: state.username,
      system: :storage
    )

    state = %{state | failures: failures, failed: reason}
    state = if failures >= @tries or over_kept?(state), do: drop(state), else: state
    scheduled(state)
  end

  # What waits goes, and is added to the gap the log will say.
  defp drop(%{rows: rows, exchanges: exchanges, details: details, kept: kept} = state) do
    times = for row <- rows, is_integer(row[:at]), do: row.at
    reason = state.failed || "unknown"

    lost =
      merge_lost(state.lost, %{
        events: length(rows),
        exchanges: length(exchanges),
        details: length(details) + length(kept),
        from: Enum.min(times, fn -> nil end),
        to: Enum.max(times, fn -> nil end),
        why: reason |> String.split("\n", parts: 2) |> hd() |> String.slice(0, @reason_chars)
      })

    Logger.error(
      "dropped #{length(rows)} activity events the journal couldn't take: #{reason}",
      user: state.username,
      system: :storage
    )

    %{
      state
      | rows: [],
        exchanges: [],
        details: [],
        kept: [],
        count: 0,
        bytes: 0,
        failures: 0,
        lost: lost
    }
  end

  defp merge_lost(nil, lost), do: lost

  defp merge_lost(before, lost) do
    %{
      events: before.events + lost.events,
      exchanges: before.exchanges + lost.exchanges,
      details: before.details + lost.details,
      from: earliest(before.from, lost.from),
      to: latest(before.to, lost.to),
      why: lost.why
    }
  end

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: min(a, b)

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: max(a, b)

  # The gap as a line of the log, at the time of the first event lost, so
  # a window that covers them shows it. Its outcome, `lost`, says what it
  # is to whatever reads the journal (`MWTClient.Sandbox.Event`).
  defp lost_row(lost) do
    from = lost.from || Values.time(DateTime.utc_now())
    to = lost.to || from

    what =
      if lost.events == 1,
        do: "event of the activity log wasn't",
        else: "events of the activity log weren't"

    summary =
      "#{lost.events} #{what} kept, from #{clock(from)} to #{clock(to)} UTC: " <>
        "the journal couldn't be written (#{lost.why})"

    %{
      id: "event-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      at: from,
      outcome: "lost",
      summary: summary,
      search_text: String.downcase(summary),
      detailed: 0
    }
  end

  defp clock(at), do: at |> Values.from_time() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  # Only for an event that was written: one dropped leaves none behind.
  defp insert_details(repo, event_id, blob) do
    repo.query!(
      """
      INSERT INTO events_details (event_id, details)
      SELECT id, ? FROM events WHERE id = ?
      ON CONFLICT (event_id) DO NOTHING
      """,
      [{:blob, blob}, event_id]
    )
  end

  # A card kept again replaces the one before: a later state of it.
  defp insert_kept(repo, {:card, id, at, blob}) do
    repo.query!(
      """
      INSERT INTO events_cards (id, at, card) VALUES (?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET at = excluded.at, card = excluded.card
      """,
      [id, at, blob]
    )
  end

  # Once for each event that names it; for none, nothing.
  defp insert_exchange(repo, exchange_id, blob) do
    repo.query!(
      """
      INSERT INTO events_exchanges (event_id, exchange)
      SELECT id, ? FROM events WHERE exchange_id = ?
      ON CONFLICT (event_id) DO NOTHING
      """,
      [{:blob, blob}, exchange_id]
    )
  end

  # Forty rows to a statement, under SQLite's limit on parameters. An id
  # recorded twice is written once.
  defp insert(repo, rows) do
    one = "(" <> Enum.map_join(@columns, ", ", fn _column -> "?" end) <> ")"

    repo.query!(
      """
      INSERT INTO events (#{Enum.join(@columns, ", ")})
      VALUES #{Enum.map_join(rows, ", ", fn _row -> one end)}
      ON CONFLICT (id) DO NOTHING
      """,
      for(row <- rows, column <- @columns, do: column_value(row, column))
    )
  end

  # A row that doesn't say has no details.
  defp column_value(row, :detailed), do: Map.get(row, :detailed, 0)
  defp column_value(row, column), do: Map.get(row, column)

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
