defmodule MWTClient.Sandbox.Monitor.SampleTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Monitor.Sample

  @at ~U[2026-11-14 12:00:00.000Z]

  # The script's output, as a VM with two CPUs prints it.
  defp output(o \\ []) do
    o =
      Map.merge(
        %{
          busy: 1_000,
          idle: 9_000,
          iowait: 0,
          uptime: "100.00",
          rx: 1_000,
          tx: 2_000,
          procs: [{1, 10, 5, 300, 50, "init"}]
        },
        Map.new(o)
      )

    procs =
      Enum.map_join(o.procs, "\n", fn {pid, utime, stime, rss, start, name} ->
        "#{pid}\t#{utime}\t#{stime}\t#{rss}\t#{start}\t#{name}"
      end)

    """
    @stat
    cpu  #{o.busy} 0 0 #{o.idle} #{o.iowait} 0 0 0 0 0
    cpu0 #{div(o.busy, 2)} 0 0 #{div(o.idle, 2)} 0 0 0 0 0 0
    cpu1 #{div(o.busy, 2)} 0 0 #{div(o.idle, 2)} 0 0 0 0 0 0
    @uptime
    #{o.uptime} 190.00
    @loadavg
    0.50 0.25 0.10 1/120 999
    @meminfo
    MemTotal:        4000000 kB
    MemFree:         1000000 kB
    MemAvailable:    2500000 kB
    Buffers:          100000 kB
    Cached:          1200000 kB
    Shmem:            200000 kB
    SReclaimable:     100000 kB
    @net
        lo:  555555    10    0    0    0     0          0         0   555555    10    0    0    0     0       0          0
      eth0: #{o.rx}    20    0    0    0     0          0         0 #{o.tx}    30    0    0    0     0       0          0
    dummy0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
    @df
    /dev/vde       67049664512  916189184 62680727552       2% /work
    /dev/vdd       16729894912 1522434048 14331691008      10% /root
    /dev/vda        8000000000 4000000000  4000000000      50% /
    @conf
    4096
    100
    @procs
    #{procs}
    @end
    """
  end

  defp reading(o \\ [], host \\ nil) do
    {:ok, guest} = Sample.parse(output(o))
    %{at: @at, guest: guest, host: host, host_used: %{work: 123, home: nil}}
  end

  # A /proc/<pid>/stat line as the kernel writes it.
  defp stat_line(pid, comm, ppid, utime, stime, start, rss) do
    "#{pid} (#{comm}) S #{ppid} #{pid} #{pid} 0 -1 4194560 1234 0 5 0 #{utime} #{stime} " <>
      "0 0 20 0 1 0 #{start} 123456789 #{rss} 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 1 0 0\n"
  end

  defp point(at), do: %{at: at, cpu: 1.0}

  describe "parse/1" do
    test "reads every section" do
      assert {:ok, guest} = Sample.parse(output())

      assert guest.cpus == 2
      assert guest.cpu_total == 10_000
      assert guest.cpu_idle == 9_000
      assert guest.uptime == 100.0
      assert guest.load == {0.5, 0.25, 0.1}
      assert guest.clk_tck == 100
      # lo is left out; the other interfaces add up.
      assert {guest.rx, guest.tx} == {1_000, 2_000}

      # /cache isn't a mount of its own here, and / isn't one of the VM's disks.
      assert [
               %{name: :work, mount: "/work", size: 67_049_664_512, used: 916_189_184},
               %{name: :home, mount: "/root", size: 16_729_894_912, used: 1_522_434_048}
             ] = guest.disks

      assert guest.processes == [%{pid: 1, start: 50, ticks: 15, rss: 300 * 4096, name: "init"}]
    end

    test "counts memory as free does" do
      {:ok, %{memory: memory}} = Sample.parse(output())
      kib = 1024

      # Cache is buffers, cached and reclaimable slab, less shared memory;
      # used is what is neither free nor cache.
      assert memory.cache == (100_000 + 1_200_000 + 100_000 - 200_000) * kib
      assert memory.used == (4_000_000 - 1_000_000 - 1_200_000) * kib
      assert memory.total == 4_000_000 * kib
      assert memory.available == 2_500_000 * kib
      assert memory.used + memory.cache + 1_000_000 * kib == memory.total
    end

    test "names may hold spaces, tabs and parentheses" do
      {:ok, guest} = Sample.parse(output(procs: [{7, 1, 1, 1, 1, "my) proc (x\twith tab"}]))
      assert [%{pid: 7, name: "my) proc (x\twith tab"}] = guest.processes
    end

    test "output cut short is an error" do
      cut = output() |> String.split("@procs") |> hd()
      assert {:error, "Reading the VM failed: " <> _} = Sample.parse(cut)
      assert {:error, "Reading the VM failed: no such VM"} = Sample.parse("no such VM\n")
    end

    test "output in another shape is an error" do
      broken = String.replace(output(), "cpu  1000", "cpu  many")
      assert {:error, "The VM's numbers came back" <> _} = Sample.parse(broken)
    end
  end

  describe "the script" do
    @describetag :tmp_dir

    test "reads a /proc and its processes, whatever their names", %{tmp_dir: proc} do
      File.write!(Path.join(proc, "stat"), """
      cpu  4705 150 1120 1659940 1120 0 54 0 0 0
      cpu0 2361 75 560 829970 560 0 27 0 0 0
      cpu1 2344 75 560 829970 560 0 27 0 0 0
      intr 114930548 113199788 3 0 5 263 0 4 [... lots more numbers ...]
      ctxt 1990473
      btime 1062191376
      processes 2915
      """)

      File.write!(Path.join(proc, "uptime"), "8300.55 16540.12\n")
      File.write!(Path.join(proc, "loadavg"), "0.20 0.18 0.12 1/80 11206\n")

      File.write!(Path.join(proc, "meminfo"), """
      MemTotal:        2048000 kB
      MemFree:          512000 kB
      MemAvailable:    1024000 kB
      Buffers:           10240 kB
      Cached:           409600 kB
      SwapCached:            0 kB
      Active:           900000 kB
      Shmem:             20480 kB
      ShmemHugePages:        0 kB
      SReclaimable:      51200 kB
      SUnreclaim:        30000 kB
      """)

      File.mkdir_p!(Path.join(proc, "net"))

      File.write!(Path.join(proc, "net/dev"), """
      Inter-|   Receive                                                |  Transmit
       face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          lo:  890564    4173    0    0    0     0          0         0   890564    4173    0    0    0     0       0          0
        eth0: 4362721   39132    0    0    0     0          0         0 189390732  149500    0    0    0     0       0          0
      """)

      for {pid, line} <- [
            {1, stat_line(1, "init.krun", 0, 130, 201, 88, 737)},
            # A kernel thread that never ran is left out; one that ran stays.
            {2, stat_line(2, "kthreadd", 0, 0, 0, 1, 0)},
            {11, stat_line(11, "kworker/0:1-events", 2, 0, 23, 88, 0)},
            {4242, stat_line(4242, "my) proc (x", 1, 400, 100, 9000, 2048)},
            {4243, stat_line(4243, "Web Content", 1, 7, 3, 9100, 1024)}
          ] do
        File.mkdir_p!(Path.join(proc, "#{pid}"))
        File.write!(Path.join([proc, "#{pid}", "stat"]), line)
      end

      {output, 0} = System.cmd("sh", ["-c", Sample.script(), "mwt-monitor", proc])
      assert {:ok, guest} = Sample.parse(output)

      assert guest.cpus == 2
      assert guest.cpu_total == 4705 + 150 + 1120 + 1_659_940 + 1120 + 54
      assert guest.cpu_idle == 1_659_940 + 1120
      assert guest.uptime == 8300.55
      assert guest.load == {0.2, 0.18, 0.12}
      assert {guest.rx, guest.tx} == {4_362_721, 189_390_732}
      assert guest.memory.total == 2_048_000 * 1024
      assert guest.memory.cache == (10_240 + 409_600 + 51_200 - 20_480) * 1024

      # The shell's glob sorts by locale (en_US puts 11/ before 1/).
      page = guest.processes |> Enum.find(&(&1.pid == 1)) |> Map.fetch!(:rss) |> div(737)

      assert Enum.sort_by(guest.processes, & &1.pid) == [
               %{pid: 1, start: 88, ticks: 331, rss: 737 * page, name: "init.krun"},
               %{pid: 11, start: 88, ticks: 23, rss: 0, name: "kworker/0:1-events"},
               %{pid: 4242, start: 9000, ticks: 500, rss: 2048 * page, name: "my) proc (x"},
               %{pid: 4243, start: 9100, ticks: 10, rss: 1024 * page, name: "Web Content"}
             ]
    end
  end

  describe "build/2" do
    test "the first sample has no rates" do
      {sample, counters} = Sample.build(reading(), nil)

      assert sample.at == @at
      assert sample.cpus == 2
      assert sample.cpu == nil
      assert sample.network == %{rx_rate: nil, tx_rate: nil, rx_total: 1_000, tx_total: 2_000}
      assert [%{pid: 1, name: "init", cpu: nil, rss: 1_228_800}] = sample.processes
      assert sample.processes_by_memory == sample.processes
      assert sample.host == nil
      assert counters.uptime == 100.0

      # Each disk with the host space its image takes, nil when unknown.
      assert [%{name: :work, host_used: 123}, %{name: :home, host_used: nil}] = sample.disks
    end

    test "CPU, network and processes are rates since the sample before" do
      {_first, counters} =
        Sample.build(
          reading(
            procs: [
              {1, 10, 5, 300, 50, "init"},
              {20, 100, 0, 1_000, 60, "busy"},
              {21, 0, 0, 5_000, 61, "big"},
              {22, 0, 0, 10, 62, "gone"}
            ]
          ),
          nil
        )

      # Five seconds later: 2 CPUs give 1000 ticks, 400 of them busy.
      {sample, _} =
        Sample.build(
          reading(
            busy: 1_400,
            idle: 9_500,
            iowait: 100,
            uptime: "105.00",
            rx: 6_000,
            tx: 2_500,
            procs: [
              {1, 10, 5, 300, 50, "init"},
              {20, 400, 100, 1_000, 60, "busy"},
              {21, 0, 0, 5_000, 61, "big"},
              # Started since: all its time is new.
              {30, 20, 5, 200, 9_000, "new"},
              # A process id used again is another process.
              {22, 50, 0, 10, 9_100, "reused"}
            ]
          ),
          counters
        )

      assert sample.cpu == 40.0
      assert sample.network.rx_rate == 1_000.0
      assert sample.network.tx_rate == 100.0
      assert sample.network.rx_total == 6_000

      # As top shows it: a share of one CPU. 400 ticks in 5 s at 100 Hz is
      # 80%. Equal CPU is ordered by memory.
      assert Enum.map(sample.processes, &{&1.name, &1.cpu}) == [
               {"busy", 80.0},
               {"reused", 10.0},
               {"new", 5.0},
               {"big", 0.0},
               {"init", 0.0}
             ]

      assert Enum.map(sample.processes_by_memory, & &1.name) ==
               ["big", "busy", "init", "new", "reused"]
    end

    test "keeps the eight busiest and the eight largest" do
      procs = for pid <- 1..20, do: {pid, pid, 0, 21 - pid, pid, "p#{pid}"}
      {_first, counters} = Sample.build(reading(procs: procs), nil)

      later = for pid <- 1..20, do: {pid, pid * 2, 0, 21 - pid, pid, "p#{pid}"}
      {sample, _} = Sample.build(reading(uptime: "105.00", procs: later), counters)

      assert Enum.map(sample.processes, & &1.pid) == Enum.to_list(20..13//-1)
      assert Enum.map(sample.processes_by_memory, & &1.pid) == Enum.to_list(1..8)
    end

    test "a VM that started again is not compared with the one before" do
      {_first, counters} = Sample.build(reading(uptime: "500.00"), nil)
      {sample, _} = Sample.build(reading(uptime: "3.00", busy: 50, idle: 100), counters)

      assert sample.cpu == nil
      assert sample.network.rx_rate == nil
      assert [%{cpu: nil}] = sample.processes
    end

    test "a network counter that went back has no rate" do
      {_first, counters} = Sample.build(reading(rx: 9_000), nil)
      {sample, _} = Sample.build(reading(uptime: "105.00", rx: 10), counters)

      assert sample.network.rx_rate == nil
      assert sample.network.tx_rate == 0.0
    end

    test "the host's CPU is a share of one core, over all the VM's processes" do
      host = fn at_ms, processes ->
        %{at_ms: at_ms, rss: 3_000, cores: 8, clk_tck: 100, processes: processes}
      end

      first = host.(0, %{{100, 1} => 50, {101, 2} => 1_000, {102, 3} => 7})
      {sample, counters} = Sample.build(reading([], first), nil)
      assert sample.host == %{rss: 3_000, cpu: nil, cores: 8}

      # 2 s later: the VM used 300 ticks; 102 ended, 103 started.
      second = host.(2_000, %{{100, 1} => 50, {101, 2} => 1_280, {103, 9} => 20})
      {sample, _} = Sample.build(reading([uptime: "102.00"], second), counters)
      assert sample.host == %{rss: 3_000, cpu: 150.0, cores: 8}
    end
  end

  describe "history" do
    test "keeps the last ten minutes" do
      old = point(DateTime.add(@at, -600, :second))
      recent = point(DateTime.add(@at, -595, :second))

      assert Sample.remember([old, recent], point(@at)) == [recent, point(@at)]
    end

    test "keeps 120 points at most, oldest first" do
      history =
        Enum.reduce(-200..0//1, [], fn s, history ->
          Sample.remember(history, point(DateTime.add(@at, s, :second)))
        end)

      assert length(history) == 120
      assert hd(history).at == DateTime.add(@at, -119, :second)
      assert List.last(history).at == @at
    end

    test "a point is what the charts draw" do
      {sample, _} =
        Sample.build(
          reading([], %{at_ms: 0, rss: 3_000, cores: 8, clk_tck: 100, processes: %{}}),
          nil
        )

      assert Sample.point(sample) == %{
               at: @at,
               cpu: nil,
               mem_used: sample.memory.used,
               mem_cache: sample.memory.cache,
               host_rss: 3_000,
               host_cpu: nil,
               rx_rate: nil,
               tx_rate: nil
             }

      assert %{host_rss: nil, host_cpu: nil} = Sample.point(%{sample | host: nil})
    end
  end
end
