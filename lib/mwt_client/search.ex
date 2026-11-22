defmodule MWTClient.Search do
  @moduledoc """
  The word search shared by the tools that keep text: diagrams, notes and
  flash cards, which search their database with `where/4`, and HTTP
  history.

  What can be searched is normalized once, with `normalize/1`, when it
  changes, so searching as someone types compares strings rather than
  rebuilding them. A search is split into words by `terms/1`, and text
  matches when it holds every word, wherever each one is, since the words of
  one idea are often written apart.
  """

  @snippet_before 24
  @snippet_after 60
  # Below this many texts, spreading a search over processes costs more than
  # it saves.
  @parallel_from 500

  # Every character `\s` stands for in a Unicode regex. Splitting on them is
  # several times faster than replacing with that regex, which matters for
  # request bodies tens of kilobytes long, and gives the same text.
  @whitespace Enum.map(
                [0x9, 0xA, 0xB, 0xC, 0xD, 0x20, 0x85, 0xA0, 0x1680, 0x180E] ++
                  Enum.to_list(0x2000..0x200A) ++
                  [0x2028, 0x2029, 0x202F, 0x205F, 0x3000],
                &<<&1::utf8>>
              )

  @doc "Lowercased, with every run of whitespace turned into one space."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :binary.split(@whitespace, [:global, :trim_all])
    |> Enum.join(" ")
  end

  @doc "The words of a search, normalized the way searched text is."
  @spec terms(String.t()) :: [String.t()]
  def terms(term) when is_binary(term), do: term |> normalize() |> String.split(" ", trim: true)

  @doc """
  `Enum.filter/2`, split across the schedulers for a list long enough that
  it pays, keeping the order.

  Searching is mostly reading: a word near the top of each text is found
  quickly, but one that is nowhere, or only near the end, reads every byte,
  and tens of megabytes read on one core is a pause someone notices while
  typing.
  """
  @spec filter([item], (item -> as_boolean(term()))) :: [item] when item: term()
  def filter(items, fun) when length(items) < @parallel_from, do: Enum.filter(items, fun)

  def filter(items, fun) do
    chunk = div(length(items), System.schedulers_online()) + 1

    items
    |> Enum.chunk_every(chunk)
    |> Task.async_stream(&Enum.filter(&1, fun), timeout: :infinity)
    |> Enum.flat_map(fn {:ok, kept} -> kept end)
  end

  @doc "Whether normalized `text` holds every one of `terms`."
  @spec matches?(String.t(), [String.t()]) :: boolean()
  def matches?(text, terms) when is_binary(text) do
    Enum.all?(terms, &String.contains?(text, &1))
  end

  @doc """
  `matches?/2` over a database table rather than one text: an SQL
  condition holding for the rows whose `seq` (a column, as `"n.seq"`)
  names the rowid of a row of `texts` whose `search_text` holds every one
  of `terms`, and the condition's parameters. `seq` names its table
  (`"flashcards.seq"` when the rows are the texts' own), and no table of
  the query is called `t`, the name the texts take inside the condition.

  `index` is the trigram index of `texts`' `search_text`, by the same
  rowid (`MWTClient.Storage.Migrations.LibraryItems`). Words of three
  characters or more are found through it; a shorter one, which no
  trigram holds, by reading the text. The meaning is the same either way.

  A short word is looked for row by row, in the text of each row the rest
  of the query leaves (a longer word, a date), not in every text first: a
  search made only of short words, with nothing else to narrow it, is the
  one that reads every row.
  """
  @spec where(String.t(), String.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def where(_seq, _index, _texts, []), do: {"1", []}

  def where(seq, index, texts, terms) do
    Enum.each([seq, index, texts], &identifier!/1)
    {long, short} = Enum.split_with(terms, &(length(String.codepoints(&1)) >= 3))

    indexed =
      if long != [] do
        # A quoted string is the trigram tokenizer's substring, whatever it
        # holds, once its own quotes are doubled.
        query =
          Enum.map_join(long, " AND ", &(~s(") <> String.replace(&1, ~s("), ~s("")) <> ~s(")))

        {"#{seq} IN (SELECT rowid FROM #{index} WHERE #{index} MATCH ?)", [query]}
      end

    read =
      if short != [] do
        # Named apart from the query around it, so `seq` names the row
        # there, even when it searches its texts' own table.
        holds = Enum.map_join(short, " AND ", fn _term -> "instr(t.search_text, ?) > 0" end)
        {"EXISTS (SELECT 1 FROM #{texts} AS t WHERE t.rowid = #{seq} AND #{holds})", short}
      end

    conditions = Enum.reject([indexed, read], &is_nil/1)
    {Enum.map_join(conditions, " AND ", &elem(&1, 0)), Enum.flat_map(conditions, &elem(&1, 1))}
  end

  defp identifier!(name) do
    if name =~ ~r/\A[a-z_]+(\.[a-z_]+)?\z/, do: name, else: raise(ArgumentError, inspect(name))
  end

  @doc """
  The first of `texts` holding one of `terms`, cut down to the words around
  the match, as `{before, match, after}`. Nil when there are no terms, or
  when no text holds any of them. `texts` can be a stream, read only as far
  as the first match.
  """
  @spec snippet(Enumerable.t(String.t()), [String.t()]) ::
          {String.t(), String.t(), String.t()} | nil
  def snippet(_texts, []), do: nil

  def snippet(texts, terms) do
    patterns = Enum.map(terms, &Regex.compile!(Regex.escape(&1), "iu"))

    Enum.find_value(texts, fn text ->
      # Terms hold no whitespace, so a text holds one exactly when it does
      # with its whitespace collapsed; asking first spares collapsing every
      # text that holds none.
      if Enum.any?(patterns, &Regex.match?(&1, text)) do
        line = String.replace(text, ~r/\s+/u, " ")

        Enum.find_value(patterns, fn pattern ->
          case Regex.run(pattern, line, return: :index) do
            [{at, length}] -> cut(line, at, length)
            nil -> nil
          end
        end)
      end
    end)
  end

  defp cut(line, at, length) do
    before = binary_part(line, 0, at)
    after_match = binary_part(line, at + length, byte_size(line) - at - length)

    before =
      if String.length(before) > @snippet_before,
        do: "…" <> String.slice(before, -@snippet_before, @snippet_before),
        else: before

    after_match =
      if String.length(after_match) > @snippet_after,
        do: String.slice(after_match, 0, @snippet_after) <> "…",
        else: after_match

    {before, binary_part(line, at, length), after_match}
  end
end
