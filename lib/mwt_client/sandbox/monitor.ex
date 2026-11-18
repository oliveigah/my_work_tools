defmodule MWTClient.Sandbox.Monitor do
  @moduledoc """
  What the VM is doing, every five seconds while it runs: its CPU, memory,
  load, disks, network and busiest processes as the VM sees them, and what
  it costs this machine.

  One process per unlocked identity, started by `MWTClient.Vault.Store`
  after `MWTClient.Sandbox.Server`, which it asks whether the VM runs.
  While it doesn't, nothing is read. A sample is one `msb exec` of a short
  script (`MWTClient.Sandbox.Monitor.Sample`), a look at this machine's
  `/proc` for the VM's bubble and everything under it
  (`MWTClient.Sandbox.Monitor.Host`), and the host space each disk image
  takes. It also uses MemoryControl to return RAM under host pressure or
  restore guest headroom. All of it runs in a task, never in this process, and a tick that
  comes while one still runs is skipped.

  CPU and network are rates between two samples, so the first sample after
  the VM starts has none. The last ten minutes are kept, in memory only,
  for the charts. After each sample, `snapshot/1` goes to the identity's
  pages as `{:sandbox_monitor, snapshot}` on the sandbox's topic
  (`MWTClient.Sandbox.Server.topic/1`).

  Tests set `config :mwt_client, MWTClient.Sandbox.Monitor, guest: guest,
  proc_root: path` to put a VM and a `/proc` of their own in place of the
  real ones, and send `:tick` themselves: the clock only runs where the
  sandbox runs VMs.
  """

  use GenServer

  alias MWTClient.Sandbox.{Disks, MemoryControl, Projects, Server, Sockets}
  alias MWTClient.Sandbox.Monitor.{Host, Sample}
  alias MWTClient.Sandbox.Server.State
  alias MWTClient.Vault.Store

  @interval_ms 5_000
  @tasks MWTClient.Sandbox.TaskSupervisor

  @type snapshot :: %{
          latest: Sample.t() | nil,
          history: [Sample.point()],
          error: String.t() | nil,
          interval_ms: pos_integer()
        }

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc """
  The latest sample, or nil while the VM isn't running; the last ten
  minutes of points, oldest first; and why the last sample failed, or nil.
  Empty when the identity is locked.
  """
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(username) do
    case Store.whereis(__MODULE__, username) do
      nil ->
        empty()

      pid ->
        try do
          GenServer.call(pid, :snapshot)
        catch
          :exit, _ -> empty()
        end
    end
  end

  defp empty, do: %{latest: nil, history: [], error: nil, interval_ms: @interval_ms}

  @impl true
  def init(opts) do
    state = %{
      username: Keyword.fetch!(opts, :username),
      task: nil,
      started_at: nil,
      counters: nil,
      latest: nil,
      history: [],
      error: nil
    }

    # An interval timer, as the sandbox's own loops: a tick lost while the
    # module is compiled again in development doesn't end the loop.
    if State.external?() do
      {:ok, _} = :timer.send_interval(@interval_ms, :tick)
      send(self(), :tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    username = state.username
    task = Task.Supervisor.async_nolink(@tasks, fn -> measure(username) end)
    {:noreply, %{state | task: task}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, take(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply,
     failed(%{state | task: nil}, "Reading the VM failed: " <> Exception.format_exit(reason))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp take(state, :skip), do: state

  # Stopped: the latest sample is no longer what the VM does. The history
  # stays, and ages out.
  defp take(state, :stopped) do
    stopped = %{state | started_at: nil, counters: nil, latest: nil, error: nil}
    if stopped != state, do: broadcast(stopped)
    stopped
  end

  defp take(state, {:error, started_at, text}), do: failed(since(state, started_at), text)

  defp take(state, {:ok, started_at, reading}) do
    state = since(state, started_at)
    {sample, counters} = Sample.build(reading, state.counters)

    state = %{
      state
      | counters: counters,
        latest: sample,
        error: nil,
        history: Sample.remember(state.history, Sample.point(sample))
    }

    broadcast(state)
    # The firewall watches the busiest processes for one that never rests.
    Server.cast(state.username, {:processes, sample.processes})
    state
  end

  # A VM started again since the last sample is not compared with it.
  defp since(%{started_at: started_at} = state, started_at), do: state

  defp since(state, started_at),
    do: %{state | started_at: started_at, counters: nil}

  defp failed(%{error: text} = state, text), do: state

  defp failed(state, text) do
    state = %{state | error: text}
    broadcast(state)
    state
  end

  defp snapshot_of(state),
    do: %{
      latest: state.latest,
      history: state.history,
      error: state.error,
      interval_ms: @interval_ms
    }

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      MWTClient.PubSub,
      Server.topic(state.username),
      {:sandbox_monitor, snapshot_of(state)}
    )
  end

  ## In the task

  defp measure(username) do
    config = Application.get_env(:mwt_client, __MODULE__, [])

    case vm(username) do
      %{vm: %{status: :running} = vm, dir: dir} ->
        with {:ok, guest} <- guest(username, vm, config),
             {:ok, output} <- guest.exec.(["sh", "-c", Sample.script(), "mwt-monitor", "/proc"]),
             {:ok, reading} <- Sample.parse(output) do
          {:ok, vm.started_at,
           %{
             at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
             guest: reading,
             host: host(username, Keyword.get(config, :proc_root, "/proc")),
             host_used: host_used(dir),
             memory_control: balance(username, reading.memory, config)
           }}
        else
          {:error, reason} -> {:error, vm.started_at, Projects.explain(reason)}
        end

      %{vm: _stopped} ->
        :stopped

      nil ->
        :skip
    end
  end

  defp balance(username, memory, config) do
    if State.external?() do
      MemoryControl.balance(username, memory, Keyword.get(config, :proc_root, "/proc"))
    end
  end

  # The sandbox may be starting again after a crash: this tick is skipped.
  defp vm(username) do
    Server.call(username, :projects)
  catch
    :exit, _ -> nil
  end

  defp guest(username, vm, config) do
    case Keyword.fetch(config, :guest) do
      {:ok, guest} -> {:ok, guest}
      :error -> Projects.guest(username, vm)
    end
  end

  defp host(username, proc_root) do
    with {:ok, text} <- File.read(Sockets.host_path(username, "bubble.pid")),
         {pid, _} <- Integer.parse(String.trim(text)) do
      Host.read(pid, proc_root)
    else
      _ -> nil
    end
  end

  defp host_used(dir) do
    paths = Disks.paths(dir)

    Map.new([:work, :home, :cache], fn name ->
      path = Map.fetch!(paths, name)
      {name, if(File.regular?(path), do: Disks.used(path))}
    end)
  end
end
