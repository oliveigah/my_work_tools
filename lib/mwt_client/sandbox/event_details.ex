defmodule MWTClient.Sandbox.EventDetails do
  @moduledoc """
  What an event of the activity log says when its line opens, beyond its
  one line: what MWT knew when it happened, for every kind of event, as a
  request MWT read shows what it carried (`MWTClient.Sandbox.Exchange`).

  Details are words, not the records they came from: sections of labelled
  values, written when the event is logged and kept with it in the
  journal (`MWTClient.Storage.Journal.record_details/3`). So the log says
  what was true then, whatever the grant or the handoff became since, and
  a later MWT draws a months-old event without knowing the shape of
  what made it. The cost: a value can't be filtered on as a field, only
  searched for as words (`search_text/1`).

  The module that owns what an event is about writes its details
  (`MWTClient.Sandbox.Approval.details/1`, `MWTClient.Sandbox.Handoff`'s,
  a grant's change, a firewall finding); this one gives them one shape and
  holds its premises, in `new/1`:

    * every value is text that shows as it reads (`MWTClient.Sandbox.Shown`):
      an agent writes much of it;
    * an event's details take at most #{div(16_384, 1024)} KiB, a value cut
      saying how much it lost, so a long script can't make the journal
      grow by more than that per event;
    * empty sections and rows with no value are dropped, so a builder can
      list every field it might know and leave the unknown ones nil.

  They never hold a real credential value or what a command printed: what
  builds them takes neither.

  A section is `%{title, by, rows}`. `by` says whose words its rows are:
  `:mwt` for what MWT knew or worked out, `:agent` for what the agent
  wrote (a reason, a commit message, a thread's title), which the page
  shows apart, as claims. A row is `{label, value}`, a value one of:

    * `{:text, text}` - a line of words;
    * `{:code, text}` - text kept as written, in a fixed font (a script, a
      command, a diff's names);
    * `{:list, [text]}` - a few items, one per line;
    * `{:change, before, after}` - a setting changed, either side nil for
      none;
    * `{:link, text, path}` - a page of MWT's, by its path (a grant, a
      handoff). Only a path starting with `/`: never somewhere else.
  """

  require Logger

  alias MWTClient.Sandbox.Shown

  @budget 16_384
  # The most of the details the word filter looks in.
  @searched 2_048

  @type value ::
          {:text, String.t()}
          | {:code, String.t()}
          | {:list, [String.t()]}
          | {:change, String.t() | nil, String.t() | nil}
          | {:link, String.t(), String.t()}
  @type row :: {String.t(), value()}
  @type section :: %{title: String.t(), by: :mwt | :agent, rows: [row()]}
  @type t :: [section()]

  @doc """
  Runs a builder of details, so that one that fails can't take down what
  logs the event: its failure becomes the details, a section saying MWT
  couldn't describe it and why, and an error in MWT's log. `what` names
  the builder there.
  """
  @spec safely(String.t(), (-> t())) :: t()
  def safely(what, builder) do
    builder.()
  rescue
    error ->
      Logger.error("could not describe #{what} for the activity log: #{Exception.message(error)}",
        system: :sandbox
      )

      new([
        section("Not described", [
          {"Why", "MWT couldn't describe this event: #{Exception.message(error)}"}
        ])
      ])
  end

  @doc """
  A section of what MWT knew. `rows` are `{label, value}`: a value given
  as text is a `{:text, _}`; nil, `""`, `[]` or a nil inside a value drops
  the row.
  """
  @spec section(String.t(), [{String.t(), term()}]) :: section()
  def section(title, rows), do: %{title: title, by: :mwt, rows: rows}

  @doc "A section of what the agent wrote: shown apart, as its words, never as facts."
  @spec agent(String.t(), [{String.t(), term()}]) :: section()
  def agent(title, rows), do: %{title: title, by: :agent, rows: rows}

  @doc """
  The sections as kept: every value showable text, empty ones dropped,
  the whole under its budget. `[]` for nothing to say.
  """
  @spec new([section() | nil]) :: t()
  def new(sections) do
    {sections, _left} =
      sections
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn section ->
        %{
          title: Shown.text(section.title),
          by: if(section.by == :agent, do: :agent, else: :mwt),
          rows: Enum.flat_map(section.rows, &row/1)
        }
      end)
      |> Enum.reject(&(&1.rows == []))
      |> Enum.map_reduce(@budget, &fit_section/2)

    Enum.reject(sections, &(&1.rows == []))
  end

  @doc """
  A "What changed" section from the settings of something before and
  after, each a list of `{label, value}` as `section/2` takes them: a row
  per label whose value reads differently, nil when none does.
  """
  @spec changes([{String.t(), term()}], [{String.t(), term()}]) :: section() | nil
  def changes(before, now) do
    old = Map.new(before, fn {label, value} -> {label, plain(value)} end)
    new = Map.new(now, fn {label, value} -> {label, plain(value)} end)
    labels = Enum.uniq(Enum.map(before ++ now, &elem(&1, 0)))

    case for(
           label <- labels,
           old[label] != new[label],
           do: {label, {:change, old[label], new[label]}}
         ) do
      [] -> nil
      rows -> section("What changed", rows)
    end
  end

  @doc "A number of seconds as the details say it: `42 s`, `12 min`, `3 h 05 min`."
  @spec duration(integer()) :: String.t()
  def duration(seconds) when seconds < 120, do: "#{seconds} s"
  def duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"

  def duration(seconds),
    do:
      "#{div(seconds, 3600)} h #{String.pad_leading("#{div(rem(seconds, 3600), 60)}", 2, "0")} min"

  # A value as one text, to tell whether it changed.
  defp plain({:list, items}) when is_list(items), do: plain(Enum.join(items, ", "))
  defp plain({kind, text}) when kind in [:text, :code], do: plain(text)
  defp plain({:link, text, _path}), do: plain(text)
  defp plain(text) when is_binary(text) and text != "", do: text
  defp plain(n) when is_integer(n), do: Integer.to_string(n)
  defp plain(_none), do: nil

  @doc "The words of the details, for the log's word filter: the first #{@searched} bytes, lowercased."
  @spec search_text(t() | nil) :: String.t()
  def search_text(nil), do: ""

  def search_text(details) do
    details
    |> Enum.flat_map(fn section -> Enum.flat_map(section.rows, &words/1) end)
    |> Enum.join(" ")
    |> String.downcase()
    |> cut_text(@searched)
  end

  @doc "The details as JSON for the clipboard: each section's title to its rows' labels and values."
  @spec to_json(t()) :: [map()]
  def to_json(details) do
    Enum.map(details, fn section ->
      %{
        "section" => section.title,
        "by" => Atom.to_string(section.by),
        "rows" => Enum.map(section.rows, fn {label, value} -> [label, json(value)] end)
      }
    end)
  end

  ## Rows

  defp row({label, value}) do
    case value(value) do
      nil -> []
      value -> [{Shown.text(label), value}]
    end
  end

  defp row(_other), do: []

  defp value(nil), do: nil
  defp value(""), do: nil
  defp value([]), do: nil
  defp value(text) when is_binary(text), do: {:text, Shown.text(text)}
  defp value(n) when is_integer(n), do: {:text, Integer.to_string(n)}
  defp value({:text, text}), do: present(text, &{:text, &1})
  defp value({:code, text}), do: present(text, &{:code, &1})

  defp value({:list, items}) when is_list(items) do
    case items |> Enum.map(&Shown.text/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      items -> {:list, items}
    end
  end

  defp value({:change, before, now}) do
    before = if is_binary(before), do: Shown.text(before)
    now = if is_binary(now), do: Shown.text(now)
    if before == now, do: nil, else: {:change, before, now}
  end

  defp value({:link, text, "/" <> _ = path}) when is_binary(text),
    do: {:link, Shown.text(text), Shown.text(path)}

  defp value({:link, text, _elsewhere}), do: value(text)
  defp value(_other), do: nil

  defp present(text, wrap) when is_binary(text) and text != "", do: wrap.(Shown.text(text))
  defp present(_text, _wrap), do: nil

  ## Budget

  defp fit_section(section, left) do
    {rows, left} = Enum.map_reduce(section.rows, left, &fit_row/2)
    {%{section | rows: Enum.reject(rows, &is_nil/1)}, left}
  end

  defp fit_row(_row, left) when left <= 0, do: {nil, 0}

  defp fit_row({label, value}, left) do
    left = left - byte_size(label)
    {value, left} = fit(value, left)
    {value && {label, value}, left}
  end

  defp fit({kind, text}, left) when kind in [:text, :code] do
    shown = cut_text(text, max(left, 0))
    cut = byte_size(text) - byte_size(shown)

    cond do
      shown == "" -> {nil, 0}
      cut > 0 -> {{kind, shown <> cut_words(kind, cut)}, 0}
      true -> {{kind, text}, left - byte_size(text)}
    end
  end

  defp fit({:list, items}, left) do
    {items, left} =
      Enum.flat_map_reduce(items, left, fn item, left ->
        if byte_size(item) <= left,
          do: {[item], left - byte_size(item)},
          else: {:halt, 0}
      end)

    if items == [], do: {nil, 0}, else: {{:list, items}, left}
  end

  defp fit({:change, before, now} = value, left),
    do: {value, left - byte_size(before || "") - byte_size(now || "")}

  defp fit({:link, text, path} = value, left), do: {value, left - byte_size(text <> path)}

  defp cut_words(:code, cut), do: "\n… #{cut} more bytes not kept"
  defp cut_words(:text, cut), do: " … (#{cut} more bytes not kept)"

  # At most `bytes` of `text`, never splitting a character.
  defp cut_text(text, bytes) when byte_size(text) <= bytes, do: text

  defp cut_text(text, bytes) do
    text
    |> binary_part(0, bytes)
    |> String.chunk(:valid)
    |> Enum.take_while(&String.valid?/1)
    |> Enum.join()
  end

  defp words({label, value}), do: [label | value_words(value)]

  defp value_words({kind, text}) when kind in [:text, :code], do: [text]
  defp value_words({:list, items}), do: items
  defp value_words({:change, before, now}), do: Enum.reject([before, now], &is_nil/1)
  defp value_words({:link, text, _path}), do: [text]

  defp json({kind, text}) when kind in [:text, :code], do: text
  defp json({:list, items}), do: items
  defp json({:change, before, now}), do: %{"before" => before, "after" => now}
  defp json({:link, text, path}), do: %{"text" => text, "path" => path}
end
