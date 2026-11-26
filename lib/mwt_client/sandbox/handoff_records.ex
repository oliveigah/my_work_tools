defmodule MWTClient.Sandbox.HandoffRecords do
  @archive_after_days 30

  @moduledoc """
  Every handoff of one identity, kept for good in its encrypted
  `library.db` (`MWTClient.Storage.Migrations.LibraryHandoffs`): one row
  each, written whole when it changes, and searched through a trigram
  index, as notes are (`MWTClient.Search.where/4`).

  The sandbox (`MWTClient.Sandbox.Server`) writes them, one at a time, in
  its own process, so two changes of one handoff never cross; it keeps
  only those waiting for you in memory. Reads run in the process that
  asks, straight from the database: a page of the list, one handoff, the
  latest of a branch.

  A handoff is **archived** once it landed or was closed more than
  #{@archive_after_days} days before: the list leaves it out unless asked to include it.
  Nothing moves when it is: it is a date the queries compare, the date
  it changed last (`changed_at/1`). One waiting for you is never
  archived, however old: hiding it would hide a decision still yours.
  """

  alias MWTClient.Sandbox.Handoff
  alias MWTClient.Search
  alias MWTClient.Storage
  alias MWTClient.Storage.Values

  @typedoc "Which half of the list: those waiting for you, or those landed or closed."
  @type half :: :waiting | :done

  @typedoc """
  What a page of the list asks: its `half`; the `terms` every handoff
  shown holds (`MWTClient.Search.terms/1`); whether archived ones count
  (`archived?`), and then only those changed from `from` until before
  `to`, either nil for no bound; which `page`, `per_page` rows each; and
  `now`, which says what is archived.
  """
  @type query :: %{
          half: half(),
          terms: [String.t()],
          archived?: boolean(),
          from: DateTime.t() | nil,
          to: DateTime.t() | nil,
          page: integer(),
          per_page: pos_integer(),
          now: DateTime.t()
        }

  @typedoc """
  A page of the list: its handoffs, newest first; how many of each half
  the query finds, whichever half it shows; the page shown, kept within
  the pages there are, and how many pages there are.
  """
  @type page :: %{
          handoffs: [Handoff.t()],
          waiting: non_neg_integer(),
          done: non_neg_integer(),
          page: pos_integer(),
          pages: pos_integer()
        }

  @doc "How many days after it landed or was closed a handoff is archived."
  @spec archive_after_days() :: pos_integer()
  def archive_after_days, do: @archive_after_days

  @doc "When the handoff changed last: handed off, landed, closed, reopened."
  @spec changed_at(Handoff.t()) :: DateTime.t()
  def changed_at(%Handoff{} = handoff), do: handoff.updated_at || handoff.opened_at

  @doc "Whether the handoff is archived at `now`."
  @spec archived?(Handoff.t(), DateTime.t()) :: boolean()
  def archived?(%Handoff{} = handoff, %DateTime{} = now) do
    not Handoff.waiting?(handoff) and
      DateTime.compare(changed_at(handoff), cutoff(now)) == :lt
  end

  defp cutoff(now), do: DateTime.add(now, -@archive_after_days, :day)

  ## Writing

  @doc """
  Keeps a handoff, new or changed, made durable before it returns. Only the
  sandbox writes, from its own process.
  """
  @spec put(String.t(), Handoff.t()) :: :ok
  def put(username, %Handoff{} = handoff) do
    Storage.transaction(username, :library, &write(&1, handoff, :replace))
  end

  @doc """
  Keeps those of `handoffs` not kept yet, in one transaction, as when
  they move here from the `sandbox` document they were part of. One kept
  already stays as it is: what was written here is newer than any copy
  from before, so an import cut short is safe to make again.
  """
  @spec import(String.t(), [Handoff.t()]) :: :ok
  def import(_username, []), do: :ok

  def import(username, handoffs) do
    Storage.transaction(username, :library, fn repo ->
      Enum.each(handoffs, &write(repo, &1, :keep))
    end)
  end

  defp write(repo, handoff, how) do
    conflict =
      case how do
        :replace ->
          """
          DO UPDATE SET project = excluded.project, branch = excluded.branch,
            waiting = excluded.waiting, opened_at = excluded.opened_at,
            changed_at = excluded.changed_at
          """

        :keep ->
          "DO NOTHING"
      end

    rows =
      repo.query!(
        """
        INSERT INTO handoffs (id, project, branch, waiting, opened_at, changed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) #{conflict}
        RETURNING seq
        """,
        [
          handoff.id,
          handoff.project,
          handoff.source.branch,
          if(Handoff.waiting?(handoff), do: 1, else: 0),
          Values.time(handoff.opened_at),
          Values.time(changed_at(handoff))
        ]
      ).rows

    case rows do
      # Kept already, and `:keep` leaves it.
      [] ->
        :ok

      [[seq]] ->
        repo.query!(
          """
          INSERT INTO handoff_records (seq, record, search_text) VALUES (?, ?, ?)
          ON CONFLICT (seq) DO UPDATE SET record = excluded.record,
            search_text = excluded.search_text
          """,
          [seq, Values.term(handoff), Handoff.search_text(handoff)]
        )

        :ok
    end
  end

  ## Reading

  @doc "The handoff numbered `id`."
  @spec get(String.t(), pos_integer()) :: {:ok, Handoff.t()} | :error
  def get(username, id) when is_integer(id) do
    case records(username, "WHERE h.id = ?", [id]) do
      [handoff] -> {:ok, handoff}
      [] -> :error
    end
  end

  @doc "The handoffs waiting for you: open or taken back. Newest first."
  @spec waiting(String.t()) :: [Handoff.t()]
  def waiting(username),
    do: records(username, "WHERE h.waiting = 1 ORDER BY h.changed_at DESC, h.id DESC", [])

  @doc "The latest handoff from `branch` of the project named `project`, or nil."
  @spec latest(String.t(), String.t(), String.t()) :: Handoff.t() | nil
  def latest(username, project, branch) do
    case records(
           username,
           "WHERE h.project = ? AND h.branch = ? ORDER BY h.id DESC LIMIT 1",
           [project, branch]
         ) do
      [handoff] -> handoff
      [] -> nil
    end
  end

  @doc """
  The handoffs of the project named `project` that aren't archived at
  `now`, newest first: what an agent there is told of.
  """
  @spec current(String.t(), String.t(), DateTime.t()) :: [Handoff.t()]
  def current(username, project, now) do
    records(
      username,
      """
      WHERE h.project = ? AND (h.waiting = 1 OR h.changed_at >= ?)
      ORDER BY h.id DESC
      """,
      [project, Values.time(cutoff(now))]
    )
  end

  @doc "The numbers of every handoff kept, in order."
  @spec ids(String.t()) :: [pos_integer()]
  def ids(username) do
    Storage.run(username, :library, fn repo ->
      repo.query!("SELECT id FROM handoffs ORDER BY id").rows
    end)
    |> List.flatten()
  end

  @doc "The highest number a kept handoff has, 0 with none."
  @spec max_id(String.t()) :: non_neg_integer()
  def max_id(username) do
    Storage.run(username, :library, fn repo ->
      [[max]] = repo.query!("SELECT coalesce(max(id), 0) FROM handoffs").rows
      max
    end)
  end

  @doc """
  A page of the list, as `t:query/0` asks: its handoffs and how many each
  half finds. Both halves are counted with the same words and dates, so
  each tab can say what it would show.
  """
  @spec page(String.t(), query()) :: page()
  def page(username, %{half: half, page: page, per_page: per_page} = query)
      when half in [:waiting, :done] and is_integer(page) and per_page > 0 do
    {scope, scope_params} = scope(query)

    {matching, search_params} =
      Search.where("h.seq", "handoff_search", "handoff_records", query.terms)

    where = "WHERE #{scope} AND #{matching}"
    params = scope_params ++ search_params

    Storage.run(username, :library, fn repo ->
      counts =
        repo.query!(
          "SELECT h.waiting, count(*) FROM handoffs h #{where} GROUP BY h.waiting",
          params
        ).rows
        |> Map.new(fn [waiting, count] -> {waiting, count} end)

      waiting = Map.get(counts, 1, 0)
      done = Map.get(counts, 0, 0)
      total = if half == :waiting, do: waiting, else: done
      pages = max(div(total + per_page - 1, per_page), 1)
      page = page |> max(1) |> min(pages)

      handoffs =
        repo.query!(
          """
          SELECT r.record FROM handoffs h JOIN handoff_records r USING (seq)
          #{where} AND h.waiting = ?
          ORDER BY h.changed_at DESC, h.id DESC LIMIT ? OFFSET ?
          """,
          params ++ [if(half == :waiting, do: 1, else: 0), per_page, (page - 1) * per_page]
        ).rows
        |> Enum.map(fn [record] -> read(record) end)

      %{handoffs: handoffs, waiting: waiting, done: done, page: page, pages: pages}
    end)
  end

  # Which handoffs the list considers: without the archived ones, those
  # waiting and those changed since the cutoff; with them, every one, or
  # those changed within the dates given.
  defp scope(%{archived?: false, now: now}),
    do: {"(h.waiting = 1 OR h.changed_at >= ?)", [Values.time(cutoff(now))]}

  defp scope(%{archived?: true} = query) do
    bounds =
      [{"h.changed_at >= ?", query[:from]}, {"h.changed_at < ?", query[:to]}]
      |> Enum.reject(fn {_condition, at} -> is_nil(at) end)

    case bounds do
      [] ->
        {"1", []}

      bounds ->
        {Enum.map_join(bounds, " AND ", &elem(&1, 0)),
         Enum.map(bounds, &Values.time(elem(&1, 1)))}
    end
  end

  defp records(username, rest, params) do
    Storage.run(username, :library, fn repo ->
      repo.query!(
        "SELECT r.record FROM handoffs h JOIN handoff_records r USING (seq) #{rest}",
        params
      ).rows
    end)
    |> Enum.map(fn [record] -> read(record) end)
  end

  # What MWT wrote, brought up to date when an older MWT wrote it.
  defp read(record), do: record |> Values.from_term() |> Handoff.upgrade()
end
