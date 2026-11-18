defmodule MWTClient.Sandbox.ActivityTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Approval, Event}
  alias MWTClient.Sandbox.Server
  alias MWTClient.Sandbox.Server.{Approvals, HostRuns}
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity("activity")
  end

  defp log(username, attrs), do: Server.cast(username, {:log, attrs})

  defp summaries(username, filters),
    do: username |> Sandbox.events(filters) |> Enum.map(& &1.summary)

  test "events outlive a lock: they are kept in the journal, not in memory", %{
    username: username,
    key: key
  } do
    log(username, %{outcome: :tunnel, summary: "kept", host: "api.example.test", up: 10})
    assert ["kept"] = summaries(username, %{q: "kept"})

    :ok = Store.close(username)
    :ok = Store.open(username, key)

    assert [%Event{summary: "kept", host: "api.example.test", up: 10, outcome: :tunnel}] =
             Sandbox.events(username, %{q: "kept"})
  end

  test "the log filters by thread, by kind and by time", %{username: username} do
    log(username, %{
      outcome: :tool,
      summary: "note read",
      agent: "claude",
      thread_id: "t-1",
      thread: "Storage"
    })

    log(username, %{
      outcome: :tool,
      summary: "card added",
      agent: "codex",
      thread_id: "t-2",
      thread: "Firewall"
    })

    log(username, %{outcome: :tunnel, summary: "traffic"})
    log(username, %{outcome: :handoff, summary: "handed off", agent: "claude", thread_id: "t-1"})

    assert summaries(username, %{thread: "t-1"}) == ["handed off", "note read"]
    assert summaries(username, %{group: "traffic"}) == ["traffic"]
    assert summaries(username, %{group: "changes", thread: "t-2"}) == ["card added"]

    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert summaries(username, %{since: later}) == []

    assert length(summaries(username, %{since: DateTime.add(DateTime.utc_now(), -60, :second)})) ==
             4

    assert [%{id: "t-1", title: "Storage", agent: "claude"}, %{id: "t-2", title: "Firewall"}] =
             Sandbox.event_threads(username)

    stats = Sandbox.event_stats(username, %{thread: "t-1"})
    assert stats.groups["all"] == 2
    assert stats.groups["changes"] == 2
  end

  test "pages go back from a cursor", %{username: username} do
    for n <- 1..5, do: log(username, %{outcome: :tunnel, summary: "conn #{n}"})
    [_newest, second | _rest] = Sandbox.events(username)

    assert summaries(username, %{before: second.id, limit: 2}) == ["conn 3", "conn 2"]
    assert summaries(username, %{before: "event-gone"}) == []
  end

  test "what an agent asked for carries the agent and thread it named" do
    approval = %Approval{
      id: "a1",
      kind: :command,
      title: "Run the tests",
      agent: "claude",
      thread: %{id: "t-1", title: "Storage", folder: "/work"},
      requested_at: DateTime.utc_now(),
      deadline: DateTime.utc_now()
    }

    assert %{agent: "claude", thread_id: "t-1", thread: "Storage", outcome: :command} =
             HostRuns.command_event(approval, "it ran")

    assert %{agent: "claude", thread_id: "t-1", outcome: :allowed} =
             Approvals.event_for(%{approval | kind: :request}, :allowed, "allowed")

    assert %{agent: nil, thread_id: nil} = Event.asked_by(nil, nil)
  end
end
