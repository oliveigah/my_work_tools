defmodule MWTClient.Sandbox.Server.ShareSync do
  @moduledoc """
  Syncing your shared folders' copies in the VM
  (`MWTClient.Sandbox.FolderSync`), in the sandbox server's state: only
  when asked, never on a timer.

  A sync is asked for (`request/3`):

    * for every share, when the VM starts (`MWTClient.Sandbox.Server.Machine`);
    * for a share just added, and with none when one is removed, so its copy
      goes (each sync first makes the VM show exactly the shares there are,
      `MWTClient.Sandbox.ShareMounts.arrange/2`);
    * from a share's Sync button, or Sync all;
    * by an agent's `mwt sync`, which waits for it;
    * for the share a command you approved ran in, once it ends, so what it
      left there reaches the VM;
    * once more, a few seconds after a sync that found files still being
      written there (`settle/2`): they may have gone half written. That
      follow-up asks for no other, so a file that never stops changing, a
      log, doesn't keep a sync going.

  One sync runs at a time. What is asked meanwhile is gathered and runs
  next, whole: a sync already under way may have looked at a folder before
  the change it was asked for. Whoever waits is answered when the sync that
  started after their ask ends.

  The workspace (`MWTClient.Sandbox.Workspace`) syncs with them, both
  halves each time, under the same asks: its `to-vm/` as one more shared
  folder, whose files are looked through as a command's output is
  (`MWTClient.Sandbox.Inbound`) and held back when they hold a credential;
  and its `from-vm/` copied back onto this machine
  (`MWTClient.Sandbox.CopyBack`), only while the grant *Workspace: write
  to your machine* is on and the VM isn't isolated. Each sync makes the
  workspace when it isn't there yet. A copy back that found a grant's real
  value tells the firewall.

  Runs in the server's process; the sync itself runs in a task.
  """

  alias MWTClient.Sandbox.{CopyBack, FolderSync, Grant, Inbound, Projects, Share, Workspace}
  alias MWTClient.Sandbox.Server.{Firewall, State, Values}

  # Tried again this often while the VM is busy with something else.
  @retry_ms 1_000
  # A follow-up for files still being written, this long after.
  @settle_ms 3_000
  @gib 1024 * 1024 * 1024

  @typedoc "Which shares: every one, or these paths."
  @type which :: :all | [Path.t()]

  @doc """
  Asks for a sync of `which`, answering `waiter`, a caller held by
  `GenServer.reply/2`, when it ends: `{:ok, statuses}` by path, or
  `{:error, text}`.
  """
  @spec request(map(), which(), GenServer.from() | nil) :: map()
  def request(state, which, waiter \\ nil) do
    due =
      case {state.sync_due, which} do
        {:all, _} -> :all
        {_, :all} -> :all
        {nil, paths} -> MapSet.new(paths)
        {due, paths} -> MapSet.union(due, MapSet.new(paths))
      end

    waiters = if waiter, do: [{waiter, which} | state.sync_waiters], else: state.sync_waiters

    %{state | sync_due: due, sync_waiters: waiters}
    |> State.change(:sync_due, & &1.sync_due)
    |> start()
  end

  @doc """
  Starts the sync that is due, unless one runs or the VM can't take it now.
  """
  @spec start(map()) :: map()
  def start(%{sync_due: nil} = state), do: state

  def start(state) do
    vm_record = State.vm_record(state)

    cond do
      running?(state) ->
        state

      state.vm.status != :running or is_nil(vm_record) ->
        # A stopped VM has no copy: the next start syncs every share.
        answer(state, state.sync_waiters, {:error, "The VM isn't running."})
        %{state | sync_waiters: []}

      state.vm.busy != nil ->
        Process.send_after(self(), :sync, @retry_ms)
        state

      not match?(%{copied: true}, vm_record) ->
        older_vm(state, vm_record)

      true ->
        run(state, vm_record)
    end
  end

  defp running?(state), do: :sync in Map.values(state.tasks)

  # An older VM still mounts the host's folders where the copies would go.
  defp older_vm(state, vm_record) do
    message =
      "Recreate the VM to copy shared folders. This VM still mounts folders from your machine."

    records =
      Map.new(state.settings.shares, fn %Share{path: path} ->
        record = FolderSync.new(path, vm_record.id)
        {path, put_in(record.status.error, message)}
      end)

    answer(state, state.sync_waiters, {:error, message})

    %{state | sync_due: nil, sync_waiters: []}
    |> State.change(:sync, fn _ -> records end)
  end

  defp run(state, vm_record) do
    state = put_workspace(state, Workspace.ensure(state.username))
    root = root(state)
    shares = shared(state)
    from_vm = root && Workspace.from_vm(root)

    paths =
      case state.sync_due do
        :all -> shares
        due -> Enum.filter(shares, &MapSet.member?(due, &1))
      end

    copy_back = copy_back(state, from_vm)

    case Projects.guest(state.username, state.vm) do
      {:ok, guest} ->
        records =
          Map.new(paths, fn path ->
            case Map.get(state.sync, path) do
              %{vm: vm} = record when vm == vm_record.id -> {path, record}
              _none_or_another_vm -> {path, FolderSync.new(path, vm_record.id)}
            end
          end)

        copy_record =
          case state.copy_back do
            %{vm: vm} = record when vm == vm_record.id -> record
            _none_or_another_vm -> CopyBack.new(vm_record.id)
          end

        server = self()
        dir = state.dir
        started_at = state.vm.started_at
        secrets = Values.secrets(state)
        progress = progress(server, vm_record.id)

        opts = [
          max_bytes: max_bytes(state.settings),
          progress: progress,
          hold: hold(state, root, server, secrets)
        ]

        settle = MapSet.intersection(state.sync_settle, MapSet.new(paths))
        shown = if copy_back, do: [from_vm | paths], else: paths

        state =
          %{
            state
            | sync_due: nil,
              sync_waiters: [],
              sync_settle: MapSet.difference(state.sync_settle, settle),
              sync_running: %{paths: paths, waiters: state.sync_waiters, settle: settle}
          }
          |> State.change(:sync_progress, fn _ -> Map.new(shown, &{&1, :waiting}) end)

        State.task(state, :sync, fn ->
          # The workspace is shown before the shares: your half is shown
          # over its frame.
          arranged = if root, do: Workspace.arrange(guest, root), else: :ok
          result = FolderSync.sync_all(records, shares, guest, dir, opts)

          copied =
            case {copy_back, arranged} do
              {nil, _arranged} ->
                nil

              {{:skip, why}, _arranged} ->
                {put_in(copy_record.status.error, why), nil}

              {:run, {:error, message}} ->
                {put_in(copy_record.status.error, message), nil}

              {:run, :ok} ->
                CopyBack.run(copy_record, guest, root,
                  dir: dir,
                  secrets: secrets,
                  progress: &progress.(from_vm, &1)
                )
            end

          Map.merge(result, %{vm: vm_record.id, started_at: started_at, copy_back: copied})
        end)

      {:error, _not_running} ->
        answer(state, state.sync_waiters, {:error, "The VM isn't running."})
        %{state | sync_waiters: []}
    end
  end

  @doc """
  The folders a sync copies into the VM: your shared folders, and the
  workspace's `to-vm/` when there is one.
  """
  @spec shared(map()) :: [Path.t()]
  def shared(state) do
    shares = Enum.map(state.settings.shares, & &1.path)

    case root(state) do
      nil -> shares
      root -> shares ++ [Workspace.to_vm(root)]
    end
  end

  @doc """
  What a command's check needs of the workspace
  (`MWTClient.Sandbox.HostCommand.check/4`): its folder, and when its
  `from-vm/` was last copied here.
  """
  @spec command_opts(map()) :: keyword()
  def command_opts(state),
    do: [
      workspace: root(state),
      copied_at: with(%{status: %{synced_at: at}} <- state.copy_back, do: at)
    ]

  @doc "The workspace's folder here, or nil while there is none."
  @spec root(map()) :: Path.t() | nil
  def root(state) do
    case Map.get(state, :workspace) do
      {:ok, root} -> root
      _none_or_error -> nil
    end
  end

  # A workspace made, or gone: the VM's shells and `mwt host` say so.
  defp put_workspace(state, workspace) do
    if Map.get(state, :workspace) == workspace,
      do: state,
      else: state |> State.change(:workspace, fn _ -> workspace end) |> State.write_inbox()
  end

  # Whether this sync copies `from-vm/` back: nil when it isn't asked for,
  # `{:skip, why}` when it may not, `:run` when it does.
  defp copy_back(_state, nil), do: nil

  defp copy_back(state, from_vm) do
    due? =
      case state.sync_due do
        :all -> true
        due -> MapSet.member?(due, from_vm)
      end

    cond do
      not due? ->
        nil

      Firewall.isolated?(state) ->
        {:skip,
         "MWT's firewall isolated this VM: nothing of from-vm comes here until you release it."}

      not workspace_on?(state) ->
        {:skip, "Workspace: write to your machine is off, so nothing of from-vm comes here."}

      true ->
        :run
    end
  end

  defp workspace_on?(state) do
    case workspace_grant(state) do
      %Grant{} = grant -> Grant.on?(grant)
      nil -> false
    end
  end

  defp workspace_grant(state),
    do: Enum.find(state.grants, &(&1.kind == :mwt and &1.tools == :workspace))

  # What holds a file of `to-vm/` back from the VM, looked at in the sync's
  # task: a token grant's real value always; a credential's shape when the
  # firewall's rule *Credential entering the VM* blocks. When it only
  # alerts, the file goes and the server is told. A file you let go
  # (`release/2`) goes as it was then.
  defp hold(_state, nil, _server, _secrets), do: nil

  defp hold(state, root, server, secrets) do
    to_vm = Workspace.to_vm(root)
    placeholders = for %Grant{placeholder: p} <- state.grants, is_binary(p), do: p
    firewall = Firewall.of(state)

    action =
      if firewall.enabled,
        do: MWTClient.Sandbox.Firewall.action(firewall, :credential_inbound),
        else: :off

    released = Map.get(state, :workspace_released, MapSet.new())

    fn
      ^to_vm, path, full ->
        if MapSet.member?(released, {path, stamp(full)}) do
          nil
        else
          case Inbound.check_file(full, secrets, placeholders) do
            {:found, findings} ->
              words = findings |> Enum.map(&Inbound.words/1) |> Enum.join("; ")

              cond do
                Enum.any?(findings, &Inbound.value?/1) or action in [:block, :isolate] ->
                  words

                action == :alert ->
                  send(server, {:workspace_inbound, path, words})
                  nil

                true ->
                  nil
              end

            _clean_or_unreadable ->
              nil
          end
        end

      _other_share, _path, _full ->
        nil
    end
  end

  defp stamp(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {size, mtime}
      {:error, _} -> nil
    end
  end

  @doc """
  Lets the file of the workspace's `to-vm/` at `path` (relative) go to the
  VM, as it is now, though it was held back: you read why, and chose. It
  goes at the sync this asks for, and again only once it changes and is
  looked through again.
  """
  @spec release(map(), String.t()) :: map()
  def release(state, path) do
    case root(state) do
      nil ->
        state

      root ->
        to_vm = Workspace.to_vm(root)
        full = Path.join(to_vm, path)

        if Workspace.within?(full, to_vm) and stamp(full) != nil do
          released = Map.get(state, :workspace_released, MapSet.new())

          state
          |> Map.put(:workspace_released, MapSet.put(released, {path, stamp(full)}))
          |> State.log(%{
            outcome: :command,
            summary: "to-vm/#{path} sent to the VM though it was held: you let it go",
            grant_id: nil
          })
          |> request([to_vm])
        else
          state
        end
    end
  end

  @doc """
  Tells the firewall that a file of `to-vm/` went to the VM holding
  something shaped like a credential, its rule only alerting.
  """
  @spec alert(map(), String.t(), String.t()) :: map()
  def alert(state, path, words) do
    {_verdict, state} = Firewall.observe(state, {:inbound, "to-vm/#{path}", words, :workspace})
    state
  end

  # Half the work disk, where the copies are kept.
  defp max_bytes(settings), do: max(div(settings.work_gib * @gib, 2), @gib)

  defp progress(server, vm),
    do: fn path, phase -> send(server, {:sync_progress, vm, path, phase}) end

  @doc "Notes how a sync under way is getting on with `path`."
  @spec progress(map(), String.t(), Path.t(), FolderSync.phase()) :: map()
  def progress(state, vm, path, phase) do
    if running?(state) and match?(%{id: ^vm}, State.vm_record(state)),
      do: State.change(state, :sync_progress, &Map.put(&1.sync_progress, path, phase)),
      else: state
  end

  @doc """
  Takes a sync's result: the records of the shares still shared, from the
  VM that runs now, and an answer to whoever waited. Then the next sync, if
  one is due.
  """
  @spec finished(map(), map() | {:error, String.t()}) :: map()
  def finished(state, %{vm: vm, started_at: started_at, records: records} = result) do
    waiters = running_waiters(state)

    state =
      if match?(%{id: ^vm, copied: true}, State.vm_record(state)) and
           state.vm.status == :running and state.vm.started_at == started_at do
        shared = MapSet.new(shared(state))
        records = Map.filter(records, fn {path, _} -> MapSet.member?(shared, path) end)
        statuses = Map.new(records, fn {path, record} -> {path, record.status} end)
        state = held(state, records)
        {state, copied} = copied(state, Map.get(result, :copy_back))

        statuses =
          case {copied, root(state)} do
            {%{status: status}, root} when is_binary(root) ->
              Map.put(statuses, Workspace.from_vm(root), status)

            _none ->
              statuses
          end

        answer(state, waiters, {:ok, statuses})
        follow_up(state, Map.take(statuses, Enum.to_list(shared)))

        State.change(state, :sync, fn state ->
          state.sync |> Map.merge(records) |> Map.filter(&MapSet.member?(shared, elem(&1, 0)))
        end)
      else
        # It ended after the VM was stopped or recreated: it belongs to that
        # boot, and the next start syncs every share again.
        answer(state, waiters, {:error, "The VM stopped or was recreated during the sync."})
        state
      end

    state |> done() |> start()
  end

  # A sync started by an older MWT, before a code reload, says nothing of
  # its VM: it is dropped.
  def finished(state, %{records: _records}) do
    answer(state, running_waiters(state), {:error, "The sync was cut short; ask again."})
    state |> done() |> start()
  end

  def finished(state, {:error, message}) do
    answer(state, running_waiters(state), {:error, "The sync failed: " <> message})
    state |> done() |> start()
  end

  # Files of `to-vm/` newly held back: each in the log, and the firewall
  # hears of it. Those let go that are gone or held no more are forgotten.
  defp held(state, records) do
    case root(state) do
      nil ->
        state

      root ->
        to_vm = Workspace.to_vm(root)

        case records do
          %{^to_vm => %{status: %{held: held}}} ->
            before = get_in(state.sync, [to_vm, :status, :held]) || []

            state =
              Enum.reduce(held -- before, state, fn %{path: path, why: why}, state ->
                {_verdict, state} =
                  Firewall.observe(state, {:inbound, "to-vm/#{path}", why, :workspace})

                State.log(state, %{
                  outcome: :blocked,
                  summary: "to-vm/#{path} held back from the VM: it holds #{why}",
                  grant_id: nil
                })
              end)

            paths = MapSet.new(held, & &1.path)
            released = Map.get(state, :workspace_released, MapSet.new())

            Map.put(
              state,
              :workspace_released,
              MapSet.filter(released, fn {path, _stamp} -> not MapSet.member?(paths, path) end)
            )

          _not_synced ->
            state
        end
    end
  end

  # A copy back's record, kept; what it brought in the log, under its
  # grant; a real value told to the firewall.
  defp copied(state, nil), do: {state, nil}

  defp copied(state, {record, finding}) do
    grant = workspace_grant(state)
    grant_id = grant && grant.id
    before = state.copy_back && state.copy_back.status
    status = record.status

    state =
      cond do
        status.error == nil and (status.written > 0 or status.removed > 0) ->
          state
          |> State.log(%{
            outcome: :tool,
            summary:
              "from-vm copied onto your machine: #{status.written} written, #{status.removed} removed; " <>
                "#{status.files} files there",
            grant_id: grant_id
          })
          |> then(&if(grant_id, do: State.used(&1, grant_id), else: &1))

        status.error != nil and (before == nil or before.error != status.error) ->
          State.log(state, %{outcome: :blocked, summary: status.error, grant_id: grant_id})

        true ->
          state
      end

    state =
      case finding do
        {:value, grant_name, path} ->
          {_verdict, state} =
            Firewall.observe(
              state,
              {:value, grant_name, "the workspace's from-vm/#{path}", :workspace}
            )

          state

        nil ->
          state
      end

    {State.change(state, :copy_back, fn _ -> record end), record}
  end

  defp running_waiters(%{sync_running: %{waiters: waiters}}), do: waiters
  defp running_waiters(_state), do: []

  # Shares with files still being written get one sync more, unless this
  # was it.
  defp follow_up(state, statuses) do
    settled = with(%{settle: settle} <- state.sync_running, do: settle) || MapSet.new()

    paths =
      for {path, status} <- statuses,
          status.unsettled > 0,
          not MapSet.member?(settled, path),
          do: path

    if paths != [], do: Process.send_after(self(), {:sync_settle, paths}, @settle_ms)
  end

  @doc """
  The follow-up sync of `paths`, whose files were still being written at
  their last sync (`follow_up/2`).
  """
  @spec settle(map(), [Path.t()]) :: map()
  def settle(state, paths) do
    %{state | sync_settle: MapSet.union(state.sync_settle, MapSet.new(paths))}
    |> request(paths)
  end

  defp done(state) do
    %{state | sync_running: nil}
    |> State.change(:sync_progress, fn _ -> %{} end)
  end

  @doc """
  A VM that just started has no copy MWT knows of: what was known goes,
  and every share is synced.
  """
  @spec reset(map()) :: map()
  def reset(state) do
    send(self(), :sync)

    %{state | sync_due: :all}
    |> State.change(:sync, fn _ -> %{} end)
    |> State.change(:copy_back, fn _ -> nil end)
  end

  # Each waiter gets the statuses of what it asked for.
  defp answer(_state, waiters, {:error, _} = error),
    do: Enum.each(waiters, fn {from, _which} -> GenServer.reply(from, error) end)

  defp answer(_state, waiters, {:ok, statuses}) do
    Enum.each(waiters, fn
      {from, :all} -> GenServer.reply(from, {:ok, statuses})
      {from, paths} -> GenServer.reply(from, {:ok, Map.take(statuses, paths)})
    end)
  end

  @doc """
  What the pages show of each share: its copy as the last sync left it
  (nil before the first), what a sync under way is doing with it (nil when
  none is), and whether one is due for it.
  """
  @spec view(map()) :: %{Path.t() => map()}
  def view(state) do
    Map.new(state.settings.shares, fn %Share{path: path} ->
      due? =
        case state.sync_due do
          :all -> true
          nil -> false
          due -> MapSet.member?(due, path)
        end

      {path,
       %{
         status: with(%{status: status} <- Map.get(state.sync, path), do: status),
         progress: Map.get(state.sync_progress, path),
         due?: due?
       }}
    end)
  end

  @doc """
  What the pages show of the workspace: where it is, or why there is none;
  and each half as `view/1` shows a share, `from_vm`'s status a copy
  back's.
  """
  @spec workspace_view(map()) :: map()
  def workspace_view(state) do
    case Map.get(state, :workspace) do
      {:ok, root} ->
        to_vm = Workspace.to_vm(root)
        from_vm = Workspace.from_vm(root)

        due? = fn path ->
          case state.sync_due do
            :all -> true
            nil -> false
            due -> MapSet.member?(due, path)
          end
        end

        %{
          root: root,
          error: nil,
          on?: workspace_on?(state),
          to_vm: %{
            path: to_vm,
            status: with(%{status: status} <- Map.get(state.sync, to_vm), do: status),
            progress: Map.get(state.sync_progress, to_vm),
            due?: due?.(to_vm)
          },
          from_vm: %{
            path: from_vm,
            status: with(%{status: status} <- state.copy_back, do: status),
            progress: Map.get(state.sync_progress, from_vm),
            due?: due?.(from_vm)
          }
        }

      {:error, reason} ->
        %{root: nil, error: Workspace.explain(reason), on?: workspace_on?(state)}

      _none ->
        %{root: nil, error: nil, on?: workspace_on?(state)}
    end
  end
end
