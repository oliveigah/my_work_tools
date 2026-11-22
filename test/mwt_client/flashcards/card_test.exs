defmodule MWTClient.Flashcards.CardTest do
  use ExUnit.Case, async: true

  alias MWTClient.Flashcards.Card

  describe "validate/1" do
    test "keeps what a card is written with, trimmed" do
      assert Card.validate(%{
               front: "  Why slots?\r\n",
               back: "Warm builds.",
               tags: [" mwt_client ", "agent   sandbox", "MWT_CLIENT", ""],
               source: "  Thread:   slots  "
             }) ==
               {:ok,
                %{
                  front: "Why slots?",
                  back: "Warm builds.",
                  tags: ["mwt_client", "agent sandbox"],
                  source: "Thread: slots"
                }}
    end

    test "checks only the fields given, so an update can name one" do
      assert Card.validate(%{back: "Only this"}) == {:ok, %{back: "Only this"}}
      assert Card.validate(%{}) == {:ok, %{}}
    end

    test "says what is wrong with each field" do
      assert {:error, errors} =
               Card.validate(%{
                 front: "   ",
                 back: String.duplicate("a", Card.max_back() + 1),
                 tags: Enum.map(1..11, &"c#{&1}"),
                 source: 42
               })

      assert errors == [
               front: "can't be blank",
               back: "is longer than #{Card.max_back()} characters",
               tags: "use at most 10 tags",
               source: "must be text"
             ]

      long = String.duplicate("x", 61)
      assert {:error, [tags: message]} = Card.validate(%{tags: [long]})
      assert message =~ "longer than 60"
      assert {:error, [tags: "must be a list of strings"]} = Card.validate(%{tags: [1]})
    end

    test "reads tags written with commas, and a blank source as none" do
      assert Card.validate(%{tags: "mwt_client, grants,, ", source: "  "}) ==
               {:ok, %{tags: ["mwt_client", "grants"], source: nil}}
    end
  end

  describe "the uncertain mark" do
    test "a note is kept trimmed, and nothing written is none" do
      assert Card.uncertain_note("  Still true?  ") == {:ok, "Still true?"}
      assert Card.uncertain_note("   ") == {:ok, nil}
      assert Card.uncertain_note(nil) == {:ok, nil}
      assert Card.uncertain_note(42) == {:error, "must be text"}

      assert Card.uncertain_note(String.duplicate("x", Card.max_uncertain_note() + 1)) ==
               {:error, "is longer than #{Card.max_uncertain_note()} characters"}
    end

    test "resolving takes the mark off and makes the card due, whatever its box" do
      marked_at = ~U[2026-11-01 10:00:00Z]
      now = ~U[2026-11-02 10:00:00Z]
      later = ~U[2026-12-01 10:00:00Z]
      card = Card.new(%{front: "Q", back: "A", box: 5, due_at: later})

      marked = Card.mark_uncertain(card, "Still?", marked_at)
      assert Card.uncertain?(marked)
      assert marked.updated_at == marked_at
      assert Card.mark_uncertain(marked, "Since X?", now).uncertain_at == marked_at

      resolved = Card.resolve(marked, now)
      refute Card.uncertain?(resolved)
      assert {resolved.uncertain_note, resolved.due_at, resolved.box} == {nil, now, 5}

      # Due already, it keeps how long it has been due; not marked, it is as it was.
      overdue = %{marked | due_at: marked_at}
      assert Card.resolve(overdue, now).due_at == marked_at
      assert Card.resolve(card, now) == card

      # An undo leaves when it is due alone.
      assert Card.unmark_uncertain(marked, now).due_at == later
    end
  end

  test "a new card is due as soon as it is written" do
    card = Card.new(%{front: "Q", back: "A"})

    assert Card.new?(card)
    assert card.box == 0
    assert card.due_at == card.created_at
    assert Card.due?(card, DateTime.utc_now())
  end

  test "updating with what is there already changes nothing" do
    card = Card.new(%{front: "Q", back: "A", tags: ["one"]})

    assert Card.update(card, %{front: "Q", tags: ["one"]}) == card

    updated = Card.update(card, %{back: "Another answer"})
    assert updated.back == "Another answer"
    assert Card.matches?(updated, ["another"])
    refute Card.matches?(updated, ["a", "zebra"])
  end

  test "two cards are the same when front and back say the same, case and spacing aside" do
    card = Card.new(%{front: "Why  slots?", back: "Warm builds."})

    assert Card.same?(card, %{front: "why slots?", back: "WARM\nbuilds."})
    refute Card.same?(card, %{front: "Why slots?", back: "Cold builds."})
  end

  test "scopes match any or all tags ignoring case, and the days since written" do
    now = ~U[2026-11-15 12:00:00Z]

    card =
      Card.new(%{
        front: "Q",
        back: "A",
        tags: ["Klife"],
        created_at: ~U[2026-11-10 12:00:00Z]
      })

    assert Card.tagged?(card, [])
    assert Card.tagged?(card, ["elixir", "klife"])
    refute Card.tagged?(card, ["elixir"])

    # Every tag asked, with :all.
    two = %{card | tags: ["Klife", "startup"]}
    assert Card.tagged?(two, ["STARTUP", "klife"], :all)
    refute Card.tagged?(two, ["klife", "elixir"], :all)
    assert Card.tagged?(two, [], :all)

    assert Card.within?(card, nil, now)
    assert Card.within?(card, 5, now)
    refute Card.within?(card, 4, now)
  end

  test "the front on one line, for lists" do
    assert Card.plain_front("# Why **slots**?\n\n- warm `deps`\n```\ncode\n```") ==
             "Why slots? warm `deps` code"
  end
end
