defmodule MWTClient.Flashcards.Session do
  @moduledoc """
  A remember session under way: the card asked now, whether its answer is
  showing, the cards still to ask, and how each one was answered.

  It holds no store of its own. Each answer is kept by
  `MWTClient.Flashcards.Library.review/3` as it is given, so leaving a
  session part way loses nothing; this only says what to ask next.

  With `repeat?`, a card forgotten comes back at the end of the session, and
  again each time it is forgotten, so a session ends with every card
  remembered at least once, unless it is ended first.

  A card judged not worth remembering is removed instead of answered
  (`remove/1`): the session moves on and lists it at the end, where it can
  be put back. So is a card whose answer is doubted, marked uncertain
  instead of answered (`mark_uncertain/1`), listed at the end apart.
  """

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Schedule

  @type t :: %__MODULE__{
          current: Card.t() | nil,
          queue: [Card.t()],
          flipped?: boolean(),
          answers: [{String.t(), Schedule.grade()}],
          fronts: %{String.t() => String.t()},
          repeat?: boolean(),
          removed: [String.t()],
          uncertain: [String.t()],
          skipped: non_neg_integer()
        }

  defstruct current: nil,
            queue: [],
            flipped?: false,
            answers: [],
            fronts: %{},
            repeat?: true,
            removed: [],
            uncertain: [],
            skipped: 0

  @doc "A session asking `cards` in order."
  @spec new([Card.t()], keyword()) :: t()
  def new(cards, opts \\ []) do
    {current, queue} =
      case cards do
        [] -> {nil, []}
        [first | rest] -> {first, rest}
      end

    %__MODULE__{
      current: current,
      queue: queue,
      repeat?: Keyword.get(opts, :repeat?, true),
      fronts: Map.new(cards, &{&1.id, &1.front})
    }
  end

  @doc "Shows the answer of the card asked."
  @spec flip(t()) :: t()
  def flip(%__MODULE__{current: nil} = session), do: session
  def flip(%__MODULE__{} = session), do: %{session | flipped?: true}

  @doc """
  Records the answer to the card asked, `card` being that card as the vote
  left it, and moves on to the next one.
  """
  @spec answer(t(), Schedule.grade(), Card.t()) :: t()
  def answer(%__MODULE__{current: %Card{id: id}} = session, grade, %Card{id: id} = card) do
    queue =
      if grade == :forgot and session.repeat?,
        do: session.queue ++ [card],
        else: session.queue

    {current, queue} =
      case queue do
        [] -> {nil, []}
        [next | rest] -> {next, rest}
      end

    %{
      session
      | current: current,
        queue: queue,
        flipped?: false,
        answers: [{id, grade} | session.answers]
    }
  end

  @doc """
  Removes the card asked from the session, as it was removed from the deck,
  and moves on to the next one. A repeat of it waiting is dropped too.
  """
  @spec remove(t()) :: t()
  def remove(%__MODULE__{current: %Card{id: id}} = session) do
    %{drop(session, id) | removed: [id | session.removed]}
  end

  @doc "Forgets that a card was removed, as when it is put back in the deck."
  @spec unremove(t(), String.t()) :: t()
  def unremove(%__MODULE__{} = session, id) do
    %{session | removed: List.delete(session.removed, id)}
  end

  @doc "The fronts of the cards removed, in the order they were."
  @spec removed(t()) :: [{String.t(), String.t()}]
  def removed(%__MODULE__{} = session), do: fronts(session, session.removed)

  @doc """
  Takes the card asked out of the session, as it was marked uncertain, and
  moves on to the next one. A repeat of it waiting is dropped too.
  """
  @spec mark_uncertain(t()) :: t()
  def mark_uncertain(%__MODULE__{current: %Card{id: id}} = session) do
    %{drop(session, id) | uncertain: [id | session.uncertain]}
  end

  @doc """
  Forgets that a card was marked uncertain, as when the mark is undone. It
  is not asked again in this session.
  """
  @spec unmark_uncertain(t(), String.t()) :: t()
  def unmark_uncertain(%__MODULE__{} = session, id) do
    %{session | uncertain: List.delete(session.uncertain, id)}
  end

  @doc "The fronts of the cards marked uncertain, in the order they were."
  @spec uncertain(t()) :: [{String.t(), String.t()}]
  def uncertain(%__MODULE__{} = session), do: fronts(session, session.uncertain)

  defp fronts(session, ids) do
    for id <- Enum.reverse(ids), do: {id, Map.fetch!(session.fronts, id)}
  end

  @doc """
  Puts a newer version of a card in the session, as when it is edited while
  it waits to be asked. Cards the session doesn't hold are ignored.
  """
  @spec refresh(t(), Card.t()) :: t()
  def refresh(%__MODULE__{} = session, %Card{id: id} = card) do
    current = if session.current && session.current.id == id, do: card, else: session.current
    queue = Enum.map(session.queue, &if(&1.id == id, do: card, else: &1))

    fronts =
      if Map.has_key?(session.fronts, id),
        do: Map.put(session.fronts, id, card.front),
        else: session.fronts

    %{session | current: current, queue: queue, fronts: fronts}
  end

  @doc "Takes a card deleted elsewhere out of what is left to ask."
  @spec drop(t(), String.t()) :: t()
  def drop(%__MODULE__{} = session, id) do
    queue = Enum.reject(session.queue, &(&1.id == id))

    if session.current && session.current.id == id do
      case queue do
        [] -> %{session | current: nil, queue: [], flipped?: false}
        [next | rest] -> %{session | current: next, queue: rest, flipped?: false}
      end
    else
      %{session | queue: queue}
    end
  end

  @doc "Ends the session before every card is asked, counting the ones left in `skipped`."
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = session) do
    %{session | current: nil, queue: [], flipped?: false, skipped: left(session)}
  end

  @doc "Whether every card has been asked, or the session was ended."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{current: current}), do: current == nil

  @doc "How many answers were given, repeats included."
  @spec answered(t()) :: non_neg_integer()
  def answered(%__MODULE__{answers: answers}), do: length(answers)

  @doc """
  How many cards were dealt with: answered, repeats included, removed or
  marked uncertain.
  """
  @spec handled(t()) :: non_neg_integer()
  def handled(%__MODULE__{} = session),
    do: length(session.answers) + length(session.removed) + length(session.uncertain)

  @doc "How many cards are still to ask, the one asked now included."
  @spec left(t()) :: non_neg_integer()
  def left(%__MODULE__{current: nil}), do: 0
  def left(%__MODULE__{queue: queue}), do: length(queue) + 1

  @doc "How many distinct cards the session asks."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{fronts: fronts}), do: map_size(fronts)

  @doc """
  The first answer given to each card, counted by vote. A card forgotten
  and then remembered on its repeat counts as forgotten.
  """
  @spec tally(t()) :: %{Schedule.grade() => non_neg_integer()}
  def tally(%__MODULE__{} = session) do
    counts = Map.new(Schedule.grades(), &{&1, 0})

    session
    |> first_answers()
    |> Enum.reduce(counts, fn {_id, grade}, counts -> Map.update!(counts, grade, &(&1 + 1)) end)
  end

  @doc "The fronts of the cards forgotten the first time they were asked, in the order asked."
  @spec forgotten(t()) :: [{String.t(), String.t()}]
  def forgotten(%__MODULE__{} = session) do
    for {id, :forgot} <- first_answers(session), do: {id, Map.fetch!(session.fronts, id)}
  end

  defp first_answers(session) do
    session.answers
    |> Enum.reverse()
    |> Enum.uniq_by(fn {id, _grade} -> id end)
  end
end
