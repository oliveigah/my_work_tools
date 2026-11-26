defmodule MWTClient.Sandbox.Msb.Commands do
  @moduledoc """
  Every `msb` command line MWT runs, after the program's name: what MWT
  asks of microsandbox, in one place. Each caller builds its command here,
  so the contract test (`mix test --only msb`, in
  `test/mwt_client/sandbox/msb_contract_test.exs`) checks the flags of
  exactly these against the `msb` in `priv/microsandbox`, and a
  microsandbox update that drops or renames one fails there, in seconds,
  before any VM boots.

  The relay runs two of them itself, in Rust (`native/mwt_relay`):
  `stop/1` and `resize_memory/2`. They are written here as the relay
  writes them, for the contract test; change both together.

  What MWT counts on beyond flags (that `exec` and `ssh` boot a stopped VM,
  the words of a refusal, the VM's process being `msb machine`) is in
  `MWTClient.Sandbox.Msb` and the `vm` tests.
  """

  alias MWTClient.Sandbox.{Bubble, Channel, Disks, MemoryControl}

  @doc """
  Creates the VM with these parts, to run in the bubble: every disk and
  folder is named by its path there (`MWTClient.Sandbox.Bubble.inside/1`),
  and the proxy and DNS by the relay's loopback ports.
  """
  @spec create(map()) :: [String.t()]
  def create(
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

  @doc "Starts the VM `name` as it was created, in the bubble."
  @spec start(String.t()) :: [String.t()]
  def start(name), do: ["start", name]

  @doc "Stops the VM `name`: the relay's, on `stop` or SIGTERM."
  @spec stop(String.t()) :: [String.t()]
  def stop(name), do: ["stop", name]

  @doc """
  Changes the running VM's memory to `mib` MiB, live: the relay's, on its
  control socket's `memory MIB`.
  """
  @spec resize_memory(String.t(), pos_integer()) :: [String.t()]
  def resize_memory(name, mib), do: ["modify", name, "--memory", "#{mib}M", "--format", "json"]

  @doc "Sets the memory the VM boots with and its ceiling, for its next start."
  @spec boot_memory(String.t(), pos_integer(), pos_integer()) :: [String.t()]
  def boot_memory(name, minimum_gib, maximum_gib) do
    ["modify", name, "--next-start", "--memory", "#{minimum_gib}G"] ++
      ["--max-memory", "#{maximum_gib}G"]
  end

  @doc "Drops environment variables from the VM's record, for its next start."
  @spec remove_env(String.t(), [String.t()]) :: [String.t()]
  def remove_env(name, keys),
    do: ["modify", name, "--next-start" | Enum.flat_map(keys, &["--env-rm", &1])]

  @doc """
  Runs `words` in the running VM. msb holds the output until the command
  ends; `exec_stream/2` passes it on as it comes, for a pipe.
  """
  @spec exec(String.t(), [String.t()]) :: [String.t()]
  def exec(name, words), do: ["exec", name, "--" | words]

  @doc "Runs `words` in the running VM, its input and output a pipe."
  @spec exec_stream(String.t(), [String.t()]) :: [String.t()]
  def exec_stream(name, words), do: ["exec", "--stream", name, "--" | words]

  @doc "The VM's record, as JSON."
  @spec inspect_vm(String.t()) :: [String.t()]
  def inspect_vm(name), do: ["inspect", name, "--format", "json"]

  @doc "An image in microsandbox's cache, by its tag."
  @spec inspect_image(String.t()) :: [String.t()]
  def inspect_image(ref), do: ["image", "inspect", ref]

  @doc "Removes images from microsandbox's cache, by their tags."
  @spec remove_images([String.t()]) :: [String.t()]
  def remove_images(refs), do: ["image", "remove" | refs]

  @doc "Loads a podman archive into microsandbox's cache, tagged `ref`."
  @spec load(Path.t(), String.t()) :: [String.t()]
  def load(archive, ref), do: ["load", "--input", archive, "--tag", ref]

  @doc """
  The VM's SSH server on stdin and stdout, for an SSH `ProxyCommand`
  (Zed's, and port forwarding's).
  """
  @spec ssh_serve(String.t()) :: [String.t()]
  def ssh_serve(name), do: ["ssh", "serve", name, "--stdio", "--no-inactivity-timeout"]

  @doc "Lets the public key in `path` into the VM's SSH server."
  @spec ssh_authorize_file(Path.t()) :: [String.t()]
  def ssh_authorize_file(path), do: ["ssh", "authorize", "--file", path]

  @doc "Lets the public key on stdin into the VM's SSH server, for you to run."
  @spec ssh_authorize_stdin() :: [String.t()]
  def ssh_authorize_stdin, do: ["ssh", "authorize", "--stdin"]
end
