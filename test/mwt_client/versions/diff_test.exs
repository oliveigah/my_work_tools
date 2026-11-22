defmodule MWTClient.Versions.DiffTest do
  use ExUnit.Case, async: true

  alias MWTClient.Versions.Diff

  doctest Diff

  defp element(id, fields \\ %{}), do: Map.merge(%{"id" => id, "type" => "rectangle"}, fields)

  test "counts the fewest elements that changed places in the drawing order" do
    [a, b, c, d] = Enum.map(~w(a b c d), &element/1)

    assert Diff.elements([a, b, c, d], [a, b, c, d]).reordered == 0
    # d brought to the front of a, b, c: one moved, not three.
    assert Diff.elements([d, a, b, c], [a, b, c, d]).reordered == 1
    assert Diff.elements([a, b, c, d], [d, c, b, a]).reordered == 3
    # Added and removed elements are no change of order.
    assert Diff.elements([a, b, c], [b, c, d]).reordered == 0
  end

  test "says what changed in words, the drawing order included" do
    [a, b] = [element("a"), element("b")]
    moved = element("a", %{"x" => 10})
    grouped = element("b", %{"groups" => ["g"]})

    assert Diff.elements_words(Diff.elements([a, b], [b, a])) == "1 element reordered"

    assert Diff.elements_words(Diff.elements([a, b], [grouped, moved])) ==
             "1 element changed, 1 element moved, 1 element reordered"

    assert Diff.elements_words(Diff.elements([a, b], [a, b])) == nil
  end
end
