defmodule MWTClientWeb.Hooks.Notifications do
  @moduledoc """
  Keeps every signed in page in step with your notifications
  (`MWTClient.Notifications`): the count the title bar's bell shows, and
  what a click on one on the desktop opens, from whichever page is open.

  On a click the window comes forward first: the page asks the desktop shell
  to present it with the activation token the click carried
  (`mwt:present-window`), without which GNOME on Wayland only flags the
  window. Then it navigates, in a second step, so the event reaches the page
  before it is replaced.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3, push_navigate: 2]

  alias MWTClient.Notifications

  def on_mount(:default, _params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Notifications.subscribe(username)

    {:cont,
     socket
     |> assign(:notifications, Notifications.count(username))
     |> attach_hook(:notifications, :handle_info, &handle_info/2)}
  end

  # A page that lists them (it has `notification_list`) gets the list anew.
  defp handle_info(:notifications_changed, socket) do
    list = Notifications.list(socket.assigns.current_scope.user.username)
    socket = assign(socket, :notifications, length(list))

    {:halt,
     if(Map.has_key?(socket.assigns, :notification_list),
       do: assign(socket, :notification_list, list),
       else: socket
     )}
  end

  defp handle_info({:desktop_open, path, token}, socket) do
    send(self(), {:desktop_navigate, path})
    {:halt, push_event(socket, "mwt:present-window", %{token: token})}
  end

  defp handle_info({:desktop_navigate, path}, socket),
    do: {:halt, push_navigate(socket, to: path)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
