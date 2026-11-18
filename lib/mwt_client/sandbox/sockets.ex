defmodule MWTClient.Sandbox.Sockets do
  @moduledoc """
  The folder of Unix sockets between MWT and one identity's VM. The VM's
  bubble has no network, so these are every way in and out of it
  (`/mwt/sockets` in there):

    * `proxy.sock` - the egress proxy (`MWTClient.Sandbox.Egress`);
    * `dns.sock` - the DNS forwarder (`MWTClient.Sandbox.Dns`);
    * `channel.sock` - the agent channel (`MWTClient.Sandbox.Channel`),
      joined to the VM's vsock;
    * `control.sock`, `relay.lock`, `start.out` - the relay's own
      (`MWTClient.Sandbox.Bubble`).

  Everything in it is the VM's bubble's to change: a VM that broke out of
  its process could. So what MWT trusts is kept beside it, in a folder of
  its own no bubble mounts (`host_dir/1`): the bubble's process id and log,
  and the SSH control socket of the port forwarding, through which anyone
  could add listeners on this machine.

  It sits in `$XDG_RUNTIME_DIR/mwt/<id>` (`mdt` in an install MDT made),
  readable by you only: Unix socket
  paths are short (108 bytes), too short for the identity's own folder, and
  the runtime directory is gone after a logout, like the VM. Tests set
  `:channel_dir`.
  """

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.Server

  @doc "The identity's folder of sockets."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Path.join(base(), String.slice(Accounts.id(username), 0, 12))

  @doc "One file in it."
  @spec path(String.t(), String.t()) :: Path.t()
  def path(username, name), do: Path.join(dir(username), name)

  @doc "MWT's own folder beside the VM's, which no bubble mounts."
  @spec host_dir(String.t()) :: Path.t()
  def host_dir(username), do: dir(username) <> "-host"

  @doc "One file in `host_dir/1`."
  @spec host_path(String.t(), String.t()) :: Path.t()
  def host_path(username, name), do: Path.join(host_dir(username), name)

  @doc "Creates `host_dir/1`, for you only, and returns it."
  @spec ensure_host!(String.t()) :: Path.t()
  def ensure_host!(username) do
    dir = host_dir(username)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc "Creates the folder, for you only, and returns it."
  @spec ensure!(String.t()) :: Path.t()
  def ensure!(username) do
    dir = dir(username)
    File.mkdir_p!(dir)
    File.chmod!(Path.dirname(dir), 0o700)
    File.chmod!(dir, 0o700)
    dir
  end

  # `mdt` in an install MDT made: msb's home is in here, and its VMs'
  # records name the path it had (MWTClient.FormerName).
  defp base do
    config = Application.get_env(:mwt_client, Server, [])
    name = MWTClient.FormerName.name()

    Keyword.get_lazy(config, :channel_dir, fn ->
      case System.get_env("XDG_RUNTIME_DIR") do
        runtime when is_binary(runtime) and runtime != "" -> Path.join(runtime, name)
        _ -> Path.join(System.tmp_dir!(), "#{name}-#{System.get_env("USER", "user")}")
      end
    end)
  end
end
