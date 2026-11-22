defmodule MWTClient.Sandbox.HandoffsSlotsUpkeepTest do
  @moduledoc """
  Worktree slots kept in order: added and removed, locked, made again by
  the mirror's updates, never switched under uncommitted work, freed and
  resumed. Taking and holding one has handoffs_slots_test.exs, so the two
  run side by side.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Guest, Handoff, Handoffs, Project, Projects}

  describe "worktree slots" do
    setup {MWTClient.HandoffsCase, :with_slots}

    test "slots are added and removed one at a time; a new one takes the lowest number missing",
         %{
           username: username,
           repo: repo,
           mirror: mirror
         } do
      two = slot(mirror, 2)
      File.mkdir_p!(Path.join(two, "_build"))
      File.write!(Path.join(two, "_build/app.beam"), "warm\n")

      # A free slot goes, with its build; the others keep their numbers.
      assert :ok = Projects.remove_slot(username, "app", "slot-2")
      refute File.exists?(two)
      refute git(mirror, ["worktree", "list"]) =~ "slot-2"
      assert [{"slot-1", nil, true}, {"slot-3", nil, true}] = states(username)
      assert [%Project{slots: [1, 3]}] = Projects.list(username)

      # A slot a task holds stays: with uncommitted work, or before its
      # handoff is accepted or closed.
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      File.write!(Path.join(one, "notes.txt"), "not committed\n")
      assert {:error, {:slot_busy, %{state: :dirty}}} = Projects.remove_slot(username, "app", "1")
      File.rm!(Path.join(one, "notes.txt"))
      assert {:error, {:slot_busy, _}} = Projects.remove_slot(username, "app", "slot-1")
      assert File.dir?(one)

      assert {:error, {:no_such_slot, "slot-2", ["slot-0", "slot-1", "slot-3"]}} =
               Projects.remove_slot(username, "app", "slot-2")

      # Added again, it takes the number missing, made at once and free.
      assert {:ok, "slot-2"} = Projects.add_slot(username, "app")
      assert sha(two, "HEAD") == sha(repo, "master")
      assert {:ok, "slot-4"} = Projects.add_slot(username, "app")
      for _n <- 5..9, do: assert({:ok, _} = Projects.add_slot(username, "app"))
      assert {:error, :no_more_slots} = Projects.add_slot(username, "app")

      # One whose folder is gone just loses its number.
      File.rm_rf!(slot(mirror, 9))
      assert :ok = Projects.remove_slot(username, "app", "slot-9")
      assert [%Project{slots: [1, 2, 3, 4, 5, 6, 7, 8]}] = Projects.list(username)

      # Projects saved with a count of slots, or none, keep the ones they had.
      [project] = Projects.list(username)
      assert %Project{slots: [1, 2]} = Project.upgrade(%{project | slots: 2})
      assert %Project{slots: [1, 2, 3]} = Project.upgrade(Map.delete(project, :slots))
    end

    test "a slot is locked, so git worktree remove leaves it; one whose folder went is made again",
         %{username: username, mirror: mirror} do
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})

      assert git(mirror, ["worktree", "list", "--porcelain"]) =~ "locked MWT worktree slot"

      # What Zed's worktree picker and thread archive run.
      assert {_, status} =
               System.cmd("git", ["-C", mirror, "worktree", "remove", "--force", one],
                 env: Guest.git_env(),
                 stderr_to_stdout: true
               )

      assert status != 0
      assert File.dir?(one)

      # Its folder deleted anyway: the slot is free, its branch stays with
      # its work, and the mirror's next update makes the folder again.
      commit(one, [{"wip.txt", "work in progress\n"}], "wip")
      File.rm_rf!(one)
      assert [{"slot-1", "fix", true} | _] = states(username)

      assert {:ok, %{state: :missing, branch: "fix"}} =
               Projects.release_slot(username, "app", "slot-1")

      {:ok, _} = Projects.mirror(username, "app")
      {0, made} = worktree(username, one, "new", %{"name" => "again"})
      assert made =~ "in slot-1"
      assert git(one, ["branch", "--show-current"]) == "again\n"
      assert git(mirror, ["branch", "--list", "fix"]) =~ "fix"
    end

    test "the mirror's updates make slots again, and new ones; a folder there is left alone", %{
      username: username,
      mirror: mirror
    } do
      # Removed, a folder of someone else's where slot-2 goes, and slot-3's
      # folder deleted with git's record of it left.
      git(mirror, ["worktree", "remove", "-f", "-f", slot(mirror, 1)])
      git(mirror, ["worktree", "remove", "-f", "-f", slot(mirror, 2)])
      File.mkdir_p!(slot(mirror, 2))
      File.write!(Path.join(slot(mirror, 2), "mine.txt"), "mine\n")
      File.rm_rf!(slot(mirror, 3))

      {:ok, _} = Projects.mirror(username, "app")
      assert git(slot(mirror, 1), ["branch", "--show-current"]) == ""
      assert git(slot(mirror, 3), ["branch", "--show-current"]) == ""
      assert File.ls!(slot(mirror, 2)) == ["mine.txt"]

      # One more slot: made when it's added.
      {:ok, "slot-4"} = Projects.add_slot(username, "app")
      assert File.dir?(slot(mirror, 4))

      assert [
               {"slot-1", nil, true},
               {"slot-2", nil, false},
               {"slot-3", nil, true},
               {"slot-4", nil, true}
             ] =
               states(username)
    end

    test "uncommitted work is never switched away", %{username: username, mirror: mirror} do
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      File.write!(Path.join(one, "notes.txt"), "not committed\n")

      assert {1, refused} = worktree(username, one, "free")
      assert refused =~ "slot-1 has uncommitted work (fix)"

      assert {1, busy} = worktree(username, one, "new", %{"name" => "cart"})

      assert busy =~
               "slot-1, where you are, isn't free: fix, based on master, with uncommitted work."

      assert busy =~ "ask the user whether it is done or dropped"

      assert {:error, {:slot_busy, %{state: :dirty}}} =
               Projects.release_slot(username, "app", "slot-1")

      assert git(one, ["branch", "--show-current"]) == "fix\n"
      assert File.read!(Path.join(one, "notes.txt")) == "not committed\n"
    end

    test "with none free, the agent is told what each holds", %{
      username: username,
      mirror: mirror
    } do
      :ok = Projects.remove_slot(username, "app", "slot-2")
      :ok = Projects.remove_slot(username, "app", "slot-3")
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      {0, _} = worktree(username, mirror, "new", %{"name" => "docs"})

      for cwd <- [one, mirror] do
        assert {1, full} = worktree(username, cwd, "new", %{"name" => "cart"})

        assert full =~
                 "No slot is free:\n  slot-0: docs, based on master, no handoff yet\n  slot-1: fix, based on master, no handoff yet"

        assert full =~ "Ask the user to free one on MWT's Projects page, or to add one."
      end
    end

    test "freed, a slot goes off its branch, and a new task from it stays there", %{
      username: username,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      two = slot(mirror, 2)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      {0, _} = worktree(username, two, "new", %{"name" => "cart"})
      commit(two, [{"c.txt", "cart\n"}], "the cart")

      # Only a slot's own thread frees it, or you on the page.
      assert {1, other} = worktree(username, two, "free", %{"slot" => "slot-1"})
      assert other =~ "slot-1 isn't the slot you are in."
      assert {1, from_mirror} = worktree(username, mirror, "free", %{"slot" => "slot-2"})
      assert from_mirror =~ "slot-2 isn't the slot you are in."
      assert git(one, ["branch", "--show-current"]) == "fix\n"

      assert {0, freed} = worktree(username, two, "free")
      assert freed =~ "Freed slot-2" and freed =~ "The branch cart stays, with its commits."
      assert freed =~ "It has no handoff."
      assert git(two, ["branch", "--show-current"]) == ""
      assert {0, again} = worktree(username, two, "free")
      assert again =~ "slot-2 is free already"

      # slot-1 is busy; the agent in slot-2 starts its next task where it is.
      {0, next} = worktree(username, two, "new", %{"name" => "next"})
      assert next =~ "Started the task next in slot-2"
      assert next =~ "You are in it: continue here."
      assert git(mirror, ["log", "-1", "--format=%s", "cart"]) == "the cart\n"

      assert {0, clone} = worktree(username, mirror, "free")
      assert clone =~ "slot-0 is free already"

      assert {:ok, %{name: "slot-1", branch: "fix"}} =
               Projects.release_slot(username, "app", "slot-1")

      assert git(one, ["branch", "--show-current"]) == ""
    end

    test "a handoff sent back after its slot went to another task resumes in a free slot", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(one), username)

      # Freed while the user looks at it, then taken by another task.
      {0, _} = worktree(username, one, "free")
      {0, _} = worktree(username, one, "new", %{"name" => "other"})
      {:ok, _} = Handoffs.send_back(username, 1, "Add a test.")

      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => one}, username)
      assert listed =~ "sent back to you"

      assert listed =~
               "Its branch is in no worktree now. To continue it, ask the user to start a thread in a free slot, which runs: mwt worktree resume fix"

      refute listed =~ "(this branch)"

      assert {1, no_branch} = worktree(username, one, "resume", %{"name" => "nope"})
      assert no_branch =~ "There is no branch nope"
      assert {0, target} = worktree(username, one, "resume", %{"name" => "master"})
      assert target =~ "master is in slot-0 already"
      assert {0, held} = worktree(username, mirror, "resume", %{"name" => "other"})
      assert held =~ "other is in slot-1 already"
      assert held =~ "It isn't the slot you are in: don't work in it from here."

      # The busy slot stays as it is; the branch goes to a free one, from a
      # thread there.
      two = slot(mirror, 2)
      assert {1, busy} = worktree(username, one, "resume", %{"name" => "fix"})
      assert busy =~ "slot-1, where you are, isn't free: other, based on master, no handoff yet."
      assert busy =~ "  slot-2  zed ssh://mwt-sandbox#{two}"
      assert {0, resumed} = worktree(username, two, "resume", %{"name" => "fix"})
      assert resumed =~ "Put the branch fix, as it was, in slot-2, #{two}"
      assert resumed =~ "You are in it: continue here."
      assert git(one, ["branch", "--show-current"]) == "other\n"
      assert git(two, ["branch", "--show-current"]) == "fix\n"

      assert {0, already} = worktree(username, mirror, "resume", %{"name" => "fix"})
      assert already =~ "fix is in slot-2 already"

      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => two}, username)
      assert listed =~ "#1  sent back to you (this branch)"
      assert listed =~ "In slot-2, #{two}."

      # Its next revision comes from the new slot.
      commit(two, [{"t.txt", "test\n"}], "a test")
      {0, said} = Channel.answer("handoff", %{"cwd" => two}, username)
      assert said =~ "Updated handoff #1 (revision 2)"
      assert [%Handoff{source: %{top: ^two, branch: "fix"}, status: :open}] = handoffs(username)
      assert sha(repo, "master") != sha(two, "HEAD")
    end

    test "a worktree that isn't a slot starts no task, and hands off only a task's branch", %{
      username: username,
      mirror: mirror,
      vm: vm
    } do
      old = Path.join(vm, "app.wt/push-options")

      git(mirror, [
        "worktree",
        "add",
        "-q",
        "--no-track",
        "-b",
        "push-options",
        old,
        "host-origin/master"
      ])

      assert {0, there} = Channel.answer("project", %{"cwd" => old}, username)
      assert there =~ "You are in the worktree #{old}, which isn't a slot"

      assert {:ok, %{others: [%{path: ^old, branch: "push-options"}]}} =
               Projects.slots(username, "app")

      commit(old, [{"p.txt", "push\n"}], "push options")
      assert {1, said} = Channel.answer("handoff", ask(old), username)
      assert said =~ "push-options isn't a task's branch"

      # It can't be resumed into a slot while it is checked out there, and
      # starts no task: it isn't a slot.
      assert {1, held} =
               worktree(username, slot(mirror, 1), "resume", %{"name" => "push-options"})

      assert held =~ "push-options is checked out in #{old}: continue it there."
      assert {1, none} = worktree(username, old, "new", %{"name" => "more"})
      assert none =~ "and you are in none"
    end
  end
end
