defmodule MWTClient.Files do
  @moduledoc """
  The file calls MWT makes most often, made in the calling process.

  Most of `File` goes through `file_server_2`: one process for the whole
  BEAM, one call at a time. `File.mkdir_p/1` makes two calls for each
  folder from `/` down, even when the folder is there already. With many
  sandboxes writing their inbox at once (the test suite runs dozens), those
  calls queued behind each other and everything else touching files waited.
  These are the same system calls, made raw: in the caller, past the
  server.
  """

  require Record

  # Only `mode` set: what `write_file_info` changes, the rest left as is.
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc "The whole of the file at `path`, as `File.read/1` returns it."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: :file.read_file(path, [:raw])

  @doc "The whole of the file at `path`, raising as `File.read!/1` does."
  @spec read!(Path.t()) :: binary()
  def read!(path) do
    case read(path) do
      {:ok, binary} -> binary
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc """
  Writes `data` to the file at `path`, as `File.write/2`. A file opened raw
  is written in the caller too.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, data), do: File.write(path, data, [:raw])

  @doc "Writes `data` to the file at `path`, raising as `File.write!/2` does."
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, data), do: File.write!(path, data, [:raw])

  @doc """
  Makes the folder `path` and its parents, as `File.mkdir_p/1`. Raw looks
  find the folders already there, and only the missing ones are made
  (making a folder has no raw call): none when `path` is there.
  """
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path) do
    parent = Path.dirname(path)

    cond do
      File.dir?(path, [:raw]) ->
        :ok

      parent == path ->
        :ok

      true ->
        with :ok <- mkdir_p(parent) do
          case File.mkdir(path) do
            {:error, :eexist} -> if File.dir?(path, [:raw]), do: :ok, else: {:error, :enotdir}
            made_or_not -> made_or_not
          end
        end
    end
  end

  @doc "As `mkdir_p/1`, raising as `File.mkdir_p!/1` does."
  @spec mkdir_p!(Path.t()) :: :ok
  def mkdir_p!(path) do
    case mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory (with -p)", path: path
    end
  end

  @doc "Sets the permissions of `path`, raising as `File.chmod!/2` does."
  @spec chmod!(Path.t(), non_neg_integer()) :: :ok
  def chmod!(path, mode) do
    case :file.write_file_info(path, file_info(mode: mode), [:raw]) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "change mode for", path: path
    end
  end

  @doc "Deletes the file at `path`, as `File.rm/1`."
  @spec rm(Path.t()) :: :ok | {:error, File.posix()}
  def rm(path), do: :file.delete(path, [:raw])
end
