defmodule MWTClient.Sandbox.Bubble do
  @moduledoc """
  The bubble one identity's VM runs in: `bwrap` (bubblewrap) around
  microsandbox, so the process running the VM has

    * namespaces of its own: user, mount, network, PID, IPC, UTS, cgroup;
    * a seccomp filter refusing the calls a VMM never makes, and any new
      user namespace (`MWTClient.Sandbox.Seccomp`);
    * `/usr` read-only and no `/home`, `/etc` or `/run` of yours;
    * no network but loopback, with a default route that leads nowhere.

  Its first process is MWT's relay (`native/mwt_relay`, built to
  `bin/mwt-relay` beside `msb`). The relay joins msb's proxy and DNS ports
  to MWT's sockets, runs the `msb create` or `msb start` it is given,
  answers `control.sock`, and is process 1 in there, so the VM runs exactly
  as long as it does.

  Everything the VM is made of is bound under `/mwt` (`inside/1`), a path
  that exists only in the bubble:

      /mwt/runtime    msb, its guest kernel, the relay       read-only
      /mwt/sockets    MWTClient.Sandbox.Sockets
      /mwt/disks      MWTClient.Sandbox.Disks

  No folder of this machine is there: shared folders and MWT's own files
  for the VM (`MWTClient.Sandbox.Inbox`) are copied into it
  (`MWTClient.Sandbox.FolderSync`), and its memory is one of its disks. A
  VM made before 2026-11-16 mounted MWT's files and its memory from
  folders: until it is recreated, its bubble has them too (`legacy`), at
  `/mwt/inbox`, read-only, and `/mwt/optmem`.

  So the VM names its disks and folders by paths the host doesn't have, and
  an `msb` outside the bubble cannot boot it (msb boots a stopped VM by
  itself on `exec` and `ssh`). Only msb's own home keeps its paths, the
  real one and the short link to it (`MWTClient.Sandbox.Msb.home/1`), so
  `msb exec` from the host finds the running VM's sockets.

  The bubble is started detached: nothing ties it to MWT, so an MWT that
  crashes leaves the VM running, without internet until MWT listens again.
  It is found again through `control.sock`.

  Which `bwrap` makes it is `bwrap/0`: MWT's own copy where its package
  installed one, the system's elsewhere. Ubuntu (24.04 and later) lets a
  program hold capabilities in a user namespace only under an AppArmor
  profile that allows it, and its profile for `/usr/bin/bwrap` doesn't, so
  the deb installs a copy of the system's bwrap at `/usr/lib/mwt/bwrap` with
  a profile for what the bubble needs (`scripts/deb/postinst.sh`).
  """

  alias MWTClient.Sandbox.{Msb, Seccomp, Sockets}

  @own_bwrap "/usr/lib/mwt/bwrap"

  @type spec :: %{
          required(:username) => String.t(),
          required(:name) => String.t(),
          required(:disks) => Path.t(),
          optional(:legacy) => %{inbox: Path.t(), optmem: Path.t()} | nil,
          optional(:memory_gib) => pos_integer(),
          optional(:memory_min_gib) => pos_integer()
        }

  @doc "The path in the bubble of one of the VM's parts: under `/mwt`."
  @spec inside(:runtime | :sockets | :disks | :inbox | :optmem) :: String.t()
  def inside(part) when part in [:runtime, :sockets, :disks, :inbox, :optmem],
    do: "/mwt/#{part}"

  @doc """
  The `bwrap` the bubble is made with, or nil when there is none: MWT's own
  copy when its package installed one, else the system's.
  """
  @spec bwrap() :: String.t() | nil
  def bwrap do
    own = Keyword.get(Application.get_env(:mwt_client, __MODULE__, []), :own_bwrap, @own_bwrap)
    if File.regular?(own), do: own, else: MWTClient.Executable.find("bwrap")
  end

  @doc "MWT's relay, or nil when this build has no runtime."
  @spec relay() :: String.t() | nil
  def relay do
    path = Path.join(Msb.runtime_dir(), "bin/mwt-relay")
    if File.regular?(path), do: path
  end

  @doc """
  Whether a bubble can be made here, by making one: the namespaces and the
  two capabilities the real one asks for, with MWT's relay inside doing its
  first two steps (`mwt-relay --check`): the route into loopback, then no
  capability left. A system that refuses says so here, before a VM is
  offered, and the message says what to do about it. Without a relay in
  this build, only the namespaces are tried.
  """
  @spec available() :: :ok | {:error, String.t()}
  def available do
    case bwrap() do
      nil ->
        {:error, "bwrap isn't installed (package bubblewrap)."}

      bwrap ->
        args =
          ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup) ++
            ~w(--as-pid-1 --uid 0 --gid 0 --cap-add CAP_NET_ADMIN --cap-add CAP_SETPCAP) ++
            ["--ro-bind", "/usr", "/usr"] ++
            usr_links() ++
            ~w(--proc /proc --dev /dev) ++
            if(relay(),
              do:
                ["--ro-bind", Msb.runtime_dir(), inside(:runtime)] ++
                  ["--", inside(:runtime) <> "/bin/mwt-relay", "--check"],
              else: ["--", "/usr/bin/true"]
            )

        case System.cmd(bwrap, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _status} -> {:error, refusal(output |> String.trim() |> String.slice(0, 300))}
        end
    end
  end

  # Ubuntu's AppArmor is the one known cause: bwrap may make the namespaces
  # there and still hold no capability in them.
  defp refusal(output) do
    if File.exists?("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") do
      "A bubble can't be made here (#{output}). On Ubuntu, AppArmor lets a program hold " <>
        "capabilities in a user namespace only with a profile for it. MWT's package installs " <>
        "one; for an MWT run from source: sudo sh scripts/deb/postinst.sh"
    else
      "A bubble can't be made here: #{output}"
    end
  end

  @doc """
  The whole `bwrap` command line that runs `msb` with `msb_words` in the
  bubble of `spec`.
  """
  @spec words(spec(), [String.t()]) :: [String.t()]
  def words(spec, msb_words) do
    home = Msb.home(spec.username)
    store = Msb.store(spec.username)

    env =
      Enum.flat_map(
        [
          {"PATH", "/usr/bin:/usr/sbin"},
          {"HOME", home},
          {"MSB_HOME", home},
          {"MSB_PATH", inside(:runtime) <> "/bin/msb"},
          {"MSB_BACKEND", "local"},
          {"NO_COLOR", "1"}
        ],
        fn {name, value} -> ["--setenv", name, value] end
      )

    # The relay is process 1: when it ends, the kernel ends the rest.
    # Root in the bubble only, with the two capabilities the relay uses
    # once (the route) and then gives up for good.
    # msb's home at its real path, which its records name, and at the short
    # one, which its sockets are under.
    # The seccomp filter, which the launcher of `start/3` hands bwrap on
    # descriptor 3.
    [bwrap() || "bwrap"] ++
      ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup) ++
      seccomp_words() ++
      ["--as-pid-1"] ++
      ~w(--uid 0 --gid 0 --cap-add CAP_NET_ADMIN --cap-add CAP_SETPCAP) ++
      ["--ro-bind", "/usr", "/usr"] ++
      usr_links() ++
      ~w(--proc /proc --dev /dev --dev-bind /dev/kvm /dev/kvm --tmpfs /tmp --tmpfs /run) ++
      ["--ro-bind", Msb.runtime_dir(), inside(:runtime)] ++
      ["--bind", Sockets.dir(spec.username), inside(:sockets)] ++
      ["--bind", spec.disks, inside(:disks)] ++
      legacy(spec[:legacy]) ++
      ["--bind", store, store, "--bind", store, home] ++
      ~w(--chdir / --clearenv) ++
      env ++
      ["--", inside(:runtime) <> "/bin/mwt-relay", "--sockets", inside(:sockets)] ++
      ["--name", spec.name] ++
      memory_words(spec) ++
      ["--", inside(:runtime) <> "/bin/msb"] ++ msb_words
  end

  defp seccomp_words, do: if(Seccomp.program(), do: ["--seccomp", "3"], else: [])

  # The folders a VM made before 2026-11-16 mounts.
  defp legacy(nil), do: []

  defp legacy(%{inbox: inbox, optmem: optmem}),
    do: ["--ro-bind", inbox, inside(:inbox), "--bind", optmem, inside(:optmem)]

  defp memory_words(%{memory_gib: maximum} = spec) do
    minimum = Map.get(spec, :memory_min_gib, MWTClient.Sandbox.MemoryControl.minimum(maximum))
    ["--memory-min-mib", "#{minimum * 1024}", "--memory-max-mib", "#{maximum * 1024}"]
  end

  defp memory_words(_spec), do: []

  @doc false
  # /bin, /lib and the like are links into /usr on the systems MWT supports.
  def usr_links do
    Enum.flat_map(~w(bin sbin lib lib64), fn name ->
      if File.exists?("/usr/#{name}"), do: ["--symlink", "usr/#{name}", "/#{name}"], else: []
    end)
  end

  @doc """
  Starts the bubble and waits, up to `seconds`, for the `msb` command in it
  to end. `{:ok, output}` when it went well; the bubble then stays, with the
  VM running in it.
  """
  @spec start(spec(), [String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def start(spec, msb_words, seconds \\ 300) do
    username = spec.username
    Msb.ensure_home!(username)

    cond do
      is_nil(relay()) ->
        {:error, "MWT's relay is missing"}

      status(username) != :down ->
        {:error, "The VM's bubble is already running."}

      true ->
        # A relay whose control socket is gone can't be asked to stop.
        kill_strays(spec.name)
        File.rm(Sockets.path(username, "start.out"))
        Sockets.ensure_host!(username)
        File.rm(Sockets.host_path(username, "bubble.pid"))

        # The seccomp filter, written beside the launcher, on descriptor 3.
        :ok = Msb.write_launcher(username)
        filter = Msb.seccomp_file(username)

        {_, 0} =
          MWTClient.Executable.cmd(
            "setsid",
            ["--fork", "sh", "-c", launcher(), "mwt-bubble" | words(spec, msb_words)],
            env: [
              {"MWT_PIDFILE", Sockets.host_path(username, "bubble.pid")},
              {"MWT_LOG", Sockets.host_path(username, "bubble.log")},
              {"MWT_SECCOMP", filter}
            ],
            stderr_to_stdout: true
          )

        await_start(username, System.monotonic_time(:millisecond) + seconds * 1_000)
    end
  end

  @doc """
  The shell that becomes the bubble, detached (a session of its own), with
  its output in a file and its process id written down, so a failure
  before the relay runs shows. Beside the id goes the time the process
  started (`/proc/PID/stat`'s 22nd field; its name, `sh`, holds no space),
  by which `MWTClient.Sandbox.Peer` knows it from a later process given
  the same id. `exec` keeps both.
  """
  @spec launcher() :: String.t()
  def launcher do
    ~s[echo "$$ $(cut -d' ' -f22 /proc/$$/stat)" > "$MWT_PIDFILE"; ] <>
      ~s(exec "$@" > "$MWT_LOG" 2>&1 < /dev/null 3< "$MWT_SECCOMP")
  end

  defp await_start(username, deadline) do
    case File.read(Sockets.path(username, "start.out")) do
      {:ok, text} ->
        case String.split(text, "\n", parts: 2) do
          ["0", output] -> {:ok, String.trim(output)}
          [_status, output] -> {:error, String.trim(output)}
          _ -> {:error, "The relay left no word on how the start went."}
        end

      {:error, _not_yet} ->
        cond do
          not bubble_alive?(username) ->
            {:error, "The bubble ended before the VM started: " <> log(username)}

          System.monotonic_time(:millisecond) > deadline ->
            {:error, "The VM took too long to start."}

          true ->
            Process.sleep(50)
            await_start(username, deadline)
        end
    end
  end

  defp bubble_alive?(username) do
    with {:ok, text} <- File.read(Sockets.host_path(username, "bubble.pid")),
         {pid, _} <- Integer.parse(text) do
      File.exists?("/proc/#{pid}")
    else
      # Not written yet.
      _ -> true
    end
  end

  defp log(username) do
    case File.read(Sockets.host_path(username, "bubble.log")) do
      {:ok, text} -> text |> String.trim() |> String.slice(-600, 600)
      {:error, _} -> ""
    end
  end

  @doc "Whether the identity's VM is up, as its relay says. `:down` when nothing answers."
  @spec status(String.t()) :: :running | :starting | :down
  def status(username) do
    case ask(username, "status", 2_000) do
      {:ok, "running" <> _} -> :running
      {:ok, "starting" <> _} -> :starting
      _stopped_or_nothing -> :down
    end
  end

  @doc "The relay's boot minimum, ceiling and last accepted memory target, in MiB."
  def memory(username) do
    with {:ok, text} <- ask(username, "memory", 2_000),
         ["memory", low, high, target] <- String.split(text),
         {low, ""} <- Integer.parse(low),
         {high, ""} <- Integer.parse(high),
         {target, ""} <- Integer.parse(target),
         true <- low > 0 and high >= low and target >= low and target <= high do
      {:ok, %{minimum_mib: low, maximum_mib: high, target_mib: target}}
    else
      _ -> {:error, "Restart the VM to enable memory sharing with this machine."}
    end
  end

  @doc "Request live virtio-mem resizing through msb inside its own namespace."
  def resize_memory(username, mib) when is_integer(mib) and mib > 0 do
    case ask(username, "memory #{mib}", 15_000) do
      {:ok, "ok\n" <> output} -> {:ok, output}
      {:ok, text} -> {:error, String.trim(text)}
      {:error, reason} -> {:error, "Changing the VM's RAM failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Stops the VM cleanly (`msb stop` in the bubble), which ends the bubble.
  Returns once nothing answers any more.
  """
  @spec stop(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def stop(username, seconds \\ 110) do
    case ask(username, "stop", seconds * 1_000) do
      {:ok, "stopped" <> output} ->
        await_down(username, System.monotonic_time(:millisecond) + 5_000)
        {:ok, String.trim(output)}

      {:ok, other} ->
        {:error, String.trim(other)}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        {:ok, ""}

      {:error, reason} ->
        {:error, "The VM's relay didn't answer: #{inspect(reason)}"}
    end
  end

  @doc """
  Stops the VM, as `stop/2` does, on MWT's way out, by `deadline`
  (monotonic milliseconds): also one whose bubble was only just launched
  by a start MWT ended halfway. Its relay listens on `control.sock` a
  moment after it starts, so while a process of the VM's bubble runs
  (`launched?/1`) and nothing listens, the stop is asked again. A relay
  asked stops the VM by itself once its `msb create` or `msb start`
  returns, whether MWT still waits or not. `{:error, text}` when no relay
  could be asked, or it didn't answer, by the deadline.
  """
  @spec stop_by(String.t(), String.t(), integer()) :: :ok | {:error, String.t()}
  def stop_by(username, name, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    case left > 0 && ask(username, "stop", left) do
      false ->
        if launched?(name),
          do: {:error, "The VM's bubble was still starting, and its relay never listened."},
          else: :ok

      {:ok, "stopped" <> _output} ->
        await_down(username, min(deadline, System.monotonic_time(:millisecond) + 5_000))
        :ok

      {:ok, other} ->
        {:error, String.trim(other)}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        if launched?(name) do
          Process.sleep(50)
          stop_by(username, name, deadline)
        else
          :ok
        end

      {:error, reason} ->
        {:error, "The VM's relay was asked to stop, and didn't answer: #{inspect(reason)}"}
    end
  end

  # Whether a process of the VM `name`'s bubble runs on this machine: the
  # launcher, bwrap or the relay itself, each of which has the relay's path
  # in the bubble and the VM's name among its words, from the moment
  # `start/3` runs it until the bubble ends.
  defp launched?(name) do
    relay = inside(:runtime) <> "/bin/mwt-relay"
    Enum.any?(processes(), fn {_pid, words} -> relay in words and named?(words, name) end)
  end

  defp named?(words, name),
    do: Enum.chunk_every(words, 2, 1, :discard) |> Enum.member?(["--name", name])

  # This machine's processes, with the words each was started with.
  defp processes do
    for entry <- File.ls!("/proc"),
        entry =~ ~r/^\d+$/,
        {:ok, raw} <- [MWTClient.Files.read("/proc/#{entry}/cmdline")],
        do: {entry, String.split(raw, <<0>>)}
  end

  # Down is when nothing answers and the relay's lock is free: the relay
  # holds it until its last moment, after its control socket is gone.
  defp await_down(username, deadline) do
    down? = status(username) == :down and lock_free?(username)

    if not down? and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      await_down(username, deadline)
    end
  end

  defp lock_free?(username) do
    lock = Sockets.path(username, "relay.lock")

    not File.exists?(lock) or
      match?(
        {_, 0},
        MWTClient.Executable.cmd("flock", ["--nonblock", lock, "true"], stderr_to_stdout: true)
      )
  end

  # One line to the relay, and everything it answers.
  defp ask(username, word, timeout) do
    path = Sockets.path(username, "control.sock")

    with {:ok, socket} <- :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 2_000) do
      answer =
        with :ok <- :gen_tcp.send(socket, word <> "\n") do
          read(socket, "", timeout)
        end

      :gen_tcp.close(socket)
      answer
    end
  end

  defp read(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> read(socket, acc <> data, timeout)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  # Ends relays of this VM that nothing can ask any more. Each is process 1
  # of its bubble, so its VM ends with it: a power cut for the VM.
  defp kill_strays(name) do
    for {entry, [program | rest]} <- processes(),
        String.ends_with?(program, "/mwt-relay"),
        named?(rest, name) do
      MWTClient.Executable.cmd("kill", ["-KILL", entry], stderr_to_stdout: true)
    end

    :ok
  end
end
