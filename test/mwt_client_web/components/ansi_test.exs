defmodule MWTClientWeb.AnsiTest do
  @moduledoc """
  What a command printed, its colours drawn in the app's palette; text it
  doesn't know how to colour shows all the same.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  doctest MWTClientWeb.Ansi

  test "draws each coloured piece in a span, plain text as it is, escaped" do
    html = render_component(&MWTClientWeb.Ansi.text/1, text: "a \e[32m<ok>\e[0m b")
    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("span.text-ok-strong") |> LazyHTML.text() == "<ok>"
    assert LazyHTML.text(doc) == "a <ok> b"
  end

  test "an unknown or partial code loses its colour, never its text" do
    assert MWTClientWeb.Ansi.segments("\e[5;99mx\e[;m y") == [{[], "x"}, {[], " y"}]

    assert MWTClientWeb.Ansi.segments("\e[48;2;1;2;3mbg\e[4mu") == [
             {[], "bg"},
             {["underline"], "u"}
           ]
  end
end
