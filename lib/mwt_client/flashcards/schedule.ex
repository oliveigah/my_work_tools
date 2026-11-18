defmodule MWTClient.Flashcards.Schedule do
  @moduledoc """
  When a card comes back, from how well it was remembered: Leitner boxes.

  A card climbs through six boxes as it is remembered, and each box waits
  longer before the card is due again. Every answer is one of four votes:

    * `:forgot` - back to box 1, due again straight away, so the next
      session shows it before the cards remembered;
    * `:hard` - remembered with effort: it stays in its box, due after that
      box's wait again;
    * `:good` - up one box;
    * `:easy` - up two boxes.

  A card never answered is in box 0 and counts as box 1, so its first `:good`
  takes it to box 2. A box is a wait, not a grade, so why a card shows up is
  always plain: it is due, and the lower its box the sooner it comes back.
  """

  alias MWTClient.Flashcards.Card

  @type grade :: :forgot | :hard | :good | :easy

  @grades [:forgot, :hard, :good, :easy]

  # Days a card waits in each box before it is due again.
  @waits %{1 => 0, 2 => 1, 3 => 3, 4 => 7, 5 => 16, 6 => 35}
  @top 6

  @doc "The votes, from worst remembered to best."
  @spec grades() :: [grade()]
  def grades, do: @grades

  @doc "The highest box."
  @spec top() :: pos_integer()
  def top, do: @top

  @doc "How many days a card waits in each box, as `{box, days}`, lowest box first."
  @spec waits() :: [{pos_integer(), non_neg_integer()}]
  def waits, do: Enum.sort(@waits)

  @doc "A vote by name, as a page or an agent sends it."
  @spec grade(term()) :: {:ok, grade()} | :error
  def grade(name) when is_binary(name) do
    case Enum.find(@grades, &(Atom.to_string(&1) == name)) do
      nil -> :error
      grade -> {:ok, grade}
    end
  end

  def grade(grade) when grade in @grades, do: {:ok, grade}
  def grade(_name), do: :error

  @doc "The box a card in `box` moves to with `grade`."
  @spec next_box(non_neg_integer(), grade()) :: pos_integer()
  def next_box(_box, :forgot), do: 1
  def next_box(box, :hard), do: max(box, 1)
  def next_box(box, :good), do: min(max(box, 1) + 1, @top)
  def next_box(box, :easy), do: min(max(box, 1) + 2, @top)

  @doc "How many days a card waits in `box`."
  @spec wait(pos_integer()) :: non_neg_integer()
  def wait(box), do: Map.fetch!(@waits, box)

  @doc "The days a card would wait with each vote, for the buttons that cast them."
  @spec preview(Card.t()) :: %{grade() => non_neg_integer()}
  def preview(%Card{box: box}), do: Map.new(@grades, &{&1, wait(next_box(box, &1))})

  @doc "The card after it is answered with `grade` at `now`."
  @spec answer(Card.t(), grade(), DateTime.t()) :: Card.t()
  def answer(%Card{} = card, grade, now) when grade in @grades do
    box = next_box(card.box, grade)

    %{
      card
      | box: box,
        due_at: DateTime.add(now, wait(box), :day),
        reviewed_at: now,
        reviews: card.reviews + 1,
        lapses: if(grade == :forgot, do: card.lapses + 1, else: card.lapses),
        updated_at: now
    }
  end

  @doc """
  The cards a session asks, at most `size`, from those it may pick from.

  The cards due come first, the least known first: by box, a new card
  counting as box 1, then the longest due. With `fill?`, a session short
  of due cards is filled with the ones coming due soonest, so it can always
  be held. They come shuffled, so one session does not ask them in the order
  the last did.
  """
  @spec pick([Card.t()], pos_integer(), boolean(), DateTime.t()) :: [Card.t()]
  def pick(cards, size, fill?, now) do
    {due, later} = Enum.split_with(cards, &Card.due?(&1, now))

    due = Enum.sort_by(due, &{max(&1.box, 1), DateTime.to_unix(&1.due_at, :microsecond)})
    picked = Enum.take(due, size)

    picked =
      if fill? and length(picked) < size do
        later
        |> Enum.sort_by(&DateTime.to_unix(&1.due_at, :microsecond))
        |> Enum.take(size - length(picked))
        |> then(&(picked ++ &1))
      else
        picked
      end

    Enum.shuffle(picked)
  end
end
