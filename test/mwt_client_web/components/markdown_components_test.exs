defmodule MWTClientWeb.MarkdownComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MWTClientWeb.MarkdownComponents

  defp render_view(text) do
    (&MarkdownComponents.markdown_view/1)
    |> render_component(id: "body", text: text, header: [])
    |> LazyHTML.from_fragment()
  end

  test "shows the text rendered, and the text as written behind the Raw tab" do
    document = render_view("# Plan\n\n- **bold** step\n- `code`")

    rendered = LazyHTML.query(document, "#body-rendered")
    assert rendered |> LazyHTML.query("h1") |> LazyHTML.text() == "Plan"
    assert rendered |> LazyHTML.query("strong") |> LazyHTML.text() == "bold"

    raw = LazyHTML.query(document, "#body-raw")
    assert LazyHTML.text(raw) == "# Plan\n\n- **bold** step\n- `code`"
    assert raw |> LazyHTML.attribute("class") |> hd() =~ "hidden"

    assert document |> LazyHTML.query("#body-tab-rendered") |> LazyHTML.attribute("aria-selected") ==
             ["true"]

    assert document |> LazyHTML.query("#body-tab-raw") |> LazyHTML.attribute("aria-selected") ==
             ["false"]
  end

  test "raw HTML in the text is never rendered" do
    document = render_view("<script>alert(1)</script>\n\n<b>hi</b>")

    assert document |> LazyHTML.query("#body-rendered script") |> Enum.count() == 0
    assert document |> LazyHTML.query("#body-rendered b") |> Enum.count() == 0
    assert document |> LazyHTML.query("#body-raw") |> LazyHTML.text() =~ "<script>"
  end
end
