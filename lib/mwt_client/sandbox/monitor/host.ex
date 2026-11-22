defmodule MWTClient.Sandbox.Monitor.Host do
  @moduledoc """
  What the VM costs this machine: the memory and CPU time of its bubble
  and every process under it (the relay, msb, the VM itself), read from
  `/proc` here.

  The bubble's first process is in `bubble.pid`, in MWT's own folder
  (`MWTClient.Sandbox.Sockets.host_dir/1`, `MWTClient.Sandbox.Bubble`);
  the processes under it are found by their parents, in each
  `/proc/<pid>/stat`. A process's CPU time there includes all its threads,
  the VM's CPUs among them.

  Processes are told apart by their id and the time they started, so a
  process id used again is a new process, not the old one going back in
  time.
  """

  @type t :: %{
          at_ms: integer(),
          rss: non_neg_integer(),
          cores: pos_integer(),
          clk_tck: pos_integer(),
          processes: %{{integer(), integer()} => non_neg_integer()}
        }

  @type stat :: %{
          pid: integer(),
          ppid: integer(),
          ticks: non_neg_integer(),
          rss: non_neg_integer(),
          start: integer()
        }

  @doc """
  The process `pid` and those under it, as `root` (`/proc`) shows them, or
  nil when `pid` isn't running.
  """
  @spec read(integer(), Path.t()) :: t() | nil
  def read(pid, root \\ "/proc") do
    case root |> stats() |> tree(pid) do
      [] ->
        nil

      stats ->
        %{page_size: page_size, clk_tck: clk_tck} = constants()

        %{
          at_ms: System.monotonic_time(:millisecond),
          rss: stats |> Enum.map(& &1.rss) |> Enum.sum() |> Kernel.*(page_size),
          cores: cores(),
          clk_tck: clk_tck,
          processes: Map.new(stats, &{{&1.pid, &1.start}, &1.ticks})
        }
    end
  end

  @doc "Every process `root` shows; those that end while it is read are left out."
  @spec stats(Path.t()) :: [stat()]
  def stats(root) do
    case File.ls(root) do
      {:ok, names} ->
        for name <- names,
            digits?(name),
            {:ok, text} <- [File.read(Path.join([root, name, "stat"]))],
            %{} = stat <- [parse_stat(text)],
            do: stat

      {:error, _} ->
        []
    end
  end

  @doc """
  One `/proc/<pid>/stat`, or nil. The name, in parentheses, may hold
  spaces and `)`: the fields that follow it are those after the last `)`.
  """
  @spec parse_stat(String.t()) :: stat() | nil
  def parse_stat(text) do
    with [pid, _] <- String.split(text, " (", parts: 2),
         {pid, ""} <- Integer.parse(pid),
         rest = text |> String.split(")") |> List.last(),
         [_state, ppid | fields] when length(fields) >= 20 <- String.split(rest),
         {ppid, ""} <- Integer.parse(ppid),
         [utime, stime] <- Enum.slice(fields, 9, 2),
         {utime, ""} <- Integer.parse(utime),
         {stime, ""} <- Integer.parse(stime),
         {start, ""} <- Integer.parse(Enum.at(fields, 17)),
         {rss, ""} <- Integer.parse(Enum.at(fields, 19)) do
      %{pid: pid, ppid: ppid, ticks: utime + stime, rss: max(rss, 0), start: start}
    else
      _ -> nil
    end
  end

  @doc "The process `pid` and every one under it, `pid` first; empty when it isn't there."
  @spec tree([stat()], integer()) :: [stat()]
  def tree(stats, pid) do
    case Enum.find(stats, &(&1.pid == pid)) do
      nil ->
        []

      top ->
        children = Enum.group_by(stats, & &1.ppid)
        descend([top], children, [])
    end
  end

  defp descend([], _children, found), do: Enum.reverse(found)

  defp descend([stat | rest], children, found),
    do: descend(rest ++ Map.get(children, stat.pid, []), children, [stat | found])

  @doc "This machine's cores, as many as MWT may run on."
  @spec cores() :: pos_integer()
  def cores do
    case :erlang.system_info(:logical_processors_available) do
      count when is_integer(count) and count > 0 ->
        count

      _unknown ->
        case :erlang.system_info(:logical_processors) do
          count when is_integer(count) and count > 0 -> count
          _ -> 1
        end
    end
  end

  @doc "This machine's page size and clock ticks per second, asked once."
  @spec constants() :: %{page_size: pos_integer(), clk_tck: pos_integer()}
  def constants do
    case :persistent_term.get({__MODULE__, :constants}, nil) do
      nil ->
        constants = %{page_size: getconf("PAGESIZE", 4096), clk_tck: getconf("CLK_TCK", 100)}
        :persistent_term.put({__MODULE__, :constants}, constants)
        constants

      constants ->
        constants
    end
  end

  defp getconf(name, default) do
    with path when is_binary(path) <- MWTClient.Executable.find("getconf"),
         {output, 0} <- System.cmd(path, [name], stderr_to_stdout: true),
         {value, _} when value > 0 <- Integer.parse(String.trim(output)) do
      value
    else
      _ -> default
    end
  end

  defp digits?(name), do: name != "" and String.match?(name, ~r/^\d+$/)
end
