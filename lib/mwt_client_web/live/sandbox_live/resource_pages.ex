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

  attr :grants, :list, required: true
  attr :credentials, :list, required: true
  attr :networks, :list, required: true
  attr :locks, :map, required: true
  attr :now, DateTime, required: true

  @doc "Every resource, in three groups, each with its lock and its grants."
  def list(assigns) do
    assigns =
      assign(assigns,
        networks: Enum.sort_by(assigns.networks, &(not &1.internet))
      )

    ~H"""
    <div id="resources-list" class="space-y-6">
      <.card
        id="resources-credentials"
        title="Credentials"
        subtitle="Secrets MWT uses for the VM, which never enters it: a token, an API key, a login a command mints."
      >
        <:help>
          The VM gets a placeholder instead; MWT swaps the real value in on the way out, where a grant over the credential lets it go. Add one here, then a grant over it on its page, or add a grant from a preset, which makes both.
        </:help>
        <:actions>
          <.button
            id="add-credential"
            phx-click="open_resource_form"
            phx-value-kind="credential"
          >
            <.icon name="hero-plus-micro" class="size-3.5" /> Add credential
          </.button>
        </:actions>
        <ul :if={@credentials != []} class="-m-4 divide-y divide-line-soft">
          <.resource_row
            :for={credential <- @credentials}
            resource={{:credential, credential.id}}
            name={credential.name}
            summary={credential_summary(credential)}
            grants={@grants}
            locks={@locks}
            now={@now}
          />
        </ul>
        <p :if={@credentials == []} id="resources-credentials-empty" class="text-xs text-muted">
          None yet.
        </p>
      </.card>

      <.card
        id="resources-networks"
        title="Networks"
        subtitle="Where the VM's connections go: the Internet, built in, and your private networks (a VPN, the office LAN, a database)."
      >
        <:help>
          A grant over a network opens it, all of it or some of its hosts. A network's own host lists keep the VM away from hosts, whatever any grant says.
        </:help>
        <:actions>
          <.button id="add-network" phx-click="open_resource_form" phx-value-kind="network">
            <.icon name="hero-plus-micro" class="size-3.5" /> Add network
          </.button>
        </:actions>
        <ul class="-m-4 divide-y divide-line-soft">
          <.resource_row
            :for={network <- @networks}
            resource={{:network, network.id}}
            name={network.name}
            summary={network_summary(network)}
            built_in={network.internet}
            grants={@grants}
            locks={@locks}
            now={@now}
          />
        </ul>
      </.card>

      <.card
        id="resources-built-in"
        title="Built in"
        subtitle="Your machine, and MWT's own tools."
      >
        <ul class="-m-4 divide-y divide-line-soft">
          <.resource_row
            resource={:machine}
            name="Your machine"
            summary="Saved commands, the projects' git, the shared folders and the workspace"
            built_in
            grants={@grants}
            locks={@locks}
            now={@now}
          />
          <.resource_row
            resource={:mwt}
            name="MWT's tools"
            summary="Notes, diagrams and flash cards, through mwt mcp"
            built_in
            grants={@grants}
            locks={@locks}
            now={@now}
          />
        </ul>
      </.card>
    </div>
    """
  end

  attr :resource, :any, required: true
  attr :name, :string, required: true
  attr :summary, :string, required: true
  attr :built_in, :boolean, default: false
  attr :grants, :list, required: true
  attr :locks, :map, required: true
  attr :now, DateTime, required: true

  # One resource: what it is, how many grants are over it and how many of
  # them are on, and its lock.
  defp resource_row(assigns) do
    over = Resource.grants(assigns.grants, assigns.resource)
    on = Enum.count(over, &Grant.on?(&1, assigns.now))

    assigns = assign(assigns, over: length(over), on: on, dom: dom_id(assigns.resource))

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
          <span
            :if={@built_in}
            class="rounded border border-line bg-deep px-1.5 py-0.5 text-[10px] font-medium text-muted"
          >
            Built in
          </span>
        </p>
        <p class="truncate text-[11px] text-faint" title={@summary}>{@summary}</p>
      </div>
      <span
        id={"resource-grants-#{@dom}"}
        class={[
          "hidden shrink-0 text-[11px] sm:inline",
          if(@on > 0, do: "font-medium text-ok-strong", else: "text-faint")
        ]}
      >
        {grants_count(@over, @on)}
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

  @doc """
  A resource's page: what it is, its lock, a network's host limits, the
  grants over it, each with its switch, and its actions.
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
    {actions, grants} = Enum.split_with(over, &Grant.action?/1)

    assigns =
      assign(assigns,
        found: found,
        name: found && Resource.name(resource, assigns.credentials, assigns.networks),
        over_grants: Enum.sort_by(grants, &{not Grant.on?(&1, assigns.now), &1.name}),
        actions: actions,
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

      <header id="resource-header" class="mb-6 flex flex-wrap items-center gap-3">
        <span class={[
          "flex size-10 shrink-0 items-center justify-center rounded-xl",
          resource_tone(@resource)
        ]}>
          <.icon name={resource_icon(@resource)} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-[10px] font-medium uppercase tracking-wide text-faint">
            {Resource.kind_words(@resource)}{if(@built_in?, do: " · Built in")}
          </p>
          <h1 id="resource-name" class="truncate text-lg font-semibold tracking-tight text-ink">
            {@name}
          </h1>
          <p :if={purpose(@found) != ""} class="mt-0.5 text-[13px] text-muted">
            {purpose(@found)}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.lock_switch resource={@resource} locks={@locks} name={@name} labelled />
          <.button
            :if={not @built_in?}
            id="edit-resource"
            phx-click="edit_resource"
            phx-value-kind={elem(@resource, 0)}
            phx-value-id={elem(@resource, 1)}
          >
            <.icon name="hero-pencil-square-micro" class="size-3.5" /> Edit
          </.button>
          <.button
            :if={not @built_in?}
            id="delete-resource"
            variant="danger"
            phx-click="confirm_delete_resource"
            phx-value-kind={elem(@resource, 0)}
            phx-value-id={elem(@resource, 1)}
          >
            <.icon name="hero-trash-micro" class="size-3.5" /> Remove
          </.button>
        </div>
      </header>

      <div class="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="space-y-5">
          <.card
            id="resource-grants"
            title="Grants over it"
            subtitle={grants_subtitle(@resource)}
            body_class=""
          >
            <:help>
              Each grant gives uses of this resource, while it is on. Of those that cover a use, the most permissive counts; a use that also goes through another resource needs a grant there too, and it goes unasked only if each lets it through.
            </:help>
            <:actions>
              <.button
                :if={add_grant_preset(@resource)}
                id="add-grant-over"
                variant="primary"
                phx-click="open_add_grant"
                phx-value-preset={add_grant_preset(@resource)}
                phx-value-over={over_value(@resource)}
              >
                <.icon name="hero-plus-micro" class="size-3.5" /> Add a grant over it
              </.button>
            </:actions>
            <ul :if={@over_grants != []} class="divide-y divide-line-soft">
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
              class="px-4 py-4 text-xs text-muted"
            >
              {no_grants_words(@resource)}
            </p>
          </.card>

          <.limits_card :if={match?(%Network{}, @found)} network={@found} />

          <.card
            :if={actions_preset(@resource)}
            id="resource-actions"
            title="Actions"
            subtitle={actions_subtitle(@resource)}
            body_class=""
          >
            <:help>
              An action is one fixed use of this resource, which MWT carries out when an agent calls it by id with a value for each parameter: mwt call ID NAME=value. Each is a grant of its own, with its own switch.
            </:help>
            <:actions>
              <.button
                id="add-action"
                phx-click="open_add_grant"
                phx-value-preset={actions_preset(@resource)}
                phx-value-over={over_value(@resource)}
              >
                <.icon name="hero-plus-micro" class="size-3.5" /> Add action
              </.button>
            </:actions>
            <ul :if={@actions != []} class="divide-y divide-line-soft">
              <Grants.grant_row
                :for={grant <- @actions}
                prefix="action"
                grant={grant}
                duration={Grants.row_duration(grant, @durations, @now)}
                mode={Grants.row_mode(grant, @modes, @now)}
                now={@now}
              />
            </ul>
            <p :if={@actions == []} id="resource-actions-empty" class="px-4 py-4 text-xs text-muted">
              None yet.
            </p>
          </.card>
        </div>

        <div class="space-y-5">
          <.card id="resource-what" title="What it is">
            <.what_it_is
              found={@found}
              has_value={has_value?(@found, @credential_values)}
              value_form={@value_form}
            />
          </.card>
          <.card id="resource-lock" title="Lock">
            <p class="text-xs leading-5 text-muted">
              Locked, every use of it is refused, whatever its grants say, and nothing waiting on it goes. Agents can't ask for it to be unlocked; only you unlock it. Isolating the VM locks every resource until you release it.
            </p>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  attr :found, :any, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true

  defp what_it_is(%{found: %Credential{}} = assigns) do
    ~H"""
    <dl class="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-x-3 gap-y-2.5 text-xs">
      <dt class="text-muted">Its value</dt>
      <dd id="credential-source" class="text-ink">
        <%= case @found.source do %>
          <% {:minted, command} -> %>
            Minted on this machine when needed, by
            <code class="block break-all rounded bg-deep px-1.5 py-1 font-mono text-[11px]">
              {command}
            </code>
          <% _stored -> %>
            <span :if={@has_value} class="text-ok-strong">Stored in your vault</span>
            <span :if={not @has_value} class="text-warn-strong">No value yet: paste one below</span>
        <% end %>
      </dd>
      <dt class="text-muted">In the VM</dt>
      <dd class="text-ink">
        <code class="font-mono text-[11px]">mwt exec {@found.id} -- COMMAND</code>
        gives that command placeholders only.
      </dd>
      <dt :if={@found.env != []} class="text-muted">Variables</dt>
      <dd :if={@found.env != []} class="font-mono text-[11px] text-ink">
        {Enum.join(@found.env, ", ")}
      </dd>
      <dt :if={@found.file_env != []} class="text-muted">File variables</dt>
      <dd :if={@found.file_env != []} class="font-mono text-[11px] text-ink">
        {Enum.join(@found.file_env, ", ")}
      </dd>
      <dt :if={@found.git} class="text-muted">Git</dt>
      <dd :if={@found.git} class="text-ink">MWT's credential helper answers for its hosts</dd>
    </dl>
    <.form
      :if={@found.source == :stored}
      for={@value_form}
      id="credential-value-form"
      phx-submit="set_credential_value"
      class="mt-4 flex items-center gap-2 border-t border-line-soft pt-3"
    >
      <input type="hidden" name="value[credential]" value={@found.id} />
      <input
        type="password"
        name="value[value]"
        id="credential-value"
        autocomplete="off"
        placeholder={if(@has_value, do: "Replace the value", else: "Paste the value")}
        class="min-w-0 flex-1 rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink focus:border-accent focus:outline-none"
      />
      <.button id="credential-value-save" type="submit">Save</.button>
    </.form>
    """
  end

  defp what_it_is(%{found: %Network{internet: true}} = assigns) do
    ~H"""
    <p class="text-xs leading-5 text-muted">
      Every public address. MWT builds it in, with a grant over all of it that is on and auto-approving when MWT starts, unless you choose otherwise. Private and reserved addresses are never its: they are networks of their own.
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
      This machine: where your saved commands run, and what the projects' git, the shared folders and the workspace reach. A command an agent writes needs no grant: you approve each one, and while your machine is locked it is refused at once.
    </p>
    """
  end

  defp what_it_is(%{found: :mwt} = assigns) do
    ~H"""
    <p class="text-xs leading-5 text-muted">
      Your notes, diagrams and flash cards in MWT, which agents read and write through mwt mcp, as its grants allow.
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
        editing: assigns.form_state.editing
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
        <.form
          for={@form}
          id="resource-form"
          phx-change="validate_resource"
          phx-submit="save_resource"
          class="flex min-h-0 flex-1 flex-col"
        >
          <div class="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4">
            <.input field={@form[:name]} label="Name" placeholder={name_placeholder(@kind)} />
            <.field_error errors={@errors} field={:name} />
            <.input
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

  defp credential_fields(assigns) do
    assigns = assign(assigns, minted?: assigns.form[:source].value == "minted")

    ~H"""
    <div>
      <p class="mb-1.5 text-[11px] font-medium uppercase tracking-wide text-muted">Its value</p>
      <div class="flex flex-wrap gap-4 text-xs text-ink">
        <label class="flex items-center gap-1.5">
          <input
            type="radio"
            name={@form[:source].name}
            id="resource-source-stored"
            value="stored"
            checked={not @minted?}
          /> Pasted, kept in your vault
        </label>
        <label class="flex items-center gap-1.5">
          <input
            type="radio"
            name={@form[:source].name}
            id="resource-source-minted"
            value="minted"
            checked={@minted?}
          /> Minted by a command on this machine
        </label>
      </div>
    </div>
    <div :if={not @minted? and is_nil(@editing)}>
      <.input field={@form[:value]} type="password" label="Value" autocomplete="off" />
      <.field_error errors={@errors} field={:value} />
    </div>
    <p :if={not @minted? and @editing} class="text-[11px] text-muted">
      Replace its value on its page.
    </p>
    <div :if={@minted?}>
      <.input
        field={@form[:mint]}
        label="Command that prints a short-lived value"
        placeholder="gcloud auth print-access-token"
      />
      <.field_error errors={@errors} field={:mint} />
    </div>
    <.input
      field={@form[:env]}
      label="Variables holding its placeholder, under mwt exec"
      placeholder="GH_TOKEN, GITHUB_TOKEN"
    />
    <.field_error errors={@errors} field={:env} />
    <.input
      field={@form[:file_env]}
      label="Variables naming a file that holds it"
      placeholder="GOOGLE_OAUTH_ACCESS_TOKEN_FILE"
    />
    <.input
      field={@form[:git]}
      type="checkbox"
      label="Git over HTTPS gets it from MWT's credential helper"
    />
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true

  defp network_fields(assigns) do
    ~H"""
    <div>
      <.input
        field={@form[:destinations]}
        type="textarea"
        label="Destinations, one a line"
        placeholder="10.20.0.0/16\ndb.corp.example:5432\n*.corp.example:443"
      />
      <.field_error errors={@errors} field={:destinations} />
    </div>
    <.input field={@form[:resolver]} label="DNS server (optional)" placeholder="10.8.0.1" />
    <.field_error errors={@errors} field={:resolver} />
    <.input field={@form[:anchor]} label="Interface it goes through (optional)" placeholder="wg0" />
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
      "mint_per" => Atom.to_string(credential.mint_per)
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

  def form_fields(:credential), do: %{"source" => "stored"}
  def form_fields(:network), do: %{}

  ## A resource's lock

  attr :resource, :any, required: true
  attr :locks, :map, required: true
  attr :name, :string, required: true
  attr :labelled, :boolean, default: false, doc: "says Open beside the switch while it is open"

  @doc """
  A resource's lock: on reads as open, as a resource is by default; locked,
  it is off, beside a badge saying by whom. A lock only the isolation
  holds ends as you release the VM, on the Firewall page: the switch can't
  end it.
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
      <span :if={@labelled and not @locked?} id={"#{@dom}-open"} class="text-[11px] text-muted">
        Open
      </span>
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
      <.switch
        id={@dom}
        on={not @locked?}
        disabled={@isolation? and not @mine?}
        label={
          cond do
            @mine? -> "Unlock #{@name}"
            @isolation? -> "#{@name} is locked by the isolation: release the VM on the Firewall page"
            true -> "Lock #{@name}"
          end
        }
        phx-click={if(@mine?, do: "unlock_resource", else: "lock_resource")}
        phx-value-kind={@kind}
        phx-value-id={@rid}
      />
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

  defp purpose(%Network{internet: true}), do: Network.internet().purpose
  defp purpose(%{purpose: purpose}) when is_binary(purpose), do: purpose
  defp purpose(_found), do: ""

  defp has_value?(%Credential{id: id}, values), do: Map.get(values, id, false)
  defp has_value?(_found, _values), do: false

  defp resource_tone({:credential, _id}), do: "bg-accent-soft/50 text-accent"
  defp resource_tone({:network, _id}), do: "bg-teal/15 text-teal"
  defp resource_tone(:machine), do: "bg-violet/15 text-violet"
  defp resource_tone(:mwt), do: "bg-ok-soft/50 text-ok-strong"

  defp credential_summary(%Credential{} = credential) do
    how =
      case credential.source do
        {:minted, _command} -> "minted on this machine"
        _stored -> "stored"
      end

    "mwt exec #{credential.id} · #{how}"
  end

  defp network_summary(%Network{internet: true} = network),
    do: "Every public address" <> blocked_summary(network)

  defp network_summary(%Network{} = network) do
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

  defp grants_subtitle(:machine), do: "MWT's built-in grants for your machine."
  defp grants_subtitle(:mwt), do: "Reading, creating and changing, each a grant of its own."

  defp no_grants_words({:credential, _id}),
    do: "No grant over it yet: its value goes nowhere until one is on."

  defp no_grants_words({:network, _id}),
    do: "No grant over it yet: the VM reaches nothing of it until one is on."

  defp no_grants_words(_built_in), do: "None."

  defp add_grant_preset({:credential, _id}), do: "token"
  defp add_grant_preset({:network, _id}), do: "network"
  defp add_grant_preset(_built_in), do: nil

  defp actions_preset({:credential, _id}), do: "request_action"
  defp actions_preset(:machine), do: "saved_command"
  defp actions_preset(_other), do: nil

  defp actions_subtitle({:credential, _id}),
    do:
      "Requests MWT sends itself with its value; each also needs a grant over its host's network."

  defp actions_subtitle(:machine),
    do:
      "Your own scripts, which agents call by id; each run is approved unless you auto-approve it."

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

  defp name_placeholder(:credential), do: "GitHub personal"
  defp name_placeholder(:network), do: "Prod VPN"

  defp purpose_placeholder(:credential), do: "My GitHub token, for gh and the API"
  defp purpose_placeholder(:network), do: "The production network, through the company VPN"
end
