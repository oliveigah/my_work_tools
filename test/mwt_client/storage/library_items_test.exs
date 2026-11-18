defmodule MWTClient.Storage.LibraryItemsTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library, as: Flashcards
  alias MWTClient.Flashcards.Settings
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note
  alias MWTClient.Storage
  alias MWTClient.Storage.ImportCheck
  alias MWTClient.Storage.Legacy
  alias MWTClient.Vault
  alias MWTClient.Vault.Store
  alias MWTClient.Versions.Version

  setup do
    unlocked_identity()
  end

  describe "the files from before library.db" do
    test "come in at the first unlock, with versions and settings, and move to legacy/", %{
      username: username,
      key: key
    } do
      note = Note.new(%{title: "Release", body: "Tag the build"})
      diagram = Diagram.new(%{title: "Flow", elements: [box("a", "Gateway")]})
      {:ok, attrs} = Card.validate(%{front: "Why?", back: "Because.", tags: ["mwt"]})
      card = Card.new(attrs)
      settings = %Settings{session_size: 25, fill: false}
      :ok = Store.close(username)

      seal(username, key, "notes.bin", [note])
      seal(username, key, "diagrams.bin", [diagram])
      seal(username, key, "flashcards.bin", %{cards: [card], settings: settings})

      seal(username, key, versions_file("notes", note.id), [
        version(2, "newer"),
        version(1, "first")
      ])

      seal(username, key, versions_file("notes", "deleted-since"), [version(1, "orphan")])

      :ok = Store.open(username, key)

      assert Notes.get(username, note.id) == {:ok, note}
      assert [%{id: id}] = Notes.list(username, "tag build")
      assert id == note.id
      assert Diagrams.get(username, diagram.id) == {:ok, diagram}
      assert [_found] = Diagrams.list(username, "gateway")
      assert Flashcards.get(username, card.id) == {:ok, card}
      assert Flashcards.settings(username) == settings

      assert [%{version: 2, content: %{body: "newer"}}, %{version: 1}] =
               Notes.versions(username, note.id)

      dir = Accounts.dir(username)

      for file <- ["notes.bin", "diagrams.bin", "flashcards.bin", "versions/notes"] do
        refute File.exists?(Path.join(dir, file)), file
        assert File.exists?(Path.join([dir, "legacy", file])), file
      end

      refute File.exists?(Path.join(dir, "versions"))
    end

    test "an import cut short is made again, keeping what came in the first time", %{
      username: username,
      key: key
    } do
      note = Note.new(%{title: "Kept", body: "first import"})
      :ok = Store.close(username)
      seal(username, key, "notes.bin", [note])
      seal(username, key, versions_file("notes", note.id), [version(1, "before")])
      :ok = Store.open(username, key)
      {:ok, edited} = Notes.save(username, note.id, %{body: "edited since"})
      :ok = Store.close(username)

      # As if the first import's files had never moved aside.
      changed = %{note | title: "Changed in the file"}
      other = Note.new(%{title: "Only in the file"})
      seal(username, key, "notes.bin", [changed, other])
      seal(username, key, versions_file("notes", note.id), [version(1, "before")])
      :ok = Store.open(username, key)

      assert Notes.get(username, note.id) == {:ok, edited}
      assert {:ok, _other} = Notes.get(username, other.id)

      assert [%{content: %{body: "first import"}}, %{content: %{body: "before"}}] =
               Notes.versions(username, note.id)

      assert [_first, _second] =
               username |> Accounts.dir() |> Path.join("legacy/notes.bin*") |> Path.wildcard()
    end

    @tag :capture_log
    test "a record that doesn't fit is kept aside, and the rest come in", %{
      username: username,
      key: key
    } do
      good = Note.new(%{title: "Fits"})
      # An older build could keep a note without a time; the table can't.
      odd = %{Note.new(%{title: "Doesn't"}) | created_at: nil}

      sent =
        {7, MWTClient.HttpClient.HistoryMetadata.new(%{}), Req.new(url: "https://a.test"), nil}

      :ok = Store.close(username)
      seal(username, key, "notes.bin", [odd, good])
      seal(username, key, "http_history.bin", [sent, {:not, :an, :entry}])

      :ok = Store.open(username, key)

      assert {:ok, _} = Notes.get(username, good.id)
      assert Notes.get(username, odd.id) == :error
      assert {:ok, {7, _, _, nil}} = MWTClient.HttpClient.Resources.get(username, 7)

      assert %{"notes.bin" => %{count: 1, kept: kept}, "http_history.bin" => %{count: 1}} =
               Legacy.failures(username)

      blob = File.read!(Path.join(Legacy.dir(username), kept))
      assert {:ok, [%Note{id: id}]} = Vault.open(key, blob)
      assert id == odd.id
    end

    @tag :capture_log
    test "one that holds what its app can't read is set aside", %{username: username, key: key} do
      :ok = Store.close(username)
      seal(username, key, "notes.bin", %{not: "a list"})

      :ok = Store.open(username, key)

      assert Notes.list(username) == []

      assert [_corrupt] =
               username
               |> Accounts.store_path("notes.bin")
               |> Kernel.<>(".*.corrupt")
               |> Path.wildcard()
    end
  end

  describe "the import check" do
    test "finds nothing missing or different after an import, and names what differs", %{
      username: username,
      key: key
    } do
      note = Note.new(%{title: "Plan", body: "first"})
      diagram = Diagram.new(%{title: "Flow", elements: [box("a", "Gateway")]})
      {:ok, attrs} = Card.validate(%{front: "Why?", back: "Because."})
      card = Card.new(attrs)
      :ok = Store.close(username)
      seal(username, key, "notes.bin", [note])
      seal(username, key, "diagrams.bin", [diagram])
      seal(username, key, "flashcards.bin", %{cards: [card], settings: %Settings{}})
      seal(username, key, versions_file("notes", note.id), [version(1, "before")])

      before = ImportCheck.read_before(username, key)
      :ok = Store.open(username, key)

      results = ImportCheck.compare(username, before)
      assert Enum.all?(results, &(&1.missing == [] and &1.extra == [] and &1.differing == []))
      assert %{before: 1, now: 1} = Enum.find(results, &(&1.kind == "notes"))
      assert %{before: 1, now: 1} = Enum.find(results, &(&1.kind == "note versions"))

      {:ok, _} = Notes.save(username, note.id, %{body: "changed since"})
      changed = ImportCheck.compare(username, before)
      lines = ImportCheck.lines(changed, unlock_ms: 3, corrupt: [], not_imported: %{})

      assert %{differing: [{_id, [:body, :updated_at, :version]}]} =
               Enum.find(changed, &(&1.kind == "notes"))

      assert Enum.any?(lines, &(&1 =~ "differs:" and &1 =~ "body"))
      assert "first unlock: 3 ms" in lines
      refute Enum.any?(lines, &(&1 =~ "changed since" or &1 =~ "Plan"))
    end
  end

  describe "search" do
    test "finds every word anywhere, short ones and any case included", %{username: username} do
      {:ok, kafka} =
        Notes.save(username, Note.new_id(), %{
          title: "Kafka Leader Epoch",
          body: "The ÉCOLE note, \"quoted\"; it ends in go"
        })

      {:ok, other} = Notes.save(username, Note.new_id(), %{title: "Unrelated", body: "go on"})

      found = fn term -> username |> Notes.list(term) |> Enum.map(& &1.id) |> Enum.sort() end

      assert found.("leader kafka") == [kafka.id]
      assert found.("ead POC") == [kafka.id]
      assert found.("école") == [kafka.id]
      assert found.(~s("quoted";)) == [kafka.id]
      assert found.("go") == Enum.sort([kafka.id, other.id])
      assert found.("go epoch") == [kafka.id]
      assert found.("o n") == Enum.sort([kafka.id, other.id])
      assert found.("leader zzz") == []
      assert found.("zz") == []
    end

    test "follows every change: an edit, a delete, a rewrite", %{username: username} do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "alpha"})
      assert [_] = Notes.list(username, "alpha")

      {:ok, _} = Notes.save(username, note.id, %{body: "beta"})
      assert Notes.list(username, "alpha") == []
      assert [_] = Notes.list(username, "beta")

      :ok = Notes.delete(username, note.id)
      assert Notes.list(username, "beta") == []

      :ok = Notes.rewrite(username, fn [] -> [Note.new(%{body: "gamma"})] end)
      assert [_] = Notes.list(username, "gamma")
    end

    test "diagrams search their elements, and cards every side", %{username: username} do
      {:ok, _diagram} =
        Diagrams.save(username, Diagram.new_id(), %{
          title: "Flow",
          elements: [box("a", "Payment gateway")]
        })

      {:ok, [{:created, card}]} =
        Flashcards.create(username, [%{front: "Why?", back: "Warm builds.", source: "Thread"}])

      assert [%{title: "Flow"}] = Diagrams.list(username, "GATEWAY pay")
      assert Diagrams.list(username, "gateway nothing") == []
      assert [%{id: id}] = Flashcards.list(username, %{query: "warm thread"})
      assert id == card.id
    end
  end

  test "the database stays whole through every kind of change", %{username: username} do
    {:ok, note} = Notes.save(username, Note.new_id(), %{body: "one"})
    {:ok, _} = Notes.update(username, note.id, %{body: "two"}, by: {:agent, :local})
    {:ok, _} = Notes.set_done(username, note.id, true)
    {:ok, diagram} = Diagrams.save(username, Diagram.new_id(), %{elements: [box("a", "x")]})
    {:ok, _copy} = Diagrams.duplicate(username, diagram.id)
    {:ok, [{:created, card}]} = Flashcards.create(username, [%{front: "Q", back: "A"}])
    {:ok, _} = Flashcards.review(username, card.id, :good)
    :ok = Diagrams.delete(username, diagram.id)
    :ok = Notes.rewrite(username, fn notes -> notes ++ [Note.new(%{body: "three"})] end)

    Storage.run(username, :library, fn repo ->
      assert repo.query!("PRAGMA integrity_check").rows == [["ok"]]

      for index <- ~w(note_search diagram_search flashcard_search) do
        repo.query!("INSERT INTO #{index} (#{index}, rank) VALUES ('integrity-check', 1)")
      end
    end)
  end

  defp seal(username, key, file, term) do
    path = Accounts.store_path(username, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Vault.seal(key, term))
  end

  # Where `MWTClient.Versions` kept an item's versions before library.db.
  defp versions_file(kind, id) do
    Path.join([
      "versions",
      kind,
      Base.url_encode64(:crypto.hash(:sha256, id), padding: false) <> ".bin"
    ])
  end

  defp version(number, body) do
    %Version{
      version: number,
      content: %{title: "Kept", body: body},
      saved_at: DateTime.utc_now(),
      replaced_at: DateTime.utc_now(),
      replaced_by: {:agent, :local},
      how: :edit
    }
  end

  defp box(id, text) do
    %{
      "id" => id,
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 10,
      "height" => 10,
      "text" => text
    }
  end
end
