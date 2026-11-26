defmodule MWTClient.QAProbes.Commands.AgentCommandsTest do
  @moduledoc """
  Probe: Commands agents write (`agent-commands`, Q3). Every run asks: no
  allowance, *allow similar*, start setting, approval mode, edit of the
  built-in grant, or command equal to a saved one lets one run unasked;
  off, agents can't ask; host commands locked, refused at once; never
  handed a credential's real value (env, args, stdin), and its output
  holding one never reaches the VM unheld.

  Each test pulls every lever it can on the grant, then asks to run a
  command the agent wrote, and checks it waits for you and ran nothing.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Grant, Policy, Server}

  @value "ghp_qaRealValue0123456789abcdefABCDEF01"

  setup do
    base = Path.join(System.tmp_dir!(), "qa-agent-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    MWTClient.VaultHelpers.unlocked_identity("qa-agent-cmd")
    |> Map.merge(%{base: base})
  end

  defp written(username, script) do
    ask = %{grant: nil, script: script, dir: nil, reason: "r", agent: "claude"}
    Server.call(username, {:request_command, ask})
  end

  defp final(username, id) do
    case Server.call(username, {:await, id, 10_000}, 15_000) do
      {:ok, approval, _grant} -> approval
      {:pending, approval} -> approval
    end
  end

  defp waiting?(username, id),
    do: Enum.any?(Sandbox.snapshot(username).waiting, &(&1.id == id))

  defp agent_commands(username),
    do: Enum.find(Sandbox.snapshot(username).grants, &Grant.agent_commands?/1)

  test "no lever on the built-in grant lets a written command run unasked", context do
    u = context.username
    marker = Path.join(context.base, "ran")
    assert %Grant{state: :on} = agent_commands(u)

    # Every lever the pages and the API have, tried; what each answers is
    # printed, none must matter.
    tries = [
      set_start_auto: Sandbox.set_start(u, "agent-commands", :auto),
      turn_on_all: Sandbox.turn_on(u, "agent-commands", 60, :all),
      set_mode_all: Sandbox.set_mode(u, "agent-commands", :all),
      allow_all: Sandbox.allow_all(u, "agent-commands", :grant),
      edit_start: Sandbox.update_grant(u, "agent-commands", %{"start" => "auto"}),
      edit_kind:
        Sandbox.update_grant(u, "agent-commands", %{"kind" => "command", "script" => "true"})
    ]

    IO.puts(
      "\n[agent-commands levers] " <> inspect(Enum.map(tries, fn {k, v} -> {k, elem(v, 0)} end))
    )

    grant = agent_commands(u)
    assert grant.kind == :agent_commands
    assert grant.allowances == []
    assert grant.start in [:off, :on]

    {:ok, card} = written(u, "touch #{marker}")
    assert waiting?(u, card.id)
    assert card.grant_id == nil
    refute File.exists?(marker)

    # Only Run, Decline and Simpler fit a command's card.
    for decision <- [:allow_once, {:allow, :all, :grant}, {:allow, :similar, 60}] do
      assert {:error, :bad_decision} = Sandbox.decide(u, card.id, decision)
    end

    :ok = Sandbox.decide(u, card.id, {:run, :send})
    assert %{run: %{exit: 0}} = final(u, card.id)

    # The same text again, right after you ran it: it asks again.
    File.rm!(marker)
    {:ok, again} = written(u, "touch #{marker}")
    assert waiting?(u, again.id)
    refute File.exists?(marker)
  end

  test "a written command equal to a saved one that runs unasked still asks", context do
    u = context.username
    marker = Path.join(context.base, "ran")

    {:ok, saved} =
      Sandbox.create_grant(u, %{
        "kind" => "command",
        "name" => "touch it",
        "purpose" => "Touches a file",
        "script" => "touch #{marker}",
        "dir" => System.user_home!()
      })

    {:ok, _} = Sandbox.set_start(u, saved.id, :auto)

    # The agent's own text, the same as the saved command's, and naming
    # the saved command's id as well as the built-in's and the former ids.
    {:ok, card} = written(u, "touch #{marker}")
    assert waiting?(u, card.id)
    assert card.saved_as == saved.id

    for id <- ["agent-commands", "commands", "any-command"] do
      ask = %{grant: id, script: "touch #{marker}", dir: nil, reason: "r", agent: "claude"}
      assert {:ok, card} = Server.call(u, {:request_command, ask})
      assert waiting?(u, card.id)
    end

    ask = %{grant: saved.id, script: "touch #{marker}", dir: nil, reason: "r", agent: "claude"}
    assert {:error, {:fixed_script, _}} = Server.call(u, {:request_command, ask})
    refute File.exists?(marker)
  end

  test "off: agents can't ask; host commands locked: refused at once", context do
    u = context.username
    {:ok, _} = Sandbox.turn_off(u, "agent-commands")
    assert {:error, {:grant_off, "agent-commands"}} = written(u, "true")

    {:ok, _} = Sandbox.turn_on(u, "agent-commands", 60, :ask)
    :ok = Sandbox.lock(u, :machine)
    assert {:error, {:locked, :machine, _}} = written(u, "true")
  end

  test "a lock while the card waits refuses it at Run", context do
    u = context.username
    marker = Path.join(context.base, "ran")
    {:ok, card} = written(u, "touch #{marker}")
    :ok = Sandbox.lock(u, :machine)
    decided = Sandbox.decide(u, card.id, {:run, :send})
    IO.puts("\n[agent-commands] Run after the lock answers #{inspect(decided)}")
    assert %{run: nil} = final(u, card.id)
    refute File.exists?(marker)
  end

  describe "with a credential holding a real value" do
    setup context do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "GitHub",
          "purpose" => "Reads klife",
          "hosts" => "api.github.com",
          "env" => "GH_TOKEN",
          "value" => @value
        })

      {:ok, grant} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      %{token: grant}
    end

    test "the command's environment, arguments and stdin hold no real value", context do
      u = context.username
      {:ok, card} = written(u, ~S[env; echo "ARGS:$*"; cat; ls /mnt/mwt/tokens 2>&1 | head -3])
      :ok = Sandbox.decide(u, card.id, {:run, :review})
      ran = final(u, card.id)
      output = (ran.run && ran.run.output) || ""
      refute output =~ @value
      refute output =~ ~r/^MWT_(?!WORKSPACE)/m
    end

    test "its output holding the real value waits for you, never sent as it is", context do
      u = context.username
      {head, tail} = String.split_at(@value, 10)
      {:ok, card} = written(u, "printf '%s%s\\n' '#{head}' '#{tail}'")
      :ok = Sandbox.decide(u, card.id, {:run, :send})

      # Held: the agent hears nothing of it until you send it.
      output_card =
        Enum.find_value(1..200, fn _ ->
          Enum.find(Sandbox.snapshot(u).waiting, &(&1.id == card.id and &1.stage == :output)) ||
            (Process.sleep(10) && nil)
        end)

      assert %{run: %{held: true}} = output_card
    end

    # Out of a substring scan's reach: the same value, base64'd. Noted:
    # the command can only print a value it finds on this machine (the
    # user's own gh login, say), and the user approved its text.
    test "base64 of the real value is not seen in a written command's output", context do
      u = context.username
      {head, tail} = String.split_at(@value, 10)
      {:ok, card} = written(u, "printf '%s%s' '#{head}' '#{tail}' | base64 -w0")
      :ok = Sandbox.decide(u, card.id, {:run, :send})
      ran = final(u, card.id)
      IO.puts("\n[agent-commands] base64 output held? #{inspect(ran.run.held)}")
      assert ran.run.output =~ Base.encode64(@value)
    end

    test "a written command holding the real value is refused before any card", context do
      u = context.username
      assert {:error, :firewall} = written(u, "echo #{@value}")
      assert Sandbox.snapshot(u).waiting == []
    end
  end

  test "pure policy: written commands ask whatever the built-in grant holds" do
    now = ~U[2026-11-25 12:00:00Z]
    every = %MWTClient.Sandbox.Allowance{id: "a", pattern: :all, until: nil}

    for state <- [:on], start <- [:off, :on, :auto], allowances <- [[], [every]] do
      grant = %{Grant.agent_commands() | state: state, start: start, allowances: allowances}
      snapshot = %{grants: [grant], own: [], resolve: fn _ -> [] end}

      assert {:ask, nil, _} =
               Policy.decide(snapshot, {:command, %{script: "ls", grant: ""}}, now)
    end
  end
end
