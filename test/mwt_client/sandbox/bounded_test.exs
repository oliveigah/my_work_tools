defmodule MWTClient.Sandbox.BoundedTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Bounded

  doctest MWTClient.Sandbox.Bounded

  test "a command that prints less than the limit gives all of it, its errors apart" do
    assert Bounded.cmd("sh", ["-c", "printf out; printf 'warning: odd' >&2; exit 3"],
             max: 64,
             seconds: 10
           ) == {:ok, "out", "warning: odd", 3}

    assert Bounded.cmd("sh", ["-c", "printf %s \"$GREETING\""],
             max: 64,
             seconds: 10,
             env: [{"GREETING", "hello"}]
           ) == {:ok, "hello", "", 0}

    assert {:ok, "", errors, 127} = Bounded.cmd("no-such-command-here", [], max: 64, seconds: 10)
    assert errors =~ "no-such-command-here"
  end

  test "errors without end are cut, and writing more of them fails" do
    {us, result} =
      :timer.tc(fn ->
        Bounded.cmd("sh", ["-c", "yes err >&2; echo done"], max: 64, seconds: 120)
      end)

    assert {:ok, output, errors, status} = result
    assert byte_size(errors) == 64 * 1024
    assert status != 0 or output == "done\n"
    assert us < 10_000_000, "it took #{div(us, 1000)} ms"
  end

  test "what a command failed with is its output and its errors, the start of them" do
    assert Bounded.failure("  out \n", "err\n", 100) == "out\nerr"
    assert Bounded.failure("", " err ", 100) == "err"
    assert Bounded.failure("x", String.duplicate("e", 50), 10) == "x\neeeeeeee …"
  end

  test "output without end is cut at the limit, and the command and its children are killed" do
    # A child of its own, to be found again by its unusual time.
    marker = "sleep #{1_000_000 + System.unique_integer([:positive])}"
    script = "#{marker} & yes"

    {us, result} =
      :timer.tc(fn -> Bounded.cmd("sh", ["-c", script], max: 1_000_000, seconds: 120) end)

    assert {:error, {:too_long, head}} = result
    assert byte_size(head) == 1_000_000
    assert head =~ ~r/\A(y\n)+y?\z/
    assert us < 10_000_000, "it took #{div(us, 1000)} ms to stop"
    assert {_, 1} = System.cmd("pgrep", ["-fx", marker])
  end

  test "a command past its time limit is a timeout" do
    assert Bounded.cmd("sleep", ["5"], max: 64, seconds: 1) == {:error, :timeout}
  end
end
