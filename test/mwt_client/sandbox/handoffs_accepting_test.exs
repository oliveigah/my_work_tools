defmodule MWTClient.Sandbox.HandoffsAcceptingTest do
  @moduledoc """
  A handoff accepted: onto its base or a branch that moved, as it is or as
  one commit, undone while it stays there. What doesn't land has
  handoffs_sent_back_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoff, Handoffs, Projects, Server}

  describe "accepting" do
    setup context do
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(tree), context.username)
      %{tree: tree}
    end

    test "waits for a target branch with no pending work", %{username: username, repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "pending\n")

      assert {:error, {:pending, "master", ^repo, ["a.txt"]}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      assert {:error, {:pending, _, _, _} = pending} =
               Handoffs.accept(username, 1, {:commit, "master"})

      assert Handoffs.explain(pending) =~ "work you haven't committed: a.txt"
      git(repo, ["checkout", "-q", "--", "a.txt"])

      # Files git doesn't track don't count.
      File.write!(Path.join(repo, "notes.txt"), "mine\n")

      assert {:ok, %{conflicts: [], worktree: ^repo, behind: 0}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      git(repo, ["checkout", "-q", "-b", "elsewhere"])
      assert {:ok, %{worktree: nil}} = Handoffs.preview(username, 1, {:commit, "master"})
    end

    test "as it is on its base by default, undone while it stays there", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      before = sha(repo, "HEAD")
      assert {:ok, %{onto: "master", prefix: "mwt/", name: "fix"}} = Handoffs.landing(username, 1)

      assert {:ok, %{as: :as_is, fast_forward?: true, commits: 1}} =
               Handoffs.preview(username, 1)

      assert {:ok, %Handoff{status: :accepted, accepted: %{how: :as_is, branch: "master"}}} =
               Handoffs.accept(username, 1)

      # Its own commit, as the VM has it: master moved to it.
      assert sha(repo, "HEAD") == sha(tree, "HEAD")
      assert sha(repo, "HEAD~1") == before
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
      assert git(repo, ["status", "--porcelain"]) == ""
      refute git(repo, ["for-each-ref"]) =~ "refs/mwt/handoffs/"

      assert {:ok, %Handoff{status: :open}} = Handoffs.undo(username, 1)
      assert sha(repo, "HEAD") == before
      refute File.exists?(Path.join(repo, "b.txt"))
    end

    test "as one commit when you choose, undone while it stays there", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      before = sha(repo, "HEAD")

      assert {:ok, %{as: :one_commit, fast_forward?: true}} =
               Handoffs.preview(username, 1, nil, one_commit: true)

      assert {:ok, %Handoff{status: :accepted, accepted: %{how: :commit, branch: "master"}}} =
               Handoffs.accept(username, 1, nil, one_commit: true)

      # One commit on what master was, with the task's tree, its title and you.
      assert sha(repo, "HEAD~1") == before
      assert sha(repo, "HEAD^{tree}") == sha(tree, "HEAD^{tree}")
      assert git(repo, ["log", "-1", "--format=%s|%an|%cn"]) == "The fix|Someone|Someone\n"
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
      assert git(repo, ["status", "--porcelain"]) == ""
      refute git(repo, ["for-each-ref"]) =~ "refs/mwt/handoffs/"

      assert {:ok, %Handoff{status: :open}} = Handoffs.undo(username, 1)
      assert sha(repo, "HEAD") == before
      refute File.exists?(Path.join(repo, "b.txt"))
    end

    test "undo leaves another branch checked out at the same commit alone", %{
      username: username,
      repo: repo
    } do
      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      head = sha(repo, "HEAD")
      git(repo, ["checkout", "-q", "-b", "other-work"])
      assert {:error, :moved} = Handoffs.undo(username, 1)
      assert sha(repo, "master") == head
      assert sha(repo, "HEAD") == head
    end

    test "on a branch that moved since, its changes go on top, counted as untested", %{
      username: username,
      repo: repo
    } do
      commit(repo, [{"c.txt", "yours\n"}], "yours")
      yours = sha(repo, "HEAD")

      assert {:ok, %{conflicts: [], behind: 1, up_to_date?: false}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      assert sha(repo, "HEAD~1") == yours
      assert File.read!(Path.join(repo, "c.txt")) == "yours\n"
      assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo\nthree\nfour\n"
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
    end

    test "a branch that has it all already takes nothing", %{username: username, repo: repo} do
      commit(repo, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "same")
      before = sha(repo, "HEAD")

      assert {:ok, %{up_to_date?: true}} = Handoffs.preview(username, 1, {:commit, "master"})
      assert {:error, :up_to_date} = Handoffs.accept(username, 1, {:commit, "master"})
      assert sha(repo, "HEAD") == before
    end

    test "with no identity on your machine no commit is made for it", %{
      username: username,
      repo: repo
    } do
      before = sha(repo, "HEAD")
      git(repo, ["config", "user.name", ""])

      assert {:error, :no_identity = reason} =
               Handoffs.accept(username, 1, {:commit, "master"}, one_commit: true)

      assert Handoffs.explain(reason) =~ "set user.name and user.email"
      assert sha(repo, "HEAD") == before
    end

    # Its files are on your branch from that moment: MWT stopping right
    # after, with no clean stop to save it, must not show it open again.
    test "is on disk as accepted when it returns", %{username: username, key: key} do
      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      assert [%Handoff{status: :accepted}] = Server.State.restore(username, key).handoffs
    end

    # To look at it again, it is opened where it was reviewed: in the VM.
    test "says where its branch is in the VM while it waits", %{username: username, tree: tree} do
      assert {:ok, %{path: ^tree, slot: "slot-1"}} = Handoffs.worktree(username, 1)
      git(tree, ["switch", "--detach", "HEAD"])
      assert {:ok, nil} = Handoffs.worktree(username, 1)
    end

    test "conflicts once your branch moved: sent back to its thread with a note", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      commit(repo, [{"a.txt", "one\ntwo\nthree\nyours\n"}], "yours")

      assert {:ok, %{conflicts: ["a.txt"]}} = Handoffs.preview(username, 1, {:commit, "master"})

      assert {:error, {:conflicts, "master", ["a.txt"]} = reason} =
               Handoffs.accept(username, 1, {:commit, "master"})

      assert Handoffs.explain(reason) =~ "Its changes conflict with master in: a.txt"
      assert git(repo, ["status", "--porcelain"]) == ""

      assert {:ok, %Handoff{status: :sent_back}} =
               Handoffs.send_back(username, 1, "Catch up with mine.")

      {:ok, _} = Projects.mirror(username, "app")
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
      assert listed =~ "sent back to you" and listed =~ "Catch up with mine."
      assert listed =~ "conflicts with their master in: a.txt"

      assert {:ok, %Handoff{status: :closed}} = Handoffs.close(username, 1)
      assert Handoffs.accept(username, 1, {:commit, "master"}) == {:error, :not_open}
      assert {:ok, %Handoff{status: :open}} = Handoffs.reopen(username, 1)
    end
  end
end
