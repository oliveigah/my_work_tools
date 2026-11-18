defmodule MWTClient.Sandbox.CheckTest do
  @moduledoc """
  A grant's checks (`MWTClient.Sandbox.Check`): what makes one, which
  grants they hold off, and, through the sandbox with a real bubble, that a
  failing one keeps its grant off for every use.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Check, Grant, Policy, Server}

  doctest Check

  @now ~U[2026-11-17 12:00:00Z]

  test "a check needs a name, a script that shows, and a time to run" do
    assert {:ok, %Check{on: [:daily], gates: false}} =
             Check.new(
               %{"name" => "n", "script" => "true", "enable" => "false", "gates" => "false"},
               "c"
             )

    assert {:error, "Say when it runs" <> _} =
             Check.new(
               %{"name" => "n", "script" => "true", "enable" => "false", "daily" => "false"},
               "c"
             )

    assert {:error, "Write the script" <> _} = Check.new(%{"name" => "n", "script" => " "}, "c")
    assert {:error, _} = Check.new(%{"name" => "n", "script" => "echo \u202E"}, "c")
  end

  test "only gating checks hold off; a daily one goes stale after a day" do
    gating = %Check{id: "a", name: "the VPN is up", script: "true"}
    telling = %Check{id: "b", name: "just so you know", script: "false", gates: false}
    grant = %Grant{id: "lan", name: "LAN", kind: :network, checks: [telling, gating]}
    ok = %{at: @now, ok?: true, exit: 0, output: ""}
    bad = %{at: @now, ok?: false, exit: 1, output: ""}

    assert Check.failing([grant], %{{"lan", "a"} => ok, {"lan", "b"} => bad}, @now) == %{}

    later = DateTime.add(@now, 26 * 3600, :second)

    assert Check.failing([grant], %{{"lan", "a"} => ok}, later) == %{
             "lan" => "the VPN is up (not checked for over a day)"
           }

    enable_only = %{grant | checks: [%{gating | on: [:enable]}]}
    assert Check.failing([enable_only], %{{"lan", "a"} => ok}, later) == %{}
    assert Check.due?(gating, ok, later)
    refute Check.due?(gating, ok, @now)
  end

  test "a grant a check holds off refuses every use" do
    grant = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      state: :on,
      placeholder: "ghp_placeholder_0123456789",
      hosts: ["api.github.com"],
      allowances: [%MWTClient.Sandbox.Allowance{id: "a", pattern: :all}]
    }

    request = %{
      host: "api.github.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "token ghp_placeholder_0123456789"}],
      body: ""
    }

    snapshot = Policy.snapshot([grant], %{"github" => "the VPN is up"})

    assert {:refuse, {:check_failing, ^grant, "the VPN is up"}} =
             Policy.decide(snapshot, {:request, request}, @now)

    assert {:allow, _, _, _} =
             Policy.decide(Policy.snapshot([grant]), {:request, request}, @now)

    lan = %Grant{id: "lan", name: "LAN", kind: :network, state: :on, destinations: ["10.0.0.0/8"]}
    held = Policy.snapshot([lan], %{"lan" => "the VPN is up"}) |> Map.put(:own, [])
    assert {:refuse, :private} = Policy.decide(held, {:connection, {10, 1, 2, 3}, 443}, @now)
  end

  describe "through the sandbox" do
    @describetag :bwrap

    setup do
      MWTClient.VaultHelpers.unlocked_identity("checks")
    end

    defp github(username) do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "GitHub",
          "purpose" => "The API",
          "hosts" => "api.github.com",
          "env" => "GH_TOKEN",
          "value" => "ghp_real_value_for_checks"
        })

      grant
    end

    defp request(grant),
      do: %{
        host: "api.github.com",
        method: "GET",
        path: "/user",
        headers: [{"authorization", "token #{grant.placeholder}"}],
        body: ""
      }

    defp ran(username, id) do
      Enum.find_value(1..300, fn _ ->
        checks = Sandbox.checks(username, id)

        if checks != %{} and Enum.all?(checks, fn {_, c} -> c.result && not c.running? end),
          do: checks,
          else: Process.sleep(20) && nil
      end)
    end

    test "a failing gating check keeps the grant off; a passing one lets it go",
         %{username: username} do
      grant = github(username)
      # The check sees the grant's own value.
      {:ok, _} =
        Sandbox.add_check(username, grant.id, %{
          "name" => "the token is the right one",
          "script" =>
            ~S[test "$GH_TOKEN" = ghp_real_value_for_checks && test "$(cat /mnt/mwt/tokens/github)" = ghp_real_value_for_checks]
        })

      assert [%{result: %{ok?: true}}] = Map.values(ran(username, grant.id))

      {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
      ran(username, grant.id)
      assert {:forward, _, _} = Server.call(username, {:authorize, request(grant)})

      {:ok, _} =
        Sandbox.add_check(username, grant.id, %{"name" => "the VPN is up", "script" => "exit 3"})

      checks = ran(username, grant.id)
      assert Enum.any?(checks, fn {_, c} -> c.result.ok? == false and c.result.exit == 3 end)

      # Off, and held off: refused, with its name.
      assert %{state: :off, held_by: "its check “the VPN is up” doesn't hold"} =
               Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id))

      assert {:deny, 403, body} = Server.call(username, {:authorize, request(grant)})
      assert body =~ "mwt_check_failing"
      assert body =~ "the VPN is up"

      assert %{state: :off, held_by: "its check “the VPN is up” doesn't hold"} =
               Enum.find(Server.call(username, :agent_grants), &(&1.id == grant.id))

      assert Enum.any?(Sandbox.events(username), &(&1.summary =~ "check “the VPN is up” failed"))
    end
  end
end
