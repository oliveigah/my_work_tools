defmodule MWTClientWeb.SandboxLive.Monitor do
  @moduledoc """
  The VM's resources on the overview, from `MWTClient.Sandbox.Monitor`: what
  the VM uses inside (CPU, memory, network, its disks, its busiest
  processes) and what it costs your machine (the memory its processes hold
  on the host, the space its disk images take), sampled every few seconds
  while it runs, with the last ten minutes as sparklines.

  Each figure is a stat tile: the value now, what it is out of, and a
  sparkline of the last ten minutes in a quiet ink with the latest point in
  the accent. Hovering a point gives its value and how long ago. Disks are a
  meter list, one bar per disk, that turns to the warning colour and says so
  when a disk is nearly full. What each one means is behind its "?", so
  nothing but figures sits under the graphs.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components, only: [bytes: 1]

  # The sparklines' drawing box and window.
  @width 120
  @height 28
  @window_ms 600_000
  # Further apart than this, two points are not joined: the VM stopped.
  @gap_ms 15_000

  attr :monitor, :any, required: true, doc: "`MWTClient.Sandbox.Monitor.snapshot/1`, or nil"
  attr :vm, :any, required: true
  attr :by, :atom, default: :cpu, doc: "the processes listed by `:cpu` or `:memory`"

  def card(assigns) do
    assigns =
      assign(assigns,
        latest: assigns.monitor && assigns.monitor.latest,
        history: (assigns.monitor && assigns.monitor.history) || [],
        error: assigns.monitor && assigns.monitor.error
      )

    ~H"""
    <section id="vm-resources" class="mb-6 overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex flex-wrap items-center gap-2 border-b border-line-soft px-4 py-2.5">
        <h2 class="text-[11px] font-semibold uppercase tracking-wide text-muted">Resources</h2>
        <span :if={@latest} class="text-[11px] text-faint">
          · last 10 minutes, every {div((@monitor && @monitor.interval_ms) || 5000, 1000)} s
        </span>
        <div class="flex-1"></div>
        <span :if={@latest} class="flex items-center gap-1.5 text-[11px] text-faint">
          <span class="relative flex size-1.5">
            <span class="absolute inline-flex size-full animate-ping rounded-full bg-ok/60"></span>
            <span class="relative inline-flex size-1.5 rounded-full bg-ok"></span>
          </span>
          live
        </span>
      </header>

      <%= cond do %>
        <% @vm.status != :running -> %>
          <p id="vm-resources-off" class="px-4 py-4 text-[12px] text-faint">
            Shown while the VM runs: its CPU, memory, disks and network, and what it costs your machine.
          </p>
        <% is_nil(@latest) and @error -> %>
          <p id="vm-resources-error" class="px-4 py-4 text-[12px] text-bad">{@error}</p>
        <% is_nil(@latest) -> %>
          <p
            id="vm-resources-waiting"
            class="flex items-center gap-2 px-4 py-4 text-[12px] text-faint"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5 animate-spin" /> Measuring…
          </p>
        <% true -> %>
          <p
            :if={@error}
            id="vm-resources-error"
            class="border-b border-line-soft bg-bad-soft/20 px-4 py-1.5 text-[11px] text-bad"
          >
            {@error} Showing the last sample.
          </p>
          <div class="grid gap-px bg-line-soft sm:grid-cols-2 lg:grid-cols-4">
            <.tile
              id="vm-cpu"
              label="CPU"
              value={percent(@latest.cpu)}
              detail={"of #{@latest.cpus} CPUs · load #{load(@latest.load)}"}
            >
              <:help>
                How busy the VM's CPUs were since the last sample, all of them together. Load is the average number of processes running or waiting to, over 1, 5 and 15 minutes.
              </:help>
              <.sparkline
                id="vm-cpu-spark"
                label="CPU"
                points={series(@history, :cpu)}
                max={100}
                format={&percent/1}
                until={@latest.at}
              />
            </.tile>
            <.tile
              id="vm-memory"
              label="Memory"
              value={bytes(@latest.memory.used)}
              detail={"of #{bytes(@latest.memory.total)} · #{bytes(@latest.memory.cache)} cache"}
              warning={memory_warning(@latest)}
            >
              <:help>
                What the VM's programs use, without the cache the VM keeps of its files: the cache is given back when programs need it.
                <span
                  :if={control = Map.get(@latest, :memory_control)}
                  id="vm-memory-control"
                  class="mt-1.5 block"
                >
                  <%= if Map.get(control, :maximum_mib) do %>
                    Target {bytes(control.target_mib * 1024 * 1024)} · limit {bytes(
                      control.maximum_mib * 1024 * 1024
                    )}: RAM is returned when your desktop needs it.
                  <% end %>
                  <span :if={control.error} class="text-warn-strong">{control.error}</span>
                </span>
              </:help>
              <.sparkline
                id="vm-memory-spark"
                label="Memory used"
                points={series(@history, :mem_used)}
                max={@latest.memory.total}
                format={&bytes/1}
                until={@latest.at}
              />
            </.tile>
            <.tile
              id="vm-network"
              label="Network"
              value={"↓ #{rate(@latest.network.rx_rate)}"}
              detail={"↑ #{rate(@latest.network.tx_rate)} · #{bytes(@latest.network.rx_total)} in so far"}
            >
              <:help>
                What the VM receives (↓, the graph) and sends (↑) per second, every interface but loopback, and all it received since it started. All of it goes through MWT's proxy.
              </:help>
              <.sparkline
                id="vm-network-spark"
                label="Received per second"
                points={series(@history, :rx_rate)}
                max={peak(series(@history, :rx_rate))}
                format={&rate/1}
                until={@latest.at}
              />
            </.tile>
            <.tile
              id="vm-host"
              label="On your machine"
              value={host_value(@latest.host)}
              detail={host_detail(@latest.host)}
            >
              <:help>
                What the VM costs this machine: the memory its processes hold here, which is often far less than the VM's own figures suggest, and their CPU as a share of one of your cores.
              </:help>
              <.sparkline
                :if={@latest.host}
                id="vm-host-spark"
                label="Memory on your machine"
                points={series(@history, :host_rss)}
                max={peak(series(@history, :host_rss))}
                format={&bytes/1}
                until={@latest.at}
              />
            </.tile>
          </div>

          <div class="grid border-t border-line-soft lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
            <div id="vm-disks" class="space-y-3 px-4 py-3 lg:border-r lg:border-line-soft">
              <p class="flex items-center gap-1.5 text-[11px] font-medium text-muted">
                Disks
                <.help id="vm-disks-help" label="About the disks">
                  The VM's own disks, as full as the VM sees them: Work for projects and builds, Home for logins and history, Cache for tools and downloads. Each is an image file on your machine.
                  <span :if={host_disks(@latest.disks)} id="vm-disks-total" class="mt-1.5 block">
                    Together they take {bytes(host_disks(@latest.disks))} on your machine: the images are sparse, and grow only as they fill.
                  </span>
                </.help>
              </p>
              <.disk :for={disk <- @latest.disks} disk={disk} />
            </div>
            <div id="vm-processes" class="px-4 py-3">
              <div class="flex items-center gap-2">
                <p class="flex items-center gap-1.5 text-[11px] font-medium text-muted">
                  Busiest processes
                  <.help id="vm-processes-help" label="About the busiest processes">
                    The six processes in the VM using the most CPU or memory at the last sample. CPU is a share of one of the VM's CPUs, like top: a process busy on two of them shows 200%. Memory is what each holds (RSS).
                  </.help>
                </p>
                <div class="flex-1"></div>
                <div class="flex rounded-md border border-line p-0.5 text-[11px]">
                  <button
                    :for={{by, label} <- [cpu: "CPU", memory: "Memory"]}
                    id={"vm-processes-by-#{by}"}
                    type="button"
                    phx-click="monitor_by"
                    phx-value-by={by}
                    class={[
                      "cursor-pointer rounded px-2 py-0.5 transition-colors",
                      if(@by == by,
                        do: "bg-hover text-ink",
                        else: "text-faint hover:text-muted"
                      )
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>
              <table class="mt-2 w-full text-[12px]">
                <thead>
                  <tr class="text-left text-[10px] uppercase tracking-wide text-faint">
                    <th class="py-1 font-medium">Process</th>
                    <th class="w-16 py-1 text-right font-medium">CPU</th>
                    <th class="w-24 py-1 text-right font-medium">Memory</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-line-soft">
                  <tr
                    :for={process <- Enum.take(processes(@latest, @by), 6)}
                    id={"vm-process-#{process.pid}"}
                    class="transition-colors hover:bg-deep/30"
                  >
                    <td
                      class="max-w-0 truncate py-1 pr-3 font-mono text-ink"
                      title={"pid #{process.pid}"}
                    >
                      {process.name}
                    </td>
                    <td class={[
                      "py-1 text-right font-mono tabular-nums",
                      if(@by == :cpu, do: "text-ink", else: "text-muted")
                    ]}>
                      {percent(process.cpu)}
                    </td>
                    <td class={[
                      "py-1 pl-3 text-right font-mono tabular-nums",
                      if(@by == :memory, do: "text-ink", else: "text-muted")
                    ]}>
                      {bytes(process.rss)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
      <% end %>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, required: true
  attr :warning, :string, default: nil, doc: "a problem to flag beside the label"
  slot :help, required: true
  slot :inner_block

  defp tile(assigns) do
    ~H"""
    <div id={@id} class="group bg-panel px-4 py-3 transition-colors hover:bg-deep/20">
      <p class="flex items-center gap-1.5 text-[11px] font-medium text-muted">
        {@label}
        <.help id={"#{@id}-help"} label={"About #{@label}"}>{render_slot(@help)}</.help>
        <span
          :if={@warning}
          id={"#{@id}-warning"}
          title={@warning}
          class="inline-flex text-warn-strong"
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
        </span>
      </p>
      <p class="mt-0.5 text-xl font-semibold text-ink">{@value}</p>
      <p class="truncate text-[11px] text-faint" title={@detail}>{@detail}</p>
      <div class="mt-2">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :points, :list, required: true, doc: "`{at, value}`, oldest first"
  attr :max, :any, required: true
  attr :format, :any, required: true
  attr :until, DateTime, required: true, doc: "the right edge: the latest sample's time"

  # A sparkline of the last ten minutes: the line in a quiet ink, the
  # latest point in the accent, a gap where the VM wasn't running. Each
  # point's hover area is the band of time around it, so the pointer only
  # needs to be near it.
  defp sparkline(assigns) do
    marks = marks(assigns.points, assigns.max, assigns.until)
    assigns = assign(assigns, marks: marks, w: @width, h: @height)

    ~H"""
    <div class="relative h-7 w-full">
      <svg
        id={@id}
        viewBox={"0 0 #{@w} #{@h}"}
        preserveAspectRatio="none"
        class="absolute inset-0 size-full overflow-visible"
        role="img"
        aria-label={aria(@label, @points, @format)}
      >
        <line
          x1="0"
          x2={@w}
          y1={@h - 0.5}
          y2={@h - 0.5}
          class="stroke-line-soft"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />
        <path :for={d <- @marks.areas} d={d} class="fill-accent/10" />
        <path
          :for={d <- @marks.lines}
          d={d}
          fill="none"
          class="stroke-muted"
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
          vector-effect="non-scaling-stroke"
        />
        <rect
          :for={band <- @marks.bands}
          x={band.x}
          y="0"
          width={band.width}
          height={@h}
          fill="transparent"
          class="cursor-crosshair hover:fill-ink/5"
        >
          <title>{@format.(band.value)} · {ago(band.at, @until)}</title>
        </rect>
      </svg>
      <span
        :if={@marks.last}
        class="pointer-events-none absolute right-0 size-2 translate-x-1/2 -translate-y-1/2 rounded-full bg-accent ring-2 ring-panel"
        style={"top: #{@marks.last}%"}
      ></span>
    </div>
    """
  end

  attr :disk, :map, required: true

  defp disk(assigns) do
    share = if assigns.disk.size > 0, do: assigns.disk.used / assigns.disk.size, else: 0.0
    assigns = assign(assigns, share: share, level: level(share))

    ~H"""
    <div id={"vm-disk-#{@disk.name}"}>
      <div class="flex items-baseline gap-2 text-[12px]">
        <span class="text-ink">{disk_name(@disk.name)}</span>
        <span class="font-mono text-[10px] text-faint">{@disk.mount}</span>
        <span
          :if={@level != :ok}
          class={[
            "inline-flex items-center gap-0.5 self-center text-[10px] font-medium",
            if(@level == :full, do: "text-bad", else: "text-warn-strong")
          ]}
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3" />
          {if @level == :full, do: "full", else: "nearly full"}
        </span>
        <span class="ml-auto font-mono text-[11px] text-muted">
          {bytes(@disk.used)} <span class="text-faint">of {bytes(@disk.size)}</span>
        </span>
      </div>
      <div
        class={["mt-1 h-2 overflow-hidden rounded-full", track(@level)]}
        role="meter"
        aria-label={"#{disk_name(@disk.name)} disk used"}
        aria-valuemin="0"
        aria-valuemax={@disk.size}
        aria-valuenow={@disk.used}
      >
        <div
          class={["h-full rounded-full transition-[width] duration-700", fill(@level)]}
          style={"width: #{max(Float.round(@share * 100, 1), 0.5)}%"}
        >
        </div>
      </div>
      <p :if={@disk.host_used} class="mt-0.5 text-[10px] text-faint">
        takes {bytes(@disk.host_used)} on your machine
      </p>
    </div>
    """
  end

  ## Drawing

  @doc false
  # The sparkline's marks for `{at, value}` points: a line and an area per
  # run of points close enough in time, a hover band per point, and where
  # the latest point sits, as a percentage from the top.
  def marks(points, max, until) do
    max = if is_number(max) and max > 0, do: max, else: 1
    from = DateTime.add(until, -@window_ms, :millisecond)

    placed =
      for {at, value} <- points,
          is_number(value),
          DateTime.compare(at, from) != :lt,
          do: %{at: at, value: value, x: x(at, from), y: y(value, max)}

    runs = runs(placed)

    %{
      lines: Enum.map(runs, &line/1),
      areas: runs |> Enum.filter(&match?([_, _ | _], &1)) |> Enum.map(&area/1),
      bands: bands(placed),
      last:
        case List.last(placed) do
          %{at: ^until, y: y} -> Float.round(y / @height * 100, 1)
          _ -> nil
        end
    }
  end

  defp x(at, from),
    do: Float.round(DateTime.diff(at, from, :millisecond) / @window_ms * @width, 2)

  # 1 unit of headroom top and bottom, so the stroke isn't clipped.
  defp y(value, max), do: Float.round(@height - 1 - min(value / max, 1.0) * (@height - 2), 2)

  defp runs([]), do: []

  defp runs([first | rest]) do
    rest
    |> Enum.reduce([[first]], fn point, [[previous | _] = run | done] ->
      if DateTime.diff(point.at, previous.at, :millisecond) > @gap_ms,
        do: [[point], Enum.reverse(run) | done],
        else: [[point | run] | done]
    end)
    |> then(fn [run | done] -> Enum.reverse([Enum.reverse(run) | done]) end)
  end

  defp line([point]), do: "M#{point.x} #{point.y}h0.01"

  defp line([first | rest]),
    do: "M#{first.x} #{first.y}" <> Enum.map_join(rest, &"L#{&1.x} #{&1.y}")

  defp area([first | _] = run) do
    last = List.last(run)
    line(run) <> "L#{last.x} #{@height}L#{first.x} #{@height}Z"
  end

  # Each point owns the time from halfway to its neighbours.
  defp bands(placed) do
    xs = placed |> Enum.map(& &1.x) |> List.to_tuple()
    last = tuple_size(xs) - 1

    placed
    |> Enum.with_index()
    |> Enum.map(fn {point, i} ->
      left = if i == 0, do: 0.0, else: (elem(xs, i - 1) + point.x) / 2
      right = if i == last, do: @width * 1.0, else: (point.x + elem(xs, i + 1)) / 2

      %{
        at: point.at,
        value: point.value,
        x: Float.round(left, 2),
        width: Float.round(max(right - left, 0.5), 2)
      }
    end)
  end

  defp aria(label, points, format) do
    values = for {_at, v} <- points, is_number(v), do: v

    case values do
      [] ->
        "#{label}: no samples yet"

      _ ->
        "#{label} over the last 10 minutes: now #{format.(List.last(values))}, " <>
          "lowest #{format.(Enum.min(values))}, highest #{format.(Enum.max(values))}"
    end
  end

  defp ago(at, until) do
    case DateTime.diff(until, at, :second) do
      0 -> "now"
      s when s < 60 -> "#{s} s ago"
      s -> "#{div(s, 60)} min #{rem(s, 60)} s ago"
    end
  end

  ## Figures

  @doc false
  def series(history, key), do: for(point <- history, do: {point.at, Map.get(point, key)})

  defp peak(points) do
    case for({_at, v} <- points, is_number(v), do: v) do
      [] -> 1
      values -> max(Enum.max(values) * 1.15, 1)
    end
  end

  defp processes(latest, :memory), do: latest.processes_by_memory
  defp processes(latest, _cpu), do: latest.processes

  defp percent(nil), do: "–"
  defp percent(n), do: "#{round_to(n)}%"

  defp rate(nil), do: "–"
  defp rate(n), do: bytes(round(n)) <> "/s"

  defp load({one, five, fifteen}), do: Enum.map_join([one, five, fifteen], " ", &round_to/1)
  defp load(_other), do: "–"

  defp round_to(n) when is_float(n) and n >= 10, do: round(n)
  defp round_to(n) when is_float(n), do: Float.round(n, 1)
  defp round_to(n), do: n

  defp memory_warning(latest) do
    case Map.get(latest, :memory_control) do
      %{error: error} when is_binary(error) -> error
      _ -> nil
    end
  end

  defp host_value(nil), do: "–"
  defp host_value(%{rss: rss}), do: bytes(rss)

  defp host_detail(nil), do: "MWT can't see the VM's processes here"

  defp host_detail(%{cpu: cpu}),
    do: "held here · CPU #{percent(cpu)} of a core"

  defp host_disks(disks) do
    case for(%{host_used: n} when is_integer(n) <- disks, do: n) do
      [] -> nil
      sizes -> Enum.sum(sizes)
    end
  end

  defp disk_name(:work), do: "Work"
  defp disk_name(:home), do: "Home"
  defp disk_name(:cache), do: "Cache"
  defp disk_name(other), do: to_string(other)

  # Nearly full at 85%, full at 95%: the fill turns to the warning colour,
  # and a word and an icon say so too.
  defp level(share) when share >= 0.95, do: :full
  defp level(share) when share >= 0.85, do: :nearly
  defp level(_share), do: :ok

  defp track(:full), do: "bg-bad-soft"
  defp track(:nearly), do: "bg-warn-soft"
  defp track(:ok), do: "bg-accent-soft"

  defp fill(:full), do: "bg-bad"
  defp fill(:nearly), do: "bg-warn"
  defp fill(:ok), do: "bg-accent"
end
