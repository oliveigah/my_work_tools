defmodule MWTClient.Sandbox.Monitor.Sample do
  @moduledoc """
  One look at the VM, as `MWTClient.Sandbox.Monitor` takes it: the script
  that runs in there, reading its output, and turning two readings into
  rates.

  The script (`script/0`) is plain `sh` and POSIX awk, for the guest's
  mawk. It prints sections, each after a line of its own (`@stat`,
  `@meminfo`, ...), and `@end` last, so output cut short shows. It prints
  only what is used: the `cpu` lines of `/proc/stat`, seven lines of
  `/proc/meminfo`, and one short line per process, made in the guest from
  `/proc/<pid>/stat`. A process's name there is in parentheses and may hold
  spaces and `)`, so its other fields are those after the last `)`.

  Counters only grow, so CPU and network are differences between two
  readings (`build/2`): the first reading after a start has no rates.

    * `cpu` - the share of all the VM's CPUs busy, 0 to 100, from the
      `cpu` line of `/proc/stat`: everything but idle and iowait;
    * a process's `cpu` - as `top` shows it: the share of one CPU, so a
      process using two whole CPUs shows 200;
    * `memory` - as `free` counts it: `cache` is buffers, the page cache
      and reclaimable slab, less shared memory (which can't be dropped and
      so counts as used); `used` is the rest of what isn't free;
    * `host.cpu` - the share of one of this machine's cores the VM's
      processes here used, all of them together.
  """

  @window_seconds 600
  @max_points 120
  @top 8

  @type process :: %{pid: integer(), name: String.t(), cpu: float() | nil, rss: integer()}

  @type disk :: %{
          name: :work | :home | :cache,
          mount: String.t(),
          size: integer(),
          used: integer(),
          host_used: integer() | nil
        }

  @type t :: %{
          at: DateTime.t(),
          cpus: pos_integer(),
          cpu: float() | nil,
          load: {float(), float(), float()},
          memory: %{total: integer(), used: integer(), cache: integer(), available: integer()},
          memory_control: map() | nil,
          disks: [disk()],
          network: %{
            rx_rate: float() | nil,
            tx_rate: float() | nil,
            rx_total: integer(),
            tx_total: integer()
          },
          processes: [process()],
          processes_by_memory: [process()],
          host: %{rss: integer() | nil, cpu: float() | nil, cores: pos_integer()} | nil
        }

  @type point :: %{
          at: DateTime.t(),
          cpu: float() | nil,
          mem_used: integer() | nil,
          mem_cache: integer() | nil,
          host_rss: integer() | nil,
          host_cpu: float() | nil,
          rx_rate: float() | nil,
          tx_rate: float() | nil
        }

  @typedoc "What the guest's script reported, read (`parse/1`)."
  @type guest :: %{
          uptime: float(),
          cpus: pos_integer(),
          cpu_total: integer(),
          cpu_idle: integer(),
          load: {float(), float(), float()},
          memory: %{total: integer(), used: integer(), cache: integer(), available: integer()},
          disks: [%{name: atom(), mount: String.t(), size: integer(), used: integer()}],
          rx: integer(),
          tx: integer(),
          clk_tck: pos_integer(),
          processes: [
            %{
              pid: integer(),
              start: integer(),
              ticks: integer(),
              rss: integer(),
              name: String.t()
            }
          ]
        }

  @typedoc """
  One reading: the guest's, this machine's (`MWTClient.Sandbox.Monitor.Host`,
  or nil), and the host space each disk image takes.
  """
  @type reading :: %{
          at: DateTime.t(),
          guest: guest(),
          host: MWTClient.Sandbox.Monitor.Host.t() | nil,
          host_used: %{optional(atom()) => integer() | nil}
        }

  @typedoc "What the next reading is compared with."
  @type counters :: map()

  # `$1` is the folder /proc is in, so tests can use one of their own. The
  # script's own processes are left out (`self`). utime and stime are
  # printed as they are: mawk may print a large sum in exponent notation.
  @script ~S"""
  exec 2>/dev/null
  p=${1:-/proc}
  echo @stat; grep '^cpu' "$p/stat"
  echo @uptime; cat "$p/uptime"
  echo @loadavg; cat "$p/loadavg"
  echo @meminfo; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|Shmem):' "$p/meminfo"
  echo @net; tail -n +3 "$p/net/dev"
  echo @df; df -P -B1 /work /root /cache | tail -n +2
  echo @conf; getconf PAGESIZE; getconf CLK_TCK
  echo @procs
  cat "$p"/[0-9]*/stat | awk -v self=$$ '{
    o = index($0, " (")
    if (o == 0 || !match($0, /\)[^)]*$/)) next
    n = split(substr($0, RSTART + 1), f, " ")
    if (n < 22) next
    pid = substr($0, 1, o - 1)
    if (pid == self || f[2] == self) next
    if (f[12] + f[13] == 0 && f[22] == 0) next
    name = substr($0, o + 2, RSTART - o - 2)
    gsub(/\t/, " ", name)
    print pid "\t" f[12] "\t" f[13] "\t" f[22] "\t" f[20] "\t" name
  }'
  echo @end
  """

  @mounts %{"/work" => :work, "/root" => :home, "/cache" => :cache}

  @doc """
  The script that reads the VM, for `sh -c`. Its one argument is where
  `/proc` is: `/proc` in the VM.
  """
  @spec script() :: String.t()
  def script, do: @script

  @doc "Reads the script's output."
  @spec parse(String.t()) :: {:ok, guest()} | {:error, String.t()}
  def parse(output) do
    sections = sections(output)

    if Map.has_key?(sections, "end") do
      try do
        {:ok, guest(sections)}
      rescue
        _ in [ArgumentError, MatchError, FunctionClauseError, CaseClauseError] ->
          {:error, "The VM's numbers came back in a shape MWT can't read."}
      end
    else
      {:error, "Reading the VM failed: " <> String.slice(String.trim(output), 0, 300)}
    end
  end

  defp sections(output) do
    {sections, _current} =
      output
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn line, {sections, current} ->
        case Regex.run(~r/^@([a-z]+)$/, line) do
          [_, name] -> {Map.put(sections, name, []), name}
          nil when is_nil(current) or line == "" -> {sections, current}
          nil -> {Map.update!(sections, current, &[line | &1]), current}
        end
      end)

    Map.new(sections, fn {name, lines} -> {name, Enum.reverse(lines)} end)
  end

  defp guest(sections) do
    {page_size, clk_tck} = conf(Map.get(sections, "conf", []))
    {cpus, total, idle} = cpu(Map.fetch!(sections, "stat"))
    {rx, tx} = network(Map.get(sections, "net", []))

    %{
      uptime: sections |> Map.fetch!("uptime") |> hd() |> String.split() |> hd() |> float!(),
      cpus: cpus,
      cpu_total: total,
      cpu_idle: idle,
      load: load(sections |> Map.fetch!("loadavg") |> hd()),
      memory: memory(Map.fetch!(sections, "meminfo")),
      disks: disks(Map.get(sections, "df", [])),
      rx: rx,
      tx: tx,
      clk_tck: clk_tck,
      processes: processes(Map.get(sections, "procs", []), page_size)
    }
  end

  defp conf(lines) do
    case Enum.map(lines, &Integer.parse/1) do
      [{page, _}, {tck, _} | _] when page > 0 and tck > 0 -> {page, tck}
      _ -> {4096, 100}
    end
  end

  # The `cpu` line sums every CPU: user, nice, system, idle, iowait, irq,
  # softirq, steal. guest and guest_nice are in user and nice already.
  defp cpu(lines) do
    rows = for line <- lines, [label | numbers] <- [String.split(line)], do: {label, numbers}
    {"cpu", numbers} = List.keyfind(rows, "cpu", 0)

    [user, nice, system, idle, iowait, irq, softirq, steal | _] =
      Enum.map(numbers, &String.to_integer/1) ++ List.duplicate(0, 8)

    cpus = Enum.count(rows, fn {label, _} -> label != "cpu" end)
    {max(cpus, 1), user + nice + system + idle + iowait + irq + softirq + steal, idle + iowait}
  end

  defp load(line) do
    [one, five, fifteen | _] = String.split(line)
    {float!(one), float!(five), float!(fifteen)}
  end

  defp memory(lines) do
    kb =
      Map.new(lines, fn line ->
        [key, value | _] = String.split(line, [":", " "], trim: true)
        {key, String.to_integer(value) * 1024}
      end)

    get = &Map.get(kb, &1, 0)
    total = get.("MemTotal")
    cache = get.("Buffers") + get.("Cached") + get.("SReclaimable") - get.("Shmem")

    %{
      total: total,
      used: max(total - get.("MemFree") - cache, 0),
      cache: max(cache, 0),
      available: Map.get(kb, "MemAvailable", get.("MemFree"))
    }
  end

  # Received bytes are the first number after the name, sent the ninth.
  defp network(lines) do
    lines
    |> Enum.flat_map(fn line ->
      with [name, rest] <- String.split(line, ":", parts: 2),
           false <- String.trim(name) == "lo",
           [rx, _, _, _, _, _, _, _, tx | _] <- String.split(rest) do
        [{String.to_integer(rx), String.to_integer(tx)}]
      else
        _ -> []
      end
    end)
    |> Enum.reduce({0, 0}, fn {rx, tx}, {rxs, txs} -> {rxs + rx, txs + tx} end)
  end

  # From the end: a file system's name may hold spaces, these mounts don't.
  # A folder that isn't a mount of its own shows the one it is in, and is
  # left out.
  defp disks(lines) do
    found =
      Enum.flat_map(lines, fn line ->
        case line |> String.split() |> Enum.take(-5) do
          [size, used, _available, _capacity, mount] when is_map_key(@mounts, mount) ->
            [
              %{
                name: Map.fetch!(@mounts, mount),
                mount: mount,
                size: String.to_integer(size),
                used: String.to_integer(used)
              }
            ]

          _ ->
            []
        end
      end)

    for name <- [:work, :home, :cache],
        %{} = disk <- [Enum.find(found, &(&1.name == name))],
        do: disk
  end

  defp processes(lines, page_size) do
    Enum.flat_map(lines, fn line ->
      with [pid, utime, stime, rss, start, name] <- String.split(line, "\t", parts: 6),
           {pid, ""} <- Integer.parse(pid),
           {utime, ""} <- Integer.parse(utime),
           {stime, ""} <- Integer.parse(stime),
           {rss, ""} <- Integer.parse(rss),
           {start, ""} <- Integer.parse(start) do
        [%{pid: pid, start: start, ticks: utime + stime, rss: rss * page_size, name: name}]
      else
        _ -> []
      end
    end)
  end

  defp float!(text) do
    {value, _} = Float.parse(text)
    value
  end

  @doc """
  A sample from a reading and the counters of the one before it (nil for
  none), and the counters for the next. Readings from a VM that started
  again since (its uptime went back) are not compared.
  """
  @spec build(reading(), counters() | nil) :: {t(), counters()}
  def build(%{at: at, guest: guest, host: host, host_used: host_used} = reading, counters) do
    elapsed = if counters, do: guest.uptime - counters.uptime
    prev = if is_number(elapsed) and elapsed > 0, do: counters

    processes =
      Enum.map(guest.processes, fn process ->
        %{
          pid: process.pid,
          name: process.name,
          rss: process.rss,
          cpu: process_cpu(process, prev, elapsed, guest.clk_tck)
        }
      end)

    sample = %{
      at: at,
      cpus: guest.cpus,
      cpu: busy(guest, prev),
      load: guest.load,
      memory: guest.memory,
      memory_control: Map.get(reading, :memory_control),
      disks: Enum.map(guest.disks, &Map.put(&1, :host_used, Map.get(host_used, &1.name))),
      network: %{
        rx_rate: rate(guest.rx, prev && prev.rx, elapsed),
        tx_rate: rate(guest.tx, prev && prev.tx, elapsed),
        rx_total: guest.rx,
        tx_total: guest.tx
      },
      processes: processes |> Enum.sort_by(&{&1.cpu || 0.0, &1.rss}, :desc) |> Enum.take(@top),
      processes_by_memory:
        processes |> Enum.sort_by(&{&1.rss, &1.cpu || 0.0}, :desc) |> Enum.take(@top),
      host: host && %{rss: host.rss, cpu: host_cpu(host, prev && prev.host), cores: host.cores}
    }

    counters = %{
      uptime: guest.uptime,
      cpu_total: guest.cpu_total,
      cpu_idle: guest.cpu_idle,
      rx: guest.rx,
      tx: guest.tx,
      processes: ticks(guest.processes),
      host: host && %{at_ms: host.at_ms, processes: host.processes}
    }

    {sample, counters}
  end

  defp busy(_guest, nil), do: nil

  defp busy(guest, prev) do
    total = guest.cpu_total - prev.cpu_total
    idle = guest.cpu_idle - prev.cpu_idle

    if total > 0,
      do: ((total - idle) / total * 100) |> max(0.0) |> min(100.0) |> Float.round(1)
  end

  # A process the last reading didn't have started since: all its time is new.
  defp process_cpu(_process, nil, _elapsed, _clk_tck), do: nil

  defp process_cpu(process, prev, elapsed, clk_tck) do
    used = process.ticks - Map.get(prev.processes, {process.pid, process.start}, 0)
    Float.round(max(used, 0) / clk_tck / elapsed * 100, 1)
  end

  defp rate(_now, nil, _elapsed), do: nil
  defp rate(now, before, _elapsed) when now < before, do: nil
  defp rate(now, before, elapsed), do: Float.round((now - before) / elapsed, 1)

  defp host_cpu(_host, nil), do: nil

  defp host_cpu(host, prev) do
    elapsed = (host.at_ms - prev.at_ms) / 1000

    if elapsed > 0 do
      used =
        Enum.reduce(host.processes, 0, fn {key, ticks}, sum ->
          sum + max(ticks - Map.get(prev.processes, key, 0), 0)
        end)

      Float.round(used / host.clk_tck / elapsed * 100, 1)
    end
  end

  defp ticks(processes), do: Map.new(processes, &{{&1.pid, &1.start}, &1.ticks})

  @doc "What the charts keep of a sample."
  @spec point(t()) :: point()
  def point(sample) do
    %{
      at: sample.at,
      cpu: sample.cpu,
      mem_used: sample.memory.used,
      mem_cache: sample.memory.cache,
      host_rss: sample.host && sample.host.rss,
      host_cpu: sample.host && sample.host.cpu,
      rx_rate: sample.network.rx_rate,
      tx_rate: sample.network.tx_rate
    }
  end

  @doc """
  The history with `point` added, oldest first: the last
  #{div(@window_seconds, 60)} minutes before it, #{@max_points} points at most.
  """
  @spec remember([point()], point()) :: [point()]
  def remember(history, %{at: at} = point) do
    since = DateTime.add(at, -@window_seconds, :second)

    (history ++ [point])
    |> Enum.filter(&(DateTime.compare(&1.at, since) == :gt))
    |> Enum.take(-@max_points)
  end
end
