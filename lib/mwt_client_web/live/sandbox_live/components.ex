defmodule MWTClientWeb.SandboxLive.Components do
  @moduledoc """
  The pieces every page of the agent sandbox shares: live clocks, the grant
  tile and switch, outcome badges, cards, and the words for times and sizes.
  """
  use MWTClientWeb, :html

  alias MWTClient.Sandbox.{Event, Grant, VM}

  @doc """
  A time that keeps itself current in the browser, so countdowns tick without
  a render per second.

  Give `deadline` for a countdown ("4:12"), or `since` for an age ("3 min
  ago"), or `since` with `duration` for how long something has run ("2h 14m").
  The server renders the same words first, so the page reads right before the
  hook runs and in tests. The id carries the time, so a new time remounts it.
  """
  attr :id, :string, required: true
  attr :deadline, DateTime, default: nil
  attr :since, DateTime, default: nil
  attr :duration, :boolean, default: false
  attr :suffix, :string, default: ""
  attr :done, :string, default: "now"
  attr :now, DateTime, required: true
  attr :class, :any, default: nil

  def clock(assigns) do
    stamp = assigns.deadline || assigns.since

    assigns =
      assigns
      |> assign(:dom_id, "#{assigns.id}-#{DateTime.to_unix(stamp)}")
      |> assign(:text, clock_text(assigns))

    ~H"""
    <span
      id={@dom_id}
      phx-hook=".Clock"
      phx-update="ignore"
      data-deadline={@deadline && DateTime.to_iso8601(@deadline)}
      data-since={@since && DateTime.to_iso8601(@since)}
      data-mode={if(@duration, do: "duration", else: nil)}
      data-suffix={@suffix}
      data-done={@done}
      class={["tabular-nums", @class]}
    >{@text}</span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Clock">
      const pad = (n) => String(n).padStart(2, "0")
      const left = (ms) => {
        const s = Math.ceil(ms / 1000)
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        return h > 0 ? `${h}h ${pad(m)}m` : `${m}:${pad(s % 60)}`
      }
      const span = (ms) => {
        const m = Math.floor(ms / 60000)
        const h = Math.floor(m / 60)
        if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`
        return h > 0 ? `${h}h ${pad(m % 60)}m` : `${m} min`
      }
      const ago = (ms) => {
        const s = Math.floor(ms / 1000)
        if (s < 10) return "just now"
        if (s < 60) return `${s} s ago`
        const m = Math.floor(s / 60)
        if (m < 60) return `${m} min ago`
        const h = Math.floor(m / 60)
        if (h < 24) return `${h} h ago`
        return `${Math.floor(h / 24)} d ago`
      }
      export default {
        mounted() {
          this.render()
          this.timer = setInterval(() => this.render(), 1000)
        },
        destroyed() {
          clearInterval(this.timer)
        },
        render() {
          const data = this.el.dataset
          const now = Date.now()
          if (data.deadline) {
            const ms = Date.parse(data.deadline) - now
            this.el.textContent = ms <= 0 ? data.done : left(ms) + (data.suffix || "")
          } else if (data.since) {
            const ms = now - Date.parse(data.since)
            this.el.textContent = data.mode === "duration" ? span(ms) : ago(ms)
          }
        },
      }
    </script>
    """
  end

  defp clock_text(%{deadline: %DateTime{} = deadline, now: now} = assigns) do
    case DateTime.diff(deadline, now, :second) do
      seconds when seconds <= 0 -> assigns.done
      seconds -> left(seconds) <> assigns.suffix
    end
  end

  defp clock_text(%{since: %DateTime{} = since, duration: true, now: now}),
    do: span(DateTime.diff(now, since, :second))

  defp clock_text(%{since: %DateTime{} = since, now: now}), do: ago(since, now)

  @doc "Seconds left, as the countdowns show them: `4:07`, or `1h 12m` past an hour."
  @spec left(integer()) :: String.t()
  def left(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    if h > 0, do: "#{h}h #{pad(m)}m", else: "#{m}:#{pad(s)}"
  end

  @doc "How long something has run: `12 min`, `2h 14m`, `3d 4h`."
  @spec span(integer()) :: String.t()
  def span(seconds) do
    m = div(seconds, 60)
    h = div(m, 60)

    cond do
      h >= 24 -> "#{div(h, 24)}d #{rem(h, 24)}h"
      h > 0 -> "#{h}h #{pad(rem(m, 60))}m"
      true -> "#{m} min"
    end
  end

  @doc "How long ago `at` was: `just now`, `42 s ago`, `3 min ago`, `2 h ago`, `5 d ago`."
  @spec ago(DateTime.t(), DateTime.t()) :: String.t()
  def ago(at, now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 10 -> "just now"
      seconds < 60 -> "#{seconds} s ago"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "A byte count in the unit that reads best."
  @spec bytes(non_neg_integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(n) when n < 1024, do: "#{n} B"
  def bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / (1024 * 1024), 1)} MB"
  def bytes(n), do: "#{Float.round(n / (1024 * 1024 * 1024), 1)} GB"

  @doc "The square tile that stands for a grant: its preset's icon, or its type's."
  attr :icon, :string, required: true
  attr :on, :boolean, default: false
  attr :class, :any, default: "size-8"

  def grant_tile(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center rounded-lg border transition-colors",
      if(@on,
        do: "border-ok/35 bg-ok-soft/50 text-ok-strong",
        else: "border-line bg-deep text-muted"
      ),
      @class
    ]}>
      <.icon name={@icon} class="size-4" />
    </span>
    """
  end

  @doc "What the VM ends up holding for a grant, in two words and a colour."
  attr :grant, Grant, required: true

  def exposure(assigns) do
    ~H"""
    <span
      :if={@grant.kind == :token and not Grant.subgrants_only?(@grant)}
      class="inline-flex items-center gap-1 rounded border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-ok-strong"
      title="The VM only has a placeholder. MWT swaps in the real value on the way out."
    >
      <.icon name="hero-shield-check-micro" class="size-3" /> Placeholder only
    </span>
    <span
      :if={Grant.subgrants_only?(@grant)}
      class="inline-flex items-center gap-1 rounded border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-ok-strong"
      title="The VM holds nothing of it: only the requests saved under it, which MWT sends itself, use its value."
    >
      <.icon name="hero-lock-closed-micro" class="size-3" /> Subgrants only
    </span>
    <span
      :if={@grant.kind == :network}
      class="inline-flex items-center gap-1 rounded border border-accent/30 bg-accent-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-accent-strong"
      title="Nothing to hold. MWT lets connections to these destinations through."
    >
      <.icon name="hero-signal-micro" class="size-3" /> Network
    </span>
    """
  end

  @doc """
  A coloured badge for an activity outcome. Hovered, it says what the
  outcome means (`outcome_meaning/1`).
  """
  attr :outcome, :atom, required: true
  attr :id, :string, default: nil

  def outcome_badge(assigns) do
    {label, classes} = outcome_style(assigns.outcome)

    assigns =
      assign(assigns, label: label, classes: classes, meaning: outcome_meaning(assigns.outcome))

    ~H"""
    <span
      id={@id}
      title={@meaning}
      class={[
        "inline-flex shrink-0 cursor-default items-center whitespace-nowrap rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
        @classes
      ]}
    >
      {@label}
    </span>
    """
  end

  @doc """
  The words and colours of each `t:MWTClient.Sandbox.Event.outcome/0`.

  A word for what happened, read in a log of everything the VM did: the
  traffic ones say whether MWT read it, so `Read` and `Not read` pair up
  as the two lists of What MWT reads do; the rest name what changed.
  """
  @spec outcome_style(Event.outcome()) :: {String.t(), String.t()}
  def outcome_style(:read), do: {"Read", "bg-deep text-muted"}
  def outcome_style(:tunnel), do: {"Not read", "bg-deep text-faint"}
  def outcome_style(:read_failed), do: {"Cert refused", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:lookup), do: {"Lookup", "bg-deep text-faint"}
  def outcome_style(:swapped), do: {"Swapped", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:allowed), do: {"Approved", "bg-ok-soft/60 text-ok-strong"}
  def outcome_style(:denied), do: {"Denied", "bg-bad-soft/60 text-bad"}
  def outcome_style(:timed_out), do: {"No answer", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:refused), do: {"Grant off", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:blocked), do: {"Blocked", "bg-bad-soft/60 text-bad"}
  def outcome_style(:violation), do: {"Wrong host", "bg-bad text-white"}
  def outcome_style(:grant), do: {"Grant change", "bg-violet/15 text-violet-strong"}
  def outcome_style(:vm), do: {"VM change", "bg-hover text-muted"}
  def outcome_style(:command), do: {"Host command", "bg-bad-soft/50 text-bad"}
  def outcome_style(:project), do: {"Project", "bg-hover text-muted"}
  def outcome_style(:handoff), do: {"Handoff", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:tool), do: {"MWT tool", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:firewall), do: {"Firewall", "bg-bad text-white"}

  @doc """
  What an outcome means, in a sentence: shown when its badge is hovered,
  in the activity log's legend, and on its line opened.
  """
  @spec outcome_meaning(Event.outcome()) :: String.t()
  def outcome_meaning(:read),
    do: "MWT read this request and sent it as the VM wrote it: the line opens to what it carried."

  def outcome_meaning(:tunnel),
    do:
      "MWT passed the connection through as bytes, unread, so there is nothing to show: the line says why."

  def outcome_meaning(:read_failed),
    do:
      "The VM's client refused MWT's certificate, so nothing went out. Not reading its host lets it through."

  def outcome_meaning(:lookup), do: "The VM looked up a host name, and MWT answered."

  def outcome_meaning(:swapped),
    do: "MWT put a grant's real value in for the VM's placeholder, then sent the request."

  def outcome_meaning(:allowed),
    do: "An agent's ask was allowed: by you, or by what its grant allows without asking."

  def outcome_meaning(:denied), do: "An agent's ask was declined: nothing went out with it."

  def outcome_meaning(:timed_out),
    do: "Nobody answered an agent's ask in time, so it was declined."

  def outcome_meaning(:refused),
    do: "A placeholder came while its grant was off, so MWT refused the request."

  def outcome_meaning(:blocked),
    do: "MWT refused the connection: a destination it always refuses, or one whose grant is off."

  def outcome_meaning(:violation),
    do: "A placeholder headed for a host its grant doesn't list, so MWT cut the request."

  def outcome_meaning(:grant),
    do: "A grant was added, edited or removed, turned on or off, or its value replaced."

  def outcome_meaning(:vm),
    do: "The VM started, stopped or was recreated, or its image or copies of its Home changed."

  def outcome_meaning(:command),
    do:
      "A command an agent asked to run on your machine: run, declined or ended. Never its output."

  def outcome_meaning(:project),
    do: "A repository became a project or stopped being one, or its settings or mirror changed."

  def outcome_meaning(:handoff),
    do: "An agent handed off work or updated it, or you landed it, sent it back or closed it."

  def outcome_meaning(:tool),
    do: "An agent used MWT's notes, diagrams, flash cards or HTTP requests, or copied files out."

  def outcome_meaning(:firewall),
    do: "MWT's firewall found something, isolated the VM or released it, or its settings changed."

  @doc "The VM's status as a dot and a word."
  attr :vm, VM, required: true
  attr :id, :string, default: nil

  def vm_status(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1.5 text-xs font-medium">
      <span class="relative flex size-2">
        <span
          :if={@vm.status in [:starting, :stopping]}
          class="absolute inline-flex size-full rounded-full bg-warn opacity-70 motion-safe:animate-ping"
        ></span>
        <span class={[
          "relative inline-flex size-2 rounded-full",
          case @vm.status do
            :running -> "bg-ok shadow-[0_0_0_3px] shadow-ok/20"
            :stopped -> "bg-faint"
            _ -> "bg-warn"
          end
        ]}></span>
      </span>
      <span class={[
        case @vm.status do
          :running -> "text-ok-strong"
          :stopped -> "text-muted"
          _ -> "text-warn-strong"
        end
      ]}>
        {vm_word(@vm.status)}
      </span>
    </span>
    """
  end

  @doc "The word for a VM status."
  def vm_word(:running), do: "Running"
  def vm_word(:stopped), do: "Stopped"
  def vm_word(:starting), do: "Starting…"
  def vm_word(:stopping), do: "Stopping…"

  @doc """
  A card with a title row, optional actions, and a body. A `help` slot puts
  a "?" beside the title, for what the subtitle would otherwise spell out.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  attr :body_class, :any, default: "p-4"
  slot :help
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section id={@id} class={["overflow-hidden rounded-xl border border-line bg-panel", @class]}>
      <header class="flex min-h-11 items-center gap-3 border-b border-line-soft px-4 py-2.5">
        <div class="min-w-0 flex-1">
          <h2 class="flex items-center gap-1.5 text-[13px] font-semibold text-ink">
            {@title}
            <.help :if={@help != []} id={"#{@id}-help"} label={"About #{@title}"}>
              {render_slot(@help)}
            </.help>
          </h2>
          <p :if={@subtitle} class="mt-0.5 text-[11px] leading-4 text-muted">{@subtitle}</p>
        </div>
        {render_slot(@actions)}
      </header>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  The button that syncs the VM's memory with yours: it opens the review of
  what the VM noted, which ends with yours copied in. The VM's memory is on
  its disk, so only while it runs.
  """
  attr :id, :string, required: true
  attr :vm, :any, required: true

  def memory_sync_button(assigns) do
    ~H"""
    <.button
      id={@id}
      variant="primary"
      phx-click="review_memories"
      disabled={@vm.status != :running or not is_nil(@vm.busy)}
      title={
        if(@vm.status == :running,
          do: "See what the VM noted, then copy your memory in",
          else: "Start the VM first: its memory is on its disk"
        )
      }
    >
      <.icon name="hero-arrows-right-left-micro" class="size-3.5" /> Sync with mine
    </.button>
    """
  end

  @doc """
  Syncs a shared folder's copy in the VM, or every one when `path` is nil
  (`MWTClient.Sandbox.Server.ShareSync`). It turns while one is under way
  or due for it.
  """
  attr :id, :string, required: true
  attr :path, :string, default: nil
  attr :busy?, :boolean, default: false
  attr :running?, :boolean, required: true
  attr :label, :string, default: "Sync"
  attr :click, :string, default: nil, doc: "the event, when it is neither one share nor all"

  def share_sync_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@click || if(@path, do: "sync_share", else: "sync_shares")}
      phx-value-path={@path}
      disabled={not @running? or @busy?}
      title={
        cond do
          not @running? -> "Start the VM first: it syncs every shared folder as it starts"
          @busy? -> "Syncing…"
          @path -> "Copy what changed in this folder into the VM"
          true -> "Copy what changed in every shared folder into the VM"
        end
      }
      class="group/sync inline-flex h-7 shrink-0 cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-2.5 text-[11px] font-medium text-ink transition-all hover:border-accent/50 hover:text-accent active:scale-[0.97] disabled:cursor-default disabled:opacity-50 disabled:hover:border-line disabled:hover:text-ink"
    >
      <.icon
        name="hero-arrow-path-micro"
        class={[
          "size-3.5 transition-transform",
          if(@busy?, do: "animate-spin", else: "group-hover/sync:rotate-90")
        ]}
      />
      {@label}
    </button>
    """
  end

  @doc """
  How a shared folder's copy stands, in a line: what a sync under way is
  doing with it, or when it was last synced. `entry` is the share's in the
  snapshot's `sync` (`MWTClient.Sandbox.Server.ShareSync.view/1`).
  """
  attr :id, :string, required: true
  attr :entry, :map, default: nil
  attr :running?, :boolean, required: true
  attr :now, DateTime, default: nil

  def share_sync_state(assigns) do
    assigns = assign(assigns, :now, assigns.now || DateTime.utc_now())

    ~H"""
    <span id={@id} class="inline-flex min-w-0 items-center gap-1">
      <%= cond do %>
        <% @entry && @entry.progress -> %>
          <span class="relative flex size-1.5 shrink-0">
            <span class="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60"></span>
            <span class="relative inline-flex size-1.5 rounded-full bg-accent"></span>
          </span>
          <span class="truncate text-accent">{phase_words(@entry.progress)}</span>
        <% @entry && @entry.due? and @running? -> %>
          <span class="truncate text-muted">Sync queued…</span>
        <% @entry && @entry.status && @entry.status.synced_at -> %>
          <span class="truncate text-muted">
            Synced {ago(@entry.status.synced_at, @now)}{changes_words(@entry.status)}
          </span>
        <% @running? -> %>
          <span class="truncate text-faint">Not synced yet</span>
        <% true -> %>
          <span class="truncate text-faint">Synced when the VM starts</span>
      <% end %>
    </span>
    """
  end

  defp phase_words(:waiting), do: "Waiting for the others…"
  defp phase_words(:scanning), do: "Looking at the folder…"
  defp phase_words(:comparing), do: "Comparing with the VM's copy…"

  defp phase_words({:sending, files, size}),
    do: "Sending #{files} #{if files == 1, do: "file", else: "files"} (#{bytes(size)})…"

  # A copy back of the workspace's from-vm, onto this machine.
  defp changes_words(%{written: 0, removed: 0}), do: ", nothing had changed"
  defp changes_words(%{written: written, removed: 0}), do: ", #{written} copied here"
  defp changes_words(%{written: 0, removed: removed}), do: ", #{removed} removed"

  defp changes_words(%{written: written, removed: removed}),
    do: ", #{written} copied here, #{removed} removed"

  defp changes_words(%{sent: 0, removed: 0}), do: ", nothing had changed"
  defp changes_words(%{sent: sent, removed: 0}), do: ", #{sent} sent"
  defp changes_words(%{sent: 0, removed: removed}), do: ", #{removed} removed"
  defp changes_words(%{sent: sent, removed: removed}), do: ", #{sent} sent, #{removed} removed"
  defp changes_words(_status), do: ""

  @doc "A quiet line for an empty list."
  attr :icon, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center gap-2 px-6 py-8 text-center">
      <span class="flex size-9 items-center justify-center rounded-full bg-deep text-faint">
        <.icon name={@icon} class="size-4" />
      </span>
      <p class="max-w-sm text-xs leading-5 text-muted">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  The page title row: a heading, a line under it, and actions on the right.
  A `help` slot puts a "?" beside the heading.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :id, :string, default: "page-header"
  slot :help
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header id={@id} class="mb-5 flex flex-wrap items-end gap-3">
      <div class="min-w-0 flex-1">
        <h1 class="flex items-center gap-2 text-lg font-semibold tracking-tight text-ink">
          {@title}
          <.help :if={@help != []} id={"#{@id}-help"} label={"About #{@title}"}>
            {render_slot(@help)}
          </.help>
        </h1>
        <p :if={@subtitle} class="mt-1 max-w-2xl text-[13px] leading-5 text-muted">{@subtitle}</p>
      </div>
      <div class="flex items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A small segmented control; the option matching `value` reads as chosen."
  attr :id, :string, required: true
  attr :options, :list, required: true, doc: "`{value, label}` pairs"
  attr :value, :any, required: true
  attr :event, :string, required: true
  attr :name, :string, default: "value"
  attr :values, :map, default: %{}, doc: "extra phx-value-* pairs, as a map"
  attr :tone, :atom, default: :accent

  attr :confirm, :map,
    default: %{},
    doc: "option value (as text) => what to ask before switching to it"

  attr :unavailable, :list,
    default: [],
    doc: "option values shown but not offered, so rows of controls line up"

  attr :even, :boolean, default: false, doc: "every option the same width"

  def segmented(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      class="inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
    >
      <%= for {value, label} <- @options do %>
        <span
          :if={value in @unavailable}
          id={"#{@id}-#{value}"}
          aria-disabled="true"
          title={"Not an action this one takes: #{label}"}
          class={[
            "cursor-not-allowed rounded px-2 py-1 text-[11px] font-medium text-faint/50 line-through",
            @even && "w-16 text-center"
          ]}
        >
          {label}
        </span>
        <button
          :if={value not in @unavailable}
          type="button"
          id={"#{@id}-#{value}"}
          role="radio"
          aria-checked={to_string(to_string(value) == to_string(@value))}
          phx-click={JS.push(@event, value: Map.put(@values, @name, value))}
          data-confirm={to_string(value) != to_string(@value) && @confirm[to_string(value)]}
          class={[
            "cursor-pointer rounded px-2 py-1 text-[11px] font-medium transition-colors",
            @even && "w-16 text-center",
            if(to_string(value) == to_string(@value),
              do: segment_tone(@tone, value),
              else: "text-muted hover:bg-hover hover:text-ink"
            )
          ]}
        >
          {label}
        </button>
      <% end %>
    </div>
    """
  end

  defp segment_tone(:actions, value) do
    case to_string(value) do
      "allow" -> "bg-ok-soft text-ok-strong shadow-sm"
      "ask" -> "bg-warn-soft text-warn-strong shadow-sm"
      "deny" -> "bg-bad-soft text-bad shadow-sm"
      _ -> "bg-active text-ink shadow-sm"
    end
  end

  defp segment_tone(:mode, value) do
    case to_string(value) do
      "all" -> "bg-ok-soft text-ok-strong shadow-sm"
      _ -> "bg-active text-ink shadow-sm"
    end
  end

  # A firewall rule's action: isolating reads as the gravest.
  defp segment_tone(:firewall, value) do
    case to_string(value) do
      "isolate" -> "bg-bad text-white shadow-sm"
      "block" -> "bg-bad-soft text-bad shadow-sm"
      "alert" -> "bg-warn-soft text-warn-strong shadow-sm"
      _ -> "bg-active text-ink shadow-sm"
    end
  end

  # A setting whose On costs something: On reads as a warning.
  defp segment_tone(:risk, value) do
    if to_string(value) == "true",
      do: "bg-warn-soft text-warn-strong shadow-sm",
      else: "bg-active text-ink shadow-sm"
  end

  defp segment_tone(_tone, _value), do: "bg-active text-ink shadow-sm"

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true
  attr :checked, :any, required: true
  attr :tone, :string, default: "violet"

  @doc """
  Radio buttons drawn as a segmented control: plain form inputs, so a form
  needs no state on the server. `tone` colours the chosen one: `"violet"`,
  `"bad"` or `"ok"`.
  """
  def pills(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      class="inline-flex items-center gap-0.5 rounded-md border border-line bg-panel p-0.5"
    >
      <label :for={{value, label} <- @options} class="relative">
        <input
          type="radio"
          name={@name}
          id={"#{@id}-#{value}"}
          value={value}
          checked={to_string(value) == to_string(@checked)}
          class="peer sr-only"
        />
        <span class={[
          "block cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:bg-hover hover:text-ink peer-focus-visible:outline-2",
          case @tone do
            "bad" ->
              "peer-checked:bg-bad-soft/50 peer-checked:text-bad peer-focus-visible:outline-bad"

            "ok" ->
              "peer-checked:bg-ok-soft/60 peer-checked:text-ok-strong peer-focus-visible:outline-ok"

            _violet ->
              "peer-checked:bg-violet/15 peer-checked:text-violet-strong peer-focus-visible:outline-violet"
          end
        ]}>
          {label}
        </span>
      </label>
    </div>
    """
  end

  ## Pages of a list

  @doc """
  One page of `items`, `per_page` each, with the page shown, kept within
  the pages there are, and how many pages there are. A list with nothing
  in it has one page, empty.

      iex> {shown, page, pages} = MWTClientWeb.SandboxLive.Components.paged(Enum.to_list(1..14), 9, 6)
      iex> {shown, page, pages}
      {[13, 14], 3, 3}
  """
  @spec paged([item], integer(), pos_integer()) :: {[item], pos_integer(), pos_integer()}
        when item: term()
  def paged(items, page, per_page) when is_integer(page) and per_page > 0 do
    pages = max(div(length(items) + per_page - 1, per_page), 1)
    page = page |> max(1) |> min(pages)
    {Enum.slice(items, (page - 1) * per_page, per_page), page, pages}
  end

  @doc """
  Which page of a list cut by `paged/3` shows, and the way to the others:
  the rows shown out of how many, then a button per page between previous
  and next. Each pushes `event` with the page it shows as `page`.

  `name` starts its ids: `NAME-pages` for the whole, `NAME-pages-shown`,
  `NAME-page-prev`, `NAME-page-N` and `NAME-page-next`.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true, doc: "what it is, for a screen reader"
  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :event, :string, required: true
  attr :class, :any, default: nil

  def pages(assigns) do
    first = (assigns.page - 1) * assigns.per_page + 1

    assigns =
      assign(assigns, first: first, last: min(first + assigns.per_page - 1, assigns.total))

    ~H"""
    <nav
      id={"#{@name}-pages"}
      aria-label={@label}
      class={["flex flex-wrap items-center gap-2 text-[11px] text-muted", @class]}
    >
      <span id={"#{@name}-pages-shown"} class="tabular-nums">
        {@first}–{@last} of {@total}
      </span>
      <span class="flex-1"></span>
      <button
        type="button"
        id={"#{@name}-page-prev"}
        phx-click={@event}
        phx-value-page={@page - 1}
        disabled={@page == 1}
        aria-label="Previous page"
        class="inline-flex size-7 cursor-pointer items-center justify-center rounded-md border border-line bg-panel text-ink transition-colors hover:border-accent/50 hover:text-accent disabled:cursor-default disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink"
      >
        <.icon name="hero-chevron-left-micro" class="size-4" />
      </button>
      <button
        :for={number <- 1..@pages}
        type="button"
        id={"#{@name}-page-#{number}"}
        phx-click={@event}
        phx-value-page={number}
        aria-current={if(number == @page, do: "page")}
        class={[
          "inline-flex h-7 min-w-7 cursor-pointer items-center justify-center rounded-md border px-2 font-medium tabular-nums transition-colors",
          if(number == @page,
            do: "border-accent/60 bg-accent-soft/50 text-accent-strong",
            else: "border-line bg-panel text-ink hover:border-accent/50 hover:text-accent"
          )
        ]}
      >
        {number}
      </button>
      <button
        type="button"
        id={"#{@name}-page-next"}
        phx-click={@event}
        phx-value-page={@page + 1}
        disabled={@page == @pages}
        aria-label="Next page"
        class="inline-flex size-7 cursor-pointer items-center justify-center rounded-md border border-line bg-panel text-ink transition-colors hover:border-accent/50 hover:text-accent disabled:cursor-default disabled:opacity-40 disabled:hover:border-line disabled:hover:text-ink"
      >
        <.icon name="hero-chevron-right-micro" class="size-4" />
      </button>
    </nav>
    """
  end

  @doc """
  The page a pager's event asks for, from its `page` value; nil when it
  isn't a whole number. The page shown keeps it within the pages there are.
  """
  @spec page_asked(term()) :: integer() | nil
  def page_asked(page) do
    case Integer.parse(to_string(page)) do
      {number, ""} -> number
      _other -> nil
    end
  end
end
