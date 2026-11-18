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
  written at once too. `flush/1` writes what waits now, so a
  read that follows sees everything recorded before it. Locking writes
  what waits before the databases close.

  `journal.db` runs with `synchronous=NORMAL`: a power cut can lose the
  last second, never the file's consistency.

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

  @columns ~w(id at outcome summary grant_id host port method path up down ms agent thread_id
              thread exchange_id search_text)a

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
    by_age + by_size
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
    {:ok, %{username: username, rows: [], exchanges: [], count: 0, bytes: 0, timer: nil}}
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

  defp waiting(state) do
    cond do
      state.count >= @batch or state.bytes >= @batch_bytes ->
        {:noreply, write(state)}

      state.timer == nil ->
        {:noreply, %{state | timer: Process.send_after(self(), :write, @every_ms)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_info(:write, state), do: {:noreply, write(%{state | timer: nil})}

  @impl true
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp write(%{rows: [], exchanges: []} = state), do: cancel(state)

  defp write(state) do
    rows = Enum.reverse(state.rows)
    exchanges = Enum.reverse(state.exchanges)

    try do
      Storage.transaction(state.username, :journal, fn repo ->
        for chunk <- Enum.chunk_every(rows, 50), do: insert(repo, chunk)
        for {exchange_id, blob} <- exchanges, do: insert_exchange(repo, exchange_id, blob)
      end)
    rescue
      error ->
        Logger.error(
          "could not write #{length(rows)} activity events: #{Exception.message(error)}",
          user: state.username,
          system: :storage
        )
    end

    cancel(%{state | rows: [], exchanges: [], count: 0, bytes: 0})
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

  # Fifty rows to a statement, under SQLite's limit on parameters. An id
  # recorded twice is written once.
  defp insert(repo, rows) do
    one = "(" <> Enum.map_join(@columns, ", ", fn _column -> "?" end) <> ")"

    repo.query!(
      """
      INSERT INTO events (#{Enum.join(@columns, ", ")})
      VALUES #{Enum.map_join(rows, ", ", fn _row -> one end)}
      ON CONFLICT (id) DO NOTHING
      """,
      for(row <- rows, column <- @columns, do: Map.get(row, column))
    )
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
