defmodule MWTClientWeb.SandboxLive do
  @moduledoc """
  The agent sandbox control panel: the VM, the grants it can be given, the
  approvals it waits on, its activity and its settings, one page each behind
  a sidebar.

  The LiveView coordinates and the `MWTClientWeb.SandboxLive.*` modules draw.
  Everything comes from `MWTClient.Sandbox` and is redrawn from its
  broadcasts, so a decision made in one window shows in every other, and
  timers (grants running out, approvals giving up) show as they happen.
  Broadcasts arrive in bursts while the VM is busy, so redraws are coalesced
  to one every `@refresh_every` milliseconds.
  """
  use MWTClientWeb, :live_view

  @behaviour MWTClientWeb.Hooks.Places

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox

  alias MWTClient.Sandbox.{
    Decision,
    Event,
    Grant,
    HandoffRecords,
    Image,
    Handoffs,
    Instructions,
    Leftovers,
    Monitor,
    Presets,
    SavedRequest,
    Projects,
    RequestView,
    Resources,
    Shares,
    Slots
  }

  alias MWTClient.Places
  alias MWTClient.Tools

  alias MWTClientWeb.SandboxLive.{
    Activity,
    Approvals,
    Dialogs,
    Grants,
    Overview,
    ResourcePages,
    Settings,
    Setup
  }

  alias MWTClientWeb.SandboxLive.Firewall, as: FirewallPage
  alias MWTClientWeb.SandboxLive.Handoffs, as: HandoffsPage
  alias MWTClientWeb.SandboxLive.Projects, as: ProjectsPage

  @pages [
    {:overview, "Overview", "hero-squares-2x2", "/tools/sandbox"},
    {:approvals, "Approvals", "hero-hand-raised", "/tools/sandbox/approvals"},
    {:projects, "Projects", "hero-code-bracket-square", "/tools/sandbox/projects"},
    {:handoffs, "Handoffs", "hero-inbox-arrow-down", "/tools/sandbox/handoffs"},
    {:grants, "Grants", "hero-key", "/tools/sandbox/grants"},
    {:activity, "Activity log", "hero-signal", "/tools/sandbox/activity"},
    {:firewall, "Firewall", "hero-shield-check", "/tools/sandbox/firewall"},
    {:settings, "Settings", "hero-cog-6-tooth", "/tools/sandbox/settings"},
    {:setup, "Setup", "hero-rocket-launch", "/tools/sandbox/setup"}
  ]

  @refresh_every 150

  # The activity log's figures are read again at most this often
  # while activity comes in.
  @stats_every 1_000

  # Activity rows per page. Every event is in the journal; a page holds this
  # many in the DOM, and only the first page takes new ones in.
  @page_size 50
  # The activity page's windows, as far back as each reaches, in seconds;
  # nil reaches everything the journal keeps.
  @windows %{"hour" => 3_600, "day" => 86_400, "week" => 604_800, "all" => nil}

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Sandbox.subscribe(username)

    {:ok,
     socket
     |> assign(:page_title, "Agent Sandbox")
     |> assign(:tool, Tools.fetch!(:sandbox))
     |> assign(:username, username)
     |> assign(:refresh_timer, nil)
     |> assign(:durations, %{})
     |> assign(:modes, %{})
     |> assign(:adding, nil)
     |> assign(:resource_form, nil)
     |> assign(:resource_form_then, nil)
     |> assign(:grant_settings, nil)
     |> assign(:resource_settings, nil)
     |> assign(:grants_tab, "grants")
     |> assign(:resource, nil)
     |> assign(:grant_term, "")
     |> assign(:grant_filters, Grants.filters())
     |> assign(:resource_filters, ResourcePages.resource_filters())
     |> assign(:resource_page, 1)
     |> assign(:grant_page, 1)
     |> assign(:console_history, [])
     |> assign(:console_term, "")
     |> assign(:console_page, 1)
     |> assign(:console_open, nil)
     |> assign(:console_decisions, [])
     |> assign(:console_error, nil)
     |> assign(:console_running, nil)
     |> assign(:console_with, %{})
     # The Overview's terminal: the folder its next command starts in, and
     # the last run its screen was cleared after.
     |> assign(:terminal_cwd, "/work")
     |> assign(:terminal_since, 0)
     |> assign(:credentials, [])
     |> assign(:networks, [])
     |> assign(:locks, %{})
     |> assign(:confirm, nil)
     |> assign(:create_dialog, nil)
     |> assign(:memory_review, nil)
     |> assign(:name_error, nil)
     |> assign(:filters, %{
       q: "",
       group: "all",
       grant: "",
       thread: "",
       decided: "",
       window: "day"
     })
     |> assign(:activity_threads, [])
     |> assign(:activity, %{
       cursors: [],
       older?: false,
       shown: 0,
       oldest: nil,
       fresh: 0,
       running: %{}
     })
     |> assign(:activity_stats, nil)
     |> assign(:stats_timer, nil)
     |> assign(:settings_tab, "runtime")
     |> assign(:resources, resources())
     |> assign(:page_size, @page_size)
     |> assign(:share_form, to_form(%{"path" => ""}, as: :share))
     |> assign(:share_error, nil)
     |> assign(:handoff_id, nil)
     |> assign(:handoff_diff, false)
     |> assign(:handoff_place, HandoffsPage.place())
     |> assign(:handoff_listing, nil)
     |> assign(:handoff_view, nil)
     |> assign(:handoff_decision, "land")
     |> assign(:project_overview, %{open: [], shares?: false})
     |> assign(:project_editing, nil)
     |> assign(:project_dialog, nil)
     |> assign(:project_worktrees, %{})
     |> assign(:projects_timer, nil)
     |> assign(:leftovers, nil)
     |> assign(:monitor, if(connected?(socket), do: Monitor.snapshot(username)))
     |> assign(:monitor_by, :cpu)
     |> assign(:vm_errors, %{})
     |> assign(:focus, nil)
     |> assign(:firewall_view, nil)
     |> assign(:reading, nil)
     |> assign(:reading_open, false)
     |> assign(:reading_key, 0)
     |> assign(:firewall_drafts, %{})
     |> assign(:firewall_errors, %{})
     |> assign(:firewall_releasing, false)
     |> stream_configure(:events, dom_id: &"event-#{&1.id}")
     |> stream(:events, [])
     |> refresh()
     |> assign_vm_form()
     |> assign_layer_form()
     |> assign(layer_versions: [], layer_versions_open: false, layer_version: nil)
     |> assign(:image_pane, nil)
     |> assign_name_form()
     |> assign_host_form()
     |> assign_way_form()
     |> restore_place()}
  end

  @impl MWTClientWeb.Hooks.Places
  def place(socket),
    do:
      Map.take(socket.assigns, [
        :filters,
        :grant_term,
        :grant_filters,
        :resource_filters,
        :monitor_by,
        :terminal_cwd,
        :terminal_since
      ])

  # Back where it was left (`MWTClientWeb.Hooks.Places`). The page comes
  # back by its address; this is what the address doesn't say: the
  # activity filters, the grants list's search and filters, and how the
  # monitor sorts.
  defp restore_place(socket) do
    place = Places.recall(socket.assigns.username, :sandbox)

    socket
    |> update(:filters, &Map.merge(&1, Map.take(place[:filters] || %{}, Map.keys(&1))))
    |> assign(:grant_term, Map.get(place, :grant_term, ""))
    |> update(
      :grant_filters,
      &Map.merge(&1, Map.take(place[:grant_filters] || %{}, Map.keys(&1)))
    )
    |> update(
      :resource_filters,
      &Map.merge(&1, Map.take(place[:resource_filters] || %{}, Map.keys(&1)))
    )
    |> assign(:monitor_by, Map.get(place, :monitor_by, :cpu))
    |> assign(:terminal_cwd, kept_cwd(place[:terminal_cwd]))
    |> assign(:terminal_since, kept_since(place[:terminal_since]))
  end

  # The terminal's folder and what its screen was cleared after, as you
  # left them; anything else, where it starts.
  defp kept_cwd("/" <> _ = cwd), do: cwd
  defp kept_cwd(_other), do: "/work"

  defp kept_since(since) when is_integer(since) and since >= 0, do: since
  defp kept_since(_other), do: 0

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :page, socket.assigns.live_action)

    socket =
      case socket.assigns.live_action do
        :grant ->
          assign(socket, :grant_id, params["id"])

        :grants ->
          socket = assign(socket, :grants_tab, Grants.tab(params["tab"]))

          # All grants and On now, the tabs Grants replaced: the list,
          # showing every grant or what is on.
          socket =
            case params["tab"] do
              status when status in ["all", "on"] ->
                update(socket, :grant_filters, &%{&1 | status: status})

              _other ->
                socket
            end

          # Opened to try something as the VM: with the credential it names.
          case params["with"] do
            id when is_binary(id) -> update(socket, :console_with, &Map.put(&1, "with", id))
            _none -> socket
          end

        :resource ->
          assign(
            socket,
            :resource,
            MWTClient.Sandbox.Resource.from_path(params["kind"], params["id"])
          )

        :activity ->
          socket
          |> assign(:reading_open, false)
          |> group_from(params["group"])
          |> grant_from(params["grant"])
          |> thread_from(params["thread"])
          |> reset_events()
          |> load_stats()
          |> load_threads()

        :firewall ->
          # Its alert notification is seen.
          Sandbox.firewall_seen(socket.assigns.username)
          socket

        :approvals ->
          # A card a line of the activity log opened, as it was decided
          # (`MWTClient.Sandbox.Decision`), read-only.
          card_id = params["card"]

          kept =
            case is_binary(card_id) && Sandbox.audit_card(socket.assigns.username, card_id) do
              false -> nil
              nil -> :gone
              # Kept before it was kept with its choice.
              %MWTClient.Sandbox.Approval{} = card -> %{card: card, choice: nil}
              kept -> kept
            end

          assign(socket, focus: params["focus"], kept_card: kept)

        :handoffs ->
          id = handoff_id(params["id"])

          socket
          |> assign(handoff_id: id, handoff_diff: params["diff"] == "1")
          |> handoff_list_place(id, params["filter"])
          # Another handoff opens on landing it.
          |> then(
            &if(id != socket.assigns.handoff_id,
              do: assign(&1, :handoff_decision, "land"),
              else: &1
            )
          )

        :projects ->
          socket |> assign_overview() |> tick_projects()

        :setup ->
          assign(
            socket,
            :ssh_entry,
            MWTClient.Sandbox.Msb.ssh_entry(socket.assigns.username, Setup.ssh_host())
          )

        :settings ->
          assign(socket, settings_tab: Settings.tab(params["tab"]))

        _ ->
          socket
      end

    {:noreply, socket |> refresh() |> assign_handoff() |> page_title()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tool={@tool}
      notices={@notices}
      update={@update}
      sandbox_waiting={@sandbox_waiting}
      notifications={@notifications}
      places={@places}
    >
      <div class="flex min-h-0 flex-1 overflow-hidden">
        <.sidebar
          page={@page}
          vm={@vm}
          waiting={length(@waiting)}
          handoffs_open={Enum.count(@waiting_handoffs, &(&1.status == :open))}
          grants_on={Enum.count(@grants, &(&1.state == :on))}
          isolated={not is_nil(@firewall.isolated)}
          proxy={@proxy}
          image={@image}
          setup_done={Setup.done?(@vm, @image, @settings)}
          now={@now}
        />

        <div id="sandbox-page" data-keep-scroll class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-6xl px-6 py-6 lg:px-8">
            <FirewallPage.banner :if={@page != :firewall} firewall={@firewall} />
            <%= case @page do %>
              <% :overview -> %>
                <Overview.page
                  vm={@vm}
                  image={@image}
                  created_ref={@created_ref}
                  proxy={@proxy}
                  tools={@tools}
                  settings={@settings}
                  memory={@memory}
                  grants={@grants}
                  credentials={@credentials}
                  networks={@networks}
                  locks={@locks}
                  waiting={@waiting}
                  recent={@recent}
                  stats={@stats}
                  ports={@ports}
                  monitor={@monitor}
                  monitor_by={@monitor_by}
                  sync={@sync}
                  workspace={@workspace}
                  now={@now}
                  terminal={
                    %{
                      history: @console_history,
                      since: @terminal_since,
                      running: @console_running,
                      cwd: @terminal_cwd,
                      error: @console_error,
                      vm_running: match?({:ok, _}, MWTClient.Sandbox.Projects.guest(@username, @vm))
                    }
                  }
                />
              <% :approvals -> %>
                <Approvals.page
                  waiting={@waiting}
                  running={@running}
                  history={@history}
                  grants={@grant_map}
                  credentials={@credentials}
                  networks={@networks}
                  marks={@marks}
                  now={@now}
                  focus={@focus}
                  kept_card={assigns[:kept_card]}
                />
              <% :grants -> %>
                <Grants.page
                  tab={@grants_tab}
                  grants={@grants}
                  credentials={@credentials}
                  networks={@networks}
                  locks={@locks}
                  durations={@durations}
                  modes={@modes}
                  now={@now}
                  term={@grant_term}
                  filters={@grant_filters}
                  page={@grant_page}
                  resource_filters={@resource_filters}
                  resource_page={@resource_page}
                  console={
                    %{
                      history: @console_history,
                      term: @console_term,
                      page: @console_page,
                      open: @console_open,
                      decisions: @console_decisions,
                      error: @console_error,
                      now: @now,
                      running: @console_running,
                      vm_running: match?({:ok, _}, MWTClient.Sandbox.Projects.guest(@username, @vm)),
                      with: @console_with,
                      waiting: @waiting
                    }
                  }
                />
              <% :grant -> %>
                <%= if @grant do %>
                  <Grants.detail
                    grant={@grant}
                    has_value={@values[@grant.id]}
                    value_form={@value_form}
                    events={@grant_events}
                    duration={Grants.row_duration(@grant, @durations, @now)}
                    mode={Grants.row_mode(@grant, @modes, @now)}
                    now={@now}
                    grants={@grants}
                    credentials={@credentials}
                    networks={@networks}
                    locks={@locks}
                    credential_values={@credential_values}
                    settings={@grant_settings}
                  />
                <% else %>
                  <div id="grant-missing" class="rounded-xl border border-dashed border-line">
                    <.empty icon="hero-key">
                      That grant doesn't exist any more.
                      <.link
                        patch={~p"/tools/sandbox/grants"}
                        class="text-accent hover:underline"
                      >See all grants</.link>
                    </.empty>
                  </div>
                <% end %>
              <% :resource -> %>
                <ResourcePages.page
                  resource={@resource}
                  grants={@grants}
                  credentials={@credentials}
                  networks={@networks}
                  locks={@locks}
                  credential_values={@credential_values}
                  value_form={to_form(%{"value" => ""}, as: :value)}
                  durations={@durations}
                  modes={@modes}
                  now={@now}
                  settings={@resource_settings}
                />
              <% :activity -> %>
                <Activity.page
                  streams={@streams}
                  filters={@filters}
                  activity={@activity}
                  stats={@activity_stats}
                  page_size={@page_size}
                  grants={@grants}
                  reading={@reading}
                  reading_open={@reading_open}
                  reading_key={@reading_key}
                  threads={@activity_threads}
                  grant_names={Map.new(@grants, &{&1.id, &1.name})}
                  now={@now}
                />
              <% :firewall -> %>
                <FirewallPage.page
                  :if={@firewall_view}
                  view={@firewall_view}
                  drafts={@firewall_drafts}
                  errors={@firewall_errors}
                  releasing={@firewall_releasing}
                  vm={@vm}
                  now={@now}
                />
              <% :settings -> %>
                <Settings.page
                  tab={@settings_tab}
                  vm={@vm}
                  image={@image}
                  builds={@builds}
                  created_ref={@created_ref}
                  memory={@memory}
                  name_form={@name_form}
                  name_error={@name_error}
                  tools={@tools}
                  settings={@settings}
                  layer_form={@layer_form}
                  layer_error={@layer_error}
                  layer_versions={@layer_versions}
                  layer_versions_open={@layer_versions_open}
                  layer_version={@layer_version}
                  image_pane={@image_pane}
                  vm_form={@vm_form}
                  vm_errors={@vm_errors}
                  resources={@resources}
                  share_form={@share_form}
                  share_error={@share_error}
                  sync={@sync}
                  host={@host}
                  host_form={@host_form}
                  host_error={@host_error}
                  way_form={@way_form}
                  way_error={@way_error}
                />
              <% :handoffs -> %>
                <HandoffsPage.page
                  place={@handoff_place}
                  listing={@handoff_listing}
                  view={@handoff_view}
                  diff={@handoff_diff}
                  decision={@handoff_decision}
                  vm={@vm}
                  now={@now}
                />
              <% :projects -> %>
                <ProjectsPage.page
                  overview={@project_overview}
                  mirror={@mirror}
                  waiting_handoffs={@waiting_handoffs}
                  editing={@project_editing}
                  dialog={@project_dialog}
                  worktrees={@project_worktrees}
                  ports={@ports}
                  leftovers={@leftovers}
                  vm={@vm}
                  now={@now}
                />
              <% :setup -> %>
                <Setup.page
                  vm={@vm}
                  image={@image}
                  settings={@settings}
                  tools={@tools}
                  ssh_entry={@ssh_entry}
                />
            <% end %>
          </div>
        </div>
      </div>

      <ResourcePages.form_dialog :if={@resource_form} form_state={@resource_form} />
      <Grants.add_dialog
        :if={@adding}
        adding={@adding}
        waiting={@waiting}
        grants={@grants}
        credentials={@credentials}
        networks={@networks}
        mints={Sandbox.credential_endpoints(@username)}
        presets={MWTClient.Sandbox.Presets.presets(@username)}
      />
      <.confirm_dialog :if={@confirm} confirm={@confirm} />
      <Dialogs.create
        :if={@create_dialog}
        mode={@create_dialog}
        vm={@vm}
        image={@image}
        snapshots={@snapshots}
        memory={@memory}
        created_ref={@created_ref}
      />
      <Dialogs.memory_review :if={@memory_review} review={@memory_review} />
    </Layouts.app>
    """
  end

  ## Sidebar

  attr :page, :atom, required: true
  attr :vm, :any, required: true
  attr :waiting, :integer, required: true
  attr :handoffs_open, :integer, required: true
  attr :grants_on, :integer, required: true
  attr :isolated, :boolean, default: false
  attr :proxy, :map, required: true
  attr :image, :map, required: true
  attr :setup_done, :boolean, required: true
  attr :now, DateTime, required: true

  defp sidebar(assigns) do
    assigns = assign(assigns, pages: @pages)

    ~H"""
    <aside
      id="sandbox-nav"
      class="flex w-56 shrink-0 flex-col border-r border-line-soft bg-panel"
    >
      <div class="border-b border-line-soft px-3 py-3">
        <div class="flex items-center gap-2.5">
          <span class={[
            "flex size-8 shrink-0 items-center justify-center rounded-lg border transition-colors",
            if(@vm.status == :running,
              do: "border-ok/35 bg-ok-soft/50 text-ok-strong",
              else: "border-line bg-deep text-muted"
            )
          ]}>
            <.icon name="hero-cube-transparent" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] font-semibold text-ink">{@vm.name}</p>
            <.vm_status vm={@vm} id="sidebar-vm-status" />
          </div>
          <button
            :if={@vm.status in [:stopped, :crashed] and is_nil(@vm.busy) and @image.loaded?}
            type="button"
            id="sidebar-vm-start"
            phx-click="start_vm"
            title="Start the VM"
            class="flex size-7 cursor-pointer items-center justify-center rounded-md text-ok transition-colors hover:bg-ok-soft/50"
          >
            <.icon name="hero-play-solid" class="size-3.5" />
          </button>
          <button
            :if={@vm.status == :running and is_nil(@vm.busy)}
            type="button"
            id="sidebar-vm-stop"
            phx-click="stop_vm"
            title="Stop the VM"
            class="flex size-7 cursor-pointer items-center justify-center rounded-md text-muted transition-colors hover:bg-hover hover:text-bad"
          >
            <.icon name="hero-stop-solid" class="size-3.5" />
          </button>
        </div>
        <p
          :if={@vm.stale?}
          class="mt-2 flex items-center gap-1.5 rounded-md bg-warn-soft/40 px-2 py-1 text-[10px] font-medium text-warn-strong"
        >
          <.icon name="hero-arrow-path-micro" class="size-3" /> Recreate to apply settings
        </p>
      </div>

      <nav aria-label="Agent sandbox" class="flex flex-col gap-0.5 p-2">
        <.link
          :for={{id, label, icon, path} <- @pages}
          patch={path}
          id={"sandbox-nav-#{id}"}
          aria-current={nav_current?(@page, id) && "page"}
          class={[
            "group flex h-8 items-center gap-2.5 rounded-md px-2.5 text-[13px] transition-colors",
            if(nav_current?(@page, id),
              do: "bg-active font-medium text-ink",
              else: "text-muted hover:bg-hover hover:text-ink"
            )
          ]}
        >
          <.icon
            name={icon}
            class={[
              "size-4 transition-colors",
              if(nav_current?(@page, id),
                do: "text-accent",
                else: "text-faint group-hover:text-muted"
              )
            ]}
          />
          <span class="flex-1">{label}</span>
          <span
            :if={id == :approvals and @waiting > 0}
            id="sandbox-nav-waiting"
            class="rounded-full bg-warn px-1.5 py-px text-[10px] font-bold tabular-nums text-deep"
          >
            {@waiting}
          </span>
          <span
            :if={id == :handoffs and @handoffs_open > 0}
            id="sandbox-nav-handoffs-open"
            class="rounded-full bg-accent-soft px-1.5 py-px text-[10px] font-semibold tabular-nums text-accent-strong"
          >
            {@handoffs_open}
          </span>
          <span
            :if={id == :grants and @grants_on > 0}
            class="rounded-full bg-ok-soft px-1.5 py-px text-[10px] font-semibold tabular-nums text-ok-strong"
          >
            {@grants_on} on
          </span>
          <span
            :if={id == :firewall and @isolated}
            id="sandbox-nav-isolated"
            title="The VM is isolated"
            class="rounded-full bg-bad px-1.5 py-px text-[10px] font-bold text-white"
          >
            Isolated
          </span>
          <span
            :if={id == :setup and not @setup_done}
            id="sandbox-nav-setup-todo"
            title="Some setup steps are left"
            class="size-1.5 rounded-full bg-accent"
          ></span>
        </.link>
      </nav>

      <div class="flex-1"></div>

      <div
        id="sandbox-health"
        class="m-2 space-y-1.5 rounded-lg border border-line-soft bg-deep/40 p-2.5"
      >
        <p class="flex items-center gap-1.5 text-[11px]">
          <span class={[
            "size-1.5 shrink-0 rounded-full",
            if(@proxy.listening?, do: "bg-ok", else: "bg-bad")
          ]}></span>
          <span class="text-muted">Proxy</span>
          <span class="ml-auto font-mono text-[10px] text-faint">
            {if @proxy.listening?, do: "listening", else: "down"}
          </span>
        </p>
        <p :if={@proxy.error} class="text-[10px] leading-4 text-bad">{@proxy.error}</p>
        <p class="flex items-center gap-1.5 text-[11px]">
          <span class={[
            "size-1.5 shrink-0 rounded-full",
            cond do
              @image.building? -> "bg-warn motion-safe:animate-pulse"
              @image.loaded? -> "bg-ok"
              true -> "bg-faint"
            end
          ]}></span>
          <span class="text-muted">Image</span>
          <span class="ml-auto truncate font-mono text-[10px] text-faint" title={@image.tag}>
            <%= cond do %>
              <% @image.building? -> %>
                building…
              <% @image.loaded? -> %>
                {@image.tag |> String.split(":") |> List.last()}
              <% true -> %>
                not built
            <% end %>
          </span>
        </p>
      </div>
    </aside>
    """
  end

  defp nav_current?(:grant, :grants), do: true
  defp nav_current?(:resource, :grants), do: true
  defp nav_current?(page, id), do: page == id

  ## Confirm

  attr :confirm, :map, required: true

  defp confirm_dialog(assigns) do
    ~H"""
    <div
      id="sandbox-confirm"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="sandbox-confirm-title"
      phx-window-keydown="cancel_confirm"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_confirm"></div>
      <div class="relative w-full max-w-sm rounded-xl border border-line bg-panel p-4 shadow-2xl shadow-black/30 dark:shadow-black/60">
        <div class="flex items-start gap-2.5">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-bad/40 bg-bad-soft/40">
            <.icon name="hero-exclamation-triangle" class="size-4 text-bad" />
          </span>
          <div class="min-w-0">
            <p id="sandbox-confirm-title" class="text-[13px] font-semibold text-ink">
              {@confirm.title}
            </p>
            <p class="mt-1 text-[11px] leading-relaxed text-muted">{@confirm.message}</p>
          </div>
        </div>
        <div class="mt-4 flex items-center justify-end gap-2">
          <.button type="button" id="sandbox-confirm-cancel" phx-click="cancel_confirm">Cancel</.button>
          <.button
            type="button"
            id="sandbox-confirm-accept"
            variant="danger"
            phx-click="accept_confirm"
            phx-mounted={JS.focus()}
          >
            {@confirm.label}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  ## Events

  @impl true
  # Starting a VM that exists goes straight through; creating one first asks
  # what happens to what it keeps.
  def handle_event("start_vm", _params, socket) do
    cond do
      not socket.assigns.image.loaded? ->
        vm_action(socket, &Sandbox.start_vm/1)

      socket.assigns.vm.exists? and not socket.assigns.vm.stale? ->
        vm_action(socket, &Sandbox.start_vm/1)

      socket.assigns.vm.exists? ->
        {:noreply, assign(socket, :create_dialog, :recreate)}

      true ->
        {:noreply, assign(socket, :create_dialog, :create)}
    end
  end

  def handle_event("stop_vm", _params, socket), do: vm_action(socket, &Sandbox.stop_vm/1)

  def handle_event("recreate_vm", _params, socket) do
    if socket.assigns.image.loaded?,
      do: {:noreply, assign(socket, :create_dialog, :recreate)},
      else: vm_action(socket, &Sandbox.recreate_vm/1)
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_dialog, nil)}

  def handle_event("confirm_create", params, socket) do
    choices = Map.get(params, "create", %{})

    options = %{
      home:
        case choices["home"] do
          "empty" -> :empty
          "snapshot:" <> id -> {:snapshot, id}
          _keep -> :keep
        end,
      cache: if(choices["cache"] == "clear", do: :clear, else: :keep),
      seed_memory: choices["seed_memory"] == "true"
    }

    fun =
      if socket.assigns.create_dialog == :recreate,
        do: &Sandbox.recreate_vm(&1, options),
        else: &Sandbox.start_vm(&1, options)

    vm_action(assign(socket, :create_dialog, nil), fun)
  end

  def handle_event("use_build", %{"ref" => ref}, socket) do
    case Sandbox.use_build(socket.assigns.username, ref) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> put_notice(:success, "#{ref} is current",
           body:
             "Recreate the VM to run it. Its Home from that time is offered if a copy was kept."
         )}

      {:error, :busy} ->
        {:noreply, put_notice(socket, :info, "Wait for the build to finish")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh() |> put_notice(:warning, "That build is gone")}
    end
  end

  def handle_event("save_image_name", %{"image_name" => %{"name" => name}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"image_name" => name}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:name_error, nil)
         |> refresh()
         |> assign_name_form()
         |> put_notice(:success, "Image name saved", body: "The next build uses it.")}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           name_form: to_form(%{"name" => name}, as: :image_name),
           name_error: errors[:image_name]
         )}
    end
  end

  def handle_event("review_memories", _params, socket) do
    case Sandbox.vm_memories(socket.assigns.username) do
      {:ok, %{entries: entries, upto: upto, more: more, size: size}} ->
        review = %{
          entries: entries,
          upto: upto,
          more: more,
          size: size,
          texts: %{},
          errors: %{}
        }

        {:noreply, assign(socket, :memory_review, review)}

      {:error, :not_running} ->
        {:noreply,
         put_notice(socket, :info, "Start the VM first",
           body: "Its memory is on its own disk, reached through the VM while it runs."
         )}

      {:error, message} ->
        {:noreply,
         put_notice(socket, :warning, "The VM's memory couldn't be read", body: message)}
    end
  end

  def handle_event("close_review", _params, socket),
    do: {:noreply, assign(socket, :memory_review, nil)}

  def handle_event("dismiss_memories", _params, socket) do
    :ok = Sandbox.dismiss_memories(socket.assigns.username, socket.assigns.memory_review.upto)
    {:noreply, socket |> assign(:memory_review, nil) |> refresh()}
  end

  def handle_event("bring_back", params, socket) do
    review = socket.assigns.memory_review
    choices = Map.get(params, "review", %{})
    texts = Map.get(choices, "text", %{})
    # Copying yours in sets aside what the VM noted, so not while some of it
    # wasn't shown.
    sync? = params["then"] == "sync" and review.more == 0

    picked =
      for index <- Map.get(choices, "pick", []),
          {index, ""} <- [Integer.parse(index)],
          entry = Enum.find(review.entries, &(&1.index == index)),
          do: {entry, String.trim(texts[to_string(index)] || "[vm] " <> entry.text)}

    cond do
      picked == [] and sync? ->
        {:noreply, copy_memory_in(socket, review, 0)}

      picked == [] ->
        {:noreply, put_notice(socket, :info, "Tick the memories to add first")}

      true ->
        bring_back(socket, review, picked, sync?)
    end
  end

  def handle_event("pick_duration", %{"id" => id, "minutes" => minutes}, socket) do
    {:noreply, update(socket, :durations, &Map.put(&1, id, parse_duration(minutes)))}
  end

  # How a grant's uses are approved once on: each time (the default), or
  # auto-approved while it stays on.
  def handle_event("pick_mode", %{"id" => id, "mode" => mode}, socket)
      when mode in ["ask", "all"] do
    {:noreply, update(socket, :modes, &Map.put(&1, id, mode))}
  end

  # A grant that is on, changed there and then: a new duration, counted
  # from now, or another approval mode. It stays on.
  def handle_event("set_duration", %{"id" => id, "minutes" => minutes}, socket) do
    minutes = minutes |> parse_duration() |> to_minutes()

    socket =
      case Sandbox.set_duration(socket.assigns.username, id, minutes) do
        {:ok, _grant} -> socket
        {:error, _off} -> put_notice(socket, :info, "It is off already")
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("set_mode", %{"id" => id, "mode" => mode}, socket)
      when mode in ["ask", "all"] do
    socket =
      case Sandbox.set_mode(socket.assigns.username, id, String.to_existing_atom(mode)) do
        {:ok, _grant} ->
          socket

        {:error, _off} ->
          put_notice(socket, :info, "It is off already")
      end

    {:noreply, refresh(socket)}
  end

  # The state a grant is in when MWT starts; it goes to that state now too.
  def handle_event("set_start", %{"id" => id, "start" => start}, socket)
      when start in ["disabled", "off", "on", "auto"] do
    socket =
      case Sandbox.set_start(socket.assigns.username, id, String.to_existing_atom(start)) do
        {:ok, _grant} ->
          socket

        {:error, :to_review} ->
          put_notice(socket, :info, "Review it first",
            body: "An agent proposed it: it starts off until you accept it."
          )

        {:error, :not_found} ->
          put_notice(socket, :info, "It was removed")
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("turn_on", %{"id" => id}, socket) do
    minutes = socket.assigns.durations |> duration(id) |> to_minutes()

    uses =
      case Map.get(socket.assigns.modes, id) do
        "all" -> :all
        "ask" -> :ask
        nil -> socket.assigns.grants |> Enum.find(&(&1.id == id)) |> default_uses()
      end

    socket =
      case Sandbox.turn_on(socket.assigns.username, id, minutes, uses) do
        {:ok, _grant} ->
          socket

        {:error, :to_review} ->
          put_notice(socket, :info, "Review it first",
            body: "An agent proposed it. Accept it on its page, then it can turn on."
          )

        {:error, refusal} ->
          turn_on_notice(socket, refusal)
      end

    {:noreply, socket |> update(:modes, &Map.delete(&1, id)) |> refresh()}
  end

  # A grant an agent proposed, accepted on its page: enabled for as long as
  # the agent asked, every use asking, or kept off.
  def handle_event("review_grant", %{"id" => id, "enable" => enable} = params, socket) do
    enable =
      case Integer.parse(enable) do
        {minutes, ""} when minutes in 1..1440 -> {minutes, :ask}
        _keep_off -> :keep_off
      end

    socket =
      case Sandbox.review(socket.assigns.username, id, enable, params["revision"]) do
        {:ok, grant} ->
          put_notice(
            socket,
            :success,
            if(enable == :keep_off,
              do: "#{grant.name} accepted",
              else: "#{grant.name} accepted and on"
            ),
            body:
              if(enable == :keep_off,
                do: "It is yours now, off: turn it on when a task needs it.",
                else: "It is yours now. The agent that proposed it hears it is on."
              )
          )

        {:error, :changed} ->
          put_notice(socket, :error, "The agent changed this proposal as you read it",
            body: "Nothing was accepted. Read it again as it is now, then accept it."
          )

        {:error, refusal} when refusal in [:no_value, :resource_to_review] ->
          turn_on_notice(socket, refusal)

        {:error, _reason} ->
          socket
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("turn_off", %{"id" => id}, socket) do
    {:ok, _grant} = Sandbox.turn_off(socket.assigns.username, id)
    {:noreply, refresh(socket)}
  end

  # Try it as the VM: one command at a time, run in the VM from here. Each
  # run goes into the console's history (`Sandbox.console_runs/1`), kept by
  # the server, so it is there when you come back; the newest opens, with
  # what MWT decided while it ran.
  def handle_event("console_change", %{"console" => params}, socket),
    do: {:noreply, assign(socket, console_with: params, console_error: nil)}

  # Stopped from here: the run ends where MWT waits for it, and is kept as
  # stopped; what it started in the VM may finish there.
  def handle_event("console_stop", _params, socket) do
    socket = cancel_async(socket, :console)

    socket =
      case socket.assigns.console_running do
        %{command: command, credential: credential, started_at: started_at} = running ->
          {:ok, run} =
            Sandbox.console_stopped(
              socket.assigns.username,
              command,
              credential,
              started_at,
              Map.get(running, :dir)
            )

          socket |> assign(console_term: "", console_page: 1) |> open_console_run(run.id)

        nil ->
          socket
      end

    {:noreply, assign(socket, :console_running, nil)}
  end

  def handle_event("console_run", %{"console" => params}, socket),
    do: {:noreply, run_console(socket, params)}

  # The Overview's terminal: a line typed, run where the last one ended;
  # `clear` clears its screen, as Ctrl+L does, and runs nothing.
  def handle_event("terminal_run", %{"command" => command}, socket) when is_binary(command) do
    case String.trim(command) do
      "clear" ->
        handle_event("terminal_clear", %{}, socket)

      _other ->
        {:noreply, start_console(socket, command, nil, socket.assigns.terminal_cwd, :terminal)}
    end
  end

  def handle_event("terminal_clear", _params, socket) do
    socket = load_console_runs(socket)
    last = Enum.reduce(socket.assigns.console_history, 0, &max(&1.id, &2))
    {:noreply, assign(socket, terminal_since: last, console_error: nil)}
  end

  # Run again: as it ran, the form showing it.
  def handle_event("console_again", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.console_history, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      run ->
        params = %{"mode" => "command", "command" => run.command, "with" => run.credential || ""}
        {:noreply, run_console(socket, params)}
    end
  end

  def handle_event("console_open", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {id, ""} when id == socket.assigns.console_open ->
        {:noreply, assign(socket, console_open: nil, console_decisions: [])}

      {id, ""} ->
        {:noreply, open_console_run(socket, id)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("console_search", %{"term" => term}, socket),
    do: {:noreply, assign(socket, console_term: term, console_page: 1)}

  def handle_event("console_page", %{"page" => page}, socket) do
    case page_asked(page) do
      nil -> {:noreply, socket}
      number -> {:noreply, assign(socket, :console_page, number)}
    end
  end

  def handle_event("console_clear", _params, socket) do
    :ok = Sandbox.clear_console_runs(socket.assigns.username)

    {:noreply,
     socket
     |> assign(console_open: nil, console_decisions: [], console_term: "", console_page: 1)
     |> load_console_runs()}
  end

  # Locking a resource stops every use of it, whatever its grants say;
  # unlocking ends that. Only you do either.
  def handle_event(event, %{"kind" => kind} = params, socket)
      when event in ["lock_resource", "unlock_resource"] and
             kind in ["credential", "network", "machine", "mwt"] do
    resource = MWTClient.Sandbox.Resource.from_path(kind, params["id"])

    _ =
      if event == "lock_resource",
        do: Sandbox.lock(socket.assigns.username, resource),
        else: Sandbox.unlock(socket.assigns.username, resource)

    {:noreply, refresh(socket)}
  end

  # Resources, added and edited from their dialog
  # (`MWTClientWeb.SandboxLive.ResourcePages`).
  def handle_event("open_resource_form", %{"kind" => kind}, socket)
      when kind in ["credential", "network"] do
    kind = String.to_existing_atom(kind)

    # Opened from the add-grant dialog too: the resource comes first, so
    # that dialog gives way, and comes back over the new resource once it
    # is added, still answering the ask it was opened from.
    then_grant =
      case socket.assigns[:adding] do
        %{editing: id} when is_binary(id) -> nil
        %{} = adding -> %{approval_id: adding[:approval_id]}
        nil -> nil
      end

    {:noreply,
     socket
     |> assign(:adding, nil)
     |> assign(:resource_form, %{
       kind: kind,
       editing: nil,
       form: to_form(ResourcePages.form_fields(kind), as: :resource),
       errors: %{},
       presets: Presets.making(kind, socket.assigns.username),
       preset: nil,
       step: if(Presets.making(kind, socket.assigns.username) == [], do: :form, else: :pick),
       then_grant: then_grant
     })}
  end

  # A preset the new resource starts from, or none ("by hand"): it fills
  # the form, and its blanks wait to be filled.
  def handle_event("pick_resource_preset", params, socket) do
    form_state = socket.assigns.resource_form

    preset =
      Enum.find(Map.get(form_state, :presets, []), &(&1.id == params["preset"]))

    fields =
      case preset do
        nil ->
          ResourcePages.form_fields(form_state.kind)

        preset ->
          Map.merge(ResourcePages.form_fields(form_state.kind), preset.fields)
          |> Map.merge(%{"name" => preset.name, "preset" => preset.id})
      end

    {:noreply,
     assign(
       socket,
       :resource_form,
       Map.merge(form_state, %{
         form: to_form(fields, as: :resource),
         errors: %{},
         preset: preset,
         step: :form
       })
     )}
  end

  def handle_event("resource_preset_back", _params, socket),
    do: {:noreply, update(socket, :resource_form, &Map.put(&1, :step, :pick))}

  def handle_event("edit_resource", %{"kind" => kind, "id" => id}, socket)
      when kind in ["credential", "network"] do
    found =
      case kind do
        "credential" -> Enum.find(socket.assigns.credentials, &(&1.id == id))
        "network" -> Enum.find(socket.assigns.networks, &(&1.id == id))
      end

    case found do
      nil ->
        {:noreply, put_notice(socket, :info, "It was removed")}

      found ->
        {:noreply,
         assign(socket, :resource_form, %{
           kind: String.to_existing_atom(kind),
           editing: id,
           form: to_form(ResourcePages.form_fields(found), as: :resource),
           errors: %{},
           presets: [],
           preset: nil
         })}
    end
  end

  def handle_event("validate_resource", %{"resource" => params}, socket) do
    {:noreply, update(socket, :resource_form, &%{&1 | form: to_form(params, as: :resource)})}
  end

  def handle_event("close_resource_form", _params, socket),
    do: {:noreply, assign(socket, :resource_form, nil)}

  def handle_event("save_resource", %{"resource" => params}, socket) do
    %{kind: kind, editing: editing} = socket.assigns.resource_form
    username = socket.assigns.username

    socket =
      assign(socket, :resource_form_then, Map.get(socket.assigns.resource_form, :then_grant))

    result =
      if editing,
        do: Sandbox.update_resource(username, {kind, editing}, params),
        else: Sandbox.create_resource(username, kind, params)

    case result do
      {:ok, resource} ->
        socket =
          socket
          |> assign(:resource_form, nil)
          |> put_notice(:success, "#{resource.name} #{if(editing, do: "saved", else: "added")}")

        case socket.assigns.resource_form_then do
          # Added from the add-grant dialog: back to it, over the new one.
          %{approval_id: approval_id} ->
            socket =
              socket
              |> assign(:resource_form_then, nil)
              |> refresh()
              |> assign(:adding, %{step: :pick, approval_id: approval_id})

            handle_event(
              "pick_over",
              %{"kind" => Atom.to_string(kind), "id" => resource.id},
              socket
            )

          nil ->
            {:noreply,
             push_navigate(socket, to: MWTClient.Sandbox.Resource.path({kind, resource.id}))}
        end

      {:error, errors} when is_map(errors) ->
        {:noreply,
         update(
           socket,
           :resource_form,
           &%{&1 | form: to_form(params, as: :resource), errors: errors}
         )}

      {:error, _reason} ->
        {:noreply, socket |> assign(:resource_form, nil) |> put_notice(:info, "It was removed")}
    end
  end

  # A resource's settings on its page: changed in place, kept once saved.
  def handle_event("resource_settings_change", %{"resource" => params}, socket) do
    {:noreply,
     update(socket, :resource_settings, fn settings ->
       %{settings | form: to_form(params, as: :resource), dirty: true}
     end)}
  end

  def handle_event("resource_settings_cancel", _params, socket),
    do: {:noreply, socket |> assign(:resource_settings, nil) |> resource_settings()}

  def handle_event("resource_settings_save", %{"resource" => params}, socket) do
    case Sandbox.update_resource(socket.assigns.username, socket.assigns.resource, params) do
      {:ok, resource} ->
        {:noreply,
         socket
         |> put_notice(:success, "#{resource.name} saved")
         |> assign(:resource_settings, nil)
         |> refresh()}

      {:error, %{} = errors} ->
        {:noreply,
         update(
           socket,
           :resource_settings,
           &%{&1 | form: to_form(params, as: :resource), errors: errors}
         )}

      {:error, _gone} ->
        {:noreply, socket |> put_notice(:info, "It can't be changed") |> refresh()}
    end
  end

  # A resource an agent proposed, accepted on its page as it showed it.
  def handle_event("accept_resource", %{"kind" => kind, "id" => id} = params, socket)
      when kind in ["credential", "network"] do
    resource = MWTClient.Sandbox.Resource.from_path(kind, id)

    case Sandbox.review_resource(socket.assigns.username, resource, params["revision"]) do
      {:ok, accepted} ->
        {:noreply,
         socket
         |> put_notice(:success, "#{accepted.name} is yours now",
           body:
             if(match?(%MWTClient.Sandbox.Credential{source: :stored}, accepted),
               do: "Paste its value when you have it: until then every use of it is refused.",
               else: "The agent that proposed it hears so. Grants over it give its uses."
             )
         )
         |> refresh()}

      {:error, :changed} ->
        {:noreply,
         socket
         |> put_notice(:error, "The agent changed this proposal as you read it",
           body: "Read it again before you accept it."
         )
         |> refresh()}

      {:error, _gone} ->
        {:noreply, socket |> put_notice(:info, "That was already settled") |> refresh()}
    end
  end

  # Declined on its page: its card's answer, or, the card gone, removed.
  def handle_event("decline_resource", %{"kind" => kind, "id" => id}, socket)
      when kind in ["credential", "network"] do
    resource = MWTClient.Sandbox.Resource.from_path(kind, id)
    username = socket.assigns.username

    case Enum.find(socket.assigns.waiting, &(&1.resource == resource)) do
      nil -> Sandbox.delete_resource(username, resource)
      ask -> Sandbox.decide(username, ask.id, :decline)
    end

    {:noreply,
     socket
     |> put_notice(:info, "Declined and removed")
     |> push_navigate(to: ~p"/tools/sandbox/grants?tab=resources")}
  end

  def handle_event("confirm_delete_resource", %{"kind" => kind, "id" => id}, socket)
      when kind in ["credential", "network"] do
    resource = MWTClient.Sandbox.Resource.from_path(kind, id)

    name =
      MWTClient.Sandbox.Resource.name(
        resource,
        socket.assigns.credentials,
        socket.assigns.networks
      )

    over = length(MWTClient.Sandbox.Resource.grants(socket.assigns.grants, resource))

    {:noreply,
     assign(socket, :confirm, %{
       title: "Remove #{name}?",
       message:
         "Every grant over it goes with it" <>
           case over do
             0 -> ""
             1 -> " (1 grant)"
             n -> " (#{n} grants)"
           end <>
           if(kind == "credential",
             do:
               ", and its value is forgotten. The VM keeps placeholders that no longer mean anything.",
             else: "."
           ),
       label: "Remove",
       action: {:delete_resource, resource}
     })}
  end

  def handle_event("set_credential_value", %{"value" => %{"credential" => id} = params}, socket) do
    case Sandbox.set_credential_value(socket.assigns.username, id, params["value"] || "") do
      :ok -> {:noreply, socket |> put_notice(:success, "Value saved") |> refresh()}
      {:error, :minted} -> {:noreply, put_notice(socket, :info, "Its value is minted")}
      {:error, :empty} -> {:noreply, put_notice(socket, :info, "Paste a value first")}
      {:error, _reason} -> {:noreply, refresh(socket)}
    end
  end

  # A network's host limits, from its page.
  def handle_event("limits_default", %{"network" => id, "default" => default}, socket)
      when default in ["reachable", "blocked"],
      do: limits_set(socket, id, {:default, String.to_existing_atom(default)})

  def handle_event("limits_add", %{"limit" => limit}, socket),
    do:
      limits_set(
        socket,
        limit["network"],
        {:put, limit["host"] || "", limit["blocked"] == "true"}
      )

  def handle_event(
        "limits_put",
        %{"network" => id, "host" => host, "blocked" => blocked},
        socket
      ),
      do: limits_set(socket, id, {:put, host, blocked == "true"})

  def handle_event("limits_remove", %{"network" => id, "host" => host}, socket),
    do: limits_set(socket, id, {:remove, host})

  def handle_event("allow_all", %{"id" => id, "minutes" => minutes}, socket) do
    socket =
      case Sandbox.allow_all(socket.assigns.username, id, allow_minutes(minutes)) do
        {:ok, _grant} -> socket
        {:error, :off} -> put_notice(socket, :info, "Turn the grant on first")
        {:error, :not_found} -> socket
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("revoke_allowance", %{"id" => id, "allowance" => allowance}, socket) do
    {:ok, _grant} = Sandbox.revoke_allowance(socket.assigns.username, id, allowance)
    {:noreply, refresh(socket)}
  end

  def handle_event("decide", %{"id" => id, "decision" => decision} = params, socket) do
    decision =
      case decision do
        "allow_once" ->
          :allow_once

        "allow_similar" ->
          {:allow, :similar, allow_minutes(params["minutes"])}

        "allow_all" ->
          {:allow, :all, allow_minutes(params["minutes"])}

        "allow_ids" ->
          {:allow, :ids, allow_minutes(params["minutes"])}

        "deny" ->
          :deny

        "deny_and_turn_off" ->
          if is_binary(params["grant"]),
            do: {:deny_and_turn_off, params["grant"]},
            else: :deny_and_turn_off

        "decline" ->
          :decline

        "simpler" ->
          :simpler

        "send_output" ->
          :send_output

        "keep_output" ->
          :keep_output
      end

    {:noreply, socket |> decide(id, decision) |> refresh()}
  end

  # An allowance from a card several grants asked for, added to each grant
  # you left ticked.
  def handle_event("allow_on_grants", %{"approval" => id, "scope" => scope} = params, socket)
      when scope in ["similar", "ids", "all"] do
    ids = for id <- List.wrap(params["grants"]), is_binary(id), do: id

    socket =
      if ids == [] do
        put_notice(socket, :info, "Tick a grant",
          body: "The allowance goes to the grants ticked."
        )
      else
        decide(
          socket,
          id,
          {:allow, String.to_existing_atom(scope), allow_minutes(params["minutes"]), ids}
        )
      end

    {:noreply, refresh(socket)}
  end

  # A command, run once from its full card, with its output going to the
  # agent or to you first.
  def handle_event("run_command", %{"run" => %{"id" => id} = params}, socket) do
    output_to = if params["output"] == "review", do: :review, else: :send
    {:noreply, socket |> decide(id, {:run, output_to}) |> refresh()}
  end

  def handle_event("stop_command", %{"id" => id}, socket) do
    socket =
      case Sandbox.stop_command(socket.assigns.username, id) do
        :ok -> socket
        {:error, :not_running} -> put_notice(socket, :info, "It had already ended")
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("save_host_notes", %{"host" => %{"notes" => notes} = host}, socket) do
    attrs = %{"host_notes" => notes, "confine_reads" => Map.get(host, "reads", "")}

    case Sandbox.update_settings(socket.assigns.username, attrs) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_host_form()
         |> put_notice(:info, "Notes saved; agents see them with mwt host")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:host_form, to_form(Map.put(host, "notes", notes), as: :host))
         |> assign(:host_error, errors[:host_notes] || errors[:confine_reads])}
    end
  end

  def handle_event("probe_host", _params, socket) do
    _ = Sandbox.probe_host(socket.assigns.username)
    {:noreply, refresh(socket)}
  end

  # An agent's ask, answered from its card: for how long, and whether each
  # use still asks.
  def handle_event("turn_on_ask", %{"ask" => %{"id" => id} = params}, socket) do
    minutes = params["minutes"] |> parse_duration() |> to_minutes()
    uses = if params["uses"] == "all", do: :all, else: :ask
    {:noreply, socket |> decide(id, {:turn_on, minutes, uses}) |> refresh()}
  end

  # From a credential's page: its kind comes first, as picking it does.
  def handle_event("open_add_grant", %{"preset" => "over", "over" => over} = params, socket) do
    case ResourcePages.over_from(over) do
      {kind, id} ->
        socket = assign(socket, :adding, %{step: :pick, approval_id: params["approval"]})
        handle_event("pick_over", %{"kind" => Atom.to_string(kind), "id" => id}, socket)

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("open_add_grant", %{"preset" => preset} = params, socket) do
    socket =
      assign(socket, :adding, %{
        step: :pick,
        approval_id: params["approval"],
        over: ResourcePages.over_from(params["over"])
      })

    handle_event("pick_preset", %{"preset" => preset}, socket)
  end

  # A grant's settings on its page: changed in place, kept only once saved.
  def handle_event("grant_settings_change", %{"grant" => params}, socket) do
    {:noreply,
     update(socket, :grant_settings, fn settings ->
       %{settings | form: to_form(params, as: :grant), dirty: true}
     end)}
  end

  def handle_event("grant_settings_cancel", _params, socket) do
    {:noreply,
     case socket.assigns[:grant] do
       %Grant{} = grant -> assign(socket, :grant_settings, settings_of(grant))
       nil -> socket
     end}
  end

  def handle_event("grant_settings_save", %{"grant" => params}, socket) do
    username = socket.assigns.username
    grant = socket.assigns.grant

    # The grant's own fields, then when it starts and whether it always
    # asks, each only when it changed.
    # A built-in grant's own fields are MWT's, but for the hosts the
    # Internet's leaves out.
    saved =
      cond do
        Grant.internet?(grant) -> Sandbox.set_except(username, grant.id, params["except"])
        Grant.built_in?(grant) -> {:ok, grant}
        true -> Sandbox.update_grant(username, grant.id, Map.drop(params, ["start"]))
      end

    with {:ok, grant} <- saved,
         {:ok, grant} <- changed_start(username, grant, params["start"]) do
      {:noreply,
       socket
       |> assign(:grant_settings, settings_of(grant))
       |> put_notice(:success, "#{grant.name} saved")
       |> refresh()}
    else
      {:error, %{} = errors} ->
        {:noreply,
         update(
           socket,
           :grant_settings,
           &%{&1 | form: to_form(params, as: :grant), errors: errors}
         )}

      {:error, :to_review} ->
        {:noreply,
         put_notice(socket, :info, "Review it first",
           body: "An agent proposed it: it starts off until you accept it."
         )}

      {:error, :always_asks} ->
        {:noreply,
         put_notice(socket, :info, "It always asks",
           body: "A command an agent writes can do anything you can: every run waits for you."
         )}

      {:error, _gone} ->
        {:noreply, socket |> put_notice(:info, "It can't be changed") |> refresh()}
    end
  end

  # A grant or action changed in the form it was added with, filled in.
  def handle_event("edit_grant", %{"id" => id}, socket) do
    case socket.assigns.grant_map[id] do
      %Grant{} = grant ->
        if Grant.built_in?(grant) do
          {:noreply, put_notice(socket, :info, "#{grant.name} is built in")}
        else
          {:noreply,
           assign(socket, :adding, %{
             step: :details,
             approval_id: nil,
             editing: grant.id,
             over: Grant.resource(grant),
             preset: Presets.type_or_preset(grant),
             form: to_form(edit_fields(grant), as: :grant),
             errors: %{}
           })}
        end

      nil ->
        {:noreply, put_notice(socket, :info, "It was removed")}
    end
  end

  def handle_event("open_add_grant", params, socket),
    do: {:noreply, assign(socket, :adding, %{step: :pick, approval_id: params["approval"]})}

  # A command an agent wrote, saved as a saved command: the form
  # filled in from its card.
  def handle_event("save_command", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.waiting, &(&1.id == id and &1.kind == :command)) do
      nil ->
        {:noreply, put_notice(socket, :info, "That was already settled")}

      approval ->
        {:ok, preset} = Presets.find("saved_command")

        params = %{
          "name" => approval.suggest_save || command_name(approval.script),
          # What the agent suggested it is for, in words for any run; never
          # its reason, which is about this one.
          "purpose" => approval.save_for || "",
          "script" => String.trim(approval.script),
          "dir" => approval.dir,
          "params" => "",
          "start" => "off"
        }

        {:noreply,
         assign(socket, :adding, %{
           step: :details,
           approval_id: id,
           preset: preset,
           form: to_form(params, as: :grant),
           errors: %{}
         })}
    end
  end

  # The catalog's search, sort and filters come from one form or another;
  # each sends what the others hold too.
  def handle_event(event, params, socket) when event in ["search_grants", "filter_grants"] do
    socket =
      socket
      |> assign(:grant_term, String.slice(params["term"] || socket.assigns.grant_term, 0, 200))
      |> assign(:grant_filters, Grants.filters(params))
      |> assign(:grant_page, 1)

    # Filtered from another tab (Show them, of what agents proposed): the
    # list is in Grants.
    {:noreply,
     if(socket.assigns.grants_tab == "grants",
       do: socket,
       else: push_patch(socket, to: ~p"/tools/sandbox/grants")
     )}
  end

  # The Resources tab's filters, and its pages.
  def handle_event("filter_resources", params, socket),
    do:
      {:noreply,
       assign(socket,
         resource_filters: ResourcePages.resource_filters(params),
         resource_page: 1
       )}

  def handle_event("clear_resource_filters", _params, socket),
    do:
      {:noreply,
       assign(socket, resource_filters: ResourcePages.resource_filters(), resource_page: 1)}

  def handle_event("resources_page", %{"page" => page}, socket) do
    case page_asked(page) do
      nil -> {:noreply, socket}
      number -> {:noreply, assign(socket, :resource_page, number)}
    end
  end

  # A label picked, dropped from its chip; the other filters stay.
  def handle_event("unpick_grant_label", %{"label" => label}, socket) do
    {:noreply,
     socket
     |> update(:grant_filters, fn filters -> %{filters | labels: filters.labels -- [label]} end)
     |> assign(:grant_page, 1)}
  end

  def handle_event("clear_grant_search", _params, socket),
    do: {:noreply, assign(socket, grant_term: "", grant_page: 1)}

  def handle_event("clear_grant_filters", _params, socket),
    do: {:noreply, assign(socket, grant_term: "", grant_filters: Grants.filters(), grant_page: 1)}

  # A page of All grants; the page shows it within the pages there are.
  def handle_event("grants_page", %{"page" => page}, socket) do
    case page_asked(page) do
      nil -> {:noreply, socket}
      number -> {:noreply, assign(socket, :grant_page, number)}
    end
  end

  def handle_event("close_add_grant", _params, socket),
    do: {:noreply, assign(socket, :adding, nil)}

  def handle_event("add_grant_back", _params, socket) do
    {:noreply, update(socket, :adding, &%{step: :pick, approval_id: &1.approval_id})}
  end

  # The resource a new grant is over, picked in the dialog: a grant over a
  # credential or a network starts from its type, its presets offered.
  def handle_event("pick_over", %{"kind" => kind, "id" => id}, socket)
      when kind in ["credential", "network"] do
    resource = {String.to_existing_atom(kind), id}

    socket =
      update(socket, :adding, &Map.merge(&1, %{over: resource, picked: true}))

    # Over a credential, its kind comes first: open use or a fixed call.
    if kind == "credential",
      do: {:noreply, update(socket, :adding, &Map.put(&1, :step, :kind))},
      else: handle_event("pick_preset", %{"preset" => "network"}, socket)
  end

  # The kind of a new grant over a credential: open use, from a grant
  # preset for its service when there are some, or a fixed call.
  def handle_event("pick_kind", %{"kind" => "fixed"}, socket),
    do: handle_event("pick_preset", %{"preset" => "request_action"}, socket)

  def handle_event("pick_kind", %{"kind" => "open"}, socket) do
    presets =
      with {:credential, id} <- socket.assigns.adding[:over],
           %{} = credential <- Enum.find(socket.assigns.credentials, &(&1.id == id)),
           do: Presets.over(credential, socket.assigns.username),
           else: (_ -> [])

    if presets == [],
      do: handle_event("pick_preset", %{"preset" => "token"}, socket),
      else: {:noreply, update(socket, :adding, &Map.put(&1, :step, :preset))}
  end

  # By hand, from the grant presets' step: a grant over the credential,
  # as its type's form starts.
  def handle_event("pick_preset", params, socket) when not is_map_key(params, "preset"),
    do: handle_event("pick_preset", %{"preset" => "token"}, socket)

  def handle_event("pick_preset", %{"preset" => id}, socket) do
    {:ok, preset} = Presets.find(id, socket.assigns.username)

    ask =
      Enum.find(socket.assigns.waiting, &(&1.id == socket.assigns.adding.approval_id))

    params =
      Map.merge(
        %{
          "name" =>
            if(ask && ask.need, do: String.slice(ask.need, 0, 60), else: preset_name(preset))
        },
        preset.fields
      )

    params =
      if ask && ask.need && params["purpose"] in [nil, ""],
        do: Map.put(params, "purpose", ask.need),
        else: params

    # Over a resource you have, from its page: a request action starts
    # from its credential, a URL to a host a grant over it lists and the
    # headers that service expects, with the token in place; a token grant
    # is over it; a network grant over it, all of it unless you list hosts.
    params =
      case {preset.kind, socket.assigns.adding[:over]} do
        {:request, {:credential, id}} ->
          credential = Enum.find(socket.assigns.credentials, &(&1.id == id))

          hosts =
            for %Grant{kind: :token} = g <- socket.assigns.grants,
                Grant.credential_id(g) == id,
                host <- g.hosts,
                not String.starts_with?(host, "*."),
                do: host

          Map.merge(params, %{
            "credential" => id,
            "method" => "GET",
            "url" => "https://#{List.first(hosts, "")}/",
            "headers" =>
              (credential && credential.request_headers) || SavedRequest.default_headers(nil),
            "start" => "off"
          })

        {:token, {:credential, id}} ->
          Map.put(params, "credential", id)

        {:network, {:network, id}} ->
          Map.merge(params, %{"network" => id, "destinations" => ""})

        {:command, _over} ->
          Map.put(params, "start", "off")

        _other ->
          params
      end

    {:noreply,
     update(socket, :adding, fn adding ->
       Map.merge(adding, %{
         step: :details,
         preset: preset,
         form: to_form(params, as: :grant),
         errors: %{}
       })
     end)}
  end

  def handle_event("validate_grant", %{"grant" => params}, socket) do
    {:noreply, update(socket, :adding, &%{&1 | form: to_form(params, as: :grant)})}
  end

  def handle_event(
        "create_grant",
        %{"grant" => params},
        %{assigns: %{adding: %{editing: id}}} = socket
      )
      when is_binary(id) do
    case Sandbox.update_grant(socket.assigns.username, id, params) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(:adding, nil)
         |> put_notice(:success, "#{grant.name} saved",
           body:
             if(Grant.auto_approved?(grant),
               do: "It is on and auto-approved: what you changed goes through without asking.",
               else: "Its id, state and value are as they were."
             )
         )
         |> refresh()}

      {:error, %{} = errors} ->
        {:noreply,
         update(socket, :adding, &%{&1 | form: to_form(params, as: :grant), errors: errors})}

      {:error, _gone} ->
        {:noreply, socket |> assign(:adding, nil) |> put_notice(:info, "It can't be changed")}
    end
  end

  def handle_event("create_grant", %{"grant" => params}, socket) do
    username = socket.assigns.username

    case Sandbox.create_grant(username, params) do
      {:ok, grant} ->
        approval_id = socket.assigns.adding.approval_id
        from_card? = saving_from_card?(socket, approval_id)

        socket =
          cond do
            # The agent is at it: on for an hour, asking each time.
            from_card? ->
              # One you set to be enabled on startup is enabled already.
              if grant.start == :off,
                do: {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)

              _ = Sandbox.command_saved(username, approval_id, grant.id)

              put_notice(
                socket,
                :success,
                "Saved as #{grant.name}, " <>
                  if(grant.start == :off,
                    do: "on for 1 h",
                    else: start_words(grant.start)
                  ),
                body:
                  "The agent hears to call it by id next time." <>
                    if(grant.start == :auto, do: "", else: " Each run asks.") <>
                    " Its card still waits for you."
              )

            is_nil(approval_id) and grant.start in [:on, :auto] ->
              put_notice(socket, :success, "#{grant.name} added, #{start_words(grant.start)}")

            is_nil(approval_id) ->
              put_notice(socket, :success, "#{grant.name} added",
                body:
                  "It starts off: it gives nothing until you turn it on. Turn it on when a task needs it, or let an agent ask for it."
              )

            true ->
              socket
              |> decide(approval_id, {:set_up, grant.id})
              |> put_notice(:success, "#{grant.name} added and turned on",
                body:
                  "The agent that asked hears it is on." <>
                    if(grant.start == :auto,
                      do: " Every use goes through without asking.",
                      else: " Each use still waits for you."
                    )
              )
          end

        # Saved from a card: stay with the card, which still waits.
        {:noreply,
         if(from_card?,
           do: socket |> assign(:adding, nil) |> refresh(),
           else:
             socket
             |> assign(:adding, nil)
             |> push_patch(to: ~p"/tools/sandbox/grants/#{grant.id}")
         )}

      {:error, errors} ->
        {:noreply,
         update(socket, :adding, &%{&1 | form: to_form(params, as: :grant), errors: errors})}
    end
  end

  def handle_event("confirm_delete_grant", %{"id" => id}, socket) do
    grant = socket.assigns.grant_map[id]

    message =
      if Grant.to_review?(grant),
        do:
          "#{grant.proposal.agent} proposed it and you haven't accepted it: the agent hears you declined it.",
        else:
          "Anything waiting on it is refused, agents' asks included. Its allowances go with it. Its resource stays."

    {:noreply,
     assign(socket, :confirm, %{
       title: "Remove #{grant.name}?",
       message: message,
       label: "Remove",
       action: {:delete_grant, id}
     })}
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("accept_confirm", _params, socket) do
    case socket.assigns.confirm.action do
      {:delete_grant, id} ->
        case Sandbox.delete_grant(socket.assigns.username, id) do
          {:error, :built_in} ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> put_notice(:info, "It is built in", body: "Turn it off instead.")}

          _done ->
            {:noreply,
             socket
             |> assign(:confirm, nil)
             |> push_patch(to: ~p"/tools/sandbox/grants")}
        end

      {:delete_resource, resource} ->
        socket = assign(socket, :confirm, nil)

        case Sandbox.delete_resource(socket.assigns.username, resource) do
          :ok ->
            {:noreply,
             socket
             |> put_notice(:success, "Removed")
             |> push_patch(to: ~p"/tools/sandbox/grants?tab=resources")}

          {:error, _reason} ->
            {:noreply, refresh(socket)}
        end
    end
  end

  def handle_event("firewall_enabled", %{"value" => value}, socket),
    do: firewall_set(socket, {:enabled, value == "true"})

  def handle_event("firewall_action", %{"rule" => rule, "value" => action}, socket),
    do: firewall_set(socket, {:action, rule, action})

  def handle_event(
        "firewall_list",
        %{"firewall_list" => %{"list" => list, "text" => text}},
        socket
      ) do
    case firewall_list(list) do
      nil ->
        {:noreply, socket}

      list ->
        case Sandbox.firewall_set(socket.assigns.username, {:list, list, text}) do
          :ok ->
            {:noreply,
             socket
             |> update(:firewall_drafts, &Map.delete(&1, list))
             |> update(:firewall_errors, &Map.delete(&1, list))
             |> refresh()
             |> put_notice(:success, "Saved")}

          {:error, message} ->
            {:noreply,
             socket
             |> update(:firewall_drafts, &Map.put(&1, list, text))
             |> update(:firewall_errors, &Map.put(&1, list, message))}
        end
    end
  end

  def handle_event("firewall_reset_list", %{"list" => list}, socket) do
    case firewall_list(list) do
      nil ->
        {:noreply, socket}

      list ->
        socket =
          socket
          |> update(:firewall_drafts, &Map.delete(&1, list))
          |> update(:firewall_errors, &Map.delete(&1, list))

        firewall_set(socket, {:reset_list, list})
    end
  end

  # The VM isolated switch. On isolates at once; off releases an isolation
  # you made, or asks first about one the firewall made.
  def handle_event("firewall_isolated", %{"value" => "true"}, socket) do
    case Sandbox.firewall_isolate(socket.assigns.username) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> put_notice(:info, "VM isolated",
           body: "Nothing it sends leaves through MWT until you turn the switch off."
         )}

      :error ->
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("firewall_isolated", %{"value" => "false"}, socket) do
    case socket.assigns.firewall.isolated do
      %{by: :you} -> release(socket, false)
      %{} -> {:noreply, assign(socket, :firewall_releasing, true)}
      nil -> {:noreply, refresh(socket)}
    end
  end

  def handle_event("firewall_release", params, socket),
    do: release(socket, get_in(params, ["release", "trust"]) == "true")

  def handle_event("cancel_firewall_release", _params, socket),
    do: {:noreply, assign(socket, :firewall_releasing, false)}

  def handle_event("filter_activity", params, socket) do
    filters = %{
      q: params["q"] || "",
      group: if(Map.has_key?(Event.groups(), params["group"]), do: params["group"], else: "all"),
      grant: params["grant"] || "",
      thread: params["thread"] || "",
      decided:
        if(params["decided"] in Enum.map(Decision.all(), &Atom.to_string/1),
          do: params["decided"],
          else: ""
        ),
      window: if(Map.has_key?(@windows, params["window"]), do: params["window"], else: "day")
    }

    {:noreply,
     socket |> assign(:filters, filters) |> reset_events() |> load_stats() |> load_threads()}
  end

  # What MWT reads, the activity log's dialog: open and closed. It is set
  # now and then, so it isn't on the page until asked for.
  def handle_event("open_reading", _params, socket),
    do: {:noreply, assign(socket, :reading_open, true)}

  def handle_event("close_reading", _params, socket),
    do: {:noreply, assign(socket, :reading_open, false)}

  # Which hosts MWT reads (`MWTClient.Sandbox.Reading`), from the activity
  # log: a host put on a list, from What MWT reads, a busiest destination
  # or a line that failed for being read; one taken off; what the rest do.
  # Only you, from here: nothing the VM does changes it.
  def handle_event("reading_put", %{"host" => host, "read" => read}, socket),
    do: reading_set(socket, {:put, host, read == "true"}, reading_words(host, read == "true"))

  def handle_event("reading_add", %{"reading" => %{"host" => host, "read" => read}}, socket),
    do: reading_set(socket, {:put, host, read == "true"}, reading_words(host, read == "true"))

  def handle_event("reading_remove", %{"host" => host}, socket),
    do: reading_set(socket, {:remove, host}, "#{host} is on neither list now")

  def handle_event("reading_default", %{"value" => value}, socket) do
    case value do
      "every_host" ->
        reading_set(socket, {:default, :every_host}, "MWT reads hosts on neither list")

      "token_hosts" ->
        reading_set(socket, {:default, :token_hosts}, "MWT doesn't read hosts on neither list")

      _other ->
        {:noreply, socket}
    end
  end

  # A destination picked on the page searches for it; none clears the search.
  def handle_event("filter_host", %{"host" => host}, socket) do
    {:noreply,
     socket
     |> update(:filters, &%{&1 | q: host})
     |> reset_events()
     |> load_stats()
     |> paged()}
  end

  # Page 1 takes new events in, so its last row moves; the cursor is read
  # again rather than remembered.
  def handle_event("older_activity", _params, socket) do
    %{activity: activity, username: username} = socket.assigns

    cursor =
      case activity.cursors do
        [] ->
          username
          |> Sandbox.events(socket |> query_filters() |> Map.put(:limit, @page_size))
          |> List.last()
          |> then(&(&1 && &1.id))

        _older ->
          activity.oldest
      end

    {:noreply,
     if(cursor, do: socket |> load_events([cursor | activity.cursors]) |> paged(), else: socket)}
  end

  def handle_event("newer_activity", _params, socket) do
    cursors =
      case socket.assigns.activity.cursors do
        [_ | rest] -> rest
        [] -> []
      end

    {:noreply, socket |> load_events(cursors) |> paged()}
  end

  # An event opened in the log: what its request carried and got back, and
  # its details, are read now, and the line drawn again with them. A
  # request still running shows what MWT read of it so far: its line stays
  # marked running, and reads the rest once the request ends.
  def handle_event("open_event", %{"id" => id}, socket) when is_binary(id) do
    case Sandbox.event(socket.assigns.username, id) do
      %Event{exchange: nil, details: [], decision: nil} ->
        {:noreply, socket}

      %Event{} = event ->
        {event, socket} = still_running(socket, event)
        {:noreply, stream_insert(socket, :events, event)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("latest_activity", _params, socket),
    do: {:noreply, socket |> reset_events() |> paged()}

  def handle_event("share_changed", %{"share" => params}, socket) do
    {:noreply, assign(socket, share_form: to_form(params, as: :share), share_error: nil)}
  end

  def handle_event("add_share", %{"share" => params}, socket) do
    case Sandbox.add_share(socket.assigns.username, params["path"] || "") do
      {:ok, _share} ->
        {:noreply,
         socket
         |> assign(share_form: to_form(%{"path" => ""}, as: :share))
         |> assign(:share_error, nil)
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           share_form: to_form(params, as: :share),
           share_error: Shares.explain(reason)
         )}
    end
  end

  # Folders picked in the desktop app's folder dialog, any number at once.
  def handle_event("add_shares", %{"paths" => paths}, socket) when is_list(paths) do
    results =
      for path <- paths, is_binary(path) do
        {path, Sandbox.add_share(socket.assigns.username, path)}
      end

    added = Enum.count(results, &match?({_, {:ok, _}}, &1))

    failed =
      for {path, {:error, reason}} <- results,
          do: "#{Path.basename(path)}: #{Shares.explain(reason)}"

    socket =
      socket
      |> assign(:share_error, if(failed == [], do: nil, else: Enum.join(failed, " ")))
      |> refresh()

    socket =
      case added do
        0 -> socket
        1 -> put_notice(socket, :success, "Folder shared", body: copied_words())
        n -> put_notice(socket, :success, "#{n} folders shared", body: copied_words())
      end

    {:noreply, socket}
  end

  def handle_event("folder_picker_unavailable", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :share_error, reason <> " Type the folder's path instead.")}
  end

  def handle_event("sync_share", %{"path" => path}, socket) do
    :ok = Sandbox.sync_shares(socket.assigns.username, [path])
    {:noreply, refresh(socket)}
  end

  def handle_event("sync_shares", _params, socket) do
    :ok = Sandbox.sync_shares(socket.assigns.username, :all)
    {:noreply, refresh(socket)}
  end

  # The workspace's two halves, both ways.
  def handle_event("sync_workspace", _params, socket) do
    :ok = Sandbox.sync_workspace(socket.assigns.username)
    {:noreply, refresh(socket)}
  end

  def handle_event("open_workspace", _params, socket) do
    case Sandbox.open_workspace(socket.assigns.username) do
      :ok -> {:noreply, socket}
      {:error, why} -> {:noreply, put_flash(socket, :error, why)}
    end
  end

  def handle_event("release_held", %{"path" => path}, socket) do
    :ok = Sandbox.release_held(socket.assigns.username, path)
    {:noreply, refresh(socket)}
  end

  def handle_event("remove_share", %{"path" => path}, socket) do
    :ok = Sandbox.remove_share(socket.assigns.username, path)
    {:noreply, refresh(socket)}
  end

  def handle_event("set_nested_virt", %{"on" => on}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"nested_virt" => on}) do
      {:ok, settings} ->
        title =
          if settings.nested_virt,
            do: "VMs inside the VM turned on",
            else: "VMs inside the VM turned off"

        {:noreply,
         socket
         |> refresh()
         |> put_notice(:success, title, body: "It applies when the VM is next created.")}

      {:error, _errors} ->
        {:noreply, put_notice(socket, :error, "That setting couldn't be changed")}
    end
  end

  def handle_event("save_way_of_working", %{"way" => %{"text" => text}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"way_of_working" => text}) do
      {:ok, settings} ->
        title =
          if settings.way_of_working == "",
            do: "Your way of working is cleared",
            else: "Your way of working is saved"

        {:noreply,
         socket
         |> refresh()
         |> assign_way_form()
         |> put_notice(:success, title, body: "It reaches agents at the VM's next start.")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:way_form, to_form(%{"text" => text}, as: :way))
         |> assign(:way_error, errors[:way_of_working])}
    end
  end

  # Fills the field only: nothing reaches agents until it is saved. The form
  # alone would not reach a field you typed in, since the server never sees
  # that typing: when it already holds the example there is no change to send,
  # and a focused field is left as it is. So the field also gets it as an event.
  def handle_event("way_of_working_example", _params, socket) do
    example = Instructions.way_of_working_example()

    {:noreply,
     socket
     |> assign(:way_form, to_form(%{"text" => example}, as: :way))
     |> assign(:way_error, nil)
     |> push_event("way_of_working_fill", %{text: example})}
  end

  ## Projects

  def handle_event("open_project", %{"path" => project} = params, socket) do
    case Projects.open(socket.assigns.username, project, params["folder"]) do
      {:ok, opened} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{opened.name} opened in Zed",
           body: params["folder"] || "Its clone, /work/#{opened.name}: slot-0."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:warning, "Zed didn't open", body: Projects.explain(reason))}
    end
  end

  def handle_event("save_project", %{"name" => name} = params, socket) do
    case Projects.update(socket.assigns.username, name, params["project"] || %{}) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> assign(:project_editing, nil)
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "Checks of #{name} saved")}

      {:error, reason} ->
        {:noreply,
         assign(socket, :project_editing, %{name: name, error: Projects.explain(reason)})}
    end
  end

  def handle_event("edit_checks", %{"name" => name}, socket),
    do: {:noreply, assign(socket, :project_editing, %{name: name, error: nil})}

  def handle_event("cancel_checks", _params, socket),
    do: {:noreply, assign(socket, :project_editing, nil)}

  def handle_event("close_project", %{"name" => name}, socket) do
    case Projects.close(socket.assigns.username, name) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{name} closed",
           body:
             "Its clone, slots, branches and handoffs stay in the VM; MWT stops following it. Open project brings it back."
         )}

      {:error, reason} ->
        {:noreply,
         put_notice(socket, :warning, "#{name} stays open", body: Projects.explain(reason))}
    end
  end

  # The Open project dialog: what there is to open, looked for when it opens,
  # since it reads your shared folders.
  def handle_event("open_dialog", _params, socket) do
    available = Projects.available(socket.assigns.username)
    {:noreply, assign(socket, :project_dialog, %{available: available, q: "", browse: nil})}
  end

  def handle_event("close_dialog", _params, socket),
    do: {:noreply, assign(socket, :project_dialog, nil)}

  def handle_event("dialog_filter", params, socket) do
    case socket.assigns.project_dialog do
      %{} = dialog ->
        {:noreply, assign(socket, :project_dialog, %{dialog | q: to_string(params["q"] || "")})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("browse", %{"path" => path}, socket) do
    case socket.assigns.project_dialog do
      %{} = dialog ->
        browse = Projects.browse(socket.assigns.username, path)
        {:noreply, assign(socket, :project_dialog, %{dialog | browse: browse})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("browse_back", _params, socket) do
    case socket.assigns.project_dialog do
      %{} = dialog -> {:noreply, assign(socket, :project_dialog, %{dialog | browse: nil})}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("reopen_project", %{"path" => path}, socket) do
    case Projects.reopen(socket.assigns.username, path) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project_dialog, nil)
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{project.name} opened",
           body:
             if(socket.assigns.vm.status == :running,
               do: "Its clone, /work/#{project.name}, is made in a moment.",
               else: "Its clone, /work/#{project.name}, is made when the VM runs."
             )
         )}

      {:error, reason} ->
        {:noreply, put_notice(socket, :warning, "Nothing opened", body: Projects.explain(reason))}
    end
  end

  def handle_event("add_slot", %{"name" => name}, socket) do
    case Projects.add_slot(socket.assigns.username, name) do
      {:ok, slot} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{slot} added to #{name}",
           body:
             if(socket.assigns.vm.status == :running,
               do: "Free for the next task.",
               else: "Made when the VM starts."
             )
         )}

      {:error, reason} ->
        {:noreply, put_notice(socket, :warning, "No slot added", body: Projects.explain(reason))}
    end
  end

  def handle_event("remove_slot", %{"name" => name, "slot" => slot}, socket) do
    case Projects.remove_slot(socket.assigns.username, name, slot) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{slot} removed from #{name}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_overview()
         |> put_notice(:warning, "#{slot} stays", body: Projects.explain(reason))}
    end
  end

  def handle_event("stop_server", %{"port" => port}, socket) do
    with {port, ""} <- Integer.parse(port),
         {:ok, _pids} <- Sandbox.stop_server(socket.assigns.username, port) do
      {:noreply,
       put_notice(socket, :success, "Killed the server on port #{port}",
         body: "It leaves the list once the VM says the port is free."
       )}
    else
      {:error, reason} ->
        {:noreply, put_notice(socket, :warning, "The server stays", body: stop_words(reason))}

      _not_a_port ->
        {:noreply, socket}
    end
  end

  def handle_event("free_slot", %{"name" => name, "slot" => slot}, socket) do
    case Projects.release_slot(socket.assigns.username, name, slot) do
      {:ok, %{branch: branch}, after_free} ->
        body = released_words(branch, after_free)

        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{slot} of #{name} released", body: body)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_overview()
         |> put_notice(:warning, "#{slot} stays as it is", body: Projects.explain(reason))}
    end
  end

  def handle_event("prune_branches", %{"name" => name}, socket) do
    case Projects.prune_branches(socket.assigns.username, name) do
      {:ok, pruned} ->
        {deleted, kept} = Enum.split_with(pruned, &match?({_, {:deleted, _}}, &1))

        title =
          case deleted do
            [] -> "No task branch of #{name} to delete"
            _ -> "Deleted #{task_branches(length(deleted))} of #{name}"
          end

        body =
          [
            deleted != [] && Enum.map_join(deleted, ", ", &elem(&1, 0)) <> ".",
            kept != [] &&
              "Kept: " <>
                Enum.map_join(kept, "; ", fn {branch, {:kept, why}} ->
                  "#{branch}, as #{Slots.kept_words(why)}"
                end) <> "."
          ]
          |> Enum.filter(& &1)
          |> Enum.join(" ")

        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, title, body: if(body != "", do: body))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_overview()
         |> put_notice(:warning, "No branch pruned", body: Projects.explain(reason))}
    end
  end

  def handle_event("remove_leftover", %{"name" => name}, socket) do
    case Leftovers.remove(socket.assigns.username, name) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> assign_overview()
         |> put_notice(:success, "#{name} removed from the VM")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_overview()
         |> put_notice(:warning, "#{name} stays", body: Leftovers.explain(reason))}
    end
  end

  def handle_event("monitor_by", %{"by" => by}, socket),
    do: {:noreply, assign(socket, :monitor_by, if(by == "memory", do: :memory, else: :cpu))}

  def handle_event("forget_project", %{"name" => name}, socket) do
    Projects.forget(socket.assigns.username, name)

    socket =
      case socket.assigns.project_dialog do
        %{} = dialog ->
          assign(socket, :project_dialog, %{
            dialog
            | available: Projects.available(socket.assigns.username)
          })

        nil ->
          socket
      end

    {:noreply, socket |> refresh() |> assign_overview()}
  end

  ## Handoffs

  # The list searched for every word typed, with the archived ones or
  # not, between the days given, from its first page.
  def handle_event("search_handoffs", params, socket) do
    {:noreply,
     socket |> update(:handoff_place, &HandoffsPage.searched(&1, params)) |> load_handoff_list()}
  end

  def handle_event("clear_handoff_search", _params, socket) do
    {:noreply,
     socket
     |> update(:handoff_place, &HandoffsPage.searched(&1, %{"term" => ""}))
     |> load_handoff_list()}
  end

  # A page of the list; the list shows it within the pages there are.
  def handle_event("handoffs_page", %{"page" => page}, socket) do
    case page_asked(page) do
      nil ->
        {:noreply, socket}

      number ->
        {:noreply, socket |> update(:handoff_place, &%{&1 | page: number}) |> load_handoff_list()}
    end
  end

  # Which of the three ways to end it the panel shows: nothing happens
  # until its button is pressed.
  def handle_event("handoff_decision", %{"choice" => choice}, socket)
      when choice in ["land", "more", "close"],
      do: {:noreply, assign(socket, :handoff_decision, choice)}

  def handle_event("accept_change", %{"accept" => params}, socket) do
    case socket.assigns.handoff_view do
      %{accept: %{}} = view ->
        accept = accept_state(view, params, socket.assigns.username)
        {:noreply, assign(socket, :handoff_view, %{view | accept: accept})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("accept_handoff", params, socket) do
    with %{accept: %{}, handoff: handoff} = view <- socket.assigns.handoff_view do
      fields = Map.get(params, "accept", %{})

      %{destination: destination, opts: opts} =
        accept_state(view, fields, socket.assigns.username)

      # The revision the page showed when you clicked, as the form sent it:
      # one handed off since doesn't land in its place.
      shown = if is_binary(fields["head"]), do: fields["head"], else: handoff.head

      case Handoffs.accept(socket.assigns.username, handoff.id, destination, [
             {:head, shown} | opts
           ]) do
        {:ok, handoff} ->
          {:noreply,
           socket
           |> refresh()
           |> assign_handoff()
           |> put_notice(:success, "Landed",
             body: "\"#{handoff.title}\": " <> Handoffs.accepted_words(handoff.accepted) <> "."
           )}

        {:error, reason} ->
          # What it merges with may have changed since the page worked it out.
          {:noreply,
           socket
           |> refresh()
           |> assign_handoff()
           |> put_notice(:warning, "Nothing landed", body: Handoffs.explain(reason))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Back to the VM, where the work is looked at and more is asked of its
  # thread: the worktree its branch is in, as worked out when the page
  # opened it, else the folder it was handed off from, where its thread is
  # in Zed's list (a landed one's branch is gone).
  def handle_event("open_handoff_worktree", _params, socket) do
    with %{handoff: handoff} = view <- socket.assigns.handoff_view do
      path =
        case view.worktree do
          %{path: path} -> path
          _none_or_unknown -> handoff.source.top
        end

      case Projects.open(socket.assigns.username, handoff.project, path) do
        {:ok, _project} ->
          body = if handoff.thread, do: "#{path}: its thread is “#{handoff.thread}”", else: path
          {:noreply, put_notice(socket, :success, "Opened in Zed", body: body)}

        {:error, reason} ->
          {:noreply,
           put_notice(socket, :warning, "Zed didn't open", body: Projects.explain(reason))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("undo_handoff", %{"id" => id}, socket) do
    handoff_action(
      socket,
      Handoffs.undo(socket.assigns.username, handoff_id(id)),
      "Taken back out"
    )
  end

  # MWT replays its commits onto its branch itself: a new revision that
  # lands as it is.
  def handle_event("catch_up_handoff", %{"id" => id}, socket) do
    case Handoffs.catch_up(socket.assigns.username, handoff_id(id)) do
      {:ok, handoff} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_handoff()
         |> put_notice(:success, "Caught up with #{handoff.base_branch}",
           body: "Revision #{handoff.revision}: it lands as it is. Its checks ran before that."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_handoff()
         |> put_notice(:warning, "Not caught up", body: Handoffs.explain(reason))}
    end
  end

  def handle_event("close_handoff", %{"id" => id}, socket) do
    handoff_action(socket, Handoffs.close(socket.assigns.username, handoff_id(id)), "Closed")
  end

  def handle_event("reopen_handoff", %{"id" => id}, socket) do
    socket = assign(socket, :handoff_decision, "land")
    handoff_action(socket, Handoffs.reopen(socket.assigns.username, handoff_id(id)), "Reopened")
  end

  # The size form reports each change, so the meters follow what you type.
  def handle_event("vm_changed", %{"vm" => params}, socket),
    do: {:noreply, assign(socket, :vm_form, to_form(params, as: :vm))}

  # Fills in what MWT suggests; Save keeps it.
  def handle_event("use_suggested", _params, socket) do
    %{cpus: cpus, memory_gib: memory_gib} = socket.assigns.resources.suggested

    params =
      Map.merge(socket.assigns.vm_form.params, %{
        "cpus" => to_string(cpus),
        "memory_gib" => to_string(memory_gib)
      })

    {:noreply, assign(socket, :vm_form, to_form(params, as: :vm))}
  end

  def handle_event("reset_vm_form", _params, socket),
    do: {:noreply, socket |> assign(:vm_errors, %{}) |> assign_vm_form()}

  def handle_event("save_settings", %{"vm" => params}, socket) do
    case Sandbox.update_settings(socket.assigns.username, params) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:vm_errors, %{})
         |> refresh()
         |> assign_vm_form()
         |> put_notice(:success, "Settings saved")}

      {:error, errors} ->
        {:noreply, assign(socket, vm_form: to_form(params, as: :vm), vm_errors: errors)}
    end
  end

  def handle_event("build_image", params, socket) do
    socket =
      case Sandbox.build_image(socket.assigns.username, cache: params["cache"] != "false") do
        :ok ->
          assign(socket, :image_pane, :log)

        {:error, {:layer, problem}} ->
          put_notice(socket, :error, "Your layer can't be built", body: problem)

        {:error, :busy} ->
          put_notice(socket, :info, "A build is already running")

        {:error, :no_podman} ->
          put_notice(socket, :error, "podman is not installed",
            body: "MWT builds the VM image with podman."
          )

        {:error, :no_msb} ->
          put_notice(socket, :error, "MWT's microsandbox runtime is missing",
            body:
              "Packaged MWT ships it. In a source checkout, run scripts/build-microsandbox.sh."
          )
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("save_layer", %{"layer" => %{"image_layer" => text}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"image_layer" => text}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_layer_form()
         |> put_notice(:success, "Your layer is saved", body: "Build the image to use it.")}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           layer_form: to_form(%{"image_layer" => text}, as: :layer),
           layer_error: errors[:image_layer]
         )}
    end
  end

  def handle_event("reset_layer", _params, socket) do
    {:noreply,
     assign(socket,
       layer_form: to_form(%{"image_layer" => Image.default_layer()}, as: :layer),
       layer_error: nil
     )}
  end

  # The versions of your layer, on the build page: the panel takes the
  # place of what podman builds and the build log while it is open.
  def handle_event("show_versions", _params, socket) do
    {:noreply,
     assign(socket,
       layer_versions: Sandbox.layer_versions(socket.assigns.username),
       layer_versions_open: true,
       layer_version: nil
     )}
  end

  def handle_event("hide_versions", _params, socket) do
    {:noreply, assign(socket, layer_versions_open: false, layer_version: nil)}
  end

  def handle_event("select_version", %{"version" => number}, socket) do
    {:noreply, assign(socket, :layer_version, String.to_integer(number))}
  end

  def handle_event("restore_version", %{"version" => number}, socket) do
    username = socket.assigns.username

    case Sandbox.restore_layer(username, String.to_integer(number)) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_layer_form()
         |> assign(layer_versions: Sandbox.layer_versions(username), layer_version: nil)
         |> put_notice(:success, "Version restored", body: "Build the image to use it.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(layer_versions: Sandbox.layer_versions(username), layer_version: nil)
         |> put_notice(:warning, "That version is gone")}
    end
  end

  def handle_event("image_pane", %{"pane" => pane}, socket) when pane in ~w(full log) do
    {:noreply,
     assign(socket, image_pane: String.to_existing_atom(pane), layer_versions_open: false)}
  end

  def handle_event("delete_build", %{"ref" => ref}, socket) do
    socket =
      case Sandbox.delete_build(socket.assigns.username, ref) do
        :ok -> put_notice(socket, :success, "#{ref} deleted")
        {:error, :busy} -> put_notice(socket, :info, "Wait for the build to finish")
        {:error, :not_found} -> put_notice(socket, :warning, "That build is gone")
        {:error, :current} -> put_notice(socket, :warning, "The current build stays")
        {:error, :in_use} -> put_notice(socket, :warning, "The VM runs that build")
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("set_value", %{"value" => %{"value" => value}}, socket) do
    socket =
      cond do
        String.trim(value) == "" ->
          socket

        Sandbox.set_value(socket.assigns.username, socket.assigns.grant_id, value) == :ok ->
          put_notice(socket, :success, "Value replaced",
            body: "Kept in your vault. The VM still only sees the placeholder."
          )

        true ->
          put_notice(socket, :error, "Could not replace the value")
      end

    {:noreply, socket |> assign(:value_form, to_form(%{"value" => ""}, as: :value)) |> refresh()}
  end

  ## Broadcasts

  @impl true
  # What the run kept open decided, read again a moment after it ended:
  # the requests it made are logged as they go, the last ones a little
  # after it.
  def handle_info({:console_decisions, id}, socket) do
    {:noreply,
     if(socket.assigns.console_open == id, do: open_console_run(socket, id), else: socket)}
  end

  def handle_info({:sandbox_changed, _area}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info({:sandbox_build_line, _line}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info({:sandbox_event, event}, socket) do
    socket =
      cond do
        socket.assigns.page != :activity ->
          socket

        Event.matches?(event, socket.assigns.filters) ->
          socket |> take_event(event) |> schedule_stats()

        true ->
          schedule_stats(socket)
      end

    {:noreply, schedule_refresh(socket)}
  end

  # A request ended: its lines stop being marked running and say how long
  # it took; one opened while it ran reads what it carried now.
  def handle_info({:sandbox_exchange, exchange_id, ms}, socket) do
    case Map.pop(socket.assigns.activity.running, exchange_id) do
      {nil, _running} ->
        {:noreply, socket}

      {events, running} ->
        socket = update(socket, :activity, &%{&1 | running: running})
        {:noreply, Enum.reduce(events, socket, &ended(&2, &1, ms))}
    end
  end

  def handle_info(:activity_stats, socket) do
    socket = assign(socket, :stats_timer, nil)
    {:noreply, if(socket.assigns.page == :activity, do: load_stats(socket), else: socket)}
  end

  # While the Projects page is shown, its projects' slots are read again
  # every few seconds, and the page with them.
  def handle_info(:projects_tick, socket) do
    socket = assign(socket, :projects_timer, nil)

    if socket.assigns.page == :projects,
      do: {:noreply, socket |> refresh() |> assign_overview(:tick) |> tick_projects()},
      else: {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> refresh()}
  end

  # The VM monitor's latest sample and history, every few seconds while the
  # VM runs (`MWTClient.Sandbox.Monitor`).
  def handle_info({:sandbox_monitor, snapshot}, socket),
    do: {:noreply, assign(socket, :monitor, snapshot)}

  @impl true
  def handle_async(:console, {:ok, {:ok, run}}, socket) do
    Process.send_after(self(), {:console_decisions, run.id}, 1_500)

    # A run from the terminal: its next command starts where this ended.
    socket =
      case socket.assigns.console_running do
        %{from: :terminal} when is_binary(run.cwd) -> assign(socket, :terminal_cwd, run.cwd)
        _other -> socket
      end

    {:noreply,
     socket
     |> assign(console_running: nil, console_term: "", console_page: 1)
     |> open_console_run(run.id)}
  end

  def handle_async(:console, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, console_running: nil, console_error: console_error(reason))}

  def handle_async(:console, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:console, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, console_running: nil, console_error: "It stopped: #{inspect(reason)}")}
  end

  def handle_async(:leftovers, {:ok, result}, socket),
    do: {:noreply, assign(socket, :leftovers, result)}

  def handle_async(:leftovers, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, :leftovers, {:error, "Looking at the VM failed: #{inspect(reason)}"})}

  def handle_async(:project_checkouts, {:ok, read}, socket),
    do: {:noreply, update(socket, :project_worktrees, &Map.merge(&1, read))}

  # The last read stays; a panel still reading says the read failed.
  def handle_async(:project_checkouts, {:exit, reason}, socket) do
    failed = {:error, "Reading the worktree slots failed: #{inspect(reason)}"}

    {:noreply,
     update(socket, :project_worktrees, fn worktrees ->
       Map.new(worktrees, fn
         {name, :reading} -> {name, failed}
         read -> read
       end)
     end)}
  end

  # The first page shows the newest events as they come; an older page stays
  # put and counts what it is missing.
  defp take_event(%{assigns: %{activity: %{cursors: []} = activity}} = socket, event) do
    socket
    |> stream_insert(:events, event, at: 0, limit: @page_size)
    |> assign(:activity, %{
      activity
      | shown: min(activity.shown + 1, @page_size),
        older?: activity.older? or activity.shown >= @page_size,
        running: watch_running(activity.running, [event])
    })
  end

  defp take_event(socket, _event),
    do: update(socket, :activity, &%{&1 | fresh: &1.fresh + 1})

  # The lines shown whose request still runs, by its exchange, each as
  # drawn: until it ends, or the page loads its lines again.
  defp watch_running(running, events) do
    for %Event{running: %DateTime{}} = event <- events, reduce: running do
      running -> Map.update(running, event.exchange_id, [event], &[event | &1])
    end
  end

  # An opened line read again from the journal, which doesn't know its
  # request runs: while nothing is kept, marked as the page shows it, with
  # what MWT read of the request so far; kept opened, so its request's end
  # draws it as it is then.
  defp still_running(socket, event) do
    running = socket.assigns.activity.running
    shown = Map.get(running, event.exchange_id, [])

    case Enum.find(shown, &(&1.id == event.id)) do
      nil ->
        {event, socket}

      before ->
        event = so_far(socket, %{event | running: before.running})
        others = Enum.reject(shown, &(&1.id == event.id))
        running = Map.put(running, event.exchange_id, [event | others])
        {event, update(socket, :activity, &%{&1 | running: running})}
    end
  end

  defp so_far(socket, %Event{exchange: :none} = event) do
    case Sandbox.request_running(socket.assigns.username, event.exchange_id) do
      %{} = exchange -> %{event | exchange: exchange}
      nil -> event
    end
  end

  # Its exchange is kept: the request ended.
  defp so_far(_socket, event), do: %{event | running: nil}

  # Only a line the page still shows is drawn again: one gone with a newer
  # page, or a page left, isn't brought back. An opened one reads what its
  # request carried, if it was kept.
  defp ended(socket, %Event{exchange: exchange} = event, ms) when not is_nil(exchange) do
    event =
      case Sandbox.event(socket.assigns.username, event.id) do
        %Event{} = read -> read
        nil -> event
      end

    stream_insert(socket, :events, %{event | running: nil, ms: ms || event.ms}, update_only: true)
  end

  defp ended(socket, event, ms),
    do:
      stream_insert(socket, :events, %{event | running: nil, ms: ms || event.ms},
        update_only: true
      )

  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket) do
    assign(socket, :refresh_timer, Process.send_after(self(), :refresh, @refresh_every))
  end

  defp schedule_refresh(socket), do: socket

  defp schedule_stats(%{assigns: %{stats_timer: nil}} = socket),
    do: assign(socket, :stats_timer, Process.send_after(self(), :activity_stats, @stats_every))

  defp schedule_stats(socket), do: socket

  defp load_stats(socket),
    do:
      assign(
        socket,
        :activity_stats,
        Sandbox.event_stats(socket.assigns.username, query_filters(socket))
      )

  # The threads that asked for something in the window, for its filter.
  defp load_threads(socket) do
    since = Map.take(query_filters(socket), [:since])
    assign(socket, :activity_threads, Sandbox.event_threads(socket.assigns.username, since))
  end

  # The page's filters as the journal reads them: the window as a time.
  defp query_filters(socket) do
    {window, filters} = Map.pop(socket.assigns.filters, :window)

    case Map.fetch!(@windows, window) do
      nil -> filters
      seconds -> Map.put(filters, :since, DateTime.add(DateTime.utc_now(), -seconds, :second))
    end
  end

  ## Loading

  defp refresh(socket) do
    username = socket.assigns.username
    snapshot = Sandbox.snapshot(username)
    grant_map = Map.new(snapshot.grants, &{&1.id, &1})

    socket
    |> assign(:now, DateTime.utc_now() |> DateTime.truncate(:second))
    |> assign(snapshot)
    |> assign(:grant_map, grant_map)
    |> assign(:marks, RequestView.marks(snapshot.grants))
    |> follow_handoff()
    |> assign_page_data(grant_map)
  end

  # The handoff being looked at, with what MWT works out about it against
  # your repository as it is now: worked out when you open it and after you
  # act on it, not on every refresh, since it runs git. Its diff only when
  # you ask for it, and, while it waits to land, where its branch is in the
  # VM, to look at it again in Zed.
  defp assign_handoff(socket) do
    username = socket.assigns.username
    id = socket.assigns[:handoff_id]
    handoff = id && kept_handoff(username, id)

    view =
      if socket.assigns[:page] == :handoffs and handoff do
        {facts, error} =
          case Handoffs.facts(username, id) do
            {:ok, facts} -> {facts, nil}
            {:error, reason} -> {nil, Handoffs.explain(reason)}
          end

        view = %{
          handoff: handoff,
          facts: facts,
          error: error,
          diff:
            if(facts && socket.assigns.handoff_diff,
              do: ok(Handoffs.diff(username, id, facts.merge_base))
            ),
          accept: nil,
          worktree: nil
        }

        # A withdrawn one doesn't land until handed off again; where its
        # branch is still shows.
        if handoff.status in [:open, :withdrawn],
          do: %{
            view
            | accept: if(handoff.status != :withdrawn, do: accept_state(view, %{}, username)),
              worktree:
                case Handoffs.worktree(username, id) do
                  {:ok, worktree} -> worktree
                  {:error, _reason} -> :unknown
                end
          },
          else: view
      end

    assign(socket, :handoff_view, view)
  end

  # A new commit on the task's base unless you choose otherwise; your
  # choice is kept while the preview is worked out again.
  defp accept_state(%{handoff: handoff} = view, params, username) do
    options =
      case Handoffs.landing(username, handoff.id) do
        {:ok, options} ->
          options

        {:error, _reason} ->
          %{branches: [], onto: handoff.base_branch, prefix: "mwt/", name: handoff.source.branch}
      end

    previous = view[:accept] || %{}
    onto = params["onto"] || previous[:onto] || options.onto
    how = if (params["how"] || previous[:how]) == "branch", do: "branch", else: "commit"
    name = params["name"] || previous[:name] || options.name
    destination = if how == "branch", do: {:branch, onto, name}, else: {:commit, onto}
    # As it is (its own commits, by a fast-forward) unless you pick one
    # commit; only offered when it could land as it is.
    as = if (params["as"] || previous[:as]) == "one_commit", do: "one_commit", else: "as_is"
    opts = [one_commit: as == "one_commit"]

    preview =
      case Handoffs.preview(username, handoff.id, destination, opts) do
        {:ok, preview} -> {:ok, preview}
        {:error, reason} -> {:error, Handoffs.explain(reason)}
      end

    %{
      onto: onto,
      how: how,
      as: as,
      name: name,
      prefix: options.prefix,
      branches: options.branches,
      destination: destination,
      opts: opts,
      preview: preview,
      form: to_form(%{"onto" => onto, "how" => how, "as" => as, "name" => name}, as: :accept)
    }
  end

  defp ok({:ok, value}), do: value
  defp ok({:error, _reason}), do: nil

  # Between those moments the record itself is kept current: an agent may
  # update the handoff while you look at it.
  defp follow_handoff(%{assigns: %{handoff_view: %{handoff: %{id: id}} = view}} = socket) do
    case kept_handoff(socket.assigns.username, id) do
      nil ->
        assign(socket, :handoff_view, nil)

      handoff ->
        if handoff != view.handoff do
          params =
            if view.accept,
              do: %{
                "onto" => view.accept.onto,
                "how" => view.accept.how,
                "as" => view.accept.as,
                "name" => view.accept.name
              },
              else: %{}

          socket = assign_handoff(socket)

          case socket.assigns.handoff_view do
            %{accept: %{} = _accept} = updated ->
              assign(socket, :handoff_view, %{
                updated
                | accept: accept_state(updated, params, socket.assigns.username)
              })

            _ ->
              socket
          end
        else
          socket
        end
    end
  end

  defp follow_handoff(socket), do: socket

  defp kept_handoff(username, id) do
    case HandoffRecords.get(username, id) do
      {:ok, handoff} -> handoff
      :error -> nil
    end
  end

  defp handoff_action(socket, result, done) do
    case result do
      {:ok, handoff} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_handoff()
         |> put_notice(:success, done, body: "\"#{handoff.title}\"")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_handoff()
         |> put_notice(:warning, "That didn't happen", body: Handoffs.explain(reason))}
    end
  end

  # Where you are in the list: which half, the words searched and the
  # page. Opening a handoff keeps it, for its Back to return there; the
  # address names the half, and another half starts from its first page.
  # The search lasts while the page is open, not after: a search left
  # from before mustn't hide a handoff that came since.
  defp handoff_list_place(socket, id, _filter) when is_integer(id), do: socket

  defp handoff_list_place(socket, nil, filter) do
    filter = if filter == "closed", do: "closed", else: "open"

    if filter == socket.assigns.handoff_place.filter,
      do: socket,
      else: update(socket, :handoff_place, &%{&1 | filter: filter, page: 1})
  end

  # The page of the list where you are, read from the handoffs kept; none
  # while one is open, which shows instead.
  defp load_handoff_list(%{assigns: %{handoff_id: nil}} = socket) do
    %{username: username, handoff_place: place, now: now} = socket.assigns

    assign(
      socket,
      :handoff_listing,
      HandoffRecords.page(username, HandoffsPage.query(place, now))
    )
  end

  defp load_handoff_list(socket), do: assign(socket, :handoff_listing, nil)

  defp handoff_id(nil), do: nil

  defp handoff_id(text) do
    case Integer.parse(to_string(text)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  # The open projects, read when the page opens, after you act on a project
  # and every few seconds (`tick_projects/1`), with their slots, read from
  # the VM apart from the page; what was read last stays shown meanwhile.
  # Projects left in the VM are looked for when the page opens and after
  # you act, not at each tick: measuring them reads the Work disk.
  defp assign_overview(socket, why \\ :act) do
    overview = Projects.overview(socket.assigns.username)

    socket
    |> assign(:project_overview, overview)
    |> read_checkouts(Enum.map(overview.open, & &1.project.name))
    |> then(&if(why == :tick, do: &1, else: assign_leftovers(&1)))
  end

  @projects_every 5_000

  defp tick_projects(%{assigns: %{projects_timer: nil}} = socket) do
    if connected?(socket),
      do:
        assign(
          socket,
          :projects_timer,
          Process.send_after(self(), :projects_tick, @projects_every)
        ),
      else: socket
  end

  defp tick_projects(socket), do: socket

  # Projects left in the VM are looked for while the VM runs, apart from
  # the page: measuring them reads the Work disk.
  defp assign_leftovers(socket) do
    if socket.assigns.vm.status == :running and connected?(socket) do
      username = socket.assigns.username
      start_async(socket, :leftovers, fn -> Leftovers.list(username) end)
    else
      assign(socket, :leftovers, nil)
    end
  end

  # Each open project's checkouts, read side by side: two trips into the VM
  # each. A read still going on is left to finish.
  defp read_checkouts(socket, names) do
    cond do
      socket.assigns.vm.status != :running ->
        assign(socket, :project_worktrees, %{})

      not connected?(socket) or names == [] ->
        socket

      Map.has_key?(socket.private[:live_async] || %{}, :project_checkouts) ->
        socket

      true ->
        username = socket.assigns.username

        socket
        |> update(:project_worktrees, fn worktrees ->
          Enum.reduce(names, worktrees, &Map.put_new(&2, &1, :reading))
        end)
        |> start_async(:project_checkouts, fn ->
          names
          |> Task.async_stream(&{&1, Projects.slots(username, &1)},
            timeout: :infinity,
            max_concurrency: 4
          )
          |> Map.new(fn {:ok, read} -> read end)
        end)
    end
  end

  defp assign_page_data(socket, grant_map) do
    username = socket.assigns.username

    case socket.assigns[:page] do
      :handoffs ->
        load_handoff_list(socket)

      # Its findings are read from the journal here, in the page's own
      # process: a journal held by a long write keeps this page waiting,
      # not the sandbox's server.
      :firewall ->
        findings = Sandbox.events(username, %{group: "firewall", limit: 50})
        assign(socket, :firewall_view, Map.put(Sandbox.firewall(username), :findings, findings))

      :activity ->
        assign(socket, :reading, Sandbox.reading(username))

      :overview ->
        socket = load_console_runs(socket)
        hour = Sandbox.events(username, %{limit: 500})
        since = DateTime.add(socket.assigns.now, -3600, :second)
        last_hour = Enum.filter(hour, &(DateTime.compare(&1.at, since) == :gt))

        socket
        |> assign(:recent, Enum.take(hour, 7))
        |> assign(:stats, %{
          waiting: length(socket.assigns.waiting),
          connections:
            Enum.count(last_hour, &(&1.outcome in [:tunnel, :read, :swapped, :allowed])),
          credentials: Enum.count(last_hour, &(&1.outcome in [:swapped, :allowed])),
          blocked: Enum.count(last_hour, &(&1.outcome in [:blocked, :violation, :firewall]))
        })

      :grant ->
        grant = grant_map[socket.assigns.grant_id]

        socket
        |> assign(:grant, grant)
        |> grant_settings(grant)
        |> assign_new(:value_form, fn -> to_form(%{"value" => ""}, as: :value) end)
        |> assign(
          :grant_events,
          if(grant, do: Sandbox.events(username, %{grant: grant.id, limit: 10}), else: [])
        )

      :resource ->
        resource_settings(socket)

      # The console's history, while its tab shows: another page's runs
      # join it as they end.
      :grants ->
        if socket.assigns.grants_tab == "console", do: load_console_runs(socket), else: socket

      # Your layer's versions: the page says when MWT moved your recipe
      # into them, and lists them when you open them.
      :settings ->
        if socket.assigns.settings_tab == "build",
          do: assign(socket, :layer_versions, Sandbox.layer_versions(username)),
          else: socket

      _other ->
        socket
    end
  end

  # A grant's settings on its page, as its form shows them: taken again
  # from the grant unless you changed them and haven't saved yet.
  defp grant_settings(socket, nil), do: assign(socket, :grant_settings, nil)

  defp grant_settings(socket, %Grant{} = grant) do
    case socket.assigns[:grant_settings] do
      %{id: id, dirty: true} when id == grant.id -> socket
      _other -> assign(socket, :grant_settings, settings_of(grant))
    end
  end

  defp settings_of(%Grant{} = grant) do
    fields =
      grant
      |> edit_fields()
      |> Map.put("start", Atom.to_string(grant.start))

    %{
      id: grant.id,
      form: to_form(fields, as: :grant),
      errors: %{},
      preset: Presets.type_or_preset(grant),
      dirty: false
    }
  end

  # A resource's settings on its page, as its form shows them: taken again
  # from it unless you changed them and haven't saved yet.
  defp resource_settings(socket) do
    found =
      case socket.assigns[:resource] do
        {:credential, id} -> Enum.find(socket.assigns.credentials, &(&1.id == id))
        {:network, id} -> Enum.find(socket.assigns.networks, &(&1.id == id))
        _built_in -> nil
      end

    case {found, socket.assigns[:resource_settings]} do
      {nil, _settings} ->
        assign(socket, :resource_settings, nil)

      {found, %{id: id, dirty: true}} when id == {found.__struct__, found.id} ->
        socket

      {found, _settings} ->
        assign(socket, :resource_settings, resource_settings_of(found))
    end
  end

  defp resource_settings_of(found) do
    %{
      id: {found.__struct__, found.id},
      form: to_form(ResourcePages.form_fields(found), as: :resource),
      errors: %{},
      dirty: false
    }
  end

  defp reset_events(socket), do: load_events(socket, [])

  # The activity page opened on a group, as the Firewall page links to it.
  defp grant_from(socket, id) when is_binary(id) and id != "",
    do: update(socket, :filters, &%{&1 | grant: id})

  defp grant_from(socket, _none), do: socket

  defp thread_from(socket, id) when is_binary(id) and id != "",
    do: update(socket, :filters, &%{&1 | thread: id})

  defp thread_from(socket, _none), do: socket

  defp group_from(socket, group) do
    if is_binary(group) and Map.has_key?(Event.groups(), group),
      do: update(socket, :filters, &%{&1 | group: group}),
      else: socket
  end

  defp release(socket, trust?) do
    socket = assign(socket, :firewall_releasing, false)

    case Sandbox.firewall_release(socket.assigns.username, trust?) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> put_notice(:success, "Released",
           body:
             "The isolation's locks ended, and every grant is as you left it. What you locked yourself stays locked."
         )}

      :error ->
        {:noreply, refresh(socket)}
    end
  end

  defp firewall_set(socket, change) do
    case Sandbox.firewall_set(socket.assigns.username, change) do
      :ok -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, put_notice(socket, :warning, "That isn't a choice here")}
    end
  end

  # The lines are streamed, so they are read again for theirs to show the
  # change. The key empties What MWT reads' fields once the lists changed;
  # a host refused stays in its field, to be put right.
  defp reading_set(socket, change, words) do
    case Sandbox.reading_set(socket.assigns.username, change) do
      :ok ->
        {:noreply,
         socket
         |> assign(:reading, Sandbox.reading(socket.assigns.username))
         |> update(:reading_key, &(&1 + 1))
         |> reset_events()
         |> put_notice(:success, words)}

      {:error, message} ->
        {:noreply, put_notice(socket, :error, message)}
    end
  end

  defp limits_set(socket, id, change) do
    case Sandbox.limits_set(socket.assigns.username, id, change) do
      {:ok, _network} -> {:noreply, refresh(socket)}
      {:error, message} -> {:noreply, put_notice(socket, :error, message)}
    end
  end

  # A resource's page title: its name.
  defp resource_title(socket) do
    case socket.assigns[:resource] do
      nil ->
        "Resource"

      resource ->
        MWTClient.Sandbox.Resource.name(
          resource,
          socket.assigns[:credentials] || [],
          socket.assigns[:networks] || []
        )
    end
  end

  defp reading_words(host, true), do: "MWT reads #{host}"
  defp reading_words(host, false), do: "MWT passes #{host} through unread"

  defp firewall_list(list) do
    Enum.find(MWTClient.Sandbox.Firewall.lists(), &(to_string(&1) == list))
  end

  defp paged(socket), do: push_event(socket, "activity_paged", %{})

  # `cursors` are the ids each older page starts after, the current page's
  # first; none is the newest page. The requests running are asked before
  # the lines are read: one that ends between has its line say how long it
  # took, or hears of its end after.
  defp load_events(socket, cursors) do
    running = Sandbox.requests_running(socket.assigns.username)

    filters =
      socket
      |> query_filters()
      |> Map.put(:limit, @page_size + 1)
      |> then(fn filters ->
        case cursors do
          [before | _] -> Map.put(filters, :before, before)
          [] -> filters
        end
      end)

    {page, rest} = socket.assigns.username |> Sandbox.events(filters) |> Enum.split(@page_size)
    page = Enum.map(page, &mark_running(&1, running))

    socket
    |> assign(:activity, %{
      cursors: cursors,
      older?: rest != [],
      shown: length(page),
      oldest: page |> List.last() |> then(&(&1 && &1.id)),
      fresh: 0,
      running: watch_running(%{}, page)
    })
    |> stream(:events, page, reset: true)
  end

  defp mark_running(%Event{exchange_id: id, ms: nil} = event, running) when is_binary(id),
    do: %{event | running: Map.get(running, id)}

  defp mark_running(event, _running), do: event

  defp assign_vm_form(socket) do
    settings = socket.assigns.settings
    params = Map.new(Settings.vm_fields(), &{Atom.to_string(&1), Map.fetch!(settings, &1)})
    assign(socket, :vm_form, to_form(params, as: :vm))
  end

  # This machine's cores and memory, what MWT suggests and the most it lets
  # you give, read when the page opens.
  defp resources do
    host = Resources.host()
    %{host: host, suggested: Resources.suggested(host), most: Resources.most(host)}
  end

  defp assign_way_form(socket) do
    form = to_form(%{"text" => socket.assigns.settings.way_of_working}, as: :way)
    socket |> assign(:way_form, form) |> assign(:way_error, nil)
  end

  defp assign_host_form(socket) do
    socket
    |> assign(
      :host_form,
      to_form(
        %{
          "notes" => socket.assigns.settings.host_notes,
          "reads" => Enum.join(Map.get(socket.assigns.settings, :confine_reads) || [], "\n")
        },
        as: :host
      )
    )
    |> assign(:host_error, nil)
  end

  defp assign_name_form(socket) do
    assign(
      socket,
      :name_form,
      to_form(%{"name" => socket.assigns.settings.image_name}, as: :image_name)
    )
  end

  defp assign_layer_form(socket) do
    socket
    |> assign(
      :layer_form,
      to_form(%{"image_layer" => socket.assigns.settings.image_layer}, as: :layer)
    )
    |> assign(:layer_error, nil)
  end

  defp page_title(socket) do
    title =
      case socket.assigns.page do
        :grant -> (socket.assigns[:grant] && socket.assigns.grant.name) || "Grant"
        :resource -> resource_title(socket)
        page -> @pages |> List.keyfind(page, 0) |> elem(1)
      end

    assign(socket, :page_title, "#{title} · Agent Sandbox")
  end

  defp vm_action(socket, fun) do
    case fun.(socket.assigns.username) do
      :ok ->
        {:noreply, refresh(socket)}

      {:error, :busy} ->
        {:noreply, put_notice(socket, :info, "The VM is busy; try again in a moment")}

      {:error, :no_image} ->
        {:noreply,
         put_notice(socket, :warning, "Build the image first",
           body: "Setup → Build the image. The VM boots from it."
         )}

      {:error, {:needs, needs}} ->
        {:noreply,
         put_notice(socket, :warning, "This machine can't run the VM yet",
           body: Enum.join(needs, " ")
         )}

      {:error, :no_snapshot} ->
        {:noreply, socket |> refresh() |> put_notice(:warning, "That copy of Home is gone")}

      {:error, :no_memory} ->
        {:noreply,
         put_notice(socket, :warning, "No memory of yours to copy",
           body: "OptMem isn't set up on this machine."
         )}

      {:error, {:no_nested_virt, host}} ->
        {:noreply,
         put_notice(socket, :warning, "This machine doesn't let the VM run VMs",
           body: Settings.nested_virt_text(host) <> " Or turn it off in Settings."
         )}

      {:error, _other} ->
        {:noreply, put_notice(socket, :error, "The VM could not be created with those choices")}
    end
  end

  ## Small things

  defp duration(durations, id), do: Map.get(durations, id, 60)

  defp copied_words,
    do:
      "Its git repositories are projects; the rest is copied into the VM, read-only there, and synced again when you ask."

  # `JS.push` sends the integer as JSON, a form would send a string.
  defp parse_duration("until_off"), do: "until_off"
  defp parse_duration(minutes) when is_integer(minutes), do: minutes
  defp parse_duration(minutes) when is_binary(minutes), do: String.to_integer(minutes)

  defp to_minutes("until_off"), do: :until_off
  defp to_minutes(minutes) when is_integer(minutes), do: minutes

  defp allow_minutes("grant"), do: :grant
  defp allow_minutes(minutes), do: String.to_integer(minutes)

  defp decide(socket, id, decision) do
    case Sandbox.decide(socket.assigns.username, id, decision) do
      :ok ->
        socket

      {:error, :not_waiting} ->
        put_notice(socket, :info, "That was already settled")

      {:error, :bad_decision} ->
        put_notice(socket, :error, "That choice doesn't fit this approval")
    end
  end

  # Whether the add dialog saves the command of a card waiting for you.
  # A grant's own fields, as its form shows them.
  # A run, unless one is going on: the form as it ran, the run kept by
  # the server when it ends (`handle_async/3`).
  defp run_console(socket, params) do
    command = MWTClientWeb.SandboxLive.VmConsole.command(params, socket.assigns.credentials)
    credential = if params["with"] in [nil, ""], do: nil, else: params["with"]

    socket
    |> start_console(command, credential, nil, :live_test)
    |> assign(:console_with, params)
  end

  # One run at a time, from the Live Test or the terminal, as the server
  # keeps them (`handle_async/3`): `dir` is where it starts, `from` who
  # hears how it ended.
  defp start_console(socket, command, credential, dir, from) do
    username = socket.assigns.username

    if socket.assigns.console_running do
      socket
    else
      socket
      |> assign(
        console_running: %{
          command: command,
          credential: credential,
          dir: dir,
          from: from,
          started_at: DateTime.utc_now()
        },
        console_error: nil
      )
      |> start_async(:console, fn ->
        Sandbox.console(username, command, credential, 60, dir)
      end)
    end
  end

  defp load_console_runs(socket),
    do: assign(socket, :console_history, Sandbox.console_runs(socket.assigns.username))

  # A run of the history opened, the history read again first: what it
  # printed is kept with it, what MWT decided read from the activity log.
  defp open_console_run(socket, id) do
    socket = load_console_runs(socket)

    case Enum.find(socket.assigns.console_history, &(&1.id == id)) do
      nil ->
        assign(socket, console_open: nil, console_decisions: [])

      run ->
        assign(socket, console_open: id, console_decisions: console_decisions(socket, run))
    end
  end

  # The requests MWT decided while a console run ran, and in the moment
  # after it, oldest first: an agent's of the same moments among them, as
  # the proxy can't tell.
  defp console_decisions(socket, run) do
    socket.assigns.username
    |> Sandbox.events(%{
      since: run.started_at,
      until: DateTime.add(run.finished_at, 2, :second),
      limit: 50
    })
    |> Enum.filter(&is_binary(&1.host))
    |> Enum.reverse()
  end

  defp console_error(:vm_not_running), do: "The VM isn't running."
  defp console_error(message) when is_binary(message), do: message
  defp console_error(other), do: inspect(other)

  defp changed_start(username, %Grant{} = grant, start) do
    case Enum.find([:off, :on, :auto], &(Atom.to_string(&1) == start)) do
      nil -> {:ok, grant}
      same when same == grant.start -> {:ok, grant}
      start -> Sandbox.set_start(username, grant.id, start)
    end
  end

  # Why a grant didn't turn on, or wasn't accepted, said where you clicked.
  defp turn_on_notice(socket, :no_value),
    do:
      put_notice(socket, :info, "Paste its value first",
        body:
          "Its credential has no value yet: every use would be refused. Paste it on the credential's page."
      )

  defp turn_on_notice(socket, :resource_to_review),
    do:
      put_notice(socket, :info, "Accept its resource first",
        body:
          "An agent proposed the credential or network it is over. Accept that on its page, then this grant."
      )

  defp turn_on_notice(socket, _other), do: socket

  defp edit_fields(%Grant{} = grant) do
    %{
      "name" => grant.name,
      "purpose" => grant.purpose,
      "hosts" => Enum.join(grant.hosts, ", "),
      "resolver" => grant.resolver || "",
      "anchor" => grant.anchor || "",
      "carriers" => Enum.join(grant.carriers, ", "),
      "env" => Enum.join(grant.env, ", "),
      "file_env" => Enum.join(grant.file_env, ", "),
      "git" => to_string(grant.git),
      "mint_per" => Atom.to_string(grant.mint_per),
      "keep_minutes" =>
        if(grant.keep_minutes, do: Integer.to_string(grant.keep_minutes), else: ""),
      "signs_as" => Enum.join(grant.signs_as, ", "),
      "attributes" => MWTClient.Sandbox.Attributes.text(grant.attributes || %{}),
      "covers_unread" => to_string(grant.covers_unread != false),
      "present_metadata" => to_string(Map.has_key?(grant.presents, :metadata)),
      "present_project" => get_in(grant.presents, [:metadata, :project]) || "",
      "present_email" => get_in(grant.presents, [:metadata, :email]) || "",
      "present_login" => to_string(Map.has_key?(grant.presents, :login)),
      "present_id_header" => get_in(grant.presents, [:login, :header]) || "",
      "source" => if(match?({:minted, _}, grant.source), do: "minted", else: "stored"),
      "mint" =>
        case grant.source do
          {:minted, command} -> command
          _stored -> ""
        end,
      # A grant over all of its network lists none: its targets are the
      # network's, and empty says so.
      "destinations" =>
        if(
          grant.kind == :network and is_binary(grant.network) and
            not MWTClient.Sandbox.Network.part?(grant),
          do: "",
          else: Enum.join(grant.destinations, "\n")
        ),
      "except" => Enum.join(grant.except, "\n"),
      "path" => grant.path && Path.basename(grant.path),
      "script" => grant.script,
      "dir" => grant.dir,
      "schema" => MWTClient.Sandbox.ParamSchema.text(grant.params),
      "confined" => to_string(grant.confined),
      "writes_dir" => to_string(grant.writes_dir),
      "with" => Enum.join(grant.with, ", "),
      "method" => grant.method,
      "url" => grant.url,
      "headers" => SavedRequest.header_lines(grant.headers),
      "body" => grant.body || "",
      # A request action's credential; a token grant's own form edits
      # what its credential presents, as it always did.
      "credential" => if(grant.kind in [:request, :token], do: Grant.credential_id(grant)),
      "network" => if(grant.kind == :network, do: grant.network),
      "start" => Atom.to_string(grant.start)
    }
  end

  # What became of a released slot's branch, in a line.
  defp released_words(_branch, nil), do: nil
  defp released_words(branch, {:deleted, _slot}), do: "#{branch} was deleted: nothing needed it."
  defp released_words(branch, {:kept, why}), do: "#{branch} stays: #{Slots.kept_words(why)}."

  defp released_words(branch, {:error, text}),
    do: "#{branch} stays: MWT couldn't prune it. #{text}"

  defp released_words(_branch, _gone), do: nil

  defp task_branches(1), do: "1 task branch"
  defp task_branches(n), do: "#{n} task branches"

  defp stop_words(:not_listening), do: "Nothing listens on that port in the VM any more."
  defp stop_words(:vm_not_running), do: "The VM isn't running."
  defp stop_words(:out_of_range), do: "Only the servers listed here can be killed."
  defp stop_words(message) when is_binary(message), do: message

  defp start_words(:on), do: "on from now and at every start"
  defp start_words(:auto), do: "on from now and at every start, each use going through"

  defp saving_from_card?(_socket, nil), do: false

  defp saving_from_card?(socket, approval_id),
    do: Enum.any?(socket.assigns.waiting, &(&1.id == approval_id and &1.kind == :command))

  # A name for a saved command, from its script: the first command's first
  # words, up to 40 characters.
  defp command_name(script) do
    script
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != "" and not String.starts_with?(&1, "#")))
    |> String.split(~r/\s*(\||&&|;|\|\|)\s*/, parts: 2)
    |> hd()
    |> String.split()
    |> Enum.take(3)
    |> Enum.join(" ")
    |> String.slice(0, 40)
  end

  # Types start unnamed; a preset suggests its own name.
  defp preset_name(%{id: id}) when id in [:token, :network, :saved_command], do: ""
  defp preset_name(%{name: name}), do: name

  # The memories ticked in the review join yours; with `sync?`, yours is
  # then copied into the VM. A text memo refuses stays in the review, with
  # its reason, and nothing is copied.
  defp bring_back(socket, review, picked, sync?) do
    results =
      Sandbox.bring_back(socket.assigns.username, Enum.map(picked, &elem(&1, 1)), review.upto)

    failed =
      for {{entry, text}, {:error, message}} <- Enum.zip(picked, results),
          do: {entry, text, message}

    added = length(picked) - length(failed)

    cond do
      failed == [] and sync? ->
        {:noreply, copy_memory_in(socket, review, added)}

      failed == [] ->
        {:noreply,
         socket
         |> assign(:memory_review, nil)
         |> refresh()
         |> put_notice(:success, "#{added} added to your memory",
           body: "Your next agent session will be asked to summarize them."
         )}

      true ->
        added_indexes =
          MapSet.new(for {{entry, _}, :ok} <- Enum.zip(picked, results), do: entry.index)

        review = %{
          review
          | entries: Enum.reject(review.entries, &MapSet.member?(added_indexes, &1.index)),
            texts: Map.new(failed, fn {entry, text, _} -> {entry.index, text} end),
            errors: Map.new(failed, fn {entry, _, message} -> {entry.index, message} end)
        }

        {:noreply,
         socket
         |> assign(:memory_review, review)
         |> put_notice(:warning, "#{length(failed)} not added",
           body:
             "memo refused them; see each one. #{added} went in. Nothing was copied into the VM."
         )}
    end
  end

  # Yours into the VM, unless it noted more since the review read its log.
  defp copy_memory_in(socket, review, added) do
    added_words = if added > 0, do: "#{added} added to your memory; ", else: ""

    case Sandbox.seed_memory(socket.assigns.username, review.size) do
      :ok ->
        socket
        |> assign(:memory_review, nil)
        |> refresh()
        |> put_notice(:success, "Syncing the VM's memory",
          body: added_words <> "yours is being copied into the VM."
        )

      {:error, :not_running} ->
        put_notice(socket, :warning, "The VM isn't running",
          body: added_words <> "start it, then sync again to copy yours in."
        )

      {:error, :busy} ->
        put_notice(socket, :info, "The VM is busy; try again in a moment",
          body: added_words <> "nothing was copied into the VM yet."
        )

      {:error, :no_memory} ->
        put_notice(socket, :warning, "No memory of yours to copy",
          body: "OptMem isn't set up on this machine."
        )
    end
  end

  defp default_uses(nil), do: :ask
  defp default_uses(grant), do: Grant.default_uses(grant)
end
