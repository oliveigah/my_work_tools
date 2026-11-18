defmodule MWTClient.Sandbox.ShellTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Msb

  setup do
    dir = Path.join(System.tmp_dir!(), "sandbox-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "home"))
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ["profile", "bashrc"] do
      script =
        File.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", "mwt-#{name}.sh"]))
        |> String.replace("/mnt/mwt", dir)
        |> String.replace("/cache", dir <> "/cache")
        |> String.replace("/usr/local/share", dir <> "/usr/local/share")

      File.write!(Path.join(dir, "#{name}.sh"), script)
    end

    File.write!(Path.join(dir, "env.sh"), "export MWT_TEST_GRANT=placeholder\n")

    for {path, command} <- [
          {"cache/mise/shims", "runtime-tool"},
          {"usr/local/share/mise/shims", "baked-tool"},
          {"usr/local/share/cargo/bin", "cargo-tool"},
          {"home/.local/bin", "home-tool"}
        ] do
      bin = Path.join(dir, path)
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, command), "#!/bin/sh\necho #{command}\n")
      File.chmod!(Path.join(bin, command), 0o755)
    end

    env = [
      {"HOME", Path.join(dir, "home")},
      {"PATH", "/usr/bin:/bin"},
      {"BASH_ENV", Path.join(dir, "profile.sh")},
      {"MWT_TEST_PROFILE", Path.join(dir, "profile.sh")},
      {"ZED_FILE_WATCHER_MODE", "native"},
      {"ZED_FILE_WATCHER_POLL_MS", "30000"},
      {"MWT_TEST_GRANT", nil}
    ]

    %{dir: dir, env: env}
  end

  test "SSH uses Bash independently of the image's CMD or passwd entry" do
    args =
      Msb.create_args(%{
        name: "test",
        image: "box:1",
        shell: "/bin/bash",
        cpus: 4,
        memory_gib: 8,
        disk_gib: 64,
        env: [{"GH_TOKEN", "placeholder"}]
      })

    after_flag = fn flag -> args |> Enum.drop_while(&(&1 != flag)) |> tl() |> hd() end
    every = fn flag -> for {^flag, value} <- Enum.zip(args, tl(args)), do: value end

    assert after_flag.("--shell") == "/bin/bash"
    assert after_flag.("--root-disk") == "64G"
    assert after_flag.("--env") == "GH_TOKEN=placeholder"

    # Everything the VM is made of is named by its path in the bubble, which
    # the host doesn't have, and the proxy and DNS by the relay's ports.
    assert after_flag.("--proxy") == "http://127.0.0.1:3128"
    assert after_flag.("--dns-nameserver") == "127.0.0.1:5353"
    assert after_flag.("--vsock") == "/mwt/sockets/channel.sock:5000"

    assert every.("--mount-disk") == [
             "/mwt/disks/home.img:/root",
             "/mwt/disks/cache.img:/cache",
             "/mwt/disks/work.img:/work",
             "/mwt/disks/memory.img:/root/.optmem"
           ]

    # No folder of this machine is mounted: shared folders and /mnt/mwt are
    # copied in (MWTClient.Sandbox.FolderSync), and the memory is a disk.
    assert every.("--volume") == []
  end

  test "commands and login probes find baked, cached and Home tools with empty Home", %{env: env} do
    command = "runtime-tool; baked-tool; cargo-tool; home-tool; echo grant=$MWT_TEST_GRANT"

    for flag <- ["-c", "-lc"] do
      assert {output, 0} = System.cmd("bash", [flag, command], env: env, stderr_to_stdout: true)
      assert output == "runtime-tool\nbaked-tool\ncargo-tool\nhome-tool\ngrant=\n"
    end
  end

  test "loading the profile repeatedly preserves PATH without exporting grants", %{
    dir: dir,
    env: env
  } do
    command = ~S"""
    before=$PATH
    . "$MWT_TEST_PROFILE"
    test "$before" = "$PATH" || exit 1
    test "${MWT_TEST_GRANT+x}" != x || exit 2
    printf 'export MWT_TEST_GRANT=updated\n' > "$(dirname "$MWT_TEST_PROFILE")/env.sh"
    . "$MWT_TEST_PROFILE"
    test "${MWT_TEST_GRANT+x}" != x || exit 3
    """

    assert {"", 0} = System.cmd("sh", ["-c", ". \"#{dir}/profile.sh\"; " <> command], env: env)
  end

  test "commands and SSH login probes poll shared files instead of relying on inotify", %{
    env: env
  } do
    command = ~S"""
    test "$ZED_FILE_WATCHER_MODE" = poll || exit 1
    test "$ZED_FILE_WATCHER_POLL_MS" = 5000 || exit 2
    """

    for flag <- ["-c", "-lc"] do
      assert {"", 0} = System.cmd("bash", [flag, command], env: env, stderr_to_stdout: true)
    end
  end

  test "interactive Bash has tools, history and a prompt without dotfiles", %{dir: dir, env: env} do
    command = ~S"""
    runtime-tool && baked-tool && home-tool || exit 1
    shopt -q histappend checkwinsize || exit 2
    test "$HISTSIZE" = 10000 || exit 3
    test "${MWT_TEST_GRANT+x}" != x || exit 4
    case "$PS1" in *mwt*) ;; *) exit 5 ;; esac
    """

    assert {output, 0} =
             System.cmd("bash", ["--rcfile", Path.join(dir, "bashrc.sh"), "-ic", command],
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "runtime-tool\nbaked-tool\nhome-tool\n"
  end
end
