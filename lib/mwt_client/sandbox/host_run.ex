defmodule MWTClient.Sandbox.HostRun do
  @moduledoc """
  Runs one command you approved on the host, as you, and reports how it
  went. `MWTClient.Sandbox.Server` calls `run/2` in a task once you approve a
  `MWTClient.Sandbox.Approval` of kind `:command`.

    * `bash -lc SCRIPT`, so your login profile sets up your usual tools, in
      the approved directory, with stdin from `/dev/null` and SIGPIPE back
      to its default, which the BEAM ignores;
    * only in the directory you approved: the path on the card is a real
      path, and the command starts there after `cd -P` and a check that it
      is still where it leads. A folder the VM can write may have been
      swapped for a link to another one since you looked; then nothing runs
      (exit 126);
    * under `timeout`: TERM at the limit, KILL 5 seconds later (exit 124,
      or 137 when it had to be killed). The program the port runs leads a
      process group of its own, whose id is the operating system pid
      `run/2` reports, so `stop/2` reaches every process the command
      started that stayed in it;
    * it ends when its shell does, at its limit, or when it is stopped,
      whatever it started: once the program is gone, what is left of its
      group is killed and the output closes (`collect/3`). A process that
      left the group (`setsid`, `ssh -f`) is out of reach: it goes on, and
      loses its output;
    * in MWT's environment without MWT's and the BEAM's own variables
      (`scrubbed?/1`), which a command such as `env` would otherwise print,
      nor `BASH_ENV`, and with the job's `env` added: the values of a
      subgrant's parameters, and the workspace;
    * stdout and stderr together; the first and last 32 KiB are kept, and
      what's between is cut and counted. Output is made valid UTF-8, so it
      can be shown and sent as text.

  Only tests set `config :mwt_client, MWTClient.Sandbox.HostRun, home: path`,
  the `HOME` commands see instead of yours (`home_env/0`), so the login
  profile of whoever runs them doesn't add its own output.
  """

  @keep 32 * 1024
  @kill_after 5

  # How a run sees its program gone: it looks this often, then gives the
  # output this long to end by itself (the shell's last words reaching MWT)
  # before what is left of the group is killed; after that kill, the output
  # may stay open this long before MWT stops reading it. And past the
  # limit and `timeout`'s own KILL, this long before MWT kills the group
  # itself, should `timeout` not have.
  @look_ms 200
  @drain_ms 500
  @close_ms 5_000
  @slack_ms 1_000

  # The BEAM ignores SIGPIPE and its children inherit that, so `seq | head`
  # would end with "write error: Broken pipe" instead of quietly, as in a
  # terminal. Bash can't undo an ignored signal; `env --default-signal`
  # (coreutils 8.31 and later) can, and is skipped where it's missing.
  # `env` and then `timeout` run in place of the outer shell, so the port's
  # pid is timeout's, which leads the command's process group: the port
  # starts each program in a session of its own.
  #
  # The command writes into a pipe of its own, which `cat` copies onto the
  # port's. A process that leaves the group (`setsid`, `ssh -f` does) keeps
  # that pipe open, and nothing in the group can reach it; the port's own
  # pipe is held by `cat` alone, which is in the group, so killing what is
  # left of the group always ends the output, and the port reports the
  # shell's status. `cat` ignores TERM, so what the command prints as it
  # stops still reaches MWT; KILL ends it with the rest. The cost: a process
  # more per run, and a process that left the group finds its output closed
  # once the run ends (its next write fails, and with SIGPIPE back to its
  # default, ends it). Anything more of such a process would take a cgroup.
  # The command comes after the folder: `bash -lc SCRIPT` as you, or a
  # confined one (`MWTClient.Sandbox.Confine`).
  @wrapper "cd -P -- \"$2\" 2>/dev/null && [ \"$(pwd -P)\" = \"$2\" ] || " <>
             "{ echo \"MWT: $2 is no longer the folder you approved, so nothing ran.\"; exit 126; }; " <>
             "t=$1; shift 2; d=; env --default-signal=PIPE true 2>/dev/null && d=--default-signal=PIPE; " <>
             ~s(exec env $d timeout --kill-after=#{@kill_after}s "$t" "$@" </dev/null ) <>
             ~s[> >(trap '' TERM; exec cat) 2>&1]

  # In a confined run, the token files of the grants it runs with are
  # written from variables named here, which are then unset, before the
  # script runs.
  @files ~S[for f in "$@"; do v=${f%%=*}; p=${f#*=}; (umask 077; printf %s "${!v}" >"$p"); unset "$v"; done; s=$MWT_CONFINED_SCRIPT; unset MWT_CONFINED_SCRIPT; exec bash -c "$s" mwt-command]

  @scrubbed_prefixes ~w(RELEASE_ ERL_ ELIXIR_ ELIXIRKIT_ MIX_ PHX_ MWT_ __MIX)
  @scrubbed ~w(SECRET_KEY_BASE PORT BINDIR ROOTDIR EMU PROGNAME DNS_CLUSTER_QUERY)

  @type job :: %{
          required(:script) => String.t(),
          required(:dir) => String.t(),
          required(:timeout) => pos_integer(),
          optional(:env) => [{String.t(), String.t()}],
          optional(:confine) => %{
            optional(:reads) => [Path.t()] | nil,
            optional(:path) => String.t() | nil,
            optional(:writes) => boolean(),
            optional(:values) => [{String.t(), String.t()}],
            optional(:files) => [{String.t(), Path.t()}]
          }
        }

  @type result :: %{
          required(:exit) => integer() | nil,
          required(:output) => String.t(),
          required(:bytes) => non_neg_integer(),
          required(:cut) => non_neg_integer(),
          required(:timed_out) => boolean(),
          required(:error) => String.t() | nil
        }

  @doc "How many bytes of output are kept from each end."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc """
  Runs `job` and waits for it to end. `started` is called with the
  command's process group id as soon as it runs.
  """
  @spec run(job(), (pos_integer() -> any())) :: result()
  def run(job, started) do
    job = resolved(job)

    with :ok <- confinable(job), do: start(job, started, command(job))
  end

  # A confined job's PATH, and the folders it may read, when it left them
  # to your login shell: what its PATH runs tools from under your home.
  defp resolved(%{confine: %{} = confine} = job) do
    path = confine[:path] || login_path()
    reads = confine[:reads] || MWTClient.Sandbox.Confine.reads_from_path(path, home())
    %{job | confine: Map.merge(confine, %{path: path, reads: reads})}
  end

  defp resolved(job), do: job

  # No silent fallback: a confined command where no bubble can be made
  # doesn't run.
  defp confinable(%{confine: %{}}) do
    case MWTClient.Sandbox.Confine.available() do
      :ok -> :ok
      {:error, why} -> failed("it runs confined, and " <> why)
    end
  end

  defp confinable(_job), do: :ok

  defp failed(message),
    do: %{exit: nil, output: "", bytes: 0, cut: 0, timed_out: false, error: message}

  # What runs: your script with your login profile, as you; or, confined,
  # with no profile, in the bubble, after the token files are written.
  defp command(%{confine: %{} = confine} = job) do
    spec = %{
      dir: job.dir,
      writes: Map.get(confine, :writes, false),
      home: home(),
      workspace: Map.get(job, :workspace),
      reads: confine.reads,
      resolver: MWTClient.Sandbox.Confine.resolver(),
      links: MWTClient.Sandbox.Confine.links(confine.reads)
    }

    files = for {variable, path} <- Map.get(confine, :files, []), do: "#{variable}=#{path}"

    MWTClient.Sandbox.Confine.words(spec) ++ ["bash", "-c", @files, "mwt-confined" | files]
  end

  defp command(%{script: script}), do: ["bash", "-lc", script]

  defp start(%{dir: dir, timeout: timeout} = job, started, command) do
    if not File.dir?(dir), do: raise("the directory #{dir} doesn't exist on this machine")
    started_at = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, MWTClient.Executable.find("bash") || "/bin/bash"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        cd: "/",
        env: env(job),
        args: ["-c", @wrapper, "mwt-host-command", "#{timeout}s", dir | command]
      ])

    program =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          program = %{pid: pid, since: since(pid)}
          started.(pid)
          program

        nil ->
          nil
      end

    watch = %{
      program: program,
      phase: :running,
      next: started_at + @look_ms,
      deadline: started_at + (timeout + @kill_after) * 1_000 + @slack_ms
    }

    result = collect(port, %{head: "", tail: "", bytes: 0}, watch)

    # `timeout` exits 124 when it is itself stopped too, so only a run that
    # lasted its whole limit timed out.
    elapsed = System.monotonic_time(:millisecond) - started_at
    %{result | timed_out: result.exit in [124, 137] and elapsed >= timeout * 1_000}
  rescue
    error -> failed(Exception.message(error))
  end

  @doc "Sends `signal` (`\"TERM\"` or `\"KILL\"`) to every process of a running command."
  @spec stop(pos_integer(), String.t()) :: :ok
  def stop(group, signal) when signal in ["TERM", "KILL"] do
    MWTClient.Executable.cmd("kill", ["-#{signal}", "--", "-#{group}"], stderr_to_stdout: true)
    :ok
  end

  @doc "Whether an environment variable is MWT's or the BEAM's own, and so kept from commands."
  @spec scrubbed?(String.t()) :: boolean()
  def scrubbed?(name),
    do: name in @scrubbed or Enum.any?(@scrubbed_prefixes, &String.starts_with?(name, &1))

  @doc """
  The `System.cmd/3` `env` for a login shell MWT starts on the host: nothing,
  so it sees your `HOME`, except in tests, which set a home of their own
  that keeps out the login profile of whoever runs them. Host commands,
  minted values and the tool probe all use it.
  """
  @spec home_env() :: [{String.t(), String.t()}]
  def home_env do
    case Application.get_env(:mwt_client, __MODULE__, [])[:home] do
      nil -> []
      home -> [{"HOME", home}]
    end
  end

  # The values of a subgrant's parameters, which its script reads as
  # variables: the script's text stays as you saved it.
  defp given(values),
    do: for({name, value} <- values, do: {String.to_charlist(name), String.to_charlist(value)})

  # Confined, the command gets nothing of MWT's environment but what it
  # should have: the home, the PATH your login shell has, your user and
  # language, the parameters' values, and the grants' values (through the
  # environment, never the arguments, which every account here can read).
  defp env(%{confine: %{} = confine} = job) do
    keep = ~w(USER LOGNAME LANG LC_ALL TZ TERM)

    unset =
      for {name, _value} <- System.get_env(),
          name not in keep,
          do: {String.to_charlist(name), false}

    unset ++
      given(
        [{"HOME", home()}, {"PATH", confine.path}, {"MWT_CONFINED_SCRIPT", job.script}] ++
          workspace(job) ++ Map.get(job, :env, []) ++ Map.get(confine, :values, [])
      )
  end

  defp env(job), do: env() ++ given(workspace(job) ++ Map.get(job, :env, []))

  # The workspace, under the same name as in the VM, so a script writes
  # `"$MWT_WORKSPACE/to-vm/…"` on either side.
  defp workspace(%{workspace: root}) when is_binary(root),
    do: [{MWTClient.Sandbox.Workspace.variable(), root}]

  defp workspace(_job), do: []

  defp home do
    case home_env() do
      [{"HOME", home}] -> home
      [] -> System.user_home!()
    end
  end

  @doc """
  The `PATH` your login shell has, which a confined command runs with: it
  gets no login profile of its own.
  """
  @spec login_path() :: String.t()
  def login_path do
    case MWTClient.Executable.cmd("timeout", ["10", "bash", "-lc", ~S(printf %s "$PATH")],
           env: home_env(),
           stderr_to_stdout: false
         ) do
      {path, 0} when path != "" -> path
      _failed -> "/usr/local/bin:/usr/bin:/bin"
    end
  end

  # Bash runs the file `BASH_ENV` names before anything else, in the
  # wrapper as in your command: one in MWT's own environment would run
  # before the values given here took hold, and could replace them, as an
  # MWT VM's sets MWT_WORKSPACE. Your login profile still runs.
  defp env do
    scrubbed =
      for {name, _value} <- System.get_env(), scrubbed?(name) do
        {String.to_charlist(name), false}
      end

    for({name, value} <- home_env(), do: {String.to_charlist(name), String.to_charlist(value)}) ++
      [{~c"BASH_ENV", false} | scrubbed]
  end

  # The output until the port reports the program's status, which it does
  # only once nothing holds the output open any more. So the run also looks
  # after its program (`look/3`): gone, it is over, whatever it started.
  defp collect(port, acc, watch) do
    receive do
      {^port, {:data, data}} ->
        acc = add(acc, data)

        # Output that never pauses still lets the run look.
        if now() >= watch.next, do: look(port, acc, watch), else: collect(port, acc, watch)

      {^port, {:exit_status, status}} ->
        finished(acc, status)
    after
      max(watch.next - now(), 0) -> look(port, acc, watch)
    end
  end

  # Running: the program gone (the shell ended, the limit or a Stop ended
  # it), or still there past the limit and `timeout`'s KILL. Then the output
  # gets `@drain_ms` to end by itself, which it does unless something the
  # command started still holds it: what is left of the group is killed,
  # which ends it, since the relay is in the group. Only a process that
  # opened the relay's own output (`/proc/PID/fd/1`, as you can) could keep
  # it open after that: then MWT stops reading, and the run ends with its
  # status unknown (`exit: nil`) rather than never.
  defp look(port, acc, %{phase: :running} = watch) do
    cond do
      not alive?(watch.program) ->
        collect(port, acc, %{watch | phase: {:ended, now()}, next: now() + @look_ms})

      now() >= watch.deadline ->
        kill_group(watch.program)
        collect(port, acc, %{watch | phase: {:killed, now()}, next: now() + @look_ms})

      true ->
        collect(port, acc, %{watch | next: now() + @look_ms})
    end
  end

  defp look(port, acc, %{phase: {:ended, at}} = watch) do
    if now() - at >= @drain_ms do
      kill_group(watch.program)
      collect(port, acc, %{watch | phase: {:killed, now()}, next: now() + @look_ms})
    else
      collect(port, acc, %{watch | next: now() + @look_ms})
    end
  end

  defp look(port, acc, %{phase: {:killed, at}} = watch) do
    if now() - at >= @close_ms do
      close(port)
      finished(acc, nil)
    else
      collect(port, acc, %{watch | next: now() + @look_ms})
    end
  end

  defp finished(acc, status) do
    tail = last(acc.tail, @keep)
    cut = acc.bytes - byte_size(acc.head) - byte_size(tail)

    output =
      if cut > 0,
        do: text(acc.head) <> "\n[… #{cut} bytes cut …]\n" <> text(tail),
        else: text(acc.head <> tail)

    %{
      exit: status,
      output: output,
      bytes: acc.bytes,
      cut: cut,
      timed_out: false,
      error: nil
    }
  end

  # The port closed from this side: no status comes any more, and what it
  # had sent meanwhile goes unread.
  defp close(port) do
    Port.close(port)
    flush(port)
  rescue
    ArgumentError -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _late} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp kill_group(%{pid: pid}), do: stop(pid, "KILL")
  defp kill_group(nil), do: :ok

  # Whether the program is still the process the port started: by its start
  # time in `/proc`, since a pid is given again once it ends. `since` is
  # `:ended` when the program was gone before the run first looked, and nil
  # where `/proc` can't tell: then only the deadline ends a run that holds
  # its output open.
  defp alive?(%{pid: pid, since: since}) when is_integer(since) do
    case stat(pid) do
      {state, ^since} -> state != "Z"
      _ended -> false
    end
  end

  defp alive?(%{since: :ended}), do: false
  defp alive?(%{since: nil}), do: true
  defp alive?(nil), do: true

  defp since(pid) do
    case stat(pid) do
      {_state, since} -> since
      nil -> if stat("self"), do: :ended, else: nil
    end
  end

  # The state and start time in `/proc/PID/stat`, after the name in
  # parentheses, which may hold anything.
  defp stat(pid) do
    with {:ok, stat} <- MWTClient.Files.read("/proc/#{pid}/stat"),
         [_, state, rest] <- Regex.run(~r/\A.*\) (\S+) (.*)\z/s, stat),
         # From the parent's pid, field 4, to the start time, field 22.
         {since, ""} <- rest |> String.split(" ") |> Enum.at(18, "") |> Integer.parse() do
      {state, since}
    else
      _ -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The head fills up to `@keep`; the rest goes to the tail, trimmed to its
  # last `@keep` bytes whenever it holds twice that.
  defp add(acc, data) do
    room = @keep - byte_size(acc.head)
    {head, rest} = if room > 0, do: split(data, room), else: {"", data}
    tail = acc.tail <> rest
    tail = if byte_size(tail) > 2 * @keep, do: last(tail, @keep), else: tail
    %{acc | head: acc.head <> head, tail: tail, bytes: acc.bytes + byte_size(data)}
  end

  defp split(data, at) when byte_size(data) <= at, do: {data, ""}

  defp split(data, at),
    do: {binary_part(data, 0, at), binary_part(data, at, byte_size(data) - at)}

  defp last(data, size) when byte_size(data) <= size, do: data
  defp last(data, size), do: binary_part(data, byte_size(data) - size, size)

  defp text(data), do: String.replace_invalid(data, "�")
end
