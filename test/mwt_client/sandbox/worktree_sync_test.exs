defmodule MWTClient.Sandbox.WorktreeSyncTest do
  @moduledoc """
  `mwt worktree sync [host|remote] [BRANCH]`, and tasks started from your
  remote's branches: a slot brought up to date with what landed on your
  branch or what a teammate pushed to your repository's own remote. Run as
  you would at a terminal in the VM, through the real `mwt`. Where it
  stops or refuses is in worktree_sync_stops_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.Handoffs

  setup {MWTClient.HandoffsCase, :with_slots}

  test "remote: a task goes onto what a teammate pushed, its uncommitted work along", context do
    %{username: username, mirror: mirror, repo: repo} = context
    team = with_remote(context)
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix-login", "--from", "master"])
    File.write!(Path.join(one, "a.txt"), "mine\n")
    theirs = push_to_remote(team, [{"b.txt", "theirs\n"}], "a teammate's work")

    assert {said, 0} = run.(["worktree", "sync", "remote"])
    assert said =~ "fix-login is at remote-origin/master now"
    assert said =~ "with no commits of its own yet"
    assert said =~ "fix-login is based on remote-origin/master from now on"
    assert said =~ "remote-origin is as the remote had it"
    assert sha(one, "HEAD") == theirs
    assert File.read!(Path.join(one, "a.txt")) == "mine\n"
    assert task_base(one, "fix-login") == "refs/remotes/remote-origin/master"

    # Handed off, it lands on your master, the one of the same name: as one
    # commit with its own change, since your master doesn't have theirs.
    assert {_, 0} = run.(["handoff", "--title", "Edit a"])
    assert {:ok, %{onto: "master"}} = Handoffs.landing(username, 1)
    assert {:ok, %{accepted: %{how: :commit}}} = Handoffs.accept(username, 1)
    assert git(repo, ["show", "master:a.txt"]) == "mine\n"
    refute git(repo, ["ls-tree", "--name-only", "master"]) =~ "b.txt"
  end

  test "host: a task catches up with what landed on your branch, its commits on top", context do
    %{mirror: mirror, repo: repo} = context
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix", "--from", "master"])
    commit(one, [{"c.txt", "mine\n"}], "my commit")
    commit(repo, [{"h.txt", "landed\n"}], "landed on master")

    assert {said, 0} = run.(["worktree", "sync"])
    assert said =~ "Rebased fix onto host-origin/master"
    assert said =~ "its own commits on top, 1"
    refute said =~ "from now on"
    assert sha(one, "HEAD~1") == sha(repo, "master")

    assert {said, 0} = run.(["worktree", "sync", "host"])
    assert said =~ "fix has everything host-origin/master has already"
  end

  test "from your branch to your remote's, only the task's own commits go along", context do
    %{mirror: mirror, repo: repo} = context
    team = with_remote(context)
    commit(repo, [{"u.txt", "not pushed\n"}], "yours, not pushed yet")
    one = slot(mirror, 1)
    run = cli(context, one)
    assert {_, 0} = run.(["worktree", "new", "fix", "--from", "master"])
    commit(one, [{"c.txt", "mine\n"}], "my commit")
    theirs = push_to_remote(team, [{"b.txt", "theirs\n"}], "a teammate's work")

    assert {_, 0} = run.(["worktree", "sync", "remote", "master"])
    assert git(one, ["log", "--format=%s", "remote-origin/master..HEAD"]) == "my commit\n"
    assert sha(one, "HEAD~1") == theirs
  end

  test "a slot no task holds is checked out on no branch, at the latest", context do
    %{mirror: mirror, repo: repo} = context
    two = slot(mirror, 2)
    run = cli(context, two)
    commit(repo, [{"h.txt", "landed\n"}], "landed on master")

    assert {said, 0} = run.(["worktree", "sync"])
    assert said =~ "slot-2 is on no branch now, at host-origin/master"
    assert sha(two, "HEAD") == sha(repo, "master")
    assert git(two, ["branch", "--show-current"]) == ""

    assert {said, 0} = run.(["worktree", "sync", "host"])
    assert said =~ "slot-2 is at host-origin/master already"
  end

  test "a task starts from your remote's branch, fetched first", context do
    %{mirror: mirror} = context
    team = with_remote(context)
    theirs = push_to_remote(team, [{"b.txt", "theirs\n"}], "a teammate's work")
    one = slot(mirror, 1)

    assert {said, 0} =
             cli(context, one).(["worktree", "new", "fix", "--from", "remote-origin/master"])

    assert said =~ "Started the task fix"
    assert said =~ "remote-origin is as the remote had it"
    assert sha(one, "HEAD") == theirs
    assert task_base(one, "fix") == "refs/remotes/remote-origin/master"
  end
end
