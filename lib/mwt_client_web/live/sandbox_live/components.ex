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

  @doc "A coloured badge for an activity outcome."
  attr :outcome, :atom, required: true

  def outcome_badge(assigns) do
    {label, classes} = outcome_style(assigns.outcome)
    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      @classes
    ]}>
      {@label}
    </span>
    """
  end

  @doc "The words and colours of each `t:MWTClient.Sandbox.Event.outcome/0`."
  @spec outcome_style(Event.outcome()) :: {String.t(), String.t()}
  def outcome_style(:tunnel), do: {"Passed", "bg-deep text-faint"}
  def outcome_style(:lookup), do: {"Lookup", "bg-deep text-faint"}
  def outcome_style(:swapped), do: {"Credential", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:allowed), do: {"Approved", "bg-ok-soft/60 text-ok-strong"}
  def outcome_style(:denied), do: {"Denied", "bg-bad-soft/60 text-bad"}
  def outcome_style(:timed_out), do: {"Timed out", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:refused), do: {"Grant off", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:blocked), do: {"Blocked", "bg-bad-soft/60 text-bad"}
  def outcome_style(:violation), do: {"Violation", "bg-bad text-white"}
  def outcome_style(:grant), do: {"Grant", "bg-violet/15 text-violet-strong"}
  def outcome_style(:vm), do: {"VM", "bg-hover text-muted"}
  def outcome_style(:command), do: {"Host", "bg-bad-soft/50 text-bad"}
  def outcome_style(:project), do: {"Project", "bg-hover text-muted"}
  def outcome_style(:handoff), do: {"Handoff", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:tool), do: {"MWT", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:firewall), do: {"Firewall", "bg-bad text-white"}

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
end
