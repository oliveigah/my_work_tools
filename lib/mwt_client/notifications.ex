defmodule MWTClient.Notifications do
  @moduledoc """
  MWT's notifications, for every app: something that waits for you, said
  once where you'll see it.

  An app notifies under a key of its choosing (`notify/4`) and withdraws it
  when it no longer waits (`withdraw/2`); notifying the same key again
  updates it. A notification belongs to the process that made it and goes
  when that process ends, so an app's notifications go with it (a locked
  vault leaves none behind).

  Every notification is listed in MWT: the bell in the title bar counts
  them and `/notifications` shows them (`list/1`). Each also goes to the
  desktop (`MWTClient.Notifications.Center`), unless your settings say
  otherwise: desktop notifications off, or this kind off (`settings/1`).
  Clicking one, on the desktop or in MWT, opens the page it names.

  Each notification is of a kind (`kinds/0`), which says which app it comes
  from and what it is about, so you can turn one kind off without the
  others. An app with something new to notify adds its kind there.

  | Kind                | What it is about                                    |
  | ------------------- | --------------------------------------------------- |
  | `sandbox.approvals` | an agent's use or ask that waits for your decision  |
  | `sandbox.handoffs`  | work an agent handed off, waiting for your review   |
  | `sandbox.firewall`  | the firewall isolated the VM, or alerts you         |
  """

  alias MWTClient.{Accounts, Preferences}
  alias MWTClient.Notifications.Center

  @kinds [
    %{
      id: "sandbox.approvals",
      app: "Agent Sandbox",
      name: "Approvals",
      text: "An agent's request or ask waits for your decision"
    },
    %{
      id: "sandbox.handoffs",
      app: "Agent Sandbox",
      name: "Handoffs",
      text: "An agent handed work off for you to review"
    },
    %{
      id: "sandbox.firewall",
      app: "Agent Sandbox",
      name: "Firewall",
      text: "The firewall isolated the VM, or saw something it alerts you of"
    }
  ]

  @preference "notifications"

  @type kind :: String.t()

  @typedoc """
  What an app notifies: its kind, a one-line summary, a few lines of body
  (plain text), and the MWT path a click opens.
  """
  @type notice :: %{kind: kind(), summary: String.t(), body: String.t(), open: String.t()}

  @type settings :: %{desktop: boolean(), kinds: %{kind() => boolean()}}

  @type listed :: %{
          key: term(),
          kind: kind(),
          summary: String.t(),
          body: String.t(),
          open: String.t(),
          since: DateTime.t(),
          shown?: boolean()
        }

  @doc "Every kind of notification, with the app it comes from and what it is about."
  @spec kinds() :: [%{id: kind(), app: String.t(), name: String.t(), text: String.t()}]
  def kinds, do: @kinds

  @doc """
  Notifies `username` of `notice` under `key`, or updates what is notified
  under it. It belongs to the calling process.

  With `quiet: true` it is listed in MWT but never put on the desktop: for
  what waited before MWT started, which the desktop already told you of.
  """
  @spec notify(String.t(), term(), notice(), keyword()) :: :ok
  def notify(username, key, %{kind: kind} = notice, opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)

    Center.show(
      {username, key},
      Map.merge(notice, %{
        scope: username,
        quiet: quiet?,
        desktop: not quiet? and desktop?(settings(username), kind)
      })
    )
  end

  @doc "Withdraws what is notified to `username` under `key`, if anything."
  @spec withdraw(String.t(), term()) :: :ok
  def withdraw(username, key), do: Center.close({username, key})

  @doc "What is notified to `username` now, newest first."
  @spec list(String.t()) :: [listed()]
  def list(username) do
    for %{key: {^username, key}, notice: notice, shown?: shown?, since: since} <- center_list() do
      %{
        key: key,
        kind: notice.kind,
        summary: notice.summary,
        body: notice.body,
        open: notice.open,
        since: since,
        shown?: shown?
      }
    end
    |> Enum.reverse()
  end

  @doc "How many notifications `username` has now."
  @spec count(String.t()) :: non_neg_integer()
  def count(username), do: length(list(username))

  @doc """
  Subscribes the caller to `username`'s notifications: `:notifications_changed`
  when they change, `{:desktop_open, path, token}` when one is clicked on
  the desktop.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  @doc false
  def topic(username), do: Center.topic(username)

  @doc "Whether notifications reach the desktop, and through what (`Center.status/1`)."
  @spec status() :: Center.status()
  def status do
    Center.status()
  catch
    :exit, _not_running -> {:unavailable, "MWT's notifications aren't running: restart MWT."}
  end

  # The center runs from MWT's start. Code reloaded into a running MWT in
  # development doesn't start it, so pages read nothing rather than fail.
  defp center_list do
    Center.list()
  catch
    :exit, _not_running -> []
  end

  ## Settings

  @doc """
  `username`'s settings: whether notifications go to the desktop, and each
  kind on or off. Everything is on until turned off.
  """
  @spec settings(String.t()) :: settings()
  def settings(username) do
    saved = Map.get(Preferences.get(@preference) || %{}, Accounts.id(username)) || %{}
    off = List.wrap(saved["off"])

    %{
      desktop: saved["desktop"] != false,
      kinds: Map.new(@kinds, &{&1.id, &1.id not in off})
    }
  end

  @doc """
  Changes `username`'s settings: `:desktop`, and kinds by id in `:kinds`.
  What is notified now follows at once: it goes to the desktop, or comes
  off it.
  """
  @spec put_settings(String.t(), map()) :: settings()
  def put_settings(username, changes) do
    current = settings(username)

    updated = %{
      desktop: Map.get(changes, :desktop, current.desktop) == true,
      kinds:
        Map.merge(
          current.kinds,
          Map.new(Map.get(changes, :kinds, %{}), fn {kind, on} -> {kind, on == true} end)
          |> Map.take(Map.keys(current.kinds))
        )
    }

    all = Preferences.get(@preference) || %{}

    saved = %{
      "desktop" => updated.desktop,
      "off" => for({kind, false} <- updated.kinds, do: kind) |> Enum.sort()
    }

    :ok = Preferences.put(@preference, Map.put(all, Accounts.id(username), saved))

    try do
      Center.refilter(username, fn notice ->
        not Map.get(notice, :quiet, false) and desktop?(updated, notice.kind)
      end)
    catch
      :exit, _not_running -> :ok
    end

    updated
  end

  @doc """
  Whether `username` ever saved notification settings: an older MWT kept
  one switch in the sandbox, which carries over only when there's nothing
  here yet.
  """
  @spec saved?(String.t()) :: boolean()
  def saved?(username),
    do: Map.has_key?(Preferences.get(@preference) || %{}, Accounts.id(username))

  @doc "Whether a notification of `kind` goes to the desktop under `settings`."
  @spec desktop?(settings(), kind()) :: boolean()
  def desktop?(settings, kind), do: settings.desktop and Map.get(settings.kinds, kind, true)

  @doc """
  Shows a test notification on the desktop, whatever the settings say, from
  the calling process; it opens the notifications page.
  """
  @spec test(String.t()) :: :ok
  def test(username) do
    Center.show({username, :test}, %{
      kind: "test",
      summary: "MWT notifications work",
      body: "What waits for you will show like this. Click one to open it in MWT.",
      scope: username,
      open: "/notifications",
      desktop: true
    })
  end
end
