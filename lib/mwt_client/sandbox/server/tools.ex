defmodule MWTClient.Sandbox.Server.Tools do
  @moduledoc """
  Calls of MWT's own tools from the VM, in the sandbox server's state
  (`MWTClient.Sandbox.MwtTools`): deciding one by its grant, counting what
  agents added in the last hour, holding one that asks as an approval
  (`kind: :tool`), and keeping how a change allowed late went.

  A held call has no waiter here: the agent's side waits with `{:await,
  id, ms}`, as `mwt wait` does, and makes the change once it hears it was
  allowed. Retries of the same call join the waiting card.
  """

  alias MWTClient.Sandbox.{Approval, Event, MwtTools, Policy}
  alias MWTClient.Sandbox.Server.{Firewall, State}

  @hour_ms 60 * 60 * 1000
  @max_waiting 10

  @doc """
  Decides one call (`t:MWTClient.Sandbox.MwtTools.use/0`): `:ok`, `{:error,
  message}` for the agent, or `{:ask, approval_id}` when it waits for you.
  """
  def decide(state, use) do
    if Firewall.isolated?(state) do
      {{:error,
        "MWT's firewall isolated this VM: nothing it sends leaves through MWT until the user " <>
          "releases it. The user has been told."}, Firewall.refused(state)}
    else
      decide_open(state, use)
    end
  end

  defp decide_open(state, use) do
    now_ms = System.monotonic_time(:millisecond)
    state = prune(state, now_ms)

    use =
      if use.grant == :create,
        do: Map.put(use, :over_limit, over_limit?(state, use)),
        else: use

    snapshot = State.policy(state)

    case Policy.decide(snapshot, {:tool, use}, State.now()) do
      {:refuse, {:grant_off, grant}} ->
        state =
          State.log(state, event(grant, :refused, "#{MwtTools.about(use).title} · off", use))

        {{:error,
          "#{grant.name} is off, so #{use.tool} can't run. Ask the user to turn it on: " <>
            ~s(mwt request #{grant.id} --reason "what you are about to do and why")}, state}

      {:refuse, {:check_failing, grant, why}} ->
        state =
          State.log(state, event(grant, :refused, "#{MwtTools.about(use).title} · paused", use))

        {{:error, "#{grant.name} is paused: #{why}. Tell the user."}, state}

      {:refuse, :no_mwt_grant} ->
        {{:error, "MWT has no grant for #{use.tool}. Tell the user."}, state}

      {:allow, grant, allowance, about} ->
        case if(use.grant == :read, do: Firewall.observe(state, :read), else: {:pass, state}) do
          {:pass, state} ->
            why =
              cond do
                allowance.pattern == :all -> "every use allowed"
                true -> "allowed like an earlier one"
              end

            state =
              state
              |> record(use, now_ms)
              |> State.used(grant.id)
              |> State.log(event(grant, :tool, "#{about.title} · #{why}", use))

            {:ok, state}

          {_refused, state} ->
            {{:error, "MWT's firewall refused this call. The user has been told."}, state}
        end

      {:ask, grant, about} ->
        hold(state, grant, about, use)
    end
  end

  @doc "Keeps how a change allowed after the agent stopped waiting went, for `mwt wait`."
  def applied(state, approval_id, outcome) do
    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      nil ->
        state

      approval ->
        {how, text} = outcome
        grant = Enum.find(state.grants, &(&1.id == approval.grant_id))

        state
        |> State.replace_approval(%{approval | applied: outcome})
        |> State.log(
          Map.merge(
            event(
              grant,
              if(how == :ok, do: :tool, else: :refused),
              "#{approval.title} · #{text}"
            ),
            Map.put(
              Event.asked_by(approval.agent, approval.thread),
              :details,
              Approval.details(approval, text)
            )
          )
        )
    end
  end

  # Retries of the same call join the card waiting for it, and only they:
  # the join is a digest of the whole call, its arguments and claims
  # included, since each joined call makes its own change once allowed.
  # Ten wait at most, so an agent in a loop can't bury the Approvals page.
  defp hold(state, grant, about, use) do
    join = Approval.digest(Map.delete(use, :apply))
    tools = Enum.filter(state.approvals, &(&1.status == :waiting and &1.kind == :tool))

    case Enum.find(tools, &(&1.grant_id == grant.id and &1.join == join)) do
      %Approval{} = waiting ->
        {{:ask, waiting.id},
         State.replace_approval(state, %{waiting | retries: waiting.retries + 1})}

      nil when length(tools) >= @max_waiting ->
        {{:error,
          "#{@max_waiting} calls of MWT's tools already wait for the user. Nothing changed: " <>
            "wait for them (mwt wait ID), or tell the user what you need."}, state}

      nil ->
        approval = approval(grant, about, use, join)

        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          MwtTools.hold_seconds() * 1000
        )

        {{:ask, approval.id}, State.change(state, :approvals, &[approval | &1.approvals])}
    end
  end

  defp approval(grant, about, use, join) do
    now = State.now()
    claims = Map.get(use, :claims, %{})

    %Approval{
      id: "tool-" <> State.unique(),
      kind: :tool,
      grant_id: grant.id,
      title: about.title,
      pattern: about.pattern,
      join: join,
      agent: claims[:agent],
      thread: Approval.thread(claims),
      requested_at: now,
      deadline: DateTime.add(now, MwtTools.hold_seconds(), :second),
      tool: %{
        tool: use.tool,
        kind: use[:kind],
        id: use[:id],
        title: use[:title],
        from: use[:from],
        to: use[:to],
        words: MwtTools.words(use)
      },
      facts: facts(use) ++ Map.get(about, :facts, [])
    }
  end

  defp facts(%{over_limit: true}) do
    %{items: items, bytes: bytes} = MwtTools.create_limit()

    [
      {"Why it asks",
       "Agents in the VM added #{items} items or #{div(bytes, 1024 * 1024)} MB in the last hour, so each addition asks until the hour has room."}
    ]
  end

  defp facts(_use), do: []

  defp event(grant, outcome, summary),
    do: %{outcome: outcome, summary: summary, grant_id: grant && grant.id}

  # Signed with who called, as the call claimed.
  defp event(grant, outcome, summary, use) do
    claims = Map.get(use, :claims, %{})

    event(grant, outcome, summary)
    |> Map.merge(Event.asked_by(claims[:agent], Approval.thread(claims)))
    |> Map.put(:details, MwtTools.details(use))
  end

  defp over_limit?(state, use) do
    %{items: items, bytes: bytes} = MwtTools.create_limit()
    added = Enum.map(state.tool_creates, &elem(&1, 1))
    length(added) >= items or Enum.sum(added) + Map.get(use, :bytes, 0) > bytes
  end

  defp record(state, %{grant: :create} = use, now_ms),
    do: %{state | tool_creates: [{now_ms, Map.get(use, :bytes, 0)} | state.tool_creates]}

  defp record(state, _use, _now_ms), do: state

  defp prune(state, now_ms),
    do: %{
      state
      | tool_creates: Enum.filter(state.tool_creates, &(now_ms - elem(&1, 0) < @hour_ms))
    }
end
