defmodule MWTClient.Sandbox.Egress do
  @moduledoc """
  The proxy every byte the VM sends goes through.

  The VM is created with `--proxy http://127.0.0.1:3128`, a port that exists
  only in the VM's bubble, where the relay joins it to this proxy's Unix
  socket (`proxy.sock`, see `MWTClient.Sandbox.Sockets`). So microsandbox
  opens an HTTP CONNECT here for each TCP connection the VM makes; the VM
  cannot opt out the way it could ignore `HTTPS_PROXY`, and the bubble has
  no network of its own to go around it. When this is not listening, the VM
  has no internet. No other program reaches it through a port.

  One listener per unlocked identity. Each connection runs in its own
  process under `MWTClient.Sandbox.TaskSupervisor`; see
  `MWTClient.Sandbox.Egress.Connection`. A socket it cannot bind is reported
  to the sandbox and retried, rather than failing the unlock.

  It holds at most 512 connections at once (`:max_connections` in this
  module's config). One more is closed as soon as it is accepted: the VM
  sees a refusal, and the activity log says so once a minute. Each one
  costs a few processes and buffers, and its head must arrive in time
  (`Connection`), so the VM can't make MWT hold more than that.
  """

  use GenServer

  require Logger

  alias MWTClient.Sandbox.Egress.Connection
  alias MWTClient.Sandbox.Server
  alias MWTClient.Sandbox.Sockets
  alias MWTClient.Vault.Store

  @retry_after 5_000
  @max_connections 512
  @said_every 60_000

  @doc "Starts the proxy of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The Unix socket one identity's proxy listens on (`MWTClient.Sandbox.Sockets`)."
  @spec path(String.t()) :: Path.t()
  def path(username), do: Sockets.path(username, "proxy.sock")

  @doc "Asks the proxy to tell the sandbox again whether it is listening."
  def report_again(username) do
    case Store.whereis(__MODULE__, username) do
      nil -> :ok
      pid -> GenServer.cast(pid, :report)
    end
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    send(self(), :listen)
    {:ok, %{username: username, socket: nil, acceptor: nil}}
  end

  # A retry scheduled before a rebind succeeded finds the socket open: it
  # would only fail on its own port and report the proxy down.
  @impl true
  def handle_info(:listen, %{socket: socket} = state) when socket != nil,
    do: {:noreply, state}

  def handle_info(:listen, state) do
    Sockets.ensure!(state.username)
    path = path(state.username)
    # A socket file left by an MWT that crashed would refuse the bind.
    File.rm(path)

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, backlog: 512]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        username = state.username
        options = Application.get_env(:mwt_client, __MODULE__, [])
        acceptor = spawn_link(fn -> accept(socket, username, options) end)
        report(state.username, %{listening?: true, error: nil, path: path})
        {:noreply, %{state | socket: socket, acceptor: acceptor}}

      {:error, reason} ->
        report(state.username, %{
          listening?: false,
          error: "Could not listen on #{path}: #{:inet.format_error(reason)}",
          path: path
        })

        Process.send_after(self(), :listen, @retry_after)
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state) do
    {:noreply, state |> close() |> tap(fn _ -> send(self(), :listen) end)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast(:report, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast(:report, state) do
    report(state.username, %{listening?: true, error: nil, path: path(state.username)})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close(state)
    File.rm(path(state.username))
    :ok
  end

  defp close(state) do
    if state.acceptor, do: Process.unlink(state.acceptor) && Process.exit(state.acceptor, :kill)
    if state.socket, do: :gen_tcp.close(state.socket)
    %{state | socket: nil, acceptor: nil}
  end

  defp serve(client, username, options) do
    case Task.Supervisor.start_child(MWTClient.Sandbox.TaskSupervisor, fn ->
           receive do
             {:go, client} -> Connection.run(client, username, options)
           after
             5_000 -> :ok
           end
         end) do
      {:ok, pid} ->
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, {:go, client})

      {:error, reason} ->
        Logger.warning("sandbox proxy could not start a handler: #{inspect(reason)}",
          system: :sandbox
        )

        :gen_tcp.close(client)
    end
  end

  # The connections open now: each joins the registry as it starts, and
  # leaves it however it ends.
  defp held(username) do
    Registry.count_match(MWTClient.Sandbox.Connections, username, :_)
  rescue
    ArgumentError -> 0
  end

  # Said once a minute, however many are refused in it.
  defp too_many(username, limit, said_at) do
    now = System.monotonic_time(:millisecond)

    if said_at && now - said_at < @said_every do
      said_at
    else
      Server.cast(
        username,
        {:log,
         %{
           outcome: :blocked,
           summary: "Too many connections open at once (#{limit}): new ones refused"
         }}
      )

      now
    end
  end

  defp report(username, status) do
    Server.cast(username, {:proxy, status})
  end

  defp accept(socket, username, options, said_at \\ nil) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        limit =
          Application.get_env(:mwt_client, __MODULE__, [])
          |> Keyword.get(:max_connections, @max_connections)

        if held(username) >= limit do
          :gen_tcp.close(client)
          accept(socket, username, options, too_many(username, limit, said_at))
        else
          serve(client, username, options)
          accept(socket, username, options, said_at)
        end

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end
end
