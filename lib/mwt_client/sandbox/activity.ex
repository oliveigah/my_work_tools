defmodule MWTClient.Sandbox.Activity do
  @moduledoc """
  The activity log, read from the journal: every event the sandbox logged
  (`MWTClient.Sandbox.Event`), kept in the identity's `journal.db` for as
  long as its retention rule says, rather than the last 1,000 in memory.

  Reads run in the caller. Each first lets the sandbox's server take the
  events sent to it before, then writes what the journal still holds in
  memory (`MWTClient.Storage.Journal.flush/1`), so it sees every event
  logged before it was asked, as when the server kept them.

  The filters, any of which can be left out:

    * `:group` - a key of `Event.groups/0`, or `"all"`;
    * `:grant` - a grant's id, or `""`;
    * `:q` - words to look for in the summary, host, path and method,
      as one piece, whatever their case;
    * `:thread` - the id of the thread that asked, or `""`;
    * `:since` - the oldest time to include, a `DateTime`, or nil;
    * `:before` - an event's id: only what was logged before it;
    * `:limit` - how many, the newest first (200 when left out).
  """

  alias MWTClient.Sandbox.Event
  alias MWTClient.Sandbox.EventStats
  alias MWTClient.Sandbox.Server
  alias MWTClient.Storage
  alias MWTClient.Storage.Journal
  alias MWTClient.Storage.Values

  # The most events the figures are worked out over; past it, the oldest
  # of the window are left out of them, not of the log.
  @stats_most 20_000

  @doc "The events passing `filters`, the newest first."
  @spec events(String.t(), map()) :: [Event.t()]
  def events(username, filters \\ %{}), do: read(username, filters, &query/3)

  @doc """
  `events/2` for the sandbox's server itself, which can't wait on itself:
  what it logged before is with the journal already, as it sent it there
  first.
  """
  @spec logged(String.t(), map()) :: [Event.t()]
  def logged(username, filters \\ %{}), do: read(username, filters, &query_logged/3)

  @doc """
  One event, opened: with what its request carried and got back
  (`MWTClient.Sandbox.Exchange`) in `exchange`, `:none` when nothing of it
  was kept (yet), or nil for an event of no such request. Nil when the
  event is gone from the journal.
  """
  @spec opened(String.t(), String.t()) :: Event.t() | nil
  def opened(username, id) do
    sql = "SELECT #{Enum.join(Event.columns(), ", ")} FROM events WHERE id = ?"

    case query(username, sql, [id]) do
      [row] ->
        event = Event.from_row(row)
        %{event | exchange: event.exchange_id && (Journal.exchange(username, id) || :none)}

      [] ->
        nil
    end
  end

  defp read(username, filters, query) do
    {conditions, params} = where(filters)

    username
    |> query.(
      """
      SELECT #{Enum.join(Event.columns(), ", ")} FROM events
      WHERE #{conditions} ORDER BY seq DESC LIMIT ?
      """,
      params ++ [Map.get(filters, :limit, 200)]
    )
    |> Enum.map(&Event.from_row/1)
  end

  @doc """
  The activity page's figures (`MWTClient.Sandbox.EventStats`) over the
  events passing `filters`, `:group`, `:before` and `:limit` aside: the
  group chooses what the totals count. The timeline runs from `:since`, or
  from the oldest event kept, to `now`.
  """
  @spec stats(String.t(), map(), DateTime.t()) :: EventStats.t()
  def stats(username, filters, now) do
    {conditions, params} =
      filters |> Map.drop([:before, :limit]) |> Map.put(:group, "all") |> where()

    events =
      username
      |> query(
        "SELECT outcome, at, host, up, down FROM events WHERE #{conditions} ORDER BY seq DESC LIMIT ?",
        params ++ [@stats_most]
      )
      |> Enum.map(fn [outcome, at, host, up, down] ->
        %{
          outcome: Event.outcome(outcome),
          at: Values.from_time(at),
          host: host,
          up: up,
          down: down
        }
      end)

    oldest =
      case Map.get(filters, :since) do
        %DateTime{} = since ->
          since

        nil ->
          case query(username, "SELECT at FROM events ORDER BY seq LIMIT 1", []) do
            [[at]] -> Values.from_time(at)
            [] -> nil
          end
      end

    EventStats.summarize(events, Map.get(filters, :group, "all"), oldest, now)
  end

  @doc """
  The threads that asked for something within `:since` (as `events/2`
  reads it), the most recent first: `%{id, title, agent}`, the title and
  agent each the latest one a thread's events named.
  """
  @spec threads(String.t(), map()) :: [
          %{id: String.t(), title: String.t() | nil, agent: String.t() | nil}
        ]
  def threads(username, filters \\ %{}) do
    {conditions, params} = where(Map.take(filters, [:since]))

    username
    |> query(
      """
      SELECT thread_id,
        (SELECT thread FROM events named WHERE named.thread_id = e.thread_id
           AND named.thread IS NOT NULL ORDER BY seq DESC LIMIT 1),
        (SELECT agent FROM events named WHERE named.thread_id = e.thread_id
           AND named.agent IS NOT NULL ORDER BY seq DESC LIMIT 1)
      FROM events e
      WHERE thread_id IS NOT NULL AND #{conditions}
      GROUP BY thread_id ORDER BY max(seq) DESC
      """,
      params
    )
    |> Enum.map(fn [id, title, agent] -> %{id: id, title: title, agent: agent} end)
  end

  defp query(username, sql, params) do
    :ok = Server.call(username, :logged)
    query_logged(username, sql, params)
  end

  defp query_logged(username, sql, params) do
    :ok = Journal.flush(username)
    Storage.run(username, :journal, & &1.query!(sql, params).rows)
  end

  defp where(filters) do
    term = filters |> Map.get(:q, "") |> String.trim() |> String.downcase()

    [
      case Map.get(Event.groups(), Map.get(filters, :group, "all")) do
        nil ->
          nil

        outcomes ->
          names = Enum.map(outcomes, &Atom.to_string/1)
          {"outcome IN (#{Enum.map_join(names, ", ", fn _ -> "?" end)})", names}
      end,
      blank_or(Map.get(filters, :grant, ""), &{"grant_id = ?", [&1]}),
      blank_or(term, &{"instr(search_text, ?) > 0", [&1]}),
      blank_or(Map.get(filters, :thread, ""), &{"thread_id = ?", [&1]}),
      case Map.get(filters, :since) do
        %DateTime{} = since -> {"at >= ?", [Values.time(since)]}
        nil -> nil
      end,
      # An id no longer kept leaves nothing older.
      case Map.get(filters, :before) do
        nil -> nil
        id -> {"seq < (SELECT seq FROM events WHERE id = ?)", [id]}
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        {"1", []}

      conditions ->
        {Enum.map_join(conditions, " AND ", &elem(&1, 0)),
         Enum.flat_map(conditions, &elem(&1, 1))}
    end
  end

  defp blank_or(value, _fun) when value in [nil, ""], do: nil
  defp blank_or(value, fun), do: fun.(value)
end
