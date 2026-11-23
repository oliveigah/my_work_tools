defmodule MWTClient.Sandbox.HandoffByHandTest do
  # What MWT answers `mwt handoff` when you run it yourself, at a terminal
  # in the VM: what it offers as the base of a branch of yours, from the
  # branch it came from, and making that branch a task. What you see at the
  # terminal is in handoff_at_terminal_test.exs, apart so the two run side
  # by side.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Projects}

  setup %{username: username, repo: repo} do
    {:ok, _} = Projects.open(username, repo)
    :ok
  end

  defp make_task(username, cwd, onto \\ ""),
    do: Channel.answer("handoff", %{"stage" => "task", "cwd" => cwd, "onto" => onto}, username)

  describe "the base a branch of yours is offered" do
    test "made where you were, on the clone's master: your master", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo"])

      assert {0, "task=no\nonto=master\nfrom=master"} = about_branch(username, clone)
    end

    test "made from your branch as the clone has it", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo", "host-origin/master"])

      assert {0, "task=no\nonto=master\nfrom=host-origin/master"} = about_branch(username, clone)
    end

    test "made from a VM task: stacked on that task", context do
      %{username: username, mirror: clone} = context
      new_worktree(clone, "topic")
      git(clone, ["switch", "-q", "-c", "on-top", "topic"])

      assert {0, "task=no\nonto=topic\nfrom=topic"} = about_branch(username, clone)
    end

    test "made from no branch: your default branch, with nothing said of where", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "--detach", "master"])
      git(clone, ["switch", "-q", "-c", "loose"])

      assert {0, "task=no\nonto=master\nfrom="} = about_branch(username, clone)
    end

    test "a branch named like one of yours is refused: it would be deleted once it lands",
         context do
      %{username: username, mirror: clone} = context

      assert {1, said} = about_branch(username, clone)
      assert said =~ "master is also the name of one of your branches"
      assert {1, ^said} = make_task(username, clone)
    end
  end

  describe "a task's branch" do
    test "says it is one, with its open handoff's title and notes", context do
      %{username: username} = context
      {_project, tree} = project_with_worktree(context)

      assert {0, "task=yes"} = about_branch(username, tree)

      commit(tree, [{"a.txt", "fixed\n"}], "Fix")

      assert {0, _} =
               Channel.answer("handoff", ask(tree, %{"body" => "Done.\n\nTwo lines."}), username)

      assert {0, "task=yes\nhandoff=1\ntitle=The fix\n--\nDone.\n\nTwo lines."} =
               about_branch(username, tree)

      assert {1, "fix is a task already: mwt handoff hands it off as it is."} =
               make_task(username, tree)
    end
  end

  describe "making a branch of yours a task" do
    test "records the base offered, and it hands off as a task does", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo"])
      commit(clone, [{"a.txt", "fixed\n"}], "Fix the typo")

      assert {0, said} = make_task(username, clone)
      assert said =~ "Made fix-typo a task based on master"

      assert git(clone, ["config", "branch.fix-typo.mwt-base"]) ==
               "refs/remotes/host-origin/master\n"

      assert {0, "task=yes"} = about_branch(username, clone)
      assert {0, _} = Channel.answer("handoff", ask(clone, %{"agent" => nil}), username)
      assert [%{base_branch: "master", stats: %{commits: 1}}] = handoffs(username)
    end

    test "on another branch of yours you name", context do
      %{username: username, repo: repo, mirror: clone} = context
      git(repo, ["branch", "release"])
      git(clone, ["fetch", "-q", repo, "+refs/heads/*:refs/remotes/host-origin/*"])
      git(clone, ["switch", "-q", "-c", "fix-typo"])

      assert {0, said} = make_task(username, clone, "release")
      assert said =~ "based on release"

      assert git(clone, ["config", "branch.fix-typo.mwt-base"]) ==
               "refs/remotes/host-origin/release\n"
    end
  end
end
