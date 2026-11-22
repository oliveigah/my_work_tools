defmodule MWTClient.Sandbox.GitTransport do
  @moduledoc """
  Git's read transport from the VM to one registered host project.

  The VM names a project ID, a remote and the fixed upload-pack service,
  never a host path or command. Git serves a temporary bare view holding
  only refs MWT chose, borrowing its objects:

    * `origin` (`mwt::<id>`): your repository's branches and tags;
    * `upstream` (`mwt::<id>/upstream`): your repository's own remote
      branches (its `refs/remotes/origin/*`) as branches. With the grant
      Git: fetch from your remotes on, this machine fetches that remote
      first, at most once a minute, into MWT's store
      (`MWTClient.Sandbox.HandoffStore`), never into your repository,
      with your credentials and never prompting; else they are as you
      last fetched them.

  No host config, internal refs, index or working tree is exposed or
  changed. Each transfer needs the grant Git: fetch from your
  repositories (`MWTClient.Sandbox.MwtTools`).

  After one status line the channel carries Git's binary protocol. Both
  directions use sockets with active-once reads: a slow peer applies OS
  backpressure instead of filling the process mailbox with a pack file.
  The command also has CPU, memory and time limits and is stopped as a
  process group when either peer leaves. Four transfers may run per
  identity; a stream rechecks isolation and project access every second.
  """

  alias MWTClient.Sandbox.{
    Gate,
    Guest,
    HandoffStore,
    HostGit,
    MwtTools,
    Project,
    Projects,
    Scratch,
    Server
  }

  @max_sessions 4
  @max_input 8 * 1024 * 1024
  @max_output 2 * 1024 * 1024 * 1024
  @max_refs 2 * 1024 * 1024
  @seconds 600

  # Only fixed code and separate arguments reach the shell. The Git
  # protocol goes over fd 3; port stdout carries no pack data.
  @upload """
  exec 3<>/dev/tcp/127.0.0.1/"$1" || exit 1
  printf '%s\\n' "$2" >&3
  ulimit -t 120
  ulimit -v 1048576
  ulimit -f 262144
  exec timeout --kill-after=5 #{@seconds} git \\
    -c core.hooksPath=/dev/null -c pack.threads=1 \\
    -c pack.windowMemory=64m -c pack.deltaCacheSize=32m \\
    -c uploadpack.allowAnySHA1InWant=false \\
    -c uploadpack.allowReachableSHA1InWant=false \\
    -c uploadpack.allowTipSHA1InWant=false \\
    -c uploadpack.allowRefInWant=false \\
    upload-pack --strict "$3" <&3 >&3 2>/dev/null
  """

  @doc "Serves one Git handshake on an agent channel connection."
  def serve(client, username, ask) do
    with :ok <- request(ask),
         {:ok, project} <- project(username, ask["project"]),
         :ok <- allowed(username, project, remote(ask)),
         {:ok, lock} <- acquire(username) do
      try do
        Scratch.with_dir("mwt-git-read", fn dir ->
          with :ok <- prepare(dir, project, remote(ask), username),
               {:ok, _project} <- project(username, ask["project"]) do
            transfer(client, username, ask, dir)
          else
            {:error, message} -> refuse(client, message)
          end
        end)
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, message} -> refuse(client, message)
    end
  rescue
    _error -> refuse(client, "The project's Git transport could not be opened.")
  catch
    :exit, _reason -> refuse(client, "MWT is not available; it may be locked or closed.")
  after
    :gen_tcp.close(client)
  end

  defp request(%{"project" => id, "service" => "git-upload-pack"} = ask)
       when is_binary(id) do
    cond do
      not Regex.match?(~r/\A[0-9a-f]{64}\z/, id) ->
        {:error, "The remote needs a registered project ID."}

      Map.get(ask, "protocol", "") not in ["", "version=1", "version=2"] ->
        {:error, "Unsupported Git protocol."}

      Map.get(ask, "remote", "origin") not in ["origin", "upstream"] ->
        {:error, "The remote is origin (mwt::ID) or upstream (mwt::ID/upstream)."}

      Map.keys(ask) -- ["command", "project", "service", "protocol", "remote"] != [] ->
        {:error, "Git requests take a project ID and service, not paths or options."}

      true ->
        :ok
    end
  end

  defp request(_ask), do: {:error, "Pushes go through review; use mwt handoff."}

  defp project(username, id) do
    if Gate.isolated?(username) do
      {:error, "The VM is isolated or MWT is locked; Git access is stopped."}
    else
      %{projects: projects, shares: shares} = Server.call(username, :projects, 1_000)

      with %Project{closed: false} = project <- Enum.find(projects, &(Project.id(&1) == id)),
           %{} <- Projects.share_of(project.path, shares) do
        {:ok, project}
      else
        _ -> {:error, "That project is closed, unshared, or no longer available."}
      end
    end
  catch
    :exit, _reason -> {:error, "MWT is not available; it may be locked or closed."}
  end

  defp remote(ask), do: Map.get(ask, "remote", "origin")

  # The grant Git: fetch from your repositories decides each transfer.
  defp allowed(username, project, remote) do
    MwtTools.authorize(username, %{
      grant: :git_fetch,
      tool: "git fetch #{remote}",
      title: "#{project.name} (#{remote})",
      args: %{"project" => project.name, "remote" => remote}
    })
  end

  defp acquire(username) do
    lock =
      Enum.find_value(1..@max_sessions, fn slot ->
        lock = {{__MODULE__, username, slot}, self()}
        if :global.set_lock(lock, [node()], 0), do: lock
      end)

    if lock, do: {:ok, lock}, else: {:error, "Four Git transfers are already running; try later."}
  end

  defp prepare(dir, project, remote, username) do
    with {:ok, _} <- HostGit.run(dir, ["init", "--quiet", "--bare", "."], seconds: 10),
         common when is_binary(common) <-
           HostGit.line(project.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, refs, objects} <- refs(project, remote, username, Path.join(common, "objects")),
         :ok <-
           File.write(
             Path.join(dir, "objects/info/alternates"),
             Enum.map_join(objects, &(&1 <> "\n"))
           ),
         {:ok, _} <-
           HostGit.run(dir, ["update-ref", "--stdin"],
             input: ref_updates(refs),
             max: @max_refs,
             seconds: 10
           ),
         {:ok, _} <- HostGit.run(dir, ["symbolic-ref", "HEAD", head(project, refs)], seconds: 10) do
      :ok
    else
      _ -> {:error, "The project's branches and tags could not be read."}
    end
  end

  # Your repository's branches and tags, for origin.
  defp refs(project, "origin", _username, objects) do
    case HostGit.run(
           project.path,
           ["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/", "refs/tags/"],
           max: @max_refs,
           seconds: 10
         ) do
      {:ok, refs} -> {:ok, refs, [objects]}
      error -> error
    end
  end

  # Its remote's branches, as branches, for upstream: fetched by this
  # machine into MWT's store first when the grant allows, else as your
  # repository last fetched them.
  defp refs(project, "upstream", username, objects) do
    %{dir: dir} = Server.call(username, :projects, 1_000)
    store = HandoffStore.path(dir, project.path)

    {repo, prefix, objects} =
      with :ok <- HandoffStore.ensure(store, project.path),
           :ok <- fetch_remote?(username, project),
           :ok <- fetch_remote(store, project.path) do
        {store, "refs/upstream/", [objects, Path.join(store, "objects")]}
      else
        _ -> {project.path, "refs/remotes/origin/", [objects]}
      end

    case HostGit.run(repo, ["for-each-ref", "--format=%(objectname) %(refname)", prefix],
           max: @max_refs,
           seconds: 10
         ) do
      {:ok, refs} ->
        branches =
          for line <- String.split(refs, "\n", trim: true),
              [oid, ^prefix <> branch] <- [String.split(line, " ", parts: 2)],
              branch != "HEAD",
              into: "",
              do: "#{oid} refs/heads/#{branch}\n"

        {:ok, branches, objects}

      error ->
        error
    end
  end

  defp fetch_remote?(username, project) do
    MwtTools.authorize(username, %{
      grant: :git_fetch_remote,
      tool: "git fetch (your machine)",
      title: project.name,
      args: %{"project" => project.name}
    })
  end

  @remote_every_seconds 60

  @doc """
  Fetches the remote `origin` of your repository `repo` into the store, as
  `refs/upstream/*`: on this machine, with your credentials, never
  prompting, at most once a minute (a fetch since is used as it is).
  """
  @spec fetch_remote(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def fetch_remote(store, repo) do
    stamp = Path.join(store, "mwt-upstream-fetched")

    fresh? =
      case File.stat(stamp, time: :posix) do
        {:ok, %{mtime: at}} -> System.os_time(:second) - at < @remote_every_seconds
        _ -> false
      end

    with false <- fresh? and :fresh,
         url when is_binary(url) <-
           HostGit.line(repo, ["config", "--get", "remote.origin.url"]) ||
             {:error, "Your repository has no remote origin."},
         {_, 0} <-
           MWTClient.Executable.cmd(
             "timeout",
             [
               "--kill-after=5",
               "60",
               "git",
               "-C",
               store,
               "-c",
               "protocol.ext.allow=never",
               "-c",
               "fetch.fsckObjects=true",
               "-c",
               "core.hooksPath=/dev/null",
               "fetch",
               "--quiet",
               "--no-tags",
               "--prune",
               "--no-recurse-submodules",
               url,
               "+refs/heads/*:refs/upstream/*"
             ],
             env: [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_ASKPASS", "true"}, {"SSH_ASKPASS", "true"}],
             stderr_to_stdout: true
           ) do
      File.touch(stamp)
    else
      :fresh ->
        :ok

      {:error, _} = error ->
        error

      {output, _status} ->
        {:error, "Fetching your remote failed: " <> String.slice(output, 0, 300)}
    end
  end

  defp ref_updates(refs) do
    for line <- String.split(refs, "\n", trim: true),
        [oid, ref] = String.split(line, " ", parts: 2),
        into: "",
        do: "create #{ref} #{oid}\n"
  end

  defp head(project, refs) do
    branches =
      for line <- String.split(refs, "\n", trim: true),
          [_oid, "refs/heads/" <> branch] <- [String.split(line, " ", parts: 2)],
          do: branch

    current = HostGit.branch(project.path)

    branch =
      if current in branches,
        do: current,
        else: Project.default_branch(branches, project.mirrored_branch)

    "refs/heads/" <> (branch || "main")
  end

  defp transfer(client, username, ask, dir) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :line,
        packet_size: 128,
        backlog: 1
      ])

    {:ok, {_address, number}} = :inet.sockname(listener)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    port = upload(number, token, dir, Map.get(ask, "protocol", ""))

    try do
      with {:ok, host} <- :gen_tcp.accept(listener, 5_000) do
        try do
          with {:ok, line} <- :gen_tcp.recv(host, 0, 5_000),
               true <- line == token <> "\n" do
            :ok =
              :inet.setopts(client,
                packet: :raw,
                active: :once,
                send_timeout: 2_000,
                exit_on_close: false
              )

            :ok = :inet.setopts(host, packet: :raw, active: :once, send_timeout: 2_000)
            :ok = :gen_tcp.send(client, "0\n")
            now = System.monotonic_time(:millisecond)

            relay(client, host, port, username, ask["project"], %{
              input: 0,
              output: 0,
              check_at: now + 1_000,
              deadline: now + @seconds * 1_000
            })
          else
            _ -> refuse(client, "The project's Git transport could not be started.")
          end
        after
          :gen_tcp.close(host)
        end
      else
        _ -> refuse(client, "The project's Git transport could not be started.")
      end
    after
      :gen_tcp.close(listener)
      stop(port)
    end
  end

  defp upload(number, token, dir, protocol) do
    env = [{"GIT_PROTOCOL", protocol} | Guest.git_env()]

    Port.open({:spawn_executable, MWTClient.Executable.find("bash")}, [
      :binary,
      :exit_status,
      :use_stdio,
      env:
        Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end),
      args: ["-c", @upload, "mwt-git-read", Integer.to_string(number), token, dir]
    ])
  end

  defp relay(client, host, port, username, id, totals) do
    now = System.monotonic_time(:millisecond)

    allowed =
      cond do
        now >= totals.deadline -> false
        now >= totals.check_at -> match?({:ok, _}, project(username, id))
        true -> true
      end

    if allowed do
      totals = if now >= totals.check_at, do: %{totals | check_at: now + 1_000}, else: totals
      receive_data(client, host, port, username, id, totals)
    end
  end

  defp receive_data(client, host, port, username, id, totals) do
    receive do
      {:tcp, ^client, bytes} ->
        input = totals.input + byte_size(bytes)

        if input <= @max_input and :gen_tcp.send(host, bytes) == :ok do
          :ok = :inet.setopts(client, active: :once)
          relay(client, host, port, username, id, %{totals | input: input})
        end

      {:tcp, ^host, bytes} ->
        output = totals.output + byte_size(bytes)

        if output <= @max_output and :gen_tcp.send(client, bytes) == :ok do
          :ok = :inet.setopts(host, active: :once)
          relay(client, host, port, username, id, %{totals | output: output})
        end

      {:tcp_closed, socket} when socket == client or socket == host ->
        :ok

      {:tcp_error, socket, _reason} when socket == client or socket == host ->
        :ok

      {^port, {:exit_status, _status}} ->
        # The socket can still hold the last pack bytes or a Git ERR
        # packet when its writer exits; drain it through to EOF.
        relay(client, host, port, username, id, totals)
    after
      1_000 -> relay(client, host, port, username, id, totals)
    end
  end

  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        MWTClient.Executable.cmd("kill", ["-KILL", "--", "-#{pid}", "#{pid}"],
          stderr_to_stdout: true
        )

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

      nil ->
        :ok
    end
  end

  defp refuse(client, message) do
    # Once the status line has gone, errors must end the Git stream, not
    # insert a second control reply into a pack file.
    case :inet.getopts(client, [:packet]) do
      {:ok, [packet: :raw]} -> :ok
      _ -> :gen_tcp.send(client, ["1\nmwt: ", message, "\n"])
    end
  end
end
