defmodule MWTClient.Sandbox.HandoffAtTerminalTaskTest do
  # `mwt handoff` as you run it yourself, at a terminal in the VM, on a
  # task's branch: finishing one an agent left, a run that stops, a new
  # revision, and asking nothing when given everything. Apart from
  # handoff_at_terminal_test.exs so the two run side by side.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Projects}

  setup %{username: username, repo: repo} do
    {:ok, _} = Projects.open(username, repo)
    :ok
  end

  describe "on a task's branch" do
    test "an agent's task, left half done: you finish it by hand", context do
      %{username: username, mirror: mirror} = context
      {:ok, "slot-1"} = Projects.add_slot(username, "app")
      tree = slot(mirror, 1)

      assert {0, _} =
               Channel.answer(
                 "worktree",
                 %{
                   "cwd" => tree,
                   "name" => "fix-login",
                   "from" => "master",
                   "thread_id" => "t-1"
                 },
                 username
               )

      # The agent ran out of quota with part of it committed; you finish
      # the rest.
      commit(tree, [{"a.txt", "half\n"}], "Half of the fix")
      File.write!(Path.join(tree, "a.txt"), "done by hand\n")
      run = at_terminal(context, tree)

      assert {shown, 0} = run.(["handoff"], "fix(login): the timeout\n", "Finished by hand.")
      refute shown =~ "isn't a task"
      assert shown =~ "Handed off as #1"

      assert [
               %{
                 title: "fix(login): the timeout",
                 body: "Finished by hand.",
                 thread_id: nil,
                 stats: %{commits: 2}
               }
             ] = handoffs(username)
    end

    test "a run that stops keeps the title you typed for the next", context do
      %{username: username} = context
      {_project, tree} = project_with_worktree(context)
      File.write!(Path.join(tree, "a.txt"), "fixed\n")
      File.write!(Path.join(tree, "new.txt"), "new\n")
      run = at_terminal(context, tree)

      assert {shown, 1} = run.(["handoff"], "fix: it\n", "unused")
      assert shown =~ "these files are new and not in git"
      assert handoffs(username) == []

      git(tree, ["add", "new.txt"])
      assert {shown, 0} = run.(["handoff"], "\n", "The notes.")
      assert shown =~ "Title of the handoff [fix: it]: "
      assert [%{title: "fix: it", body: "The notes."}] = handoffs(username)

      # Handed off: nothing typed is kept.
      gitdir = String.trim(git(tree, ["rev-parse", "--absolute-git-dir"]))
      refute File.exists?(Path.join(gitdir, "mwt-handoff/fix"))
    end

    test "a new revision starts from the open handoff's title and notes", context do
      %{username: username} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "fixed\n"}], "Fix")
      assert {0, _} = Channel.answer("handoff", ask(tree, %{"body" => "Done."}), username)
      File.write!(Path.join(tree, "a.txt"), "fixed better\n")
      run = at_terminal(context, tree)

      assert {shown, 0} = run.(["handoff"], "\n", "And better.")
      assert shown =~ "Title of the handoff [The fix]: "
      assert shown =~ "Updated handoff #1 (revision 2)"
      assert editor_saw(context) =~ ~r/\ADone.\n\n# -+ >8 -+\n/
      assert editor_saw(context) =~ "Left empty, it keeps the notes it has."
      assert [%{title: "The fix", body: "And better.\nDone.", revision: 2}] = handoffs(username)
    end

    test "given the title and the notes, it asks nothing more", context do
      %{username: username, base: base} = context
      {_project, tree} = project_with_worktree(context)
      File.write!(Path.join(tree, "a.txt"), "fixed\n")
      notes = Path.join(base, "notes.md")
      File.write!(notes, "From a file.")
      run = at_terminal(context, tree)

      assert {shown, 0} = run.(["handoff", "--title", "fix: it", "--body", notes], "", "unused")
      refute shown =~ "Title of the handoff"
      assert [%{title: "fix: it", body: "From a file."}] = handoffs(username)
      refute File.exists?(Path.join(base, "editor-saw"))
    end
  end
end
