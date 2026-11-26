defmodule MWTClient.Sandbox.Server.State do
  @moduledoc """
  The sandbox server's state, and the small things every part of the server
  does to it: change it and tell the pages, log an event, save it sealed,
  set a timer, start a task, write the VM's inbox.

  Nothing here decides anything. `MWTClient.Sandbox.Server` holds the state
  and takes the messages; `Approvals`, `Grants`, `Values`, `HostRuns` and
  `Machine`, next to this module, each do one job on it. All of it runs in
  the server's own process: these are its functions in files of their own,
  not processes.
  """

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.Notifications
  alias MWTClient.SaveTimer
  alias MWTClient.Storage.Documents
  alias MWTClient.Storage.Journal

  alias MWTClient.Sandbox.Server.Running

  alias MWTClient.Sandbox.{
    Allowance,
    Approval,
    Build,
    CertificateAuthority,
    Decision,
    Event,
    EventDetails,
    Grant,
    Handoff,
    HandoffRecords,
    HostInfo,
    Inbox,
    Notices,
    Snapshot
  }

  @flush_after 250
  @document "sandbox"
  @recent_events 30
  # Where the state was kept before library.db.
  @legacy_file "sandbox.bin"
  @tasks MWTClient.Sandbox.TaskSupervisor

  @doc "The PubSub topic of everything that changes."
  def topic(username), do: "sandbox:" <> Accounts.id(username)

  @doc "The PubSub topic of the waiting count, which every page's title bar shows."
  def waiting_topic(username), do: "sandbox-waiting:" <> Accounts.id(username)

  @doc """
  A value taken out of the function it travelled in (`MWTClient.Sandbox.Server.call/3`); anything else as it is.
  """
  def opened(sealed) when is_function(sealed, 0), do: sealed.()

  def opened(plain), do: plain

  @doc """
  Tests run without touching microsandbox.
  """
  def external?,
    do:
      Keyword.get(Application.get_env(:mwt_client, MWTClient.Sandbox.Server, []), :external, true)

  @doc """
  The grant an approval is about, or nil.
  """
  def grant_of(state, %Approval{grant_id: id}), do: Enum.find(state.grants, &(&1.id == id))

  @doc """
  `value` when it is text, else the empty string: what the VM sends isn't trusted to be text.
  """
  def to_text(value) when is_binary(value), do: value

  def to_text(_other), do: ""

  @doc """
  What `mwt host` prints: this machine's description, your notes included.
  """
  def host_text(state),
    do:
      HostInfo.text(
        state.host.facts,
        state.host.tools,
        state.settings.shares,
        state.settings.host_notes,
        MWTClient.Sandbox.Server.Forwarding.address(state),
        MWTClient.Sandbox.Server.ShareSync.root(state)
      )

  @doc """
  Writes the host's description into the VM's inbox.
  """
  def write_host(state) do
    Inbox.write_host(inbox_dir(state), host_text(state))
    inbox_changed(state)
  rescue
    error ->
      Logger.error("could not write host.md: #{Exception.message(error)}", system: :sandbox)
      state
  end

  @doc """
  Starts looking at which tools this machine has, in a task.
  """
  def probe_host(state) do
    state
    |> change(:host, &%{&1.host | probing?: true})
    |> task(:probe_host, &HostInfo.probe_tools/0)
  end

  @doc """
  The sandbox's CA certificate, as PEM.
  """
  def ca_pem(state), do: CertificateAuthority.pem(state.ca.cert)

  @doc """
  Puts `grant` in the place of the one with its id, and tells the pages.
  """
  def replace_grant(state, grant) do
    change(
      state,
      :grants,
      &Enum.map(&1.grants, fn g -> if g.id == grant.id, do: grant, else: g end)
    )
  end

  @doc """
  Puts `approval` in the place of the one with its id, and tells the pages.
  """
  def replace_approval(state, approval) do
    change(
      state,
      :approvals,
      &Enum.map(&1.approvals, fn a -> if a.id == approval.id, do: approval, else: a end)
    )
  end

  @doc """
  Counts one more use of a grant, now.
  """
  def used(state, grant_id) do
    case Enum.find(state.grants, &(&1.id == grant_id)) do
      nil ->
        state

      grant ->
        state |> replace_grant(%{grant | uses: grant.uses + 1, last_used_at: now()}) |> changed()
    end
  end

  @doc """
  Applies `fun` to the state under `area` and tells the pages.
  """
  def change(state, area, fun) do
    before = waiting_count(state)
    state = Map.put(state, area, fun.(state))
    broadcast(state, {:sandbox_changed, area})
    # A forwarder runs exactly while the VM does.
    state = if area == :vm, do: MWTClient.Sandbox.Server.Forwarding.sync(state), else: state
    # Notifications follow the approvals and the handoffs.
    state =
      case area do
        :approvals -> sync_notices(state)
        :waiting_handoffs -> sync_handoff_notices(state)
        _other -> state
      end

    after_count = waiting_count(state)

    if before != after_count do
      Phoenix.PubSub.broadcast(
        MWTClient.PubSub,
        waiting_topic(state.username),
        {:sandbox_waiting, after_count}
      )
    end

    state
  end

  # One notification per waiting approval and stage: made when it starts
  # waiting, withdrawn when it stops. Your notification settings decide
  # whether it reaches the desktop.
  defp sync_notices(state) do
    wanted = for %Approval{status: :waiting} = a <- state.approvals, into: %{}, do: {a.id, a}

    for {id, approval} <- wanted, Map.get(state.notified, id) != approval.stage do
      Notifications.notify(
        state.username,
        {:sandbox_approval, id},
        Notices.approval(approval, grant_of(state, approval))
      )
    end

    for id <- Map.keys(state.notified),
        not is_map_key(wanted, id),
        do: Notifications.withdraw(state.username, {:sandbox_approval, id})

    %{state | notified: Map.new(wanted, fn {id, approval} -> {id, approval.stage} end)}
  end

  @doc """
  One notification per open handoff: made when it opens, made again when
  the agent updates it, withdrawn once you accept or close it.
  With `quiet: true`, as when MWT starts, what is open is listed in MWT but
  not put on the desktop again.
  """
  def sync_handoff_notices(state, opts \\ []) do
    wanted = for %Handoff{status: :open} = h <- state.waiting_handoffs, into: %{}, do: {h.id, h}

    for {id, handoff} <- wanted,
        Map.get(notified_handoffs(state), id) != Notices.handed_off(handoff) do
      Notifications.notify(
        state.username,
        {:sandbox_handoff, id},
        Notices.handoff(handoff),
        opts
      )
    end

    for id <- Map.keys(notified_handoffs(state)),
        not is_map_key(wanted, id),
        do: Notifications.withdraw(state.username, {:sandbox_handoff, id})

    Map.put(
      state,
      :notified_handoffs,
      Map.new(wanted, fn {id, handoff} -> {id, Notices.handed_off(handoff)} end)
    )
  end

  @doc """
  Adds an event to the activity log, kept in the identity's journal
  (`MWTClient.Storage.Journal`), and tells the pages. The last
  #{@recent_events} stay in memory too (`recent_events/1`).

  Its details are what the caller gives (`MWTClient.Sandbox.EventDetails`),
  then, for an event that names a grant, the grant as it is now
  (`MWTClient.Sandbox.Grant.details/1`): what it opened, its state and
  allowances when it happened, whatever it becomes after. A caller logs
  after making its change, so a grant's event shows the grant changed.
  """
  def log(state, attrs) do
    # Who or what decided it (`MWTClient.Sandbox.Decision`): said where it
    # was logged, or, for a refusal or a card that timed out, by its
    # outcome. The card and the grant's version go beside the line.
    {decision, attrs} = Map.pop(attrs, :decision)

    {decision, state} =
      case decision || inferred(state, attrs) do
        nil -> {nil, state}
        decision -> keep_decided(state, decision)
      end

    # The grant is the audit's to say, by a link (`MWTClient.Sandbox.Decision`).
    details = Map.get(attrs, :details) || []

    event =
      Event
      |> struct!(Map.merge(%{id: Event.new_id(), at: now(), decision: decision}, attrs))
      |> then(&%{&1 | details: EventDetails.new(details)})
      |> then(&%{&1 | detailed?: Event.details(&1) != nil})
      |> then(&%{&1 | running: Running.since(state, &1.exchange_id)})

    Journal.record(state.username, Event.row(event))

    if event.detailed?,
      do: Journal.record_details(state.username, event.id, event.details)

    broadcast(state, {:sandbox_event, event})
    Map.put(state, :recent_events, Enum.take([event | recent_events(state)], @recent_events))
  end

  # What decided an action its line didn't say: a refusal or a timeout by
  # its outcome; a lookup, a connection or a request read let through, by
  # the grant it went under, on.
  defp inferred(state, attrs) do
    with nil <- Decision.inferred(attrs[:outcome], attrs[:summary] || ""),
         outcome when outcome in [:read, :tunnel, :lookup, :tool] <- attrs[:outcome],
         id when is_binary(id) <- attrs[:grant_id],
         %Grant{} = grant <- Enum.find(state.grants, &(&1.id == id)) do
      Decision.grant(grant)
    else
      %{} = decision -> decision
      _none -> nil
    end
  end

  @doc """
  The decision the last line about card `id` was logged with, or nil:
  for a line that follows it, such as the request its allowing lets go.
  """
  def card_decision(state, id), do: state |> Map.get(:card_decisions, %{}) |> Map.get(id)

  # The card a decision names, kept in the journal; and what decided each
  # card's line, for the lines that follow it, a few hundred at most, the
  # oldest let go.
  defp keep_decided(state, decision) do
    {decision, card} = Decision.kept(decision)
    if card, do: Journal.record_card(state.username, card.card.id, card)

    state =
      case decision[:settled] || decision[:card] do
        nil ->
          state

        id ->
          decisions = Map.get(state, :card_decisions, %{})
          decisions = if map_size(decisions) >= 500, do: %{}, else: decisions
          Map.put(state, :card_decisions, Map.put(decisions, id, decision))
      end

    {decision, state}
  end

  @doc """
  The last events logged, newest first, from memory: for what can't wait
  on the journal, as the firewall isolating the VM.
  """
  def recent_events(state), do: Map.get(state, :recent_events, [])

  @doc """
  Sends `message` to this identity's pages.
  """
  def broadcast(state, message),
    do: Phoenix.PubSub.broadcast(MWTClient.PubSub, topic(state.username), message)

  # The same for the handoffs notified so far.
  defp notified_handoffs(state), do: Map.get(state, :notified_handoffs, %{})

  @doc """
  How many approvals wait for you.
  """
  def waiting_count(state), do: Enum.count(state.approvals, &(&1.status == :waiting))

  @doc """
  Runs `fun` in a task whose result comes back to the server as a message, remembered under `purpose`.
  """
  def task(state, purpose, fun) do
    %Task{ref: ref, pid: pid} = Task.Supervisor.async_nolink(@tasks, fun)

    # Which process runs each, so that locking MWT can end a VM action under
    # way (`Machine.shut_down/1`). Those of tasks already ended go here.
    pids =
      state
      |> Map.get(:task_pids, %{})
      |> Map.take(Map.keys(state.tasks))
      |> Map.put(ref, pid)

    %{state | tasks: Map.put(state.tasks, ref, purpose)} |> Map.put(:task_pids, pids)
  end

  @doc "The process running the task `ref` started by `task/3`, or nil."
  def task_pid(state, ref), do: state |> Map.get(:task_pids, %{}) |> Map.get(ref)

  @doc """
  The folder the VM has a copy of at `/mnt/mwt`.
  """
  def inbox_dir(state), do: Path.join(state.dir, "inbox")

  # The VM's copy follows (`MWTClient.Sandbox.Server.Copying`): due from
  # now, so an agent told of this change waits for it.
  defp inbox_changed(state) do
    send(self(), :sync_inbox)
    Map.put(state, :inbox_due, true)
  end

  @doc """
  Writes the VM's inbox again from the grants as they are: placeholders, files, instructions, the host's description.
  """
  def write_inbox(state) do
    Inbox.write(inbox_dir(state), state.grants, ca_pem(state),
      locked: locked_credentials(state),
      way_of_working: state.settings.way_of_working,
      workspace: MWTClient.Sandbox.Server.ShareSync.root(state)
    )

    write_host(state)
  rescue
    error ->
      Logger.error("could not write the sandbox inbox: #{Exception.message(error)}",
        system: :sandbox
      )

      state
  end

  @doc """
  The ids of the credentials locked now: by you, or all of them while the
  VM is isolated.
  """
  def locked_credentials(state) do
    isolated? = match?(%{isolated: %{}}, Map.get(state, :firewall))

    for %{id: id} <- Map.get(state, :credentials, []),
        isolated? or Map.has_key?(Map.get(state, :locks, %{}), {:credential, id}),
        into: MapSet.new(),
        do: id
  end

  @doc """
  A timer for the grant's own end and one for each timed allowance. When
  one fires, `sweep/1` reads the clock.
  """
  def schedule_expiry(%Grant{} = grant) do
    if grant.state == :on and grant.expires_at,
      do: timer({:expire_grant, grant.id, grant.expires_at}, grant.expires_at)

    for %Allowance{until: %DateTime{} = until, id: id} <- grant.allowances,
        do: timer({:expire_allowance, grant.id, id}, until)

    :ok
  end

  @doc """
  Sends `message` to the server at `at`.
  """
  def timer(message, %DateTime{} = at) do
    Process.send_after(self(), message, max(DateTime.diff(at, now(), :millisecond), 0))
  end

  @doc """
  Marks the state for saving: it is written a moment later, once for every change in between.
  """
  def changed(state), do: %{state | flush: SaveTimer.ensure(state.flush, @flush_after)}

  @doc """
  Writes the state now, and drops the write that was to follow. For what
  must not wait, like a handoff accepted onto your branch: its files are
  there already, and its record must say so even if MWT stops right after.
  """
  def saved(state) do
    if state.flush, do: Process.cancel_timer(state.flush)
    :ok = persist(state)
    %{state | flush: nil}
  end

  @doc """
  Marks the state for saving again when its `:flush` was lost
  (`MWTClient.SaveTimer`), so what changed last gets written anyway.
  """
  def resave(state), do: if(SaveTimer.lost?(state.flush), do: changed(state), else: state)

  @doc """
  Writes what outlives a lock, as the `sandbox` document of the identity's
  encrypted `library.db` (`MWTClient.Storage.Documents`).
  """
  def persist(state) do
    saved = %{
      version: 1,
      grants: state.grants,
      credentials: Map.get(state, :credentials, []),
      networks: Map.get(state, :networks, []),
      locks: Map.get(state, :locks, %{}),
      values: state.values,
      settings: state.settings,
      ca: state.ca,
      created_spec: state.created_spec,
      created_ref: state.created_ref,
      vm_record: vm_record(state),
      builds: state.builds,
      current: state.image.tag,
      snapshots: state.snapshots,
      projects: state.projects,
      handoff_seq: state.handoff_seq,
      memory: state.memory,
      firewall: Map.get(state, :firewall),
      reading: Map.get(state, :reading),
      checks: Map.get(state, :checks, %{})
    }

    case Documents.put(state.username, @document, saved) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.error("could not write the sandbox: #{Exception.message(error)}",
          user: state.username,
          system: :sandbox
        )

        :ok
    end
  end

  @doc """
  Reads what `persist/1` wrote, brought up to date when an older MWT wrote
  it; the first time, from `sandbox.bin`, where an MWT before `library.db`
  kept it, sealed with the password's `key`. What can't be read is set
  aside, and the sandbox starts empty.
  """
  def restore(username, key) do
    case Documents.load(username, @document, @legacy_file, key, :sandbox) do
      {:ok, %{version: 1} = saved} ->
        saved
        |> drop_checks()
        |> Map.update!(:grants, &Grant.upgrade_all/1)
        |> drop_file_grants()
        |> Map.update(:builds, [], fn builds ->
          Enum.map(builds, &struct(Build, Map.from_struct(&1)))
        end)
        |> Map.update(:snapshots, [], fn snaps ->
          Enum.map(snaps, &struct(Snapshot, Map.from_struct(&1)))
        end)

      {:ok, unreadable} ->
        aside = "#{@document}.#{System.system_time(:second)}.unreadable"

        Logger.warning("the sandbox's saved state could not be read; kept as #{aside}",
          user: username,
          system: :sandbox
        )

        :ok = Documents.put(username, aside, unreadable)
        :ok = Documents.delete(username, @document)
        %{}

      :none ->
        %{}
    end
  end

  @doc """
  What the state holds in memory only, as it starts: nothing of it is saved.
  """
  def memory do
    %{
      # project name => what its last update did
      mirror: %{},
      # shared folder => what MWT knows of its copy in the VM
      # (`MWTClient.Sandbox.FolderSync`), and the syncs asked for
      # (`MWTClient.Sandbox.Server.ShareSync`): which shares are due (nil,
      # :all or a set of paths), who waits for the next sync, the one under
      # way and how it is getting on, by path.
      sync: %{},
      sync_due: nil,
      sync_waiters: [],
      sync_running: nil,
      sync_progress: %{},
      # Shares whose next sync is the follow-up for files that weren't
      # settled: it asks for no other.
      sync_settle: MapSet.new(),
      # The workspace (`MWTClient.Sandbox.Workspace`): `{:ok, root}`,
      # `:none` before it is made, or `{:error, reason}`; the last copy
      # back of its `from-vm/` (`MWTClient.Sandbox.CopyBack`); and the
      # files of its `to-vm/` you let go though they were held back, as
      # {path, {size, mtime}}.
      workspace: :none,
      copy_back: nil,
      workspace_released: MapSet.new(),
      # The VM's copy of /mnt/mwt (`MWTClient.Sandbox.Server.Copying`): what
      # MWT knows of it, whether a change is still to be copied, and who
      # waits for that.
      inbox_sync: nil,
      inbox_due: false,
      inbox_waiters: [],
      # VM actions waiting for file-copy tasks to end before starting or
      # replacing the VM. Each keeps the busy label to restore afterward.
      copy_waiters: [],
      approvals: [],
      # approval id => the stage its notification was made for
      notified: %{},
      # handoff id => how many times it had been handed off when notified
      notified_handoffs: %{},
      waiters: %{},
      minted: %{},
      # The ID tokens mints printed beside their values, by the same key,
      # kept as long (`MWTClient.Sandbox.Server.Values.minted/2`).
      id_tokens: %{},
      minting: %{},
      # Values made from the grants' (`MWTClient.Sandbox.Made`), by
      # placeholder: in memory only, as minted values are.
      made: %{},
      tasks: %{},
      # ref => the process running it (`task/3`).
      task_pids: %{},
      running: %{},
      # The requests MWT read that are still running, and their calls'
      # monitors (`MWTClient.Sandbox.Server.Running`).
      requests_running: %{},
      request_monitors: %{},
      # What agents in the VM added with MWT's tools in the last hour, as
      # {monotonic ms, bytes} (`MWTClient.Sandbox.Server.Tools`).
      tool_creates: [],
      # The VM's ports on this machine (`MWTClient.Sandbox.Server.Forwarding`).
      forwarder: nil,
      ports: MWTClient.Sandbox.Server.Forwarding.initial(),
      # The firewall's windows (`MWTClient.Sandbox.Firewall.watch/0`), and
      # how much it refused since it isolated the VM.
      firewall_watch: MWTClient.Sandbox.Firewall.watch(),
      firewall_refused: 0,
      # What was last handed to `UnlockState`, when, and the timer of a
      # change of the windows still to hand (`MWTClient.Sandbox.Server.Kept`).
      kept: nil,
      kept_at: nil,
      kept_due: nil,
      # The last events logged, newest first, kept for the record an
      # isolation makes at once, with no wait on the journal.
      recent_events: [],
      # The console's runs, newest first, in memory only
      # (`MWTClient.Sandbox.ConsoleHistory`).
      console_runs: [],
      # The ids of the grants live after the last message: one that leaves
      # closes what it let through (`MWTClient.Sandbox.Server.Grants.close_ended/1`).
      live: MapSet.new(),
      # What the network path's view was last published from
      # (`MWTClient.Sandbox.Gate.publish/1`), and its version.
      gate: nil,
      gate_version: 0
    }
  end

  # The modules whose structs the state holds, and this one, which says what
  # else it holds.
  @shapes [
    Allowance,
    Approval,
    Build,
    MWTClient.Sandbox.Firewall,
    Grant,
    Handoff,
    MWTClient.Sandbox.Project,
    MWTClient.Sandbox.Settings,
    Snapshot,
    __MODULE__
  ]

  @doc "Which code the state is shaped for: it changes when any of its modules is compiled again."
  def code, do: :erlang.phash2(Enum.map(@shapes, & &1.module_info(:md5)))

  @doc """
  The state, brought up to date with the code running now, before the
  server handles each message. In development MWT's modules are compiled
  again while the server runs: a struct the state holds may have gained a
  field since (a grant its `minutes`, an approval what the agent suggested),
  and the built-in grant its name. Without this, the first use of a new
  field crashes the server, and what was decided since the last save is
  lost. It does what `restore/2` and `MWTClient.Sandbox.Server.init/1` do
  for a saved state, once per change of code.
  """
  def current(state) do
    code = code()

    if Map.get(state, :code) == code,
      do: state,
      else: state |> upgrade() |> Map.put(:code, code)
  end

  defp upgrade(state) do
    state =
      memory()
      |> Map.merge(state)
      |> moved_handoffs()
      |> Map.put(:firewall, MWTClient.Sandbox.Firewall.upgrade(Map.get(state, :firewall)))
      |> Map.put(:reading, MWTClient.Sandbox.Reading.upgrade(Map.get(state, :reading)))

    restruct = fn module -> &struct(module, Map.delete(&1, :__struct__)) end

    credentials =
      Enum.map(Map.get(state, :credentials, []), &MWTClient.Sandbox.Credential.upgrade/1)

    {grants, networks} =
      state.grants
      |> Enum.map(&Grant.upgrade/1)
      |> Enum.reject(&(&1.kind == :file))
      |> MWTClient.Sandbox.Server.Grants.with_built_in()
      |> MWTClient.Sandbox.Network.migrate(
        Enum.map(Map.get(state, :networks, []), &MWTClient.Sandbox.Network.upgrade/1)
      )

    {grants, credentials} = MWTClient.Sandbox.Credential.migrate(grants, credentials)

    state =
      state
      |> Map.put(:credentials, credentials)
      |> Map.put(:networks, networks)
      |> Map.put(:locks, MWTClient.Sandbox.Server.Locks.upgrade(Map.get(state, :locks)))

    %{
      state
      | grants: grants,
        approvals: Enum.map(state.approvals, restruct.(Approval)),
        settings:
          state.settings
          |> restruct.(MWTClient.Sandbox.Settings).()
          |> Map.update!(:shares, fn shares ->
            Enum.map(shares, &MWTClient.Sandbox.Share.upgrade/1)
          end),
        builds: Enum.map(state.builds, restruct.(Build)),
        snapshots: Enum.map(state.snapshots, restruct.(Snapshot)),
        waiting_handoffs: Enum.map(state.waiting_handoffs, &Handoff.upgrade/1),
        projects: Enum.map(state.projects, &MWTClient.Sandbox.Project.upgrade/1)
    }
    |> Map.delete(:yolo)
  end

  # A server running since before handoffs had rows of their own
  # (`MWTClient.Sandbox.HandoffRecords`) holds them all: they move there,
  # and it keeps those waiting for you. Its library opened before the code
  # that makes their table was loaded, so the table is made first.
  defp moved_handoffs(%{handoffs: handoffs, username: username} = state) do
    :ok = MWTClient.Storage.Database.migrate(username, :library)
    :ok = HandoffRecords.import(username, Enum.map(handoffs, &Handoff.upgrade/1))

    state
    |> Map.delete(:handoffs)
    |> Map.put(:waiting_handoffs, HandoffRecords.waiting(username))
  end

  defp moved_handoffs(state), do: state

  # File grants are gone (2026-11-18): each handed the VM a real value no
  # switch could take back. One saved before is dropped with its value;
  # `dropped_files` names them, for the server to log once it starts.
  # Checks (*Only while…*) are gone: a grant saved with some keeps none, and
  # MWT names them once (`dropped_checks`), so you can see what no longer
  # runs.
  defp drop_checks(saved) do
    dropped =
      for grant <- saved.grants,
          checks = Map.get(grant, :checks) || [],
          checks != [],
          do: {grant.name, Enum.map(checks, &Map.get(&1, :name, "a check"))}

    saved
    |> Map.update!(:grants, fn grants -> Enum.map(grants, &Map.delete(&1, :checks)) end)
    |> Map.update(:dropped_checks, dropped, &(&1 ++ dropped))
  end

  defp drop_file_grants(saved) do
    {files, grants} = Enum.split_with(saved.grants, &(&1.kind == :file))
    ids = Enum.map(files, & &1.id)

    saved
    |> Map.put(:grants, grants)
    |> Map.update(:values, %{}, &Map.drop(&1 || %{}, ids))
    |> Map.put(:dropped_files, Enum.map(files, & &1.name))
  end

  @doc """
  A length of time as the log says it: `for 30 min`, `until turned off`.
  """
  def duration_words(:until_off), do: "until turned off"

  def duration_words(:grant), do: "while the grant is on"

  def duration_words(60), do: "for 1 h"

  def duration_words(minutes) when rem(minutes, 60) == 0, do: "for #{div(minutes, 60)} h"

  def duration_words(minutes), do: "for #{minutes} min"

  @doc """
  Which VM MWT runs (`MWTClient.Sandbox.VM`'s `record`), or nil. A sandbox
  process started by code from before records has none in its state until
  it restarts, so it is read with a default.
  """
  def vm_record(state), do: Map.get(state, :vm_record)

  @doc """
  What `MWTClient.Sandbox.Policy` decides from, as the state is now: the
  grants, the values made from them and the locks.
  """
  def policy(state) do
    made = state |> Map.get(:made, %{}) |> Map.values()

    MWTClient.Sandbox.Policy.snapshot(
      state.grants,
      made,
      Map.get(state, :locks, %{}),
      Map.new(Map.get(state, :networks, []), &{&1.id, &1.limits})
    )
  end

  @doc """
  A short id not used before in this run.
  """
  def unique, do: Integer.to_string(System.unique_integer([:positive]), 36) |> String.downcase()

  @doc """
  The time, to the second.
  """
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
