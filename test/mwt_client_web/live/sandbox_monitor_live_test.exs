defmodule MWTClientWeb.SandboxMonitorLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClientWeb.SandboxLive.Monitor

  @gib 1024 * 1024 * 1024
  @until ~U[2026-11-14 12:10:00.000Z]

  defp at(seconds_before), do: DateTime.add(@until, -seconds_before, :second)

  defp process(pid, name, cpu, rss), do: %{pid: pid, name: name, cpu: cpu, rss: rss}

  defp sample(overrides \\ %{}) do
    Map.merge(
      %{
        at: @until,
        cpus: 12,
        cpu: 23.4,
        load: {0.51, 0.25, 0.09},
        memory: %{total: 24 * @gib, used: 3 * @gib, cache: div(@gib, 2), available: 20 * @gib},
        disks: [
          %{name: :work, mount: "/work", size: 64 * @gib, used: @gib, host_used: 2 * @gib},
          %{name: :home, mount: "/root", size: 16 * @gib, used: 14 * @gib, host_used: @gib},
          %{name: :cache, mount: "/cache", size: 10 * @gib, used: 10 * @gib - 1, host_used: nil}
        ],
        network: %{rx_rate: 1_200_000.0, tx_rate: 40_000.0, rx_total: 3 * @gib, tx_total: @gib},
        processes: for(n <- 1..8, do: process(n, "proc-#{n}", 100.0 - n * 10, n * 1_000_000)),
        processes_by_memory:
          for(n <- 1..8, do: process(100 + n, "big-#{n}", 1.0, (9 - n) * @gib)),
        host: %{rss: 2 * @gib + div(@gib, 2), cpu: 12.5, cores: 16}
      },
      overrides
    )
  end

  defp history do
    # Two minutes of samples, a stop of a minute, then the last minute.
    for s <- Enum.to_list(300..180//-5) ++ Enum.to_list(60..0//-5) do
      %{
        at: at(s),
        cpu: s / 10,
        mem_used: 3 * @gib,
        mem_cache: @gib,
        host_rss: 2 * @gib,
        host_cpu: 5.0,
        rx_rate: 1000.0,
        tx_rate: 10.0
      }
    end
  end

  defp snapshot(latest, error \\ nil),
    do: %{latest: latest, history: history(), error: error, interval_ms: 5000}

  defp card(assigns) do
    html = render_component(&Monitor.card/1, assigns)
    page = LazyHTML.from_fragment(html)
    {page, fn selector -> page |> LazyHTML.query(selector) |> LazyHTML.text() end}
  end

  test "while the VM is off, it says what it will show" do
    {page, _text} = card(monitor: nil, vm: %{status: :stopped})
    assert LazyHTML.query(page, "#vm-resources-off") |> Enum.count() == 1
  end

  test "before the first sample it is measuring; a failure says why" do
    {page, _} = card(monitor: %{snapshot(nil) | history: []}, vm: %{status: :running})
    assert LazyHTML.query(page, "#vm-resources-waiting") |> Enum.count() == 1

    {_page, text} = card(monitor: snapshot(nil, "The VM isn't running."), vm: %{status: :running})
    assert text.("#vm-resources-error") =~ "The VM isn't running."
  end

  test "shows the VM inside and what it costs your machine, with ten-minute sparklines" do
    {page, text} = card(monitor: snapshot(sample()), vm: %{status: :running})

    assert text.("#vm-cpu") =~ "23%" and text.("#vm-cpu") =~ "of 12 CPUs"
    assert text.("#vm-memory") =~ "3.0 GB" and text.("#vm-memory") =~ "of 24.0 GB"
    assert text.("#vm-network") =~ "↓ 1.1 MB/s" and text.("#vm-network") =~ "↑ 39.1 KB/s"
    assert text.("#vm-host") =~ "2.5 GB" and text.("#vm-host") =~ "13% of a core"

    # A sparkline per figure, each point hoverable for its value.
    for id <- ~w(vm-cpu-spark vm-memory-spark vm-network-spark vm-host-spark),
        do: assert(LazyHTML.query(page, "##{id}[role=img]") |> Enum.count() == 1)

    assert text.("#vm-cpu-spark title") =~ "0.0% · now"

    # Disks: a meter each, nearly full and full ones said in words too.
    assert text.("#vm-disk-work") =~ "takes 2.0 GB on your machine"
    assert text.("#vm-disk-home") =~ "nearly full"
    assert text.("#vm-disk-cache") =~ "full"
    assert text.("#vm-disks") =~ "Together they take 3.0 GB on your machine"

    # The busiest six processes, by CPU.
    assert LazyHTML.query(page, "#vm-processes tbody tr") |> Enum.count() == 6
    assert text.("#vm-process-1") =~ "proc-1" and text.("#vm-process-1") =~ "90%"
  end

  test "lists processes by memory when asked, and says when the host side is unknown" do
    {page, text} =
      card(monitor: snapshot(sample(%{host: nil})), vm: %{status: :running}, by: :memory)

    assert text.("#vm-processes tbody tr:first-child") =~ "big-1"
    assert text.("#vm-host") =~ "can't see the VM's processes"
    assert LazyHTML.query(page, "#vm-host-spark") |> Enum.count() == 0
  end

  test "shows the memory target and ceiling, and explains a control failure" do
    control = %{minimum_mib: 4096, maximum_mib: 24576, target_mib: 8192, error: nil}

    {_page, text} =
      card(monitor: snapshot(sample(%{memory_control: control})), vm: %{status: :running})

    assert text.("#vm-memory-control") =~ "Target 8.0 GB"
    assert text.("#vm-memory-control") =~ "limit 24.0 GB"

    {_page, text} =
      card(
        monitor: snapshot(sample(%{memory_control: %{error: "Restart the VM"}})),
        vm: %{status: :running}
      )

    assert text.("#vm-memory-control") =~ "Restart the VM"
  end

  test "a sparkline breaks where the VM wasn't running, and ends at the latest sample" do
    marks = Monitor.marks(Monitor.series(history(), :cpu), 100, @until)
    assert length(marks.lines) == 2
    assert length(marks.bands) == length(history())
    # The latest is 0%: at the bottom.
    assert marks.last > 90

    # Points older than ten minutes are left out; nothing to draw is fine.
    old = [{at(700), 50.0}, {at(0), 50.0}]
    assert %{lines: [_], bands: [_]} = Monitor.marks(old, 100, @until)
    assert %{lines: [], bands: [], last: nil} = Monitor.marks([], 100, @until)
  end
end
