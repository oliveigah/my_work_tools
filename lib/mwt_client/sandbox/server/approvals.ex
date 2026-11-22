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

      # A grant that always asks takes no allowance: once is all. Nothing
      # is similar to a use MWT couldn't describe (no pattern).
      {:allow, scope, duration} ->
        (scope == :all or (scope == :similar and approval.pattern != nil)) and
          duration?(duration, :grant) and not always_asks?(state, approval)

      :deny ->
        true

      :deny_and_turn_off ->
        true

      _other ->
        false
    end
  end

  defp to_review?(state, approval) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      %Grant{} = grant -> Grant.to_review?(grant)
      nil -> false
    end
  end

  defp always_asks?(state, approval) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      %Grant{} = grant -> Grant.ceiling(grant) == :ask
      nil -> false
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
    |> Grants.turn_on(grant, minutes, uses, " · asked by #{approval.agent}")
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
      if grant.start == :off,
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
    |> answer_waiters(approval, :allow)
    |> State.log(HostRuns.command_event(approval, "you sent its output to the agent"))
  end

  def decide(state, approval, :keep_output) do
    state
    |> settle(approval, :denied, :keep_output)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(HostRuns.command_event(approval, "you kept its output from the agent"))
  end

  def decide(state, approval, :decline) do
    state
    |> settle(approval, :denied, :decline)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(event_for(approval, :denied, "you declined"))
  end

  def decide(state, approval, :simpler) do
    state
    |> settle(approval, :denied, :simpler)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(event_for(approval, :denied, "you asked for a simpler one"))
  end

  def decide(state, approval, :allow_once) do
    state
    |> settle(approval, :allowed, :allow_once)
    |> answer_waiters(approval, :allow)
    |> State.log(event_for(approval, :allowed, "you allowed once"))
  end

  def decide(state, approval, {:allow, scope, duration}) do
    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        decide(state, approval, :allow_once)

      grant ->
        pattern = if scope == :all, do: :all, else: approval.pattern

        state
        |> Grants.allow(grant, pattern, duration)
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
    end
  end

  def decide(state, approval, :deny) do
    state
    |> settle(approval, :denied, :deny)
    |> answer_waiters(approval, {:deny, :by_you})
    |> State.log(event_for(approval, :denied, "you denied"))
  end

  def decide(state, approval, :deny_and_turn_off) do
    state =
      state
      |> settle(approval, :denied, :deny_and_turn_off)
      |> answer_waiters(approval, {:deny, :by_you})
      |> State.log(event_for(approval, :denied, "you denied"))

    case Enum.find(state.grants, &(&1.id == approval.grant_id)) do
      nil ->
        state

      grant ->
        state
        |> settle_waiting(grant.id, :grant_off)
        |> State.replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
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
  """
  def run(state, approval, decision, how) do
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

    grant = State.grant_of(state, approval)

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
      |> State.log(HostRuns.command_event(approval, how))

    # A request subgrant's call is a request MWT sends, not a script; a
    # confined one runs once the values of the grants it names are at hand.
    cond do
      approval.call ->
        HostRuns.send_call(state, approval)

      match?(%Grant{confined: true}, grant) ->
        HostRuns.run_confined(state, approval, job, grant)

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
        GenServer.reply(from, {:ok, settled, State.live_grant(acc, approval.grant_id)})
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
            GenServer.reply(from, {:ok, approval.grant_id})
            State.used(acc, approval.grant_id)

          denied ->
            GenServer.reply(from, refusal(denied, grant))
            acc
        end

      {from, {:request, request}}, acc ->
        case {outcome, grant} do
          {:allow, %Grant{}} ->
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

      grant && Grant.subgrants_only?(grant) ->
        {:error, {:subgrants_only, grant.id}}

      grant && Grant.on?(grant) ->
        {:already_on, State.live_grant(state, grant.id)}

      length(waiting) >= @max_waiting_activations and
          not Enum.any?(waiting, &(&1.pattern == pattern)) ->
        {:error, :too_many}

      true ->
        {:ok,
         %Approval{
           id: "ask-" <> State.unique(),
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
  A grant an agent proposes (`mwt propose`), checked as the add form
  checks yours (`MWTClient.Sandbox.Proposal`): a token or network grant,
  or a subgrant of a grant that takes them. Returns the grant to save
  (off, disabled on startup, to review), the ask the agent waits on, and
  the proposal of the same name it replaces, still to review, or nil.
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
        with {:ok, target} <- target(state, wanted),
             :ok <- script_given(target, ask),
             {:ok, preset} <- proposed_preset(state, target, ask),
             previous = previous(state, target, name),
             :ok <- room(state, previous),
             existing = Enum.reject(state.grants, &(previous && &1.id == previous.id)),
             attrs = Proposal.attrs(target, place(state, target, ask), preset),
             {:ok, grant, _value} <-
               refused(Grants.build_grant(attrs, existing, preset: preset, proposal: true)) do
          said = %{agent: agent, thread: Approval.thread(ask), reason: reason, minutes: minutes}

          grant = %{
            grant
            | id: (previous && previous.id) || grant.id,
              proposal: Proposal.stamp(said, State.now()),
              state: :off,
              start: :off,
              expires_at: nil,
              allowances: []
          }

          {:ok, grant, proposal_ask(grant, target, said, previous), previous}
        end
    end
  end

  defp target(state, wanted) do
    case Proposal.target(wanted, state.grants) do
      {:error, reason} -> {:error, reason}
      target -> {:ok, target}
    end
  end

  # A command subgrant is its script: none, and there is nothing to read.
  defp script_given({:under, %Grant{kind: :command}}, ask) do
    if ask |> Map.get(:script) |> State.to_text() |> String.trim() == "",
      do: {:error, :no_script},
      else: :ok
  end

  defp script_given(_target, _ask), do: :ok

  # A preset a new grant starts from, MWT's or yours, of its own type.
  defp proposed_preset(state, {:new, kind}, ask) do
    case ask |> Map.get(:preset) |> State.to_text() |> String.trim() do
      "" ->
        {:ok, nil}

      id ->
        case Presets.find(id, state.username) do
          {:ok, %{id: id, kind: ^kind} = preset} when is_binary(id) -> {:ok, preset}
          _other -> {:error, {:no_preset, id, kind}}
        end
    end
  end

  defp proposed_preset(_state, _target, _ask), do: {:ok, nil}

  # The proposal of the same name, under the same grant, still to review:
  # proposing again changes it.
  defp previous(state, target, name) do
    parent = with {:under, %Grant{id: id}} <- target, do: id
    parent = if is_binary(parent), do: parent, else: nil

    Enum.find(
      state.grants,
      &(Grant.to_review?(&1) and &1.parent == parent and
          String.downcase(&1.name) == String.downcase(name))
    )
  end

  defp room(state, nil) do
    if Enum.count(state.grants, &Grant.to_review?/1) >= @max_to_review,
      do: {:error, :too_many_proposals},
      else: :ok
  end

  defp room(_state, _previous), do: :ok

  # A command subgrant runs in the folder the agent names, as this
  # machine has it: a shared folder's path, or your home folder.
  defp place(state, {:under, %Grant{kind: :command}}, ask) do
    asked = ask |> Map.get(:dir) |> State.to_text() |> String.trim()
    shares = state.settings.shares ++ HostCommand.halves(ShareSync.root(state))
    dir = asked |> HostCommand.place(shares, System.user_home!()) |> elem(1)
    Map.put(ask, :dir, dir)
  end

  defp place(_state, _target, ask), do: ask

  defp refused({:ok, grant, value}), do: {:ok, grant, value}
  defp refused({:error, errors}), do: {:error, {:proposal, Proposal.refusal(errors)}}

  # The ask the agent waits on: answered once you accept the grant and it
  # turns on; declining it removes the proposal.
  defp proposal_ask(grant, target, said, previous) do
    parent_name = with {:under, %Grant{name: name}} <- target, do: name

    %Approval{
      id: "ask-" <> State.unique(),
      kind: :activation,
      grant_id: grant.id,
      title: "Review #{grant.name}",
      agent: said.agent,
      thread: said.thread,
      minutes: said.minutes,
      reason: said.reason,
      pattern: "propose #{grant.id}",
      proposal: %{
        kind: grant.kind,
        parent_name: if(is_binary(parent_name), do: parent_name),
        updated: previous != nil
      },
      requested_at: State.now(),
      deadline: DateTime.add(State.now(), @activation_hold_seconds, :second),
      claims: [{"Reason", said.reason}, {"It is for", grant.purpose}]
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
    |> State.log(HostRuns.command_event(approval, "output kept: you didn't release it in time"))
  end

  def give_up(state, approval) do
    minutes = approval.deadline |> DateTime.diff(approval.requested_at) |> div(60) |> max(1)

    state
    |> settle(approval, :timed_out, nil)
    |> answer_waiters(approval, {:deny, :timed_out})
    |> State.log(event_for(approval, :timed_out, "gave up after #{minutes} min"))
  end

  @doc """
  Marks an approval decided. The history keeps the last 100, and a command still running stays in sight whatever is decided meanwhile.
  """
  def settle(state, approval, status, decision) do
    approval = %{approval | status: status, decision: decision, decided_at: State.now()}

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
  Denies every use waiting on a grant, as when the grant turns off.
  """
  def settle_waiting(state, grant_id, decision, kinds \\ [:request, :connection, :tool]) do
    state.approvals
    |> Enum.filter(&(&1.status == :waiting and &1.grant_id == grant_id and &1.kind in kinds))
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> settle(approval, :denied, decision)
      |> answer_waiters(approval, {:deny, :grant_off})
      |> State.log(event_for(approval, :refused, "its grant turned off"))
    end)
  end

  @doc """
  The log's event for what became of an approval.
  """
  def event_for(%Approval{kind: :command} = approval, _outcome, how),
    do: HostRuns.command_event(approval, how)

  def event_for(approval, outcome, how) do
    Map.merge(Event.asked_by(approval.agent, approval.thread), %{
      outcome: outcome,
      summary: "#{approval.title} · #{how}",
      host: approval.host,
      port: event_port(approval),
      grant_id: approval.grant_id,
      method: approval.method,
      path: approval.path,
      exchange_id: is_map(approval.request) && Map.get(approval.request, :exchange)
    })
  end

  defp event_port(%Approval{kind: kind}) when kind in [:connection, :tool], do: nil
  defp event_port(%Approval{request: %{port: port}}) when is_integer(port), do: port
  defp event_port(_approval), do: 443
end
