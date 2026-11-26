defmodule MWTClient.Sandbox.HandoffsSlotsTest do
  @moduledoc """
  Worktree slots: a task's branch in a slot that keeps what git ignores,
  and who holds a slot. slot-0 is the clone itself; the others are
  worktrees of it. Keeping slots in order has
  handoffs_slots_upkeep_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoff, Handoffs, Projects}

  describe "worktree slots" do
    setup {MWTClient.HandoffsCase, :with_slots}

    test "the clone is slot-0: free on its own branch, a task's once taken, never removed", %{
      username: username,
      mirror: mirror
    } do
      assert {:ok,
              %{slots: [%{name: "slot-0", path: ^mirror, branch: "master", free?: true} | _]}} =
               Projects.slots(username, "app")

      assert {0, free} = Channel.answer("project", %{"cwd" => mirror}, username)
      assert free =~ "You are in slot-0 (the clone itself), #{mirror}, which is free, on master."
      assert {0, already} = worktree(username, mirror, "free")
      assert already =~ "slot-0 is free already: it is on master, which no task started"
      assert git(mirror, ["branch", "--show-current"]) == "master\n"

      {0, started} = worktree(username, mirror, "new", %{"name" => "fix-in-clone"})
      assert started =~ "Started the task fix-in-clone in slot-0"
      assert started =~ "You are in it: continue here."
      refute started =~ "It isn't the slot you are in"

      assert {0, mine} = Channel.answer("project", %{"cwd" => mirror}, username)
      assert mine =~ "You are in slot-0 (the clone itself), #{mirror}, held by the task branch"

      commit(mirror, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(mirror), username)
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => mirror}, username)
      assert listed =~ "#1  open, waiting for the user (this branch)"
      assert listed =~ "In slot-0, #{mirror}."

      assert {:ok, %{slots: [%{name: "slot-0", branch: "fix-in-clone", free?: false} | _]}} =
               Projects.slots(username, "app")

      assert {:error, :the_clone} = Projects.remove_slot(username, "app", "slot-0")
      assert File.dir?(mirror)
    end

    test "a task gets its own branch in a slot that keeps what git ignores", %{
      username: username,
      repo: repo,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      {0, _} = worktree(username, one, "new", %{"name" => "fix"})
      File.mkdir_p!(Path.join(one, "_build"))
      File.write!(Path.join(one, "_build/app.beam"), "warm\n")
      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(one), username)

      # Busy while its handoff is open: its thread starts nothing else
      # there, and a thread in slot-2 starts the next task in slot-2.
      assert {1, busy} = worktree(username, one, "new", %{"name" => "cart"})
      assert busy =~ "slot-1, where you are, isn't free: fix, based on master, handoff #1 open."
      assert busy =~ "If fix is your thread's task, do the new work on it"
      assert busy =~ "If it isn't, another thread holds this slot: tell the user"
      assert busy =~ "  slot-2  zed ssh://mwt-sandbox#{slot(mirror, 2)}"
      {0, second} = worktree(username, slot(mirror, 2), "new", %{"name" => "cart"})
      assert second =~ "in slot-2, #{slot(mirror, 2)}"

      assert [{"slot-1", "fix", false}, {"slot-2", "cart", false}, {"slot-3", nil, true}] =
               states(username)

      # Landed with nothing done on it since: its branch goes, so task
      # branches don't pile up, and slot-1 is on no branch, at that same
      # commit, free; the next task takes it, on a new branch from your
      # branch as it is now.
      {:ok, landed_fix} = Handoffs.accept(username, 1, {:commit, "master"})
      assert [{"slot-1", nil, true} | _] = states(username)
      assert git(mirror, ["branch", "--list", "fix"]) == ""
      assert sha(one, "HEAD") == landed_fix.head
      assert %{kind: :branch_deleted, text: deleted} = List.last(landed_fix.timeline)
      assert deleted =~ "MWT deleted its branch fix in the VM"
      assert deleted =~ "#{one} is on no branch now"

      # Its thread, asked for more, is told to take it again first.
      assert {0, landed} = Channel.answer("project", %{"cwd" => one}, username)

      assert landed =~ "You are in slot-1, #{one}, which is free. Take it now"

      assert landed =~ "Take it now, before anything else"

      {0, third} = worktree(username, one, "new", %{"name" => "docs"})
      assert third =~ "Started the task docs in slot-1"
      assert git(one, ["branch", "--show-current"]) == "docs\n"
      assert sha(one, "HEAD") == sha(repo, "master")
      assert File.read!(Path.join(one, "_build/app.beam")) == "warm\n"

      # Its commit is your branch's now, as it is (a fast-forward); the
      # branches of tasks that haven't landed stay.
      assert git(mirror, ["log", "-1", "--format=%s", "host-origin/master"]) == "the fix\n"
      assert sha(mirror, "host-origin/master") == landed_fix.head
      assert git(mirror, ["branch", "--list", "cart", "docs"]) =~ "cart"

      # Taken back out after you landed it: its thread is told to make the
      # branch again first, and a thread in a free slot resumes it from its
      # handoff's commit.
      {:ok, _} = Handoffs.undo(username, 1)
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => slot(mirror, 3)}, username)
      assert listed =~ "Its branch fix was deleted in the VM when it landed."
      assert listed =~ "Run mwt worktree resume fix in your slot before you change anything"
      assert {0, resumed} = worktree(username, slot(mirror, 3), "resume", %{"name" => "fix"})
      assert resumed =~ "Put the branch fix, as it was, in slot-3"
      assert git(slot(mirror, 3), ["log", "-1", "--format=%s"]) == "the fix\n"
    end

    test "a thread holds its slot from its first step; a second thread there only reads", %{
      username: username,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      a = %{"thread_id" => "thread-a", "agent" => "claude", "thread" => "Fix the login"}
      b = %{"thread_id" => "thread-b", "agent" => "claude", "thread" => "Look around"}
      project = fn who -> Channel.answer("project", Map.put(who, "cwd", one), username) end

      # Free, the slot is the first thread's to take, named for the ask.
      assert {0, free} = project.(a)
      assert free =~ "Take it now, before anything else"
      assert free =~ "never task or wip"

      for vague <- ["task", "wip", "question-2", "Explore"] do
        assert {1, said} = worktree(username, one, "new", Map.put(a, "name", vague))
        assert said =~ "\"#{vague}\" says nothing of the work"
      end

      {0, _} = worktree(username, one, "new", Map.put(a, "name", "fix-login"))
      assert git(mirror, ["config", "branch.fix-login.mwt-thread"]) == "thread-a\n"

      assert {:ok, %{slots: [_clone, %{thread: "thread-a", free?: false} | _]}} =
               Projects.slots(username, "app")

      # The thread holding it is told so; the other, opened in the same
      # slot, that it only reads there, and starts, frees and hands off
      # nothing.
      assert {0, mine} = project.(a)
      assert mine =~ "which your thread holds for its task fix-login"

      assert {0, theirs} = project.(b)
      assert theirs =~ "which another thread holds for its task fix-login. Tell the user."
      assert theirs =~ "You may go on in this thread read-only"
      assert theirs =~ "no builds or tests"

      assert {1, taken} = worktree(username, one, "new", Map.put(b, "name", "cart"))
      assert taken =~ "Another thread holds slot-1, for its task fix-login (no handoff yet)."
      assert taken =~ "  slot-2  zed ssh://mwt-sandbox#{slot(mirror, 2)}"
      assert {1, not_freed} = worktree(username, one, "free", b)
      assert not_freed =~ "Another thread holds slot-1"
      assert git(one, ["branch", "--show-current"]) == "fix-login\n"

      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      prepare = Map.merge(b, %{"stage" => "prepare", "cwd" => one})
      assert {1, not_handed} = Channel.answer("handoff", prepare, username)
      assert not_handed =~ "Another thread holds fix-login: only that thread hands it off"
      assert {1, _} = Channel.answer("handoff", ask(one, b), username)
      assert handoffs(username) == []

      # With no thread named, as from an older mwt, it says both cases.
      assert {0, either} = Channel.answer("project", %{"cwd" => one}, username)
      assert either =~ "If fix-login is your thread's task, it is yours to change"

      # Its own thread hands off; asked for more, it is told the work goes
      # into the handoff's next revision rather than another task.
      assert {0, _} = Channel.answer("handoff", ask(one, a), username)
      assert [%Handoff{id: 1, status: :open}] = handoffs(username)
      assert {1, more} = worktree(username, one, "new", Map.put(a, "name", "fix-signup"))
      assert more =~ "slot-1 is yours already, on your task fix-login."
      assert more =~ "more work doesn't change it"
      assert {0, again} = project.(a)
      assert again =~ "If the user asks for more: Its handoff #1 is open"
      assert again =~ "updates handoff #1 with a new revision"
    end

    test "asked for more, a thread takes its open handoff back, then hands off again", %{
      username: username,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      a = %{"thread_id" => "thread-a", "agent" => "claude", "thread" => "Fix the login"}
      b = %{"thread_id" => "thread-b", "agent" => "claude", "thread" => "Look around"}

      withdraw = fn who, reason ->
        Channel.answer(
          "handoff",
          Map.merge(who, %{"stage" => "withdraw", "cwd" => one, "reason" => reason}),
          username
        )
      end

      {0, _} = worktree(username, one, "new", Map.put(a, "name", "fix-login"))
      assert {1, nothing} = withdraw.(a, "more")
      assert nothing =~ "fix-login has no handoff to take back"

      commit(one, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(one, a), username)

      # Only its own thread takes it back.
      assert {1, not_mine} = withdraw.(b, "mine now")
      assert not_mine =~ "Another thread holds fix-login"
      assert [%Handoff{status: :open}] = handoffs(username)

      assert {0, took} = withdraw.(a, "the signup form too")
      assert took =~ "Took handoff #1 back: the user can't land it until you hand off again."
      assert [%Handoff{status: :withdrawn, timeline: timeline}] = handoffs(username)
      assert %{kind: :withdrawn, note: "the signup form too"} = List.last(timeline)
      assert {1, twice} = withdraw.(a, "again")
      assert twice =~ "You took handoff #1 back already"

      # You can't land it meanwhile; the agent sees it, with why.
      assert Handoffs.accept(username, 1, {:commit, "master"}) == {:error, :withdrawn}
      assert Handoffs.explain(:withdrawn) =~ "it can be landed once handed off again"
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => one}, username)
      assert listed =~ "#1  withdrawn: taken back for more work"
      assert listed =~ "Taken back for: the signup form too"
      assert [{"slot-1", "fix-login", false} | _] = states(username)

      # Its next handoff updates the same one, open again.
      commit(one, [{"b.txt", "signup\n"}], "the signup form")
      assert {0, updated} = Channel.answer("handoff", ask(one, a), username)
      assert updated =~ "#1"
      assert [%Handoff{id: 1, status: :open, revision: 2}] = handoffs(username)

      # Landed, there is nothing to take back: its branch went, and more
      # work is a new task.
      {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      assert {1, landed} = withdraw.(a, "more")
      assert landed =~ "This worktree is on no branch, so it has no handoff to take back"
      assert landed =~ "mwt worktree new TASK"
    end

    test "a thread the user asks to carry on a task takes over its hold", %{
      username: username,
      mirror: mirror
    } do
      one = slot(mirror, 1)
      a = %{"thread_id" => "thread-a"}
      b = %{"thread_id" => "thread-b"}
      {0, _} = worktree(username, one, "new", Map.put(a, "name", "fix-login"))

      assert {0, adopted} = worktree(username, one, "resume", Map.put(b, "name", "fix-login"))
      assert adopted =~ "another thread held it: this thread holds it now"
      assert git(mirror, ["config", "branch.fix-login.mwt-thread"]) == "thread-b\n"
      assert {0, old} = Channel.answer("project", Map.put(a, "cwd", one), username)
      assert old =~ "which another thread holds for its task fix-login"

      # From another slot, it isn't taken over: that slot is another
      # thread's place.
      two = slot(mirror, 2)
      assert {0, elsewhere} = worktree(username, two, "resume", Map.put(a, "name", "fix-login"))
      assert elsewhere =~ "It isn't the slot you are in"
      assert git(mirror, ["config", "branch.fix-login.mwt-thread"]) == "thread-b\n"

      # A branch taken before MWT recorded threads goes to the first thread
      # that names itself there.
      git(mirror, ["config", "--unset", "branch.fix-login.mwt-thread"])
      assert {0, claimed} = worktree(username, one, "resume", Map.put(a, "name", "fix-login"))
      assert claimed =~ "fix-login is in slot-1 already"
      assert git(mirror, ["config", "branch.fix-login.mwt-thread"]) == "thread-a\n"
    end
  end
end
