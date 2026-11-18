defmodule MWTClient.Sandbox.HandoffRevisionsTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, HandoffStore, Handoffs, Project, Projects, Server}

  test "the clone is slot-0: a task taken there hands off like any slot", context do
    %{username: username, repo: repo, mirror: clone} = context
    {:ok, project} = Projects.open(username, repo)

    assert {0, words} =
             Channel.answer(
               "worktree",
               %{"cwd" => clone, "name" => "fix-in-clone", "from" => "master"},
               username
             )

    assert words =~ "slot-0"
    commit(clone, [{"vm.txt", "work\n"}], "work in the clone")
    submitted = sha(clone, "HEAD")

    assert {0, words} = Channel.answer("handoff", ask(clone), username)
    assert words =~ "Handed off as #1"

    assert [%{head: ^submitted, source: %{top: ^clone, branch: "fix-in-clone"}}] =
             handoffs(username)

    refute File.exists?(Path.join(repo, "vm.txt"))

    assert git(clone, ["config", "--get", "remote.origin.url"]) ==
             Project.remote_url(project) <> "\n"
  end

  test "a branch no task started isn't handed off", context do
    %{username: username, repo: repo, mirror: clone} = context
    {:ok, _project} = Projects.open(username, repo)
    git(clone, ["switch", "-q", "-c", "loose"])
    commit(clone, [{"vm.txt", "work\n"}], "loose work")

    assert {1, words} = Channel.answer("handoff", ask(clone), username)
    assert words =~ "isn't a task's branch"
    assert handoffs(username) == []
  end

  test "with Git: hand off off, nothing is handed off", context do
    %{username: username} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "work\n"}], "work")
    {:ok, _} = MWTClient.Sandbox.turn_off(username, "git-handoff")

    assert {1, words} = Channel.answer("handoff", ask(tree), username)
    assert words =~ "Git: hand off is off"
    assert words =~ "mwt request git-handoff"
    assert handoffs(username) == []
  end

  test "a revision behind its base is refused until it catches up, conflicts named", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"a.txt", "VM edit\n"}], "VM work")
    commit(repo, [{"a.txt", "host edit\n"}], "host work")

    assert {1, words} = Channel.answer("handoff", ask(tree), username)
    assert words =~ "a.txt"
    assert words =~ "mwt handoff"
    assert handoffs(username) == []
  end

  test "one whose base moved after it was handed off lands as one commit on top", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "VM\n"}], "VM")
    head = sha(tree, "HEAD")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    commit(repo, [{"host.txt", "host\n"}], "host")
    host = sha(repo, "HEAD")

    assert {:ok, %{fast_forward?: false, as: :one_commit, behind: 1}} =
             Handoffs.preview(username, 1)

    assert {:ok, %{accepted: %{how: :commit, branch: "master"}}} = Handoffs.accept(username, 1)
    assert sha(repo, "HEAD~1") == host
    assert File.read!(Path.join(repo, "vm.txt")) == "VM\n"
    assert File.read!(Path.join(repo, "host.txt")) == "host\n"
    assert sha(tree, "HEAD") == head
  end

  test "continuing work does not change the submitted revision", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "first\n"}], "first")
    head = sha(tree, "HEAD")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    commit(tree, [{"vm.txt", "later\n"}], "later")
    latest = sha(tree, "HEAD")

    assert [%{head: ^head, revision: 1}] = handoffs(username)
    assert {:ok, %{accepted: %{how: :as_is}}} = Handoffs.accept(username, 1)
    assert sha(repo, "master") == head
    assert sha(tree, "HEAD") == latest
    assert File.read!(Path.join(tree, "vm.txt")) == "later\n"
  end

  test "each new submission keeps the previous revision reachable", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "first\n"}], "first")
    first = sha(tree, "HEAD")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    commit(tree, [{"vm.txt", "second\n"}], "second")
    second = sha(tree, "HEAD")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    assert [%{head: ^second, revision: 2}] = handoffs(username)

    store = HandoffStore.path(Server.call(username, :projects).dir, repo)
    assert sha(store, "refs/handoff-revisions/1/1") == first
    assert sha(store, "refs/handoff-revisions/1/2") == second
  end

  test "a submitted revision lands after its slot's branch is deleted", context do
    %{username: username, repo: repo, mirror: clone} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "retained\n"}], "retain")
    head = sha(tree, "HEAD")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    git(tree, ["switch", "-q", "--detach"])
    git(clone, ["branch", "-D", "fix"])
    MWTClient.StandIns.put_guest(username, nil)

    assert {:ok, _} = Handoffs.accept(username, 1)
    assert sha(repo, "master") == head
    assert File.read!(Path.join(repo, "vm.txt")) == "retained\n"
  end

  test "submission pins the requested commit even if the branch has advanced", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "checked\n"}], "checked")
    checked = sha(tree, "HEAD")
    commit(tree, [{"vm.txt", "later\n"}], "later")

    assert {0, _} = Channel.answer("handoff", ask(tree, %{"head" => checked}), username)
    assert [%{head: ^checked}] = handoffs(username)
    assert {:ok, _} = Handoffs.accept(username, 1)
    assert File.read!(Path.join(repo, "vm.txt")) == "checked\n"
  end

  test "facts keep the submitted comparison base after the host moves on", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "work\n"}], "work")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    [submitted] = handoffs(username)
    commit(repo, [{"host.txt", "later\n"}], "later")

    assert {:ok, facts} = Handoffs.facts(username, 1)
    assert facts.merge_base == submitted.base_commit
    assert Enum.map(facts.files, & &1.path) == ["vm.txt"]
    assert facts.behind == 1
  end

  test "an independent clone is recognized by its registered origin", context do
    %{username: username, repo: repo, vm: vm, base: base} = context
    {:ok, project} = Projects.open(username, repo)
    clone = Path.join(vm, "independent")
    git(base, ["clone", "-q", repo, clone])
    git(clone, ["remote", "set-url", "origin", Project.remote_url(project)])
    git(clone, ["switch", "-q", "-c", "independent-work"])
    git(clone, ["config", "branch.independent-work.mwt-base", "refs/remotes/origin/master"])
    commit(clone, [{"independent.txt", "work\n"}], "independent")

    assert {0, _} = Channel.answer("handoff", ask(clone), username)
    assert {:ok, _} = Handoffs.accept(username, 1)
    assert File.read!(Path.join(repo, "independent.txt")) == "work\n"
  end

  test "the CLI fetches, commits the work and catches up by rebasing onto origin", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(repo, [{"host.txt", "host\n"}], "host work")
    host = sha(repo, "HEAD")
    File.write!(Path.join(tree, "a.txt"), "edited\n")
    {:ok, _} = Projects.update(username, "app", %{"checks" => "test -f host.txt"})
    run = cli(context, tree)

    assert {words, 0} = run.(["handoff", "--title", "Edit a"])
    assert words =~ "Committed what was uncommitted: Edit a"
    assert words =~ "Rebased onto origin/master"
    assert words =~ "The checks passed"
    assert words =~ "Handed off"
    assert sha(tree, "HEAD~1") == host
    assert git(tree, ["log", "-1", "--format=%s"]) == "Edit a\n"
    assert [%{head: head, stats: %{behind: 0, commits: 1}}] = handoffs(username)
    assert head == sha(tree, "HEAD")

    # It lands as it is: your master moves to that very commit.
    assert {:ok, %{accepted: %{how: :as_is, commits: 1}}} = Handoffs.accept(username, 1)
    assert sha(repo, "master") == head
  end

  test "a new revision folds into the handoff's commit; your own commits stay", context do
    %{username: username} = context
    {_project, tree} = project_with_worktree(context)
    run = cli(context, tree)
    File.write!(Path.join(tree, "a.txt"), "first\n")
    assert {_, 0} = run.(["handoff", "--title", "The fix"])
    [%{head: first}] = handoffs(username)
    {:ok, _} = Handoffs.send_back(username, 1, "More")

    File.write!(Path.join(tree, "a.txt"), "second\n")
    assert {words, 0} = run.(["handoff"])
    assert words =~ "Folded what was uncommitted into the handoff's commit"
    [%{head: second, revision: 2, stats: %{commits: 1}}] = handoffs(username)
    assert second != first
    assert sha(tree, "HEAD~1") == sha(tree, "origin/master")

    # The user commits a piece of their own: it stays, and the next
    # revision is a commit on top of it.
    commit(tree, [{"b.txt", "mine\n"}], "My own piece")
    mine = sha(tree, "HEAD")
    File.write!(Path.join(tree, "a.txt"), "third\n")
    assert {words, 0} = run.(["handoff"])
    assert words =~ "Committed what was uncommitted: The fix"
    assert sha(tree, "HEAD~1") == mine
    assert [%{revision: 3, stats: %{commits: 3}}] = handoffs(username)
  end

  test "sent back after its branch moved under it, the caught-up revision lands as it is",
       context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    run = cli(context, tree)
    File.write!(Path.join(tree, "a.txt"), "VM edit\n")
    assert {_, 0} = run.(["handoff", "--title", "Edit a"])

    # Another piece of work lands on master, changing the same lines.
    commit(repo, [{"a.txt", "host edit\n"}], "host work")
    {:ok, _} = Handoffs.send_back(username, 1, "Resolve the conflict")

    # The thread catches up: mwt handoff's rebase stops at the conflict,
    # the thread resolves it, and runs it again.
    assert {words, status} = run.(["handoff"])
    assert status != 0 and words =~ "a.txt"
    File.write!(Path.join(tree, "a.txt"), "host edit\nVM edit\n")
    git(tree, ["add", "a.txt"])

    assert {words, 0} = run.(["handoff"])
    assert words =~ "Continued the rebase you resolved"
    assert words =~ "Updated handoff #1 (revision 2)"

    # Measured from where it is now, not from where revision 1 was: the
    # branch's own commit is neither its work nor a conflict.
    assert [%{revision: 2, stats: stats}] = handoffs(username)

    assert %{behind: 0, commits: 1, conflicts: 0} =
             Map.take(stats, [:behind, :commits, :conflicts])

    assert {:ok, %{accepted: %{how: :as_is}}} = Handoffs.accept(username, 1)
    assert File.read!(Path.join(repo, "a.txt")) == "host edit\nVM edit\n"
  end

  test "caught up here, MWT replays its commits onto the moved branch and it lands as it is",
       context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "VM\n"}], "VM work")
    commit(tree, [{"vm2.txt", "more\n"}], "More VM work")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    [%{head: first}] = handoffs(username)
    commit(repo, [{"host.txt", "host\n"}], "host work")
    host = sha(repo, "HEAD")
    git(repo, ["config", "user.name", "Me Here"])
    git(repo, ["config", "user.email", "me@example.test"])

    assert {:ok, %{as: :one_commit, behind: 1}} = Handoffs.preview(username, 1)
    assert {:ok, caught} = Handoffs.catch_up(username, 1)
    assert %{revision: 2, base_commit: ^host} = caught
    assert caught.head != first
    assert Enum.any?(caught.timeline, &(&1.kind == :caught_up and &1.commits == 2))
    # Nothing in your repository moved: the commits are in MWT's store.
    assert sha(repo, "HEAD") == host

    # Each commit kept its author, date and words; you are its committer.
    store = HandoffStore.path(Server.call(username, :projects).dir, repo)

    assert git(store, ["log", "--format=%s|%an|%cn", "#{host}..#{caught.head}"]) ==
             "More VM work|Someone|Me Here\nVM work|Someone|Me Here\n"

    assert git(store, ["log", "-1", "--format=%ad", "--date=raw", "#{caught.head}"]) ==
             git(tree, ["log", "-1", "--format=%ad", "--date=raw", "HEAD"])

    # The revision it replaces stays reachable.
    assert git(store, ["rev-parse", "refs/handoff-revisions/1/1"]) == first <> "\n"

    assert {:ok, %{as: :as_is, behind: 0}} = Handoffs.preview(username, 1)
    assert {:ok, %{accepted: %{how: :as_is}}} = Handoffs.accept(username, 1)
    assert sha(repo, "master") == caught.head
    assert sha(repo, "master~2") == host
  end

  test "it doesn't catch up here where its changes conflict; nothing changes", context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"a.txt", "VM edit\n"}], "VM work")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    [before] = handoffs(username)
    commit(repo, [{"a.txt", "host edit\n"}], "host work")

    assert {:error, {:catch_up, {:conflicts, ["a.txt"]}} = reason} =
             Handoffs.catch_up(username, 1)

    assert Handoffs.explain(reason) =~ "Ask its thread to catch up"
    assert [^before] = handoffs(username)
  end

  test "asked to catch up, the thread hears which branch and files, and that it is the ask to hand off",
       context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"a.txt", "VM edit\n"}], "VM work")
    assert {0, _} = Channel.answer("handoff", ask(tree), username)
    commit(repo, [{"a.txt", "host edit\n"}], "host work")

    assert {:ok, handoff} = Handoffs.ask_to_catch_up(username, 1)
    assert handoff.status == :sent_back
    sent = List.last(Enum.filter(handoff.timeline, &(&1.kind == :sent_back)))
    assert sent.catch_up
    assert sent.note =~ "Catch up with master"
    assert sent.note =~ "a.txt"

    {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
    assert listed =~ "Sent back to catch up: Catch up with master"
    assert listed =~ "It is the user's ask to hand off again"
  end

  test "failed CLI checks leave the last submitted revision unchanged", context do
    %{username: username} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "first\n"}], "first")
    {0, _} = Channel.answer("handoff", ask(tree), username)
    [previous] = handoffs(username)
    commit(tree, [{"vm.txt", "second\n"}], "second")
    {:ok, _} = Projects.update(username, "app", %{"checks" => "false"})
    run = cli(context, tree)

    assert {words, 1} = run.(["handoff", "--title", "Failing revision"])
    assert words =~ "checks failed"
    assert [^previous] = handoffs(username)
  end

  test "a sent-back revision after one landed as one commit brings only later work",
       context do
    %{username: username, repo: repo} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"vm.txt", "first\n"}], "first")
    {0, _} = Channel.answer("handoff", ask(tree), username)

    {:ok, _} =
      Handoffs.accept(username, 1, {:branch, "master", "feature"}, one_commit: true)

    {:ok, _} = Handoffs.send_back(username, 1, "More")
    File.write!(Path.join(tree, "vm.txt"), "second\n")
    run = cli(context, tree)

    assert {words, 0} = run.(["handoff"])
    assert words =~ "after what landed on mwt/feature before"
    assert [%{stats: %{commits: 1}}] = handoffs(username)
    assert {:ok, _} = Handoffs.accept(username, 1)
    assert git(repo, ["show", "mwt/feature:vm.txt"]) == "second\n"
  end
end
