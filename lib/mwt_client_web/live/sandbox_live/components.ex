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

  @doc """
  A resource, by name, as a link to its page (`MWTClient.Sandbox.Resource`):
  the credential, network, machine or MWT's tools a grant mediates. `bare`
  drops the frame, for inside a line of text.
  """
  attr :resource, :any, required: true
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :bare, :boolean, default: false

  def resource_chip(assigns) do
    ~H"""
    <.link
      navigate={MWTClient.Sandbox.Resource.path(@resource)}
      id={@id}
      title={"#{MWTClient.Sandbox.Resource.kind_words(@resource)}: #{@name}"}
      class={[
        "relative z-10 inline-flex min-w-0 items-center gap-1 transition-colors hover:text-accent",
        if(@bare,
          do: "text-muted",
          else:
            "rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted hover:border-accent/40"
        )
      ]}
    >
      <.icon name={resource_icon(@resource)} class="size-3 shrink-0" />
      <span class="truncate">{@name}</span>
    </.link>
    """
  end

  @doc "The icon for a kind of resource."
  def resource_icon({:credential, _id}), do: "hero-key-micro"
  def resource_icon({:network, _id}), do: "hero-globe-alt-micro"
  def resource_icon(:machine), do: "hero-computer-desktop-micro"
  def resource_icon(:mwt), do: "hero-document-text-micro"

  @doc "What the VM ends up holding for a grant, in two words and a colour."
  attr :grant, Grant, required: true

  def exposure(assigns) do
    ~H"""
    <span
      :if={@grant.kind == :token}
      class="inline-flex items-center gap-1 rounded border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-ok-strong"
      title="The VM only has a placeholder. MWT swaps in the real value on the way out."
    >
      <.icon name="hero-shield-check-micro" class="size-3" /> Placeholder only
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
  def outcome_style(:refused), do: {"Refused", "bg-warn-soft/60 text-warn-strong"}
  def outcome_style(:blocked), do: {"Blocked", "bg-bad-soft/60 text-bad"}
  def outcome_style(:violation), do: {"Wrong host", "bg-bad text-white"}
  def outcome_style(:grant), do: {"Grant change", "bg-violet/15 text-violet-strong"}
  def outcome_style(:vm), do: {"VM change", "bg-hover text-muted"}
  def outcome_style(:command), do: {"Host command", "bg-bad-soft/50 text-bad"}
  def outcome_style(:call), do: {"Fixed call", "bg-violet/15 text-violet-strong"}
  def outcome_style(:project), do: {"Project", "bg-hover text-muted"}
  def outcome_style(:handoff), do: {"Handoff", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:tool), do: {"MWT tool", "bg-accent-soft/60 text-accent-strong"}
  def outcome_style(:firewall), do: {"Firewall", "bg-bad text-white"}
  def outcome_style(:lost), do: {"Not kept", "bg-warn-soft/60 text-warn-strong"}

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
    do:
      "MWT refused it before it went anywhere: no grant that is on covers it (one is off, leaves its host out, or doesn't list it), or a call's values break a parameter's shape or rule. The line says which."

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

  def outcome_meaning(:call),
    do:
      "A call of a fixed request: asked, sent through MWT's proxy, answered. The request it sent has a line of its own."

  def outcome_meaning(:project),
    do: "A repository became a project or stopped being one, or its settings or mirror changed."

  def outcome_meaning(:handoff),
    do: "An agent handed off work or updated it, or you landed it, sent it back or closed it."

  def outcome_meaning(:tool),
    do: "An agent used MWT's notes, diagrams, flash cards or HTTP requests, or copied files out."

  def outcome_meaning(:firewall),
    do: "MWT's firewall found something, isolated the VM or released it, or its settings changed."

  def outcome_meaning(:lost),
    do: "Events MWT couldn't write to the activity log, so they aren't in it: how many, and when."

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
  A part of a page, without a box: a heading with its "?", actions on the
  right, and what it holds under a rule. Pages are sections one under the
  other; `card/1` is for a list that is one thing.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  slot :help
  slot :actions
  slot :inner_block, required: true

  def page_section(assigns) do
    ~H"""
    <section id={@id} class={["border-t border-line-soft pt-4", @class]}>
      <header class="mb-3 flex flex-wrap items-center gap-x-3 gap-y-1">
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
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A short label beside a name: one shape for every tag (*Proposed*, *To review*, *Starts on*, *Locked*), its tone saying what
  kind of thing it says.
  """
  attr :id, :string, default: nil
  attr :tone, :atom, default: :plain, values: [:plain, :accent, :ok, :warn, :bad, :violet]
  attr :icon, :string, default: nil
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      id={@id}
      title={@title}
      class={[
        "inline-flex shrink-0 items-center gap-1 rounded border px-1.5 py-0.5 text-[10px] font-medium",
        case @tone do
          :plain -> "border-line bg-deep text-muted"
          :accent -> "border-accent/40 bg-accent-soft/30 text-accent-strong"
          :ok -> "border-ok/40 bg-ok-soft/30 text-ok-strong"
          :warn -> "border-warn/45 bg-warn-soft/40 text-warn-strong"
          :bad -> "border-bad/45 bg-bad-soft/40 text-bad"
          :violet -> "border-violet/40 bg-violet/10 text-violet-strong"
        end
      ]}
    >
      <.icon :if={@icon} name={@icon} class="size-3" />{render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A form's text field as the sandbox's forms show one: its label in words,
  a "?" for what its value means when there is more to say, the field,
  and a line under it. Errors show apart (`field_error`), as the sandbox's
  builders return them by field.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil, doc: "a line under the field"
  attr :help, :string, default: nil, doc: "more, behind a ?"
  attr :type, :string, default: "text"
  attr :mono, :boolean, default: false, doc: "for code: scripts, hosts, headers"

  attr :rest, :global,
    include:
      ~w(placeholder rows autocomplete phx-mounted phx-debounce min max disabled spellcheck)

  def text_field(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center gap-1">
        <label for={@field.id} class="text-[12px] font-medium text-ink">{@label}</label>
        <.help :if={@help} id={"#{@field.id}-help"} label={"About #{@label}"}>{@help}</.help>
      </div>
      <textarea
        :if={@type == "textarea"}
        id={@field.id}
        name={@field.name}
        class={field_classes(@mono)}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
      <input
        :if={@type != "textarea"}
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        class={field_classes(@mono)}
        {@rest}
      />
      <p :if={@hint} class="text-[11px] leading-4 text-muted">{@hint}</p>
    </div>
    """
  end

  @doc """
  A form's yes-or-no field, as the sandbox's forms show one: a box, its
  label, and a line under it.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :id, :string, default: nil
  attr :checked_value, :string, default: "true"
  attr :unchecked_value, :string, default: "false"

  attr :checked, :boolean,
    default: nil,
    doc: "whether it is checked; by default, whether the field holds the checked value"

  def check_field(assigns) do
    assigns =
      assign_new(assigns, :is_checked, fn ->
        if is_nil(assigns.checked),
          do: to_string(assigns.field.value) == assigns.checked_value,
          else: assigns.checked
      end)

    ~H"""
    <label class="flex cursor-pointer items-start gap-2.5">
      <input type="hidden" name={@field.name} value={@unchecked_value} />
      <input
        type="checkbox"
        name={@field.name}
        id={@id || @field.id}
        value={@checked_value}
        checked={@is_checked}
        class="mt-0.5 size-4 shrink-0 cursor-pointer rounded accent-accent"
      />
      <span class="min-w-0">
        <span class="block text-[12px] font-medium text-ink">{@label}</span>
        <span :if={@hint} class="block text-[11px] leading-4 text-muted">{@hint}</span>
      </span>
    </label>
    """
  end

  @doc """
  One choice of a few, in a form, as a row of pills: radio inputs a
  submit sends, so it is saved with the rest.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :options, :list, required: true, doc: "`{value, label}` pairs"
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  def choice_field(assigns) do
    ~H"""
    <div id={@id} class="space-y-1.5">
      <p :if={@label} class="text-[12px] font-medium text-ink">{@label}</p>
      <div
        role="radiogroup"
        class="inline-flex flex-wrap rounded-lg border border-line-soft bg-deep/60 p-0.5"
      >
        <label
          :for={{value, label} <- @options}
          id={"#{@id}-#{value}"}
          class={[
            "cursor-pointer rounded-md px-3 py-1 text-[12px] transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
            if(to_string(@value) == to_string(value),
              do: "bg-panel font-medium text-ink shadow-sm",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <input
            type="radio"
            name={@name}
            value={value}
            checked={to_string(@value) == to_string(value)}
            class="sr-only"
          />
          {label}
        </label>
      </div>
      <p :if={@hint} class="text-[11px] leading-4 text-muted">{@hint}</p>
    </div>
    """
  end

  defp field_classes(mono) do
    [
      "w-full rounded-lg border border-line-soft bg-deep/40 px-3 py-2 text-ink shadow-xs",
      "placeholder:text-faint transition-colors focus:border-accent/60 focus:bg-panel focus:outline-none focus:ring-2 focus:ring-accent/15",
      if(mono, do: "font-mono text-[12px]", else: "text-[13px]")
    ]
  end

  @doc """
  Where a command or a script runs: on the host, your machine, as you
  (`MWTClient.Sandbox.Grant.host_command?/1`), beside every script or
  command a page shows; or on the VM, for what the console tries as the
  VM would.
  """
  attr :id, :string, default: nil
  attr :place, :atom, required: true, values: [:vm, :machine]

  def where(assigns) do
    ~H"""
    <span
      id={@id}
      title={
        if(@place == :vm,
          do: "Runs on the VM: agents' own tools, where MWT sees only what leaves it",
          else:
            "Runs on the host, your machine: carried out by MWT or as you, the VM only sends values"
        )
      }
      class={[
        "inline-flex shrink-0 items-center gap-1 rounded border px-1.5 py-0.5 text-[10px] font-medium",
        if(@place == :vm,
          do: "border-accent/35 bg-accent-soft/30 text-accent-strong",
          else: "border-warn/40 bg-warn-soft/30 text-warn-strong"
        )
      ]}
    >
      <.icon
        name={
          if(@place == :vm, do: "hero-cube-transparent-micro", else: "hero-computer-desktop-micro")
        }
        class="size-3"
      />
      {if(@place == :vm, do: "Runs on VM", else: "Runs on host")}
    </span>
    """
  end

  @doc """
  A grant's kind: open use or a fixed call (`Grant.kind_of/1`), by who
  builds what it lets through. Every grant shows it.
  """
  attr :id, :string, default: nil
  attr :kind, :atom, required: true, values: [:open, :fixed]

  def kind_badge(assigns) do
    ~H"""
    <span
      id={@id}
      title={"#{kind_name(@kind)}: #{kind_words(@kind)}"}
      class="inline-flex shrink-0 items-center rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
    >
      {kind_name(@kind)}
    </span>
    """
  end

  @doc "What a kind of grant is called."
  def kind_name(:open), do: "Open use"
  def kind_name(:fixed), do: "Fixed call"

  @doc "What a kind of grant is, in a line."
  def kind_words(:open),
    do:
      "The agent builds it with its own tools; MWT checks each request or command against the grants."

  def kind_words(:fixed),
    do: "MWT builds it from your template and the agent's values, which must fit its parameters."

  @doc """
  What a form holds beyond the common case, folded: its summary says what
  of it is set, so nothing set there is hidden.
  """
  attr :id, :string, required: true
  attr :set, :list, default: [], doc: "what is set in it, each a few words"
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  def advanced(assigns) do
    ~H"""
    <details id={@id} open={@open} class="group rounded-lg border border-line-soft">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-xs text-muted transition-colors hover:text-ink">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3.5 shrink-0 transition-transform group-open:rotate-90"
        />
        <span class="font-medium">Advanced</span>
        <span :if={@set != []} class="min-w-0 truncate text-faint">· {Enum.join(@set, " · ")}</span>
      </summary>
      <div class="space-y-4 border-t border-line-soft px-3 py-3">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  @doc """
  Choosing a preset, or none, before a form: each with what it is, what it
  sets and what it asks you for, so you choose knowing what you get; a
  search over them when there are many. Choosing pushes `event` with the
  preset's id as `preset`; "By hand" with none.
  """
  attr :id, :string, required: true
  attr :presets, :list, required: true
  attr :event, :string, required: true
  attr :by_hand, :string, required: true, doc: "what By hand means here, in a line"

  def preset_picker(assigns) do
    ~H"""
    <div id={@id} phx-hook=".PresetSearch" class="space-y-2">
      <input
        :if={length(@presets) > 5}
        type="search"
        id={"#{@id}-search"}
        data-preset-search
        placeholder="Search presets"
        autocomplete="off"
        class="w-full rounded-md border border-line bg-deep px-2.5 py-1.5 text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
      />
      <ul class="divide-y divide-line-soft overflow-hidden rounded-lg border border-line-soft">
        <li>
          <button
            type="button"
            id={"#{@id}-none"}
            phx-click={@event}
            class="flex w-full cursor-pointer items-start gap-3 px-3 py-2.5 text-left transition-colors hover:bg-accent-soft/20"
          >
            <.icon name="hero-pencil-square" class="mt-0.5 size-4 shrink-0 text-muted" />
            <span class="min-w-0 flex-1">
              <span class="block text-xs font-medium text-ink">By hand</span>
              <span class="block text-[11px] text-muted">{@by_hand}</span>
            </span>
          </button>
        </li>
        <li
          :for={preset <- @presets}
          data-preset-text={
            String.downcase(
              "#{preset.name} #{preset.blurb} #{Enum.join(MWTClient.Sandbox.Presets.summary(preset), " ")}"
            )
          }
        >
          <button
            type="button"
            id={"#{@id}-#{preset.id}"}
            phx-click={@event}
            phx-value-preset={preset.id}
            class="flex w-full cursor-pointer items-start gap-3 px-3 py-2.5 text-left transition-colors hover:bg-accent-soft/20"
          >
            <.icon name={preset.icon} class="mt-0.5 size-4 shrink-0 text-muted" />
            <span class="min-w-0 flex-1">
              <span class="block text-xs font-medium text-ink">{preset.name}</span>
              <span class="block text-[11px] text-muted">{preset.blurb}</span>
              <span
                :if={MWTClient.Sandbox.Presets.summary(preset) != []}
                class="mt-0.5 block text-[10px] text-faint"
              >
                Sets: {Enum.join(MWTClient.Sandbox.Presets.summary(preset), " · ")}
              </span>
              <span
                :if={MWTClient.Sandbox.Presets.needs(preset) != []}
                class="block text-[10px] text-faint"
              >
                You give: {Enum.join(MWTClient.Sandbox.Presets.needs(preset), ", ")}
              </span>
            </span>
          </button>
        </li>
      </ul>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PresetSearch">
      // Shows only the presets whose words hold every word typed; By hand
      // always shows.
      export default {
        mounted() {
          const input = this.el.querySelector("[data-preset-search]")
          if (!input) return
          input.addEventListener("input", () => {
            const words = input.value.toLowerCase().split(/\s+/).filter(Boolean)
            this.el.querySelectorAll("[data-preset-text]").forEach((row) => {
              const text = row.dataset.presetText
              row.hidden = !words.every((word) => text.includes(word))
            })
          })
        }
      }
    </script>
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

  @doc """
  A small segmented control; the option matching `value` reads as chosen.
  Each option's id is the control's, `--`, and its value: a control's id
  may end in an id of yours (a grant's), and ids MWT gives never hold
  `--`, so no option's id can be another element's.
  """
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
          id={"#{@id}--#{value}"}
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
          id={"#{@id}--#{value}"}
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
