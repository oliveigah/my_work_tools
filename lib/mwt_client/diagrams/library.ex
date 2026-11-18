defmodule MWTClient.Diagrams.Library do
  @moduledoc """
  Owns one identity's diagrams.

  They are kept in the identity's `library.db` (`MWTClient.Storage`),
  encrypted on disk with the rest of it: what a list shows in `diagrams`,
  the elements, as one term, and their search text in `diagram_contents`,
  searched through a trigram index (`MWTClient.Search.where/4`). Every
  function takes the username they belong to.

  Reads run in the process that asks, straight from the database, so none
  waits behind a write. Writes go through this process, one per unlocked
  identity, started by `MWTClient.Vault.Store`: each change is one
  transaction, made durable before it returns, with the version it may
  keep; and this process remembers who changed each diagram last, which
  the version rule asks.

  Lists come back as summaries, which never read the elements. The words
  around a match cost a walk over the elements, so they are asked for
  apart, with `snippets/3`, and only for the diagrams on screen. Every
  change is broadcast, once written, to the processes that `subscribe/1`,
  all but the one that made it.

  Every change to a diagram's title or elements counts up its `version`,
  and may keep what it replaced as a version to restore
  (`MWTClient.Versions`).

  At its first start with an identity whose diagrams are still in
  `diagrams.bin`, from before `library.db`, it imports them and their
  versions, then moves the files into `legacy/` (`MWTClient.Storage.Legacy`).
  """

  use GenServer

  alias MWTClient.Accounts
  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Search
  alias MWTClient.Storage
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Values
  alias MWTClient.Vault.Store
  alias MWTClient.Versions

  @kind "diagrams"
  @legacy_file "diagrams.bin"

  @type summary :: %{
          id: String.t(),
          title: String.t(),
          updated_at: DateTime.t(),
          count: non_neg_integer()
        }

  @type snippet :: {String.t(), String.t(), String.t()}

  @doc "Starts the library for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes the caller to diagram changes made by other processes."
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  @doc """
  Summaries of the diagrams holding every word of `term`, the most recently
  changed first. A blank term lists them all.
  """
  @spec list(String.t(), String.t()) :: [summary()]
  def list(username, term \\ "") when is_binary(term) do
    {matching, params} =
      Search.where("d.seq", "diagram_search", "diagram_contents", Diagram.terms(term))

    Storage.run(username, :library, fn repo ->
      repo.query!(
        """
        SELECT id, title, updated_at, element_count FROM diagrams d
        WHERE #{matching} ORDER BY updated_at DESC, seq DESC
        """,
        params
      ).rows
    end)
    |> Enum.map(fn [id, title, updated_at, count] ->
      %{id: id, title: title, updated_at: Values.from_time(updated_at), count: count}
    end)
  end

  @doc """
  The words around `term` in each of the diagrams `ids` that holds it in its
  elements, as `Diagram.snippet/2` cuts them. Diagrams gone, or holding the
  words in their title alone, are left out.
  """
  @spec snippets(String.t(), [String.t()], String.t()) :: %{String.t() => snippet()}
  def snippets(username, ids, term) when is_list(ids) and is_binary(term) do
    case Diagram.terms(term) do
      [] ->
        %{}

      terms ->
        Storage.run(username, :library, fn repo ->
          repo.query!(
            """
            SELECT d.id, c.elements FROM diagrams d JOIN diagram_contents c USING (seq)
            WHERE d.id IN (SELECT value FROM json_each(?))
            """,
            [Jason.encode!(ids)]
          ).rows
        end)
        |> Enum.flat_map(fn [id, elements] ->
          case Diagram.snippet(%Diagram{elements: Values.from_term(elements)}, terms) do
            nil -> []
            snippet -> [{id, snippet}]
          end
        end)
        |> Map.new()
    end
  end

  @doc "The diagram changed last, if there is one."
  @spec latest(String.t()) :: {:ok, Diagram.t()} | :error
  def latest(username) do
    case diagrams(username, "ORDER BY d.updated_at DESC, d.seq DESC LIMIT 1", []) do
      [diagram] -> {:ok, diagram}
      [] -> :error
    end
  end

  @doc "One diagram, elements and all."
  @spec get(String.t(), String.t()) :: {:ok, Diagram.t()} | :error
  def get(username, id) do
    case diagrams(username, "WHERE d.id = ?", [id]) do
      [diagram] -> {:ok, diagram}
      [] -> :error
    end
  end

  @doc "Every diagram, the oldest change first."
  @spec all(String.t()) :: [Diagram.t()]
  def all(username), do: diagrams(username, "ORDER BY d.updated_at, d.seq", [])

  @doc """
  Writes `:title` and `:elements` into the diagram `id`, creating it if it is
  not there yet.

  A diagram exists from its first save, so one opened and left empty does not
  clutter the list.
  """
  @spec save(String.t(), String.t(), map()) :: {:ok, Diagram.t()} | {:error, :invalid_id}
  def save(username, id, attrs) when is_map(attrs) do
    if Diagram.id?(id), do: call(username, {:save, id, attrs}), else: {:error, :invalid_id}
  end

  @doc "Updates an existing diagram's title or elements without creating a missing diagram."
  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, Diagram.t()} | {:stale, Diagram.t()} | :error
  def update(username, id, attrs, opts \\ []) when is_map(attrs) and is_list(opts),
    do: call(username, {:update, id, attrs, opts})

  @doc "The versions kept of a diagram, the newest first."
  @spec versions(String.t(), String.t()) :: [Versions.Version.t()]
  def versions(username, id), do: username |> Versions.open(@kind) |> Versions.list(id)

  @doc """
  Makes the version numbered `number` of a diagram its title and elements
  again. What it replaces is kept as a version, so a restore is undone the
  same way.
  """
  @spec restore_version(String.t(), String.t(), integer()) :: {:ok, Diagram.t()} | :error
  def restore_version(username, id, number), do: call(username, {:restore_version, id, number})

  @doc "Copies a diagram under a new identifier and title."
  @spec duplicate(String.t(), String.t()) :: {:ok, Diagram.t()} | :error
  def duplicate(username, id), do: call(username, {:duplicate, id})

  @doc "Deletes one diagram."
  @spec delete(String.t(), String.t()) :: :ok | :error
  def delete(username, id), do: call(username, {:delete, id})

  @doc """
  Replaces every diagram with what `fun` returns when given them all, oldest
  change first. It runs in this process, so no save can land in between.
  """
  @spec rewrite(String.t(), ([Diagram.t()] -> [Diagram.t()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
  end

  defp call(username, request), do: GenServer.call(Store.via(__MODULE__, username), request)

  @columns """
  SELECT d.id, d.title, c.elements, d.created_at, d.updated_at, d.version, c.search_text
  FROM diagrams d JOIN diagram_contents c USING (seq)
  """

  defp diagrams(username, rest, params) do
    Storage.run(username, :library, &select(&1, rest, params))
  end

  defp select(repo, rest, params) do
    for [id, title, elements, created_at, updated_at, version, search_text] <-
          repo.query!(@columns <> rest, params).rows do
      %Diagram{
        id: id,
        title: title,
        elements: Values.from_term(elements),
        created_at: Values.from_time(created_at),
        updated_at: Values.from_time(updated_at),
        version: version,
        search_text: search_text
      }
    end
  end

  defp fetch(repo, id) do
    case select(repo, "WHERE d.id = ?", [id]) do
      [diagram] -> {:ok, diagram}
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
    attrs = Map.take(attrs, [:title, :elements])

    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, diagram} ->
          change(repo, diagram, attrs, state)

        :error ->
          diagram = stored(Diagram.new(Map.put(attrs, :id, id)))
          put(repo, diagram, nil)
          {{:ok, diagram}, state, id}
      end
    end)
  end

  def handle_call({:update, id, attrs, opts}, from, state) do
    expected = Keyword.get(opts, :version)
    attrs = Map.take(attrs, [:title, :elements])

    write(state, from, fn repo ->
      case fetch(repo, id) do
        # A change already made, sent again, is no change.
        {:ok, diagram} ->
          if expected not in [nil, diagram.version] and Diagram.update(diagram, attrs) != diagram,
            do: {{:stale, diagram}, state, nil},
            else: change(repo, diagram, attrs, state, Keyword.get(opts, :by, :you))

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:restore_version, id, number}, from, state) do
    write(state, from, fn repo ->
      with {:ok, diagram} <- fetch(repo, id),
           {:ok, version} <- Versions.fetch(state.versions, id, number) do
        attrs = Map.take(version.content, [:title, :elements])
        change(repo, diagram, attrs, state, :you, :restore)
      else
        :error -> {:error, state, nil}
      end
    end)
  end

  def handle_call({:duplicate, id}, from, state) do
    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, diagram} ->
          copy =
            stored(Diagram.new(%{title: "#{diagram.title} copy", elements: diagram.elements}))

          put(repo, copy, nil)
          {{:ok, copy}, state, copy.id}

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:delete, id}, from, state) do
    write(state, from, fn repo ->
      case repo.query!("DELETE FROM diagrams WHERE id = ? RETURNING seq", [id]).rows do
        [] -> {:error, state, nil}
        [_deleted] -> {:ok, %{state | versions: Versions.forget(state.versions, id)}, id}
      end
    end)
  end

  def handle_call({:rewrite, fun}, from, state) do
    write(state, from, fn repo ->
      diagrams =
        repo
        |> select("ORDER BY d.updated_at, d.seq", [])
        |> fun.()
        |> Map.new(&{&1.id, stored(&1)})

      ids = Map.keys(diagrams)

      repo.query!("DELETE FROM diagrams WHERE id NOT IN (SELECT value FROM json_each(?))", [
        Jason.encode!(ids)
      ])

      for {_id, diagram} <- diagrams, do: put(repo, diagram, nil)
      {:ok, %{state | versions: Versions.keep_only(state.versions, ids)}, :all}
    end)
  end

  # Runs `fun` in one transaction, which answers `{reply, state, changed}`,
  # and tells subscribers of the diagram `changed`, if any, once written.
  defp write(state, from, fun) do
    {reply, state, changed} = Storage.transaction(state.username, :library, fun)
    if changed, do: broadcast(state, from, changed)
    {:reply, reply, state}
  end

  defp change(repo, diagram, attrs, state, by \\ :you, how \\ :edit) do
    case Diagram.update(diagram, attrs) do
      ^diagram ->
        {{:ok, diagram}, state, nil}

      updated ->
        before = %{
          version: diagram.version,
          content: %{title: diagram.title, elements: diagram.elements},
          saved_at: diagram.updated_at
        }

        state = %{state | versions: Versions.changed(state.versions, diagram.id, before, by, how)}
        updated = stored(%{updated | version: diagram.version + 1})
        put(repo, updated, diagram)
        {{:ok, updated}, state, diagram.id}
    end
  end

  # Writes a diagram, new or not. Its elements are written again only when
  # they, or what it is searched by, changed since `before`.
  defp put(repo, %Diagram{} = diagram, before) do
    %{rows: [[seq]]} =
      repo.query!(
        """
        INSERT INTO diagrams (id, title, element_count, created_at, updated_at, version)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          title = excluded.title, element_count = excluded.element_count,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          version = excluded.version
        RETURNING seq
        """,
        [
          diagram.id,
          diagram.title,
          length(diagram.elements),
          Values.time(diagram.created_at),
          Values.time(diagram.updated_at),
          diagram.version
        ]
      )

    if before == nil or
         {before.elements, before.search_text} != {diagram.elements, diagram.search_text} do
      repo.query!(
        """
        INSERT INTO diagram_contents (seq, elements, search_text) VALUES (?, ?, ?)
        ON CONFLICT (seq) DO UPDATE SET
          elements = excluded.elements, search_text = excluded.search_text
        """,
        [seq, Values.term(diagram.elements), diagram.search_text]
      )
    end

    :ok
  end

  # As a read gives it back, so what a write answers is what a read will.
  defp stored(%Diagram{} = diagram) do
    %{
      diagram
      | created_at: Values.stored_time(diagram.created_at),
        updated_at: Values.stored_time(diagram.updated_at)
    }
  end

  defp topic(username), do: "diagrams:" <> Accounts.id(username)

  defp broadcast(state, {caller, _tag}, id) do
    Phoenix.PubSub.broadcast_from(
      MWTClient.PubSub,
      caller,
      topic(state.username),
      {:diagrams_changed, id}
    )
  end

  # The diagrams kept in `diagrams.bin` before `library.db`, with their
  # versions, in one transaction. A diagram already here is kept as it is,
  # as is its history, so an import cut short is safe to make again.
  defp import_legacy(username, key, versions) do
    case Legacy.read(username, @legacy_file, key, :diagrams) do
      {:ok, diagrams} when is_list(diagrams) ->
        Storage.transaction(username, :library, fn repo ->
          {imported, failed} =
            Legacy.each_record(repo, diagrams, fn diagram ->
              diagram = stored(upgrade(diagram))
              if insert_new(repo, diagram), do: {:ok, diagram.id}, else: :skip
            end)

          Legacy.keep_failed(username, @legacy_file, key, failed, :diagrams)
          Versions.import_legacy(versions, key, imported)
        end)

        Legacy.retire(username, @legacy_file)

      {:ok, _other} ->
        Legacy.set_aside(username, @legacy_file, :diagrams)

      :none ->
        :ok
    end

    Legacy.retire(username, Versions.legacy_dir(@kind))
  end

  defp insert_new(repo, diagram) do
    case repo.query!("SELECT 1 FROM diagrams WHERE id = ?", [diagram.id]).rows do
      [] -> put(repo, diagram, nil) == :ok
      [_here] -> false
    end
  end

  # Rebuilt through the struct, so one kept by a build whose struct had
  # fewer fields gets this build's defaults for them, and is searched as
  # this build searches.
  defp upgrade(diagram), do: Diagram.with_search_text(struct(Diagram, Map.from_struct(diagram)))
end
