defmodule MWTClient.Sandbox do
  @moduledoc """
  The agent sandbox: a microsandbox VM that agents run in, the grants that
  give it access, and the approvals that hold its requests.

  This module is the only way in for the control panel. Behind it,
  `MWTClient.Sandbox.Server` keeps one identity's sandbox and
  `MWTClient.Sandbox.Egress` is the proxy all of the VM's traffic goes
  through. `docs/agent_sandbox.md` has the design.

  Every function takes the username it belongs to. Changes are broadcast to
  `subscribe/1`rs as `{:sandbox_changed, area}`, new activity as
  `{:sandbox_event, event}` and image build output as
  `{:sandbox_build_line, line}`. `subscribe_waiting/1` delivers only
  `{:sandbox_waiting, count}`, for the title bar of every page.

  Approvals are of three types, in one queue: agents asking for a grant to
  be turned on (activations) or to run a command on the host (commands),
  both arriving through `MWTClient.Sandbox.Channel`, and uses of a grant
  held by the proxy. See `MWTClient.Sandbox.Approval`.
  """

  alias MWTClient.Sandbox.{
    Activity,
    Approval,
    Build,
    Destinations,
    Event,
    Grant,
    Guest,
    Memory,
    Ports,
    Projects,
    Server,
    Settings,
    Share,
    Shares,
    Snapshot,
    VM
  }

  @type username :: String.t()

  @type snapshot :: %{
          vm: VM.t(),
          settings: Settings.t(),
          grants: [Grant.t()],
          values: %{String.t() => boolean()},
          waiting: [Approval.t()],
          running: [Approval.t()],
          history: [Approval.t()],
          image: map(),
          builds: [Build.t()],
          created_ref: String.t() | nil,
          snapshots: [Snapshot.t()],
          memory: map(),
          folders: map(),
          proxy: map(),
          tools: map(),
          inbox: String.t(),
          host: map()
        }

  @typedoc """
  What creating the VM does to what it keeps:

    * `home` - `:keep` it, go back to `{:snapshot, id}`, or start `:empty`;
    * `cache` - `:keep` it or `:clear` it;
    * `seed_memory` - start the VM's memory from a copy of yours.

  Home is copied into a snapshot first whenever it holds anything.
  """
  @type create_options :: %{
          optional(:home) => :keep | :empty | {:snapshot, String.t()},
          optional(:cache) => :keep | :clear,
          optional(:seed_memory) => boolean()
        }

  @doc "Subscribes the caller to every change."
  @spec subscribe(username()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.topic(username))

  @doc "Subscribes the caller to the count of approvals waiting."
  @spec subscribe_waiting(username()) :: :ok | {:error, term()}
  def subscribe_waiting(username),
    do: Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.waiting_topic(username))

  @doc "Everything the control panel shows, apart from activity."
  @spec snapshot(username()) :: snapshot()
  def snapshot(username), do: Server.call(username, :snapshot)

  @doc "How many approvals of either type wait for you; 0 while locked."
  @spec waiting_count(username()) :: non_neg_integer()
  def waiting_count(username) do
    Server.call(username, :waiting_count)
  catch
    :exit, _locked -> 0
  end

  @doc """
  Activity, newest first.

  ## Filters

    * `:group` - one of the keys of `Event.groups/0`, or `"all"`
    * `:grant` - a grant id, or `""` for any
    * `:q` - words to look for in the summary, host and path
    * `:thread` - the id of the thread that asked, or `""` for any
    * `:since` - only events from this `DateTime` on, or nil for all kept
    * `:until` - only events up to this `DateTime`, or nil for up to now
    * `:before` - an event id: only events older than it, for the next page
    * `:limit` - at most this many, 200 by default

  Every event is kept in the identity's journal, for as long as its
  retention rule says (`MWTClient.Sandbox.Activity`).
  """
  @spec events(username(), map()) :: [Event.t()]
  def events(username, filters \\ %{}), do: Activity.events(username, filters)

  @doc """
  One event of the log, opened: for a request MWT read, with what it
  carried and what came back to the VM (`MWTClient.Sandbox.Activity.opened/2`).
  """
  @spec event(username(), String.t()) :: Event.t() | nil
  def event(username, id), do: Activity.opened(username, id)

  @doc """
  A card an action's decision names (`MWTClient.Sandbox.Decision`), as it
  was decided: `%{card: approval, choice: words}`, or nil once no line
  names it any more.
  """
  @spec audit_card(username(), String.t()) :: map() | nil
  def audit_card(username, id), do: MWTClient.Storage.Journal.card(username, id)

  @doc """
  The activity log's figures over the events kept that pass the
  same filters as `events/2` (`:limit` and `:before` aside): counts per
  group, bytes, busiest hosts, and a timeline (`MWTClient.Sandbox.EventStats`),
  from `:since`, or the oldest event kept, to now.
  """
  @spec event_stats(username(), map()) :: MWTClient.Sandbox.EventStats.t()
  def event_stats(username, filters \\ %{}),
    do: Activity.stats(username, filters, DateTime.truncate(DateTime.utc_now(), :second))

  @doc """
  The threads that asked for something since `:since` (all kept when nil),
  the most recent first, for the activity page's thread filter.
  """
  @spec event_threads(username(), map()) :: [map()]
  def event_threads(username, filters \\ %{}), do: Activity.threads(username, filters)

  @doc """
  What the VM takes on this machine, for the Storage page: its status, and
  each disk's size (what the VM sees) and used space (what this machine
  holds for it), the copies of Home with theirs, and how many image builds
  are kept.
  """
  @spec space(username()) :: map()
  def space(username), do: Server.call(username, :space)

  @doc """
  Gives this machine back the space the VM's disks hold for what the VM
  deleted, in the background, with the VM stopped (`Disks.reclaim!/1`).
  `space/1` says how it went.
  """
  @spec reclaim_space(username()) ::
          :ok | {:error, :busy | :running | {:needs, [String.t()]}}
  def reclaim_space(username), do: Server.call(username, :reclaim_space)

  @doc "Deletes a copy of the VM's Home."
  @spec delete_snapshot(username(), String.t()) :: :ok | {:error, :not_found}
  def delete_snapshot(username, id), do: Server.call(username, {:delete_snapshot, id})

  @doc "The certificate of the CA only the VM trusts, as PEM."
  @spec ca_pem(username()) :: String.t()
  def ca_pem(username), do: Server.call(username, :ca_pem)

  @doc """
  Builds the VM image with podman and loads it into microsandbox: MWT's
  base, your layer, MWT's final layer. `cache: false` builds every step
  again, for when a build may hold something damaged or stale.
  """
  @spec build_image(username(), keyword()) ::
          :ok | {:error, :busy | :no_podman | :no_msb | {:layer, String.t()}}
  def build_image(username, opts \\ []), do: Server.call(username, {:build_image, opts})

  @doc """
  Starts the VM, creating it first when it does not exist or its settings
  changed; `options` apply only then.
  """
  @spec start_vm(username(), create_options()) :: :ok | {:error, atom()}
  def start_vm(username, options \\ %{}), do: Server.call(username, {:start_vm, options})

  @doc "Stops the VM."
  @spec stop_vm(username()) :: :ok | {:error, :busy}
  def stop_vm(username), do: Server.call(username, :stop_vm)

  @doc "Creates the VM again from the current image, with the current settings."
  @spec recreate_vm(username(), create_options()) :: :ok | {:error, atom()}
  def recreate_vm(username, options \\ %{}), do: Server.call(username, {:recreate_vm, options})

  @doc """
  Stops the server listening on `port` in the VM, one of
  `MWTClient.Sandbox.Ports.range/0`: SIGTERM to each process holding it
  there (`MWTClient.Sandbox.Ports.stop_words/1`). Returns the process ids
  signalled. The VM's next report of what listens takes it off the list.
  """
  @spec stop_server(username(), integer()) ::
          {:ok, [pos_integer()]}
          | {:error, :out_of_range | :not_listening | :vm_not_running | String.t()}
  def stop_server(username, port) when is_integer(port) do
    with true <- port in Ports.range() || {:error, :out_of_range},
         {:ok, guest} <- Projects.guest(username, snapshot(username).vm),
         {:ok, output} <- guest.exec.(Ports.stop_words(port)) do
      case Ports.stopped(output) do
        [] ->
          {:error, :not_listening}

        pids ->
          Server.cast(
            username,
            {:log,
             %{
               outcome: :vm,
               summary:
                 "Stopped the server on port #{port} in the VM (pid #{Enum.join(pids, ", ")})"
             }}
          )

          {:ok, pids}
      end
    end
  end

  @doc "Makes a kept build current again. The VM picks it up when recreated."
  @spec use_build(username(), String.t()) :: :ok | {:error, :busy | :not_found}
  def use_build(username, ref), do: Server.call(username, {:use_build, ref})

  @doc """
  Deletes a build from microsandbox and podman, and from the builds kept:
  never the current one, nor the one the VM was created from.
  """
  @spec delete_build(username(), String.t()) ::
          :ok | {:error, :busy | :not_found | :current | :in_use}
  def delete_build(username, ref), do: Server.call(username, {:delete_build, ref})

  @doc """
  The VM's memories you haven't reviewed: those noted after its memory was
  copied from yours, or after your last review, read through the running
  VM. `upto` is what to pass to `bring_back/3` or `dismiss_memories/2` once
  you are done with them, and `size` to `seed_memory/2`.
  """
  @spec vm_memories(username()) ::
          {:ok, Memory.fetched()} | {:error, :not_running | String.t()}
  def vm_memories(username) do
    case Server.call(username, :memory) do
      %{vm: %{running?: true, name: name}, from: from} ->
        Memory.fetch(Guest.vm(username, name), from)

      _stopped ->
        {:error, :not_running}
    end
  end

  @doc """
  Adds `texts`, chosen from the VM's memories, to your memory with
  `memo note`, and marks everything up to `upto` reviewed when all of them
  went in. Returns memo's answer per text.
  """
  @spec bring_back(username(), [String.t()], non_neg_integer()) ::
          [:ok | {:error, String.t()}]
  def bring_back(username, texts, upto) do
    results = Memory.bring_back(texts)
    added = Enum.count(results, &(&1 == :ok))

    if Enum.all?(results, &(&1 == :ok)),
      do: Server.call(username, {:reviewed, upto, added}),
      else: if(added > 0, do: Server.call(username, {:reviewed, 0, added}))

    results
  end

  @doc "Marks the VM's memories up to `upto` reviewed without adding any."
  @spec dismiss_memories(username(), non_neg_integer()) :: :ok
  def dismiss_memories(username, upto), do: Server.call(username, {:reviewed, upto, 0})

  @doc """
  Replaces the VM's memory with a copy of yours, in a task, while the VM
  runs; what it had is moved aside in it. With `expect`, the `size` of
  `vm_memories/1`, only if the VM noted nothing since.
  """
  @spec seed_memory(username(), non_neg_integer() | nil) ::
          :ok | {:error, :busy | :not_running | :no_memory}
  def seed_memory(username, expect \\ nil), do: Server.call(username, {:seed_memory, expect})

  @doc """
  Turns a grant on for `minutes`, or `:until_off`. With `uses: :all`, every
  use goes through without asking while it stays on; otherwise each one
  waits for you. Agents waiting for it hear it is on.
  """
  @spec turn_on(username(), String.t(), pos_integer() | :until_off, :ask | :all) ::
          {:ok, Grant.t()} | {:error, :not_found | :actions_only | :to_review}
  def turn_on(username, id, minutes, uses \\ :ask),
    do: Server.call(username, {:turn_on, id, minutes, uses})

  @doc """
  Accepts a grant an agent proposed (`MWTClient.Sandbox.Grant.to_review?/1`),
  as you do on its page: reviewed, yours from now on. With
  `{minutes, uses}` it also turns on, which answers the agent waiting for
  it; with `:keep_off` it stays off. A token grant with no value yet can't
  be enabled: `{:error, :no_value}`. `revision` is the proposal's as the
  page showed it (`Grant.proposal`): one the agent changed since is
  `{:error, :changed}`, not accepted.
  """
  @spec review(
          username(),
          String.t(),
          :keep_off | {pos_integer() | :until_off, :ask | :all},
          String.t() | nil
        ) ::
          {:ok, Grant.t()}
          | {:error, :not_found | :reviewed | :no_value | :changed | :resource_to_review}
  def review(username, id, enable, revision),
    do: Server.call(username, {:review, id, enable, revision})

  @doc """
  Accepts a credential or network an agent proposed, on its page, as it
  showed `revision`: yours from now on. A credential's value is yours to
  paste whenever you have it; until then every use is refused.
  """
  @spec review_resource(username(), MWTClient.Sandbox.Resource.id(), String.t() | nil) ::
          {:ok, struct()} | {:error, :not_found | :reviewed | :changed}
  def review_resource(username, resource, revision),
    do: Server.call(username, {:review_resource, resource, revision})

  @doc """
  Gives a grant that is on a new duration, counted from now: `minutes`, or
  `:until_off`. It stays on.
  """
  @spec set_duration(username(), String.t(), pos_integer() | :until_off) ::
          {:ok, Grant.t()} | {:error, :not_found | :off}
  def set_duration(username, id, minutes),
    do: Server.call(username, {:set_duration, id, minutes})

  @doc """
  Changes how the uses of a grant that is on are approved: `:ask`, each
  waits for you, or `:all`, every use goes through while it stays on.
  """
  @spec set_mode(username(), String.t(), :ask | :all) ::
          {:ok, Grant.t()} | {:error, :not_found | :off}
  def set_mode(username, id, mode), do: Server.call(username, {:set_mode, id, mode})

  @doc """
  Sets the state a grant is in when MWT starts, and puts it in that state
  now: `:off`, `:on` (enabled until turned off, every use asks) or `:auto`
  (enabled until turned off, every use goes through). One an agent
  proposed starts off until you review it (`:to_review`); Commands agents
  write never lets a use through unasked (`:always_asks`).
  """
  @spec set_start(username(), String.t(), Grant.start()) ::
          {:ok, Grant.t()} | {:error, :not_found | :to_review | :always_asks}
  def set_start(username, id, start), do: Server.call(username, {:set_start, id, start})

  @doc """
  Sets the hosts a network grant leaves out (`Grant.except`), from a
  form's text (`MWTClient.Sandbox.Network.except_entries/1`): the one field
  the Internet's built-in grant lets you change, beside how it starts and
  whether it always asks. Another network grant's are set with the rest
  of its form (`update_grant/3`).
  """
  @spec set_except(username(), String.t(), String.t() | nil) ::
          {:ok, Grant.t()} | {:error, :not_found | %{except: String.t()}}
  def set_except(username, id, text) do
    case MWTClient.Sandbox.Network.except_entries(text) do
      {:ok, entries} -> Server.call(username, {:set_except, id, entries})
      {:error, message} -> {:error, %{except: message}}
    end
  end

  @doc """
  The firewall (`MWTClient.Sandbox.Firewall`): its settings and incidents,
  and how much it refused since it isolated the VM. Its findings are in the activity log (`events/2`, the
  `firewall` group), read by whoever shows them, never by the server.
  """
  @spec firewall(username()) :: %{
          firewall: MWTClient.Sandbox.Firewall.t(),
          refused: non_neg_integer()
        }
  def firewall(username), do: Server.call(username, :firewall)

  @doc "Which hosts the proxy reads (`MWTClient.Sandbox.Reading`)."
  @spec reading(username()) :: MWTClient.Sandbox.Reading.t()
  def reading(username), do: Server.call(username, :reading)

  @doc """
  Changes which hosts the proxy reads: `{:default, :every_host |
  :token_hosts}`, `{:put, host, read?}` (opt a host in or out), or
  `{:remove, host}`. `{:error, message}` for a host that can't be an entry.
  """
  @spec reading_set(username(), tuple()) :: :ok | {:error, String.t()}
  def reading_set(username, change), do: Server.call(username, {:reading_set, change})

  @doc """
  Changes a network's limits, the hosts the VM may never reach there
  (`MWTClient.Sandbox.HostLimits`): `{:default, :reachable | :blocked}`,
  `{:put, host, blocked?}` or `{:remove, host}`. `{:ok, network}`, or
  `{:error, message}` for a host that can't be an entry.
  """
  @spec limits_set(username(), String.t(), tuple()) ::
          {:ok, MWTClient.Sandbox.Network.t()} | {:error, String.t()}
  def limits_set(username, network_id, change),
    do: Server.call(username, {:limits_set, network_id, change})

  @doc """
  Adds a resource from its form's fields: `:credential` (its name, words,
  where its value comes from and how tools find it, and the value when
  pasted) or `:network` (its name, words, destinations, DNS server and
  interface). `{:ok, resource}` or `{:error, errors}` by field.
  """
  @spec create_resource(username(), :credential | :network, map()) ::
          {:ok, struct()} | {:error, map()}
  def create_resource(username, kind, attrs) when kind in [:credential, :network],
    do: Server.call(username, {:create_resource, kind, attrs})

  @doc "Changes a credential or a network from its form (`create_resource/3`)."
  @spec update_resource(username(), MWTClient.Sandbox.Resource.id(), map()) ::
          {:ok, struct()} | {:error, map() | :not_found | :built_in}
  def update_resource(username, resource, attrs),
    do: Server.call(username, {:update_resource, resource, attrs})

  @doc """
  Removes a credential or a network, with every grant over it. The
  Internet, your machine and MWT's tools are built in, and stay.
  """
  @spec delete_resource(username(), MWTClient.Sandbox.Resource.id()) ::
          :ok | {:error, :not_found | :built_in}
  def delete_resource(username, resource), do: Server.call(username, {:delete_resource, resource})

  @doc """
  The credential endpoints a grant's value is refused at
  (`MWTClient.Sandbox.Firewall.minting/3`), as the network path sees the
  firewall now; none while it, or its rule, is off. Read without asking
  the server.
  """
  @spec credential_endpoints(username()) :: [String.t()]
  def credential_endpoints(username) do
    case MWTClient.Sandbox.Gate.view(username) do
      %{firewall: %MWTClient.Sandbox.Firewall{enabled: true} = firewall} ->
        if MWTClient.Sandbox.Firewall.action(firewall, :credential_mint) == :off,
          do: [],
          else: firewall.mints

      _none ->
        []
    end
  end

  @doc """
  Changes the firewall: `{:enabled, boolean}`, `{:action, rule, action}`,
  `{:list, list, text}` or `{:reset_list, list}`.
  """
  @spec firewall_set(username(), tuple()) ::
          :ok | {:error, :bad_action | :bad_change | String.t()}
  def firewall_set(username, change), do: Server.call(username, {:firewall_set, change})

  @doc """
  Isolates the VM yourself, as the firewall would on a finding, locking
  every resource as the isolation's (`Server.Locks`): `:error` when it
  already is isolated.
  """
  @spec firewall_isolate(username()) :: :ok | :error
  def firewall_isolate(username), do: Server.call(username, :firewall_isolate)

  @doc """
  Ends the VM's isolation, whoever isolated it, and the isolation's locks;
  yours stay. With `trust?`, the incident's destination joins the trusted
  list. No grant changes either way.
  """
  @spec firewall_release(username(), boolean()) :: :ok | :error
  def firewall_release(username, trust?),
    do: Server.call(username, {:firewall_release, trust? == true})

  @doc "You looked at the Firewall page: its alert notification goes."
  @spec firewall_seen(username()) :: :ok
  def firewall_seen(username), do: Server.cast(username, :firewall_seen)

  @doc """
  Turns a grant off: it gives nothing from now, its time and allowances
  gone. Requests waiting on it are refused.
  """
  @spec turn_off(username(), String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def turn_off(username, id), do: Server.call(username, {:turn_off, id})

  @doc """
  Runs `command` in the running VM as an agent there would, under
  `credential` (`mwt exec`) when one is named, and gives back what it
  printed and its exit status (`MWTClient.Sandbox.Console`), as the
  console's history keeps it (`console_runs/1`). It starts in `dir` (an
  absolute folder in the VM, `/work` when nil), and says the folder its
  shell ended in (`cwd`), for a terminal's next command. Runs in the
  caller: it takes as long as the command, up to `seconds`.
  """
  @spec console(username(), String.t(), String.t() | nil, pos_integer(), String.t() | nil) ::
          {:ok, MWTClient.Sandbox.ConsoleHistory.run()} | {:error, :vm_not_running | String.t()}
  def console(username, command, credential, seconds \\ 60, dir \\ nil) do
    alias MWTClient.Sandbox.Console

    with :ok <- Server.call(username, {:console_check, command}),
         {:ok, guest} <- Projects.guest(username, snapshot(username).vm),
         {:ok, result} <- Console.run(guest, command, credential, seconds, dir) do
      Server.call(username, {:console_ran, result})
    else
      {:error, {:carries_value, name}} ->
        {:error,
         "That command holds the real value of #{name}. What you type here goes into the VM, where agents can read it: use the credential instead (Speaking as)."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records a console run you stopped from MWT before it ended
  (`console/4`): its command, who it spoke as and when it started, with
  no output, as the history and the activity log keep it.
  """
  @spec console_stopped(username(), String.t(), String.t() | nil, DateTime.t(), String.t() | nil) ::
          {:ok, MWTClient.Sandbox.ConsoleHistory.run()}
  def console_stopped(username, command, credential, started_at, dir \\ nil) do
    Server.call(
      username,
      {:console_ran,
       %{
         command: command,
         credential: credential,
         dir: dir,
         status: nil,
         output: "",
         cut: false,
         timed_out: false,
         stopped: true,
         started_at: started_at,
         finished_at: DateTime.utc_now()
       }}
    )
  end

  @doc """
  The console's runs, newest first, each with what it printed
  (`MWTClient.Sandbox.ConsoleHistory`): kept in memory, until the identity
  locks or MWT stops.
  """
  @spec console_runs(username()) :: [MWTClient.Sandbox.ConsoleHistory.run()]
  def console_runs(username), do: Server.call(username, :console_runs)

  @doc "Forgets the console's runs. The activity log keeps its line of each."
  @spec clear_console_runs(username()) :: :ok
  def clear_console_runs(username), do: Server.call(username, :clear_console_runs)

  @doc """
  Locks a resource the VM reaches through MWT (`MWTClient.Sandbox.Resource`):
  `{:credential, id}`, `{:network, id}`, `:machine`, your machine, where
  saved commands, git and the shared folders are carried out, or `:mwt`,
  MWT's tools. Every use of it is refused, whatever its grants say, until
  you unlock it; agents can't ask for that. No grant changes.
  """
  @spec lock(username(), MWTClient.Sandbox.Resource.id()) :: :ok | {:error, :not_found}
  def lock(username, resource), do: Server.call(username, {:lock, resource})

  @doc "Unlocks a resource you locked (`lock/2`)."
  @spec unlock(username(), MWTClient.Sandbox.Resource.id()) :: :ok | {:error, :not_found}
  def unlock(username, resource), do: Server.call(username, {:unlock, resource})

  @doc """
  Lets every use of an `on` grant through without asking, for `minutes` or
  while it stays on (`:grant`). Uses waiting on it go through at once.
  """
  @spec allow_all(username(), String.t(), pos_integer() | :grant) ::
          {:ok, Grant.t()} | {:error, :not_found | :off}
  def allow_all(username, id, duration), do: Server.call(username, {:allow_all, id, duration})

  @doc "Ends a temporary allowance early."
  @spec revoke_allowance(username(), String.t(), String.t()) ::
          {:ok, Grant.t()} | {:error, :not_found}
  def revoke_allowance(username, id, allowance_id),
    do: Server.call(username, {:revoke_allowance, id, allowance_id})

  @doc """
  Adds a grant from the add dialog's params. It starts off.

    * every type: `"kind"` (`"token"`, `"network"` or `"command"`), `"name"`,
      `"purpose"` (what it is for, which agents read), and `"preset"` when a
      preset filled the form;
    * `"token"`: `"hosts"`, `"carriers"` (the headers its value travels
      in; `authorization` when none), `"env"`, `"file_env"`, `"git"`, `"prefix"` (how
      the placeholder starts), `"source"` (`"stored"` with `"value"`, or
      `"minted"` with `"mint"`, a command printing a short-lived token);
    * `"network"`: `"destinations"`, one per line.

  Lists are comma or newline separated.
  """
  @spec create_grant(username(), map()) :: {:ok, Grant.t()} | {:error, %{atom() => String.t()}}
  def create_grant(username, attrs), do: Server.call(username, {:create_grant, attrs})

  @doc """
  Changes a grant from its form's fields, checked as when it was added. It
  keeps its id, placeholder, value, kind, the resource it is over and its
  state. The built-in grants can't be changed.
  """
  @spec update_grant(username(), String.t(), map()) ::
          {:ok, Grant.t()} | {:error, :not_found | :built_in | %{atom() => String.t()}}
  def update_grant(username, id, attrs), do: Server.call(username, {:update_grant, id, attrs})

  @doc "Replaces a grant's stored value."
  @spec set_value(username(), String.t(), String.t()) :: :ok | {:error, :not_found | :minted}
  def set_value(username, id, value), do: Server.call(username, {:set_value, id, value})

  @doc """
  Pastes or replaces a stored credential's value: every grant over it, and
  its actions, use it from now. `{:error, :minted}` for one a command mints.
  """
  @spec set_credential_value(username(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :minted | :empty}
  def set_credential_value(username, id, value),
    do: Server.call(username, {:set_credential_value, id, value})

  @doc "Removes a grant. Requests waiting on it are refused. Built-in grants stay; its resource stays."
  @spec delete_grant(username(), String.t()) :: :ok | {:error, :not_found | :built_in}
  def delete_grant(username, id), do: Server.call(username, {:delete_grant, id})

  @doc """
  Decides a waiting approval.

  A use (a request or a connection):

    * `:allow_once`;
    * `{:allow, :similar, duration}` - this one, and uses like it for
      `duration` (minutes, or `:grant` while the grant stays on);
    * `{:allow, :all, duration}` - every use of its grant for `duration`;
    * `:deny`, or `:deny_and_turn_off`, which also turns its grant off.

  An activation (an agent asking for a grant):

    * `{:turn_on, minutes | :until_off, :ask | :all}` - turns the grant on;
      `:all` lets every use through while it stays on;
    * `{:set_up, grant_id}` - for an ask no grant met: the grant you just
      added for it, turned on for the minutes asked;
    * `:decline`.

  A command (an agent asking to run something on the host), waiting to run:

    * `{:run, :send}` - runs it once; its output goes back to the agent;
    * `{:run, :review}` - runs it once; when it ends, it waits again for
      you with its output;
    * `:decline`;
    * `:simpler` - declines it and tells the agent to send the smallest
      command that gets the raw data, and to do the rest in the VM.

  A command that ran and waits with its output: `:send_output` or
  `:keep_output`.
  """
  @spec decide(username(), String.t(), Approval.decision()) ::
          :ok | {:error, :not_waiting | :bad_decision}
  def decide(username, approval_id, decision),
    do: Server.call(username, {:decide, approval_id, decision})

  @doc """
  Notes that the command an agent wrote and asked to run is now the saved
  command `grant_id`, which you just added from its card. The card
  says so, and the agent hears to run it by name next time.
  """
  @spec command_saved(username(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def command_saved(username, approval_id, grant_id),
    do: Server.call(username, {:command_saved, approval_id, grant_id})

  @doc "Stops a command running on the host: TERM to its processes, KILL 5 seconds later."
  @spec stop_command(username(), String.t()) :: :ok | {:error, :not_running}
  def stop_command(username, approval_id),
    do: Server.call(username, {:stop_command, approval_id})

  @doc """
  Looks again for the command-line tools agents are told about (`mwt host`),
  in the background.
  """
  @spec probe_host(username()) :: :ok | {:error, :busy}
  def probe_host(username), do: Server.call(username, :probe_host)

  @doc """
  Changes resources, the hold time, the proxy port, the image name, your
  layer of the image (`"image_layer"`, the one it replaced kept as a
  version) or your notes about this machine (`"host_notes"`) from the
  settings forms.
  """
  @spec update_settings(username(), map()) ::
          {:ok, Settings.t()} | {:error, %{atom() => String.t()}}
  def update_settings(username, attrs), do: Server.call(username, {:update_settings, attrs})

  @doc "The versions kept of your layer of the image, the newest first."
  @spec layer_versions(username()) :: [MWTClient.Versions.Version.t()]
  def layer_versions(username), do: MWTClient.Sandbox.LayerVersions.list(username)

  @doc """
  Makes the version numbered `number` your layer again, keeping the one it
  replaces as a version too.
  """
  @spec restore_layer(username(), integer()) :: {:ok, Settings.t()} | {:error, :not_found}
  def restore_layer(username, number), do: Server.call(username, {:restore_layer, number})

  @doc """
  Shares a folder, if `MWTClient.Sandbox.Shares` allows it: its git
  repositories become projects, the rest is copied into the VM
  (`MWTClient.Sandbox.FolderSync`).
  """
  @spec add_share(username(), String.t()) :: {:ok, Share.t()} | {:error, Shares.reason()}
  def add_share(username, path), do: Server.call(username, {:add_share, path})

  @doc "Stops sharing a folder."
  @spec remove_share(username(), String.t()) :: :ok
  def remove_share(username, path), do: Server.call(username, {:remove_share, path})

  @doc """
  Syncs the copies of shared folders in the VM: every one (`:all`) or
  those paths (`MWTClient.Sandbox.Server.ShareSync`). Returns at once; the
  snapshot's `sync` shows how it goes.
  """
  @spec sync_shares(username(), :all | [String.t()]) :: :ok
  def sync_shares(username, which), do: Server.call(username, {:sync_shares, which})

  @doc """
  Syncs the workspace both ways (`MWTClient.Sandbox.Workspace`): your
  `to-vm/` into the VM, its `from-vm/` onto this machine. Answered at once.
  """
  @spec sync_workspace(String.t()) :: :ok
  def sync_workspace(username), do: Server.call(username, :sync_workspace)

  @doc "Opens the workspace in your file manager."
  @spec open_workspace(String.t()) :: :ok | {:error, String.t()}
  def open_workspace(username) do
    case Server.call(username, :projects) do
      %{workspace: root} when is_binary(root) ->
        MWTClient.Sandbox.Workspace.open(root)

      _none ->
        {:error, "There is no workspace yet: it is made at the first sync with the VM running."}
    end
  end

  @doc """
  Lets a file of the workspace's `to-vm/` that was held back go to the VM
  as it is now (`path` relative to `to-vm/`).
  """
  @spec release_held(String.t(), String.t()) :: :ok
  def release_held(username, path), do: Server.call(username, {:workspace_release, path})

  @doc """
  The addresses MWT always refuses for the VM: loopback, link-local,
  unspecified and every address of this machine's own interfaces.
  """
  @spec refused_addresses() :: [String.t()]
  def refused_addresses do
    own = Enum.map(Destinations.host_addresses(), &to_string(:inet.ntoa(&1)))
    Enum.uniq(Destinations.refused_ranges() ++ own)
  end
end
