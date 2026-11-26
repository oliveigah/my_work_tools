defmodule MWTClient.ProcessGuardTest do
  @moduledoc """
  MWT's own process is not dumpable once it started, so no other program
  running as you reads its memory or environment through `/proc`.

  A process holding `CAP_SYS_PTRACE`, as root's do, reads it anyway, so
  the test that tries is left out of a suite that holds it (`:no_ptrace`,
  `test_helper.exs`); as root, run it under
  `setpriv --bounding-set=-sys_ptrace`.
  """
  use ExUnit.Case, async: true

  alias MWTClient.ProcessGuard

  test "MWT's process isn't dumpable once it started" do
    refute ProcessGuard.dumpable?()
  end

  # A process MWT starts is dumpable again, and the same reader gets its
  # environment: what stops it is the mark, not the file's mode.
  @tag :no_ptrace
  test "another program can't read MWT's environment, but can that of one MWT started" do
    assert {output, status} =
             System.cmd("cat", ["/proc/#{:os.getpid()}/environ"], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "Permission denied"

    port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["30"])
    {:os_pid, child} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{child}"]) end)

    assert {_environ, 0} = System.cmd("cat", ["/proc/#{child}/environ"])
  end
end
