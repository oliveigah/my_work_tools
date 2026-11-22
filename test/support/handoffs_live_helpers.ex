defmodule MWTClientWeb.HandoffsLiveHelpers do
  @moduledoc """
  What the tests of the Handoffs page share: a repository of yours, shared
  with the sandbox and opened as a project with a free slot (`project/1`,
  a setup), and handoffs made in it the way an agent makes them
  (`hand_off/6`). A folder of this machine stands in for the VM.

  Each test has an identity, a repository and a VM folder of its own, so
  the modules that use these run side by side.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Projects}

  @me [
    {"GIT_AUTHOR_NAME", "Someone"},
    {"GIT_AUTHOR_EMAIL", "someone@example.test"},
    {"GIT_COMMITTER_NAME", "Someone"},
    {"GIT_COMMITTER_EMAIL", "someone@example.test"}
  ]

  def git(dir, args) do
    {output, 0} =
      MWTClient.Executable.cmd("git", ["-C", dir | args],
        env: @me ++ Guest.git_env(),
        stderr_to_stdout: true
      )

    output
  end

  @doc """
  A setup: signs in, makes your repository `app` with one commit, a VM
  folder, shares the repository and opens it as a project with slot-1.
  """
  def project(%{conn: conn}) do
    base = Path.join(System.tmp_dir!(), "handoffs-live-#{System.unique_integer([:positive])}")
    # Before the identity: removed once its sandbox's work has ended.
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)
    context = MWTClientWeb.ConnCase.sign_in(conn)

    repo = Path.join(base, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\nthree\n")
    File.write!(Path.join(repo, "mix.exs"), "# the build\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])
    # Who you commit as: a landing's commit is yours.
    git(repo, ["config", "user.name", "Someone"])
    git(repo, ["config", "user.email", "someone@example.test"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    MWTClient.StandIns.put_guest(context.username, Guest.local(vm))

    {:ok, _} = MWTClient.Sandbox.add_share(context.username, repo)
    {:ok, _} = Projects.open(context.username, repo)
    # Tasks go in slot-1, beside the clone (slot-0).
    {:ok, "slot-1"} = Projects.add_slot(context.username, "app")
    Map.merge(context, %{repo: repo, vm: vm})
  end

  @doc """
  An agent's handoff: a task in a free worktree slot, from a thread there,
  based on your master unless it says, with one commit, then `mwt handoff`.
  `mwt worktree new` fetches origin first, as here.
  """
  def hand_off(username, vm, task, title, change, base \\ "master") do
    project = Enum.find(Sandbox.snapshot(username).projects, &(&1.name == "app"))

    git(Path.join(vm, "app"), ["fetch", "-q", project.path, "+refs/heads/*:refs/remotes/origin/*"])

    {:ok, %{slots: slots}} = Projects.slots(username, "app")
    %{path: free} = Enum.find(slots, &(&1.free? and &1.name != "slot-0"))

    {:ok, _project, %{path: tree}, :started, _onto, _where} =
      Projects.take_slot(username, free, :new, task, from: base)

    change.(tree)
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "work on #{task}"])

    {0, _} =
      Channel.answer(
        "handoff",
        %{
          "cwd" => tree,
          "title" => title,
          "body" => "Done, with tests.",
          "agent" => "claude",
          "thread" => "Fix the login thread"
        },
        username
      )

    [handoff | _] = Sandbox.snapshot(username).handoffs
    handoff
  end
end
