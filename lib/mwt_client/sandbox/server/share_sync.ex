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

  Runs in the server's process; the sync itself runs in a task.
  """

  alias MWTClient.Sandbox.{FolderSync, Projects, Share}
  alias MWTClient.Sandbox.Server.State

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
    shares = Enum.map(state.settings.shares, & &1.path)

    paths =
      case state.sync_due do
        :all -> shares
        due -> Enum.filter(shares, &MapSet.member?(due, &1))
      end

    case Projects.guest(state.username, state.vm) do
      {:ok, guest} ->
        records =
          Map.new(paths, fn path ->
            case Map.get(state.sync, path) do
              %{vm: vm} = record when vm == vm_record.id -> {path, record}
              _none_or_another_vm -> {path, FolderSync.new(path, vm_record.id)}
            end
          end)

        server = self()
        dir = state.dir
        started_at = state.vm.started_at
        opts = [max_bytes: max_bytes(state.settings), progress: progress(server, vm_record.id)]

        settle = MapSet.intersection(state.sync_settle, MapSet.new(paths))

        state =
          %{
            state
            | sync_due: nil,
              sync_waiters: [],
              sync_settle: MapSet.difference(state.sync_settle, settle),
              sync_running: %{paths: paths, waiters: state.sync_waiters, settle: settle}
          }
          |> State.change(:sync_progress, fn _ -> Map.new(paths, &{&1, :waiting}) end)

        State.task(state, :sync, fn ->
          FolderSync.sync_all(records, shares, guest, dir, opts)
          |> Map.merge(%{vm: vm_record.id, started_at: started_at})
        end)

      {:error, _not_running} ->
        answer(state, state.sync_waiters, {:error, "The VM isn't running."})
        %{state | sync_waiters: []}
    end
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
  def finished(state, %{vm: vm, started_at: started_at, records: records}) do
    waiters = running_waiters(state)

    state =
      if match?(%{id: ^vm, copied: true}, State.vm_record(state)) and
           state.vm.status == :running and state.vm.started_at == started_at do
        shared = MapSet.new(state.settings.shares, & &1.path)
        records = Map.filter(records, fn {path, _} -> MapSet.member?(shared, path) end)
        statuses = Map.new(records, fn {path, record} -> {path, record.status} end)
        answer(state, waiters, {:ok, statuses})
        follow_up(state, statuses)

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
end
