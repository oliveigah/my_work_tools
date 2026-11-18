defmodule MWTClientWeb.SandboxLive.Activity do
  @moduledoc """
  The proxy activity page: everything the VM did through MWT, as MWT saw
  it, laid out to read a lot of it at once.

    * One row of filters: the groups, each with how many events it holds,
      words to look for, a grant, the thread that asked, and how far back.
    * A timeline of the events that pass them, stacked by series, from the
      start of that window to now, and the busiest destinations beside it;
      a destination narrows the log to itself.
    * The log, one dense line per event, newest first, that opens on a
      click to everything MWT recorded about it: for a request MWT read,
      what it carried and what came back to the VM, side by side
      (`MWTClient.Sandbox.Exchange`), read when it opens; and a button
      that copies it all as JSON.

  Every event is read from the identity's journal
  (`MWTClient.Sandbox.Activity`); the figures are worked out over the
  window (`MWTClient.Sandbox.EventStats`), and the log shows one page at a
  time. The newest page
  takes new activity in at the top while it matches the filters, and says
  it is live; an older page stays as it is and counts what came in since,
  with a way back to the newest.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{EventStats, Exchange}

  # The most of a body shown on the page; Copy as JSON takes all that was
  # kept.
  @shown_chars 4_000

  @groups [
    {"all", "All"},
    {"traffic", "Passed"},
    {"credentials", "Credentials"},
    {"blocked", "Blocked"},
    {"lookups", "Lookups"},
    {"changes", "Changes"},
    {"commands", "Host commands"},
    {"firewall", "Firewall"}
  ]

  @windows [
    {"hour", "Last hour"},
    {"day", "Last 24 hours"},
    {"week", "Last 7 days"},
    {"all", "Everything kept"}
  ]

  # The series' names and colours, as Tailwind classes, the log's badges'
  # own: plain traffic grey, a credential blue, blocked red, and violet for
  # what isn't traffic. In this stacking order, neighbours stay apart for
  # colour-blind eyes too, in both themes.
  @series [
    passed: {"Passed", "bg-muted/70"},
    credentials: {"Credentials", "bg-accent"},
    blocked: {"Blocked", "bg-bad"},
    other: {"Other", "bg-violet"}
  ]

  attr :streams, :any, required: true
  attr :filters, :map, required: true
  attr :activity, :map, required: true, doc: "where the page is: cursors, older?, shown, fresh"
  attr :stats, :map, required: true, doc: "`MWTClient.Sandbox.EventStats.t()`, nil until read"
  attr :page_size, :integer, required: true
  attr :grants, :list, required: true
  attr :threads, :list, default: [], doc: "the threads that asked in the window: id, title, agent"
  attr :grant_names, :map, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    page = length(assigns.activity.cursors) + 1
    first = (page - 1) * assigns.page_size + 1

    assigns =
      assign(assigns,
        groups: @groups,
        windows: @windows,
        page: page,
        live?: assigns.activity.cursors == [],
        range: "#{first}–#{first + max(assigns.activity.shown, 1) - 1}"
      )

    ~H"""
    <.page_header id="activity-header" title="Proxy activity">
      <:help>
        Every connection, request, lookup and decision the VM's traffic met in MWT, and the changes around it: grants, the VM, host commands, projects, handoffs, tool calls. A request MWT read (to a host a grant covers) opens to what the VM sent and what reached it: placeholders as the VM wrote them, never a real value, and at most 64 KB of each body. Connections passed through as bytes have no content to show. Events are kept in your encrypted journal for as long as Settings › Storage says, and what an agent asked for carries the thread it named.
      </:help>
      <:actions>
        <span
          :if={@live?}
          id="activity-live"
          class="inline-flex items-center gap-1.5 rounded-full border border-ok/30 bg-ok-soft/30 px-2.5 py-1 text-[11px] font-medium text-ok-strong"
        >
          <span class="relative flex size-1.5">
            <span class="absolute inline-flex size-full rounded-full bg-ok opacity-70 motion-safe:animate-ping"></span>
            <span class="relative inline-flex size-1.5 rounded-full bg-ok"></span>
          </span>
          Live
        </span>
        <button
          :if={not @live?}
          type="button"
          id="activity-paused"
          phx-click="latest_activity"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-line bg-deep px-2.5 py-1 text-[11px] font-medium text-muted transition-colors hover:border-accent/50 hover:text-ink"
        >
          <.icon name="hero-pause-micro" class="size-3" /> Paused on page {@page} · back to live
        </button>
      </:actions>
    </.page_header>

    <form
      id="activity-filters"
      phx-change="filter_activity"
      phx-submit="filter_activity"
      class="mb-4 flex flex-wrap items-center gap-2"
      autocomplete="off"
    >
      <div
        id="activity-groups"
        role="radiogroup"
        aria-label="What happened"
        class="inline-flex flex-wrap items-center gap-0.5 rounded-lg border border-line bg-deep p-0.5"
      >
        <label
          :for={{value, label} <- @groups}
          id={"activity-group-#{value}"}
          class={[
            "flex cursor-pointer items-center gap-1.5 rounded-md px-2 py-1 text-[11px] font-medium transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
            if(@filters.group == value,
              do: "bg-active text-ink shadow-sm",
              else: "text-muted hover:bg-hover hover:text-ink"
            )
          ]}
        >
          <input
            type="radio"
            name="group"
            value={value}
            checked={@filters.group == value}
            class="sr-only"
          />
          {label}
          <span
            :if={@stats}
            id={"activity-group-#{value}-count"}
            class={[
              "rounded px-1 text-[10px] tabular-nums",
              cond do
                value == "blocked" and count(@stats, value) > 0 -> "bg-bad-soft/60 text-bad"
                @filters.group == value -> "bg-deep text-muted"
                true -> "text-faint"
              end
            ]}
          >
            {count_text(count(@stats, value))}
          </span>
        </label>
      </div>
      <div class="relative min-w-56 flex-1">
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
        />
        <input
          type="text"
          name="q"
          id="activity-search"
          value={@filters.q}
          placeholder="Host, path or words"
          phx-debounce="150"
          class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-7 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
        />
        <button
          :if={@filters.q != ""}
          type="button"
          id="activity-search-clear"
          phx-click="filter_host"
          phx-value-host=""
          title="Clear the search"
          class="absolute right-1.5 top-1/2 flex size-5 -translate-y-1/2 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </div>
      <select
        name="grant"
        id="activity-grant"
        class="rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
      >
        <option value="" selected={@filters.grant == ""}>Any grant</option>
        <option :for={grant <- @grants} value={grant.id} selected={@filters.grant == grant.id}>
          {grant.name}
        </option>
      </select>
      <select
        name="thread"
        id="activity-thread"
        class="max-w-56 rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
      >
        <option value="" selected={@filters.thread == ""}>Any thread</option>
        <option
          :if={@filters.thread != "" and not Enum.any?(@threads, &(&1.id == @filters.thread))}
          value={@filters.thread}
          selected
        >
          {thread_label(%{id: @filters.thread, title: nil, agent: nil})}
        </option>
        <option :for={thread <- @threads} value={thread.id} selected={@filters.thread == thread.id}>
          {thread_label(thread)}
        </option>
      </select>
      <select
        name="window"
        id="activity-window"
        class="rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
      >
        <option
          :for={{value, label} <- @windows}
          value={value}
          selected={@filters.window == value}
        >
          {label}
        </option>
      </select>
    </form>

    <div
      :if={@stats}
      class="mb-4 grid items-stretch gap-4 lg:grid-cols-[minmax(0,1.9fr)_minmax(0,1fr)]"
    >
      <.timeline stats={@stats} />
      <.hosts stats={@stats} filters={@filters} />
    </div>

    <button
      :if={@activity.fresh > 0}
      type="button"
      id="activity-fresh"
      phx-click="latest_activity"
      class="mb-3 flex w-full cursor-pointer items-center justify-center gap-1.5 rounded-lg border border-accent/30 bg-accent-soft/40 px-3 py-1.5 text-[11px] font-medium text-accent-strong transition-colors hover:bg-accent-soft/70"
    >
      <.icon name="hero-arrow-up-micro" class="size-3.5" />
      {@activity.fresh} newer {if @activity.fresh == 1, do: "event", else: "events"} · Back to the latest
    </button>

    <div
      id="activity-table"
      phx-hook=".Paged"
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <div class={[
        row_grid(),
        "border-b border-line-soft bg-deep/40 py-2 text-[10px] font-semibold uppercase tracking-wide text-faint"
      ]}>
        <span>Time</span>
        <span>Result</span>
        <span>Request</span>
        <span class="hidden text-right md:block">Grant</span>
        <span class="hidden text-right sm:block">Sent / received</span>
        <span class="hidden text-right sm:block">Took</span>
      </div>
      <%!-- The empty states sit outside the stream: a child in it would count against its limit. --%>
      <div :if={@activity.shown == 0} id="activity-empty">
        <%= if @activity.cursors == [] do %>
          <.empty icon="hero-queue-list">Nothing matches these filters.</.empty>
        <% else %>
          <.empty icon="hero-clock" id="activity-aged-out">
            These have aged out of the journal.
          </.empty>
        <% end %>
      </div>
      <ul id="activity-log" phx-update="stream" class="divide-y divide-line-soft/70">
        <li
          :for={{dom_id, event} <- @streams.events}
          id={dom_id}
          class={[
            "border-l-2",
            stripe(event.outcome)
          ]}
        >
          <details
            id={"#{dom_id}-open"}
            class="group/event"
            phx-hook=".OpenEvent"
            phx-mounted={JS.ignore_attributes(["open"])}
            data-event={event.id}
            data-read={if(event.exchange_id && is_nil(event.exchange), do: "no", else: "yes")}
          >
            <summary class={[
              row_grid(),
              "cursor-pointer list-none py-1 leading-4 transition-colors hover:bg-hover/40 group-open/event:bg-hover/30 [&::-webkit-details-marker]:hidden"
            ]}>
              <span
                class="font-mono text-[10px] tabular-nums text-faint"
                title={DateTime.to_iso8601(event.at)}
              >
                {Calendar.strftime(event.at, "%H:%M:%S")}
              </span>
              <span class="flex"><.outcome_badge outcome={event.outcome} /></span>
              <span class="flex min-w-0 items-baseline gap-2">
                <%= if event.host do %>
                  <span
                    class="min-w-0 shrink truncate font-mono text-[11px] text-ink"
                    title={target(event)}
                  >
                    <span :if={event.method} class="font-semibold text-muted">{event.method}</span>
                    {event.host}<span :if={event.port && event.port != 443} class="text-faint">:{event.port}</span><span
                      :if={event.path}
                      class="text-muted"
                    >{event.path}</span>
                  </span>
                  <span
                    :if={event.outcome != :tunnel}
                    class="min-w-0 flex-1 truncate text-[11px] text-faint"
                  >
                    {event.summary}
                  </span>
                <% else %>
                  <span class="min-w-0 truncate text-xs text-ink">{event.summary}</span>
                <% end %>
              </span>
              <span class="hidden truncate text-right text-[11px] text-muted md:block">
                {(event.grant_id && @grant_names[event.grant_id]) || ""}
              </span>
              <span class="hidden whitespace-nowrap text-right font-mono text-[10px] tabular-nums text-faint sm:block">
                <%= if event.up || event.down do %>
                  {bytes(event.up)} / {bytes(event.down)}
                <% end %>
              </span>
              <span class="hidden whitespace-nowrap text-right font-mono text-[10px] tabular-nums text-faint sm:block">
                {took(event.ms)}
              </span>
            </summary>
            <.details event={event} grant_names={@grant_names} now={@now} />
          </details>
        </li>
      </ul>
      <nav
        :if={@activity.cursors != [] or @activity.older?}
        id="activity-pager"
        aria-label="Activity pages"
        class="flex items-center gap-2 border-t border-line-soft bg-deep/30 px-4 py-2"
      >
        <span id="activity-range" class="text-[11px] text-muted">
          <%= if @activity.cursors == [] do %>
            Newest {@activity.shown}
          <% else %>
            Page {@page} · {@range}
          <% end %>
        </span>
        <div class="flex-1"></div>
        <button
          :if={length(@activity.cursors) > 1}
          type="button"
          id="activity-latest"
          phx-click="latest_activity"
          class="cursor-pointer rounded-md px-2 py-1 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
        >
          Latest
        </button>
        <.button
          type="button"
          id="activity-newer"
          phx-click="newer_activity"
          disabled={@activity.cursors == []}
        >
          <.icon name="hero-chevron-left-micro" class="size-3.5" /> Newer
        </.button>
        <.button
          type="button"
          id="activity-older"
          phx-click="older_activity"
          disabled={not @activity.older?}
        >
          Older <.icon name="hero-chevron-right-micro" class="size-3.5" />
        </.button>
      </nav>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenEvent">
      // An event that carried content reads it the first time it opens.
      export default {
        mounted() {
          this.onToggle = () => {
            if (this.el.open && this.el.dataset.read === "no") {
              this.el.dataset.read = "asked"
              this.pushEvent("open_event", {id: this.el.dataset.event})
            }
          }
          this.el.addEventListener("toggle", this.onToggle)
        },
        destroyed() {
          this.el.removeEventListener("toggle", this.onToggle)
        },
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Paged">
      export default {
        mounted() {
          // A new page starts at its newest row, not where the last one ended.
          this.handleEvent("activity_paged", () => {
            const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            document.getElementById("sandbox-page")?.scrollTo({top: 0, behavior: still ? "auto" : "smooth"})
          })
        },
      }
    </script>
    """
  end

  defp row_grid,
    do:
      "grid grid-cols-[4rem_6rem_minmax(0,1fr)] items-center gap-3 px-4 sm:grid-cols-[4rem_6rem_minmax(0,1fr)_7.5rem_4rem] md:grid-cols-[4rem_6rem_minmax(0,1fr)_8rem_7.5rem_4rem]"

  ## Timeline

  attr :stats, :map, required: true

  # Stacked bars, one per step of time, with a tooltip each. The peak is
  # the only number on the scale; a faint line marks its half.
  defp timeline(assigns) do
    timeline = assigns.stats.timeline
    peak = max(timeline.peak, 1)

    totals =
      Map.new(EventStats.series(), fn series ->
        {series, timeline.buckets |> Enum.map(& &1.counts[series]) |> Enum.sum()}
      end)

    assigns =
      assign(assigns,
        timeline: timeline,
        peak: peak,
        series: @series,
        totals: totals,
        ticks: ticks(timeline)
      )

    ~H"""
    <section
      id="activity-timeline"
      class="flex min-w-0 flex-col overflow-hidden rounded-xl border border-line bg-panel"
    >
      <header class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-line-soft px-4 py-2.5">
        <div class="min-w-0 flex-1">
          <h2 class="flex items-center gap-1.5 text-[13px] font-semibold text-ink">
            <span id="activity-total" class="tabular-nums">{count_text(@stats.total)}</span>
            {if @stats.total == 1, do: "event", else: "events"}
            <.help id="activity-timeline-help" label="About the timeline">
              The events that pass the filters, per {step_text(@timeline.step)}, from the oldest event MWT keeps to now. Hover a bar for its counts. ↑ is what the VM sent and ↓ what it received, added up as its connections closed.
            </.help>
          </h2>
          <p id="activity-bytes" class="mt-0.5 whitespace-nowrap text-[11px] text-faint">
            Since {Calendar.strftime(@timeline.from, "%H:%M")} UTC · ↑ {bytes(@stats.up)} · ↓ {bytes(
              @stats.down
            )}
          </p>
        </div>
        <ul id="activity-legend" class="flex flex-wrap items-center gap-x-3 gap-y-1">
          <li
            :for={{series, {label, color}} <- @series}
            id={"activity-legend-#{series}"}
            class="flex items-center gap-1.5 text-[11px] text-muted"
          >
            <span class={["size-2 rounded-sm", color]}></span>
            {label}
            <span class="tabular-nums text-faint">{count_text(@totals[series])}</span>
          </li>
        </ul>
      </header>
      <div class="flex flex-1 flex-col px-4 pb-2 pt-3">
        <div class="relative flex min-h-28 flex-1 gap-3">
          <div class="flex w-6 flex-col justify-between text-right font-mono text-[9px] tabular-nums text-faint">
            <span>{@peak}</span>
            <span>0</span>
          </div>
          <div class="relative flex-1">
            <div class="pointer-events-none absolute inset-x-0 top-0 border-t border-dashed border-line-soft">
            </div>
            <div class="pointer-events-none absolute inset-x-0 top-1/2 border-t border-dashed border-line-soft/60">
            </div>
            <div class="pointer-events-none absolute inset-x-0 bottom-0 border-t border-line"></div>
            <div
              id="activity-bars"
              class="absolute inset-0 flex items-end gap-[2px]"
              role="img"
              aria-label={"#{@stats.total} events over time, at most #{@timeline.peak} in one #{step_text(@timeline.step)}"}
            >
              <div
                :for={bucket <- @timeline.buckets}
                class="group/bar relative flex h-full min-w-0 flex-1 flex-col justify-end"
              >
                <div class="absolute inset-0 rounded-sm transition-colors group-hover/bar:bg-hover/50">
                </div>
                <div
                  class="relative flex flex-col-reverse gap-px overflow-hidden rounded-t-[3px]"
                  style={"height: #{Float.round(bucket.total / @peak * 100, 2)}%"}
                >
                  <div
                    :for={{series, {_label, color}} <- @series}
                    :if={bucket.counts[series] > 0}
                    class={["min-h-px w-full", color]}
                    style={"flex: #{bucket.counts[series]} 1 0"}
                  >
                  </div>
                </div>
                <div class="pointer-events-none absolute bottom-full left-1/2 z-20 mb-1 hidden w-max -translate-x-1/2 rounded-lg border border-line bg-panel px-2.5 py-1.5 text-[10px] leading-4 text-ink shadow-xl shadow-black/20 group-hover/bar:block">
                  <p class="font-medium">
                    {Calendar.strftime(bucket.at, "%H:%M:%S")}–{Calendar.strftime(
                      DateTime.add(bucket.at, @timeline.step, :second),
                      "%H:%M:%S"
                    )}
                  </p>
                  <p :if={bucket.total == 0} class="text-faint">No events</p>
                  <p
                    :for={{series, {label, color}} <- @series}
                    :if={bucket.counts[series] > 0}
                    class="flex items-center gap-1.5 text-muted"
                  >
                    <span class={["size-1.5 rounded-sm", color]}></span>
                    {label}
                    <span class="ml-auto pl-3 tabular-nums text-ink">{bucket.counts[series]}</span>
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="ml-9 mt-1 flex justify-between font-mono text-[9px] tabular-nums text-faint">
          <span :for={tick <- @ticks}>{tick}</span>
        </div>
      </div>
    </section>
    """
  end

  # Five times under the bars: the first, three between, and now.
  defp ticks(%{from: from, to: to}) do
    span = DateTime.diff(to, from, :second)
    format = if span > 86_400, do: "%b %-d %H:%M", else: "%H:%M"

    for n <- 0..4 do
      if n == 4,
        do: "now",
        else: from |> DateTime.add(div(span * n, 4), :second) |> Calendar.strftime(format)
    end
  end

  defp step_text(seconds) when seconds < 60, do: "#{seconds} seconds"
  defp step_text(60), do: "minute"
  defp step_text(seconds) when seconds < 3600, do: "#{div(seconds, 60)} minutes"
  defp step_text(3600), do: "hour"
  defp step_text(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)} hours"
  defp step_text(_seconds), do: "day"

  ## Busiest destinations

  attr :stats, :map, required: true
  attr :filters, :map, required: true

  defp hosts(assigns) do
    assigns =
      assign(assigns, :top, Enum.max(Enum.map(assigns.stats.hosts, & &1.count), fn -> 1 end))

    ~H"""
    <section
      id="activity-hosts"
      class="flex min-w-0 flex-col overflow-hidden rounded-xl border border-line bg-panel"
    >
      <header class="flex items-center gap-1.5 border-b border-line-soft px-4 py-2.5">
        <h2 class="text-[13px] font-semibold text-ink">Busiest destinations</h2>
        <.help id="activity-hosts-help" label="About the busiest destinations">
          The hosts the filtered events went to most, with how many carried a credential and how many were blocked. Click one to show only its events; click it again to show everything.
        </.help>
      </header>
      <p
        :if={@stats.hosts == []}
        id="activity-hosts-empty"
        class="px-4 py-6 text-center text-[11px] text-faint"
      >
        No destinations in these events.
      </p>
      <ul :if={@stats.hosts != []} class="flex-1 space-y-0.5 p-1.5">
        <li :for={{host, index} <- Enum.with_index(@stats.hosts)}>
          <button
            type="button"
            id={"activity-host-#{index}"}
            phx-click="filter_host"
            phx-value-host={if(@filters.q == host.host, do: "", else: host.host)}
            title={
              if(@filters.q == host.host,
                do: "Show every destination again",
                else: "Show only #{host.host}"
              )
            }
            class={[
              "group/host relative w-full cursor-pointer overflow-hidden rounded-md px-2.5 py-1.5 text-left transition-colors",
              if(@filters.q == host.host,
                do: "bg-accent-soft/40 ring-1 ring-accent/40",
                else: "hover:bg-hover/50"
              )
            ]}
          >
            <span
              class="absolute inset-y-1 left-0 rounded-r bg-accent/10 transition-[width] duration-300"
              style={"width: #{Float.round(host.count / @top * 100, 2)}%"}
            ></span>
            <span class="relative flex items-center gap-2">
              <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink">{host.host}</span>
              <span
                :if={host.blocked > 0}
                class="rounded bg-bad-soft/60 px-1 text-[9px] font-semibold tabular-nums text-bad"
                title={"#{host.blocked} blocked"}
              >
                {host.blocked} blocked
              </span>
              <span
                :if={host.credentials > 0}
                class="rounded bg-accent-soft/60 px-1 text-[9px] font-semibold tabular-nums text-accent-strong"
                title={"#{host.credentials} with a credential"}
              >
                {host.credentials} cred
              </span>
              <span class="w-10 text-right text-[11px] font-medium tabular-nums text-muted">
                {count_text(host.count)}
              </span>
            </span>
          </button>
        </li>
      </ul>
    </section>
    """
  end

  ## One event, opened

  attr :event, :any, required: true
  attr :grant_names, :map, required: true
  attr :now, DateTime, required: true

  defp details(assigns) do
    ~H"""
    <div class="border-t border-line-soft/70 bg-deep/40 px-4 py-3">
      <div class="flex items-start gap-4">
        <dl class="grid min-w-0 flex-1 grid-cols-[7rem_minmax(0,1fr)] gap-x-4 gap-y-1 pl-[4.75rem] text-[11px]">
          <dt class="text-faint">What happened</dt>
          <dd class="text-ink">{@event.summary}</dd>
          <dt class="text-faint">When</dt>
          <dd class="font-mono text-[10px] text-muted">
            {Calendar.strftime(@event.at, "%Y-%m-%d %H:%M:%S")} UTC · {ago(@event.at, @now)}
          </dd>
          <%= if @event.host do %>
            <dt class="text-faint">Destination</dt>
            <dd class="font-mono text-[10px] text-ink">
              {@event.host}<span :if={@event.port}>:{@event.port}</span>
            </dd>
          <% end %>
          <%= if @event.method || @event.path do %>
            <dt class="text-faint">Request</dt>
            <dd class="break-all font-mono text-[10px] text-ink">
              {@event.method} {@event.path}
            </dd>
          <% end %>
          <%= if @event.grant_id do %>
            <dt class="text-faint">Grant</dt>
            <dd class="text-ink">
              <.link
                patch={~p"/tools/sandbox/grants/#{@event.grant_id}"}
                class="text-accent hover:underline"
              >
                {@grant_names[@event.grant_id] || @event.grant_id}
              </.link>
            </dd>
          <% end %>
          <%= if @event.up || @event.down do %>
            <dt class="text-faint">Sent / received</dt>
            <dd class="font-mono text-[10px] text-muted">
              {exact(@event.up)} / {exact(@event.down)} bytes
            </dd>
          <% end %>
          <%= if @event.ms do %>
            <dt class="text-faint">Open for</dt>
            <dd class="font-mono text-[10px] text-muted">{took(@event.ms)}</dd>
          <% end %>
        </dl>
        <div class="flex shrink-0 items-center gap-1.5">
          <button
            :if={@event.host}
            type="button"
            phx-click="filter_host"
            phx-value-host={@event.host}
            class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] text-muted transition-colors hover:border-accent/50 hover:text-ink"
          >
            <.icon name="hero-funnel-micro" class="size-3" /> Only {@event.host}
          </button>
          <button
            type="button"
            id={"event-copy-#{@event.id}"}
            phx-hook="CopyText"
            phx-update="ignore"
            data-copy-target={"event-json-#{@event.id}"}
            title="Copy this event as JSON, with what its request carried and got back"
            class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] font-medium text-muted transition-all hover:border-accent/50 hover:text-accent active:scale-[0.97]"
          >
            <.icon name="hero-clipboard-document-micro" class="size-3.5" />
            <span data-copy-label>Copy as JSON</span>
          </button>
        </div>
      </div>
      <pre id={"event-json-#{@event.id}"} hidden phx-no-curly-interpolation><%= event_json(@event) %></pre>

      <%= cond do %>
        <% is_map(@event.exchange) -> %>
          <div id={"event-exchange-#{@event.id}"} class="mt-3 grid gap-3 xl:grid-cols-2">
            <.request_panel event={@event} request={@event.exchange.request} />
            <.response_panel event={@event} response={@event.exchange.response} />
          </div>
        <% @event.exchange == :none -> %>
          <p
            id={"event-exchange-#{@event.id}"}
            class="mt-3 flex items-center gap-1.5 text-[11px] text-faint"
          >
            <.icon name="hero-information-circle-micro" class="size-3.5" />
            Nothing of what it carried was kept: its connection hadn't ended yet, or it ended before anything came back.
          </p>
        <% @event.exchange_id -> %>
          <p
            id={"event-exchange-#{@event.id}"}
            class="mt-3 flex items-center gap-1.5 text-[11px] text-faint"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5 animate-spin" />
            Reading what it carried…
          </p>
        <% @event.outcome == :tunnel and is_nil(@event.method) -> %>
          <p
            id={"event-exchange-#{@event.id}"}
            class="mt-3 flex items-center gap-1.5 text-[11px] text-faint"
          >
            <.icon name="hero-lock-closed-micro" class="size-3.5" />
            Passed through as bytes: MWT reads only requests to hosts a grant covers, so there is no content to show.
          </p>
        <% true -> %>
      <% end %>
    </div>
    """
  end

  attr :event, :any, required: true
  attr :request, :map, required: true

  defp request_panel(assigns) do
    ~H"""
    <section
      id={"event-request-#{@event.id}"}
      class="flex min-w-0 flex-col overflow-hidden rounded-lg border border-line bg-panel"
    >
      <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-3 py-1.5">
        <span class="text-[10px] font-semibold uppercase tracking-wide text-faint">Request</span>
        <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={@request.path}>
          <span class="font-semibold text-muted">{@request.method}</span> {@request.path}
        </span>
        <span class="shrink-0 text-[10px] text-faint">as the VM sent it</span>
      </header>
      <.headers id={"event-request-headers-#{@event.id}"} headers={@request.headers} />
      <.body_view
        id={"event-request-body-#{@event.id}"}
        body={@request.body}
        headers={@request.headers}
      />
    </section>
    """
  end

  attr :event, :any, required: true
  attr :response, :map, default: nil

  defp response_panel(assigns) do
    ~H"""
    <section
      id={"event-response-#{@event.id}"}
      class="flex min-w-0 flex-col overflow-hidden rounded-lg border border-line bg-panel"
    >
      <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-3 py-1.5">
        <span class="text-[10px] font-semibold uppercase tracking-wide text-faint">Response</span>
        <span
          :if={@response && @response.status}
          id={"event-response-status-#{@event.id}"}
          class={[
            "rounded px-1.5 py-px font-mono text-[11px] font-semibold tabular-nums",
            status_tone(@response.status)
          ]}
        >
          {@response.status} {@response.reason}
        </span>
        <span class="flex-1"></span>
        <span :if={@response} class="shrink-0 text-[10px] text-faint">
          {if @response.by_mwt?, do: "from MWT", else: "as it reached the VM"}
        </span>
      </header>
      <%= if @response do %>
        <p
          :if={@response.note}
          id={"event-response-note-#{@event.id}"}
          class={[
            "flex items-start gap-1.5 border-b border-line-soft px-3 py-1.5 text-[11px]",
            if(@response.by_mwt?, do: "text-muted", else: "text-warn-strong")
          ]}
        >
          <.icon name="hero-information-circle-micro" class="mt-px size-3.5 shrink-0" />
          {@response.note}
        </p>
        <.headers id={"event-response-headers-#{@event.id}"} headers={@response.headers} />
        <.body_view
          id={"event-response-body-#{@event.id}"}
          body={@response.body}
          headers={@response.headers}
        />
      <% else %>
        <p class="px-3 py-3 text-[11px] text-faint">
          Nothing came back: the connection ended before an answer.
        </p>
      <% end %>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :headers, :list, required: true

  defp headers(assigns) do
    ~H"""
    <div id={@id} class="max-h-48 overflow-auto border-b border-line-soft px-3 py-1.5">
      <p :if={@headers == []} class="text-[11px] text-faint">No headers</p>
      <dl class="grid grid-cols-[minmax(0,auto)_minmax(0,1fr)] gap-x-3 font-mono text-[10px] leading-4">
        <%= for {name, value} <- @headers do %>
          <dt class="truncate text-muted" title={name}>{name}</dt>
          <dd class="break-all text-ink">{value}</dd>
        <% end %>
      </dl>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :body, :map, required: true
  attr :headers, :list, required: true

  defp body_view(assigns) do
    text = Exchange.readable(assigns.body, assigns.headers)

    shown =
      if is_binary(text) and String.length(text) > @shown_chars,
        do: String.slice(text, 0, @shown_chars),
        else: text

    assigns =
      assign(assigns,
        text: text,
        shown: shown,
        shortened?: is_binary(text) and shown != text
      )

    ~H"""
    <div id={@id} class="flex min-h-0 flex-1 flex-col">
      <%= cond do %>
        <% is_binary(@shown) -> %>
          <pre
            class="max-h-80 flex-1 overflow-auto whitespace-pre-wrap break-words px-3 py-2 font-mono text-[11px] leading-4 text-ink"
            phx-no-curly-interpolation
          ><%= @shown %></pre>
        <% @text == :binary -> %>
          <p class="px-3 py-2 text-[11px] text-faint">
            Binary, {bytes(byte_size(@body.data))}: Copy as JSON gives it in base64.
          </p>
        <% @body.note -> %>
          <p class="px-3 py-2 text-[11px] text-faint">{@body.note}</p>
        <% true -> %>
          <p class="px-3 py-2 text-[11px] text-faint">No body</p>
      <% end %>
      <p
        :if={@shortened? or @body.cut?}
        id={"#{@id}-cut"}
        class="flex items-center gap-1.5 border-t border-line-soft bg-deep/30 px-3 py-1 text-[10px] text-faint"
      >
        <.icon name="hero-scissors-micro" class="size-3" />
        {cut_words(@shortened?, @body)}
      </p>
    </div>
    """
  end

  # What a cut body says: shown in part here, kept in part by MWT.
  defp cut_words(shortened?, body) do
    of = if body.bytes, do: " of #{bytes(body.bytes)}", else: ""

    cond do
      shortened? and body.cut? ->
        "Shortened here. MWT kept the first #{bytes(byte_size(body.data))}#{of}: Copy as JSON gives all of that."

      shortened? ->
        "Shortened here#{of}. Copy as JSON gives all of it."

      true ->
        "MWT kept the first #{bytes(byte_size(body.data || ""))}#{of}."
    end
  end

  defp status_tone(status) when status in 200..299, do: "bg-ok-soft/60 text-ok-strong"
  defp status_tone(status) when status in 300..399, do: "bg-accent-soft/60 text-accent-strong"
  defp status_tone(status) when status in 400..499, do: "bg-warn-soft/60 text-warn-strong"
  defp status_tone(_status), do: "bg-bad-soft/60 text-bad"

  # The event as JSON for the clipboard: what the log says of it, and what
  # its request carried and got back when that was read.
  defp event_json(event) do
    %{
      "id" => event.id,
      "at" => DateTime.to_iso8601(event.at),
      "outcome" => Atom.to_string(event.outcome),
      "summary" => event.summary,
      "host" => event.host,
      "port" => event.port,
      "method" => event.method,
      "path" => event.path,
      "grant" => event.grant_id,
      "sent_bytes" => event.up,
      "received_bytes" => event.down,
      "ms" => event.ms,
      "agent" => event.agent,
      "thread" => event.thread
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> then(fn json ->
      if is_map(event.exchange), do: Map.merge(json, Exchange.to_json(event.exchange)), else: json
    end)
    |> Jason.encode!(pretty: true)
  end

  ## Small things

  defp count(stats, group), do: Map.get(stats.groups, group, 0)

  defp count_text(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp count_text(n), do: Integer.to_string(n)

  defp target(event),
    do:
      [event.method, "#{event.host}#{if event.port, do: ":#{event.port}"}#{event.path}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

  # A line's left edge says how it went, for the eye running down the log.
  # Only the left edge's colour: the dividers between lines keep theirs.
  defp stripe(outcome) when outcome in [:blocked, :violation, :firewall], do: "border-l-bad"
  defp stripe(outcome) when outcome in [:denied, :refused, :timed_out], do: "border-l-warn"
  defp stripe(outcome) when outcome in [:swapped, :allowed], do: "border-l-accent/70"
  defp stripe(_outcome), do: "border-l-transparent"

  defp took(nil), do: ""
  defp took(ms) when ms < 1000, do: "#{ms} ms"
  defp took(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  defp took(ms), do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1000)}s"

  defp exact(nil), do: "0"

  defp exact(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  # A thread by its title, else the start of its id, with its agent.
  defp thread_label(thread) do
    name = thread.title || "thread " <> String.slice(thread.id, 0, 8)
    if thread.agent, do: "#{name} · #{thread.agent}", else: name
  end
end
