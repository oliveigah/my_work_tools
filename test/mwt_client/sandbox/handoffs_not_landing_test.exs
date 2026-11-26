defmodule MWTClient.Sandbox.HandoffsNotLandingTest do
  @moduledoc """
  A handoff that doesn't land: refused for a real value it brings, or left
  in the VM. Accepting has handoffs_accepting_test.exs, so the two run side
  by side. The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Guest, Handoffs, Project, Projects}

  describe "a handoff bringing a real value" do
    @real "ghp_REAL_SECRET_VALUE_0123"

    setup %{username: username} do
      {:ok, _grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "api.github.com",
          "env" => "GH_TOKEN",
          "value" => @real
        })

      :ok
    end

    test "is refused, in a file, a commit message or its words; a clean one goes", context do
      %{username: username} = context
      {_project, tree} = project_with_worktree(context)
      # Only told, the firewall leaves the VM to try again.
      :ok = Sandbox.firewall_set(username, {:action, :real_value, :alert})
      start = sha(tree, "HEAD")

      commit(tree, [{"config.exs", ~s(config :app, token: "#{@real}"\n)}], "Add the config")

      assert {:error, {:real_value, "GitHub", "the file config.exs"} = refused} =
               Handoffs.open(username, %{cwd: tree, title: "Config"})

      assert Handoffs.explain(refused) =~ "MWT refused this handoff: the file config.exs holds"
      refute Handoffs.explain(refused) =~ @real
      assert handoffs(username) == []

      git(tree, ["reset", "-q", "--hard", start])
      commit(tree, [{"b.txt", "b\n"}], "Use #{@real} for now")

      assert {:error, {:real_value, "GitHub", "commit " <> _}} =
               Handoffs.open(username, %{cwd: tree, title: "B"})

      git(tree, ["reset", "-q", "--hard", start])
      commit(tree, [{"c.txt", "c\n"}], "C")

      assert {:error, {:real_value, "GitHub", "its title or notes"}} =
               Handoffs.open(username, %{cwd: tree, title: "C", body: "Tested with #{@real}"})

      assert handoffs(username) == []
      assert {:ok, _handoff, :opened} = Handoffs.open(username, %{cwd: tree, title: "C"})
      refute Enum.any?(Sandbox.events(username), &(inspect(&1) =~ @real))
    end

    test "isolates the VM by default", context do
      %{username: username} = context
      {_project, tree} = project_with_worktree(context)
      File.mkdir_p!(Path.join(tree, "deep/in/a"))
      commit(tree, [{"deep/in/a/folder.txt", "x #{@real} y\n"}], "Add it")

      assert {:error, {:real_value, "GitHub", "the file deep/in/a/folder.txt"}} =
               Handoffs.open(username, %{cwd: tree, title: "Deep"})

      assert %{rule: :real_value} = Sandbox.firewall(username).firewall.isolated
    end
  end

  describe "projects left in the VM" do
    alias MWTClient.Sandbox.Leftovers

    test "are mirrors whose repository is gone from your machine, with what would go with them",
         context do
      %{username: username, repo: repo, mirror: mirror, vm: vm} = context
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"b.txt", "unhanded\n"}], "work never handed off")
      File.write!(Path.join(tree, "notes.txt"), "not committed\n")

      # A clone of an agent's own, beside it, is no mirror of MWT's.
      {_, 0} =
        System.cmd("git", ["clone", "-q", repo, Path.join(vm, "clone")], env: Guest.git_env())

      # Your repository is there: nothing is left over.
      assert {:ok, []} = Leftovers.list(username)
      assert {:error, :not_left_over} = Leftovers.remove(username, "app")

      File.rm_rf!(repo)

      assert {:ok, [left]} = Leftovers.list(username)
      assert %{name: "app", why: :repository_gone, project: %Project{name: "app"}} = left
      assert left.size > 0
      assert left.uncommitted == [tree]
      assert left.unmerged == ["fix"]

      assert :ok = Leftovers.remove(username, "app")
      refute File.exists?(mirror)
      refute File.exists?(mirror <> ".wt")
      assert File.dir?(Path.join(vm, "clone"))
      assert Projects.list(username) == []
      assert {:ok, []} = Leftovers.list(username)
    end

    test "or no project's: forgotten, and no shared folder has a repository by its name", %{
      username: username,
      repo: repo,
      base: base,
      mirror: mirror
    } do
      {:ok, _} = Projects.open(username, repo)
      :ok = Projects.forget(username, "app")

      # Forgotten but still shared: opening it again uses its mirror.
      assert {:ok, []} = Leftovers.list(username)

      # Moved out of every shared folder.
      File.rename!(repo, Path.join(base, "elsewhere"))

      assert {:ok, [%{name: "app", why: :not_a_project, project: nil, unmerged: []}]} =
               Leftovers.list(username)

      assert :ok = Leftovers.remove(username, "app")
      refute File.exists?(mirror)

      assert [%{summary: "app removed from the VM"} | _] =
               for(%{outcome: :project} = e <- Sandbox.events(username), do: e)
    end
  end
end
