defmodule MWTClient.Sandbox.LocksTest do
  @moduledoc """
  Locks: what you lock (a credential, a network, your machine) refuses
  every use, whatever its grants say, and no grant changes. Agents can ask
  for a grant, never for a lock to end.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Approval, Gate, Grant, Policy, Server}
  alias MWTClient.Sandbox.Server.{HostRuns, Locks, State}
  alias MWTClient.Vault.Store

  defp server_state(username), do: :sys.get_state(Store.whereis(Server, username))
  defp snapshot(username), do: username |> server_state() |> State.policy()

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("locks")
    %{username: username}
  end

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "Read oliveigah/klife",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value_0123456789"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)
    grant
  end

  defp request(grant) do
    %{
      host: "api.github.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "token " <> grant.placeholder}],
      body: ""
    }
  end

  test "a locked credential's value goes nowhere, its grants unchanged; unlocked, it goes again",
       %{username: username} do
    grant = github(username)
    assert {:forward, _, _} = Server.call(username, {:authorize, request(grant)})

    :ok = Sandbox.lock(username, {:credential, grant.credential})
    assert {:deny, 403, body} = Server.call(username, {:authorize, request(grant)})
    assert body =~ "mwt_locked"
    assert Grant.on?(Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id)))
    assert Map.has_key?(Sandbox.snapshot(username).locks, {:credential, grant.credential})

    # mwt exec says so before anything runs.
    dir = username |> server_state() |> State.inbox_dir()
    script = File.read!(Path.join([dir, "grant-env", grant.credential <> ".sh"]))
    assert script =~ "locked by the user"

    :ok = Sandbox.unlock(username, {:credential, grant.credential})
    assert {:forward, _, _} = Server.call(username, {:authorize, request(grant)})
  end

  test "host commands locked refuses the agent's commands; MWT's own tools, git and sync included, lock apart",
       %{username: username} do
    :ok = Sandbox.lock(username, :machine)

    snapshot = snapshot(username)

    assert {:refuse, {:locked, :machine, _}} =
             Policy.decide(snapshot, {:command, %{script: "ls"}}, DateTime.utc_now())

    # MWT's tools are a resource of their own: notes, diagrams and flash
    # cards, and the projects' git and the shared folders, all MWT's code.
    for use <- [%{grant: :read, tool: "list_notes"}, %{grant: :git_fetch}, %{grant: :share_sync}] do
      refute match?(
               {:refuse, {:locked, _, _}},
               Policy.decide(snapshot, {:tool, use}, DateTime.utc_now())
             )
    end

    :ok = Sandbox.lock(username, :mwt)

    for use <- [%{grant: :read, tool: "list_notes"}, %{grant: :git_fetch}] do
      assert {:refuse, {:locked, :mwt, _}} =
               Policy.decide(snapshot(username), {:tool, use}, DateTime.utc_now())
    end

    :ok = Sandbox.unlock(username, :machine)
    snapshot = snapshot(username)

    assert {:ask, _, _} =
             Policy.decide(snapshot, {:command, %{script: "ls"}}, DateTime.utc_now())
  end

  test "isolating locks every resource, beside yours; releasing ends only the isolation's",
       %{username: username} do
    grant = github(username)
    credential = {:credential, grant.credential}
    :ok = Sandbox.lock(username, :machine)

    :ok = Sandbox.firewall_isolate(username)
    locks = Sandbox.snapshot(username).locks
    assert Locks.holders(locks, credential) == [:isolation]
    assert Locks.holders(locks, {:network, "internet"}) == [:isolation]
    assert Locks.holders(locks, :machine) == [:isolation, :you]
    # No grant changed.
    assert Grant.on?(Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id)))

    # Unlocking yours leaves the isolation's.
    :ok = Sandbox.unlock(username, :machine)
    assert Locks.holders(Sandbox.snapshot(username).locks, :machine) == [:isolation]
    :ok = Sandbox.lock(username, :machine)

    :ok = Sandbox.firewall_release(username, false)
    locks = Sandbox.snapshot(username).locks
    refute Map.has_key?(locks, credential)
    assert Locks.holders(locks, :machine) == [:you]
    assert {:forward, _, _} = Server.call(username, {:authorize, request(grant)})
  end

  test "a credential's lock stops the commands running with it, named by credential" do
    now = DateTime.utc_now()

    running = fn id, with ->
      %Approval{
        id: id,
        kind: :command,
        title: id,
        requested_at: now,
        deadline: now,
        run: %{state: :running},
        confine: %{confined: true, with: with, writes_dir: false}
      }
    end

    # The token grants over "google" have ids of their own.
    state = %{
      grants: [%Grant{id: "gcp", name: "GCP", kind: :token, credential: "google"}],
      approvals: [running.("run-bq", ["google"]), running.("run-charge", ["stripe"])]
    }

    assert [%{id: "run-bq"}] = HostRuns.running_with(state, {:credential, "google"})
    assert HostRuns.running_with(state, :mwt) == []
    assert length(HostRuns.running_with(state, :machine)) == 2
  end

  test "an unknown resource can't be locked", %{username: username} do
    assert {:error, :not_found} = Sandbox.lock(username, {:credential, "nothing"})
    assert {:error, :not_found} = Sandbox.lock(username, {:network, "nothing"})
  end

  test "a locked network refuses its connections", %{username: username} do
    {:ok, network} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "LAN",
        "purpose" => "The office network",
        "destinations" => "10.0.0.0/8"
      })

    {:ok, _} = Sandbox.turn_on(username, network.id, 60, :all)
    assert {:ok, _} = Gate.destination(username, {10, 1, 2, 3}, 443)

    :ok = Sandbox.lock(username, {:network, network.id})
    assert {:deny, words} = Gate.destination(username, {10, 1, 2, 3}, 443)
    assert words =~ "locked"
  end
end
