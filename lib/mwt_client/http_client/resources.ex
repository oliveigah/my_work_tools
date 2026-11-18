defmodule MWTClient.HttpClient.Resources do
  @moduledoc """
  Owns one identity's request history: requests sent, and samples saved
  but never sent, numbered in one sequence and listed together.

  They are kept in the identity's `journal.db` (`MWTClient.Storage`),
  encrypted on disk with the rest of it, an entry in three rows
  (`MWTClient.Storage.Migrations.JournalHttpHistory`): what a list shows,
  what an open entry shows, and the response. So recording one entry
  writes that entry, whatever the history holds, a list never reads a
  body, and opening an entry reads its response only through `get/2`.

  Every function takes the username the history belongs to, and runs in
  the process that calls it, as one statement or one transaction: reading
  never waits on a write. Only `rewrite/2` goes through this process, one
  per unlocked identity, so two rewrites can't interleave. It also
  imports, at its first start, a history kept in `http_history.bin` from
  before `journal.db`, then moves the file into `legacy/`
  (`MWTClient.Storage.Legacy`).

  Changes are broadcast to the processes that `subscribe/1`, all but the
  one that made them, once they are written.
  """

  use GenServer

  alias MWTClient.Accounts
  alias MWTClient.HttpClient.HistoryMetadata
  alias MWTClient.HttpClient.Utils
  alias MWTClient.Search
  alias MWTClient.Storage
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Usage
  alias MWTClient.Storage.Values
  alias MWTClient.Vault.Store

  @legacy_file "http_history.bin"

  @type history_id :: pos_integer()
  @type metadata :: HistoryMetadata.t()
  @typedoc "Nil marks a saved request sample that has never been sent."
  @type response :: Req.Response.t() | Exception.t() | nil
  @type entry :: {history_id(), metadata(), Req.Request.t(), response()}
  @typedoc "An entry without the identifier the history gave it."
  @type history_data :: {metadata(), Req.Request.t(), response()}
  @type outline ::
          {history_id(), metadata(), Req.Request.t(),
           {:response, non_neg_integer(), map(), non_neg_integer()}
           | {:error, Exception.t()}
           | :sample}
  @type summary ::
          {history_id(), String.t() | nil, [String.t()], DateTime.t(), non_neg_integer() | nil,
           atom(), URI.t(), non_neg_integer()}

  @doc "Starts the history owner for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes to `:http_history_changed`, sent when another process changes the history."
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  @doc "Stores a completed request or an unsent sample and returns its unique identifier."
  @spec record(String.t(), metadata(), Req.Request.t(), response()) :: history_id()
  def record(username, %HistoryMetadata{} = metadata, %Req.Request{} = request, response) do
    # Encoded before the transaction, so the write lock is held only to write.
    row = row(HistoryMetadata.with_search_text(metadata, request, response), request, response)
    identifier = Storage.transaction(username, :journal, &insert(&1, nil, row))
    broadcast(username, self())
    identifier
  end

  @doc """
  Changes the metadata of one entry with `fun`, and its search text with
  it, in one transaction. Returns the entry as it is now.
  """
  @spec update(String.t(), history_id(), (metadata() -> metadata())) :: {:ok, entry()} | :error
  def update(username, identifier, fun) when is_function(fun, 1) do
    result =
      Storage.transaction(username, :journal, fn repo ->
        with {:ok, {^identifier, metadata, request, response}} <- fetch(repo, identifier) do
          metadata =
            metadata |> fun.() |> HistoryMetadata.with_search_text(request, response)

          repo.query!("UPDATE http_requests SET description = ?, tags = ? WHERE id = ?", [
            metadata.description,
            Values.strings(metadata.tags),
            identifier
          ])

          repo.query!(
            "UPDATE http_request_details SET metadata = ?, search_text = ? WHERE id = ?",
            [kept_metadata(metadata), metadata.search_text, identifier]
          )

          {:ok, {identifier, metadata, request, response}}
        end
      end)

    if result != :error, do: broadcast(username, self())
    result
  end

  @doc "Returns all recorded request history entries, newest first."
  @spec all(String.t()) :: [entry()]
  def all(username), do: entries(username, "ORDER BY r.id DESC", [])

  @doc """
  Returns history entries whose search text holds the given term, as one
  piece, spaces and all, newest first.
  """
  @spec search(String.t(), String.t()) :: [entry()]
  def search(username, term) when is_binary(term) do
    {matching, params} = matching(term)
    entries(username, "WHERE #{matching} ORDER BY r.id DESC", params)
  end

  @doc "What a list shows of the entries `search/2` finds, newest first: never a body."
  @spec summaries(String.t(), String.t()) :: [summary()]
  def summaries(username, term \\ "") when is_binary(term) do
    {matching, params} = matching(term)

    Storage.run(username, :journal, fn repo ->
      repo.query!(
        """
        SELECT id, description, tags, completed_at, duration_ms, method, url, status
        FROM http_requests r WHERE #{matching} ORDER BY id DESC
        """,
        params
      ).rows
    end)
    |> Enum.map(fn [id, description, tags, completed_at, duration_ms, method, url, status] ->
      {id, description, Values.from_strings(tags), Values.from_time(completed_at), duration_ms,
       method(method), URI.parse(url), status}
    end)
  end

  @doc "Returns one recorded request history entry, if it exists."
  @spec get(String.t(), history_id()) :: {:ok, entry()} | :error
  def get(username, identifier), do: Storage.run(username, :journal, &fetch(&1, identifier))

  @doc "Returns one entry without reading its response body."
  @spec outline(String.t(), history_id()) :: {:ok, outline()} | :error
  def outline(username, identifier) do
    Storage.run(username, :journal, fn repo ->
      repo.query!(
        """
        SELECT d.metadata, d.search_text, d.request, d.outline
        FROM http_request_details d WHERE d.id = ?
        """,
        [identifier]
      ).rows
    end)
    |> case do
      [[metadata, search_text, request, outline]] ->
        {:ok,
         {identifier, metadata(metadata, search_text), Values.from_term(request),
          Values.from_term(outline)}}

      [] ->
        :error
    end
  end

  @doc "Deletes one recorded request history entry."
  @spec delete(String.t(), history_id()) :: :ok | :error
  def delete(username, identifier) do
    Storage.run(username, :journal, fn repo ->
      repo.query!("DELETE FROM http_requests WHERE id = ? RETURNING id", [identifier]).rows
    end)
    |> case do
      [_deleted] ->
        broadcast(username, self())
        :ok

      [] ->
        :error
    end
  end

  @doc """
  Clears this identity's request history. Identifiers go on from where
  they were, so one held from before finds nothing rather than another
  request.
  """
  @spec clear(String.t()) :: :ok
  def clear(username) do
    Storage.run(username, :journal, & &1.query!("DELETE FROM http_requests"))
    broadcast(username, self())
    :ok
  end

  @doc """
  Applies the `http_history` retention rule (`MWTClient.Storage.Retention`)
  as of `now`: requests completed before `:days` ago go, then the oldest
  until the history takes at most `:gb`. Samples never sent stay. Returns
  how many went.
  """
  @spec trim(String.t(), map(), DateTime.t()) :: non_neg_integer()
  def trim(username, rule, now) do
    by_age =
      case rule[:days] do
        nil ->
          0

        days ->
          cutoff = Values.time(DateTime.add(now, -days, :day))

          Storage.run(username, :journal, fn repo ->
            repo.query!("DELETE FROM http_requests WHERE status != 0 AND completed_at < ?", [
              cutoff
            ]).num_rows
          end)
      end

    by_size = if rule[:gb], do: trim_to(username, rule.gb * 1_000_000_000, 0), else: 0
    if by_age + by_size > 0, do: broadcast(username, self())
    by_age + by_size
  end

  # A few rounds at most: each removes the oldest share the excess is of
  # what the history takes, and measures again.
  defp trim_to(_username, _limit, 3), do: 0

  defp trim_to(username, limit, round) do
    if Usage.file_bytes(username, :journal) <= limit do
      0
    else
      bytes = Usage.group_bytes(username, :journal, "http")

      if bytes <= limit do
        0
      else
        removed =
          Storage.run(username, :journal, fn repo ->
            [[sent]] = repo.query!("SELECT count(*) FROM http_requests WHERE status != 0").rows
            excess = ceil(sent * (bytes - limit) / bytes) + 1

            repo.query!(
              """
              DELETE FROM http_requests WHERE id IN (
                SELECT id FROM http_requests WHERE status != 0 ORDER BY id LIMIT ?
              )
              """,
              [excess]
            ).num_rows
          end)

        if removed == 0, do: 0, else: removed + trim_to(username, limit, round + 1)
      end
    end
  end

  @doc """
  Applies the `http_bodies` retention rule as of `now`: the bodies of
  responses completed before `:days` ago go, and each entry keeps its
  status, headers and search text. Returns how many bodies went.
  """
  @spec drop_bodies(String.t(), map(), DateTime.t()) :: non_neg_integer()
  def drop_bodies(_username, %{days: nil}, _now), do: 0

  def drop_bodies(username, %{days: days}, now) do
    cutoff = Values.time(DateTime.add(now, -days, :day))
    drop_bodies_before(username, cutoff, 0)
  end

  defp drop_bodies_before(username, cutoff, dropped) do
    batch =
      Storage.transaction(username, :journal, fn repo ->
        rows =
          repo.query!(
            """
            SELECT r.id, p.response FROM http_requests r JOIN http_responses p USING (id)
            WHERE r.response_bytes > 0 AND r.completed_at < ? LIMIT 100
            """,
            [cutoff]
          ).rows

        for [identifier, blob] <- rows do
          {response, outline} =
            case Values.from_term(blob) do
              %Req.Response{} = response ->
                {%{response | body: ""}, {:response, response.status, response.headers, 0}}

              other ->
                {other, response_outline(other)}
            end

          repo.query!("UPDATE http_responses SET response = ? WHERE id = ?", [
            Values.term(response),
            identifier
          ])

          repo.query!("UPDATE http_request_details SET outline = ? WHERE id = ?", [
            Values.term(outline),
            identifier
          ])

          repo.query!("UPDATE http_requests SET response_bytes = 0 WHERE id = ?", [identifier])
        end

        length(rows)
      end)

    if batch == 100,
      do: drop_bodies_before(username, cutoff, dropped + batch),
      else: dropped + batch
  end

  @doc """
  Rewrites this identity's whole history in one step.

  `fun` is given the current entries, oldest first and without identifiers,
  and returns the new history the same way; it runs in the process that owns
  the history, so two rewrites cannot interleave. Returned metadata must
  already carry its search text.

  The result is numbered afresh, in the order returned, so an identifier
  held from before — an open tab, a selection — finds nothing afterwards
  instead of landing on a different request. A request recorded while `fun`
  runs is kept, since only the entries it was given are removed. The old
  entries go in the transaction that writes the new ones, so a reader
  never sees the history empty partway.
  """
  @spec rewrite(String.t(), ([history_data()] -> [history_data()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    # Writing a large history can take a while, and a caller that gave up
    # partway would not know whether it landed.
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
  end

  @impl true
  def init(opts) do
    username = Keyword.fetch!(opts, :username)
    import_legacy(username, Keyword.fetch!(opts, :key))
    {:ok, %{username: username}}
  end

  @impl true
  def handle_call({:rewrite, fun}, {caller, _tag}, state) do
    before = entries(state.username, "ORDER BY r.id", [])

    gone =
      Jason.encode!(for {identifier, _metadata, _request, _response} <- before, do: identifier)

    rows =
      before
      |> Enum.map(fn {_identifier, metadata, request, response} ->
        {metadata, request, response}
      end)
      |> fun.()
      |> Enum.map(fn {metadata, request, response} -> row(metadata, request, response) end)

    Storage.transaction(state.username, :journal, fn repo ->
      for row <- rows, do: insert(repo, nil, row)

      repo.query!("DELETE FROM http_requests WHERE id IN (SELECT value FROM json_each(?))", [gone])
    end)

    broadcast(state.username, caller)
    {:reply, :ok, state}
  end

  defp matching(term) do
    case HistoryMetadata.normalize_search_text(term) do
      "" -> {"1", []}
      term -> Search.where("r.id", "http_request_search", "http_request_details", [term])
    end
  end

  @entry """
  SELECT r.id, d.metadata, d.search_text, d.request, p.response
  FROM http_requests r
  JOIN http_request_details d USING (id)
  JOIN http_responses p USING (id)
  """

  defp entries(username, rest, params) do
    Storage.run(username, :journal, &select(&1, rest, params))
  end

  defp select(repo, rest, params) do
    for [identifier, metadata, search_text, request, response] <-
          repo.query!(@entry <> rest, params).rows do
      {identifier, metadata(metadata, search_text), Values.from_term(request),
       Values.from_term(response)}
    end
  end

  defp fetch(repo, identifier) do
    case select(repo, "WHERE r.id = ?", [identifier]) do
      [entry] -> {:ok, entry}
      [] -> :error
    end
  end

  # The search text is kept once, in its own column, and not again in the
  # metadata term beside it.
  defp kept_metadata(metadata), do: Values.term(%{metadata | search_text: ""})

  defp metadata(term, search_text), do: %{Values.from_term(term) | search_text: search_text}

  # Everything an entry is written with, encoded.
  defp row(%HistoryMetadata{} = metadata, %Req.Request{} = request, response) do
    %{
      completed_at: Values.time(metadata.completed_at || DateTime.utc_now()),
      duration_ms: metadata.duration_ms,
      description: metadata.description,
      tags: Values.strings(metadata.tags),
      method: Atom.to_string(request.method),
      url: URI.to_string(request.url),
      status: status(response),
      response_bytes: response_bytes(response),
      metadata: kept_metadata(metadata),
      search_text: metadata.search_text,
      request: Values.term(request),
      outline: Values.term(response_outline(response)),
      response: Values.term(response)
    }
  end

  # Writes an entry as `identifier`, or as the next one when it is nil.
  # One already there under that identifier is kept, and nil returned.
  defp insert(repo, identifier, row) do
    %{rows: rows} =
      repo.query!(
        """
        INSERT INTO http_requests
          (id, completed_at, duration_ms, description, tags, method, url, status, response_bytes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO NOTHING
        RETURNING id
        """,
        [
          identifier,
          row.completed_at,
          row.duration_ms,
          row.description,
          row.tags,
          row.method,
          row.url,
          row.status,
          row.response_bytes
        ]
      )

    case rows do
      [[identifier]] ->
        repo.query!(
          """
          INSERT INTO http_request_details (id, metadata, request, outline, search_text)
          VALUES (?, ?, ?, ?, ?)
          """,
          [identifier, row.metadata, row.request, row.outline, row.search_text]
        )

        repo.query!("INSERT INTO http_responses (id, response) VALUES (?, ?)", [
          identifier,
          row.response
        ])

        identifier

      [] ->
        nil
    end
  end

  defp status(nil), do: 0
  defp status(%Req.Response{status: status}), do: status
  defp status(_error), do: 599

  defp response_bytes(%Req.Response{} = response), do: Utils.response_body_size(response)
  defp response_bytes(_response), do: 0

  defp response_outline(nil), do: :sample

  defp response_outline(%Req.Response{} = response) do
    {:response, response.status, response.headers, Utils.response_body_size(response)}
  end

  defp response_outline(error), do: {:error, error}

  # A method was an atom when it was recorded, and Req's own are atoms
  # already; another is one of the few a user ever typed.
  defp method(name), do: String.to_atom(name)

  defp topic(username), do: "http_history:" <> Accounts.id(username)

  # Everyone but `from`, who knows what it changed.
  defp broadcast(username, from) do
    Phoenix.PubSub.broadcast_from(
      MWTClient.PubSub,
      from,
      topic(username),
      :http_history_changed
    )
  end

  # The history kept in `http_history.bin` before `journal.db`, under the
  # identifiers it had, in one transaction. An entry already here is kept
  # as it is, so an import cut short is safe to make again. Each entry's
  # search text is built afresh, as this build builds it.
  defp import_legacy(username, key) do
    case Legacy.read(username, @legacy_file, key, :http_client) do
      {:ok, entries} when is_list(entries) ->
        Storage.transaction(username, :journal, fn repo ->
          {_imported, failed} =
            Legacy.each_record(repo, entries, fn {identifier, metadata, request, response} ->
              metadata =
                HistoryMetadata
                |> struct(Map.from_struct(metadata))
                |> HistoryMetadata.with_search_text(request, response)

              {:ok, insert(repo, identifier, row(metadata, request, response))}
            end)

          Legacy.keep_failed(username, @legacy_file, key, failed, :http_client)
        end)

        Legacy.retire(username, @legacy_file)

      {:ok, _other} ->
        Legacy.set_aside(username, @legacy_file, :http_client)

      :none ->
        :ok
    end
  end
end
