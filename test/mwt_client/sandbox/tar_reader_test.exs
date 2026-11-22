defmodule MWTClient.Sandbox.TarReaderTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.TarReader

  setup do
    dir = Path.join(System.tmp_dir!(), "tar-reader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # The archive GNU tar makes of `names` in `dir`, as the copy back asks
  # for one.
  defp archive(dir, names, extra \\ []) do
    out = Path.join(dir, "out.tar")

    {_, 0} =
      System.cmd(
        "tar",
        ["-c", "-f", out, "--format=gnu", "--no-recursion", "-C", Path.join(dir, "src")] ++
          extra ++ names
      )

    out
  end

  defp put(dir, name, bytes) do
    path = Path.join([dir, "src", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp entries(path) do
    {:ok, io} = File.open(path, [:read, :raw, :binary])

    try do
      read_all(io, [])
    after
      File.close(io)
    end
  end

  defp read_all(io, acc) do
    case TarReader.next(io) do
      {:file, name, size} ->
        {:ok, _bytes} = TarReader.data(io, size, "", fn chunk, read -> {:cont, read <> chunk} end)
        read_all(io, [{:file, name, size} | acc])

      {:dir, name} ->
        read_all(io, [{:dir, name} | acc])

      :eof ->
        {:ok, Enum.reverse(acc)}

      {:error, why} ->
        {:error, why, Enum.reverse(acc)}
    end
  end

  # Each file's name and bytes, as `data/4` gives them, read in turn.
  defp contents(path) do
    {:ok, io} = File.open(path, [:read, :raw, :binary])

    try do
      files(io, [])
    after
      File.close(io)
    end
  end

  defp files(io, acc) do
    case TarReader.next(io) do
      {:file, name, size} ->
        {:ok, bytes} = TarReader.data(io, size, "", fn chunk, read -> {:cont, read <> chunk} end)
        files(io, [{name, bytes} | acc])

      :eof ->
        Enum.reverse(acc)
    end
  end

  test "reads files and their bytes, a long name included", %{dir: dir} do
    long = String.duplicate("deep/", 30) <> "name.txt"
    put(dir, "a.txt", "alpha\n")
    put(dir, long, "long\n")
    put(dir, "big.bin", :crypto.strong_rand_bytes(3 * 1024 * 1024 + 7))

    out = archive(dir, ["a.txt", long, "big.bin"])

    assert [{"a.txt", "alpha\n"}, {^long, "long\n"}, {"big.bin", big}] = contents(out)
    assert big == File.read!(Path.join([dir, "src", "big.bin"]))
  end

  test "a folder is an entry of its own", %{dir: dir} do
    File.mkdir_p!(Path.join([dir, "src", "sub"]))
    put(dir, "sub/x", "x")

    out = archive(dir, ["sub", "sub/x"])
    assert {:ok, [{:dir, "sub"}, {:file, "sub/x", 1}]} = entries(out)
  end

  test "a symlink stops it", %{dir: dir} do
    put(dir, "a.txt", "a")
    File.ln_s!("/etc/passwd", Path.join([dir, "src", "link"]))

    out = archive(dir, ["a.txt", "link"])
    assert {:error, why, [{:file, "a.txt", 1}]} = entries(out)
    assert why =~ "kind the copy back never asks for"
  end

  test "a header whose checksum is wrong stops it", %{dir: dir} do
    put(dir, "a.txt", "a")
    out = archive(dir, ["a.txt"])
    bytes = File.read!(out)
    <<head::binary-size(10), byte, rest::binary>> = bytes
    File.write!(out, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

    assert {:error, "a header whose checksum is wrong", []} = entries(out)
  end

  test "an archive cut inside a file says so", %{dir: dir} do
    put(dir, "a.txt", String.duplicate("a", 2000))
    out = archive(dir, ["a.txt"])
    File.write!(out, binary_part(File.read!(out), 0, 1024))

    {:ok, io} = File.open(out, [:read, :raw, :binary])
    assert {:file, "a.txt", 2000} = TarReader.next(io)

    assert {:error, "the archive ends inside a file"} =
             TarReader.data(io, 2000, nil, fn _chunk, acc -> {:cont, acc} end)

    File.close(io)
  end

  test "a pax header stops it", %{dir: dir} do
    put(dir, "a.txt", "a")
    out = Path.join(dir, "pax.tar")

    {_, 0} =
      System.cmd("tar", ["-c", "-f", out, "--format=pax", "-C", Path.join(dir, "src"), "a.txt"])

    assert {:error, why, []} = entries(out)
    assert why =~ "kind the copy back never asks for"
  end
end
