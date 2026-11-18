defmodule MWTClient.Sandbox.Scratch do
  @moduledoc """
  Folders of MWT's own in the system's temporary folder, for what it hands
  a command: a list of files, a command's errors, a copy of your memory.

  The temporary folder is shared by every account on the machine. A name
  another account can guess, made with `mkdir -p`, may already be that
  account's folder: what MWT writes there is then theirs to read, or to
  change before a command reads it. So each folder's name is random, MWT
  makes it itself (one already there is an error, never a folder to use),
  and only you can open it.
  """

  @doc "Makes a folder only you can open, named `prefix` and a random part."
  @spec dir!(String.t()) :: Path.t()
  def dir!(prefix) do
    random = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{random}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  @doc "Runs `fun` with a folder made by `dir!/1`, removed when it returns."
  @spec with_dir(String.t(), (Path.t() -> result)) :: result when result: var
  def with_dir(prefix, fun) do
    dir = dir!(prefix)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end
