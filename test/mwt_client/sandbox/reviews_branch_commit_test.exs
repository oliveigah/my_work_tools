defmodule MWTClient.Sandbox.ReviewsBranchCommitTest do
  # mwt review branch and commit, and what a pull request needs.
  use MWTClient.ReviewsCase

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Projects}

  test "a branch is named on one remote when both have it; a commit is against its parent",
       context do
    %{repo: repo, mirror: mirror, colleague: colleague, server: server} = context
    git(colleague, ["fetch", "-q", "origin"])
    # Your own feature and a colleague's, by the same name.
    git(repo, ["branch", "feature"])
    commit(colleague, [{"d.txt", "theirs\n"}], "their feature")
    git(colleague, ["push", "-q", "origin", "HEAD:refs/heads/feature"])
    theirs = sha(colleague, "HEAD")

    run = cli(context, slot(mirror, 1))
    assert {said, 1} = run.(["review", "branch", "feature", "--onto", "master"])
    assert said =~ "host-origin/feature"
    assert said =~ "remote-origin/feature"
    assert said =~ "say which"

    assert {said, 1} = run.(["review", "branch", "remote-origin/feature", "--onto", "nope"])
    assert said =~ "There is no branch or commit nope here"

    assert {said, 0} = run.(["review", "branch", "remote-origin/feature", "--onto", "master"])
    assert said =~ "Reviewing remote-origin/feature in slot-1"
    assert git(slot(mirror, 1), ["branch", "--show-current"]) == "review-feature\n"

    # A commit on a branch, by a short id; one on no branch, fetched by its
    # full id from your remote.
    run2 = cli(context, slot(mirror, 2))
    assert {said, 0} = run2.(["review", "commit", binary_part(theirs, 0, 9)])
    assert said =~ ", its parent: 1 file changed"
    assert sha(slot(mirror, 2), "HEAD") == sha(colleague, "HEAD~1")
    assert status(slot(mirror, 2)) == [" A d.txt"]

    git(colleague, ["switch", "-q", "--detach", "origin/master"])
    commit(colleague, [{"e.txt", "lone\n"}], "a lone commit")
    git(colleague, ["push", "-q", "origin", "HEAD:refs/keep/lone"])
    lone = sha(colleague, "HEAD")
    run3 = cli(context, slot(mirror, 3))
    assert {said, 1} = run3.(["review", "commit", binary_part(lone, 0, 9)])
    assert said =~ "Give its full id"
    assert {said, 0} = run3.(["review", "commit", lone])
    assert said =~ "Reviewing commit #{binary_part(lone, 0, 12)}"
    assert status(slot(mirror, 3)) == [" A e.txt"]
    assert git(server, ["for-each-ref", "refs/review/"]) == ""
  end

  test "a review thread can record a timeline without becoming a task", context do
    %{username: username, mirror: mirror, colleague: colleague, server: server} = context
    commit(colleague, [{"d.txt", "reviewed\n"}], "Review this")
    git(colleague, ["push", "-q", "origin", "HEAD:refs/heads/feature"])
    git(mirror, ["fetch", "-q", server, "refs/heads/feature:refs/remotes/remote-origin/feature"])
    cwd = slot(mirror, 1)
    thread = "review-thread"
    assert :ok = Sandbox.set_timeline_override(username, thread, "on")

    assert {0, words} =
             Channel.answer(
               "review",
               %{
                 "action" => "commit",
                 "target" => sha(colleague, "HEAD"),
                 "cwd" => cwd,
                 "thread_id" => thread
               },
               username
             )

    assert words =~ "mwt help timeline"

    assert {0, _} =
             Channel.answer(
               "summary",
               %{"cwd" => cwd, "thread_id" => thread, "text" => "Review started."},
               username
             )

    assert {:ok,
            %{
              slots: [
                _,
                %{task?: false, review_thread: ^thread, summary: [%{title: "Review started."}]}
                | _
              ]
            }} =
             Projects.slots(username, "app")
  end

  test "a pull request needs Git: fetch from your remotes, and a link of the project's remote",
       context do
    %{username: username, repo: repo, mirror: mirror} = context
    run = cli(context, slot(mirror, 1))

    {:ok, _} = Sandbox.turn_off(username, "git-fetch-remote")
    assert {said, 1} = run.(["review", "pr", "7", "--onto", "master"])
    assert said =~ "git-fetch-remote"
    assert hd(states(username)) == {"slot-1", nil, true}

    git(repo, ["remote", "set-url", "origin", "git@github.com:acme/app.git"])

    assert {said, 1} =
             run.(["review", "pr", "https://github.com/someone/else/pull/3", "--onto", "master"])

    assert said =~ "That pull request is in github.com/someone/else"
    assert said =~ "github.com/acme/app"

    assert {said, 1} = run.(["review", "pr", "seven", "--onto", "master"])
    assert said =~ "\"seven\" isn't a pull request"
    assert {:ok, %{slots: slots}} = Projects.slots(username, "app")
    assert Enum.all?(slots, & &1.free?)
  end
end
