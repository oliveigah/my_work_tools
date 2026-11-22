defmodule MWTClient.Sandbox.Server.HostRuns do
  @moduledoc """
  Commands on this machine, in the sandbox server's state: an agent's ask
  checked against its command grant and held as an approval, the run once
  you approve it, its output and how it ended, and stopping it.

  `MWTClient.Sandbox.HostCommand` checks and describes an ask and
  `MWTClient.Sandbox.HostRun` runs one; this keeps the server's record of
  both. Runs in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{
    Approval,
    Event,
    Grant,
    HostRun,
    Inbound,
    Param,
    Policy,
    SavedRequest,
    Shares
  }

  alias MWTClient.Sandbox.Server.{Approvals, Firewall, ShareSync, State, Values}

  # A command waits as long for your go-ahead, and once it ran with its
  # output for you, as long again for you to release it.
  @command_hold_seconds 30 * 60
  @max_waiting_commands 10

  @doc """
  The command grant an ask goes through: Ask to run commands, built in and off
  until you turn it on, takes the agent's text; a saved command runs your
  text, in its folder, and takes none from the agent.
  """
  def command_grant(state, ask) do
    case Policy.decide(
           State.policy(state),
           {:command, ask},
           State.now()
         ) do
      {:ask, grant, %{script: nil}} ->
        # Values belong to a subgrant's parameters: the text here is the agent's.
        if Map.get(ask, :values) in [nil, %{}],
          do: {:ok, grant, ask, []},
          else: {:error, {:takes_no_values, grant.id}}

      {:ask, grant, about} ->
        # A call is checked before it waits or runs.
        case Param.check(grant.params, Map.get(ask, :values)) do
          {:ok, values} ->
            {:ok, grant, Map.put(ask, :script, about.script), [folder: about.dir, values: values]}

          {:error, problem} ->
            {:error, {:values, grant, problem}}
        end

      {:refuse, {:grant_off, grant}} ->
        {:error, {:grant_off, grant.id}}

      {:refuse, {:check_failing, grant, why}} ->
        {:error, {:check_failing, grant.name, why}}

      {:refuse, {:fixed_script, grant}} ->
        {:error, {:fixed_script, grant.id}}

      {:refuse, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A call of a request subgrant, checked: the subgrant, by its exact id, on,
  under a token grant that lists its host; the values, against its
  parameters; the ask's reason and time limit. Answers what
  `command_approval/3` takes.
  """
  def call_request(state, ask) do
    snapshot = State.policy(state)

    case Policy.decide(snapshot, {:call, ask}, State.now()) do
      {:ask, grant, %{parent: parent}} ->
        with {:ok, values} <- values(grant, ask),
             {:ok, checked} <- SavedRequest.check(ask, grant, parent, values) do
          {:ok, grant, checked}
        end

      {:refuse, {:grant_off, grant}} ->
        {:error, {:grant_off, grant.id}}

      {:refuse, {:wrong_host, parent}} ->
        {:error, {:wrong_host, parent.name}}

      {:refuse, {:check_failing, grant, why}} ->
        {:error, {:check_failing, grant.name, why}}

      {:refuse, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A request subgrant's call (its request, values in place) that would
  send its grant's value to a
  credential endpoint (`MWTClient.Sandbox.Firewall.minting/3`): refused
  before it waits or runs, unless the firewall's rule only alerts.
  `{:pass, state}`, or `{{:error, reason}, state}`.
  """
  def minting(state, %Grant{kind: :request} = grant, call) do
    host = SavedRequest.host(grant)
    path = call.url |> URI.parse() |> Map.get(:path)
    parent = Enum.find(state.grants, &(&1.id == grant.parent))

    with entry when is_binary(entry) <-
           MWTClient.Sandbox.Firewall.minting(Firewall.of(state), host, path),
         {verdict, state} when verdict != :pass <-
           Firewall.observe(state, {:mint, parent.name, host, entry}) do
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
  Sends a request subgrant's call that you approved, or that went through
  without asking: its grant's value is fetched (minted when it has to be),
  and the request goes out in a task, which reports as a command's run
  does. With no value to send, it ends there, and the agent hears why.
  """
  def send_call(state, %Approval{call: call} = approval) do
    grant = State.grant_of(state, approval)
    parent = grant && Enum.find(state.grants, &(&1.id == grant.parent))

    if is_nil(parent) do
      finished_command(state, approval.id, %{error: "its grant was removed"})
    else
      Values.fetch(state, parent, SavedRequest.host(grant), fn state, result ->
        case result do
          {:ok, value} ->
            name = parent.name
            timeout = approval.timeout

            state
            |> State.used(parent.id)
            |> State.task({:command, approval.id}, fn ->
              SavedRequest.send(call, value, name, timeout)
            end)

          {:error, :no_value} ->
            finished_command(state, approval.id, %{error: "#{parent.name} has no value yet"})

          {:error, message} ->
            finished_command(state, approval.id, %{
              error: "minting #{parent.name}'s token failed: #{message}"
            })
        end
      end)
    end
  end

  @doc """
  Runs a confined command subgrant (`MWTClient.Sandbox.Confine`) once the
  real values of the token grants it names are at hand, fetched one after
  the other (minted where they are). Without one, it ends there, and the
  agent hears why. Each value goes in the variables the VM sees that
  grant's placeholder in, and in its token file, `/mnt/mwt/tokens/<id>`, as
  in the VM.
  """
  def run_confined(state, approval, job, %Grant{} = grant) do
    withs = for id <- grant.with, found = token(state, id), found != nil, do: found

    if length(withs) != length(grant.with) do
      finished_command(state, approval.id, %{error: "a grant it runs with was removed"})
    else
      fetch_all(state, withs, [], fn state, result ->
        case result do
          {:ok, pairs} ->
            server = self()
            id = approval.id
            reads = Map.get(state.settings, :confine_reads)
            job = Map.put(job, :confine, %{confine(grant, pairs) | reads: reads})
            state = Enum.reduce(withs, state, &State.used(&2, &1.id))

            State.task(state, {:command, id}, fn ->
              HostRun.run(job, fn group -> send(server, {:command_started, id, group}) end)
            end)

          {:error, message} ->
            finished_command(state, approval.id, %{error: message})
        end
      end)
    end
  end

  defp token(state, id), do: Enum.find(state.grants, &(&1.id == id and &1.kind == :token))

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
  defp confine(grant, pairs) do
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
      writes: grant.writes_dir,
      values: values ++ paths ++ carried,
      files: files,
      reads: nil,
      path: nil
    }
  end

  @doc """
  The approval a checked command waits as, unless ten already wait.
  """
  def command_approval(state, checked, grant) do
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
         grant_id: grant.id,
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
         script_from: if(grant.script || grant.kind == :request, do: :grant, else: :agent),
         suggest_save: checked[:suggest_save],
         save_for: checked[:save_for],
         saved_as: checked[:saved_as],
         facts:
           [
             {"Grant", grant.name},
             cond do
               grant.kind == :request -> {"Request", "Yours, saved as #{grant.name}"}
               grant.script -> {"Script", "Yours, saved as #{grant.name}"}
               true -> {"Script", "The agent's, exactly as shown"}
             end
           ] ++
             runs_fact(state, grant) ++ checked.facts,
         hints: checked.hints,
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
    grant = State.grant_of(state, approval)

    if grant && (Grant.saved_command?(grant) or grant.kind == :request) &&
         Grant.auto_approved?(grant, State.now()),
       do: Approvals.run(state, approval, :auto, "auto-approved, output to the agent"),
       else: state
  end

  def auto_approve(state, _approval), do: state

  @doc """
  Notes that the command of an approval through Ask to run commands is now the
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
  so. An answer to a request subgrant has every grant's value written out
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
            case token(state, id) do
              %Grant{name: name} -> name
              nil -> id
            end
          end)

        [{"Runs", "Confined, with the value of: #{names}"}]

      grant.confined ->
        [{"Runs", "Confined: no home of yours, your tools read-only"}]

      true ->
        [{"Runs", "As you: your home, your keys and your logins in reach"}]
    end
  end

  defp runs_fact(_state, _grant), do: []

  # What would enter the VM, looked through: an answer to a request
  # subgrant with every grant's value written out first, then shapes; a
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
  def command_event(approval, how) do
    Map.merge(Event.asked_by(approval.agent, approval.thread), %{
      outcome: :command,
      summary: "#{approval.title} · #{how}",
      details: Approval.details(approval, how)
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
      run.stopped -> "stopped by you after #{seconds} s (exit #{run.exit})"
      run.timed_out -> "hit its time limit (exit #{run.exit})"
      true -> "exit #{run.exit} after #{seconds} s"
    end
  end
end
