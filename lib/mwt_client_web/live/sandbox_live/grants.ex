defmodule MWTClientWeb.SandboxLive.Grants do
  @moduledoc """
  The grants page. What is enabled comes first, in a section of its own
  that no search or filter touches, each with its time left, duration and
  approval mode, changeable there. Those enabled on startup and until off,
  the ones that stay as MWT left them, fold into one row with their count
  and how many auto-approve, opened on a click. Below, the catalog: every
  grant and subgrant is a card, found by a search and by filters down the
  side (enabled or disabled, and type, each with how many it would show),
  in the order you pick. A card has the same controls, compact. One
  grant's page has the same controls, the state it starts in, what the VM
  gets, its subgrants and its allowances; and the dialog that adds a
  grant, of a type or from a preset, or a subgrant.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Firewall, Grant, Param, Presets, SavedRequest}

  @durations [{15, "15 min"}, {60, "1 h"}, {240, "4 h"}, {"until_off", "Until off"}]
  @short_durations [{15, "15m"}, {60, "1h"}, {240, "4h"}, {"until_off", "Until off"}]

  @statuses [{"all", "All"}, {"on", "Enabled"}, {"off", "Disabled"}, {"review", "To review"}]
  @per_page 6
  @sorts [{"recent", "Recently used"}, {"name", "Name"}, {"on", "Enabled first"}]

  @doc "The durations a grant can be turned on for."
  def durations, do: @durations

  @doc "The filters the catalog starts with: everything, most recently used first."
  def filters, do: %{status: "all", type: "all", sort: "recent"}

  @doc "Filters from the form's params, anything unknown left at its default."
  def filters(params) do
    pick = fn key, options ->
      value = params[Atom.to_string(key)]
      if Enum.any?(options, &(elem(&1, 0) == value)), do: value, else: filters()[key]
    end

    type = params["type"]

    %{
      status: pick.(:status, @statuses),
      type: if(type in type_ids(), do: type, else: "all"),
      sort: pick.(:sort, @sorts)
    }
  end

  attr :grants, :list, required: true
  attr :durations, :map, required: true, doc: "the duration picked for each grant that is off"
  attr :modes, :map, default: %{}, doc: "the approval mode picked for each grant that is off"
  attr :now, DateTime, required: true
  attr :term, :string, default: "", doc: "what the search looks for"
  attr :filters, :map, default: %{status: "all", type: "all", sort: "recent"}
  attr :page, :integer, default: 1, doc: "the page of All grants shown, #{@per_page} cards each"

  attr :startup_open, :boolean,
    default: false,
    doc: "whether the row of grants enabled on startup and until off is open"

  def page(assigns) do
    %{grants: grants, term: term, filters: filters, now: now} = assigns
    enabled = Enum.filter(grants, &Grant.on?(&1, now))
    {startup, others} = Enum.split_with(enabled, &standard?/1)
    found = search(grants, term)
    cards = catalog(found, filters, now)
    {shown, page, pages} = paged(cards, assigns.page, @per_page)

    assigns =
      assign(assigns,
        enabled: enabled,
        startup: startup,
        others: others,
        cards: cards,
        shown: shown,
        page: page,
        pages: pages,
        per_page: @per_page,
        to_review: Enum.count(grants, &Grant.to_review?/1),
        statuses: facet(@statuses, by_type(found, filters.type), &status_of(&1, now)),
        types: type_facet(by_status(found, filters.status, now)),
        sorts: @sorts,
        names: Map.new(grants, &{&1.id, &1.name}),
        filtered?: term != "" or filters.status != "all" or filters.type != "all"
      )

    ~H"""
    <.page_header
      id="grants-header"
      title="Grants"
      subtitle="Enable access for as long as a task needs."
    >
      <:help>
        Agents in the VM can ask for a grant with mwt request. Tokens never enter the VM: it gets a placeholder, and MWT swaps the real value in on the way out, once you approve the use or you chose to auto-approve it.
      </:help>
      <:actions>
        <.button id="add-grant" variant="primary" phx-click="open_add_grant">
          <.icon name="hero-plus-micro" class="size-3.5" /> Add grant
        </.button>
      </:actions>
    </.page_header>

    <div
      :if={@to_review > 0}
      id="grants-to-review"
      class="mb-5 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-warn/45 bg-warn-soft/30 px-3 py-2.5 text-[12px] text-ink"
    >
      <.icon name="hero-sparkles" class="size-4 shrink-0 text-warn" />
      <span class="min-w-0 flex-1">
        {if @to_review == 1,
          do: "An agent proposed a grant. It stays off until you review it and accept it.",
          else:
            "Agents proposed #{@to_review} grants. Each stays off until you review it and accept it."}
      </span>
      <button
        type="button"
        id="grants-show-to-review"
        phx-click="filter_grants"
        phx-value-status="review"
        phx-value-term=""
        class="cursor-pointer text-[11px] font-semibold text-accent hover:underline"
      >
        Show {if @to_review == 1, do: "it", else: "them"}
      </button>
    </div>

    <.card
      id="grants-enabled"
      title="Enabled"
      subtitle={enabled_subtitle(@enabled, @now)}
      body_class=""
      class={["mb-8", @enabled != [] && "border-ok/40"]}
    >
      <:help>
        What the VM can use now, all of it: the search and filters of All grants don't apply here. Those enabled on startup and until off fold into one row; open it to change them. Change how long a grant stays enabled, or how its uses are approved, without turning it off: a new duration counts from now.
      </:help>
      <ul class="divide-y divide-line-soft">
        <.grant_row
          :for={grant <- @others}
          prefix="enabled"
          grant={grant}
          under={grant.parent && @names[grant.parent]}
          duration={row_duration(grant, @durations, @now)}
          mode={row_mode(grant, @modes, @now)}
          now={@now}
        />
        <.startup_group
          :if={@startup != []}
          grants={@startup}
          open={@startup_open}
          names={@names}
          durations={@durations}
          modes={@modes}
          now={@now}
        />
      </ul>
    </.card>

    <section id="grants-all" aria-label="All grants">
      <header class="mb-3 flex flex-wrap items-baseline gap-x-2 gap-y-1 border-t border-line-soft pt-5">
        <h2 class="flex items-center gap-1.5 text-[15px] font-semibold tracking-tight text-ink">
          All grants
          <.help id="grants-all-help" label="About all grants">
            Every grant, enabled or disabled, and its subgrants: the uses of it that MWT carries out when an agent calls them by id, each with a switch of its own. Open one for what the VM gets, its subgrants and its allowances. The search and filters apply only here; an enabled grant is also in Enabled, with the same controls.
          </.help>
        </h2>
        <p id="grants-all-count" class="text-[11px] text-muted">
          {all_subtitle(@grants, @cards, @filtered?)}
        </p>
      </header>

      <form
        id="grant-search"
        phx-change="search_grants"
        phx-submit="search_grants"
        class="mb-5 flex flex-wrap items-center gap-3"
        autocomplete="off"
      >
        <div class="relative min-w-64 flex-1">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="term"
            id="grant-search-term"
            value={@term}
            placeholder="Search grants and subgrants: name, what it's for, hosts, scripts, parameters…"
            phx-debounce="120"
            class="w-full rounded-xl border border-line bg-panel py-2.5 pl-10 pr-10 text-[13px] text-ink shadow-sm shadow-black/5 outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
          <button
            :if={@term != ""}
            type="button"
            id="clear-grant-search"
            phx-click="clear_grant_search"
            title="Clear search"
            class="absolute right-2.5 top-1/2 flex size-6 -translate-y-1/2 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <label class="flex items-center gap-2 text-[11px] text-muted">
          Sort
          <select
            name="sort"
            id="grant-sort"
            class="rounded-lg border border-line bg-panel px-2.5 py-2 text-xs text-ink outline-none focus:border-accent/60"
          >
            <option :for={{value, label} <- @sorts} value={value} selected={@filters.sort == value}>
              {label}
            </option>
          </select>
        </label>
        <input type="hidden" name="status" value={@filters.status} />
        <input type="hidden" name="type" value={@filters.type} />
      </form>

      <div class="grid items-start gap-5 lg:grid-cols-[12.5rem_minmax(0,1fr)]">
        <aside id="grant-filters" class="space-y-5 lg:sticky lg:top-0" aria-label="Filters">
          <.facet
            id="grant-status"
            title="Status"
            name="status"
            options={@statuses}
            value={@filters.status}
            term={@term}
            filters={@filters}
          />
          <.facet
            id="grant-type"
            title="Type"
            name="type"
            options={@types}
            value={@filters.type}
            term={@term}
            filters={@filters}
          />
          <button
            :if={@filtered?}
            type="button"
            id="grant-filters-clear"
            phx-click="clear_grant_filters"
            class="inline-flex cursor-pointer items-center gap-1 text-[11px] font-medium text-accent hover:underline"
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" /> Clear search and filters
          </button>
        </aside>

        <div class="min-w-0">
          <div
            :if={@cards == []}
            id="grants-no-match"
            class="rounded-xl border border-dashed border-line"
          >
            <.empty icon="hero-magnifying-glass">
              {no_match_words(@term)}
              <button
                type="button"
                phx-click="clear_grant_filters"
                class="cursor-pointer text-accent hover:underline"
              >
                Clear search and filters
              </button>
            </.empty>
          </div>

          <ul id="grants-all-list" class="grid gap-3 md:grid-cols-2">
            <.grant_card
              :for={card <- @shown}
              grant={card.grant}
              under={card.grant.parent && @names[card.grant.parent]}
              duration={row_duration(card.grant, @durations, @now)}
              mode={row_mode(card.grant, @modes, @now)}
              now={@now}
            />
          </ul>
          <.pages
            :if={@pages > 1}
            name="grants"
            label="Pages of All grants"
            page={@page}
            pages={@pages}
            per_page={@per_page}
            total={length(@cards)}
            event="grants_page"
            class="mt-4"
          />
        </div>
      </div>
    </section>
    """
  end

  attr :grants, :list, required: true, doc: "the enabled grants enabled on startup and until off"
  attr :open, :boolean, required: true
  attr :names, :map, required: true, doc: "every grant's name, by id"
  attr :durations, :map, required: true
  attr :modes, :map, required: true
  attr :now, DateTime, required: true

  # The grants enabled on startup and until off, the ones that stay as MWT
  # left them, as one row: how many, how many auto-approve and how many
  # ask, and their names. Open, each is a row as any other.
  defp startup_group(assigns) do
    auto = Enum.count(assigns.grants, &Grant.auto_approved?(&1, assigns.now))

    assigns =
      assign(assigns,
        auto: auto,
        ask: length(assigns.grants) - auto,
        listed: Enum.map_join(assigns.grants, ", ", & &1.name),
        tiles: Enum.take(assigns.grants, 4),
        more: max(length(assigns.grants) - 4, 0)
      )

    ~H"""
    <li id="enabled-startup" class={@open && "bg-deep/25"}>
      <button
        type="button"
        id="enabled-startup-toggle"
        phx-click="toggle_startup_grants"
        aria-expanded={to_string(@open)}
        aria-controls="enabled-startup-list"
        title={@listed}
        class="group/startup flex w-full cursor-pointer flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2.5 text-left transition-colors hover:bg-hover/40 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <.icon
          name="hero-chevron-right-micro"
          class={[
            "size-4 shrink-0 text-faint transition-transform duration-200 group-hover/startup:text-ink",
            @open && "rotate-90"
          ]}
        />
        <span class="flex shrink-0 -space-x-2" aria-hidden="true">
          <.grant_tile
            :for={grant <- @tiles}
            icon={Presets.icon(grant)}
            on
            class="size-7 ring-2 ring-panel"
          />
          <span
            :if={@more > 0}
            class="flex size-7 items-center justify-center rounded-lg border border-line bg-deep text-[10px] font-semibold text-muted ring-2 ring-panel"
          >
            +{@more}
          </span>
        </span>
        <span class="min-w-0 flex-1 basis-44">
          <span class="flex items-center gap-1.5 text-[13px] font-semibold text-ink">
            <.icon name="hero-power-micro" class="size-3.5 text-ok" /> Enabled on startup
            <span class="font-normal text-faint">· until off</span>
          </span>
          <span id="enabled-startup-names" class="mt-0.5 block truncate text-[11px] text-muted">
            {@listed}
          </span>
        </span>
        <span id="enabled-startup-overview" class="flex shrink-0 flex-wrap items-center gap-1.5">
          <span
            id="enabled-startup-count"
            class="rounded-md bg-deep px-2 py-1 text-[11px] font-semibold tabular-nums text-ink"
          >
            {grants_words(@grants)}
          </span>
          <span
            id="enabled-startup-auto"
            title="Every use goes through without asking. Each is still logged."
            class={[
              "inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium tabular-nums",
              if(@auto > 0, do: "bg-ok-soft/45 text-ok-strong", else: "bg-deep text-faint")
            ]}
          >
            <.icon name="hero-bolt-micro" class="size-3" /> {@auto} auto
          </span>
          <span
            id="enabled-startup-ask"
            title="Every use waits for you."
            class={[
              "inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium tabular-nums",
              if(@ask > 0, do: "bg-accent-soft/40 text-accent-strong", else: "bg-deep text-faint")
            ]}
          >
            <.icon name="hero-hand-raised-micro" class="size-3" /> {@ask} ask
          </span>
        </span>
        <span class="w-9 shrink-0 text-right text-[11px] font-medium text-accent group-hover/startup:underline">
          {if(@open, do: "Hide", else: "Show")}
        </span>
      </button>
      <ul
        :if={@open}
        id="enabled-startup-list"
        class="divide-y divide-line-soft border-t border-line-soft"
      >
        <.grant_row
          :for={grant <- @grants}
          prefix="enabled"
          grant={grant}
          under={grant.parent && @names[grant.parent]}
          duration={row_duration(grant, @durations, @now)}
          mode={row_mode(grant, @modes, @now)}
          now={@now}
        />
      </ul>
    </li>
    """
  end

  @doc """
  Whether an enabled grant is as MWT starts it: enabled on startup, and
  still until off. Turned on for a time, or until off without being
  enabled on startup, it is not, and shows on its own.
  """
  def standard?(%Grant{start: start, expires_at: nil}) when start in [:on, :auto], do: true
  def standard?(%Grant{}), do: false

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true, doc: "`{value, label, count}`"
  attr :value, :string, required: true
  attr :term, :string, required: true
  attr :filters, :map, required: true

  # One filter down the side: a list to pick one from, each with how many
  # cards it would show with the search and the other filters as they are.
  defp facet(assigns) do
    ~H"""
    <form id={@id} phx-change="filter_grants" class="space-y-1.5" aria-label={@title}>
      <input type="hidden" name="term" value={@term} />
      <input
        :for={{key, value} <- @filters}
        :if={Atom.to_string(key) != @name}
        type="hidden"
        name={key}
        value={value}
      />
      <p class="px-2 text-[10px] font-semibold uppercase tracking-wide text-faint">{@title}</p>
      <div role="radiogroup" aria-label={@title} class="space-y-0.5">
        <label
          :for={{value, label, count} <- @options}
          id={"#{@id}-#{value}"}
          class={[
            "flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-[12px] transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
            cond do
              @value == value -> "bg-accent-soft/50 font-medium text-accent-strong"
              count == 0 -> "text-faint hover:bg-hover/50"
              true -> "text-muted hover:bg-hover hover:text-ink"
            end
          ]}
        >
          <input type="radio" name={@name} value={value} checked={@value == value} class="sr-only" />
          <span class="min-w-0 flex-1 truncate">{label}</span>
          <span class="text-[10px] tabular-nums opacity-80">{count}</span>
        </label>
      </div>
    </form>
    """
  end

  attr :grant, Grant, required: true
  attr :under, :string, default: nil, doc: "its grant's name, for a subgrant"
  attr :duration, :any, required: true
  attr :mode, :string, default: "ask"
  attr :now, DateTime, required: true

  # One grant or subgrant in the catalog: what it is and reaches, how it
  # stands, and the controls that turn it on, compact.
  defp grant_card(assigns) do
    assigns = assign(assigns, :on?, Grant.on?(assigns.grant, assigns.now))

    ~H"""
    <li
      id={"grant-card-#{@grant.id}"}
      class={[
        "group/card relative flex min-w-0 flex-col rounded-xl border bg-panel shadow-sm shadow-black/5 transition-all duration-200 hover:-translate-y-0.5 hover:shadow-lg hover:shadow-black/10 dark:shadow-black/30",
        if(@on?,
          do: "border-ok/45 ring-1 ring-ok/15",
          else: "border-line hover:border-accent/40"
        )
      ]}
    >
      <div class="flex flex-1 flex-col p-4 pb-3">
        <div class="flex items-start gap-3">
          <.grant_tile icon={Presets.icon(@grant)} on={@on?} class="size-10" />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <p class="flex min-w-0 flex-1 items-center gap-1 text-[10px] font-medium uppercase tracking-wide text-faint">
                <span class="truncate">{Presets.type_name(@grant)}</span>
                <span
                  :if={@under}
                  id={"grant-under-#{@grant.id}"}
                  class="inline-flex min-w-0 items-center gap-0.5 normal-case tracking-normal"
                >
                  · <.icon name="hero-arrow-turn-down-right-micro" class="size-3 shrink-0" />
                  <span class="truncate">{@under}</span>
                </span>
              </p>
              <.card_state grant={@grant} on?={@on?} now={@now} />
            </div>
            <.link
              patch={~p"/tools/sandbox/grants/#{@grant.id}"}
              id={"grant-link-#{@grant.id}"}
              class="mt-0.5 line-clamp-2 break-words text-[14px] font-semibold leading-5 text-ink transition-colors after:absolute after:inset-0 after:rounded-xl after:content-[''] hover:text-accent"
            >
              {@grant.name}
            </.link>
          </div>
        </div>

        <p
          class={[
            "mt-2.5 line-clamp-2 min-h-8 text-[12px] leading-4",
            if(@grant.purpose != "", do: "text-muted", else: "italic text-faint")
          ]}
          title={@grant.purpose}
        >
          {if @grant.purpose != "", do: @grant.purpose, else: "No description"}
        </p>
        <p
          class="mt-2 truncate rounded-md bg-deep/60 px-2 py-1 font-mono text-[10px] text-muted"
          title={summary(@grant)}
        >
          {summary(@grant)}
        </p>

        <div class="relative z-10 mt-2.5 flex flex-wrap items-center gap-1.5">
          <.proposed_badge grant={@grant} id={"grant-proposed-#{@grant.id}"} />
          <.exposure grant={@grant} />
          <span
            :if={Grant.built_in?(@grant)}
            class="rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
          >
            Built in
          </span>
          <.start_badge grant={@grant} id={"grant-start-#{@grant.id}"} />
          <.ceiling_badge grant={@grant} id={"grant-ceiling-#{@grant.id}"} />
          <.held_badge grant={@grant} id={"grant-held-#{@grant.id}"} />
          <.auto_badge
            :if={Grant.auto_approved?(@grant, @now)}
            id={"grant-auto-#{@grant.id}"}
          />
          <button
            :if={Grant.takes_subgrants?(@grant)}
            type="button"
            id={"add-subgrant-#{@grant.id}"}
            phx-click="open_add_grant"
            phx-value-preset={subgrant_preset(@grant)}
            phx-value-parent={@grant.id}
            title={"Add a subgrant: #{subgrant_words(@grant)}"}
            class="inline-flex cursor-pointer items-center gap-1 rounded border border-dashed border-line px-1.5 py-0.5 text-[10px] font-medium text-muted transition-colors hover:border-accent/50 hover:bg-accent-soft/30 hover:text-accent"
          >
            <.icon name="hero-plus-micro" class="size-3" /> Subgrant
          </button>
        </div>
        <.asks_only
          :if={Grant.ask_to_run?(@grant)}
          id={"grant-asks-only-#{@grant.id}"}
          class="relative z-10"
        />
      </div>

      <footer
        :if={Grant.subgrants_only?(@grant)}
        id={"grant-subgrants-only-#{@grant.id}"}
        class="relative z-10 rounded-b-xl border-t border-line-soft bg-deep/40 px-3 py-2.5 text-[11px] text-muted"
      >
        Nothing to turn on: each subgrant has a switch of its own.
      </footer>
      <footer
        :if={Grant.to_review?(@grant)}
        id={"grant-to-review-#{@grant.id}"}
        class="relative z-10 flex flex-wrap items-center gap-2 rounded-b-xl border-t border-warn/30 bg-warn-soft/20 px-3 py-2.5"
      >
        <span class="min-w-0 flex-1 text-[11px] leading-4 text-muted">
          Off until you review it and accept it.
        </span>
        <.link
          patch={~p"/tools/sandbox/grants/#{@grant.id}"}
          id={"grant-review-#{@grant.id}"}
          class="inline-flex items-center gap-1 rounded-md bg-violet px-2.5 py-1 text-[11px] font-semibold text-deep transition-all hover:brightness-110"
        >
          <.icon name="hero-eye-micro" class="size-3.5" /> Review
        </.link>
      </footer>
      <footer
        :if={not Grant.subgrants_only?(@grant) and not Grant.to_review?(@grant)}
        class={[
          "relative z-10 flex flex-wrap items-center gap-2 rounded-b-xl border-t px-3 py-2.5",
          if(@on?, do: "border-ok/25 bg-ok-soft/15", else: "border-line-soft bg-deep/40")
        ]}
      >
        <.segmented
          id={"grant-duration-#{@grant.id}"}
          options={short_durations()}
          value={@duration}
          event={if(@on?, do: "set_duration", else: "pick_duration")}
          name="minutes"
          values={%{"id" => @grant.id}}
        />
        <.segmented
          :if={Grant.auto_approvable?(@grant)}
          id={"grant-mode-#{@grant.id}"}
          options={[{"ask", "Ask"}, {"all", "Auto"}]}
          value={@mode}
          event={if(@on?, do: "set_mode", else: "pick_mode")}
          name="mode"
          values={%{"id" => @grant.id}}
          tone={:mode}
        />
        <span class="flex-1"></span>
        <.switch
          id={"grant-switch-#{@grant.id}"}
          on={@on?}
          label={if(@on?, do: "Turn #{@grant.name} off", else: "Turn #{@grant.name} on")}
          phx-click={if(@on?, do: "turn_off", else: "turn_on")}
          phx-value-id={@grant.id}
        />
      </footer>
    </li>
    """
  end

  attr :grant, Grant, required: true
  attr :on?, :boolean, required: true
  attr :now, DateTime, required: true

  # Enabled with its time left, or when it was last used.
  defp card_state(assigns) do
    ~H"""
    <%= cond do %>
      <% @on? and @grant.expires_at -> %>
        <span
          id={"grant-left-#{@grant.id}"}
          class="inline-flex shrink-0 items-center gap-1 rounded-full bg-ok-soft/60 px-2 py-0.5 font-mono text-[10px] font-semibold text-ok-strong"
        >
          <span class="size-1.5 rounded-full bg-ok"></span>
          <.clock
            id={"grant-clock-#{@grant.id}"}
            deadline={@grant.expires_at}
            suffix=" left"
            done="ending…"
            now={@now}
          />
        </span>
      <% @on? -> %>
        <span
          id={"grant-left-#{@grant.id}"}
          class="inline-flex shrink-0 items-center gap-1 rounded-full bg-ok-soft/60 px-2 py-0.5 text-[10px] font-semibold text-ok-strong"
        >
          <span class="size-1.5 rounded-full bg-ok"></span> Enabled
        </span>
      <% @grant.last_used_at -> %>
        <span class="shrink-0 text-[10px] text-faint">
          Used <.clock id={"grant-used-#{@grant.id}"} since={@grant.last_used_at} now={@now} />
        </span>
      <% true -> %>
        <span class="shrink-0 text-[10px] text-faint">Never used</span>
    <% end %>
    """
  end

  defp short_durations, do: @short_durations

  defp enabled_subtitle([], _now),
    do: "Nothing is enabled, the Internet included: the VM reaches nothing through MWT."

  defp enabled_subtitle(enabled, now) do
    auto = Enum.count(enabled, &Grant.auto_approved?(&1, now))

    "#{grants_words(enabled)}: " <>
      case {auto, length(enabled) - auto} do
        {0, _ask} -> "every use asks."
        {_auto, 0} -> "every use auto-approved."
        {auto, ask} -> "#{auto} auto-approved, #{ask} asking each time."
      end
  end

  defp all_subtitle(grants, _cards, false), do: grants_words(grants)

  defp all_subtitle(grants, cards, true), do: "#{length(cards)} of #{length(grants)} match."

  defp no_match_words(""), do: "Nothing matches these filters."
  defp no_match_words(term), do: "Nothing matches “#{term}” with these filters."

  @doc """
  The cards the catalog shows: the grants that pass the filters, in the
  order picked. Most recently used first goes by each one's own last use,
  never used last, by name.
  """
  def catalog(grants, filters, now) do
    grants
    |> by_status(filters.status, now)
    |> by_type(filters.type)
    |> sorted(filters.sort, now)
    |> Enum.map(&%{grant: &1})
  end

  defp by_status(grants, "all", _now), do: grants
  defp by_status(grants, status, now), do: Enum.filter(grants, &(status_of(&1, now) == status))

  defp by_type(grants, "all"), do: grants
  defp by_type(grants, type), do: Enum.filter(grants, &(type_id(&1) == type))

  defp status_of(grant, now) do
    cond do
      Grant.to_review?(grant) -> "review"
      Grant.on?(grant, now) -> "on"
      true -> "off"
    end
  end

  defp sorted(grants, "name", _now), do: Enum.sort_by(grants, &String.downcase(&1.name))

  defp sorted(grants, "on", now),
    do: grants |> by_last_use() |> Enum.sort_by(&if(Grant.on?(&1, now), do: 0, else: 1))

  defp sorted(grants, _recent, _now), do: by_last_use(grants)

  # A filter's options with their counts: All, then each option.
  defp facet(options, grants, value_of) do
    counts = Enum.frequencies_by(grants, value_of)

    for {value, label} <- options,
        do:
          {value, label, if(value == "all", do: length(grants), else: Map.get(counts, value, 0))}
  end

  # The types there are, as the catalog filters by them.
  defp type_facet(grants) do
    counts = Enum.frequencies_by(grants, &type_id/1)

    [{"all", "All", length(grants)}] ++
      for type <- Presets.types(),
          id = Atom.to_string(type.id),
          do: {id, type.name, Map.get(counts, id, 0)}
  end

  defp type_ids, do: Enum.map(Presets.types(), &Atom.to_string(&1.id))

  defp type_id(grant), do: grant |> Presets.type_of() |> Map.fetch!(:id) |> Atom.to_string()

  @doc "The kind of subgrant a grant takes, as the preset its form starts from."
  def subgrant_preset(%Grant{kind: :token}), do: "request_subgrant"
  def subgrant_preset(%Grant{}), do: "saved_command"

  defp subgrant_words(%Grant{kind: :token}),
    do: "a request MWT sends with its value, which agents call by id, with parameters"

  defp subgrant_words(%Grant{}), do: "a command of yours that agents call by id, with parameters"

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  # How many grants, and how many of them are subgrants.
  defp grants_words(grants) do
    subgrants = Enum.count(grants, &Grant.subgrant?/1)

    case {length(grants) - subgrants, subgrants} do
      {grants, 0} -> count(grants, "grant")
      {0, subgrants} -> count(subgrants, "subgrant")
      {grants, subgrants} -> "#{count(grants, "grant")}, #{count(subgrants, "subgrant")}"
    end
  end

  # The duration and approval mode a row shows as chosen: on, what the
  # grant is on for and how; off, what you picked for turning it on.
  defp row_duration(grant, durations, now),
    do: if(Grant.on?(grant, now), do: on_duration(grant), else: Map.get(durations, grant.id, 60))

  # What a grant that is on is on for, or until off when it has no end.
  defp on_duration(%Grant{expires_at: nil}), do: "until_off"
  defp on_duration(%Grant{minutes: minutes}) when is_integer(minutes), do: minutes
  defp on_duration(%Grant{}), do: nil

  @doc "The approval mode a grant's row offers while it is off and you picked none (`Grant.default_uses/1`)."
  @spec default_mode(Grant.t()) :: String.t()
  def default_mode(grant), do: if(Grant.default_uses(grant) == :all, do: "all", else: "ask")

  defp row_mode(grant, modes, now) do
    cond do
      not Grant.on?(grant, now) -> Map.get(modes, grant.id, default_mode(grant))
      Grant.auto_approved?(grant, now) -> "all"
      true -> "ask"
    end
  end

  @doc """
  The grants every word of `term` is found in, in any case: in the name,
  what it's for, its type, hosts, variables, destinations, file name,
  script or folder.
  """
  def search(grants, term) do
    case term |> to_string() |> String.downcase() |> String.split() do
      [] ->
        grants

      words ->
        Enum.filter(grants, fn grant ->
          text = searchable(grant)
          Enum.all?(words, &String.contains?(text, &1))
        end)
    end
  end

  defp searchable(grant) do
    [
      grant.name,
      grant.id,
      grant.purpose,
      Presets.type_name(grant),
      grant.hosts,
      grant.env,
      grant.file_env,
      grant.destinations,
      grant.path,
      grant.script,
      grant.dir,
      grant.method,
      grant.url,
      Enum.map(grant.params, &[&1.name, &1.about])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  # Most recently used first; never used last, by name.
  defp by_last_use(grants) do
    Enum.sort_by(grants, fn grant ->
      case grant.last_used_at do
        nil -> {1, 0, String.downcase(grant.name)}
        at -> {0, -DateTime.to_unix(at, :microsecond), String.downcase(grant.name)}
      end
    end)
  end

  attr :grant, Grant, required: true
  attr :duration, :any, required: true
  attr :mode, :string, default: "ask"
  attr :now, DateTime, required: true

  attr :prefix, :string,
    default: "grant",
    doc: "the start of its ids: an enabled grant is in Enabled and in All grants"

  attr :under, :string, default: nil, doc: "its grant's name, for a subgrant"

  # One enabled grant or subgrant: what it is, in four tags at most (enabled
  # on startup, its type, the grant it is a subgrant of, built in or
  # yours), and how long it stays enabled and how it is approved.
  defp grant_row(assigns) do
    ~H"""
    <li
      id={"#{@prefix}-row-#{@grant.id}"}
      class="group/row flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2.5 transition-colors hover:bg-hover/40"
    >
      <.grant_tile icon={Presets.icon(@grant)} on={Grant.on?(@grant, @now)} class="size-8" />
      <div class="min-w-0 flex-1 basis-44">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <.link
            patch={~p"/tools/sandbox/grants/#{@grant.id}"}
            id={"#{@prefix}-link-#{@grant.id}"}
            title={@grant.purpose}
            class="truncate text-[13px] font-semibold text-ink transition-colors hover:text-accent"
          >
            {@grant.name}
          </.link>
          <span id={"#{@prefix}-tags-#{@grant.id}"} class="flex flex-wrap items-center gap-1">
            <.start_badge grant={@grant} id={"#{@prefix}-start-#{@grant.id}"} />
            <span
              :if={Presets.type_name(@grant) != @grant.name}
              id={"#{@prefix}-type-#{@grant.id}"}
              class="rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
            >
              {Presets.type_name(@grant)}
            </span>
            <span
              :if={@under}
              id={"#{@prefix}-under-#{@grant.id}"}
              class="inline-flex items-center gap-1 rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
            >
              <.icon name="hero-arrow-turn-down-right-micro" class="size-3" /> Subgrant of {@under}
            </span>
            <span
              :if={not Grant.proposed?(@grant)}
              id={"#{@prefix}-origin-#{@grant.id}"}
              class="rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
            >
              {if(Grant.built_in?(@grant), do: "Built in", else: "Yours")}
            </span>
            <.proposed_badge grant={@grant} id={"#{@prefix}-origin-#{@grant.id}"} />
          </span>
        </div>
        <p class="mt-0.5 truncate font-mono text-[10px] text-faint" title={summary(@grant)}>
          {summary(@grant)}
        </p>
        <.asks_only :if={Grant.ask_to_run?(@grant)} id={"#{@prefix}-asks-only-#{@grant.id}"} />
      </div>
      <.controls
        grant={@grant}
        id={@prefix}
        duration={@duration}
        mode={@mode}
        now={@now}
        short
      />
    </li>
    """
  end

  attr :grant, Grant, required: true

  attr :id, :string,
    required: true,
    doc: "the prefix of the controls' ids, before their part and the grant's id"

  attr :duration, :any, required: true
  attr :mode, :string, required: true
  attr :now, DateTime, required: true
  attr :short, :boolean, default: false, doc: "the choices in short words, for a list"

  # How long, how its uses are approved, and the switch. On, they change
  # the grant there and then; off, they choose how it turns on.
  defp controls(assigns) do
    on? = Grant.on?(assigns.grant, assigns.now)

    assigns =
      assign(assigns,
        on?: on?,
        values: %{"id" => assigns.grant.id}
      )

    ~H"""
    <div class="flex shrink-0 flex-wrap items-center justify-end gap-x-3 gap-y-2">
      <div class="hidden text-right text-[11px] text-faint lg:block">
        <%= cond do %>
          <% @on? and @grant.expires_at -> %>
            <span
              id={"#{@id}-left-#{@grant.id}"}
              class="rounded-md bg-ok-soft/40 px-2 py-1 font-mono text-[11px] font-semibold text-ok-strong"
            >
              <.clock
                id={"#{@id}-clock-#{@grant.id}"}
                deadline={@grant.expires_at}
                suffix=" left"
                done="ending…"
                now={@now}
              />
            </span>
          <% @on? -> %>
            <span
              id={"#{@id}-left-#{@grant.id}"}
              class="rounded-md bg-ok-soft/40 px-2 py-1 font-mono text-[11px] font-semibold text-ok-strong"
            >
              until off
            </span>
          <% @grant.last_used_at -> %>
            Used <.clock id={"#{@id}-used-#{@grant.id}"} since={@grant.last_used_at} now={@now} />
          <% true -> %>
            Never used
        <% end %>
      </div>
      <.segmented
        id={"#{@id}-duration-#{@grant.id}"}
        options={if(@short, do: short_durations(), else: durations())}
        value={@duration}
        event={if(@on?, do: "set_duration", else: "pick_duration")}
        name="minutes"
        values={@values}
      />
      <.segmented
        :if={Grant.auto_approvable?(@grant)}
        id={"#{@id}-mode-#{@grant.id}"}
        options={
          if(@short,
            do: [{"ask", "Ask"}, {"all", "Auto"}],
            else: [{"ask", "Ask each time"}, {"all", "Auto-approve"}]
          )
        }
        value={@mode}
        event={if(@on?, do: "set_mode", else: "pick_mode")}
        name="mode"
        values={@values}
        tone={:mode}
      />
      <.switch
        id={"#{@id}-switch-#{@grant.id}"}
        on={@on?}
        label={if(@on?, do: "Turn #{@grant.name} off", else: "Turn #{@grant.name} on")}
        phx-click={if(@on?, do: "turn_off", else: "turn_on")}
        phx-value-id={@grant.id}
      />
    </div>
    """
  end

  @doc "A one-line description of what a grant reaches."
  def summary(%Grant{kind: :token} = grant) do
    hosts =
      case grant.hosts do
        [first, second | [_ | _] = rest] -> "#{first}, #{second} +#{length(rest)}"
        hosts -> Enum.join(hosts, ", ")
      end

    case grant.env do
      [] -> "→ #{hosts}"
      env -> "#{Enum.join(env, ", ")} → #{hosts}"
    end
  end

  def summary(%Grant{kind: :network, internet: true}), do: "Every public address"

  def summary(%Grant{kind: :network, destinations: destinations}),
    do: Enum.join(destinations, "  ·  ")

  def summary(%Grant{kind: :mwt, tools: :read}), do: "mwt mcp  ·  list_* and get_*"

  def summary(%Grant{kind: :mwt, tools: :create}),
    do: "mwt mcp  ·  create_* and import_http_request"

  def summary(%Grant{kind: :mwt, tools: :change}), do: "mwt mcp  ·  update_*, as a diff"

  def summary(%Grant{kind: :mwt, tools: :git_fetch}),
    do: "git fetch host-origin and remote-origin, in the projects' clones"

  def summary(%Grant{kind: :mwt, tools: :git_fetch_remote}),
    do: "your repositories' remotes, fetched by this machine into MWT's store"

  def summary(%Grant{kind: :mwt, tools: :git_handoff}),
    do: "mwt handoff, into MWT's review store"

  def summary(%Grant{kind: :mwt, tools: :share_sync}),
    do: "mwt sync, your shared folders' copies in the VM"

  def summary(%Grant{kind: :mwt, tools: :workspace}),
    do: "the workspace's from-vm, copied into ~/mwt-vm/from-vm here"

  def summary(%Grant{kind: :command, script: nil} = grant), do: "mwt run #{grant.id} -- COMMAND"

  def summary(%Grant{kind: :request} = grant),
    do: "#{Grant.signature(grant)}  ·  #{grant.method} #{grant.url}"

  def summary(%Grant{kind: :command, script: script, dir: dir} = grant),
    do: "#{Grant.signature(grant)}  ·  #{script |> String.split("\n") |> hd()}  ·  in #{dir}"

  attr :grant, Grant, required: true
  attr :id, :string, required: true

  # Who proposed it, when an agent did, and whether it still waits for
  # your review.
  defp proposed_badge(assigns) do
    ~H"""
    <span
      :if={Grant.proposed?(@grant)}
      id={@id}
      title={"#{@grant.proposal.agent} proposed it" <> if(@grant.proposal.reason != "", do: ": " <> @grant.proposal.reason, else: "")}
      class="inline-flex items-center gap-1 rounded border border-violet/40 bg-violet/10 px-1.5 py-0.5 text-[10px] font-medium text-violet-strong"
    >
      <.icon name="hero-sparkles-micro" class="size-3" /> Proposed by {@grant.proposal.agent}
    </span>
    <span
      :if={Grant.to_review?(@grant)}
      id={"#{@id}-review"}
      class="inline-flex items-center gap-1 rounded border border-warn/40 bg-warn-soft/40 px-1.5 py-0.5 text-[10px] font-medium text-warn-strong"
    >
      <.icon name="hero-eye-micro" class="size-3" /> To review
    </span>
    """
  end

  attr :grant, Grant, required: true
  attr :id, :string, required: true

  # Enabled each time MWT starts, when it is; how its uses are approved
  # shows apart.
  defp start_badge(assigns) do
    ~H"""
    <span
      :if={@grant.start in [:on, :auto]}
      id={@id}
      title={"Enabled each time MWT starts, until turned off, #{start_approval(@grant)}. Change it on its page."}
      class="inline-flex items-center gap-1 rounded border border-ok/40 bg-ok-soft/40 px-1.5 py-0.5 text-[10px] font-semibold text-ok-strong"
    >
      <.icon name="hero-power-micro" class="size-3" /> Enabled on startup
    </span>
    """
  end

  defp start_approval(%Grant{start: :auto}), do: "every use going through without asking"

  defp start_approval(%Grant{} = grant) do
    if Grant.auto_approvable?(grant),
      do: "every use waiting for you",
      else: "nothing auto-approving it"
  end

  attr :grant, Grant, required: true
  attr :id, :string, required: true

  # A gating check holds it off: every use is refused.
  defp held_badge(assigns) do
    ~H"""
    <span
      :if={@grant.held_by}
      id={@id}
      title={"Paused: #{@grant.held_by}. Every use is refused until that changes."}
      class="inline-flex items-center gap-1 rounded border border-bad/40 bg-bad-soft/40 px-1.5 py-0.5 text-[10px] font-semibold text-bad"
    >
      <span class="size-1.5 rounded-full bg-bad"></span> Paused
    </span>
    """
  end

  attr :grant, Grant, required: true
  attr :id, :string, required: true

  # A grant set to always ask.
  defp ceiling_badge(assigns) do
    ~H"""
    <span
      :if={Grant.ceiling(@grant) == :ask and not Grant.ask_to_run?(@grant)}
      id={@id}
      title="Every use waits for you and is allowed once. No allowance or Auto-approve covers one."
      class="inline-flex items-center gap-1 rounded border border-warn/40 bg-warn-soft/30 px-1.5 py-0.5 text-[10px] font-semibold text-warn-strong"
    >
      <.icon name="hero-hand-raised-micro" class="size-3" /> Always asks
    </span>
    """
  end

  attr :id, :string, required: true

  # Every use goes through without asking while the grant stays on.
  defp auto_badge(assigns) do
    ~H"""
    <span
      id={@id}
      title="Every use goes through without asking while it stays enabled. Each is still logged."
      class="inline-flex items-center gap-1 rounded border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-ok-strong"
    >
      <.icon name="hero-bolt-micro" class="size-3" /> Auto-approve
    </span>
    """
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil

  # What turning Ask to run commands on does, and doesn't.
  defp asks_only(assigns) do
    ~H"""
    <p
      id={@id}
      class={["mt-1 flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong", @class]}
    >
      <.icon name="hero-hand-raised-micro" class="mt-px size-3.5 shrink-0" />
      <span>
        Only while it is enabled may agents <em>ask</em>
        to run a command they wrote here. You read and approve every run; nothing auto-approves one.
      </span>
    </p>
    """
  end

  ## One grant

  attr :grant, Grant, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true
  attr :events, :list, required: true
  attr :duration, :any, required: true, doc: "the duration picked while it is off"
  attr :mode, :string, default: "ask", doc: "the approval mode picked while it is off"
  attr :now, DateTime, required: true
  attr :grants, :list, default: [], doc: "every grant: its own grant, and its subgrants"
  attr :checks, :map, default: %{}, doc: "how each check went last, by check id"
  attr :check_form, :any, default: nil

  def detail(assigns) do
    on? = Grant.on?(assigns.grant, assigns.now)

    assigns =
      assign(assigns,
        parent: Enum.find(assigns.grants, &(&1.id == assigns.grant.parent)),
        subgrants: assigns.grants |> Grant.subgrants(assigns.grant) |> by_last_use(),
        duration: if(on?, do: on_duration(assigns.grant), else: assigns.duration),
        mode:
          cond do
            not on? -> assigns.mode
            Grant.auto_approved?(assigns.grant, assigns.now) -> "all"
            true -> "ask"
          end
      )

    ~H"""
    <nav id="grant-crumbs" class="mb-4 flex flex-wrap items-center">
      <.link
        patch={~p"/tools/sandbox/grants"}
        id="grant-back"
        class="inline-flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-accent"
      >
        <.icon name="hero-arrow-left-micro" class="size-3.5" /> All grants
      </.link>
      <span :if={@parent} class="inline-flex items-center gap-1.5 text-xs text-faint">
        <span class="px-1">/</span>
        <.link
          patch={~p"/tools/sandbox/grants/#{@parent.id}"}
          id="grant-parent"
          class="text-muted transition-colors hover:text-accent"
        >
          {@parent.name}
        </.link>
        <span class="px-1">/</span>
        subgrant
      </span>
    </nav>

    <header id={"grant-detail-#{@grant.id}"} class="mb-5 flex flex-wrap items-center gap-3">
      <.grant_tile icon={Presets.icon(@grant)} on={Grant.on?(@grant)} class="size-11" />
      <div class="min-w-0 flex-1 basis-96">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-lg font-semibold tracking-tight text-ink">{@grant.name}</h1>
          <.proposed_badge grant={@grant} id="detail-proposed" />
          <.exposure grant={@grant} />
          <span class="font-mono text-[10px] text-faint">id {@grant.id}</span>
        </div>
        <p class="mt-0.5 text-[13px] text-muted">
          <span :if={Presets.type_name(@grant) != @grant.name}>{Presets.type_name(@grant)} ·</span>
          <span class="text-ink">{@grant.purpose}</span>
        </p>
        <.asks_only :if={Grant.ask_to_run?(@grant)} id="grant-asks-only" />
      </div>
      <div class="ml-auto flex flex-wrap items-center justify-end gap-3">
        <.button
          :if={not Grant.built_in?(@grant) and not Grant.to_review?(@grant)}
          id="edit-grant"
          variant="ghost"
          phx-click="edit_grant"
          phx-value-id={@grant.id}
        >
          <.icon name="hero-pencil-square-micro" class="size-3.5" /> Edit
        </.button>
        <.start_badge grant={@grant} id="detail-start" />
        <.ceiling_badge grant={@grant} id="detail-ceiling" />
        <.held_badge grant={@grant} id="detail-held" />
        <.auto_badge
          :if={Grant.auto_approved?(@grant, @now)}
          id="detail-auto"
        />
        <.controls
          :if={not Grant.subgrants_only?(@grant) and not Grant.to_review?(@grant)}
          grant={@grant}
          id="detail"
          duration={@duration}
          mode={@mode}
          now={@now}
        />
      </div>
    </header>

    <.review
      :if={Grant.to_review?(@grant)}
      grant={@grant}
      grants={@grants}
      has_value={@has_value}
      now={@now}
    />

    <div class="grid gap-5 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
      <div class="space-y-5">
        <.card id="grant-delivery" title="What the VM gets">
          <:help>{delivery_help(@grant)}</:help>
          <.delivery
            grant={@grant}
            parent_name={(@parent && @parent.name) || "its grant"}
          />
        </.card>

        <.card
          :if={Grant.takes_subgrants?(@grant)}
          id="grant-subgrants"
          title="Subgrants"
          subtitle={subgrants_subtitle(@subgrants)}
          body_class=""
        >
          <:help>
            A subgrant is one fixed use of this grant: {if(@grant.kind == :token,
              do: "a request MWT sends itself with its value",
              else: "a script of yours"
            )}, which agents call by id with a value for each of its parameters and never change. Each has a switch of its own, so it can be on, even always, while this grant stays off.
          </:help>
          <ul class="divide-y divide-line-soft">
            <li
              :for={subgrant <- @subgrants}
              id={"subgrant-#{subgrant.id}"}
              class="flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/40"
            >
              <.grant_tile
                icon={Presets.icon(subgrant)}
                on={Grant.on?(subgrant, @now)}
                class="size-7"
              />
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                  <.link
                    patch={~p"/tools/sandbox/grants/#{subgrant.id}"}
                    id={"subgrant-link-#{subgrant.id}"}
                    class="truncate text-[13px] font-semibold text-ink transition-colors hover:text-accent"
                  >
                    {subgrant.name}
                  </.link>
                  <.start_badge grant={subgrant} id={"subgrant-start-#{subgrant.id}"} />
                </div>
                <p class="mt-0.5 truncate font-mono text-[10px] text-faint">
                  {Grant.signature(subgrant)}
                </p>
              </div>
              <span class={[
                "shrink-0 rounded-md px-2 py-1 text-[11px] font-medium",
                if(Grant.on?(subgrant, @now),
                  do: "bg-ok-soft/40 text-ok-strong",
                  else: "bg-deep text-faint"
                )
              ]}>
                {if(Grant.on?(subgrant, @now), do: "Enabled", else: "Disabled")}
              </span>
            </li>
          </ul>
          <div class="border-t border-line-soft px-4 py-2.5">
            <.button
              id="add-subgrant"
              phx-click="open_add_grant"
              phx-value-preset={subgrant_preset(@grant)}
              phx-value-parent={@grant.id}
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Add a subgrant
            </.button>
          </div>
        </.card>

        <.card
          :if={@grant.kind == :token and @grant.source == :stored}
          id="grant-value-card"
          title="The real value"
        >
          <:help>Kept in your vault, encrypted with your password. MWT never shows it again.</:help>
          <div
            :if={not @has_value}
            id="grant-no-value"
            class="mb-3 flex gap-2 rounded-lg border border-warn/35 bg-warn-soft/30 p-2.5 text-xs text-ink"
          >
            <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0 text-warn" />
            No value yet: requests carrying the placeholder are refused with mwt_no_value.
          </div>
          <.form for={@value_form} id="grant-value-form" phx-submit="set_value" class="flex gap-2">
            <input
              type="password"
              name={@value_form[:value].name}
              id="grant-new-value"
              autocomplete="new-password"
              placeholder={
                if(@has_value, do: "Paste a new value to replace it", else: "Paste the value")
              }
              class={input_classes()}
            />
            <.button type="submit" id="grant-value-save" class="shrink-0 self-start">
              {if @has_value, do: "Replace", else: "Save"}
            </.button>
          </.form>
        </.card>
      </div>

      <div class="space-y-5">
        <.card :if={not Grant.subgrants_only?(@grant)} id="grant-start" title="When MWT starts">
          <:help>
            The state it is in each time MWT starts or unlocks: disabled, or enabled until turned off, asking for each use or auto-approving them. Choosing one puts it in that state now, too. In between, its switch, duration and approval mode change it as for any grant, until the next start.
          </:help>
          <div class="flex flex-wrap items-center gap-3">
            <.segmented
              id={"start-#{@grant.id}"}
              options={
                for start <- Grant.starts(@grant),
                    do: {Atom.to_string(start), start_label(start, Grant.starts(@grant))}
              }
              value={Atom.to_string(@grant.start)}
              event="set_start"
              name="start"
              values={%{"id" => @grant.id}}
              tone={:mode}
              confirm={%{"auto" => confirm_auto(@grant)}}
            />
            <p id="grant-start-words" class="min-w-0 flex-1 basis-48 text-[11px] leading-4 text-muted">
              {start_words(@grant)}
            </p>
          </div>
        </.card>

        <div
          :if={:ask in Grant.ceilings(@grant) and not Grant.subgrants_only?(@grant)}
          id="grant-ceiling"
          class="rounded-xl border border-line-soft px-4 py-3"
        >
          <button
            type="button"
            id={"ceiling-#{@grant.id}"}
            role="switch"
            aria-checked={to_string(Grant.ceiling(@grant) == :ask)}
            phx-click="set_ceiling"
            phx-value-id={@grant.id}
            phx-value-ceiling={if Grant.ceiling(@grant) == :ask, do: "allow", else: "ask"}
            data-confirm={Grant.ceiling(@grant) != :ask && confirm_always_asks(@grant)}
            class="group flex w-full cursor-pointer items-start gap-2.5 text-left"
          >
            <span class={[
              "mt-0.5 flex size-4 shrink-0 items-center justify-center rounded border transition-colors",
              if(Grant.ceiling(@grant) == :ask,
                do: "border-accent bg-accent text-white",
                else: "border-line group-hover:border-accent"
              )
            ]}>
              <.icon :if={Grant.ceiling(@grant) == :ask} name="hero-check-micro" class="size-3" />
            </span>
            <span class="min-w-0">
              <span class="block text-xs font-medium text-ink">Always ask me</span>
              <span id="grant-ceiling-words" class="block text-[11px] leading-4 text-muted">
                Every use waits for you and is allowed once: no auto-approve.
              </span>
            </span>
          </button>
        </div>

        <.host_rules_card :if={@grant.kind == :network} grant={@grant} />

        <.card
          :if={Grant.auto_approvable?(@grant)}
          id="grant-allowances"
          title="Allowed for now"
          body_class=""
        >
          <:help>
            Uses these cover go through without asking. They end with their time, or when the grant turns off.
          </:help>
          <div :if={@grant.allowances == []}>
            <.empty icon="hero-clock">None right now.</.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={allowance <- @grant.allowances}
              id={"allowance-#{allowance.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p :if={allowance.pattern == :all} class="text-[11px] font-medium text-ok-strong">
                  Every use
                </p>
                <p :if={allowance.pattern != :all} class="break-all font-mono text-[11px] text-ink">
                  {allowance.pattern}
                </p>
                <p class="mt-0.5 text-[10px] text-faint">
                  <%= if allowance.until do %>
                    <.clock
                      id={"allowance-left-#{allowance.id}"}
                      deadline={allowance.until}
                      suffix=" left"
                      now={@now}
                    />
                  <% else %>
                    While the grant stays on
                  <% end %>
                </p>
              </div>
              <button
                type="button"
                id={"revoke-allowance-#{allowance.id}"}
                phx-click="revoke_allowance"
                phx-value-id={@grant.id}
                phx-value-allowance={allowance.id}
                class="cursor-pointer rounded px-2 py-1 text-[11px] text-muted transition-colors hover:bg-bad-soft/40 hover:text-bad"
              >
                End now
              </button>
            </li>
          </ul>
        </.card>

        <.checks_card grant={@grant} checks={@checks} form={@check_form} now={@now} />

        <.card id="grant-activity" title="Recent use" body_class="">
          <div :if={@events == []}>
            <.empty icon="hero-queue-list">Nothing has used this grant yet.</.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={event <- @events}
              id={"grant-event-#{event.id}"}
              class="flex items-start gap-2.5 px-4 py-2"
            >
              <.outcome_badge outcome={event.outcome} />
              <p class="min-w-0 flex-1 text-[11px] leading-4 text-ink">{event.summary}</p>
              <span class="shrink-0 text-[10px] text-faint">
                <.clock id={"grant-event-at-#{event.id}"} since={event.at} now={@now} />
              </span>
            </li>
          </ul>
        </.card>

        <section
          :if={not Grant.built_in?(@grant)}
          id="grant-danger"
          class="flex items-center gap-3 rounded-xl border border-bad/25 px-4 py-3"
        >
          <p class="flex-1 text-[11px] leading-4 text-muted">
            {remove_words(@grant, length(@subgrants))}
          </p>
          <.button
            id="delete-grant"
            variant="danger"
            phx-click="confirm_delete_grant"
            phx-value-id={@grant.id}
          >
            Remove
          </.button>
        </section>
      </div>
    </div>
    """
  end

  attr :grant, Grant, required: true

  # A network grant's hosts that go otherwise than its approval mode says
  # (`Grant.host_rules`): each one asked about, let through or refused.
  # The Internet's is where a few public hosts get finer control.
  defp host_rules_card(assigns) do
    assigns =
      assign(assigns,
        form: to_form(%{"host" => "", "action" => "ask"}, as: :host_rule),
        rules: Enum.sort_by(assigns.grant.host_rules, &String.trim_leading(&1.host, "*."))
      )

    ~H"""
    <.card id="grant-host-rules" title="Hosts" body_class="">
      <:help>
        {host_rules_help(@grant)}
      </:help>
      <ul :if={@rules != []} id="grant-host-rules-list" class="divide-y divide-line-soft">
        <li
          :for={rule <- @rules}
          id={"host-rule-#{host_rule_id(rule.host)}"}
          class="flex items-center gap-3 px-4 py-2"
        >
          <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={rule.host}>
            {rule.host}
          </span>
          <.segmented
            id={"host-rule-#{host_rule_id(rule.host)}-action"}
            options={[{"ask", "Ask"}, {"auto", "Auto"}, {"block", "Block"}]}
            value={to_string(rule.action)}
            event="host_rule_put"
            name="action"
            values={%{"id" => @grant.id, "host" => rule.host}}
          />
          <button
            type="button"
            id={"host-rule-#{host_rule_id(rule.host)}-remove"}
            phx-click="host_rule_remove"
            phx-value-id={@grant.id}
            phx-value-host={rule.host}
            title={"Take #{rule.host} off: its uses go as #{@grant.name}'s mode says"}
            class="cursor-pointer rounded p-1 text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" />
          </button>
        </li>
      </ul>
      <p :if={@rules == []} id="grant-host-rules-empty" class="px-4 py-2.5 text-[11px] text-faint">
        No host of its own: every use goes as {@grant.name}'s approval mode says.
      </p>
      <.form
        for={@form}
        id="grant-host-rule-form"
        phx-submit="host_rule_add"
        class="flex flex-wrap items-center gap-2 border-t border-line-soft bg-deep/30 px-4 py-2"
      >
        <input type="hidden" name="grant" value={@grant.id} />
        <div class="min-w-0 flex-1">
          <input
            type="text"
            name={@form[:host].name}
            id="grant-host-rule-host"
            value=""
            placeholder="api.example.com"
            title="A host name: it covers every name under it too"
            spellcheck="false"
            autocomplete="off"
            class={[input_classes(), "font-mono"]}
          />
        </div>
        <div class="w-24 shrink-0">
          <select name={@form[:action].name} id="grant-host-rule-action" class={input_classes()}>
            <option value="ask">Ask</option>
            <option value="auto">Auto</option>
            <option value="block">Block</option>
          </select>
        </div>
        <.button type="submit" id="grant-host-rule-add">Add</.button>
      </.form>
    </.card>
    """
  end

  defp host_rules_help(%Grant{internet: true}),
    do:
      "Public hosts that go otherwise than the Internet's mode says. Ask: each request MWT reads there waits for you, and a connection it can't read is asked about as one. Auto: each goes through. Block: each is refused. An entry covers its name and every name under it, on any port; the most exact one decides. A connection MWT can't read is held by the strictest entry for any name it may be for: the name it asked for, and the names MWT's DNS answered for its address."

  defp host_rules_help(%Grant{}),
    do:
      "Hosts under this grant that go otherwise than its mode says. Ask: each request MWT reads there waits for you, and a connection it can't read is asked about as one. Auto: each goes through. Block: each is refused. An entry covers its name and every name under it, on any port; the most exact one decides."

  # A DOM id for a host entry: its letters, digits and dashes, a star as `any`.
  defp host_rule_id(host),
    do: host |> String.replace("*", "any") |> String.replace(~r/[^a-z0-9-]/, "-")

  attr :grant, Grant, required: true
  attr :grants, :list, required: true
  attr :has_value, :boolean, required: true
  attr :now, DateTime, required: true

  # A grant an agent proposed, waiting for you: who, why, what to look at,
  # and accepting it, which is what lets it turn on.
  defp review(assigns) do
    grant = assigns.grant
    proposal = grant.proposal

    assigns =
      assign(assigns,
        proposal: proposal,
        minutes: Map.get(proposal, :minutes) || 60,
        needs_value?:
          grant.kind == :token and grant.source == :stored and not Grant.subgrants_only?(grant) and
            not assigns.has_value,
        hints:
          if(Grant.saved_command?(grant),
            do:
              MWTClient.Sandbox.Param.hints(grant.params, grant.script) ++
                MWTClient.Sandbox.HostCommand.hints(grant.script, assigns.grants),
            else: []
          )
      )

    ~H"""
    <section
      id="grant-review"
      class="mb-5 overflow-hidden rounded-xl border border-warn/45 bg-panel shadow-sm"
    >
      <div class="flex flex-wrap items-start gap-3 bg-warn-soft/25 px-4 py-3.5">
        <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-violet/15 text-violet-strong">
          <.icon name="hero-sparkles" class="size-5" />
        </span>
        <div class="min-w-0 flex-1 basis-80">
          <h2 class="text-[14px] font-semibold text-ink">
            {@proposal.agent} proposed this grant
            <span :if={@proposal.at} class="text-[11px] font-normal text-muted">
              · <.clock id="grant-review-since" since={@proposal.at} now={@now} />
            </span>
          </h2>
          <p
            :if={@proposal.thread && @proposal.thread[:title]}
            id="grant-review-thread"
            class="mt-0.5 truncate text-[11px] text-muted"
          >
            From the thread “{@proposal.thread[:title]}”{if @proposal.thread[:folder],
              do: " in #{@proposal.thread[:folder]}"}
          </p>
          <p
            :if={@proposal.reason != ""}
            id="grant-review-reason"
            class="mt-2 break-words rounded-lg border border-line-soft bg-deep/50 px-3 py-2 text-xs leading-5 text-ink"
          >
            {@proposal.reason}
          </p>
          <p class="mt-2 text-[11px] leading-4 text-muted">
            The agent's words, until you accept them. Read what it opens below{if @needs_value?,
              do: ", paste its value"}, and edit anything first. Nothing turns it on, an agent's ask included, until you accept it here.
          </p>
          <ul :if={@hints != []} id="grant-review-hints" class="mt-2 space-y-1">
            <li
              :for={hint <- @hints}
              class="flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
            >
              <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
              <span>{hint}</span>
            </li>
          </ul>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2 border-t border-warn/25 px-4 py-3">
        <button
          type="button"
          id="grant-accept-enable"
          phx-click="review_grant"
          phx-value-id={@grant.id}
          phx-value-enable={@minutes}
          disabled={@needs_value? or Grant.subgrants_only?(@grant)}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95 disabled:cursor-default disabled:opacity-40 disabled:hover:brightness-100"
        >
          <.icon name="hero-check-micro" class="size-3.5" />
          Accept and enable for {minutes_words(@minutes)}
        </button>
        <button
          type="button"
          id="grant-accept"
          phx-click="review_grant"
          phx-value-id={@grant.id}
          phx-value-enable="keep_off"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-accent/50 hover:bg-accent-soft/30 hover:text-accent"
        >
          Accept, keep disabled
        </button>
        <span
          :if={@needs_value?}
          id="grant-review-needs-value"
          class="text-[11px] text-warn-strong"
        >
          Paste its value below to enable it.
        </span>
        <span class="flex-1"></span>
        <button
          type="button"
          id="grant-review-edit"
          phx-click="edit_grant"
          phx-value-id={@grant.id}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium text-muted transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-pencil-square-micro" class="size-3.5" /> Edit
        </button>
        <button
          type="button"
          id="grant-review-remove"
          phx-click="confirm_delete_grant"
          phx-value-id={@grant.id}
          class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
        >
          Remove
        </button>
      </div>
    </section>
    """
  end

  defp remove_words(%Grant{kind: :token}, subgrants),
    do:
      "Removing it refuses anything waiting on it#{if subgrants > 0, do: ", and removes its subgrants"}. The VM keeps the placeholder, which is worthless on its own."

  defp remove_words(%Grant{} = grant, subgrants) do
    if Grant.subgrant?(grant),
      do: "Removing it refuses calls waiting on it. Agents can no longer call it by its id.",
      else:
        "Removing it refuses anything waiting on it#{if subgrants > 0, do: ", and removes its subgrants"}."
  end

  defp subgrants_subtitle([]), do: "None yet."
  defp subgrants_subtitle(subgrants), do: "#{length(subgrants)}, each with a switch of its own."

  # The setting's name, with how uses are approved only where both are
  # offered.
  defp start_label(:off, _starts), do: "Disabled"

  defp start_label(:on, starts),
    do: if(:auto in starts, do: "Enabled, ask", else: "Enabled")

  defp start_label(:auto, starts),
    do: if(:on in starts, do: "Enabled, auto", else: "Enabled")

  defp start_words(%Grant{start: :off}),
    do: "It starts disabled. You, or an agent's ask, enable it for a time."

  defp start_words(%Grant{start: :on} = grant) do
    cond do
      Grant.ask_to_run?(grant) ->
        "Enabled on startup, until turned off: agents may ask to run commands, and every run waits for you."

      Grant.auto_approvable?(grant) or Grant.ceiling(grant) == :ask ->
        "Enabled on startup, until turned off. Every use still waits for you."

      true ->
        "Enabled on startup, until turned off."
    end
  end

  defp start_words(%Grant{start: :auto}),
    do:
      "Enabled on startup, until turned off, and every use goes through without asking. Each is still logged."

  attr :grant, Grant, required: true
  attr :checks, :map, required: true
  attr :form, :any, required: true
  attr :now, DateTime, required: true

  # Scripts of yours that say the grant still holds: how each went last,
  # Run now, and a form to add one.
  defp checks_card(assigns) do
    assigns = assign(assigns, form: assigns.form || to_form(%{}, as: :check))

    ~H"""
    <.card :if={not Grant.ask_to_run?(@grant)} id="grant-checks" title="Only while…" body_class="">
      <:help>
        Conditions this grant needs, each a short script of yours run on this machine: exit 0 means it holds. They run as it turns on, once a day while it is on, and when you ask. While one fails, the grant is paused: off, and agents are told the condition's name.
      </:help>
      <div :if={@grant.checks == []} class="px-4 py-3 text-[11px] text-muted">
        None: it works whenever it is on. Add one such as “the VPN is up” to pause it otherwise.
      </div>
      <ul :if={@grant.checks != []} class="divide-y divide-line-soft">
        <li
          :for={check <- @grant.checks}
          id={"check-#{check.id}"}
          class="flex items-start gap-3 px-4 py-2.5"
        >
          <.check_dot status={check_status(@checks[check.id])} />
          <div class="min-w-0 flex-1">
            <p class="text-xs font-medium text-ink">
              {check.name}
              <span :if={not check.gates} class="ml-1 text-[10px] font-normal text-faint">
                (tells you only)
              </span>
            </p>
            <code class="mt-0.5 block truncate font-mono text-[10px] text-muted">{check.script}</code>
            <p id={"check-status-#{check.id}"} class="mt-0.5 text-[10px] text-faint">
              {check_words(@checks[check.id], @now)}
            </p>
            <pre
              :if={match?(%{result: %{ok?: false, output: o}} when o != "", @checks[check.id])}
              class="mt-1 max-h-24 overflow-auto whitespace-pre-wrap rounded border border-line-soft bg-deep/60 p-1.5 font-mono text-[10px] text-muted"
            >{@checks[check.id].result.output}</pre>
          </div>
          <button
            type="button"
            id={"remove-check-#{check.id}"}
            phx-click="remove_check"
            phx-value-id={@grant.id}
            phx-value-check={check.id}
            class="cursor-pointer rounded px-2 py-1 text-[11px] text-muted transition-colors hover:bg-bad-soft/40 hover:text-bad"
          >
            Remove
          </button>
        </li>
      </ul>
      <div
        :if={@grant.checks != []}
        class="flex items-center gap-2 border-t border-line-soft px-4 py-2"
      >
        <.button
          id="run-checks"
          variant="ghost"
          phx-click="run_checks"
          phx-value-id={@grant.id}
        >
          <.icon name="hero-play-micro" class="size-3.5" /> Run now
        </.button>
      </div>
      <details id="add-check" class="group border-t border-line-soft">
        <summary class="flex cursor-pointer list-none items-center gap-1.5 px-4 py-2 text-[11px] font-medium text-accent [&::-webkit-details-marker]:hidden">
          <.icon name="hero-plus-micro" class="size-3.5" /> Add a condition
        </summary>
        <.form for={@form} id="add-check-form" phx-submit="add_check" class="space-y-2 px-4 pb-3">
          <input type="hidden" name="grant_id" value={@grant.id} />
          <.input
            field={@form[:name]}
            label="The condition"
            placeholder="the VPN is up"
            help={field_help(:check_name)}
          />
          <.input
            field={@form[:script]}
            type="textarea"
            rows="2"
            label="How to tell: exit 0 means it holds"
            help={field_help(:check_script)}
            placeholder="ip link show wg0 up | grep -q UP"
            class={[input_classes(), "font-mono text-xs"]}
          />
          <.button type="submit" id="add-check-save">Add and run it</.button>
        </.form>
      </details>
    </.card>
    """
  end

  attr :status, :atom, required: true

  defp check_dot(assigns) do
    ~H"""
    <span class={[
      "mt-1 size-2 shrink-0 rounded-full",
      case @status do
        :ok -> "bg-ok"
        :failed -> "bg-bad"
        :running -> "bg-warn motion-safe:animate-pulse"
        :never -> "bg-line"
      end
    ]}></span>
    """
  end

  defp check_status(%{running?: true}), do: :running
  defp check_status(%{result: %{ok?: true}}), do: :ok
  defp check_status(%{result: %{ok?: false}}), do: :failed
  defp check_status(_none), do: :never

  defp check_words(%{running?: true}, _now), do: "Running…"
  defp check_words(%{result: nil}, _now), do: "Not run yet"
  defp check_words(nil, _now), do: "Not run yet"

  defp check_words(%{result: result}, _now) do
    at = Calendar.strftime(result.at, "%b %-d, %H:%M UTC")

    if result.ok?,
      do: "Holds, since it ran #{at}",
      else: "Failed #{at}#{if result.exit, do: " (exit #{result.exit})", else: ""}"
  end

  defp confirm_always_asks(grant) do
    "#{grant.name} will ask for every use from now: its allowances end, Auto-approve included" <>
      if(grant.start == :auto, do: ", and it starts Enabled, ask", else: "") <> ". Continue?"
  end

  # Enabled on startup and auto-approved is for what you fully trust: it
  # says what that means.
  defp confirm_auto(grant) do
    "From now, and each time MWT starts, #{grant.name} is enabled and every use of it goes " <>
      "through without asking. Each is still logged. Enable it on startup, auto-approved?"
  end

  defp delivery_help(%Grant{internet: true}),
    do:
      "Nothing to hold. While this is on, the VM reaches any public address, through MWT and its firewall. Off, it reaches only what other grants list, DNS answers only their names, and turning it off closes every connection it let through."

  defp delivery_help(%Grant{kind: kind}), do: delivery_help(kind)

  defp delivery_help(:token),
    do:
      "The VM sees a placeholder. When a request carrying it in one of its headers goes to one of these hosts, MWT asks you, swaps in the real value and sends it on. Sent anywhere else, it is blocked and logged."

  defp delivery_help(:network),
    do:
      "Nothing to hold. While this is on, MWT lets the VM's connections to these destinations through, from this machine, so they reach whatever your network or VPN reaches. Services behind a VPN often trust where a connection comes from, so the VM acts as you there: list destinations, not whole networks, where you can."

  defp delivery_help(:request),
    do:
      "Nothing. MWT sends this request itself when an agent calls it, with the grant's real value."

  defp delivery_help(:command),
    do:
      "Nothing to hold. While this is on, agents may ask MWT to run a command on this machine, as you, outside the VM. Each run shows on a card with its exact text and waits for you; nothing lets one through unasked. It is for jobs that need what only this machine has, so the work goes to the value instead of the value to the VM."

  defp delivery_help(:mwt),
    do:
      "Nothing to hold. MWT's own tools, notes, diagrams, flash cards and HTTP samples, through the MCP server mwt mcp in the VM: MWT carries each call out itself, on this machine, so no token is in the VM."

  attr :grant, Grant, required: true
  attr :parent_name, :string, default: nil, doc: "a subgrant's grant, by name"

  defp delivery(%{grant: %Grant{kind: :token, reach: :subgrants}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-xs">
      <dt class="pt-0.5 text-muted">In the VM</dt>
      <dd id={"grant-subgrants-only-#{@grant.id}"} class="text-[11px] text-ink">
        Nothing: no placeholder, no variable, no file. Its value is only for its subgrants, which MWT sends itself, each with a switch of its own. mwt exec {@grant.id} runs nothing.
      </dd>

      <dt class="pt-0.5 text-muted">Its subgrants go to</dt>
      <dd class="flex flex-wrap gap-1.5">
        <span
          :for={host <- @grant.hosts}
          class="rounded border border-line bg-deep px-1.5 py-0.5 font-mono text-[11px] text-ink"
        >
          {host}
        </span>
      </dd>

      <dt class="pt-0.5 text-muted">Real value</dt>
      <dd>
        <%= case @grant.source do %>
          <% {:minted, command} -> %>
            <p class="text-[11px] text-ink">Minted on this machine when needed, by</p>
            <code class="mt-1 block break-all rounded-md border border-line-soft bg-deep px-2 py-1.5 font-mono text-[10px] leading-4 text-muted">
              {command}
            </code>
            <.kept_line grant={@grant} />
          <% :stored -> %>
            <p class="text-[11px] text-ink">Stored in your vault</p>
        <% end %>
      </dd>
    </dl>
    """
  end

  defp delivery(%{grant: %Grant{kind: :token}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-xs">
        <dt class="pt-0.5 text-muted">In the VM</dt>
        <dd class="space-y-1">
          <p id={"grant-exec-#{@grant.id}"} class="select-all font-mono text-[11px] text-ink">
            mwt exec {@grant.id} -- COMMAND
          </p>
          <p class="text-[11px] text-faint">
            While this grant is on, only that command and its children get these variables.
            Ordinary shells and editors get no credential exports.
          </p>
          <p :for={var <- @grant.env} class="font-mono text-[11px] text-ink">
            {var}=<span class="select-all text-muted">{@grant.placeholder}</span>
          </p>
          <p :for={var <- @grant.file_env} class="font-mono text-[11px] text-ink">
            {var}=<span class="text-muted">{Grant.token_file(@grant)}</span>
          </p>
          <p class="text-[11px] text-faint">
            The file {Grant.token_file(@grant)} holds the placeholder too.
          </p>
          <p :if={Grant.git_hosts(@grant) != []} class="text-[11px] text-faint">
            Within that command, git over HTTPS gets it from MWT's credential helper for {Enum.join(
              Grant.git_hosts(@grant),
              ", "
            )}.
          </p>
          <p
            :if={Map.has_key?(@grant.presents, :metadata)}
            id={"grant-present-#{@grant.id}"}
            class="text-[11px] text-faint"
          >
            Within that command, a cloud metadata server on loopback (GCE_METADATA_HOST) gives it as the access token of {@grant.presents.metadata.project}{if @grant.presents.metadata.email !=
                                                                                                                                                                 "",
                                                                                                                                                               do:
                                                                                                                                                                 ", as #{@grant.presents.metadata.email}"}.
          </p>
          <p
            :if={@grant.signs_as != []}
            id={"grant-signs-as-#{@grant.id}"}
            class="text-[11px] text-faint"
          >
            Within that command, MWT answers a request to sign a JWT as {Enum.join(
              @grant.signs_as,
              ", "
            )} itself: it signs with the real value, and the command gets a placeholder JWT that goes only to the host its aud names. The VM may act as these accounts toward the hosts below.
          </p>
          <p
            :if={Grant.login_placeholder(@grant)}
            id={"grant-login-#{@grant.id}"}
            class="text-[11px] text-faint"
          >
            Within that command, GOOGLE_APPLICATION_CREDENTIALS names a login file of placeholders ({Grant.login_file(
              @grant
            )}): MWT answers its refresh from the mint, and an ID token the mint prints goes only to the hosts below, in {Enum.join(
              Grant.id_token_carriers(@grant),
              " or "
            )}.
          </p>
        </dd>

        <dt class="pt-0.5 text-muted">May go to</dt>
        <dd class="flex flex-wrap gap-1.5">
          <span
            :for={host <- @grant.hosts}
            class="rounded border border-line bg-deep px-1.5 py-0.5 font-mono text-[11px] text-ink"
          >
            {host}
          </span>
        </dd>

        <dt class="pt-0.5 text-muted">Swapped in</dt>
        <dd id={"grant-carriers-#{@grant.id}"} class="text-[11px] text-ink">
          Only {Enum.join(Grant.carriers(@grant), ", ")}, Basic credentials included.
          A placeholder in any other header is refused.
        </dd>

        <dt class="pt-0.5 text-muted">Real value</dt>
        <dd>
          <%= case @grant.source do %>
            <% {:minted, command} -> %>
              <p class="text-[11px] text-ink">Minted on this machine when needed, by</p>
              <code class="mt-1 block break-all rounded-md border border-line-soft bg-deep px-2 py-1.5 font-mono text-[10px] leading-4 text-muted">
                {command}
              </code>
              <.kept_line grant={@grant} />
            <% :stored -> %>
              <p class="text-[11px] text-ink">Stored in your vault</p>
          <% end %>
        </dd>
      </dl>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :network, internet: true}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div
        id="grant-internet"
        class="flex items-center gap-2 rounded-md border border-line-soft bg-deep px-2.5 py-1.5"
      >
        <.icon name="hero-globe-alt-micro" class="size-3.5 text-accent" />
        <span class="text-[11px] text-ink">Every public address on the internet</span>
      </div>
      <p id="grant-internet-off" class="text-[11px] leading-4 text-muted">
        Off, the VM still reaches token grants' hosts, every request read by MWT, and network
        grants' destinations; nothing else. Agents reach their model's API over the internet:
        to keep them working with this off, list it in a network grant (<span class="font-mono">api.anthropic.com:443</span>).
      </p>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :network}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <ul class="space-y-1.5">
        <li
          :for={destination <- @grant.destinations}
          class="flex items-center gap-2 rounded-md border border-line-soft bg-deep px-2.5 py-1.5"
        >
          <.icon name="hero-signal-micro" class="size-3.5 text-accent" />
          <span class="font-mono text-[11px] text-ink">{destination}</span>
        </li>
      </ul>
      <p
        :if={@grant.resolver || @grant.anchor}
        id={"grant-network-#{@grant.id}"}
        class="text-[11px] leading-4 text-muted"
      >
        <span :if={@grant.resolver}>
          Its names are asked of <span class="font-mono text-ink">{@grant.resolver}</span>.
        </span>
        <span :if={@grant.anchor}>
          It goes only through <span class="font-mono text-ink">{@grant.anchor}</span>,
          and opens nothing while that is down.
        </span>
      </p>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :mwt, tools: tools}} = assigns)
       when tools in [:git_fetch, :git_fetch_remote, :git_handoff, :share_sync, :workspace] do
    ~H"""
    <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
      <dt class="text-muted">
        {case @grant.tools do
          :share_sync -> "Shared folders"
          :workspace -> "Workspace"
          _git -> "Git"
        end}
      </dt>
      <dd id="grant-git-tools" class="text-[11px] text-ink">
        <%= case @grant.tools do %>
          <% :git_fetch -> %>
            <code class="font-mono">git fetch host-origin</code>
            and <code class="font-mono">git fetch remote-origin</code>
            in a project's clone: your committed branches and tags, and the branches of your repository's own remote origin. MWT serves them from a view of your repository; its configuration, hooks and working files never travel. A push is always refused.
          <% :git_fetch_remote -> %>
            Before <code class="font-mono">remote-origin</code>
            answers, this machine runs <code class="font-mono">git fetch</code>
            of your repository's own remote, with your credentials and without prompting, into MWT's store, never into your repository, at most once a minute. Off, remote-origin shows the remote branches as you last fetched them.
          <% :git_handoff -> %>
            <code class="font-mono">mwt handoff</code>: an agent's exact commit, into MWT's review store, never into your repository. Landing is never a grant: you decide it on the Handoffs page.
          <% :share_sync -> %>
            <code class="font-mono">mwt sync</code>: the same sync as the Sync button, for every shared folder or the one an agent names. Your files are copied into the VM, where they are read-only; nothing of the VM comes back.
          <% :workspace -> %>
            At each sync of your shared folders, what agents left in the workspace's
            <code class="font-mono">from-vm</code>
            folder is copied into <code class="font-mono">~/mwt-vm/from-vm</code>
            here, read-only: regular files and folders only, nothing executable, no name starting with a dot or a dash, at most 1 GiB, and nothing holding a grant's real value. The VM never chooses where it is written, and nothing of it runs here by itself.
        <% end %>
      </dd>
      <dt class="text-muted">Built in</dt>
      <dd class="text-[11px] text-ink">
        MWT's own, so it can't be edited or removed. Turn it off, or change how it starts, below.
      </dd>
    </dl>
    """
  end

  defp delivery(%{grant: %Grant{kind: :mwt}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
      <dt class="text-muted">Tools</dt>
      <dd id="grant-mwt-tools" class="text-[11px] text-ink">
        <%= case @grant.tools do %>
          <% :read -> %>
            <code class="font-mono">list_*</code>
            and <code class="font-mono">get_*</code>: your notes, diagrams and flash cards, yours and agents'. Never HTTP requests: your history holds the credentials you sent, so from the VM they are only added.
          <% :create -> %>
            <code class="font-mono">create_*</code>
            and <code class="font-mono">import_http_request</code>: new notes, diagrams, flash cards and, when you ask an agent for one, HTTP samples. Nothing already there changes. Past 200 items or 50 MB in an hour, each one asks.
          <% :change -> %>
            <code class="font-mono">update_*</code>: changes to notes, diagrams and flash cards already there, yours included. Its card shows the change as a diff; what it replaces is kept as a version you restore from the item's Versions.
        <% end %>
      </dd>
      <dt class="text-muted">In the VM</dt>
      <dd class="text-[11px] text-ink">
        <span class="font-mono">mwt mcp</span>, an MCP server set up for Claude Code and Codex at every boot. Nothing in the VM holds a token for it.
      </dd>
      <dt class="text-muted">Built in</dt>
      <dd class="text-[11px] text-ink">
        MWT's own, so it can't be edited or removed. Turn it off, or change how it starts, below.
      </dd>
    </dl>
    """
  end

  defp delivery(%{grant: %Grant{kind: :request}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
      <dt class="text-muted">Sends</dt>
      <dd id="grant-request">
        <p class="break-all font-mono text-[11px] text-ink">
          <span class="font-semibold text-violet-strong">{@grant.method}</span> {@grant.url}
        </p>
        <ul class="mt-1.5 space-y-0.5">
          <li
            :for={{name, value} <- @grant.headers}
            class="break-all font-mono text-[10px] text-muted"
          >
            {name}: {SavedRequest.shown_value(value, @parent_name)}
          </li>
        </ul>
        <pre
          :if={@grant.body}
          id="grant-request-body"
          class="mt-1.5 overflow-x-auto whitespace-pre-wrap break-words rounded-md border border-line-soft bg-deep/50 p-2 font-mono text-[11px] text-ink"
          phx-no-format
        >{pretty(@grant.body)}</pre>
        <p class="mt-1 text-[10px] text-faint">
          MWT sends it itself, with {@parent_name}'s real value where {SavedRequest.token_mark()} is: the VM never holds it. Each value is encoded where it goes; the host and headers never change.
        </p>
      </dd>
      <.params_list grant={@grant} />
      <dt class="text-muted">Approval</dt>
      <dd class="text-[11px] text-ink">
        Every call waits for you, with the exact request on its card, unless you turned it on with Auto-approve.
      </dd>
      <dt class="text-muted">In the VM</dt>
      <dd class="font-mono text-[11px] text-ink">{Grant.signature(@grant)} --reason "…"</dd>
    </dl>
    """
  end

  defp delivery(%{grant: %Grant{kind: :command}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div
        :if={is_nil(@grant.script)}
        id="grant-ask-to-run"
        class="flex gap-2.5 rounded-lg border border-warn/35 bg-warn-soft/30 p-3"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warn" />
        <p class="text-xs leading-5 text-ink">
          The escape hatch, built in by MWT: agents write the command. Only while it is on can they ask, and you read and approve every run. Save the ones worth keeping as subgrants, so this can stay off.
        </p>
      </div>
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
        <dt class="text-muted">Runs</dt>
        <dd :if={is_nil(@grant.script)} class="text-[11px] text-ink">
          Whatever text the agent sends, exactly as its card shows it.
        </dd>
        <dd :if={@grant.script} id="grant-delivery-script">
          <pre
            class="overflow-x-auto whitespace-pre-wrap break-words rounded-md border border-line-soft bg-deep/50 p-2 font-mono text-[11px] text-ink"
            phx-no-format
          >{@grant.script}</pre>
          <p class="mt-1 text-[10px] text-faint">
            Yours, run exactly as it is. Agents call it by id and send no text{if @grant.params != [],
              do: ": only a value for each parameter, which it reads as a variable"}.
          </p>
        </dd>
        <dt :if={@grant.script} class="text-muted">Parameters</dt>
        <dd :if={@grant.script && @grant.params == []} class="text-[11px] text-ink">
          None: an agent chooses only when it runs.
        </dd>
        <dd :if={@grant.params != []} id="grant-delivery-params">
          <ul class="space-y-1.5">
            <li
              :for={param <- @grant.params}
              id={"grant-param-#{param.name}"}
              class="text-[11px] leading-4"
            >
              <span class="font-mono font-semibold text-violet-strong">${param.name}</span>
              <span class="text-ink">· {Param.shape_words(param.shape)}</span>
              <span class="block text-muted">{param.about}</span>
            </li>
          </ul>
        </dd>
        <dt :if={@grant.script} class="text-muted">In</dt>
        <dd :if={@grant.script} class="font-mono text-[11px] text-ink">{@grant.dir}</dd>
        <dt :if={@grant.script} class="text-muted">As</dt>
        <dd :if={@grant.script} id="grant-runs-as" class="text-[11px] text-ink">
          <%= if @grant.confined do %>
            Confined: an empty home, your tools read-only, its folder {if @grant.writes_dir,
              do: "writable",
              else: "read-only"}{if @grant.with != [],
              do: ", with the real values of #{Enum.join(@grant.with, ", ")}"}.
          <% else %>
            <span class="text-warn-strong">
              You: your home, your keys and your logins are in its reach. Edit it to run it confined.
            </span>
          <% end %>
        </dd>
        <dt class="text-muted">Approval</dt>
        <dd :if={is_nil(@grant.script)} class="text-[11px] text-ink">
          Every run waits for you, always. Nothing auto-approves one.
        </dd>
        <dd :if={@grant.script} class="text-[11px] text-ink">
          Every run waits for you, unless you turned it on with Auto-approve.
        </dd>
        <dt class="text-muted">In the VM</dt>
        <dd class="font-mono text-[11px] text-ink">
          <%= if @grant.script do %>
            {Grant.signature(@grant)} --reason "…"
          <% else %>
            mwt run {@grant.id} --reason "…" -- COMMAND
          <% end %>
        </dd>
      </dl>
    </div>
    """
  end

  attr :grant, Grant, required: true

  defp params_list(assigns) do
    ~H"""
    <dt class="text-muted">Parameters</dt>
    <dd :if={@grant.params == []} class="text-[11px] text-ink">
      None: an agent chooses only when it runs.
    </dd>
    <dd :if={@grant.params != []} id="grant-delivery-params">
      <ul class="space-y-1.5">
        <li
          :for={param <- @grant.params}
          id={"grant-param-#{param.name}"}
          class="text-[11px] leading-4"
        >
          <span class="font-mono font-semibold text-violet-strong">${param.name}</span>
          <span class="text-ink">· {Param.shape_words(param.shape)}</span>
          <span class="block text-muted">{param.about}</span>
        </li>
      </ul>
    </dd>
    """
  end

  defp pretty(body) do
    case Jason.decode(body) do
      {:ok, json} -> Jason.encode!(json, pretty: true)
      _invalid -> body
    end
  end

  ## Adding a grant

  @doc """
  The dialog that adds a grant: first a type or a preset, then the form.
  Opened from an agent's ask, it says what the agent asked for, and the new
  grant answers it.
  """
  attr :adding, :map, required: true
  attr :waiting, :list, required: true
  attr :grants, :list, default: []
  attr :mints, :list, default: [], doc: "the firewall's credential endpoints, while it watches"

  attr :presets, :list,
    default: [],
    doc: "MWT's presets and yours (`MWTClient.Sandbox.Presets.presets/1`)"

  def add_dialog(assigns) do
    # Ask to run commands is built in: only saved commands are added.
    # A request subgrant is added under its token grant, not from here.
    types = Enum.reject(Presets.types(), &(&1.kind in [:request, :mwt]))
    {access, commands} = Enum.split_with(types, &(&1.kind != :command))
    commands = Enum.reject(commands, &(&1.id == :command))

    assigns =
      assign(assigns,
        ask:
          Enum.find(
            assigns.waiting,
            &(&1.id == assigns.adding[:approval_id] and &1.kind == :activation)
          ),
        access: access,
        commands: commands,
        built_in: Enum.find(assigns.grants, &Grant.ask_to_run?/1),
        editing:
          assigns.adding[:editing] &&
            Enum.find(assigns.grants, &(&1.id == assigns.adding.editing)),
        parent:
          assigns.adding[:parent] && Enum.find(assigns.grants, &(&1.id == assigns.adding.parent)),
        saving:
          Enum.find(
            assigns.waiting,
            &(&1.id == assigns.adding[:approval_id] and &1.kind == :command)
          )
      )

    ~H"""
    <div
      id="add-grant-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="add-grant-title"
      phx-window-keydown="close_add_grant"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50 backdrop-blur-[1px]" phx-click="close_add_grant"></div>
      <div class="relative flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 transition duration-150 ease-out motion-safe:starting:scale-[0.98] starting:opacity-0 dark:shadow-black/60">
        <header class="flex items-center gap-3 border-b border-line-soft px-5 py-3.5">
          <button
            :if={@adding.step == :details and is_nil(@editing) and is_nil(@parent)}
            type="button"
            id="add-grant-back"
            phx-click="add_grant_back"
            title="Pick another type"
            class="flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </button>
          <div class="min-w-0 flex-1">
            <h2 id="add-grant-title" class="text-sm font-semibold text-ink">
              <%= cond do %>
                <% @editing -> %>
                  Edit {@editing.name}
                <% @adding.step == :pick -> %>
                  Add a grant
                <% @parent && @adding.preset.kind in [:command, :request] -> %>
                  Add a subgrant of {@parent.name}
                <% true -> %>
                  Add {@adding.preset.name}
              <% end %>
            </h2>
            <p class="mt-0.5 text-[11px] text-muted">
              <%= cond do %>
                <% @ask -> %>
                  {@ask.agent} asked for: {@ask.need}
                <% @adding.step == :pick -> %>
                  Pick what it is, or start from a preset.
                <% true -> %>
                  {@adding.preset.blurb}
              <% end %>
            </p>
          </div>
          <button
            type="button"
            id="add-grant-close"
            phx-click="close_add_grant"
            title="Close"
            class="flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>

        <div class="min-h-0 overflow-y-auto p-5">
          <div :if={@adding.step == :pick} class="space-y-5">
            <div id="type-grid" class="grid gap-2.5 sm:grid-cols-3">
              <.type_tile :for={type <- @access} type={type} />
            </div>

            <div>
              <p class="mb-2 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Commands on this machine
                <.help id="command-types-help" label="About command grants">
                  Both run as you, outside the VM. Ask to run commands is built in: while it is on, agents may ask to run a command they write, and you approve every run. A subgrant of it is your own script: agents call it by id, with a value for each of its parameters, and send no text.
                </.help>
              </p>
              <div id="command-type-grid" class="grid gap-2.5 sm:grid-cols-2">
                <.type_tile :for={type <- @commands} type={type} />
                <.type_tile
                  :if={@built_in}
                  type={elem(Presets.find("command"), 1)}
                  taken={@built_in}
                />
              </div>
            </div>

            <div>
              <p class="mb-2 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Presets
              </p>
              <div id="preset-grid" class="grid gap-2 sm:grid-cols-2">
                <button
                  :for={preset <- @presets}
                  type="button"
                  id={"preset-#{preset.id}"}
                  phx-click="pick_preset"
                  phx-value-preset={preset.id}
                  class="group flex cursor-pointer items-center gap-2.5 rounded-lg border border-line-soft px-3 py-2 text-left transition-all hover:border-accent/50 hover:bg-accent-soft/20"
                >
                  <.icon
                    name={preset.icon}
                    class="size-4 shrink-0 text-muted transition-colors group-hover:text-accent"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block text-xs font-medium text-ink">{preset.name}</span>
                    <span class="block truncate text-[10px] text-faint">{preset.blurb}</span>
                  </span>
                  <span class="shrink-0 rounded bg-deep px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-wide text-faint">
                    {Presets.kind_name(preset.kind)}
                  </span>
                </button>
              </div>
              <p class="mt-2 text-[11px] leading-4 text-faint">
                A preset only fills the form. What it makes is a plain grant you can change.
              </p>
            </div>
          </div>

          <.form
            :if={@adding.step == :details}
            for={@adding.form}
            id="add-grant-form"
            phx-change="validate_grant"
            phx-submit="create_grant"
            class="space-y-4"
          >
            <input type="hidden" name="grant[kind]" value={@adding.preset.kind} />
            <input type="hidden" name="grant[preset]" value={@adding.preset.id} />
            <div
              :if={is_nil(@editing) and Map.get(@adding.preset, :fill, []) != []}
              id="preset-fill"
              class="space-y-2 rounded-lg border border-accent/30 bg-accent-soft/10 p-3"
            >
              <p class="text-[11px] font-medium text-ink">
                Fill in first: each goes where the fields below say {"{name}"}.
              </p>
              <div class="grid gap-2 sm:grid-cols-2">
                <div :for={field <- @adding.preset.fill}>
                  <label
                    class="text-[11px] font-medium uppercase tracking-wide text-muted"
                    for={"fill-#{field.name}"}
                  >
                    {field.label}
                  </label>
                  <input
                    type="text"
                    name={"grant[fill][#{field.name}]"}
                    id={"fill-#{field.name}"}
                    value={get_in(@adding.form.params, ["fill", field.name])}
                    placeholder={field.example}
                    class={input_classes()}
                  />
                </div>
              </div>
              <.field_error errors={@adding.errors} field={:fill} />
            </div>
            <input :if={@parent} type="hidden" name="grant[parent]" value={@parent.id} />
            <div
              :if={@editing}
              id="editing-note"
              class="flex items-start gap-2.5 rounded-lg border border-line-soft bg-deep/50 p-3 text-[11px] leading-4 text-muted"
            >
              <.icon name="hero-pencil-square-micro" class="mt-px size-3.5 shrink-0 text-accent" />
              <span>
                It keeps its id <span class="font-mono text-ink">{@editing.id}</span>, so agents still find it, and stays as it is: on or off, asking or not.
                <span :if={Grant.auto_approved?(@editing)} class="text-warn-strong">
                  It is auto-approved now: what you save goes through without asking.
                </span>
                <span :if={@editing.kind == :token}>
                  Replace its value on its page.
                </span>
              </span>
            </div>
            <ol
              id="preset-guide"
              class="space-y-1.5 rounded-lg border border-accent/25 bg-accent-soft/20 p-3"
            >
              <li
                :for={{step, index} <- Enum.with_index(@adding.preset.guide, 1)}
                class="flex gap-2.5 text-xs leading-5 text-ink"
              >
                <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[10px] font-semibold text-accent-strong">
                  {index}
                </span>
                <span>{step}</span>
              </li>
            </ol>

            <.input
              field={@adding.form[:name]}
              label="Name"
              placeholder="Shown on switches and approvals"
              help={field_help(:name)}
              phx-mounted={JS.focus()}
            />
            <.field_error errors={@adding.errors} field={:name} />

            <div>
              <.input
                field={@adding.form[:purpose]}
                type="textarea"
                label="What it's for"
                help={
                  field_help(
                    if(@adding.preset.kind == :command, do: :purpose_command, else: :purpose)
                  )
                }
                rows="2"
                placeholder={
                  if(@adding.preset.kind == :command,
                    do: "Lists the pods of a namespace in the staging cluster",
                    else: "Push to github.com/me/project and open pull requests there"
                  )
                }
              />
              <p id="purpose-hint" class="mt-1 text-[10px] text-faint">
                <%= cond do %>
                  <% @adding.preset.kind != :command -> %>
                    Agents in the VM read this to find the grant they need. Say what it opens, and for what.
                  <% @adding[:approval_id] && @adding.form[:purpose].value not in [nil, ""] -> %>
                    The agent's suggestion: words for any time it runs, not its reason for this run. Check it says what the script does.
                  <% true -> %>
                    Say what it does, for any time it runs: agents read this to pick it, and the search finds it by these words.
                <% end %>
              </p>
              <.field_error errors={@adding.errors} field={:purpose} />
            </div>

            <%= if @adding.preset.kind == :token do %>
              <div>
                <p class="mb-1.5 flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-muted">
                  Who uses its value
                  <.help id="grant-reach-help" label="About who uses its value">
                    {field_help(:reach)}
                  </.help>
                </p>
                <div
                  id="grant-reach"
                  class="inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
                >
                  <label
                    :for={
                      {value, label} <- [
                        {"vm", "The VM, through mwt exec"},
                        {"subgrants", "Only its subgrants"}
                      ]
                    }
                    class="relative"
                  >
                    <input
                      type="radio"
                      name="grant[reach]"
                      id={"grant-reach-#{value}"}
                      value={value}
                      checked={reach(@adding.form) == value}
                      class="peer sr-only"
                    />
                    <span class="block cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:text-ink peer-checked:bg-active peer-checked:text-ink peer-checked:shadow-sm">
                      {label}
                    </span>
                  </label>
                </div>
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <div>
                  <.input
                    field={@adding.form[:hosts]}
                    label="Hosts it may go to"
                    placeholder="api.example.com"
                    help={field_help(:hosts)}
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Comma separated. *.example.com covers subdomains.
                  </p>
                  <.mint_hint
                    id="grant-hosts-mints"
                    entries={
                      Firewall.mints_under(
                        @mints,
                        String.split(to_string(@adding.form[:hosts].value), [",", "\n"], trim: true)
                      )
                    }
                  />
                  <.field_error errors={@adding.errors} field={:hosts} />
                </div>
                <div :if={reach(@adding.form) == "vm"}>
                  <.input
                    field={@adding.form[:env]}
                    label="Variables holding the placeholder"
                    placeholder="API_TOKEN"
                    help={field_help(:env)}
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Comma separated. Supplied only to mwt exec commands. Optional: a file holds it too.
                  </p>
                  <.field_error errors={@adding.errors} field={:env} />
                </div>
              </div>

              <p
                :if={reach(@adding.form) == "subgrants"}
                id="grant-reach-words"
                class="text-[11px] leading-4 text-muted"
              >
                The hosts still matter: a subgrant's URL must be on one of them. Add its subgrants from its page.
              </p>

              <details
                :if={reach(@adding.form) == "vm"}
                id="token-more"
                class="group rounded-lg border border-line-soft"
                open={
                  @adding.form[:file_env].value not in [nil, ""] or
                    @adding.form[:carriers].value not in [nil, ""] or
                    @adding.form[:present_metadata].value in ["true", true] or
                    @adding.errors[:present_project] != nil or @adding.errors[:present_email] != nil or
                    @adding.form[:signs_as].value not in [nil, ""] or @adding.errors[:signs_as] != nil or
                    @adding.form[:present_login].value in ["true", true] or
                    @adding.errors[:present_login] != nil or @adding.errors[:present_id_header] != nil or
                    @adding.form[:git].value == "true" or @adding.errors[:prefix] != nil or
                    @adding.errors[:carriers] != nil
                }
              >
                <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-3.5 transition-transform group-open:rotate-90"
                  /> More ways the VM gets it
                </summary>
                <div class="grid gap-4 border-t border-line-soft p-3 sm:grid-cols-2">
                  <div>
                    <.input
                      field={@adding.form[:file_env]}
                      label="Variables naming the token file"
                      placeholder="CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"
                      help={field_help(:file_env)}
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      For tools that read the token from a file.
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@adding.form[:carriers]}
                      label="Headers it travels in"
                      placeholder="Authorization"
                      help={field_help(:carriers)}
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      Comma separated. MWT puts the real value only there; a placeholder in any other header is refused.
                    </p>
                    <.field_error errors={@adding.errors} field={:carriers} />
                  </div>
                  <div
                    :if={metadata_offered?(@adding)}
                    id="grant-present-metadata-box"
                    class="sm:col-span-2"
                  >
                    <label class="flex cursor-pointer items-start gap-2">
                      <input type="hidden" name="grant[present_metadata]" value="false" />
                      <input
                        type="checkbox"
                        name="grant[present_metadata]"
                        id="grant-present-metadata"
                        value="true"
                        checked={@adding.form[:present_metadata].value in ["true", true]}
                        class="mt-0.5 size-3.5 cursor-pointer accent-accent"
                      />
                      <span class="text-xs text-ink">
                        Serve it as a cloud metadata server
                        <.help id="grant-present-metadata-help" label="About the metadata server">
                          {field_help(:present_metadata)}
                        </.help>
                        <span class="block text-[10px] text-faint">
                          For Google client libraries that look for default credentials instead of reading the token file: within mwt exec, they find the placeholder on a metadata server (GCE_METADATA_HOST). Only placeholders; nothing listens once the command ends.
                        </span>
                      </span>
                    </label>
                    <div
                      :if={@adding.form[:present_metadata].value in ["true", true]}
                      class="mt-2 grid gap-3 pl-5 sm:grid-cols-2"
                    >
                      <div>
                        <.input
                          field={@adding.form[:present_project]}
                          label="Project"
                          placeholder="my-project"
                          help={field_help(:present_project)}
                        />
                        <.field_error errors={@adding.errors} field={:present_project} />
                      </div>
                      <div>
                        <.input
                          field={@adding.form[:present_email]}
                          label="Account"
                          placeholder="sa@my-project.iam.gserviceaccount.com"
                          help={field_help(:present_email)}
                        />
                        <.field_error errors={@adding.errors} field={:present_email} />
                      </div>
                    </div>
                  </div>
                  <div :if={signing_offered?(@adding)} id="grant-signs-as-box" class="sm:col-span-2">
                    <.input
                      field={@adding.form[:signs_as]}
                      label="May sign as"
                      placeholder="svc@my-project.iam.gserviceaccount.com"
                      help={field_help(:signs_as)}
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      Comma separated service accounts. For clients of a service behind Identity-Aware Proxy that ask Google to sign a JWT: MWT signs with the real value and gives them a placeholder. The VM may then act as these accounts toward the hosts above.
                    </p>
                    <.field_error errors={@adding.errors} field={:signs_as} />
                  </div>
                  <div
                    :if={login_offered?(@adding)}
                    id="grant-present-login-box"
                    class="sm:col-span-2"
                  >
                    <label class="flex cursor-pointer items-start gap-2">
                      <input type="hidden" name="grant[present_login]" value="false" />
                      <input
                        type="checkbox"
                        name="grant[present_login]"
                        id="grant-present-login"
                        value="true"
                        checked={@adding.form[:present_login].value in ["true", true]}
                        class="mt-0.5 size-3.5 cursor-pointer accent-accent"
                      />
                      <span class="text-xs text-ink">
                        Give it a Google login file
                        <.help id="grant-present-login-help" label="About the login file">
                          {field_help(:present_login)}
                        </.help>
                        <span class="block text-[10px] text-faint">
                          For tools that refresh a Google login themselves, as an ID token needs: within mwt exec, GOOGLE_APPLICATION_CREDENTIALS names a login of placeholders, whose refresh MWT answers from the command that mints it.
                        </span>
                      </span>
                    </label>
                    <.field_error errors={@adding.errors} field={:present_login} />
                    <div
                      :if={@adding.form[:present_login].value in ["true", true]}
                      class="mt-2 max-w-72 pl-5"
                    >
                      <.input
                        field={@adding.form[:present_id_header]}
                        label="Header its ID token travels in"
                        placeholder="As the token goes"
                        help={field_help(:present_id_header)}
                      />
                      <.field_error errors={@adding.errors} field={:present_id_header} />
                    </div>
                  </div>
                  <div :if={is_nil(@editing)}>
                    <.input
                      field={@adding.form[:prefix]}
                      label="Placeholder starts with"
                      placeholder="mwt_"
                      help={field_help(:prefix)}
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      For clients that check the format: ghp_, sk-, ….
                    </p>
                    <.field_error errors={@adding.errors} field={:prefix} />
                  </div>
                  <label class="flex cursor-pointer items-start gap-2 sm:col-span-2">
                    <input type="hidden" name="grant[git]" value="false" />
                    <input
                      type="checkbox"
                      name="grant[git]"
                      id="grant-git"
                      value="true"
                      checked={@adding.form[:git].value == "true"}
                      class="mt-0.5 size-3.5 cursor-pointer accent-accent"
                    />
                    <span class="text-xs text-ink">
                      Answer git over HTTPS for these hosts
                      <.help id="grant-git-help" label="About git over HTTPS">
                        {field_help(:git)}
                      </.help>
                      <span class="block text-[10px] text-faint">
                        Within mwt exec, MWT's credential helper gives git the placeholder as the password.
                      </span>
                    </span>
                  </label>
                </div>
              </details>

              <%!-- Where the value comes from can't change while editing, so
                   nothing to choose shows; the form still carries it, or the
                   first change would forget the grant is minted and drop its
                   command. --%>
              <input
                :if={@editing}
                type="hidden"
                name="grant[source]"
                value={source(@adding.form)}
              />
              <div :if={@editing && source(@adding.form) == "minted"}>
                <.input
                  field={@adding.form[:mint]}
                  label="The command that mints it"
                  placeholder="gcloud auth print-access-token"
                  help={field_help(:mint)}
                />
                <.field_error errors={@adding.errors} field={:mint} />
                <.mint_per_field form={@adding.form} />
                <.keep_field form={@adding.form} errors={@adding.errors} />
              </div>

              <div :if={is_nil(@editing)}>
                <p class="mb-1.5 flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-muted">
                  The real value
                  <.help id="grant-source-help" label="About the real value">
                    {field_help(:source)}
                  </.help>
                </p>
                <div
                  id="grant-source"
                  class="mb-2 inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
                >
                  <label
                    :for={
                      {value, label} <- [
                        {"stored", "Stored in your vault"},
                        {"minted", "Minted by a command"}
                      ]
                    }
                    class="relative"
                  >
                    <input
                      type="radio"
                      name="grant[source]"
                      id={"grant-source-#{value}"}
                      value={value}
                      checked={source(@adding.form) == value}
                      class="peer sr-only"
                    />
                    <span class="block cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:text-ink peer-checked:bg-active peer-checked:text-ink peer-checked:shadow-sm">
                      {label}
                    </span>
                  </label>
                </div>
                <div :if={source(@adding.form) == "minted"}>
                  <.input
                    field={@adding.form[:mint]}
                    placeholder="gcloud auth print-access-token --impersonate-service-account=… --lifetime=1800s"
                  />
                  <p class="mt-1 flex items-center gap-1 text-[10px] text-faint">
                    Runs here, with your host login, when the VM needs a token.
                    <.help id="grant-mint-help" label="About minted tokens">
                      {field_help(:mint)}
                    </.help>
                  </p>
                  <.field_error errors={@adding.errors} field={:mint} />
                  <.mint_per_field form={@adding.form} />
                  <.keep_field form={@adding.form} errors={@adding.errors} />
                </div>
                <div :if={source(@adding.form) == "stored"}>
                  <input
                    type="password"
                    name="grant[value]"
                    id="grant-value"
                    autocomplete="new-password"
                    placeholder="Paste the token"
                    class={input_classes()}
                  />
                  <p class="mt-1 flex items-center gap-1 text-[10px] text-faint">
                    Kept in your vault, encrypted with your password. The VM only ever gets the placeholder.
                    <.help id="grant-value-help" label="About the value">{field_help(:value)}</.help>
                  </p>
                  <.field_error errors={@adding.errors} field={:value} />
                </div>
              </div>
            <% end %>

            <div :if={@adding.preset.kind == :network}>
              <.input
                field={@adding.form[:destinations]}
                type="textarea"
                label="Destinations"
                help={field_help(:destinations)}
                placeholder="10.20.0.0/16:443,5432\ngit.corp.internal:443\n*.corp.example:443"
              />
              <p class="mt-1 text-[10px] text-faint">
                One per line: an address, a range, a host name, or every name under one (*.corp.example), then optionally :ports. Anything after # is a note.
              </p>
              <.field_error errors={@adding.errors} field={:destinations} />
              <div id="grant-private-network" class="mt-3">
                <.input
                  field={@adding.form[:anchor]}
                  label="Only through the VPN interface"
                  placeholder="wg0"
                  help={field_help(:anchor)}
                />
                <p class="mt-1 text-[10px] text-faint">
                  Optional, and best for a VPN: its interface's name, as ip link shows it. While the VPN is down, this grant opens nothing, so its addresses never reach whatever network you are on instead.
                </p>
                <.field_error errors={@adding.errors} field={:anchor} />
              </div>
              <details
                id="network-more"
                class="group mt-3 rounded-lg border border-line-soft"
                open={
                  @adding.form[:resolver].value not in [nil, ""] or @adding.errors[:resolver] != nil
                }
              >
                <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-3.5 transition-transform group-open:rotate-90"
                  /> More
                </summary>
                <div class="border-t border-line-soft p-3">
                  <.input
                    field={@adding.form[:resolver]}
                    label="DNS server for its names"
                    placeholder="10.8.0.1"
                    help={field_help(:resolver)}
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Only if this machine can't look the names up itself: they are asked of this server instead.
                  </p>
                  <.field_error errors={@adding.errors} field={:resolver} />
                </div>
              </details>
            </div>

            <div :if={@adding.preset.id == :request_subgrant} id="request-fields" class="space-y-3">
              <div class="flex gap-2">
                <div class="w-28 shrink-0">
                  <p class="mb-1 flex items-center gap-1">
                    <label
                      for="grant-method"
                      class="text-[11px] font-medium uppercase tracking-wide text-muted"
                    >
                      Method
                    </label>
                    <.help id="grant-method-help" label="About the method">
                      {field_help(:method)}
                    </.help>
                  </p>
                  <select
                    name="grant[method]"
                    id="grant-method"
                    class={[input_classes(), "font-mono text-xs"]}
                  >
                    <option
                      :for={method <- SavedRequest.methods()}
                      value={method}
                      selected={@adding.form[:method].value == method}
                    >
                      {method}
                    </option>
                  </select>
                </div>
                <div class="min-w-0 flex-1">
                  <p class="mb-1 flex items-center gap-1">
                    <label
                      for="grant-url"
                      class="text-[11px] font-medium uppercase tracking-wide text-muted"
                    >
                      URL
                    </label>
                    <.help id="grant-url-help" label="About the URL">
                      Where MWT sends the request: https:// to a host {if(@parent,
                        do: @parent.name,
                        else: "the grant"
                      )} lists, written out in full. A parameter goes in the path or the query as $NAME, and MWT puts the agent's value there encoded; a word keeps its / in the path, so $REPO can be owner/name. The scheme and the host never change between calls, so the token only ever goes there.
                    </.help>
                  </p>
                  <input
                    type="text"
                    name="grant[url]"
                    id="grant-url"
                    value={@adding.form[:url].value}
                    spellcheck="false"
                    autocomplete="off"
                    phx-debounce="300"
                    placeholder="https://api.github.com/repos/$REPO/pulls/$PR"
                    class={[input_classes(), "font-mono text-xs"]}
                  />
                </div>
              </div>
              <.field_error errors={@adding.errors} field={:method} />
              <.field_error errors={@adding.errors} field={:url} />
              <.mint_hint id="grant-url-mints" entries={url_mints(@mints, @adding.form[:url].value)} />
              <p :if={@parent} class="-mt-1 text-[10px] text-faint">
                {@parent.name} sends its token only to {Enum.join(@parent.hosts, ", ")}.
              </p>
              <div>
                <p class="mb-1 flex items-center gap-1">
                  <label
                    for="grant-headers"
                    class="text-[11px] font-medium uppercase tracking-wide text-muted"
                  >
                    Headers
                  </label>
                  <.help id="grant-headers-help" label="About the headers">
                    The request's HTTP headers, Name: value, one a line, the same on every call: agents can't add or change one. {SavedRequest.token_mark()} stands for the real value, where the service takes it (Authorization: Bearer {SavedRequest.token_mark()}); MWT puts it there as it sends, and the VM never sees it. Empty, it starts from the headers the grant's service expects.
                  </.help>
                </p>
                <textarea
                  name="grant[headers]"
                  id="grant-headers"
                  rows="3"
                  spellcheck="false"
                  autocomplete="off"
                  class={[input_classes(), "font-mono text-xs"]}
                >{@adding.form[:headers].value}</textarea>
                <.field_error errors={@adding.errors} field={:headers} />
              </div>
              <div>
                <p class="mb-1 flex items-center gap-1">
                  <label
                    for="grant-body"
                    class="text-[11px] font-medium uppercase tracking-wide text-muted"
                  >
                    Body
                  </label>
                  <.help id="grant-body-help" label="About the body">
                    What the request sends: JSON, or empty for none. A parameter is a whole JSON value, "$TITLE", never part of a longer text: MWT encodes the agent's value into it, so it can't change the shape of the body. A number parameter on its own goes in as a number. Like the headers, it is the same on every call but for the parameters.
                  </.help>
                </p>
                <textarea
                  name="grant[body]"
                  id="grant-body"
                  rows="3"
                  spellcheck="false"
                  autocomplete="off"
                  placeholder={~s({"title": "$TITLE"})}
                  class={[input_classes(), "font-mono text-xs"]}
                >{@adding.form[:body].value}</textarea>
                <.field_error errors={@adding.errors} field={:body} />
              </div>
              <.params_field form={@adding.form} errors={@adding.errors} request />
              <.start_pick :if={is_nil(@editing)} form={@adding.form} errors={@adding.errors} />
            </div>

            <div :if={@adding.preset.id == :saved_command} class="space-y-3">
              <div
                :if={@saving}
                id="saving-from"
                class="flex items-start gap-2.5 rounded-lg border border-line-soft bg-deep/50 p-3 text-[11px] leading-4 text-muted"
              >
                <.icon name="hero-bookmark-square-micro" class="mt-px size-3.5 shrink-0 text-accent" />
                <span>
                  From what {@saving.agent} asked to run. Turn what varies into parameters. Saving doesn't run it: its card still waits for you, and the agent hears to call this one by id next time.
                </span>
              </div>
              <div>
                <p class="mb-1 flex items-center gap-1">
                  <label
                    for="grant-script"
                    class="text-[11px] font-medium uppercase tracking-wide text-muted"
                  >
                    Script
                  </label>
                  <.help id="grant-script-help" label="About the script">
                    The exact text that runs on this machine, with bash -lc, in the folder below, each time an agent calls the subgrant by its id: agents can run only this, and send no text of their own. It reads each parameter as a variable, "$NAME", always in double quotes, so a value is never read as a command. Keep it to what must run here, one command if you can; agents work on its output in the VM.
                  </.help>
                </p>
                <textarea
                  name="grant[script]"
                  id="grant-script"
                  rows="4"
                  spellcheck="false"
                  autocomplete="off"
                  placeholder="kubectl get pods -n web -o json"
                  class={[input_classes(), "font-mono text-xs"]}
                >{@adding.form[:script].value}</textarea>
                <.field_error errors={@adding.errors} field={:script} />
              </div>
              <.params_field form={@adding.form} errors={@adding.errors} />
              <div>
                <.input
                  field={@adding.form[:dir]}
                  label="Folder it runs in"
                  placeholder="~/projects/site"
                  help={field_help(:dir)}
                />
                <.field_error errors={@adding.errors} field={:dir} />
              </div>
              <.confine_field form={@adding.form} errors={@adding.errors} />
              <.start_pick :if={is_nil(@editing)} form={@adding.form} errors={@adding.errors} />
            </div>

            <p
              :if={@adding.preset.kind == :command}
              class="flex items-start gap-2 rounded-lg border border-line-soft bg-deep/50 p-3 text-[11px] leading-4 text-muted"
            >
              <.icon name="hero-hand-raised-micro" class="mt-px size-3.5 shrink-0 text-warn" />
              <span class="flex-1">
                {cond do
                  @adding.preset.id != :saved_command ->
                    "Every run waits for your approval."

                  @adding.form[:start].value in ["on", "auto"] ->
                    "It has a switch of its own, apart from Ask to run commands, which can stay off."

                  @saving ->
                    "Saved, it turns on for 1 h, and every run waits for your approval. Change either where it is listed."

                  @ask ->
                    "Saved, it turns on for #{minutes_words(@ask.minutes)}, and every run waits for your approval."

                  true ->
                    "It starts off. Turn it on for a time, asking each time or auto-approved."
                end}
              </span>
              <.help id="grant-command-help" label="How a command runs">
                Once on, agents can ask. Each run shows its exact text on a card and waits for you, unless you auto-approve its subgrant; it runs on this machine, outside the VM, confined or as you as set above. Its output goes back to the agent once you release it.
              </.help>
            </p>

            <p
              :if={@adding.preset.kind != :command}
              class="flex items-start gap-2 rounded-lg border border-line-soft bg-deep/50 p-3 text-[11px] leading-4 text-muted"
            >
              <.icon name="hero-hand-raised-micro" class="mt-px size-3.5 shrink-0 text-warn" />
              <span class="flex-1">
                Every {if @adding.preset.kind == :network, do: "connection", else: "request"} using it waits for your approval.
              </span>
              <.help id="grant-uses-help" label="About approving uses">
                Each use waits on a card in Approvals for you to allow it once, allow similar ones for a while, or deny it. From a card, or the grant's page, you can let them through for a while, or auto-approve every use while it is on; Always ask me on its page rules both out.
              </.help>
            </p>

            <footer class="flex items-center justify-end gap-2 pt-1">
              <.button type="button" phx-click="close_add_grant" variant="ghost">Cancel</.button>
              <.button type="submit" id="create-grant" variant="primary">
                <%= cond do %>
                  <% @editing -> %>
                    Save changes
                  <% @ask && @adding.preset.id in [:saved_command, :request_subgrant] -> %>
                    Save subgrant
                  <% @ask -> %>
                    Add and turn on for {minutes_words(@ask.minutes)}
                  <% @adding.preset.id in [:saved_command, :request_subgrant] -> %>
                    Save subgrant
                  <% true -> %>
                    Add grant
                <% end %>
              </.button>
            </footer>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true

  # The state a subgrant starts in, chosen as it is added.
  defp start_pick(assigns) do
    ~H"""
    <div id="grant-start-field">
      <p class="mb-1 flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-muted">
        When MWT starts
        <.help id="grant-start-help" label="About the state it starts in">
          The state it is put in each time MWT starts. Disabled: it stays off until you, or an agent's ask you approve, enable it for a time. Enabled, ask: enabled from now and at every start, until you turn it off, and every call still waits for you. Enabled, auto: the same, and every call goes through without asking, logged in Activity. Only for what you fully trust.
        </.help>
      </p>
      <.pills
        id="grant-start-pick"
        name="grant[start]"
        options={[{"off", "Disabled"}, {"on", "Enabled, ask"}, {"auto", "Enabled, auto"}]}
        checked={@form[:start].value || "off"}
        tone="ok"
      />
      <.field_error errors={@errors} field={:start} />
      <p
        :if={@form[:start].value == "auto"}
        id="grant-start-always"
        class="mt-1.5 flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
      >
        <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
        <span>
          Every call will go through without asking, with whatever values the agent gives within the shapes of the parameters.
        </span>
      </p>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true
  attr :request, :boolean, default: false

  # What an agent chooses on each call.
  defp params_field(assigns) do
    ~H"""
    <div>
      <p class="mb-1 flex items-center gap-1">
        <label for="grant-params" class="text-[11px] font-medium uppercase tracking-wide text-muted">
          Parameters
        </label>
        <.help id="grant-params-help" label="About parameters">
          What an agent chooses on each call, one a line: NAME: shape: what it is. The agent must give a value for each, of its shape, or MWT refuses the call before anything runs; a value starting with - is always refused. The shape is word (letters, digits and _ . - @ : +, in parts joined by /), number, date, time, decimal, text, or the values it may take, as a|b|c. {if(
            @request,
            do:
              "The request puts each where you wrote $NAME, encoded: a value can't change the host, the headers or the shape of the body.",
            else:
              "The script reads each as a variable and never changes: a value can't add a command."
          )} Leave it empty for one that is always the same.
        </.help>
      </p>
      <textarea
        name="grant[params]"
        id="grant-params"
        rows="2"
        spellcheck="false"
        autocomplete="off"
        phx-debounce="300"
        placeholder={
          if(@request,
            do: "REPO: word: the repository, as owner/name",
            else: "REPO_NAME: word: the repository, as owner/name"
          )
        }
        class={[input_classes(), "font-mono text-xs"]}
      >{@form[:params].value}</textarea>
      <.field_error errors={@errors} field={:params} />
      <.params_preview
        :if={not @request}
        params={@form[:params].value}
        script={@form[:script].value}
      />
      <.params_preview :if={@request} params={@form[:params].value} script={nil} />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true

  # Whether a saved command runs in a bubble, and with which grants'
  # values. New ones start confined; one saved before runs as you until
  # you tick it.
  defp confine_field(assigns) do
    assigns = assign(assigns, confined?: assigns.form[:confined].value not in ["false", false])

    ~H"""
    <div id="grant-confine" class="space-y-2 rounded-lg border border-line-soft p-3">
      <label class="flex cursor-pointer items-start gap-2">
        <input type="hidden" name="grant[confined]" value="false" />
        <input
          type="checkbox"
          name="grant[confined]"
          id="grant-confined"
          value="true"
          checked={@confined?}
          class="mt-0.5 size-3.5 cursor-pointer accent-accent"
        />
        <span class="text-xs text-ink">
          Runs confined
          <.help id="grant-confined-help" label="About running confined">
            {field_help(:confined)}
          </.help>
          <span class="block text-[10px] text-faint">
            In a bubble on this machine: an empty home, your tools read-only, nothing of your keys or logins. Not confined, it runs as you, with all of them in reach.
          </span>
        </span>
      </label>
      <div :if={@confined?} class="space-y-2 pl-5">
        <label class="flex cursor-pointer items-start gap-2">
          <input type="hidden" name="grant[writes_dir]" value="false" />
          <input
            type="checkbox"
            name="grant[writes_dir]"
            id="grant-writes-dir"
            value="true"
            checked={@form[:writes_dir].value in ["true", true]}
            class="mt-0.5 size-3.5 cursor-pointer accent-accent"
          />
          <span class="text-xs text-ink">
            May write in its folder <span class="text-[10px] text-faint">(read-only otherwise)</span>
            <.help id="grant-writes-dir-help" label="About writing in its folder">
              {field_help(:writes_dir)}
            </.help>
          </span>
        </label>
        <div>
          <.input
            field={@form[:with]}
            label="With the real values of"
            placeholder="github, stripe"
            help={field_help(:with)}
          />
          <p class="mt-1 text-[10px] text-faint">
            Token grants, by id, comma separated. Each value is in the variables the VM sees its placeholder in, and in its token file, as in the VM.
          </p>
          <.field_error errors={@errors} field={:with} />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true

  # Where the firewall refuses this grant's value: a credential endpoint
  # among its hosts, or the URL a subgrant sends to.
  defp mint_hint(assigns) do
    ~H"""
    <p
      :if={@entries != []}
      id={@id}
      class="mt-1 flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
    >
      <.icon name="hero-key-micro" class="mt-px size-3.5 shrink-0" />
      <span>
        A credential endpoint is here ({Enum.join(@entries, ", ")}): MWT refuses this value there, so it can't mint another credential. The Firewall page's list says which.
      </span>
    </p>
    """
  end

  defp url_mints(mints, url) do
    case URI.parse(to_string(url)) do
      %URI{host: host, path: path} when is_binary(host) ->
        List.wrap(Firewall.mint(mints, host, path))

      _not_yet ->
        []
    end
  end

  attr :params, :any, default: nil
  attr :script, :any, default: nil

  # The parameters as MWT reads them while you type: how a call will look,
  # and what deserves a second look in how the script reads them.
  defp params_preview(assigns) do
    script = to_string(assigns.script || "")

    {params, problems} =
      case Param.parse(to_string(assigns.params || "")) do
        {:ok, params} ->
          unused =
            for param <- Param.unused(params, script),
                do: "The script doesn't read $#{param.name}."

          {params,
           if(String.trim(script) == "", do: [], else: unused ++ Param.hints(params, script))}

        {:error, message} ->
          {[], [message]}
      end

    assigns = assign(assigns, parsed: params, problems: problems)

    ~H"""
    <div id="grant-params-preview" class="mt-1.5 space-y-1">
      <p :if={@parsed != []} class="text-[10px] leading-4 text-faint">
        A call gives
        <span :for={param <- @parsed} class="mr-1.5 font-mono text-violet-strong">
          {param.name}=<span class="text-muted">{Param.shape_name(param.shape)}</span>
        </span>
      </p>
      <p
        :for={problem <- @problems}
        class="flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
      >
        <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
        <span>{problem}</span>
      </p>
    </div>
    """
  end

  attr :type, :map, required: true
  attr :taken, :any, default: nil, doc: "the grant that makes a second of this type pointless"

  # A grant type to pick; the built-in Ask to run commands links to itself instead.
  defp type_tile(assigns) do
    ~H"""
    <%= if @taken do %>
      <.link
        patch={~p"/tools/sandbox/grants/#{@taken.id}"}
        id={"type-#{@type.id}"}
        phx-click="close_add_grant"
        class="group flex flex-col items-start gap-2 rounded-lg border border-dashed border-line p-3 text-left transition-colors hover:border-accent/50"
      >
        <span class="flex size-8 items-center justify-center rounded-lg bg-deep text-faint">
          <.icon name={@type.icon} class="size-4" />
        </span>
        <span class="block text-xs font-semibold text-muted">{@type.name}</span>
        <span class="block text-[11px] leading-4 text-faint">
          Built in, listed with your grants. While it is on, agents may ask; you approve every run.
        </span>
        <span class="inline-flex items-center gap-1 text-[10px] font-medium text-accent">
          Open it <.icon name="hero-arrow-right-micro" class="size-3" />
        </span>
      </.link>
    <% else %>
      <button
        type="button"
        id={"type-#{@type.id}"}
        phx-click="pick_preset"
        phx-value-preset={@type.id}
        class="group flex cursor-pointer flex-col items-start gap-2 rounded-lg border border-line p-3 text-left transition-all hover:-translate-y-px hover:border-accent/50 hover:bg-accent-soft/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
      >
        <span class="flex size-8 items-center justify-center rounded-lg bg-deep text-muted transition-colors group-hover:text-accent">
          <.icon name={@type.icon} class="size-4" />
        </span>
        <span class="block text-xs font-semibold text-ink">{@type.name}</span>
        <span class="block text-[11px] leading-4 text-muted">{@type.blurb}</span>
        <span class={[
          "inline-flex items-center gap-1 text-[10px] font-medium",
          if(@type.kind == :command,
            do: "text-warn-strong",
            else: "text-ok-strong"
          )
        ]}>
          <.icon
            name={
              if @type.kind == :command,
                do: "hero-exclamation-triangle-micro",
                else: "hero-shield-check-micro"
            }
            class="size-3"
          />
          {exposure_words(@type)}
        </span>
      </button>
    <% end %>
    """
  end

  defp source(form), do: if(form[:source].value == "minted", do: "minted", else: "stored")

  defp reach(form), do: if(form[:reach].value == "subgrants", do: "subgrants", else: "vm")

  # The metadata server is for Google's client libraries, whose requests go
  # to Google's APIs: the form offers it on a grant whose hosts are among
  # them, however the grant was made (added, edited, proposed), or that has
  # it on. Elsewhere it would be a box that does nothing.
  defp metadata_offered?(adding),
    do: adding.form[:present_metadata].value in ["true", true] or google_hosts?(adding.form)

  # Signing a JWT as a service account is Google's IAM Credentials: the
  # same hosts, or a grant that already signs.
  defp signing_offered?(adding),
    do: adding.form[:signs_as].value not in [nil, ""] or google_hosts?(adding.form)

  # A Google login is refreshed at Google's token endpoint: the same hosts,
  # or a grant that has one.
  defp login_offered?(adding),
    do: adding.form[:present_login].value in ["true", true] or google_hosts?(adding.form)

  defp google_hosts?(form) do
    form[:hosts].value
    |> to_string()
    |> String.split([",", "\n"])
    |> Enum.any?(&google_api?/1)
  end

  defp google_api?(host) do
    host = host |> String.trim() |> String.downcase() |> String.trim_leading("*.")
    host == "googleapis.com" or String.ends_with?(host, ".googleapis.com")
  end

  attr :form, :any, required: true

  # One minted value for every host, or one per host, its command told
  # which.
  defp mint_per_field(assigns) do
    ~H"""
    <label class="mt-2 flex cursor-pointer items-start gap-2">
      <input type="hidden" name="grant[mint_per]" value="grant" />
      <input
        type="checkbox"
        name="grant[mint_per]"
        id="grant-mint-per"
        value="host"
        checked={@form[:mint_per].value == "host"}
        class="mt-0.5 size-3.5 cursor-pointer accent-accent"
      />
      <span class="text-xs text-ink">
        A value for each host
        <.help id="grant-mint-per-help" label="About a value for each host">
          {field_help(:mint_per)}
        </.help>
        <span class="block text-[10px] text-faint">
          The command is told MWT_HOST, and each host's value is kept apart: for tokens bound to where they go.
        </span>
      </span>
    </label>
    """
  end

  # How long a value it minted is kept at most: for a service that takes
  # a token only while it is young, whatever its expiry says.
  defp keep_field(assigns) do
    ~H"""
    <div class="mt-3 max-w-56">
      <.input
        field={@form[:keep_minutes]}
        type="number"
        min="1"
        max="1440"
        label="Keep each value at most (minutes)"
        placeholder="As the command says"
        help={field_help(:keep_minutes)}
      />
      <.field_error errors={@errors} field={:keep_minutes} />
    </div>
    """
  end

  defp kept_line(assigns) do
    ~H"""
    <p :if={@grant.keep_minutes} id={"grant-keep-#{@grant.id}"} class="mt-1 text-[11px] text-faint">
      Each value kept at most {@grant.keep_minutes} min, then minted again.
    </p>
    """
  end

  @field_help %{
    name:
      "The grant's name, as it shows on its switch, on every approval card and in Activity. When you add it, MWT makes its id from it (lowercase, with dashes): agents use the id in mwt request, mwt exec and mwt call, and it never changes, even when you rename the grant.",
    purpose:
      "What it opens and what for, in your words: the service, the access and the job, such as Push to github.com/me/site and open pull requests. Agents in the VM read it in mwt grants to pick the grant they need, and the search here finds grants by it. It allows nothing by itself: the hosts, destinations or script below decide what goes through.",
    purpose_command:
      "What the script does, in words for any time it runs, such as Lists the pods of a namespace in the staging cluster; not why one agent needs it now. Agents read it in mwt grants to pick the subgrant to call, and the search here finds it by these words. It allows nothing by itself: the script decides what runs.",
    reach:
      "Who uses the real value. The VM, through mwt exec: a command run as mwt exec ID -- COMMAND gets the placeholder in the variables below, and MWT swaps the real value in on its requests to the hosts. Only its subgrants: the VM gets nothing of it, no placeholder, no variable, no file; only the requests you save under it as subgrants use it, sent by MWT itself, and there is nothing of it to turn on. Pick that when a few fixed requests are all the work needs.",
    hosts:
      "The hosts the real value may be sent to, comma separated: api.example.com for that host only, *.example.com for it and every name under it. MWT swaps the placeholder for the real value only in HTTPS requests to these hosts; a placeholder sent anywhere else is refused, and the firewall may isolate the VM for it. MWT reads the requests to these hosts, instead of passing them through, to find the placeholder. A request subgrant's URL must be on one of them.",
    env:
      "Environment variables that hold the placeholder, comma separated, such as GH_TOKEN or STRIPE_API_KEY: the ones the tool reads its token from. Only a command run as mwt exec ID -- COMMAND, and its children, get them: never the VM's shells, so nothing else there holds it. Optional: the placeholder is also in /mnt/mwt/tokens/ID.",
    file_env:
      "Environment variables that hold the path of a file containing the placeholder, comma separated, for tools that read their token from a file, such as CLOUDSDK_AUTH_ACCESS_TOKEN_FILE. Like the variables above, only within mwt exec, and the file holds only the placeholder.",
    carriers:
      "The HTTP headers the real value may travel in, comma separated; Authorization when empty, Basic credentials included. MWT swaps the value into these headers only: a placeholder found in any other header, in the URL or in the body is refused. Name the header the service reads its key from, such as X-Api-Key.",
    present_metadata:
      "Some Google client libraries don't read a token file: they ask a cloud metadata server for default credentials. With this on, mwt exec runs one on loopback for the command's lifetime (GCE_METADATA_HOST), serving the placeholder as the access token; MWT swaps the real value on the way out. It serves only placeholders, and stops when the command ends.",
    signs_as:
      "The service accounts MWT may sign a JWT as for this grant, by email, comma separated. A client of a service behind Identity-Aware Proxy asks Google's IAM Credentials to sign claims it builds (signJwt) and sends the JWT as its bearer; the firewall refuses that request, since its answer is a credential. For these accounts MWT answers it itself: it sends the same request with the real value, keeps the signed JWT, and gives the command a placeholder JWT with the same claims, which goes only to the host its aud names, if the grant lists it. This is a trust decision: the VM may then act as these accounts toward every host the grant lists, through MWT and this grant's approval. Your account needs the Service Account Token Creator role on each.",
    present_login:
      "Some Google tools refresh a login themselves rather than take a token: a CLI that needs your ID token beside its token, for one. With this on, within mwt exec, GOOGLE_APPLICATION_CREDENTIALS names a login file (an authorized_user login) whose refresh token is a placeholder. Its refresh at oauth2.googleapis.com never goes out: MWT answers it from the command that mints this grant's value, with the grant's placeholder as the access token and, when the command prints an id_token beside its value, a placeholder ID token carrying only the real one's iss, aud, iat, exp, email and hd. Google's libraries take the file before a metadata server. Only placeholders reach the VM.",
    present_id_header:
      "The header the tool sends the ID token in, when it isn't the one the grant's value goes in: a service's own, such as X-Id-Token. MWT puts a fresh ID token there, minted again once the one it keeps is older than the grant keeps its values, and refuses the placeholder in any other header.",
    keep_minutes:
      "The longest a value the command minted is kept before MWT mints a new one, in minutes, whatever the command says of its expiry. For a service that accepts a token only while it is young, such as one that refuses an ID token issued more than 5 minutes before: 4 keeps it under that. Empty keeps each value as the command says, or 10 minutes.",
    present_project:
      "The Google Cloud project the metadata server says the credentials belong to: what client libraries take as the default project. Lowercase letters, digits and dashes, as the cloud names it.",
    present_email:
      "The service account the metadata server reports, as an email, for libraries that ask which account they act as. Empty for the default one. It changes nothing the token itself may do.",
    prefix:
      "How the placeholder starts, up to 24 letters, digits, dots, dashes or underscores. Some clients check a token's format before sending it, such as ghp_ for GitHub or sk- for OpenAI: give the prefix they expect, so they accept the placeholder. It is set as the grant is added.",
    git:
      "With it on, git over HTTPS to these hosts, within mwt exec ID -- git …, gets the placeholder as the password from MWT's credential helper, and MWT swaps the real value on the way out. Off, git has no credential for them. Hosts with a * are left out: git asks for exact hosts.",
    mint:
      "A command MWT runs on this machine, as you and with your logins, whenever the VM needs a value and the last one is about to expire. It prints the token, or a JSON object with value and expires_in (seconds): MWT keeps it in memory until a minute before then, else 10 minutes. It is told MWT_GRANT, this grant's id, and MWT_HOST when each host gets its own value. The VM only ever sees a placeholder.",
    source:
      "Where the real value comes from. Stored in your vault: you paste it once; it is kept encrypted with your password, and you replace it on the grant's page. Minted by a command: MWT runs a command of yours on this machine for a short-lived value whenever one is needed, so nothing long-lived is kept.",
    value:
      "The token itself. It is kept in your vault, encrypted with your password, and never shown again; you can replace it on the grant's page. The VM gets a placeholder, worthless anywhere but through MWT, toward the hosts above.",
    mint_per:
      "With it on, each host gets a value of its own: the command is told MWT_HOST, and each host's result is kept apart, for tokens bound to where they go (an audience). Off, one value serves every host.",
    destinations:
      "What the VM may connect to while the grant is on, one a line: an address (10.0.0.5), a range (10.20.0.0/16), a host name (git.corp.internal), or every name under one (*.corp.example), each optionally followed by :ports (:443,5432 or :8000-8100); without ports, every port. A name opens only the addresses MWT's own DNS answered for it. Anything after # is a note. Each request MWT can read waits for you, and each connection it can't, unless you let them through.",
    anchor:
      "Your VPN's network interface on this machine, as ip link shows it: wg0, tun0, utun4. With it, connections under this grant leave only through that interface: while the VPN is down, the grant opens nothing, so these addresses never reach whatever network you are on instead. Empty, they go wherever this machine routes them.",
    resolver:
      "The DNS server that answers the names listed above: an address, with :port when it isn't 53 (10.8.0.1, 10.8.0.1:5353). Use it when this machine can't look those names up itself, such as names only your VPN's DNS knows. Empty, this machine's own resolver answers.",
    method:
      "The HTTP method MWT sends, the same on every call. GET reads; POST, PUT, PATCH and DELETE change something. Keep reading and changing in separate subgrants: one that only reads is easy to trust for good.",
    dir:
      "The folder on this machine the script runs in, as its working directory; ~ is your home folder, and it must exist. A path in a shared folder is the same here and in the VM. Confined, the script reads it, and writes in it only if you allow it below.",
    confined:
      "Runs it in a bubble on this machine (bwrap): an empty home, your tools and the system read-only, its folder read-only unless you allow writing, nothing of your SSH keys, cloud logins or browser profiles in reach, and only the real values of the token grants you name below. Not confined, it runs as you, with everything you can reach: needed for tools that use your own login, such as kubectl with your kubeconfig or gh with your keyring.",
    writes_dir:
      "Lets the confined script change files in its folder; otherwise it can only read them. Nothing else on this machine is writable from the bubble but a scratch folder of its own.",
    with:
      "Token grants, by id, comma separated, whose real values the confined script gets: in the same variables the VM sees their placeholders in, and in their token files. For a script that calls an API itself. Only a confined command takes them, and never a grant minted per host.",
    check_name:
      "What must hold for the grant to be used, written as the agent hears it when it doesn't: the VPN is up, I am on the office network. Keep it short and true when the check passes.",
    check_script:
      "A short script of yours, run confined on this machine for at most a minute, as the grant turns on, once a day while it is on, and whenever you ask. Exit 0 means the condition holds; anything else pauses the grant: it is off for the VM, its uses are refused, and agents are told the condition. A token grant's check gets its real value, as a confined command does; its output is for you only."
  }

  # What a field's value means and what it is used for, behind its ?.
  defp field_help(field), do: Map.fetch!(@field_help, field)

  defp minutes_words(60), do: "1 h"
  defp minutes_words(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes_words(minutes), do: "#{minutes} min"

  attr :errors, :map, required: true
  attr :field, :atom, required: true

  defp field_error(assigns) do
    ~H"""
    <p
      :if={@errors[@field]}
      id={"grant-error-#{@field}"}
      class="mt-1 flex items-center gap-1.5 text-[11px] text-bad"
    >
      <.icon name="hero-exclamation-circle-micro" class="size-3.5" /> {@errors[@field]}
    </p>
    """
  end

  defp exposure_words(%{kind: :token}), do: "VM gets a placeholder"
  defp exposure_words(%{kind: :network}), do: "Nothing to hold"
  defp exposure_words(%{kind: :request}), do: "Your request, sent by MWT with the value"
  defp exposure_words(%{kind: :mwt}), do: "Nothing to hold: MWT does it"
  defp exposure_words(%{id: :saved_command}), do: "Your text, run each time you approve"
  defp exposure_words(%{kind: :command}), do: "Their text, run each time you approve"
end
