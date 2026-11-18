defmodule MWTClient.Flashcards.TransferTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library
  alias MWTClient.Flashcards.Settings
  alias MWTClient.Flashcards.Transfer

  setup do
    unlocked_identity()
  end

  test "an export comes back the same in another identity", %{username: username} do
    {:ok, [{:created, card}]} =
      Library.create(username, [
        %{front: "Why?", back: "Because.", tags: ["one"], source: "Thread"}
      ])

    {:ok, _card} = Library.review(username, card.id, :good)
    {:ok, card} = Library.remove(username, card.id)
    {:ok, settings} = Library.put_settings(username, %{session_size: 7, fill: false})

    {:ok, exported} = Transfer.export(username)
    {:ok, prepared} = Transfer.prepare(Transfer.version(), exported)
    assert Transfer.describe(prepared) == "1 flash card"

    other = also_unlock("other")
    :ok = Transfer.replace(other, prepared)

    assert {:ok, ^card} = Library.get(other, card.id)
    assert %DateTime{} = card.removed_at
    assert Library.settings(other) == settings
  end

  test "merging adds new cards and keeps the settings here", %{username: username} do
    mine = keep(username, card("Mine", ~U[2026-09-01 10:00:00.000001Z]))
    {:ok, settings} = Library.put_settings(username, %{session_size: 3})

    :ok =
      merge(username, [card("Theirs", ~U[2026-09-02 10:00:00.000001Z])], %Settings{
        session_size: 40
      })

    assert fronts(username) == ["Mine", "Theirs"]
    assert {:ok, ^mine} = Library.get(username, mine.id)
    assert Library.settings(username) == settings
  end

  test "a card both sides hold keeps the version changed last, answers included", %{
    username: username
  } do
    older = card("Plan", ~U[2026-09-01 10:00:00.000001Z])
    newer = %{older | box: 4, reviews: 3, updated_at: ~U[2026-09-05 10:00:00.000001Z]}

    keep(username, older)
    :ok = merge(username, [newer])
    assert {:ok, %{box: 4, reviews: 3}} = Library.get(username, older.id)
    # Answers alone make no copy.
    assert length(Library.list(username)) == 1

    # The older one coming back changes nothing.
    :ok = merge(username, [older])
    assert {:ok, %{box: 4}} = Library.get(username, older.id)
  end

  test "when the imported version wins, a card written differently here is kept beside it", %{
    username: username
  } do
    mine = keep(username, card("Plan", ~U[2026-09-01 10:00:00.000001Z], "local answer"))
    theirs = %{mine | back: "remote answer", updated_at: ~U[2026-09-05 10:00:00.000001Z]}

    :ok = merge(username, [theirs])

    assert {:ok, %{back: "remote answer"}} = Library.get(username, mine.id)
    assert [%{id: kept}] = Library.list(username, %{query: "local"})
    refute kept == mine.id

    # Merging the same file again finds the copy already kept.
    :ok = merge(username, [theirs])
    assert length(Library.list(username)) == 2
  end

  test "refuses damaged sections" do
    damaged = "The flash cards in this file are damaged."
    good = card("Fine", ~U[2026-09-01 10:00:00.000001Z]) |> Map.from_struct()

    assert Transfer.prepare(1, %{cards: [%{good | box: 9}], settings: %{}}) == {:error, damaged}

    assert Transfer.prepare(1, %{cards: [%{good | front: ""}], settings: %{}}) ==
             {:error, damaged}

    assert Transfer.prepare(1, %{cards: [%{good | id: "../x"}], settings: %{}}) ==
             {:error, damaged}

    assert Transfer.prepare(1, %{cards: :nope, settings: %{}}) == {:error, damaged}
    assert Transfer.prepare(2, %{cards: [], settings: %{}}) == {:error, damaged}
    assert {:ok, %{cards: [_card]}} = Transfer.prepare(1, %{cards: [good], settings: %{}})
  end

  defp card(front, updated_at, back \\ "Answer") do
    Card.new(%{
      front: front,
      back: back,
      tags: ["one"],
      created_at: ~U[2026-08-01 10:00:00.000001Z],
      updated_at: updated_at
    })
  end

  defp keep(username, card) do
    :ok = Library.rewrite(username, &[card | &1])
    card
  end

  defp merge(username, cards, settings \\ %Settings{}) do
    data = %{cards: Enum.map(cards, &Map.from_struct/1), settings: Map.from_struct(settings)}
    {:ok, prepared} = Transfer.prepare(Transfer.version(), data)
    Transfer.merge(username, prepared)
  end

  defp fronts(username), do: username |> Library.list() |> Enum.map(& &1.front) |> Enum.sort()
end
