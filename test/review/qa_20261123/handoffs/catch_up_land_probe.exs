defmodule MWTClient.QAProbes.Handoffs.CatchUpLandTest do
  # Probe: a handoff MWT caught up ("Catch up here") then landed as it is.
  # The spec: the slot is free as soon as its handoff lands; the branch goes
  # when nothing was done on it since. Shows what happens instead.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs}

  setup {MWTClient.HandoffsCase, :with_slots}

  test "caught up by MWT, landed as it is: the VM branch is kept as if it had new commits, and the slot stays held",
       %{username: username, mirror: mirror, repo: repo} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"vm.txt", "VM\n"}], "VM work")
    {0, _} = Channel.answer("handoff", ask(one), username)
    vm_head = sha(one, "HEAD")

    # Your master moves (no conflict); you click Catch up here, then Land.
    commit(repo, [{"host.txt", "host\n"}], "host work")
    assert {:ok, caught} = Handoffs.catch_up(username, 1)
    assert caught.head != vm_head

    assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert landed.accepted.how == :as_is
    IO.puts("\n[catch-up probe] last timeline event: " <> inspect(List.last(landed.timeline)))

    # Nothing was done in the VM since the handoff: the branch is still at the
    # very commit the thread handed off. Yet:
    assert sha(mirror, "fix") == vm_head
    assert %{kind: :branch_kept, text: text} = List.last(landed.timeline)
    assert text =~ "it has commits since this revision"

    # And the slot is not free, though its handoff landed.
    states = states(username)
    IO.puts("[catch-up probe] slots: " <> inspect(states))
    assert {"slot-1", "fix", false} in states

    # The thread there is told it did work since.
    {1, words} = worktree(username, one, "new", %{"name" => "next-thing"})
    IO.puts("[catch-up probe] mwt worktree new in slot-1: " <> words)
  end
end
