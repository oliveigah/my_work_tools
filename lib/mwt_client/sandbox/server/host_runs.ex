defmodule MWTClient.Sandbox.Server.HostRuns do
  @moduledoc """
  Commands on this machine, in the sandbox server's state: an agent's ask
  checked (a command it wrote, which needs no grant, or a saved command or
  request action, against the grants of every resource it goes through)
  and held as an approval, the run once you approve it, its output and how
  it ended, and stopping it.

  `MWTClient.Sandbox.HostCommand` checks and describes an ask and
  `MWTClient.Sandbox.HostRun` runs one; this keeps the server's record of
  both. Runs in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{
    Approval,
    Credential,
    Event,
    Grant,
    HostRun,
    Inbound,
    Decision,
    Openness,
    Param,
    Pins,
    Policy,
    SavedRequest,
    Shares
  }

  alias MWTClient.Sandbox.Egress.FixedCall
  alias MWTClient.Sandbox.Server.{Approvals, Firewall, ShareSync, State, Values}

  # A command waits as long for your go-ahead, and once it ran with its
  # output for you, as long again for you to release it.
  @command_hold_seconds 30 * 60
  @max_waiting_commands 10

  @doc """
  What an ask to run goes through: a command the agent wrote takes its
  text and asks you about every run, while Commands agents write is on
  (`{:ok, nil, ask, []}`); a saved command, named by its id, runs your
  text in its folder, takes none from the agent, and its own grant
  decides, for the credentials it runs with too
  (`MWTClient.Sandbox.Policy`).
  """
  def command_grant(state, ask) do
    case Policy.decide(
           State.policy(state),
           {:command, ask},
           State.now()
         ) do
      {:ask, nil, _about} ->
        # Values belong to an action's parameters: the text here is the agent's.
        if Map.get(ask, :values) in [nil, %{}],
          do: {:ok, nil, ask, []},
          else: {:error, {:takes_no_values, "commands"}}

      {:refuse, {:grant_off, grant}} ->
        {:error, {:grant_off, grant.id}}

      {:refuse, {:fixed_script, grant}} ->
        {:error, {:fixed_script, grant.id}}

      {:refuse, reason} ->
        {:error, reason}

      _goes_or_asks ->
        grant = Enum.find(state.grants, &(&1.kind == :command and &1.id == id_of(ask)))

        # A call is checked before it waits or runs.
        case Param.check(grant.params, Map.get(ask, :values)) do
          {:ok, values} ->
            {:ok, grant, Map.put(ask, :script, grant.script), [folder: grant.dir, values: values]}

          {:error, problem} ->
            {:error, {:values, grant, problem}}
        end
    end
  end

  defp id_of(ask), do: ask |> Map.get(:grant) |> State.to_text() |> String.trim()

  @doc """
  A call of a request action, checked: the action, by its exact id, its
  credential and the network of its host given by grants that are on
  (`MWTClient.Sandbox.Policy`); the values, against its parameters; the
  ask's reason and time limit. Answers what `command_approval/3` takes.
  """
  def call_request(state, ask) do
    snapshot = State.policy(state)

    case Policy.decide(snapshot, {:call, ask}, State.now()) do
      {:refuse, {:grant_off, grant}} ->
        {:error, {:grant_off, grant.id}}

      {:refuse, reason} ->
        {:error, reason}

      _goes_or_asks ->
        grant = Enum.find(state.grants, &(&1.kind == :request and &1.id == id_of(ask)))

        with {:ok, values} <- values(grant, ask),
             {:ok, checked} <-
               SavedRequest.check(ask, grant, credential_name(state, grant), values) do
          {:ok, grant, checked}
        end
    end
  end

  # The name of the credential a request action sends with.
  defp credential_name(state, grant) do
    id = Grant.credential_id(grant)
    Enum.find_value(Map.get(state, :credentials, []), id, &(&1.id == id && &1.name))
  end

  @doc """
  A request action's call (its request, values in place) that would
  send its grant's value to a
  credential endpoint (`MWTClient.Sandbox.Firewall.minting/3`): refused
  before it waits or runs, unless the firewall's rule only alerts.
  `{:pass, state}`, or `{{:error, reason}, state}`.
  """
  def minting(state, %Grant{kind: :request} = grant, call) do
    host = SavedRequest.host(grant)
    path = call.url |> URI.parse() |> Map.get(:path)

    with entry when is_binary(entry) <-
           MWTClient.Sandbox.Firewall.minting(Firewall.of(state), host, path),
         {verdict, state} when verdict != :pass <-
           Firewall.observe(state, {:mint, credential_name(state, grant), host, entry}) do
      {{:error, {:credential_endpoint, host, entry}}, state}
    else
      nil -> {:pass, state}
      {:pass, state} -> {:pass, state}
    end
  end

  defp values(grant, ask) do
    case Param.check(grant.params, Map.get(ask, :values)) do
      {:ok, values} -> {:ok, values}
      {:error, problem} -> {:error, {:values, grant, problem}}
    end
  end

  @doc """
  Whether a command or a call that waited may be carried out now, as it
  was asked: `:ok`, or why not. Its grant is still there, on by the clock,
  held off by no check, under the definition it was asked under
  (`Grant.definition/1`, `:changed` otherwise); a request action's token
  grant still lists its host; and the VM isn't isolated. It is the same
  decision as when it was asked (`MWTClient.Sandbox.Policy`), taken again:
  a card can wait 30 minutes, and what you turned off, edited or removed
  meanwhile is what holds.
  """
  @spec still(map(), Approval.t()) :: :ok | {:refused, :grant_off | :changed | :isolated}
  def still(state, %Approval{kind: :command} = approval) do
    grant = State.grant_of(state, approval)
    agents? = approval.script_from == :agent

    cond do
      Firewall.isolated?(state) ->
        {:refused, :isolated}

      is_nil(grant) and not agents? ->
        {:refused, :grant_off}

      Pins.changed(approval.pins) != [] ->
        {:refused, :pin_changed}

      grant && Approval.digest(Grant.definition(grant)) != approval.definition ->
        {:refused, :changed}

      true ->
        case Policy.decide(State.policy(state), use_of(approval), State.now()) do
          {:refuse, {:locked, _resource, _grant}} -> {:refused, :locked}
          {:refuse, _why} -> {:refused, :grant_off}
          _goes_or_asks -> :ok
        end
    end
  end

  # The use a card holds, as the policy decides one: a call by its
  # action's id; a command with the agent's text, or none for a saved
  # command, whose text is the grant's.
  defp use_of(%Approval{call: %{}} = approval), do: {:call, %{grant: approval.grant_id}}

  defp use_of(%Approval{script_from: :grant} = approval),
    do: {:command, %{grant: approval.grant_id, script: nil}}

  defp use_of(%Approval{} = approval),
    do: {:command, %{grant: approval.grant_id, script: approval.script}}

  @doc "Why a card that waited wasn't carried out, in the log's words and the run's."
  @spec refused_words(:grant_off | :changed | :isolated | :locked) :: String.t()
  def refused_words(:grant_off),
    do:
      "not carried out: a grant it needs no longer gives it (off, out of time, removed, " <>
        "or no longer covering it)"

  def refused_words(:changed),
    do:
      "not carried out: its grant was edited while it waited, so the card no longer says what would run"

  def refused_words(:isolated), do: "not carried out: the VM is isolated"

  def refused_words(:pin_changed),
    do:
      "not carried out: a file it runs changed since you approved it (MWTClient.Sandbox.Pins); ask again to see it as it is now"

  def refused_words(:locked), do: "not carried out: you locked what it reaches"

  # How a saved command runs, fixed into its card as it is asked: what the
  # card says, and what Run then does.
  defp confine_of(%Grant{kind: :command, script: script} = grant) when is_binary(script),
    do: %{confined: grant.confined, with: grant.with, writes_dir: grant.writes_dir}

  defp confine_of(_grant), do: nil

  @doc """
  Sends a request action's call that you approved, or that went through
  without asking: its grant's value is fetched (minted when it has to be),
  and the request goes out in a task, which reports as a command's run
  does. With no value to send, it ends there, and the agent hears why.
  It goes only while the action still allows it (`still/2`), looked at
  before the value is fetched and again once it is at hand: a mint takes
  up to 30 seconds, and a value never goes out after its grant stopped
  allowing it.
  """
  def send_call(state, %Approval{call: call} = approval) do
    grant = State.grant_of(state, approval)

    case still(state, approval) do
      {:refused, why} ->
        finished_command(state, approval.id, %{error: refused_words(why)})

      :ok ->
        fetch_and_send(state, approval, call, grant)
    end
  end

  # The action carries its credential's fields (`Credential.attach/2`):
  # its value is fetched, or minted, as any grant over the credential's.
  defp fetch_and_send(state, approval, call, grant) do
    Values.fetch(state, grant, SavedRequest.host(grant), fn state, result ->
      case {result, still(state, approval)} do
        {_result, {:refused, why}} ->
          finished_command(state, approval.id, %{error: refused_words(why)})

        {{:ok, value}, :ok} ->
          name = credential_name(state, grant)
          timeout = approval.timeout
          needs = SavedRequest.needs(call.headers)

          id_token =
            if needs.id_token, do: Values.id_token_of(state, grant, SavedRequest.host(grant))

          adapter = MWTClient.Sandbox.Adapter.of(grant)
          signing = SavedRequest.accounts(call, grant)

          cond do
            needs.id_token and is_nil(id_token) ->
              finished_command(state, approval.id, %{
                error: "#{name}'s mint gave no ID token: it must print one beside its value"
              })

            match?({:error, _}, signing) ->
              finished_command(state, approval.id, %{error: elem(signing, 1)})

            true ->
              {:ok, accounts} = signing
              username = state.username

              # The call's mark, for the proxy it goes through: the action
              # covers its credential in this request alone, and goes out
              # as the agent's own would (`MWTClient.Sandbox.Egress.FixedCall`).
              mark = %{
                grant_id: grant.id,
                card: approval.id,
                name: grant.name,
                definition: approval.definition,
                network: Policy.network_of_host(State.policy(state), SavedRequest.host(grant))
              }

              state
              |> State.used(grant.id)
              |> State.task({:command, approval.id}, fn ->
                # Signed here, off the server's process: Google answers in
                # its own time.
                case sign_all(adapter, value, accounts, needs.accounts, call) do
                  {:ok, jwts} ->
                    values = %{token: value, id_token: id_token, jwts: jwts}
                    {built, swaps} = SavedRequest.build(call, values, name)
                    FixedCall.send(username, built, Map.put(mark, :swaps, swaps), timeout)

                  {:error, message} ->
                    %{
                      exit: nil,
                      status: nil,
                      output: "",
                      bytes: 0,
                      cut: 0,
                      timed_out: false,
                      error: message
                    }
                end
              end)
          end

        {{:error, :no_value}, :ok} ->
          finished_command(state, approval.id, %{
            error: "#{credential_name(state, grant)} has no value yet"
          })

        {{:error, message}, :ok} ->
          finished_command(state, approval.id, %{
            error: "minting #{credential_name(state, grant)}'s token failed: #{message}"
          })
      end
    end)
  end

  # The JWTs a call sends, each signed as its account for the call's URL,
  # keyed as its header names it (`:one` for `{signed_jwt}`).
  defp sign_all(_adapter, _value, [], _marks, _call), do: {:ok, %{}}

  defp sign_all(adapter, value, accounts, marks, call) do
    aud = SavedRequest.audience(call)

    Enum.zip(marks, accounts)
    |> Enum.reduce_while({:ok, %{}}, fn {mark, account}, {:ok, acc} ->
      case adapter.sign_jwt(value, account, aud, DateTime.utc_now()) do
        {:ok, jwt} -> {:cont, {:ok, Map.put(acc, mark, jwt)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  @doc """
  Runs a confined saved command (`MWTClient.Sandbox.Confine`) once the
  real values of the credentials it names are at hand, fetched one after
  the other (minted where they are). The saved command is the grant for
  them: a fixed call covers the credentials it names, and no other grant
  over them has a say. A credential gone since, it ends there, and the
  agent hears why. Each value goes in the variables the VM sees that
  credential's placeholder in, and in its token file,
  `/mnt/mwt/tokens/<id>`, as in the VM. `confine` is how its card says it
  runs (`Approval.confine`), fixed as it was asked.
  """
  def run_confined(state, approval, job, %{with: with} = confine) do
    withs = for id <- with, found = credential_view(state, id), found != nil, do: found

    if length(withs) != length(with) do
      finished_command(state, approval.id, %{
        error: "a credential it runs with is gone: #{Enum.join(with, ", ")}"
      })
    else
      fetch_all(state, withs, [], fn state, result ->
        case result do
          {:ok, pairs} ->
            server = self()
            id = approval.id
            reads = Map.get(state.settings, :confine_reads)
            job = Map.put(job, :confine, %{confine(confine, pairs) | reads: reads})

            State.task(state, {:command, id}, fn ->
              HostRun.run(job, fn group -> send(server, {:command_started, id, group}) end)
            end)

          {:error, message} ->
            finished_command(state, approval.id, %{error: message})
        end
      end)
    end
  end

  # Credential `id` as a grant over it reads, for its value to be fetched
  # (`Credential.attach/2`): where it comes from and how it is minted are
  # the credential's. Nil once it is gone.
  defp credential_view(state, id) do
    case Enum.find(Map.get(state, :credentials, []), &(&1.id == id)) do
      nil ->
        nil

      credential ->
        Credential.attach(%Grant{id: id, name: credential.name, kind: :token}, credential)
    end
  end

  defp fetch_all(state, [], pairs, k), do: k.(state, {:ok, Enum.reverse(pairs)})

  defp fetch_all(state, [grant | rest], pairs, k) do
    Values.fetch(state, grant, fn state, result ->
      case result do
        {:ok, value} ->
          fetch_all(state, rest, [{grant, value} | pairs], k)

        {:error, :no_value} ->
          k.(state, {:error, "#{grant.name} has no value yet"})

        {:error, message} ->
          k.(state, {:error, "minting #{grant.name}'s token failed: #{message}"})
      end
    end)
  end

  # What the bubble gets: the values under the grants' variables, each
  # token file written from a variable unset before the script runs.
  defp confine(%{writes_dir: writes_dir}, pairs) do
    indexed = Enum.with_index(pairs, 1)

    values =
      for {{with, value}, _n} <- indexed, name <- with.env, do: {name, value}

    paths =
      for {{with, _value}, _n} <- indexed,
          name <- with.file_env,
          do: {name, Grant.token_file(with)}

    carried = for {{_with, value}, n} <- indexed, do: {"MWT_FILE_#{n}", value}
    files = for {{with, _value}, n} <- indexed, do: {"MWT_FILE_#{n}", Grant.token_file(with)}

    %{
      writes: writes_dir,
      values: values ++ paths ++ carried,
      files: files,
      reads: nil,
      path: nil
    }
  end

  @doc """
  The approval a checked command waits as, unless ten already wait.
  `grant` is the saved command or request action it runs, nil for a
  command the agent wrote.
  """
  def command_approval(state, checked, grant) do
    pins = Map.get(checked, :pins, [])
    moved = moved(grant, pins)

    waiting =
      Enum.filter(state.approvals, &(&1.status == :waiting and &1.kind == :command))

    if length(waiting) >= @max_waiting_commands and
         not Enum.any?(waiting, &(&1.pattern == checked.pattern)) do
      {:error, :too_many}
    else
      {:ok,
       %Approval{
         id: "run-" <> State.unique(),
         kind: :command,
         grant_id: grant && grant.id,
         title: checked.title,
         agent: checked.agent,
         thread: checked.thread,
         reason: checked.reason,
         script: checked.script,
         dir: checked.dir,
         timeout: checked.timeout,
         pattern: checked.pattern,
         values: checked.values,
         call: checked[:call],
         definition: grant && Approval.digest(Grant.definition(grant)),
         confine: confine_of(grant),
         script_from: if(grant, do: :grant, else: :agent),
         suggest_save: checked[:suggest_save],
         save_for: checked[:save_for],
         saved_as: checked[:saved_as],
         facts:
           cond do
             is_nil(grant) ->
               [{"Script", "The agent's, exactly as shown"}]

             grant.kind == :request ->
               [{"Grant", grant.name}, {"Request", "Yours, saved as #{grant.name}"}]

             true ->
               [{"Grant", grant.name}, {"Script", "Yours, saved as #{grant.name}"}]
           end ++
             runs_fact(state, grant) ++ openness_fact(grant) ++ checked.facts,
         hints: checked.hints,
         pins: pins,
         repin: moved != [],
         warnings: moved_warnings(grant, moved) ++ Map.get(checked, :warnings, []),
         claims:
           [{"Reason", checked.reason}] ++
             if(checked[:suggest_save],
               do: [{"Save it as", checked.suggest_save}, {"Saved, it is for", checked.save_for}],
               else: []
             ),
         requested_at: State.now(),
         deadline: DateTime.add(State.now(), @command_hold_seconds, :second)
       }}
    end
  end

  @doc """
  The same script, directory and limit as one waiting for its go-ahead
  joins it.
  """
  def hold_command(state, approval) do
    case Enum.find(state.approvals, fn other ->
           other.status == :waiting and other.kind == :command and other.stage == :run and
             other.pattern == approval.pattern
         end) do
      %Approval{} = waiting ->
        joined = %{waiting | retries: waiting.retries + 1}
        {State.replace_approval(state, joined), joined}

      nil ->
        Process.send_after(
          self(),
          {:give_up, approval.id, approval.deadline},
          @command_hold_seconds * 1_000
        )

        {State.change(state, :approvals, &[approval | &1.approvals]), approval}
    end
  end

  @doc """
  A command just held as an approval: run at once, its output sent to the
  agent, when it is a saved command you turned on with Auto-approve. Ask
  to run commands always waits for you.
  """
  def auto_approve(state, %Approval{kind: :command, stage: :run, status: :waiting} = approval) do
    # A saved command or a call goes unasked only when every resource it
    # goes through lets it through unasked (`MWTClient.Sandbox.Policy`): a
    # command the agent wrote never does.
    if approval.script_from == :grant and not approval.repin and
         match?(
           {:allow, _, _, _},
           Policy.decide(State.policy(state), use_of(approval), State.now())
         ),
       do: Approvals.run(state, approval, :auto, "auto-approved, output to the agent"),
       else: state
  end

  def auto_approve(state, _approval), do: state

  @doc """
  What let a card's command or call run unasked (`auto_approve/2`): the
  allowance of its grant that covers it, as the policy decides it now
  (`MWTClient.Sandbox.Decision`); nil when none does any more.
  """
  def auto_decision(state, approval) do
    case Policy.decide(State.policy(state), use_of(approval), State.now()) do
      {:allow, grant, allowance, _about} -> Decision.allowance(grant, allowance)
      _other -> nil
    end
  end

  @doc """
  Notes that the command an agent wrote, on an approval, is now the
  saved command `grant`: its card says so, and the agent hears, with the
  run's answer, to run it by name next time.
  """
  def saved(state, approval_id, grant) do
    case Enum.find(state.approvals, &(&1.id == approval_id and &1.kind == :command)) do
      %Approval{script_from: :agent} = approval ->
        state =
          state
          |> State.replace_approval(%{approval | saved_as: grant.id})
          |> State.log(command_event(approval, "you saved it as #{grant.name}"))
          |> State.changed()

        {:ok, state}

      _other ->
        {:error, :not_found}
    end
  end

  # A command that ran in a shared folder, or in the workspace's to-vm,
  # may have left files there: that one is synced, so they reach the VM's
  # copy. `mwt sync` waits for it.
  defp sync_its_share(state, %Approval{dir: dir}) when is_binary(dir) do
    case Enum.find(ShareSync.shared(state), &Shares.within?(dir, &1)) do
      path when is_binary(path) -> ShareSync.request(state, [path])
      nil -> state
    end
  end

  defp sync_its_share(state, _approval), do: state

  @doc """
  Takes a run's result: the output goes to the agent, or waits for you
  first when you asked to see it, or when it holds a credential
  (`MWTClient.Sandbox.Inbound`): a token grant's real value in a command's
  output always; something shaped like one when the firewall's rule says
  so. An answer to a request action has every grant's value written out
  as its name first. Auto-approval never lets a held one go.
  """
  def finished_command(state, approval_id, result) do
    state = %{state | running: Map.delete(state.running, approval_id)}

    case Enum.find(state.approvals, &(&1.id == approval_id)) do
      %Approval{run: %{state: :running} = run} = approval ->
        state = sync_its_share(state, approval)
        {output, findings} = inbound(state, approval, result[:output] || "")

        run =
          Map.merge(run, %{
            state: :done,
            finished_at: State.now(),
            exit: result[:exit],
            status: result[:status],
            output: output,
            bytes: result[:bytes] || 0,
            cut: result[:cut] || 0,
            timed_out: result[:timed_out] || false,
            error: result[:error],
            findings: findings
          })

        approval = %{approval | run: run}
        state = State.log(state, command_event(approval, ended_words(run)))
        {held?, state} = hold?(state, approval, findings)

        run =
          Map.merge(run, %{held: held?, output_to: if(held?, do: :review, else: run.output_to)})

        approval = %{approval | run: run}

        # A command that couldn't start has no output worth holding.
        case if(run.error, do: :send, else: run.output_to) do
          :send ->
            state
            |> State.replace_approval(approval)
            |> Approvals.answer_waiters(approval, :allow)

          :review ->
            deadline = DateTime.add(State.now(), @command_hold_seconds, :second)

            Process.send_after(
              self(),
              {:give_up, approval.id, deadline},
              @command_hold_seconds * 1_000
            )

            state
            |> State.replace_approval(%{
              approval
              | status: :waiting,
                stage: :output,
                deadline: deadline,
                decided_at: nil
            })
        end

      _gone ->
        state
    end
  end

  # How a saved command runs: confined, with which grants' values, or as
  # you, with everything you can reach.
  defp runs_fact(state, %Grant{kind: :command, script: script} = grant) when is_binary(script) do
    cond do
      grant.confined and grant.with != [] ->
        names =
          Enum.map_join(grant.with, ", ", fn id ->
            Enum.find_value(Map.get(state, :credentials, []), id, &(&1.id == id && &1.name))
          end)

        [{"Runs", "Confined, with the value of: #{names}"}]

      grant.confined ->
        [{"Runs", "Confined: no home of yours, your tools read-only"}]

      true ->
        [{"Runs", "As you: your home, your keys and your logins in reach"}]
    end
  end

  defp runs_fact(_state, _grant), do: []

  # The files a saved command runs that changed since it was pinned: as
  # it was saved, or as its last run you allowed found them. Nothing to
  # compare for a command the agent wrote, or one pinned before pins.
  defp moved(%Grant{kind: :command, pins: [_ | _] = pinned}, pins) do
    by_path = Map.new(pinned, &{&1.path, &1})

    for pin <- pins,
        was = Map.get(by_path, pin.path, %{pin | hash: nil, content: ""}),
        was.hash != pin.hash,
        do: {was, pin}
  end

  defp moved(_grant, _pins), do: []

  defp moved_warnings(_grant, []), do: []

  defp moved_warnings(grant, moved) do
    for {was, now} <- moved do
      lines =
        was.content
        |> Pins.diff(now.content)
        |> Enum.map_join("\n", fn {kind, line} ->
          if(kind == :ins, do: "+ ", else: "- ") <> line
        end)

      "#{now.file} changed since #{grant.name} was pinned: this run asks, whatever its setting, and running it pins what is there now." <>
        if(lines == "", do: "", else: "\n" <> lines)
    end
  end

  @doc """
  Pins what a saved command's run found (`Approval.pins`) on its grant, as
  you let that run go: the next run compares against it.
  """
  def repin(state, %Approval{script_from: :grant, pins: pins} = approval) do
    case State.grant_of(state, approval) do
      %Grant{kind: :command} = grant when grant.pins != pins ->
        state |> State.replace_grant(%{grant | pins: pins}) |> State.changed()

      _other ->
        state
    end
  end

  def repin(state, _approval), do: state

  # How open the fixed call is (`MWTClient.Sandbox.Openness`): said on
  # every card it raises, a warning beside the rest, never a decision.
  defp openness_fact(%Grant{} = grant) do
    case Openness.grade(grant) do
      %{grade: grade, why: why} ->
        [
          {"How open",
           Enum.join([Openness.words(grade) <> ": " <> Openness.meaning(grade) | why], " ")}
        ]

      nil ->
        []
    end
  end

  defp openness_fact(nil), do: []

  # What would enter the VM, looked through: an answer to a request
  # action with every grant's value written out first, then shapes; a
  # command's output for values and shapes alike.
  defp inbound(state, approval, output) do
    secrets = Values.secrets(state)
    placeholders = for %Grant{placeholder: p} <- state.grants, is_binary(p), do: p

    {output, look_for} =
      if approval.call, do: {Inbound.scrub(output, secrets), nil}, else: {output, secrets}

    case Inbound.check(output, look_for, placeholders) do
      :ok -> {output, []}
      {:found, findings} -> {output, findings}
    end
  end

  # Whether what was found holds the output for you: a real value always,
  # a shape when the firewall's rule blocks. The firewall hears of each.
  defp hold?(state, _approval, []), do: {false, state}

  defp hold?(state, approval, findings) do
    words = findings |> Enum.map(&Inbound.words/1) |> Enum.join("; ")
    how = if approval.call, do: :call, else: :command

    {verdict, state} = Firewall.observe(state, {:inbound, approval.title, words, how})
    held? = verdict != :pass or Enum.any?(findings, &Inbound.value?/1)

    state =
      if held?,
        do: State.log(state, command_event(approval, "output held for you: #{words}")),
        else: state

    {held?, state}
  end

  @doc """
  The commands that run with a resource (`Policy.resource/1`), which its
  lock stops: every one on your machine, or those a credential's value
  went into (a confined command's `with` names credentials). Commands
  don't run through a network, nor through MWT's tools.
  """
  def running_with(state, :machine), do: Enum.filter(state.approvals, &Approval.running?/1)

  def running_with(state, {:credential, id}) do
    Enum.filter(state.approvals, fn approval ->
      Approval.running?(approval) and id in (get_in(approval.confine || %{}, [:with]) || [])
    end)
  end

  def running_with(_state, {:network, _id}), do: []
  def running_with(_state, :mwt), do: []

  # How long a stopped command has to end on TERM before it is killed.
  @kill_after_ms 5_000

  @doc """
  Stops each of `approvals` that is running: TERM to its process group,
  KILL if it is still there 5 s later, the run marked stopped, and
  `words` logged as why. What isolating the VM or locking what a command
  reaches does to the commands running.
  """
  def stop_running(state, approvals, words) do
    approvals
    |> Enum.filter(&Approval.running?/1)
    |> Enum.reduce(state, fn approval, acc ->
      Process.send_after(self(), {:kill_command, approval.id}, @kill_after_ms)

      acc
      |> State.replace_approval(%{approval | run: %{approval.run | stopped: true}})
      |> stop_group(approval.id, "TERM")
      |> State.log(command_event(approval, "stopped: " <> words))
    end)
  end

  @doc """
  Signals a running command's process group; one that hasn't reported its group yet is stopped as soon as it does.
  """
  def stop_group(state, approval_id, signal) do
    case state.running do
      %{^approval_id => group} when is_integer(group) ->
        HostRun.stop(group, signal)
        state

      %{^approval_id => :stop} ->
        state

      _not_started when signal == "TERM" ->
        # Not reported yet: stopped as soon as it is.
        if Enum.any?(state.approvals, &(&1.id == approval_id and Approval.running?(&1))),
          do: put_in(state.running[approval_id], :stop),
          else: state

      _ended ->
        state
    end
  end

  @doc """
  The log's event for something that happened to a command.
  """
  def command_event(approval, how, decision \\ nil) do
    # A request action's call is no command on your machine: its lines
    # say *Fixed call*, beside the request it sent through the proxy.
    Map.merge(Event.asked_by(approval.agent, approval.thread), %{
      decision: decision,
      outcome: if(approval.call, do: :call, else: :command),
      summary: "#{approval.title} · #{how}",
      details: Approval.details(approval)
    })
  end

  @doc """
  Where a run's output goes, in the log's words.
  """
  def output_words(:send), do: ", output to the agent"

  def output_words(:review), do: ", output to you first"

  defp ended_words(%{error: error}) when is_binary(error),
    do: "couldn't start: #{String.slice(error, 0, 120)}"

  defp ended_words(%{status: status} = run) when is_integer(status) do
    seconds = DateTime.diff(run.finished_at, run.started_at)
    "HTTP #{status} after #{seconds} s"
  end

  defp ended_words(run) do
    seconds = DateTime.diff(run.finished_at, run.started_at)

    cond do
      # Something it started took its output from MWT's reach
      # (`MWTClient.Sandbox.HostRun`): over, with no status to tell.
      is_nil(run.exit) -> "ended after #{seconds} s, its exit status unknown"
      run.stopped -> "stopped by you after #{seconds} s (exit #{run.exit})"
      run.timed_out -> "hit its time limit (exit #{run.exit})"
      true -> "exit #{run.exit} after #{seconds} s"
    end
  end
end
