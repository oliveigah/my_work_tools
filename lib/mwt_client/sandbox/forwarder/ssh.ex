defmodule MWTClient.Sandbox.Forwarder.SSH do
  @moduledoc """
  The tunnel `MWTClient.Sandbox.Forwarder` uses with a real VM: OpenSSH as
  a control master, through the identity's launcher (`MWTClient.Sandbox.Msb`,
  `write_launcher/1`) running `msb ssh serve VM --stdio`, the way Zed's SSH
  entry reaches the VM.

  msb's SSH server carries forwarded connections (`direct-tcpip`) over its
  own channel to the VM's agent, which connects inside the VM, so servers on
  the VM's loopback can be reached. Forwards are added and removed on the
  master (`ssh -O forward|cancel`). Nothing else runs over it: msb's SSH
  server keeps an agent connection for every command until the session
  ends, and forwarded connections don't count toward that.

    * The key is MWT's own, made on first use (`ssh-keygen`, no passphrase)
      in the identity's sandbox folder, and added with `msb ssh authorize`
      on each open; msb ignores a key it already has.
    * No `~/.ssh/config` (`-F /dev/null`), no prompts (`BatchMode`), no
      known hosts: the transport is msb's process, not a network.
    * Opening returns once the master answers on its control socket, which
      it makes a moment after it starts: forwards asked before that fail,
      and the forwarder would wait out its retry (30 seconds) before asking
      again. A master that doesn't answer within 10 seconds, or ends, is a
      failed open, which the forwarder tries again in 5.
    * The master runs under a wrapper that ends it when its stdin closes, so
      it never outlives MWT.
    * The launcher refuses `ssh` while the VM isn't running, so opening
      fails then, and the forwarder tries again.
  """

  @behaviour MWTClient.Sandbox.Forwarder

  alias MWTClient.Sandbox.Msb.Commands

  # `$@` is ssh. Background jobs get /dev/null as stdin, so the watcher
  # reads MWT's end through fd 3. It writes nowhere: holding the port's
  # output open would keep MWT from hearing that ssh ended. The wrapper ends
  # when ssh does.
  @wrapper ~S"""
  exec 3<&0
  "$@" &
  ssh=$!
  { cat <&3; kill "$ssh"; } >/dev/null 2>&1 &
  wait "$ssh"
  """

  @control_timeout 10
  @ready_within 10_000

  @impl true
  def open(%{launcher: launcher, vm: vm, key: key, control: control}) do
    with {:ok, ssh} <- find("ssh"),
         :ok <- launcher?(launcher),
         :ok <- ensure_key(key),
         :ok <- authorize(launcher, key <> ".pub") do
      _ = File.rm(control)

      port =
        Port.open({:spawn_executable, MWTClient.Executable.find("bash") || "/bin/bash"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", @wrapper, "mwt-forward", ssh | master_args(vm, launcher, key, control)]
        ])

      conn = %{port: port, ssh: ssh, control: control, host: host(vm), vm: vm}

      case await_master(conn, System.monotonic_time(:millisecond) + @ready_within) do
        :ok ->
          {:ok, conn}

        {:error, message} ->
          close(conn)
          {:error, message}
      end
    end
  end

  # Until the master answers `-O check`, or ends, or the time is up.
  defp await_master(%{port: port} = conn, deadline) do
    case control(conn, ["-O", "check", conn.host]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        receive do
          {^port, {:exit_status, code}} -> {:error, "ssh to the VM ended (exit #{code})"}
        after
          50 ->
            if System.monotonic_time(:millisecond) < deadline,
              do: await_master(conn, deadline),
              else:
                {:error, "The connection to the VM didn't come up: " <> last_line(output, status)}
        end
    end
  end

  @doc false
  def master_args(vm, launcher, key, control) do
    ["-M", "-N", "-n", "-S", control, "-F", "/dev/null", "-i", key] ++
      options([
        "IdentitiesOnly=yes",
        "BatchMode=yes",
        "StrictHostKeyChecking=no",
        "UserKnownHostsFile=/dev/null",
        "LogLevel=ERROR",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=3",
        "ExitOnForwardFailure=no",
        "ProxyCommand=" <> Enum.map_join([launcher | Commands.ssh_serve(vm)], " ", &shell_quote/1)
      ]) ++ [host(vm)]
  end

  @impl true
  def forward(conn, address, port, target) do
    case control(conn, ["-O", "forward", "-L", spec(address, port, target), conn.host]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, last_line(output, status)}
    end
  end

  @impl true
  def cancel(conn, address, port, target) do
    control(conn, ["-O", "cancel", "-L", spec(address, port, target), conn.host])
    :ok
  end

  @impl true
  def close(conn) do
    control(conn, ["-O", "exit", conn.host])
    Port.close(conn.port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The `-L` spec: listen on `address:port` here, connect to `target:port` in
  the VM.

      iex> MWTClient.Sandbox.Forwarder.SSH.spec("127.77.1.2", 4000, "::1")
      "127.77.1.2:4000:[::1]:4000"
  """
  def spec(address, port, target), do: "#{address}:#{port}:#{bracket(target)}:#{port}"

  defp bracket(target), do: if(String.contains?(target, ":"), do: "[#{target}]", else: target)

  defp control(conn, args) do
    MWTClient.Executable.cmd(
      "timeout",
      ["#{@control_timeout}", conn.ssh, "-S", conn.control, "-F", "/dev/null"] ++
        options(["BatchMode=yes", "LogLevel=ERROR"]) ++ args,
      stderr_to_stdout: true
    )
  end

  defp options(options), do: Enum.flat_map(options, &["-o", &1])

  defp host(vm), do: "root@" <> vm

  defp last_line(output, status) do
    case output |> String.trim() |> String.split("\n") |> List.last() do
      line when line in [nil, ""] -> "ssh exited #{status}"
      line -> line
    end
  end

  defp find(name) do
    case MWTClient.Executable.find(name) do
      nil -> {:error, "#{name} isn't installed on this machine"}
      path -> {:ok, path}
    end
  end

  defp launcher?(launcher) do
    if File.regular?(launcher), do: :ok, else: {:error, "MWT's launcher for the VM is missing"}
  end

  defp ensure_key(key) do
    if File.exists?(key) and File.exists?(key <> ".pub") do
      :ok
    else
      _ = File.rm(key)
      _ = File.rm(key <> ".pub")
      File.mkdir_p!(Path.dirname(key))

      case MWTClient.Executable.cmd(
             "ssh-keygen",
             ["-q", "-t", "ed25519", "-N", "", "-C", "MWT port forwarding", "-f", key],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, "Couldn't make MWT's SSH key: " <> String.trim(output)}
      end
    end
  end

  defp authorize(launcher, public_key) do
    # The launcher runs msb confined: the key is the one file of this
    # machine it is let read.
    case System.cmd(launcher, Commands.ssh_authorize_file(public_key),
           env: [{"MWT_MSB_READ", public_key}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, "msb ssh authorize failed: " <> String.trim(output)}
    end
  end

  # For the shell ssh runs ProxyCommand with.
  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"
end
