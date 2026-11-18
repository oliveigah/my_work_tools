defmodule MWTClient.Sandbox.LeftoversCloneTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Leftovers, Projects}

  test "a clone is found through its project marker and compared to fetched origin branches",
       context do
    %{username: username, repo: repo, mirror: clone} = context
    {_project, tree} = project_with_worktree(context)
    commit(tree, [{"local.txt", "only in the VM\n"}], "local work")
    File.write!(Path.join(tree, "uncommitted.txt"), "keep\n")
    assert git(clone, ["for-each-ref", "refs/remotes/host/"]) == ""
    File.rm_rf!(repo)

    assert {:ok, [left]} = Leftovers.list(username)
    assert left.unmerged == ["fix"]
    assert left.uncommitted == [tree]
    assert left.external_worktrees == []
  end

  test "legacy host refs still identify an older project mirror", %{
    username: username,
    repo: repo,
    mirror: clone
  } do
    {:ok, _} = Projects.open(username, repo)
    git(clone, ["config", "--unset", "mwt.project"])
    git(clone, ["update-ref", "refs/remotes/host/master", sha(clone, "origin/master")])
    git(clone, ["symbolic-ref", "refs/remotes/host/HEAD", "refs/remotes/host/master"])
    File.rm_rf!(repo)
    assert {:ok, [%{name: "app", unmerged: []}]} = Leftovers.list(username)
  end

  test "removing a clone cannot orphan linked worktrees outside its project folders", %{
    username: username,
    repo: repo,
    mirror: clone,
    vm: vm
  } do
    {:ok, _} = Projects.open(username, repo)
    tree = Path.join(vm, "separate-worktree")
    git(clone, ["worktree", "add", "--quiet", "-b", "feature", tree])
    File.write!(Path.join(tree, "a.txt"), "keep my work\n")
    File.rm_rf!(repo)

    assert {:ok, [%{external_worktrees: [^tree]}]} = Leftovers.list(username)
    assert {:error, {:external_worktrees, [^tree]}} = Leftovers.remove(username, "app")
    assert File.exists?(Path.join(clone, ".git/config"))
    assert File.read!(Path.join(tree, "a.txt")) == "keep my work\n"
    assert sha(tree, "HEAD") == sha(clone, "HEAD")
  end
end
