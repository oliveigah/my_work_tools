defmodule MWTClient.Sandbox.HostGitTest do
  use ExUnit.Case, async: true

  import MWTClient.GitHelpers

  alias MWTClient.Sandbox.HostGit

  setup :initialized_repository

  test "runs no hook, even from a core.hooksPath in the working tree", %{base: base, path: path} do
    marker = Path.join(base, "hook-ran")
    hooks = Path.join(path, ".githooks")
    File.mkdir_p!(hooks)
    hook = Path.join(hooks, "reference-transaction")
    File.write!(hook, "#!/bin/sh\necho \"$1\" >> '#{marker}'\n")
    File.chmod!(hook, 0o755)
    git!(path, ["config", "core.hooksPath", ".githooks"])

    # git itself runs it on any ref it moves.
    git!(path, ["update-ref", "refs/heads/plain", "HEAD"])
    assert File.exists?(marker)
    File.rm!(marker)

    assert {:ok, _} = HostGit.run(path, ["update-ref", "refs/heads/ours", "HEAD"])
    assert {:ok, _} = HostGit.run(path, ["update-ref", "-d", "refs/heads/ours"])
    assert {:ok, _} = HostGit.run(path, ["fetch", "--no-write-fetch-head", path, "HEAD:refs/x"])
    refute File.exists?(marker)
  end

  test "successful commands return stdout without warnings", %{path: path} do
    git!(path, ["config", "alias.warn", "!printf '0\\n'; printf 'warning: something\\n' >&2"])

    assert {:ok, "0\n"} = HostGit.run(path, ["warn"])
    assert HostGit.line(path, ["warn"]) == "0"
  end

  test "failures keep diagnostics, but an allowed exit status returns only stdout", %{path: path} do
    git!(path, [
      "config",
      "alias.fail",
      "!printf 'result\\n'; printf 'fatal: failed\\n' >&2; exit 1"
    ])

    assert {:error, error} = HostGit.run(path, ["fail"])
    assert error =~ "result"
    assert error =~ "fatal: failed"
    assert {:ok, "result\n"} = HostGit.run(path, ["fail"], ok: [0, 1])
  end

  test "stdout and stderr are each bounded, and only stdout can be cut", %{path: path} do
    git!(path, ["config", "alias.warn", "!printf 1234; printf 12345678 >&2"])

    assert {:ok, "1234"} = HostGit.run(path, ["warn"], max: 8)
    assert {:error, _} = HostGit.run(path, ["warn"], max: 7)
    assert {:error, _} = HostGit.run(path, ["warn"], max: 7, cut: true)

    git!(path, ["config", "alias.warn", "!printf 12345678; printf 1234 >&2"])

    assert {:error, _} = HostGit.run(path, ["warn"], max: 7)
    assert {:cut, "1234567"} = HostGit.run(path, ["warn"], max: 7, cut: true)
  end
end
