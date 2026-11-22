defmodule MWTClient.Flashcards.Card do
  @moduledoc """
  One flash card: a question on the front, its answer on the back, both in
  Markdown, and where it belongs.

  `tags` are the labels a session picks cards by: the project a card is
  about, a topic, a thread. `source` says where it came from, such as the
  thread an agent wrote it from, and is shown under the answer.

  The rest is how well it is remembered, kept by `MWTClient.Flashcards.Schedule`:
  the `box` it is in (0 until it is first answered), when it is `due_at`, and
  how many times it was answered and forgotten. A new card is due from the
  moment it is written.

  A card judged not worth remembering is removed from the deck: `removed_at`
  says when. It is kept, out of sessions and lists, so it can be put back,
  and so an agent writing it again is told it was removed rather than
  adding it once more.

  A card whose answer the user doubts, as stale or as raising a question,
  is marked uncertain: `uncertain_at` says when, and `uncertain_note` what
  they doubt, if they wrote it. Sessions don't ask it until the doubt is
  settled (`resolve/2`), by an agent checking it against the code or by
  the user; then it is due, so the next session asks it as it reads by
  then. Only the user marks a card: an agent with a doubt asks them.

  `search_text` is the front, the back, the tags and the source,
  normalized once when they change, so searching does not redo it for every
  card on every keystroke.

  `version` counts the changes to the front, the back, the tags and the
  source, from 1 when it is written; answering it changes none of them. An
  agent changing a card names the version it read, so it never overwrites
  an edit it hasn't seen.
  """

  alias MWTClient.Search

  @max_front 2_000
  @max_back 20_000
  @max_source 300
  @max_tag 60
  @max_tags 10
  @max_id 64
  @max_uncertain_note 1_000

  @type t :: %__MODULE__{
          id: String.t(),
          front: String.t(),
          back: String.t(),
          tags: [String.t()],
          source: String.t() | nil,
          box: non_neg_integer(),
          due_at: DateTime.t(),
          reviewed_at: DateTime.t() | nil,
          reviews: non_neg_integer(),
          lapses: non_neg_integer(),
          removed_at: DateTime.t() | nil,
          uncertain_at: DateTime.t() | nil,
          uncertain_note: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          search_text: String.t(),
          version: pos_integer()
        }

  defstruct [
    :id,
    :due_at,
    :reviewed_at,
    :removed_at,
    :uncertain_at,
    :uncertain_note,
    :created_at,
    :updated_at,
    :source,
    front: "",
    back: "",
    tags: [],
    box: 0,
    reviews: 0,
    lapses: 0,
    search_text: "",
    version: 1
  ]

  @doc "The longest front kept, in characters."
  def max_front, do: @max_front

  @doc "The longest back kept, in characters."
  def max_back, do: @max_back

  @doc "The longest source kept, in characters."
  def max_source, do: @max_source

  @doc "The longest tag, in characters."
  def max_tag, do: @max_tag

  @doc "The most tags one card holds."
  def max_tags, do: @max_tags

  @doc "The longest note on what the user doubts, in characters."
  def max_uncertain_note, do: @max_uncertain_note

  @doc "A fresh card identifier, safe in a DOM id and a CSS selector."
  @spec new_id() :: String.t()
  def new_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `id` has the shape of a card identifier."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id and id =~ ~r/\A[\w-]+\z/

  @doc """
  Checks what a card is written with, `:front`, `:back`, `:tags` and
  `:source`, and returns them as they will be kept.

  Only the fields given are checked, so an update can name one. The errors
  are `{field, message}` pairs, the message fit to show next to the field.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def validate(attrs) when is_map(attrs) do
    {kept, errors} =
      Enum.reduce([:front, :back, :tags, :source], {%{}, []}, fn field, {kept, errors} ->
        case Map.fetch(attrs, field) do
          {:ok, value} ->
            case check(field, value) do
              {:ok, value} -> {Map.put(kept, field, value), errors}
              {:error, message} -> {kept, [{field, message} | errors]}
            end

          :error ->
            {kept, errors}
        end
      end)

    if errors == [], do: {:ok, kept}, else: {:error, Enum.reverse(errors)}
  end

  @doc """
  Builds a card from attributes already through `validate/1`, plus any of
  `:id`, `:created_at` and the review state; a new card is due when it is
  created.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    now = DateTime.utc_now()
    created_at = Map.get(attrs, :created_at, now)

    card = %__MODULE__{
      id: Map.get_lazy(attrs, :id, &new_id/0),
      front: Map.get(attrs, :front, ""),
      back: Map.get(attrs, :back, ""),
      tags: Map.get(attrs, :tags, []),
      source: Map.get(attrs, :source),
      box: Map.get(attrs, :box, 0),
      due_at: Map.get(attrs, :due_at, created_at),
      reviewed_at: Map.get(attrs, :reviewed_at),
      reviews: Map.get(attrs, :reviews, 0),
      lapses: Map.get(attrs, :lapses, 0),
      removed_at: Map.get(attrs, :removed_at),
      uncertain_at: Map.get(attrs, :uncertain_at),
      uncertain_note: Map.get(attrs, :uncertain_note),
      created_at: created_at,
      updated_at: Map.get(attrs, :updated_at, created_at)
    }

    with_search_text(card)
  end

  @doc """
  Applies validated `:front`, `:back`, `:tags` or `:source` to a card.

  The card is returned as it was when none of them changes it, so saving
  what is already there does not count as a change.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = card, attrs) do
    updated = struct(card, Map.take(attrs, [:front, :back, :tags, :source]))

    if updated == card,
      do: card,
      else: with_search_text(%{updated | updated_at: DateTime.utc_now()})
  end

  @doc "Whether the card has never been answered."
  @spec new?(t()) :: boolean()
  def new?(%__MODULE__{reviews: reviews}), do: reviews == 0

  @doc "Whether the card is due at `now`."
  @spec due?(t(), DateTime.t()) :: boolean()
  def due?(%__MODULE__{due_at: due_at}, now), do: DateTime.compare(due_at, now) != :gt

  @doc """
  Whether two cards say the same thing: the same front and back, ignoring
  case and spacing. An agent asked twice for the same cards writes them once.
  """
  @spec same?(t() | map(), t() | map()) :: boolean()
  def same?(one, other) do
    Search.normalize(one.front) == Search.normalize(other.front) and
      Search.normalize(one.back) == Search.normalize(other.back)
  end

  @doc """
  The tags of a card as written: trimmed, inner spaces collapsed, and
  without repeats, ignoring case, the first spelling kept. Accepts a list or
  one comma-separated string.
  """
  @spec tags(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def tags(value) when is_binary(value), do: value |> String.split(",") |> tags()

  def tags(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      tags =
        value
        |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)

      cond do
        length(tags) > @max_tags ->
          {:error, "use at most #{@max_tags} tags"}

        long = Enum.find(tags, &(String.length(&1) > @max_tag)) ->
          {:error, "#{inspect(long)} is longer than #{@max_tag} characters"}

        true ->
          {:ok, tags}
      end
    else
      {:error, "must be a list of strings"}
    end
  end

  def tags(nil), do: {:ok, []}
  def tags(_value), do: {:error, "must be a list of strings"}

  @doc """
  Whether the card holds `tags`, ignoring case: any one of them with
  `:any`, every one with `:all`. No tags means every card.
  """
  @spec tagged?(t(), [String.t()], :any | :all) :: boolean()
  def tagged?(card, tags, match \\ :any)
  def tagged?(_card, [], _match), do: true

  def tagged?(%__MODULE__{tags: mine}, tags, match) do
    mine = MapSet.new(mine, &String.downcase/1)
    held? = &MapSet.member?(mine, String.downcase(&1))
    if match == :all, do: Enum.all?(tags, held?), else: Enum.any?(tags, held?)
  end

  @doc "Whether the card was removed from the deck."
  @spec removed?(t()) :: boolean()
  def removed?(%__MODULE__{removed_at: removed_at}), do: removed_at != nil

  @doc "Whether the user marked the card uncertain, and it isn't settled yet."
  @spec uncertain?(t() | map()) :: boolean()
  def uncertain?(%{uncertain_at: uncertain_at}), do: uncertain_at != nil

  @doc """
  A note on what the user doubts, as it is kept: trimmed, and nil when
  nothing is written.
  """
  @spec uncertain_note(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def uncertain_note(nil), do: {:ok, nil}

  def uncertain_note(value) do
    case text(value, @max_uncertain_note, :optional) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end

  @doc """
  The card marked uncertain at `now`, with `note` (through
  `uncertain_note/1`). A card marked already keeps when it first was, and
  takes the new note. How well it is remembered is kept.
  """
  @spec mark_uncertain(t(), String.t() | nil, DateTime.t()) :: t()
  def mark_uncertain(%__MODULE__{} = card, note, now) do
    changed(card, %{uncertain_at: card.uncertain_at || now, uncertain_note: note}, now)
  end

  @doc """
  The card with its mark taken off as if it had never been made, as an undo
  does: when it is due stays as it was.
  """
  @spec unmark_uncertain(t(), DateTime.t()) :: t()
  def unmark_uncertain(%__MODULE__{} = card, now) do
    changed(card, %{uncertain_at: nil, uncertain_note: nil}, now)
  end

  @doc """
  The card with its doubt settled at `now`: unmarked, and due by `now`, so
  the next session asks it as it reads after the check, whatever box it is
  in. A card not marked is returned as it is.
  """
  @spec resolve(t(), DateTime.t()) :: t()
  def resolve(%__MODULE__{uncertain_at: nil} = card, _now), do: card

  def resolve(%__MODULE__{} = card, now) do
    due_at = if DateTime.compare(card.due_at, now) == :gt, do: now, else: card.due_at
    changed(card, %{uncertain_at: nil, uncertain_note: nil, due_at: due_at}, now)
  end

  # The card with `fields`, its change time `now` if they change it.
  defp changed(card, fields, now) do
    updated = struct(card, fields)
    if updated == card, do: card, else: %{updated | updated_at: now}
  end

  @doc "Whether the card was written within the last `days` days of `now`. Nil means any time."
  @spec within?(t(), pos_integer() | nil, DateTime.t()) :: boolean()
  def within?(_card, nil, _now), do: true

  def within?(%__MODULE__{created_at: created_at}, days, now) do
    DateTime.compare(created_at, DateTime.add(now, -days, :day)) != :lt
  end

  @doc "Rebuilds the text searches run against."
  @spec with_search_text(t()) :: t()
  def with_search_text(%__MODULE__{} = card) do
    text =
      Enum.join([card.front, card.back, Enum.join(card.tags, " "), card.source || ""], "\n")

    %{card | search_text: Search.normalize(text)}
  end

  @doc "Whether the card holds every one of `terms`."
  @spec matches?(t(), [String.t()]) :: boolean()
  def matches?(%__MODULE__{search_text: text}, terms), do: Search.matches?(text, terms)

  @doc """
  The front as one line of plain text, for lists: Markdown marks at the
  start of lines and bold marks dropped, and lines joined. Code spans keep
  their backticks, which say something.
  """
  @spec plain_front(t() | String.t()) :: String.t()
  def plain_front(%__MODULE__{front: front}), do: plain_front(front)

  def plain_front(front) when is_binary(front) do
    front
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r/\A\s*(?:[#>]+\s*|[-*+]\s+|\d+[.)]\s+)*/u, ""))
    |> Enum.reject(&(String.trim(&1) in ["", "```", "~~~"]))
    |> Enum.join(" ")
    |> String.replace(~r/\*\*|__/u, "")
    |> String.split()
    |> Enum.join(" ")
  end

  defp check(:front, value), do: text(value, @max_front, :required)
  defp check(:back, value), do: text(value, @max_back, :required)
  defp check(:tags, value), do: tags(value)

  defp check(:source, value) when is_nil(value), do: {:ok, nil}

  defp check(:source, value) do
    case text(value, @max_source, :optional) do
      {:ok, ""} -> {:ok, nil}
      {:ok, source} -> {:ok, source |> String.split() |> Enum.join(" ")}
      error -> error
    end
  end

  defp text(value, max, required) when is_binary(value) do
    value = value |> String.replace("\r\n", "\n") |> String.trim()

    cond do
      value == "" and required == :required -> {:error, "can't be blank"}
      String.length(value) > max -> {:error, "is longer than #{max} characters"}
      true -> {:ok, value}
    end
  end

  defp text(_value, _max, _required), do: {:error, "must be text"}
end
