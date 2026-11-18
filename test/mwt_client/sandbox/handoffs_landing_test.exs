defmodule MWTClient.Sandbox.HandoffsLandingTest do
  @moduledoc """
  Where a handoff lands besides its base: another branch, a new one, and
  tasks based on branches other than the default.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoff, Handoffs, Project, Projects}

  describe "landing elsewhere" do
    test "a new branch leaves your branches and a dirty checkout alone", context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"task.txt", "task\n"}], "the task")
      {0, _} = Channel.answer("handoff", ask(tree), username)
      before = sha(repo, "HEAD")
      File.write!(Path.join(repo, "a.txt"), "uncommitted host work\n")
      status = git(repo, ["status", "--porcelain"])

      assert {:ok, %{new_branch?: true, branch: "mwt/fix", from: "master", worktree: nil}} =
               Handoffs.preview(username, 1, {:branch, "master", "fix"})

      assert {:ok, handoff} = Handoffs.accept(username, 1, {:branch, "master", "fix"})
      assert %{branch: "mwt/fix", from: "master", new_branch?: true} = handoff.accepted

      assert Handoffs.accepted_words(handoff.accepted) ==
               "its commit as it is on a new branch, mwt/fix, from master"

      assert sha(repo, "mwt/fix") == sha(tree, "HEAD")

      assert sha(repo, "mwt/fix~1") == before
      assert sha(repo, "mwt/fix^{tree}") == sha(tree, "HEAD^{tree}")
      assert sha(repo, "HEAD") == before
      assert git(repo, ["status", "--porcelain"]) == status
      assert File.read!(Path.join(repo, "a.txt")) == "uncommitted host work\n"
      assert {:ok, %{commits: [_], files: [_]}} = Handoffs.facts(username, 1)

      assert {:ok, _} = Handoffs.undo(username, 1)
      assert git(repo, ["branch", "--list", "mwt/fix"]) == ""
      assert git(repo, ["status", "--porcelain"]) == status
    end

    test "a new branch never overwrites one, nor one it would have to be a folder of", context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"task.txt", "task\n"}], "the task")
      {0, _} = Channel.answer("handoff", ask(tree), username)
      git(repo, ["branch", "mwt/fix"])
      git(repo, ["branch", "mwt/nested/one"])
      before = sha(repo, "mwt/fix")

      assert {:error, :bad_destination} = Handoffs.accept(username, 1, {:branch, "master", ""})

      assert {:error, :bad_destination} =
               Handoffs.accept(username, 1, {:branch, "master", "bad branch"})

      assert {:error, {:branch_exists, "mwt/fix"}} =
               Handoffs.accept(username, 1, {:branch, "master", "fix"})

      assert {:error, {:branch_exists, "mwt/nested"}} =
               Handoffs.preview(username, 1, {:branch, "master", "nested"})

      assert sha(repo, "mwt/fix") == before
      assert {:ok, handoff} = Handoffs.accept(username, 1, {:branch, "master", "fix-2"})
      assert handoff.accepted.branch == "mwt/fix-2"
    end

    test "a branch called mwt makes new branches start with mwt-", context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"task.txt", "task\n"}], "the task")
      {0, _} = Channel.answer("handoff", ask(tree), username)
      git(repo, ["branch", "mwt"])
      assert {:ok, %{prefix: "mwt-"}} = Handoffs.landing(username, 1)
      assert {:ok, handoff} = Handoffs.accept(username, 1, {:branch, "master", "fix"})
      assert handoff.accepted.branch == "mwt-fix"
    end

    test "any branch takes it where its changes apply; master stays as it was", context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"task.txt", "task\n"}], "the task")
      {0, _} = Channel.answer("handoff", ask(tree), username)
      git(repo, ["checkout", "-q", "-b", "release"])
      commit(repo, [{"release.txt", "release\n"}], "release work")
      release = sha(repo, "HEAD")
      git(repo, ["branch", "clash"])
      git(repo, ["checkout", "-q", "clash"])
      commit(repo, [{"task.txt", "theirs\n"}], "clash")
      git(repo, ["checkout", "-q", "master"])
      master = sha(repo, "HEAD")

      assert {:ok, %{branches: branches, onto: "master"}} = Handoffs.landing(username, 1)

      assert Enum.map(branches, &{&1.branch, &1.default?}) ==
               [{"clash", false}, {"master", true}, {"release", false}]

      assert {:ok, %{conflicts: ["task.txt"]}} = Handoffs.preview(username, 1, {:commit, "clash"})

      assert {:ok, %{conflicts: [], behind: 1, worktree: nil}} =
               Handoffs.preview(username, 1, {:commit, "release"})

      assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "release"})
      assert landed.accepted.branch == "release"
      assert sha(repo, "release~1") == release
      assert git(repo, ["show", "release:task.txt"]) == "task\n"
      assert git(repo, ["show", "release:release.txt"]) == "release\n"
      assert sha(repo, "master") == master
      assert sha(repo, "HEAD") == master
      assert git(repo, ["status", "--porcelain"]) == ""

      assert {:ok, _} = Handoffs.undo(username, 1)
      assert sha(repo, "release") == release
    end

    test "later revisions land where the previous revision did, caught up with it",
         context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      mwt = cli(context, tree)
      commit(tree, [{"task.txt", "task\n"}], "first")
      {_, 0} = mwt.(["handoff", "--title", "The fix"])
      {:ok, first} = Handoffs.accept(username, 1, {:branch, "master", "fix"})
      branch = first.accepted.branch
      {:ok, _} = Handoffs.send_back(username, 1, "More work")
      first_head = sha(tree, "HEAD")
      File.write!(Path.join(tree, "task.txt"), "revision\n")
      assert {said, 0} = mwt.(["handoff", "--title", "The fix"])
      refute said =~ "Rebased"
      assert sha(tree, "HEAD~1") == first_head
      assert {:ok, _} = Handoffs.accept(username, 1)
      assert git(repo, ["show", branch <> ":task.txt"]) == "revision\n"

      {:ok, _} = Handoffs.send_back(username, 1, "Another revision")
      git(repo, ["checkout", "-q", branch])
      commit(repo, [{"host.txt", "host\n"}], "host work")
      host = sha(repo, "HEAD")
      git(repo, ["checkout", "-q", "master"])
      File.write!(Path.join(tree, "task.txt"), "another revision\n")
      # It catches up with what you added there before it goes.
      assert {said, 0} = mwt.(["handoff", "--title", "The fix"])
      assert said =~ "Rebased onto origin/#{branch}"
      assert sha(tree, "HEAD~1") == host
      assert {:ok, updated} = Handoffs.accept(username, 1)
      assert updated.accepted.branch == branch
      assert sha(repo, branch <> "~1") == host
      assert git(repo, ["show", branch <> ":host.txt"]) == "host\n"
      assert git(repo, ["show", branch <> ":task.txt"]) == "another revision\n"
      assert {:ok, %Handoff{landed: nil}} = Handoffs.undo(username, 1)
    end

    test "tasks from one base land one after the other, the second caught up first", context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, first} = project_with_worktree(context, "task-a")
      second = new_worktree(mirror, "task-b")

      baseline = sha(repo, "master")
      commit(first, [{"first.txt", "A\n"}], "task A")
      commit(second, [{"second.txt", "B\n"}], "task B")
      {0, _} = Channel.answer("handoff", ask(first, %{"title" => "Task A"}), username)
      {0, _} = Channel.answer("handoff", ask(second, %{"title" => "Task B"}), username)
      assert {:ok, _} = Handoffs.accept(username, 1)
      assert sha(repo, "master~1") == baseline
      assert {:ok, %{behind: 1}} = Handoffs.facts(username, 2)

      # The mirror follows; B's ongoing edits stay intact.
      File.write!(Path.join(second, "second.txt"), "B in progress\n")
      assert :ok = Projects.fresh(username, "app")
      assert sha(mirror, "HEAD") == baseline
      assert File.read!(Path.join(second, "second.txt")) == "B in progress\n"
      refute File.exists?(Path.join(second, "first.txt"))

      # Now, B lands on top of A only as one commit, untested with it; a
      # revision of B must catch up first.
      assert {:ok, %{behind: 1, conflicts: []}} =
               Handoffs.preview(username, 2, {:commit, "master"})

      b = ask(second, %{"title" => "Task B"})
      assert {1, refusal} = Channel.answer("handoff", b, username)
      assert refusal =~ "Commit or discard"
      commit(second, [{"second.txt", "B done\n"}], "finish B")
      assert {1, behind} = Channel.answer("handoff", b, username)
      assert behind =~ "has 1 commit this branch doesn't have"

      # mwt handoff catches up first: B goes as it is, on top of A.
      assert {said, 0} = cli(context, second).(["handoff", "--title", "Task B"])
      assert said =~ "Rebased onto origin/master"
      assert {:ok, %{behind: 0, as: :as_is}} = Handoffs.preview(username, 2, {:commit, "master"})
      assert {:ok, _} = Handoffs.accept(username, 2)
      assert sha(repo, "master") == sha(second, "HEAD")
      assert git(repo, ["log", "--format=%s", "-3"]) == "finish B\ntask B\ntask A\n"
      assert File.read!(Path.join(repo, "first.txt")) == "A\n"
      assert File.read!(Path.join(repo, "second.txt")) == "B done\n"
    end

    test "new projects prefer main, then master, and upgrades preserve the chosen baseline",
         context do
      %{repo: repo} = context
      git(repo, ["checkout", "-q", "-b", "feature"])
      assert {:ok, %Project{mirrored_branch: "master"} = project} = Project.new(repo, [])
      git(repo, ["branch", "main"])
      assert {:ok, %Project{mirrored_branch: "main"}} = Project.new(repo, [])

      old =
        project
        |> Map.delete(:mirrored_branch)
        |> Map.put(:default_target, "feature")
        |> Map.put(:targets, ["master", "feature"])

      assert %Project{mirrored_branch: "feature"} = Project.upgrade(old)
      refute Map.has_key?(Project.upgrade(old), :targets)
    end
  end

  describe "tasks based on other branches" do
    test "a later task based on a landed branch lands on it again by default", context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, first} = project_with_worktree(context, "login-feature")
      commit(first, [{"login.txt", "first\n"}], "login first")
      commit(first, [{"login.txt", "second\n"}], "login second")
      {0, _} = Channel.answer("handoff", ask(first), username)

      {:ok, first_handoff} =
        Handoffs.accept(username, 1, {:branch, "master", "login-feature"})

      feature = first_handoff.accepted.branch
      assert feature == "mwt/login-feature"
      # Its two commits land as they are.
      assert git(repo, ["rev-list", "--count", "master.." <> feature]) == "2\n"
      assert sha(repo, feature) == sha(first, "HEAD")
      assert {:ok, %{commits: [_, _]}} = Handoffs.facts(username, 1)

      git(mirror, ["fetch", repo, "+refs/heads/#{feature}:refs/remotes/origin/#{feature}"])
      second = new_worktree(mirror, "tweak-login", "refs/remotes/origin/" <> feature)
      git(second, ["branch", "--set-upstream-to", "origin/" <> feature])

      assert sha(second, "HEAD") == sha(repo, feature)
      commit(second, [{"login.txt", "third\n"}], "login third")
      commit(second, [{"login.txt", "fourth\n"}], "login fourth")

      # Main advancing does not force an unrelated merge into a feature-based task.
      commit(repo, [{"main.txt", "unrelated\n"}], "main work")
      main = sha(repo, "master")
      assert {:ok, plan} = Handoffs.prepare(username, %{cwd: second, title: "Tweak login"})
      assert plan.onto == feature
      assert plan.ref == "refs/remotes/origin/" <> feature

      assert {:ok, second_handoff, :opened} =
               Handoffs.open(username, %{cwd: second, title: "Tweak login"})

      assert second_handoff.id != first_handoff.id
      assert second_handoff.base_branch == feature
      assert {:ok, %{onto: ^feature}} = Handoffs.landing(username, second_handoff.id)
      assert {:ok, landed} = Handoffs.accept(username, second_handoff.id)
      assert landed.accepted.branch == feature
      assert git(repo, ["rev-list", "--count", "master~1.." <> feature]) == "4\n"
      assert sha(repo, feature) == sha(second, "HEAD")
      assert git(repo, ["show", feature <> ":login.txt"]) == "fourth\n"
      assert sha(repo, "master") == main
      assert {:ok, %{commits: [_, _]}} = Handoffs.facts(username, second_handoff.id)
    end

    test "a VM task branch and a pinned commit are valid bases", context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, parent} = project_with_worktree(context, "parent-feature")
      pinned = sha(repo, "master")
      commit(parent, [{"parent.txt", "parent\n"}], "parent first")
      child = new_worktree(mirror, "child-feature", "refs/heads/parent-feature")
      snapshot = new_worktree(mirror, "snapshot-task", pinned)

      commit(child, [{"child.txt", "child\n"}], "child work")
      commit(parent, [{"more-parent.txt", "more\n"}], "parent second")

      assert {:ok, child_handoff, :opened} =
               Handoffs.open(username, %{
                 cwd: child,
                 title: "Child",
                 onto: "refs/heads/parent-feature"
               })

      assert child_handoff.base_branch == nil
      assert child_handoff.base_ref == "refs/heads/parent-feature"
      assert {:ok, %{files: [%{path: "child.txt"}]}} = Handoffs.facts(username, child_handoff.id)

      # With no host branch for a base, it lands on your default branch:
      # only what it changed since its base, not the parent's work.
      assert {:ok, %{onto: "master"}} = Handoffs.landing(username, child_handoff.id)
      assert {:ok, _} = Handoffs.accept(username, child_handoff.id)
      assert git(repo, ["show", "master:child.txt"]) == "child\n"
      refute git(repo, ["ls-tree", "--name-only", "master"]) =~ "parent.txt"

      commit(repo, [{"new-main.txt", "new main\n"}], "main advances")

      assert sha(snapshot, "HEAD") == pinned
      commit(snapshot, [{"snapshot.txt", "snapshot\n"}], "snapshot work")

      assert {:ok, plan} =
               Handoffs.prepare(username, %{cwd: snapshot, title: "Snapshot", onto: pinned})

      assert plan.ref == pinned

      assert {:ok, handoff, :opened} =
               Handoffs.open(username, %{cwd: snapshot, title: "Snapshot", onto: pinned})

      assert {:ok, %{behind: 2}} = Handoffs.preview(username, handoff.id)
      assert {:ok, _} = Handoffs.accept(username, handoff.id)
      assert git(repo, ["show", "master:snapshot.txt"]) == "snapshot\n"
      assert git(repo, ["show", "master:new-main.txt"]) == "new main\n"
      refute File.exists?(Path.join(snapshot, "new-main.txt"))
    end

    test "host metadata refresh leaves origin references and local work unchanged", context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, tree} = project_with_worktree(context)
      before = git(mirror, ["for-each-ref", "refs/remotes/origin/"])
      git(repo, ["checkout", "-q", "-b", "release"])
      commit(repo, [{"release.txt", "release\n"}], "release work")
      git(repo, ["checkout", "-q", "master"])
      File.write!(Path.join(tree, "a.txt"), "ongoing\n")
      assert :ok = Projects.fresh(username, "app")
      assert git(mirror, ["for-each-ref", "refs/remotes/origin/"]) == before
      assert File.read!(Path.join(tree, "a.txt")) == "ongoing\n"
      assert "release" in Projects.mirrored(username, "app")
    end
  end
end
