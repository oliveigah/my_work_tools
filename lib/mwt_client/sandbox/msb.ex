defmodule MWTClient.Sandbox.Msb do
  @moduledoc """
  The `msb` command line, which is how MWT drives microsandbox: there is no
  Elixir SDK. Every call runs under `timeout`, so a stuck `msb` cannot stall
  the sandbox process.

  MWT ships its own runtime, built by `scripts/build-microsandbox.sh` into
  `priv/microsandbox`: `msb` from the pinned commit of an upstream release
  (superradcompany/microsandbox), that release's libkrunfw, which `msb`
  finds beside its `bin/`, and MWT's relay. Whatever `msb` is on the PATH
  is never used.

  Each identity has its own microsandbox home, in its sandbox folder, not
  `~/.microsandbox`: an `msb` you install yourself, at any version, neither
  sees MWT's VMs nor migrates their database, and one identity's VM never
  sees another's.

  The VM's own process never runs from here: it is started and stopped in a
  bubble (`MWTClient.Sandbox.Bubble`). What runs on the host is `msb` for
  images, for the VM's record, and for going into a running VM.
  """

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.{Bounded, Bubble, Channel, Disks, MemoryControl, Seccomp, Sockets}

  # What `run/3` takes from a command: VM commands print a few KiB.
  @max_output 4 * 1024 * 1024
  @error_limit 4 * 1024

  @doc "The folder holding MWT's runtime: `bin/msb` and `lib/libkrunfw.so.*`."
  @spec runtime_dir() :: Path.t()
  def runtime_dir do
    Keyword.get_lazy(config(), :runtime_dir, fn ->
      Application.app_dir(:mwt_client, "priv/microsandbox")
    end)
  end

  @doc "MWT's `msb`, or nil when this build has no runtime."
  @spec executable() :: String.t() | nil
  def executable do
    path = Path.join(runtime_dir(), "bin/msb")
    if File.regular?(path), do: path
  end

  @doc """
  Where one identity's microsandbox home is kept: its VM, images and SSH
  keys. Each identity has its own, in its sandbox folder, so the bubble of
  one never holds another's VM.
  """
  @spec store(String.t()) :: Path.t()
  def store(username), do: Path.join([Accounts.dir(username), "sandbox", "microsandbox"])

  @doc """
  The path `msb` is given as its home (`MSB_HOME`): a link to `store/1`,
  beside the identity's sockets. microsandbox keeps Unix sockets of its own
  under its home, and a socket's path must fit in 108 bytes, which the
  identity's folder is too deep for. What it records of its images it
  records by their real path, so the link can move.
  """
  @spec home(String.t()) :: Path.t()
  def home(username), do: Sockets.path(username, "msb")

  @doc "Makes the home and the link to it, and returns the link."
  @spec ensure_home!(String.t()) :: Path.t()
  def ensure_home!(username) do
    store = store(username)
    home = home(username)
    File.mkdir_p!(store)

    # msb takes no store that another account could swap a folder of: no
    # folder above it may be writable by a group or by everyone. A login
    # umask of 002, Ubuntu's, makes every new folder exactly that. MWT's
    # folders are nobody else's to read either.
    for dir <- mwt_folders(store), do: File.chmod!(dir, 0o700)
    Sockets.ensure!(username)

    if File.read_link(home) != {:ok, store} do
      File.rm_rf!(home)
      File.ln_s!(store, home)
    end

    home
  end

  # A path and the folders above it, up to MWT's own data folder.
  defp mwt_folders(path) do
    root = Accounts.root()

    if String.starts_with?(path, root <> "/"),
      do: path |> Stream.iterate(&Path.dirname/1) |> Enum.take_while(&(&1 != Path.dirname(root))),
      else: [path]
  end

  @doc """
  The command `ssh` runs to reach `host`, read from the text of an SSH
  config: the first `ProxyCommand` in a `Host` block that names `host`, as
  ssh itself takes the first value it finds. Nil when there is none.
  `Include` and `Match` are not followed.

      iex> config = "Host other\\n  ProxyCommand nc a 22\\nHost mwt-sandbox\\n  User root\\n  ProxyCommand /x/msb ssh serve vm --stdio\\n"
      iex> MWTClient.Sandbox.Msb.proxy_command(config, "mwt-sandbox")
      "/x/msb ssh serve vm --stdio"

      iex> MWTClient.Sandbox.Msb.proxy_command("Host *\\n  ProxyCommand=/y/msb ssh\\n", "mwt-sandbox")
      nil
  """
  @spec proxy_command(String.t(), String.t()) :: String.t() | nil
  def proxy_command(text, host) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce_while(false, fn line, in_block? ->
      case Regex.run(~r/\A\s*([A-Za-z]+)\s*(?:=|\s)\s*(.*?)\s*\z/, line) do
        [_, keyword, value] ->
          case String.downcase(keyword) do
            "host" -> {:cont, host in String.split(value)}
            "match" -> {:cont, false}
            "proxycommand" when in_block? -> {:halt, {:found, value}}
            _other -> {:cont, in_block?}
          end

        nil ->
          {:cont, in_block?}
      end
    end)
    |> case do
      {:found, command} -> command
      _none -> nil
    end
  end

  @doc """
  How your SSH config (`~/.ssh/config`) reaches `host`: `:ok` through this
  identity's launcher, `{:other, command}` through something else, or
  `:missing`. Something else is how Zed ends up in a VM MWT no longer runs:
  a launcher of an older MWT, say, which runs another microsandbox home.
  Tests point `config :mwt_client, MWTClient.Sandbox.Msb, ssh_config:`
  elsewhere.
  """
  @spec ssh_entry(String.t(), String.t()) :: :ok | :missing | {:other, String.t()}
  def ssh_entry(username, host) do
    path = Keyword.get_lazy(config(), :ssh_config, fn -> Path.expand("~/.ssh/config") end)

    with {:ok, text} <- File.read(path),
         command when is_binary(command) <- proxy_command(text, host) do
      program = command |> String.split() |> List.first("") |> Path.expand()
      if program == launcher(username), do: :ok, else: {:other, command}
    else
      _none -> :missing
    end
  end

  @doc "Where `write_launcher/1` puts an identity's launcher."
  @spec launcher(String.t()) :: Path.t()
  def launcher(username), do: Path.join(bin(username), "msb")

  @doc """
  Where `write_launcher/1` puts MWT's confined msb: every `msb` MWT runs on
  this machine runs through it, and so does the launcher, after its checks.
  """
  @spec confined(String.t()) :: Path.t()
  def confined(username), do: Path.join(bin(username), "msb-confined")

  @doc """
  Where `write_launcher/1` puts the seccomp filter (`MWTClient.Sandbox.Seccomp`)
  that the VM's bubble and the confined msb load. Beside the launcher, not in
  the runtime folder: after a reboot, Zed reaches the VM through the launcher
  before MWT has written anything there.
  """
  @spec seccomp_file(String.t()) :: Path.t()
  def seccomp_file(username), do: Path.join(bin(username), "seccomp.bpf")

  defp bin(username), do: Path.join([Accounts.dir(username), "sandbox", "bin"])

  @doc """
  Writes what runs msb on this machine for an identity, all in its sandbox
  folder, which no bubble mounts; MWT rewrites them on start, and their paths
  stay put when an MWT update moves the runtime:

    * the launcher (`launcher/1`), for Zed's SSH config and for you. It only
      looks at the VM and goes into it. msb boots a stopped VM by itself on
      `exec` and `ssh`, so those are refused while the VM isn't running (the
      relay holds `relay.lock` while it is), and what starts, stops or
      changes the VM is refused always: MWT does that. Then it runs the
      confined msb;
    * the confined msb (`confined/1`), which runs msb in a bubble of its
      own. It has the VM's microsandbox store (whose records a VM that broke
      out of its own bubble could have rewritten) and MWT's runtime, and
      nothing else of this machine: no KVM, so no VM starts here whatever
      the records say; no network, unless MWT asks for it to pull an image
      (`MWT_MSB_NETWORK=1`); no home folder of yours; the seccomp filter. One
      more path it may read is named by `MWT_MSB_READ` (an image's archive, a
      key to authorize);
    * the seccomp filter (`seccomp_file/1`).
  """
  @spec write_launcher(String.t()) :: :ok | {:error, term()}
  def write_launcher(username) do
    case executable() do
      nil ->
        {:error, :no_runtime}

      msb ->
        with :ok <- write(seccomp_file(username), Seccomp.program() || "", 0o644),
             :ok <- write(confined(username), confined_script(username, msb), 0o755) do
          write(launcher(username), launcher_script(username), 0o755)
        end
    end
  end

  defp launcher_script(username) do
    """
    #!/bin/sh
    # Written by MWT on start: MWT's own msb, for this identity's VM.
    lock=#{shell_quote(Sockets.path(username, "relay.lock"))}
    case "${1:-}" in
      ls|list|status|ps|inspect|metrics|logs|df|ping|jobs|help|--help|-h|--version|-V)
        ;;
      exec|ssh|cp|copy|attach|signal|kill|eof|touch)
        if [ ! -e "$lock" ] || flock --nonblock "$lock" true 2>/dev/null; then
          echo "MWT's VM isn't running. Start it in MWT." >&2
          exit 1
        fi
        ;;
      *)
        echo "MWT starts, stops and changes its VM itself: msb ${1:-} isn't available here." >&2
        exit 1
        ;;
    esac
    exec #{shell_quote(confined(username))} "$@"
    """
  end

  defp confined_script(username, msb) do
    filter? = Seccomp.program() != nil
    links = Enum.map_join(Bubble.usr_links(), " ", &shell_quote/1)

    """
    #!/bin/sh
    # Written by MWT on start: every msb MWT runs on this machine, in a bubble
    # of its own, with this identity's VM's store and MWT's runtime and
    # nothing else of this machine (MWTClient.Sandbox.Msb.write_launcher/1).
    store=#{shell_quote(store(username))}
    home=#{shell_quote(home(username))}
    runtime=#{shell_quote(runtime_dir())}
    msb=#{shell_quote(msb)}
    filter=#{shell_quote(seccomp_file(username))}
    mkdir -p "$store" || exit 1
    if [ -n "${MWT_MSB_READ:-}" ]; then
      set -- --ro-bind "$MWT_MSB_READ" "$MWT_MSB_READ" -- "$msb" "$@"
    else
      set -- -- "$msb" "$@"
    fi
    net=--unshare-net
    if [ "${MWT_MSB_NETWORK:-}" != 1 ]; then
      # msb makes an HTTP client as it starts, even for what needs no
      # network (a load), and aborts when it finds no CA certificate: only
      # the system's bundle, public, read-only, where TLS libraries look.
      for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        target=$(readlink -f "$bundle" 2>/dev/null) || continue
        if [ -f "$target" ]; then
          set -- --ro-bind "$target" /etc/ssl/certs/ca-certificates.crt "$@"
          break
        fi
      done
    fi
    if [ "${MWT_MSB_NETWORK:-}" = 1 ]; then
      # A pull: the network, /etc, and where its links for names and
      # certificates lead (systemd-resolved's stub is in /run).
      net=
      for linked in /etc/resolv.conf /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        target=$(readlink -f "$linked" 2>/dev/null) || continue
        case "$target" in
          ""|/etc/*|/usr/*) ;;
          *) set -- --ro-bind-try "$target" "$target" "$@" ;;
        esac
      done
      set -- --ro-bind /etc /etc "$@"
    fi
    exec #{shell_quote(Bubble.bwrap() || "bwrap")} \
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup $net \
      --die-with-parent#{if filter?, do: " --seccomp 3", else: ""} \
      --ro-bind /usr /usr #{links} \
      --proc /proc --dev /dev --tmpfs /tmp \
      --ro-bind "$runtime" "$runtime" \
      --bind "$store" "$store" --bind "$store" "$home" \
      --chdir / --clearenv --setenv PATH /usr/bin:/usr/sbin \
      --setenv HOME "$home" --setenv MSB_HOME "$home" --setenv MSB_PATH "$msb" \
      --setenv MSB_BACKEND local --setenv NO_COLOR 1 \
      "$@"#{if filter?, do: ~s( 3< "$filter"), else: ""}
    """
  end

  defp write(path, content, mode) do
    if File.read(path) == {:ok, content} do
      :ok
    else
      temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temporary, content),
           :ok <- File.chmod(temporary, mode) do
        File.rename(temporary, path)
      end
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  defp config, do: Application.get_env(:mwt_client, __MODULE__, [])

  @doc """
  Runs `msb` with `args` on the host, in an identity's home, giving up after
  `seconds`. For what needs no VM process: images, the VM's record, and
  going into a VM that runs (`exec`). Starting and stopping go through
  `MWTClient.Sandbox.Bubble`.

  What a command in the VM prints is the VM's to decide, so at most
  `max_output/0` bytes of it are taken (`MWTClient.Sandbox.Bounded`); more
  is an error, and the command is stopped. The output is stdout alone: a
  warning on stderr, such as git's, is no part of what callers parse. An
  error says both, cut to its first `error_limit/0` bytes.
  """
  @spec run(String.t(), [String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(username, args, seconds \\ 60) do
    ensure_home!(username)

    with :ok <- written(write_launcher(username)) do
      # Only a pull needs the network; nothing else is read from here.
      env = [
        {"MWT_MSB_NETWORK", if(hd(args) == "pull", do: "1", else: false)},
        {"MWT_MSB_READ", false}
      ]

      case Bounded.cmd(confined(username), args, max: @max_output, seconds: seconds, env: env) do
        {:ok, output, _errors, 0} ->
          {:ok, output}

        {:ok, output, errors, _status} ->
          {:error, Bounded.failure(output, errors, @error_limit)}

        {:error, :timeout} ->
          {:error, "msb #{hd(args)} took longer than #{seconds} s"}

        {:error, {:too_long, _head}} ->
          {:error,
           "msb #{hd(args)} printed more than #{div(@max_output, 1024 * 1024)} MiB, so MWT stopped it"}
      end
    end
  end

  defp written(:ok), do: :ok
  defp written({:error, :no_runtime}), do: {:error, "MWT's msb is missing"}

  defp written({:error, reason}),
    do: {:error, "MWT couldn't write its msb scripts: #{inspect(reason)}"}

  @doc "The most output `run/3` takes from one command, in bytes."
  @spec max_output() :: pos_integer()
  def max_output, do: @max_output

  @doc "The most of an error's text `run/3` keeps, in bytes."
  @spec error_limit() :: pos_integer()
  def error_limit, do: @error_limit

  @doc """
  The environment every `msb` call gets. `MSB_PATH` names the binary that
  VMs are spawned with, so a stray one in MWT's own environment can't pair
  MWT's `msb` with another. `MWT_MSB` is the confined msb (`confined/1`),
  which a script runs to reach the VM's store from this machine.
  """
  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(username) do
    path = if msb = executable(), do: [{"MSB_PATH", msb}], else: []

    [
      {"MSB_BACKEND", "local"},
      {"NO_COLOR", "1"},
      {"MSB_HOME", home(username)},
      {"MWT_MSB", confined(username)} | path
    ]
  end

  @doc """
  Whether the identity's VM exists in microsandbox's records: `:exists` or
  `:missing`. Whether it runs is the relay's to say
  (`MWTClient.Sandbox.Bubble.status/1`): msb records the VM's process id as
  the bubble sees it, which means nothing out here.
  """
  @spec status(String.t(), String.t()) :: :exists | :missing | {:error, String.t()}
  def status(username, name) do
    case run(username, ["inspect", name, "--format", "json"], 20) do
      {:ok, _record} ->
        :exists

      {:error, message} ->
        if message =~ ~r/not found|no such|does not exist/i, do: :missing, else: {:error, message}
    end
  end

  @doc "Whether an image tag is in the identity's microsandbox cache."
  @spec image?(String.t(), String.t() | nil) :: boolean()
  def image?(_username, nil), do: false
  def image?(username, tag), do: match?({:ok, _}, run(username, ["image", "inspect", tag], 20))

  @doc """
  The arguments of `msb create` for a VM with these parts, to run in the
  bubble: every disk and folder is named by its path there
  (`MWTClient.Sandbox.Bubble.inside/1`), and the proxy and DNS by the
  relay's loopback ports.
  """
  @spec create_args(map()) :: [String.t()]
  def create_args(
        %{
          name: name,
          image: image,
          cpus: cpus,
          memory_gib: memory,
          disk_gib: disk,
          shell: shell
        } = vm
      ) do
    disks =
      Enum.flat_map(Disks.names(), fn disk ->
        ["--mount-disk", "#{Bubble.inside(:disks)}/#{disk}.img:#{Disks.mount_point(disk)}"]
      end)

    # No folder of this machine is mounted: shared folders and /mnt/mwt are
    # copied in while the VM runs (MWTClient.Sandbox.FolderSync), and the
    # VM's memory is a disk of its own.
    env = Enum.flat_map(vm.env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)

    # The CPU's virtualization, for VMs inside the VM: only when asked for
    # (MWTClient.Sandbox.NestedVirt). microsandbox refuses it at start when
    # this machine's KVM doesn't offer it.
    nested = if Map.get(vm, :nested_virt, false), do: ["--nested-virt"], else: []

    # Ports that exist only in the bubble, where the relay joins them to MWT.
    # The agent channel: the VM's vsock port, joined to MWT's socket.
    ["create", image, "--name", name, "--replace", "--pull", "never"] ++
      ["--shell", shell] ++
      [
        "--cpus",
        "#{cpus}",
        "--memory",
        "#{MemoryControl.minimum(memory)}G",
        "--max-memory",
        "#{memory}G",
        "--root-disk",
        "#{disk}G"
      ] ++
      nested ++
      ["--proxy", "http://127.0.0.1:3128", "--dns-nameserver", "127.0.0.1:5353"] ++
      ["--net", "public,private"] ++
      ["--vsock", "#{Bubble.inside(:sockets)}/channel.sock:#{Channel.port()}"] ++
      disks ++ env
  end
end
