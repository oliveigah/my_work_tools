defmodule MWTClient.Sandbox.Server.Copying do
  @moduledoc """
  MWT's own files, copied into the running VM at `/mnt/mwt`
  (`MWTClient.Sandbox.Inbox.into_vm/4`), in the sandbox server's state.

  Each start copies them in before anything in the VM reads them
  (`MWTClient.Sandbox.Server.Machine`). After that, every change MWT makes
  to them (`State.write_inbox/1`) sends `:sync_inbox` to the server, which
  copies what changed within moments; the shared folders' look every few
  seconds sends it too, as a backstop. One copy runs at a time: a change
  made meanwhile starts another when it ends.

  An agent told that a grant is on goes on to use it at once, with what
  `/mnt/mwt` holds for it. So the channel holds that answer until the copy
  under way, if any, has ended (`await/2`): never more than a few seconds.

  VM lifecycle tasks also wait here for both kinds of file copy (shared
  folders and `/mnt/mwt`) to end. A stop shuts down the old VM first, then
  drains its copies; a start or recreate cannot launch the next VM until
  they finish. The lifecycle task already marks the VM busy, preventing
  new copies from starting while it waits.

  Runs in the server's process, except `drain/1`, called by a lifecycle task.
  """

  require Logger

  alias MWTClient.Sandbox.Inbox
  alias MWTClient.Sandbox.Server.State

  @doc "Waits in a lifecycle task until the owning server has no file copies left."
  def drain(server), do: GenServer.call(server, :copies_idle, :infinity)

  @doc "Holds a lifecycle task's call while a file copy is still running."
  def await_idle(state, from) do
    if active?(state) do
      state
      |> Map.update!(:copy_waiters, &[{from, state.vm.busy} | &1])
      |> State.change(:vm, &%{&1.vm | busy: "Finishing file copies…"})
    else
      GenServer.reply(from, :ok)
      state
    end
  end

  @doc "Releases lifecycle tasks after the last file copy ended, including a failed copy."
  def release_idle(state) do
    if state.copy_waiters != [] and not active?(state) do
      {_from, busy} = List.last(state.copy_waiters)
      state = State.change(state, :vm, &%{&1.vm | busy: busy})
      Enum.each(state.copy_waiters, fn {from, _busy} -> GenServer.reply(from, :ok) end)
      %{state | copy_waiters: []}
    else
      state
    end
  end

  defp active?(state),
    do: Enum.any?(state.tasks, fn {_ref, task} -> task in [:sync, :sync_inbox] end)

  @doc """
  Starts a copy of what changed, unless one is under way: `inbox_due` then
  starts another when it ends.
  """
  def start(state) do
    vm_record = State.vm_record(state)

    cond do
      # A start copies everything itself; a stopped VM has no copy left,
      # so what MWT knew of it goes too. Other work on a running VM (copying
      # your memory in) doesn't hold it up.
      state.vm.status != :running or is_nil(vm_record) or
          Enum.any?(Map.values(state.tasks), &match?({:vm, _}, &1)) ->
        answer_waiters(%{state | inbox_due: false, inbox_sync: nil})

      :sync_inbox in Map.values(state.tasks) ->
        state

      true ->
        record =
          case state.inbox_sync do
            %{vm: vm} = record when vm == vm_record.id -> record
            _none_or_another_vm -> Inbox.record(State.inbox_dir(state), vm_record.id)
          end

        username = state.username
        name = state.vm.name
        dir = state.dir

        %{state | inbox_due: false}
        |> State.task(:sync_inbox, fn -> Inbox.into_vm(record, username, name, dir) end)
    end
  end

  @doc "Takes a copy's result; starts the next one when a change came meanwhile."
  def finished(state, %{status: status} = record) do
    if status.error,
      do: Logger.warning("copying /mnt/mwt into the VM failed: #{status.error}", system: :sandbox)

    state = %{state | inbox_sync: record}
    after_copy(state)
  end

  def finished(state, crashed) do
    Logger.warning("copying /mnt/mwt into the VM crashed: #{inspect(crashed)}", system: :sandbox)
    after_copy(%{state | inbox_sync: nil})
  end

  defp after_copy(%{inbox_due: true} = state), do: start(state)
  defp after_copy(state), do: answer_waiters(state)

  @doc """
  Answers `from` once no copy is under way or due: at once when none is, or
  when the VM isn't running.
  """
  def await(state, from) do
    pending? =
      state.vm.status == :running and
        (state.inbox_due or :sync_inbox in Map.values(state.tasks))

    if pending? do
      %{state | inbox_waiters: [from | state.inbox_waiters]}
    else
      GenServer.reply(from, :ok)
      state
    end
  end

  @doc "Answers everyone waiting for a copy to end."
  def answer_waiters(state) do
    Enum.each(state.inbox_waiters, &GenServer.reply(&1, :ok))
    %{state | inbox_waiters: []}
  end
end
