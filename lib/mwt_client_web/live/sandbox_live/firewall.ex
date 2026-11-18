defmodule MWTClientWeb.SandboxLive.Firewall do
  @moduledoc """
  The Firewall page (`MWTClient.Sandbox.Firewall`), in three parts:

    * the isolation card, with the one *VM isolated* switch: the firewall
      turns it on when a rule isolates, you turn it on or off yourself.
      While isolated: who isolated it and why, what came before, and the
      grants releasing turns back on. Turning off an isolation the firewall
      made asks first (`release_dialog/1`); your own just ends. The past
      isolations fold under it;
    * the rules, by group, each in a line with its action;
    * what it found lately, and the lists, a tab each.

  Also the banner every other sandbox page shows while the VM is isolated.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.Firewall

  @actions [isolate: "Isolate", block: "Block", alert: "Alert", off: "Off"]

  @list_words %{
    trusted:
      {"Trusted", "Trusted destinations",
       "The rules on destinations (blocked services, DNS names, uploads, ports, scanning) spare these. A placeholder sent elsewhere is never spared.",
       "One name or address a line: example.com covers it and every name under it."},
    blocked:
      {"Blocked", "Blocked services",
       "Paste sites, file drops, request catchers, tunnels into the VM and mining pools: looked up or connected to, they set off Blocked services.",
       "One name or address a line: example.com covers it and every name under it."},
    protected:
      {"Protected", "Protected paths",
       "A command the agent writes, to run on your machine, that names one of these sets off Command touching secrets. Your own saved commands are never checked.",
       "One path or part of one a line, matched anywhere in the command's text, in any case."},
    mints:
      {"Endpoints", "Credential endpoints",
       "Hosts and paths whose answers are credentials: token exchanges, key creation, a registry's token. A request that would carry a grant's real value to one sets off Minting a credential.",
       "One host, or host/path, a line: example.com covers it and every name under it; * stands for one segment of the path, which may go on after the entry's."}
  }

  @findings_shown 8

  attr :view, :map, required: true, doc: "`MWTClient.Sandbox.firewall/1`"
  attr :drafts, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :releasing, :boolean, default: false, doc: "the release dialog is open"
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    assigns = assign(assigns, firewall: assigns.view.firewall)

    ~H"""
    <.page_header
      id="firewall-header"
      title="Firewall"
      subtitle="Watches what the VM does through MWT and isolates it on the first sign of trouble."
    >
      <:help>
        It hears DNS, every connection and tunnel through the proxy, credential use, the agent's asks and the commands it writes, MWT's tools, and the VM's busiest processes. Rules go by behaviour and by the lists, not by signatures of known attacks.
      </:help>
      <:actions>
        <span class="text-[11px] text-muted">Watching</span>
        <.segmented
          id="firewall-enabled"
          options={[{"true", "On"}, {"false", "Off"}]}
          value={to_string(@firewall.enabled)}
          event="firewall_enabled"
          confirm={
            %{
              "false" =>
                "Turn the firewall off? Nothing is watched or isolated until you turn it on again."
            }
          }
        />
      </:actions>
    </.page_header>

    <.isolation
      firewall={@firewall}
      refused={@view.refused}
      restorable={Map.get(@view, :restorable, [])}
      vm={@vm}
      now={@now}
    />

    <div class="grid items-start gap-5 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
      <.rules firewall={@firewall} />

      <div class="space-y-5">
        <.findings findings={@view.findings} now={@now} />
        <.lists firewall={@firewall} drafts={@drafts} errors={@errors} />
      </div>
    </div>

    <.release_dialog
      :if={@releasing and not is_nil(@firewall.isolated)}
      incident={@firewall.isolated}
      restorable={Map.get(@view, :restorable, [])}
    />
    """
  end

  ## The isolation card

  attr :firewall, Firewall, required: true
  attr :refused, :integer, required: true
  attr :restorable, :list, default: [], doc: "the grants releasing turns back on, by name"
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp isolation(assigns) do
    incident = assigns.firewall.isolated

    assigns =
      assign(assigns,
        incident: incident,
        past: Enum.filter(assigns.firewall.incidents, & &1.released)
      )

    ~H"""
    <section
      id="firewall-isolation"
      class={[
        "mb-5 overflow-hidden rounded-xl border bg-panel transition-colors",
        if(@incident, do: "border-bad/50 shadow-sm", else: "border-line")
      ]}
    >
      <div class={[
        "flex flex-wrap items-center gap-x-4 gap-y-3 px-5 py-4",
        @incident && "bg-bad-soft/40"
      ]}>
        <span class={[
          "flex size-10 shrink-0 items-center justify-center rounded-xl border",
          cond do
            @incident -> "border-bad bg-bad text-white"
            not @firewall.enabled -> "border-warn/40 bg-warn-soft/50 text-warn-strong"
            true -> "border-ok/35 bg-ok-soft/50 text-ok-strong"
          end
        ]}>
          <.icon
            name={
              if(@incident || not @firewall.enabled,
                do: "hero-shield-exclamation",
                else: "hero-shield-check"
              )
            }
            class="size-5"
          />
        </span>

        <div class="min-w-0 flex-1 basis-72">
          <%= cond do %>
            <% @incident -> %>
              <h2 id="firewall-isolation-title" class="text-[15px] font-semibold text-bad">
                VM isolated by {Firewall.isolated_by(@incident)}
              </h2>
              <p
                :if={@incident.by == :firewall}
                id="firewall-incident-summary"
                class="mt-1 text-[13px] leading-5 text-ink"
              >
                {@incident.summary}
              </p>
              <p class="mt-1 text-[11px] text-muted">
                <.clock id="firewall-incident-since" since={@incident.at} now={@now} />
                · {@refused} refused since · nothing it sends leaves through MWT; the VM keeps running
              </p>
            <% not @firewall.enabled -> %>
              <h2 id="firewall-isolation-title" class="text-[15px] font-semibold text-ink">
                Not isolated
              </h2>
              <p id="firewall-off" class="mt-0.5 text-xs leading-5 text-warn-strong">
                The firewall is off: nothing is watched, so nothing isolates the VM but you, with the switch.
              </p>
            <% true -> %>
              <h2 id="firewall-isolation-title" class="text-[15px] font-semibold text-ink">
                Not isolated
              </h2>
              <p class="mt-0.5 text-xs leading-5 text-muted">
                The firewall turns the switch on at the first sign of trouble; you can too. While it is on, nothing the VM sends leaves through MWT.
              </p>
          <% end %>
        </div>

        <div class="flex items-center gap-3">
          <.button
            :if={@incident && @vm.status == :running && is_nil(@vm.busy)}
            type="button"
            id="firewall-stop-vm"
            variant="danger"
            phx-click="stop_vm"
            title="Stop the VM; it stays isolated"
          >
            <.icon name="hero-stop-micro" class="size-3.5" /> Stop the VM
          </.button>
          <label
            for="firewall-isolated"
            class={[
              "flex cursor-pointer items-center gap-2.5 rounded-lg border px-3 py-2",
              if(@incident, do: "border-bad/40 bg-panel", else: "border-line bg-deep/60")
            ]}
          >
            <span class={[
              "text-[13px] font-medium",
              if(@incident, do: "text-bad", else: "text-ink")
            ]}>
              VM isolated
            </span>
            <.switch
              id="firewall-isolated"
              on={not is_nil(@incident)}
              label={if(@incident, do: "Release the VM", else: "Isolate the VM")}
              tone={:bad}
              phx-click={JS.push("firewall_isolated", value: %{value: to_string(is_nil(@incident))})}
            />
          </label>
        </div>
      </div>

      <div :if={@incident} class="space-y-3 border-t border-bad/20 px-5 py-3">
        <p id="firewall-restorable" class="flex items-start gap-2 text-[11px] leading-4 text-muted">
          <.icon name="hero-key-micro" class="mt-px size-3.5 shrink-0 text-faint" />
          <span>{back_words(@restorable)}</span>
        </p>

        <details
          id="firewall-incident-before"
          open={@incident.by == :firewall}
          phx-mounted={JS.ignore_attributes(["open"])}
          class="group"
        >
          <summary class="flex cursor-pointer list-none items-center gap-1.5 text-[11px] font-medium uppercase tracking-wide text-muted hover:text-ink">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3.5 transition-transform group-open:rotate-90"
            /> What came before · {length(@incident.events)}
          </summary>
          <p :if={@incident.events == []} class="mt-2 pl-5 text-[11px] text-faint">
            Nothing logged before it.
          </p>
          <ol
            :if={@incident.events != []}
            id="firewall-incident-events"
            class="mt-2 max-h-64 space-y-1 overflow-y-auto pl-5"
          >
            <li
              :for={event <- @incident.events}
              id={"firewall-incident-event-#{event.id}"}
              class="flex items-center gap-2 text-[11px]"
            >
              <span class="w-16 shrink-0 font-mono text-faint">
                {Calendar.strftime(event.at, "%H:%M:%S")}
              </span>
              <.outcome_badge outcome={event.outcome} />
              <span class="min-w-0 flex-1 truncate text-ink" title={event.summary}>
                {event.summary}
              </span>
              <span :if={event.host} class="shrink-0 truncate font-mono text-faint">
                {event.host}{if event.port, do: ":#{event.port}"}
              </span>
            </li>
          </ol>
        </details>
      </div>

      <details
        :if={@past != []}
        id="firewall-incidents"
        phx-mounted={JS.ignore_attributes(["open"])}
        class={["group border-t", if(@incident, do: "border-bad/20", else: "border-line-soft")]}
      >
        <summary class="flex cursor-pointer list-none items-center gap-1.5 px-5 py-2.5 text-[11px] text-muted hover:text-ink">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 transition-transform group-open:rotate-90"
          />
          <span class="font-medium">
            {length(@past)} past {if length(@past) == 1, do: "isolation", else: "isolations"}
          </span>
          <span class="truncate text-faint">
            · the last by {Firewall.isolated_by(hd(@past))},
            <.clock id="firewall-incidents-last" since={hd(@past).at} now={@now} />
          </span>
        </summary>
        <ul class="divide-y divide-line-soft border-t border-line-soft">
          <li
            :for={incident <- @past}
            id={"firewall-incident-#{incident.id}"}
            class="flex items-baseline gap-3 px-5 py-2"
          >
            <span class="min-w-0 flex-1">
              <span class="block text-xs font-medium text-ink">
                By {Firewall.isolated_by(incident)}
              </span>
              <span
                :if={incident.by == :firewall}
                class="block truncate text-[11px] leading-4 text-muted"
                title={incident.summary}
              >
                {incident.summary}
              </span>
            </span>
            <span class="shrink-0 rounded bg-deep px-1.5 py-px text-[10px] font-medium text-muted">
              {released_words(incident.released)}
            </span>
            <span class="w-20 shrink-0 text-right text-[10px] text-faint">
              <.clock id={"firewall-incident-at-#{incident.id}"} since={incident.at} now={@now} />
            </span>
          </li>
        </ul>
      </details>
    </section>
    """
  end

  defp back_words([]), do: "No grant was on when it was isolated: turn on what you want again."

  defp back_words(names),
    do:
      "Releasing turns back on, for the time they have left, the grants that were on: " <>
        Enum.join(names, ", ") <> "."

  defp released_words(:release), do: "Released"
  defp released_words(:trust), do: "Released, trusted"

  ## Releasing an isolation the firewall made

  attr :incident, :map, required: true
  attr :restorable, :list, required: true

  defp release_dialog(assigns) do
    assigns = assign(assigns, form: to_form(%{"trust" => "false"}, as: :release))

    ~H"""
    <div
      id="firewall-release-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="firewall-release-title"
      phx-window-keydown="cancel_firewall_release"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_firewall_release"></div>
      <.form
        for={@form}
        id="firewall-release-form"
        phx-submit="firewall_release"
        class="relative w-full max-w-md overflow-hidden rounded-xl border border-bad/40 bg-panel shadow-2xl shadow-black/30 dark:shadow-black/60"
      >
        <div class="flex items-start gap-3 border-b border-line-soft bg-bad-soft/30 px-5 py-4">
          <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-bad text-white">
            <.icon name="hero-exclamation-triangle" class="size-5" />
          </span>
          <div class="min-w-0">
            <p id="firewall-release-title" class="text-[15px] font-semibold text-ink">
              Release the VM?
            </p>
            <p class="mt-0.5 text-xs leading-5 text-muted">
              The firewall isolated it, not you: {Firewall.rule_name(@incident.rule)}.
            </p>
          </div>
        </div>

        <div class="space-y-3 px-5 py-4">
          <p
            id="firewall-release-summary"
            class="rounded-md border border-line bg-deep px-3 py-2 text-xs leading-5 text-ink"
          >
            {@incident.summary}
          </p>
          <p class="text-xs leading-5 text-muted">
            Releasing doesn't undo what it saw. Whatever did it may still be running in the VM: release it once you know what happened, from what came before and the activity log.
          </p>
          <p class="text-[11px] leading-4 text-muted">{back_words(@restorable)}</p>
          <div
            :if={@incident.host}
            id="firewall-release-trust"
            class="rounded-md border border-line px-3 py-2"
          >
            <.input
              field={@form[:trust]}
              type="checkbox"
              label={"Trust #{@incident.host} from now on"}
            />
            <p class="mt-1 pl-5.5 text-[11px] leading-4 text-faint">
              The rules on destinations spare it. A placeholder sent there is still caught.
            </p>
          </div>
        </div>

        <div class="flex items-center justify-end gap-2 border-t border-line-soft px-5 py-3">
          <.button
            type="button"
            id="firewall-release-cancel"
            phx-click="cancel_firewall_release"
            phx-mounted={JS.focus()}
          >
            Keep it isolated
          </.button>
          <.button type="submit" id="firewall-release-confirm" variant="danger">
            Release
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  ## Rules

  attr :firewall, Firewall, required: true

  defp rules(assigns) do
    assigns = assign(assigns, actions: @actions, action_ids: Keyword.keys(@actions))

    ~H"""
    <.card id="firewall-rules" title="Rules" body_class="">
      <:help>
        Isolate turns the VM isolated switch on: the VM is cut off at once. Block refuses this one use and goes on watching. Alert lets it through, logs it and notifies you once in 10 minutes per rule and destination. Off ignores it. The "?" beside a rule says exactly what sets it off.
      </:help>
      <:actions>
        <span class="text-[11px] text-faint">{count_words(@firewall)}</span>
      </:actions>
      <section
        :for={{group, name} <- Firewall.groups()}
        id={"firewall-group-#{group}"}
        class="border-b border-line-soft last:border-b-0"
      >
        <h3 class="bg-deep/40 px-4 py-1.5 text-[10px] font-semibold uppercase tracking-wider text-muted">
          {name}
        </h3>
        <div class="divide-y divide-line-soft">
          <div
            :for={rule <- Enum.filter(Firewall.rules(), &(&1.group == group))}
            id={"firewall-rule-#{rule.id}"}
            class="flex items-center gap-4 px-4 py-2.5"
          >
            <div class="min-w-0 flex-1">
              <p class="flex items-center gap-1.5 text-[13px] font-medium text-ink">
                <span class="truncate">{rule.name}</span>
                <.help id={"firewall-rule-help-#{rule.id}"} label={"About #{rule.name}"}>
                  {rule.text}
                </.help>
              </p>
              <p class="mt-0.5 truncate text-[11px] text-muted" title={rule.brief}>
                {rule.brief}
              </p>
            </div>
            <.segmented
              id={"firewall-action-#{rule.id}"}
              options={@actions}
              unavailable={@action_ids -- rule.actions}
              even
              value={Firewall.action(@firewall, rule.id)}
              event="firewall_action"
              values={%{"rule" => to_string(rule.id)}}
              tone={:firewall}
            />
          </div>
        </div>
      </section>
    </.card>
    """
  end

  # "8 isolate · 3 block · 3 alert", the actions as set.
  defp count_words(firewall) do
    counts = Enum.frequencies_by(Firewall.rules(), &Firewall.action(firewall, &1.id))

    @actions
    |> Enum.filter(fn {action, _label} -> Map.has_key?(counts, action) end)
    |> Enum.map_join(" · ", fn {action, label} ->
      "#{counts[action]} #{String.downcase(label)}"
    end)
  end

  ## Found lately

  attr :findings, :list, required: true
  attr :now, DateTime, required: true

  defp findings(assigns) do
    assigns = assign(assigns, shown: Enum.take(assigns.findings, @findings_shown))

    ~H"""
    <.card id="firewall-findings" title="Found lately" body_class="">
      <:actions>
        <.link
          patch={~p"/tools/sandbox/activity?group=firewall"}
          id="firewall-findings-all"
          class="text-[11px] text-accent hover:underline"
        >
          All in the activity log
        </.link>
      </:actions>
      <p
        :if={@shown == []}
        id="firewall-findings-empty"
        class="flex items-center gap-2 px-4 py-4 text-xs text-muted"
      >
        <.icon name="hero-shield-check" class="size-4 shrink-0 text-faint" /> Nothing found yet.
      </p>
      <ul :if={@shown != []} class="divide-y divide-line-soft">
        <li
          :for={event <- @shown}
          id={"firewall-finding-#{event.id}"}
          class="flex items-baseline gap-3 px-4 py-2"
        >
          <p class="line-clamp-2 min-w-0 flex-1 text-xs leading-5 text-ink" title={event.summary}>
            {event.summary}
          </p>
          <span class="shrink-0 text-[10px] text-faint">
            <.clock id={"firewall-finding-at-#{event.id}"} since={event.at} now={@now} />
          </span>
        </li>
      </ul>
    </.card>
    """
  end

  ## Lists

  attr :firewall, Firewall, required: true
  attr :drafts, :map, required: true
  attr :errors, :map, required: true

  defp lists(assigns) do
    assigns = assign(assigns, lists: Firewall.lists(), list_words: @list_words)

    ~H"""
    <.card id="firewall-lists" title="Lists" body_class="">
      <:help>
        The rules read these. One entry a line; Save keeps a list as you wrote it, once every line reads.
      </:help>
      <div role="tablist" class="flex gap-1 border-b border-line-soft px-3">
        <button
          :for={{list, index} <- Enum.with_index(@lists)}
          type="button"
          role="tab"
          id={"firewall-list-tab-#{list}"}
          aria-selected={to_string(index == 0)}
          aria-controls={"firewall-list-panel-#{list}"}
          phx-click={select_list(list)}
          class="-mb-px flex cursor-pointer items-center gap-1.5 border-b-2 border-transparent px-2 py-2 text-xs font-medium text-muted transition-colors hover:text-ink aria-selected:border-accent aria-selected:text-ink"
        >
          {elem(@list_words[list], 0)}
          <span class={[
            "rounded px-1 text-[10px] tabular-nums",
            if(@errors[list], do: "bg-bad-soft text-bad", else: "bg-deep text-faint")
          ]}>
            {length(Map.fetch!(@firewall, list))}
          </span>
        </button>
      </div>
      <.list_panel
        :for={{list, index} <- Enum.with_index(@lists)}
        list={list}
        hidden={index != 0}
        entries={Map.fetch!(@firewall, list)}
        draft={@drafts[list]}
        error={@errors[list]}
        words={@list_words[list]}
      />
    </.card>
    """
  end

  # Tabs switch in the browser, so what you typed in one stays while you
  # look at another; the server never needs to know which is open.
  defp select_list(list) do
    JS.add_class("hidden", to: "#firewall-lists [role=tabpanel]")
    |> JS.remove_class("hidden", to: "#firewall-list-panel-#{list}")
    |> JS.set_attribute({"aria-selected", "false"}, to: "#firewall-lists [role=tab]")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#firewall-list-tab-#{list}")
  end

  attr :list, :atom, required: true
  attr :hidden, :boolean, required: true
  attr :entries, :list, required: true
  attr :draft, :string, default: nil
  attr :error, :string, default: nil
  attr :words, :any, required: true

  defp list_panel(assigns) do
    {_tab, title, help, hint} = assigns.words

    assigns =
      assign(assigns,
        title: title,
        help: help,
        hint: hint,
        form:
          to_form(
            %{
              "list" => to_string(assigns.list),
              "text" => assigns.draft || Enum.join(assigns.entries, "\n")
            },
            as: :firewall_list
          )
      )

    ~H"""
    <div
      id={"firewall-list-panel-#{@list}"}
      role="tabpanel"
      aria-labelledby={"firewall-list-tab-#{@list}"}
      class={["p-4", @hidden && "hidden"]}
    >
      <p class="mb-3 text-[11px] leading-4 text-muted">
        <span class="font-semibold text-ink">{@title}.</span> {@help}
      </p>
      <.form
        for={@form}
        id={"firewall-list-form-#{@list}"}
        phx-submit="firewall_list"
        class="space-y-2"
      >
        <input type="hidden" name={@form[:list].name} value={@form[:list].value} />
        <.input
          field={@form[:text]}
          id={"firewall-list-text-#{@list}"}
          type="textarea"
          rows="9"
          spellcheck="false"
          class={[input_classes(), "font-mono text-[11px] leading-5", @error && "border-bad/70"]}
        />
        <p :if={@error} id={"firewall-list-error-#{@list}"} class="text-[11px] text-bad">
          {@error}
        </p>
        <p class="text-[10px] leading-4 text-faint">{@hint}</p>
        <div class="flex items-center gap-2">
          <.button type="submit" id={"firewall-list-save-#{@list}"} variant="primary">
            Save
          </.button>
          <.button
            type="button"
            id={"firewall-list-reset-#{@list}"}
            variant="ghost"
            phx-click="firewall_reset_list"
            phx-value-list={@list}
            data-confirm="Reset this list to its defaults? Your entries go."
          >
            Reset to defaults
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  @doc "The banner every other sandbox page shows while the VM is isolated."
  attr :firewall, :any, required: true

  def banner(assigns) do
    ~H"""
    <.link
      :if={@firewall && @firewall.isolated}
      navigate={~p"/tools/sandbox/firewall"}
      id="firewall-banner"
      class="mb-5 flex items-center gap-3 rounded-lg border border-bad/50 bg-bad-soft/50 px-4 py-2.5 text-xs text-bad transition-colors hover:bg-bad-soft/70"
    >
      <.icon name="hero-shield-exclamation" class="size-4 shrink-0" />
      <span class="min-w-0 flex-1">
        <%= if @firewall.isolated.by == :you do %>
          <span class="font-semibold">You isolated the VM.</span>
        <% else %>
          <span class="font-semibold">The firewall isolated the VM:</span>
          {@firewall.isolated.summary}.
        <% end %>
        Nothing it sends leaves through MWT.
      </span>
      <span class="shrink-0 font-medium underline">Review and release</span>
    </.link>
    """
  end
end
