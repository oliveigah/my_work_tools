defmodule MWTClient.FilesTest do
  use ExUnit.Case, async: true

  alias MWTClient.Files

  setup do
    dir = Path.join(System.tmp_dir!(), "files-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "makes a folder and its parents, and leaves one that is there", %{dir: dir} do
    folder = Path.join(dir, "a/b/c")
    assert Files.mkdir_p!(folder) == :ok
    assert File.dir?(folder)
    assert Files.mkdir_p(folder) == :ok

    # Where a file is in the way, it fails as File.mkdir_p does.
    file = Path.join(dir, "a/file")
    File.write!(file, "")
    assert Files.mkdir_p(Path.join(file, "below")) == File.mkdir_p(Path.join(file, "below"))
    assert_raise File.Error, fn -> Files.mkdir_p!(Path.join(file, "below")) end
  end

  test "writes and reads a file whole, failing as File does", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "text")

    assert Files.write!(path, ["one", "\n"]) == :ok
    assert Files.read!(path) == "one\n"
    assert Files.read(path) == File.read(path)

    missing = Path.join(dir, "missing")
    assert Files.read(missing) == File.read(missing)

    assert_raise File.Error, ~r/could not read file .*missing.*: no such file/, fn ->
      Files.read!(missing)
    end

    assert Files.write(Path.join(missing, "x"), "") == File.write(Path.join(missing, "x"), "")
  end

  test "sets a file's mode, and deletes it", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "script")
    File.write!(path, "data")

    assert Files.chmod!(path, 0o751) == :ok
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o751
    assert File.read!(path) == "data"

    assert Files.rm(path) == :ok
    refute File.exists?(path)
    assert Files.rm(path) == File.rm(path)
    assert_raise File.Error, ~r/could not change mode/, fn -> Files.chmod!(path, 0o644) end
  end
end
