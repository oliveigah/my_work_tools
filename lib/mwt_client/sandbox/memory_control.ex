defmodule MWTClient.Sandbox.MemoryControl do
  @moduledoc """
  Shares memory with the desktop using microsandbox's existing virtio-mem
  controls. The configured RAM is a ceiling. The VM boots with at most
  4 GiB, so the rest can be unplugged, and normally grows towards its ceiling.

  The monitor calls this in its sampling task. Only host pressure asks for
  shrinkage; guest demand takes priority over further shrinking. Targets
  leave working memory and headroom in the guest, change in bounded steps,
  and wait for the guest's total to follow a shrink before asking for more.
  No cache-clearing commands run in the guest.

  Hotplug is asynchronous, not emergency balloon deflation. An allocation
  larger than the available headroom can still exhaust the guest before
  another sample. The configured ceiling is not a promise that all of it
  is always available when the host also needs memory.
  """

  alias MWTClient.Sandbox.{Bubble, Msb}
  alias MWTClient.Sandbox.Msb.Commands

  @mib 1024 * 1024
  @gib 1024 * @mib
  @step 2 * @gib
  @alignment 128 * @mib

  @doc "The boot allocation, in GiB; it is the lower bound for live shrinking."
  def minimum(maximum_gib), do: min(4, maximum_gib)

  @doc "Reset the boot geometry before every start: live targets also persist in msb."
  def prepare(username, name, maximum_gib) do
    Msb.run(username, Commands.boot_memory(name, minimum(maximum_gib), maximum_gib))
  end

  @doc "Read host memory. Missing or malformed readings never mean zero available RAM."
  def host(root \\ "/proc") do
    with {:ok, text} <- File.read(Path.join(root, "meminfo")),
         [_, total] <- Regex.run(~r/^MemTotal:\s+(\d+) kB$/m, text),
         [_, available] <- Regex.run(~r/^MemAvailable:\s+(\d+) kB$/m, text),
         total = String.to_integer(total) * 1024,
         available = String.to_integer(available) * 1024,
         true <- total > 0 and available <= total do
      %{total: total, available: available}
    else
      _ -> nil
    end
  end

  @doc "The next target in MiB, from guest memory, host memory, and the relay's limits."
  def target(guest, host, limits)

  def target(%{total: total, available: available}, %{total: host_total, available: host_free}, %{
        minimum_mib: low,
        maximum_mib: high,
        target_mib: now
      })
      when total > 0 and available >= 0 and available <= total and
             host_total > 0 and host_free >= 0 and host_free <= host_total and
             low > 0 and high >= low and now >= low and now <= high do
    current = now * @mib
    ceiling = high * @mib
    floor = low * @mib
    reserve = div(host_total, 5) |> max(2 * @gib) |> min(8 * @gib)
    headroom = div(ceiling, 4) |> max(256 * @mib) |> min(4 * @gib)
    working = total - available
    safe = align(working + headroom)
    # MemTotal excludes kernel reservations; allow that difference, but not
    # another whole resize. A slow/refused unplug must not stack requests.
    converged? = total <= current + max(div(current, 20), 128 * @mib)

    bytes =
      cond do
        available < div(headroom, 2) ->
          # Grow even during host pressure when it can spare something.
          spare = max(host_free - min(@gib, div(host_total, 20)), 0)
          current + min(max(@step, safe - current), spare)

        host_free < reserve and converged? ->
          max(current - min(@step, reserve - host_free), safe) |> min(current)

        host_free > reserve + @step ->
          current + min(@step, host_free - reserve)

        true ->
          current
      end

    bytes |> max(floor) |> min(ceiling) |> div(@alignment) |> Kernel.*(div(@alignment, @mib))
  end

  def target(_guest, _host, %{target_mib: now}), do: now

  defp align(bytes), do: div(bytes + @alignment - 1, @alignment) * @alignment

  @doc "Balance one running VM, returning its target and any control failure for the monitor."
  def balance(username, guest, root \\ "/proc") do
    with {:ok, limits} <- Bubble.memory(username) do
      case host(root) do
        nil ->
          Map.put(
            limits,
            :error,
            "Reading this machine's available RAM failed; its memory target is unchanged."
          )

        host ->
          resize(username, guest, host, limits)
      end
    else
      {:error, reason} -> %{error: reason}
    end
  end

  defp resize(username, guest, host, limits) do
    next = target(guest, host, limits)

    if next == limits.target_mib do
      Map.put(limits, :error, nil)
    else
      case Bubble.resize_memory(username, next) do
        {:ok, _output} -> %{limits | target_mib: next} |> Map.put(:error, nil)
        {:error, reason} -> Map.put(limits, :error, reason)
      end
    end
  end
end
