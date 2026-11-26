defmodule MWTClient.Sandbox.Guest do
  @moduledoc """
  Reaching into a VM from MWT: running a command there, and the address
  git uses for a repository there.

  Both go through `msb exec`, a pipe into the running VM. There is no
  network between MWT and the VM and no shared folder for projects, so this
  pipe is how a project's commits travel: git's own protocol runs through
  it, with `git upload-pack` or `git receive-pack` on the VM's end.
  `--stream` matters: plain `msb exec` holds the command's output until it
  ends, which stalls a protocol that talks both ways.

  A guest is a map, so tests can put a folder of this machine in the VM's
  place (`local/1`):

    * `root` - where projects live there (`/work`);
    * `exec` - runs a command, given as words, and returns its output
      (stdout), at most `MWTClient.Sandbox.Msb.max_output/0` bytes of it:
      what a command in the VM prints is the VM's to decide;
    * `run` - runs a command, given as words, for at most a number of
      seconds, taking at most a number of bytes of its output, and returns
      the output and the exit status, whatever it is: what the VM console
      shows (`MWTClient.Sandbox.Console`);
    * `git_url` - the address of the repository at a path there, for
      `git push` and `git fetch` on this machine;
    * `env` - what git needs in its environment to use that address;
    * `stream` - the words that run a command, given as words, in the VM
      with its input and output streamed, for a pipe on this machine;
    * `place` - where a path of this machine is in the VM: the same path,
      or one under `root` for tests;
    * `show` - how a shared folder's copy is shown at its path
      (`MWTClient.Sandbox.ShareMounts`): a read-only bind `:mount` in a
      VM, a `:link` in a test's folder, where nothing can be mounted.
  """

  alias MWTClient.Sandbox.{Bounded, Msb}
  alias MWTClient.Sandbox.Msb.Commands

  @type t :: %{
          root: Path.t(),
          exec: ([String.t()] -> {:ok, String.t()} | {:error, String.t()}),
          run: ([String.t()], pos_integer(), pos_integer() ->
                  {:ok, String.t(), non_neg_integer()} | {:error, term()}),
          git_url: (Path.t() -> String.t()),
          env: [{String.t(), String.t()}],
          stream: ([String.t()] -> [String.t()]),
          place: (Path.t() -> Path.t()),
          show: :mount | :link
        }

  @doc "The running VM of an identity."
  @spec vm(String.t(), String.t()) :: t()
  def vm(username, name) do
    %{
      root: "/work",
      exec: fn words -> Msb.run(username, Commands.exec(name, words), 300) end,
      run: fn words, seconds, max ->
        Msb.run_status(username, Commands.exec(name, words), seconds, max)
      end,
      # git's `ext` transport: a command whose input and output carry the
      # protocol. `%s` becomes upload-pack or receive-pack.
      git_url: fn path ->
        "ext::" <>
          Enum.map_join(
            [Msb.confined(username) | Commands.exec_stream(name, ["git", "%s", path])],
            " ",
            &ext_word/1
          )
      end,
      env: Msb.env(username),
      stream: fn words -> [Msb.confined(username) | Commands.exec_stream(name, words)] end,
      place: & &1,
      show: :mount
    }
  end

  @doc """
  A folder of this machine standing in for the VM's disk, for tests. Its
  `exec` takes output as `MWTClient.Sandbox.Msb.run/3` does: stdout alone,
  at most `Msb.max_output/0` bytes of it, more is an error.
  """
  @spec local(Path.t()) :: t()
  def local(root) do
    %{
      root: root,
      exec: fn [command | args] ->
        case Bounded.cmd(command, args,
               max: Msb.max_output(),
               seconds: 300,
               env: git_env()
             ) do
          {:ok, output, _errors, 0} ->
            {:ok, output}

          {:ok, output, errors, _status} ->
            {:error, Bounded.failure(output, errors, Msb.error_limit())}

          {:error, :timeout} ->
            {:error, "#{command} took longer than 300 s"}

          {:error, {:too_long, _head}} ->
            {:error, "#{command} printed too much"}
        end
      end,
      run: fn [command | args], seconds, max ->
        case Bounded.cmd(command, args, max: max, seconds: seconds, env: git_env()) do
          {:ok, output, _errors, status} -> {:ok, output, status}
          {:error, reason} -> {:error, reason}
        end
      end,
      git_url: fn path -> path end,
      env: [],
      stream: & &1,
      place: &(root <> &1),
      show: :link
    }
  end

  @doc "An environment in which git reads no configuration but the repository's own."
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env, do: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  # In an `ext::` address a space separates words and `%` starts an escape;
  # `% ` is a space inside a word. `%s` is left for git to fill in.
  defp ext_word("%s"), do: "%s"
  defp ext_word(word), do: word |> String.replace("%", "%%") |> String.replace(" ", "% ")
end
