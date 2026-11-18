defmodule MWTClient.HandoffsCase do
  @moduledoc """
  Projects, their mirrors, agent worktrees and handoffs, through the
  sandbox of an unlocked identity, as the agent channel and the pages use
  them. A folder of this machine stands in for the VM's Work disk
  (`MWTClient.StandIns`); `vm_live_test.exs` has the real VM.

  Each test has an identity of its own, with a repository of yours in a
  shared folder: the test modules about handoffs run side by side.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Projects}

  using do
    quote do
      import MWTClient.HandoffsCase
    end
  end

  @me [
    {"GIT_AUTHOR_NAME", "Someone"},
    {"GIT_AUTHOR_EMAIL", "someone@example.test"},
    {"GIT_COMMITTER_NAME", "Someone"},
    {"GIT_COMMITTER_EMAIL", "someone@example.test"}
  ]

  @doc "What git runs with: who commits, and none of this machine's git config."
  def git_env, do: @me ++ Guest.git_env()

  def git(dir, args) do
    case System.cmd("git", ["-C", dir | args],
           env: git_env(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{output}")
    end
  end

  def commit(dir, files, message) do
    Enum.each(files, fn {name, text} -> File.write!(Path.join(dir, name), text) end)
    git(dir, ["add", "--all"])
    git(dir, ["commit", "-q", "-m", message])
  end

  def sha(dir, rev), do: dir |> git(["rev-parse", rev]) |> String.trim()

  setup do
    %{username: username, key: key} = MWTClient.VaultHelpers.unlocked_identity("handoffs")
    base = Path.join(System.tmp_dir!(), "handoffs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "host/app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    commit(repo, [{"a.txt", "one\ntwo\nthree\n"}], "first")
    # Who you commit as: a landing's commit is yours.
    git(repo, ["config", "user.name", "Someone"])
    git(repo, ["config", "user.email", "someone@example.test"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    MWTClient.StandIns.put_guest(username, Guest.local(vm))

    # Your projects folder, shared read-only: every repository in it is a project.
    {:ok, _} = Sandbox.add_share(username, Path.join(base, "host"))

    %{username: username, key: key, repo: repo, vm: vm, base: base, mirror: Path.join(vm, "app")}
  end

  # A project, and a task started in a worktree slot the way an agent
  # starts one: in slot-1, which the project gets first.
  def project_with_worktree(%{username: username, repo: repo, mirror: mirror}, task \\ "fix") do
    {:ok, project} = Projects.open(username, repo)
    {:ok, "slot-1"} = Projects.add_slot(username, project.name)
    tree = Path.join(mirror <> ".wt", "slot-1")

    {0, _} =
      Channel.answer("worktree", %{"cwd" => tree, "name" => task, "from" => "master"}, username)

    {project, tree}
  end

  @doc """
  Another task beside it, as a worktree of the clone on a branch of its
  own, from `from`: recorded as a task (its base in git config), as
  `mwt worktree new` records one, so it hands off; not a slot.
  """
  def new_worktree(clone, branch, from \\ "refs/remotes/origin/master") do
    tree = Path.join(clone <> ".wt", branch)
    git(clone, ["worktree", "add", "-q", "--no-track", "-b", branch, tree, from])
    git(clone, ["config", "branch.#{branch}.mwt-base", from])
    tree
  end

  def ask(cwd, extra \\ %{}),
    do:
      Map.merge(
        %{
          "cwd" => cwd,
          "title" => "The fix",
          "body" => "Done.",
          "agent" => "claude",
          "thread" => "Fix the login"
        },
        extra
      )

  def handoffs(username), do: Sandbox.snapshot(username).handoffs

  # The mwt command an agent runs in `cwd`, as in the VM: socat carries its
  # ask to the channel's socket and the answer back.
  def cli(%{base: base, username: username}, cwd) do
    cli = Path.expand("../../priv/sandbox/mwt-cli", __DIR__)
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)

    # Both ways at once, as socat does: git's remote helper (`git fetch
    # origin`, through MWT) talks while it reads.
    File.write!(Path.join(bin, "socat"), """
    #!/usr/bin/env python3
    import os, socket, sys, threading
    address = sys.argv[-1]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(address[len("UNIX-CONNECT:"):])
    def send():
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                break
            s.sendall(chunk)
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    threading.Thread(target=send, daemon=True).start()
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        os.write(1, chunk)
    """)

    File.chmod!(Path.join(bin, "socat"), 0o755)

    File.cp!(
      Path.expand("../../priv/sandbox/mwt-git-remote", __DIR__),
      Path.join(bin, "git-remote-mwt")
    )

    File.chmod!(Path.join(bin, "git-remote-mwt"), 0o755)

    fn args ->
      System.cmd("bash", [cli | args],
        cd: cwd,
        env:
          [
            {"PATH", bin <> ":" <> System.get_env("PATH")},
            {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(username)},
            {"MWT_AGENT", "claude"},
            {"MWT_THREAD", nil},
            {"CLAUDE_CODE_SESSION_ID", nil},
            {"CLAUDE_PID", nil},
            {"CODEX_THREAD_ID", nil}
          ] ++ git_env(),
        stderr_to_stdout: true
      )
    end
  end
end
