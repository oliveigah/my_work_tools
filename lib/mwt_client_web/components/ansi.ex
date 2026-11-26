defmodule MWTClientWeb.Ansi do
  @moduledoc """
  What a command printed in the VM, with its colours: the colour codes a
  terminal reads (`ESC[…m`, all that `MWTClient.Sandbox.Console.shown/1`
  leaves) drawn in the app's own palette, so `ls --color`, git and test
  runners read as they do in a terminal, in light and dark themes.

  It knows the eight colours and their bright forms, bold, dim, italic and
  underline. 256 colours and true colour fall back to the text's own, as
  does any code it doesn't know: a colour lost, never text.
  """
  use Phoenix.Component

  @fg %{
    30 => "text-faint",
    31 => "text-bad",
    32 => "text-ok-strong",
    33 => "text-warn",
    34 => "text-accent",
    35 => "text-violet",
    36 => "text-teal",
    37 => "text-ink",
    90 => "text-muted",
    91 => "text-bad",
    92 => "text-ok",
    93 => "text-warn",
    94 => "text-accent",
    95 => "text-violet",
    96 => "text-teal",
    97 => "text-ink"
  }

  @bg %{
    40 => "bg-deep",
    41 => "bg-bad-soft",
    42 => "bg-ok-soft",
    43 => "bg-warn-soft",
    44 => "bg-accent-soft",
    45 => "bg-violet/20",
    46 => "bg-teal/20",
    47 => "bg-hover",
    100 => "bg-hover",
    101 => "bg-bad-soft",
    102 => "bg-ok-soft",
    103 => "bg-warn-soft",
    104 => "bg-accent-soft",
    105 => "bg-violet/20",
    106 => "bg-teal/20",
    107 => "bg-active"
  }

  @plain %{fg: nil, bg: nil, bold: false, dim: false, italic: false, underline: false}

  @doc """
  `text` cut where its colours change: each piece with the classes it is
  drawn with, empty pieces left out.

      iex> MWTClientWeb.Ansi.segments("plain \\e[1;31mred\\e[0m done")
      [{[], "plain "}, {["text-bad", "font-semibold"], "red"}, {[], " done"}]
      iex> MWTClientWeb.Ansi.segments("\\e[38;5;208mkept\\e[39m")
      [{[], "kept"}]
  """
  @spec segments(String.t()) :: [{[String.t()], String.t()}]
  def segments(text) when is_binary(text) do
    text
    |> String.split(~r/\e\[([0-9;]*)m/, include_captures: true)
    |> Enum.reduce({@plain, []}, fn piece, {style, out} ->
      case Regex.run(~r/\A\e\[([0-9;]*)m\z/, piece) do
        [_, codes] -> {apply_codes(style, codes), out}
        nil when piece == "" -> {style, out}
        nil -> {style, [{classes(style), piece} | out]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp apply_codes(_style, ""), do: @plain

  defp apply_codes(style, codes) do
    codes
    |> String.split(";")
    |> Enum.map(&Integer.parse/1)
    |> Enum.map(fn
      {n, ""} -> n
      _other -> nil
    end)
    |> sgr(style)
  end

  # Each code in turn; 38 and 48 take their colour's own codes with them,
  # which this doesn't draw.
  defp sgr([], style), do: style
  defp sgr([0 | rest], _style), do: sgr(rest, @plain)
  defp sgr([1 | rest], style), do: sgr(rest, %{style | bold: true})
  defp sgr([2 | rest], style), do: sgr(rest, %{style | dim: true})
  defp sgr([3 | rest], style), do: sgr(rest, %{style | italic: true})
  defp sgr([4 | rest], style), do: sgr(rest, %{style | underline: true})
  defp sgr([22 | rest], style), do: sgr(rest, %{style | bold: false, dim: false})
  defp sgr([23 | rest], style), do: sgr(rest, %{style | italic: false})
  defp sgr([24 | rest], style), do: sgr(rest, %{style | underline: false})
  defp sgr([39 | rest], style), do: sgr(rest, %{style | fg: nil})
  defp sgr([49 | rest], style), do: sgr(rest, %{style | bg: nil})
  defp sgr([wide, 5, _n | rest], style) when wide in [38, 48], do: sgr(rest, style)
  defp sgr([wide, 2, _r, _g, _b | rest], style) when wide in [38, 48], do: sgr(rest, style)
  defp sgr([n | rest], style) when is_map_key(@fg, n), do: sgr(rest, %{style | fg: @fg[n]})
  defp sgr([n | rest], style) when is_map_key(@bg, n), do: sgr(rest, %{style | bg: @bg[n]})
  defp sgr([_unknown | rest], style), do: sgr(rest, style)

  defp classes(style) do
    [
      style.fg,
      style.bg,
      style.bold && "font-semibold",
      style.dim && "opacity-60",
      style.italic && "italic",
      style.underline && "underline"
    ]
    |> Enum.filter(&is_binary/1)
  end

  attr :text, :string, required: true

  @doc "What a command printed, its colours drawn (`segments/1`)."
  def text(assigns) do
    assigns = assign(assigns, :segments, segments(assigns.text))

    # On one line, unformatted: inside a <pre>, any space here would show.
    ~H"""
    <span phx-no-format><%= for {classes, piece} <- @segments do %><span :if={classes != []} class={classes}>{piece}</span><%= if classes == [], do: piece %><% end %></span>
    """
  end
end
