defmodule MWTClient.QaProbes.Grants.CheckWindowTest do
  @moduledoc """
  Probe: "Checks: Only while…" run "before the grant turns on". With a
  result from earlier that held, does a grant turned on now let uses
  through while its check runs again, and fails?
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-check-window")
  end

  defp request(grant) do
    %{
      host: "api.example.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }
  end

  defp result(username, id) do
    Enum.find_value(1..500, fn _ ->
      case Sandbox.checks(username, id) |> Map.values() do
        [%{result: %{} = result, running?: false}] -> result
        _ -> Process.sleep(20) && nil
      end
    end)
  end

  test "a grant turned on uses an earlier pass while today's check runs and fails",
       %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Prod",
        "purpose" => "Prod API",
        "hosts" => "api.example.com",
        "env" => "TOK",
        "source" => "stored",
        "value" => "value-that-the-fence-allows-01"
      })

    {:ok, _} =
      Sandbox.add_check(username, grant.id, %{
        "name" => "the token can't push to main",
        "script" => ~s(sleep 2; test "$TOK" = value-that-the-fence-allows-01)
      })

    assert %{ok?: true} = result(username, grant.id)

    # Later the value changes (rotated), and you turn the grant on.
    :ok = Sandbox.set_value(username, grant.id, "value-the-fence-would-refuse-02")
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)

    verdict = Server.call(username, {:authorize, request(grant)}, 15_000)
    IO.inspect(elem(verdict, 0), label: "a request right after turning on")
    assert {:forward, replace, _} = verdict
    assert [%{to: "value-the-fence-would-refuse-02"}] = replace.request

    assert %{ok?: false} = result(username, grant.id)
    snapshot_grant = Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id))
    IO.inspect(snapshot_grant.state, label: "the grant once its check failed")
  end
end
