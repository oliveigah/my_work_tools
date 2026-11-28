defmodule MWTClient.Sandbox.Server do
  @moduledoc """
  The agent sandbox of one unlocked identity: its grants and their values,
  the VM, the image, and every decision the proxy asks for.

  One process per unlocked identity, started by `MWTClient.Vault.Store`. Grants,
  values, settings and the CA are the `sandbox` document of the identity's
  encrypted `library.db` (`State.persist/1`); activity goes to its
  `journal.db` (`MWTClient.Sandbox.Activity`); approvals (agents' asks
  included) live in memory.

  This module is the process: it holds the state and takes every message.
  What it does with one is in the modules next to it, each with one job on
  that state, all running here, in this process:

  | Module      | Its job                                                        |
  | ----------- | -------------------------------------------------------------- |
  | `State`     | changing the state and telling the pages, the log, saving      |
  | `Grants`    | building and checking grants, turning on, allowances, expiry   |
  | `Approvals` | what waits for you: holding, your decision, giving up          |
  | `Values`    | the real values, and answering the proxy with them             |
  | `HostRuns`  | commands on this machine: the ask, the run, its output         |
  | `Machine`   | the VM in its bubble, its disks, the image                     |
  | `Firewall`  | what the sensors report, checked; isolating and releasing      |

  Whether a use goes through, asks or is refused is not decided here:
  `MWTClient.Sandbox.Policy` says, from the grants, the use and the clock,
  and this process acts on the answer.

  The network path (the proxy and DNS) doesn't wait on this process: it
  decides from a view this process publishes after every message that
  changes what it reads, before the answer goes (`MWTClient.Sandbox.Gate`),
  and the firewall counts what it sees in a process of its own
  (`MWTClient.Sandbox.Watch`), which tells this one what it found. It asks
  this process only what waits for you or needs a real value: a
  connection to hold for your approval (`destination`), and a request
  carrying a placeholder (`authorize`). A use of a grant waits for you
  unless an allowance covers it: the caller is held, and answered when you
  decide or when the hold runs out. When a grant stops being live, what it
  let through closes (`Grants.close_ended/1`).

  `MWTClient.Sandbox.Channel` brings agents' asks from the VM: for a grant
  (`request_access`), which waits for you as an activation approval, and to
  run a command on the host (`request_command`), which waits as a command
  approval. It waits on your answer (`await`) for a while before telling the
  agent to come back. An approved command runs in a task
  (`MWTClient.Sandbox.HostRun`), and its output goes back to the agent, or
  first to you when you chose to see it; `stop_command` kills it.

  Every approval waiting for you, and every open handoff, is notified
  (`MWTClient.Notifications`, with `MWTClient.Sandbox.Notices`); the
  notification is withdrawn once the approval is decided or gives up, or the
  handoff is accepted or closed, and a command coming back with
  its output gets a new one.

  It also keeps the image's builds and the copies of the VM's Home disk, as
  many as their retention rules say (`MWTClient.Storage.Retention`), the projects, their mirrors and the
  handoffs agents send, and how
  far the VM's memory was seeded and reviewed.

  Slow work (`msb`, podman, copying disks, minting tokens, git) runs outside
  this process, so the pages and the proxy never wait on it. Only
  `MWTClient.Sandbox`, `Gate`, `Channel`, `Projects` and `Handoffs` call this
  module; the proxy, DNS and the watch only cast to it, to log.
  """

  use GenServer

  require Logger

  alias MWTClient.Accounts

  alias MWTClient.Sandbox.{
    Approval,
    CertificateAuthority,
    Credential,
    CredentialEndpoint,
    Decision,
    Disks,
    Event,
    EventDetails,
    Exchange,
    Explain,
    Gate,
    Grant,
    Handoff,
    HandoffRecords,
    HostCommand,
    HostInfo,
    HostRun,
    Image,
    LayerVersions,
    Memory,
    Msb,
    NestedVirt,
    Policy,
    Presets,
    Project,
    Projects,
    Resources,
    SavedRequest,
    Secrets,
    Settings,
    SlotSummaries,
    Share,
    Shares,
    VM,
    Workspace
  }

  alias MWTClient.Sandbox.Server.{
    Approvals,
    Copying,
    Firewall,
    Forwarding,
    Grants,
    HostRuns,
    Kept,
    Locks,
    Machine,
    Running,
    ShareSync,
    State,
    Tools,
    Values
  }

  alias MWTClient.Storage.Journal
  alias MWTClient.Vault.Store

  @poll_every 10_000
  @sweep_every 30_000
  @mirror_every 2_000
  # How often MWT looks again at its own files for the VM (/mnt/mwt), in
  # case a change of theirs went unsent (`Copying`). Your shared folders
  # are synced only when asked (`ShareSync`).
  @inbox_every 3_000
  # A mirror that failed is tried again this often, unless your branch moves.
  @mirror_retry_seconds 60
  @kill_after_ms 5_000
  # What a real value in a kept exchange reads as.
  @withheld "[real credential withheld by MWT]"

  # Why a request whose call ended first has only its request kept.
  @call_ended "MWT's connection for it ended before the request did: only the request is " <>
                "kept, as MWT read it before deciding."

  @doc "Starts the sandbox for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :username)},
      start: {__MODULE__, :start_link, [opts]},
      # Room to stop the VM on the way out.
      shutdown: 30_000
    }
  end

  @doc "The PubSub topic of everything that changes."
  defdelegate topic(username), to: State

  @doc "The PubSub topic of the waiting count, which every page's title bar shows."
  defdelegate waiting_topic(username), to: State

  @doc "The microsandbox name of this identity's VM."
  def vm_name(username), do: "mwt-" <> String.slice(Accounts.id(username), 0, 10)

  @doc false
  def call(username, message, timeout \\ 15_000),
    do: GenServer.call(Store.via(__MODULE__, username), sealed(message), timeout)

  # A value on its way to the vault travels inside a function. A message is
  # printed in full when the process it was sent to crashes, and again when
  # its caller does; a function prints as its name and nothing else.
  # `opened/1` takes it out, here in the sandbox's own process.
  defp sealed({:create_grant, %{"value" => value} = attrs}) when is_binary(value),
    do: {:create_grant, %{attrs | "value" => fn -> value end}}

  defp sealed({:create_resource, :credential, %{"value" => value} = attrs}) when is_binary(value),
    do: {:create_resource, :credential, %{attrs | "value" => fn -> value end}}

  defp sealed({:update_resource, {:credential, _id} = resource, %{"value" => value} = attrs})
       when is_binary(value),
       do: {:update_resource, resource, %{attrs | "value" => fn -> value end}}

  defp sealed({operation, id, value})
       when operation in [:set_value, :set_credential_value] and is_binary(value),
       do: {operation, id, fn -> value end}

  defp sealed(message), do: message

  @doc false
  def cast(username, message), do: GenServer.cast(Store.via(__MODULE__, username), message)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)
    dir = Path.join(Accounts.dir(username), "sandbox")
    File.mkdir_p!(dir)

    saved = State.restore(username, Keyword.fetch!(opts, :key))
    # The VM's disks, and the folder that held its memory before it had a
    # disk for it (2026-11-16): a VM made before then mounts it, and a VM
    # made since takes what is there at its first start.
    folders = dir |> Disks.paths() |> Map.put(:optmem, Path.join(dir, "optmem"))

    saved_settings = Map.from_struct(saved[:settings] || default_settings())

    # A recipe from before MWT kept the base, a whole Containerfile, is kept
    # as a version of your layer, which starts from MWT's default.
    settings =
      struct(Settings, saved_settings)
      |> Map.update!(:image_layer, &(&1 || Image.default_layer()))
      |> Map.update!(:shares, fn shares -> Enum.map(shares, &Share.upgrade/1) end)
      |> then(&LayerVersions.upgrade(username, &1, saved_settings[:containerfile]))

    builds = saved[:builds] || []
    current = saved[:current]
    # Isolated when MWT stopped: still isolated, every resource locked by it.
    firewall = MWTClient.Sandbox.Firewall.upgrade(saved[:firewall])
    # What this process kept since the unlock, when it is starting again
    # after a failure: nil at a start.
    kept = Kept.restore(username)

    # Every token grant over a credential of its own or shared
    # (`MWTClient.Sandbox.Credential.migrate/2`): one saved before
    # credentials existed is given one, merged with those minted the same
    # way.
    # And every network grant over a network (`MWTClient.Sandbox.Network`):
    # one saved before networks existed is given one, and its host list
    # becomes grants over it, before each grant starts as its setting says.
    {grants, networks} =
      if(kept, do: kept.grants, else: saved[:grants] || [])
      |> Grants.with_built_in()
      |> MWTClient.Sandbox.Network.migrate(
        Enum.map(saved[:networks] || [], &MWTClient.Sandbox.Network.upgrade/1)
      )

    {grants, credentials} =
      if(kept, do: grants, else: Grants.start(grants))
      |> Credential.migrate(Enum.map(saved[:credentials] || [], &Credential.upgrade/1))

    state =
      Map.merge(State.memory(), %{
        username: username,
        dir: dir,
        ca: saved[:ca] || CertificateAuthority.new(),
        # Every start begins from each grant's own setting; a restart
        # after a failure, from each grant as it was. Isolated when MWT
        # stopped, it is still: the isolation locks, and no grant changes.
        grants: grants,
        credentials: credentials,
        # The networks the VM reaches, the Internet included, each under the
        # grants that name it (`MWTClient.Sandbox.Network`).
        networks: networks,
        # The locked resources (`{:credential, id}`, `{:network, id}`,
        # `:machine`), each with who holds it, you or the isolation, and
        # since when (`Server.Locks`): a locked resource refuses every use,
        # whatever the grants say.
        locks: MWTClient.Sandbox.Server.Locks.upgrade(saved[:locks]),
        # The firewall's settings and incidents (`MWTClient.Sandbox.Firewall`).
        firewall: firewall,
        # Which hosts the proxy reads (`MWTClient.Sandbox.Reading`).
        reading: MWTClient.Sandbox.Reading.upgrade(saved[:reading]),
        values: saved[:values] || %{},
        settings: settings,
        created_spec: saved[:created_spec],
        created_ref: saved[:created_ref],
        vm_record: saved[:vm_record],
        builds: builds,
        # A copy whose file is gone can't be brought back: it isn't listed.
        snapshots: Enum.filter(saved[:snapshots] || [], &Disks.snapshot?(folders, &1)),
        projects: Enum.map(saved[:projects] || [], &Project.upgrade/1),
        # Only those waiting for you: every handoff is kept in
        # `HandoffRecords`, and read from there.
        waiting_handoffs: moved_handoffs(username, saved[:handoffs]),
        # The numbers already given, even one whose saving of this state
        # didn't happen before MWT stopped: its record is kept apart.
        handoff_seq: max(saved[:handoff_seq] || 0, HandoffRecords.max_id(username)),
        memory: saved[:memory] || %{seed_count: nil, seeded_at: nil, reviewed: 0},
        folders: folders,
        host: %{facts: HostInfo.facts(), tools: nil, probed_at: nil, probing?: false},
        build: nil,
        vm: %VM{name: vm_name(username), msb: Msb.executable()},
        # What a VM needs from this machine, looked at once: a bubble can be
        # made, and the tools that make disks are there.
        needs: if(State.external?(), do: Machine.needs(), else: []),
        image: %{
          tag: current,
          loaded?: false,
          building?: false,
          building: nil,
          log: [],
          error: nil
        },
        proxy: %{listening?: false, error: nil, path: nil},
        # The workspace as it is: made at the first sync with the VM up.
        workspace: Workspace.locate(username),
        flush: nil,
        code: State.code()
      })

    state = Kept.restored(state, kept)

    # Connections a grant let through before a restart of this process
    # close unless it is live again.
    state =
      state
      |> log_dropped_files(saved[:dropped_files] || [])
      |> log_dropped_checks(saved[:dropped_checks] || [])

    state =
      state
      |> Gate.publish()
      |> Grants.close_unlive()
      |> State.write_inbox()
      |> State.sync_handoff_notices(quiet: true)

    carry_notifications_switch(username, saved[:settings])
    if is_nil(saved[:ca]), do: State.persist(state)
    state = if State.external?(), do: State.probe_host(state), else: state
    if State.external?(), do: Machine.write_launcher(username)
    Enum.each(state.grants, &State.schedule_expiry/1)
    # The loops run on interval timers rather than each tick setting the
    # next: in development, a tick can be lost while this module is compiled
    # again (`MWTClient.SaveTimer`), and a lost tick would end its loop.
    send(self(), :sweep)
    {:ok, _} = :timer.send_interval(@sweep_every, :sweep)
    # After a restart of this process, the proxy tells it again how it is.
    MWTClient.Sandbox.Egress.report_again(username)

    if State.external?() do
      {:ok, _} = :timer.send_interval(@poll_every, :poll)
      {:ok, _} = :timer.send_interval(@mirror_every, :mirror)
      {:ok, _} = :timer.send_interval(@inbox_every, :sync_inbox)
      {:ok, state, {:continue, :check}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:check, state),
    do: {:noreply, state |> State.current() |> Machine.check(clear_legacy_env: true)}

  # A new identity's VM gets what this machine can spare (`Resources.suggested/1`).
  defp default_settings, do: struct!(Settings, Resources.suggested(Resources.host()))

  # File grants saved before they were gone (2026-11-18), dropped on
  # restore with their values (`State.restore/2`), said once in Activity.
  defp log_dropped_files(state, []), do: state

  defp log_dropped_files(state, names) do
    state
    |> State.log(%{
      outcome: :grant,
      summary:
        "Removed, with the values you saved: #{Enum.join(names, ", ")}. File grants are gone: " <>
          "a command action runs the job where the file is, or a token grant's file variable gives a placeholder."
    })
    |> State.saved()
  end

  defp log_dropped_checks(state, []), do: state

  defp log_dropped_checks(state, dropped) do
    words =
      Enum.map_join(dropped, "; ", fn {grant, checks} ->
        "#{grant}: #{Enum.join(checks, ", ")}"
      end)

    state
    |> State.log(%{
      outcome: :grant,
      summary:
        "Checks removed, which no longer run: #{words}. A network reached through an " <>
          "interface of its own opens nothing while it is down; lock a credential that " <>
          "turns out to do more than you set it up for."
    })
    |> State.saved()
  end

  # Before notifications were MWT's own, the sandbox's settings had their
  # switch. One turned off there stays off, unless notifications were set
  # since.
  defp carry_notifications_switch(username, %{desktop_notifications: false}) do
    unless MWTClient.Notifications.saved?(username),
      do: MWTClient.Notifications.put_settings(username, %{desktop: false})
  end

  defp carry_notifications_switch(_username, _settings), do: :ok

  # Each message finds the state shaped for the code running now
  # (`State.current/1`): in development, modules are compiled again while
  # this process runs.
  @impl true
  def handle_call(message, from, state) do
    state = State.current(state)

    case screened(state, message) do
      {:ok, message} ->
        message |> answer(from, state) |> settled()

      {:value, grant, how, refusal} ->
        {_verdict, state} = Firewall.observe(state, {:value, grant, nil, how})
        what = if how == :tool, do: "a write through MWT's tools", else: "an ask"

        state =
          State.log(state, %{
            outcome: :blocked,
            summary: "#{grant}'s real value in #{what} from the VM · refused"
          })

        {:reply, refusal, state}
    end
  end

  # What the VM asks through the agent channel or MWT's tools, looked
  # through for real values before anything is done with it: `{:ok,
  # message}` to go on, or the refusal. A tool's call is looked at by the
  # arguments it was called with.
  defp screened(state, {kind, ask} = message)
       when kind in [:request_access, :propose, :request_command, :call] and is_map(ask) do
    case Values.carried(state, texts(ask)) do
      nil -> {:ok, message}
      grant -> {:value, grant, :ask, {:error, :firewall}}
    end
  end

  defp screened(state, {:tool, %{} = use} = message) do
    case Values.carried(state, texts(Map.get(use, :args))) do
      nil ->
        {:ok, message}

      grant ->
        {:value, grant, :tool,
         {:error,
          "MWT refused this call: it holds a real credential, which nothing in the VM " <>
            "should have. The user has been told."}}
    end
  end

  defp screened(_state, message), do: {:ok, message}

  defp texts(text) when is_binary(text), do: [text]
  # Keys too: a parameter's or a field's name is text the VM chose, and a
  # value hidden there would otherwise reach the log and the refusal.
  defp texts(%{} = map),
    do: Enum.flat_map(map, fn {key, value} -> texts(key) ++ texts(value) end)

  defp texts(list) when is_list(list), do: Enum.flat_map(list, &texts/1)
  defp texts(_other), do: []

  defp answer(:snapshot, _from, state) do
    {waiting, decided} = Enum.split_with(state.approvals, &(&1.status == :waiting))
    {running, history} = Enum.split_with(decided, &Approval.running?/1)

    {:reply,
     %{
       vm:
         state.vm
         |> Map.put(:stale?, Machine.stale?(state))
         |> Map.put(:record, State.vm_record(state)),
       settings: state.settings,
       grants: state.grants,
       # What each grant's value comes from, and whether it has one: its
       # credential's (`MWTClient.Sandbox.Credential`), by grant id.
       credentials: Map.get(state, :credentials, []),
       # Whether each credential has a value stored, by its id.
       credential_values:
         Map.new(Map.get(state, :credentials, []), &{&1.id, Map.has_key?(state.values, &1.id)}),
       networks: Map.get(state, :networks, []),
       locks: Map.get(state, :locks, %{}),
       values:
         Map.new(state.grants, fn grant ->
           id = if grant.kind == :token, do: Grant.credential_id(grant), else: grant.id
           {grant.id, Map.has_key?(state.values, id)}
         end),
       waiting: Enum.sort_by(waiting, & &1.requested_at, DateTime),
       running: Enum.sort_by(running, & &1.run.started_at, DateTime),
       history: history,
       image: state.image,
       builds: state.builds,
       created_ref: state.created_ref,
       snapshots: Enum.sort_by(state.snapshots, & &1.taken_at, {:desc, DateTime}),
       projects: Enum.map(state.projects, &Project.upgrade/1),
       mirror: state.mirror,
       waiting_handoffs: state.waiting_handoffs,
       memory: Map.put(state.memory, :host?, Memory.host_memory?()),
       folders: state.folders,
       proxy: state.proxy,
       tools: %{
         msb: Msb.executable(),
         launcher: Msb.launcher(state.username),
         podman: Image.podman?(),
         nested_virt: NestedVirt.host(),
         needs: state.needs
       },
       inbox: State.inbox_dir(state),
       sync: ShareSync.view(state),
       workspace: ShareSync.workspace_view(state),
       host: Map.put(state.host, :text, State.host_text(state)),
       ports: Forwarding.view(state),
       firewall: Firewall.of(state)
     }, state}
  end

  defp answer(:host_text, _from, state), do: {:reply, State.host_text(state), state}

  defp answer(:firewall, _from, state), do: {:reply, Firewall.view(state), state}

  defp answer(:firewall_isolated?, _from, state), do: {:reply, Firewall.isolated?(state), state}

  defp answer({:firewall_set, change}, _from, state) do
    {reply, state} = Firewall.set(state, change)
    {:reply, reply, state}
  end

  defp answer(:reading, _from, state),
    do: {:reply, Map.get(state, :reading) || MWTClient.Sandbox.Reading.new(), state}

  # Which hosts MWT reads, as you set it on the activity log.
  defp answer({:reading_set, change}, _from, state) do
    alias MWTClient.Sandbox.Reading

    reading = Map.get(state, :reading) || Reading.new()

    result =
      case change do
        {:default, default} when default in [:every_host, :token_hosts] ->
          {:ok, Reading.set_default(reading, default)}

        {:put, host, read?} when is_binary(host) and is_boolean(read?) ->
          Reading.put(reading, host, read?)

        {:remove, host} when is_binary(host) ->
          {:ok, Reading.remove(reading, host)}

        _other ->
          {:error, "That isn't a change to what MWT reads."}
      end

    case result do
      {:ok, changed} ->
        {:reply, :ok, state |> State.change(:reading, fn _ -> changed end) |> State.changed()}

      error ->
        {:reply, error, state}
    end
  end

  # A network's limits: the hosts the VM may never reach there
  # (`MWTClient.Sandbox.HostLimits`). Only you change them: nothing the VM
  # sends reaches this.
  defp answer({:limits_set, network_id, change}, _from, state) do
    case MWTClient.Sandbox.Server.Resources.set_limits(state, network_id, change) do
      {:ok, state, network} -> {:reply, {:ok, network}, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  # Resources added, edited and removed on their own
  # (`MWTClient.Sandbox.Server.Resources`).
  defp answer({:create_resource, :credential, attrs}, _from, state),
    do: resource_reply(MWTClient.Sandbox.Server.Resources.create_credential(state, attrs), state)

  defp answer({:create_resource, :network, attrs}, _from, state),
    do: resource_reply(MWTClient.Sandbox.Server.Resources.create_network(state, attrs), state)

  defp answer({:update_resource, {:credential, id}, attrs}, _from, state),
    do:
      resource_reply(
        MWTClient.Sandbox.Server.Resources.update_credential(state, id, attrs),
        state
      )

  defp answer({:update_resource, {:network, id}, attrs}, _from, state),
    do: resource_reply(MWTClient.Sandbox.Server.Resources.update_network(state, id, attrs), state)

  defp answer({:update_resource, _built_in, _attrs}, _from, state),
    do: {:reply, {:error, :built_in}, state}

  defp answer({:delete_resource, resource}, _from, state) do
    case MWTClient.Sandbox.Server.Resources.delete(state, resource) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp answer(:firewall_isolate, _from, state) do
    {reply, state} = Firewall.isolate_by_you(state)
    {:reply, reply, state}
  end

  defp answer({:firewall_release, trust?}, _from, state) when is_boolean(trust?) do
    {reply, state} = Firewall.release(state, trust?)
    {:reply, reply, state}
  end

  # What listens in the VM, as the VM reports it, and what `mwt ports` prints.
  defp answer({:ports_report, report}, _from, state),
    do: {:reply, :ok, Forwarding.reported(state, report)}

  defp answer(:ports_text, _from, state), do: {:reply, Forwarding.text(state), state}

  # Which VM MWT runs, for `mwt vm` in a VM to compare itself with.
  defp answer(:vm_record, _from, state),
    do:
      {:reply, %{name: state.vm.name, status: state.vm.status, record: State.vm_record(state)},
       state}

  defp answer(:probe_host, _from, state) do
    if state.host.probing?,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, State.probe_host(state)}
  end

  defp answer(:waiting_count, _from, state), do: {:reply, State.waiting_count(state), state}

  defp answer(:requests_running, _from, state), do: {:reply, Running.all(state), state}

  defp answer({:request_running, id}, _from, state) do
    unfinished = Running.unfinished(state, id)
    {:reply, unfinished && redacted(state, unfinished), state}
  end

  # Once what was sent before is handled, every event it logged is with
  # the journal (`MWTClient.Sandbox.Activity`).
  defp answer(:logged, _from, state), do: {:reply, :ok, state}

  defp answer(:ca_pem, _from, state), do: {:reply, State.ca_pem(state), state}

  defp answer({:build_image, _opts}, _from, %{image: %{building?: true}} = state),
    do: {:reply, {:error, :busy}, state}

  defp answer({:build_image, opts}, _from, state) do
    cond do
      not Image.podman?() ->
        {:reply, {:error, :no_podman}, state}

      is_nil(Msb.executable()) ->
        {:reply, {:error, :no_msb}, state}

      problem = Image.layer_problem(state.settings.image_layer) ->
        {:reply, {:error, {:layer, problem}}, state}

      true ->
        {:reply, :ok, Machine.start_build(state, opts)}
    end
  end

  defp answer({:start_vm, options}, _from, state) do
    cond do
      state.vm.busy ->
        {:reply, {:error, :busy}, state}

      state.needs != [] ->
        {:reply, {:error, {:needs, state.needs}}, state}

      not state.image.loaded? ->
        {:reply, {:error, :no_image}, state}

      state.vm.exists? and not Machine.stale?(state) ->
        {:reply, :ok, Machine.vm_task(state, :start, "Starting…")}

      true ->
        Machine.create(state, options, "Creating…")
    end
  end

  # What the VM's disks and copies of Home take on this machine, for the
  # Storage page.
  defp answer(:space, _from, state) do
    disks =
      for name <- Disks.names(), path = Map.fetch!(state.folders, name), File.regular?(path) do
        %{name: name, path: path, size: File.stat!(path).size, used: Disks.used(path)}
      end

    snapshots =
      for snapshot <- state.snapshots, Disks.snapshot?(state.folders, snapshot) do
        Map.put(snapshot, :used, Disks.used(Disks.snapshot_path(state.folders, snapshot.id)))
      end

    {:reply,
     %{
       status: state.vm.status,
       busy: state.vm.busy,
       reclaimed: state.vm.reclaimed,
       disks: disks,
       snapshots: snapshots,
       builds: length(state.builds)
     }, state}
  end

  defp answer(:reclaim_space, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      state.vm.status != :stopped -> {:reply, {:error, :running}, state}
      Disks.missing_tools() != [] -> {:reply, {:error, {:needs, Disks.missing_tools()}}, state}
      true -> {:reply, :ok, Machine.reclaim(state)}
    end
  end

  # A copy of Home, deleted: it never was the disk the VM uses.
  defp answer({:delete_snapshot, id}, _from, state) do
    case Enum.find(state.snapshots, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      snapshot ->
        :ok = Disks.delete!(state.folders, snapshot)

        {:reply, :ok,
         state
         |> State.change(:snapshots, &Enum.reject(&1.snapshots, fn kept -> kept.id == id end))
         |> State.log(%{outcome: :vm, summary: "Copy of Home #{snapshot.tag || id} deleted"})
         |> State.saved()}
    end
  end

  defp answer(:stop_vm, _from, state) do
    if state.vm.busy,
      do: {:reply, {:error, :busy}, state},
      else: {:reply, :ok, Machine.vm_task(state, :stop, "Stopping…")}
  end

  defp answer({:recreate_vm, options}, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      state.needs != [] -> {:reply, {:error, {:needs, state.needs}}, state}
      not state.image.loaded? -> {:reply, {:error, :no_image}, state}
      true -> Machine.create(state, options, "Recreating…")
    end
  end

  defp answer({:use_build, ref}, _from, state) do
    cond do
      state.image.building? ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.builds, &(&1.ref == ref)) ->
        {:reply, {:error, :not_found}, state}

      true ->
        state =
          state
          |> State.change(:image, &%{&1.image | tag: ref, loaded?: false})
          |> State.log(%{outcome: :vm, summary: "Image #{ref} is current again"})
          |> State.changed()

        {:reply, :ok, if(State.external?(), do: Machine.check(state), else: state)}
    end
  end

  # The current build and the VM's stay: the next build replaces the one,
  # recreating the VM frees the other.
  defp answer({:delete_build, ref}, _from, state) do
    cond do
      state.image.building? ->
        {:reply, {:error, :busy}, state}

      not Enum.any?(state.builds, &(&1.ref == ref)) ->
        {:reply, {:error, :not_found}, state}

      ref == state.image.tag ->
        {:reply, {:error, :current}, state}

      ref == state.created_ref ->
        {:reply, {:error, :in_use}, state}

      true ->
        username = state.username

        state =
          state
          |> State.change(:builds, fn state -> Enum.reject(state.builds, &(&1.ref == ref)) end)
          |> State.log(%{outcome: :vm, summary: "Image #{ref} deleted"})
          |> State.task(:delete_builds, fn -> Image.delete(username, ref) end)
          |> State.changed()

        {:reply, :ok, state}
    end
  end

  defp answer(:memory, _from, state) do
    from = max(state.memory.seed_count || 0, state.memory.reviewed)

    {:reply,
     Map.merge(state.memory, %{
       from: from,
       vm: %{name: state.vm.name, running?: state.vm.status == :running}
     }), state}
  end

  # The VM's memory is on its disk: reached through the VM, while it runs.
  defp answer({:seed_memory, expect}, _from, state) do
    cond do
      state.vm.busy -> {:reply, {:error, :busy}, state}
      state.vm.status != :running -> {:reply, {:error, :not_running}, state}
      not Memory.host_memory?() -> {:reply, {:error, :no_memory}, state}
      true -> {:reply, :ok, Machine.seed_task(state, expect)}
    end
  end

  # The channel, before telling an agent a grant is on: once /mnt/mwt in
  # the VM has what changed.
  defp answer(:inbox_copied, from, state), do: {:noreply, Copying.await(state, from)}

  # A lifecycle task has stopped the old VM, or is about to start one.
  # Its busy flag/task prevents new copies; existing ones must finish
  # before any command can reach a replacement VM under the same name.
  defp answer(:copies_idle, from, state), do: {:noreply, Copying.await_idle(state, from)}

  defp answer({:reviewed, upto, added}, _from, state) do
    state =
      state
      |> State.change(:memory, &%{&1.memory | reviewed: max(&1.memory.reviewed, upto)})
      |> State.changed()

    state =
      if added > 0,
        do:
          State.log(state, %{
            outcome: :vm,
            summary: "#{added} of the VM's memories added to yours"
          }),
        else: state

    {:reply, :ok, state}
  end

  defp answer({:turn_on, id, minutes, uses}, _from, state) when uses in [:ask, :all] do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        # Proposed by an agent, only accepting it on its page turns it on;
        # over a resource to review or a credential with no value, nothing.
        case Grants.turn_on_refusal(state, grant) do
          nil ->
            state =
              state
              |> Grants.turn_on(grant, minutes, uses, "")
              |> Approvals.settle_activations(id, minutes, uses)

            {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}

          refusal ->
            {:reply, {:error, refusal}, state}
        end
    end
  end

  defp answer({:set_duration, id, minutes}, _from, state)
       when minutes == :until_off or (is_integer(minutes) and minutes in 1..10_080) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{} = grant ->
        if Grant.on?(grant, State.now()) do
          state = Grants.set_duration(state, grant, minutes)
          {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}
        else
          {:reply, {:error, :off}, state}
        end
    end
  end

  defp answer({:set_mode, id, mode}, _from, state) when mode in [:ask, :all] do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{} = grant ->
        cond do
          not Grant.on?(grant, State.now()) ->
            {:reply, {:error, :off}, state}

          true ->
            state = Grants.set_mode(state, grant, mode)
            {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}
        end
    end
  end

  defp answer({:set_start, id, start}, _from, state)
       when start in [:off, :on, :auto] do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{} = grant ->
        cond do
          start in Grant.starts(grant) ->
            state = Grants.set_start(state, grant, start)
            {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}

          Grant.always_asks?(grant) ->
            {:reply, {:error, :always_asks}, state}

          true ->
            {:reply, {:error, :to_review}, state}
        end
    end
  end

  defp answer({:set_except, id, entries}, _from, state) when is_list(entries) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{kind: :network} = grant ->
        state = Grants.set_except(state, grant, entries)
        {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}

      _other ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp answer({:turn_off, id}, _from, state) do
    Grants.with_grant(state, id, fn grant ->
      {Grant.put_down(grant), "#{grant.name} turned off: it gives nothing"}
    end)
  end

  # The agent sandbox's section of an export (`MWTClient.Sandbox.Transfer`).
  defp answer(:transfer_export, _from, state),
    do: {:reply, MWTClient.Sandbox.Server.Transfers.export(state), state}

  defp answer({:transfer_import, mode, prepared}, _from, state) when mode in [:merge, :replace] do
    state = MWTClient.Sandbox.Server.Transfers.import(state, mode, prepared)
    {:reply, :ok, state}
  end

  # The console (`MWTClient.Sandbox.Console`): a command you typed goes
  # into the VM only if it carries none of your real values, and each run
  # is in the activity log, its output not, and in the console's history
  # (`MWTClient.Sandbox.ConsoleHistory`), its output with it, in memory.
  defp answer({:console_check, command}, _from, state) do
    case Values.carried(state, [command]) do
      nil -> {:reply, :ok, state}
      name -> {:reply, {:error, {:carries_value, name}}, state}
    end
  end

  defp answer({:console_ran, run}, _from, state) do
    state =
      state
      |> State.log(%{outcome: :vm, summary: MWTClient.Sandbox.Console.summary(run)})
      |> State.change(
        :console_runs,
        &MWTClient.Sandbox.ConsoleHistory.add(Map.get(&1, :console_runs, []), run)
      )

    {:reply, {:ok, hd(state.console_runs)}, state}
  end

  defp answer(:console_runs, _from, state),
    do: {:reply, Map.get(state, :console_runs, []), state}

  defp answer(:clear_console_runs, _from, state),
    do: {:reply, :ok, State.change(state, :console_runs, fn _state -> [] end)}

  # Locks a resource (`Grant.resource/1`): every use of it is refused,
  # whatever the grants say, until you unlock it. Its connections close,
  # and what waited on its grants is refused. No grant changes.
  defp answer({:lock, resource}, _from, state) do
    with name when is_binary(name) <- resource_name(state, resource),
         {:ok, locked} <- state |> Locks.lock(resource, :you) |> State.save() do
      touched = for g <- state.grants, Grant.resource(g) == resource, do: g.id
      agents? = &(resource == :machine and &1.kind == :command and &1.script_from == :agent)

      locked =
        locked
        |> then(
          &Enum.reduce(touched, &1, fn id, acc -> Approvals.settle_waiting(acc, id, :locked) end)
        )
        |> Approvals.settle_waiting_where(agents?, :locked)
        |> State.log(%{
          outcome: :grant,
          summary: "#{name} locked by you: every use refused until you unlock it"
        })
        |> HostRuns.stop_running(
          HostRuns.running_with(state, resource),
          "#{name} was locked by you"
        )
        |> State.write_inbox()

      {:reply, :ok, locked}
    else
      nil -> {:reply, {:error, :not_found}, state}
      {:error, :storage} = error -> {:reply, error, state}
    end
  end

  defp answer({:unlock, resource}, _from, state) do
    with name when is_binary(name) <- resource_name(state, resource),
         {:ok, unlocked} <- state |> Locks.unlock(resource, :you) |> State.save() do
      still =
        if Map.has_key?(unlocked.locks, resource),
          do: ": the isolation still holds it, until you release the VM",
          else: ""

      unlocked =
        unlocked
        |> State.log(%{outcome: :grant, summary: "#{name} unlocked by you#{still}"})
        |> State.write_inbox()

      {:reply, :ok, unlocked}
    else
      nil -> {:reply, {:error, :not_found}, state}
      {:error, :storage} = error -> {:reply, error, state}
    end
  end

  defp answer({:allow_all, id, duration}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{state: :on} = grant ->
        allow_all(state, grant, duration)

      %Grant{} ->
        {:reply, {:error, :off}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp answer({:revoke_allowance, id, allowance_id}, _from, state) do
    Grants.with_grant(state, id, fn grant ->
      {%{grant | allowances: Enum.reject(grant.allowances, &(&1.id == allowance_id))}, nil}
    end)
  end

  defp answer({:create_grant, attrs}, _from, state) do
    # A preset that filled the form, MWT's or yours; a type is no preset.
    preset =
      case Presets.find(to_string(attrs["preset"]), state.username) do
        {:ok, %{id: id} = preset} when is_binary(id) -> preset
        _type_or_none -> nil
      end

    case Grants.build_new(state, attrs, preset) do
      {:ok, grant, value} ->
        grant = pinned(state, grant)

        # A value pasted only for a credential the grant makes.
        values =
          if value,
            do: Map.put(state.values, Grant.credential_id(grant), value),
            else: state.values

        state =
          %{state | values: values}
          |> State.change(:grants, &(&1.grants ++ [grant]))
          |> Grants.put_credential_of(grant)
          |> Grants.put_network_of(grant)
          |> State.log(%{outcome: :grant, summary: "#{grant.name} added", grant_id: grant.id})
          |> Grants.add_preset_actions(grant, preset, attrs["fill"])
          |> State.write_inbox()
          |> State.changed()

        # As kept: over its credential and its network, their fields copied.
        {:reply, {:ok, grant_by_id(state, grant.id)}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  defp answer({:update_grant, id, attrs}, _from, state) do
    with %Grant{} = grant <- Enum.find(state.grants, &(&1.id == id)),
         {:ok, updated} <-
           Grants.edit_grant(grant, attrs, state.grants, Map.get(state, :credentials, [])) do
      updated = pinned(state, updated)

      state =
        state
        |> State.replace_grant(updated)
        |> Grants.put_credential_of(updated)
        |> Grants.put_network_of(updated)
        |> State.log(%{
          outcome: :grant,
          summary: "#{grant.name} edited",
          grant_id: id,
          details: Grant.changes(grant, updated)
        })
        # What was minted the old way, and the cards asked under the old
        # definition, don't outlive the edit.
        |> Grants.edited(grant, updated)
        |> State.write_inbox()
        |> State.changed()

      {:reply, {:ok, grant_by_id(state, id)}, state}
    else
      nil -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp answer({:set_value, id, value}, _from, state) do
    value = State.opened(value)

    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{source: {:minted, _}} ->
        {:reply, {:error, :minted}, state}

      grant ->
        # The value is its credential's: every grant over it uses it.
        state =
          %{state | values: Map.put(state.values, Grant.credential_id(grant), value)}
          |> State.change(:grants, & &1.grants)
          |> State.log(%{outcome: :grant, summary: "#{grant.name}: value replaced", grant_id: id})
          |> State.write_inbox()
          |> State.changed()

        {:reply, :ok, state}
    end
  end

  defp answer({:set_credential_value, id, value}, _from, state) do
    value = State.opened(value)

    case Enum.find(Map.get(state, :credentials, []), &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Credential{source: {:minted, _}} ->
        {:reply, {:error, :minted}, state}

      %Credential{} when value in [nil, ""] ->
        {:reply, {:error, :empty}, state}

      credential ->
        state =
          %{state | values: Map.put(state.values, id, value)}
          |> State.change(:grants, & &1.grants)
          |> State.log(%{outcome: :grant, summary: "#{credential.name}: value replaced"})
          |> State.write_inbox()
          |> State.changed()

        {:reply, :ok, state}
    end
  end

  defp answer({:delete_grant, id}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{} = grant ->
        if Grant.built_in?(grant),
          do: {:reply, {:error, :built_in}, state},
          else: {:reply, :ok, Grants.delete(state, grant, "#{grant.name} removed")}
    end
  end

  defp answer({:decide, approval_id, decision}, _from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      nil ->
        {:reply, {:error, :not_waiting}, state}

      approval ->
        if Approvals.fits?(approval, decision, state),
          do:
            {:reply, :ok,
             state |> Approvals.decide(approval, decision) |> declined(approval, decision)},
          else: {:reply, {:error, :bad_decision}, state}
    end
  end

  defp answer(:agent_grants, _from, state),
    do: {:reply, state.grants, state}

  defp answer({kind, _ask}, _from, state)
       when kind in [:request_access, :propose, :request_command, :call] and
              is_map_key(state, :firewall) and state.firewall.isolated != nil,
       do: {:reply, {:error, :isolated}, Firewall.refused(state)}

  defp answer({:request_access, ask}, _from, state) do
    case Approvals.activation(state, ask) do
      {:ok, approval} ->
        case Firewall.observe(state, {:ask, ask_key(approval), approval.title}) do
          {:pass, state} ->
            {state, held} = Approvals.hold_activation(state, approval)
            {:reply, {:ok, held}, state}

          {_refused, state} ->
            {:reply, {:error, :firewall}, state}
        end

      {:already_on, grant} ->
        {:reply, {:already_on, grant}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A grant an agent proposes: saved at once, off, to review on its page;
  # the agent waits on an ask that turning it on answers.
  defp answer({:propose, ask}, _from, state) do
    case Approvals.proposal(state, ask) do
      {:ok, made, approval, previous} ->
        case Firewall.observe(state, {:ask, ask_key(approval), approval.title}) do
          {:pass, state} ->
            state =
              case made do
                {:grant, grant} ->
                  Grants.save_proposed(state, grant, previous)

                resource ->
                  MWTClient.Sandbox.Server.Resources.save_proposed(state, resource, previous)
              end

            {state, held} = Approvals.hold_activation(state, approval)

            # Proposed again while its ask waited: that ask, now for the
            # changed proposal.
            {state, held} =
              if previous && not held.proposal.updated do
                held = %{held | proposal: %{held.proposal | updated: true}}
                {State.replace_approval(state, held), held}
              else
                {state, held}
              end

            {:reply, {:ok, held}, state}

          {_refused, state} ->
            {:reply, {:error, :firewall}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # You accept a resource an agent proposed, on its page.
  defp answer({:review_resource, resource, revision}, _from, state) do
    case MWTClient.Sandbox.Server.Resources.review(state, resource, revision) do
      {:ok, state, reviewed} -> {:reply, {:ok, reviewed}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # You accept a grant an agent proposed, on its page: reviewed, and, with
  # `{minutes, uses}`, turned on, which answers the agent waiting for it.
  defp answer({:review, id, enable, revision}, _from, state) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Grant{} = grant ->
        cond do
          not Grant.to_review?(grant) ->
            {:reply, {:error, :reviewed}, state}

          # The agent proposed it again since the page you accepted from
          # showed it: you haven't read what it is now.
          not MWTClient.Sandbox.Proposal.accepts?(grant.proposal, revision) ->
            {:reply, {:error, :changed}, state}

          # Its resource first: you accept a grant over what you have.
          MWTClient.Sandbox.Resource.to_review?(
            Grant.resource(grant),
            Map.get(state, :credentials, []),
            Map.get(state, :networks, [])
          ) ->
            {:reply, {:error, :resource_to_review}, state}

          enable != :keep_off and
              Grants.turn_on_refusal(state, %{grant | proposal: nil}) == :no_value ->
            {:reply, {:error, :no_value}, state}

          true ->
            # Accepting is approving it: a saved command's files are pinned
            # as they are now, as saving one on its page does (Q10), so a
            # file changed after you accepted makes its next run ask.
            state = Grants.review(state, pinned(state, grant))
            reviewed = Enum.find(state.grants, &(&1.id == id))

            state =
              case enable do
                :keep_off ->
                  state

                {minutes, uses} ->
                  state
                  |> Grants.turn_on(reviewed, minutes, uses, "")
                  |> Approvals.settle_activations(id, minutes, uses)
              end

            {:reply, {:ok, Enum.find(state.grants, &(&1.id == id))}, state}
        end
    end
  end

  defp answer({:command_saved, approval_id, grant_id}, _from, state) do
    with %Grant{kind: :command, script: script} = grant when is_binary(script) <-
           Enum.find(state.grants, &(&1.id == grant_id)),
         {:ok, state} <- HostRuns.saved(state, approval_id, grant) do
      {:reply, :ok, state}
    else
      _other -> {:reply, {:error, :not_found}, state}
    end
  end

  defp answer({:request_command, ask}, _from, state) do
    with {:ok, grant, ask, opts} <-
           HostRuns.command_grant(state, ask),
         {:ok, checked} <-
           HostCommand.check(
             ask,
             state.settings.shares,
             state.grants,
             opts ++ ShareSync.command_opts(state)
           ),
         {:ok, approval} <- HostRuns.command_approval(state, checked, grant),
         {:pass, state} <- screen_command(state, approval) do
      {state, held} = HostRuns.hold_command(state, approval)
      state = HostRuns.auto_approve(state, held)
      {:reply, {:ok, Enum.find(state.approvals, &(&1.id == held.id)) || held}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, refused_values(state, reason, ask)}
      {_refused, state} -> {:reply, {:error, :firewall}, state}
    end
  end

  # An action, called by id: a request action's request, which MWT sends
  # itself, or a command action's script.
  defp answer({:call, ask}, from, state) do
    case Enum.find(state.grants, &(&1.id == ask.grant and &1.kind == :request)) do
      nil ->
        answer({:request_command, Map.put(ask, :script, nil)}, from, state)

      %Grant{} = _request ->
        with {:ok, grant, checked} <- HostRuns.call_request(state, ask),
             {:pass, state} <- HostRuns.minting(state, grant, checked.call),
             {:ok, approval} <- HostRuns.command_approval(state, checked, grant) do
          {state, held} = HostRuns.hold_command(state, approval)
          state = HostRuns.auto_approve(state, held)
          {:reply, {:ok, Enum.find(state.approvals, &(&1.id == held.id)) || held}, state}
        else
          {{:error, reason}, state} ->
            {:reply, {:error, reason}, refused_values(state, reason, ask)}

          {:error, reason} ->
            {:reply, {:error, reason}, refused_values(state, reason, ask)}
        end
    end
  end

  defp answer({:stop_command, approval_id}, _from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      %Approval{run: %{state: :running}} = approval ->
        state =
          state
          |> State.replace_approval(%{approval | run: %{approval.run | stopped: true}})
          |> HostRuns.stop_group(approval_id, "TERM")
          |> State.log(HostRuns.command_event(approval, "you stopped it"))

        Process.send_after(self(), {:kill_command, approval_id}, @kill_after_ms)
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :not_running}, state}
    end
  end

  # A call of MWT's tools from the VM (`MWTClient.Sandbox.MwtTools`).
  defp answer({:tool, use}, _from, state) do
    {reply, state} = Tools.decide(state, use)
    {:reply, reply, state}
  end

  defp answer({:await, approval_id, ms}, from, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      approval ->
        if Approval.final?(approval) do
          {:reply, {:ok, approval, State.grant_of(state, approval)}, state}
        else
          ref = make_ref()
          Process.send_after(self(), {:stop_waiting, approval_id, ref}, ms)
          {:noreply, Approvals.add_waiter(state, approval_id, {from, {:await, ref}})}
        end
    end
  end

  defp answer({:update_settings, attrs}, _from, state) do
    case Settings.cast(state.settings, attrs, Resources.most(Resources.host())) do
      {:ok, settings} ->
        settings = LayerVersions.change(state.username, state.settings, settings, :you, :edit)

        # The inbox, the host's description in it, follows: your notes,
        # and the guides the agents' instructions carry.
        state =
          state
          |> State.change(:settings, fn _ -> settings end)
          |> State.write_inbox()
          |> State.changed()

        {:reply, {:ok, settings}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  end

  defp answer({:timeline_enabled, thread}, _from, state),
    do: {:reply, Settings.timeline_enabled?(state.settings, thread), state}

  defp answer({:set_timeline_override, thread, mode}, _from, state) do
    case Settings.put_timeline_override(state.settings, thread, mode) do
      {:ok, settings} ->
        {:reply, :ok, state |> State.change(:settings, fn _ -> settings end) |> State.changed()}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp answer({:record_summary, thread, project, branch, token, entry}, _from, state) do
    result =
      if Settings.timeline_enabled?(state.settings, thread),
        do: SlotSummaries.persist(state.username, project, branch, token, entry),
        else: {:error, :timeline_disabled}

    {:reply, result, state}
  end

  defp answer({:restore_layer, number}, _from, state) do
    case LayerVersions.fetch(state.username, number) do
      {:ok, version} ->
        restored = %{state.settings | image_layer: LayerVersions.text(version)}
        settings = LayerVersions.change(state.username, state.settings, restored, :you, :restore)
        state = state |> State.change(:settings, fn _ -> settings end) |> State.changed()
        {:reply, {:ok, settings}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  ## Projects and handoffs
  #
  # The records only: the git work runs in the caller's process
  # (`MWTClient.Sandbox.Projects`, `MWTClient.Sandbox.Handoffs`), or in a
  # task for the mirrors, never here.

  # Records are upgraded on the way out too: a process whose code was
  # reloaded in development keeps the ones it read before.
  defp answer(:projects, _from, state) do
    {:reply,
     %{
       projects: Enum.map(state.projects, &Project.upgrade/1),
       mirror: state.mirror,
       waiting_handoffs: state.waiting_handoffs,
       vm: %{name: state.vm.name, status: state.vm.status, started_at: state.vm.started_at},
       dir: Path.dirname(state.folders.optmem),
       shares: state.settings.shares,
       workspace: ShareSync.root(state)
     }, state}
  end

  defp answer({:add_project, %Project{} = project}, _from, state) do
    if Enum.any?(state.projects, &(&1.path == project.path or &1.name == project.name)) do
      {:reply, {:error, :already_added}, state}
    else
      {:reply, {:ok, project},
       state
       |> State.change(:projects, &(&1.projects ++ [project]))
       |> State.log(%{
         outcome: :project,
         summary: "#{project.name} is a project",
         details: Project.details(project)
       })
       |> State.write_inbox()
       |> State.changed()}
    end
  end

  defp answer({:put_project, %Project{name: name} = project, summary}, _from, state) do
    case Enum.find(state.projects, &(&1.name == name)) do
      %Project{} = before ->
        {:reply, {:ok, project},
         state
         |> State.change(:projects, fn state ->
           Enum.map(state.projects, &if(&1.name == name, do: project, else: &1))
         end)
         |> State.log(%{
           outcome: :project,
           summary: summary,
           details: Project.changes(before, project) ++ Project.details(project)
         })
         |> State.changed()}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # A project was used just now (`MWTClient.Sandbox.Project.used_at/1`).
  # Not logged: using it is in the log already, where it says something.
  defp answer({:used_project, name}, _from, state) do
    now = State.now()

    {:reply, :ok,
     state
     |> State.change(:projects, fn state ->
       Enum.map(state.projects, fn project ->
         if project.name == name,
           do: %{Project.upgrade(project) | last_used_at: now},
           else: project
       end)
     end)
     |> State.changed()}
  end

  defp answer({:remove_project, name}, _from, state) do
    case Enum.find(state.projects, &(&1.name == name)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      project ->
        {:reply, {:ok, project},
         state
         |> State.change(:projects, &Enum.reject(&1.projects, fn p -> p.name == name end))
         |> State.change(:mirror, &Map.delete(&1.mirror, name))
         |> State.log(%{
           outcome: :project,
           summary: "#{name} is no longer a project",
           details: Project.details(project)
         })
         |> State.write_inbox()
         |> State.changed()}
    end
  end

  # What one update of a mirror did. Logged only when it says something
  # new: a rescue, a failure, or that it works again.
  defp answer({:mirrored, name, entry}, _from, state) do
    before = Map.get(state.mirror, name, %{})

    summary =
      cond do
        entry[:error] && entry.error != before[:error] ->
          "The clone of #{name} could not be prepared: #{entry.error}"

        is_nil(entry[:error]) && before[:error] ->
          "The clone of #{name} reads your branches again"

        true ->
          nil
      end

    state =
      state
      |> State.change(:mirror, &Map.put(&1.mirror, name, entry))
      |> then(fn state ->
        if summary,
          do:
            State.log(state, %{
              outcome: :project,
              summary: summary,
              details: [mirror_details(name, entry, state)]
            }),
          else: state
      end)

    {:reply, :ok, state}
  end

  defp answer(:next_handoff_id, _from, state) do
    id = state.handoff_seq + 1
    {:reply, id, state |> State.change(:handoff_seq, fn _ -> id end) |> State.changed()}
  end

  # A handoff, new or updated, kept at once (`HandoffRecords`), as every
  # change of one: accepting one puts its files on your branch first,
  # which its record must not lose.
  defp answer({:put_handoff, %Handoff{} = handoff, summary}, _from, state) do
    :ok = HandoffRecords.put(state.username, handoff)
    {:reply, :ok, state |> hold_waiting(handoff) |> State.log(handoff_event(handoff, summary))}
  end

  # What the list shows of one, worked out again: nothing to log.
  defp answer({:handoff_stats, id, stats}, _from, state) do
    case handoff(state, id) do
      nil ->
        {:reply, :ok, state}

      handoff ->
        updated = %{handoff | stats: stats}
        :ok = HandoffRecords.put(state.username, updated)
        {:reply, :ok, hold_waiting(state, updated)}
    end
  end

  defp answer({:update_handoff, id, fun, summary}, _from, state) do
    case handoff(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      handoff ->
        updated = fun.(handoff)
        :ok = HandoffRecords.put(state.username, updated)

        {:reply, {:ok, updated},
         state |> hold_waiting(updated) |> State.log(handoff_event(updated, summary))}
    end
  end

  defp answer({:add_share, path}, _from, state) do
    case Shares.validate(path, state.settings.shares, workspace: ShareSync.root(state)) do
      {:ok, share} ->
        settings = %{state.settings | shares: state.settings.shares ++ [share]}

        {:reply, {:ok, share},
         state
         |> State.change(:settings, fn _ -> settings end)
         |> State.write_host()
         |> State.changed()
         |> ShareSync.request([share.path])}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp answer({:remove_share, path}, _from, state) do
    settings = %{state.settings | shares: Enum.reject(state.settings.shares, &(&1.path == path))}

    # A sync of none: the VM shows the shares there are, so this one's copy goes.
    {:reply, :ok,
     state
     |> State.change(:settings, fn _ -> settings end)
     |> State.write_host()
     |> State.changed()
     |> ShareSync.request([])}
  end

  # From a page's Sync button: answered at once, the sync goes on.
  defp answer({:sync_shares, which}, _from, state),
    do: {:reply, :ok, ShareSync.request(state, which)}

  defp answer(:sync_workspace, _from, state) do
    case ShareSync.root(state) do
      nil ->
        {:reply, :ok, ShareSync.request(state, :all)}

      root ->
        {:reply, :ok, ShareSync.request(state, [Workspace.to_vm(root), Workspace.from_vm(root)])}
    end
  end

  # From the Overview: a file of the workspace's to-vm you let go to the VM
  # though it was held back.
  defp answer({:workspace_release, path}, _from, state) when is_binary(path),
    do: {:reply, :ok, ShareSync.release(state, path)}

  # From `mwt sync`: answered when the sync ends.
  defp answer({:sync_shares_wait, which}, from, state),
    do: {:noreply, ShareSync.request(state, which, from)}

  # A connection `MWTClient.Sandbox.Gate` found waiting for you, decided
  # again with the state as it is here, and held: the firewall saw it
  # there already.
  defp answer({:destination, ip, port}, from, state),
    do: answer({:destination, ip, port, %{}}, from, state)

  # `seen` is what the connection showed before it was asked about: the
  # name it asked for (`name`), and why MWT can't read it (`why`).
  defp answer({:destination, ip, port, seen}, from, state) do
    answered = Gate.answered_for(state.username, ip)

    decision =
      Policy.decide(
        state |> State.policy() |> Map.put(:answered, answered),
        {:unread, ip, port, [Map.get(seen, :name)]},
        State.now()
      )

    names = Map.get(answered, MWTClient.Sandbox.Destinations.unmap(ip), [])
    destination(decision, "#{:inet.ntoa(ip)}", port, from, state, Map.put(seen, :answered, names))
  end

  defp answer({:authorize_network, _request}, _from, state)
       when is_map_key(state, :firewall) and state.firewall.isolated != nil,
       do: {:reply, Values.isolated(), Firewall.refused(state)}

  # A request on a connection a network grant opened, which the grant would
  # ask you about (`Gate.authorize/2`): a card of its own, the request in
  # full, as a token grant's request has. `{:ok, grant_id, decision}` once
  # allowed, with what allowed it (`MWTClient.Sandbox.Decision`).
  defp answer({:authorize_network, request}, from, state) do
    snapshot = State.policy(state)
    now = State.now()

    case Policy.decide(snapshot, {:network_request, request}, now) do
      :pass ->
        {:reply, {:ok, nil, Decision.passed(state.grants, now)}, state}

      {:allow, grant, allowance, _about} ->
        {:reply, {:ok, grant.id, Decision.allowance(grant, allowance)},
         State.used(state, grant.id)}

      {:refuse, reason} ->
        world = %{snapshot: snapshot, isolated: false, now: now}
        {event, _observation, answer} = Values.kept_refusal(reason, request, world)
        state = if event, do: State.log(state, event), else: state
        {:reply, answer, state}

      {:ask, grant, about} ->
        id = Approval.new_id("approval")

        approval = %Approval{
          id: id,
          grant_id: grant.id,
          kind: :request,
          title: about.title,
          method: request.method,
          host: request.host,
          path: request.path,
          pattern: about.pattern,
          join: Approvals.request_join(request, id),
          request: request,
          requested_at: State.now(),
          deadline: DateTime.add(State.now(), state.settings.hold_seconds, :second),
          facts: about.facts ++ [{"Through", grant.name}] ++ host_entry_fact(about, grant),
          claims: about.claims,
          host_entry: Map.get(about, :host_entry)
        }

        {:noreply, Approvals.hold(state, approval, {from, {:network_request, request}})}
    end
  end

  # Every real value at hand, for work done outside the server that must
  # look for them (a handoff's files). Never leaves MWT's own processes.
  defp answer(:secrets, _from, state), do: {:reply, Values.secrets(state), state}

  # A real value found in a handoff, which is refused. What the network
  # path finds goes to `MWTClient.Sandbox.Gate.found/4`.
  defp answer({:found, {:value, grant}, destination, :handoff}, _from, state) do
    summary = "#{grant}'s real value in #{destination} · handoff refused"
    state = State.log(state, %{outcome: :blocked, summary: summary, host: nil})
    {_verdict, state} = Firewall.observe(state, {:value, grant, destination, :handoff})
    {:reply, :cut, state}
  end

  defp answer({:authorize, _request}, _from, state)
       when is_map_key(state, :firewall) and state.firewall.isolated != nil,
       do: {:reply, Values.isolated(), Firewall.refused(state)}

  defp answer({:authorize_fixed, _request, _fixed}, _from, state)
       when is_map_key(state, :firewall) and state.firewall.isolated != nil,
       do: {:reply, Values.isolated(), Firewall.refused(state)}

  # A request MWT built from a fixed call, on a connection it opened itself
  # (`MWTClient.Sandbox.Egress.FixedCall`): decided by the call, again, as
  # it leaves. Its action still there as it was approved, still allowing
  # it, and the request the one it builds; then the values MWT fetched for
  # it go in, where its template marks them, and the answer is looked
  # through for them as any request's.
  defp answer({:authorize_fixed, request, fixed}, _from, state) do
    action = Enum.find(state.grants, &(&1.id == fixed.grant_id and &1.kind == :request))
    snapshot = State.policy(state)
    now = State.now()

    decision = action && Policy.decide(snapshot, {:call, %{grant: action.id}}, now)

    refuse = fn why ->
      state =
        State.log(
          state,
          Values.request_event(request, action, :refused, "Fixed call #{fixed.name} · #{why}")
        )

      {:reply, Values.deny(403, "mwt_denied", "MWT refused this fixed call: #{why}.", action),
       state}
    end

    cond do
      is_nil(action) or Approval.digest(Grant.definition(action)) != fixed.definition ->
        refuse.("it was edited or removed since it was called")

      match?({:refuse, _}, decision) ->
        refuse.("a grant it needs no longer gives it, or you locked what it reaches")

      not Policy.fixed_route_current?(snapshot, request, fixed, now) ->
        refuse.("the network grant or route changed before it was sent")

      String.downcase(request.host || "") != String.downcase(SavedRequest.host(action) || "") or
          request.method != action.method ->
        refuse.("it isn't the request the call builds")

      true ->
        values = for s <- fixed.swaps, do: {s.label, s.placeholder, s.value, s.within}

        # As its call was decided, which the call's own line says.
        state =
          State.log(
            state,
            Map.put(
              Values.request_event(
                request,
                action,
                :swapped,
                "Fixed call · #{action.name} · built by MWT from the agent's values"
              ),
              :decision,
              State.card_decision(state, fixed[:card])
            )
          )

        {:reply, {:forward, Values.replace(values), Values.scan(state, request.host, action)},
         state}
    end
  end

  # A real value in what the VM wrote is refused before anything else, so
  # nothing of the request (its path included) is described or logged.
  defp answer({:authorize, request}, from, state) do
    texts =
      [request.path, request.body] ++ Enum.map(request.headers, fn {_name, value} -> value end)

    case Values.carried(state, texts) do
      nil ->
        authorize(request, from, state)

      grant ->
        state =
          State.log(state, %{
            outcome: :blocked,
            summary: "#{grant}'s real value in a request from the VM · blocked",
            host: request.host,
            port: Map.get(request, :port, 443)
          })

        {_verdict, state} = Firewall.observe(state, {:value, grant, request.host, :request})
        {:reply, Values.value_blocked(), state}
    end
  end

  defp authorize(request, from, state) do
    decision =
      Policy.decide(
        State.policy(state),
        {:request, request},
        State.now()
      )

    case endpoint(state, decision, request) do
      {:ok, ask} ->
        decided(decision, Map.put(request, :endpoint, ask), from, state)

      {:error, code, message} ->
        grant = elem(decision, 1)
        state = State.log(state, Values.request_event(request, grant, :refused, message))
        {:reply, Values.deny(403, code, message, grant), state}

      nil ->
        case minting(state, decision, request) do
          {:pass, state} -> decided(decision, request, from, state)
          {refused, state} -> {:reply, refused, state}
        end
    end
  end

  # A credential endpoint the grant takes is answered by MWT
  # (`MWTClient.Sandbox.CredentialEndpoint`), so the firewall's rule for
  # credential endpoints has nothing to stop: no value goes there from the
  # VM, and nothing real comes back to it. Checked before anyone is asked,
  # so a card never shows a request that can't be answered.
  defp endpoint(state, decision, request) when elem(decision, 0) in [:allow, :ask] do
    case elem(decision, 1) do
      %Grant{kind: :token} = grant ->
        # Signing as an account any grant over the credential that is on
        # names, for an audience any of them lists; what is signed belongs
        # to the one grant that does both.
        over = on_over(state, grant)
        view = credential_view(grant, over)

        case CredentialEndpoint.recognize(view, request) do
          nil ->
            nil

          found ->
            with {:ok, %{kind: :sign_jwt} = ask} <- CredentialEndpoint.check(view, request, found) do
              CredentialEndpoint.signer([grant | over], ask)
            end
        end

      # A network grant's answer carries no value: there is no credential
      # in the request to trade.
      _grant ->
        nil
    end
  end

  defp endpoint(_state, _decision, _request), do: nil

  # A request that would carry a grant's value to a credential endpoint
  # (`MWTClient.Sandbox.Firewall.minting/3`) is refused before its value is
  # fetched, unless the firewall's rule only alerts: its answer would be a
  # credential the VM holds.
  defp minting(state, {:allow, %Grant{kind: :token} = grant, _allowance, _about}, request),
    do: minting_of(state, grant, request)

  defp minting(state, {:ask, %Grant{kind: :token} = grant, _about}, request),
    do: minting_of(state, grant, request)

  defp minting(state, _decision, _request), do: {:pass, state}

  defp minting_of(state, grant, request) do
    with entry when is_binary(entry) <-
           MWTClient.Sandbox.Firewall.minting(Firewall.of(state), request.host, request.path),
         {verdict, state} when verdict != :pass <-
           Firewall.observe(state, {:mint, grant.name, request.host, entry}) do
      state =
        State.log(
          state,
          Values.request_event(
            request,
            grant,
            :blocked,
            "#{grant.name}'s value to #{request.host}, a credential endpoint · refused"
          )
        )

      {Values.minting(grant, request.host, entry), state}
    else
      nil -> {:pass, state}
      {:pass, state} -> {:pass, state}
    end
  end

  defp decided(decision, request, from, state) do
    case decision do
      :pass ->
        state =
          State.log(state, %{
            decision: Decision.passed(state.grants, State.now()),
            outcome: :read,
            summary: "Read by MWT, no credential in it",
            host: request.host,
            port: Map.get(request, :port, 443),
            method: request.method,
            path: request.path,
            exchange_id: Map.get(request, :exchange)
          })

        {:reply, {:forward, Values.replace([]), Values.scan(state, request.host)}, state}

      {:refuse, reason} ->
        world = %{snapshot: State.policy(state), isolated: false, now: State.now()}
        {event, observation, answer} = Values.kept_refusal(reason, request, world)
        state = if event, do: State.log(state, event), else: state

        state =
          if observation,
            do: state |> Firewall.observe(observation) |> elem(1),
            else: state

        {:reply, answer, state}

      # Let through by a network grant alone: no credential in it, nothing
      # to put in.
      {:allow, %Grant{kind: :network} = grant, allowance, about} ->
        state =
          state
          |> State.used(grant.id)
          |> used_through(about)
          |> State.log(%{
            decision: Decision.allowance(grant, allowance),
            outcome: :read,
            summary: "#{about.title} · let through by #{grant.name}",
            host: request.host,
            port: Map.get(request, :port, 443),
            grant_id: grant.id,
            method: request.method,
            path: request.path,
            exchange_id: Map.get(request, :exchange)
          })

        {:reply, {:forward, Values.replace([]), Values.scan(state, request.host)}, state}

      {:allow, grant, allowance, about} ->
        why =
          cond do
            allowance.pattern == :all -> "every use allowed"
            true -> "allowed like an earlier one"
          end

        state =
          state
          |> used_through(about)
          |> State.log(
            Map.put(
              Values.request_event(request, grant, :swapped, "#{about.title} · #{why}"),
              :decision,
              Decision.allowance(grant, allowance)
            )
          )

        {:noreply, Values.let_through(state, grant, request, from)}

      {:ask, grant, about} ->
        id = Approval.new_id("approval")
        # One resource's say has no list of who asks: its grant does.
        about = Map.put_new(about, :asking, [grant.id])
        also = about.asking -- [grant.id]

        approval = %Approval{
          id: id,
          grant_id: grant.id,
          also: also,
          kind: :request,
          title: about.title,
          method: request.method,
          host: request.host,
          path: request.path,
          pattern: about.pattern,
          join: Approvals.request_join(request, id),
          request: request,
          requested_at: State.now(),
          deadline: DateTime.add(State.now(), state.settings.hold_seconds, :second),
          facts: about.facts ++ asking_facts(state, about) ++ host_entry_fact(about, grant),
          claims: about.claims,
          host_entry: Map.get(about, :host_entry)
        }

        # The token grant whose value the request carries goes in once the
        # card is allowed, whichever grant asked.
        request = Map.put(request, :credential, Map.get(about, :credential))
        {:noreply, Approvals.hold(state, approval, {from, {:request, request}})}
    end
  end

  # The token grants over `grant`'s credential that are on.
  defp on_over(state, %Grant{} = grant) do
    id = Grant.credential_id(grant)
    now = State.now()

    Enum.filter(
      state.grants,
      &(&1.kind == :token and Grant.credential_id(&1) == id and Grant.on?(&1, now))
    )
  end

  # A token grant as its credential's endpoints see it: the accounts and
  # hosts of every grant over the credential that is on (`over`), together.
  defp credential_view(%Grant{} = grant, over) do
    %{
      grant
      | signs_as:
          over |> Enum.flat_map(& &1.signs_as) |> Enum.concat(grant.signs_as) |> Enum.uniq(),
        hosts: over |> Enum.flat_map(& &1.hosts) |> Enum.concat(grant.hosts) |> Enum.uniq()
    }
  end

  # Marks used every grant that let a use through beside the one answering.
  defp used_through(state, about),
    do: Enum.reduce(Map.get(about, :through, []), state, &State.used(&2, &1))

  # The grants a card answers for, and those that let its use through,
  # by name: one card for every grant that asked about one use.
  defp asking_facts(state, about) do
    names = fn ids ->
      ids
      |> Enum.map(&grant_by_id(state, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(", ", & &1.name)
    end

    asking = Map.get(about, :asking, [])
    through = Map.get(about, :through, [])
    network = for id <- asking, %Grant{kind: :network} = g <- [grant_by_id(state, id)], do: g

    Enum.map(network, &{"Through", &1.name}) ++
      if(length(asking) > 1, do: [{"Asking", names.(asking)}], else: []) ++
      if through != [], do: [{"Let through by", names.(through)}], else: []
  end

  defp grant_by_id(state, id), do: Enum.find(state.grants, &(&1.id == id))

  @impl true
  def handle_cast(message, state), do: message |> cast_in(State.current(state)) |> settled()

  defp cast_in({:log, attrs}, state), do: {:noreply, State.log(state, attrs)}

  # A use the network path let through (`MWTClient.Sandbox.Gate`).
  defp cast_in({:used, grant_id}, state), do: {:noreply, State.used(state, grant_id)}

  # What the firewall's watch found (`MWTClient.Sandbox.Watch`): logged,
  # alerts notified; and the isolation it already marked, recorded and
  # carried out.
  defp cast_in({:firewall_found, findings}, state),
    do: {:noreply, Enum.reduce(findings, state, &Firewall.found(&2, &1))}

  defp cast_in({:firewall_isolate, finding}, state) do
    if Firewall.isolated?(state),
      do: {:noreply, state},
      else: {:noreply, Firewall.isolate(state, finding)}
  end

  # A request MWT read began: it runs until its call hands over what it
  # carried, or the call's process ends (`Running`).
  defp cast_in({:began, id, pid, unfinished}, state) when is_binary(id) and is_pid(pid),
    do: {:noreply, Running.began(state, id, pid, unfinished)}

  # What a request MWT read carried and what came back, kept with its
  # events once the request ended, and how long it took.
  defp cast_in({:exchange, id, exchange}, state) do
    {ms, state} = Running.ended(state, id)
    {:noreply, request_ended(state, id, ms, exchange)}
  end

  # The VM's busiest processes, from the monitor.
  defp cast_in({:processes, processes}, state) when is_list(processes) do
    {_verdict, state} = Firewall.observe(state, {:processes, processes})
    {:noreply, state}
  end

  defp cast_in(:firewall_seen, state), do: {:noreply, Firewall.seen(state)}

  defp cast_in({:tool_applied, approval_id, outcome}, state),
    do: {:noreply, Tools.applied(state, approval_id, outcome)}

  defp cast_in({:proxy, status}, state) do
    {:noreply, State.change(state, :proxy, fn _ -> status end)}
  end

  # A real value in what a request carried, though none should be, is
  # hidden before it is kept or shown.
  defp redacted(state, exchange) do
    secrets = Gate.log_secrets(state)
    Exchange.redact(exchange, &Secrets.replace(secrets, &1, @withheld))
  end

  # A request ended: its lines say how long it took, and the pages hear of
  # it, to stop marking it running and read what it carried, if kept.
  defp request_ended(state, id, ms, exchange) do
    cond do
      exchange -> Journal.record_exchange(state.username, id, redacted(state, exchange), ms)
      ms -> Journal.record_took(state.username, id, ms)
      true -> :ok
    end

    State.broadcast(state, {:sandbox_exchange, id, ms})
    state
  end

  # While the VM runs, each mirror follows your branches: the task looks at
  # them, and updates the mirrors whose branches moved.
  @impl true
  def handle_info(message, state), do: message |> info(State.current(state)) |> settled()

  # Every message ends here, before its answer goes: the network path's
  # view is published again if what it reads changed (`Gate.publish/1`),
  # then what a grant let through closes once it stopped being live
  # (`Grants.close_ended/1`). A call that turned a grant off returns once
  # no new decision lets it through and its connections are closing.
  defp settled({:reply, reply, state}), do: {:reply, reply, settle(state)}
  defp settled({:reply, reply, state, extra}), do: {:reply, reply, settle(state), extra}
  defp settled({:noreply, state}), do: {:noreply, settle(state)}
  defp settled({:noreply, state, extra}), do: {:noreply, settle(state), extra}
  defp settled(other), do: other

  defp settle(state),
    do: state |> Gate.publish() |> Grants.close_ended() |> Kept.keep()

  defp info(:mirror, state) do
    if state.vm.status == :running and state.projects != [] and
         :mirror not in Map.values(state.tasks) do
      %{username: username, projects: projects, mirror: mirror} = state
      shares = state.settings.shares
      vm = %{name: state.vm.name, status: state.vm.status, started_at: state.vm.started_at}

      {:noreply,
       State.task(state, :mirror, fn ->
         Projects.follow(username, projects, mirror, vm, @mirror_retry_seconds, shares)
       end)}
    else
      {:noreply, state}
    end
  end

  # MWT's own files changed: their copy in the VM follows within moments.
  defp info(:sync_inbox, state), do: {:noreply, Copying.start(state)}

  # The firewall's windows changed a moment ago: handed to `UnlockState` now.
  defp info(:keep, state), do: {:noreply, Kept.due(state)}

  # A sync of the shared folders is due, or was waiting for the VM to be
  # free (`ShareSync`).
  defp info(:sync, state), do: {:noreply, ShareSync.start(state)}

  defp info({:sync_progress, vm, path, phase}, state),
    do: {:noreply, ShareSync.progress(state, vm, path, phase)}

  defp info({:sync_settle, paths}, state), do: {:noreply, ShareSync.settle(state, paths)}

  # A file of the workspace's to-vm went to the VM with something shaped
  # like a credential, the firewall's rule only alerting.
  defp info({:workspace_inbound, path, words}, state),
    do: {:noreply, ShareSync.alert(state, path, words)}

  defp info(:poll, state) do
    if state.vm.busy != nil or Enum.any?(Map.values(state.tasks), &(&1 == :check)),
      do: {:noreply, state},
      else: {:noreply, Machine.check(state)}
  end

  # The timers only say when to look: what has ended is read from the clock
  # (`sweep/1`), as every decision does (`Grant.on?/2`, `Allowance.covers?/3`).
  defp info({:expire_grant, _id, _expires_at}, state), do: {:noreply, Grants.sweep(state)}

  # YOLO mode is gone (2026-11-18): a timer set by a server started before.
  defp info({:yolo_ends, _since}, state), do: {:noreply, state}

  defp info({:expire_allowance, _id, _allowance_id}, state),
    do: {:noreply, Grants.sweep(state)}

  # Timers stand still while the machine sleeps, and a wall clock can be set
  # back: looking again every so often keeps what is shown right. A write
  # whose :flush got lost is made here too.
  defp info(:sweep, state),
    do:
      {:noreply,
       state
       |> Grants.sweep()
       |> Firewall.prune()
       |> State.resave()}

  # Each timer names the deadline it was set for: a command waiting a second
  # time, with its output, has a later one, which its first timer must not
  # end.
  defp info({:give_up, approval_id, deadline}, state) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.status == :waiting)) do
      %Approval{deadline: ^deadline} = approval -> {:noreply, Approvals.give_up(state, approval)}
      _settled_or_moved -> {:noreply, state}
    end
  end

  defp info({:command_started, approval_id, group}, state) do
    case state.running do
      %{^approval_id => :stop} ->
        HostRun.stop(group, "TERM")
        Process.send_after(self(), {:kill_command, approval_id}, @kill_after_ms)
        {:noreply, put_in(state.running[approval_id], group)}

      _ ->
        {:noreply, put_in(state.running[approval_id], group)}
    end
  end

  # Stopping sent TERM; whatever still runs gets KILL.
  defp info({:kill_command, approval_id}, state),
    do: {:noreply, HostRuns.stop_group(state, approval_id, "KILL")}

  # An agent waited as long as it said it would: it hears "still waiting",
  # and the ask stays for you.
  defp info({:stop_waiting, approval_id, ref}, state) do
    {mine, others} =
      state.waiters
      |> Map.get(approval_id, [])
      |> Enum.split_with(&match?({_from, {:await, ^ref}}, &1))

    approval = Enum.find(state.approvals, &(&1.id == approval_id))
    Enum.each(mine, fn {from, _} -> GenServer.reply(from, {:pending, approval}) end)

    waiters =
      if others == [],
        do: Map.delete(state.waiters, approval_id),
        else: Map.put(state.waiters, approval_id, others)

    {:noreply, %{state | waiters: waiters}}
  end

  defp info(:flush, state) do
    _ = State.persist(state)
    {:noreply, %{state | flush: nil}}
  end

  defp info({port, {:data, {_eol, line}}}, %{build: port} = state) do
    {:noreply, Machine.build_line(state, line)}
  end

  defp info({port, {:exit_status, status}}, %{build: port} = state) do
    state = %{state | build: nil}

    state =
      if status == 0 do
        Machine.built(state, Image.read_build(Machine.build_dir(state), state.image.building))
      else
        state
        |> State.change(
          :image,
          &%{
            &1.image
            | building?: false,
              building: nil,
              error: "The build failed (exit #{status}). See the log."
          }
        )
        |> State.log(%{
          outcome: :vm,
          summary: "Image build failed",
          details: [
            EventDetails.section("The build", [
              {"Exit", status},
              {"Image",
               state.image.building && "#{state.image.building.name}:#{state.image.building.tag}"},
              {"Last lines of its log",
               {:code, state.image.log |> Enum.take(60) |> Enum.reverse() |> Enum.join("\n")}}
            ])
          ]
        })
      end

    {:noreply, state}
  end

  defp info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {purpose, tasks} = Map.pop(state.tasks, ref)

    state = Machine.finished(%{state | tasks: tasks}, purpose, result)
    {:noreply, Copying.release_idle(state)}
  end

  defp info({:DOWN, ref, :process, _pid, reason}, state)
       when is_map_key(state.tasks, ref) do
    {purpose, tasks} = Map.pop(state.tasks, ref)

    state =
      Machine.finished(%{state | tasks: tasks}, purpose, {:error, "crashed: #{inspect(reason)}"})

    {:noreply, Copying.release_idle(state)}
  end

  # The call a running request was on ended before the request did: it
  # ends with it, keeping the request as MWT read it, if its driver said.
  defp info({:DOWN, ref, :process, _pid, _reason}, state)
       when is_map_key(state.request_monitors, ref) do
    {{id, ms, unfinished}, state} = Running.down(state, ref)

    exchange = unfinished && Map.put(unfinished, :note, @call_ended)
    {:noreply, request_ended(state, id, ms, exchange)}
  end

  # A completion can have removed its monitor while DOWN was already queued.
  defp info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp info({:ports, pid, snapshot}, %{forwarder: pid} = state),
    do: {:noreply, Forwarding.forwarded(state, snapshot)}

  defp info({:ports, _stopped, _snapshot}, state), do: {:noreply, state}

  defp info({:EXIT, pid, reason}, %{forwarder: pid} = state),
    do: {:noreply, Forwarding.crashed(state, reason)}

  defp info(:sync_forwarder, state), do: {:noreply, Forwarding.sync(state)}

  defp info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Crash reports print the state; the vault key, real values, minted
  # tokens, private keys and commands' output must never reach a log.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state ->
        state
        |> Map.replace(:key, :redacted)
        |> Map.replace(
          :values,
          Map.new(Map.get(state, :values, %{}), fn {id, _} -> {id, :redacted} end)
        )
        |> Map.replace(:minted, :redacted)
        |> Map.replace(:sync, :redacted)
        |> Map.replace(:inbox_sync, :redacted)
        |> Map.replace(:minting, :redacted)
        |> Map.replace(:ca, :redacted)
        # What the network path's view was made from: values and the CA.
        |> Map.replace(:gate, :redacted)
        |> Map.replace(:gate_secrets, :redacted)
        |> Map.replace(:waiters, :redacted)
        # What running requests carried, kept should their calls end first.
        |> Map.replace(:requests_running, :redacted)
        |> Map.replace(:approvals, Enum.map(Map.get(state, :approvals, []), &redact_output/1))

      other ->
        other
    end)
  end

  # The clone of a project, as an update left it: its error in full.
  defp mirror_details(name, entry, state) do
    EventDetails.section("The clone", [
      {"Project", name},
      {"Folder",
       case Enum.find(state.projects, &(&1.name == name)) do
         %Project{path: path} -> path
         nil -> nil
       end},
      {"Error", entry[:error] && {:code, entry.error}},
      {"Branches it reads", {:list, tip_lines(entry[:tips])}}
    ])
  end

  defp tip_lines(tips) when is_map(tips) do
    for {branch, commit} <- Enum.sort(tips),
        do: "#{branch} #{String.slice(to_string(commit), 0, 12)}"
  end

  defp tip_lines(_none), do: []

  # A handoff's event, signed with the agent and thread that made it.
  # The handoff numbered `id`: in memory while it waits for you, else as kept.
  defp handoff(state, id) do
    Enum.find(state.waiting_handoffs, &(&1.id == id)) ||
      case HandoffRecords.get(state.username, id) do
        {:ok, handoff} -> handoff
        :error -> nil
      end
  end

  # The handoffs waiting for you, held in memory, with this one as it is
  # now: among them while it waits, gone from them once it doesn't. Told
  # to the pages either way, which show the others too.
  defp hold_waiting(state, %Handoff{id: id} = handoff) do
    State.change(state, :waiting_handoffs, fn state ->
      held = state.waiting_handoffs

      cond do
        not Handoff.waiting?(handoff) -> Enum.reject(held, &(&1.id == id))
        Enum.any?(held, &(&1.id == id)) -> Enum.map(held, &if(&1.id == id, do: handoff, else: &1))
        true -> [handoff | held]
      end
    end)
  end

  # Handoffs were part of the saved state, the latest 100, until each had
  # a row of its own (`HandoffRecords`): those still there move once, and
  # the state is saved without them from then on. What waits for you is
  # read back.
  defp moved_handoffs(username, saved) do
    :ok = HandoffRecords.import(username, Enum.map(saved || [], &Handoff.upgrade/1))
    HandoffRecords.waiting(username)
  end

  defp handoff_event(handoff, summary) do
    thread = %{id: handoff.thread_id, title: handoff.thread}

    Map.merge(Event.asked_by(handoff.agent, thread), %{
      outcome: :handoff,
      summary: summary,
      details: Handoff.details(handoff)
    })
  end

  # A command's output can hold anything it printed, secrets included.
  defp redact_output(%Approval{run: %{output: _} = run} = approval),
    do: %{approval | run: %{run | output: :redacted}}

  defp redact_output(approval), do: approval

  @impl true
  def terminate(reason, state) do
    State.persist(state)

    # A command reports back to this process, which is going away.
    for {_id, group} <- state.running, is_integer(group), do: HostRun.stop(group, "KILL")

    # Locking MWT or quitting it leaves no VM running without the proxy,
    # nor one a start, create or recreate under way would launch after
    # (`Machine.shut_down/1`). A crash leaves the VM alone, and any such
    # action too: the proxy is a process of its own and keeps going, and
    # the restarted sandbox finds the VM running and takes it back
    # (`check/1`), so a bug costs the agents their pending asks, not their
    # VM. If the restarts give up, the vault locks and the proxy closes with
    # it: the VM has no internet until an unlock takes it back.
    if deliberate?(reason), do: Machine.shut_down(state)

    # Locked: nothing the network path decides from is left. A crash keeps
    # the view, and what it allows, until the restarted server publishes.
    if deliberate?(reason), do: Gate.forget(state.username)

    :ok
  end

  # A call refused for its values (MWT's floor, a type, or a schema they
  # don't keep to), in the log: which action, which parameter and why,
  # never the value, which is the agent's text.
  defp refused_values(state, {:values, %Grant{} = grant, problem}, ask) do
    why =
      case problem do
        {:rule, param, _words} ->
          "#{param.name} isn't #{MWTClient.Sandbox.ParamSchema.words(param.schema)}"

        {:type, param} ->
          "#{param.name} isn't #{MWTClient.Sandbox.ParamSchema.words(param.schema)}"

        {:floor, param, why} ->
          "#{param.name}: #{why}"

        {:missing, param} ->
          "#{param.name} is missing"

        {:unknown, name} ->
          "it has no parameter #{name}"

        {:hidden, param, _what} ->
          "#{param.name} holds what doesn't show"
      end

    State.log(state, %{
      outcome: :refused,
      summary: "Call of #{grant.name} · refused before anything ran: #{why}",
      grant_id: grant.id,
      agent: ask_agent(ask)
    })
  end

  # Already logged where it was found (a real value, the firewall), or not
  # an ask MWT decided (too many waiting): nothing more to say here.
  defp refused_values(state, reason, _ask) when reason in [:firewall, :too_many], do: state

  # Any other refusal of a call or a command before anything ran: a line
  # in the activity log, decided by MWT, so the audit holds every action
  # the agent asked for, refused ones included.
  defp refused_values(state, reason, ask) do
    grant = Enum.find(state.grants, &(&1.id == ask_grant_id(ask)))

    what =
      case grant do
        %Grant{} -> "Call of #{grant.name}"
        nil -> "A command the agent wrote"
      end

    why = refused_ask_words(state, reason)

    State.log(state, %{
      outcome: :refused,
      summary: "#{what} · refused before anything ran: #{why}",
      grant_id: grant && grant.id,
      agent: ask_agent(ask),
      decision: Decision.refused(why)
    })
  end

  # What the VM sent is any shape it chose: only text counts.
  defp ask_grant_id(ask), do: ask |> Map.get(:grant) |> State.to_text() |> String.trim()

  defp ask_agent(ask) do
    case Map.get(ask, :agent) do
      agent when is_binary(agent) -> agent
      _other -> nil
    end
  end

  # The refusals of `HostRuns.command_grant/2` and `call_request/2`, in
  # words: the policy's own (`Explain.refusal_words/1`), a grant named by
  # its id found again first.
  defp refused_ask_words(state, {:grant_off, id}) when is_binary(id) do
    case Enum.find(state.grants, &(&1.id == id)) do
      %Grant{} = grant -> Explain.refusal_words({:grant_off, grant})
      nil -> "#{id} is off"
    end
  end

  defp refused_ask_words(_state, {:no_such_grant, _ids}), do: "no fixed call has that id"
  defp refused_ask_words(_state, {:name_a_grant, _ids}), do: "it names no fixed call"

  defp refused_ask_words(_state, {:fixed_script, _id}),
    do: "a saved command takes no command text"

  defp refused_ask_words(_state, {:takes_no_values, _what}), do: "it takes no values"

  defp refused_ask_words(_state, {:credential_endpoint, host, _entry}),
    do: "#{host} would make another credential from its value"

  defp refused_ask_words(_state, reason), do: Explain.refusal_words(reason)

  defp deliberate?(:normal), do: true

  defp deliberate?(:shutdown), do: true

  defp deliberate?({:shutdown, _detail}), do: true

  defp deliberate?(_crash), do: false

  # A connection the firewall let through, as the grants decide it.
  defp destination(decision, address, port, from, state, seen) do
    case decision do
      {:allow, %Grant{internet: true} = grant, _allowance, _about} ->
        {:reply, {:ok, grant.id}, state}

      {:refuse, {:grant_off, grant}} ->
        host = Map.get(seen, :name) || address

        state =
          State.log(state, %{
            outcome: :blocked,
            summary: "#{host}:#{port} · #{grant.name} would open it, and is off",
            host: host,
            port: port,
            grant_id: grant.id
          })

        {:reply, {:deny, "#{grant.name} would open it, and is off: ask for it to be turned on"},
         state}

      {:refuse, {:locked, resource, grant}} ->
        host = Map.get(seen, :name) || address
        summary = MWTClient.Sandbox.Resource.locked_words(resource)

        state =
          State.log(state, %{
            outcome: :blocked,
            summary: "#{host} · locked by you",
            host: host,
            port: port,
            grant_id: grant.id
          })

        {:reply, {:deny, summary}, state}

      {:refuse, {:excepted, grant, entry}} ->
        host = Map.get(seen, :name) || address
        summary = Gate.excepted_words(grant, entry, host)

        state =
          State.log(state, %{
            outcome: :blocked,
            summary: summary,
            host: host,
            port: port,
            grant_id: grant.id
          })

        {:reply, {:deny, summary}, state}

      {:refuse, {:host_blocked, network, entry}} ->
        host = Map.get(seen, :name) || address
        summary = Gate.blocked_words(network, entry, host)

        state =
          State.log(state, %{
            outcome: :blocked,
            summary: summary,
            host: host,
            port: port
          })

        {:reply, {:deny, summary}, state}

      {:refuse, reason} ->
        summary =
          case reason do
            :reserved -> "This machine or a reserved address · always refused"
            :internet_off -> "Public address with no grant on over the Internet"
            _private -> "Private address with no network grant on"
          end

        state =
          State.log(state, %{outcome: :blocked, summary: summary, host: address, port: port})

        {:reply, {:deny, summary}, state}

      {:allow, grant, _allowance, _about} ->
        {:reply, {:ok, grant.id}, State.used(state, grant.id)}

      {:ask, grant, about} ->
        name = Map.get(seen, :name)

        # What the connection showed: the name it asked for, the names
        # MWT's DNS answered for its address, and why MWT can't show more.
        facts =
          [{"Destination", about.pattern}] ++
            if(name, do: [{"Name asked for", name}], else: []) ++
            case Map.get(seen, :answered, []) do
              [] -> []
              names -> [{"Answered by MWT for it", Enum.join(names, ", ")}]
            end ++
            if(seen[:why], do: [{"Not read", seen.why}], else: []) ++
            [{"Listed as", about.listed_as}, {"Grant", grant.name}] ++
            host_entry_fact(about, grant)

        approval = %Approval{
          id: Approval.new_id("approval"),
          grant_id: grant.id,
          kind: :connection,
          title: "Connect to #{if name, do: "#{name} (#{about.pattern})", else: about.pattern}",
          host: name || address,
          pattern: about.pattern,
          join: about.pattern,
          requested_at: State.now(),
          deadline: DateTime.add(State.now(), state.settings.hold_seconds, :second),
          facts: facts,
          host_entry: Map.get(about, :host_entry)
        }

        {:noreply, Approvals.hold(state, approval, {from, :connection})}
    end
  end

  # What a lockable resource is called, or nil when there is none.
  defp resource_name(_state, :machine), do: "Host commands"
  defp resource_name(_state, :mwt), do: "MWT's tools"

  defp resource_name(state, {:credential, id}) do
    case Enum.find(Map.get(state, :credentials, []), &(&1.id == id)) do
      %Credential{name: name} -> "The credential #{name}"
      nil -> nil
    end
  end

  defp resource_name(state, {:network, id}) do
    case Enum.find(Map.get(state, :networks, []), &(&1.id == id)) do
      %MWTClient.Sandbox.Network{name: name} -> "The network #{name}"
      nil -> nil
    end
  end

  defp resource_name(_state, _other), do: nil

  # A network grant over a network you already have (`attrs["network"]`):
  # over all of it, its fields copied, or over the hosts its form lists.
  defp resource_reply({:ok, state, resource}, _before), do: {:reply, {:ok, resource}, state}
  defp resource_reply({:error, reason}, state), do: {:reply, {:error, reason}, state}

  # Why a use waits for you when its grant's host list asked about it.
  defp host_entry_fact(%{host_entry: entry}, grant) when is_binary(entry),
    do: [{"Asks you", "#{entry} is set to Ask on #{grant.name}"}]

  defp host_entry_fact(_about, _grant), do: []

  # A saved command, pinned as you save it: the files it runs, as they are
  # now (`MWTClient.Sandbox.Pins`). A run that finds one changed asks.
  defp pinned(state, %Grant{kind: :command, script: script, dir: dir} = grant)
       when is_binary(script) and is_binary(dir),
       do: %{grant | pins: MWTClient.Sandbox.Pins.of(script, dir, ShareSync.root(state))}

  defp pinned(_state, grant), do: grant

  # An ask about to wait for you, shown to the firewall first: the text of a
  # command the agent wrote, and whether you declined the same before.
  defp screen_command(state, approval) do
    with {:pass, state} <-
           if(approval.script_from == :agent and is_binary(approval.script),
             do: Firewall.observe(state, {:command, approval.script}),
             else: {:pass, state}
           ) do
      Firewall.observe(state, {:ask, ask_key(approval), approval.title})
    end
  end

  # What you declined, for the firewall to know it when asked again.
  defp declined(state, approval, decision)
       when decision in [:decline, :deny, :deny_and_turn_off] and
              approval.kind in [:activation, :command] do
    {_verdict, state} = Firewall.observe(state, {:declined, ask_key(approval)})

    # Declining what an agent proposed removes it, unless you accepted it
    # since: then it is yours. A resource goes with what was proposed over
    # it.
    cond do
      approval.resource &&
          MWTClient.Sandbox.Resource.to_review?(
            approval.resource,
            Map.get(state, :credentials, []),
            Map.get(state, :networks, [])
          ) ->
        MWTClient.Sandbox.Server.Resources.decline(state, approval.resource)

      grant = approval.proposal && Enum.find(state.grants, &(&1.id == approval.grant_id)) ->
        if Grant.to_review?(grant),
          do: Grants.delete(state, grant, "#{grant.name} removed: you declined it"),
          else: state

      true ->
        state
    end
  end

  defp declined(state, _approval, _decision), do: state

  defp ask_key(%Approval{kind: :activation, resource: {_kind, _id} = resource}),
    do: {:resource, resource}

  defp ask_key(%Approval{kind: :activation, grant_id: nil, need: need}),
    do: {:need, squish(String.downcase(need || ""))}

  defp ask_key(%Approval{kind: :activation, grant_id: id}), do: {:grant, id}

  # The script with its spacing collapsed, so re-asking the same command
  # padded with whitespace still counts as asking again.
  defp ask_key(%Approval{kind: :command, grant_id: id, script: script, call: call}),
    do: {:command, id, squish(script || call || "")}

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # Every use of an on grant allowed for `duration`.
  defp allow_all(state, grant, duration) do
    state =
      state
      |> Grants.allow(grant, :all, duration)
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: every use allowed #{State.duration_words(duration)}",
        grant_id: grant.id
      })

    {:reply, {:ok, Enum.find(state.grants, &(&1.id == grant.id))}, state}
  end
end
