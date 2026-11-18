defmodule MWTClient.Sandbox.ServerNotificationsTest do
  @moduledoc """
  The sandbox keeps one notification per approval waiting for you
  (`MWTClient.Notifications`). The desktop is never reached in tests, but
  what is notified is listed all the same, which is what these read.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Notifications
  alias MWTClient.Notifications.Center
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Grant
  alias MWTClient.Sandbox.Server

  setup do
    context = MWTClient.VaultHelpers.unlocked_identity("notify")

    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push to oliveigah/klife",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value"
      })

    Map.put(context, :grant, grant)
  end

  # What is notified to this identity, by approval id.
  defp shown(username) do
    _ = :sys.get_state(Center)

    for %{key: {^username, {:sandbox_approval, id}}, notice: notice} <- Center.list(),
        into: %{},
        do: {id, notice}
  end

  defp ask(username, grant) do
    {:ok, approval} =
      Server.call(
        username,
        {:request_access,
         %{grant: grant.id, minutes: 30, reason: "push the fix", agent: "claude"}}
      )

    approval
  end

  test "an agent's ask shows until you decide it", %{username: username, grant: grant} do
    approval = ask(username, grant)

    assert %{summary: "Claude asks to turn on GitHub", open: open, scope: ^username} =
             shown(username)[approval.id]

    assert open == "/tools/sandbox/approvals?focus=#{approval.id}"

    :ok = Sandbox.decide(username, approval.id, :decline)
    assert shown(username) == %{}
  end

  test "asking again joins the waiting ask without a second notification", %{
    username: username,
    grant: grant
  } do
    first = ask(username, grant)
    again = ask(username, grant)
    assert again.id == first.id
    assert Map.keys(shown(username)) == [first.id]
  end

  test "turning the desktop off keeps them listed in MWT; on again sends them there", %{
    username: username,
    grant: grant
  } do
    approval = ask(username, grant)
    assert %{desktop: true} = shown(username)[approval.id]

    Notifications.put_settings(username, %{desktop: false})
    assert %{desktop: false} = shown(username)[approval.id]

    {:ok, other} =
      Server.call(
        username,
        {:request_access, %{need: "Postgres", reason: "migrate", agent: "codex"}}
      )

    assert %{desktop: false} = shown(username)[other.id]
    assert [_, _] = Notifications.list(username)

    # One kind off leaves the others on.
    Notifications.put_settings(username, %{desktop: true, kinds: %{"sandbox.approvals" => false}})
    assert %{desktop: false} = shown(username)[approval.id]

    Notifications.put_settings(username, %{kinds: %{"sandbox.approvals" => true}})
    assert %{desktop: true} = shown(username)[approval.id]
    assert %{desktop: true} = shown(username)[other.id]
  end

  test "a command shows while it waits, and again when its output waits for you", %{
    username: username
  } do
    # Ask to run commands, the escape hatch, is built in.
    grant = Enum.find(Sandbox.snapshot(username).grants, &Grant.ask_to_run?/1)

    {:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :ask)

    {:ok, approval} =
      Server.call(
        username,
        {:request_command,
         %{grant: "commands", script: "echo hi", timeout: 10, reason: "check", agent: "claude"}}
      )

    assert %{summary: "Claude asks to run a command it wrote, on this machine"} =
             shown(username)[approval.id]

    # Running, it waits for nobody; done, its output waits for you.
    :ok = Sandbox.decide(username, approval.id, {:run, :review})

    output =
      Enum.find_value(1..300, fn _ ->
        case shown(username)[approval.id] do
          %{summary: "A command's output waits for you"} = notice -> notice
          _other -> Process.sleep(10) && nil
        end
      end)

    assert output.body =~ "echo hi\nExit 0"

    :ok = Sandbox.decide(username, approval.id, :keep_output)
    assert shown(username) == %{}
  end

  test "after a restart, open handoffs are listed but not put on the desktop again", %{
    username: username,
    key: key
  } do
    :ok = MWTClient.Vault.Store.close(username)

    {:ok, saved} =
      MWTClient.VaultHelpers.with_storage(username, key, fn ->
        MWTClient.Storage.Documents.get(username, "sandbox")
      end)

    at = DateTime.utc_now() |> DateTime.truncate(:second)

    handoff = %MWTClient.Sandbox.Handoff{
      id: 3,
      title: "Fix the login",
      agent: "claude",
      project: "app",
      repo: "/nowhere/app",
      onto: "main",
      source: %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "fix"},
      head: "abc",
      opened_at: at,
      updated_at: at,
      timeline: [%{at: at, kind: :opened, text: "claude handed it off"}]
    }

    # An older MWT kept the desktop switch in the sandbox's settings.
    settings = Map.put(saved.settings, :desktop_notifications, false)

    MWTClient.VaultHelpers.with_storage(username, key, fn ->
      :ok =
        MWTClient.Storage.Documents.put(username, "sandbox", %{
          saved
          | handoffs: [handoff],
            settings: settings
        })
    end)

    :ok = MWTClient.Vault.Store.open(username, key)
    _ = Sandbox.snapshot(username)
    _ = :sys.get_state(Center)

    assert [%{key: {:sandbox_handoff, 3}, summary: "Claude handed off #3: Fix the login"}] =
             Notifications.list(username)

    assert [%{notice: %{desktop: false, quiet: true}}] =
             Enum.filter(Center.list(), &(&1.key == {username, {:sandbox_handoff, 3}}))

    # The old switch, off, carried over; turning the desktop on again leaves
    # what waited before the restart off it.
    refute Notifications.settings(username).desktop
    Notifications.put_settings(username, %{desktop: true})

    assert [%{notice: %{desktop: false}}] =
             Enum.filter(Center.list(), &(&1.key == {username, {:sandbox_handoff, 3}}))
  end

  test "locking the vault closes the identity's notifications", %{
    username: username,
    grant: grant
  } do
    ask(username, grant)
    assert map_size(shown(username)) == 1

    pid = GenServer.whereis(MWTClient.Vault.Store.via(Server, username))
    ref = Process.monitor(pid)
    MWTClient.Vault.Store.close(username)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert shown(username) == %{}
  end
end
