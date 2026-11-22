defmodule MWTClient.TestFolders do
  @moduledoc """
  Removes a folder a test made, whole, with `rm -rf`.

  `File.rm_rf!/1` makes a few calls on Erlang's file server for each file
  and folder in the tree, and that server is one process for the whole
  BEAM. Every test removes its identity's folder (databases, inbox,
  sockets) and most remove one of their own: their cleanups queued behind
  each other and behind every other test's file calls. `rm` makes the same
  system calls in a process of its own.
  """

  @doc """
  Removes `path` and all it holds; nothing there is fine, as with
  `File.rm_rf!/1`. A folder that can't be removed (something still writing
  into it) fails the test, with what `rm` said.
  """
  @spec remove!(Path.t()) :: :ok
  def remove!(path) do
    case MWTClient.Executable.cmd("rm", ["-rf", "--", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "rm -rf #{path} exited #{status}: #{String.trim(output)}"
    end
  end
end
