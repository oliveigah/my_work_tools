defmodule MWTClient.Sandbox.ProjectsCloneTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Guest, Mirror, Project, Projects, Slots}

  test "opening creates an ordinary writable clone with branches and tags", %{
    username: username,
    repo: repo,
    mirror: clone
  } do
    git(repo, ["branch", "develop"])
    git(repo, ["tag", "v1"])

    assert {:ok, project} = Projects.open(username, repo)
    assert git(clone, ["remote", "get-url", "origin"]) == Project.remote_url(project) <> "\n"
    assert git(clone, ["branch", "--show-current"]) == "master\n"
    assert git(clone, ["config", "branch.master.remote"]) == "origin\n"
    assert sha(clone, "origin/develop") == sha(repo, "develop")
    assert sha(clone, "v1") == sha(repo, "v1")
    refute File.exists?(clone <> ".wt")

    commit(clone, [{"local.txt", "owned by the VM\n"}], "local work")
    assert sha(clone, "HEAD") != sha(repo, "HEAD")
    refute File.exists?(Path.join(repo, "local.txt"))
  end

  test "refreshing host metadata preserves the VM's branch, staged work and remote refs", %{
    username: username,
    repo: repo,
    mirror: clone
  } do
    {:ok, _} = Projects.open(username, repo)
    fetched = sha(clone, "origin/master")
    commit(clone, [{"local.txt", "local\n"}], "local work")
    head = sha(clone, "HEAD")
    git(clone, ["branch", "keep-me"])
    File.write!(Path.join(clone, "a.txt"), "staged in the VM\n")
    git(clone, ["add", "a.txt"])
    File.write!(Path.join(clone, "untracked.txt"), "keep\n")
    status = git(clone, ["status", "--porcelain"])
    index = git(clone, ["write-tree"])

    commit(repo, [{"host.txt", "host advanced\n"}], "host change")
    git(repo, ["branch", "another-host-branch"])
    assert {:ok, %{tips: tips, rescued: nil}} = Projects.mirror(username, "app")

    assert tips["master"] == sha(repo, "master")
    assert git(clone, ["branch", "--show-current"]) == "master\n"
    assert sha(clone, "HEAD") == head
    assert sha(clone, "keep-me") == head
    assert sha(clone, "origin/master") == fetched
    assert git(clone, ["status", "--porcelain"]) == status
    assert git(clone, ["write-tree"]) == index
    assert File.read!(Path.join(clone, "untracked.txt")) == "keep\n"
    refute File.exists?(Path.join(clone, "host.txt"))
  end

  test "an old mirror migrates in place with its slots and their tasks intact", %{
    username: username,
    repo: repo,
    mirror: clone,
    vm: vm
  } do
    git(vm, ["clone", "--quiet", "--no-local", repo, clone])
    git(clone, ["remote", "rename", "origin", "host"])
    git(clone, ["config", "remote.host.url", "mwt::host"])
    commit(clone, [{"local.txt", "local commit\n"}], "local work")
    head = sha(clone, "HEAD")
    tree = Path.join(clone <> ".wt", "slot-2")
    git(clone, ["worktree", "add", "--quiet", "-b", "active-task", tree])
    git(clone, ["worktree", "lock", "--reason", "legacy slot", tree])
    git(clone, ["config", "branch.active-task.mwt-thread", "existing-thread"])
    git(clone, ["config", "branch.active-task.mwt-base", "refs/remotes/host/master"])
    File.write!(Path.join(clone, "a.txt"), "staged\n")
    git(clone, ["add", "a.txt"])
    File.write!(Path.join(tree, "a.txt"), "active task changes\n")
    File.mkdir_p!(Path.join(tree, "_build"))
    File.write!(Path.join(tree, "_build/warm"), "keep\n")
    before = git(clone, ["status", "--porcelain"])

    {:ok, project} = Projects.ensure(username, repo)
    legacy = %{project | slots: [1, 2, 3]}
    assert {:ok, %{rescued: nil}} = Mirror.run(legacy, Guest.local(vm))

    assert sha(clone, "HEAD") == head
    assert sha(tree, "HEAD") == head
    assert git(clone, ["branch", "--show-current"]) == "master\n"
    assert git(clone, ["status", "--porcelain"]) == before
    assert git(tree, ["branch", "--show-current"]) == "active-task\n"
    assert File.read!(Path.join(tree, "a.txt")) == "active task changes\n"
    assert File.read!(Path.join(tree, "_build/warm")) == "keep\n"
    assert git(clone, ["config", "branch.active-task.mwt-thread"]) == "existing-thread\n"
    assert git(clone, ["remote", "get-url", "origin"]) == Project.remote_url(project) <> "\n"
    assert sha(clone, "origin/master") == sha(repo, "master")

    # The mirror's own remote goes, with its branches, which nothing would
    # update; what tracked it tracks origin, and the task's base follows.
    assert git(clone, ["remote"]) =~ "origin"
    refute git(clone, ["remote"]) =~ "host"
    assert git(clone, ["for-each-ref", "refs/remotes/host/"]) == ""
    assert git(clone, ["config", "branch.master.remote"]) == "origin\n"

    assert git(clone, ["config", "branch.active-task.mwt-base"]) ==
             "refs/remotes/origin/master\n"

    refute File.exists?(Path.join(clone <> ".wt", "slot-1"))
    refute File.exists?(Path.join(clone <> ".wt", "slot-3"))
    # Its slots as they were: slot-2's task still held by its thread; the
    # clone, staged work and all, is slot-0.
    assert {:ok, %{slots: slots}} = Slots.look(legacy, Guest.local(vm), [])

    assert [
             %{name: "slot-0", path: ^clone, state: :dirty, free?: false},
             %{name: "slot-1", state: :absent, free?: true},
             %{
               name: "slot-2",
               path: ^tree,
               branch: "active-task",
               thread: "existing-thread",
               state: :dirty,
               free?: false
             },
             %{name: "slot-3", state: :absent}
           ] = slots
  end

  test "a clone made from a mirror before loses its host remote at the next run; yours stays",
       %{username: username, repo: repo, mirror: clone, vm: vm} do
    {:ok, project} = Projects.ensure(username, repo)
    assert {:ok, _} = Mirror.run(project, Guest.local(vm))
    # As a mirror migrated before its host remote went left it.
    git(clone, ["remote", "add", "host", "mwt::host"])
    git(clone, ["update-ref", "refs/remotes/host/master", sha(clone, "HEAD")])

    assert {:ok, _} = Mirror.run(project, Guest.local(vm))
    refute git(clone, ["remote"]) =~ "host"
    assert git(clone, ["for-each-ref", "refs/remotes/host/"]) == ""

    # A remote you named host yourself, elsewhere, is yours: it stays.
    git(clone, ["remote", "add", "host", Path.join(vm, "elsewhere.git")])
    assert {:ok, _} = Mirror.run(project, Guest.local(vm))
    assert git(clone, ["remote", "get-url", "host"]) == Path.join(vm, "elsewhere.git") <> "\n"
  end

  test "a clone made when MWT was MDT keeps its work and takes MWT's names", %{
    username: username,
    repo: repo,
    mirror: clone,
    vm: vm
  } do
    {:ok, project} = Projects.ensure(username, repo)
    assert {:ok, _} = Mirror.run(project, Guest.local(vm))
    "mwt::" <> id = String.trim(git(clone, ["remote", "get-url", "origin"]))

    # As MDT left it.
    git(clone, ["config", "remote.origin.url", "mdt::" <> id])
    git(clone, ["config", "remote.upstream.url", "mdt::#{id}/upstream"])
    git(clone, ["config", "--remove-section", "mwt"])
    git(clone, ["config", "mdt.clone-version", "1"])
    git(clone, ["config", "mdt.project", Project.id(project)])
    git(clone, ["branch", "a.task"])
    git(clone, ["config", "branch.a.task.mdt-base", "refs/remotes/origin/master"])
    git(clone, ["config", "branch.a.task.mdt-thread", "a-thread"])
    commit(clone, [{"local.txt", "local\n"}], "local work")
    head = sha(clone, "HEAD")

    assert {:ok, _} = Mirror.run(project, Guest.local(vm))

    assert git(clone, ["remote", "get-url", "origin"]) == "mwt::#{id}\n"
    assert git(clone, ["remote", "get-url", "upstream"]) == "mwt::#{id}/upstream\n"
    assert git(clone, ["config", "branch.a.task.mwt-base"]) == "refs/remotes/origin/master\n"
    assert git(clone, ["config", "branch.a.task.mwt-thread"]) == "a-thread\n"
    assert git(clone, ["config", "mwt.clone-version"]) == "1\n"
    assert git(clone, ["config", "mwt.project"]) == Project.id(project) <> "\n"
    refute git(clone, ["config", "--list"]) =~ "mdt"
    assert sha(clone, "HEAD") == head
  end

  test "later refreshes preserve custom origin and commit identity configuration", %{
    username: username,
    repo: repo,
    mirror: clone
  } do
    {:ok, _} = Projects.open(username, repo)
    git(clone, ["remote", "set-url", "origin", "example:another-repository"])
    git(clone, ["config", "user.name", "VM developer"])
    git(clone, ["config", "user.email", "vm@example.test"])

    assert {:ok, _} = Projects.mirror(username, "app")
    assert git(clone, ["remote", "get-url", "origin"]) == "example:another-repository\n"
    assert git(clone, ["config", "user.name"]) == "VM developer\n"
    assert git(clone, ["config", "user.email"]) == "vm@example.test\n"
  end

  test "an existing clone remains openable when its host source is unshared or gone", %{
    username: username,
    repo: repo,
    mirror: clone,
    base: base
  } do
    {:ok, _} = Projects.open(username, repo)
    File.write!(Path.join(clone, "local.txt"), "keep working\n")
    :ok = MWTClient.Sandbox.remove_share(username, Path.join(base, "host"))
    {:ok, _} = Projects.close(username, "app")
    File.rm_rf!(repo)

    assert {:ok, %{closed: false}} = Projects.open(username, repo)
    assert {:ok, _} = Projects.open(username, "app")
    assert File.read!(Path.join(clone, "local.txt")) == "keep working\n"
  end

  test "a missing clone still needs a shared host source before initialization", %{
    username: username,
    repo: repo,
    mirror: clone,
    base: base
  } do
    {:ok, _} = Projects.ensure(username, repo)
    :ok = MWTClient.Sandbox.remove_share(username, Path.join(base, "host"))

    assert {:error, :not_shared} = Projects.open(username, "app")
    refute File.exists?(clone)
  end
end
