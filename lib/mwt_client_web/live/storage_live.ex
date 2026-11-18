defmodule MWTClientWeb.StorageLive do
  @moduledoc """
  Storage: what MWT keeps for the signed-in identity, what it takes on
  this machine, and for how long (docs/storage.md).

    * **What you made** - notes, diagrams, flash cards and the small state
      the apps keep whole: counted and measured, never removed by a rule.
    * **What is kept for a while** - every kind with a retention rule of
      its own (`MWTClient.Storage.Retention`): what it holds, its rule, a
      way to change it, back to its default, and to clear the kind.
    * **Files** - the two databases, the space free inside them, and what
      to do with them: compact, back up, check, apply the rules now.
    * **The VM** - its disks, the copies of Home, the rules for those and
      for image builds, and giving back the space the VM deleted.

  Measuring reads every page of both databases (`MWTClient.Storage.Usage`),
  so it runs in the background, as do the actions that take a while.
  """
  use MWTClientWeb, :live_view

  alias MWTClient.Accounts
  alias MWTClient.Sandbox
  alias MWTClient.Storage.Backups
  alias MWTClient.Storage.Janitor
  alias MWTClient.Storage.Maintenance
  alias MWTClient.Storage.Retention
  alias MWTClient.Storage.Usage

  @made [
    {"notes", "Notes", "hero-document-text"},
    {"diagrams", "Diagrams", "hero-square-3-stack-3d"},
    {"flashcards", "Flash cards", "hero-rectangle-stack"},
    {"documents", "Saved state", "hero-cog-6-tooth"}
  ]

  @vm_kinds ~w(vm_snapshots vm_images)

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username

    {:ok,
     socket
     |> assign(:page_title, "Storage")
     |> assign(:username, username)
     |> assign(:made, @made)
     |> assign(:kinds, Enum.reject(Retention.kinds(), &(&1.key in @vm_kinds)))
     |> assign(:vm_kinds, Enum.filter(Retention.kinds(), &(&1.key in @vm_kinds)))
     |> assign(:rules, Retention.rules(username))
     |> assign(:editing, nil)
     |> assign(:rule_form, nil)
     |> assign(:confirm, nil)
     |> assign(:working, nil)
     |> assign(:result, nil)
     |> assign(:usage, nil)
     |> assign(:space, nil)
     |> assign(:data_dir, Accounts.dir(username))
     |> assign(:last_backup, username |> Backups.list() |> List.first())
     |> measure()
     |> look_at_vm()}
  end

  @impl true
  def handle_event("edit_rule", %{"key" => key}, socket) do
    rule = Map.fetch!(socket.assigns.rules, key)
    params = Map.new(rule, fn {field, value} -> {Atom.to_string(field), form_value(value)} end)

    {:noreply,
     assign(socket, editing: key, rule_form: to_form(params, as: :rule, id: "rule-form-#{key}"))}
  end

  def handle_event("cancel_rule", _params, socket),
    do: {:noreply, assign(socket, editing: nil, rule_form: nil)}

  def handle_event("save_rule", %{"key" => key, "rule" => params}, socket) do
    case Retention.put(socket.assigns.username, key, params) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(editing: nil, rule_form: nil)
         |> assign(:rules, Retention.rules(socket.assigns.username))
         |> put_flash(:info, "#{Retention.kind(key).label}: rule saved.")}

      {:error, errors} ->
        form =
          to_form(params,
            as: :rule,
            id: "rule-form-#{key}",
            errors: for({field, message} <- errors, do: {field, {message, []}}),
            action: :validate
          )

        {:noreply, assign(socket, :rule_form, form)}
    end
  end

  def handle_event("reset_rule", %{"key" => key}, socket) do
    :ok = Retention.reset(socket.assigns.username, key)

    {:noreply,
     socket
     |> assign(editing: nil, rule_form: nil)
     |> assign(:rules, Retention.rules(socket.assigns.username))
     |> put_flash(:info, "#{Retention.kind(key).label}: back to its default.")}
  end

  def handle_event("clear", %{"key" => key}, socket) when is_binary(key),
    do: {:noreply, assign(socket, :confirm, {:clear, key})}

  def handle_event("delete_snapshot", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :confirm, {:snapshot, id})}

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("confirm", _params, %{assigns: %{confirm: {:clear, key}}} = socket) do
    true = key in Maintenance.clearable()
    :ok = Maintenance.clear(socket.assigns.username, key)

    {:noreply,
     socket
     |> assign(:confirm, nil)
     |> put_flash(:info, "#{Retention.kind(key).label}: cleared.")
     |> measure()}
  end

  def handle_event("confirm", _params, %{assigns: %{confirm: {:snapshot, id}}} = socket) do
    socket = assign(socket, :confirm, nil)

    case Sandbox.delete_snapshot(socket.assigns.username, id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Copy of Home deleted.") |> look_at_vm()}
      {:error, :not_found} -> {:noreply, look_at_vm(socket)}
    end
  end

  def handle_event("confirm", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("run", %{"action" => action}, %{assigns: %{working: nil}} = socket)
      when action in ~w(compact backup check sweep) do
    username = socket.assigns.username

    {:noreply,
     socket
     |> assign(:working, action)
     |> assign(:result, nil)
     |> start_async(:action, fn -> {action, run(action, username)} end)}
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  def handle_event("reclaim", _params, socket) do
    case Sandbox.reclaim_space(socket.assigns.username) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Reclaiming the VM's disk space…") |> look_at_vm()}

      {:error, :running} ->
        {:noreply, put_flash(socket, :error, "Stop the VM first: its disks are in use.")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "The VM is busy. Try again once it is done.")}

      {:error, {:needs, tools}} ->
        {:noreply,
         put_flash(socket, :error, "Install #{Enum.join(tools, ", ")} (e2fsprogs) first.")}
    end
  end

  @impl true
  def handle_async(:usage, {:ok, usage}, socket), do: {:noreply, assign(socket, :usage, usage)}

  def handle_async(:usage, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :usage, {:error, inspect(reason)})}

  def handle_async(:space, {:ok, space}, socket) do
    # While the VM's disks are being reclaimed, look again shortly.
    if space[:busy], do: Process.send_after(self(), :look_at_vm, 2_000)
    {:noreply, assign(socket, :space, space)}
  end

  def handle_async(:space, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :space, :none)}

  def handle_async(:action, {:ok, {action, result}}, socket) do
    {:noreply,
     socket
     |> assign(working: nil, result: {action, result})
     |> assign(:last_backup, socket.assigns.username |> Backups.list() |> List.first())
     |> measure()}
  end

  def handle_async(:action, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:working, nil)
     |> put_flash(:error, "That didn't finish: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(:look_at_vm, socket), do: {:noreply, look_at_vm(socket)}

  defp measure(socket) do
    username = socket.assigns.username
    start_async(socket, :usage, fn -> Usage.summary(username) end)
  end

  defp look_at_vm(socket) do
    username = socket.assigns.username

    start_async(socket, :space, fn ->
      try do
        Sandbox.space(username)
      catch
        :exit, _locked -> :none
      end
    end)
  end

  defp run("compact", username), do: Maintenance.compact(username)
  defp run("backup", username), do: Backups.create(username)
  defp run("check", username), do: Maintenance.check(username)
  defp run("sweep", username), do: Janitor.sweep(username)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      notices={@notices}
      update={@update}
      sandbox_waiting={@sandbox_waiting}
      notifications={@notifications}
      places={@places}
    >
      <div class="flex min-h-0 flex-1 justify-center overflow-y-auto p-6">
        <div class="w-full max-w-4xl py-2">
          <header class="mb-6 flex items-start gap-3">
            <span class="flex size-9 shrink-0 items-center justify-center rounded-lg border border-line bg-panel text-accent">
              <.icon name="hero-circle-stack" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h1 class="text-lg font-semibold tracking-tight">Storage</h1>
              <p class="text-[13px] text-muted">
                What MWT keeps for {@username}, what it takes on this machine, and for how long.
                Everything is encrypted with a key only your password opens.
              </p>
            </div>
            <div :if={is_map(@usage)} id="storage-total" class="text-right">
              <p class="text-lg font-semibold tabular-nums">{bytes(total(@usage))}</p>
              <p class="text-[11px] text-faint">on this machine, the VM aside</p>
            </div>
          </header>

          <div class="flex flex-col gap-4">
            <.section id="storage-made" icon="hero-sparkles" title="What you made">
              <:note>No rule ever removes these. Delete them where you made them.</:note>
              <div class="grid gap-2 sm:grid-cols-4">
                <div
                  :for={{key, label, icon} <- @made}
                  id={"made-#{key}"}
                  class="rounded-lg border border-line-soft bg-deep/40 px-3 py-2.5"
                >
                  <p class="flex items-center gap-1.5 text-[11px] font-medium text-muted">
                    <.icon name={icon} class="size-3.5" /> {label}
                  </p>
                  <p class="mt-1 text-sm font-semibold tabular-nums">
                    {measured(@usage, key, :items)}
                  </p>
                  <p class="text-[11px] text-faint tabular-nums">{measured(@usage, key, :bytes)}</p>
                </div>
              </div>
            </.section>

            <.section id="storage-kept" icon="hero-clock" title="What is kept for a while">
              <:note>
                Each kind has a rule of its own, applied a minute after you sign in and every hour.
                What a rule removes frees room inside the databases for what comes next; Compact gives it back to the disk.
              </:note>
              <div
                :if={is_map(@usage) and @usage.not_imported != %{}}
                id="storage-not-imported"
                class="mb-3 rounded-lg border border-warn/40 bg-warn-soft/30 px-3 py-2 text-[12px]"
              >
                <p class="font-medium text-warn-strong">
                  Some records from before couldn't be imported
                </p>
                <p :for={{file, failed} <- @usage.not_imported} class="mt-1 text-[11px] text-muted">
                  {failed.count} of {file}: kept, sealed with your password, in <span class="font-mono">legacy/{failed.kept}</span>. The first failed with: {String.slice(
                    failed.why,
                    0,
                    160
                  )}
                </p>
              </div>
              <ul class="divide-y divide-line-soft">
                <.kind_row
                  :for={kind <- @kinds}
                  kind={kind}
                  rule={@rules[kind.key]}
                  usage={@usage}
                  editing={@editing}
                  rule_form={@rule_form}
                  confirm={@confirm}
                  clearable
                />
              </ul>
            </.section>

            <.section id="storage-files" icon="hero-server-stack" title="Files">
              <div class="mb-3 grid gap-2 sm:grid-cols-2">
                <div
                  :for={{name, label} <- [library: "library.db", journal: "journal.db"]}
                  id={"file-#{name}"}
                  class="rounded-lg border border-line-soft bg-deep/40 px-3 py-2.5"
                >
                  <p class="font-mono text-[11px] text-muted">{label}</p>
                  <p class="mt-1 text-sm font-semibold tabular-nums">
                    {file_bytes(@usage, name)}
                  </p>
                  <p class="text-[11px] text-faint tabular-nums">{file_free(@usage, name)}</p>
                </div>
              </div>
              <div class="flex flex-wrap gap-2">
                <.button
                  :for={
                    {action, label, icon} <- [
                      {"compact", "Compact", "hero-arrows-pointing-in"},
                      {"backup", "Back up now", "hero-archive-box-arrow-down"},
                      {"check", "Check", "hero-shield-check"},
                      {"sweep", "Apply the rules now", "hero-sparkles"}
                    ]
                  }
                  id={"run-#{action}"}
                  phx-click="run"
                  phx-value-action={action}
                  disabled={@working != nil}
                >
                  <.icon
                    name={if(@working == action, do: "hero-arrow-path", else: icon)}
                    class={["size-3.5", @working == action && "motion-safe:animate-spin"]}
                  />
                  {label}
                </.button>
              </div>
              <.result :if={@result} result={@result} />
              <dl class="mt-4 grid gap-x-4 gap-y-1 text-[11px] sm:grid-cols-[auto_1fr]">
                <dt class="text-faint">Where it is</dt>
                <dd id="storage-dir" class="select-all break-all font-mono text-muted">
                  {@data_dir}
                </dd>
                <dt class="text-faint">Last backup</dt>
                <dd id="storage-last-backup" class="text-muted">
                  {if @last_backup, do: date(@last_backup.at), else: "None yet"}
                </dd>
              </dl>
            </.section>

            <.section id="storage-vm" icon="hero-cpu-chip" title="The VM">
              <%= case @space do %>
                <% nil -> %>
                  <p class="text-xs text-muted">Looking at the VM's disks…</p>
                <% :none -> %>
                  <p id="vm-none" class="text-xs text-muted">The agent sandbox isn't running.</p>
                <% space -> %>
                  <.vm_space space={space} confirm={@confirm} />
              <% end %>
              <ul class="mt-3 divide-y divide-line-soft border-t border-line-soft">
                <.kind_row
                  :for={kind <- @vm_kinds}
                  kind={kind}
                  rule={@rules[kind.key]}
                  usage={nil}
                  editing={@editing}
                  rule_form={@rule_form}
                  confirm={@confirm}
                  clearable={false}
                />
              </ul>
            </.section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :note
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section id={@id} class="rounded-xl border border-line bg-panel">
      <div class="flex h-10 items-center gap-2 border-b border-line-soft px-4">
        <.icon name={@icon} class="size-4 text-accent" />
        <h2 class="text-[13px] font-semibold">{@title}</h2>
      </div>
      <div class="p-4">
        <p :for={note <- @note} class="mb-3 text-[11px] leading-relaxed text-muted">
          {render_slot(note)}
        </p>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :kind, :map, required: true
  attr :rule, :map, required: true
  attr :usage, :any, required: true
  attr :editing, :string, default: nil
  attr :rule_form, :any, default: nil
  attr :confirm, :any, default: nil
  attr :clearable, :boolean, default: false

  defp kind_row(assigns) do
    assigns = assign(assigns, :changed?, assigns.rule != assigns.kind.default)

    ~H"""
    <li id={"kind-#{@kind.key}"} class="py-3 first:pt-0 last:pb-0">
      <div class="flex flex-wrap items-start gap-3">
        <div class="min-w-0 flex-1">
          <p class="flex items-center gap-2 text-[13px] font-medium">
            {@kind.label}
            <span
              :if={@changed?}
              id={"kind-#{@kind.key}-changed"}
              class="rounded-full border border-accent/30 bg-accent-soft/40 px-1.5 text-[10px] font-medium text-accent-strong"
            >
              Changed
            </span>
          </p>
          <p class="text-[11px] text-muted">{@kind.about}</p>
          <p id={"kind-#{@kind.key}-rule"} class="mt-1 text-[11px] text-ink">
            <.icon name="hero-clock-micro" class="size-3 text-faint" /> {Retention.describe(
              @rule,
              off(@kind)
            )}
          </p>
          <p :if={@changed?} class="text-[10px] text-faint">
            Default: {Retention.describe(@kind.default, off(@kind))}
          </p>
        </div>
        <div :if={@usage != nil} class="w-36 text-right text-[11px] tabular-nums">
          <p class="font-medium text-ink">{measured(@usage, @kind.key, :items)}</p>
          <p class="text-faint">{measured(@usage, @kind.key, :bytes)}</p>
          <p class="text-faint">{measured(@usage, @kind.key, :oldest)}</p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <.button
            :if={@editing != @kind.key}
            variant="ghost"
            id={"edit-#{@kind.key}"}
            phx-click="edit_rule"
            phx-value-key={@kind.key}
          >
            <.icon name="hero-pencil-square" class="size-3.5" /> Rule
          </.button>
          <.button
            :if={@clearable}
            variant="ghost"
            id={"clear-#{@kind.key}"}
            phx-click="clear"
            phx-value-key={@kind.key}
            class="hover:text-bad"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </.button>
        </div>
      </div>

      <div
        :if={@confirm == {:clear, @kind.key}}
        id={"confirm-clear-#{@kind.key}"}
        class="mt-2 flex flex-wrap items-center gap-2 rounded-lg border border-bad/30 bg-bad-soft/30 px-3 py-2 text-[12px]"
      >
        <span class="flex-1">Remove every one of {String.downcase(@kind.label)}? This can't be undone.</span>
        <.button variant="danger" id={"confirm-clear-#{@kind.key}-yes"} phx-click="confirm">
          Remove them
        </.button>
        <.button variant="ghost" phx-click="cancel_confirm">Keep them</.button>
      </div>

      <.form
        :if={@editing == @kind.key and @rule_form}
        for={@rule_form}
        id={"rule-form-#{@kind.key}"}
        phx-submit="save_rule"
        class="mt-3 rounded-lg border border-line-soft bg-deep/40 p-3"
      >
        <input type="hidden" name="key" value={@kind.key} />
        <div class="grid gap-3 sm:grid-cols-2">
          <.limit
            :for={field <- @kind.fields}
            field={field}
            form={@rule_form}
            default={@kind.default}
          />
        </div>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <.button variant="primary" type="submit" id={"save-#{@kind.key}"}>Save</.button>
          <.button type="button" phx-click="cancel_rule">Cancel</.button>
          <.button
            :if={@changed?}
            type="button"
            variant="ghost"
            id={"reset-#{@kind.key}"}
            phx-click="reset_rule"
            phx-value-key={@kind.key}
          >
            Back to the default
          </.button>
        </div>
      </.form>
    </li>
    """
  end

  attr :field, :atom, required: true
  attr :form, :any, required: true
  attr :default, :map, required: true

  defp limit(%{field: :monthly} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@form[:monthly]}
        type="checkbox"
        label="Past the daily ones, keep one a month (else none)"
      />
    </div>
    """
  end

  defp limit(assigns) do
    assigns = assign(assigns, :about, limit_about(assigns.field))

    ~H"""
    <div>
      <.input
        field={@form[@field]}
        type="number"
        min="1"
        label={@about.label}
        placeholder="off"
      />
      <p class="mt-1 text-[10px] text-faint">
        {@about.hint} Default: {limit_default(@default[@field], @about.unit)}.
      </p>
    </div>
    """
  end

  attr :result, :any, required: true

  defp result(assigns) do
    ~H"""
    <div
      id="storage-result"
      class="mt-3 rounded-lg border border-line-soft bg-deep/40 px-3 py-2 text-[12px] text-muted"
    >
      {result_text(@result)}
    </div>
    """
  end

  attr :space, :map, required: true
  attr :confirm, :any, default: nil

  defp vm_space(assigns) do
    ~H"""
    <div id="vm-space">
      <div class="mb-3 grid gap-2 sm:grid-cols-3">
        <div
          :for={disk <- @space.disks}
          id={"vm-disk-#{disk.name}"}
          class="rounded-lg border border-line-soft bg-deep/40 px-3 py-2.5"
        >
          <p class="text-[11px] font-medium capitalize text-muted">{disk.name}</p>
          <p class="mt-1 text-sm font-semibold tabular-nums">{bytes(disk.used)}</p>
          <p class="text-[11px] text-faint tabular-nums">of {bytes(disk.size)}</p>
        </div>
      </div>
      <p :if={@space.disks == []} class="mb-3 text-xs text-muted">The VM has no disks yet.</p>

      <div class="flex flex-wrap items-center gap-2">
        <.button
          id="reclaim"
          phx-click="reclaim"
          disabled={@space.status != :stopped or @space.busy != nil or @space.disks == []}
        >
          <.icon name="hero-arrow-uturn-down" class="size-3.5" /> Reclaim disk space
        </.button>
        <span class="text-[11px] text-muted">
          <%= cond do %>
            <% @space.busy -> %>
              {@space.busy}
            <% @space.status != :stopped -> %>
              Stop the VM first: this checks each disk and gives back what the VM deleted.
            <% true -> %>
              Checks each disk and gives back the room the VM's deleted files still hold.
          <% end %>
        </span>
      </div>
      <p :if={@space.reclaimed} id="vm-reclaimed" class="mt-2 text-[11px] text-muted">
        Last time: {reclaimed_text(@space.reclaimed)}
      </p>

      <div :if={@space.snapshots != []} class="mt-4">
        <p class="mb-1.5 text-[11px] font-medium text-muted">Copies of Home</p>
        <ul class="divide-y divide-line-soft rounded-lg border border-line-soft">
          <li
            :for={snapshot <- @space.snapshots}
            id={"snapshot-#{snapshot.id}"}
            class="flex items-center gap-3 px-3 py-2 text-[12px]"
          >
            <span class="flex-1 font-mono text-[11px]">{snapshot.tag || snapshot.id}</span>
            <span class="text-[11px] text-faint">{date(snapshot.taken_at)}</span>
            <span class="w-20 text-right text-[11px] tabular-nums text-muted">{bytes(snapshot.used)}</span>
            <%= if @confirm == {:snapshot, snapshot.id} do %>
              <.button variant="danger" id={"confirm-snapshot-#{snapshot.id}"} phx-click="confirm">
                Delete it
              </.button>
              <.button variant="ghost" phx-click="cancel_confirm">Keep</.button>
            <% else %>
              <.button
                variant="ghost"
                id={"delete-snapshot-#{snapshot.id}"}
                phx-click="delete_snapshot"
                phx-value-id={snapshot.id}
                class="hover:text-bad"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </.button>
            <% end %>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp off(kind), do: Map.get(kind, :off, "kept until you remove it")

  defp limit_about(:days), do: %{label: "Keep for (days)", hint: "Older ones go.", unit: :days}
  defp limit_about(:gb), do: %{label: "At most (GB)", hint: "The oldest go first.", unit: :gb}
  defp limit_about(:count), do: %{label: "Keep the newest", hint: "Older ones go.", unit: :count}

  defp limit_about(:every_days),
    do: %{label: "Every version for (days)", hint: "Then thinned.", unit: :days}

  defp limit_about(:daily_days),
    do: %{label: "One a day until (days)", hint: "Then one a month, or none.", unit: :days}

  defp limit_about(:most),
    do: %{label: "At most, per item", hint: "The oldest go first.", unit: :count}

  defp limit_default(nil, _unit), do: "off"
  defp limit_default(value, :days), do: "#{value} days"
  defp limit_default(value, :gb), do: "#{value} GB"
  defp limit_default(value, :count), do: "#{value}"

  defp form_value(nil), do: ""
  defp form_value(value) when is_boolean(value), do: to_string(value)
  defp form_value(value), do: Integer.to_string(value)

  defp measured(nil, _key, field) when field in [:items, :bytes, :oldest], do: "…"
  defp measured({:error, _reason}, _key, _field), do: "?"

  defp measured(usage, key, :items),
    do: usage.kinds |> Map.fetch!(key) |> Map.fetch!(:items) |> count()

  defp measured(usage, key, :bytes),
    do: usage.kinds |> Map.fetch!(key) |> Map.fetch!(:bytes) |> bytes()

  defp measured(usage, key, :oldest) do
    case Map.fetch!(usage.kinds, key).oldest do
      nil -> ""
      at -> "since " <> date(at)
    end
  end

  defp file_bytes(usage, name) when is_map(usage), do: bytes(usage.files[name].bytes)
  defp file_bytes(_usage, _name), do: "…"

  defp file_free(usage, name) when is_map(usage) do
    file = usage.files[name]
    "#{bytes(file.free)} free inside, for what comes next · write-ahead log #{bytes(file.wal)}"
  end

  defp file_free(_usage, _name), do: ""

  defp total(usage) do
    files = usage.files |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum()
    files + usage.kinds["backups"].bytes + usage.kinds["legacy"].bytes
  end

  defp result_text({"compact", sizes}) do
    Enum.map_join(sizes, " · ", fn {name, {before, now}} ->
      "#{name}.db #{bytes(before)} → #{bytes(now)}"
    end)
  end

  defp result_text({"backup", {:ok, backup}}),
    do: "Backed up as #{backup.name} (#{bytes(backup.bytes)})."

  defp result_text({"backup", {:error, message}}), do: "The backup failed: #{message}"

  defp result_text({"check", checks}) do
    Enum.map_join(checks, " · ", fn
      {name, :ok} -> "#{name}.db is sound"
      {name, {:error, problems}} -> "#{name}.db: #{Enum.join(Enum.take(problems, 3), "; ")}"
    end)
  end

  defp result_text({"sweep", removed}) do
    case Enum.filter(removed, fn {_key, count} -> count > 0 end) do
      [] ->
        "Nothing was past its rule."

      gone ->
        Enum.map_join(gone, " · ", fn {key, count} ->
          "#{Retention.kind(key).label}: #{count} removed"
        end)
    end
  end

  defp reclaimed_text(results) do
    freed = results |> Enum.map(fn {_disk, r} -> max(r.before - r.after, 0) end) |> Enum.sum()
    "#{bytes(freed)} given back"
  end

  defp count(0), do: "None"
  defp count(1), do: "1 item"
  defp count(n), do: "#{n} items"

  defp bytes(nil), do: "—"
  defp bytes(n) when n < 1024, do: "#{n} B"
  defp bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / (1024 * 1024), 1)} MB"
  defp bytes(n), do: "#{Float.round(n / (1024 * 1024 * 1024), 2)} GB"

  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y")
end
