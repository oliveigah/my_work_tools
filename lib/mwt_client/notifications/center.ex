defmodule MWTClient.Notifications.Center do
  @moduledoc """
  What is notified now, for every identity, and its delivery to the desktop
  MWT runs in, through the freedesktop notification service on the session
  bus (GNOME Shell's, on GNOME). Apps don't call it: they go through
  `MWTClient.Notifications`, which decides what reaches the desktop.

  One connection (`MWTClient.DBus.Connection`) serves the whole app and stays
  open while MWT runs. GNOME sends a notification's clicks only to the
  connection that showed it, and removes an app's notifications as soon as
  that connection closes, so a short-lived sender such as `notify-send`
  can't do this.

  Whoever shows a notification picks its key; showing the same key again
  updates it in place. A notification belongs to the process that showed
  it and closes when that process ends, so a locked vault leaves none
  behind. Until then it is listed (`list/1`), which is what MWT's own pages
  show, whether or not it reached the desktop.

  A notice is `%{kind:, summary:, body:, scope:, open:, desktop:}`: the
  kind of notification (`MWTClient.Notifications.kinds/0`), plain text (the
  body is escaped for GNOME, which reads it as markup), the username it is
  for, the MWT path a click opens, and whether it goes to the desktop. One
  that doesn't is only listed; `refilter/3` changes that for what is
  listed. A notification you dismiss on the desktop stays listed (what it
  is about still waits) and isn't shown there again until it is shown
  anew.

  Whatever changes an identity's list is told to its pages
  (`MWTClient.Notifications.subscribe/1`) as `:notifications_changed`; a
  click as `{:desktop_open, path, token}`, where `token` is the activation
  token the desktop sent with the click, which a Wayland window needs to
  come forward, or nil.

  GNOME attributes the notifications to MWT's desktop entry (`MWT.desktop`,
  which the packages install), so they carry MWT's name and icon and follow
  its switch in GNOME's notification settings. Signals are taken only from
  the service that showed the notification.

  With no session bus (a server, a remote shell) or no notification
  service, it keeps track of what it would show, so `list/1` answers the
  same, and tries again every `:retry_every` milliseconds. With
  `address: nil` (tests) it never connects.
  """

  use GenServer

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.DBus.{Connection, Message}

  @service "org.freedesktop.Notifications"
  @path "/org/freedesktop/Notifications"
  @app_name "MWT"
  @desktop_entry "MWT"
  @summary_limit 120
  @body_limit 400

  @type key :: term()

  @type notice :: %{
          kind: String.t(),
          summary: String.t(),
          body: String.t(),
          scope: String.t(),
          open: String.t(),
          desktop: boolean(),
          quiet: boolean()
        }

  @type listed :: %{
          key: key(),
          notice: notice(),
          shown?: boolean(),
          since: DateTime.t()
        }

  @type status ::
          :off
          | :connecting
          | {:connected, %{name: String.t(), vendor: String.t(), version: String.t()}}
          | {:unavailable, String.t()}

  ## Client

  @doc """
  Starts the service. Options: `:name`; `:address`, a D-Bus address,
  `:session` or nil (by default from `config :mwt_client, #{inspect(__MODULE__)}`,
  else `:session`); `:retry_every` in milliseconds (30 seconds).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Shows `notice` under `key`, or updates the one shown under it. It belongs
  to the calling process.
  """
  @spec show(GenServer.server(), key(), notice()) :: :ok
  def show(server \\ __MODULE__, key, %{} = notice),
    do: GenServer.cast(server, {:show, key, clean(notice), self()})

  @doc "Closes the notification shown under `key`, if there is one."
  @spec close(GenServer.server(), key()) :: :ok
  def close(server \\ __MODULE__, key), do: GenServer.cast(server, {:close, key})

  @doc """
  What is shown, oldest first: each key, its notice, whether the desktop
  has it (`shown?`; false while there is no connection, and for a notice
  that doesn't go there), and when it was first shown.
  """
  @spec list(GenServer.server()) :: [listed()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc """
  Decides again, for each notice of `scope`, whether it goes to the desktop:
  `fun` gets the notice and answers. Those that now go are shown there,
  those that no longer go are closed there; all stay listed.
  """
  @spec refilter(GenServer.server(), String.t(), (notice() -> boolean())) :: :ok
  def refilter(server \\ __MODULE__, scope, fun),
    do: GenServer.call(server, {:refilter, scope, fun})

  @doc "Whether notifications reach the desktop, and through what."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The PubSub topic `username`'s pages hear about their notifications on."
  def topic(username), do: "notifications:" <> Accounts.id(username)

  # Valid UTF-8 without NUL bytes (the bus drops a connection sending
  # anything else), single-line summaries, and both kept short: GNOME
  # truncates long ones anyway.
  defp clean(notice) do
    %{
      kind: Map.get(notice, :kind, "other"),
      summary: notice.summary |> text() |> String.replace(~r/\s+/, " ") |> cut(@summary_limit),
      body: notice.body |> text() |> cut(@body_limit),
      scope: Map.fetch!(notice, :scope),
      open: Map.fetch!(notice, :open),
      desktop: Map.get(notice, :desktop, true) == true,
      quiet: Map.get(notice, :quiet, false) == true
    }
  end

  defp text(value) do
    value
    |> to_string()
    |> String.replace_invalid()
    |> String.replace(<<0>>, "")
    |> String.trim()
  end

  defp cut(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit - 1) <> "…",
      else: text
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Application.get_env(:mwt_client, __MODULE__, [])
    address = Keyword.get(opts, :address, Keyword.get(config, :address, :session))

    state = %{
      address: address,
      retry_every: Keyword.get(opts, :retry_every, 30_000),
      conn: nil,
      service: nil,
      status: if(address, do: :connecting, else: :off),
      retry: nil,
      # key => %{notice, owner, id (nil until the desktop has it), at,
      # since, dismissed? (closed on the desktop since it was last shown)}
      entries: %{},
      ids: %{},
      tokens: %{},
      owners: %{},
      counter: 0
    }

    if address, do: send(self(), :retry)
    {:ok, state}
  end

  @impl true
  def handle_cast({:show, key, notice, owner}, state) do
    previous = Map.get(state.entries, key)

    entry = %{
      notice: notice,
      owner: owner,
      id: previous && previous.id,
      at: (previous && previous.at) || state.counter,
      since: (previous && previous.since) || DateTime.utc_now(),
      dismissed?: false
    }

    state =
      state
      |> watch(owner)
      |> Map.update!(:counter, &(&1 + 1))
      |> put_in([:entries, key], entry)

    changed(notice.scope)
    {:noreply, place(state, key)}
  end

  def handle_cast({:close, key}, state), do: {:noreply, close_key(state, key)}

  @impl true
  def handle_call(:list, _from, state) do
    list =
      state.entries
      |> Enum.sort_by(fn {_key, entry} -> entry.at end)
      |> Enum.map(fn {key, entry} ->
        %{key: key, notice: entry.notice, shown?: entry.id != nil, since: entry.since}
      end)

    {:reply, list, state}
  end

  def handle_call({:refilter, scope, fun}, _from, state) do
    state =
      state.entries
      |> Enum.filter(fn {_key, entry} -> entry.notice.scope == scope end)
      |> Enum.reduce(state, fn {key, entry}, acc ->
        desktop = fun.(entry.notice) == true

        if desktop == entry.notice.desktop,
          do: acc,
          else: acc |> put_in([:entries, key, :notice, :desktop], desktop) |> place(key)
      end)

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:retry, %{conn: nil} = state), do: {:noreply, connect(%{state | retry: nil})}
  def handle_info(:retry, state), do: {:noreply, ready(%{state | retry: nil}, state.conn)}

  def handle_info({:dbus_signal, conn, %Message{} = signal}, %{conn: conn} = state) do
    if signal.sender == state.service and signal.path == @path and
         signal.interface == @service,
       do: {:noreply, on_signal(state, signal.member, signal.body)},
       else: {:noreply, state}
  end

  def handle_info({:dbus_signal, _old_conn, _signal}, state), do: {:noreply, state}

  # Nobody calls MWT here; a call is answered so the caller doesn't wait.
  def handle_info({:dbus_method_call, conn, call}, state) do
    unless :no_reply_expected in call.flags do
      Connection.send_message(
        conn,
        Message.error(call, "org.freedesktop.DBus.Error.UnknownMethod", "MWT serves nothing here")
      )
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.info("Desktop notifications lost the session bus: #{inspect(reason)}")

    state = %{
      state
      | conn: nil,
        service: nil,
        status: {:unavailable, "The connection to the session bus closed."},
        entries: Map.new(state.entries, fn {key, entry} -> {key, %{entry | id: nil}} end),
        ids: %{},
        tokens: %{}
    }

    {:noreply, retry(state, 1_000)}
  end

  # A connection that failed to start also exits.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    keys = for {key, %{owner: ^owner}} <- state.entries, do: key
    state = %{state | owners: Map.delete(state.owners, owner)}
    {:noreply, Enum.reduce(keys, state, &close_key(&2, &1))}
  end

  defp close_key(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        take_down(state, entry.id)
        changed(entry.notice.scope)
        %{state | entries: entries} |> forget_id(entry.id) |> unwatch(entry.owner)
    end
  end

  defp take_down(state, id) do
    if id && state.conn do
      Connection.send_message(state.conn, %{
        Message.call(@service, @path, @service, "CloseNotification", "u", [id])
        | flags: [:no_reply_expected]
      })
    end
  end

  # Shows a notice on the desktop, or takes it down from there, as it says.
  defp place(state, key) do
    entry = state.entries[key]

    if entry.notice.desktop do
      deliver(state, key)
    else
      take_down(state, entry.id)

      state
      |> forget_id(entry.id)
      |> put_in([:entries, key, :id], nil)
    end
  end

  defp changed(scope),
    do: Phoenix.PubSub.broadcast(MWTClient.PubSub, topic(scope), :notifications_changed)

  ## Signals

  defp on_signal(state, "ActivationToken", [id, token]) when is_map_key(state.ids, id),
    do: put_in(state.tokens[id], token)

  defp on_signal(state, "ActionInvoked", [id, _action]) when is_map_key(state.ids, id) do
    key = state.ids[id]
    %{notice: notice} = state.entries[key]

    Phoenix.PubSub.broadcast(
      MWTClient.PubSub,
      topic(notice.scope),
      {:desktop_open, notice.open, state.tokens[id]}
    )

    %{state | tokens: Map.delete(state.tokens, id)}
  end

  # Dismissed, expired, or gone after a click: off the desktop, but still
  # listed, since what it is about still waits. It goes back to the desktop
  # only when shown anew.
  defp on_signal(state, "NotificationClosed", [id, _reason]) when is_map_key(state.ids, id) do
    key = state.ids[id]

    state
    |> forget_id(id)
    |> update_in([:entries, key], &%{&1 | id: nil, dismissed?: true})
  end

  defp on_signal(state, _member, _body), do: state

  ## Connection

  defp connect(state) do
    case Connection.start_link(owner: self(), address: state.address) do
      {:ok, conn} -> ready(%{state | conn: conn}, conn)
      {:error, reason} -> retry(%{state | status: {:unavailable, describe(reason)}})
    end
  end

  # Finds the notification service and shows what it doesn't have yet. The
  # connection stays open when there is none: one may start later.
  defp ready(state, conn) do
    case server_information(conn) do
      {:ok, sender, info} ->
        state = %{state | service: sender, status: {:connected, info}}
        state |> pending() |> Enum.reduce(state, &deliver(&2, &1))

      {:error, reason} ->
        retry(%{state | status: {:unavailable, reason}})
    end
  end

  defp server_information(conn) do
    message = Message.call(@service, @path, @service, "GetServerInformation")

    case Connection.call(conn, message) do
      {:ok, %Message{sender: sender, body: [name, vendor, version, _spec]}} ->
        {:ok, sender, %{name: name, vendor: vendor, version: version}}

      {:ok, _other} ->
        {:error, "The notification service answered in a way MWT doesn't understand."}

      {:error, {:dbus, "org.freedesktop.DBus.Error.ServiceUnknown", _text}} ->
        {:error, "No notification service runs on this desktop."}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  # Entries the desktop doesn't have yet and should, oldest first.
  defp pending(state) do
    state.entries
    |> Enum.filter(fn {_key, entry} ->
      is_nil(entry.id) and entry.notice.desktop and not entry.dismissed?
    end)
    |> Enum.sort_by(fn {_key, entry} -> entry.at end)
    |> Enum.map(&elem(&1, 0))
  end

  defp deliver(%{status: {:connected, _info}, conn: conn} = state, key) when conn != nil do
    entry = state.entries[key]

    case Connection.call(conn, notify(entry)) do
      {:ok, %Message{body: [id]}} ->
        state = if entry.id && entry.id != id, do: forget_id(state, entry.id), else: state

        state
        |> put_in([:entries, key, :id], id)
        |> put_in([:ids, id], key)

      {:error, reason} ->
        Logger.warning("Desktop notification not shown: #{inspect(reason)}")
        retry(%{state | status: {:unavailable, describe(reason)}})
    end
  end

  # Not connected: it goes out once there is a connection.
  defp deliver(state, _key), do: state

  defp notify(%{notice: notice, id: id}) do
    Message.call(@service, @path, @service, "Notify", "susssasa{sv}i", [
      @app_name,
      id || 0,
      "",
      notice.summary,
      escape(notice.body),
      # "default" is a click on the notification itself.
      ["default", "Open", "review", "Review"],
      %{"desktop-entry" => {"s", @desktop_entry}, "urgency" => {"y", 1}},
      -1
    ])
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp retry(state, after_ms \\ nil) do
    if state.retry, do: Process.cancel_timer(state.retry)
    %{state | retry: Process.send_after(self(), :retry, after_ms || state.retry_every)}
  end

  ## Owners and ids

  defp watch(state, nil), do: state
  defp watch(state, owner) when is_map_key(state.owners, owner), do: state

  defp watch(state, owner),
    do: %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}

  defp unwatch(state, owner) do
    if Enum.any?(state.entries, fn {_key, entry} -> entry.owner == owner end) do
      state
    else
      case Map.pop(state.owners, owner) do
        {nil, _owners} ->
          state

        {ref, owners} ->
          Process.demonitor(ref, [:flush])
          %{state | owners: owners}
      end
    end
  end

  defp forget_id(state, nil), do: state

  defp forget_id(state, id),
    do: %{state | ids: Map.delete(state.ids, id), tokens: Map.delete(state.tokens, id)}

  defp describe(:no_session_bus), do: "There's no desktop session bus."
  defp describe(:unsupported_address), do: "The session bus address isn't a Unix socket."
  defp describe(:timeout), do: "The desktop didn't answer in time."
  defp describe(:closed), do: "The connection to the session bus closed."
  defp describe({:connect, reason}), do: "Couldn't reach the session bus (#{inspect(reason)})."
  defp describe({:auth, reason}), do: "The session bus refused MWT (#{inspect(reason)})."
  defp describe({:dbus, _name, text}), do: "The notification service refused: #{text}"
  defp describe(other), do: "Couldn't use the session bus: #{inspect(other)}"
end
