defmodule MWTClient.Sandbox.HostGit do
  @moduledoc """
  git on one of your repositories, as the sandbox runs it for a project.

  Two things set it apart from the Git tool's own runner. It talks to a
  repository in the VM, so every object that arrives is checked
  (`fetch.fsckObjects`) and nothing follows submodules. And it never changes
  what is yours without being asked.

  What git prints can be the VM's to choose (a diff, file names, a remote's
  refusal), and so can its size. `run/3` bounds each output stream by `:max`
  and fails past that, instead of taking gigabytes into MWT's memory, and
  `:file_limit` bounds what a fetch may write. What it reports as an error
  is text that shows all it holds (`MWTClient.Sandbox.Shown`); what it
  returns on success is git's stdout, for the caller to read. Warnings on
  stderr never become part of a count, object id or other result.
  """

  alias MWTClient.Sandbox.Shown

  @max_output 32 * 1024 * 1024

  @transport ~w(-c protocol.ext.allow=always -c fetch.fsckObjects=true -c transfer.fsckObjects=true -c fetch.recurseSubmodules=false)

  @doc """
  Runs git in `repo`. `{:ok, output}` when it exits 0.

  ## Options

    * `:input` - bytes supplied to git on stdin (empty by default)
    * `:env` - more environment variables
    * `:seconds` - how long it may take (120)
    * `:ok` - exit statuses that count as done ([0])
    * `:max` - how many bytes are read from each of stdout and stderr
      (32 MiB); more is an error
    * `:cut` - with `true`, more than `:max` is `{:cut, the_first_max_bytes}`
      instead of an error, for stdout that is only shown. Stderr is never cut
    * `:file_limit` - the largest file git may write, in MiB; a fetch that
      brings more fails
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:cut, binary()} | {:error, String.t()}
  def run(repo, args, opts \\ []) do
    seconds = Keyword.get(opts, :seconds, 120)
    max = Keyword.get(opts, :max, @max_output)
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Keyword.get(opts, :env, [])]

    limit =
      case Keyword.get(opts, :file_limit) do
        nil -> ""
        mib -> "ulimit -f #{mib * 1024}; "
      end

    scratch =
      Path.join(System.tmp_dir!(), "mwt-git-#{Base.url_encode64(:crypto.strong_rand_bytes(12))}")

    File.mkdir!(scratch)
    File.chmod!(scratch, 0o700)
    errors = Path.join(scratch, "stderr")
    input = Path.join(scratch, "stdin")
    MWTClient.Files.write!(input, Keyword.get(opts, :input, ""))

    # Each pipe reads one byte past its limit, telling "more" from
    # "exactly that much". FD 3 carries stdout to the outer pipe while
    # stderr goes through the inner one. Both finish before we read the
    # diagnostics, and pipefail preserves git's exit status.
    script = """
    set -o pipefail
    errors=$1
    input=$2
    shift 2
    #{limit}{ git "$@" < "$input" 2>&1 1>&3 3>&- | head -c #{max + 1} > "$errors"; } 3>&1 | head -c #{max + 1}
    """

    words =
      ["--kill-after=5", "#{seconds}", "bash", "-c", script, "git", errors, input, "-C", repo] ++
        @transport ++ args

    try do
      case MWTClient.Executable.cmd("timeout", words, env: env) do
        {_output, 124} ->
          {:error, "git #{hd(args)} took longer than #{seconds} s"}

        {output, status} ->
          result(output, MWTClient.Files.read!(errors), status, args, opts, max)
      end
    after
      # The two files it holds, then the folder: three calls where a
      # recursive removal makes seven, two of them raw.
      MWTClient.Files.rm(errors)
      MWTClient.Files.rm(input)
      File.rmdir(scratch)
    end
  end

  defp result(output, errors, status, args, opts, max) do
    cond do
      byte_size(errors) > max ->
        {:error, "git #{hd(args)} printed more than #{size(max)}"}

      byte_size(output) > max ->
        if Keyword.get(opts, :cut, false),
          do: {:cut, binary_part(output, 0, max)},
          else: {:error, "git #{hd(args)} printed more than #{size(max)}"}

      status in Keyword.get(opts, :ok, [0]) ->
        {:ok, output}

      true ->
        {:error, (output <> errors) |> String.trim() |> Shown.text()}
    end
  end

  defp size(bytes) when bytes >= 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MiB"
  defp size(bytes), do: "#{div(bytes, 1024)} KiB"

  @doc "The one line a git command prints, or nil when it fails or prints nothing."
  @spec line(Path.t(), [String.t()]) :: String.t() | nil
  def line(repo, args) do
    case run(repo, args) do
      {:ok, output} -> output |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      {:error, _} -> nil
    end
  end

  @doc "The top folder of the repository `path` is in, or nil when it is in none."
  @spec top(Path.t()) :: Path.t() | nil
  def top(path), do: if(File.dir?(path), do: line(path, ["rev-parse", "--show-toplevel"]))

  @doc "The branch checked out, or nil when HEAD is detached."
  @spec branch(Path.t()) :: String.t() | nil
  def branch(repo), do: line(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])

  @doc """
  Who you commit as in `repo`: its `user.name` and `user.email` as git
  reads them there, from your own configuration (global, or the
  repository's, or an `includeIf`). Nil unless both are set.
  """
  @spec identity(Path.t()) :: %{name: String.t(), email: String.t()} | nil
  def identity(repo) do
    with name when is_binary(name) <- line(repo, ["config", "user.name"]),
         email when is_binary(email) <- line(repo, ["config", "user.email"]) do
      %{name: name, email: email}
    end
  end
end
