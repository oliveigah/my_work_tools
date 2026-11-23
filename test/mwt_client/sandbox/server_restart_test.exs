defmodule MWTClient.Sandbox.ServerRestartTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Server, UnlockState}
  alias MWTClient.Vault.Store

  setup do
    MWTClient.VaultHelpers.unlocked_identity("restart")
  end

  defp grants(username) do
    for grant <- Sandbox.snapshot(username).grants,
        grant.id in ["internet", "mwt-read", "mwt-create", "mwt-change"],
        into: %{},
        do: {grant.id, {grant.state, grant.expires_at, length(grant.allowances)}}
  end

  # The server's process fails, and its supervisor starts it again.
  defp fail_and_restart(username) do
    pid = Store.whereis(Server, username)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _ = :sys.get_state(Store.supervisor(username))
    restarted = Store.whereis(Server, username)
    assert restarted not in [nil, pid]
    restarted
  end

  test "a restart after a failure turns on nothing you turned off, nor off what you turned on",
       %{username: username} do
    {:ok, _} = Sandbox.turn_off(username, "internet")
    {:ok, _} = Sandbox.turn_off(username, "mwt-read")
    {:ok, _} = Sandbox.turn_on(username, "mwt-change", 30)
    before = grants(username)
    assert {:on, %DateTime{}, 0} = before["mwt-change"]

    fail_and_restart(username)

    assert grants(username) == before
    assert {:off, nil, 0} = grants(username)["internet"]

    assert Enum.any?(
             Sandbox.events(username),
             &(&1.summary =~ "stopped on a failure and started again")
           )
  end

  test "the firewall's counts are kept too", %{username: username} do
    pid = Store.whereis(Server, username)
    :sys.replace_state(pid, &%{&1 | firewall_refused: 7})
    # Its windows go at most once a second: the timer that sends the last
    # change rings now.
    send(pid, :keep)
    _ = :sys.get_state(pid)
    assert %{firewall_refused: 7} = UnlockState.get(username)

    restarted = fail_and_restart(username)

    assert :sys.get_state(restarted).firewall_refused == 7
  end

  test "a lock and an unlock are a start: every grant in its start setting",
       %{username: username, key: key} do
    started = grants(username)
    {:ok, _} = Sandbox.turn_off(username, "internet")

    :ok = Store.close(username)
    assert UnlockState.get(username) == nil
    :ok = Store.open(username, key)

    assert grants(username) == started
  end
end
