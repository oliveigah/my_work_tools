defmodule MWTClient.Sandbox.Resources do
  @moduledoc """
  How much of this machine the VM may have: its cores and memory, what MWT
  suggests giving the VM, and the most it lets you give.

  The suggestion gives the VM nearly all of it, since builds and tests in
  the VM are what the machine works on while agents do, and keeps back
  what your desktop needs to stay usable beside a busy VM: an eighth of the
  cores, at least one, and a fifth of the memory, from 4 to 16 GiB.

  The most is every core, and the memory less an eighth of it, from 2 to 8
  GiB, never more than the suggestion keeps back. A vCPU is a thread on
  this machine that its scheduler shares out like any other, so a VM with
  every core slows your desktop but can't stop it. A machine that runs out
  of memory starts killing programs. The memory limit here is a
  ceiling; MemoryControl additionally returns memory under host pressure.

  `host/0` reads this machine: the cores MWT may run on, and `MemTotal` from
  `/proc/meminfo`, nil where there is none. The rest is arithmetic on what
  it read, so tests give machines of their own.
  """

  @gib 1024 * 1024 * 1024

  # Beyond what `MWTClient.Sandbox.Settings` takes anyway.
  @max_cpus 64
  @max_memory_gib 512

  @type host :: %{cores: pos_integer(), memory: non_neg_integer() | nil}
  @type amounts :: %{cpus: pos_integer(), memory_gib: pos_integer()}

  @doc "This machine's cores and memory in bytes (nil when it can't be read)."
  @spec host() :: host()
  def host, do: %{cores: MWTClient.Sandbox.Monitor.Host.cores(), memory: memory()}

  @doc "What the VM is given unless you choose otherwise."
  @spec suggested(host()) :: amounts()
  def suggested(%{cores: cores} = host) do
    most = most(host)
    kept_cores = max(1, div(cores + 4, 8))

    memory_gib =
      case host.memory do
        nil -> min(8, most.memory_gib)
        bytes -> gib(bytes - clamp(bytes / 5, 4 * @gib, 16 * @gib))
      end

    %{
      cpus: min(max(1, cores - kept_cores), most.cpus),
      memory_gib: memory_gib |> max(1) |> min(most.memory_gib)
    }
  end

  @doc "The most the VM may be given on this machine."
  @spec most(host()) :: amounts()
  def most(%{cores: cores, memory: memory}) do
    memory_gib =
      case memory do
        nil -> @max_memory_gib
        bytes -> bytes |> Kernel.-(clamp(bytes / 8, 2 * @gib, 8 * @gib)) |> gib() |> max(1)
      end

    %{cpus: min(max(cores, 1), @max_cpus), memory_gib: min(memory_gib, @max_memory_gib)}
  end

  @doc "What this machine keeps for itself if the VM is given `amounts`."
  @spec left(host(), amounts()) :: %{cores: integer(), memory_gib: float() | nil}
  def left(%{cores: cores, memory: memory}, %{cpus: cpus, memory_gib: memory_gib}) do
    %{
      cores: cores - cpus,
      memory_gib: memory && Float.round(memory / @gib - memory_gib, 1)
    }
  end

  @doc "A byte count in GiB, to one decimal, as the settings show this machine's memory."
  @spec gib_text(non_neg_integer()) :: String.t()
  def gib_text(bytes) do
    gib = Float.round(bytes / @gib, 1)
    if gib == Float.round(gib), do: "#{trunc(gib)}", else: "#{gib}"
  end

  defp gib(bytes), do: floor(bytes / @gib)

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp memory do
    with {:ok, text} <- File.read("/proc/meminfo"),
         [_, kib] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, text) do
      String.to_integer(kib) * 1024
    else
      _ -> nil
    end
  end
end
