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
    case MWTClient.Executable.cmd("git", ["-C", dir | args],
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
    base = Path.join(System.tmp_dir!(), "handoffs-#{System.unique_integer([:positive])}")
    # Before the identity: removed once its sandbox's work has ended.
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)
    %{username: username, key: key} = MWTClient.VaultHelpers.unlocked_identity("handoffs")

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
  def new_worktree(clone, branch, from \\ "refs/remotes/host-origin/master") do
    tree = Path.join(clone <> ".wt", branch)
    git(clone, ["worktree", "add", "-q", "--no-track", "-b", branch, tree, from])
    git(clone, ["config", "branch.#{branch}.mwt-base", from])
    tree
  end

  @doc """
  A setup for the tests of worktree slots: your repository ignores the
  build's output, which a slot keeps warm, and the project has slot-1 to
  slot-3 beside slot-0, the clone. `worktree/4` fetches from it.
  """
  def with_slots(%{username: username, repo: repo, mirror: mirror}) do
    commit(repo, [{".gitignore", "_build/\n"}], "ignore the build")
    {:ok, _} = Projects.open(username, repo)
    {:ok, "slot-1"} = Projects.add_slot(username, "app")
    {:ok, "slot-2"} = Projects.add_slot(username, "app")
    {:ok, "slot-3"} = Projects.add_slot(username, "app")
    Process.put(:fetch, {mirror, repo})
    :ok
  end

  @doc """
  Your repository's own remote `origin`, a Git server standing in for
  GitHub, cloned from your repository as it is; returns a teammate's clone
  of it, for `push_to_remote/3`.
  """
  def with_remote(%{base: base, repo: repo}) do
    server = Path.join(base, "server.git")
    git(base, ["clone", "-q", "--bare", repo, server])
    git(repo, ["remote", "add", "origin", server])
    team = Path.join(base, "teammate")
    git(base, ["clone", "-q", server, team])
    team
  end

  @doc "A teammate's commit in `team`, pushed to the remote's master; its ID."
  def push_to_remote(team, files, message) do
    commit(team, files, message)
    git(team, ["push", "-q", "origin", "HEAD:master"])
    sha(team, "HEAD")
  end

  @doc "The base a task's branch records (`branch.NAME.mwt-base`)."
  def task_base(dir, branch),
    do: dir |> git(["config", "branch.#{branch}.mwt-base"]) |> String.trim()

  @doc "The folder of slot `n` of the clone `mirror`."
  def slot(mirror, n), do: Path.join(mirror <> ".wt", "slot-#{n}")

  @doc """
  `mwt worktree ACTION` in `cwd`: a new task from your master unless
  `fields` names another base. It fetches host-origin first, as the command does.
  """
  def worktree(username, cwd, action, fields \\ %{}) do
    {mirror, repo} = Process.get(:fetch)
    git(mirror, ["fetch", "-q", repo, "+refs/heads/*:refs/remotes/host-origin/*"])
    base = if action == "new", do: %{"from" => "master"}, else: %{}

    Channel.answer(
      "worktree",
      Map.merge(Map.merge(base, %{"cwd" => cwd, "action" => action}), fields),
      username
    )
  end

  @doc "The numbered slots' states, `{name, branch, free?}`; slot-0's apart."
  def states(username) do
    {:ok, %{slots: slots}} = Projects.slots(username, "app")
    for slot <- slots, slot.name != "slot-0", do: {slot.name, slot.branch, slot.free?}
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

  @doc "What MWT says of the branch in `cwd`, as `mwt handoff` asks it at a terminal."
  def about_branch(username, cwd),
    do: Channel.answer("handoff", %{"stage" => "branch", "cwd" => cwd}, username)

  @doc "Every handoff kept, the newest first."
  def handoffs(username) do
    for id <- Enum.reverse(MWTClient.Sandbox.HandoffRecords.ids(username)),
        {:ok, handoff} <- [MWTClient.Sandbox.HandoffRecords.get(username, id)],
        do: handoff
  end

  # The mwt command an agent runs in `cwd`, as in the VM: socat carries its
  # ask to the channel's socket and the answer back.
  def cli(context, cwd) do
    run = mwt(context, cwd)
    fn args -> run.(args, "bash", []) end
  end

  @doc """
  The mwt command as you run it at a terminal in the VM, in `cwd`: in a
  pseudo-terminal of its own, under Zed's server (as its terminals are),
  with no agent's thread. Each line of `typed` is what you type, in order;
  git's editor puts `notes` above what the file held, which
  `editor_saw/1` reads. Returns what the terminal showed and the exit
  status.
  """
  def at_terminal(%{base: base} = context, cwd) do
    run = mwt(context, cwd)
    terminal = Path.join(base, "bin/terminal")
    editor = Path.join(base, "bin/editor")

    File.write!(terminal, """
    #!/usr/bin/env python3
    # Runs the command in a new pseudo-terminal: types $TYPED into it, and
    # writes what it shows to stdout. Gives up after 60 s.
    import os, pty, select, signal, sys, time
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])
    os.write(fd, os.environ.get("TYPED", "").encode())
    shown, deadline = b"", time.monotonic() + 60
    while True:
        ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            os.kill(pid, signal.SIGKILL)
            shown += b"\\n[terminal: gave up after 60 s]"
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        shown += chunk
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(shown.replace(b"\\r\\n", b"\\n"))
    sys.exit(os.waitstatus_to_exitcode(status))
    """)

    File.write!(editor, """
    #!/bin/sh
    cp "$1" "$EDITOR_SAW"
    { printf '%s\\n' "$NOTES"; cat "$EDITOR_SAW"; } > "$1"
    """)

    File.chmod!(terminal, 0o755)
    File.chmod!(editor, 0o755)

    fn args, typed, notes ->
      run.(args, terminal, [
        {"MWT_AGENT", "zed-remote-serv"},
        {"TYPED", typed},
        {"GIT_EDITOR", editor},
        {"EDITOR_SAW", Path.join(base, "editor-saw")},
        {"NOTES", notes}
      ])
    end
  end

  @doc "What git's editor was given to start from, in the last `at_terminal/2` run."
  def editor_saw(%{base: base}), do: File.read!(Path.join(base, "editor-saw"))

  # mwt-cli in `cwd`, run by `program` (bash, or a terminal running bash),
  # with `env` over an agent's environment.
  defp mwt(%{base: base, username: username}, cwd) do
    cli = Path.expand("../../priv/sandbox/mwt-cli", __DIR__)
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)

    fake_socat!(bin)

    File.cp!(
      Path.expand("../../priv/sandbox/mwt-git-remote", __DIR__),
      Path.join(bin, "git-remote-mwt")
    )

    File.chmod!(Path.join(bin, "git-remote-mwt"), 0o755)

    fn args, program, env ->
      command = if program == "bash", do: [cli | args], else: ["bash", cli | args]

      MWTClient.Executable.cmd(program, command,
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
          ]
          |> Kernel.++(git_env())
          |> Map.new()
          |> Map.merge(Map.new(env))
          |> Enum.to_list(),
        stderr_to_stdout: true
      )
    end
  end

  # Stands in for socat in `bin`, so tests don't need it installed. Both
  # ways at once, as socat does: git's remote helper (`git fetch origin`,
  # through MWT) talks while it reads.
  def fake_socat!(bin) do
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
  end
end
