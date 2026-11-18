defmodule MWTClient.Notes.Library do
  @moduledoc """
  Owns one identity's notes.

  They are kept in the identity's `library.db` (`MWTClient.Storage`),
  encrypted on disk with the rest of it, each in its own rows: what a list
  shows in `notes`, the body and its search text in `note_texts`, searched
  through a trigram index (`MWTClient.Search.where/4`). Every function
  takes the username they belong to.

  Reads run in the process that asks, straight from the database, so none
  waits behind a write. Writes go through this process, one per unlocked
  identity, started by `MWTClient.Vault.Store`: each change is one
  transaction, made durable before it returns, with the version it may
  keep; and this process remembers who changed each note last, which the
  version rule asks.

  This module is the only way in, for the notes page and for anything else
  that writes notes. Every change is broadcast to the processes that
  `subscribe/1`, all but the one that made it, once it is written, so a
  page shows what was written elsewhere without asking. Lists come back as
  summaries, which never read a body. The words around a match are asked
  for apart, with `snippets/3`, and only for the notes on screen.

  Every change to a note's title or body counts up its `version`, and may
  keep what it replaced as a version to restore (`MWTClient.Versions`).

  At its first start with an identity whose notes are still in `notes.bin`,
  from before `library.db`, it imports them and their versions, then moves
  the files into `legacy/` (`MWTClient.Storage.Legacy`).
  """

  use GenServer

  alias MWTClient.Accounts
  alias MWTClient.Notes.Note
  alias MWTClient.Search
  alias MWTClient.Storage
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Values
  alias MWTClient.Vault.Store
  alias MWTClient.Versions

  @kind "notes"
  @legacy_file "notes.bin"

  @type summary :: %{
          id: String.t(),
          title: String.t(),
          done_at: DateTime.t() | nil,
          updated_at: DateTime.t(),
          excerpt: String.t() | nil
        }

  @type snippet :: {String.t(), String.t(), String.t()}

  @typedoc """
  Sent to subscribers when a note changes, naming it, or `:all` when every
  note was replaced at once, as by an import.
  """
  @type message :: {:notes_changed, String.t() | :all}

  @doc "Starts the library for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes the caller to the `t:message/0`s of changes made by others."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  @doc """
  Summaries of the notes holding every word of `term`, the most recently
  changed first. A blank term lists them all.
  """
  @spec list(String.t(), String.t()) :: [summary()]
  def list(username, term \\ "") when is_binary(term) do
    {matching, params} = Search.where("n.seq", "note_search", "note_texts", Note.terms(term))

    Storage.run(username, :library, fn repo ->
      repo.query!(
        """
        SELECT id, title, done_at, updated_at, excerpt FROM notes n
        WHERE #{matching} ORDER BY updated_at DESC, seq DESC
        """,
        params
      ).rows
    end)
    |> Enum.map(fn [id, title, done_at, updated_at, excerpt] ->
      %{
        id: id,
        title: title,
        done_at: Values.from_time(done_at),
        updated_at: Values.from_time(updated_at),
        excerpt: excerpt
      }
    end)
  end

  @doc """
  The words around `term` in each of the notes `ids` that holds it in its
  body, as `Note.snippet/2` cuts them. Notes gone, or holding the words in
  their title alone, are left out.
  """
  @spec snippets(String.t(), [String.t()], String.t()) :: %{String.t() => snippet()}
  def snippets(username, ids, term) when is_list(ids) and is_binary(term) do
    case Note.terms(term) do
      [] ->
        %{}

      terms ->
        Storage.run(username, :library, fn repo ->
          repo.query!(
            """
            SELECT n.id, t.body FROM notes n JOIN note_texts t USING (seq)
            WHERE n.id IN (SELECT value FROM json_each(?))
            """,
            [Jason.encode!(ids)]
          ).rows
        end)
        |> Enum.flat_map(fn [id, body] ->
          case Note.snippet(%Note{body: body}, terms) do
            nil -> []
            snippet -> [{id, snippet}]
          end
        end)
        |> Map.new()
    end
  end

  @doc "The note changed last, if there is one."
  @spec latest(String.t()) :: {:ok, Note.t()} | :error
  def latest(username) do
    case notes(username, "ORDER BY n.updated_at DESC, n.seq DESC LIMIT 1", []) do
      [note] -> {:ok, note}
      [] -> :error
    end
  end

  @doc "One note, body and all."
  @spec get(String.t(), String.t()) :: {:ok, Note.t()} | :error
  def get(username, id) do
    case notes(username, "WHERE n.id = ?", [id]) do
      [note] -> {:ok, note}
      [] -> :error
    end
  end

  @doc "Every note, the oldest change first."
  @spec all(String.t()) :: [Note.t()]
  def all(username), do: notes(username, "ORDER BY n.updated_at, n.seq", [])

  @doc """
  Writes `:title` and `:body` into the note `id`, creating it if it is not
  there yet.

  A note exists from its first save, so one opened and left blank does not
  clutter the list.
  """
  @spec save(String.t(), String.t(), map()) :: {:ok, Note.t()} | {:error, :invalid_id}
  def save(username, id, attrs) when is_map(attrs) do
    if Note.id?(id), do: call(username, {:save, id, attrs}), else: {:error, :invalid_id}
  end

  @doc """
  Updates an existing note's title or body without creating a missing note.

  Options: `:by`, who changes it (`t:MWTClient.Versions.by/0`, you by
  default), and `:version`, the version the change was based on. A note
  whose version is another by now is left as it is and comes back as
  `{:stale, note}`, so the change never overwrites an edit its maker hasn't
  seen; unless it holds what the change asks already, as when a change
  made is sent again.
  """
  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, Note.t()} | {:stale, Note.t()} | :error
  def update(username, id, attrs, opts \\ []) when is_map(attrs) and is_list(opts),
    do: call(username, {:update, id, attrs, opts})

  @doc "The versions kept of a note, the newest first."
  @spec versions(String.t(), String.t()) :: [Versions.Version.t()]
  def versions(username, id), do: username |> Versions.open(@kind) |> Versions.list(id)

  @doc """
  Makes the version numbered `number` of a note its title and body again.
  What it replaces is kept as a version, so a restore is undone the same
  way.
  """
  @spec restore_version(String.t(), String.t(), integer()) :: {:ok, Note.t()} | :error
  def restore_version(username, id, number), do: call(username, {:restore_version, id, number})

  @doc """
  Marks a note done, or open again. Asking for the state it is already in
  changes nothing, so it is safe to repeat.
  """
  @spec set_done(String.t(), String.t(), boolean()) :: {:ok, Note.t()} | :error
  def set_done(username, id, done?) when is_boolean(done?) do
    call(username, {:set_done, id, done?})
  end

  @doc "Deletes one note."
  @spec delete(String.t(), String.t()) :: :ok | :error
  def delete(username, id), do: call(username, {:delete, id})

  @doc """
  Replaces every note with what `fun` returns when given them all, oldest
  change first. It runs in this process, so no save can land in between.
  """
  @spec rewrite(String.t(), ([Note.t()] -> [Note.t()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
  end

  defp call(username, request), do: GenServer.call(Store.via(__MODULE__, username), request)

  @columns """
  SELECT n.id, n.title, t.body, n.excerpt, n.done_at, n.created_at, n.updated_at, n.version,
         t.search_text
  FROM notes n JOIN note_texts t USING (seq)
  """

  defp notes(username, rest, params) do
    Storage.run(username, :library, &select(&1, rest, params))
  end

  defp select(repo, rest, params) do
    for [id, title, body, excerpt, done_at, created_at, updated_at, version, search_text] <-
          repo.query!(@columns <> rest, params).rows do
      %Note{
        id: id,
        title: title,
        body: body,
        excerpt: excerpt,
        done_at: Values.from_time(done_at),
        created_at: Values.from_time(created_at),
        updated_at: Values.from_time(updated_at),
        version: version,
        search_text: search_text
      }
    end
  end

  defp fetch(repo, id) do
    case select(repo, "WHERE n.id = ?", [id]) do
      [note] -> {:ok, note}
      [] -> :error
    end
  end

  @impl true
  def init(opts) do
    username = Keyword.fetch!(opts, :username)
    versions = Versions.open(username, @kind)
    import_legacy(username, Keyword.fetch!(opts, :key), versions)
    {:ok, %{username: username, versions: versions}}
  end

  @impl true
  def handle_call({:save, id, attrs}, from, state) do
    attrs = Map.take(attrs, [:title, :body])

    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, note} ->
          change(repo, note, attrs, state)

        :error ->
          note = stored(Note.new(Map.put(attrs, :id, id)))
          put(repo, note, nil)
          {{:ok, note}, state, id}
      end
    end)
  end

  def handle_call({:update, id, attrs, opts}, from, state) do
    expected = Keyword.get(opts, :version)
    attrs = Map.take(attrs, [:title, :body])

    write(state, from, fn repo ->
      case fetch(repo, id) do
        # A change already made, sent again, is no change: it answers as
        # it did, whatever version it was based on.
        {:ok, note} ->
          if expected not in [nil, note.version] and Note.update(note, attrs) != note,
            do: {{:stale, note}, state, nil},
            else: change(repo, note, attrs, state, Keyword.get(opts, :by, :you))

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:restore_version, id, number}, from, state) do
    write(state, from, fn repo ->
      with {:ok, note} <- fetch(repo, id),
           {:ok, version} <- Versions.fetch(state.versions, id, number) do
        change(repo, note, Map.take(version.content, [:title, :body]), state, :you, :restore)
      else
        :error -> {:error, state, nil}
      end
    end)
  end

  def handle_call({:set_done, id, done?}, from, state) do
    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, note} -> change(repo, note, %{done: done?}, state)
        :error -> {:error, state, nil}
      end
    end)
  end

  def handle_call({:delete, id}, from, state) do
    write(state, from, fn repo ->
      case repo.query!("DELETE FROM notes WHERE id = ? RETURNING seq", [id]).rows do
        [] -> {:error, state, nil}
        [_deleted] -> {:ok, %{state | versions: Versions.forget(state.versions, id)}, id}
      end
    end)
  end

  def handle_call({:rewrite, fun}, from, state) do
    write(state, from, fn repo ->
      notes =
        repo
        |> select("ORDER BY n.updated_at, n.seq", [])
        |> fun.()
        |> Map.new(&{&1.id, stored(&1)})

      ids = Map.keys(notes)

      repo.query!("DELETE FROM notes WHERE id NOT IN (SELECT value FROM json_each(?))", [
        Jason.encode!(ids)
      ])

      for {_id, note} <- notes, do: put(repo, note, nil)
      {:ok, %{state | versions: Versions.keep_only(state.versions, ids)}, :all}
    end)
  end

  # Runs `fun` in one transaction, which answers `{reply, state, changed}`,
  # and tells subscribers of the note `changed`, if any, once it is written.
  defp write(state, from, fun) do
    {reply, state, changed} = Storage.transaction(state.username, :library, fun)
    if changed, do: broadcast(state, from, changed)
    {:reply, reply, state}
  end

  defp change(repo, note, attrs, state, by \\ :you, how \\ :edit) do
    case Note.update(note, attrs) do
      ^note ->
        {{:ok, note}, state, nil}

      updated ->
        {updated, state} = count_version(note, stored(updated), state, by, how)
        put(repo, updated, note)
        {{:ok, updated}, state, note.id}
    end
  end

  # Marking a note done changes neither its title nor its body: no version.
  defp count_version(note, updated, state, by, how) do
    if {note.title, note.body} == {updated.title, updated.body} do
      {updated, state}
    else
      before = %{
        version: note.version,
        content: %{title: note.title, body: note.body},
        saved_at: note.updated_at
      }

      {%{updated | version: note.version + 1},
       %{state | versions: Versions.changed(state.versions, note.id, before, by, how)}}
    end
  end

  # Writes a note, new or not. Its body is written again only when it, or
  # what it is searched by, changed since `before`.
  defp put(repo, %Note{} = note, before) do
    %{rows: [[seq]]} =
      repo.query!(
        """
        INSERT INTO notes (id, title, excerpt, done_at, created_at, updated_at, version)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          title = excluded.title, excerpt = excluded.excerpt, done_at = excluded.done_at,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          version = excluded.version
        RETURNING seq
        """,
        [
          note.id,
          note.title,
          note.excerpt,
          Values.time(note.done_at),
          Values.time(note.created_at),
          Values.time(note.updated_at),
          note.version
        ]
      )

    if before == nil or {before.body, before.search_text} != {note.body, note.search_text} do
      repo.query!(
        """
        INSERT INTO note_texts (seq, body, search_text) VALUES (?, ?, ?)
        ON CONFLICT (seq) DO UPDATE SET body = excluded.body, search_text = excluded.search_text
        """,
        [seq, note.body, note.search_text]
      )
    end

    :ok
  end

  # As a read gives it back, so what a write answers is what a read will.
  defp stored(%Note{} = note) do
    %{
      note
      | done_at: Values.stored_time(note.done_at),
        created_at: Values.stored_time(note.created_at),
        updated_at: Values.stored_time(note.updated_at)
    }
  end

  # Everyone but the caller, who has the answer to its own call already.
  defp broadcast(state, {caller, _tag}, id) do
    Phoenix.PubSub.broadcast_from(
      MWTClient.PubSub,
      caller,
      topic(state.username),
      {:notes_changed, id}
    )
  end

  defp topic(username), do: "notes:" <> Accounts.id(username)

  # The notes kept in `notes.bin` before `library.db`, with their versions,
  # in one transaction. A note already here is kept as it is, as is its
  # history, so an import cut short is safe to make again.
  defp import_legacy(username, key, versions) do
    case Legacy.read(username, @legacy_file, key, :notes) do
      {:ok, notes} when is_list(notes) ->
        Storage.transaction(username, :library, fn repo ->
          {imported, failed} =
            Legacy.each_record(repo, notes, fn note ->
              note = stored(upgrade(note))
              if insert_new(repo, note), do: {:ok, note.id}, else: :skip
            end)

          Legacy.keep_failed(username, @legacy_file, key, failed, :notes)
          Versions.import_legacy(versions, key, imported)
        end)

        Legacy.retire(username, @legacy_file)

      {:ok, _other} ->
        Legacy.set_aside(username, @legacy_file, :notes)

      :none ->
        :ok
    end

    Legacy.retire(username, Versions.legacy_dir(@kind))
  end

  defp insert_new(repo, note) do
    case repo.query!("SELECT 1 FROM notes WHERE id = ?", [note.id]).rows do
      [] -> put(repo, note, nil) == :ok
      [_here] -> false
    end
  end

  # Rebuilt through the struct, so a note kept by a build whose struct had
  # fewer fields comes back with this build's defaults for the ones it lacks,
  # with an excerpt if it was kept before excerpts were, and searched as
  # this build searches.
  defp upgrade(note) do
    upgraded = struct(Note, Map.from_struct(note))

    upgraded =
      if Map.has_key?(note, :excerpt),
        do: upgraded,
        else: %{upgraded | excerpt: Note.excerpt(upgraded)}

    Note.with_search_text(upgraded)
  end
end
