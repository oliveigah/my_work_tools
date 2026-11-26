defmodule MWTClient.Sandbox.AuditTest do
  @moduledoc """
  Every action's line says who or what decided it
  (`MWTClient.Sandbox.Decision`), and keeps what decided it as it was:
  the card you decided, read-only, and the grant's version, whatever
  became of the grant since. The log filters on it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Decision, Grant, Server}

  doctest Decision

  setup do
    MWTClient.VaultHelpers.unlocked_identity("audit")
  end

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value_0123456789"
      })

    grant
  end

  defp request(host, headers \\ []) do
    %{
      host: host,
      method: "GET",
      path: "/user",
      headers: [{"host", host} | headers],
      body: "",
      exchange: "exchange-" <> Integer.to_string(System.unique_integer([:positive]))
    }
  end

  defp waiting(username) do
    Enum.find_value(1..200, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [card | _] -> card
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  defp line(username, pred),
    do: Enum.find(Sandbox.events(username, %{limit: 100}), pred)

  test "a request the Internet's grant lets through says so, with the grant as it was then",
       %{username: username} do
    assert {:forward, _, _} = Server.call(username, {:authorize, request("example.com")})

    event = line(username, &(&1.host == "example.com"))
    assert %{by: :allowance, grant: "internet", version: version} = event.decision
    assert %{origin: %{kind: :start}, pattern: :all} = event.decision.allowance
    assert Decision.by_words(event.decision) == "Auto-approve"
    assert Decision.because(event.decision) == "The grant starts on with Auto-approve"
    assert Decision.allowed?(event.decision, event.outcome)

    # The state it decided in, which tells whether it changed since.
    internet = fn -> Enum.find(Sandbox.snapshot(username).grants, &Grant.internet?/1) end
    assert Decision.version_id(internet.()) == version
    {:ok, _} = Sandbox.set_except(username, "internet", ["paste.example.com"])
    refute Decision.version_id(internet.()) == version
  end

  test "a request you allowed on its card keeps the card, read-only, and says what you chose",
       %{username: username} do
    grant = github(username)
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)

    task =
      Task.async(fn ->
        Server.call(
          username,
          {:authorize,
           request("api.github.com", [{"authorization", "token #{grant.placeholder}"}])},
          :infinity
        )
      end)

    card = waiting(username)
    :ok = Sandbox.decide(username, card.id, :allow_once)
    assert {:forward, _, _} = Task.await(task)

    event = line(username, &(&1.decision[:card] == card.id))
    assert %{by: :you, choice: "you allowed once", grant: id} = event.decision
    assert id == grant.id

    assert %{card: kept, choice: "you allowed once"} = Sandbox.audit_card(username, card.id)

    assert kept.id == card.id and kept.title == card.title

    # The log filters by it.
    assert [%{decision: %{by: :you}}] =
             Sandbox.events(username, %{decided: "you", limit: 10})
             |> Enum.filter(&(&1.decision[:card] == card.id))
  end

  test "a refusal says why, and a card that ran out of time keeps the card", %{
    username: username
  } do
    {:ok, _} = Sandbox.turn_off(username, "internet")
    Server.call(username, {:authorize, request("example.com")})

    refused = line(username, &(&1.host == "example.com"))
    assert %{by: :refused, why: why} = refused.decision
    assert is_binary(why) and why != ""

    assert Enum.all?(
             Sandbox.events(username, %{decided: "refused"}),
             &(&1.decision.by == :refused)
           )
  end

  test "an ask refused before anything ran leaves a line, decided by MWT", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "hello",
        "purpose" => "Says hello",
        "script" => "echo hello",
        "dir" => System.tmp_dir!()
      })

    call = %{grant: grant.id, script: nil, values: %{}, dir: nil, reason: "r", agent: "claude"}
    written = %{call | grant: nil, script: "ls"}

    # Off: the call is refused, and the log says so.
    assert {:error, {:grant_off, _}} = Server.call(username, {:request_command, call})
    off = line(username, &(&1.summary =~ "Call of hello · refused before anything ran"))
    assert %{by: :refused, why: why} = off.decision
    assert why =~ "is off"
    assert off.grant_id == grant.id

    # Host commands locked: a command the agent wrote is refused, logged too.
    :ok = Sandbox.lock(username, :machine)
    assert {:error, {:locked, :machine, _}} = Server.call(username, {:request_command, written})

    assert %{decision: %{by: :refused}} =
             line(username, &(&1.summary =~ "A command the agent wrote · refused"))
  end

  test "a real value in a name the VM chose is refused like one in a value", %{
    username: username
  } do
    github(username)

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "say",
        "purpose" => "Says a word",
        "script" => ~s(echo "$WORD"),
        "params" => "WORD: word: what to say",
        "dir" => System.tmp_dir!()
      })

    ask = %{
      grant: grant.id,
      script: nil,
      values: %{"WORD" => "hi", "ghp_real_value_0123456789" => "x"},
      dir: nil,
      reason: "r",
      agent: "claude"
    }

    assert {:error, :firewall} = Server.call(username, {:call, ask})

    refute Enum.any?(
             Sandbox.events(username, %{limit: 100}),
             &(&1.summary =~ "ghp_real_value_0123456789")
           )
  end

  test "a saved command run unasked names the allowance; one you ran, you", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "hello",
        "purpose" => "Says hello",
        "script" => "echo hello",
        "dir" => System.tmp_dir!()
      })

    ask = %{grant: grant.id, script: nil, values: %{}, dir: nil, reason: "r", agent: "claude"}

    {:ok, _} = Sandbox.set_start(username, grant.id, :auto)
    {:ok, auto} = Server.call(username, {:request_command, ask})
    {:ok, _done, _grant} = Server.call(username, {:await, auto.id, 10_000}, 15_000)

    ran = line(username, &(&1.decision[:settled] == auto.id))
    # The grant's start setting made its standing yes.
    assert %{by: :allowance, allowance: %{origin: %{kind: :start}}} = ran.decision

    {:ok, _} = Sandbox.set_start(username, grant.id, :on)
    {:ok, card} = Server.call(username, {:request_command, ask})
    :ok = Sandbox.decide(username, card.id, {:run, :send})
    {:ok, _done, _grant} = Server.call(username, {:await, card.id, 10_000}, 15_000)

    assert %{decision: %{by: :you, card: id}} = line(username, &(&1.decision[:card] == card.id))
    assert id == card.id
  end
end
