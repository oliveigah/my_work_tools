defmodule MWTClient.Sandbox.Server.Running do
  @moduledoc """
  The requests MWT read that are still running, for the activity log to
  mark their lines and say how long they took.

  A request runs from when its call asks for it to be judged
  (`began/4`) until it ends, when its call hands over what it carried
  (`ended/2`), or until the call's process does (`down/2`): a call that
  crashed or was killed ends every request it ran, and what its driver
  said to keep of it then (`MWTClient.Sandbox.Egress.Driver.unfinished/2`)
  is what the log keeps. Nothing runs from before the server started: its
  record lives in memory only.

  Each is kept by its id, the one its events name as `exchange_id`, with
  when it began, the monitor on its call and what to keep should the call
  end first (`requests_running`), and found by that monitor
  (`request_monitors`).
  """

  @doc """
  The request `id`, run by the call `pid`, began now; `unfinished` is
  what to keep of it should its call end first, or nil. Told again (a
  request judged twice), it keeps its first start.
  """
  def began(state, id, pid, unfinished) do
    if Map.has_key?(state.requests_running, id) do
      state
    else
      ref = Process.monitor(pid)

      began = %{
        ref: ref,
        since: System.monotonic_time(:millisecond),
        at: DateTime.utc_now(),
        unfinished: unfinished
      }

      %{
        state
        | requests_running: Map.put(state.requests_running, id, began),
          request_monitors: Map.put(state.request_monitors, ref, id)
      }
    end
  end

  @doc """
  The request `id` ended: how long it ran, in milliseconds, or nil for one
  not known to have begun.
  """
  def ended(state, id) do
    case Map.pop(state.requests_running, id) do
      {nil, _running} ->
        {nil, state}

      {began, running} ->
        # Flushing scans the server's mailbox. A queued DOWN can be
        # ignored once its ref is removed from request_monitors.
        Process.demonitor(began.ref)

        state = %{
          state
          | requests_running: running,
            request_monitors: Map.delete(state.request_monitors, began.ref)
        }

        {took(began), state}
    end
  end

  @doc """
  The call a request ran on ended, its monitor `ref` says: `{id, ms,
  unfinished}` for the request, or nil when `ref` is no request's.
  """
  def down(state, ref) do
    case Map.pop(state.request_monitors, ref) do
      {nil, _refs} ->
        {nil, state}

      {id, refs} ->
        {began, running} = Map.pop(state.requests_running, id)

        {{id, took(began), began.unfinished},
         %{state | requests_running: running, request_monitors: refs}}
    end
  end

  @doc "When the request `id` began, while it runs; nil otherwise."
  def since(_state, nil), do: nil

  def since(state, id) do
    case Map.fetch(state.requests_running, id) do
      {:ok, began} -> began.at
      :error -> nil
    end
  end

  @doc """
  What to keep of the request `id` should its call end first, while it
  runs: the request as MWT read it, with no answer yet. Nil once it ended,
  or when its driver keeps nothing until then.
  """
  def unfinished(state, id) do
    case Map.fetch(state.requests_running, id) do
      {:ok, began} -> began.unfinished
      :error -> nil
    end
  end

  @doc "Every running request's id, with when it began."
  def all(state), do: Map.new(state.requests_running, fn {id, began} -> {id, began.at} end)

  defp took(began), do: max(System.monotonic_time(:millisecond) - began.since, 0)
end
