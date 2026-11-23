defmodule MWTClient.Sandbox.HandoffAtTerminalTest do
  # `mwt handoff` as you run it yourself, at a terminal in the VM, on a
  # branch of your own: it offers to make it a task, based on the branch it
  # came from, asks the title and opens git's editor for the notes. An agent
  # is never asked. On a task's branch: handoff_at_terminal_task_test.exs;
  # what MWT answers: handoff_by_hand_test.exs.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.Projects

  setup %{username: username, repo: repo} do
    {:ok, _} = Projects.open(username, repo)
    :ok
  end

  describe "on a branch of yours" do
    test "it is offered as a task, then you are asked the title and the notes", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo"])
      File.write!(Path.join(clone, "a.txt"), "fixed\n")
      run = at_terminal(context, clone)

      assert {shown, 0} = run.(["handoff"], "\nfix: the typo\n", "It fixes the typo.")

      assert shown =~
               "fix-typo isn't a task yet, and only a task hands off. Make it one, based on master (it came from master)?"

      assert shown =~ "Made fix-typo a task based on master"
      assert shown =~ "Title of the handoff: "
      assert shown =~ "Committed what was uncommitted: fix: the typo"
      assert shown =~ "Handed off as #1"

      assert [%{title: "fix: the typo", body: "It fixes the typo.", base_branch: "master"}] =
               handoffs(username)

      assert editor_saw(context) =~ "# ------------------------ >8 ------------------------"
      assert editor_saw(context) =~ "Left empty, it goes with no notes."
      assert git(clone, ["log", "-1", "--format=%s"]) == "fix: the typo\n"
    end

    test "declining the offer hands nothing off, and the branch stays as it was", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo"])
      commit(clone, [{"a.txt", "fixed\n"}], "Fix the typo")
      run = at_terminal(context, clone)

      assert {shown, 1} = run.(["handoff", "--title", "fix: it"], "n\n", "unused")
      assert shown =~ "nothing was handed off"
      assert handoffs(username) == []
      assert {0, "task=no" <> _} = about_branch(username, clone)
    end

    test "the title kept is the branch's own: another branch in the same folder starts afresh",
         context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "first-fix"])
      File.write!(Path.join(clone, "new.txt"), "new\n")
      run = at_terminal(context, clone)
      assert {_, 1} = run.(["handoff"], "\nfix: the first\n", "unused")

      File.rm!(Path.join(clone, "new.txt"))
      git(clone, ["switch", "-q", "-c", "second-fix", "master"])
      File.write!(Path.join(clone, "a.txt"), "second\n")

      assert {shown, 0} = run.(["handoff"], "\nfix: the second\n", "Second.")
      refute shown =~ "[fix: the first]"
      assert [%{title: "fix: the second"}] = handoffs(username)
    end
  end

  describe "an agent" do
    test "is never asked: a branch that isn't a task is refused, as before", context do
      %{username: username, mirror: clone} = context
      git(clone, ["switch", "-q", "-c", "fix-typo"])
      commit(clone, [{"a.txt", "fixed\n"}], "Fix the typo")

      assert {said, 1} = cli(context, clone).(["handoff", "--title", "fix: it"])
      assert said =~ "fix-typo isn't a task's branch"
      refute said =~ "Make it one"
      assert handoffs(username) == []
    end

    test "with no title and no handoff open, is told to give one", context do
      {_project, tree} = project_with_worktree(context)
      File.write!(Path.join(tree, "a.txt"), "fixed\n")

      assert {said, 1} = cli(context, tree).(["handoff"])
      assert said =~ "Give it a title"
    end
  end
end
