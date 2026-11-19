defmodule MWTClientWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MWTClientWeb, :html

  alias MWTClient.Tools
  alias MWTClientWeb.Notices

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell: a thin title bar plus a full height work area.

  Pass `chrome={false}` for standalone screens (like the login page) that own
  the whole window.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} tool={@tool}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :tool, :map, default: nil, doc: "the tool currently open, see `MWTClient.Tools`"
  attr :chrome, :boolean, default: true, doc: "renders the title bar"
  attr :notices, :list, default: [], doc: "the notices to float, see `MWTClientWeb.Notices`"
  attr :update, :map, default: %{status: :idle, package: nil, release: nil, message: nil}

  attr :sandbox_waiting, :integer,
    default: 0,
    doc: "approvals and agent requests waiting in the agent sandbox"

  attr :notifications, :integer,
    default: 0,
    doc: "how many notifications there are now, see `MWTClient.Notifications`"

  attr :places, :map,
    default: %{},
    doc: "the page each tool was left on, by tool id, see `MWTClientWeb.Hooks.Places`"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="relative flex h-full flex-col overflow-hidden bg-app text-ink">
      <header
        :if={@chrome}
        class="flex h-10 shrink-0 items-center gap-2 border-b border-line-soft bg-panel px-3"
      >
        <.link
          navigate={~p"/tools"}
          class="flex items-center gap-2 rounded px-1.5 py-1 transition-colors hover:bg-hover"
          title="All tools"
        >
          <.logo id="header-logo" class="size-4" />
          <span class="text-[13px] font-semibold tracking-wide text-ink">MWT</span>
        </.link>

        <div class="mx-1 h-4 w-px bg-line"></div>

        <.tool_switcher current={@tool} places={@places} />

        <div class="flex-1"></div>

        <.link
          :if={@sandbox_waiting > 0}
          navigate={~p"/tools/sandbox/approvals"}
          id="sandbox-waiting"
          title="Agent requests waiting for you"
          class="group flex h-7 shrink-0 items-center gap-1.5 rounded-md border border-warn/40 bg-warn-soft/40 px-2 text-[11px] font-semibold text-warn-strong transition-colors hover:border-warn/70 hover:bg-warn-soft/70"
        >
          <span class="relative flex size-2">
            <span class="absolute inline-flex size-full rounded-full bg-warn opacity-60 motion-safe:animate-ping"></span>
            <span class="relative inline-flex size-2 rounded-full bg-warn"></span>
          </span>
          <span id="sandbox-waiting-count">{@sandbox_waiting}</span>
          <span class="hidden md:inline">waiting</span>
        </.link>

        <.link
          :if={@current_scope}
          navigate={~p"/notifications"}
          id="notifications-link"
          title={
            if(@notifications == 0,
              do: "Notifications",
              else: "Notifications: #{@notifications} waiting for you"
            )
          }
          class={[
            "relative flex size-7 items-center justify-center rounded transition-colors hover:bg-hover",
            if(@notifications > 0, do: "text-ink", else: "text-muted hover:text-ink")
          ]}
        >
          <.icon
            name={if @notifications > 0, do: "hero-bell-alert", else: "hero-bell"}
            class="size-4"
          />
          <span
            :if={@notifications > 0}
            id="notifications-count"
            class="absolute -right-0.5 -top-0.5 flex h-3.5 min-w-3.5 items-center justify-center rounded-full bg-accent px-1 text-[9px] font-semibold leading-none text-deep tabular-nums"
          >
            {if @notifications > 99, do: "99+", else: @notifications}
          </span>
        </.link>

        <.settings_menu current_scope={@current_scope} update={@update} />
      </header>

      <main class="flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
      <.notice_group notices={@notices} />
      <div
        :if={@update.status != :idle}
        id="update-notice"
        role="status"
        class="fixed bottom-3 right-3 z-50 flex w-[min(22rem,calc(100vw-1.5rem))] items-center gap-3 rounded-xl border border-line bg-panel px-3 py-2.5 shadow-xl shadow-black/15"
      >
        <span class={[
          "flex size-8 shrink-0 items-center justify-center rounded-lg",
          if(@update.status == :error,
            do: "bg-bad-soft text-bad",
            else: "bg-accent-soft text-accent"
          )
        ]}>
          <.icon
            name={
              case @update.status do
                :error -> "hero-exclamation-circle"
                status when status in [:installed, :current] -> "hero-check"
                _ -> "hero-arrow-down-tray"
              end
            }
            class="size-4"
          />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-xs font-semibold text-ink">
            <%= case @update.status do %>
              <% :checking -> %>
                Checking for updates…
              <% :current -> %>
                MWT is up to date
              <% :available -> %>
                MWT {@update.release.version} is available
              <% :downloading -> %>
                Downloading MWT {@update.release.version}…
              <% :reading -> %>
                Reading the package…
              <% :error -> %>
                MWT was not updated
              <% :installed -> %>
                Update installed
              <% :installing -> %>
                Installing MWT {@update.package.version}…
              <% :ready -> %>
                Install MWT {@update.package.version}?
            <% end %>
          </p>
          <p
            :if={@update.status == :ready}
            id="update-package"
            class="mt-0.5 truncate font-mono text-[11px] text-muted"
            title={@update.package.file}
          >
            {@update.package.file}
          </p>
          <p
            :if={@update.status == :current}
            id="update-current"
            class="mt-0.5 text-[11px] text-muted"
          >
            {@update.message}
          </p>
          <p
            :if={@update.message && @update.status != :current}
            id="update-error"
            class="mt-0.5 text-[11px] leading-4 text-bad"
          >
            {@update.message}
          </p>
          <p :if={@update.status == :available} class="mt-0.5 text-[11px] text-muted">
            A signed release, from GitHub.
          </p>
          <p :if={@update.status == :downloading} class="mt-0.5 text-[11px] text-muted">
            Checking its signature and checksum before installing it.
          </p>
          <p :if={@update.status == :installing} class="mt-0.5 text-[11px] text-muted">
            The system asks for your password to install it.
          </p>
          <p :if={@update.status == :installed} class="mt-0.5 text-[11px] text-muted">
            Restarting MWT…
          </p>
        </div>
        <button
          :if={@update.status in [:ready, :available]}
          id="install-update"
          type="button"
          phx-click="install_update"
          class="shrink-0 cursor-pointer rounded-md bg-accent px-2.5 py-1.5 text-[11px] font-semibold text-white transition-colors hover:bg-accent/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          Install
        </button>
        <button
          :if={@update.status in [:ready, :available, :current, :error]}
          id="dismiss-update"
          type="button"
          phx-click="dismiss_update"
          aria-label="Dismiss update notice"
          title="Dismiss"
          class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
        <.icon
          :if={updating?(@update)}
          name="hero-arrow-path"
          class="size-4 animate-spin text-accent"
        />
        <button
          :if={@update.status == :installed}
          id="restart-after-update"
          type="button"
          phx-click={JS.dispatch("mwt:restart-after-update")}
          class="shrink-0 cursor-pointer rounded-md bg-accent px-2.5 py-1.5 text-[11px] font-semibold text-white transition-colors hover:bg-accent/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          Restart
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The settings menu at the end of the title bar: who is signed in, the
  theme, updates, and the pages that set MWT up (agents, storage, export
  and import), with locking last.

  It opens and closes in the browser alone (`JS`), so it works the same
  over every tool; its theme and update buttons send the events the
  `MWTClientWeb.Hooks` of every page answer.
  """
  attr :current_scope, :map, default: nil
  attr :update, :map, required: true

  def settings_menu(assigns) do
    ~H"""
    <%!-- Clicks on the button are inside, so it alone opens and closes the
          menu; any click elsewhere, or Escape, closes it. --%>
    <div
      class="relative"
      id="settings"
      phx-click-away={close_settings_menu()}
      phx-window-keydown={close_settings_menu()}
      phx-key="Escape"
    >
      <button
        type="button"
        id="settings-menu-button"
        phx-click={toggle_settings_menu()}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls="settings-menu"
        title="Settings"
        aria-label="Settings"
        class="group flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink aria-expanded:bg-active aria-expanded:text-ink focus-visible:outline-2 focus-visible:outline-accent"
      >
        <.icon
          name="hero-cog-6-tooth"
          class="size-4 transition-transform duration-300 group-hover:rotate-45 group-aria-expanded:rotate-45"
        />
      </button>

      <div
        id="settings-menu"
        role="menu"
        aria-labelledby="settings-menu-button"
        class="absolute right-0 top-full z-50 mt-1.5 hidden w-64 origin-top-right rounded-xl border border-line bg-panel p-1.5 shadow-xl shadow-black/15 dark:shadow-black/50"
      >
        <div
          :if={@current_scope}
          id="settings-account"
          class="flex items-center gap-2.5 rounded-lg px-2 pb-2.5 pt-1.5"
        >
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[11px] font-semibold text-accent">
            {@current_scope.user.initials}
          </span>
          <span class="min-w-0">
            <span class="block text-[10px] font-medium uppercase tracking-wide text-faint">
              Signed in as
            </span>
            <span class="block truncate text-[13px] font-semibold text-ink">
              {@current_scope.user.username}
            </span>
          </span>
        </div>

        <div class="flex items-center gap-2.5 rounded-lg px-2 py-1.5">
          <.icon name="hero-swatch" class="size-4 shrink-0 text-faint" />
          <span class="flex-1 text-xs text-ink">Theme</span>
          <.theme_toggle />
        </div>

        <button
          id="check-updates"
          type="button"
          role="menuitem"
          phx-click={JS.push("check_updates") |> close_settings_menu()}
          disabled={updating?(@update)}
          class={settings_item_class()}
        >
          <.icon
            name="hero-arrow-path"
            class="size-4 shrink-0 self-start text-faint transition-colors group-hover:text-accent"
          />
          <span class="min-w-0 flex-1">
            <span class="block">Check for updates</span>
            <span class="block text-[11px] leading-4 text-faint">
              From MWT's signed releases
            </span>
          </span>
        </button>

        <button
          id="update-from-file"
          type="button"
          role="menuitem"
          phx-hook=".PickUpdate"
          data-on-pick={close_settings_menu()}
          disabled={updating?(@update)}
          class={settings_item_class()}
        >
          <.icon
            name="hero-arrow-down-tray"
            class="size-4 shrink-0 self-start text-faint transition-colors group-hover:text-accent"
          />
          <span class="min-w-0 flex-1">
            <span class="block">Install from a file…</span>
            <span class="block text-[11px] leading-4 text-faint">
              A package you downloaded
            </span>
          </span>
        </button>

        <div :if={@current_scope} class="my-1 h-px bg-line-soft" role="separator"></div>

        <.settings_link
          :if={@current_scope}
          id="agent-access-link"
          navigate={~p"/agents"}
          icon="hero-command-line"
          hint="Let an agent use MWT from your machine"
        >
          Connect an agent
        </.settings_link>
        <.settings_link
          :if={@current_scope}
          id="storage-link"
          navigate={~p"/storage"}
          icon="hero-circle-stack"
          hint="What MWT keeps and how much room it takes"
        >
          Storage
        </.settings_link>
        <.settings_link
          :if={@current_scope}
          id="transfer-link"
          navigate={~p"/transfer"}
          icon="hero-arrows-right-left"
          hint="Move your data to or from another MWT"
        >
          Export and import
        </.settings_link>

        <div :if={@current_scope} class="my-1 h-px bg-line-soft" role="separator"></div>

        <.link
          :if={@current_scope}
          id="logout-link"
          href={~p"/logout"}
          method="delete"
          role="menuitem"
          class={[settings_item_class(), "hover:bg-bad-soft/40 hover:text-bad"]}
        >
          <.icon
            name="hero-lock-closed"
            class="size-4 shrink-0 text-faint transition-colors group-hover:text-bad"
          />
          <span class="flex-1">Lock and sign out</span>
        </.link>
      </div>
    </div>
    <%!-- The server says which package this install takes (.deb or .rpm),
          or shows in the update notice why MWT can't update itself here;
          the native picker then offers only that kind of file.

          data-on-pick runs here, not as phx-click: LiveView skips the
          phx-click of an element whose hook is waiting for a reply. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PickUpdate">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            if (this.el.dataset.onPick) this.js().exec(this.el.dataset.onPick)
            this.pick()
          })
        },

        pick() {
          this.pushEvent("pick_update", {}, async ({extension}) => {
            if (!extension) return

            const dialog = window.__TAURI__?.dialog
            const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke

            if (!dialog && !invoke) {
              return this.pushEvent("update_picker_failed", {
                reason: "The file picker is only available in the desktop app.",
              })
            }

            const options = {
              title: "Choose the MWT package to install",
              directory: false,
              multiple: false,
              filters: [{name: `MWT package (.${extension})`, extensions: [extension]}],
            }

            try {
              const selection = dialog
                ? await dialog.open(options)
                : await invoke("plugin:dialog|open", {options})
              const first = Array.isArray(selection) ? selection[0] : selection
              const path = first && typeof first === "object" ? first.path : first

              if (path) this.pushEvent("select_update", {path})
            } catch (error) {
              this.pushEvent("update_picker_failed", {
                reason: `The file picker could not be opened: ${error?.message || error}`,
              })
            }
          })
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  defp settings_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      role="menuitem"
      class={settings_item_class()}
    >
      <.icon
        name={@icon}
        class="size-4 shrink-0 self-start text-faint transition-colors group-hover:text-accent"
      />
      <span class="min-w-0 flex-1">
        <span class="block">{render_slot(@inner_block)}</span>
        <span class="block text-[11px] leading-4 text-faint">{@hint}</span>
      </span>
    </.link>
    """
  end

  defp settings_item_class do
    [
      "group flex w-full cursor-pointer items-center gap-2.5 rounded-lg px-2 py-1.5 text-left text-xs text-ink",
      "transition-colors hover:bg-hover focus-visible:bg-hover focus-visible:outline-none",
      "disabled:cursor-wait disabled:opacity-60"
    ]
  end

  defp toggle_settings_menu do
    JS.toggle(
      to: "#settings-menu",
      in: {"transition ease-out duration-100", "opacity-0 scale-95", "opacity-100 scale-100"},
      out: {"transition ease-in duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#settings-menu-button")
  end

  defp close_settings_menu(js \\ %JS{}) do
    js
    |> JS.hide(
      to: "#settings-menu",
      transition:
        {"transition ease-in duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
    )
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#settings-menu-button")
  end

  @doc """
  The update buttons of the sign-in screen: the settings menu's Check for
  updates, and its picker for a package you downloaded.
  """
  attr :update, :map, required: true

  def update_check(assigns) do
    ~H"""
    <div class="flex items-center">
      <button
        id="check-updates"
        type="button"
        phx-click="check_updates"
        disabled={updating?(@update)}
        title="Check MWT's signed releases for a newer MWT"
        aria-label="Check for updates"
        class="flex h-7 shrink-0 cursor-pointer items-center gap-1.5 rounded-md px-2 text-[11px] font-medium text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-wait disabled:opacity-60"
      >
        <.icon name="hero-arrow-path" class="size-3.5" />
        <span class="hidden sm:inline">Update</span>
      </button>
      <button
        id="update-from-file"
        type="button"
        phx-hook=".PickUpdate"
        disabled={updating?(@update)}
        title="Install MWT from a package you downloaded"
        aria-label="Install from a file"
        class="flex size-7 shrink-0 cursor-pointer items-center justify-center rounded-md text-muted transition-colors hover:bg-hover hover:text-ink disabled:cursor-wait disabled:opacity-60"
      >
        <.icon name="hero-arrow-down-tray" class="size-3.5" />
      </button>
    </div>
    """
  end

  # While MWT checks, downloads, reads or installs, the update buttons wait.
  defp updating?(update), do: update.status in [:checking, :downloading, :reading, :installing]

  @doc """
  Switches between tools, naming every one of them and marking the one open.

  Each goes back to the page it was left on (`places`); the one open goes
  to its first page.
  """
  attr :current, :map, default: nil, doc: "the tool currently open, if any"
  attr :places, :map, default: %{}, doc: "the page each tool was left on, by tool id"

  def tool_switcher(assigns) do
    ~H"""
    <nav
      id="tool-switcher"
      aria-label="Tools"
      class="flex items-center gap-1"
    >
      <.link
        :for={tool <- Tools.all()}
        id={"tool-switch-#{tool.id}"}
        navigate={
          if(@current && @current.id == tool.id,
            do: tool.path,
            else: Map.get(@places, tool.id, tool.path)
          )
        }
        aria-current={@current && @current.id == tool.id && "page"}
        class={[
          "group flex h-7 items-center gap-2 rounded-md px-2.5 text-[13px] transition-colors",
          if(@current && @current.id == tool.id,
            do: "bg-active font-medium text-ink",
            else: "text-muted hover:bg-hover hover:text-ink"
          )
        ]}
      >
        <.icon
          name={tool.icon}
          class={[
            "size-4 transition-colors",
            if(@current && @current.id == tool.id,
              do: "text-accent",
              else: "text-faint group-hover:text-muted"
            )
          ]}
        />
        {tool.name}
      </.link>
    </nav>
    """
  end

  @doc """
  Switches between the dark theme, the light theme and the system preference.

  The choice is applied and persisted by the script in `root.html.heex`; which
  segment reads as active is derived from the `data-theme` and
  `data-theme-source` attributes it sets on `<html>`.
  """
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    assigns =
      assign(assigns, :themes, [
        {"system", "hero-computer-desktop-micro", "Follow the system theme",
         "[[data-theme-source=system]_&]:bg-active [[data-theme-source=system]_&]:text-ink"},
        {"light", "hero-sun-micro", "Light theme",
         "[[data-theme-source=user][data-theme=light]_&]:bg-active [[data-theme-source=user][data-theme=light]_&]:text-ink"},
        {"dark", "hero-moon-micro", "Dark theme",
         "[[data-theme-source=user][data-theme=dark]_&]:bg-active [[data-theme-source=user][data-theme=dark]_&]:text-ink"}
      ])

    ~H"""
    <div class={["flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5", @class]}>
      <button
        :for={{theme, icon, label, active_class} <- @themes}
        type="button"
        phx-click={JS.dispatch("phx:set-theme") |> JS.push("set_theme", value: %{theme: theme})}
        data-phx-theme={theme}
        title={label}
        aria-label={label}
        class={[
          "flex size-5 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:text-ink",
          active_class
        ]}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  # The left crow of the mark, on a 24-unit grid; the right one is its mirror image.
  @logo_wing "M4.8 15.2C2.9 12.4 1.6 8.4 1.2 3L2.2 5.4L2.6 2.4L3.4 5.3L4 2.8L4.5 5.7L5.3 4.2C5.6 7.4 6.4 9.6 7.6 11.8Z"
  @logo_body "M7.4 11.2C5.4 12.6 4.6 15.4 4.8 17.6L2.8 21.6L4.2 22.2L6.4 19.2C8.8 19.2 10.4 17.4 10.4 14.6C10.4 13.6 10.2 12.8 9.8 12.2Z"
  @logo_head "M13.16 4.53Q9.96 7.86 7.36 10.99C6.62 11.28 5.69 12.78 6.66 13.94C7.69 14.86 9.19 14.57 9.79 13.44C10.15 12.72 9.98 12.24 9.94 11.84Z"

  @doc """
  The MWT mark: two crows, Memory and Thought, facing each other. Their raised
  wings are the outer strokes of a W, their crossing beaks the inner ones.

  It is drawn in `currentColor`, the theme's ink unless the class says
  otherwise. The cuts between each wing and its body, and the eyes, are holes,
  so the mark sits on any background. Each use needs its own `id`, which also
  names its masks.
  """
  attr :id, :string, required: true
  attr :class, :any, default: "size-5"

  def logo(assigns) do
    assigns =
      assign(assigns,
        wing: @logo_wing,
        body: @logo_body,
        head: @logo_head,
        sides: [nil, "matrix(-1 0 0 1 24 0)"]
      )

    ~H"""
    <svg
      id={@id}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      class={["text-ink", @class]}
    >
      <defs>
        <mask id={"#{@id}-wings"} maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
          <rect width="24" height="24" fill="#fff" />
          <g
            :for={side <- @sides}
            transform={side}
            fill="none"
            stroke="#000"
            stroke-width="0.7"
            stroke-linejoin="round"
          >
            <path d={@body} />
            <path d={@head} />
          </g>
        </mask>
        <mask id={"#{@id}-eyes"} maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
          <rect width="24" height="24" fill="#fff" />
          <circle :for={side <- @sides} transform={side} cx="7.54" cy="11.99" r="0.65" fill="#000" />
        </mask>
      </defs>
      <g mask={"url(##{@id}-wings)"}>
        <path :for={side <- @sides} transform={side} d={@wing} />
      </g>
      <g mask={"url(##{@id}-eyes)"}>
        <g :for={side <- @sides} transform={side}>
          <path d={@body} />
          <path d={@head} />
        </g>
      </g>
    </svg>
    """
  end

  @doc """
  Floats the notices raised through `MWTClientWeb.Notices` in the bottom left
  corner, the ones waiting to be dismissed ahead of the ones leaving on their own.

  The padding stands in for the corner offset so the cards' shadows are not
  clipped when a long stack has to scroll.
  """
  attr :notices, :list, required: true

  def notice_group(assigns) do
    {persistent, passing} = Enum.split_with(assigns.notices, &Notices.persistent?/1)
    assigns = assign(assigns, :notices, persistent ++ passing)

    ~H"""
    <div
      :if={@notices != []}
      id="notices"
      aria-live="polite"
      class="pointer-events-none fixed bottom-0 left-0 z-50 flex max-h-[calc(100vh-2.25rem)] w-[25.5rem] max-w-full flex-col gap-2 overflow-y-auto p-3"
    >
      <.notice :for={notice <- @notices} notice={notice} />
    </div>
    """
  end

  attr :notice, :map, required: true

  defp notice(assigns) do
    assigns = assign(assigns, :persistent?, Notices.persistent?(assigns.notice))

    ~H"""
    <div
      id={"notice-#{@notice.id}"}
      role={if @persistent?, do: "alert", else: "status"}
      phx-hook={if not @persistent?, do: "NoticeTimer"}
      data-notice-id={@notice.id}
      data-timeout={if not @persistent?, do: "6000"}
      class={[
        "pointer-events-auto flex shrink-0 items-start gap-2.5 rounded-lg border bg-panel px-3 py-2.5",
        "shadow-lg shadow-black/10 dark:shadow-black/40",
        "transition duration-150 ease-out motion-safe:starting:translate-y-1.5 starting:opacity-0",
        notice_border(@notice.kind)
      ]}
    >
      <.icon
        name={notice_icon(@notice.kind)}
        class={["mt-px size-4 shrink-0", notice_tone(@notice.kind)]}
      />
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <p class={["min-w-0 flex-1 text-[11px] font-semibold", notice_tone(@notice.kind)]}>
            {@notice.title}
          </p>
          <span
            :if={@notice.source}
            class="max-w-[40%] shrink-0 truncate font-mono text-[10px] text-faint"
          >
            {@notice.source}
          </span>
        </div>
        <pre
          :if={@notice.body not in [nil, ""]}
          class={[
            "mt-0.5 max-h-40 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed",
            if(@persistent?, do: "text-ink/90", else: "text-muted")
          ]}
          phx-no-curly-interpolation
        ><%= @notice.body %></pre>
      </div>
      <button
        type="button"
        id={"dismiss-notice-#{@notice.id}"}
        phx-click="dismiss_notice"
        phx-value-id={@notice.id}
        title="Dismiss"
        aria-label="Dismiss"
        class="flex size-5 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp notice_icon(:success), do: "hero-check-circle"
  defp notice_icon(:info), do: "hero-information-circle"
  defp notice_icon(:warning), do: "hero-exclamation-triangle"
  defp notice_icon(:error), do: "hero-exclamation-circle"

  defp notice_tone(:success), do: "text-ok"
  defp notice_tone(:info), do: "text-accent"
  defp notice_tone(:warning), do: "text-warn"
  defp notice_tone(:error), do: "text-bad"

  defp notice_border(:success), do: "border-ok/30"
  defp notice_border(:info), do: "border-accent/40"
  defp notice_border(:warning), do: "border-warn/40"
  defp notice_border(:error), do: "border-bad/40"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed bottom-3 right-3 z-50 flex w-80 flex-col gap-2"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't reach the app"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
