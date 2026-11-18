defmodule MWTClient.Flashcards.Transfer do
  @moduledoc """
  Exports an identity's flash cards and session settings, and imports them
  back.

  A section is `%{cards: [map], settings: map}`, cards oldest change first,
  each map holding what a card is written with and how well it is
  remembered. Plain maps rather than structs, so a file never depends on how
  the struct looks in the build that wrote it; the search text is left out,
  since it is derived and rebuilt on the way back in.

  Cards are matched by identifier, which is random and so names the same
  card on any installation. New cards are added. Where both sides hold one,
  the version changed last wins, answers and removal included; should that be the
  imported one, and the version here says something else, the version here
  is kept beside it as a copy, so merging never loses a card written on this
  side. Merging keeps the settings here; replacing takes the file's.
  """

  @behaviour MWTClient.Transfer.Participant

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library
  alias MWTClient.Flashcards.Settings

  @damaged "The flash cards in this file are damaged."
  @fields [
    :id,
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
    :updated_at
  ]

  @impl true
  def key, do: "flashcards.library"

  @impl true
  def label, do: "Flash cards"

  @impl true
  def version, do: 1

  @impl true
  def export(username) do
    {:ok,
     %{
       cards: username |> Library.all() |> Enum.map(&Map.take(&1, @fields)),
       settings: username |> Library.settings() |> Map.from_struct()
     }}
  end

  @impl true
  def prepare(1, %{cards: cards, settings: settings}) when is_list(cards) and is_map(settings) do
    cards
    |> Enum.reduce_while([], fn card, prepared ->
      case prepare_card(card) do
        {:ok, card} -> {:cont, [card | prepared]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        {:error, @damaged}

      prepared ->
        {:ok, %{cards: Enum.reverse(prepared), settings: Settings.change(%Settings{}, settings)}}
    end
  end

  def prepare(_version, _data), do: {:error, @damaged}

  @impl true
  def describe(%{cards: []}), do: "No flash cards"
  def describe(%{cards: [_card]}), do: "1 flash card"
  def describe(%{cards: cards}), do: "#{length(cards)} flash cards"

  @impl true
  def merge(username, %{cards: cards}), do: Library.rewrite(username, &combine(&1, cards))

  @impl true
  def replace(username, %{cards: cards, settings: settings}) do
    :ok = Library.rewrite(username, fn _current -> cards end)
    {:ok, _settings} = Library.put_settings(username, settings)
    :ok
  end

  defp combine(current, imported) do
    here = Map.new(current, &{&1.id, &1})

    imported
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(here, fn theirs, cards ->
      case Map.fetch(cards, theirs.id) do
        :error ->
          Map.put(cards, theirs.id, theirs)

        {:ok, mine} ->
          case DateTime.compare(theirs.updated_at, mine.updated_at) do
            :gt -> cards |> Map.put(theirs.id, theirs) |> keep_aside(mine, theirs)
            _not_newer -> cards
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at, DateTime)
  end

  # The copy's identifier is derived from the version it keeps, so importing
  # the same file again finds it already there rather than making another.
  # Answers alone don't make a copy: the newer answers simply win.
  defp keep_aside(cards, mine, theirs) do
    if {mine.front, mine.back, mine.tags, mine.source} ==
         {theirs.front, theirs.back, theirs.tags, theirs.source} do
      cards
    else
      stamp = DateTime.to_unix(mine.updated_at, :microsecond)
      id = :sha256 |> :crypto.hash("#{mine.id}:#{stamp}") |> binary_part(0, 12)
      copy = %{mine | id: Base.url_encode64(id, padding: false)}
      Map.put_new(cards, copy.id, copy)
    end
  end

  # Checked as strictly as a card written here, since sessions order and
  # match by these fields.
  defp prepare_card(
         %{
           id: id,
           box: box,
           due_at: %DateTime{},
           reviewed_at: reviewed_at,
           reviews: reviews,
           lapses: lapses,
           removed_at: removed_at,
           created_at: %DateTime{},
           updated_at: %DateTime{}
         } = card
       )
       when is_integer(box) and box in 0..6 and is_integer(reviews) and reviews >= 0 and
              is_integer(lapses) and lapses >= 0 and
              (is_nil(reviewed_at) or is_struct(reviewed_at, DateTime)) and
              (is_nil(removed_at) or is_struct(removed_at, DateTime)) do
    with true <- Card.id?(id),
         {:ok, written} <- Card.validate(Map.take(card, [:front, :back, :tags, :source])),
         true <- Map.has_key?(written, :front) and Map.has_key?(written, :back) do
      {:ok, card |> Map.take(@fields) |> Map.merge(written) |> Card.new()}
    else
      _invalid -> :error
    end
  end

  defp prepare_card(_card), do: :error
end
