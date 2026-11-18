defmodule MWTClient.Sandbox.HandoffsTest do
  @moduledoc "Project discovery, commit identity and Git diagnostics during handoffs."
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox

  alias MWTClient.Sandbox.{
    Channel,
    Guest,
    Handoff,
    Handoffs,
    HostGit,
    Project,
    Projects,
    Share
  }

  describe "a registered project" do
    test "is every repository in a shared folder, and only those", %{
      username: username,
      repo: repo,
      base: base
    } do
      # Another repository beside it, deeper down; a linked worktree, a
      # dependency folder and a hidden one, which are not projects.
      other = Path.join(base, "host/group/lib")
      File.mkdir_p!(other)
      git(other, ["init", "-q", "-b", "main"])
      commit(other, [{"x.txt", "x\n"}], "x")
      git(repo, ["worktree", "add", "-q", Path.join(base, "host/app-wt"), "-b", "side"])
      File.mkdir_p!(Path.join(base, "host/node_modules/dep/.git"))
      File.mkdir_p!(Path.join(base, "host/.cache/thing/.git"))

      outside = Path.join(base, "elsewhere")
      File.mkdir_p!(outside)
      git(outside, ["init", "-q", "-b", "main"])
      commit(outside, [{"y.txt", "y\n"}], "y")

      assert %{shared: [%{share: %Share{}, repos: repos}], closed: []} =
               Projects.available(username)

      assert [
               %{path: ^repo, name: "app", branch: "master"},
               %{path: ^other, name: "lib", branch: "main"}
             ] = repos

      assert %{open: [], shares?: true} = Projects.overview(username)
      assert Projects.open(username, outside) == {:error, :not_shared}
      assert Projects.reopen(username, outside) == {:error, :not_shared}

      # Opened, it is on the page and no longer among those to open.
      {:ok, _} = Projects.open(username, repo)

      assert %{open: [%{project: %Project{name: "app"}, share: %Share{}}]} =
               Projects.overview(username)

      assert %{shared: [%{repos: [%{name: "lib"}]}]} = Projects.available(username)

      # Closed, it is off the page and offered to open again; nothing else
      # changes.
      assert {:ok, %Project{closed: true}} = Projects.close(username, "app")
      assert %{open: []} = Projects.overview(username)
      assert %{closed: [%{project: %Project{name: "app"}}]} = Projects.available(username)
      assert {:ok, %Project{closed: false}} = Projects.reopen(username, "app")
      assert %{open: [_]} = Projects.overview(username)

      # Once its folder isn't shared, it stays, marked: MWT stops following it.
      :ok = Sandbox.remove_share(username, Path.join(base, "host"))

      assert %{open: [%{project: %Project{name: "app"}, share: nil}], shares?: false} =
               Projects.overview(username)

      assert Projects.mirror(username, "app") == {:error, :not_shared}
    end

    test "can be found deeper in a shared folder, one folder at a time, never out of it", %{
      username: username,
      repo: repo,
      base: base
    } do
      host = Path.join(base, "host")
      deep = Path.join(host, "a/b/c/d/e")
      File.mkdir_p!(deep)
      git(deep, ["init", "-q", "-b", "main"])
      commit(deep, [{"x.txt", "x\n"}], "x")
      File.mkdir_p!(Path.join(host, ".hidden"))
      File.ln_s!(Path.join(base, "elsewhere"), Path.join(host, "link"))

      # Past the scan's 4 levels: not in the list.
      assert %{shared: [%{repos: repos}]} = Projects.available(username)
      refute Enum.any?(repos, &(&1.path == deep))

      assert {:ok, %{parent: nil, entries: entries}} = Projects.browse(username, host)

      assert [%{name: "a", kind: :folder}, %{name: "app", kind: :repository, project: nil}] =
               entries

      assert {:ok, %{parent: ^host}} = Projects.browse(username, Path.join(host, "a"))
      {:ok, _} = Projects.open(username, repo)

      assert {:ok, %{entries: [_, %{name: "app", project: %Project{name: "app"}}]}} =
               Projects.browse(username, host)

      assert {:ok, %{entries: [%{name: "e", path: ^deep, kind: :repository}]}} =
               Projects.browse(username, Path.join(host, "a/b/c/d"))

      assert {:ok, %Project{name: "e"}} = Projects.reopen(username, deep)

      # Never out of a shared folder, nor into a repository.
      assert Projects.browse(username, base) == {:error, :not_shared}
      assert Projects.browse(username, Path.join(host, "a/../..")) == {:error, :not_shared}
      assert Projects.browse(username, Path.join(host, "link")) == {:error, :not_shared}
      assert Projects.browse(username, "relative") == {:error, :not_shared}
      assert Projects.browse(username, repo) == {:error, :not_a_folder}
    end

    test "closing pauses metadata following without changing the clone", %{
      username: username,
      repo: repo,
      mirror: clone
    } do
      {:ok, _} = Projects.open(username, repo)
      {:ok, _} = Projects.close(username, "app")
      vm = %{name: "vm", status: :running, started_at: nil}
      %{projects: projects, mirror: entries} = Sandbox.snapshot(username)
      shares = Sandbox.snapshot(username).settings.shares
      previous = entries["app"].tips["master"]
      fetched = sha(clone, "origin/master")

      commit(repo, [{"b.txt", "yours\n"}], "second")
      :ok = Projects.follow(username, projects, entries, vm, 60, shares)
      assert Sandbox.snapshot(username).mirror["app"].tips["master"] == previous

      assert :ok = Projects.fresh(username, "app")
      assert Sandbox.snapshot(username).mirror["app"].tips["master"] == sha(repo, "master")
      assert sha(clone, "origin/master") == fetched
      refute File.exists?(Path.join(clone, "b.txt"))
    end

    test "opening keeps one record and refuses invalid or sensitive host sources", %{
      username: username,
      repo: repo,
      mirror: clone,
      base: base
    } do
      assert {:ok, %Project{name: "app", path: ^repo}} =
               Projects.open(username, Path.join(repo, "."))

      assert {:ok, %Project{name: "app"}} = Projects.open(username, repo)
      assert [%Project{}] = Projects.list(username)
      assert sha(clone, "HEAD") == sha(repo, "master")
      assert {:error, {:not_a_repository, _}} = Projects.open(username, base)

      assert {:error, {:refused, _, "MWT's own data"}} =
               Project.check(repo, data_dir: Path.join(base, "host"))
    end

    test "a missing host default chooses a landing fallback without moving local branches", %{
      username: username,
      repo: repo,
      mirror: clone
    } do
      {:ok, _} = Projects.open(username, repo)
      initial = sha(clone, "HEAD")
      git(repo, ["branch", "-m", "master", "trunk"])
      assert {:ok, %{default: "trunk"}} = Projects.mirror(username, "app")
      assert [%Project{mirrored_branch: "trunk"}] = Projects.list(username)
      assert sha(clone, "HEAD") == initial
      assert git(clone, ["branch", "--show-current"]) == "master\n"
      assert sha(clone, "origin/master") == initial

      assert {:ok, %Project{mirrored_branch: "trunk"}} =
               Projects.update(username, "app", %{"mirrored_branch" => "develop"})

      assert :ok = Projects.forget(username, "app")
      assert Projects.list(username) == []
    end

    test "concurrent initialization and metadata refreshes leave local files intact", %{
      username: username,
      repo: repo,
      mirror: clone
    } do
      {:ok, _} = Projects.open(username, repo)
      initial = sha(clone, "HEAD")
      File.write!(Path.join(clone, "local.txt"), "keep\n")

      for n <- 1..3 do
        commit(repo, [{"b.txt", "change #{n}\n"}], "change #{n}")

        results =
          [
            fn -> Projects.mirror(username, "app") end,
            fn -> Projects.mirror(username, "app") end
            | List.duplicate(fn -> Projects.fresh(username, "app") end, 4)
          ]
          |> Enum.map(&Task.async/1)
          |> Task.await_many(60_000)

        assert Enum.all?(results, &(&1 == :ok or match?({:ok, _}, &1))), inspect(results)
        assert sha(clone, "HEAD") == initial
        assert File.read!(Path.join(clone, "local.txt")) == "keep\n"
      end
    end
  end

  describe "handoff Git operations" do
    test "a clone inherits the host's commit identity and keeps its own configuration", context do
      %{username: username, repo: repo, mirror: clone} = context
      git(repo, ["config", "user.name", "You"])
      git(repo, ["config", "user.email", "you@example.test"])
      {_project, tree} = project_with_worktree(context)
      File.write!(Path.join(tree, "a.txt"), "by the agent\n")
      git_vm = fn args -> System.cmd("git", ["-C", tree | args], env: Guest.git_env()) end
      assert {_, 0} = git_vm.(["commit", "-q", "-am", "the fix"])
      assert {"You you@example.test You\n", 0} = git_vm.(["log", "-1", "--format=%an %ae %cn"])

      git(repo, ["config", "user.email", "you@work.test"])
      {:ok, _} = Projects.mirror(username, "app")
      assert git(clone, ["config", "user.email"]) == "you@example.test\n"
      git(repo, ["config", "user.name", ""])
      assert {:ok, %{identity: nil}} = Projects.mirror(username, "app")
      assert git(clone, ["config", "user.name"]) == "You\n"
    end

    test "a missing commit-graph file does not prevent a handoff, its facts or landing",
         context do
      %{username: username, repo: repo} = context
      {_project, tree} = project_with_worktree(context)
      base_commit = sha(repo, "HEAD")
      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")
      head = sha(tree, "HEAD")

      # Git can still read the commits when this optional cache is missing,
      # but warns on stderr before printing a count, hash or merge result.
      graphs = Path.join(repo, ".git/objects/info/commit-graphs")
      File.mkdir_p!(graphs)
      File.write!(Path.join(graphs, "commit-graph-chain"), String.duplicate("0", 40) <> "\n")
      git(repo, ["config", "core.commitGraph", "true"])

      assert git(repo, ["rev-list", "--count", "HEAD..HEAD"]) =~
               "warning: unable to find all commit-graph files\n"

      assert {0, said} = Channel.answer("handoff", ask(tree), username)
      assert said =~ "Handed off as #1"

      assert {:ok,
              %{
                tip: ^base_commit,
                merge_base: ^base_commit,
                commits: [%{sha: ^head, subject: "the fix"}],
                files: [%{path: "a.txt", added: 1, removed: 0}],
                added: 1,
                removed: 0,
                behind: 0,
                conflicts: []
              }} = Handoffs.facts(username, 1)

      assert {:ok, _} = Handoffs.accept(username, 1, {:branch, "master", "fix"})
      assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo\nthree\n"
      assert {:ok, "one\ntwo\nthree\nfour\n"} = HostGit.run(repo, ["show", "mwt/fix:a.txt"])
      assert [%Handoff{status: :accepted}] = handoffs(username)
    end

    # The same warning in the VM's repository: git there prints it on
    # stderr, which is no part of the output MWT reads.

    test "a git warning in the VM's repository neither stops a handoff nor is kept as edits",
         context do
      %{username: username, repo: repo, mirror: mirror} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"b.txt", "two\n"}], "the fix")

      graphs = Path.join(mirror, ".git/objects/info/commit-graphs")
      File.mkdir_p!(graphs)
      File.write!(Path.join(graphs, "commit-graph-chain"), String.duplicate("0", 40) <> "\n")
      git(mirror, ["config", "core.commitGraph", "true"])
      assert git(tree, ["status", "--porcelain"]) =~ "warning: unable to find all commit-graph"

      assert {0, said} = Channel.answer("handoff", ask(tree), username)
      assert said =~ "Handed off as #1"
      assert {0, _project} = Channel.answer("project", %{"cwd" => tree}, username)

      commit(repo, [{"c.txt", "yours\n"}], "you move on")
      assert {:ok, %{rescued: nil}} = Projects.mirror(username, "app")
    end

    test "only registered project clones can hand off", %{username: username, vm: vm, repo: repo} do
      other = Path.join(vm, "other")
      {_, 0} = System.cmd("git", ["clone", "-q", repo, other], env: Guest.git_env())
      git(other, ["checkout", "-q", "-b", "work"])
      commit(other, [{"x.txt", "x\n"}], "work")
      assert {1, said} = Channel.answer("handoff", ask(other), username)
      assert said =~ "no registered host origin"
      MWTClient.StandIns.remove_guest(username)
      assert {1, "The VM isn't running."} = Channel.answer("handoff", ask(other), username)
    end
  end
end
