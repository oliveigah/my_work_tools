defmodule MWTClient.Sandbox.HostGitTest do
  use ExUnit.Case, async: true

  import MWTClient.GitHelpers

  alias MWTClient.Sandbox.HostGit

  setup :initialized_repository

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
