defmodule MWTClientWeb.SandboxLive.Settings do
  @moduledoc """
  The settings page, in two tabs, with only what you can change:

    * **Runtime** - how the VM runs: the folders it sees, its CPUs, memory
      and disks, how long a request waits for you, VMs inside it, its
      memory (OptMem), and your notes about this machine for agents;
    * **Build** - its image: the name, your Containerfile, MWT's layer, the
      build and the builds kept.

  Each setting carries a "?" that says what it is and when it applies. The
  CPUs and memory show how much of this machine they take, against what
  MWT suggests (`MWTClient.Sandbox.Resources`).
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Image, NestedVirt, Resources}

  @tabs [
    {"runtime", "Runtime", "hero-cpu-chip-micro"},
    {"build", "Build", "hero-cube-micro"}
  ]

  @tab_ids Enum.map(@tabs, &elem(&1, 0))

  # The tabs before there were two, so links to them still land.
  @old_tabs %{
    "general" => "runtime",
    "storage" => "runtime",
    "host" => "runtime",
    "image" => "build"
  }

  # The fields of the size and timing form.
  @vm_fields ~w(cpus memory_gib disk_gib home_gib cache_gib work_gib hold_seconds)a

  @doc "The tab a `tab` query parameter names, Runtime if none or unknown."
  @spec tab(String.t() | nil) :: String.t()
  def tab(id) when id in @tab_ids, do: id
  def tab(id) when is_map_key(@old_tabs, id), do: Map.fetch!(@old_tabs, id)
  def tab(_id), do: "runtime"

  @doc "The settings the size and timing form holds."
  @spec vm_fields() :: [atom()]
  def vm_fields, do: @vm_fields

  attr :tab, :string, default: "runtime"
  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :builds, :list, required: true
  attr :created_ref, :string, default: nil
  attr :memory, :map, required: true
  attr :name_form, :any, required: true
  attr :name_error, :string, default: nil
  attr :tools, :map, required: true
  attr :settings, :any, required: true
  attr :containerfile_form, :any, required: true
  attr :containerfile_error, :string, default: nil
  attr :vm_form, :any, required: true
  attr :vm_errors, :map, required: true
  attr :resources, :map, required: true, doc: "this machine: `host`, `suggested`, `most`"
  attr :share_form, :any, required: true
  attr :share_error, :string, default: nil

  attr :sync, :map,
    default: %{},
    doc:
      "each shared folder's copy in the VM, by path: its status, a sync under way, one due (`MWTClient.Sandbox.Server.ShareSync.view/1`)"

  attr :host, :map, required: true
  attr :host_form, :any, required: true
  attr :host_error, :string, default: nil
  attr :way_form, :any, required: true
  attr :way_error, :string, default: nil

  def page(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <.page_header id="settings-header" title="Settings">
      <:help>
        How the VM runs and how its image is built. Microsandbox can't change mounts or resources on a VM that exists, so most changes here apply when it is recreated; each setting's "?" says when.
      </:help>
    </.page_header>

    <div
      :if={@vm.stale?}
      id="settings-stale"
      class="mb-4 flex flex-wrap items-center gap-3 rounded-xl border border-warn/35 bg-warn-soft/30 px-4 py-2.5"
    >
      <.icon name="hero-arrow-path" class="size-4 text-warn" />
      <p class="flex flex-1 items-center gap-1.5 text-xs text-ink">
        The VM still runs with the previous settings or image.
        <.help id="settings-stale-help" label="About recreating">
          Recreating starts a fresh root filesystem from the current image; you choose what happens to its Home and Cache.
        </.help>
      </p>
      <.button
        id="settings-recreate"
        phx-click="recreate_vm"
        disabled={not is_nil(@vm.busy) or not @image.loaded?}
      >
        Recreate now
      </.button>
    </div>

    <nav
      id="settings-tabs"
      aria-label="Settings sections"
      class="mb-5 flex flex-wrap items-center gap-1 border-b border-line-soft"
    >
      <.link
        :for={{id, label, icon} <- @tabs}
        id={"settings-tab-#{id}"}
        patch={tab_path(id)}
        aria-current={@tab == id && "page"}
        class={[
          "-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-[13px] transition-colors",
          if(@tab == id,
            do: "border-accent font-medium text-ink",
            else: "border-transparent text-muted hover:border-line hover:text-ink"
          )
        ]}
      >
        <.icon
          name={icon}
          class={["size-3.5", if(@tab == id, do: "text-accent", else: "text-faint")]}
        />
        {label}
        <span
          :if={id == "build" and not @image.loaded?}
          class="size-1.5 rounded-full bg-accent"
          title="Not built yet"
        ></span>
      </.link>
    </nav>

    <%= case @tab do %>
      <% "runtime" -> %>
        <.runtime {assigns} />
      <% "build" -> %>
        <.image_tab {assigns} />
    <% end %>
    """
  end

  defp tab_path("runtime"), do: ~p"/tools/sandbox/settings"
  defp tab_path(id), do: ~p"/tools/sandbox/settings?tab=#{id}"

  ## Runtime

  defp runtime(assigns) do
    assigns = assign(assigns, :pick_from, pick_from(assigns.settings.shares))

    ~H"""
    <div class="space-y-5">
      <.card id="settings-shares" title="Shared folders" body_class="">
        <:help>
          What you share here reaches the VM two ways, and nothing of your machine is mounted. Every git repository in it is a project: the Projects page opens it in the VM, with a writable clone in /work whose origin is your repository through MWT, and work comes back as handoffs; nothing of a repository is copied, so a .env or an ignored secrets file in one stays here. Everything else is copied into the VM, one way, and shown there read-only at the same path. A copy changes only when synced: when you add the folder, each time the VM starts, with Sync, after a command you approved ran in it, and when an agent runs mwt sync (the grant Shared folders: sync). The VM never writes to your folders. Adding or removing one needs no recreate. Never shared: your home folder itself, ~/.ssh, ~/.gnupg, ~/.optmem, cloud CLI logins, MWT's own data, a folder inside a repository (share the repository), and folders at a path the VM uses itself (/work, /cache, /root, /mnt). Folders can't sit inside one another.
        </:help>
        <:actions>
          <span class="text-[11px] text-faint">{length(@settings.shares)} shared</span>
          <.share_sync_button
            :if={@settings.shares != []}
            id="shares-sync-all"
            label="Sync all"
            running?={@vm.status == :running}
            busy?={Enum.any?(Map.values(@sync), &(&1.progress != nil))}
          />
        </:actions>
        <ul id="shares" class="divide-y divide-line-soft">
          <li :if={@settings.shares == []}>
            <.empty icon="hero-folder">
              The VM sees no folder of yours yet. Share project folders, one by one.
            </.empty>
          </li>
          <li
            :for={{share, index} <- Enum.with_index(@settings.shares)}
            id={"share-#{index}"}
            class="group/share flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
          >
            <.icon name="hero-folder" class="size-4 shrink-0 text-faint" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-xs font-medium text-ink">{Path.basename(share.path)}</p>
              <p class="truncate font-mono text-[10px] text-faint" title={share.path}>
                {share.path}
              </p>
              <.share_copy
                id={"share-copy-#{index}"}
                entry={@sync[share.path]}
                running?={@vm.status == :running}
              />
            </div>
            <.share_sync_button
              id={"share-sync-#{index}"}
              path={share.path}
              running?={@vm.status == :running}
              busy?={match?(%{progress: progress} when progress != nil, @sync[share.path])}
            />
            <button
              type="button"
              id={"share-remove-#{index}"}
              phx-click="remove_share"
              phx-value-path={share.path}
              title="Stop sharing"
              class="flex size-7 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-bad-soft/40 hover:text-bad"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
        <.form
          for={@share_form}
          id="share-form"
          phx-submit="add_share"
          phx-change="share_changed"
          class="border-t border-line-soft bg-deep/30 px-4 py-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              id="share-pick"
              phx-hook=".PickFolders"
              data-default-path={@pick_from}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-[13px] font-semibold leading-none text-deep transition-all hover:brightness-110 active:scale-[0.98] active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            >
              <.icon name="hero-folder-plus-micro" class="size-3.5" /> Choose folders…
            </button>
            <span class="text-[11px] text-faint">or</span>
            <div class="min-w-48 flex-1">
              <input
                type="text"
                name={@share_form[:path].name}
                id="share-path"
                value={@share_form[:path].value}
                placeholder="type a path: ~/projects/some-repo"
                autocomplete="off"
                spellcheck="false"
                class={[input_classes(), "font-mono text-xs", @share_error && "border-bad/70"]}
              />
            </div>
            <.button type="submit" id="share-add">
              <.icon name="hero-plus-micro" class="size-3.5" /> Share
            </.button>
          </div>
          <p
            :if={@share_error}
            id="share-error"
            class="mt-2 flex items-start gap-1.5 text-[11px] leading-4 text-bad"
          >
            <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
            {@share_error}
          </p>
        </.form>
      </.card>

      <.size_card
        vm_form={@vm_form}
        vm_errors={@vm_errors}
        settings={@settings}
        resources={@resources}
      />

      <div class="grid items-start gap-5 lg:grid-cols-2">
        <.nested_virt_card settings={@settings} host={@tools.nested_virt} />
        <.memory_card memory={@memory} vm={@vm} />
      </div>

      <.host_card host={@host} host_form={@host_form} host_error={@host_error} />

      <.way_of_working_card way_form={@way_form} way_error={@way_error} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PickFolders">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            event.preventDefault()
            await this.pick()
          })
        },

        async pick() {
          // The desktop shell exposes the native picker through the Tauri IPC.
          // In a plain browser there is nothing to call, so the path is typed.
          const dialog = window.__TAURI__?.dialog
          const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke

          if (!dialog && !invoke) {
            document.getElementById("share-path")?.focus()
            return this.pushEvent("folder_picker_unavailable", {
              reason: "The folder picker only opens in the desktop app.",
            })
          }

          const options = {
            directory: true,
            multiple: true,
            recursive: false,
            title: "Share folders with the VM",
            defaultPath: this.el.dataset.defaultPath || undefined,
          }

          try {
            const selection = dialog
              ? await dialog.open(options)
              : await invoke("plugin:dialog|open", {options})
            const picked = selection == null ? [] : Array.isArray(selection) ? selection : [selection]
            const paths = picked
              .map((item) => (item && typeof item === "object" ? item.path : item))
              .filter(Boolean)

            if (!paths.length) return
            this.pushEvent("add_shares", {paths})
          } catch (error) {
            this.pushEvent("folder_picker_unavailable", {
              reason: `The folder picker could not be opened: ${error?.message || error}.`,
            })
          }
        },
      }
    </script>
    """
  end

  ## Size and timing

  attr :vm_form, :any, required: true
  attr :vm_errors, :map, required: true
  attr :settings, :any, required: true
  attr :resources, :map, required: true

  # One form, in three parts. The CPUs and memory show what they take of
  # this machine as you type (the form reports each change), against what
  # MWT suggests; nothing is saved until Save.
  defp size_card(assigns) do
    %{host: host, suggested: suggested, most: most} = assigns.resources
    cpus = number(assigns.vm_form[:cpus].value)
    memory_gib = number(assigns.vm_form[:memory_gib].value)

    assigns =
      assign(assigns,
        host: host,
        suggested: suggested,
        most: most,
        cpus: cpus,
        memory_gib: memory_gib,
        on_suggestion?: cpus == suggested.cpus and memory_gib == suggested.memory_gib,
        dirty?: dirty?(assigns.vm_form, assigns.settings)
      )

    ~H"""
    <.card id="settings-vm" title="Size and timing" body_class="">
      <:help>
        What the VM is given, and how long it waits for you. Each "?" says what a setting is and when a change applies: when the VM is recreated, at its next start, or at once.
      </:help>
      <.form
        for={@vm_form}
        id="vm-form"
        phx-change="vm_changed"
        phx-submit="save_settings"
        autocomplete="off"
      >
        <div
          id="vm-suggestion"
          class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line-soft bg-accent-soft/15 px-4 py-2.5"
        >
          <.icon name="hero-sparkles-micro" class="size-4 shrink-0 text-accent" />
          <p class="min-w-0 flex-1 text-[11px] leading-4 text-muted">
            <span class="text-ink">
              This machine has {plural(@host.cores, "core", "cores")}<span :if={@host.memory}> and {Resources.gib_text(@host.memory)} GiB of memory</span>.
            </span>
            MWT suggests
            <span id="vm-suggested" class="font-medium text-ink">
              {plural(@suggested.cpus, "CPU", "CPUs")} and {@suggested.memory_gib} GiB
            </span>
            for the VM: nearly all of it, with enough kept back for your desktop.
            <.help id="vm-suggestion-help" label="How MWT suggests">
              <span class="block">
                The VM gets every core but an eighth (one at least) and all the memory but a fifth (from 4 to 16 GiB), since builds and tests in it are what this machine works on while agents do.
              </span>
              <span class="mt-1.5 block">
                The most it can have is every core, and the memory less an eighth of it (from 2 to 8 GiB). Past that, this machine would run out of memory and start killing programs.
              </span>
            </.help>
          </p>
          <.button
            :if={not @on_suggestion?}
            type="button"
            id="vm-use-suggested"
            phx-click="use_suggested"
          >
            Use {plural(@suggested.cpus, "CPU", "CPUs")}, {@suggested.memory_gib} GiB
          </.button>
          <span
            :if={@on_suggestion?}
            id="vm-on-suggestion"
            class="inline-flex items-center gap-1 text-[11px] font-medium text-ok-strong"
          >
            <.icon name="hero-check-micro" class="size-3.5" /> Suggested values
          </span>
        </div>

        <.section title="Processor and memory">
          <.setting
            field={@vm_form[:cpus]}
            label="CPUs"
            unit={if(@cpus == 1, do: "CPU", else: "CPUs")}
            applies={:recreate}
            min="1"
            max={@most.cpus}
            error={@vm_errors[:cpus]}
          >
            <:help>
              How many virtual CPUs the VM has, up to this machine's {@host.cores} cores. Each is a thread here that this machine's scheduler shares out like any other program's, so an idle VM takes nothing, and a busy one slows your desktop but can't stop it.
            </:help>
            <:meter>
              <.share
                id="vm-cpus-share"
                value={@cpus}
                total={@host.cores}
                suggested={@suggested.cpus}
                most={@most.cpus}
                unit="cores"
                over="More than suggested: your desktop slows down while the VM is busy."
              />
            </:meter>
          </.setting>
          <.setting
            field={@vm_form[:memory_gib]}
            label="Memory"
            unit="GiB"
            applies={:recreate}
            min="1"
            max={@most.memory_gib}
            error={@vm_errors[:memory_gib]}
          >
            <:help>
              The most RAM the VM can have. MWT returns RAM when your desktop needs it and grows the VM again as memory becomes available, keeping headroom for its programs. Capped at {@most.memory_gib} GiB here.
            </:help>
            <:meter :if={@host.memory}>
              <.share
                id="vm-memory-share"
                value={@memory_gib}
                total={@host.memory / (1024 * 1024 * 1024)}
                suggested={@suggested.memory_gib}
                most={@most.memory_gib}
                unit="GiB"
                over="More than suggested: with the VM busy, this machine may run short of memory and swap."
              />
            </:meter>
          </.setting>
        </.section>

        <.section title="Disks">
          <:help>
            Each disk is a file on this machine that takes space only as it fills, so a generous size costs nothing until the VM uses it. Only the VM opens them: nothing here reads what is inside.
          </:help>
          <.setting
            field={@vm_form[:disk_gib]}
            label="Root disk"
            unit="GiB"
            applies={:recreate}
            min="4"
            max="4096"
            error={@vm_errors[:disk_gib]}
          >
            <:help>
              The VM's /: the image, and what is written outside the disks below (apt packages, /tmp, /var). It starts again from the image whenever the VM is recreated.
            </:help>
          </.setting>
          <.setting
            field={@vm_form[:home_gib]}
            label="Home"
            path="/root"
            unit="GiB"
            applies={:next_start}
            min="1"
            max="4096"
            error={@vm_errors[:home_gib]}
          >
            <:help>
              Logins, shell history, Zed's server, agent settings. Kept when the VM is recreated, unless you choose to start it empty then. A bigger size applies at the next start; it is never made smaller.
            </:help>
          </.setting>
          <.setting
            field={@vm_form[:cache_gib]}
            label="Cache"
            path="/cache"
            unit="GiB"
            applies={:next_start}
            min="1"
            max="4096"
            error={@vm_errors[:cache_gib]}
          >
            <:help>
              Tool versions installed in the VM (mise) and package caches. Kept when the VM is recreated, unless you choose to start it empty then. A bigger size applies at the next start; it is never made smaller.
            </:help>
          </.setting>
          <.setting
            field={@vm_form[:work_gib]}
            label="Work"
            path="/work"
            unit="GiB"
            applies={:next_start}
            min="1"
            max="4096"
            error={@vm_errors[:work_gib]}
          >
            <:help>
              Your projects in the VM, their worktrees, and everything built in them. Recreating the VM never empties it. A bigger size applies at the next start; it is never made smaller.
            </:help>
          </.setting>
        </.section>

        <.section title="Waiting for you">
          <.setting
            field={@vm_form[:hold_seconds]}
            label="Approval wait"
            unit="s"
            applies={:now}
            min="30"
            max="600"
            error={@vm_errors[:hold_seconds]}
          >
            <:help>
              How long a request that needs your decision waits on Approvals before it gives up and the agent gets a refusal. The image sets HEX_HTTP_TIMEOUT above it, since Hex otherwise gives up after 15 seconds.
            </:help>
          </.setting>
        </.section>

        <div class="flex items-center gap-3 border-t border-line-soft bg-deep/30 px-4 py-2.5">
          <p
            id="vm-form-state"
            class={[
              "flex flex-1 items-center gap-1.5 text-[11px]",
              if(@dirty?, do: "text-warn-strong", else: "text-faint")
            ]}
          >
            <span class={["size-1.5 rounded-full", if(@dirty?, do: "bg-warn", else: "bg-faint/60")]}></span>
            {if @dirty?, do: "Unsaved changes", else: "Saved"}
          </p>
          <button
            :if={@dirty?}
            type="button"
            id="vm-reset"
            phx-click="reset_vm_form"
            class="cursor-pointer rounded-md px-2 py-1 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            Discard
          </button>
          <.button type="submit" id="vm-save" variant="primary" disabled={not @dirty?}>
            Save
          </.button>
        </div>
      </.form>
    </.card>
    """
  end

  attr :title, :string, required: true
  slot :help
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div class="border-b border-line-soft last:border-b-0">
      <p class="flex items-center gap-1.5 px-4 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-wide text-faint">
        {@title}
        <.help :if={@help != []} id={"vm-section-#{slug(@title)}-help"} label={"About #{@title}"}>
          {render_slot(@help)}
        </.help>
      </p>
      <div class="divide-y divide-line-soft/60">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :path, :string, default: nil
  attr :unit, :string, required: true
  attr :applies, :atom, required: true, values: [:recreate, :next_start, :now]
  attr :error, :string, default: nil
  attr :min, :any, required: true
  attr :max, :any, required: true
  slot :help, required: true
  slot :meter

  # A setting on one row: its name, a "?" for what it is, when a change
  # applies, and the number with its unit; a meter beneath when it has one.
  defp setting(assigns) do
    ~H"""
    <div id={"setting-#{@field.id}"} class="px-4 py-2.5">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-1.5">
        <div class="flex min-w-0 flex-1 items-center gap-1.5">
          <label for={@field.id} class="text-xs font-medium text-ink">{@label}</label>
          <span :if={@path} class="font-mono text-[10px] text-faint">{@path}</span>
          <.help id={"#{@field.id}-help"} label={"About #{@label}"}>
            {render_slot(@help)}
            <span class="mt-1.5 block text-muted">{applies_text(@applies)}</span>
          </.help>
          <span
            class="rounded border border-line-soft px-1.5 py-px text-[9px] font-medium uppercase tracking-wide text-faint"
            title={applies_text(@applies)}
          >
            {applies_label(@applies)}
          </span>
        </div>
        <div class={[
          "flex items-center overflow-hidden rounded-md border bg-deep transition-colors focus-within:border-accent/60 focus-within:ring-2 focus-within:ring-accent/15",
          if(@error, do: "border-bad/70", else: "border-line")
        ]}>
          <.input
            field={@field}
            type="number"
            min={@min}
            max={@max}
            class="w-20 border-0 bg-transparent px-2 py-1 text-right text-[13px] tabular-nums text-ink outline-none [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
          />
          <span class="w-12 border-l border-line-soft px-2 py-1 text-[11px] text-faint">{@unit}</span>
        </div>
      </div>
      <p :if={@error} id={"#{@field.id}-error"} class="mt-1 text-right text-[11px] text-bad">
        {@error}
      </p>
      <div :if={@meter != []} class="mt-2">{render_slot(@meter)}</div>
    </div>
    """
  end

  # What the VM has of a shared folder: its copy, as the last sync left it,
  # what a sync under way is doing, and the repositories left to projects.
  attr :id, :string, required: true
  attr :entry, :map, default: nil
  attr :running?, :boolean, default: false

  defp share_copy(assigns) do
    assigns = assign(assigns, :status, assigns.entry && assigns.entry.status)

    ~H"""
    <div id={@id} class="mt-0.5 space-y-0.5 text-[10px] leading-4">
      <%= if @status && @status.project? do %>
        <p id={"#{@id}-project"} class="flex items-center gap-1 text-muted">
          <.icon name="hero-code-bracket-square-micro" class="size-3 shrink-0 text-accent" />
          A git repository: it reaches the VM as a project, by git. Nothing of it is copied.
        </p>
      <% else %>
        <p id={"#{@id}-files"} class="flex min-w-0 items-center gap-1 text-muted">
          <.icon name="hero-document-duplicate-micro" class="size-3 shrink-0 text-accent" />
          <span :if={@status} class="shrink-0">
            {count(@status.files, "file")} ({bytes(@status.bytes)}), read-only in the VM ·
          </span>
          <.share_sync_state id={"#{@id}-state"} entry={@entry} running?={@running?} />
        </p>
      <% end %>
      <p
        :if={@status && not @status.project? && @status.trees != []}
        id={"#{@id}-projects"}
        class="flex items-center gap-1 text-faint"
        title={Enum.join(@status.trees, "\n")}
      >
        <.icon name="hero-code-bracket-square-micro" class="size-3 shrink-0" />
        <span class="truncate">
          Left to projects, not copied: {Enum.map_join(
            Enum.take(@status.trees, 4),
            ", ",
            &Path.basename/1
          )}{if length(@status.trees) > 4,
            do: ", …"}.
        </span>
      </p>
      <p :if={@status && @status.error} id={"#{@id}-error"} class="flex items-start gap-1 text-bad">
        <.icon name="hero-exclamation-circle-micro" class="mt-0.5 size-3 shrink-0" />
        <span>{@status.error}</span>
      </p>
    </div>
    """
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  attr :id, :string, required: true
  attr :value, :any, required: true, doc: "what the form holds now, nil when not a number"
  attr :total, :any, required: true, doc: "this machine's whole"
  attr :suggested, :integer, required: true
  attr :most, :integer, required: true
  attr :unit, :string, required: true
  attr :over, :string, required: true, doc: "what giving more than suggested costs"

  # How much of this machine the VM takes: its share filled, the part it
  # can never have hatched, and a mark where MWT suggests.
  defp share(assigns) do
    value = assigns.value
    total = max(assigns.total, 1)
    taken = if is_number(value), do: min(max(value, 0), total), else: 0

    assigns =
      assign(assigns,
        taken: percent_of(taken, total),
        mark: percent_of(assigns.suggested, total),
        beyond: percent_of(assigns.most, total),
        left: if(is_number(value), do: round_text(total - value)),
        total_text: round_text(total),
        over?: is_number(value) and value > assigns.suggested and value <= assigns.most
      )

    ~H"""
    <div id={@id}>
      <div class="relative">
        <div
          class="relative h-2 overflow-hidden rounded-full bg-deep ring-1 ring-inset ring-line-soft"
          role="img"
          aria-label={"The VM takes #{@value || 0} of #{@total_text} #{@unit}; MWT suggests #{@suggested}"}
        >
          <div
            class="absolute inset-y-0 right-0 bg-[repeating-linear-gradient(135deg,var(--color-line)_0_2px,transparent_2px_5px)] opacity-70"
            style={"left: #{@beyond}%"}
            title="This machine keeps this much, whatever you choose"
          >
          </div>
          <div
            class={[
              "absolute inset-y-0 left-0 rounded-full transition-[width] duration-300",
              if(@over?, do: "bg-warn", else: "bg-accent")
            ]}
            style={"width: #{@taken}%"}
          >
          </div>
        </div>
        <div
          class="absolute -inset-y-1 w-[3px] rounded-full bg-ink ring-2 ring-panel"
          style={"left: calc(#{@mark}% - 1.5px)"}
          title={"Suggested: #{@suggested}"}
        >
        </div>
      </div>
      <div class="mt-1 flex items-center gap-3 text-[10px] text-faint">
        <span class="tabular-nums">
          VM <span class="text-muted">{@value || "–"}</span>
          · this machine keeps <span id={"#{@id}-left"} class="text-muted">{@left || "–"}</span>
          of {@total_text} {@unit}
        </span>
        <span class="flex-1"></span>
        <span :if={@over?} id={"#{@id}-over"} class="flex items-center gap-1 text-warn-strong">
          <.icon name="hero-exclamation-triangle-micro" class="size-3" /> {@over}
        </span>
        <span :if={not @over?} class="flex items-center gap-1">
          <span class="inline-block h-2.5 w-[3px] rounded-full bg-ink"></span> suggested {@suggested}
        </span>
      </div>
    </div>
    """
  end

  defp applies_label(:recreate), do: "On recreate"
  defp applies_label(:next_start), do: "Next start"
  defp applies_label(:now), do: "At once"

  defp applies_text(:recreate), do: "A change applies when the VM is recreated."
  defp applies_text(:next_start), do: "A change applies when the VM next starts."
  defp applies_text(:now), do: "A change applies to the next request."

  # Whether the form holds other values than the saved settings.
  defp dirty?(form, settings) do
    Enum.any?(@vm_fields, &(to_string(form[&1].value) != to_string(Map.fetch!(settings, &1))))
  end

  defp number(value) when is_integer(value), do: value

  defp number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp percent_of(part, whole), do: Float.round(min(max(part / whole, 0.0), 1.0) * 100, 2)

  defp round_text(value) when is_integer(value), do: Integer.to_string(value)

  defp round_text(value) do
    rounded = Float.round(value * 1.0, 1)
    if rounded == Float.round(rounded), do: Integer.to_string(trunc(rounded)), else: "#{rounded}"
  end

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(n, _one, many), do: "#{n} #{many}"

  defp slug(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  attr :settings, :any, required: true
  attr :host, :any, required: true

  # Off and On, with what this machine allows beneath. On is offered only
  # where the machine allows it; a VM that has it on can always turn it off.
  defp nested_virt_card(assigns) do
    ~H"""
    <.card id="settings-nested-virt" title="VMs inside the VM">
      <:help>
        <span class="block">
          On, the VM can run VMs of its own: MWT's own VM tests, a development instance of MWT with a real VM, QEMU, an Android emulator. Containers don't need it.
        </span>
        <span class="mt-1.5 block">
          The cost is exposure: every process in the VM, all of them root, can reach the part of this machine's kernel that emulates the CPU's virtualization for a VM's own VMs. Several published escapes from a VM to its host were in that code, so keep this machine's kernel up to date while it is on. It applies when the VM is recreated, and so does turning it off.
        </span>
      </:help>
      <:actions>
        <.segmented
          :if={@settings.nested_virt or @host == :allowed}
          id="nested-virt"
          options={[{false, "Off"}, {true, "On"}]}
          value={@settings.nested_virt}
          event="set_nested_virt"
          name="on"
          tone={:risk}
          confirm={%{"true" => nested_virt_warning()}}
        />
      </:actions>
      <p id="nested-virt-host" class="flex items-start gap-1.5 text-xs leading-5 text-muted">
        <.icon
          name={
            if @host == :allowed,
              do: "hero-check-circle-micro",
              else: "hero-exclamation-triangle-micro"
          }
          class={["mt-0.5 size-3.5 shrink-0", if(@host == :allowed, do: "text-ok", else: "text-warn")]}
        />
        <span>
          {nested_virt_text(@host)}
          <code
            :if={match?({:off, _}, @host)}
            id="nested-virt-enable"
            class="mt-1 block w-fit rounded bg-deep px-1.5 py-0.5 font-mono text-[11px] text-ink"
          >
            {NestedVirt.enable_line(elem(@host, 1))}
          </code>
        </span>
      </p>
    </.card>
    """
  end

  @doc "What this machine allows, in a sentence, for `MWTClient.Sandbox.NestedVirt.host/1`."
  @spec nested_virt_text(NestedVirt.host()) :: String.t()
  def nested_virt_text(:allowed), do: "This machine allows it."

  def nested_virt_text({:off, module}),
    do:
      "This machine's KVM (#{module}) was loaded without nesting. To allow it, put this line in a file in /etc/modprobe.d and reload #{module}, or restart."

  def nested_virt_text(:unavailable),
    do:
      "This machine's CPU offers no hardware virtualization to MWT, so the VM can't be given it."

  defp nested_virt_warning do
    "Every process in the VM will reach more of this machine's kernel: the code that " <>
      "emulates the CPU's virtualization, where several escapes from VMs were found. " <>
      "It applies when you recreate the VM. Turn it on?"
  end

  ## The VM's memory

  attr :memory, :map, required: true
  attr :vm, :any, required: true

  defp memory_card(assigns) do
    ~H"""
    <.card id="settings-vm-memory" title="The VM's memory">
      <:help>
        The VM has its own OptMem, at /root/.optmem, on a disk of its own: nothing of it is on this machine, and recreating the VM keeps it. Syncing, while the VM runs, shows what it noted since the last sync: what you tick joins your memory, then yours is copied into the VM, replacing what it remembers there (moved aside in the VM, not deleted). The copy holds every memory you have, work ones included.
      </:help>
      <%= if @memory.host? do %>
        <p id="vm-memory-state" class="text-xs leading-5 text-muted">
          <%= if @memory.seeded_at do %>
            Last copied from yours ({@memory.seed_count} memories) on {Calendar.strftime(
              @memory.seeded_at,
              "%b %-d, %H:%M"
            )} UTC.
          <% else %>
            Its own, never copied from yours.
          <% end %>
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <.memory_sync_button id="vm-memory-sync" vm={@vm} />
        </div>
      <% else %>
        <p class="text-xs leading-5 text-muted">
          OptMem isn't installed on this machine (~/.optmem/memo), so the VM's memory can't be set up or compared with yours.
        </p>
      <% end %>
    </.card>
    """
  end

  ## This machine, for agents

  attr :host, :map, required: true
  attr :host_form, :any, required: true
  attr :host_error, :string, default: nil

  # Your notes are the part you write; MWT adds the rest of what agents
  # read (`mwt host`), which shows on asking.
  defp host_card(assigns) do
    ~H"""
    <.card id="settings-host" title="This machine, for agents">
      <:help>
        What agents in the VM read about this machine with mwt host (also /mnt/mwt/host.md), so the commands they ask to run here fit it: its system, shell, shared folders and the tools found, then your notes. They never probe it themselves.
      </:help>
      <.form for={@host_form} id="host-notes-form" phx-submit="save_host_notes" class="space-y-2">
        <label for="host-notes" class="flex items-center gap-1.5 text-xs font-medium text-ink">
          Your notes
          <.help id="host-notes-help" label="About your notes">
            Anything an agent should know before it asks to run a command here: how the VPN comes up, which Kubernetes contexts exist, what not to touch. Up to 4,000 characters; agents read them at once.
          </.help>
        </label>
        <.input
          field={@host_form[:notes]}
          id="host-notes"
          type="textarea"
          rows="3"
          placeholder="e.g. The work VPN comes up with openvpn3 session-start --config work. Kubernetes contexts: staging, prod."
          class={[input_classes(), "leading-5", @host_error && "border-bad/70"]}
        />
        <p :if={@host_error} id="host-notes-error" class="text-[11px] text-bad">
          {@host_error}
        </p>
        <label for="host-reads" class="flex items-center gap-1.5 pt-1 text-xs font-medium text-ink">
          Folders confined commands may read
          <.help id="host-reads-help" label="About these folders">
            A confined subgrant runs in a bubble with an empty home: these folders of yours are the only ones it sees, read-only, each with what it links to. Where your tools live. One a line; leave it empty for those your login shell's PATH runs tools from.
          </.help>
        </label>
        <.input
          field={@host_form[:reads]}
          id="host-reads"
          type="textarea"
          rows="2"
          placeholder="From your PATH: ~/.local/bin, ~/.local/share/mise/shims, …"
          class={[input_classes(), "font-mono text-xs leading-5"]}
        />
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
          <p
            id="host-tools"
            class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 text-[11px] text-muted"
          >
            <span>
              Agents also read {@host.facts.os}, {@host.facts.arch}, {@host.facts.shell}, and
              <%= cond do %>
                <% @host.probing? -> %>
                  the tools found (looking…).
                <% is_nil(@host.tools) -> %>
                  the tools found (not checked yet).
                <% true -> %>
                  {length(@host.tools)} tools found.
              <% end %>
            </span>
            <button
              type="button"
              id="host-probe"
              phx-click="probe_host"
              disabled={@host.probing?}
              class="cursor-pointer text-accent hover:underline disabled:cursor-default disabled:opacity-50"
            >
              Look for tools again
            </button>
          </p>
          <.button type="submit" id="host-notes-save">Save</.button>
        </div>
        <details id="host-preview" class="group/preview">
          <summary class="flex cursor-pointer list-none items-center gap-1 text-[11px] text-accent hover:underline [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3 transition-transform group-open/preview:rotate-90"
            /> What agents read
          </summary>
          <pre
            id="host-text"
            class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap rounded-lg border border-line-soft bg-deep/50 p-2.5 font-mono text-[10px] leading-4 text-ink"
          >{@host.text}</pre>
        </details>
      </.form>
    </.card>
    """
  end

  attr :way_form, :any, required: true
  attr :way_error, :string, default: nil

  # How you like to work with agents, in your own words: your taste rather
  # than a fact of the VM, so empty until you write it.
  defp way_of_working_card(assigns) do
    ~H"""
    <.card id="settings-way-of-working" title="Your way of working">
      <:help>
        Your own text for the agents in the VM: which decisions to bring you, how you like a system built, anything about working with you. MWT adds it after its own instructions, in ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md, under a heading that says it is yours. It reaches them at the VM's next start.
      </:help>
      <.form
        for={@way_form}
        id="way-of-working-form"
        phx-submit="save_way_of_working"
        class="space-y-2"
      >
        <.input
          field={@way_form[:text]}
          id="way-of-working-text"
          type="textarea"
          rows="12"
          placeholder="Empty, agents read only MWT's instructions. Write how you like to work with them, or start from MWT's example."
          class={[input_classes(), "font-mono text-xs leading-5", @way_error && "border-bad/70"]}
        />
        <p :if={@way_error} id="way-of-working-error" class="text-[11px] text-bad">
          {@way_error}
        </p>
        <div class="flex flex-wrap items-center justify-end gap-3">
          <button
            type="button"
            id="way-of-working-example"
            phx-click="way_of_working_example"
            data-confirm="Put MWT's example in the field, in place of what is there? Nothing changes for agents until you save."
            class="cursor-pointer text-[11px] text-accent hover:underline"
          >
            Start from MWT's example
          </button>
          <.button type="submit" id="way-of-working-save">Save</.button>
        </div>
      </.form>
    </.card>
    """
  end

  # The picker opens where the latest shared folder sits, or in your home.
  defp pick_from([]), do: System.user_home() || ""
  defp pick_from(shares), do: shares |> List.last() |> Map.fetch!(:path) |> Path.dirname()

  ## Build

  defp image_tab(assigns) do
    current = Enum.find(assigns.builds, &(&1.ref == assigns.image.tag))

    assigns =
      assign(assigns,
        mwt_layer: Image.mwt_layer(),
        current: current,
        different_default?: assigns.settings.containerfile != Image.default_containerfile(),
        edited?: current != nil and current.containerfile != assigns.settings.containerfile
      )

    ~H"""
    <.card id="settings-image" title="The VM's image" class="mb-5" body_class="">
      <:help>
        Your Containerfile, then MWT's layer, built with podman on this machine and handed to microsandbox. MWT's default comes with Bash, completion, language runtimes and development CLIs already installed. The build runs here, in a rootless podman container, which isolates less than the VM: install scripts in your Containerfile run there.
      </:help>
      <:actions>
        <span
          id="image-state"
          class={[
            "rounded-full border px-2 py-0.5 text-[10px] font-medium",
            cond do
              @image.building? -> "border-warn/40 bg-warn-soft/40 text-warn-strong"
              @image.loaded? -> "border-ok/30 bg-ok-soft/40 text-ok-strong"
              true -> "border-line text-muted"
            end
          ]}
        >
          <%= cond do %>
            <% @image.building? -> %>
              Building…
            <% @image.loaded? -> %>
              Built
            <% true -> %>
              Not built
          <% end %>
        </span>
        <.button
          id="image-build"
          variant={if(@image.loaded?, do: "secondary", else: "primary")}
          phx-click="build_image"
          disabled={@image.building? or not @tools.podman}
        >
          <.icon name="hero-wrench-screwdriver-micro" class="size-3.5" />
          {if @image.loaded?, do: "Rebuild", else: "Build"}
        </.button>
      </:actions>

      <div
        id="image-setup-guide"
        class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line-soft px-4 py-2.5"
      >
        <p class="flex-1 text-[11px] leading-5 text-muted">
          Save the recipe, build it, then recreate the VM to use it.
        </p>
        <.form
          for={@name_form}
          id="image-name-form"
          phx-submit="save_image_name"
          class="flex items-center gap-2"
        >
          <label for="image-name" class="text-[11px] font-medium text-muted">Name</label>
          <input
            type="text"
            id="image-name"
            name={@name_form[:name].name}
            value={@name_form[:name].value}
            spellcheck="false"
            autocomplete="off"
            class={[
              "w-52 rounded-md border bg-deep px-2 py-1 font-mono text-xs text-ink outline-none focus:border-accent/60",
              if(@name_error, do: "border-bad/70", else: "border-line")
            ]}
          />
          <.help id="image-name-help" label="About the image name">
            Each build is tagged with its date and number, like
            <span class="font-mono">{@settings.image_name}:{Date.to_iso8601(Date.utc_today())}.1</span>
          </.help>
          <.button type="submit" id="image-name-save">Save</.button>
        </.form>
        <p :if={@name_error} id="image-name-error" class="w-full text-right text-[11px] text-bad">
          {@name_error}
        </p>
      </div>

      <p
        :if={@different_default?}
        id="containerfile-default-differs"
        class="flex items-center gap-2 border-b border-line-soft bg-accent-soft/20 px-4 py-2 text-[11px] text-ink"
      >
        <.icon name="hero-information-circle-micro" class="size-3.5 shrink-0 text-accent" />
        <span class="flex-1">
          Your recipe differs from MWT's current default. To adopt it, choose "Start from MWT's default", review, save and build.
        </span>
      </p>

      <p
        :if={@edited?}
        id="containerfile-edited"
        class="flex items-center gap-2 border-b border-warn/30 bg-warn-soft/25 px-4 py-2 text-[11px] text-ink"
      >
        <.icon name="hero-pencil-square-micro" class="size-3.5 text-warn" />
        The Containerfile changed since the current build. Build to use it.
      </p>

      <p
        :if={not @tools.podman}
        class="flex items-center gap-2 border-b border-bad/30 bg-bad-soft/20 px-4 py-2 text-[11px] text-bad"
      >
        <.icon name="hero-x-circle-micro" class="size-3.5 shrink-0" />
        podman is not installed, so the image can't be built.
      </p>

      <div class="grid gap-0 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
        <.form
          for={@containerfile_form}
          id="containerfile-form"
          phx-submit="save_containerfile"
          class="flex min-w-0 flex-col border-line-soft lg:border-r"
        >
          <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
            <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
              Containerfile
            </p>
            <button
              type="button"
              id="containerfile-reset"
              phx-click="reset_containerfile"
              class="cursor-pointer rounded px-1.5 py-0.5 text-[10px] text-faint transition-colors hover:bg-hover hover:text-ink"
            >
              Start from MWT's default
            </button>
          </div>
          <textarea
            name={@containerfile_form[:containerfile].name}
            id="containerfile"
            spellcheck="false"
            rows="18"
            class="min-h-80 w-full flex-1 resize-y border-0 bg-deep px-4 py-3 font-mono text-[11px] leading-5 text-ink outline-none focus:ring-2 focus:ring-inset focus:ring-accent/25"
          >{@containerfile_form[:containerfile].value}</textarea>
          <div class="flex items-center gap-2 border-t border-line-soft px-4 py-2">
            <p :if={@containerfile_error} id="containerfile-error" class="flex-1 text-[11px] text-bad">
              {@containerfile_error}
            </p>
            <p
              :if={is_nil(@containerfile_error)}
              class="flex-1 truncate font-mono text-[10px] text-faint"
              title={@image.tag}
            >
              {@image.tag || "not built yet"}
            </p>
            <.button type="submit" id="containerfile-save">Save</.button>
          </div>
        </.form>

        <div class="flex min-w-0 flex-col">
          <%= if @image.building? or @image.log != [] or @image.error do %>
            <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
              <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Build log
              </p>
              <.icon
                :if={@image.building?}
                name="hero-arrow-path-micro"
                class="size-3.5 animate-spin text-warn"
              />
            </div>
            <p
              :if={@image.error}
              id="image-error"
              class="border-b border-bad/30 bg-bad-soft/20 px-4 py-2 text-[11px] text-bad"
            >
              {@image.error}
            </p>
            <pre
              id="build-log"
              class="max-h-96 min-h-48 flex-1 overflow-auto bg-deep/60 px-4 py-3 font-mono text-[10px] leading-4 text-muted"
              phx-no-curly-interpolation
            ><%= @image.log |> Enum.take(160) |> Enum.reverse() |> Enum.join("\n") %></pre>
          <% else %>
            <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
              <p class="flex flex-1 items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                MWT adds this layer
                <.help id="mwt-layer-help" label="About MWT's layer">
                  It points at /mnt/mwt and /cache. The image holds nothing of this identity's; CA, grant and helper updates arrive without rebuilding it.
                </.help>
              </p>
            </div>
            <pre
              id="mwt-layer"
              class="max-h-96 flex-1 overflow-auto bg-deep/40 px-4 py-3 font-mono text-[10px] leading-4 text-faint"
              phx-no-curly-interpolation
            ><%= String.trim(@mwt_layer) %></pre>
          <% end %>
        </div>
      </div>
    </.card>

    <.card id="settings-builds" title="Builds kept" body_class="">
      <:help>
        The current one and the two before it. Going back means using a build, not the recipe: rebuilding the same Containerfile later gives other versions.
      </:help>
      <ul class="divide-y divide-line-soft">
        <li :if={@builds == []} id="builds-empty">
          <.empty icon="hero-archive-box">No build yet. Build the image above.</.empty>
        </li>
        <li
          :for={build <- @builds}
          id={"build-" <> String.replace(build.tag, ".", "-")}
          class="px-4 py-2.5"
        >
          <div class="flex flex-wrap items-center gap-3">
            <.icon
              name="hero-archive-box"
              class={[
                "size-4 shrink-0",
                if(build.ref == @image.tag, do: "text-accent", else: "text-faint")
              ]}
            />
            <span class="font-mono text-xs text-ink">{build.tag}</span>
            <span
              :if={build.ref == @image.tag}
              class="rounded-full border border-accent/30 bg-accent/10 px-1.5 py-px text-[9px] font-semibold uppercase tracking-wide text-accent"
            >
              current
            </span>
            <span
              :if={build.ref == @created_ref and @vm.exists?}
              class="rounded-full border border-ok/30 bg-ok-soft/40 px-1.5 py-px text-[9px] font-semibold uppercase tracking-wide text-ok-strong"
            >
              the VM runs it
            </span>
            <span class="text-[11px] text-muted">
              {Calendar.strftime(build.built_at, "%b %-d, %H:%M")} UTC
            </span>
            <span :if={build.size} class="text-[11px] text-faint">{gigabytes(build.size)}</span>
            <span class="flex-1"></span>
            <.button
              :if={build.ref != @image.tag}
              id={"build-use-" <> String.replace(build.tag, ".", "-")}
              phx-click="use_build"
              phx-value-ref={build.ref}
              disabled={@image.building?}
            >
              Make current
            </.button>
          </div>
          <details :if={build.versions != ""} class="group mt-1.5 pl-7">
            <summary class="cursor-pointer list-none text-[10px] text-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
              <.icon
                name="hero-chevron-right-micro"
                class="size-3 transition-transform group-open:rotate-90"
              /> What's in it
            </summary>
            <pre
              class="mt-1.5 max-h-56 overflow-auto rounded-md bg-deep/60 px-3 py-2 font-mono text-[10px] leading-4 text-muted"
              phx-no-curly-interpolation
            ><%= String.trim(build.versions) %></pre>
          </details>
        </li>
      </ul>
    </.card>
    """
  end

  defp gigabytes(bytes), do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"
end
