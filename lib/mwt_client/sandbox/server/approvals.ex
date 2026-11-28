defmodule MWTClient.Sandbox.Server.Approvals do
  @moduledoc """
  What waits for you, in the sandbox server's state: holding a use or an
  agent's ask as an approval, joining a retry to the one already waiting,
  your decision and what it sets off, giving up when the time runs out, and
  answering everyone who was held.

  A use is decided before it gets here (`MWTClient.Sandbox.Policy`); this is
  what happens when the answer was "ask". Runs in the server's process
  (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{
    Approval,
    Decision,
    Describe,
    Event,
    Grant,
    HostCommand,
    HostRun,
    Presets,
    Proposal,
    Shown
  }

  alias MWTClient.Sandbox.Server.{Grants, HostRuns, ShareSync, State, Values}

  @history_limit 100
  # An agent's ask waits this long for you; the agent itself waits less and
  # comes back with `mwt wait`.
  @activation_hold_seconds 30 * 60
  @max_waiting_activations 10
  # The VM's requests and connections waiting for you: each holds what MWT
  # read of it (a request, up to 64 KiB of body), shows on every page and
  # raises a notification, so there are at most this many of each kind,
  # and this many held on any one of them.
  @max_waiting_uses 20
  @max_waiters 10

  @doc """
  Joins a waiting approval for the very same use, so a client's retries
  are one decision, or starts a new one. "The same" is `join`, not the
  pattern: a request that differs from the card in anything, a header, the
  query or a byte of its body, is another card, since a decision covers
  what its card shows.

  The VM decides how many it sends, so at most `max_waiting_uses/0`
  requests (and as many connections) wait at once, and `max_waiters/0`
  callers on each; one more is refused at once: a request with `429`
  `mwt_too_many_waiting`, a connection closed.
  """
  def hold(state, approval, waiter) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.grant_id == approval.grant_id and
             other.kind == approval.kind and other.join == approval.join
         end) do
      %Approval{} = waiting ->
        if length(Map.get(state.waiters, waiting.id, [])) >= @max_waiters do
          too_many(state, approval, waiter, "#{@max_waiters} of the same already wait")
        else
          state
          |> State.replace_approval(%{waiting | retries: waiting.retries + 1})
          |> add_waiter(waiting.id, waiter)
        end

      nil ->
        if Enum.count(state.approvals, &(&1.status == :waiting and &1.kind == approval.kind)) >=
             @max_waiting_uses do
          too_many(state, approval, waiter, "#{@max_waiting_uses} others already wait for you")
        else
          start_hold(state, approval, waiter)
        end
    end
  end

  @doc "The most requests, and the most connections, that wait for you at once."
  def max_waiting_uses, do: @max_waiting_uses

  @doc "The most callers held on one waiting request or connection."
  def max_waiters, do: @max_waiters

  defp start_hold(state, approval, waiter) do
    Process.send_after(
      self(),
      {:give_up, approval.id, approval.deadline},
      max(DateTime.diff(approval.deadline, State.now(), :millisecond), 0)
    )

    state
    |> add_waiter(approval.id, waiter)
    |> State.change(:approvals, &[approval | &1.approvals])
  end

  # Refused at once, without a card: the agent hears why, and the log
  # keeps it.
  defp too_many(state, approval, {from, held}, why) do
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))
    message = "Too many wait for the user's approval (#{why}). Try again once they decided."

    GenServer.reply(
      from,
      case held do
        :connection -> {:deny, message}
        {:request, _request} -> Values.deny(429, "mwt_too_many_waiting", message, grant)
      end
    )

    State.log(state, event_for(approval, :refused, why))
  end

  @doc """
  What a waiting request's card is joined by: a digest of everything MWT
  read of it, which is everything its card shows (method, host, full
  target, every header in order, and its body). Two requests share it only
  when they are the same request, so a retry joins and nothing else does:
  not one with the placeholder in another header, nor one with a header
  more.

  A request whose body MWT holds only the start of (it reads at most 64
  KiB before deciding) joins nothing: two that differ only past that
  start would share one card, and one decision would let through a body
  nobody saw. Its card is its own, `id`.
  """
  def request_join(request, id) do
    if Describe.whole_body?(request),
      do: Approval.digest(Map.delete(request, :exchange)),
      else: {:only_the_start, id}
  end

  @doc """
  Holds one more caller on an approval, to be answered when it is decided.
  """
  def add_waiter(state, approval_id, waiter),
    do:
      Map.update!(
        state,
        :waiters,
        &Map.update(&1, approval_id, [waiter], fn list -> list ++ [waiter] end)
      )

  @doc """
  Which decisions fit which approval: activations are answered by turning
  a grant on (or setting one up), uses by letting them through.
  """
  def fits?(%Approval{kind: :activation, grant_id: nil}, decision, state) do
    case decision do
      {:set_up, grant_id} -> Enum.any?(state.grants, &(&1.id == grant_id))
      :decline -> true
      _other -> false
    end
  end

  def fits?(%Approval{kind: :activation} = approval, decision, state) do
    case decision do
      # One an agent proposed turns on only as you accept it, on its page.
      {:turn_on, minutes, uses} ->
        uses in [:ask, :all] and duration?(minutes, :until_off) and
          not to_review?(state, approval)

      :decline ->
        true

      _other ->
        false
    end
  end

  def fits?(%Approval{kind: :command, stage: :run}, decision, _state) do
    case decision do
      {:run, output_to} -> output_to in [:send, :review]
      :decline -> true
      :simpler -> true
      _other -> false
    end
  end

  def fits?(%Approval{kind: :command, stage: :output}, decision, _state),
    do: decision in [:send_output, :keep_output]

  def fits?(%Approval{} = approval, decision, state) do
    case decision do
      :allow_once ->
        true

      # Nothing is similar to a use MWT couldn't describe (no pattern).
      {:allow, scope, duration} ->
        (scope == :all or (scope == :similar and approval.pattern != nil) or
           (scope == :ids and MWTClient.Sandbox.Allowance.widen(approval.pattern) != nil)) and
          duration?(duration, :grant)

      # Only some of the card's grants, those you left ticked.
      {:allow, scope, duration, ids} ->
        is_list(ids) and ids != [] and Enum.all?(ids, &(&1 in Approval.grant_ids(approval))) and
          fits?(approval, {:allow, scope, duration}, state)

      :deny ->
        true

      :deny_and_turn_off ->
        true

      # Turning off the one of the card's grants you chose.
      {:deny_and_turn_off, id} ->
        id in Approval.grant_ids(approval)

      _other ->
        false
    end
  end

  # Turning it on from its card waits for what its page or its resource
  # needs first (`Grants.turn_on_refusal/2`).
  defp to_review?(state, approval) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      %Grant{} = grant -> Grants.turn_on_refusal(state, grant) != nil
      nil -> approval.resource != nil
    end
  end

  defp duration?(minutes, _open) when is_integer(minutes) and minutes > 0, do: true

  defp duration?(open, open), do: true

  defp duration?(_other, _open), do: false

  @doc """
  Carries out your decision on a waiting approval. `fits?/3` says which decisions an approval takes.
  """
  def decide(state, approval, {:turn_on, minutes, uses}) do
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))

    state
    |> settle(approval, :allowed, {:turn_on, minutes, uses})
    |> Grants.turn_on(
      grant,
      minutes,
      uses,
      " · asked by #{approval.agent}",
      you(state, approval, "you turned it on", true)
    )
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, {:set_up, grant_id}) do
    grant = Enum.find(state.grants, &(&1.id == grant_id))
    approval = %{approval | grant_id: grant_id}
    minutes = approval.minutes

    state
    |> State.replace_approval(approval)
    |> settle(approval, :allowed, {:set_up, grant_id})
    |> then(fn state ->
      # One you set to be enabled on startup is enabled already, as you chose.
      if not Grants.starts_on?(grant.start),
        do: Grants.turn_on(state, grant, minutes, :ask, " · asked by #{approval.agent}"),
        else: state
    end)
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, {:run, output_to}),
    do:
      state
      |> run(
        approval,
        {:run, output_to},
        "you ran it" <> HostRuns.output_words(output_to)
      )

  def decide(state, approval, :send_output) do
    state
    |> settle(approval, :allowed, :send_output)
    |> State.log(
      HostRuns.command_event(
        approval,
        "you sent its output to the agent",
        you(state, approval, "you sent its output to the agent", true)
      )
    )
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, :keep_output) do
    state
    |> settle(approval, :denied, :keep_output)
    |> State.log(
      HostRuns.command_event(
        approval,
        "you kept its output from the agent",
        you(state, approval, "you kept its output from the agent", false)
      )
    )
    |> answer_waiters(approval, {:deny, :by_you})
  end

  def decide(state, approval, :decline) do
    state
    |> settle(approval, :denied, :decline)
    |> State.log(
      event_for(approval, :denied, "you declined", you(state, approval, "you declined", false))
    )
    |> answer_waiters(approval, {:deny, :by_you})
  end

  def decide(state, approval, :simpler) do
    state
    |> settle(approval, :denied, :simpler)
    |> State.log(
      event_for(
        approval,
        :denied,
        "you asked for a simpler one",
        you(state, approval, "you asked for a simpler one", false)
      )
    )
    |> answer_waiters(approval, {:deny, :by_you})
  end

  def decide(state, approval, :allow_once) do
    state
    |> settle(approval, :allowed, :allow_once)
    |> State.log(
      event_for(
        approval,
        :allowed,
        "you allowed once",
        you(state, approval, "you allowed once", true)
      )
    )
    |> answer_waiters(approval, :allow)
  end

  def decide(state, approval, {:allow, scope, duration}),
    do: decide(state, approval, {:allow, scope, duration, Approval.grant_ids(approval)})

  def decide(state, approval, {:allow, scope, duration, ids}) do
    case for(id <- ids, grant = Enum.find(state.grants, &(&1.id == id)), do: grant) do
      [] ->
        decide(state, approval, :allow_once)

      # This card goes by your decision; the allowance, added to each grant
      # you left ticked, then settles the others it would have let through
      # (`Policy.settles?/3`), which may leave out some it doesn't cover,
      # such as a host its host list asks about.
      grants ->
        pattern =
          case scope do
            :all -> :all
            :ids -> MWTClient.Sandbox.Allowance.widen(approval.pattern)
            :similar -> approval.pattern
          end

        how =
          case scope do
            :all -> "every use"
            :ids -> "similar, any id"
            :similar -> "similar"
          end

        state =
          state
          |> settle(approval, :allowed, {:allow, scope, duration})
          |> then(fn settled ->
            words =
              "you allowed #{how} #{State.duration_words(duration)}" <>
                if(length(grants) > 1,
                  do: ", on #{Enum.map_join(grants, ", ", & &1.name)}",
                  else: ""
                )

            State.log(
              settled,
              event_for(approval, :allowed, words, you(state, approval, words, true))
            )
          end)
          |> answer_waiters(approval, :allow)

        Enum.reduce(grants, state, fn grant, state ->
          grant = Enum.find(state.grants, &(&1.id == grant.id)) || grant

          state
          |> Grants.allow(grant, pattern, duration, %{kind: :card, card: approval.id})
          |> State.log(%{
            outcome: :grant,
            summary:
              if(scope == :all,
                do: "#{grant.name}: every use allowed #{State.duration_words(duration)}",
                else:
                  "#{grant.name}: uses like “#{approval.title}” allowed #{State.duration_words(duration)}"
              ),
            grant_id: grant.id
          })
        end)
    end
  end

  def decide(state, approval, :deny) do
    state
    |> settle(approval, :denied, :deny)
    |> State.log(
      event_for(approval, :denied, "you denied", you(state, approval, "you denied", false))
    )
    |> answer_waiters(approval, {:deny, :by_you})
  end

  def decide(state, approval, :deny_and_turn_off),
    do: decide(state, approval, {:deny_and_turn_off, approval.grant_id})

  def decide(state, approval, {:deny_and_turn_off, id}) do
    state =
      state
      |> settle(approval, :denied, :deny_and_turn_off)
      |> State.log(
        event_for(approval, :denied, "you denied", you(state, approval, "you denied", false))
      )
      |> answer_waiters(approval, {:deny, :by_you})

    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        state

      grant ->
        state
        |> settle_waiting(grant.id, :grant_off)
        |> State.replace_grant(Grant.put_down(grant))
        |> State.log(%{
          outcome: :grant,
          summary: "#{grant.name} turned off from an approval",
          grant_id: grant.id
        })
        |> State.write_inbox()
        |> State.changed()
    end
  end

  @doc """
  Starts a command that waited to run, settled with `decision`: yours
  (`{:run, output_to}`), or `:auto` for a saved command you auto-approved,
  whose output goes straight to the agent. `how` is what the log says.

  Only as it was asked: when its grant no longer allows it, or was edited
  since (`HostRuns.still/2`), nothing runs, the card is refused, and the
  agent hears why. It runs confined as its card says (`Approval.confine`),
  never as the grant says now.
  """
  def run(state, approval, decision, how) do
    case HostRuns.still(state, approval) do
      :ok ->
        start(state, approval, decision, how)

      {:refused, why} ->
        state
        |> settle(approval, :denied, why)
        |> answer_waiters(approval, {:deny, why})
        |> State.log(
          HostRuns.command_event(
            approval,
            HostRuns.refused_words(why),
            Decision.refused(HostRuns.refused_words(why))
          )
        )
    end
  end

  defp start(state, approval, decision, how) do
    output_to =
      case decision do
        {:run, output_to} -> output_to
        :auto -> :send
      end

    run = %{
      state: :running,
      output_to: output_to,
      started_at: State.now(),
      finished_at: nil,
      exit: nil,
      output: "",
      bytes: 0,
      cut: 0,
      stopped: false,
      timed_out: false,
      error: nil,
      status: nil,
      findings: [],
      held: false
    }

    approval = %{approval | run: run}
    server = self()
    id = approval.id

    job = %{
      script: approval.script,
      dir: approval.dir,
      timeout: approval.timeout,
      env: Map.get(approval, :values) || [],
      workspace: ShareSync.root(state)
    }

    state =
      state
      |> settle(approval, :allowed, decision)
      |> State.log(
        HostRuns.command_event(
          approval,
          how,
          settled(
            if(decision == :auto,
              do: HostRuns.auto_decision(state, approval),
              else: you(state, approval, how, true)
            ),
            approval
          )
        )
      )
      |> HostRuns.repin(approval)

    # A request action's call is a request MWT sends, not a script; a
    # confined one runs once the values of the grants it names are at hand.
    cond do
      approval.call ->
        HostRuns.send_call(state, approval)

      match?(%{confined: true}, approval.confine) ->
        HostRuns.run_confined(state, approval, job, approval.confine)

      true ->
        State.task(state, {:command, id}, fn ->
          HostRun.run(job, fn group -> send(server, {:command_started, id, group}) end)
        end)
    end
  end

  @doc """
  Turning a grant on yourself answers the agents waiting for it.
  """
  def settle_activations(state, grant_id, minutes, uses) do
    state.approvals
    |> Enum.filter(
      &(&1.status == :waiting and &1.kind == :activation and &1.grant_id == grant_id)
    )
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :allowed, {:turn_on, minutes, uses})
      |> answer_waiters(approval, :allow)
    end)
  end

  @doc """
  Answers the agent waiting on a resource it proposed: you accepted it.
  """
  def settle_resource(state, resource) do
    state.approvals
    |> Enum.filter(
      &(&1.status == :waiting and &1.kind == :activation and &1.resource == resource)
    )
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :allowed, :accepted)
      |> answer_waiters(approval, :allow)
    end)
  end

  @doc """
  Answers everyone held on `approval`: the proxy's connections and
  requests, and agents waiting through the channel.
  """
  def answer_waiters(state, approval, outcome) do
    {waiters, all} = Map.pop(state.waiters, approval.id, [])
    state = %{state | waiters: all}
    grant = Enum.find(state.grants, &(&1.id == approval.grant_id))
    settled = Enum.find(state.approvals, &(&1.id == approval.id)) || approval

    Enum.reduce(waiters, state, fn
      # The agent hears of the grant as it is for it now.
      {from, {:await, _ref}}, acc ->
        GenServer.reply(
          from,
          {:ok, settled, Enum.find(acc.grants, &(&1.id == approval.grant_id))}
        )

        acc

      {from, :connection}, acc ->
        GenServer.reply(
          from,
          if(outcome == :allow, do: {:ok, approval.grant_id}, else: {:deny, "Not allowed"})
        )

        if outcome == :allow, do: State.used(acc, approval.grant_id), else: acc

      # A network grant's request: once allowed, the token grant's turn,
      # if a placeholder is in it (`Gate.authorize/2`).
      {from, {:network_request, _request}}, acc ->
        case outcome do
          :allow ->
            # With what decided the card, which its line said first.
            GenServer.reply(
              from,
              {:ok, approval.grant_id, State.card_decision(acc, approval.id)}
            )

            State.used(acc, approval.grant_id)

          denied ->
            GenServer.reply(from, refusal(denied, grant))
            acc
        end

      {from, {:request, request}}, acc ->
        # The grant whose value the request carries, whichever grant the
        # card was asked for.
        credential = Enum.find(acc.grants, &(&1.id == Map.get(request, :credential)))
        grant = credential || grant

        case {outcome, grant} do
          # A card a network grant led, with no credential in the request.
          {:allow, %Grant{kind: :network}} ->
            GenServer.reply(
              from,
              {:forward, Values.replace([]), Values.scan(acc, request.host)}
            )

            approval
            |> Approval.grant_ids()
            |> Enum.reduce(acc, &State.used(&2, &1))
            |> State.log(%{
              # As its card was decided, which its own line says.
              decision: State.card_decision(acc, approval.id),
              outcome: :read,
              summary: "Read by MWT, no credential in it",
              host: request.host,
              port: Map.get(request, :port, 443),
              grant_id: approval.grant_id,
              method: request.method,
              path: request.path,
              exchange_id: Map.get(request, :exchange)
            })

          {:allow, %Grant{}} ->
            acc =
              Enum.reduce(Approval.grant_ids(approval) -- [grant.id], acc, &State.used(&2, &1))

            Values.let_through(acc, grant, request, from)

          {denied, _grant} ->
            GenServer.reply(from, refusal(denied, grant))
            acc
        end
    end)
  end

  # The answer to a request whose card was declined, timed out, or whose
  # grant turned off or VM was isolated meanwhile.
  defp refusal({:deny, :timed_out}, grant),
    do: Values.deny(403, "mwt_approval_timeout", "Nobody decided in time.", grant)

  defp refusal({:deny, :grant_off}, grant),
    do: Values.deny(403, "mwt_grant_off", "The grant turned off while this waited.", grant)

  defp refusal({:deny, :isolated}, _grant), do: Values.isolated()

  defp refusal({:deny, :locked}, grant),
    do:
      Values.deny(
        403,
        "mwt_locked",
        MWTClient.Sandbox.Resource.locked_words(MWTClient.Sandbox.Grant.resource(grant)) <>
          " Tell the user what you were doing.",
        grant
      )

  defp refusal(_denied, grant),
    do: Values.deny(403, "mwt_denied_by_user", "The user denied this request.", grant)

  @doc """
  What an agent asked for, checked: a grant that exists (by id, or by name
  in any case), or a `need` no grant meets yet.
  """
  def activation(state, ask) do
    # An ask is the VM's: what isn't text counts as nothing.
    reason = ask |> Map.get(:reason) |> Shown.text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> Shown.text() |> String.trim() |> String.slice(0, 60)
    agent = if agent == "", do: "An agent", else: agent
    minutes = Map.get(ask, :minutes) || 60
    wanted = ask |> Map.get(:grant) |> State.to_text() |> String.trim()
    need = ask |> Map.get(:need) |> Shown.text() |> String.trim() |> String.slice(0, 400)

    grant =
      Enum.find(state.grants, &(&1.id == wanted)) ||
        Enum.find(state.grants, &(String.downcase(&1.name) == String.downcase(wanted)))

    waiting = Enum.filter(state.approvals, &(&1.status == :waiting and &1.kind == :activation))
    pattern = if grant, do: "activate #{grant.id}", else: "need #{need}"

    cond do
      reason == "" ->
        {:error, :no_reason}

      not (is_integer(minutes) and minutes in 1..1440) ->
        {:error, :bad_minutes}

      wanted == "" and need == "" ->
        {:error, :nothing_asked}

      wanted != "" and is_nil(grant) ->
        {:error, :unknown_grant}

      # Its resource locked: nothing it gives would go, and the lock is
      # the user's alone.
      grant && Map.has_key?(Map.get(state, :locks, %{}), Grant.resource(grant)) ->
        {:error, {:locked, Grant.resource(grant)}}

      grant && Grant.on?(grant) ->
        {:already_on, Enum.find(state.grants, &(&1.id == grant.id))}

      length(waiting) >= @max_waiting_activations and
          not Enum.any?(waiting, &(&1.pattern == pattern)) ->
        {:error, :too_many}

      true ->
        {:ok,
         %Approval{
           id: Approval.new_id("ask"),
           kind: :activation,
           grant_id: grant && grant.id,
           title:
             cond do
               is_nil(grant) -> "Access you haven't set up"
               Grant.to_review?(grant) -> "Review #{grant.name}"
               true -> "Turn on #{grant.name}"
             end,
           agent: agent,
           thread: Approval.thread(ask),
           minutes: minutes,
           need: if(grant, do: nil, else: need),
           reason: reason,
           pattern: pattern,
           requested_at: State.now(),
           deadline: DateTime.add(State.now(), @activation_hold_seconds, :second),
           claims: [{"Reason", reason}]
         }}
    end
  end

  @max_to_review 20

  @doc """
  What an agent proposes (`mwt propose`), checked as the forms check what
  you add (`MWTClient.Sandbox.Proposal`): a credential, a network, a grant
  over a resource, or an action over one that takes them. Returns what to
  save, tagged (`{:grant, grant}`, `{:credential, credential}` or
  `{:network, network}`, off and to review), the ask the agent waits on,
  and the proposal of the same name it replaces, still to review, or nil.
  Nothing is saved here.
  """
  def proposal(state, ask) do
    reason = ask |> Map.get(:reason) |> Shown.text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> Shown.text() |> String.trim() |> String.slice(0, 60)
    agent = if agent == "", do: "An agent", else: agent
    minutes = Map.get(ask, :minutes) || 60
    wanted = ask |> Map.get(:grant) |> State.to_text() |> String.trim()
    name = ask |> Map.get(:name) |> line() |> String.slice(0, 60)
    purpose = ask |> Map.get(:purpose) |> line() |> String.slice(0, 280)
    ask = Map.merge(ask, %{name: name, purpose: purpose})

    cond do
      reason == "" ->
        {:error, :no_reason}

      not (is_integer(minutes) and minutes in 1..1440) ->
        {:error, :bad_minutes}

      name == "" ->
        {:error, :no_name}

      purpose == "" ->
        {:error, :no_purpose}

      true ->
        with {:ok, target} <- target(state, wanted, Map.get(ask, :over)),
             :ok <- script_given(target, ask),
             {:ok, preset} <- proposed_preset(state, target, ask),
             previous = previous(state, target, name),
             :ok <- room(state, previous),
             {:ok, attrs} <- fields(Proposal.attrs(target, place(state, target, ask), preset)),
             {:ok, made} <- build(state, target, attrs, preset, previous) do
          said = %{agent: agent, thread: Approval.thread(ask), reason: reason, minutes: minutes}
          made = stamped(made, Proposal.stamp(said, State.now()))
          {:ok, made, proposal_ask(made, target, said, previous), previous}
        end
    end
  end

  defp target(state, wanted, over) do
    known = %{
      grants: state.grants,
      credentials: Map.get(state, :credentials, []),
      networks: Map.get(state, :networks, [])
    }

    case Proposal.target(wanted, over, known) do
      {:error, reason} -> {:error, reason}
      target -> {:ok, target}
    end
  end

  # A command action is its script: none, and there is nothing to read.
  defp script_given({:over, :machine, _over}, ask) do
    if ask |> Map.get(:script) |> State.to_text() |> String.trim() == "",
      do: {:error, :no_script},
      else: :ok
  end

  defp script_given(_target, _ask), do: :ok

  # The preset it starts from, MWT's or yours, of what it makes.
  defp proposed_preset(state, target, ask) do
    case {ask |> Map.get(:preset) |> State.to_text() |> String.trim(),
          Proposal.preset_makes(target)} do
      {"", _makes} ->
        {:ok, nil}

      {id, nil} ->
        {:error, {:no_preset, id, Proposal.thing(target)}}

      {id, makes} ->
        case Presets.find(id, state.username) do
          {:ok, %{id: id, makes: ^makes} = preset} when is_binary(id) -> {:ok, preset}
          _other -> {:error, {:no_preset, id, Proposal.thing(target)}}
        end
    end
  end

  defp fields({:ok, attrs}), do: {:ok, attrs}
  defp fields({:error, message}), do: {:error, {:proposal, message}}

  # What it makes, built as the forms build what you add.
  defp build(state, {:new, :credential}, attrs, preset, previous) do
    alias MWTClient.Sandbox.Server.Resources

    keep = [valueless: true, placeholder: previous && previous.placeholder]

    case Resources.build_credential(attrs, preset, keep) do
      {:ok, credential, _value} ->
        {:ok,
         {:credential,
          %{credential | id: resource_id(state, :credentials, credential.name, previous)}}}

      {:error, errors} ->
        {:error, {:proposal, Proposal.refusal(errors)}}
    end
  end

  defp build(state, {:new, :network}, attrs, _preset, previous) do
    case MWTClient.Sandbox.Server.Resources.build_network(attrs) do
      {:ok, network} ->
        {:ok, {:network, %{network | id: resource_id(state, :networks, network.name, previous)}}}

      {:error, errors} ->
        {:error, {:proposal, Proposal.refusal(errors)}}
    end
  end

  defp build(state, _target, attrs, preset, previous) do
    others = %{state | grants: Enum.reject(state.grants, &(previous && &1.id == previous.id))}

    case Grants.build_new(others, attrs, preset, proposal: true) do
      {:ok, grant, _value} ->
        grant = %{
          grant
          | id: (previous && previous.id) || grant.id,
            state: :off,
            start: :off,
            expires_at: nil,
            allowances: []
        }

        {:ok, {:grant, grant}}

      {:error, errors} ->
        {:error, {:proposal, Proposal.refusal(errors)}}
    end
  end

  # A new resource's id, made from its name; the one it replaces keeps its.
  defp resource_id(_state, _key, _name, %{id: id}), do: id

  defp resource_id(state, key, name, nil) do
    alias MWTClient.Sandbox.Server.Resources
    Resources.new_id(name, state |> Map.get(key, []) |> Enum.map(& &1.id))
  end

  defp stamped({tag, made}, proposal), do: {tag, %{made | proposal: proposal}}

  # The proposal of the same name, of the same kind, over the same
  # resource, still to review: proposing again changes it.
  defp previous(state, {:new, :credential}, name),
    do: same_name(Map.get(state, :credentials, []), name)

  defp previous(state, {:new, :network}, name),
    do: same_name(Map.get(state, :networks, []), name)

  defp previous(state, target, name) do
    same? =
      case target do
        {:over, resource, _over} -> &(Grant.action?(&1) and Grant.resource(&1) == resource)
        {:grant, resource, _over} -> &(not Grant.action?(&1) and Grant.resource(&1) == resource)
      end

    Enum.find(
      state.grants,
      &(Grant.to_review?(&1) and same?.(&1) and String.downcase(&1.name) == String.downcase(name))
    )
  end

  defp same_name(resources, name) do
    Enum.find(
      resources,
      &(match?(%{proposal: %{reviewed_at: nil}}, &1) and
          String.downcase(&1.name) == String.downcase(name))
    )
  end

  defp room(state, nil) do
    to_review =
      Enum.count(state.grants, &Grant.to_review?/1) +
        Enum.count(
          Map.get(state, :credentials, []) ++ Map.get(state, :networks, []),
          &match?(%{proposal: %{reviewed_at: nil}}, &1)
        )

    if to_review >= @max_to_review, do: {:error, :too_many_proposals}, else: :ok
  end

  defp room(_state, _previous), do: :ok

  # A command action runs in the folder the agent names, as this
  # machine has it: a shared folder's path, or your home folder.
  defp place(state, {:over, :machine, _over}, ask) do
    asked = ask |> Map.get(:dir) |> State.to_text() |> String.trim()
    shares = state.settings.shares ++ HostCommand.halves(ShareSync.root(state))
    dir = asked |> HostCommand.place(shares, System.user_home!()) |> elem(1)
    Map.put(ask, :dir, dir)
  end

  # Anything else runs nowhere: the folder the CLI always sends is no
  # field of it.
  defp place(_state, _target, ask), do: Map.delete(ask, :dir)

  # The ask the agent waits on: for a grant, answered once you accept it
  # and it turns on; for a resource, once you accept it. Declining it
  # removes the proposal.
  defp proposal_ask({tag, made}, target, said, previous) do
    parent_name =
      case target do
        {:over, _resource, %{name: name}} -> name
        {:grant, _resource, %{name: name}} -> name
        _new -> nil
      end

    {grant_id, resource, kind} =
      case tag do
        :grant -> {made.id, nil, made.kind}
        resource -> {nil, {resource, made.id}, resource}
      end

    %Approval{
      id: Approval.new_id("ask"),
      kind: :activation,
      grant_id: grant_id,
      resource: resource,
      title: "Review #{made.name}",
      agent: said.agent,
      thread: said.thread,
      minutes: said.minutes,
      reason: said.reason,
      pattern: "propose #{if(resource, do: "#{tag}:", else: "")}#{made.id}",
      proposal: %{
        kind: kind,
        parent_name: if(is_binary(parent_name), do: parent_name),
        updated: previous != nil
      },
      requested_at: State.now(),
      deadline: DateTime.add(State.now(), @activation_hold_seconds, :second),
      claims: [{"Reason", said.reason}, {"It is for", made.purpose}]
    }
  end

  defp line(text),
    do: text |> Shown.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  @doc """
  One waiting ask per grant (and per described need): asking again joins it.
  """
  def hold_activation(state, approval) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.kind == :activation and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        joined = %{waiting | retries: waiting.retries + 1}
        {State.replace_approval(state, joined), joined}

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          @activation_hold_seconds * 1_000
        )

        {State.change(state, :approvals, &[approval | &1.approvals]), approval}
    end
  end

  @doc """
  Ends an approval nobody decided in time, and tells everyone held on it.
  """
  def give_up(state, %Approval{kind: :command, stage: :output} = approval) do
    state
    |> settle(approval, :timed_out, nil)
    |> answer_waiters(approval, {:deny, :timed_out})
    |> State.log(
      HostRuns.command_event(
        approval,
        "output kept: you didn't release it in time",
        Decision.timeout(approval)
      )
    )
  end

  def give_up(state, approval) do
    minutes = approval.deadline |> DateTime.diff(approval.requested_at) |> div(60) |> max(1)

    state
    |> settle(approval, :timed_out, nil)
    |> answer_waiters(approval, {:deny, :timed_out})
    |> State.log(
      event_for(approval, :timed_out, "gave up after #{minutes} min", Decision.timeout(approval))
    )
  end

  @doc """
  Marks an approval decided. The history keeps the last 100, and a command still running stays in sight whatever is decided meanwhile.
  """
  def settle(state, approval, status, decision) do
    approval = %{approval | status: status, decision: decision, decided_at: State.now()}
    state = State.keep_approval(state, approval)

    # A change's contents are for deciding; the history keeps what it said.
    approval =
      if approval.tool,
        do: %{approval | tool: %{approval.tool | from: nil, to: nil}},
        else: approval

    State.change(state, :approvals, fn state ->
      {waiting, decided} =
        state.approvals
        |> Enum.map(&if(&1.id == approval.id, do: approval, else: &1))
        |> Enum.split_with(&(&1.status == :waiting))

      # A running command stays whatever is decided meanwhile.
      {running, history} = Enum.split_with(decided, &Approval.running?/1)

      waiting ++
        running ++
        Enum.take(Enum.sort_by(history, & &1.decided_at, {:desc, DateTime}), @history_limit)
    end)
  end

  @doc """
  Refuses what waits on a grant, as when the grant turns off: every use
  and every command or call still waiting to run, unless `kinds` names
  fewer. `decision` says why: `:grant_off`, or `:changed` for a grant
  edited while they waited. Activations wait for a grant that is off, so
  only its removal refuses them, by naming them. A command that ran and
  whose output waits for you stays: nothing more runs when you release it.
  """
  def settle_waiting(
        state,
        grant_id,
        decision,
        kinds \\ [:request, :connection, :tool, :command]
      ),
      do:
        settle_waiting_where(
          state,
          &(grant_id in Approval.grant_ids(&1) and &1.kind in kinds),
          decision
        )

  @doc """
  Refuses every use, command or call still waiting to run that `picks?`
  picks, as `settle_waiting/4` does for a grant's: for what waits on no
  grant, as the commands agents write, when host commands are locked.
  """
  def settle_waiting_where(state, picks?, decision) do
    state.approvals
    |> Enum.filter(&(&1.status == :waiting and &1.stage == :run and picks?.(&1)))
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :denied, decision)
      |> State.log(event_for(approval, :refused, refused_words(approval, decision)))
      |> answer_waiters(approval, {:deny, decision})
    end)
  end

  defp refused_words(%Approval{kind: :command}, decision), do: HostRuns.refused_words(decision)
  defp refused_words(_approval, :changed), do: "its grant was edited"
  defp refused_words(_approval, :locked), do: "you locked what it reaches"
  defp refused_words(_approval, _decision), do: "its grant turned off"

  @doc """
  The log's event for what became of an approval; `decision` says who or what
  decided it (`MWTClient.Sandbox.Decision`), nil to let its outcome say.
  """
  def event_for(approval, outcome, how, decision \\ nil)

  def event_for(%Approval{kind: :command} = approval, _outcome, how, decision),
    do: HostRuns.command_event(approval, how, settled(decision, approval))

  def event_for(approval, outcome, how, decision) do
    Map.merge(Event.asked_by(approval.agent, approval.thread), %{
      decision: settled(decision, approval),
      outcome: outcome,
      summary: "#{approval.title} · #{how}",
      host: approval.host,
      port: event_port(approval),
      grant_id: approval.grant_id,
      method: approval.method,
      path: approval.path,
      exchange_id: is_map(approval.request) && Map.get(approval.request, :exchange),
      details: Approval.details(approval)
    })
  end

  # A card's line's decision says which card it settled, which an
  # allowance's names apart from the card it came from.
  defp settled(nil, _approval), do: nil
  defp settled(decision, approval), do: Map.put_new(decision, :settled, approval.id)

  # Decided by you on `approval`, choosing `how`, its grant as it is now.
  defp you(state, approval, how, allowed?),
    do: Decision.you(approval, how, State.grant_of(state, approval), allowed?)

  defp event_port(%Approval{kind: kind}) when kind in [:connection, :tool], do: nil
  defp event_port(%Approval{request: %{port: port}}) when is_integer(port), do: port
  defp event_port(_approval), do: 443
end
