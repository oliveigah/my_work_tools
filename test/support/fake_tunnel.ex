defmodule MWTClient.FakeTunnel do
  @moduledoc false
  # A tunnel for `MWTClient.Sandbox.Forwarder` in tests. Its opts (or, when
  # the server builds them, `config :mwt_client, MWTClient.FakeTunnel`) name
  # the test process, told of every call, and an agent holding which
  # forwards fail (`fail`) and whether opening works (`open`). What listens
  # in the VM comes as reports, as from the VM's watcher: `report/1` writes
  # one.

  @behaviour MWTClient.Sandbox.Forwarder

  def agent(attrs \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> Map.merge(%{fail: %{}, open: :ok}, attrs) end)
    agent
  end

  def set(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))

  @impl true
  def open(opts) do
    %{test: test, agent: agent} =
      Map.merge(Map.new(Application.get_env(:mwt_client, __MODULE__, [])), opts)

    case Agent.get(agent, & &1.open) do
      :ok ->
        ref = make_ref()
        send(test, {:tunnel, :open, ref, opts})
        {:ok, %{port: ref, test: test, agent: agent}}

      {:error, message} ->
        send(test, {:tunnel, :open_failed})
        {:error, message}
    end
  end

  @impl true
  def forward(%{test: test, agent: agent}, address, port, target) do
    send(test, {:tunnel, :forward, address, port, target})

    case Agent.get(agent, &Map.get(&1.fail, port)) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  @impl true
  def cancel(%{test: test}, address, port, target) do
    send(test, {:tunnel, :cancel, address, port, target})
    :ok
  end

  @impl true
  def close(%{test: test, port: ref}) do
    send(test, {:tunnel, :close, ref})
    :ok
  end

  @doc """
  A report as the VM's watcher sends it, for `{bind, port, process}` or
  `{bind, port, process, folder}`: `ss -ltnpH` lines, then the folders.
  """
  def report(listeners) do
    listeners =
      listeners
      |> Enum.with_index(100)
      |> Enum.map(fn
        {{bind, port, process}, pid} -> {bind, port, process, pid, nil}
        {{bind, port, process, cwd}, pid} -> {bind, port, process, pid, cwd}
      end)

    lines =
      Enum.map(listeners, fn {bind, port, process, pid, _cwd} ->
        "LISTEN 0      4096   #{bind}:#{port}   0.0.0.0:*    users:((\"#{process}\",pid=#{pid},fd=3))"
      end)

    folders = for {_, _, _, pid, cwd} <- listeners, cwd, do: "cwd #{pid} #{cwd}"
    Enum.join(lines ++ folders, "\n")
  end

  @doc "What `MWTClient.Sandbox.Ports.parse/1` reads from `report/1`."
  def listeners(listeners), do: listeners |> report() |> MWTClient.Sandbox.Ports.parse()
end
