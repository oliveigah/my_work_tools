defmodule MWTClientWeb.NotificationsLive do
  @moduledoc """
  Your notifications, from every app (`MWTClient.Notifications`): what
  waits for you now, each a link to where you deal with it, and the
  settings that decide which of them reach the desktop.

  The list follows along as notifications come and go
  (`MWTClientWeb.Hooks.Notifications` keeps `notification_list` current).
  """
  use MWTClientWeb, :live_view

  alias MWTClient.Notifications

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username

    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> assign(:username, username)
     |> assign(:notification_list, Notifications.list(username))
     |> assign(:settings, Notifications.settings(username))
     |> assign(:desktop, Notifications.status())}
  end

  @impl true
  def handle_event("set_desktop", %{"on" => on}, socket) do
    settings = Notifications.put_settings(socket.assigns.username, %{desktop: on == "true"})
    {:noreply, assign(socket, :settings, settings)}
  end

  def handle_event("set_kind", %{"kind" => kind, "on" => on}, socket) do
    settings =
      Notifications.put_settings(socket.assigns.username, %{kinds: %{kind => on == "true"}})

    {:noreply, assign(socket, :settings, settings)}
  end

  # The test belongs to this page, so it goes when the page does.
  def handle_event("test", _params, socket) do
    Notifications.test(socket.assigns.username)

    {:noreply,
     socket
     |> assign(:desktop, Notifications.status())
     |> put_notice(:info, "Sent a test notification")}
  end

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
      <div class="flex min-h-0 flex-1 overflow-y-auto px-6 py-8 sm:px-10">
        <div class="mx-auto w-full max-w-3xl space-y-6">
          <header>
            <h1 class="flex items-center gap-2 text-lg font-semibold tracking-tight text-ink">
              Notifications
              <.help id="notifications-help" label="About notifications">
                What waits for you in any app: an agent's request, work handed off for review. Each is listed here until it no longer waits, and shown on the desktop unless you turn that off below. Clicking one opens it.
              </.help>
            </h1>
          </header>

          <section
            id="notification-list"
            class="overflow-hidden rounded-xl border border-line bg-panel"
          >
            <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2.5">
              <.icon name="hero-bell-micro" class="size-4 text-faint" />
              <span class="text-[13px] font-semibold text-ink">Waiting for you</span>
              <span class="ml-auto text-[11px] tabular-nums text-faint">
                {length(@notification_list)}
              </span>
            </header>
            <ul class="divide-y divide-line-soft">
              <li :if={@notification_list == []} id="notifications-empty">
                <div class="flex flex-col items-center gap-2 px-6 py-10 text-center">
                  <span class="flex size-9 items-center justify-center rounded-full bg-deep text-faint">
                    <.icon name="hero-bell-slash" class="size-4" />
                  </span>
                  <p class="text-xs text-muted">Nothing waits for you.</p>
                </div>
              </li>
              <li
                :for={{item, i} <- Enum.with_index(@notification_list)}
                id={"notification-#{i}"}
              >
                <.link
                  navigate={item.open}
                  class="group flex items-start gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
                >
                  <span class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-md bg-accent-soft/50 text-accent">
                    <.icon name={kind_icon(item.kind)} class="size-4" />
                  </span>
                  <div class="min-w-0 flex-1">
                    <p class="flex flex-wrap items-baseline gap-x-2">
                      <span class="text-[13px] font-medium text-ink group-hover:text-accent">
                        {item.summary}
                      </span>
                      <span class="text-[11px] text-faint">{ago(item.since)}</span>
                    </p>
                    <p
                      :if={item.body != ""}
                      class="mt-0.5 whitespace-pre-line text-[12px] leading-5 text-muted"
                    >
                      {item.body}
                    </p>
                    <p class="mt-1 text-[10px] font-medium uppercase tracking-wide text-faint">
                      {kind_label(item.kind)}
                    </p>
                  </div>
                  <.icon
                    name="hero-chevron-right-micro"
                    class="mt-1.5 size-4 shrink-0 text-faint transition-transform group-hover:translate-x-0.5 group-hover:text-accent"
                  />
                </.link>
              </li>
            </ul>
          </section>

          <section
            id="notification-settings"
            class="overflow-hidden rounded-xl border border-line bg-panel"
          >
            <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2.5">
              <.icon name="hero-computer-desktop-micro" class="size-4 text-faint" />
              <span class="text-[13px] font-semibold text-ink">On the desktop</span>
              <.help id="notifications-desktop-help" label="About desktop notifications">
                A notification on your desktop for each, so you hear of it while working in another window; clicking one brings MWT forward on it. GNOME lists them under MWT in Settings, Notifications, where you can turn off banners or sounds. Turned off here, they are still listed above.
              </.help>
            </header>
            <div class="space-y-3 px-4 py-3">
              <div class="flex items-center gap-3">
                <.switch
                  id="notifications-desktop-switch"
                  on={@settings.desktop}
                  label="Desktop notifications"
                  phx-click="set_desktop"
                  phx-value-on={to_string(not @settings.desktop)}
                />
                <span class="flex-1 text-xs text-ink">Show notifications on the desktop</span>
                <.button
                  type="button"
                  id="notifications-test"
                  phx-click="test"
                  disabled={not match?({:connected, _}, @desktop)}
                >
                  Send a test
                </.button>
              </div>
              <p id="notifications-status" class="flex items-start gap-1.5 text-[11px] leading-4">
                <span class={[
                  "mt-1 size-1.5 shrink-0 rounded-full",
                  case @desktop do
                    {:connected, _info} -> "bg-ok"
                    :connecting -> "bg-warn motion-safe:animate-pulse"
                    _other -> "bg-faint"
                  end
                ]}></span>
                <span class="text-muted">{desktop_words(@desktop)}</span>
              </p>
              <ul class="divide-y divide-line-soft rounded-lg border border-line-soft">
                <li
                  :for={kind <- Notifications.kinds()}
                  id={"notifications-kind-#{dom_id(kind.id)}"}
                  class={[
                    "flex items-center gap-3 px-3 py-2 transition-opacity",
                    not @settings.desktop && "opacity-50"
                  ]}
                >
                  <.icon name={kind_icon(kind.id)} class="size-4 shrink-0 text-faint" />
                  <div class="min-w-0 flex-1">
                    <p class="text-xs text-ink">
                      {kind.name} <span class="text-faint">· {kind.app}</span>
                    </p>
                    <p class="text-[11px] text-muted">{kind.text}</p>
                  </div>
                  <.switch
                    id={"notifications-kind-switch-#{dom_id(kind.id)}"}
                    on={@settings.kinds[kind.id]}
                    label={"#{kind.name} on the desktop"}
                    phx-click="set_kind"
                    phx-value-kind={kind.id}
                    phx-value-on={to_string(not @settings.kinds[kind.id])}
                    disabled={not @settings.desktop}
                  />
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dom_id(kind), do: String.replace(kind, ~r/[^a-z0-9]+/, "-")

  defp kind_icon("sandbox.approvals"), do: "hero-hand-raised"
  defp kind_icon("sandbox.handoffs"), do: "hero-inbox-arrow-down"
  defp kind_icon(_other), do: "hero-bell"

  defp kind_label(kind) do
    case Enum.find(Notifications.kinds(), &(&1.id == kind)) do
      nil -> "MWT"
      found -> "#{found.app} · #{found.name}"
    end
  end

  defp ago(at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  defp desktop_words({:connected, %{name: name, version: version}}),
    do: "Shown by #{name} #{version}, through the session bus"

  defp desktop_words(:connecting), do: "Connecting to the desktop…"
  defp desktop_words({:unavailable, reason}), do: reason
  defp desktop_words(:off), do: "Not shown here: this MWT runs without a desktop"
  defp desktop_words(_status), do: "Checking the desktop…"
end
