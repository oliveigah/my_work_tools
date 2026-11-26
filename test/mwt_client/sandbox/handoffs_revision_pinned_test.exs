defmodule MWTClient.Sandbox.HandoffsRevisionPinnedTest do
  @moduledoc """
  A handoff's decisions against its revisions: landing names the revision
  you looked at, and a revision being received neither interleaves with
  a close or a send-back nor writes over what changed on the record
  meanwhile. The sandbox, VM stand-in and helpers are
  `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Guest, HandoffRecords, Handoffs, Server}
  alias MWTClient.StandIns

  setup {MWTClient.HandoffsCase, :with_slots}

  test "Land names the revision you looked at; one handed off since lands nothing", %{
    username: username,
    mirror: mirror,
    repo: repo
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "first\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    {:ok, %{head: seen}} = HandoffRecords.get(username, 1)
    before = sha(repo, "master")

    # Its thread hands off again while you look at the first.
    commit(one, [{"b.txt", "more\n"}], "more")
    {0, _} = Channel.answer("handoff", ask(one), username)
    {:ok, %{head: latest, revision: 2}} = HandoffRecords.get(username, 1)

    assert {:error, {:revised, 2} = refused} =
             Handoffs.accept(username, 1, {:commit, "master"}, head: seen)

    assert Handoffs.explain(refused) =~ "revision 2 waits now, and nothing landed"
    assert sha(repo, "master") == before
    assert {:ok, %{status: :open}} = HandoffRecords.get(username, 1)

    assert {:ok, %{status: :accepted}} =
             Handoffs.accept(username, 1, {:commit, "master"}, head: latest)

    assert sha(repo, "master") == latest
  end

  test "a close while a revision is received waits for it, and both stay", context do
    %{username: username, mirror: mirror} = context
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "first\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    commit(one, [{"b.txt", "more\n"}], "more")

    revising = receiving(context, fn -> Channel.answer("handoff", ask(one), username) end)
    closing = Task.async(fn -> Handoffs.close(username, 1) end)
    # It waits for the revision rather than being written over by it.
    assert Task.yield(closing, 100) == nil

    send(revising.paused, :go)
    assert {0, words} = Task.await(revising.task)
    assert words =~ "revision 2"
    assert {:ok, %{status: :closed}} = Task.await(closing)

    {:ok, record} = HandoffRecords.get(username, 1)
    assert %{status: :closed, revision: 2} = record
    # Closed at that revision, its branch in the VM goes.
    assert [:opened, :updated, :closed, :branch_deleted] = Enum.map(record.timeline, & &1.kind)
  end

  test "what changes on the record while a revision is received stays", context do
    %{username: username, mirror: mirror} = context
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "first\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    commit(one, [{"b.txt", "more\n"}], "more")

    revising = receiving(context, fn -> Channel.answer("handoff", ask(one), username) end)

    # Meanwhile something is marked on it, outside the lock.
    {:ok, _} =
      Server.call(
        username,
        {:update_handoff, 1,
         fn handoff ->
           %{
             handoff
             | timeline:
                 Enum.map(handoff.timeline, fn
                   %{kind: :opened} = event -> Map.put(event, :marked, true)
                   event -> event
                 end)
           }
         end, "#1: marked"}
      )

    send(revising.paused, :go)
    assert {0, _} = Task.await(revising.task)

    {:ok, record} = HandoffRecords.get(username, 1)
    assert %{status: :open, revision: 2} = record
    assert %{marked: true} = Enum.find(record.timeline, &(&1.kind == :opened))
    assert List.last(record.timeline).kind == :updated
  end

  # Runs `fun`, a handoff from the VM, until it reads the folder it comes
  # from, inside the handoffs' lock and after it read the record: there it
  # waits for `:go`.
  defp receiving(%{username: username, vm: vm}, fun) do
    test = self()
    local = Guest.local(vm)

    StandIns.put_guest(username, %{
      local
      | exec: fn
          ["sh", "-c", _look, "mwt-handoff", _cwd] = words ->
            send(test, {:paused, self()})
            receive do: (:go -> :ok)
            local.exec.(words)

          words ->
            local.exec.(words)
        end
    })

    task = Task.async(fun)
    assert_receive {:paused, paused}
    %{task: task, paused: paused}
  end
end
