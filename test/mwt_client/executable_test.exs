defmodule MWTClient.ExecutableTest do
  use ExUnit.Case, async: true

  alias MWTClient.Executable

  setup do
    dir = Path.join(System.tmp_dir!(), "executable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "finds on PATH what System.find_executable/1 finds" do
    for name <- ~w(git bash timeout sh no-such-program-here) do
      assert Executable.find(name) == System.find_executable(name), name
    end
  end

  test "a path is checked as it is: a regular file with an execute bit", %{dir: dir} do
    script = Path.join(dir, "script")
    File.write!(script, "#!/bin/sh\n")

    File.chmod!(script, 0o644)
    assert Executable.find(script) == nil
    assert System.find_executable(script) == nil

    File.chmod!(script, 0o700)
    assert Executable.find(script) == script
    assert System.find_executable(script) == script

    assert Executable.find(dir) == nil
    assert Executable.find(Path.join(dir, "missing")) == nil
  end

  test "a program kept is looked for again once it is gone", %{dir: dir} do
    name = "mwt-executable-test-#{System.unique_integer([:positive])}"
    script = Path.join(dir, name)
    File.write!(script, "#!/bin/sh\n")
    File.chmod!(script, 0o755)
    folders = dir <> ":" <> System.get_env("PATH")
    on_exit(fn -> :persistent_term.erase({Executable, name, folders}) end)

    assert Executable.find(name, folders) == script
    assert :persistent_term.get({Executable, name, folders}) == script

    File.rm!(script)
    assert Executable.find(name, folders) == nil
  end

  test "runs a program by name, and raises as System.cmd/3 does when there is none" do
    assert {"hello\n", 0} = Executable.cmd("sh", ["-c", "echo hello"])
    assert_raise ErlangError, ~r/enoent/, fn -> Executable.cmd("no-such-program-here", []) end
    assert_raise ErlangError, ~r/enoent/, fn -> System.cmd("no-such-program-here", []) end
  end
end
