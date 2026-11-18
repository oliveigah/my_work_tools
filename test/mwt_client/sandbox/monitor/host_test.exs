defmodule MWTClient.Sandbox.Monitor.HostTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Monitor.Host

  @moduletag :tmp_dir

  # A /proc/<pid>/stat line as the kernel writes it.
  defp stat_line(pid, comm, ppid, utime, stime, start, rss) do
    "#{pid} (#{comm}) S #{ppid} #{pid} #{pid} 0 -1 4194560 1234 0 5 0 #{utime} #{stime} " <>
      "0 0 20 0 1 0 #{start} 123456789 #{rss} 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 1 0 0\n"
  end

  defp fake_proc(root, processes) do
    for {pid, comm, ppid, utime, stime, start, rss} <- processes do
      File.mkdir_p!(Path.join(root, "#{pid}"))

      File.write!(
        Path.join([root, "#{pid}", "stat"]),
        stat_line(pid, comm, ppid, utime, stime, start, rss)
      )
    end

    # What else /proc holds, which isn't a process.
    File.write!(Path.join(root, "stat"), "cpu  1 2 3 4\n")
    File.mkdir_p!(Path.join(root, "self"))
    root
  end

  test "sums the bubble and every process under it", %{tmp_dir: root} do
    fake_proc(root, [
      {1, "systemd", 0, 900, 900, 1, 3_000},
      {500, "bwrap", 1, 1, 1, 7_000, 100},
      {501, "mwt-relay", 500, 2, 3, 7_001, 200},
      {502, "msb", 501, 10, 5, 7_002, 1_000},
      # The VM: its threads' time is in its own line.
      {503, "krun VMM (x) y", 502, 4_000, 1_000, 7_003, 50_000},
      {504, "msb", 501, 0, 0, 7_004, 300},
      # Not the VM's, though close by.
      {600, "msb", 1, 77, 77, 8_000, 9_999},
      {601, "bash", 600, 5, 5, 8_001, 999}
    ])

    %{page_size: page} = Host.constants()
    assert %{} = host = Host.read(500, root)

    assert host.rss == (100 + 200 + 1_000 + 50_000 + 300) * page
    assert host.cores == Host.cores()
    assert host.clk_tck == Host.constants().clk_tck
    assert is_integer(host.at_ms)

    assert host.processes == %{
             {500, 7_000} => 2,
             {501, 7_001} => 5,
             {502, 7_002} => 15,
             {503, 7_003} => 5_000,
             {504, 7_004} => 0
           }
  end

  test "nothing when the bubble isn't running", %{tmp_dir: root} do
    fake_proc(root, [{1, "systemd", 0, 900, 900, 1, 3_000}])

    assert Host.read(500, root) == nil
    assert Host.read(500, Path.join(root, "missing")) == nil
  end

  test "a stat that can't be read is left out", %{tmp_dir: root} do
    fake_proc(root, [{500, "bwrap", 1, 1, 1, 7_000, 100}])
    File.mkdir_p!(Path.join(root, "501"))
    File.mkdir_p!(Path.join(root, "502"))
    File.write!(Path.join(root, "502/stat"), "garbage")

    assert [%{pid: 500}] = Host.stats(root)
  end

  test "reads a name with spaces and parentheses" do
    assert %{pid: 42, ppid: 7, ticks: 30, rss: 9, start: 123} =
             Host.parse_stat(stat_line(42, "a) b (c", 7, 10, 20, 123, 9))

    assert Host.parse_stat("42 (short) S 7") == nil
  end

  test "finds a whole tree, its top first" do
    stats = [
      %{pid: 3, ppid: 2},
      %{pid: 2, ppid: 1},
      %{pid: 1, ppid: 0},
      %{pid: 4, ppid: 1},
      %{pid: 9, ppid: 8}
    ]

    assert Enum.map(Host.tree(stats, 1), & &1.pid) == [1, 2, 4, 3]
    assert Host.tree(stats, 5) == []
  end

  test "reads this machine's /proc" do
    host = Host.read(String.to_integer(System.pid()))

    assert host.rss > 0
    assert map_size(host.processes) >= 1
  end
end
