defmodule Mix.Tasks.Compile.NativeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.Native

  setup do
    dir = Path.join(System.tmp_dir!(), "compile-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp file(dir, name, mtime) do
    path = Path.join(dir, name)
    File.write!(path, name)
    File.touch!(path, mtime)
    path
  end

  test "a program is built when it is missing or older than any of its sources", %{dir: dir} do
    source = file(dir, "main.rs", 1_000)
    other = file(dir, "Cargo.toml", 1_000)
    program = Path.join(dir, "mwt-present")

    assert Native.stale?(program, [source, other])

    file(dir, "mwt-present", 2_000)
    refute Native.stale?(program, [source, other])
    # A source that isn't there (no Cargo.lock yet) changes nothing.
    refute Native.stale?(program, [source, Path.join(dir, "Cargo.lock")])

    File.touch!(source, 3_000)
    assert Native.stale?(program, [source, other])
  end

  test "a runtime other than the pinned one is told, the pinned one isn't" do
    assert Native.runtime_warning("0.7.15+f9ae8e23d\n", "0.7.15+f9ae8e23d\n") == nil

    warning = Native.runtime_warning("0.7.15+f9ae8e23d\n", "0.8.2+aed6456b4\n")
    assert warning =~ "holds msb 0.7.15+f9ae8e23d, scripts/microsandbox.pin says 0.8.2+aed6456b4"
    assert warning =~ "./scripts/install-runtime.sh"
  end
end
