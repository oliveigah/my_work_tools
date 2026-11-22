defmodule MWTClient.Sandbox.HandoffsLandingInTurnTest do
  @moduledoc """
  Where a handoff lands when another landed before it: a later revision
  where the previous one did, tasks from one base one after the other.
  Apart from handoffs_landing_test.exs so the two run side by side.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoff, Handoffs, Projects}

  describe "landing elsewhere" do
    test "later revisions land where the previous revision did, caught up with it",
         context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      mwt = cli(context, tree)
      commit(tree, [{"task.txt", "task\n"}], "first")
      {_, 0} = mwt.(["handoff", "--title", "The fix"])
      {:ok, first} = Handoffs.accept(username, 1, {:branch, "master", "fix"})
      branch = first.accepted.branch
      # Each landing deleted the task's branch: sent back, its thread
      # makes it again before it changes anything.
      {:ok, _} = Handoffs.send_back(username, 1, "More work")
      {_, 0} = mwt.(["worktree", "resume", "fix"])
      first_head = sha(tree, "HEAD")
      File.write!(Path.join(tree, "task.txt"), "revision\n")
      assert {said, 0} = mwt.(["handoff", "--title", "The fix"])
      refute said =~ "Rebased"
      assert sha(tree, "HEAD~1") == first_head
      assert {:ok, _} = Handoffs.accept(username, 1)
      assert git(repo, ["show", branch <> ":task.txt"]) == "revision\n"

      {:ok, _} = Handoffs.send_back(username, 1, "Another revision")
      {_, 0} = mwt.(["worktree", "resume", "fix"])
      git(repo, ["checkout", "-q", branch])
      commit(repo, [{"host.txt", "host\n"}], "host work")
      host = sha(repo, "HEAD")
      git(repo, ["checkout", "-q", "master"])
      File.write!(Path.join(tree, "task.txt"), "another revision\n")
      # It catches up with what you added there before it goes.
      assert {said, 0} = mwt.(["handoff", "--title", "The fix"])
      assert said =~ "Rebased onto host-origin/#{branch}"
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
      assert said =~ "Rebased onto host-origin/master"
      assert {:ok, %{behind: 0, as: :as_is}} = Handoffs.preview(username, 2, {:commit, "master"})
      assert {:ok, _} = Handoffs.accept(username, 2)
      assert sha(repo, "master") == sha(second, "HEAD")
      assert git(repo, ["log", "--format=%s", "-3"]) == "finish B\ntask B\ntask A\n"
      assert File.read!(Path.join(repo, "first.txt")) == "A\n"
      assert File.read!(Path.join(repo, "second.txt")) == "B done\n"
    end
  end
end
