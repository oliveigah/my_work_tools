defmodule MWTClient.Sandbox.HandoffsPrunedBranchesTest do
  @moduledoc """
  Task branches in the VM that nothing needs any more are deleted, so they
  don't pile up: when a slot is freed or taken, when a handoff is closed,
  and when anyone runs `mwt worktree prune`; never one a slot has, one
  another task is based on, or one with commits found nowhere else.
  What landing does is in handoffs_landed_branch_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Guest, Handoff, Handoffs, Projects}
  alias MWTClient.StandIns

  setup {MWTClient.HandoffsCase, :with_slots}

  test "freed with nothing of its own, an exploration's branch goes; one with a commit stays", %{
    username: username,
    mirror: mirror
  } do
    one = slot(mirror, 1)
    two = slot(mirror, 2)
    {0, _} = worktree(username, one, "new", %{"name" => "explore-login"})
    {0, _} = worktree(username, two, "new", %{"name" => "spike-cache"})
    commit(two, [{"b.txt", "spike\n"}], "the spike")

    assert {0, freed} = worktree(username, one, "free")

    assert freed =~
             "MWT deleted the branch explore-login, as nothing needed it any more and nothing of it is lost."

    assert git(mirror, ["branch", "--list", "explore-login"]) == ""
    refute git(mirror, ["config", "--list", "--local"]) =~ "branch.explore-login."

    assert {0, kept} = worktree(username, two, "free")
    assert kept =~ "The branch spike-cache stays: 1 commit on it is on none of your branches."
    assert git(mirror, ["log", "-1", "--format=%s", "spike-cache"]) == "the spike\n"
  end

  test "closed, a handoff's branch goes and its slot is on no branch; resume makes it again", %{
    username: username,
    mirror: mirror
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    head = sha(one, "HEAD")

    assert {:ok, %Handoff{status: :closed} = closed} = Handoffs.close(username, 1)
    assert %{kind: :branch_deleted, text: deleted} = List.last(closed.timeline)
    assert deleted =~ "MWT deleted its branch fix in the VM"
    assert deleted =~ "#{one} is on no branch now"
    assert git(one, ["branch", "--show-current"]) == ""
    assert sha(one, "HEAD") == head

    # Reopened and asked for more, its thread makes the branch again first.
    {:ok, _} = Handoffs.reopen(username, 1)
    assert {0, resumed} = worktree(username, one, "resume", %{"name" => "fix"})
    assert resumed =~ "Put the branch fix, as it was, in slot-1"
    assert sha(mirror, "fix") == head
  end

  test "a new task sweeps the branches nothing needs, never one a slot has, even just resumed",
       %{username: username, mirror: mirror} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})

    # Taken back out and resumed: at the commit that landed, nothing
    # done on it yet, which a sweep leaves to its slot.
    {:ok, _} = Handoffs.undo(username, 1)
    {0, _} = worktree(username, one, "resume", %{"name" => "fix"})

    # Left from before: a task's branch with nothing of its own, one with
    # a commit, one a task is based on; and a branch no task started.
    leftover(mirror, "explored")
    leftover(mirror, "parked")
    git(mirror, ["update-ref", "refs/heads/parked", commit_on(mirror, "parked", "parked work")])
    leftover(mirror, "groundwork")
    git(mirror, ["branch", "--no-track", "mine", "host-origin/master"])

    two = slot(mirror, 2)

    {0, _} =
      worktree(username, two, "new", %{
        "name" => "on-groundwork",
        "from" => "refs/heads/groundwork"
      })

    branches = git(mirror, ["branch", "--format=%(refname:short)"]) |> String.split()
    assert "fix" in branches and git(one, ["branch", "--show-current"]) == "fix\n"
    refute "explored" in branches
    assert "parked" in branches
    assert "groundwork" in branches
    assert "mine" in branches
    assert "on-groundwork" in branches
  end

  test "landed as one commit while the VM was stopped, its branch goes once its slot is taken", %{
    username: username,
    mirror: mirror,
    vm: vm
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    StandIns.remove_guest(username)
    {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"}, one_commit: true)
    StandIns.put_guest(username, Guest.local(vm))

    # Its commit is in no branch of yours, only in its handoff.
    assert git(mirror, ["branch", "--list", "fix"]) =~ "fix"
    {0, _} = worktree(username, one, "new", %{"name" => "next"})
    assert git(mirror, ["branch", "--list", "fix"]) == ""
  end

  test "mwt worktree prune says what it would delete, then deletes it", context do
    %{mirror: mirror} = context
    leftover(mirror, "explored")
    leftover(mirror, "parked")
    git(mirror, ["update-ref", "refs/heads/parked", commit_on(mirror, "parked", "parked work")])
    run = cli(context, mirror)

    assert {said, 0} = run.(["worktree", "prune", "--dry-run"])
    assert said =~ "Would delete 1 task branch in app (a dry run: nothing changed)"
    assert said =~ "  explored\n"
    assert said =~ "  parked stays: 1 commit on it is on none of your branches"
    assert git(mirror, ["branch", "--list", "explored"]) =~ "explored"

    assert {said, 0} = run.(["worktree", "prune"])
    assert said =~ "Deleted 1 task branch in app"
    assert git(mirror, ["branch", "--list", "explored"]) == ""

    assert {said, 0} = run.(["worktree", "prune"])
    assert said =~ "Nothing to delete in app"
  end

  test "pruning needs the VM", %{username: username} do
    StandIns.remove_guest(username)
    assert {:error, :vm_not_running} = Projects.prune_branches(username, "app")
  end

  # A task's branch at your master, in no worktree, as one left behind.
  defp leftover(mirror, task) do
    git(mirror, ["branch", "--no-track", task, "host-origin/master"])
    git(mirror, ["config", "branch.#{task}.mwt-base", "refs/remotes/host-origin/master"])
  end

  # A commit on top of `branch`, made without a worktree.
  defp commit_on(mirror, branch, message) do
    tree = git(mirror, ["rev-parse", "#{branch}^{tree}"]) |> String.trim()
    git(mirror, ["commit-tree", tree, "-p", branch, "-m", message]) |> String.trim()
  end
end
