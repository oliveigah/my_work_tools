defmodule MWTClient.Sandbox.BubbleTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Bubble, Msb, Sockets}

  # Only paths are made from it: no identity needs to exist.
  @user "bubble-tester"

  @spec_ %{username: @user, name: "mwt-abc", disks: "/data/sandbox/disks"}

  defp pairs(words, flag) do
    words
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(&(hd(&1) == flag))
    |> Enum.map(fn [_flag, from, to] -> {from, to} end)
  end

  test "the VM's process gets namespaces of its own and nothing of your account" do
    words = Bubble.words(@spec_, ["start", "mwt-abc"])

    for flag <-
          ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup --as-pid-1 --clearenv) do
      assert flag in words, flag
    end

    # The seccomp filter, on the descriptor `start/3`'s launcher opens.
    assert ["--seccomp", "3"] == Enum.drop_while(words, &(&1 != "--seccomp")) |> Enum.take(2)

    # Read-only: the system's programs, MWT's runtime. No folder of yours,
    # and none of MWT's for the VM: those are copied into the VM.
    assert pairs(words, "--ro-bind") == [
             {"/usr", "/usr"},
             {Msb.runtime_dir(), "/mwt/runtime"}
           ]

    # Read-write: the sockets to MWT, the VM's disks (its memory is one),
    # and msb's own home, the only paths that are the same outside: its
    # real folder, and the short link its sockets are under.
    assert pairs(words, "--bind") == [
             {Sockets.dir(@user), "/mwt/sockets"},
             {"/data/sandbox/disks", "/mwt/disks"},
             {Msb.store(@user), Msb.store(@user)},
             {Msb.store(@user), Msb.home(@user)}
           ]

    # A VM made before 2026-11-16 mounts MWT's files and its memory from
    # folders: until it is recreated, its bubble has them.
    legacy = %{inbox: "/data/sandbox/inbox", optmem: "/data/sandbox/optmem"}
    words = Bubble.words(Map.put(@spec_, :legacy, legacy), ["start", "mwt-abc"])
    assert {"/data/sandbox/inbox", "/mwt/inbox"} in pairs(words, "--ro-bind")
    assert {"/data/sandbox/optmem", "/mwt/optmem"} in pairs(words, "--bind")

    # MWT's own folder, where the port forwarding's SSH control socket and
    # the bubble's process id are, isn't there.
    refute Enum.any?(words, &String.starts_with?(&1, Sockets.host_dir(@user)))

    # Nothing else of the host's is there: no home folder, no /etc, no /run
    # of yours, and no device but KVM.
    assert pairs(words, "--dev-bind") == [{"/dev/kvm", "/dev/kvm"}]
    refute "/" in (words -- ["--chdir", "/"])
    refute Enum.any?(words, &(&1 in ["/home", "/etc", System.user_home!()]))
  end

  @tag :tmp_dir
  test "under the bubble's seccomp filter, programs run and no user namespace can be made", %{
    tmp_dir: dir
  } do
    bwrap = Bubble.bwrap()
    python = System.find_executable("python3")

    if bwrap && python && MWTClient.Sandbox.Seccomp.program() do
      filter = Path.join(dir, "seccomp.bpf")
      File.write!(filter, MWTClient.Sandbox.Seccomp.program())
      clone = MWTClient.Sandbox.Seccomp.clone(MWTClient.Sandbox.Seccomp.arch())

      # A thread (glibc tries clone3, gets ENOSYS, and uses clone), then
      # clone asking for a user namespace, then unshare.
      probe = """
      import ctypes, os, threading
      t = threading.Thread(target=lambda: None); t.start(); t.join(); print("thread ok")
      libc = ctypes.CDLL(None, use_errno=True)
      print("clone", libc.syscall(#{clone}, 0x10000000 | 17, 0, 0, 0, 0), os.strerror(ctypes.get_errno()))
      try:
          os.unshare(os.CLONE_NEWUSER); print("unshare made one")
      except OSError as error:
          print("unshare", error.strerror)
      """

      words =
        [bwrap | ~w(--unshare-user --unshare-pid --unshare-net --seccomp 3)] ++
          ~w(--ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64) ++
          ~w(--proc /proc --dev /dev --tmpfs /tmp --) ++ [python, "-I", "-c", probe]

      {output, 0} =
        System.cmd("sh", ["-c", ~s(exec "$@" 3< "$FILTER"), "probe" | words],
          env: [{"FILTER", filter}],
          stderr_to_stdout: true
        )

      assert output =~ "thread ok"
      assert output =~ "clone -1 Operation not permitted"
      assert output =~ "unshare Operation not permitted"
    end
  end

  test "the relay is the bubble's first process and runs msb from the bubble's paths" do
    words = Bubble.words(@spec_, ["create", "box:1", "--name", "mwt-abc"])
    {_bwrap, ["--" | command]} = Enum.split_while(words, &(&1 != "--"))

    assert command == [
             "/mwt/runtime/bin/mwt-relay",
             "--sockets",
             "/mwt/sockets",
             "--name",
             "mwt-abc",
             "--",
             "/mwt/runtime/bin/msb",
             "create",
             "box:1",
             "--name",
             "mwt-abc"
           ]

    assert {"MSB_PATH", "/mwt/runtime/bin/msb"} in pairs(words, "--setenv")
    assert {"MSB_HOME", Msb.home(@user)} in pairs(words, "--setenv")
  end

  test "with no relay answering, the VM is down and stopping it is done already" do
    assert Bubble.status(@user) == :down
    assert Bubble.stop(@user) == {:ok, ""}
  end

  test "whether a bubble can be made here comes back as :ok or as words" do
    case Bubble.available() do
      :ok -> :ok
      {:error, words} -> assert words =~ ~r/bwrap|bubble/
    end
  end

  test "the bubble is made with the system's bwrap unless MWT's package installed its own" do
    # No package installed one on a machine that runs the tests from source.
    assert Bubble.bwrap() in [System.find_executable("bwrap"), "/usr/lib/mwt/bwrap"]
    assert hd(Bubble.words(@spec_, ["start", "mwt-abc"])) == (Bubble.bwrap() || "bwrap")
  end
end
