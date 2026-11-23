defmodule MWTClient.QAProbes.Handoffs.DefaultBranchRenameTest do
  # Probe: slots are made at host-origin/<default branch> as the VM's clone
  # last fetched it; MWT never fetches into the clone after opening it.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.Projects

  setup {MWTClient.HandoffsCase, :with_slots}

  test "after you rename master to main, adding a slot fails until some agent fetches",
       %{username: username, repo: repo} do
    git(repo, ["branch", "-m", "master", "main"])
    result = Projects.mirror(username, "app")
    IO.puts("\n[rename probe] mirror: " <> inspect(result, limit: 5))
    added = Projects.add_slot(username, "app")
    IO.puts("[rename probe] add slot: " <> inspect(added))
    assert {:error, text} = added
    assert text =~ "worktree slots"
  end
end
