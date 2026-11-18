defmodule MWTClient.Flashcards.ScheduleTest do
  use ExUnit.Case, async: true

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Schedule

  @now ~U[2026-11-15 12:00:00.000000Z]

  test "votes move a card between boxes" do
    # From each box, where each vote takes it; box 0 is a card never answered.
    for {box, forgot, hard, good, easy} <- [
          {0, 1, 1, 2, 3},
          {1, 1, 1, 2, 3},
          {3, 1, 3, 4, 5},
          {5, 1, 5, 6, 6},
          {6, 1, 6, 6, 6}
        ] do
      assert Enum.map(Schedule.grades(), &Schedule.next_box(box, &1)) == [
               forgot,
               hard,
               good,
               easy
             ],
             "from box #{box}"
    end
  end

  test "an answer sets when the card is due and counts it" do
    card = Card.new(%{front: "Q", back: "A", created_at: ~U[2026-11-01 12:00:00.000000Z]})

    good = Schedule.answer(card, :good, @now)

    assert {good.box, good.due_at, good.reviews, good.lapses} ==
             {2, DateTime.add(@now, 1, :day), 1, 0}

    assert good.reviewed_at == @now

    forgot = Schedule.answer(good, :forgot, @now)
    assert {forgot.box, forgot.due_at, forgot.reviews, forgot.lapses} == {1, @now, 2, 1}

    easy = Schedule.answer(%{card | box: 4}, :easy, @now)
    assert {easy.box, easy.due_at} == {6, DateTime.add(@now, 35, :day)}
  end

  test "the vote buttons show the wait each vote gives" do
    assert Schedule.preview(%Card{box: 0}) == %{forgot: 0, hard: 0, good: 1, easy: 3}
    assert Schedule.preview(%Card{box: 4}) == %{forgot: 0, hard: 7, good: 16, easy: 35}
  end

  test "reads votes by name and nothing else" do
    assert Schedule.grade("good") == {:ok, :good}
    assert Schedule.grade(:easy) == {:ok, :easy}
    assert Schedule.grade("great") == :error
    assert Schedule.grade(nil) == :error
  end

  describe "pick/4" do
    setup do
      due = fn id, box, days_ago ->
        %Card{id: id, box: box, due_at: DateTime.add(@now, -days_ago, :day)}
      end

      later = fn id, box, days_ahead ->
        %Card{id: id, box: box, due_at: DateTime.add(@now, days_ahead, :day)}
      end

      cards = [
        due.("known-overdue", 5, 10),
        due.("forgotten", 1, 0),
        due.("new", 0, 2),
        due.("learning", 2, 1),
        later.("soon", 3, 1),
        later.("far", 6, 30)
      ]

      %{cards: cards}
    end

    test "asks the cards due, the least known first", %{cards: cards} do
      assert ids(Schedule.pick(cards, 2, true, @now)) == MapSet.new(["new", "forgotten"])

      assert ids(Schedule.pick(cards, 3, true, @now)) ==
               MapSet.new(["new", "forgotten", "learning"])
    end

    test "fills a short session with the cards coming due soonest", %{cards: cards} do
      assert ids(Schedule.pick(cards, 5, true, @now)) ==
               MapSet.new(["new", "forgotten", "learning", "known-overdue", "soon"])

      assert length(Schedule.pick(cards, 50, true, @now)) == 6
    end

    test "without filling, asks only the cards due", %{cards: cards} do
      assert ids(Schedule.pick(cards, 50, false, @now)) ==
               MapSet.new(["new", "forgotten", "learning", "known-overdue"])

      assert Schedule.pick(Enum.take(cards, -2), 10, false, @now) == []
    end
  end

  defp ids(cards), do: MapSet.new(cards, & &1.id)
end
