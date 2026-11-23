defmodule MWTClient.Sandbox.Server.Kept do
  @moduledoc """
  What the sandbox's server hands `MWTClient.Sandbox.UnlockState` after
  each message, to come back to after a restart, and takes back in its
  `init`: each grant as it is, the firewall's windows and refusals since
  an isolation, and what agents added in the last hour.

  The grants go as soon as they change: a grant you turned off must stay
  off whenever the server fails next. The firewall's windows change with
  each connection and each DNS query, so they go at most once a second
  (`@windows_every`), the last change on a timer: a failure forgets at most
  that second of counting. Nothing goes when nothing changed, which costs a
  comparison of terms that are mostly the very same ones.
  """

  alias MWTClient.Sandbox.UnlockState

  @windows_every 1_000

  @doc """
  What the server kept since the unlock, or nil: it is starting for the
  first time since then, a start.
  """
  @spec restore(String.t()) :: UnlockState.kept() | nil
  def restore(username), do: UnlockState.get(username)

  @doc """
  The state of a server that started again after a failure, from what it
  kept: the windows as they were, and an event in Activity that says so.
  The grants were taken as they were in `init`. Nil, a start: the state
  as it is.
  """
  def restored(state, nil), do: state

  def restored(state, kept) do
    state
    |> Map.merge(Map.take(kept, [:firewall_watch, :firewall_refused, :tool_creates]))
    |> Map.merge(%{kept: kept, kept_at: System.monotonic_time(:millisecond)})
    |> MWTClient.Sandbox.Server.State.log(%{
      outcome: :grant,
      summary:
        "The sandbox's server stopped on a failure and started again: grants and the " <>
          "firewall's counts are as they were. Asks it was answering were lost."
    })
  end

  @doc "Hands `UnlockState` what changed since it last did (see the module's notes)."
  def keep(%{kept: last} = state) do
    kept = kept(state)
    now = System.monotonic_time(:millisecond)

    cond do
      kept == last -> state
      last == nil or kept.grants != last.grants -> put(state, kept, now)
      now - state.kept_at >= @windows_every -> put(state, kept, now)
      state.kept_due != nil -> state
      true -> %{state | kept_due: Process.send_after(self(), :keep, @windows_every)}
    end
  end

  # A server's state from before this module (in development, compiled
  # again while it runs) keeps nothing until it starts again.
  def keep(state), do: state

  @doc "The timer of the windows' last change rang: they go now."
  def due(state), do: keep(%{state | kept_due: nil, kept_at: state.kept_at - @windows_every})

  defp kept(state) do
    %{
      grants: state.grants,
      firewall_watch: state.firewall_watch,
      firewall_refused: state.firewall_refused,
      tool_creates: state.tool_creates
    }
  end

  defp put(state, kept, now) do
    if state.kept_due, do: Process.cancel_timer(state.kept_due)
    :ok = UnlockState.put(state.username, kept)
    %{state | kept: kept, kept_at: now, kept_due: nil}
  end
end
