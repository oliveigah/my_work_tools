defmodule MWTClient.QAProbes.Handoffs.UndoAfterSwitchTest do
  # Probe: Undo of a landing refuses once you switched your checkout to
  # another branch, though the branch still has exactly what landed.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs}

  setup {MWTClient.HandoffsCase, :with_slots}

  test "landed on your checked-out master, then you switch branch: Undo says master moved",
       %{username: username, mirror: mirror, repo: repo} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"vm.txt", "VM\n"}], "VM work")
    {0, _} = Channel.answer("handoff", ask(one), username)

    assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert landed.accepted.undo.kind == :merge
    git(repo, ["switch", "-q", "-c", "something-else"])
    assert sha(repo, "master") == landed.landed.commit

    assert {:error, :moved} = Handoffs.undo(username, 1)
    IO.puts("\n[undo probe] " <> Handoffs.explain(:moved))
  end
end
