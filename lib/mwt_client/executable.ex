defmodule MWTClient.Executable do
  @moduledoc """
  Finds a program on `PATH` as `System.find_executable/1` does, without
  Erlang's file server, and runs one by name (`cmd/3`).

  `System.find_executable/1`, and `System.cmd/3` given a bare name, look
  in each folder of `PATH` in turn with `:file.read_file_info/1`, which
  goes through `file_server_2`: one process for the whole BEAM, which also
  serves every `File.read`, `File.mkdir_p` and `File.rm_rf`. MWT finds
  `timeout`, `bash` and `git` for each git command it runs, and `PATH` is
  long (a tool manager adds a folder per tool): those lookups queued behind
  everything else touching files. Here each folder is one raw `stat` in
  the calling process.

  The answer is the same: the first folder holding a regular file with an
  execute bit set, an empty folder name standing for the current one.

  What was found is kept, for the `PATH` it was found on, and looked at
  again, one raw `stat`, before each use: one removed while MWT runs is
  looked for again, and one not found is looked for at every call. The one
  difference: a second copy installed while MWT runs, in a folder of `PATH`
  before the one found, is used only once MWT restarts.
  """

  @doc """
  The absolute path of the program `name`, looked up in `folders` (`PATH`,
  as `:os.find_executable/2` takes it) unless it is a path already, or nil
  when there is none.
  """
  @spec find(String.t(), String.t()) :: Path.t() | nil
  def find(name, folders \\ System.get_env("PATH", "")) when is_binary(name) do
    case Path.type(name) do
      :absolute ->
        if executable?(name), do: name

      _relative ->
        key = {__MODULE__, name, folders}

        case :persistent_term.get(key, nil) do
          nil -> search(key, name, folders)
          found -> if executable?(found), do: found, else: search(key, name, folders)
        end
    end
  end

  # A new key costs `:persistent_term` nothing; only replacing one does,
  # which happens when a program found moved.
  defp search(key, name, folders) do
    found =
      folders
      |> String.split(":")
      |> Enum.find_value(fn folder ->
        path = Path.absname(Path.join(if(folder == "", do: ".", else: folder), name))
        if executable?(path), do: path
      end)

    if found, do: :persistent_term.put(key, found)
    found
  end

  @doc """
  `System.cmd/3` with `name` found by `find/1`. A program that isn't
  there raises as `System.cmd/3` does: an `ErlangError` of `:enoent`.
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def cmd(name, args, opts \\ []) do
    case find(name) do
      nil -> :erlang.error(:enoent, [name, args, opts])
      path -> System.cmd(path, args, opts)
    end
  end

  # As `:os.find_executable/1` checks: a regular file, any execute bit.
  defp executable?(path) do
    case :file.read_file_info(path, [:raw]) do
      {:ok, info} ->
        %File.Stat{type: type, mode: mode} = File.Stat.from_record(info)
        type == :regular and Bitwise.band(mode, 0o111) != 0

      {:error, _reason} ->
        false
    end
  end
end
