defmodule MWTClient.Sandbox.ConsoleTest do
  @moduledoc """
  The VM console: a command you type, run where agents run theirs, its
  output and errors together, its exit status, and its limits.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Console, Guest}

  doctest Console

  @moduletag :tmp_dir

  test "gives back the output with its errors, and the exit status", %{tmp_dir: dir} do
    assert {:ok, result} = Console.run(Guest.local(dir), "echo out; echo err >&2; exit 3", nil)
    assert %{status: 3, output: "out\nerr\n", cut: false, timed_out: false} = result
    assert DateTime.compare(result.finished_at, result.started_at) != :lt
  end

  test "a command past its time is stopped, and says so", %{tmp_dir: dir} do
    assert {:ok, %{timed_out: true, status: nil}} =
             Console.run(Guest.local(dir), "sleep 30", nil, 1)
  end

  test "too much output is cut at the most it keeps", %{tmp_dir: dir} do
    assert {:ok, %{cut: true, status: nil, output: output}} =
             Console.run(Guest.local(dir), "yes x | head -c 400000", nil)

    assert byte_size(output) <= Console.max_output()
  end

  test "nothing to run, or a credential no id could be, is refused before anything runs",
       %{tmp_dir: dir} do
    assert {:error, "Type a command."} = Console.run(Guest.local(dir), "  ", nil)
    assert {:error, "No credential is called that."} = Console.run(Guest.local(dir), "ls", "a b")
  end
end
