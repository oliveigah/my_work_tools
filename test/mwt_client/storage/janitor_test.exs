defmodule MWTClient.Storage.JanitorTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias Exqlite.Sqlite3
  alias MWTClient.Accounts
  alias MWTClient.HttpClient.{HistoryMetadata, Resources}
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note
  alias MWTClient.Storage

  alias MWTClient.Storage.{
    Backups,
    Database,
    Janitor,
    Journal,
    Legacy,
    Maintenance,
    Retention,
    Usage
  }

  setup do
    unlocked_identity()
  end

  defp record(username, path, days_ago, response \\ %Req.Response{status: 200, body: "the body"}) do
    at = DateTime.add(DateTime.utc_now(), -days_ago, :day)
    metadata = HistoryMetadata.new(%{started_at: at, completed_at: at})

    Resources.record(
      username,
      metadata,
      Req.new(url: "https://api.example.test" <> path),
      response
    )
  end

  defp event(username, id, days_ago) do
    at = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    Journal.record(username, %{
      id: id,
      at: DateTime.to_unix(at, :microsecond),
      outcome: "tunnel",
      summary: id,
      search_text: id
    })
  end

  defp events(username) do
    :ok = Journal.flush(username)

    Storage.run(username, :journal, fn repo ->
      repo.query!("SELECT id FROM events ORDER BY seq").rows |> List.flatten()
    end)
  end

  describe "HTTP history" do
    test "requests past their days go; samples never sent stay", %{username: username} do
      old = record(username, "/old", 100)
      new = record(username, "/new", 1)
      sample = record(username, "/sample", 400, nil)

      assert Resources.trim(username, %{days: 90, gb: nil}, DateTime.utc_now()) == 1
      assert Resources.get(username, old) == :error
      assert {:ok, _} = Resources.get(username, new)
      assert {:ok, {_, _, _, nil}} = Resources.get(username, sample)
    end

    test "bodies past their days go; the entry keeps its status, headers and search", %{
      username: username
    } do
      old = record(username, "/old", 30, %Req.Response{status: 201, body: "searchable body"})
      new = record(username, "/new", 1)

      assert Resources.drop_bodies(username, %{days: 7}, DateTime.utc_now()) == 1

      assert {:ok, {^old, _, _, %Req.Response{status: 201, body: ""}}} =
               Resources.get(username, old)

      assert {:ok, {^old, _, _, {:response, 201, _, 0}}} = Resources.outline(username, old)
      assert [{^old, _, _, _}] = Resources.search(username, "searchable body")
      assert {:ok, {_, _, _, %Req.Response{body: "the body"}}} = Resources.get(username, new)
      assert Resources.drop_bodies(username, %{days: 7}, DateTime.utc_now()) == 0
    end
  end

  test "agent activity past its days goes", %{username: username} do
    event(username, "old", 200)
    event(username, "new", 1)

    assert Journal.trim(username, %{days: 180, gb: nil}, DateTime.utc_now()) == 1
    assert events(username) == ["new"]
  end

  # Without auto_vacuum the file never shrinks on its own: a size limit that
  # counted it would delete for ever. Limits count the pages in use.
  test "what a kind takes is its pages in use, not the file", %{username: username} do
    # Its tables and indexes take a page each when empty.
    empty = Usage.group_bytes(username, :journal, "events")
    for n <- 1..3_000, do: event(username, "e#{n}", 1)
    events(username)
    full = Usage.group_bytes(username, :journal, "events")
    file = Usage.file_bytes(username, :journal)

    :ok = Maintenance.clear(username, "agent_activity")

    assert Usage.group_bytes(username, :journal, "events") < empty + div(full - empty, 10)
    assert Usage.file_bytes(username, :journal) >= div(file, 2)
    assert Usage.free_bytes(username, :journal) > 0
  end

  test "files from before go once their days have passed since they retired", %{
    username: username
  } do
    File.write!(Accounts.store_path(username, "old.bin"), "old")
    File.write!(Accounts.store_path(username, "new.bin"), "new")
    Legacy.retire(username, "old.bin")
    Legacy.retire(username, "new.bin")
    old = Path.join(Legacy.dir(username), "old.bin")
    File.touch!(old, System.os_time(:second) - 40 * 86_400)

    assert Legacy.trim(username, %{days: nil}, DateTime.utc_now()) == 0
    assert Legacy.trim(username, %{days: 30}, DateTime.utc_now()) == 1
    refute File.exists?(old)
    assert File.exists?(Path.join(Legacy.dir(username), "new.bin"))
  end

  test "a backup is both databases, encrypted, with vault.json; the newest few are kept", %{
    username: username,
    key: key
  } do
    {:ok, _note} = Notes.save(username, Note.new_id(), %{title: "Backed up", body: "secret plan"})

    assert {:ok, backup} = Backups.create(username, ~U[2026-11-01 10:00:00Z])
    dir = Path.join(Backups.dir(username), backup.name)
    assert File.ls!(dir) |> Enum.sort() == ~w(journal.db library.db vault.json)
    refute File.read!(Path.join(dir, "library.db")) =~ "secret plan"

    # It opens with the identity's own key.
    {:ok, data_key, storage} = Accounts.data_key(username, key)

    {:ok, db} =
      Sqlite3.open(Database.uri(Path.join(dir, "library.db"), storage), mode: [:readonly])

    :ok =
      Sqlite3.execute(
        db,
        "PRAGMA key = #{Database.secret(Storage.database_key(data_key, :library))}"
      )

    {:ok, statement} = Sqlite3.prepare(db, "SELECT title FROM notes")
    assert {:ok, [["Backed up"]]} = Sqlite3.fetch_all(db, statement)
    Sqlite3.close(db)

    for day <- 2..4,
        do:
          {:ok, _} =
            Backups.create(
              username,
              DateTime.new!(~D[2026-11-01], ~T[10:00:00]) |> DateTime.add(day, :day)
            )

    {:ok, _rule} = Retention.put(username, "backups", %{"count" => "2"})
    assert Backups.trim(username, Retention.rule(username, "backups")) == 2
    assert [%{name: "20261105T100000Z"}, %{name: "20261104T100000Z"}] = Backups.list(username)
  end

  test "a sweep applies every rule, each by its own module", %{username: username} do
    old = record(username, "/old", 100)
    event(username, "old", 200)
    {:ok, _rule} = Retention.put(username, "http_history", %{"days" => "200"})

    removed = Janitor.sweep(username)

    assert Map.keys(removed) |> Enum.sort() == Enum.sort(Janitor.kinds())
    assert removed["agent_activity"] == 1
    assert removed["http_history"] == 0
    assert {:ok, _} = Resources.get(username, old)
  end

  test "compact, check and clear, on demand", %{username: username} do
    record(username, "/one", 1)
    sample = record(username, "/sample", 1, nil)
    event(username, "e", 1)

    assert %{library: {_, _}, journal: {before, now}} = Maintenance.compact(username)
    assert is_integer(before) and is_integer(now)
    assert Maintenance.check(username) == %{library: :ok, journal: :ok}

    :ok = Maintenance.clear(username, "http_history")
    assert [{^sample, _, _, _}] = Resources.all(username)
    :ok = Maintenance.clear(username, "agent_activity")
    assert events(username) == []
  end

  test "what each kind takes is measured", %{username: username} do
    {:ok, _note} = Notes.save(username, Note.new_id(), %{body: "one"})
    record(username, "/one", 1)
    event(username, "e", 1)

    usage = Usage.summary(username)

    assert %{items: 1, bytes: bytes} = usage.kinds["notes"]
    assert bytes > 0
    assert %{items: 1, oldest: %DateTime{}} = usage.kinds["http_history"]
    assert %{items: 1} = usage.kinds["agent_activity"]
    assert usage.files.library.bytes > 0

    for kind <- Retention.kinds(),
        kind.key not in ~w(vm_snapshots vm_images),
        do: assert(Map.has_key?(usage.kinds, kind.key), kind.key)
  end
end
