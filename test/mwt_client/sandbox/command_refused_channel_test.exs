defmodule MWTClient.Sandbox.CommandRefusedChannelTest do
  @moduledoc """
  What the agent hears of a run MWT didn't carry out, through `mwt` in the
  VM: refused because its grant was turned off, removed or edited while it
  waited, never read as the user declining; and a run whose exit status
  is unknown, whose output comes back with MWT's own status.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Approval, Server}
  alias MWTClient.Vault.Store

  # Asks without waiting for the user: `mwt wait` hears the rest.
  defp asked(context, args) do
    {output, 120} = mwt(context, args)
    [_, id] = Regex.run(~r/mwt wait (run-\S+)/, output)
    id
  end

  test "a command the agent wrote is refused once you lock your machine while it waits",
       context do
    marker = Path.join(context.project, "ran-after-off")

    id = asked(context, ["run", "--reason", "r", "--wait", "0", "--", "touch #{marker}"])

    # No grant gives it, so none can be turned off: the lock stops it.
    :ok = Sandbox.lock(context.username, :machine)
    assert {:error, :not_waiting} = Sandbox.decide(context.username, id, {:run, :send})

    {output, 121} = mwt(context, ["wait", id, "--wait", "5"])
    assert output =~ "It didn't run"
    refute output =~ "declined"
    refute File.exists?(marker)
  end

  test "a confined action removed while its call waits doesn't run", context do
    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "peek",
        "purpose" => "Shows whether the home is in reach",
        "script" => ~S[cat "$HOME/mine" 2>/dev/null || echo "no home"],
        "dir" => context.project,
        "confined" => "true"
      })

    {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)
    id = asked(context, ["call", grant.id, "--reason", "r", "--wait", "0"])
    :ok = Sandbox.delete_grant(context.username, grant.id)

    {output, 121} = mwt(context, ["wait", id, "--wait", "5"])
    assert output =~ "It didn't run: #{grant.id} no longer allowed it"
  end

  test "an action edited while its call waits: the agent hears it changed", context do
    attrs = %{
      "kind" => "command",
      "name" => "hello",
      "purpose" => "Says hello",
      "script" => "echo hello",
      "dir" => context.project
    }

    {:ok, grant} = Sandbox.create_grant(context.username, attrs)
    {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)
    id = asked(context, ["call", grant.id, "--reason", "r", "--wait", "0"])
    {:ok, _} = Sandbox.update_grant(context.username, grant.id, %{attrs | "script" => "echo bye"})

    {output, 121} = mwt(context, ["wait", id, "--wait", "5"])
    assert output =~ "the user edited #{grant.id} while this waited"
  end

  test "a run whose exit status is unknown brings its output back, with MWT's status",
       context do
    server = Store.whereis(Server, context.username)
    now = DateTime.utc_now()

    # As `MWTClient.Sandbox.HostRun` reports a run something it started
    # kept the output of: over, its status unknown.
    approval = %Approval{
      id: "run-unknown",
      kind: :command,
      grant_id: nil,
      script_from: :agent,
      title: "make serve",
      script: "make serve",
      status: :allowed,
      decision: {:run, :send},
      requested_at: now,
      decided_at: now,
      deadline: DateTime.add(now, 600),
      run: %{
        state: :done,
        output_to: :send,
        started_at: now,
        finished_at: now,
        exit: nil,
        output: "serving on :4100\n",
        bytes: 17,
        cut: 0,
        stopped: false,
        timed_out: false,
        error: nil,
        status: nil,
        findings: [],
        held: false
      }
    }

    :sys.replace_state(server, &%{&1 | approvals: [approval | &1.approvals]})

    # Its output, and a line saying the status is unknown, with 121: "its
    # output didn't come back" as a status, rather than the CLI's 1.
    {output, 121} = mwt(context, ["wait", "run-unknown", "--wait", "5"])
    assert output =~ "serving on :4100"
    assert output =~ "its exit status is unknown"
  end
end
