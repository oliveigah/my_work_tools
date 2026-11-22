defmodule MWTClientWeb.SandboxLive.Overview do
  @moduledoc """
  The overview: the VM and its controls, its resources (`Monitor`), its
  servers open on this machine (`Servers`), what is shared right now, the
  VM's memory and the latest activity, on one screen. What waits for you is
  a count here, and the Approvals page itself.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Grant, Presets}
  alias MWTClientWeb.SandboxLive.{Monitor, Servers}

  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :created_ref, :string, default: nil
  attr :proxy, :map, required: true
  attr :tools, :map, required: true
  attr :settings, :any, required: true
  attr :memory, :map, required: true
  attr :grants, :list, required: true
  attr :waiting, :list, required: true
  attr :recent, :list, required: true
  attr :stats, :map, required: true
  attr :ports, :map, required: true
  attr :monitor, :any, default: nil
  attr :monitor_by, :atom, default: :cpu
  attr :sync, :map, default: %{}
  attr :workspace, :map, default: %{root: nil, error: nil, on?: false}
  attr :now, DateTime, required: true

  def page(assigns) do
    on = Enum.filter(assigns.grants, &Grant.on?/1)
    assigns = assign(assigns, on: on)

    ~H"""
    <section
      id="vm-card"
      class="relative mb-5 overflow-hidden rounded-xl border border-line bg-panel"
    >
      <div class={[
        "pointer-events-none absolute inset-0 opacity-60",
        @vm.status == :running &&
          "bg-[radial-gradient(ellipse_at_top_left,var(--color-ok-soft),transparent_55%)]"
      ]}>
      </div>
      <div class="relative flex flex-wrap items-center gap-5 px-5 py-4">
        <span class={[
          "flex size-12 shrink-0 items-center justify-center rounded-xl border transition-colors",
          if(@vm.status == :running,
            do: "border-ok/35 bg-ok-soft/60 text-ok-strong",
            else: "border-line bg-deep text-muted"
          )
        ]}>
          <.icon name="hero-cube-transparent" class="size-6" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="text-lg font-semibold tracking-tight text-ink">{@vm.name}</h1>
            <.vm_status vm={@vm} id="vm-status" />
            <span :if={@vm.status == :running and @vm.started_at} class="text-xs text-muted">
              for <.clock id="vm-uptime" since={@vm.started_at} duration now={@now} />
            </span>
          </div>
          <p id="vm-image" class="mt-1 font-mono text-[11px] text-muted">
            {if @vm.exists?, do: @created_ref || "unknown image", else: @image.tag} · {@settings.cpus} CPUs · {@settings.memory_gib} GiB · {@settings.disk_gib} GiB disk · {length(
              @settings.shares
            )} shared folders
          </p>
          <p :if={@vm.exists? and @vm.record} id="vm-record" class="mt-1 text-[11px] text-muted">
            <span class="font-mono text-ink">vm {@vm.record.id}</span>
            <span :if={@vm.record.created_at}>
              · created
              <.clock
                id="vm-created"
                since={@vm.record.created_at}
                now={@now}
              /> · in the VM, <code class="font-mono">mwt vm</code>
              says if you're in this one
            </span>
          </p>
          <p
            :if={@vm.exists? and @created_ref != @image.tag}
            id="vm-next-image"
            class="mt-1 text-[11px] text-muted"
          >
            Next image: <span class="font-mono">{@image.tag}</span>. Recreate to use it.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.button
            :if={@vm.exists? and not @vm.stale? and is_nil(@vm.busy) and @image.loaded?}
            id="vm-recreate-any"
            phx-click="recreate_vm"
            title="Start over from the image, choosing what happens to Home and Cache"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5" /> Recreate…
          </.button>
          <%= cond do %>
            <% @vm.busy -> %>
              <.button id="vm-busy" disabled>
                <.icon name="hero-arrow-path-micro" class="size-3.5 animate-spin" /> {@vm.busy}
              </.button>
            <% not @image.loaded? -> %>
              <.button id="vm-build" variant="primary" patch={~p"/tools/sandbox/setup"}>
                <.icon name="hero-wrench-screwdriver-micro" class="size-3.5" />
                {if @image.building?, do: "Image building…", else: "Build the image"}
              </.button>
            <% @vm.status == :running -> %>
              <.button id="vm-stop" phx-click="stop_vm">
                <.icon name="hero-stop-micro" class="size-3.5" /> Stop
              </.button>
            <% @vm.exists? -> %>
              <.button id="vm-start" variant="primary" phx-click="start_vm">
                <.icon name="hero-play-micro" class="size-3.5" /> Start
              </.button>
            <% true -> %>
              <.button id="vm-start" variant="primary" phx-click="start_vm">
                <.icon name="hero-play-micro" class="size-3.5" /> Create and start
              </.button>
          <% end %>
        </div>
      </div>
      <div
        :if={@vm.error}
        id="vm-error"
        class="relative flex gap-2.5 border-t border-bad/30 bg-bad-soft/20 px-5 py-2.5"
      >
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0 text-bad" />
        <pre
          class="min-w-0 flex-1 whitespace-pre-wrap break-words font-mono text-[11px] leading-4 text-ink"
          phx-no-curly-interpolation
        ><%= @vm.error %></pre>
      </div>
      <div
        :if={not @proxy.listening?}
        id="proxy-down"
        class="relative flex gap-2.5 border-t border-bad/30 bg-bad-soft/20 px-5 py-2.5"
      >
        <.icon name="hero-signal-slash" class="mt-px size-4 shrink-0 text-bad" />
        <p class="text-xs text-ink">
          {@proxy.error || "The proxy isn't listening."} The VM has no internet until it is.
        </p>
      </div>
      <div
        :if={not @image.loaded? and not @vm.exists?}
        id="vm-first-run"
        class="relative flex flex-wrap items-center gap-x-3 gap-y-1 border-t border-line-soft px-5 py-3 text-xs leading-5 text-muted"
      >
        <.icon name="hero-sparkles-micro" class="size-4 text-accent" />
        <span>New sandbox: build its image, share your folders, then start it.</span>
        <.link patch={~p"/tools/sandbox/setup"} class="font-medium text-accent hover:underline">
          Open Setup
        </.link>
        <span :if={not @tools.podman} class="text-bad">podman isn't installed.</span>
        <span :for={need <- @tools.needs} class="text-bad">{need}</span>
        <span :if={is_nil(@tools.msb)} class="text-bad">
          This MWT has no microsandbox runtime; in a source checkout, run scripts/build-microsandbox.sh.
        </span>
      </div>
      <div
        :if={@vm.stale?}
        id="vm-stale"
        class="relative flex flex-wrap items-center gap-3 border-t border-warn/30 bg-warn-soft/30 px-5 py-2.5"
      >
        <.icon name="hero-arrow-path" class="size-4 text-warn" />
        <p class="flex flex-1 items-center gap-1.5 text-xs text-ink">
          Settings or the image changed. Recreate the VM to use them.
          <.help id="vm-stale-help" label="About recreating">
            The VM keeps what it was created with until it is recreated. Recreating asks what happens to its Home (logins, history) and Cache; its memory and your folders stay.
          </.help>
        </p>
        <.button
          id="vm-recreate"
          phx-click="recreate_vm"
          disabled={not is_nil(@vm.busy) or not @image.loaded?}
        >
          Recreate now
        </.button>
      </div>
    </section>

    <Monitor.card monitor={@monitor} vm={@vm} by={@monitor_by} />

    <div class="mb-6 grid gap-3 sm:grid-cols-3">
      <.link
        patch={~p"/tools/sandbox/approvals"}
        id="stat-waiting"
        class={[
          "group rounded-xl border bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:shadow-lg hover:shadow-black/10",
          if(@stats.waiting > 0, do: "border-warn/40", else: "border-line hover:border-accent/50")
        ]}
      >
        <p class="text-[11px] font-medium text-muted">Waiting for you</p>
        <p class={[
          "mt-1 text-2xl font-semibold tabular-nums",
          if(@stats.waiting > 0, do: "text-warn-strong", else: "text-ink")
        ]}>
          {@stats.waiting}
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {waiting_words(@waiting)}
        </p>
      </.link>
      <.link
        patch={~p"/tools/sandbox/grants"}
        id="stat-grants"
        class="group rounded-xl border border-line bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:border-accent/50 hover:shadow-lg hover:shadow-black/10"
      >
        <p class="text-[11px] font-medium text-muted">Grants on</p>
        <p class="mt-1 text-2xl font-semibold tabular-nums text-ink">
          {length(@on)}<span class="text-sm font-normal text-faint"> / {length(@grants)}</span>
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {review_words(Enum.count(@grants, &Grant.to_review?/1))}
        </p>
      </.link>
      <.link
        patch={~p"/tools/sandbox/activity"}
        id="stat-activity"
        class="group rounded-xl border border-line bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:border-accent/50 hover:shadow-lg hover:shadow-black/10"
      >
        <p class="text-[11px] font-medium text-muted">Last hour</p>
        <p class="mt-1 text-2xl font-semibold tabular-nums text-ink">
          {@stats.connections}<span class="text-sm font-normal text-faint"> connections</span>
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {@stats.credentials} used a credential ·
          <span class={@stats.blocked > 0 && "text-bad"}>{@stats.blocked} blocked</span>
        </p>
      </.link>
    </div>

    <div class="grid items-start gap-5 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
      <div class="space-y-5">
        <Servers.overview_card ports={@ports} />

        <.card id="overview-activity" title="Latest activity" body_class="">
          <:actions>
            <.link patch={~p"/tools/sandbox/activity"} class="text-[11px] text-accent hover:underline">
              Activity log
            </.link>
          </:actions>
          <div :if={@recent == []}>
            <.empty icon="hero-queue-list" id="overview-activity-empty">
              Nothing in the last hour.
            </.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={event <- @recent}
              id={"recent-#{event.id}"}
              class="flex items-center gap-2.5 px-4 py-2"
            >
              <.outcome_badge outcome={event.outcome} />
              <p class="min-w-0 flex-1 truncate text-[11px] text-ink" title={event.summary}>
                {event.host || event.summary}
                <span :if={event.host} class="text-faint">· {event.summary}</span>
              </p>
              <span class="shrink-0 text-[10px] text-faint">
                <.clock id={"recent-at-#{event.id}"} since={event.at} now={@now} />
              </span>
            </li>
          </ul>
        </.card>
      </div>

      <div class="space-y-5">
        <.card id="overview-grants" title="Shared right now" body_class="">
          <:actions>
            <.link patch={~p"/tools/sandbox/grants"} class="text-[11px] text-accent hover:underline">
              All grants
            </.link>
          </:actions>
          <div :if={@on == []}>
            <.empty icon="hero-lock-closed">
              Nothing beyond the public internet.
            </.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={grant <- @on}
              id={"overview-grant-#{grant.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <.grant_tile icon={Presets.icon(grant)} on class="size-7" />
              <.link
                patch={~p"/tools/sandbox/grants/#{grant.id}"}
                class="min-w-0 flex-1 truncate text-xs font-medium text-ink hover:text-accent"
              >
                {grant.name}
              </.link>
              <span class="font-mono text-[11px] text-ok-strong">
                <%= if grant.expires_at do %>
                  <.clock
                    id={"overview-left-#{grant.id}"}
                    deadline={grant.expires_at}
                    done="ending…"
                    now={@now}
                  />
                <% else %>
                  until off
                <% end %>
              </span>
              <.switch
                id={"overview-switch-#{grant.id}"}
                on
                label={"Turn #{grant.name} off"}
                phx-click="turn_off"
                phx-value-id={grant.id}
              />
            </li>
          </ul>
        </.card>

        <.shares_card shares={@settings.shares} sync={@sync} vm={@vm} now={@now} />

        <.workspace_card workspace={@workspace} vm={@vm} now={@now} />

        <.memory_card memory={@memory} vm={@vm} />
      </div>
    </div>
    """
  end

  attr :shares, :list, required: true
  attr :sync, :map, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  # Your shared folders' copies in the VM: when each was last synced, and
  # the buttons that sync them.
  defp shares_card(assigns) do
    assigns =
      assign(assigns,
        running?: assigns.vm.status == :running,
        busy?: Enum.any?(Map.values(assigns.sync), &(&1.progress != nil))
      )

    ~H"""
    <.card id="overview-shares" title="Shared folders" body_class="">
      <:help>
        Each one's files are copied into the VM, read-only at the same path; its git repositories are projects. A copy changes only when synced: as the VM starts, with Sync, after a command you approved ran in it, and when an agent runs mwt sync.
      </:help>
      <:actions>
        <.share_sync_button
          :if={@shares != []}
          id="overview-shares-sync-all"
          label="Sync all"
          running?={@running?}
          busy?={@busy?}
        />
      </:actions>
      <div :if={@shares == []}>
        <.empty icon="hero-folder" id="overview-shares-empty">
          No folder shared.
          <.link patch={~p"/tools/sandbox/settings"} class="text-accent hover:underline">
            Share one in Settings
          </.link>
        </.empty>
      </div>
      <ul class="divide-y divide-line-soft">
        <li
          :for={{share, index} <- Enum.with_index(@shares)}
          id={"overview-share-#{index}"}
          class="flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
        >
          <.icon name="hero-folder" class="size-4 shrink-0 text-faint" />
          <div class="min-w-0 flex-1">
            <p class="truncate text-xs font-medium text-ink" title={share.path}>
              {Path.basename(share.path)}
            </p>
            <p class="flex min-w-0 text-[10px] leading-4">
              <.share_sync_state
                id={"overview-share-state-#{index}"}
                entry={@sync[share.path]}
                running?={@running?}
                now={@now}
              />
            </p>
            <p
              :if={match?(%{status: %{error: error}} when is_binary(error), @sync[share.path])}
              id={"overview-share-error-#{index}"}
              class="truncate text-[10px] leading-4 text-bad"
              title={@sync[share.path].status.error}
            >
              {@sync[share.path].status.error}
            </p>
          </div>
          <.share_sync_button
            id={"overview-share-sync-#{index}"}
            path={share.path}
            running?={@running?}
            busy?={match?(%{progress: progress} when progress != nil, @sync[share.path])}
          />
        </li>
      </ul>
    </.card>
    """
  end

  attr :workspace, :map, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  # The workspace: where it is, or why there is none; each half's last
  # sync, files of yours held back from the VM, and the buttons.
  defp workspace_card(assigns) do
    halves = for key <- [:to_vm, :from_vm], half = assigns.workspace[key], half, do: half

    assigns =
      assign(assigns,
        running?: assigns.vm.status == :running,
        busy?: Enum.any?(halves, &(&1.progress != nil)),
        held: get_in(assigns.workspace, [:to_vm, :status, :held]) || []
      )

    ~H"""
    <.card id="overview-workspace" title="Workspace" body_class="">
      <:help>
        A folder to move files between the VM and this machine, at the same path on both sides. to-vm is yours: what your commands leave there, the VM reads. from-vm is what agents leave for you, copied here read-only. Both sync with your shared folders.
      </:help>
      <:actions>
        <button
          :if={@workspace.root}
          type="button"
          id="overview-workspace-open"
          phx-click="open_workspace"
          title={"Open #{@workspace.root} in your file manager"}
          class="inline-flex h-7 shrink-0 cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-2.5 text-[11px] font-medium text-ink transition-all hover:border-accent/50 hover:text-accent active:scale-[0.97]"
        >
          <.icon name="hero-folder-open-micro" class="size-3.5" /> Open
        </button>
        <.share_sync_button
          :if={@workspace.root}
          id="overview-workspace-sync"
          click="sync_workspace"
          running?={@running?}
          busy?={@busy?}
        />
      </:actions>
      <%= cond do %>
        <% @workspace.error -> %>
          <p id="overview-workspace-error" class="px-4 py-3 text-xs leading-5 text-bad">
            {@workspace.error}
          </p>
        <% is_nil(@workspace.root) -> %>
          <.empty icon="hero-arrows-right-left" id="overview-workspace-empty">
            Made at the first sync with the VM running.
          </.empty>
        <% true -> %>
          <p
            id="overview-workspace-root"
            class="truncate px-4 pt-2.5 font-mono text-[11px] text-muted"
            title={@workspace.root}
          >
            {@workspace.root}
          </p>
          <ul class="divide-y divide-line-soft">
            <li
              id="overview-workspace-to-vm"
              class="flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
            >
              <.icon name="hero-arrow-up-tray" class="size-4 shrink-0 text-faint" />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-medium text-ink">
                  to-vm <span class="font-normal text-faint">· yours, the VM reads it</span>
                </p>
                <p class="flex min-w-0 text-[10px] leading-4">
                  <.share_sync_state
                    id="overview-workspace-to-vm-state"
                    entry={@workspace.to_vm}
                    running?={@running?}
                    now={@now}
                  />
                </p>
                <p
                  :if={match?(%{status: %{error: error}} when is_binary(error), @workspace.to_vm)}
                  id="overview-workspace-to-vm-error"
                  class="text-[10px] leading-4 break-words text-bad"
                  title={@workspace.to_vm.status.error}
                >
                  {@workspace.to_vm.status.error}
                </p>
              </div>
            </li>
            <li
              :for={{held, index} <- Enum.with_index(@held)}
              id={"overview-workspace-held-#{index}"}
              class="flex items-center gap-3 bg-warn-soft/30 px-4 py-2 pl-11"
            >
              <div class="min-w-0 flex-1">
                <p class="truncate font-mono text-[11px] text-ink" title={held.path}>
                  {held.path}
                </p>
                <p class="text-[10px] leading-4 text-warn-strong">
                  Held back from the VM: it holds {held.why}.
                </p>
              </div>
              <button
                type="button"
                id={"overview-workspace-release-#{index}"}
                phx-click="release_held"
                phx-value-path={held.path}
                data-confirm={"Send #{held.path} to the VM as it is? The agent can then read what it holds."}
                class="inline-flex h-7 shrink-0 cursor-pointer items-center rounded-md border border-line bg-panel px-2.5 text-[11px] font-medium text-ink transition-all hover:border-warn/60 hover:text-warn-strong active:scale-[0.97]"
              >
                Send it to the VM
              </button>
            </li>
            <li
              id="overview-workspace-from-vm"
              class="flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
            >
              <.icon name="hero-arrow-down-tray" class="size-4 shrink-0 text-faint" />
              <div class="min-w-0 flex-1">
                <p class="text-xs font-medium text-ink">
                  from-vm
                  <span class="font-normal text-faint">· the VM's, copied here read-only</span>
                </p>
                <p class="flex min-w-0 text-[10px] leading-4">
                  <%= if @workspace.on? do %>
                    <.share_sync_state
                      id="overview-workspace-from-vm-state"
                      entry={@workspace.from_vm}
                      running?={@running?}
                      now={@now}
                    />
                  <% else %>
                    <span id="overview-workspace-from-vm-state" class="truncate text-faint">
                      Off: Workspace: write to your machine is off, so nothing comes here.
                    </span>
                  <% end %>
                </p>
                <p
                  :if={
                    @workspace.on? and
                      match?(%{status: %{error: error}} when is_binary(error), @workspace.from_vm)
                  }
                  id="overview-workspace-from-vm-error"
                  class="text-[10px] leading-4 break-words text-bad"
                  title={@workspace.from_vm.status.error}
                >
                  {@workspace.from_vm.status.error}
                </p>
              </div>
            </li>
          </ul>
      <% end %>
    </.card>
    """
  end

  attr :memory, :map, required: true
  attr :vm, :any, required: true

  # The VM's OptMem and the round trip with yours: the same two buttons as
  # in Settings, for the end of a session.
  defp memory_card(assigns) do
    ~H"""
    <.card id="overview-memory" title="Memory">
      <:help>
        The VM keeps its own OptMem, on its own disk. Syncing shows what it noted: what you tick joins yours, then yours is copied in.
      </:help>
      <:actions>
        <.link
          patch={~p"/tools/sandbox/settings"}
          class="text-[11px] text-accent hover:underline"
        >
          Settings
        </.link>
      </:actions>
      <%= if @memory.host? do %>
        <p id="overview-memory-state" class="text-xs leading-5 text-muted">
          <%= if @memory.seeded_at do %>
            Last copied from yours ({@memory.seed_count} memories) on {Calendar.strftime(
              @memory.seeded_at,
              "%b %-d"
            )}.
          <% else %>
            Its own, never copied from yours.
          <% end %>
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <.memory_sync_button id="overview-memory-sync" vm={@vm} />
        </div>
      <% else %>
        <p id="overview-memory-state" class="text-xs leading-5 text-muted">
          OptMem isn't installed on this machine.
        </p>
      <% end %>
    </.card>
    """
  end

  defp waiting_words(waiting) do
    asks = Enum.count(waiting, &(&1.kind == :activation))
    commands = Enum.count(waiting, &(&1.kind == :command))
    uses = length(waiting) - asks - commands

    "#{uses} #{if uses == 1, do: "use", else: "uses"} · #{asks} #{if asks == 1, do: "agent", else: "agents"} asking" <>
      if(commands > 0,
        do: " · #{commands} #{if commands == 1, do: "command", else: "commands"}",
        else: ""
      )
  end

  # Grants an agent proposed that you haven't reviewed yet.
  defp review_words(0), do: "None proposed to review"
  defp review_words(1), do: "1 proposed by an agent, to review"
  defp review_words(n), do: "#{n} proposed by agents, to review"
end
