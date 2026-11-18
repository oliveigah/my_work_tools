defmodule MWTClient.Sandbox.Forwarder do
  @moduledoc """
  Keeps a running VM's ports forwarded to its address on this machine
  (`MWTClient.Sandbox.Ports`). One per running VM, started and stopped by
  `MWTClient.Sandbox.Server` (`MWTClient.Sandbox.Server.Forwarding`), which
  it tells what is forwarded with `{:ports, pid, %{status: status, ports:
  entries}}`.

  It opens a tunnel to the VM (`MWTClient.Sandbox.Forwarder.SSH`; tests use
  their own, set as `config :mwt_client, MWTClient.Sandbox.Forwarder,
  tunnel: module`). What listens in the VM comes from the VM itself, which
  reports it when it changes (`listening/2`): each time, this forwards what
  is new and removes what stopped listening. A port that couldn't be
  forwarded is tried again after 30 seconds; when the tunnel closes, it is
  opened again every 5 seconds and the last report applied again.

  The status is `:connecting` while the tunnel opens, `:waiting` until the
  first report, `:on` after, and `{:error, message}` while the tunnel is
  down.
  """

  use GenServer

  alias MWTClient.Sandbox.Ports

  @doc "Opens the tunnel; its `:port` field is the port whose `{:exit_status, _}` says it closed."
  @callback open(opts :: map()) :: {:ok, conn :: map()} | {:error, String.t()}

  @doc "Starts listening on `address:port` here, connecting to `target:port` in the VM."
  @callback forward(conn :: map(), address :: String.t(), 1..65_535, target :: String.t()) ::
              :ok | {:error, String.t()}

  @doc "Stops a forward."
  @callback cancel(conn :: map(), address :: String.t(), 1..65_535, target :: String.t()) :: :ok

  @doc "Closes the tunnel and its forwards."
  @callback close(conn :: map()) :: :ok

  @defaults %{reconnect_every: 5_000, retry_after: 30_000}

  @doc """
  Starts forwarding. Options: `:report_to`, `:address`, `:tunnel` (the
  module), `:tunnel_opts` (given to its `open/1`), and for tests
  `:reconnect_every`, `:retry_after`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "What listens in the VM now, as `MWTClient.Sandbox.Ports.parse/1` read it from its report."
  @spec listening(pid(), [Ports.listener()]) :: :ok
  def listening(pid, listeners), do: GenServer.cast(pid, {:listening, listeners})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state =
      Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults))))
      |> Map.merge(%{
        report_to: Keyword.fetch!(opts, :report_to),
        address: Keyword.fetch!(opts, :address),
        tunnel: Keyword.fetch!(opts, :tunnel),
        tunnel_opts: Keyword.get(opts, :tunnel_opts, %{}),
        conn: nil,
        said: "",
        status: :connecting,
        # The last report, applied again when the tunnel comes back.
        listeners: nil,
        forwarded: %{},
        failed: %{},
        entries: [],
        reported: nil
      })

    send(self(), :connect)
    {:ok, _} = :timer.send_interval(state.retry_after, :retry)
    {:ok, report(state)}
  end

  @impl true
  def handle_cast({:listening, listeners}, state) do
    state = %{state | listeners: listeners}
    {:noreply, if(state.conn, do: state |> apply_listeners() |> report(), else: state)}
  end

  @impl true
  def handle_info(:connect, state) do
    case state.tunnel.open(state.tunnel_opts) do
      {:ok, conn} ->
        state = %{state | conn: conn, said: "", status: :waiting}
        {:noreply, state |> apply_listeners() |> report()}

      {:error, message} ->
        Process.send_after(self(), :connect, state.reconnect_every)
        {:noreply, report(%{state | status: {:error, message}})}
    end
  end

  # Ports that couldn't be forwarded get another try once their wait is over.
  def handle_info(:retry, %{conn: conn, failed: failed} = state)
      when not is_nil(conn) and failed != %{},
      do: {:noreply, state |> apply_listeners() |> report()}

  def handle_info(:retry, state), do: {:noreply, state}

  # What the tunnel prints, kept for when it closes.
  def handle_info({port, {:data, data}}, %{conn: %{port: port}} = state),
    do: {:noreply, %{state | said: String.slice(state.said <> data, -500, 500)}}

  def handle_info({port, {:exit_status, status}}, %{conn: %{port: port}} = state) do
    said = state.said |> String.trim() |> String.split("\n") |> List.last()
    detail = if said in [nil, ""], do: "exit #{status}", else: said

    Process.send_after(self(), :connect, state.reconnect_every)

    {:noreply,
     report(%{
       state
       | conn: nil,
         forwarded: %{},
         failed: %{},
         entries: [],
         status: {:error, "The connection to the VM closed (#{detail})"}
     })}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn, tunnel: tunnel}) when not is_nil(conn),
    do: tunnel.close(conn)

  def terminate(_reason, _state), do: :ok

  defp apply_listeners(%{listeners: nil} = state), do: state

  defp apply_listeners(state) do
    sync(%{state | status: :on}, Ports.plan(state.listeners))
  end

  # Forwards what is new or moved, removes what is gone, and retries what
  # failed once its wait is over.
  defp sync(state, entries) do
    wanted = for %{status: :pending} = entry <- entries, into: %{}, do: {entry.port, entry.target}
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(state.forwarded, state, fn {port, target}, acc ->
        if Map.get(wanted, port) == target do
          acc
        else
          acc.tunnel.cancel(acc.conn, acc.address, port, target)
          %{acc | forwarded: Map.delete(acc.forwarded, port)}
        end
      end)

    state = %{state | failed: Map.take(state.failed, Map.keys(wanted))}

    state =
      Enum.reduce(wanted, state, fn {port, target}, acc ->
        cond do
          Map.get(acc.forwarded, port) == target ->
            acc

          match?({^target, _reason, at} when now - at < acc.retry_after, acc.failed[port]) ->
            acc

          true ->
            case acc.tunnel.forward(acc.conn, acc.address, port, target) do
              :ok ->
                %{
                  acc
                  | forwarded: Map.put(acc.forwarded, port, target),
                    failed: Map.delete(acc.failed, port)
                }

              {:error, message} ->
                reason = why_not(acc.address, port, message)
                %{acc | failed: Map.put(acc.failed, port, {target, reason, now})}
            end
        end
      end)

    entries =
      Enum.map(entries, fn entry ->
        cond do
          entry.status != :pending -> entry
          Map.has_key?(state.forwarded, entry.port) -> %{entry | status: :forwarded}
          failed = state.failed[entry.port] -> %{entry | status: {:skipped, elem(failed, 1)}}
          true -> entry
        end
      end)

    %{state | entries: entries}
  end

  # The tunnel only says it failed; trying the port here says why.
  defp why_not(address, port, message) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))

    case :gen_tcp.listen(port, ip: ip, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        "Couldn't forward it: #{message}"

      {:error, :eaddrinuse} ->
        "Something on this machine already uses it"

      {:error, :eacces} ->
        "Listening on it here needs root"

      {:error, reason} ->
        "Couldn't listen on it here (#{reason})"
    end
  end

  defp report(state) do
    snapshot = %{status: state.status, ports: state.entries}

    if snapshot != state.reported do
      send(state.report_to, {:ports, self(), snapshot})
      %{state | reported: snapshot}
    else
      state
    end
  end
end
