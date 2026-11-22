defmodule MWTClient.Sandbox.TarReader do
  @moduledoc """
  Reads a tar archive the VM wrote, entry by entry, from a file open here:
  the copy back's way to take files from the VM without running `tar -x`
  on this machine (`MWTClient.Sandbox.CopyBack`).

  It knows only what the copy back asks the VM's tar for (`--format=gnu`):
  regular files, folders, and GNU's long-name entries (`L`) before a name
  longer than 100 bytes; and POSIX ustar's name prefix. Anything else (a
  link, a device, a pax header, a size in base 256, a header whose
  checksum is wrong) is an error, and reading stops there. Names are
  returned as written, for the caller to judge: this module only reads.

  `next/1` gives the next entry; after a file, `data/4` reads its bytes,
  and must be called before the next `next/1`.
  """

  @block 512
  @chunk 1024 * 1024
  @longest_name 4096

  @typedoc "An entry: a file with its size, a folder, or the end of the archive."
  @type entry :: {:file, binary(), non_neg_integer()} | {:dir, binary()} | :eof

  @doc "The next entry of the archive open as `io` (a raw binary file)."
  @spec next(:file.io_device()) :: entry() | {:error, String.t()}
  def next(io), do: next(io, nil)

  defp next(io, long_name) do
    case :file.read(io, @block) do
      {:ok, <<0::size(@block)-unit(8)>>} ->
        if long_name, do: {:error, "a long name with no entry after it"}, else: :eof

      {:ok, <<header::binary-size(@block)>>} ->
        with :ok <- checksum(header),
             {:ok, size} <- octal(binary_part(header, 124, 12)) do
          entry(io, header, size, long_name)
        end

      {:ok, _short} ->
        {:error, "the archive ends inside a header"}

      :eof ->
        # GNU tar ends with zero blocks; an archive cut short ends here.
        if long_name, do: {:error, "a long name with no entry after it"}, else: :eof

      {:error, reason} ->
        {:error, "the archive couldn't be read: #{:file.format_error(reason)}"}
    end
  end

  defp entry(io, header, size, long_name) do
    name = long_name || name(header)

    case binary_part(header, 156, 1) do
      type when type in ["0", <<0>>] ->
        {:file, name, size}

      "5" ->
        with :ok <- skip(io, size), do: {:dir, String.trim_trailing(name, "/")}

      "L" when size <= @longest_name and long_name == nil ->
        case :file.read(io, padded(size)) do
          {:ok, <<text::binary-size(size), _padding::binary>>} ->
            next(io, text |> :binary.split(<<0>>) |> hd())

          _short ->
            {:error, "the archive ends inside a long name"}
        end

      "L" ->
        {:error, "a long name that is too long, or two in a row"}

      type ->
        {:error, "an entry of a kind the copy back never asks for (#{inspect(type)})"}
    end
  end

  # GNU's magic ("ustar  ") keeps the name in its own field alone; POSIX's
  # ("ustar\0") may put the start of it in the prefix.
  defp name(header) do
    own = header |> binary_part(0, 100) |> field()

    case binary_part(header, 257, 6) do
      "ustar" <> <<0>> ->
        case header |> binary_part(345, 155) |> field() do
          "" -> own
          prefix -> prefix <> "/" <> own
        end

      _gnu_or_older ->
        own
    end
  end

  defp field(bytes), do: bytes |> :binary.split(<<0>>) |> hd()

  # The sum of the header's bytes, its checksum field counted as spaces.
  defp checksum(header) do
    <<before::binary-size(148), stored::binary-size(8), rest::binary>> = header
    sum = Enum.sum(:binary.bin_to_list(before)) + 8 * ?\s + Enum.sum(:binary.bin_to_list(rest))

    case octal(stored) do
      {:ok, ^sum} -> :ok
      _wrong -> {:error, "a header whose checksum is wrong"}
    end
  end

  # An octal number, padded with spaces or NULs. GNU's base-256 sizes (the
  # top bit set) are past anything the copy back takes.
  defp octal(<<1::1, _::bitstring>>), do: {:error, "a size past what is taken"}

  defp octal(bytes) do
    digits = bytes |> field() |> String.trim()

    case Integer.parse(digits, 8) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ when digits == "" -> {:ok, 0}
      _other -> {:error, "a header with a number that isn't one"}
    end
  end

  defp padded(size), do: div(size + @block - 1, @block) * @block

  # Past an entry's data, padding included.
  defp skip(io, size), do: forward(io, padded(size))

  defp forward(_io, 0), do: :ok

  defp forward(io, bytes) do
    case :file.position(io, {:cur, bytes}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "the archive couldn't be read: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Reads the `size` bytes of the file entry just returned, a chunk at a
  time, each given to `fun` with an accumulator starting at `acc`, then
  the padding after them. `fun` returns `{:cont, acc}` to go on, or
  `{:halt, term}` to stop, which is returned; `{:ok, acc}` once all are
  read.
  """
  @spec data(
          :file.io_device(),
          non_neg_integer(),
          acc,
          (binary(), acc -> {:cont, acc} | {:halt, term()})
        ) :: {:ok, acc} | {:halt, term()} | {:error, String.t()}
        when acc: term()
  def data(io, size, acc, fun) do
    with {:ok, acc} <- chunks(io, size, acc, fun),
         :ok <- forward(io, padded(size) - size) do
      {:ok, acc}
    end
  end

  defp chunks(_io, 0, acc, _fun), do: {:ok, acc}

  defp chunks(io, left, acc, fun) do
    case :file.read(io, min(left, @chunk)) do
      {:ok, bytes} ->
        case fun.(bytes, acc) do
          {:cont, acc} -> chunks(io, left - byte_size(bytes), acc, fun)
          {:halt, _} = halt -> halt
        end

      :eof ->
        {:error, "the archive ends inside a file"}

      {:error, reason} ->
        {:error, "the archive couldn't be read: #{:file.format_error(reason)}"}
    end
  end
end
