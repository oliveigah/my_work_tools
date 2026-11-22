defmodule MWTClient.Sandbox.Bounded do
  @moduledoc """
  Runs a command on this machine whose output the VM decides, and takes at
  most `max` bytes of it, and its errors apart.

  Whatever MWT runs in the VM through `msb exec` prints what the VM's root
  makes it print: `sh`, `git`, `find` and `tar` there are found on a PATH
  root controls. `System.cmd/3` would collect all of it, so a VM printing
  without end would grow MWT's memory without end. Here the output is
  collected up to `max` bytes; one byte more and the command is killed,
  with every process it started, and the run is `{:error, {:too_long,
  head}}`, `head` being the first `max` bytes. This machine's `head` stands
  between the command and MWT, and lets one byte past `max` through: a
  port reads whatever comes, without waiting for MWT to take it, so a
  flood would otherwise pile up in MWT's mailbox while MWT waits for a
  scheduler on a busy machine.

  What it writes to stderr is kept apart, its first 64 KiB, in a folder of
  MWT's own (`MWTClient.Sandbox.Scratch`): a warning from git in the VM is
  no part of the output MWT reads, and the errors of a command that failed
  say why. Past those 64 KiB, writing to stderr fails, which ends a
  command flooding it.

  The command runs under `timeout`, which gives it a process group of its
  own: TERM at `seconds`, KILL 5 seconds later, and the group is what is
  killed when the output is too long.
  """

  alias MWTClient.Sandbox.Scratch

  @kill_after 5
  @error_bytes 64 * 1024

  # Runs the command with its stdout on fd 3, through `head` to the port,
  # and its stderr through another `head` into a file; the pipeline ends
  # once that `head` did, so the errors are all written by then. The status
  # is the command's.
  @apart ~S"""
  errors=$1 most=$2 taken=$3
  shift 3
  { { "$@" 2>&1 1>&3 3>&- | head -c "$most" >"$errors"; exit "${PIPESTATUS[0]}"; } 3>&1 |
    head -c "$taken"; exit "${PIPESTATUS[0]}"; }
  """

  @type result ::
          {:ok, output :: binary(), errors :: binary(), status :: non_neg_integer()}
          | {:error, :timeout | {:too_long, binary()}}

  @doc """
  Runs `command` with `args`, giving up after `seconds`, and returns what
  it printed on stdout, the first 64 KiB of what it printed on stderr, and
  its exit status. Options:

    * `:max` - the most bytes of output taken (required);
    * `:seconds` - the time limit (required);
    * `:env` - variables to set, as for `System.cmd/3`.
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: result()
  def cmd(command, args, opts) do
    max = Keyword.fetch!(opts, :max)
    seconds = Keyword.fetch!(opts, :seconds)

    env =
      for {name, value} <- Keyword.get(opts, :env, []),
          do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}

    Scratch.with_dir("mwt-cmd", fn dir ->
      errors = Path.join(dir, "errors")

      port =
        Port.open({:spawn_executable, MWTClient.Executable.find("timeout")}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          env: env,
          args:
            ["--kill-after=#{@kill_after}", "#{seconds}", "bash", "-c", @apart, "mwt-bounded"] ++
              [errors, "#{@error_bytes}", "#{max + 1}", command | args]
        ])

      case collect(port, max, [], 0) do
        {:ok, _output, 124} -> {:error, :timeout}
        {:ok, output, status} -> {:ok, output, read_errors(errors), status}
        too_long -> too_long
      end
    end)
  end

  @doc """
  What a command that failed said: its output and its errors, the start of
  them when they are long (`brief/2`).
  """
  @spec failure(binary(), binary(), pos_integer()) :: binary()
  def failure(output, errors, limit) do
    [output, errors]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> brief(limit)
  end

  # `head` wrote at most `@error_bytes`; nothing at all when stderr stayed
  # quiet.
  defp read_errors(path) do
    case File.read(path) do
      {:ok, errors} -> errors
      {:error, _reason} -> ""
    end
  end

  @doc """
  The start of a long text, at most `limit` bytes of it and an ellipsis:
  enough of an error to tell what went wrong, short enough for a notice.
  A character cut in two shows as `�`.

      iex> MWTClient.Sandbox.Bounded.brief("short", 10)
      "short"

      iex> MWTClient.Sandbox.Bounded.brief("a longer error", 8)
      "a longer …"
  """
  @spec brief(binary(), pos_integer()) :: binary()
  def brief(text, limit) when byte_size(text) <= limit, do: text

  def brief(text, limit),
    do: String.replace_invalid(binary_part(text, 0, limit), "�") <> " …"

  defp collect(port, max, acc, size) do
    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > max do
          head = IO.iodata_to_binary([acc | data])
          stop(port)
          {:error, {:too_long, binary_part(head, 0, max)}}
        else
          collect(port, max, [acc | data], size)
        end

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}
    end
  end

  # Kills the command's process group, then waits for it to end, dropping
  # what it printed meanwhile, so no message of it stays behind.
  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        MWTClient.Executable.cmd("kill", ["-KILL", "--", "-#{pid}", "#{pid}"],
          stderr_to_stdout: true
        )

      nil ->
        :ok
    end

    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, {:data, _data}} -> drain(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      (@kill_after + 1) * 1_000 ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        :ok
    end
  end
end
