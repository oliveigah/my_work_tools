defmodule MWTClient.Sandbox.ConsoleHistory do
  @moduledoc """
  The console's runs (`MWTClient.Sandbox.Console`), newest first: what
  each printed and how it ended, to read again after you leave the page,
  and to run again.

  The sandbox's server keeps it, in memory only: it goes when the
  identity locks, MWT stops or the server fails, and never reaches the
  disk. What a run
  printed is the VM's, and may hold what a service answered; the
  activity log keeps a line of each run (`Console.summary/1`), never its
  output, for as long as it keeps the rest.

  At most 100 runs and 8 MiB of output: past either, the oldest runs
  go. A run's output is at most `Console.max_output/0`, so the newest
  always stays.
  """

  @most 100
  @most_bytes 8 * 1024 * 1024

  @typedoc """
  A run as kept: `Console.result/0`, with its `id` in this history and
  whether you stopped it from the page (`stopped`), which leaves it
  no output and no status.
  """
  @type run :: %{
          required(:id) => pos_integer(),
          required(:command) => String.t(),
          required(:credential) => String.t() | nil,
          required(:status) => non_neg_integer() | nil,
          required(:output) => String.t(),
          required(:cut) => boolean(),
          required(:timed_out) => boolean(),
          required(:stopped) => boolean(),
          required(:started_at) => DateTime.t(),
          required(:finished_at) => DateTime.t()
        }

  @doc """
  `runs` with `run` first, given the next id; the oldest dropped past
  #{@most} runs or #{div(@most_bytes, 1024 * 1024)} MiB of output.

      iex> alias MWTClient.Sandbox.ConsoleHistory
      iex> at = ~U[2026-11-25 10:00:00Z]
      iex> run = %{command: "ls", credential: nil, status: 0, output: "a", cut: false,
      ...>   timed_out: false, started_at: at, finished_at: at}
      iex> [second, first] = [] |> ConsoleHistory.add(run) |> ConsoleHistory.add(%{run | command: "pwd"})
      iex> {first.id, first.command, first.stopped, second.id, second.command}
      {1, "ls", false, 2, "pwd"}
  """
  @spec add([run()], map()) :: [run()]
  def add(runs, run) do
    id = 1 + Enum.reduce(runs, 0, &max(&1.id, &2))

    run =
      run
      |> Map.take([
        :command,
        :credential,
        :status,
        :output,
        :cut,
        :timed_out,
        :started_at,
        :finished_at
      ])
      |> Map.merge(%{id: id, stopped: Map.get(run, :stopped, false)})

    [run | runs]
    |> Enum.take(@most)
    |> Enum.reduce_while({[], 0}, fn kept, {acc, bytes} ->
      bytes = bytes + byte_size(kept.output)

      if bytes > @most_bytes and acc != [],
        do: {:halt, {acc, bytes}},
        else: {:cont, {[kept | acc], bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  The runs whose command or credential holds `term`, whatever its case;
  every run when it is blank.

      iex> runs = [%{command: "gh repo view o/r", credential: "github"}, %{command: "ls", credential: nil}]
      iex> MWTClient.Sandbox.ConsoleHistory.matching(runs, "GITHUB") |> Enum.map(& &1.command)
      ["gh repo view o/r"]
      iex> MWTClient.Sandbox.ConsoleHistory.matching(runs, " ") |> length()
      2
  """
  @spec matching([map()], String.t() | nil) :: [map()]
  def matching(runs, term) do
    case term |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        runs

      term ->
        Enum.filter(runs, fn run ->
          String.contains?(String.downcase(run.command), term) or
            String.contains?(String.downcase(run.credential || ""), term)
        end)
    end
  end
end
