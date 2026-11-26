defmodule MWTClient.Sandbox.HandoffsLandingInTurnTest do
  @moduledoc """
  Where a handoff lands when another landed before it: tasks from one
  base one after the other.
  Apart from handoffs_landing_test.exs so the two run side by side.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs, Projects}

  describe "landing elsewhere" do
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
