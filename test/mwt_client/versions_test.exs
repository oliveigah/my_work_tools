defmodule MWTClient.VersionsTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Flashcards.Library, as: Flashcards
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note
  alias MWTClient.Versions

  @vm {:agent, :vm, %{agent: "claude", thread: "Design the MCP grant"}}

  setup do
    unlocked_identity()
  end

  describe "notes" do
    test "an agent's change keeps what it replaced, and restoring brings it back", %{
      username: username
    } do
      {:ok, note} = Notes.save(username, Note.new_id(), %{title: "Plan", body: "Mine"})
      assert note.version == 1

      {:ok, changed} = Notes.update(username, note.id, %{body: "The agent's"}, by: @vm)
      assert changed.version == 2

      assert [kept] = Notes.versions(username, note.id)
      assert kept.version == 1
      assert kept.content == %{title: "Plan", body: "Mine"}
      assert kept.replaced_by == @vm
      assert kept.how == :edit
      assert Versions.who(kept.replaced_by) == "claude in the VM"

      {:ok, restored} = Notes.restore_version(username, note.id, 1)
      assert {restored.body, restored.version} == {"Mine", 3}

      # The restore kept the agent's text, so it is undone the same way.
      assert [undo, ^kept] = Notes.versions(username, note.id)
      assert {undo.content.body, undo.how, undo.replaced_by} == {"The agent's", :restore, :you}

      {:ok, again} = Notes.restore_version(username, note.id, undo.version)
      assert again.body == "The agent's"
      assert Notes.restore_version(username, note.id, 99) == :error
    end

    test "your own typing keeps one version per burst, and the first edit after an agent's",
         %{username: username} do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "a"})

      for body <- ["ab", "abc", "abcd"],
          do: {:ok, _} = Notes.save(username, note.id, %{body: body})

      assert [%{content: %{body: "a"}}] = Notes.versions(username, note.id)

      {:ok, _} = Notes.update(username, note.id, %{body: "agent"}, by: {:agent, :local})
      {:ok, _} = Notes.save(username, note.id, %{body: "agent, then me"})

      assert [%{content: %{body: "agent"}, replaced_by: :you}, %{content: %{body: "abcd"}}, _] =
               Notes.versions(username, note.id)
    end

    test "a change based on an older version is refused", %{username: username} do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "one"})
      {:ok, _} = Notes.save(username, note.id, %{body: "two"})

      assert {:stale, current} =
               Notes.update(username, note.id, %{body: "agent"}, by: @vm, version: 1)

      assert {current.body, current.version} == {"two", 2}

      assert {:ok, %{body: "agent"}} =
               Notes.update(username, note.id, %{body: "agent"}, version: 2)
    end

    test "marking done is not a version", %{username: username} do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "task"})
      {:ok, done} = Notes.set_done(username, note.id, true)

      assert done.version == 1
      assert Notes.versions(username, note.id) == []
    end

    test "deleting a note forgets its versions, and so does an import replacing it", %{
      username: username
    } do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "a"})
      {:ok, _} = Notes.update(username, note.id, %{body: "b"}, by: @vm)
      {:ok, other} = Notes.save(username, Note.new_id(), %{body: "c"})
      {:ok, _} = Notes.update(username, other.id, %{body: "d"}, by: @vm)

      :ok = Notes.delete(username, note.id)
      assert Notes.versions(username, note.id) == []

      :ok = Notes.rewrite(username, fn _notes -> [] end)
      assert Notes.versions(username, other.id) == []
    end

    test "versions are kept encrypted", %{username: username} do
      {:ok, note} = Notes.save(username, Note.new_id(), %{body: "the secret plan"})
      {:ok, _} = Notes.update(username, note.id, %{body: "b"}, by: @vm)

      assert [%{content: %{body: "the secret plan"}}] = Notes.versions(username, note.id)
      refute on_disk(username) =~ "secret"
    end
  end

  test "diagrams keep their title and elements", %{username: username} do
    {:ok, diagram} =
      Diagrams.save(username, Diagram.new_id(), %{title: "Flow", elements: [box("a")]})

    {:ok, changed} =
      Diagrams.update(username, diagram.id, %{elements: [box("b")]}, by: @vm, version: 1)

    assert changed.version == 2
    assert {:stale, _} = Diagrams.update(username, diagram.id, %{title: "x"}, version: 1)

    assert [%{content: %{title: "Flow", elements: [%{"id" => "a"}]}}] =
             Diagrams.versions(username, diagram.id)

    {:ok, restored} = Diagrams.restore_version(username, diagram.id, 1)
    assert [%{"id" => "a"}] = restored.elements
  end

  test "cards keep their words, not how well they are known", %{username: username} do
    {:ok, [{:created, card}]} =
      Flashcards.create(username, [%{front: "Why?", back: "Because.", tags: ["mwt"]}])

    {:ok, reviewed} = Flashcards.review(username, card.id, :good)
    assert reviewed.version == 1

    {:ok, changed} =
      Flashcards.update(username, card.id, %{back: "Because, really."}, by: @vm, version: 1)

    assert changed.version == 2

    assert [%{content: %{front: "Why?", back: "Because.", tags: ["mwt"], source: nil}}] =
             Flashcards.versions(username, card.id)

    {:ok, restored} = Flashcards.restore_version(username, card.id, 1)
    assert {restored.back, restored.box} == {"Because.", reviewed.box}
    assert {:stale, _} = Flashcards.update(username, card.id, %{front: "?"}, version: 2)
  end

  test "your editing keeps another version once 10 minutes passed", %{username: username} do
    versions = Versions.open(username, "notes")
    before = fn n -> %{version: n, content: %{body: "#{n}"}, saved_at: DateTime.utc_now()} end

    versions = Versions.changed(versions, "n", before.(1), :you, :edit)
    versions = Versions.changed(versions, "n", before.(2), :you, :edit)
    assert length(Versions.list(versions, "n")) == 1

    eleven_minutes_ago = System.monotonic_time(:millisecond) - 11 * 60 * 1000
    versions = put_in(versions.recent["n"].kept, eleven_minutes_ago)
    versions = Versions.changed(versions, "n", before.(3), :you, :edit)
    assert [%{version: 3}, %{version: 1}] = Versions.list(versions, "n")
  end

  test "a version the same as the newest one kept is not kept twice", %{username: username} do
    versions = Versions.open(username, "notes")
    before = fn n -> %{version: n, content: %{body: "same"}, saved_at: DateTime.utc_now()} end

    versions = Versions.changed(versions, "n", before.(1), {:agent, :local}, :edit)
    versions = Versions.changed(versions, "n", before.(2), {:agent, :local}, :edit)

    assert [%{version: 1}] = Versions.list(versions, "n")
  end

  test "at most as many versions per item as the rule says, the oldest dropped", %{
    username: username
  } do
    assert MWTClient.Storage.Retention.rule(username, "note_versions").most == 100
    {:ok, _rule} = MWTClient.Storage.Retention.put(username, "note_versions", %{most: 50})
    versions = Versions.open(username, "notes")

    versions =
      Enum.reduce(1..55, versions, fn n, acc ->
        before = %{version: n, content: %{body: "#{n}"}, saved_at: DateTime.utc_now()}
        Versions.changed(acc, "n", before, {:agent, :local}, :edit)
      end)

    list = Versions.list(versions, "n")
    assert length(list) == 50
    assert {hd(list).version, List.last(list).version} == {55, 6}
  end

  defp box(id),
    do: %{
      "id" => id,
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 10,
      "height" => 10
    }
end
