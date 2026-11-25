defmodule MWTClientWeb.SandboxLive.Grants do
  @moduledoc """
  The grants page, in three tabs, Grants first shown. **Resources**: every
  resource and its lock (`MWTClientWeb.SandboxLive.ResourcePages`).
  **Grants**: every grant in one list, what ends soonest first, each with
  its time left, duration, approval mode and switch, changeable there, and
  the resource it gives a use of; found by status, resource, how it starts
  and a search, a page at a time. **Console**: a command run in the VM as
  an agent's would be (`MWTClientWeb.SandboxLive.VmConsole`).
  One grant's page has what it does now and its settings, edited in place;
  and the dialog that adds a grant over a resource, or an action.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Firewall, Grant, Param, Presets, SavedRequest}

  @durations [{15, "15 min"}, {60, "1 h"}, {240, "4 h"}, {"until_off", "Until off"}]
  @short_durations [{15, "15m"}, {60, "1h"}, {240, "4h"}, {"until_off", "Until off"}]

  @statuses [
    {"on", "On"},
    {"off", "Off"},
    {"review", "To review"},
    {"all", "All"}
  ]

  # Resources first, as what grants are over; Grants is the one shown
  # first (`tab/1`).
  @tabs [{"resources", "Resources"}, {"grants", "Grants"}, {"console", "Console"}]

  @doc """
  The tab a `tab` parameter names, Grants when it names none. `on` and
  `all`, the tabs Grants replaced, are Grants.
  """
  def tab(value) when value in ["resources", "console"], do: value
  def tab(_value), do: "grants"

  @starts [{"all", "Starts on or off"}, {"on", "Starts on"}, {"off", "Starts off"}]

  @per_page 20

  @doc "The durations a grant can be turned on for."
  def durations, do: @durations

  @doc """
  The filters the list starts with: what is on. Whatever they are, the
  list is in one order: what ends soonest first, then what is on until
  off, then the rest by last use (`catalog/3`).
  """
  def filters, do: %{status: "on", starts: "all", resource: "all"}

  @doc "Filters from the form's params, anything unknown left at its default."
  def filters(params) do
    pick = fn key, options ->
      value = params[Atom.to_string(key)]
      if Enum.any?(options, &(elem(&1, 0) == value)), do: value, else: filters()[key]
    end

    resource = params["resource"]

    %{
      status: pick.(:status, @statuses),
      starts: pick.(:starts, @starts),
      # A resource as `ResourcePages.over_value/1` names it; one no grant
      # is over shows nothing, as any filter that matches nothing does.
      resource:
        if(
          is_binary(resource) and
            resource =~ ~r/\A((credential|network):[a-z0-9][a-z0-9-]*|machine|mwt)\z/,
          do: resource,
          else: "all"
        )
    }
  end

  attr :grants, :list, required: true

  attr :credentials, :list,
    default: [],
    doc: "the credentials grants are over (`MWTClient.Sandbox.Credential`)"

  attr :networks, :list,
    default: [],
    doc: "the networks grants are over, the Internet included (`MWTClient.Sandbox.Network`)"

  attr :locks, :map, default: %{}, doc: "what you locked, by resource"

  attr :durations, :map, required: true, doc: "the duration picked for each grant that is off"
  attr :modes, :map, default: %{}, doc: "the approval mode picked for each grant that is off"
  attr :now, DateTime, required: true
  attr :term, :string, default: "", doc: "what the search looks for"

  attr :filters, :map, default: %{status: "on", starts: "all", resource: "all"}

  attr :page, :integer, default: 1, doc: "the page of the list shown, #{@per_page} rows each"
  attr :tab, :string, default: "grants", doc: "the tab shown: `grants`, `resources` or `console`"
  attr :console, :map, default: %{}, doc: "what the console tab shows (`VmConsole.panel/1`)"
  attr :resource_filters, :map, default: nil, doc: "the Resources tab's filters"
  attr :resource_page, :integer, default: 1

  def page(assigns) do
    %{grants: grants, term: term, filters: filters, now: now} = assigns
    found = search(grants, term)
    rows = catalog(found, filters, now)
    {shown, page, pages} = paged(rows, assigns.page, @per_page)

    assigns =
      assign(assigns,
        rows: rows,
        shown: shown,
        page: page,
        pages: pages,
        per_page: @per_page,
        to_review: Enum.count(grants, &Grant.to_review?/1),
        resources_to_review:
          for(
            resource <- assigns.credentials ++ assigns.networks,
            match?(%{proposal: %{reviewed_at: nil}}, resource),
            do: resource
          ),
        locked: Map.keys(assigns.locks),
        statuses: facet(@statuses, except(found, filters, :status, now), &status_of(&1, now)),
        starts: facet(@starts, except(found, filters, :starts, now), &starts_id/1),
        resources:
          resource_facet(
            except(found, filters, :resource, now),
            assigns.credentials,
            assigns.networks
          ),
        filtered?:
          term != "" or filters.status != "on" or filters.starts != "all" or
            filters.resource != "all",
        tabs: @tabs,
        on_count: Enum.count(grants, &Grant.on?(&1, now)),
        counts: %{
          "grants" => length(grants),
          "resources" => length(assigns.credentials) + length(assigns.networks) + 2
        }
      )

    ~H"""
    <.page_header
      id="grants-header"
      title="Grants"
      subtitle="What agents in the VM may use: your resources, and the grants that give their use."
    >
      <:help>
        A resource is something of yours an agent could use: a credential, a network, your machine. A grant gives a use of one resource while it is on; off, it gives nothing. Two kinds. Open use: agents run their own tools in the VM, and MWT inspects each request as it leaves, holding it to the grant's limits (where it may go, and what it may do there). Fixed call: MWT itself sends one fixed request, or runs your script, on your machine, agents giving only values. A use that goes through two resources (a request with your token, over the Internet) needs a grant over each. Tokens never enter the VM: it gets a placeholder, and MWT swaps the real value in on the way out.
      </:help>
    </.page_header>

    <nav
      id="grants-tabs"
      class="mb-5 flex items-center gap-1 border-b border-line-soft"
      aria-label="Grants"
    >
      <.link
        :for={{value, label} <- @tabs}
        patch={
          if(value == "grants",
            do: ~p"/tools/sandbox/grants",
            else: ~p"/tools/sandbox/grants?tab=#{value}"
          )
        }
        id={"grants-tab-#{value}"}
        aria-current={@tab == value && "page"}
        class={[
          "-mb-px inline-flex items-center gap-1.5 border-b-2 px-3 py-2 text-[13px] font-medium transition-colors",
          if(@tab == value,
            do: "border-accent text-ink",
            else: "border-transparent text-muted hover:border-line hover:text-ink"
          )
        ]}
      >
        {label}
        <span
          :if={@counts[value]}
          class={[
            "rounded-full px-1.5 text-[10px] tabular-nums",
            if(@tab == value, do: "bg-accent-soft/60 text-accent", else: "bg-deep text-faint")
          ]}
        >
          {@counts[value]}
        </span>
      </.link>
    </nav>

    <.needs_you
      to_review={@to_review}
      resources_to_review={@resources_to_review}
      locked={@locked}
      credentials={@credentials}
      networks={@networks}
    />

    <section :if={@tab == "grants"} id="grants-list" aria-label="Grants">
      <form
        id="grant-filters"
        phx-change="filter_grants"
        phx-submit="filter_grants"
        class="mb-3 flex flex-wrap items-center gap-2"
        autocomplete="off"
      >
        <div
          id="grant-status"
          role="radiogroup"
          aria-label="Status"
          class="flex items-center rounded-lg border border-line bg-deep p-0.5"
        >
          <label
            :for={{value, label, count} <- @statuses}
            id={"grant-status-#{value}"}
            class={[
              "flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1 text-[12px] transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
              if(@filters.status == value,
                do: "bg-panel font-medium text-ink shadow-sm",
                else: "text-muted hover:text-ink"
              )
            ]}
          >
            <input
              type="radio"
              name="status"
              value={value}
              checked={@filters.status == value}
              class="sr-only"
            />
            {label}
            <span class="text-[10px] tabular-nums opacity-70">{count}</span>
          </label>
        </div>
        <div class="relative min-w-48 flex-1">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="term"
            id="grant-search-term"
            value={@term}
            placeholder="Search: name, hosts, script…"
            phx-debounce="120"
            class="w-full rounded-lg border border-line bg-panel py-1.5 pl-8 pr-2 text-[12px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
          />
        </div>
        <.filter_select
          id="grant-resource"
          name="resource"
          options={@resources}
          value={@filters.resource}
          all="Every resource"
        />
        <.filter_select
          id="grant-starts"
          name="starts"
          options={@starts}
          value={@filters.starts}
          all="Starts on or off"
        />
        <button
          :if={@filtered?}
          type="button"
          id="grant-filters-clear"
          phx-click="clear_grant_filters"
          class="inline-flex cursor-pointer items-center gap-1 text-[11px] font-medium text-accent hover:underline"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" /> Clear
        </button>
        <span class="flex-1"></span>
        <.button id="add-grant" type="button" phx-click="open_add_grant">
          <.icon name="hero-plus-micro" class="size-3.5" /> Add grant
        </.button>
      </form>

      <div :if={@rows != []} class="overflow-hidden rounded-xl border border-line bg-panel">
        <ul id="grants-rows" class="divide-y divide-line-soft">
          <.grant_row
            :for={%{grant: grant} <- @shown}
            grant={grant}
            over={over_of(grant, @credentials, @networks)}
            duration={row_duration(grant, @durations, @now)}
            mode={row_mode(grant, @modes, @now)}
            now={@now}
          />
        </ul>
      </div>
      <.pages
        :if={@pages > 1}
        name="grants"
        label="Pages of grants"
        page={@page}
        pages={@pages}
        per_page={@per_page}
        total={length(@rows)}
        event="grants_page"
        class="mt-3"
      />
      <div
        :if={@rows == []}
        id="grants-no-match"
        class="rounded-xl border border-dashed border-line"
      >
        <.empty icon={
          if(@filters.status == "on" and not @filtered?,
            do: "hero-power",
            else: "hero-magnifying-glass"
          )
        }>
          <%= if @filters.status == "on" and not @filtered? do %>
            Nothing is on: agents in the VM can use nothing through MWT. Turn a grant on, or let an agent ask for one.
            <button
              type="button"
              id="grants-show-all"
              phx-click="filter_grants"
              phx-value-status="all"
              class="cursor-pointer text-accent hover:underline"
            >
              Show every grant
            </button>
          <% else %>
            {no_match_words(@term)}
            <button
              type="button"
              id="grants-clear-filters"
              phx-click="clear_grant_filters"
              class="cursor-pointer text-accent hover:underline"
            >
              Clear the search and filters
            </button>
          <% end %>
        </.empty>
      </div>
    </section>

    <MWTClientWeb.SandboxLive.ResourcePages.list
      :if={@tab == "resources"}
      grants={@grants}
      credentials={@credentials}
      networks={@networks}
      locks={@locks}
      now={@now}
      filters={@resource_filters || MWTClientWeb.SandboxLive.ResourcePages.resource_filters()}
      page={@resource_page}
    />

    <MWTClientWeb.SandboxLive.VmConsole.panel
      :if={@tab == "console"}
      credentials={@credentials}
      history={@console[:history] || []}
      term={@console[:term] || ""}
      page={@console[:page] || 1}
      open={@console[:open]}
      decisions={@console[:decisions] || []}
      error={@console[:error]}
      now={@console[:now] || DateTime.utc_now()}
      running={@console[:running]}
      vm_running={@console[:vm_running] || false}
      console_with={@console[:with] || %{}}
      waiting={@console[:waiting] || []}
    />
    """
  end

  attr :to_review, :integer, required: true
  attr :resources_to_review, :list, required: true
  attr :locked, :list, required: true
  attr :credentials, :list, required: true
  attr :networks, :list, required: true

  # What waits for you, in one strip: what agents proposed, and what is
  # locked.
  defp needs_you(assigns) do
    ~H"""
    <div
      :if={@to_review > 0 or @resources_to_review != [] or @locked != []}
      id="grants-needs-you"
      class="mb-5 space-y-1.5 rounded-lg border border-warn/40 bg-warn-soft/20 px-3 py-2.5 text-[12px] text-ink"
    >
      <p
        :if={@resources_to_review != []}
        id="resources-to-review"
        class="flex flex-wrap items-center gap-x-2 gap-y-1"
      >
        <.icon name="hero-sparkles-micro" class="size-4 text-warn" />
        <span>Proposed by an agent, to review first:</span>
        <.link
          :for={resource <- @resources_to_review}
          navigate={
            MWTClient.Sandbox.Resource.path(
              if(match?(%MWTClient.Sandbox.Credential{}, resource),
                do: {:credential, resource.id},
                else: {:network, resource.id}
              )
            )
          }
          id={"resources-to-review-#{resource.id}"}
          class="font-semibold text-accent hover:underline"
        >
          {resource.name}
        </.link>
      </p>
      <p
        :if={@to_review > 0}
        id="grants-to-review"
        class="flex flex-wrap items-center gap-x-2 gap-y-1"
      >
        <.icon name="hero-sparkles-micro" class="size-4 text-warn" />
        <span>
          {if @to_review == 1,
            do: "A grant an agent proposed waits for you.",
            else: "#{@to_review} grants agents proposed wait for you."}
        </span>
        <button
          type="button"
          id="grants-show-to-review"
          phx-click="filter_grants"
          phx-value-status="review"
          phx-value-term=""
          class="cursor-pointer font-semibold text-accent hover:underline"
        >
          Show {if @to_review == 1, do: "it", else: "them"}
        </button>
      </p>
      <p :if={@locked != []} id="grants-locked" class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <.icon name="hero-lock-closed-micro" class="size-4 text-bad" />
        <span>Locked, refusing every use whatever the grants say:</span>
        <.resource_chip
          :for={resource <- @locked}
          resource={resource}
          name={MWTClient.Sandbox.Resource.name(resource, @credentials, @networks)}
          id={"grants-locked-#{MWTClientWeb.SandboxLive.ResourcePages.dom_id(resource)}"}
        />
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true, doc: "`{value, label, count}`, All first"
  attr :value, :string, required: true
  attr :all, :string, required: true, doc: "what All reads as"

  # A filter of the list as a select: each option with how many rows it
  # would show with the other filters as they are.
  defp filter_select(assigns) do
    ~H"""
    <select
      name={@name}
      id={@id}
      aria-label={@all}
      class={[
        "max-w-48 rounded-lg border bg-panel px-2 py-1.5 text-[12px] focus:border-accent focus:outline-none",
        if(@value == "all", do: "border-line text-muted", else: "border-accent/50 text-ink")
      ]}
    >
      <option
        :for={{value, label, count} <- @options}
        id={"#{@id}-#{String.replace(value, ":", "-")}"}
        value={value}
        selected={@value == value}
      >
        {if(value == "all", do: @all, else: label)} ({count})
      </option>
    </select>
    """
  end

  @doc """
  Whether a grant is one of those on from startup and until off, as MWT
  left them.
  """
  def standard?(%Grant{start: start, expires_at: nil}) when start in [:on, :auto], do: true
  def standard?(%Grant{}), do: false

  defp short_durations, do: @short_durations

  defp no_match_words(""), do: "Nothing matches these filters."
  defp no_match_words(term), do: "Nothing matches “#{term}” with these filters."

  @doc """
  The rows the list shows: the grants that pass the filters, what ends
  soonest first, then what is on until off, then the rest by last use,
  never used last, by name.
  """
  def catalog(grants, filters, now) do
    grants
    |> filtered(filters, now)
    |> sorted(now)
    |> Enum.map(&%{grant: &1})
  end

  # The grants that pass every filter.
  defp filtered(grants, filters, now) do
    grants
    |> by_status(filters.status, now)
    |> by(Map.get(filters, :starts, "all"), &starts_id/1)
    |> by_resource(Map.get(filters, :resource, "all"))
  end

  # The grants that pass every filter but `key`'s: what that filter's
  # counts are counted over.
  defp except(grants, filters, key, now),
    do: filtered(grants, Map.put(filters, key, "all"), now)

  defp by(grants, "all", _value_of), do: grants
  defp by(grants, value, value_of), do: Enum.filter(grants, &(value_of.(&1) == value))

  defp starts_id(%Grant{start: start}), do: if(start in [:on, :auto], do: "on", else: "off")

  defp by_resource(grants, "all"), do: grants

  defp by_resource(grants, resource),
    do:
      Enum.filter(
        grants,
        &(MWTClientWeb.SandboxLive.ResourcePages.over_value(Grant.resource(&1)) == resource)
      )

  # The resources the grants are over, by name, each with how many: All,
  # then each resource, the built-in ones last.
  defp resource_facet(grants, credentials, networks) do
    alias MWTClientWeb.SandboxLive.ResourcePages

    counts = Enum.frequencies_by(grants, &ResourcePages.over_value(Grant.resource(&1)))

    resources =
      Enum.map(credentials, &{:credential, &1.id}) ++
        Enum.map(networks, &{:network, &1.id}) ++ [:machine, :mwt]

    [{"all", "All", length(grants)}] ++
      for resource <- resources,
          value = ResourcePages.over_value(resource),
          Map.has_key?(counts, value),
          do:
            {value, MWTClient.Sandbox.Resource.name(resource, credentials, networks),
             Map.fetch!(counts, value)}
  end

  defp by_status(grants, "all", _now), do: grants
  defp by_status(grants, status, now), do: Enum.filter(grants, &(status_of(&1, now) == status))

  defp status_of(grant, now) do
    cond do
      Grant.to_review?(grant) -> "review"
      true -> grant |> Grant.state_at(now) |> Atom.to_string()
    end
  end

  # What ends soonest first, then what is on until off, then the rest by
  # last use.
  defp sorted(grants, now) do
    grants
    |> by_last_use()
    |> Enum.sort_by(fn grant ->
      cond do
        Grant.on?(grant, now) and grant.expires_at -> {0, DateTime.to_unix(grant.expires_at)}
        Grant.on?(grant, now) -> {1, 0}
        true -> {2, 0}
      end
    end)
  end

  # A filter's options with their counts: All, then each option.
  defp facet(options, grants, value_of) do
    counts = Enum.frequencies_by(grants, value_of)

    for {value, label} <- options,
        do:
          {value, label, if(value == "all", do: length(grants), else: Map.get(counts, value, 0))}
  end

  # The duration and approval mode a row shows as chosen: on, what the
  # grant is on for and how; off, what you picked for turning it on.
  def row_duration(grant, durations, now),
    do: if(Grant.on?(grant, now), do: on_duration(grant), else: Map.get(durations, grant.id, 60))

  # What a grant that is on is on for, or until off when it has no end.
  defp on_duration(%Grant{expires_at: nil}), do: "until_off"
  defp on_duration(%Grant{minutes: minutes}) when is_integer(minutes), do: minutes
  defp on_duration(%Grant{}), do: nil

  @doc "The approval mode a grant's row offers while it is off and you picked none (`Grant.default_uses/1`)."
  @spec default_mode(Grant.t()) :: String.t()
  def default_mode(grant), do: if(Grant.default_uses(grant) == :all, do: "all", else: "ask")

  def row_mode(grant, modes, now) do
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

  attr :over, :any, default: nil, doc: "the resource it mediates and its name, `{resource, name}`"

  # One grant: what it is, in a few tags (the resource it is over; over a
  # credential, its kind and where it runs; proposed, or how it starts),
  # and how long it stays on and how its uses are approved.
  def grant_row(assigns) do
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
            <.resource_chip
              :if={@over}
              id={"#{@prefix}-over-#{@grant.id}"}
              resource={elem(@over, 0)}
              name={elem(@over, 1)}
            />
            <.kind_badge id={"#{@prefix}-kind-#{@grant.id}"} kind={Grant.kind_of(@grant)} />
            <.where
              :if={Grant.host_command?(@grant)}
              id={"#{@prefix}-where-#{@grant.id}"}
              place={:machine}
            />
            <%= cond do %>
              <% Grant.proposed?(@grant) -> %>
                <.proposed_badge grant={@grant} id={"#{@prefix}-origin-#{@grant.id}"} />
              <% @grant.start in [:on, :auto] -> %>
                <.start_badge grant={@grant} id={"#{@prefix}-start-#{@grant.id}"} />
              <% true -> %>
            <% end %>
          </span>
        </div>
        <p class="mt-0.5 truncate font-mono text-[10px] text-faint" title={summary(@grant)}>
          {summary(@grant)}
        </p>
      </div>
      <.controls
        :if={not Grant.to_review?(@grant)}
        grant={@grant}
        id={@prefix}
        duration={@duration}
        mode={@mode}
        now={@now}
        short
      />
      <.link
        :if={Grant.to_review?(@grant)}
        patch={~p"/tools/sandbox/grants/#{@grant.id}"}
        id={"#{@prefix}-review-#{@grant.id}"}
        class="inline-flex items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110"
      >
        <.icon name="hero-eye-micro" class="size-3.5" /> Review
      </.link>
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
        id={"#{@id}-mode-#{@grant.id}"}
        options={
          cond do
            Grant.always_asks?(@grant) and @short -> [{"ask", "Ask"}]
            Grant.always_asks?(@grant) -> [{"ask", "Always asks"}]
            @short -> [{"ask", "Ask"}, {"all", "Auto"}]
            true -> [{"ask", "Ask each time"}, {"all", "Auto-approve"}]
          end
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

  @doc "The resource a grant mediates, and its name, for its row: `{resource, name}`."
  def over_of(%Grant{} = grant, credentials, networks) do
    resource = Grant.resource(grant)
    {resource, MWTClient.Sandbox.Resource.name(resource, credentials, networks)}
  end

  def summary(%Grant{kind: :token} = grant) do
    hosts =
      case grant.hosts do
        [first, second | [_ | _] = rest] -> "#{first}, #{second} +#{length(rest)}"
        hosts -> Enum.join(hosts, ", ")
      end

    only =
      case grant.attributes || %{} do
        empty when map_size(empty) == 0 -> ""
        attributes -> " · only #{MWTClient.Sandbox.Attributes.words(attributes)}"
      end

    case grant.env do
      [] -> "→ #{hosts}#{only}"
      env -> "#{Enum.join(env, ", ")} → #{hosts}#{only}"
    end
  end

  def summary(%Grant{kind: :network, internet: true} = grant),
    do: "Every public address" <> except_summary(grant)

  def summary(%Grant{kind: :network, destinations: destinations} = grant),
    do: Enum.join(destinations, "  ·  ") <> except_summary(grant)

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

  def summary(%Grant{kind: :agent_commands}), do: "mwt run -- COMMAND  ·  every run asks"

  def summary(%Grant{kind: :request} = grant),
    do: "#{Grant.signature(grant)}  ·  #{grant.method} #{grant.url}"

  def summary(%Grant{kind: :command, script: script, dir: dir} = grant),
    do: "#{Grant.signature(grant)}  ·  #{script |> String.split("\n") |> hd()}  ·  in #{dir}"

  # The hosts a network grant leaves out, after what it covers.
  defp except_summary(%Grant{except: []}), do: ""
  defp except_summary(%Grant{except: except}), do: "  ·  except " <> Enum.join(except, ", ")

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
      <.icon name="hero-power-micro" class="size-3" /> Starts on
    </span>
    """
  end

  defp start_approval(%Grant{start: :auto}), do: "every use going through without asking"

  defp start_approval(%Grant{}), do: "every use waiting for you"

  ## One grant

  attr :grant, Grant, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true
  attr :events, :list, required: true
  attr :duration, :any, required: true, doc: "the duration picked while it is off"
  attr :mode, :string, default: "ask", doc: "the approval mode picked while it is off"
  attr :now, DateTime, required: true
  attr :grants, :list, default: [], doc: "every grant, for the ones it overlaps"
  attr :credentials, :list, default: []
  attr :networks, :list, default: []
  attr :locks, :map, default: %{}, doc: "what is locked, by resource"
  attr :credential_values, :map, default: %{}, doc: "whether each credential has a value, by id"

  attr :settings, :map,
    default: nil,
    doc: "its settings' form: `form`, `errors`, `preset`, `dirty` (`grant_settings_*` events)"

  @doc """
  One grant's page, in two parts. **Now**: whether it is on, for how
  long, how its uses are approved, what holds it back, what it allows
  without asking, and its last uses; each change applies at once.
  **Settings**: what it is, edited in place and kept once saved, the
  common fields first and the rest under Advanced. What the VM gets, in
  detail, is folded below.
  """
  def detail(assigns) do
    on? = Grant.on?(assigns.grant, assigns.now)
    resource = Grant.resource(assigns.grant)
    alias MWTClient.Sandbox.Resource

    credential =
      with {:credential, id} <- resource,
           do: Enum.find(assigns.credentials, &(&1.id == id)),
           else: (_ -> nil)

    # Another grant that is on and covers the same uses: turning this one
    # off wouldn't stop them.
    covering =
      for %{grant: other, may?: false} <-
            MWTClient.Sandbox.Overlaps.of(assigns.grant, assigns.grants),
          Grant.on?(other, assigns.now),
          do: other

    assigns =
      assign(assigns,
        resource: resource,
        resource_name: Resource.name(resource, assigns.credentials, assigns.networks),
        over_credential: credential,
        covering: covering,
        unreached: unreached(assigns.grant, assigns),
        locked: Map.has_key?(assigns.locks, resource),
        resource_to_review: Resource.to_review?(resource, assigns.credentials, assigns.networks),
        no_value:
          match?(%MWTClient.Sandbox.Credential{source: :stored}, credential) and
            not Map.get(assigns.credential_values, credential.id, false),
        duration: if(on?, do: on_duration(assigns.grant), else: assigns.duration),
        mode:
          cond do
            not on? -> assigns.mode
            Grant.auto_approved?(assigns.grant, assigns.now) -> "all"
            true -> "ask"
          end
      )

    ~H"""
    <nav id="grant-crumbs" class="mb-4">
      <.link
        patch={~p"/tools/sandbox/grants"}
        id="grant-back"
        class="inline-flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-accent"
      >
        <.icon name="hero-arrow-left-micro" class="size-3.5" /> Grants
      </.link>
    </nav>

    <header id={"grant-detail-#{@grant.id}"} class="mb-5 flex flex-wrap items-start gap-3">
      <.grant_tile icon={Presets.icon(@grant)} on={Grant.on?(@grant)} class="size-11" />
      <div class="min-w-0 flex-1 basis-80">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-xl font-semibold tracking-tight text-ink">{@grant.name}</h1>
          <.kind_badge id="detail-kind" kind={Grant.kind_of(@grant)} />
          <.where :if={Grant.host_command?(@grant)} id="detail-where" place={:machine} />
          <.proposed_badge grant={@grant} id="detail-proposed" />
        </div>
        <p class="mt-1 flex flex-wrap items-center gap-1.5 text-[13px] text-muted">
          Over <.resource_chip id="grant-resource" resource={@resource} name={@resource_name} />
        </p>
        <p :if={@grant.purpose != ""} class="mt-1 max-w-3xl text-[13px] leading-5 text-ink">
          {@grant.purpose}
        </p>
      </div>
    </header>

    <.review
      :if={Grant.to_review?(@grant)}
      grant={@grant}
      grants={@grants}
      has_value={@has_value}
      now={@now}
      resource_to_review={if @resource_to_review, do: {@resource, @resource_name}}
    />

    <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_21rem]">
      <div class="min-w-0 space-y-3">
        <.form
          :if={@settings}
          for={@settings.form}
          id="grant-settings-form"
          phx-change="grant_settings_change"
          phx-submit="grant_settings_save"
          class="rounded-xl border border-line bg-panel shadow-sm"
        >
          <header id="grant-settings" class="border-b border-line-soft px-5 py-3.5">
            <h2 class="text-[14px] font-semibold text-ink">Settings</h2>
            <p class="mt-0.5 text-[12px] text-muted">
              What it gives and how. Changes are kept once you save them.
            </p>
          </header>
          <div class="space-y-5 px-5 py-5">
            <.grant_fields
              :if={not Grant.built_in?(@grant)}
              adding={@settings}
              editing={@grant}
              over={@resource}
              over_credential={@over_credential}
              over_name={@resource_name}
              credentials={@credentials}
            />
            <.except_field
              :if={Grant.internet?(@grant)}
              id="internet-except"
              form={@settings.form}
              errors={@settings.errors}
            />
            <.choice_field
              id="grant-start"
              name="grant[start]"
              label="When MWT starts"
              options={
                for start <- Grant.starts(@grant),
                    do: {start, start_label(start, Grant.starts(@grant))}
              }
              value={@settings.form[:start].value}
              hint="Saved, it applies now too, and at each start."
            />
          </div>
          <footer
            id="grant-settings-bar"
            class="sticky bottom-0 flex items-center justify-end gap-2 rounded-b-xl border-t border-line-soft bg-panel/95 px-5 py-3 backdrop-blur"
          >
            <.button
              :if={not Grant.built_in?(@grant)}
              type="button"
              id="delete-grant"
              variant="danger"
              title={remove_words(@grant)}
              phx-click="confirm_delete_grant"
              phx-value-id={@grant.id}
            >
              <.icon name="hero-trash-micro" class="size-3.5" /> Remove
            </.button>
            <span class={[
              "mr-auto text-[12px]",
              if(@settings.dirty, do: "text-warn-strong", else: "text-faint")
            ]}>
              {if(@settings.dirty, do: "Changes not saved yet", else: "Saved")}
            </span>
            <.button
              :if={@settings.dirty}
              type="button"
              id="grant-settings-cancel"
              phx-click="grant_settings_cancel"
            >
              Cancel
            </.button>
            <.button
              type="submit"
              id="grant-settings-save"
              variant="primary"
              disabled={not @settings.dirty}
            >
              Save
            </.button>
          </footer>
        </.form>
        <p
          :if={Grant.built_in?(@grant)}
          id="grant-kept"
          class="flex items-center gap-2 px-1 text-[11px] leading-4 text-faint"
        >
          <.icon name="hero-shield-check-micro" class="size-3.5 shrink-0" />
          MWT's own grant: it can't be removed, and only {cond do
            Grant.internet?(@grant) -> "the hosts it leaves out, how it starts and how it asks"
            Grant.always_asks?(@grant) -> "whether it starts on: it always asks"
            true -> "how it starts and how it asks"
          end} change. Turn it off to stop it.
        </p>
      </div>

      <aside class="space-y-4 lg:sticky lg:top-4">
        <section id="grant-now" class="rounded-xl border border-line bg-panel p-4 shadow-sm">
          <div class="flex items-center gap-3">
            <div class="min-w-0 flex-1">
              <p class="text-[12px] font-semibold text-ink">Now</p>
              <p id="grant-state" class="mt-0.5 text-[13px] text-muted">
                <%= cond do %>
                  <% Grant.to_review?(@grant) -> %>
                    Off until you accept it
                  <% Grant.on?(@grant, @now) and @grant.expires_at -> %>
                    <span class="font-medium text-ok-strong">On</span>
                    ·
                    <.clock
                      id={"detail-clock-#{@grant.id}"}
                      deadline={@grant.expires_at}
                      suffix=" left"
                      done="ending…"
                      now={@now}
                    />
                  <% Grant.on?(@grant, @now) -> %>
                    <span class="font-medium text-ok-strong">On</span> · until off
                  <% true -> %>
                    Off
                <% end %>
              </p>
            </div>
            <.switch
              :if={not Grant.to_review?(@grant)}
              id={"detail-switch-#{@grant.id}"}
              on={Grant.on?(@grant, @now)}
              label={
                if(Grant.on?(@grant, @now),
                  do: "Turn #{@grant.name} off",
                  else: "Turn #{@grant.name} on"
                )
              }
              phx-click={if(Grant.on?(@grant, @now), do: "turn_off", else: "turn_on")}
              phx-value-id={@grant.id}
            />
          </div>
          <div :if={not Grant.to_review?(@grant)} class="mt-3 space-y-2.5">
            <div>
              <p class="mb-1 text-[11px] text-muted">
                {if(Grant.on?(@grant, @now), do: "On for", else: "Turns on for")}
              </p>
              <.segmented
                id={"detail-duration-#{@grant.id}"}
                options={short_durations()}
                value={@duration}
                event={if(Grant.on?(@grant, @now), do: "set_duration", else: "pick_duration")}
                name="minutes"
                values={%{"id" => @grant.id}}
              />
            </div>
            <div>
              <p class="mb-1 text-[11px] text-muted">Each use</p>
              <.segmented
                id={"detail-mode-#{@grant.id}"}
                options={
                  if(Grant.always_asks?(@grant),
                    do: [{"ask", "Always asks"}],
                    else: [{"ask", "Ask me"}, {"all", "Auto"}]
                  )
                }
                value={@mode}
                event={if(Grant.on?(@grant, @now), do: "set_mode", else: "pick_mode")}
                name="mode"
                values={%{"id" => @grant.id}}
                tone={:mode}
              />
            </div>
          </div>
          <ul
            :if={@locked or @no_value or @resource_to_review or @covering != [] or @unreached != []}
            id="grant-blockers"
            class="mt-3 space-y-1.5 border-t border-line-soft pt-3 text-[12px]"
          >
            <li :if={@locked} id="grant-resource-locked" class="flex items-start gap-1.5 text-bad">
              <.icon name="hero-lock-closed-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>{@resource_name} is locked: every use is refused.</span>
            </li>
            <li
              :if={@no_value}
              id="grant-resource-no-value"
              class="flex items-start gap-1.5 text-warn-strong"
            >
              <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>
                {@resource_name} has no value yet: paste it on <.link
                  navigate={MWTClient.Sandbox.Resource.path(@resource)}
                  class="underline"
                >its page</.link>.
              </span>
            </li>
            <li
              :if={@resource_to_review}
              id="grant-resource-to-review"
              class="flex items-start gap-1.5 text-warn-strong"
            >
              <.icon name="hero-sparkles-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>An agent proposed {@resource_name}: accept it on its page first.</span>
            </li>
            <li
              :if={@unreached != []}
              id="grant-unreached"
              class="flex items-start gap-1.5 text-bad"
            >
              <.icon name="hero-no-symbol-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>
                Nothing lets its requests out, as it would the agent's own: {Enum.join(
                  @unreached,
                  "; "
                )}. Each is refused until a grant over the network lets it out.
              </span>
            </li>
            <li
              :if={@covering != []}
              id="grant-covered-by"
              class="flex items-start gap-1.5 text-muted"
            >
              <.icon name="hero-information-circle-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>
                Also covered by <.link
                  :for={other <- @covering}
                  patch={~p"/tools/sandbox/grants/#{other.id}"}
                  class="font-medium text-ink underline"
                >{other.name}</.link>, on: turning this off doesn't stop the uses they share.
              </span>
            </li>
          </ul>
          <div
            :if={@grant.allowances != []}
            id="grant-allowances"
            class="mt-3 border-t border-line-soft pt-3"
          >
            <p class="mb-1.5 text-[11px] text-muted">Allowed without asking, for now</p>
            <ul class="space-y-1">
              <li
                :for={allowance <- @grant.allowances}
                id={"allowance-#{allowance.id}"}
                class="flex items-center gap-2 text-[11px]"
              >
                <span :if={allowance.pattern == :all} class="flex-1 font-medium text-ok-strong">
                  Every use
                </span>
                <span
                  :if={allowance.pattern != :all}
                  class="min-w-0 flex-1 truncate font-mono text-ink"
                  title={allowance.pattern}
                >
                  {allowance.pattern}
                </span>
                <span class="text-[10px] text-faint">
                  <%= if allowance.until do %>
                    <.clock
                      id={"allowance-left-#{allowance.id}"}
                      deadline={allowance.until}
                      suffix=" left"
                      now={@now}
                    />
                  <% else %>
                    while on
                  <% end %>
                </span>
                <button
                  type="button"
                  id={"revoke-allowance-#{allowance.id}"}
                  phx-click="revoke_allowance"
                  phx-value-id={@grant.id}
                  phx-value-allowance={allowance.id}
                  class="cursor-pointer rounded px-1.5 py-0.5 text-muted transition-colors hover:bg-bad-soft/40 hover:text-bad"
                >
                  End
                </button>
              </li>
            </ul>
          </div>
        </section>

        <section id="grant-kind" class="rounded-xl border border-line bg-panel p-4 shadow-sm">
          <div class="flex items-center gap-2">
            <p class="text-[12px] font-semibold text-ink">{kind_name(Grant.kind_of(@grant))}</p>
            <.where :if={Grant.host_command?(@grant)} place={:machine} />
          </div>
          <p class="mt-1.5 text-[12px] leading-5 text-muted">
            {kind_words(Grant.kind_of(@grant))}
          </p>
          <p id="grant-kind-use" class="mt-1.5 text-[12px] leading-5 text-ink">
            {use_words(@grant)}
          </p>
          <p
            :if={Grant.kind_of(@grant) == :fixed and @grant.kind != :mwt}
            id="grant-kind-covers"
            class="mt-1.5 text-[11px] leading-4 text-faint"
          >
            {covers_words(@grant)}
          </p>
          <.openness grant={@grant} />
          <p
            :if={@grant.kind == :network and not MWTClient.Sandbox.Network.part?(@grant)}
            id="grant-network-part"
            class="mt-1.5 text-[11px] leading-4 text-faint"
          >
            Some hosts on other terms (one that always asks, say): list them under
            <span class="font-medium text-muted">Except these hosts</span>
            in Settings, then
            <button
              type="button"
              id="grant-network-add-part"
              phx-click="open_add_grant"
              phx-value-preset="network"
              phx-value-over={"network:#{MWTClient.Sandbox.Network.id_of(@grant)}"}
              class="cursor-pointer font-medium text-accent hover:underline"
            >
              add a grant over them
            </button>
            with those hosts as its request targets. Only some hosts: turn this one off and add that grant.
          </p>
          <p :if={@grant.kind == :token} class="mt-2 select-all font-mono text-[11px] text-ink">
            mwt exec {Grant.credential_id(@grant)} -- COMMAND
          </p>
          <p :if={Grant.action?(@grant)} class="mt-2 select-all font-mono text-[11px] text-ink">
            {Grant.signature(@grant)}
          </p>
          <.link
            :if={@grant.kind in [:token, :network]}
            navigate={try_path(@grant)}
            id="grant-try"
            class="mt-3 inline-flex items-center gap-1 text-[12px] font-medium text-accent hover:underline"
          >
            <.icon name="hero-command-line-micro" class="size-3.5" /> Try it as the VM
          </.link>
        </section>

        <section id="grant-activity" class="rounded-xl border border-line bg-panel p-4 shadow-sm">
          <div class="mb-2 flex items-center gap-2">
            <p class="flex-1 text-[12px] font-semibold text-ink">Last uses</p>
            <.link
              navigate={~p"/tools/sandbox/activity"}
              class="text-[11px] text-accent hover:underline"
            >
              Activity log
            </.link>
          </div>
          <p :if={@events == []} class="text-[12px] text-faint">Nothing has used it yet.</p>
          <ul :if={@events != []} class="space-y-1.5">
            <li
              :for={event <- Enum.take(@events, 5)}
              id={"grant-event-#{event.id}"}
              class="flex items-start gap-2"
            >
              <.outcome_badge outcome={event.outcome} />
              <p class="min-w-0 flex-1 truncate text-[11px] leading-4 text-ink" title={event.summary}>
                {event.summary}
              </p>
              <span class="shrink-0 text-[10px] text-faint">
                <.clock id={"grant-event-at-#{event.id}"} since={event.at} now={@now} />
              </span>
            </li>
          </ul>
        </section>

        <details id="grant-details" class="group rounded-xl border border-line bg-panel shadow-sm">
          <summary class="flex cursor-pointer list-none items-center gap-1.5 px-4 py-3 text-[12px] font-semibold text-ink">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3.5 text-muted transition-transform group-open:rotate-90"
            /> What the VM gets
            <span class="ml-auto font-mono text-[10px] font-normal text-faint">id {@grant.id}</span>
          </summary>
          <div class="space-y-2 border-t border-line-soft px-4 py-3">
            <.exposure grant={@grant} />
            <.delivery grant={@grant} parent_name={@resource_name} />
            <p class="text-[10px] leading-4 text-faint">{delivery_help(@grant)}</p>
          </div>
        </details>
      </aside>
    </div>
    """
  end

  # The hosts a grant's requests go to that no network grant lets out now,
  # as it would the agent's own (`MWTClient.Sandbox.Policy.reach/3`), each
  # with why in a few words: a request action's host, a token grant's.
  # A lock says so on its own line.
  defp unreached(%Grant{kind: kind} = grant, assigns) when kind in [:request, :token] do
    hosts =
      if kind == :request,
        do: [SavedRequest.host(grant)],
        else: Enum.map(grant.hosts, &String.replace_prefix(&1, "*.", ""))

    limits = Map.new(assigns.networks, &{&1.id, &1.limits})
    snapshot = MWTClient.Sandbox.Policy.snapshot(assigns.grants, [], assigns.locks, limits)

    for host <- Enum.uniq(hosts),
        is_binary(host),
        {:refuse, reason} <- [MWTClient.Sandbox.Policy.reach(snapshot, host, assigns.now)],
        words = unreached_words(host, reason),
        do: words
  end

  defp unreached(_grant, _assigns), do: []

  defp unreached_words(host, {:grant_off, other}),
    do: "#{host}, which #{other.name} would let out, and is off"

  defp unreached_words(host, {:outside, _network}), do: "#{host}, which no grant covers"

  defp unreached_words(host, {:excepted, other, entry}),
    do: "#{host}, which #{other.name} leaves out (#{entry})"

  defp unreached_words(host, {:host_blocked, _network, _entry}),
    do: "#{host}, blocked on its network"

  defp unreached_words(host, {:locked, {:network, _id}, _grant}),
    do: "#{host}, whose network is locked"

  defp unreached_words(host, _other), do: "#{host}"

  # How agents use a grant, and where what it lets through goes.
  defp use_words(%Grant{kind: :token} = grant),
    do:
      "Agents run their own tools in the VM with mwt exec #{Grant.credential_id(grant)}, which gives them placeholders; MWT swaps in the real value on the way out, only toward the hosts this grant lists. Each request also needs a grant over its network."

  defp use_words(%Grant{kind: :request} = grant),
    do:
      "Agents call it by id with values; MWT builds the request, #{grant.method} to #{SavedRequest.host(grant)}, and sends it through the same checks as the agents' own."

  defp use_words(%Grant{kind: :network}),
    do:
      "Agents' own tools reach it from the VM; MWT checks each connection and request as it leaves."

  defp use_words(%Grant{kind: :agent_commands}),
    do:
      "Agents write a command and send it with mwt run; you read and approve every run, on the host."

  defp use_words(%Grant{kind: :mwt}),
    do: "Agents call MWT's tools by name; MWT carries each call out itself, on the host."

  defp use_words(%Grant{}),
    do:
      "Agents call it by id with values; MWT runs your script as you saved it, on the host, one call at a time."

  attr :grant, Grant, required: true

  # How open a fixed call is (`MWTClient.Sandbox.Openness`), so it never
  # looks narrower than it is: its grade, why, and the files it runs.
  defp openness(assigns) do
    assigns = assign(assigns, :openness, MWTClient.Sandbox.Openness.grade(assigns.grant))

    ~H"""
    <div
      :if={@openness}
      id="grant-openness"
      class={[
        "mt-3 rounded-lg border p-2.5",
        case @openness.grade do
          :open -> "border-bad/40 bg-bad-soft/30"
          :wide -> "border-warn/35 bg-warn-soft/25"
          :narrow -> "border-line-soft bg-deep/40"
        end
      ]}
    >
      <p class="flex items-center gap-1.5 text-[11px] font-semibold text-ink">
        <.icon
          name={
            if(@openness.grade == :narrow,
              do: "hero-check-circle-micro",
              else: "hero-exclamation-triangle-micro"
            )
          }
          class={[
            "size-3.5",
            case @openness.grade do
              :open -> "text-bad"
              :wide -> "text-warn"
              :narrow -> "text-ok"
            end
          ]}
        /> How open:
        <span id="grant-openness-grade">{MWTClient.Sandbox.Openness.words(@openness.grade)}</span>
      </p>
      <p class="mt-1 text-[11px] leading-4 text-muted">
        {MWTClient.Sandbox.Openness.meaning(@openness.grade)}
      </p>
      <ul :if={@openness.why != []} class="mt-1 space-y-0.5">
        <li :for={why <- @openness.why} class="text-[11px] leading-4 text-ink">{why}</li>
      </ul>
      <p
        :if={@openness.files != []}
        id="grant-openness-files"
        class="mt-1 text-[11px] leading-4 text-warn-strong"
      >
        It runs {Enum.join(@openness.files, ", ")}: it is only as narrow as that file, which can change after you saved it.
      </p>
      <p class="mt-1 text-[10px] leading-4 text-faint">
        Read from the template and its parameters' schemas: a warning, which can miss things, never a decision.
      </p>
    </div>
    """
  end

  # What a fixed call covers (docs/grant_mental_model.md, Q5): its
  # credential, or your machine and the credentials a saved command runs
  # with; a request's network is the network grants', as for the agent's.
  defp covers_words(%Grant{kind: :request} = grant),
    do:
      "It covers #{Grant.credential_id(grant)}'s value in its own request, and nothing else: no grant over the credential has a say, and the agents' own requests never carry it on its account. Its request goes out to #{SavedRequest.host(grant)} as the agents' own would: a grant over that network has to let it out (the Internet's, usually), and a lock or a blocked host refuses it."

  defp covers_words(%Grant{kind: :command, with: [_ | _] = with}),
    do:
      "It covers what it runs with, and nothing else: your machine, and the values of #{Enum.join(with, ", ")}, whatever their other grants say. A lock on any of them still refuses it."

  defp covers_words(%Grant{}),
    do: "It covers your machine for this script alone. Locking host commands still refuses it."

  defp try_path(%Grant{kind: :token} = grant),
    do: "/tools/sandbox/grants?tab=console&with=#{Grant.credential_id(grant)}"

  defp try_path(%Grant{}), do: "/tools/sandbox/grants?tab=console"

  attr :grant, Grant, required: true
  attr :grants, :list, required: true
  attr :has_value, :boolean, required: true
  attr :now, DateTime, required: true

  attr :resource_to_review, :any,
    default: nil,
    doc: "the resource it is over, `{resource, name}`, when an agent proposed that too"

  # A grant an agent proposed, waiting for you: who, why, what to look at,
  # and accepting it, which is what lets it turn on. Over a resource still
  # to review, that resource is accepted first, on its own page.
  defp review(assigns) do
    grant = assigns.grant
    proposal = grant.proposal

    assigns =
      assign(assigns,
        proposal: proposal,
        minutes: Map.get(proposal, :minutes) || 60,
        needs_value?:
          grant.kind == :token and grant.source == :stored and
            not assigns.has_value,
        hints:
          cond do
            Grant.saved_command?(grant) ->
              MWTClient.Sandbox.Param.hints(grant.params, grant.script) ++
                MWTClient.Sandbox.HostCommand.hints(grant.script, assigns.grants)

            # A mint the agent wrote runs as you, unconfined, whenever the
            # value is needed: read like a command's script. One over a
            # credential of its own was proposed with it, before credentials
            # were proposed apart; a credential proposed apart shows it on
            # its own page.
            match?({:minted, _}, grant.source) and Grant.credential_id(grant) == grant.id ->
              {:minted, command} = grant.source

              [
                "Its mint is a command the agent wrote. It runs on this machine as you, outside any bubble, each time the value is needed, with no ask."
                | MWTClient.Sandbox.HostCommand.hints(command, assigns.grants)
              ]

            true ->
              []
          end
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
          phx-value-revision={Map.get(@proposal, :revision)}
          phx-value-enable={@minutes}
          disabled={@needs_value? or @resource_to_review != nil}
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
          phx-value-revision={Map.get(@proposal, :revision)}
          phx-value-enable="keep_off"
          disabled={@resource_to_review != nil}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-accent/50 hover:bg-accent-soft/30 hover:text-accent disabled:cursor-default disabled:opacity-40"
        >
          Accept, keep disabled
        </button>
        <span
          :if={@resource_to_review}
          id="grant-review-resource-first"
          class="text-[11px] text-warn-strong"
        >
          Accept <.link
            navigate={MWTClient.Sandbox.Resource.path(elem(@resource_to_review, 0))}
            class="font-medium underline"
          >{elem(@resource_to_review, 1)}</.link>, which it is over, first.
        </span>
        <span
          :if={@needs_value? and is_nil(@resource_to_review)}
          id="grant-review-needs-value"
          class="text-[11px] text-warn-strong"
        >
          Paste its credential's value to enable it.
        </span>
        <span class="flex-1"></span>
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

  defp remove_words(%Grant{} = grant) do
    if Grant.action?(grant),
      do: "Removing it refuses calls waiting on it. Agents can no longer call it by its id.",
      else:
        "Removing it refuses anything waiting on it. Its resource stays, with its other grants."
  end

  # The setting's name, with how uses are approved only where both are
  # offered.
  defp start_label(:off, _starts), do: "Off"

  defp start_label(:on, starts),
    do: if(:auto in starts, do: "Enabled, ask", else: "Enabled")

  defp start_label(:auto, starts),
    do: if(:on in starts, do: "Enabled, auto", else: "Enabled")

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
      "Nothing to hold. While this is on, agents may call this script by id, with a value for each parameter; MWT runs it on this machine, as you or confined, outside the VM. It is for jobs that need what only this machine has, so the work goes to the value instead of the value to the VM."

  defp delivery_help(:agent_commands),
    do:
      "Nothing to hold. While this is on, agents may ask MWT to run a command they write on this machine, as you, outside the VM. Each run shows on a card with its exact text and waits for you; nothing lets one through unasked, and none is handed a credential's value."

  defp delivery_help(:mwt),
    do:
      "Nothing to hold. MWT's own tools, notes, diagrams, flash cards and HTTP samples, through the MCP server mwt mcp in the VM: MWT carries each call out itself, on this machine, so no token is in the VM."

  attr :grant, Grant, required: true
  attr :parent_name, :string, default: nil, doc: "an action's grant, by name"

  defp delivery(%{grant: %Grant{kind: :token}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-xs">
        <dt class="pt-0.5 text-muted">In the VM</dt>
        <dd class="space-y-1">
          <p id={"grant-exec-#{@grant.id}"} class="select-all font-mono text-[11px] text-ink">
            mwt exec {Grant.credential_id(@grant)} -- COMMAND
          </p>
          <p class="text-[11px] text-faint">
            That command and its children speak as the credential {Grant.credential_id(@grant)}: they get these placeholders, worthless outside MWT. It decides nothing: this grant gives its value to the hosts below, and reaching them takes a grant over their network too. Ordinary shells and editors get no credential variables.
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
              <pre
                id={"grant-mint-command-#{@grant.id}"}
                class="mt-1 overflow-x-auto whitespace-pre-wrap break-words rounded-md border border-line-soft bg-deep/50 p-2 font-mono text-[11px] text-ink"
                phx-no-format
              >{command}</pre>
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
      <.except_list grant={@grant} />
      <p id="grant-internet-off" class="text-[11px] leading-4 text-muted">
        Off, the VM reaches only the hosts other grants over the Internet name, and network
        grants' destinations; nothing else, a token grant's hosts included. Agents reach their model's API over the internet:
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
      <.except_list grant={@grant} />
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

  defp delivery(%{grant: %Grant{kind: :agent_commands}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div
        id="grant-ask-to-run"
        class="flex gap-2.5 rounded-lg border border-warn/35 bg-warn-soft/30 p-3"
      >
        <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warn" />
        <p class="text-xs leading-5 text-ink">
          The escape hatch, built in by MWT: agents write the command, and you read and approve every run. A command can do anything you can, and MWT sees nothing of it once it runs, so no setting lets one through unasked. Save the ones worth keeping as saved commands, which run only your own script. Off, agents can't ask; locking host commands stops every run.
        </p>
      </div>
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
        <dt class="flex flex-col items-start gap-1 text-muted">
          Runs <.where id="grant-delivery-where" place={:machine} />
        </dt>
        <dd class="text-[11px] text-ink">
          Whatever text the agent sends, exactly as its card shows it, as you.
        </dd>
        <dt class="text-muted">Credentials</dt>
        <dd class="text-[11px] text-ink">
          None: a command an agent writes is never handed a credential's value.
        </dd>
        <dt class="text-muted">Approval</dt>
        <dd id="grant-always-asks" class="text-[11px] text-ink">
          Every run waits for you, always. Nothing auto-approves one.
        </dd>
        <dt class="text-muted">In the VM</dt>
        <dd class="font-mono text-[11px] text-ink">mwt run --reason "…" -- COMMAND</dd>
      </dl>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :command}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
        <dt class="flex flex-col items-start gap-1 text-muted">
          Runs <.where id="grant-delivery-where" place={:machine} />
        </dt>
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
              <span id={"grant-param-schema-#{param.name}"} class="text-ink">
                · {MWTClient.Sandbox.ParamSchema.words(param.schema)}
              </span>
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
        <dd class="text-[11px] text-ink">
          Every run waits for you, unless you turned it on with Auto-approve.
        </dd>
        <dt class="text-muted">In the VM</dt>
        <dd class="font-mono text-[11px] text-ink">{Grant.signature(@grant)} --reason "…"</dd>
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
          <span id={"grant-param-schema-#{param.name}"} class="text-ink">
            · {MWTClient.Sandbox.ParamSchema.words(param.schema)}
          </span>
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

  attr :credentials, :list,
    default: [],
    doc: "the credentials you have, which a new token grant may be over"

  attr :networks, :list,
    default: [],
    doc: "the networks you have, which a new network grant may be over"

  attr :mints, :list, default: [], doc: "the firewall's credential endpoints, while it watches"

  attr :presets, :list,
    default: [],
    doc: "MWT's presets and yours (`MWTClient.Sandbox.Presets.presets/1`)"

  def add_dialog(assigns) do
    # A command an agent writes needs no grant: only saved commands are added.
    # A request action is added from its credential's page, not from here.
    types = Enum.reject(Presets.types(), &(&1.kind in [:request, :mwt, :agent_commands]))
    {access, commands} = Enum.split_with(types, &(&1.kind != :command))
    over = assigns.adding[:over]
    reviewed? = &(not match?(%{proposal: %{reviewed_at: nil}}, &1))

    # Over a credential: the grant presets for its service, or for any.
    over_credential =
      with {:credential, id} <- over,
           %{} = credential <- Enum.find(assigns.credentials, &(&1.id == id)),
           do: credential,
           else: (_ -> nil)

    assigns =
      assign(assigns,
        ask:
          Enum.find(
            assigns.waiting,
            &(&1.id == assigns.adding[:approval_id] and &1.kind == :activation)
          ),
        access: access,
        commands: commands,
        over: over,
        over_credential: over_credential,
        pickable_credentials: Enum.filter(assigns.credentials, reviewed?),
        pickable_networks:
          assigns.networks |> Enum.filter(reviewed?) |> Enum.sort_by(&(not &1.internet)),
        grant_presets:
          if(over_credential,
            do: Presets.for_credential(assigns.presets, over_credential),
            else: []
          ),
        over_name:
          over && MWTClient.Sandbox.Resource.name(over, assigns.credentials, assigns.networks),
        editing:
          assigns.adding[:editing] &&
            Enum.find(assigns.grants, &(&1.id == assigns.adding.editing)),
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
            :if={
              @adding.step in [:details, :preset] and is_nil(@editing) and
                (is_nil(@over) or @adding[:picked])
            }
            type="button"
            id="add-grant-back"
            phx-click="add_grant_back"
            title="Pick another resource"
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
                <% @adding.step in [:preset, :kind] -> %>
                  Add a grant over {@over_name}
                <% @over && @adding.preset.kind in [:command, :request] -> %>
                  Add a fixed call over {@over_name}
                <% @over -> %>
                  Add a grant over {@over_name}
                <% true -> %>
                  Add {@adding.preset.name}
              <% end %>
            </h2>
            <p class="mt-0.5 text-[11px] text-muted">
              <%= cond do %>
                <% @ask -> %>
                  {@ask.agent} asked for: {@ask.need}
                <% @adding.step == :pick -> %>
                  Pick the resource it gives a use of.
                <% @adding.step == :kind -> %>
                  What kind of grant: agents' own tools, or one call MWT makes for them? The kind decides where it runs.
                <% @adding.step == :preset -> %>
                  Start from a preset for its service, or by hand.
                <% @adding.preset.kind == :network and match?({:network, _}, @adding[:over]) -> %>
                  All of it, or only the hosts you list as its request targets.
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
          <div :if={@adding.step == :kind} id="pick-kind" class="grid gap-3 sm:grid-cols-2">
            <button
              :for={kind <- [:open, :fixed]}
              type="button"
              id={"pick-kind-#{kind}"}
              phx-click="pick_kind"
              phx-value-kind={kind}
              class="group flex cursor-pointer flex-col items-start gap-2 rounded-xl border border-line p-4 text-left transition-all hover:-translate-y-px hover:border-accent/50 hover:bg-accent-soft/15"
            >
              <span class="flex items-center gap-2">
                <span class="text-[13px] font-semibold text-ink">{kind_name(kind)}</span>
                <.where place={if(kind == :open, do: :vm, else: :machine)} />
              </span>
              <span class="text-[12px] leading-5 text-muted">{kind_words(kind)}</span>
              <span class="text-[11px] leading-4 text-faint">
                {if(kind == :open,
                  do: "For open-ended work: gh, git, any API call within its limits.",
                  else: "For one narrow, repeatable call: safe to let through without asking."
                )}
              </span>
            </button>
          </div>
          <.preset_picker
            :if={@adding.step == :preset}
            id="grant-presets"
            presets={@grant_presets}
            event="pick_preset"
            by_hand="The hosts its value may go to, and anything it narrows by: you fill them in."
          />
          <div :if={@adding.step == :pick} id="pick-resource" class="space-y-5">
            <p class="text-[11px] leading-4 text-muted">
              A grant gives a use of one resource. Pick the one it is over; a new one is added first, on its own.
            </p>
            <div>
              <p class="mb-2 flex items-center justify-between gap-2 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Credentials
                <button
                  type="button"
                  id="pick-add-credential"
                  phx-click="open_resource_form"
                  phx-value-kind="credential"
                  class="inline-flex cursor-pointer items-center gap-1 normal-case tracking-normal text-accent transition-colors hover:text-accent-strong"
                >
                  <.icon name="hero-plus-micro" class="size-3" /> Add a credential
                </button>
              </p>
              <div :if={@pickable_credentials != []} class="grid gap-2 sm:grid-cols-2">
                <.over_tile
                  :for={credential <- @pickable_credentials}
                  resource={{:credential, credential.id}}
                  icon={credential.icon || "hero-key"}
                  name={credential.name}
                  summary={MWTClientWeb.SandboxLive.ResourcePages.credential_summary(credential)}
                />
              </div>
              <p
                :if={@pickable_credentials == []}
                id="pick-no-credentials"
                class="rounded-lg border border-dashed border-line px-3 py-2.5 text-[11px] leading-4 text-muted"
              >
                None yet. Add the credential first, from a preset or by hand: a token, an API key, a GitHub App, a login a command mints.
              </p>
            </div>
            <div>
              <p class="mb-2 flex items-center justify-between gap-2 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Networks
                <button
                  type="button"
                  id="pick-add-network"
                  phx-click="open_resource_form"
                  phx-value-kind="network"
                  class="inline-flex cursor-pointer items-center gap-1 normal-case tracking-normal text-accent transition-colors hover:text-accent-strong"
                >
                  <.icon name="hero-plus-micro" class="size-3" /> Add a network
                </button>
              </p>
              <div class="grid gap-2 sm:grid-cols-2">
                <.over_tile
                  :for={network <- @pickable_networks}
                  resource={{:network, network.id}}
                  icon={if(network.internet, do: "hero-globe-alt", else: "hero-signal")}
                  name={network.name}
                  summary={MWTClientWeb.SandboxLive.ResourcePages.network_summary(network)}
                />
              </div>
            </div>
            <div>
              <p class="mb-2 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Host commands
                <.help id="command-types-help" label="About saved commands">
                  A saved command is your own script, run on this machine: agents call it by id, with a value for each of its parameters, and send no text. A command an agent writes goes under Commands agents write, built in: you approve each one.
                </.help>
              </p>
              <div id="command-type-grid" class="grid gap-2.5 sm:grid-cols-2">
                <.type_tile :for={type <- @commands} type={type} />
              </div>
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
            <.grant_fields
              adding={@adding}
              editing={@editing}
              over={@over}
              over_credential={@over_credential}
              over_name={@over_name}
              saving={@saving}
              ask={@ask}
              mints={@mints}
              grant_presets={@grant_presets}
              credentials={@credentials}
            />
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
                    "It is on from now and at every start, until you turn it off."

                  @saving ->
                    "Saved, it turns on for 1 h, and every run waits for your approval. Change either where it is listed."

                  @ask ->
                    "Saved, it turns on for #{minutes_words(@ask.minutes)}, and every run waits for your approval."

                  true ->
                    "It starts off. Turn it on for a time, asking each time or auto-approved."
                end}
              </span>
              <.help id="grant-command-help" label="How a command runs">
                Once on, agents can ask. Each run shows its exact text on a card and waits for you, unless you auto-approve it; it runs on this machine, outside the VM, confined or as you as set above. Its output goes back to the agent once you release it.
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
                  <% @ask && @adding.preset.id in [:saved_command, :request_action] -> %>
                    Save fixed call
                  <% @ask -> %>
                    Add and turn on for {minutes_words(@ask.minutes)}
                  <% @adding.preset.id in [:saved_command, :request_action] -> %>
                    Save fixed call
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

  attr :adding, :map, required: true, doc: "the form's state: `form`, `errors`, `preset`"
  attr :editing, :any, default: nil, doc: "the grant being edited, or nil for a new one"
  attr :over, :any, default: nil, doc: "the resource it is over"
  attr :over_credential, :any, default: nil
  attr :over_name, :string, default: nil
  attr :saving, :any, default: nil
  attr :ask, :any, default: nil
  attr :mints, :list, default: []
  attr :grant_presets, :list, default: []
  attr :credentials, :list, default: []

  @doc """
  A grant's fields, as its kind has them: the add dialog's and its page's
  settings are one form (`add_dialog/1`, `detail/1`).
  """
  def grant_fields(assigns) do
    ~H"""
    <input type="hidden" name="grant[kind]" value={@adding.preset.kind} />
    <input type="hidden" name="grant[preset]" value={@adding.preset.id} />
    <div
      :if={is_nil(@editing) and Map.get(@adding.preset, :fill, []) != []}
      id="preset-fill"
    >
      <div class="grid gap-3 sm:grid-cols-2">
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
    <input
      :if={match?({:credential, _}, @over) and @adding.preset.kind in [:request, :token]}
      type="hidden"
      name="grant[credential]"
      value={elem(@over, 1)}
    />
    <input
      :if={match?({:network, _}, @over)}
      type="hidden"
      name="grant[network]"
      value={elem(@over, 1)}
    />
    <details
      :if={is_nil(@editing) and @adding.preset.guide != []}
      id="preset-guide"
      class="group rounded-lg border border-line-soft"
    >
      <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-xs text-muted transition-colors hover:text-ink">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3.5 transition-transform group-open:rotate-90"
        /> How to set it up
      </summary>
      <ol class="space-y-1.5 border-t border-line-soft px-3 py-2.5">
        <li
          :for={{step, index} <- Enum.with_index(@adding.preset.guide, 1)}
          class="flex gap-2 text-xs leading-5 text-ink"
        >
          <span class="w-4 shrink-0 text-right text-faint">{index}.</span>
          <span>{step}</span>
        </li>
      </ol>
    </details>

    <.text_field
      field={@adding.form[:name]}
      label="Name"
      placeholder="Shown on switches and approvals"
      help={field_help(:name)}
      phx-mounted={is_nil(@editing) && JS.focus()}
    />
    <.field_error errors={@adding.errors} field={:name} />

    <div>
      <.text_field
        field={@adding.form[:purpose]}
        type="textarea"
        label="What it's for"
        help={field_help(if(@adding.preset.kind == :command, do: :purpose_command, else: :purpose))}
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
      <p
        :if={@over_credential && is_nil(@editing)}
        id="grant-credential-of"
        class="text-[11px] leading-4 text-muted"
      >
        Over <span class="font-medium text-ink">{@over_credential.name}</span>: its value and how tools find it are the credential's. This grant says where it may go.
      </p>

      <div>
        <.text_field
          mono
          field={@adding.form[:hosts]}
          label="Hosts it may go to"
          placeholder="api.example.com, *.example.com"
          help={field_help(:hosts)}
        />
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

      <.advanced
        id="grant-advanced"
        set={token_advanced_set(@adding.form)}
        open={Enum.any?([:attributes, :carriers, :signs_as], &Map.has_key?(@adding.errors, &1))}
      >
        <div id="grant-attributes-box">
          <label
            for="grant-attributes"
            class="mb-1.5 block text-[11px] font-medium uppercase tracking-wide text-muted"
          >
            Only these uses
          </label>
          <textarea
            id="grant-attributes"
            name="grant[attributes]"
            rows="2"
            placeholder="github.repository = owner/name"
            class="w-full rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink focus:border-accent focus:outline-none"
          >{@adding.form[:attributes].value}</textarea>
          <p class="mt-1 text-[10px] leading-4 text-faint">
            A line each: http.method, http.path, graphql.operation, git.direction, github.repository. Empty, every use of its hosts.
          </p>
          <.field_error errors={@adding.errors} field={:attributes} />
          <label class="mt-2 flex cursor-pointer items-start gap-2">
            <input type="hidden" name="grant[covers_unread]" value="false" />
            <input
              type="checkbox"
              name="grant[covers_unread]"
              id="grant-covers-unread"
              value="true"
              checked={@adding.form[:covers_unread].value not in ["false", false]}
              class="mt-0.5 size-3.5 cursor-pointer accent-accent"
            />
            <span class="text-xs text-ink">
              Covers requests MWT can't read
              <.help id="grant-covers-unread-help" label="About requests MWT can't read">
                On, a request whose attribute MWT couldn't read (a repository a GraphQL query names in its variables) counts as matching this grant when it refuses or asks: it can't be walked around. Off, such a request doesn't match it, and the other grants decide.
              </.help>
            </span>
          </label>
        </div>
        <div>
          <.text_field
            mono
            field={@adding.form[:carriers]}
            label="Headers it travels in"
            placeholder="Authorization"
            help={field_help(:carriers)}
          />
          <.field_error errors={@adding.errors} field={:carriers} />
        </div>
        <div :if={signing_offered?(@adding, @over_credential)} id="grant-signs-as-box">
          <.text_field
            mono
            field={@adding.form[:signs_as]}
            label="May sign as"
            placeholder="svc@my-project.iam.gserviceaccount.com"
            help={field_help(:signs_as)}
          />
          <.field_error errors={@adding.errors} field={:signs_as} />
        </div>
      </.advanced>
    <% end %>

    <div :if={@adding.preset.kind == :network and match?({:network, _}, @over)}>
      <.text_field
        mono
        field={@adding.form[:destinations]}
        type="textarea"
        label="Request targets"
        rows="3"
        placeholder={
          Enum.join(["Empty: all of it.", "myhost.example.com", "*.api.corp.example:443"], "\n")
        }
      />
      <p class="mt-1 text-[10px] leading-4 text-faint">
        Where agents' requests and connections may go with this grant. Empty, anywhere on {@over_name}. Or one a line: a host (myhost.example.com), every host under one (*.corp.example), an address or a range, then optionally :ports.
      </p>
      <.field_error errors={@adding.errors} field={:destinations} />
      <.except_field form={@adding.form} errors={@adding.errors} class="mt-4" />
    </div>

    <div :if={@adding.preset.kind == :network and not match?({:network, _}, @over)}>
      <.text_field
        mono
        field={@adding.form[:destinations]}
        type="textarea"
        label="Destinations"
        help={field_help(:destinations)}
        placeholder={
          Enum.join(["10.20.0.0/16:443,5432", "git.corp.internal:443", "*.corp.example:443"], "\n")
        }
      />
      <p class="mt-1 text-[10px] text-faint">
        One per line: an address, a range, a host name, or every name under one (*.corp.example), then optionally :ports. Anything after # is a note.
      </p>
      <.field_error errors={@adding.errors} field={:destinations} />
      <.except_field form={@adding.form} errors={@adding.errors} class="mt-3" />
      <div id="grant-private-network" class="mt-3">
        <.text_field
          mono
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
        open={@adding.form[:resolver].value not in [nil, ""] or @adding.errors[:resolver] != nil}
      >
        <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 transition-transform group-open:rotate-90"
          /> More
        </summary>
        <div class="border-t border-line-soft p-3">
          <.text_field
            mono
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

    <div :if={@adding.preset.id == :request_action} id="request-fields" class="space-y-3">
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
              Where MWT sends the request: https:// to a host, written out in full; reaching it also takes a grant over the network it is on. A parameter goes in the path or the query as $NAME, and MWT puts the agent's value there encoded; a word keeps its / in the path, so $REPO can be owner/name. The scheme and the host never change between calls, so the token only ever goes there.
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
      <div>
        <p class="mb-1 flex items-center gap-1">
          <label
            for="grant-headers"
            class="text-[11px] font-medium uppercase tracking-wide text-muted"
          >
            Headers
          </label>
          <.help id="grant-headers-help" label="About the headers">
            The request's HTTP headers, Name: value, one a line, the same on every call: agents can't add or change one. {SavedRequest.token_mark()} stands for the real value, where the service takes it (Authorization: Bearer {SavedRequest.token_mark()}); MWT puts it there as it sends, and the VM never sees it. Over a Google login, {"{id_token}"} stands for its ID token, and {"{signed_jwt}"} for a JWT signed as the grant's account ({"{signed_jwt:ACCOUNT}"} to name one of several), for this URL. Empty, it starts from the headers the grant's service expects.
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
          <.where id="grant-script-where" place={:machine} />
          <.help id="grant-script-help" label="About the script">
            The exact text that runs on this machine, with bash -lc, in the folder below, each time an agent calls it by its id: agents can run only this, and send no text of their own. It reads each parameter as a variable, "$NAME", always in double quotes, so a value is never read as a command. Keep it to what must run here, one command if you can; agents work on its output in the VM.
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
        <.text_field
          mono
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
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true

  # The state an action starts in, chosen as it is added.
  defp start_pick(assigns) do
    ~H"""
    <div id="grant-start-field">
      <p class="mb-1 flex items-center gap-1 text-[11px] font-medium uppercase tracking-wide text-muted">
        When MWT starts
        <.help id="grant-start-help" label="About the state it starts in">
          The state it is put in each time MWT starts. Off: it gives nothing until you, or an agent's ask you approve, turn it on for a time. Enabled, ask: on from now and at every start, until you turn it off, and every call still waits for you. Enabled, auto: the same, and every call goes through without asking, logged in Activity. Only for what you fully trust.
        </.help>
      </p>
      <.pills
        id="grant-start-pick"
        name="grant[start]"
        options={[
          {"off", "Off"},
          {"on", "Enabled, ask"},
          {"auto", "Enabled, auto"}
        ]}
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

  # What an agent chooses on each call: the call's JSON Schema. A form
  # filled from NAME: shape: what it is lines (a preset's, an agent's
  # command saved) shows the schema they make.
  defp params_field(assigns) do
    schema =
      case String.trim(to_string(assigns.form[:schema].value || "")) do
        "" ->
          case MWTClient.Sandbox.Param.parse(to_string(assigns.form[:params].value || "")) do
            {:ok, params} -> MWTClient.Sandbox.ParamSchema.text(params)
            {:error, _} -> to_string(assigns.form[:params].value || "")
          end

        text ->
          text
      end

    assigns = assign(assigns, :schema, schema)

    ~H"""
    <div id="grant-schema-box">
      <p class="mb-1 flex items-center gap-1">
        <label for="grant-schema" class="text-[11px] font-medium uppercase tracking-wide text-muted">
          Parameters
        </label>
        <.help id="grant-schema-help" label="About parameters">{schema_help(@request)}</.help>
      </p>
      <textarea
        name="grant[schema]"
        id="grant-schema"
        rows={if(@schema == "", do: "3", else: "8")}
        spellcheck="false"
        autocomplete="off"
        phx-debounce="300"
        placeholder={schema_placeholder()}
        class={[input_classes(), "font-mono text-xs"]}
      >{@schema}</textarea>
      <.field_error errors={@errors} field={:params} />
      <.params_preview
        schema={@schema}
        script={if(@request, do: nil, else: @form[:script].value)}
      />
    </div>
    """
  end

  defp schema_placeholder,
    do:
      Enum.join(
        [
          ~s({),
          ~s(  "type": "object",),
          ~s(  "properties": {),
          ~s(    "REPO": {"description": "the repository, as owner/name",),
          ~s(             "type": "string", "format": "word", "pattern": "^oliveigah/"},),
          ~s(    "COUNT": {"description": "how many", "type": "integer", "minimum": 1, "maximum": 10}),
          ~s(  }),
          ~s(})
        ],
        "\n"
      )

  defp schema_help(request?),
    do:
      "What an agent chooses on each call, as one JSON Schema: an object whose properties are the parameters, each with its description, what it is, and what its values may be: \"type\" string, integer, number or boolean, \"format\" (date, date-time, email, or MWT's word: letters, digits and _ . - @ : +, parts joined by /), \"enum\", \"pattern\", \"minimum\", \"maximum\", \"maxLength\"… Every parameter is required. Whatever the schema says, no value starts with - (but a number), goes up a folder, or hides characters. A call whose values don't keep to it is refused before anything runs, and the agent is told why. Leave it empty for a call that is always the same. " <>
        if(request?,
          do:
            "The request puts each where you wrote $NAME, encoded: a value can't change the host, the headers or the shape of the body.",
          else:
            "The script reads each as a variable, \"$NAME\", and never changes: a value can't add a command."
        )

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
          <.text_field
            mono
            field={@form[:with]}
            label="With the real values of"
            placeholder="github, stripe"
            help={field_help(:with)}
            hint="Credentials, by id, comma separated. Each needs an open-use grant over it that allows your machine, on when the script runs."
          />
          <.field_error errors={@errors} field={:with} />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true

  # Where the firewall refuses this grant's value: a credential endpoint
  # among its hosts, or the URL an action sends to.
  defp mint_hint(assigns) do
    ~H"""
    <p
      :if={@entries != []}
      id={@id}
      class="mt-1 flex items-center gap-1.5 text-[11px] leading-4 text-muted"
    >
      <.icon name="hero-key-micro" class="size-3.5 shrink-0 text-warn" />
      <span>MWT keeps this value away from the credential endpoints here.</span>
      <.help id={"#{@id}-help"} label="About credential endpoints">
        A credential endpoint is here ({Enum.join(@entries, ", ")}): MWT refuses this value there, so it can't mint another credential. The Firewall page's list says which.
      </.help>
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

  attr :schema, :any, default: nil
  attr :script, :any, default: nil

  # The parameters as MWT reads them while you type: how a call will look,
  # and what deserves a second look in how the script reads them.
  defp params_preview(assigns) do
    script = to_string(assigns.script || "")

    {params, problems} =
      case MWTClient.Sandbox.ParamSchema.parse(assigns.schema) do
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
          {param.name}=<span class="text-muted">{MWTClient.Sandbox.ParamSchema.words(param.schema)}</span>
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

  attr :resource, :any, required: true
  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :summary, :string, required: true

  # A resource to add a grant over.
  defp over_tile(assigns) do
    ~H"""
    <button
      type="button"
      id={"pick-over-#{MWTClientWeb.SandboxLive.ResourcePages.dom_id(@resource)}"}
      phx-click="pick_over"
      phx-value-kind={elem(@resource, 0)}
      phx-value-id={elem(@resource, 1)}
      class="group flex cursor-pointer items-center gap-2.5 rounded-lg border border-line-soft px-3 py-2 text-left transition-all hover:-translate-y-px hover:border-accent/50 hover:bg-accent-soft/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
    >
      <.icon
        name={@icon}
        class="size-4 shrink-0 text-muted transition-colors group-hover:text-accent"
      />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-xs font-medium text-ink">{@name}</span>
        <span class="block truncate text-[10px] text-faint">{@summary}</span>
      </span>
      <.icon
        name="hero-chevron-right-micro"
        class="size-3.5 shrink-0 text-faint transition-colors group-hover:text-accent"
      />
    </button>
    """
  end

  attr :type, :map, required: true
  attr :taken, :any, default: nil, doc: "the grant that makes a second of this type pointless"

  # A grant type to pick; one that is taken links to the grant instead.
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
          MWT's own, listed with your grants. While it is on, agents may ask; you approve every run.
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

  # What a token grant's Advanced holds that is set, in a few words each,
  # for its summary: nothing set there stays out of sight.
  defp token_advanced_set(form) do
    text = &(form[&1].value |> to_string() |> String.trim())

    [
      text.(:attributes) != "" &&
        "only " <> (text.(:attributes) |> String.split("\n") |> Enum.join("; ")),
      form[:covers_unread].value in ["false", false] && "skips what MWT can't read",
      text.(:carriers) != "" && "in " <> text.(:carriers),
      text.(:signs_as) != "" && "signs as " <> text.(:signs_as)
    ]
    |> Enum.filter(& &1)
  end

  # Signing a JWT as a service account is Google's IAM Credentials: the
  # same hosts, a Google credential, or a grant that already signs.
  defp signing_offered?(adding, over_credential),
    do:
      adding.form[:signs_as].value not in [nil, ""] or google_hosts?(adding.form) or
        match?(%{adapter: :google}, over_credential)

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

  attr :grant, Grant, required: true

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
      "What the script does, in words for any time it runs, such as Lists the pods of a namespace in the staging cluster; not why one agent needs it now. Agents read it in mwt grants to pick the call to make, and the search here finds it by these words. It allows nothing by itself: the script decides what runs.",
    hosts:
      "The hosts the real value may be sent to, comma separated: api.example.com for that host only, *.example.com for it and every name under it. MWT swaps the placeholder for the real value only in HTTPS requests to these hosts; a placeholder sent anywhere else is refused, and the firewall may isolate the VM for it. MWT reads the requests to these hosts, instead of passing them through, to find the placeholder. Reaching them is a network grant's to give: the Internet's, for public hosts.",
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
      "The HTTP method MWT sends, the same on every call. GET reads; POST, PUT, PATCH and DELETE change something. Keep reading and changing in separate fixed calls: one that only reads is easy to trust for good.",
    dir:
      "The folder on this machine the script runs in, as its working directory; ~ is your home folder, and it must exist. A path in a shared folder is the same here and in the VM. Confined, the script reads it, and writes in it only if you allow it below.",
    confined:
      "Runs it in a bubble on this machine (bwrap): an empty home, your tools and the system read-only, its folder read-only unless you allow writing, nothing of your SSH keys, cloud logins or browser profiles in reach, and only the real values of the credentials you name below. Not confined, it runs as you, with everything you can reach: needed for tools that use your own login, such as kubectl with your kubeconfig or gh with your keyring.",
    writes_dir:
      "Lets the confined script change files in its folder; otherwise it can only read them. Nothing else on this machine is writable from the bubble but a scratch folder of its own.",
    with:
      "Credentials, by id, comma separated, whose real values the confined script gets: in the same variables the VM sees their placeholders in, and in their token files. For a script that calls an API itself. Each run needs, for each, a token grant over it that is on and allows your machine, and asks if any of those asks. Only a confined command takes them, and never a credential minted per host."
  }

  # What a field's value means and what it is used for, behind its ?.
  defp field_help(field), do: Map.fetch!(@field_help, field)

  defp minutes_words(60), do: "1 h"
  defp minutes_words(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes_words(minutes), do: "#{minutes} min"

  attr :form, :any, required: true
  attr :errors, :map, default: %{}
  attr :class, :string, default: nil

  attr :id, :string,
    default: "grant-except",
    doc: "its ids' start: the add dialog's and a grant page's may show at once"

  @doc """
  The hosts a network grant leaves out (`Grant.except`): what it covers
  but these, for another grant over them to give on its own terms.
  """
  def except_field(assigns) do
    assigns = assign(assigns, :field, %{assigns.form[:except] | id: assigns.id})

    ~H"""
    <div id={"#{@id}-box"} class={@class}>
      <.text_field
        mono
        field={@field}
        type="textarea"
        label="Except these hosts"
        rows="2"
        placeholder={Enum.join(["paste.example.com", "*.tracker.example"], "\n")}
      />
      <p class="mt-1 text-[10px] leading-4 text-faint">
        One a line: a host, and every name under it. This grant doesn't cover them, so another grant over them decides: one that asks makes them ask, even while this lets everything else through. With none on, they are refused.
      </p>
      <.field_error errors={@errors} field={:except} />
    </div>
    """
  end

  attr :grant, Grant, required: true

  # The hosts a network grant leaves out, as its page lists them.
  defp except_list(assigns) do
    ~H"""
    <div :if={@grant.except != []} id="grant-except-list" class="space-y-1">
      <p class="text-[11px] text-muted">
        Except, left to grants over them (refused while none is on):
      </p>
      <ul class="flex flex-wrap gap-1.5">
        <li
          :for={entry <- @grant.except}
          class="rounded-md border border-bad/30 bg-bad-soft/10 px-2 py-0.5 font-mono text-[11px] text-ink"
        >
          {entry}
        </li>
      </ul>
    </div>
    """
  end

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

  defp exposure_words(%{kind: kind}) when kind in [:command, :agent_commands],
    do: "Their text, run each time you approve"
end
