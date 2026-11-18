defmodule MWTClient.Flashcards.LibraryTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library
  alias MWTClient.Flashcards.Settings
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "writes cards, and a card already here only once", %{username: username} do
    cards = [
      %{front: "Why slots?", back: "Warm builds.", tags: ["mwt_client"]},
      %{front: "What is a handoff?", back: "Work offered to the user's branch."}
    ]

    assert {:ok, [{:created, slots}, {:created, handoff}]} = Library.create(username, cards)
    assert slots.tags == ["mwt_client"]
    assert handoff.tags == []
    assert {:ok, ^slots} = Library.get(username, slots.id)

    # Again, reworded only in case and spacing, and twice in one call.
    again = [
      %{front: "why  SLOTS?", back: "warm builds."},
      %{front: "New?", back: "Yes."},
      %{front: "New?", back: "yes."}
    ]

    assert {:ok, [{:existing, ^slots}, {:created, new}, {:existing, new}]} =
             Library.create(username, again)

    assert length(Library.list(username)) == 3
  end

  test "writes none of the cards when any is wrong", %{username: username} do
    assert Library.create(username, [%{front: "Fine", back: "Fine"}, %{front: "No answer"}]) ==
             {:error, [{1, [back: "can't be blank"]}]}

    assert Library.list(username) == []
  end

  test "a tag in use keeps its spelling", %{username: username} do
    {:ok, [{:created, _first}]} =
      Library.create(username, [%{front: "A", back: "a", tags: ["Klife"]}])

    {:ok, [{:created, second}, {:created, third}]} =
      Library.create(username, [
        %{front: "B", back: "b", tags: ["KLIFE", "Startup"]},
        %{front: "C", back: "c", tags: ["startup"]}
      ])

    assert second.tags == ["Klife", "Startup"]
    assert third.tags == ["Startup"]

    {:ok, third} = Library.update(username, third.id, %{tags: ["klife"]})
    assert third.tags == ["Klife"]

    assert Library.tags(username) == [
             %{name: "Klife", cards: 3, due: 3},
             %{name: "Startup", cards: 1, due: 1}
           ]
  end

  test "updating keeps how well a card is known", %{username: username} do
    {:ok, [{:created, card}]} = Library.create(username, [%{front: "Q", back: "A"}])
    {:ok, reviewed} = Library.review(username, card.id, :good)

    assert {:ok, updated} = Library.update(username, card.id, %{back: "Better answer"})
    assert {updated.back, updated.box, updated.due_at} == {"Better answer", 2, reviewed.due_at}

    assert Library.update(username, card.id, %{front: ""}) == {:error, [front: "can't be blank"]}
    assert Library.update(username, Card.new_id(), %{front: "Q"}) == :error
    assert Library.review(username, Card.new_id(), :good) == :error
  end

  test "lists by words, tags and how recently written, the newest first", %{
    username: username
  } do
    old = ~U[2026-01-01 00:00:00Z]

    {:ok, [{:created, recent}, {:created, other}]} =
      Library.create(username, [
        %{
          front: "Why slots?",
          back: "Warm builds.",
          tags: ["mwt_client"],
          source: "Thread: slots"
        },
        %{front: "Enum.at?", back: "Lists have no access syntax.", tags: ["elixir"]}
      ])

    :ok =
      Library.rewrite(username, fn cards ->
        Enum.map(cards, &if(&1.id == other.id, do: %{&1 | created_at: old}, else: &1))
      end)

    assert [%{id: first}, %{id: second}] = Library.list(username)
    assert {first, second} == {recent.id, other.id}

    assert [%{id: ^first}] = Library.list(username, %{query: "warm SLOTS"})
    assert [%{id: ^first}] = Library.list(username, %{query: "thread"})
    assert [%{id: ^second}] = Library.list(username, %{tags: ["ELIXIR", "nothing"]})
    assert [%{id: ^first}] = Library.list(username, %{days: 7})
    assert Library.list(username, %{days: 7, tags: ["elixir"]}) == []

    assert Library.count(username, %{tags: ["mwt_client"]}) == %{cards: 1, due: 1}
    assert Library.count(username, %{}) == %{cards: 2, due: 2}
  end

  test "a session picks the cards due in its scope", %{username: username} do
    {:ok, created} =
      Library.create(
        username,
        for(n <- 1..4, do: %{front: "Q#{n}", back: "A", tags: ["one"]})
      )

    [{:created, known} | _rest] = created
    {:ok, _known} = Library.review(username, known.id, :easy)

    assert length(Library.pick(username, %{tags: ["one"]}, 10)) == 4
    {:ok, _settings} = Library.put_settings(username, %{fill: false})
    picked = Library.pick(username, %{tags: ["one"]}, 10)
    assert length(picked) == 3
    refute known.id in Enum.map(picked, & &1.id)
    assert Library.pick(username, %{tags: ["two"]}, 10) == []
  end

  test "settings change as asked and stay in range", %{username: username} do
    assert Library.settings(username) == %Settings{
             session_size: 10,
             repeat_forgotten: true,
             fill: true
           }

    assert {:ok, %Settings{session_size: 100, repeat_forgotten: false, fill: true}} =
             Library.put_settings(username, %{
               "session_size" => "500",
               "repeat_forgotten" => "false"
             })

    assert {:ok, %Settings{session_size: 100}} =
             Library.put_settings(username, %{"session_size" => "lots"})

    assert {:ok, %Settings{session_size: 1}} = Library.put_settings(username, %{session_size: 0})
  end

  test "picks by any of the tags, or all of them", %{username: username} do
    {:ok, [{:created, both}, {:created, one}, {:created, _other}]} =
      Library.create(username, [
        %{front: "Both", back: "a", tags: ["mwt_client", "grants"]},
        %{front: "One", back: "b", tags: ["mwt_client"]},
        %{front: "Other", back: "c", tags: ["klife"]}
      ])

    assert ids(Library.list(username, %{tags: ["grants", "klife"]})) == 2
    assert [%{id: id}] = Library.list(username, %{tags: ["mwt_client", "grants"], match: :all})
    assert id == both.id
    assert Library.count(username, %{tags: ["mwt_client"], match: :all}) == %{cards: 2, due: 2}

    # The tags of the cards picked, so each count says what adding it leaves.
    assert Library.tags(username, %{tags: ["mwt_client"], match: :all}) == [
             %{name: "mwt_client", cards: 2, due: 2},
             %{name: "grants", cards: 1, due: 1}
           ]

    assert Enum.map(
             Library.pick(username, %{tags: ["grants", "mwt_client"], match: :all}, 10),
             & &1.id
           ) ==
             [both.id]

    refute one.id == both.id
  end

  test "a card removed leaves the deck, can be put back, and isn't written again", %{
    username: username
  } do
    {:ok, [{:created, card}, {:created, _kept}]} =
      Library.create(username, [
        %{front: "Not worth it?", back: "No.", tags: ["noise"]},
        %{front: "Worth it?", back: "Yes.", tags: ["signal"]}
      ])

    {:ok, reviewed} = Library.review(username, card.id, :good)
    assert {:ok, removed} = Library.remove(username, card.id)
    assert %DateTime{} = removed.removed_at
    assert {removed.box, removed.reviews} == {reviewed.box, reviewed.reviews}
    assert DateTime.compare(removed.updated_at, reviewed.updated_at) == :gt

    # Removing again keeps when it first was.
    assert {:ok, ^removed} = Library.remove(username, card.id)

    assert [%{front: "Worth it?"}] = Library.list(username)
    assert [%{id: id, removed_at: %DateTime{}}] = Library.list(username, %{removed: true})
    assert id == card.id
    assert Library.count(username, %{}) == %{cards: 1, due: 1}
    assert Library.count(username, %{removed: true}).cards == 1
    assert Library.tags(username) == [%{name: "signal", cards: 1, due: 1}]
    assert Library.pick(username, %{}, 10) |> Enum.map(& &1.front) == ["Worth it?"]

    # Written again, it is told it was removed, and stays out.
    assert {:ok, [{:removed, ^removed}]} =
             Library.create(username, [%{front: "not worth it?", back: "no."}])

    assert length(Library.list(username)) == 1

    assert {:ok, restored} = Library.restore(username, card.id)
    assert restored.removed_at == nil
    assert restored.box == reviewed.box
    assert length(Library.list(username)) == 2
    assert Library.remove(username, Card.new_id()) == :error
  end

  test "deletes", %{username: username} do
    {:ok, [{:created, card}]} = Library.create(username, [%{front: "Q", back: "A"}])

    assert Library.delete(username, card.id) == :ok
    assert Library.delete(username, card.id) == :error
    assert Library.list(username) == []
  end

  test "cards and settings are encrypted on disk and survive a restart", %{
    username: username,
    key: key
  } do
    {:ok, [{:created, card}]} =
      Library.create(username, [%{front: "Secret plans", back: "launch codes", tags: ["ops"]}])

    {:ok, card} = Library.review(username, card.id, :good)
    {:ok, settings} = Library.put_settings(username, %{session_size: 25})

    :ok = Store.close(username)

    blob = on_disk(username)
    assert byte_size(blob) > 0
    refute blob =~ "launch codes"
    refute blob =~ "Secret plans"

    :ok = Store.open(username, key)
    assert {:ok, ^card} = Library.get(username, card.id)
    assert Library.settings(username) == settings
  end

  @tag :capture_log
  test "a file that won't decrypt is kept aside, not overwritten", %{username: username, key: key} do
    :ok = Store.close(username)
    path = Accounts.store_path(username, "flashcards.bin")
    File.write!(path, "not a sealed file")

    :ok = Store.open(username, key)
    assert Library.list(username) == []
    assert [_corrupt] = Path.wildcard(path <> ".*.corrupt")
  end

  describe "subscribers" do
    setup %{username: username} do
      :ok = Library.subscribe(username)
      {:ok, [{:created, card}]} = Library.create(username, [%{front: "Mine", back: "A"}])
      # The process that made a change already has the answer to its call.
      refute_received {:flashcards_changed, _id}
      %{card: card}
    end

    test "hear about changes made by anyone else", %{username: username, card: card} do
      id = card.id
      elsewhere = fn fun -> Task.async(fun) |> Task.await() end

      elsewhere.(fn -> Library.update(username, id, %{back: "From elsewhere"}) end)
      assert_receive {:flashcards_changed, ^id}

      # Nothing changed, so nothing is said.
      elsewhere.(fn -> Library.update(username, id, %{back: "From elsewhere"}) end)
      elsewhere.(fn -> Library.create(username, [%{front: "Mine", back: "From elsewhere"}]) end)
      refute_receive {:flashcards_changed, _id}, 50

      elsewhere.(fn -> Library.review(username, id, :hard) end)
      assert_receive {:flashcards_changed, ^id}

      elsewhere.(fn ->
        Library.create(username, [%{front: "1", back: "1"}, %{front: "2", back: "2"}])
      end)

      assert_receive {:flashcards_changed, :all}

      elsewhere.(fn -> Library.put_settings(username, %{fill: false}) end)
      assert_receive {:flashcards_changed, :settings}

      elsewhere.(fn -> Library.delete(username, id) end)
      assert_receive {:flashcards_changed, ^id}
    end
  end

  defp ids(cards), do: length(cards)
end
