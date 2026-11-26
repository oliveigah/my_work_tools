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

  test "starts in the folder given, and says the one its shell ended in", %{tmp_dir: dir} do
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)

    assert {:ok, %{output: output, dir: ^dir, cwd: ^sub, status: 0}} =
             Console.run(Guest.local(dir), "pwd; cd sub", nil, 60, dir)

    assert output == dir <> "\n"

    # A folder gone since: it starts in /work, or home, and says where it is.
    assert {:ok, %{cwd: cwd}} = Console.run(Guest.local(dir), "true", nil, 60, "/no/such/dir")
    assert is_binary(cwd) and cwd != "/no/such/dir"

    assert {:error, "That folder can't be started in."} =
             Console.run(Guest.local(dir), "ls", nil, 60, "relative/path")
  end

  test "colours stay and other escapes go; a line written over keeps its last", %{tmp_dir: dir} do
    assert {:ok, %{output: output}} =
             Console.run(
               Guest.local(dir),
               ~S{printf '\033[31mred\033[0m \033[2Kx\n1%%\r100%%\n'},
               nil
             )

    assert output == "\e[31mred\e[0m x\n100%\n"
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
