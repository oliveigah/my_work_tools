defmodule MWTClientWeb.SandboxLive.ResourcePages do
  @moduledoc """
  Resources on the Grants page (`MWTClient.Sandbox.Resource`): the
  Resources tab, every resource with its lock and the grants over it; one
  resource's page, with what it is, its lock, a network's host limits, the
  grants over it and its actions; and the dialog that adds or edits a
  credential or a network.

  A resource is what a grant gives a use of. It holds what it is and your
  limits on it: a lock, and for a network, the hosts the VM may never
  reach there. Grants give; resources limit.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Credential, Grant, HostLimits, Network, Resource}
  alias MWTClientWeb.SandboxLive.Grants

  ## The Resources tab

  @per_page 10
  @resource_kinds [
    {"all", "All"},
    {"credential", "Credentials"},
    {"network", "Networks"},
    {"other", "Others"}
  ]
  @resource_states [
    {"all", "Open or locked"},
    {"open", "Open"},
    {"locked", "Locked"},
    {"review", "To review"},
    {"unused", "No grant"}
  ]

  @doc "The filters the Resources tab starts with: every resource."
  def resource_filters, do: %{kind: "all", state: "all", term: ""}

  @doc "Filters from the form's params, anything unknown left at its default."
  def resource_filters(params) do
    pick = fn key, options ->
      value = params[Atom.to_string(key)]
      if Enum.any?(options, &(elem(&1, 0) == value)), do: value, else: "all"
    end

    %{
      kind: pick.(:kind, @resource_kinds),
      state: pick.(:state, @resource_states),
      term: params["term"] |> to_string() |> String.slice(0, 200)
    }
  end

  attr :grants, :list, required: true
  attr :credentials, :list, required: true
  attr :networks, :list, required: true
  attr :locks, :map, required: true
  attr :now, DateTime, required: true
  attr :filters, :map, default: %{kind: "all", state: "all", term: ""}
  attr :page, :integer, default: 1

  @doc """
  Every resource in one list, a page at a time: each credential, each
  network (the Internet first), your machine and MWT's tools, with what it
  is, how many grants are over it and how many are on, its last use, and
  its lock; found by kind, state and words.
  """
  def list(assigns) do
    entries = resource_entries(assigns)
    found = Enum.filter(entries, &matches?(&1, assigns.filters))
    {shown, page, pages} = paged(found, assigns.page, @per_page)

    unkinded = Enum.filter(entries, &matches?(&1, %{assigns.filters | kind: "all"}))

    kinds =
      for {value, label} <- @resource_kinds,
          do: {value, label, Enum.count(unkinded, &(value == "all" or &1.kind == value))}

    assigns =
      assign(assigns,
        found: found,
        shown: shown,
        page: page,
        pages: pages,
        per_page: @per_page,
        kinds: kinds,
        states: @resource_states,
        filtered?: assigns.filters != resource_filters()
      )

    ~H"""
    <section id="resources-list" aria-label="Resources">
      <form
        id="resource-filters"
        phx-change="filter_resources"
        phx-submit="filter_resources"
        class="mb-3 flex flex-wrap items-center gap-2"
        autocomplete="off"
      >
        <div
          id="resource-kind"
          role="radiogroup"
          aria-label="Kind"
          class="flex items-center rounded-lg border border-line bg-deep p-0.5"
        >
          <label
            :for={{value, label, count} <- @kinds}
            id={"resource-kind-#{value}"}
            class={[
              "flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1 text-[12px] transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
              if(@filters.kind == value,
                do: "bg-panel font-medium text-ink shadow-sm",
                else: "text-muted hover:text-ink"
              )
            ]}
          >
            <input
              type="radio"
              name="kind"
              value={value}
              checked={@filters.kind == value}
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
            id="resource-search-term"
            value={@filters.term}
            placeholder="Search: name, service, hosts…"
            phx-debounce="120"
            class="w-full rounded-lg border border-line bg-panel py-1.5 pl-8 pr-2 text-[12px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
          />
        </div>
        <select
          name="state"
          id="resource-state"
          aria-label="State"
          class={[
            "rounded-lg border bg-panel px-2 py-1.5 text-[12px] focus:border-accent focus:outline-none",
            if(@filters.state == "all",
              do: "border-line text-muted",
              else: "border-accent/50 text-ink"
            )
          ]}
        >
          <option :for={{value, label} <- @states} value={value} selected={@filters.state == value}>
            {label}
          </option>
        </select>
        <button
          :if={@filtered?}
          type="button"
          id="resource-filters-clear"
          phx-click="clear_resource_filters"
          class="inline-flex cursor-pointer items-center gap-1 text-[11px] font-medium text-accent hover:underline"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" /> Clear
        </button>
        <span class="flex-1"></span>
        <.button
          id="add-credential"
          type="button"
          phx-click="open_resource_form"
          phx-value-kind="credential"
        >
          <.icon name="hero-plus-micro" class="size-3.5" /> Add credential
        </.button>
        <.button
          id="add-network"
          type="button"
          phx-click="open_resource_form"
          phx-value-kind="network"
        >
          <.icon name="hero-plus-micro" class="size-3.5" /> Add network
        </.button>
      </form>

      <div :if={@found != []} class="overflow-hidden rounded-xl border border-line bg-panel">
        <ul id="resources-rows" class="divide-y divide-line-soft">
          <.resource_row
            :for={entry <- @shown}
            resource={entry.resource}
            name={entry.name}
            summary={entry.summary}
            built_in={entry.built_in}
            to_review={entry.to_review}
            grants={@grants}
            locks={@locks}
            now={@now}
          />
        </ul>
      </div>
      <.pages
        :if={@pages > 1}
        name="resources"
        label="Pages of resources"
        page={@page}
        pages={@pages}
        per_page={@per_page}
        total={length(@found)}
        event="resources_page"
        class="mt-3"
      />
      <div
        :if={@found == []}
        id="resources-credentials-empty"
        class="rounded-xl border border-dashed border-line"
      >
        <.empty icon="hero-key">
          {if(@filtered?, do: "Nothing matches these filters.", else: "No resource yet.")}
        </.empty>
      </div>
    </section>
    """
  end

  # Every resource as the list shows it, with what it is filtered by.
  defp resource_entries(assigns) do
    credentials =
      for credential <- assigns.credentials,
          do: %{
            resource: {:credential, credential.id},
            kind: "credential",
            name: credential.name,
            summary: credential_summary(credential),
            built_in: false,
            to_review: to_review?(credential),
            words:
              "#{credential.name} #{credential.id} #{credential.purpose} #{credential.adapter}"
          }

    networks =
      for network <- Enum.sort_by(assigns.networks, &(not &1.internet)),
          do: %{
            resource: {:network, network.id},
            kind: "network",
            name: network.name,
            summary: network_summary(network),
            built_in: network.internet,
            to_review: to_review?(network),
            words:
              "#{network.name} #{network.id} #{network.purpose} #{Enum.join(network.destinations, " ")}"
          }

    others = [
      %{
        resource: :machine,
        kind: "other",
        name: "Host commands",
        summary: "Code run on your machine: your saved commands, and the commands agents write",
        built_in: true,
        to_review: false,
        words: "host commands your machine saved commands agents write run"
      },
      %{
        resource: :mwt,
        kind: "other",
        name: "MWT's tools",
        summary:
          "Notes, diagrams and flash cards through mwt mcp; the projects' git, the shared folders and the workspace",
        built_in: true,
        to_review: false,
        words:
          "mwt tools notes diagrams flash cards mcp git shared folders workspace sync handoff"
      }
    ]

    for entry <- credentials ++ networks ++ others do
      over = Resource.grants(assigns.grants, entry.resource)

      Map.merge(entry, %{
        locked: Map.has_key?(assigns.locks, entry.resource),
        grant_count: length(over)
      })
    end
  end

  defp matches?(entry, filters) do
    words = filters.term |> String.downcase() |> String.split(~r/\s+/, trim: true)
    text = String.downcase(entry.words)

    (filters.kind == "all" or entry.kind == filters.kind) and
      case filters.state do
        "open" -> not entry.locked
        "locked" -> entry.locked
        "review" -> entry.to_review
        "unused" -> entry.grant_count == 0
        _all -> true
      end and Enum.all?(words, &String.contains?(text, &1))
  end

  attr :resource, :any, required: true
  attr :name, :string, required: true
  attr :summary, :string, required: true
  attr :built_in, :boolean, default: false
  attr :to_review, :boolean, default: false, doc: "an agent proposed it, not accepted yet"
  attr :grants, :list, required: true
  attr :locks, :map, required: true
  attr :now, DateTime, required: true

  # One resource: what it is, how many grants are over it and how many of
  # them are on, and its lock.
  defp resource_row(assigns) do
    over = Resource.grants(assigns.grants, assigns.resource)

    assigns =
      assign(assigns,
        usage: usage(over, assigns.now),
        dom: dom_id(assigns.resource)
      )

    ~H"""
    <li id={"resource-#{@dom}"} class="flex items-center gap-3 px-4 py-3">
      <span class={[
        "flex size-8 shrink-0 items-center justify-center rounded-lg",
        resource_tone(@resource)
      ]}>
        <.icon name={resource_icon(@resource)} class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <p class="flex items-center gap-1.5">
          <.link
            navigate={Resource.path(@resource)}
            id={"resource-link-#{@dom}"}
            class="truncate text-[13px] font-semibold text-ink transition-colors hover:text-accent"
          >
            {@name}
          </.link>
          <.badge :if={@built_in}>Built in</.badge>
          <.badge :if={@to_review} id={"resource-to-review-#{@dom}"} tone={:warn}>
            Proposed · to review
          </.badge>
        </p>
        <p class="truncate text-[11px] text-faint" title={@summary}>{@summary}</p>
      </div>
      <span
        id={"resource-grants-#{@dom}"}
        class={[
          "hidden w-28 shrink-0 text-right text-[11px] sm:inline",
          if(@usage.on > 0, do: "font-medium text-ok-strong", else: "text-faint")
        ]}
      >
        {grants_count(@usage.count, @usage.on)}
      </span>
      <span
        id={"resource-used-#{@dom}"}
        class="hidden w-28 shrink-0 text-right text-[11px] text-faint md:inline"
      >
        <%= if @usage.last_used do %>
          Used <.clock id={"resource-used-at-#{@dom}"} since={@usage.last_used} now={@now} />
        <% else %>
          Never used
        <% end %>
      </span>
      <.lock_switch resource={@resource} locks={@locks} name={@name} />
    </li>
    """
  end

  defp grants_count(0, _on), do: "No grant"
  defp grants_count(1, 1), do: "1 grant, on"
  defp grants_count(1, 0), do: "1 grant, off"
  defp grants_count(n, on), do: "#{n} grants, #{on} on"

  ## One resource's page

  attr :resource, :any, required: true, doc: "the resource, or nil when there is none"
  attr :grants, :list, required: true
  attr :credentials, :list, required: true
  attr :networks, :list, required: true
  attr :locks, :map, required: true
  attr :credential_values, :map, default: %{}, doc: "whether each credential has a value, by id"
  attr :value_form, :any, required: true
  attr :durations, :map, required: true
  attr :modes, :map, required: true
  attr :now, DateTime, required: true

  attr :settings, :map,
    default: nil,
    doc: "its settings' form: `form`, `errors`, `dirty` (`resource_settings_*` events)"

  @doc """
  A resource's page: what it is and its lock in its head; **Now**, whether
  it can be used (a credential's value) and the grants and actions over
  it, each with its switch; a network's host limits; **Settings**, what it
  is, edited in place and kept once saved.
  """
  def page(assigns) do
    resource = assigns.resource

    found =
      case resource do
        {:credential, id} -> Enum.find(assigns.credentials, &(&1.id == id))
        {:network, id} -> Enum.find(assigns.networks, &(&1.id == id))
        :machine -> :machine
        :mwt -> :mwt
        nil -> nil
      end

    over = if found, do: Resource.grants(assigns.grants, resource), else: []

    assigns =
      assign(assigns,
        found: found,
        name: found && Resource.name(resource, assigns.credentials, assigns.networks),
        over_grants: Enum.sort_by(over, &{not Grant.on?(&1, assigns.now), &1.name}),
        usage: usage(over, assigns.now),
        dom: resource && dom_id(resource),
        built_in?: built_in?(found)
      )

    ~H"""
    <div
      :if={is_nil(@found)}
      id="resource-missing"
      class="rounded-xl border border-dashed border-line"
    >
      <.empty icon="hero-cube-transparent">
        That resource doesn't exist any more.
        <.link
          patch={~p"/tools/sandbox/grants?tab=resources"}
          class="text-accent hover:underline"
        >See all resources</.link>
      </.empty>
    </div>

    <div :if={@found} id={"resource-page-#{@dom}"}>
      <.link
        patch={~p"/tools/sandbox/grants?tab=resources"}
        id="resource-back"
        class="mb-3 inline-flex items-center gap-1 text-xs text-muted transition-colors hover:text-accent"
      >
        <.icon name="hero-arrow-left-micro" class="size-3.5" /> Resources
      </.link>

      <header id="resource-header" class="mb-5 flex flex-wrap items-start gap-3">
        <span class={[
          "flex size-11 shrink-0 items-center justify-center rounded-xl",
          resource_tone(@resource)
        ]}>
          <.icon name={resource_icon(@resource)} class="size-5" />
        </span>
        <div class="min-w-0 flex-1 basis-80">
          <div class="flex flex-wrap items-center gap-2">
            <h1 id="resource-name" class="text-xl font-semibold tracking-tight text-ink">
              {@name}
            </h1>
            <.badge :if={Resource.kind_words(@resource) != @name}>
              {Resource.kind_words(@resource)}
            </.badge>
            <.badge :if={match?(%Credential{}, @found)}>{adapter_name(@found)}</.badge>
            <.badge :if={@built_in?}>Built in</.badge>
          </div>
          <p :if={purpose(@found) != ""} class="mt-1 max-w-3xl text-[13px] leading-5 text-muted">
            {purpose(@found)}
          </p>
        </div>
        <.lock_switch resource={@resource} locks={@locks} name={@name} />
      </header>

      <div
        :if={to_review?(@found)}
        id="resource-review"
        class="mb-5 rounded-xl border border-warn/45 bg-warn-soft/25 p-4"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-sparkles" class="mt-0.5 size-4 shrink-0 text-warn" />
          <div class="min-w-0 flex-1 space-y-1">
            <p class="text-[13px] font-medium text-ink">
              {@found.proposal.agent} proposed this {kind_word(@resource)}. Nothing over it can be accepted or turned on until you accept it.
            </p>
            <p class="break-words text-xs text-muted">
              <span class="text-faint">Why:</span> {@found.proposal.reason}
            </p>
            <p
              :if={match?(%Credential{source: :stored}, @found)}
              id="resource-review-value"
              class="text-xs text-muted"
            >
              Its value is yours to paste, now or later: until you do, every use of it is refused.
            </p>
            <div :if={match?(%Credential{source: {:minted, _}}, @found)} class="space-y-1">
              <p class="flex items-center gap-1.5 text-xs text-muted">
                Its value is minted by this command, which the agent wrote:
                <.where place={:machine} />
              </p>
              <pre
                id="resource-review-mint"
                class="overflow-x-auto rounded-md border border-line-soft bg-deep/60 px-2.5 py-1.5 font-mono text-[11px] text-ink"
              >{elem(@found.source, 1)}</pre>
              <ul id="resource-review-hints" class="space-y-1">
                <li
                  :for={hint <- mint_hints(@found, @grants)}
                  class="flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
                >
                  <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
                  <span>{hint}</span>
                </li>
              </ul>
            </div>
          </div>
        </div>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <.button
            id="resource-accept"
            variant="primary"
            phx-click="accept_resource"
            phx-value-kind={elem(@resource, 0)}
            phx-value-id={elem(@resource, 1)}
            phx-value-revision={@found.proposal.revision}
          >
            <.icon name="hero-check-micro" class="size-3.5" /> Accept
          </.button>
          <.button
            id="resource-decline"
            variant="danger"
            phx-click="decline_resource"
            phx-value-kind={elem(@resource, 0)}
            phx-value-id={elem(@resource, 1)}
          >
            Decline
          </.button>
          <span class="text-[11px] text-muted">
            Declining removes it, with what was proposed over it.
          </span>
        </div>
      </div>

      <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_21rem]">
        <div class="min-w-0 space-y-5">
          <section
            id="resource-now"
            class="overflow-hidden rounded-xl border border-line bg-panel shadow-sm"
          >
            <header class="flex flex-wrap items-center gap-3 border-b border-line-soft px-5 py-3.5">
              <div class="min-w-0 flex-1">
                <h2 class="flex items-center gap-1.5 text-[14px] font-semibold text-ink">
                  Grants over it
                  <.help id="resource-grants-help" label="About the grants over it">
                    Each gives uses of this resource while it is on. Open use: the agent builds the request or command. Fixed call: MWT builds it from your template and the agent's values. Of those that cover a use, the most permissive counts.
                  </.help>
                </h2>
                <p class="mt-0.5 text-[12px] text-muted">{grants_subtitle(@resource)}</p>
              </div>
              <.button
                :if={add_grant_preset(@resource)}
                id="add-grant-over"
                phx-click="open_add_grant"
                phx-value-preset={add_grant_preset(@resource)}
                phx-value-over={over_value(@resource)}
              >
                <.icon name="hero-plus-micro" class="size-3.5" /> Add grant
              </.button>
            </header>
            <ul :if={@over_grants != []} id="resource-grants" class="divide-y divide-line-soft">
              <Grants.grant_row
                :for={grant <- @over_grants}
                prefix="resource"
                grant={grant}
                duration={Grants.row_duration(grant, @durations, @now)}
                mode={Grants.row_mode(grant, @modes, @now)}
                now={@now}
              />
            </ul>
            <p
              :if={@over_grants == []}
              id="resource-grants-empty"
              class="px-5 py-5 text-[12px] text-muted"
            >
              {no_grants_words(@resource)}
            </p>
          </section>

          <.limits_card :if={match?(%Network{}, @found)} network={@found} />

          <.form
            :if={@settings && not @built_in?}
            for={@settings.form}
            id="resource-settings-form"
            phx-change="resource_settings_change"
            phx-submit="resource_settings_save"
            class="rounded-xl border border-line bg-panel shadow-sm"
          >
            <header id="resource-settings" class="border-b border-line-soft px-5 py-3.5">
              <h2 class="text-[14px] font-semibold text-ink">Settings</h2>
              <p class="mt-0.5 text-[12px] text-muted">
                What it is. Every grant over it follows; changes are kept once you save them.
              </p>
            </header>
            <div class="space-y-5 px-5 py-5">
              <.text_field field={@settings.form[:name]} label="Name" />
              <.field_error errors={@settings.errors} field={:name} />
              <.text_field
                field={@settings.form[:purpose]}
                type="textarea"
                label="What it is"
                rows="2"
              />
              <.field_error errors={@settings.errors} field={:purpose} />
              <%= if match?(%Credential{}, @found) do %>
                <.credential_fields
                  form={@settings.form}
                  errors={@settings.errors}
                  editing={@found.id}
                  settings?={true}
                  has_value={has_value?(@found, @credential_values)}
                />
              <% else %>
                <.network_fields form={@settings.form} errors={@settings.errors} />
              <% end %>
            </div>
            <footer
              id="resource-settings-bar"
              class="sticky bottom-0 flex items-center justify-end gap-2 rounded-b-xl border-t border-line-soft bg-panel/95 px-5 py-3 backdrop-blur"
            >
              <.button
                :if={not @built_in?}
                type="button"
                id="delete-resource"
                variant="danger"
                title="Every grant over it goes with it, and anything waiting on them is refused."
                phx-click="confirm_delete_resource"
                phx-value-kind={elem(@resource, 0)}
                phx-value-id={elem(@resource, 1)}
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
                id="resource-settings-cancel"
                phx-click="resource_settings_cancel"
              >
                Cancel
              </.button>
              <.button
                type="submit"
                id="resource-settings-save"
                variant="primary"
                disabled={not @settings.dirty}
              >
                Save
              </.button>
            </footer>
          </.form>
        </div>

        <aside class="space-y-4 lg:sticky lg:top-4">
          <section
            :if={match?(%Credential{}, @found)}
            id="resource-value"
            class="rounded-xl border border-line bg-panel p-4 shadow-sm"
          >
            <p class="text-[12px] font-semibold text-ink">Its value</p>
            <.value_line
              found={@found}
              has_value={has_value?(@found, @credential_values)}
              value_form={@value_form}
            />
          </section>

          <section id="resource-use" class="rounded-xl border border-line bg-panel p-4 shadow-sm">
            <p class="text-[12px] font-semibold text-ink">Use</p>
            <dl class="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-[12px]">
              <dt class="text-muted">Grants</dt>
              <dd id="resource-use-grants" class={["text-ink", @usage.on > 0 && "text-ok-strong"]}>
                {grants_count(@usage.count, @usage.on)}
              </dd>
              <dt class="text-muted">Last used</dt>
              <dd id="resource-use-last" class="text-ink">
                <%= if @usage.last_used do %>
                  <.clock id="resource-last-used" since={@usage.last_used} now={@now} />
                <% else %>
                  never
                <% end %>
              </dd>
              <dt class="text-muted">Lock</dt>
              <dd class="text-ink">
                {if(Map.has_key?(@locks, @resource), do: "locked: every use refused", else: "open")}
              </dd>
            </dl>
            <.link
              :if={match?(%Credential{}, @found) or match?(%Network{}, @found)}
              navigate={try_path(@resource)}
              id="resource-try"
              class="mt-3 inline-flex items-center gap-1 text-[12px] font-medium text-accent hover:underline"
            >
              <.icon name="hero-command-line-micro" class="size-3.5" /> Try it as the VM
            </.link>
          </section>

          <section id="resource-what" class="rounded-xl border border-line bg-panel p-4 shadow-sm">
            <p class="text-[12px] font-semibold text-ink">
              {if(match?(%Credential{}, @found), do: "In the VM", else: "What it is")}
            </p>
            <div class="mt-2">
              <.what_it_is found={@found} has_value={false} value_form={@value_form} />
            </div>
          </section>
        </aside>
      </div>
    </div>
    """
  end

  # How a resource is used: its grants, how many are on, and the last use
  # of any of them.
  defp usage(grants, now) do
    %{
      count: length(grants),
      on: Enum.count(grants, &Grant.on?(&1, now)),
      last_used:
        grants
        |> Enum.map(& &1.last_used_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)
    }
  end

  defp adapter_name(%Credential{adapter: adapter}) do
    case MWTClient.Sandbox.Adapter.find(adapter) do
      {:ok, found} -> found.name()
      :error -> to_string(adapter)
    end
  end

  attr :found, Credential, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true

  # Where a credential's value comes from, and for a pasted one, pasting it.
  defp value_line(assigns) do
    ~H"""
    <div id="credential-source" class="mt-1.5 text-[12px] text-ink">
      <%= case @found.source do %>
        <% {:minted, command} -> %>
          <p class="flex flex-wrap items-center gap-1.5">
            Minted when needed by a command <.where place={:machine} />
          </p>
          <code class="mt-1.5 block break-all rounded-md bg-deep/60 px-2 py-1.5 font-mono text-[11px]">
            {command}
          </code>
        <% _stored -> %>
          <p :if={@has_value} class="text-ok-strong">Stored in your vault</p>
          <p :if={not @has_value} class="text-warn-strong">
            No value yet: every use is refused until you paste it.
          </p>
      <% end %>
    </div>
    <.form
      :if={@found.source == :stored}
      for={@value_form}
      id="credential-value-form"
      phx-submit="set_credential_value"
      class="mt-2.5 flex items-center gap-2"
    >
      <input type="hidden" name="value[credential]" value={@found.id} />
      <input
        type="password"
        name="value[value]"
        id="credential-value"
        autocomplete="off"
        placeholder={if(@has_value, do: "Replace the value", else: "Paste the value")}
        class="min-w-0 flex-1 rounded-lg border border-line-soft bg-deep/40 px-3 py-1.5 font-mono text-xs text-ink focus:border-accent/60 focus:outline-none focus:ring-2 focus:ring-accent/15"
      />
      <.button id="credential-value-save" type="submit">Save</.button>
    </.form>
    """
  end

  # The console, set to speak as the credential.
  defp try_path({:credential, id}), do: "/tools/sandbox/grants?tab=console&with=#{id}"
  defp try_path(_resource), do: "/tools/sandbox/grants?tab=console"

  attr :found, :any, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true

  defp what_it_is(%{found: %Credential{}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-[12px]">
      <dt class="text-muted">Command</dt>
      <dd class="select-all font-mono text-[11px] text-ink">mwt exec {@found.id} -- COMMAND</dd>
      <dt :if={@found.env != []} class="text-muted">Variables</dt>
      <dd :if={@found.env != []} class="font-mono text-[11px] text-ink">
        {Enum.join(@found.env, ", ")}
      </dd>
      <dt :if={@found.file_env != []} class="text-muted">File variables</dt>
      <dd :if={@found.file_env != []} class="font-mono text-[11px] text-ink">
        {Enum.join(@found.file_env, ", ")}
      </dd>
      <dt :if={@found.git} class="text-muted">Git</dt>
      <dd :if={@found.git} class="text-ink">over HTTPS, from MWT's helper</dd>
    </dl>
    <p class="mt-2 text-[11px] leading-4 text-faint">
      Only that command and its children get placeholders, worthless outside MWT.
    </p>
    """
  end

  defp what_it_is(%{found: %Network{internet: true}} = assigns) do
    ~H"""
    <p class="text-xs leading-5 text-muted">
      Every public address. Private and reserved addresses are networks of their own.
    </p>
    """
  end

  defp what_it_is(%{found: %Network{}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-x-3 gap-y-2.5 text-xs">
      <dt class="text-muted">Destinations</dt>
      <dd id="network-destinations" class="space-y-0.5 font-mono text-[11px] text-ink">
        <p :for={destination <- @found.destinations}>{destination}</p>
      </dd>
      <dt class="text-muted">DNS server</dt>
      <dd class="text-ink">{@found.resolver || "This machine's own"}</dd>
      <dt class="text-muted">Interface</dt>
      <dd class="text-ink">{@found.anchor || "Wherever this machine routes it"}</dd>
    </dl>
    """
  end

  defp what_it_is(%{found: :machine} = assigns) do
    ~H"""
    <p class="text-xs leading-5 text-muted">
      Code run on this machine for agents: your saved commands, and the commands agents write, which you approve one by one. Locked, nothing an agent asks runs here; the VM, git, the shared folders and the workspace go on: they are MWT's tools.
    </p>
    """
  end

  defp what_it_is(%{found: :mwt} = assigns) do
    ~H"""
    <p class="text-xs leading-5 text-muted">
      What MWT does for agents with its own code: your notes, diagrams and flash cards through mwt mcp; the projects' git, the shared folders' sync and the workspace.
    </p>
    """
  end

  attr :network, Network, required: true

  # A network's limits, set as What MWT reads is: what a host on neither
  # list gets, then the two lists. A host is on one list at most.
  defp limits_card(assigns) do
    {blocked, reachable} = HostLimits.lists(assigns.network.limits)
    assigns = assign(assigns, blocked: blocked, reachable: reachable)

    ~H"""
    <.card
      id="resource-limits"
      title="Hosts"
      subtitle="Hosts the VM may never reach on this network, whatever any grant says."
    >
      <:help>
        A limit only takes away: a host it leaves reachable still needs a grant that is on. The most exact entry decides: api.example.com before example.com, which covers every name under it. Reachable entries matter when hosts on neither list are blocked, or under a blocked domain. A host is judged by the name it is for: MWT holds a connection until its first bytes say it.
      </:help>
      <div class="flex flex-wrap items-center gap-3 rounded-lg border border-line bg-deep/40 px-3 py-2.5">
        <div class="min-w-0 flex-1">
          <p class="text-xs font-medium text-ink">Hosts on neither list</p>
          <p class="mt-0.5 text-[11px] leading-4 text-muted">
            {if(@network.limits.default == :blocked,
              do: "Blocked: the VM reaches only the hosts listed as reachable.",
              else: "Reachable, as the grants say."
            )}
          </p>
        </div>
        <.segmented
          id="limits-default"
          options={[{"reachable", "Reachable"}, {"blocked", "Blocked"}]}
          value={to_string(@network.limits.default)}
          event="limits_default"
          name="default"
          values={%{"network" => @network.id}}
        />
      </div>
      <div class="mt-3 grid gap-3 sm:grid-cols-2">
        <.limits_list
          id="limits-blocked"
          title="Blocked"
          icon="hero-no-symbol-micro"
          blocked?={true}
          hosts={@blocked}
          network={@network.id}
        />
        <.limits_list
          id="limits-reachable"
          title="Reachable"
          icon="hero-check-circle-micro"
          blocked?={false}
          hosts={@reachable}
          network={@network.id}
        />
      </div>
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :blocked?, :boolean, required: true
  attr :hosts, :list, required: true
  attr :network, :string, required: true

  # One list of a network's limits: its hosts, each moved to the other list
  # or taken off, and a field to add one.
  defp limits_list(assigns) do
    assigns =
      assign(assigns,
        form: to_form(%{"host" => "", "blocked" => to_string(assigns.blocked?)}, as: :limit),
        other: if(assigns.blocked?, do: "Reachable", else: "Blocked")
      )

    ~H"""
    <section id={@id} class="flex min-w-0 flex-col overflow-hidden rounded-lg border border-line">
      <header class="flex items-center gap-1.5 border-b border-line-soft bg-deep/40 px-3 py-2">
        <.icon name={@icon} class="size-3.5 text-muted" />
        <h3 class="text-xs font-semibold text-ink">{@title}</h3>
        <span id={"#{@id}-count"} class="text-[11px] tabular-nums text-faint">{length(@hosts)}</span>
      </header>
      <ul :if={@hosts != []} class="max-h-64 flex-1 divide-y divide-line-soft/70 overflow-y-auto">
        <li
          :for={host <- @hosts}
          id={"#{@id}-#{host_id(host)}"}
          class="group/host flex items-center gap-1 py-1 pl-3 pr-1.5 transition-colors hover:bg-hover/40"
        >
          <span class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={host}>
            {host}
          </span>
          <button
            type="button"
            id={"#{@id}-#{host_id(host)}-move"}
            phx-click="limits_put"
            phx-value-network={@network}
            phx-value-host={host}
            phx-value-blocked={to_string(not @blocked?)}
            title={"Move #{host} to #{@other}"}
            class="cursor-pointer rounded p-1 text-faint opacity-60 transition group-hover/host:opacity-100 hover:bg-hover hover:text-ink focus-visible:opacity-100"
          >
            <.icon
              name={if(@blocked?, do: "hero-arrow-right-micro", else: "hero-arrow-left-micro")}
              class="size-3.5"
            />
          </button>
          <button
            type="button"
            id={"#{@id}-#{host_id(host)}-remove"}
            phx-click="limits_remove"
            phx-value-network={@network}
            phx-value-host={host}
            title={"Take #{host} off: it goes as hosts on neither list do"}
            class="cursor-pointer rounded p-1 text-faint opacity-60 transition group-hover/host:opacity-100 hover:bg-hover hover:text-ink focus-visible:opacity-100"
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" />
          </button>
        </li>
      </ul>
      <p :if={@hosts == []} id={"#{@id}-empty"} class="flex-1 px-3 py-3 text-[11px] text-faint">
        No host here yet.
      </p>
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-submit="limits_add"
        class="flex items-center gap-1.5 border-t border-line-soft bg-deep/30 px-2 py-1.5"
      >
        <input type="hidden" name="limit[network]" value={@network} />
        <input type="hidden" name={@form[:blocked].name} value={@form[:blocked].value} />
        <input
          type="text"
          name={@form[:host].name}
          id={"#{@id}-host"}
          placeholder="example.com"
          autocomplete="off"
          class="min-w-0 flex-1 rounded border border-line bg-deep px-2 py-1 font-mono text-[11px] text-ink focus:border-accent focus:outline-none"
        />
        <button
          type="submit"
          id={"#{@id}-add"}
          class="cursor-pointer rounded px-2 py-1 text-[11px] font-semibold text-accent transition-colors hover:bg-hover"
        >
          Add
        </button>
      </.form>
    </section>
    """
  end

  ## Adding and editing a resource

  attr :form_state, :map,
    required: true,
    doc: "`%{kind: :credential | :network, editing: id | nil, form: form, errors: map}`"

  @doc "The dialog that adds a credential or a network, or edits one."
  def form_dialog(assigns) do
    assigns =
      assign(assigns,
        kind: assigns.form_state.kind,
        form: assigns.form_state.form,
        errors: assigns.form_state.errors,
        editing: assigns.form_state.editing,
        presets: Map.get(assigns.form_state, :presets, []),
        preset: Map.get(assigns.form_state, :preset),
        step: Map.get(assigns.form_state, :step, :form)
      )

    ~H"""
    <div
      id="resource-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="resource-dialog-title"
      phx-window-keydown="close_resource_form"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_resource_form"></div>
      <div class="relative flex max-h-full w-full max-w-xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 dark:shadow-black/60">
        <header class="flex items-start gap-3 border-b border-line-soft px-5 py-4">
          <div class="min-w-0 flex-1">
            <h2 id="resource-dialog-title" class="text-[15px] font-semibold text-ink">
              {dialog_title(@kind, @editing)}
            </h2>
            <p class="mt-1 text-xs leading-5 text-muted">{dialog_words(@kind)}</p>
          </div>
          <button
            type="button"
            id="resource-dialog-close"
            phx-click="close_resource_form"
            aria-label="Close"
            class="-mr-1 cursor-pointer rounded-md p-1 text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <div :if={@step == :pick} class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          <.preset_picker
            id="resource-presets"
            presets={@presets}
            event="pick_resource_preset"
            by_hand={
              if(@kind == :credential,
                do: "Any token or API key, or a command that mints one: you fill in every field.",
                else: "Its destinations, DNS server and interface: you fill in every field."
              )
            }
          />
        </div>
        <.form
          :if={@step != :pick}
          for={@form}
          id="resource-form"
          phx-change="validate_resource"
          phx-submit="save_resource"
          class="flex min-h-0 flex-1 flex-col"
        >
          <div class="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4">
            <div :if={@preset} class="flex items-center gap-2 text-[11px] text-muted">
              <.icon name={@preset.icon} class="size-3.5" /> From the preset
              <span class="font-medium text-ink">{@preset.name}</span>
              <button
                :if={is_nil(@editing)}
                type="button"
                id="resource-preset-change"
                phx-click="resource_preset_back"
                class="cursor-pointer text-accent hover:underline"
              >
                Change
              </button>
            </div>
            <input :if={@preset} type="hidden" name="resource[preset]" value={@preset.id} />
            <details
              :if={@preset && @preset.guide != []}
              id="resource-preset-guide"
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
                  :for={{step, index} <- Enum.with_index(@preset.guide, 1)}
                  class="flex gap-2 text-xs leading-5 text-ink"
                >
                  <span class="w-4 shrink-0 text-right text-faint">{index}.</span>
                  <span>{step}</span>
                </li>
              </ol>
            </details>
            <div :if={@preset && @preset.fill != []} id="resource-preset-fill" class="space-y-3">
              <div :for={field <- @preset.fill}>
                <label
                  class="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted"
                  for={"resource-fill-#{field.name}"}
                >
                  {field.label}
                </label>
                <input
                  type="text"
                  name={"resource[fill][#{field.name}]"}
                  id={"resource-fill-#{field.name}"}
                  value={get_in(@form.params, ["fill", field.name])}
                  placeholder={field.example}
                  class="w-full rounded-md border border-line bg-deep px-2.5 py-1.5 text-xs text-ink transition-colors placeholder:text-faint focus:border-accent focus:outline-none"
                />
              </div>
              <.field_error errors={@errors} field={:fill} />
            </div>
            <.text_field field={@form[:name]} label="Name" placeholder={name_placeholder(@kind)} />
            <.field_error errors={@errors} field={:name} />
            <.text_field
              field={@form[:purpose]}
              type="textarea"
              label="What it is"
              placeholder={purpose_placeholder(@kind)}
            />
            <.field_error errors={@errors} field={:purpose} />
            <%= if @kind == :credential do %>
              <.credential_fields form={@form} errors={@errors} editing={@editing} />
            <% else %>
              <.network_fields form={@form} errors={@errors} />
            <% end %>
          </div>
          <footer class="flex justify-end gap-2 border-t border-line-soft px-5 py-3">
            <.button type="button" id="resource-cancel" phx-click="close_resource_form">
              Cancel
            </.button>
            <.button type="submit" id="resource-save" variant="primary">
              {if(@editing, do: "Save", else: "Add")}
            </.button>
          </footer>
        </.form>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true
  attr :editing, :any, required: true
  attr :settings?, :boolean, default: false
  attr :has_value, :boolean, default: false

  defp credential_fields(assigns) do
    # A top-level password key is filtered from both decoded and form-encoded logs.
    password = %{
      assigns.form[:password]
      | id: if(assigns.settings?, do: "resource-settings-password", else: "resource-password"),
        name: "credential_password",
        value: nil
    }

    assigns =
      assign(assigns,
        password: password,
        minted?: assigns.form[:source].value == "minted",
        adapter: to_string(assigns.form[:adapter].value || "bearer"),
        adapters: MWTClient.Sandbox.Adapter.all()
      )

    ~H"""
    <.choice_field
      id="resource-source"
      name={@form[:source].name}
      label="Its value"
      options={[
        {"stored", "Pasted, kept in your vault"},
        {"minted", "Minted by a command on this machine"}
      ]}
      value={if(@minted?, do: "minted", else: "stored")}
    />
    <div :if={not @minted?} id={"#{@password.id}-field"} phx-hook=".ResourcePassword">
      <.text_field
        field={@password}
        type="password"
        label="Value (optional now)"
        autocomplete="new-password"
        placeholder="Paste the value"
        hint={
          if(@has_value,
            do: "Leave blank to keep the saved value.",
            else: "Until you paste a value, every use is refused."
          )
        }
        phx-update="ignore"
      />
      <.field_error errors={@errors} field={:value} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ResourcePassword">
      export default {
        mounted() {
          this.handleEvent("clear-resource-password", () => {
            this.el.querySelector("input").value = ""
          })
        }
      }
    </script>
    <div :if={@minted?}>
      <.text_field
        field={@form[:mint]}
        label={
          if(@adapter == "github" and app?(@form),
            do: "Command that prints the App's private key",
            else: "Command that prints a short-lived value"
          )
        }
        placeholder={
          if(@adapter == "github" and app?(@form),
            do: "pass show github/app-key",
            else: "gcloud auth print-access-token"
          )
        }
      />
      <p id="resource-mint-where" class="mt-1 flex items-center gap-1.5 text-[10px] text-faint">
        <.where place={:machine} /> each time a value is needed, as you, never in the VM
      </p>
      <.field_error errors={@errors} field={:mint} />
    </div>
    <div>
      <.text_field
        field={@form[:env]}
        label="Variables holding its placeholder"
        placeholder="API_KEY, SERVICE_TOKEN"
      />
      <p class="mt-1 text-[10px] leading-4 text-faint">
        Only under mwt exec, and only its placeholder: MWT swaps the real value in on the way out.
      </p>
      <.field_error errors={@errors} field={:env} />
    </div>
    <.advanced
      id="resource-advanced"
      set={credential_advanced_set(@form, @adapter, @editing)}
      open={
        Enum.any?(
          [
            :adapter,
            :app,
            :keep_minutes,
            :prefix,
            :present_project,
            :present_email,
            :present_id_header
          ],
          &Map.has_key?(@errors, &1)
        )
      }
    >
      <div>
        <label
          for="resource-adapter"
          class="mb-1.5 block text-[11px] font-medium uppercase tracking-wide text-muted"
        >
          The service it is for
        </label>
        <select
          id="resource-adapter"
          name={@form[:adapter].name}
          class="w-full rounded-md border border-line bg-deep px-2.5 py-1.5 text-xs text-ink transition-colors focus:border-accent focus:outline-none"
        >
          <option
            :for={adapter <- @adapters}
            value={adapter.id()}
            selected={Atom.to_string(adapter.id()) == @adapter}
          >
            {adapter_label(adapter.id())}
          </option>
        </select>
        <p class="mt-1 text-[10px] leading-4 text-faint">
          How MWT reads a minted value, what a grant over it may narrow by, and the grant presets offered for it.
        </p>
        <.field_error errors={@errors} field={:adapter} />
      </div>
      <div :if={@adapter == "github"} id="resource-github-app" class="space-y-2">
        <p class="text-[11px] text-muted">
          A GitHub App: with both ids, the command prints the App's private key, and MWT trades it for an hour's installation token.
        </p>
        <div class="grid gap-2 sm:grid-cols-2">
          <.text_field
            field={@form[:app_id]}
            label="App's client id or app id"
            placeholder="Iv23liABCD1234"
          />
          <.text_field
            field={@form[:installation_id]}
            label="Installation's id"
            placeholder="12345678"
          />
        </div>
        <.field_error errors={@errors} field={:app} />
      </div>
      <div :if={@minted?}>
        <.text_field
          field={@form[:keep_minutes]}
          type="number"
          label="Mint again after at most (minutes)"
          placeholder="Until a minute before it expires"
        />
        <.field_error errors={@errors} field={:keep_minutes} />
      </div>
      <.text_field
        field={@form[:file_env]}
        label="Variables naming a file that holds it"
        placeholder="SERVICE_TOKEN_FILE"
      />
      <.text_field
        :if={is_nil(@editing)}
        field={@form[:prefix]}
        label="Its placeholder starts with"
        placeholder="mwt_ (some tools check a token's shape: ghp_, sk-…)"
      />
      <.check_field
        field={@form[:git]}
        label="Git over HTTPS gets it from MWT's credential helper"
        hint="For a token git sends as a password, with any git host over HTTPS: the helper answers with the placeholder for the hosts a grant over it lists."
      />
      <div :if={@adapter == "google"} id="resource-google" class="space-y-3">
        <.check_field
          field={@form[:present_login]}
          label="A Google login file, for tools that refresh a login themselves"
        />
        <.text_field
          :if={@form[:present_login].value in ["true", true]}
          field={@form[:present_id_header]}
          label="Header the tool sends the ID token in (optional)"
          placeholder="X-Id-Token"
        />
        <.check_field
          field={@form[:present_metadata]}
          label="A metadata server, for Google's client libraries"
        />
        <div
          :if={@form[:present_metadata].value in ["true", true]}
          class="grid gap-2 sm:grid-cols-2"
        >
          <.text_field field={@form[:present_project]} label="Project" placeholder="my-project" />
          <.text_field
            field={@form[:present_email]}
            label="Account it reports (optional)"
            placeholder="sa@my-project.iam.gserviceaccount.com"
          />
        </div>
        <.field_error errors={@errors} field={:present_project} />
        <.field_error errors={@errors} field={:present_email} />
        <.field_error errors={@errors} field={:present_id_header} />
      </div>
    </.advanced>
    """
  end

  # What a credential's Advanced holds that is set, for its summary.
  defp credential_advanced_set(form, adapter, editing) do
    text = &(form[&1].value |> to_string() |> String.trim())

    [
      adapter != "bearer" &&
        case MWTClient.Sandbox.Adapter.find(adapter) do
          {:ok, found} -> found.name()
          :error -> adapter
        end,
      app?(form) && "a GitHub App",
      text.(:keep_minutes) != "" && "minted again after #{text.(:keep_minutes)} min",
      text.(:file_env) != "" && "a token file",
      (is_nil(editing) and text.(:prefix) not in ["", "mwt_"]) && "placeholder #{text.(:prefix)}…",
      form[:git].value in ["true", true] && "git over HTTPS",
      form[:present_login].value in ["true", true] && "a Google login file",
      form[:present_metadata].value in ["true", true] && "a metadata server"
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Whether the form names a GitHub App: either of its ids given.
  defp app?(form),
    do: Enum.any?([form[:app_id].value, form[:installation_id].value], &(&1 not in [nil, ""]))

  defp adapter_label(:bearer), do: "Any service: a bearer token or API key"
  defp adapter_label(:github), do: "GitHub: a token, or a GitHub App"
  defp adapter_label(:google), do: "Google: gcloud and Google's APIs"
  defp adapter_label(:hex), do: "Hex: an API key"
  defp adapter_label(other), do: to_string(other)

  attr :form, :any, required: true
  attr :errors, :map, required: true

  defp network_fields(assigns) do
    ~H"""
    <div>
      <.text_field
        field={@form[:destinations]}
        type="textarea"
        label="Destinations, one a line"
        placeholder={Enum.join(["10.20.0.0/16", "db.corp.example:5432", "*.corp.example:443"], "\n")}
      />
      <.field_error errors={@errors} field={:destinations} />
    </div>
    <.text_field field={@form[:resolver]} label="DNS server (optional)" placeholder="10.8.0.1" />
    <.field_error errors={@errors} field={:resolver} />
    <.text_field
      field={@form[:anchor]}
      label="Interface it goes through (optional)"
      placeholder="wg0"
    />
    <.field_error errors={@errors} field={:anchor} />
    """
  end

  attr :errors, :map, required: true
  attr :field, :atom, required: true

  defp field_error(assigns) do
    ~H"""
    <p
      :if={Map.get(@errors, @field)}
      id={"resource-error-#{@field}"}
      class="-mt-2 text-[11px] text-bad"
    >
      {Map.get(@errors, @field)}
    </p>
    """
  end

  @doc "A resource's form fields, as its dialog shows them."
  def form_fields(%Credential{} = credential) do
    %{
      "name" => credential.name,
      "purpose" => credential.purpose,
      "source" => if(match?({:minted, _}, credential.source), do: "minted", else: "stored"),
      "mint" =>
        case credential.source do
          {:minted, command} -> command
          _stored -> ""
        end,
      "env" => Enum.join(credential.env, ", "),
      "file_env" => Enum.join(credential.file_env, ", "),
      "git" => to_string(credential.git),
      "keep_minutes" =>
        if(credential.keep_minutes, do: Integer.to_string(credential.keep_minutes), else: ""),
      "mint_per" => Atom.to_string(credential.mint_per),
      "adapter" => Atom.to_string(credential.adapter),
      "app_id" => (credential.app && credential.app.app_id) || "",
      "installation_id" => (credential.app && credential.app.installation_id) || "",
      "present_login" => to_string(Map.has_key?(credential.presents, :login)),
      "present_id_header" => get_in(credential.presents, [:login, :header]) || "",
      "present_metadata" => to_string(Map.has_key?(credential.presents, :metadata)),
      "present_project" => get_in(credential.presents, [:metadata, :project]) || "",
      "present_email" => get_in(credential.presents, [:metadata, :email]) || ""
    }
  end

  def form_fields(%Network{} = network) do
    %{
      "name" => network.name,
      "purpose" => network.purpose,
      "destinations" => Enum.join(network.destinations, "\n"),
      "resolver" => network.resolver || "",
      "anchor" => network.anchor || ""
    }
  end

  def form_fields(:credential), do: %{"source" => "stored", "adapter" => "bearer"}
  def form_fields(:network), do: %{}

  ## A resource's lock

  attr :resource, :any, required: true
  attr :locks, :map, required: true
  attr :name, :string, required: true

  @doc """
  A resource's lock: a Lock button while it is open, as a resource is by
  default; locked, a tag saying by whom and Unlock. A lock only the
  isolation holds ends as you release the VM, on the Firewall page: the
  button can't end it.
  """
  def lock_switch(assigns) do
    {kind, id} =
      case assigns.resource do
        {kind, id} -> {Atom.to_string(kind), id}
        kind -> {Atom.to_string(kind), ""}
      end

    holders = MWTClient.Sandbox.Server.Locks.holders(assigns.locks, assigns.resource)

    assigns =
      assign(assigns,
        kind: kind,
        rid: id,
        locked?: holders != [],
        mine?: :you in holders,
        isolation?: :isolation in holders,
        dom: "lock-#{kind}" <> if(id == "", do: "", else: "-#{id}")
      )

    ~H"""
    <span class="inline-flex shrink-0 items-center gap-2">
      <span
        :if={@locked?}
        id={"#{@dom}-locked"}
        title={
          cond do
            @mine? and @isolation? ->
              "Locked by you and by the isolation"

            @isolation? ->
              "Locked by the isolation: it ends as you release the VM on the Firewall page"

            true ->
              "Locked by you"
          end
        }
        class="inline-flex items-center gap-1 rounded-md bg-bad-soft/40 px-1.5 py-0.5 text-[10px] font-semibold text-bad"
      >
        <.icon name="hero-lock-closed-micro" class="size-3" />
        {if(@isolation? and not @mine?, do: "Isolated", else: "Locked")}
      </span>
      <button
        type="button"
        id={@dom}
        aria-pressed={to_string(@locked?)}
        disabled={@isolation? and not @mine?}
        title={
          cond do
            @mine? -> "Unlock #{@name}: its grants give its uses again"
            @isolation? -> "#{@name} is locked by the isolation: release the VM on the Firewall page"
            true -> "Lock #{@name}: every use of it is refused, whatever its grants say"
          end
        }
        phx-click={if(@mine?, do: "unlock_resource", else: "lock_resource")}
        phx-value-kind={@kind}
        phx-value-id={@rid}
        class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:border-bad/50 hover:text-bad disabled:cursor-default disabled:opacity-40"
      >
        <.icon
          name={if(@locked?, do: "hero-lock-open-micro", else: "hero-lock-closed-micro")}
          class="size-3.5"
        />
        {if(@mine?, do: "Unlock", else: "Lock")}
      </button>
    </span>
    """
  end

  ## Words and helpers

  @doc "A resource as part of an element's id."
  def dom_id({kind, id}), do: "#{kind}-#{id}"
  def dom_id(kind) when is_atom(kind), do: Atom.to_string(kind)

  @doc "How the add dialog names the resource a new grant is over: `kind:id`."
  def over_value({kind, id}), do: "#{kind}:#{id}"
  def over_value(kind) when is_atom(kind), do: Atom.to_string(kind)

  @doc "The resource a value of `over_value/1` names, or nil."
  def over_from(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      ["credential", id] -> {:credential, id}
      ["network", id] -> {:network, id}
      ["machine"] -> :machine
      ["mwt"] -> :mwt
      _other -> nil
    end
  end

  def over_from(_value), do: nil

  defp built_in?(%Network{internet: true}), do: true
  defp built_in?(found) when found in [:machine, :mwt], do: true
  defp built_in?(_found), do: false

  # A mint an agent wrote runs as you, unconfined, whenever the value is
  # needed: read like a command's script.
  defp mint_hints(%Credential{source: {:minted, command}}, grants),
    do: [
      "It runs on this machine as you, outside any bubble, each time the value is needed, with no ask."
      | MWTClient.Sandbox.HostCommand.hints(command, grants)
    ]

  defp to_review?(%{proposal: %{reviewed_at: nil}}), do: true
  defp to_review?(_found), do: false

  defp kind_word({:credential, _id}), do: "credential"
  defp kind_word({:network, _id}), do: "network"
  defp kind_word(_built_in), do: "resource"

  defp purpose(%Network{internet: true}), do: Network.internet().purpose
  defp purpose(%{purpose: purpose}) when is_binary(purpose), do: purpose
  defp purpose(_found), do: ""

  defp has_value?(%Credential{id: id}, values), do: Map.get(values, id, false)
  defp has_value?(_found, _values), do: false

  defp resource_tone({:credential, _id}), do: "bg-accent-soft/50 text-accent"
  defp resource_tone({:network, _id}), do: "bg-teal/15 text-teal"
  defp resource_tone(:machine), do: "bg-violet/15 text-violet"
  defp resource_tone(:mwt), do: "bg-ok-soft/50 text-ok-strong"

  @doc "What a credential is, in a line: how its value is made and what the VM gets."
  def credential_summary(%Credential{} = credential) do
    how =
      case credential.source do
        {:minted, _command} -> "minted on this machine"
        _stored -> "stored"
      end

    "mwt exec #{credential.id} · #{how}"
  end

  @doc "What a network is, in a line."
  def network_summary(%Network{internet: true} = network),
    do: "Every public address" <> blocked_summary(network)

  def network_summary(%Network{} = network) do
    Enum.join(
      [
        Enum.join(network.destinations, ", "),
        network.resolver && "names by #{network.resolver}",
        network.anchor && "through #{network.anchor}"
      ]
      |> Enum.reject(&(&1 in [nil, ""])),
      " · "
    ) <> blocked_summary(network)
  end

  defp blocked_summary(%Network{limits: %HostLimits{default: :blocked}}),
    do: " · only the hosts you listed"

  defp blocked_summary(%Network{limits: limits}) do
    case Enum.count(limits.rules, & &1.blocked?) do
      0 -> ""
      1 -> " · 1 host blocked"
      n -> " · #{n} hosts blocked"
    end
  end

  defp grants_subtitle({:credential, _id}),
    do: "Where its value may go, and how each use is approved."

  defp grants_subtitle({:network, _id}),
    do: "What the VM may reach on it, all of it or some hosts, and how each use is approved."

  defp grants_subtitle(:machine),
    do: "Your saved commands, and Commands agents write, which always asks."

  defp grants_subtitle(:mwt), do: "Built in: each of MWT's tools a grant of its own."

  defp no_grants_words({:credential, _id}),
    do: "No grant over it yet: its value goes nowhere until one is on."

  defp no_grants_words({:network, _id}),
    do: "No grant over it yet: the VM reaches nothing of it until one is on."

  defp no_grants_words(_built_in), do: "None."

  # What a resource's Add grant starts from: over a credential, choosing
  # its kind first (`pick_over`); over a network, open use; over your
  # machine, a saved command.
  defp add_grant_preset({:credential, _id}), do: "over"
  defp add_grant_preset({:network, _id}), do: "network"
  defp add_grant_preset(:machine), do: "saved_command"
  defp add_grant_preset(_built_in), do: nil

  defp host_id(host), do: host |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp dialog_title(:credential, nil), do: "Add a credential"
  defp dialog_title(:credential, _id), do: "Edit the credential"
  defp dialog_title(:network, nil), do: "Add a network"
  defp dialog_title(:network, _id), do: "Edit the network"

  defp dialog_words(:credential),
    do:
      "A secret the VM never holds: it gets a placeholder, which MWT swaps for the value where a grant over the credential lets it go."

  defp dialog_words(:network),
    do:
      "Addresses, ranges and names the VM may reach through this machine, as a VPN or your LAN does. Grants over it open it."

  defp name_placeholder(:credential), do: "Stripe test key"
  defp name_placeholder(:network), do: "Prod VPN"

  defp purpose_placeholder(:credential), do: "A Stripe test key, for the checkout tests"
  defp purpose_placeholder(:network), do: "The production network, through the company VPN"
end
