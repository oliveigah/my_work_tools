defmodule MWTClient.Flashcards.SessionTest do
  use ExUnit.Case, async: true

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Session

  setup do
    %{cards: Enum.map(~w(a b c), &%Card{id: &1, front: "Front #{&1}", back: "Back #{&1}"})}
  end

  test "asks each card, its answer shown only once flipped", %{cards: [a, b, c] = cards} do
    session = Session.new(cards)

    assert session.current == a
    refute session.flipped?
    assert {Session.answered(session), Session.left(session), Session.size(session)} == {0, 3, 3}

    session = session |> Session.flip() |> Session.answer(:good, a)
    assert session.current == b
    refute session.flipped?

    session = session |> Session.flip() |> Session.answer(:easy, b)
    session = session |> Session.flip() |> Session.answer(:hard, c)

    assert Session.done?(session)
    assert Session.tally(session) == %{forgot: 0, hard: 1, good: 1, easy: 1}
    assert Session.forgotten(session) == []
  end

  test "a card forgotten comes back at the end until it is remembered", %{
    cards: [a, b, c] = cards
  } do
    session = Session.new(cards)

    session = Session.answer(session, :forgot, %{a | box: 1})
    assert Enum.map(session.queue, & &1.id) == ["c", "a"]
    # It comes back as the vote left it.
    assert List.last(session.queue).box == 1

    session = session |> Session.answer(:good, b) |> Session.answer(:good, c)
    assert session.current.id == "a"

    session = Session.answer(session, :forgot, a)
    assert session.current.id == "a"

    session = Session.answer(session, :good, a)
    assert Session.done?(session)
    assert Session.answered(session) == 5

    # Counted by the first answer to each card.
    assert Session.tally(session) == %{forgot: 1, hard: 0, good: 2, easy: 0}
    assert Session.forgotten(session) == [{"a", "Front a"}]
  end

  test "without repeats, a card forgotten waits for the next session", %{cards: [a | _] = cards} do
    session = cards |> Session.new(repeat?: false) |> Session.answer(:forgot, a)
    assert Enum.map(session.queue, & &1.id) == ["c"]
  end

  test "a card removed leaves the session, repeats and all, and is listed", %{
    cards: [a, b, c] = cards
  } do
    session = cards |> Session.new() |> Session.answer(:forgot, a)
    assert Enum.map(session.queue, & &1.id) == ["c", "a"]

    session = session |> Session.answer(:good, b) |> Session.answer(:good, c)
    assert session.current.id == "a"

    session = Session.remove(session)
    assert Session.done?(session)
    assert Session.handled(session) == 4
    assert Session.removed(session) == [{"a", "Front a"}]

    # Put back in the deck, it is no longer listed as removed.
    assert Session.unremove(session, "a") |> Session.removed() == []

    session = cards |> Session.new() |> Session.remove()
    assert session.current.id == "b"
    assert {Session.handled(session), Session.left(session)} == {1, 2}
  end

  test "ending early counts the cards left", %{cards: [a | _] = cards} do
    session = cards |> Session.new() |> Session.answer(:good, a) |> Session.stop()

    assert Session.done?(session)
    assert session.skipped == 2
    assert Session.tally(session).good == 1
  end

  test "a card edited elsewhere is asked as it is now; one deleted is skipped", %{
    cards: [a, b, _c] = cards
  } do
    session = Session.new(cards)

    session = Session.refresh(session, %{b | front: "Edited"})
    assert Enum.find(session.queue, &(&1.id == "b")).front == "Edited"

    session = Session.refresh(session, %Card{id: "elsewhere", front: "Not asked"})
    assert Session.size(session) == 3

    session = Session.drop(session, a.id)
    assert session.current.id == "b"

    session = Session.drop(session, "c")
    assert session.queue == []
  end
end
