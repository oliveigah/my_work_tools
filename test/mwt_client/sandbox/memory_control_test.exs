defmodule MWTClient.Sandbox.MemoryControlTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{MemoryControl, Msb}

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024
  @limits %{minimum_mib: 4096, maximum_mib: 24 * 1024, target_mib: 24 * 1024}

  defp host(free), do: %{total: 32 * @gib, available: trunc(free * @gib)}
  defp guest(total, free), do: %{total: trunc(total * @gib), available: trunc(free * @gib)}

  test "host pressure reclaims cache while preserving working memory and headroom" do
    # 2 GiB working, 16 GiB potentially reclaimable; never wipe all cache.
    next = MemoryControl.target(guest(24, 22), host(1), @limits)
    assert next == 22 * 1024

    limits = %{@limits | target_mib: 6 * 1024}
    assert MemoryControl.target(guest(6, 4), host(1), limits) == 6 * 1024
  end

  test "grows under guest demand, even when the host is below its usual reserve" do
    limits = %{@limits | target_mib: 8 * 1024}
    assert MemoryControl.target(guest(8, 1), host(4), limits) > 8 * 1024
    assert MemoryControl.target(guest(8, 1), host(0.5), limits) == 8 * 1024
  end

  test "host recovery restores capacity without crossing the ceiling" do
    limits = %{@limits | target_mib: 8 * 1024}
    assert MemoryControl.target(guest(8, 6), host(10), limits) == 10 * 1024
    assert MemoryControl.target(guest(24, 22), host(10), @limits) == 24 * 1024
  end

  test "the recovery threshold leaves a dead band" do
    limits = %{@limits | target_mib: 8 * 1024}
    assert MemoryControl.target(guest(8, 6), host(7), limits) == 8 * 1024
    # Returning one full step must not immediately ask for it back.
    assert MemoryControl.target(guest(8, 6), host(8), limits) == 8 * 1024
  end

  test "pending unplug does not stack more shrink requests, and demand can cancel it" do
    limits = %{@limits | target_mib: 16 * 1024}
    assert MemoryControl.target(guest(24, 20), host(1), limits) == 16 * 1024
    assert MemoryControl.target(guest(24, 1), host(4), limits) > 16 * 1024
  end

  test "busy guest isn't shrunk below its working set even under host pressure" do
    assert MemoryControl.target(guest(24, 3), host(1), @limits) == 24 * 1024
  end

  test "invalid or missing readings do not change the target" do
    for input <- [nil, %{}, host(-1), %{total: @gib, available: 2 * @gib}] do
      assert MemoryControl.target(guest(24, 20), input, @limits) == @limits.target_mib
    end

    assert MemoryControl.target(guest(24, 25), host(1), @limits) == @limits.target_mib
  end

  test "small ceilings remain usable and all targets stay within their limits" do
    for maximum <- [1, 2, 4, 8, 24, 512],
        current <- MemoryControl.minimum(maximum)..maximum,
        free <- [0, div(current, 2), current],
        host_free <- [0, 1, 4, 16] do
      limits = %{
        minimum_mib: MemoryControl.minimum(maximum) * 1024,
        maximum_mib: maximum * 1024,
        target_mib: current * 1024
      }

      target = MemoryControl.target(guest(current, free), host(host_free), limits)
      assert target >= limits.minimum_mib and target <= limits.maximum_mib
      assert rem(target * @mib, 128 * @mib) == 0
    end
  end

  @tag :tmp_dir
  test "reads host MemAvailable, without falling back to MemFree", %{tmp_dir: root} do
    File.write!(
      Path.join(root, "meminfo"),
      "MemTotal: 32000000 kB\nMemFree: 1 kB\nMemAvailable: 8000000 kB\n"
    )

    assert MemoryControl.host(root) == %{total: 32_000_000 * 1024, available: 8_000_000 * 1024}
    File.write!(Path.join(root, "meminfo"), "MemTotal: 32000000 kB\nMemFree: 1 kB\n")
    assert MemoryControl.host(root) == nil
  end

  test "create separates boot RAM from the hotplug ceiling" do
    args =
      Msb.create_args(%{
        name: "vm",
        image: "alpine",
        cpus: 2,
        memory_gib: 24,
        disk_gib: 4,
        write_budget_gib: 1,
        shell: "/bin/sh",
        shares: [],
        env: []
      })

    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--memory", "4G"])
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--max-memory", "24G"])
  end
end
