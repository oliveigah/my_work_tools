defmodule MWTClient.Storage.ImportCheck do
  @moduledoc """
  Compares what an identity kept before its databases (its `.bin` files
  and `versions/`, beside the databases or under `legacy/`) with what the
  apps read from the databases now: to check the import on a copy of real
  data (`scripts/check-storage-import.exs`, docs/storage.md).

  It reports counts, ids and the names of fields that differ, never what
  an item says, so its report can be pasted into a thread. Times are
  compared to the microsecond, the most either side keeps.
  """

  alias MWTClient.Accounts
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Flashcards.Library, as: Flashcards
  alias MWTClient.HttpClient.Resources
  alias MWTClient.MCP.Access
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Sandbox.AgentThreads
  alias MWTClient.Storage.Documents
  alias MWTClient.Storage.Legacy
  alias MWTClient.Vault

  @files %{
    notes: "notes.bin",
    diagrams: "diagrams.bin",
    flashcards: "flashcards.bin",
    http_history: "http_history.bin",
    mcp_access: "mcp_access.bin",
    agent_threads: "agent_threads.bin",
    sandbox: "sandbox.bin"
  }

  @note_fields [:title, :body, :done_at, :created_at, :updated_at, :version]
  @diagram_fields [:title, :elements, :created_at, :updated_at, :version]
  @card_fields [
    :front,
    :back,
    :tags,
    :source,
    :box,
    :due_at,
    :reviewed_at,
    :reviews,
    :lapses,
    :removed_at,
    :created_at,
    :updated_at,
    :version
  ]

  @typedoc "One kind compared: how many each side holds, and what doesn't match."
  @type result :: %{
          kind: String.t(),
          before: non_neg_integer(),
          now: non_neg_integer(),
          missing: [term()],
          extra: [term()],
          differing: [{term(), [atom()]}]
        }

  @doc """
  What the files from before hold, opened with the password's `key`. Read
  before unlocking, so it is what an older build would read. A file not
  there, or not opening, is `nil`.
  """
  @spec read_before(String.t(), Vault.key()) :: map()
  def read_before(username, key) do
    files = Map.new(@files, fn {kind, file} -> {kind, open(username, file, key)} end)

    versions =
      Map.new(~w(notes diagrams flashcards), fn kind ->
        {kind, versions_before(username, kind, key)}
      end)

    Map.put(files, :versions, versions)
  end

  @doc "Compares `before` (`read_before/2`) with what the unlocked identity's apps read."
  @spec compare(String.t(), map()) :: [result()]
  def compare(username, before) do
    notes = list(before.notes)
    diagrams = list(before.diagrams)
    cards = before.flashcards && before.flashcards[:cards]

    [
      items("notes", notes, Notes.all(username), @note_fields),
      versions("note versions", notes, before.versions["notes"], &Notes.versions(username, &1)),
      items("diagrams", diagrams, Diagrams.all(username), @diagram_fields),
      versions(
        "diagram versions",
        diagrams,
        before.versions["diagrams"],
        &Diagrams.versions(username, &1)
      ),
      items("flash cards", list(cards), Flashcards.all(username), @card_fields),
      versions(
        "flash card versions",
        list(cards),
        before.versions["flashcards"],
        &Flashcards.versions(username, &1)
      ),
      settings(before.flashcards, Flashcards.settings(username)),
      history(list(before.http_history), Resources.all(username)),
      mcp(before.mcp_access, username),
      threads(before.agent_threads, AgentThreads.list(username)),
      sandbox(before.sandbox, username)
    ]
  end

  @doc "Files set aside as unreadable, beside the databases or under `legacy/`."
  @spec corrupt(String.t()) :: [String.t()]
  def corrupt(username) do
    for dir <- [Accounts.dir(username), Legacy.dir(username)],
        path <- Path.wildcard(Path.join(dir, "*.corrupt")),
        do: Path.relative_to(path, Accounts.dir(username))
  end

  @doc "The report, line by line: no titles, bodies or other content."
  @spec lines([result()], keyword()) :: [String.t()]
  def lines(results, opts \\ []) do
    kinds =
      Enum.flat_map(results, fn result ->
        status =
          if result.missing == [] and result.extra == [] and result.differing == [],
            do: "ok  ",
            else: "DIFF"

        [
          "#{status} #{result.kind}: #{result.before} before, #{result.now} now" |> String.trim()
        ] ++
          ids("  missing now", result.missing) ++
          ids("  only now", result.extra) ++
          Enum.map(Enum.take(result.differing, 20), fn {id, fields} ->
            "  differs: #{inspect(id)} in #{Enum.join(fields, ", ")}"
          end)
      end)

    extra =
      Enum.flat_map(opts, fn
        {:unlock_ms, ms} ->
          ["first unlock: #{ms} ms"]

        {:corrupt, []} ->
          ["set aside as .corrupt: none"]

        {:corrupt, files} ->
          ["set aside as .corrupt: #{Enum.join(files, ", ")}"]

        {:not_imported, failures} when failures == %{} ->
          ["not imported: none"]

        {:not_imported, failures} ->
          Enum.map(failures, fn {file, f} -> "not imported: #{f.count} of #{file}" end)
      end)

    kinds ++ extra
  end

  defp ids(_label, []), do: []

  defp ids(label, ids),
    do: ["#{label}: #{length(ids)} (#{ids |> Enum.take(10) |> Enum.map_join(", ", &inspect/1)})"]

  defp open(username, file, key) do
    path =
      Enum.find(
        [Accounts.store_path(username, file), Path.join(Legacy.dir(username), file)],
        &File.regular?/1
      )

    with path when is_binary(path) <- path,
         {:ok, blob} <- File.read(path),
         {:ok, term} <- Vault.open(key, blob) do
      term
    else
      _none -> nil
    end
  end

  # Each item's versions, by the digest the file is named with.
  defp versions_before(username, kind, key) do
    dirs = [
      Accounts.store_path(username, Path.join("versions", kind)),
      Path.join([Legacy.dir(username), "versions", kind])
    ]

    for dir <- dirs,
        path <- Path.wildcard(Path.join(dir, "*.bin")),
        {:ok, blob} <- [File.read(path)],
        {:ok, list} when is_list(list) <- [Vault.open(key, blob)],
        into: %{},
        do: {Path.basename(path), list}
  end

  defp list(nil), do: []
  defp list(items) when is_list(items), do: items

  defp items(kind, before, now, fields) do
    old = Map.new(before, &{&1.id, &1})
    new = Map.new(now, &{&1.id, &1})

    differing =
      for {id, item} <- old,
          {:ok, current} <- [Map.fetch(new, id)],
          fields = Enum.reject(fields, &(norm(Map.get(item, &1)) == norm(Map.get(current, &1)))),
          fields != [],
          do: {id, fields}

    result(kind, old, new, differing)
  end

  defp versions(kind, items, files, fetch) do
    old =
      for item <- items,
          list = Map.get(files || %{}, digest(item.id), []),
          list != [],
          into: %{},
          do: {item.id, list}

    new =
      for item <- items,
          list = fetch.(item.id),
          list != [],
          into: %{},
          do: {item.id, list}

    differing =
      for {id, list} <- old,
          {:ok, current} <- [Map.fetch(new, id)],
          norm(Enum.map(list, &version/1)) != norm(Enum.map(current, &version/1)),
          do: {id, [:versions]}

    result(kind, count(old), count(new), old, new, differing)
  end

  defp version(v), do: {v.version, v.content, v.saved_at, v.replaced_at, v.replaced_by, v.how}

  defp count(map), do: map |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  defp settings(nil, _now), do: result("flash card settings", 0, 0, %{}, %{}, [])

  defp settings(%{settings: settings}, now) do
    differing =
      if Map.from_struct(settings) == Map.from_struct(now),
        do: [],
        else: [{:settings, [:settings]}]

    result("flash card settings", 1, 1, %{}, %{}, differing)
  end

  defp history(before, now) do
    old =
      Map.new(before, fn {id, metadata, request, response} ->
        {id, {metadata, request, response}}
      end)

    new =
      Map.new(now, fn {id, metadata, request, response} -> {id, {metadata, request, response}} end)

    differing =
      for {id, {metadata, request, response}} <- old,
          {:ok, {m, r, p}} <- [Map.fetch(new, id)],
          fields =
            [
              {:description, metadata.description == m.description},
              {:tags, metadata.tags == m.tags},
              {:started_at, norm(metadata.started_at) == norm(m.started_at)},
              {:completed_at, norm(metadata.completed_at) == norm(m.completed_at)},
              {:duration_ms, metadata.duration_ms == m.duration_ms},
              {:request, request == r},
              {:response, response == p}
            ]
            |> Enum.reject(&elem(&1, 1))
            |> Enum.map(&elem(&1, 0)),
          fields != [],
          do: {id, fields}

    result("HTTP history", old, new, differing)
  end

  defp mcp(nil, username),
    do: result("MCP access", 0, if(Access.enabled?(username), do: 1, else: 0), %{}, %{}, [])

  defp mcp(%{hash: hash}, username) do
    differing =
      case Documents.get(username, "mcp.access") do
        {:ok, %{hash: ^hash}} -> []
        _other -> [{:token, [:hash]}]
      end

    result("MCP access", 1, if(Access.enabled?(username), do: 1, else: 0), %{}, %{}, differing)
  end

  defp threads(nil, now), do: result("agent threads", %{}, Map.new(now, &{&1.id, &1}), [])

  defp threads(%{threads: before}, now) do
    old = Map.new(before, &{&1.id, &1})
    new = Map.new(now, &{&1.id, &1})
    result("agent threads", old, new, [])
  end

  defp sandbox(nil, _username), do: result("sandbox", 0, 0, %{}, %{}, [])

  defp sandbox(before, username) do
    now =
      case Documents.get(username, "sandbox") do
        {:ok, saved} -> saved
        :none -> %{}
      end

    differing =
      [
        {:grants, keys(before[:grants], & &1.id) == keys(now[:grants], & &1.id)},
        {:projects, keys(before[:projects], & &1.name) == keys(now[:projects], & &1.name)},
        {:handoffs, keys(before[:handoffs], & &1.id) == keys(now[:handoffs], & &1.id)},
        {:ca, before[:ca] == now[:ca]}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    result(
      "sandbox",
      1,
      if(now == %{}, do: 0, else: 1),
      %{},
      %{},
      if(differing == [], do: [], else: [{:state, differing}])
    )
  end

  defp keys(nil, _fun), do: []
  defp keys(list, fun), do: list |> Enum.map(fun) |> Enum.sort()

  defp result(kind, old, new, differing),
    do: result(kind, map_size(old), map_size(new), old, new, differing)

  defp result(kind, before, now, old, new, differing) do
    %{
      kind: kind,
      before: before,
      now: now,
      missing: old |> Map.keys() |> Enum.reject(&Map.has_key?(new, &1)) |> Enum.sort(),
      extra: new |> Map.keys() |> Enum.reject(&Map.has_key?(old, &1)) |> Enum.sort(),
      differing: Enum.sort(differing)
    }
  end

  # The name `MWTClient.Versions` gave an item's file.
  defp digest(id), do: Base.url_encode64(:crypto.hash(:sha256, id), padding: false) <> ".bin"

  # Times to the microsecond; structs as maps; the rest as it is.
  defp norm(%DateTime{} = at), do: {:time, DateTime.to_unix(at, :microsecond)}
  defp norm(%_{} = struct), do: struct |> Map.from_struct() |> norm()
  defp norm(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, norm(v)} end)
  defp norm(list) when is_list(list), do: Enum.map(list, &norm/1)
  defp norm(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> norm() |> List.to_tuple()
  defp norm(value), do: value
end
