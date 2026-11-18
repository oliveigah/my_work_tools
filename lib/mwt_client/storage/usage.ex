defmodule MWTClient.Storage.Usage do
  @moduledoc """
  What an identity's data takes on disk: each database's files, the space
  freed inside them that later writes reuse, and the share of each kind of
  thing, measured from SQLite's `dbstat` table, page by page.

  `dbstat` reads every page, so measuring a database of gigabytes takes a
  while: the Storage page measures in the background, and a retention rule
  with a size measures only when the whole file is over it.
  """

  alias MWTClient.Storage
  alias MWTClient.Storage.Backups
  alias MWTClient.Storage.Database
  alias MWTClient.Storage.Journal
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Values

  # What each table and index belongs to, by the start of its name: the
  # search index's own tables and every index of a table with it.
  @groups [
    {"notes", ["note"]},
    {"diagrams", ["diagram"]},
    {"flashcards", ["flashcard"]},
    {"versions", ["versions"]},
    {"documents", ["documents"]},
    {"http", ["http_"]},
    {"events", ["events"]}
  ]

  @doc "The bytes the files of database `name` take: the file and its write-ahead log."
  @spec file_bytes(String.t(), Database.name()) :: non_neg_integer()
  def file_bytes(username, name) do
    path = Database.path(username, name)

    for suffix <- ["", "-wal"], reduce: 0 do
      total ->
        case File.stat(path <> suffix) do
          {:ok, %{size: size}} -> total + size
          {:error, _reason} -> total
        end
    end
  end

  @doc """
  The bytes of database `name`'s write-ahead log: what was written since
  the last checkpoint, cut back to 64 MiB after each. One that stays large
  means a read kept open, holding checkpoints back.
  """
  @spec wal_bytes(String.t(), Database.name()) :: non_neg_integer()
  def wal_bytes(username, name) do
    case File.stat(Database.path(username, name) <> "-wal") do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  @doc "The bytes inside database `name` that are free, for later writes to reuse."
  @spec free_bytes(String.t(), Database.name()) :: non_neg_integer()
  def free_bytes(username, name) do
    Storage.run(username, name, fn repo ->
      [[free]] = repo.query!("PRAGMA freelist_count").rows
      [[size]] = repo.query!("PRAGMA page_size").rows
      free * size
    end)
  end

  @doc """
  The bytes of each group of tables in database `name`: `"notes"`,
  `"versions"`, `"http"`, `"events"` and the rest, `"other"` for what
  belongs to none (the schema, the migrations).
  """
  @spec groups(String.t(), Database.name()) :: %{String.t() => non_neg_integer()}
  def groups(username, name) do
    Storage.run(username, name, fn repo ->
      repo.query!("SELECT name, sum(pgsize) FROM dbstat GROUP BY name").rows
    end)
    |> Enum.reduce(%{}, fn [table, bytes], acc ->
      Map.update(acc, group(table), bytes, &(&1 + bytes))
    end)
  end

  @doc "The bytes of one group of tables (`groups/2`) in database `name`."
  @spec group_bytes(String.t(), Database.name(), String.t()) :: non_neg_integer()
  def group_bytes(username, name, group), do: Map.get(groups(username, name), group, 0)

  @typedoc "One kind: how many there are, the bytes they take, and when the oldest is from."
  @type kind :: %{items: non_neg_integer(), bytes: non_neg_integer(), oldest: DateTime.t() | nil}

  @doc """
  Everything an identity keeps, measured: each database's files and the
  free space inside them, and each kind, by key: `"notes"`, `"diagrams"`,
  `"flashcards"` and `"documents"`, which no rule removes, and every kind
  with a retention rule but the VM's (`MWTClient.Storage.Retention`).

  Versions share one table, so each kind's bytes are its versions'
  content plus their share of the rest, about.
  """
  @spec summary(String.t()) :: %{
          files: map(),
          kinds: %{String.t() => kind()},
          not_imported: %{String.t() => map()}
        }
  def summary(username) do
    # Counted with what the journal still holds in memory.
    :ok = Journal.flush(username)
    library = groups(username, :library)
    journal = groups(username, :journal)

    versions =
      Storage.run(username, :library, fn repo ->
        repo.query!(
          "SELECT kind, count(*), sum(length(content)), min(replaced_at) FROM versions GROUP BY kind"
        ).rows
      end)
      |> Map.new(fn [kind, items, bytes, oldest] -> {kind, {items, bytes || 0, oldest}} end)

    content = versions |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    rest = max(Map.get(library, "versions", 0) - content, 0)
    all = versions |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sum()

    version_kind = fn kind ->
      {items, bytes, oldest} = Map.get(versions, kind, {0, 0, nil})
      share = if all > 0, do: div(rest * items, all), else: 0
      %{items: items, bytes: bytes + share, oldest: Values.from_time(oldest)}
    end

    kinds = %{
      "notes" => counted(username, :library, "notes", "created_at", library),
      "diagrams" => counted(username, :library, "diagrams", "created_at", library),
      "flashcards" => counted(username, :library, "flashcards", "created_at", library),
      "documents" => counted(username, :library, "documents", "updated_at", library),
      "note_versions" => version_kind.("notes"),
      "diagram_versions" => version_kind.("diagrams"),
      "flashcard_versions" => version_kind.("flashcards"),
      "http_history" =>
        counted(username, :journal, "http_requests", "completed_at", journal,
          group: "http",
          where: "status != 0"
        ),
      "http_bodies" => bodies(username),
      "agent_activity" => counted(username, :journal, "events", "at", journal),
      "backups" => backups(username),
      "legacy" => %{
        items: length(Path.wildcard(Path.join(Legacy.dir(username), "*"))),
        bytes: folder_bytes(Legacy.dir(username)),
        oldest: nil
      }
    }

    files =
      Map.new(Database.names(), fn name ->
        {name,
         %{
           path: Database.path(username, name),
           bytes: file_bytes(username, name),
           wal: wal_bytes(username, name),
           free: free_bytes(username, name)
         }}
      end)

    %{files: files, kinds: kinds, not_imported: Legacy.failures(username)}
  end

  defp counted(username, database, table, time, groups, opts \\ []) do
    where = Keyword.get(opts, :where, "1")

    [[items, oldest]] =
      Storage.run(username, database, fn repo ->
        repo.query!("SELECT count(*), min(#{time}) FROM #{table} WHERE #{where}").rows
      end)

    %{
      items: items,
      bytes: Map.get(groups, Keyword.get(opts, :group, table), 0),
      oldest: Values.from_time(oldest)
    }
  end

  defp bodies(username) do
    [[items, bytes, oldest]] =
      Storage.run(username, :journal, fn repo ->
        repo.query!("""
        SELECT count(*), sum(length(p.response)), min(r.completed_at)
        FROM http_requests r JOIN http_responses p USING (id) WHERE r.response_bytes > 0
        """).rows
      end)

    %{items: items, bytes: bytes || 0, oldest: Values.from_time(oldest)}
  end

  defp backups(username) do
    backups = Backups.list(username)

    %{
      items: length(backups),
      bytes: backups |> Enum.map(& &1.bytes) |> Enum.sum(),
      oldest: backups |> List.last() |> then(&(&1 && &1.at))
    }
  end

  @doc "The bytes a folder and everything in it take, or 0 when it isn't there."
  @spec folder_bytes(Path.t()) :: non_neg_integer()
  def folder_bytes(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.map(&folder_bytes(Path.join(path, &1)))
        |> Enum.sum()

      {:ok, %{type: :regular, size: size}} ->
        size

      _other ->
        0
    end
  end

  defp group(table) do
    table = String.replace_prefix(table, "sqlite_autoindex_", "")

    Enum.find_value(@groups, "other", fn {group, prefixes} ->
      if Enum.any?(prefixes, &String.starts_with?(table, &1)), do: group
    end)
  end
end
