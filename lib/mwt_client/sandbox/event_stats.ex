defmodule MWTClient.Sandbox.EventStats do
  @moduledoc """
  The activity log's figures, worked out from the events of the
  journal (`MWTClient.Sandbox.Activity.stats/3`), so a page gets a small
  summary rather than the events each time it redraws.

  `summarize/3` takes the events that pass the search and grant filters,
  newest first, and the group chosen:

    * `groups` - how many of them each group of `Event.groups/0` holds,
      `"all"` included, so the group buttons can say what choosing them
      would show;
    * `total`, `up`, `down` - how many are in the group chosen, and the
      bytes they sent and received;
    * `hosts` - the busiest destinations among them, with how many of
      their events carried a credential and how many were blocked;
    * `timeline` - how many fell in each step of time, by series, from the
      start given (the page's window, or the oldest event kept) to now.

  The series are the groups the page offers, so a group chosen leaves its
  own colour in the timeline: `:traffic`, `:credentials`, `:blocked` and
  `:other` for everything else (lookups, changes, host commands).
  """

  alias MWTClient.Sandbox.Event

  @series [:traffic, :credentials, :blocked, :other]

  # How long each bar of the timeline may stand for. The shortest that
  # draws the whole span in no more than `@bars` bars is used.
  @steps [15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400]
  @bars 60
  @shortest_span 15 * 60
  @hosts 8

  @type series :: :traffic | :credentials | :blocked | :other
  @type bucket :: %{at: DateTime.t(), counts: %{series() => non_neg_integer()}, total: integer()}

  @type t :: %{
          groups: %{String.t() => non_neg_integer()},
          total: non_neg_integer(),
          up: non_neg_integer(),
          down: non_neg_integer(),
          hosts: [
            %{
              host: String.t(),
              count: pos_integer(),
              credentials: non_neg_integer(),
              blocked: non_neg_integer(),
              bytes: non_neg_integer()
            }
          ],
          timeline: %{
            from: DateTime.t(),
            to: DateTime.t(),
            step: pos_integer(),
            peak: non_neg_integer(),
            buckets: [bucket()]
          }
        }

  @doc "The series of the timeline, in the order they stack, bottom first."
  @spec series() :: [series()]
  def series, do: @series

  @doc "Which series an event's outcome falls in."
  @spec series_of(Event.outcome()) :: series()
  def series_of(outcome) when outcome in [:tunnel, :read], do: :traffic

  def series_of(outcome) when outcome in [:swapped, :allowed, :denied, :timed_out, :refused],
    do: :credentials

  def series_of(outcome) when outcome in [:blocked, :violation, :firewall, :read_failed],
    do: :blocked

  def series_of(_outcome), do: :other

  @doc """
  The figures for `events`, newest first, that pass the search and grant
  filters, at `now`; `group` is the group chosen (`"all"` for none). `oldest` is when
  the oldest event MWT keeps happened, matching or not, so the timeline
  covers the same time whatever is filtered; nil when there is none.
  """
  @spec summarize([Event.t()], String.t(), DateTime.t() | nil, DateTime.t()) :: t()
  def summarize(events, group, oldest, now) do
    outcomes = Map.get(Event.groups(), group)
    chosen = if outcomes, do: Enum.filter(events, &(&1.outcome in outcomes)), else: events

    %{
      groups: groups(events),
      total: length(chosen),
      up: chosen |> Enum.map(&(&1.up || 0)) |> Enum.sum(),
      down: chosen |> Enum.map(&(&1.down || 0)) |> Enum.sum(),
      hosts: hosts(chosen),
      timeline: timeline(chosen, oldest, now)
    }
  end

  defp groups(events) do
    counts = Enum.frequencies_by(events, & &1.outcome)

    Event.groups()
    |> Map.new(fn {id, outcomes} ->
      {id, outcomes |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()}
    end)
    |> Map.put("all", length(events))
  end

  defp hosts(events) do
    events
    |> Enum.filter(& &1.host)
    |> Enum.group_by(& &1.host)
    |> Enum.map(fn {host, events} ->
      %{
        host: host,
        count: length(events),
        credentials: Enum.count(events, &(series_of(&1.outcome) == :credentials)),
        blocked: Enum.count(events, &(series_of(&1.outcome) == :blocked)),
        bytes: events |> Enum.map(&((&1.up || 0) + (&1.down || 0))) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.host})
    |> Enum.take(@hosts)
  end

  @doc """
  The timeline from `oldest` (or `#{div(@shortest_span, 60)}` minutes back,
  if that is earlier) to `now`, in the shortest step of time that needs
  about #{@bars} bars or fewer. Bars start on whole steps of the clock.
  """
  @spec timeline([Event.t()], DateTime.t() | nil, DateTime.t()) :: map()
  def timeline(events, oldest, now) do
    now_s = DateTime.to_unix(now)
    from_s = min(now_s - @shortest_span, (oldest && DateTime.to_unix(oldest)) || now_s)
    span = now_s - from_s
    step = Enum.find(@steps, List.last(@steps), &(div(span, &1) <= @bars))
    first = div(from_s, step) * step
    count = div(now_s - first, step) + 1

    counts =
      Enum.reduce(events, %{}, fn event, acc ->
        index = div(DateTime.to_unix(event.at) - first, step)

        if index >= 0 and index < count,
          do: Map.update(acc, {index, series_of(event.outcome)}, 1, &(&1 + 1)),
          else: acc
      end)

    buckets =
      for index <- 0..(count - 1) do
        series = Map.new(@series, &{&1, Map.get(counts, {index, &1}, 0)})

        %{
          at: DateTime.from_unix!(first + index * step),
          counts: series,
          total: series |> Map.values() |> Enum.sum()
        }
      end

    %{
      from: DateTime.from_unix!(first),
      to: now,
      step: step,
      peak: buckets |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end),
      buckets: buckets
    }
  end
end
