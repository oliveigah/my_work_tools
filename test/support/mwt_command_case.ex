defmodule MWTClient.MwtCommandCase do
  @moduledoc """
  The `mwt` command in the VM, run on this machine against an unlocked
  identity's agent channel, with a fake socat: what the agent types, the
  channel, the server's approval, and what the agent hears back.

  Each test has an identity, with Ask to run commands on, and a folder of
  its own, so the modules that use this run side by side.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions, only: [flunk: 1]

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Channel

  using do
    quote do
      import MWTClient.MwtCommandCase
    end
  end

  @cli Path.expand("../../priv/sandbox/mwt-cli", __DIR__)

  # Stands in for socat: sends stdin to the Unix socket the address names,
  # then prints everything until MWT closes.
  @fake_socat """
  #!/usr/bin/env python3
  import socket, sys
  address = sys.argv[-1]
  assert address.startswith("UNIX-CONNECT:"), address
  data = sys.stdin.buffer.read()
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(address[len("UNIX-CONNECT:"):])
  s.sendall(data)
  while True:
      chunk = s.recv(65536)
      if not chunk:
          break
      sys.stdout.buffer.write(chunk)
  """

  setup do
    base = Path.join(System.tmp_dir!(), "mwt-run-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    project = Path.join(base, "project")
    File.mkdir_p!(bin)
    File.mkdir_p!(project)
    File.write!(Path.join(bin, "socat"), @fake_socat)
    File.chmod!(Path.join(bin, "socat"), 0o755)
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    # A command an agent writes needs no grant: each run asks.
    "commands"
    |> MWTClient.VaultHelpers.unlocked_identity()
    |> Map.merge(%{bin: bin, project: project})
  end

  @doc """
  Runs `mwt` with `args` in the test's project folder, as the agent
  `claude` in the thread "Ship the release". Options: `:input`, a script
  on its stdin; `:cd`; `:stderr` (true: printed with stdout).
  """
  def mwt(context, args, opts \\ []) do
    {input, opts} = Keyword.pop(opts, :input)

    env = [
      {"PATH", context.bin <> ":" <> System.get_env("PATH")},
      {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)},
      {"MWT_AGENT", "claude"},
      {"MWT_THREAD", "Ship the release"},
      {"CLAUDE_CODE_SESSION_ID", nil},
      {"CLAUDE_PID", nil},
      {"CODEX_THREAD_ID", nil}
    ]

    if input do
      # A script on stdin: run through a shell so the CLI's stdin is a pipe.
      script_file = Path.join(context.bin, "stdin-#{System.unique_integer([:positive])}")
      File.write!(script_file, input)
      quoted = Enum.map_join([@cli | args], " ", &shell_quote/1)

      MWTClient.Executable.cmd("bash", ["-c", "bash #{quoted} < #{shell_quote(script_file)}"],
        env: env,
        cd: Keyword.get(opts, :cd, context.project)
      )
    else
      MWTClient.Executable.cmd("bash", [@cli | args],
        env: env,
        cd: Keyword.get(opts, :cd, context.project),
        stderr_to_stdout: Keyword.get(opts, :stderr, true)
      )
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  @doc "The first approval waiting for you that `fun` picks, waited for up to 3 s."
  def waiting(username, fun) do
    Enum.find_value(1..300, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, fun) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end) || flunk("nothing like that waited")
  end

  @doc "The card asking to run a host command."
  def command(username), do: waiting(username, &(&1.kind == :command and &1.stage == :run))

  @doc "The card asking whether a command's output goes to the agent."
  def output_card(username),
    do: waiting(username, &(&1.kind == :command and &1.stage == :output))

  @doc "Shares the test's project folder, returning its path."
  def share(context) do
    {:ok, share} = Sandbox.add_share(context.username, context.project)
    share.path
  end
end
