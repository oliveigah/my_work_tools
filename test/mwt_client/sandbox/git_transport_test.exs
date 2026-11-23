defmodule MWTClient.Sandbox.GitTransportTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Gate, Project, Projects, Server}

  @helper Path.expand("../../../priv/sandbox/mwt-git-remote", __DIR__)

  setup context do
    project = %Project{name: "app", path: context.repo, mirrored_branch: "master"}
    {:ok, project} = Server.call(context.username, {:add_project, project})
    bin = Path.join(context.base, "git-bin")
    File.mkdir!(bin)
    fake_socat!(bin)
    File.cp!(@helper, Path.join(bin, "git-remote-mwt"))
    File.chmod!(Path.join(bin, "git-remote-mwt"), 0o755)

    %{
      project: project,
      remote: Project.remote_url(project),
      clone: Path.join(context.base, "clone"),
      env:
        git_env() ++
          [
            {"PATH", bin <> ":" <> System.get_env("PATH")},
            {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)}
          ]
    }
  end

  test "ordinary clone, ls-remote and fetch read host commits without moving local work",
       context do
    git(context.repo, ["branch", "release"])
    git(context.repo, ["tag", "v1"])
    File.write!(Path.join(context.repo, "a.txt"), "uncommitted host work\n")
    File.write!(Path.join(context.repo, "local.txt"), "host only\n")

    assert {refs, 0} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert refs =~ "refs/heads/master"
    assert refs =~ "refs/heads/release"
    assert refs =~ "refs/tags/v1"

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])
    assert File.read!(Path.join(context.clone, "a.txt")) == "one\ntwo\nthree\n"
    refute File.exists?(Path.join(context.clone, "local.txt"))
    assert git(context.clone, ["config", "remote.origin.url"]) == context.remote <> "\n"

    commit(context.clone, [{"vm.txt", "VM commit\n"}], "VM work")
    vm_head = sha(context.clone, "HEAD")
    File.write!(Path.join(context.clone, "vm.txt"), "unfinished VM work\n")
    commit(context.repo, [{"host.txt", "new host commit\n"}], "Host work")
    host_head = sha(context.repo, "HEAD")

    assert {_, 0} = remote_git(context, context.clone, ["fetch", "origin"])
    assert sha(context.clone, "origin/master") == host_head
    assert sha(context.clone, "HEAD") == vm_head
    assert File.read!(Path.join(context.clone, "vm.txt")) == "unfinished VM work\n"
    assert File.read!(Path.join(context.repo, "local.txt")) == "host only\n"
  end

  test "hidden refs and a detached host HEAD cannot advertise or serve unrelated objects",
       context do
    tree = git(context.repo, ["rev-parse", "master^{tree}"]) |> String.trim()
    hidden = git(context.repo, ["commit-tree", tree, "-m", "Private commit"]) |> String.trim()
    git(context.repo, ["update-ref", "refs/private/hidden", hidden])
    git(context.repo, ["checkout", "--quiet", "--detach", hidden])

    assert {refs, 0} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert refs =~ "refs/heads/master"
    refute refs =~ "refs/private/"
    refute refs =~ hidden

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])
    assert {error, status} = remote_git(context, context.clone, ["fetch", "origin", hidden])
    assert status != 0
    assert error =~ "not our ref" or error =~ "unadvertised object"
    assert sha(context.repo, "HEAD") == hidden
  end

  test "binary pack contents larger than socket buffers arrive intact", context do
    content = :crypto.strong_rand_bytes(512 * 1024)
    commit(context.repo, [{"image.bin", content}], "Add binary file")

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])
    assert File.read!(Path.join(context.clone, "image.bin")) == content
  end

  test "a client asking for protocol version 2 is answered in an earlier one", context do
    assert {refs, 0} =
             remote_git(context, context.base, [
               "-c",
               "protocol.version=2",
               "ls-remote",
               context.remote
             ])

    assert refs =~ "refs/heads/master"

    assert {trace, 0} =
             System.cmd("git", ["-C", context.base, "ls-remote", context.remote],
               env: context.env ++ [{"GIT_PROTOCOL", "version=2"}, {"GIT_TRACE_PACKET", "1"}],
               stderr_to_stdout: true
             )

    assert trace =~ "< #{sha(context.repo, "master")} refs/heads/master"
    refute trace =~ ~r/< version 2/
  end

  # Under version 2, upload-pack ignores `uploadpack.allow*InWant` and
  # serves any object of the borrowed store by its id.
  test "a stash and a commit reset away can't be fetched by id under any protocol version",
       context do
    File.write!(Path.join(context.repo, "secret.env"), "API_KEY=only-in-the-stash\n")
    git(context.repo, ["add", "secret.env"])
    git(context.repo, ["stash", "push", "--quiet", "-m", "wip"])
    stash = sha(context.repo, "refs/stash")
    commit(context.repo, [{"oops.txt", "reset away\n"}], "Oops")
    dangling = sha(context.repo, "HEAD")
    git(context.repo, ["reset", "--quiet", "--hard", "HEAD~1"])

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])

    for oid <- [stash, dangling], protocol <- ["version=1", "version=2"] do
      assert {error, status} =
               System.cmd(
                 "timeout",
                 ["--kill-after=2", "20", "git", "-C", context.clone, "fetch", "origin", oid],
                 env: context.env ++ [{"GIT_PROTOCOL", protocol}],
                 stderr_to_stdout: true
               )

      assert status not in [0, 124, 137], "#{protocol} fetch of #{oid} gave #{status}"
      assert error =~ "not our ref" or error =~ "unadvertised object"

      assert {_, missing} =
               System.cmd("git", ["-C", context.clone, "cat-file", "-e", oid],
                 env: context.env,
                 stderr_to_stdout: true
               )

      assert missing != 0
    end
  end

  test "pushes are refused and never change host branches", context do
    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])
    original = sha(context.repo, "master")
    commit(context.clone, [{"vm.txt", "VM work\n"}], "VM work")

    assert {error, status} = remote_git(context, context.clone, ["push", "origin", "HEAD:master"])
    assert status != 0
    assert error =~ "mwt handoff"
    assert sha(context.repo, "master") == original
  end

  test "host paths, arbitrary options, unknown projects and write services are refused",
       context do
    for changes <- [
          %{"project" => context.repo},
          %{"project" => String.duplicate("0", 64)},
          %{"service" => "git-receive-pack"},
          %{"path" => context.repo},
          %{"arguments" => ["--advertise-refs"]},
          %{"protocol" => "version=2:arbitrary"}
        ] do
      socket = open_stream(context, Map.merge(handshake(context), changes))
      assert {:ok, "1\n"} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
    end
  end

  test "the line handshake preserves binary bytes already waiting in the socket", context do
    socket = open_stream(context, handshake(context), "0000")
    assert {:ok, "0\n"} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :inet.setopts(socket, packet: :raw)
    assert {:ok, advertisement} = :gen_tcp.recv(socket, 0, 5_000)
    assert advertisement =~ "refs/heads/master"
    :gen_tcp.close(socket)
  end

  test "closed and unshared projects cannot be fetched", context do
    assert {:ok, _} = Projects.close(context.username, "app")
    assert {message, status} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert status != 0
    assert message =~ "closed, unshared"

    {:ok, _} = Server.call(context.username, {:put_project, context.project, "Reopen"})
    :ok = MWTClient.Sandbox.remove_share(context.username, Path.join(context.base, "host"))
    assert {_, status} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert status != 0
  end

  test "isolation stops new and existing read streams", context do
    socket = open_stream(context, handshake(context))
    assert {:ok, "0\n"} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :inet.setopts(socket, packet: :raw, active: true)
    Gate.trip(context.username, %{reason: :test})
    assert_receive {:tcp_closed, ^socket}, 3_000

    assert {message, status} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert status != 0
    assert message =~ "isolated"
  end

  test "a fifth concurrent Git read is refused until another stream ends", context do
    sockets =
      for _ <- 1..4 do
        socket = open_stream(context, handshake(context))
        assert {:ok, "0\n"} = :gen_tcp.recv(socket, 0, 5_000)
        socket
      end

    fifth = open_stream(context, handshake(context))
    assert {:ok, "1\n"} = :gen_tcp.recv(fifth, 0, 5_000)
    assert {:ok, message} = :gen_tcp.recv(fifth, 0, 5_000)
    assert message =~ "Four Git transfers"

    # Wait for the server's close after EOF so capacity is returned before
    # the next request; no timing assumptions about the worker's cleanup.
    [first | rest] = sockets
    :ok = :inet.setopts(first, packet: :raw, active: true)
    :ok = :gen_tcp.shutdown(first, :write)
    assert_receive {:tcp_closed, ^first}
    replacement = open_stream(context, handshake(context))
    assert {:ok, "0\n"} = :gen_tcp.recv(replacement, 0, 5_000)
    Enum.each([replacement, fifth | rest], &:gen_tcp.close/1)
  end

  defp handshake(context) do
    %{
      "command" => "git",
      "project" => Project.id(context.project),
      "service" => "git-upload-pack",
      "protocol" => ""
    }
  end

  defp open_stream(context, request, tail \\ "") do
    {:ok, socket} =
      :gen_tcp.connect({:local, Channel.socket_path(context.username)}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    :ok = :gen_tcp.send(socket, [Jason.encode!(request), "\n", tail])
    socket
  end

  test "remote-origin serves your repository's own remote branches, as you last fetched them",
       context do
    # Your repository's own remote, a Git server of yours, with a branch
    # of a colleague's that your machine fetched.
    server = Path.join(context.base, "server.git")
    git(context.base, ["clone", "-q", "--bare", context.repo, server])
    git(context.repo, ["remote", "add", "origin", server])
    work = Path.join(context.base, "colleague")
    git(context.base, ["clone", "-q", server, work])
    git(work, ["switch", "-q", "-c", "colleague"])
    commit(work, [{"c.txt", "theirs\n"}], "a colleague's work")
    git(work, ["push", "-q", "origin", "colleague"])
    git(context.repo, ["fetch", "-q", "origin"])
    fetched = sha(context.repo, "origin/colleague")

    # Off, the remote isn't fetched for the VM: what your machine has.
    {:ok, _} = MWTClient.Sandbox.turn_off(context.username, "git-fetch-remote")
    commit(work, [{"c.txt", "theirs, later\n"}], "more of it")
    git(work, ["push", "-q", "origin", "colleague"])

    remote_origin = context.remote <> "/remote-origin"
    assert {refs, 0} = remote_git(context, context.base, ["ls-remote", remote_origin])
    assert refs =~ "#{fetched}\trefs/heads/colleague"
    refute refs =~ "refs/heads/HEAD"

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone])
    git(context.clone, ["remote", "add", "remote-origin", remote_origin])
    assert {_, 0} = remote_git(context, context.clone, ["fetch", "-q", "remote-origin"])
    assert sha(context.clone, "remote-origin/colleague") == fetched

    # On, your machine fetches it first, into MWT's store: your
    # repository's own remote branches don't move.
    {:ok, _} = MWTClient.Sandbox.turn_on(context.username, "git-fetch-remote", :until_off, :all)
    assert {_, 0} = remote_git(context, context.clone, ["fetch", "-q", "remote-origin"])
    assert sha(context.clone, "remote-origin/colleague") == sha(work, "HEAD")
    assert sha(context.repo, "origin/colleague") == fetched
  end

  test "with Git: fetch from your repositories off, nothing is fetched", context do
    {:ok, _} = MWTClient.Sandbox.turn_off(context.username, "git-fetch")
    assert {said, status} = remote_git(context, context.base, ["ls-remote", context.remote])
    assert status != 0
    assert said =~ "Git: fetch from your repositories is off"
    assert said =~ "mwt request git-fetch"
  end

  defp remote_git(context, dir, args) do
    System.cmd("git", ["-C", dir | args], env: context.env, stderr_to_stdout: true)
  end
end
