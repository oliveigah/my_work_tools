defmodule MWTClient.Sandbox.ReviewsPullRequestTest do
  # mwt review pr: set up, the slot taken while its changes are there, and
  # set up again once they are discarded.
  use MWTClient.ReviewsCase

  test "a pull request is set up as unstaged changes over where it parts from its base",
       context do
    %{username: username, repo: repo, mirror: mirror, parted: parted} = context
    tree = slot(mirror, 1)
    run = cli(context, tree)
    host_refs = git(repo, ["for-each-ref"])

    # Projects merge into different branches: it is always named.
    assert {said, 1} = run.(["review", "pr", "7"])
    assert said =~ "name the branch the pull request merges into"
    assert said =~ "The branches: host-origin/master, remote-origin/master."
    assert states(username) |> hd() == {"slot-1", nil, true}

    assert {said, 0} = run.(["review", "pr", "7", "--onto", "master"])
    assert said =~ "Reviewing PR #7 in slot-1"
    assert said =~ "where it parts from remote-origin/master"
    assert said =~ "3 files changed"

    # On its own branch, at the commit it parted from: master's later
    # commit isn't in it, and nothing is staged; the new file is there.
    assert git(tree, ["branch", "--show-current"]) == "review-pr-7\n"
    assert sha(tree, "HEAD") == parted
    assert Enum.sort(status(tree)) == [" A b.txt", " D c.txt", " M a.txt"]
    assert git(tree, ["diff", "--cached", "--name-only"]) == ""
    assert File.read!(Path.join(tree, "a.txt")) == "one\nTWO\nthree\n"
    refute File.exists?(Path.join(tree, "m.txt"))

    # Your repository is only read: the pull request went into MWT's store.
    assert git(repo, ["for-each-ref"]) == host_refs
    assert git(store(context), ["for-each-ref", "refs/review/"]) =~ "refs/review/pull/7"

    # Its changes take the slot, as any uncommitted work does; it is no
    # task, so nothing is handed off from it.
    assert {"slot-1", "review-pr-7", false} = hd(states(username))
    assert {said, 1} = run.(["worktree", "new", "fix-it", "--from", "master"])
    assert said =~ "slot-1, where you are, isn't free"
    assert {said, 1} = run.(["review", "pr", "8", "--onto", "master"])
    assert said =~ "slot-1, where you are, isn't free"
    assert {said, 1} = run.(["handoff", "--title", "fix: it"])
    assert said =~ "review-pr-7 isn't a task's branch"
    assert handoffs(username) == []
  end

  test "discarded, its changes free the slot, and the pull request is set up there again",
       context do
    %{username: username, mirror: mirror, colleague: colleague} = context
    tree = slot(mirror, 2)
    run = cli(context, tree)
    assert {_, 0} = run.(["review", "pr", "#7", "--onto", "remote-origin/master"])
    File.mkdir_p!(Path.join(tree, "_build"))
    File.write!(Path.join(tree, "_build/warm"), "kept\n")

    # Elsewhere, while it is checked out here: refused.
    assert {said, 1} = cli(context, slot(mirror, 3)).(["review", "pr", "7", "--onto", "master"])
    assert said =~ "review-pr-7 is checked out in #{tree}"

    # The colleague pushes more; you discard the changes, as in Zed, and
    # review it again: the branch is made again at the new head.
    commit(colleague, [{"b.txt", "newer\n"}], "more of it")
    git(colleague, ["push", "-q", "origin", "+HEAD:refs/pull/7/head"])
    git(tree, ["reset", "-q", "--hard"])
    git(tree, ["clean", "-fdq"])
    assert {"slot-2", "review-pr-7", true} = Enum.at(states(username), 1)

    assert {said, 0} = run.(["review", "pr", "7", "--onto", "master"])
    assert said =~ "Reviewing PR #7 in slot-2"
    assert File.read!(Path.join(tree, "b.txt")) == "newer\n"
    assert File.read!(Path.join(tree, "_build/warm")) == "kept\n"

    # A commit made on it, found on no remote's branch, keeps the branch
    # where it is.
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "mine"])
    assert {"slot-2", "review-pr-7", true} = Enum.at(states(username), 1)
    assert {said, 1} = run.(["review", "pr", "7", "--onto", "master"])
    assert said =~ "There is a branch review-pr-7 already"
    assert git(tree, ["log", "-1", "--format=%s"]) == "mine\n"
  end
end
