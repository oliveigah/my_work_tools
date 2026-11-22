defmodule MWTClient.Versions.Diff do
  @moduledoc """
  What differs between two versions of an item, in the terms its pages and
  approval cards show: a note's text line by line, a diagram's elements
  counted by what happened to them, a card's fields side by side.
  """

  @geometry ~w(x y width height x1 y1 x2 y2)

  @typedoc "One line of a text diff: kept, taken out or put in."
  @type line :: {:eq | :del | :ins, String.t()}

  @doc """
  The lines of `old` and `new`, each marked as kept, taken out or put in,
  in order.

      iex> MWTClient.Versions.Diff.lines("a\\nb", "a\\nc")
      [{:eq, "a"}, {:del, "b"}, {:ins, "c"}]
  """
  @spec lines(String.t(), String.t()) :: [line()]
  def lines(old, new) do
    old
    |> String.split("\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)
  end

  @doc """
  The lines of a text diff with no more than `context` kept lines around
  each change; a run of kept lines left out becomes `{:skip, count}`.
  """
  @spec around_changes([line()], non_neg_integer()) :: [line() | {:skip, pos_integer()}]
  def around_changes(lines, context \\ 2) do
    indexed = Enum.with_index(lines)

    changed =
      for {{op, _line}, index} <- indexed, op != :eq, into: MapSet.new(), do: index

    near? = fn index ->
      Enum.any?(max(index - context, 0)..(index + context)//1, &MapSet.member?(changed, &1))
    end

    indexed
    |> Enum.chunk_by(fn {{op, _line}, index} -> op != :eq or near?.(index) end)
    |> Enum.flat_map(fn
      [{{:eq, _line}, index} | _rest] = run ->
        if near?.(index), do: Enum.map(run, &elem(&1, 0)), else: [{:skip, length(run)}]

      run ->
        Enum.map(run, &elem(&1, 0))
    end)
  end

  @doc """
  How a diagram's elements changed, by their ids: `added`, `removed`,
  `moved` (only where or how big), `changed` (anything else), and
  `reordered`, the fewest of those in both that had to change places in the
  drawing order, which decides what covers what.

      iex> a = %{"id" => "a"}
      iex> b = %{"id" => "b"}
      iex> MWTClient.Versions.Diff.elements([a, b], [b, a])
      %{added: 0, removed: 0, moved: 0, changed: 0, reordered: 1}
  """
  @spec elements([map()], [map()]) :: %{
          added: non_neg_integer(),
          removed: non_neg_integer(),
          moved: non_neg_integer(),
          changed: non_neg_integer(),
          reordered: non_neg_integer()
        }
  def elements(old, new) do
    old_order = Enum.map(old, & &1["id"])
    new_order = Enum.map(new, & &1["id"])
    old = Map.new(old, &{&1["id"], &1})
    new = Map.new(new, &{&1["id"], &1})
    both = for {id, element} <- new, Map.has_key?(old, id), do: {old[id], element}

    %{
      added: Enum.count(Map.keys(new), &(not Map.has_key?(old, &1))),
      removed: Enum.count(Map.keys(old), &(not Map.has_key?(new, &1))),
      moved: Enum.count(both, fn {a, b} -> a != b and same_but_place?(a, b) end),
      changed: Enum.count(both, fn {a, b} -> a != b and not same_but_place?(a, b) end),
      reordered: reordered(Enum.filter(old_order, &Map.has_key?(new, &1)), new_order)
    }
  end

  # Those of `kept`, in their old order, not on the longest run that keeps
  # its order in the new one: each of them moved past something.
  defp reordered(kept, new_order) do
    place = new_order |> Enum.with_index() |> Map.new()
    length(kept) - longest_rising(Enum.map(kept, &place[&1]))
  end

  # The length of the longest strictly rising subsequence, by patience
  # sorting: `tops` keeps the smallest last value of a run of each length.
  defp longest_rising(values) do
    values
    |> Enum.reduce(:gb_trees.empty(), fn value, tops ->
      case first_at_least(tops, value) do
        nil -> :gb_trees.insert(value, true, tops)
        top -> :gb_trees.insert(value, true, :gb_trees.delete(top, tops))
      end
    end)
    |> :gb_trees.size()
  end

  defp first_at_least(tops, value) do
    iterator = :gb_trees.iterator_from(value, tops)

    case :gb_trees.next(iterator) do
      {top, _true, _rest} -> top
      :none -> nil
    end
  end

  @doc "The counts of `elements/2` in words, or nil when nothing differs."
  @spec elements_words(map()) :: String.t() | nil
  def elements_words(counts) do
    [
      {counts.added, "added"},
      {counts.removed, "removed"},
      {counts.changed, "changed"},
      {counts.moved, "moved"},
      {counts.reordered, "reordered"}
    ]
    |> Enum.reject(fn {count, _word} -> count == 0 end)
    |> Enum.map(fn {count, word} ->
      "#{count} #{if count == 1, do: "element", else: "elements"} #{word}"
    end)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  @doc """
  The fields of two maps that differ, as `{field, old, new}`, in the order
  of `fields`.
  """
  @spec fields(map(), map(), [atom()]) :: [{atom(), term(), term()}]
  def fields(old, new, fields) do
    for field <- fields, Map.get(old, field) != Map.get(new, field) do
      {field, Map.get(old, field), Map.get(new, field)}
    end
  end

  defp same_but_place?(a, b), do: Map.drop(a, @geometry) == Map.drop(b, @geometry)
end
