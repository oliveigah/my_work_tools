defmodule MWTClient.QAProbes.Handoffs.RebaseInProgressTest do
  # Probe: a branch in the middle of a rebase is on no worktree in
  # `git worktree list`, so MWT treats it as checked out nowhere: in the VM
  # (deleting a landed task's branch) and on your machine (landing on it).
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs}

  setup {MWTClient.HandoffsCase, :with_slots}

  defp run(dir, args, env \\ []) do
    MWTClient.Executable.cmd("git", ["-C", dir | args],
      env: git_env() ++ env,
      stderr_to_stdout: true
    )
  end

  test "VM: landing deletes the task's branch while its slot is mid-rebase, with uncommitted work",
       %{username: username, mirror: mirror} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"vm.txt", "VM\n"}], "VM work")
    {0, _} = Channel.answer("handoff", ask(one), username)
    head = sha(one, "HEAD")

    # The user asks the thread to reword/split its commit; it starts an
    # interactive rebase, stopped at an edit, and changes a file.
    {_, 0} =
      run(one, ["rebase", "-i", "HEAD~1"], [
        {"GIT_SEQUENCE_EDITOR", "sed -i 1s/^pick/edit/"}
      ])

    File.write!(Path.join(one, "vm.txt"), "VM, split in two\n")
    assert git(one, ["status", "--porcelain"]) =~ "vm.txt"

    # Meanwhile you land handoff #1 (master didn't move: as it is).
    assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    IO.puts("\n[rebase probe VM] last event: " <> inspect(List.last(landed.timeline)))

    # The branch went, although its slot has uncommitted work on it.
    assert git(mirror, ["branch", "--list", "fix"]) == ""
    assert sha(mirror, "HEAD") != nil
    _ = head

    # The thread finishes its rebase: git can't put the branch back.
    git(one, ["commit", "-q", "-a", "--amend", "-m", "VM work, reworded"])
    {out, status} = run(one, ["rebase", "--continue"], [{"GIT_EDITOR", "true"}])
    IO.puts("[rebase probe VM] rebase --continue exit #{status}: #{out}")
    assert status != 0
    assert out =~ "refs/heads/fix"
    assert git(one, ["branch", "--show-current"]) == ""
    # The reworded commit is on no branch; the slot reads as free.
    IO.puts("[rebase probe VM] slots: " <> inspect(states(username)))
  end

  test "host: landing moves your branch while you rebase it; your rebase --abort then drops what landed",
       %{username: username, mirror: mirror, repo: repo} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"vm.txt", "VM\n"}], "VM work")
    {0, _} = Channel.answer("handoff", ask(one), username)
    before = sha(repo, "master")

    # You are rewording your own last commit on master: an interactive
    # rebase, stopped at an edit. git itself refuses to move master now.
    {_, 0} =
      run(repo, ["rebase", "-i", "HEAD~1"], [
        {"GIT_SEQUENCE_EDITOR", "sed -i 1s/^pick/edit/"}
      ])

    {refused, status} = run(repo, ["branch", "-f", "master", "HEAD~1"])
    assert status != 0 and refused =~ "used by worktree"

    # MWT lands on master anyway, by update-ref.
    assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    IO.puts("\n[rebase probe host] landed: " <> inspect(landed.accepted))
    assert landed.accepted.worktree == nil
    landed_commit = landed.landed.commit
    assert sha(repo, "refs/heads/master") == landed_commit

    # You give up your rebase: master goes back to where it was before it,
    # and what landed is no longer on it, while the handoff says Landed.
    {_, 0} = run(repo, ["rebase", "--abort"])
    assert sha(repo, "master") == before
    {_, 1} = run(repo, ["merge-base", "--is-ancestor", landed_commit, "master"])
    assert {:ok, %{status: :accepted}} = MWTClient.Sandbox.HandoffRecords.get(username, 1)
    IO.puts("[rebase probe host] master after abort: #{sha(repo, "master")} (before: #{before})")
    assert {:error, :moved} = Handoffs.undo(username, 1)
  end
end
