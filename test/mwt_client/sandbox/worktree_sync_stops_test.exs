defmodule MWTClient.Sandbox.WorktreeSyncStopsTest do
  @moduledoc """
  Where `mwt worktree sync` stops or refuses: at conflicts, which the next
  sync goes on from; a rebase given up; a remote not fetched for the VM; a
  slot another thread holds; a task whose open handoff keeps its base.
  What it does otherwise is in worktree_sync_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Channel

  setup {MWTClient.HandoffsCase, :with_slots}

  test "at conflicts it stops; resolved, the next sync goes on", context do
    %{mirror: mirror} = context
    team = with_remote(context)
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix", "--from", "master"])
    commit(one, [{"a.txt", "mine\n"}], "my change")
    push_to_remote(team, [{"a.txt", "theirs\n"}], "their change")

    assert {said, 1} = run.(["worktree", "sync", "remote"])
    assert said =~ "rebasing onto remote-origin/master stopped at conflicts in:\n  a.txt"

    File.write!(Path.join(one, "a.txt"), "both\n")
    git(one, ["add", "a.txt"])
    assert {said, 0} = run.(["worktree", "sync"])
    assert said =~ "Continued the rebase you resolved: fix is on remote-origin/master now"
    assert git(one, ["log", "-1", "--format=%s"]) == "my change\n"
    assert task_base(one, "fix") == "refs/remotes/remote-origin/master"
  end

  test "a rebase given up puts the old base back", context do
    %{mirror: mirror} = context
    team = with_remote(context)
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix", "--from", "master"])
    commit(one, [{"a.txt", "mine\n"}], "my change")
    push_to_remote(team, [{"a.txt", "theirs\n"}], "their change")
    assert {_, 1} = run.(["worktree", "sync", "remote"])
    git(one, ["rebase", "--abort"])

    assert {said, 0} = run.(["worktree", "sync"])
    assert said =~ "The last sync's rebase onto remote-origin/master was given up"
    assert said =~ "fix is based on host-origin/master again"
    assert said =~ "fix has everything host-origin/master has already"
    assert task_base(one, "fix") == "refs/remotes/host-origin/master"
  end

  test "with the remote not fetched for the VM, it says remote-origin may be behind", context do
    %{username: username, mirror: mirror, repo: repo} = context
    with_remote(context)
    git(repo, ["fetch", "-q", "origin"])
    {:ok, _} = Sandbox.turn_off(username, "git-fetch-remote")
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix", "--from", "master"])

    assert {said, 0} = run.(["worktree", "sync", "remote"])
    assert said =~ "remote-origin may be behind the remote"
    assert said =~ "mwt request git-fetch-remote"
  end

  test "only its own thread syncs a task; an open handoff keeps its base", %{
    username: username,
    mirror: mirror
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix", "thread_id" => "thread-a"})

    sync =
      &Channel.answer("worktree", Map.merge(%{"action" => "sync", "cwd" => one}, &1), username)

    assert {1, said} = sync.(%{"thread_id" => "thread-b"})
    assert said =~ "slot-1 holds another thread's task, fix: only that thread syncs it."

    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one, %{"thread_id" => "thread-a"}), username)
    assert {1, said} = sync.(%{"thread_id" => "thread-a", "level" => "remote"})
    assert said =~ "fix's handoff #1 is based on host-origin/master"
    assert said =~ "mwt handoff --onto remote-origin/master"

    assert {0, plan} = sync.(%{"thread_id" => "thread-a"})
    assert plan =~ "mode=rebase\n"
    assert plan =~ "record=no\n"
  end

  test "it takes host or remote, and a branch", %{base: base} = context do
    run = cli(context, base)
    assert {said, 1} = run.(["worktree", "sync", "upstream"])
    assert said =~ "mwt worktree sync [host|remote] [BRANCH]"
  end
end
