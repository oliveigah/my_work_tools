defmodule MWTClientWeb.Hooks.Places do
  @moduledoc """
  Brings a tool back where it was left when you switch to another and
  return (`MWTClient.Places`).

  Every signed in page gets `places`, the page each tool was last on, for
  the title bar to link to. While a tool is open, the page it is on is
  recorded after each `handle_params`, and, for a tool that implements
  this module's `c:place/1`, what that returns is kept after each render
  that changed it. Keeping it as it changes, rather than when the tool is
  left, means a page that reconnects (after the machine slept, say) comes
  back as it was too.

  A tool takes its place back in its own `mount/3`, with
  `MWTClient.Places.recall/2`, and checks it against what still exists.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  alias MWTClient.Places

  @doc """
  What places the tool: the assigns that make it look as it does, beyond
  what its URL says. Cheap, as it runs after every render.
  """
  @callback place(Phoenix.LiveView.Socket.t()) :: map()

  def on_mount(:default, _params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    socket = assign(socket, :places, Places.paths(username))

    if connected?(socket) do
      {:cont,
       socket
       |> attach_hook(:places_visit, :handle_params, &visit/3)
       |> attach_hook(:places_keep, :after_render, &keep/1)}
    else
      {:cont, socket}
    end
  end

  defp visit(_params, uri, socket) do
    case socket.assigns[:tool] do
      %{id: tool} ->
        %URI{path: path, query: query} = URI.parse(uri)
        page = if query in [nil, ""], do: path, else: path <> "?" <> query
        :ok = Places.visit(username(socket), tool, page)

      _not_a_tool ->
        :ok
    end

    {:cont, socket}
  end

  defp keep(socket) do
    with %{id: tool} <- socket.assigns[:tool],
         true <- function_exported?(socket.view, :place, 1),
         place = socket.view.place(socket),
         false <- place == socket.private[:kept_place] do
      :ok = Places.keep(username(socket), tool, place)
      put_private(socket, :kept_place, place)
    else
      _unchanged_or_not_a_tool -> socket
    end
  end

  defp username(socket), do: socket.assigns.current_scope.user.username
end
