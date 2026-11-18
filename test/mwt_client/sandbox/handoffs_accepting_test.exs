defmodule MWTClient.Sandbox.HandoffsAcceptingTest do
  @moduledoc """
  What happens to a handoff once it is sent: accepted onto its base, sent
  back with a note, refused for a real value it brings, or left in the VM.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox

  alias MWTClient.Sandbox.{
    AgentThreads,
    Channel,
    Guest,
    Handoff,
    Handoffs,
    Project,
    Projects,
    Server
  }

  alias MWTClientWeb.SandboxLive.Handoffs, as: HandoffsPage

  describe "accepting" do
    setup context do
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "the fix")
      {0, _} = Channel.answer("handoff", ask(tree), context.username)
      %{tree: tree}
    end

    test "waits for a target branch with no pending work", %{username: username, repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "pending\n")

      assert {:error, {:pending, "master", ^repo, ["a.txt"]}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      assert {:error, {:pending, _, _, _} = pending} =
               Handoffs.accept(username, 1, {:commit, "master"})

      assert Handoffs.explain(pending) =~ "work you haven't committed: a.txt"
      git(repo, ["checkout", "-q", "--", "a.txt"])

      # Files git doesn't track don't count.
      File.write!(Path.join(repo, "notes.txt"), "mine\n")

      assert {:ok, %{conflicts: [], worktree: ^repo, behind: 0}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      git(repo, ["checkout", "-q", "-b", "elsewhere"])
      assert {:ok, %{worktree: nil}} = Handoffs.preview(username, 1, {:commit, "master"})
    end

    test "as it is on its base by default, undone while it stays there", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      before = sha(repo, "HEAD")
      assert {:ok, %{onto: "master", prefix: "mwt/", name: "fix"}} = Handoffs.landing(username, 1)

      assert {:ok, %{as: :as_is, fast_forward?: true, commits: 1}} =
               Handoffs.preview(username, 1)

      assert {:ok, %Handoff{status: :accepted, accepted: %{how: :as_is, branch: "master"}}} =
               Handoffs.accept(username, 1)

      # Its own commit, as the VM has it: master moved to it.
      assert sha(repo, "HEAD") == sha(tree, "HEAD")
      assert sha(repo, "HEAD~1") == before
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
      assert git(repo, ["status", "--porcelain"]) == ""
      refute git(repo, ["for-each-ref"]) =~ "refs/mwt/handoffs/"

      assert {:ok, %Handoff{status: :open}} = Handoffs.undo(username, 1)
      assert sha(repo, "HEAD") == before
      refute File.exists?(Path.join(repo, "b.txt"))
    end

    test "as one commit when you choose, undone while it stays there", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      before = sha(repo, "HEAD")

      assert {:ok, %{as: :one_commit, fast_forward?: true}} =
               Handoffs.preview(username, 1, nil, one_commit: true)

      assert {:ok, %Handoff{status: :accepted, accepted: %{how: :commit, branch: "master"}}} =
               Handoffs.accept(username, 1, nil, one_commit: true)

      # One commit on what master was, with the task's tree, its title and you.
      assert sha(repo, "HEAD~1") == before
      assert sha(repo, "HEAD^{tree}") == sha(tree, "HEAD^{tree}")
      assert git(repo, ["log", "-1", "--format=%s|%an|%cn"]) == "The fix|Someone|Someone\n"
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
      assert git(repo, ["status", "--porcelain"]) == ""
      refute git(repo, ["for-each-ref"]) =~ "refs/mwt/handoffs/"

      assert {:ok, %Handoff{status: :open}} = Handoffs.undo(username, 1)
      assert sha(repo, "HEAD") == before
      refute File.exists?(Path.join(repo, "b.txt"))
    end

    test "undo leaves another branch checked out at the same commit alone", %{
      username: username,
      repo: repo
    } do
      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      head = sha(repo, "HEAD")
      git(repo, ["checkout", "-q", "-b", "other-work"])
      assert {:error, :moved} = Handoffs.undo(username, 1)
      assert sha(repo, "master") == head
      assert sha(repo, "HEAD") == head
    end

    test "on a branch that moved since, its changes go on top, counted as untested", %{
      username: username,
      repo: repo
    } do
      commit(repo, [{"c.txt", "yours\n"}], "yours")
      yours = sha(repo, "HEAD")

      assert {:ok, %{conflicts: [], behind: 1, up_to_date?: false}} =
               Handoffs.preview(username, 1, {:commit, "master"})

      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      assert sha(repo, "HEAD~1") == yours
      assert File.read!(Path.join(repo, "c.txt")) == "yours\n"
      assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo\nthree\nfour\n"
      assert File.read!(Path.join(repo, "b.txt")) == "new\n"
    end

    test "a branch that has it all already takes nothing", %{username: username, repo: repo} do
      commit(repo, [{"a.txt", "one\ntwo\nthree\nfour\n"}, {"b.txt", "new\n"}], "same")
      before = sha(repo, "HEAD")

      assert {:ok, %{up_to_date?: true}} = Handoffs.preview(username, 1, {:commit, "master"})
      assert {:error, :up_to_date} = Handoffs.accept(username, 1, {:commit, "master"})
      assert sha(repo, "HEAD") == before
    end

    test "with no identity on your machine no commit is made for it", %{
      username: username,
      repo: repo
    } do
      before = sha(repo, "HEAD")
      git(repo, ["config", "user.name", ""])

      assert {:error, :no_identity = reason} =
               Handoffs.accept(username, 1, {:commit, "master"}, one_commit: true)

      assert Handoffs.explain(reason) =~ "set user.name and user.email"
      assert sha(repo, "HEAD") == before
    end

    # Its files are on your branch from that moment: MWT stopping right
    # after, with no clean stop to save it, must not show it open again.
    test "is on disk as accepted when it returns", %{username: username, key: key} do
      assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
      assert [%Handoff{status: :accepted}] = Server.State.restore(username, key).handoffs
    end

    # To look at it again, it is opened where it was reviewed: in the VM.
    test "says where its branch is in the VM while it waits", %{username: username, tree: tree} do
      assert {:ok, %{path: ^tree, slot: "slot-1"}} = Handoffs.worktree(username, 1)
      git(tree, ["switch", "--detach", "HEAD"])
      assert {:ok, nil} = Handoffs.worktree(username, 1)
    end

    test "conflicts once your branch moved: sent back to its thread with a note", %{
      username: username,
      repo: repo,
      tree: tree
    } do
      commit(repo, [{"a.txt", "one\ntwo\nthree\nyours\n"}], "yours")

      assert {:ok, %{conflicts: ["a.txt"]}} = Handoffs.preview(username, 1, {:commit, "master"})

      assert {:error, {:conflicts, "master", ["a.txt"]} = reason} =
               Handoffs.accept(username, 1, {:commit, "master"})

      assert Handoffs.explain(reason) =~ "Its changes conflict with master in: a.txt"
      assert git(repo, ["status", "--porcelain"]) == ""

      assert {:ok, %Handoff{status: :sent_back}} =
               Handoffs.send_back(username, 1, "Catch up with mine.")

      {:ok, _} = Projects.mirror(username, "app")
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
      assert listed =~ "sent back to you" and listed =~ "Catch up with mine."
      assert listed =~ "conflicts with their master in: a.txt"

      assert {:ok, %Handoff{status: :closed}} = Handoffs.close(username, 1)
      assert Handoffs.accept(username, 1, {:commit, "master"}) == {:error, :not_open}
      assert {:ok, %Handoff{status: :open}} = Handoffs.reopen(username, 1)
    end
  end

  describe "sending back" do
    setup context do
      {_project, tree} = project_with_worktree(context)
      commit(tree, [{"a.txt", "one\ntwo\nthree\nfour\n"}], "the fix")

      {0, _} =
        Channel.answer("handoff", ask(tree, %{"thread_id" => "thread-a"}), context.username)

      %{tree: tree}
    end

    defp sent_back_event(handoff),
      do: handoff.timeline |> Enum.filter(&(&1.kind == :sent_back)) |> List.last()

    test "says the note in the handoff's thread when MWT can reach it", %{
      username: username,
      tree: tree
    } do
      # The thread's mwt-acp, attached to the channel, with the thread open.
      {:ok, socket} =
        :gen_tcp.connect({:local, Channel.socket_path(username)}, 0, [
          :binary,
          packet: :line,
          active: false
        ])

      line = fn message -> :ok = :gen_tcp.send(socket, Jason.encode!(message) <> "\n") end
      line.(%{command: "attach", agent: "claude-acp", pid: 1})
      line.(%{type: "opened", thread: "thread-a", folder: tree, working: false})

      Enum.find_value(1..100, fn _ ->
        match?(%{open?: true}, AgentThreads.get(username, "thread-a")) ||
          (Process.sleep(10) && nil)
      end)

      task = Task.async(fn -> Handoffs.send_back(username, 1, "Add a test.") end)
      {:ok, said} = :gen_tcp.recv(socket, 0, 2_000)

      assert %{"type" => "say", "id" => say_id, "thread" => "thread-a", "text" => text} =
               Jason.decode!(said)

      assert text == "MWT (handoff #1 sent back): Add a test."

      # By then the handoff says it, for the agent that looks.
      assert {0, listed} = Channel.answer("handoffs", %{"cwd" => tree}, username)
      assert listed =~ "sent back to you" and listed =~ "Add a test."

      line.(%{type: "said", id: say_id})
      assert {:ok, %Handoff{status: :sent_back} = handoff} = Task.await(task)
      assert %{note: "Add a test.", delivery: %{said?: true}} = sent_back_event(handoff)

      assert HandoffsPage.delivery_words(sent_back_event(handoff).delivery) =~
               "went to its thread"
    end

    test "says why the note didn't go to its thread", %{username: username} do
      assert {:ok, handoff} = Handoffs.send_back(username, 1, "Add a test.")
      assert %{delivery: %{said?: false, why: why}} = sent_back_event(handoff)
      assert why == "The VM isn't running."
      assert HandoffsPage.delivery_words(sent_back_event(handoff).delivery) =~ "mwt handoffs"

      # Sent back again: each send back says its own.
      assert {:ok, handoff} = Handoffs.send_back(username, 1, "And another.")

      assert [%{delivery: %{said?: false}}, %{note: "And another.", delivery: %{said?: false}}] =
               Enum.filter(handoff.timeline, &(&1.kind == :sent_back))
    end
  end

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
