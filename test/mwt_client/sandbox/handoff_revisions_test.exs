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

    assert git(clone, ["config", "--get", "remote.host-origin.url"]) ==
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
end
