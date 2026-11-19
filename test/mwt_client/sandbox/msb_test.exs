defmodule MWTClient.Sandbox.MsbTest do
  # The runtime folder is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MWTClient.Accounts
  alias MWTClient.Sandbox.{Msb, Sockets}
  alias MWTClient.Sandbox.Grant
  alias MWTClient.Sandbox.Server.Machine

  doctest MWTClient.Sandbox.Msb

  # Only paths are made from it: no identity needs to exist.
  @user "msb-tester"

  setup do
    saved = Application.get_env(:mwt_client, Msb)
    # A space and a quote, as a home folder may have.
    dir = Path.join(System.tmp_dir!(), "msb test 'runtime' #{System.unique_integer([:positive])}")
    Application.put_env(:mwt_client, Msb, Keyword.put(saved, :runtime_dir, dir))

    on_exit(fn ->
      Application.put_env(:mwt_client, Msb, saved)
      File.rm_rf!(dir)
      File.rm_rf!(Accounts.dir(@user))
      File.rm_rf!(Sockets.dir(@user))
    end)

    %{dir: dir}
  end

  # A stand-in msb that prints what it was run with.
  defp fake_runtime(dir) do
    msb = Path.join(dir, "bin/msb")
    File.mkdir_p!(Path.dirname(msb))
    File.write!(msb, ~S(#!/bin/sh
printf 'home=%s path=%s args=%s\n' "$MSB_HOME" "$MSB_PATH" "$*"
))
    File.chmod!(msb, 0o755)
    msb
  end

  # Holds the relay's lock the way a running relay does, until the test ends.
  defp hold_lock do
    Sockets.ensure!(@user)
    lock = Sockets.path(@user, "relay.lock")
    flock = System.find_executable("flock")
    port = Port.open({:spawn_executable, flock}, [:binary, args: [lock, "sleep", "60"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("pkill", ["-P", "#{pid}"]) end)

    Enum.find_value(1..200, fn _ ->
      case System.cmd(flock, ["--nonblock", lock, "true"], stderr_to_stdout: true) do
        {_, 0} -> Process.sleep(10) && nil
        {_, _held} -> true
      end
    end) || flunk("the lock was never taken")
  end

  # What a command in the VM prints is the VM's to decide (root there puts
  # its own `sh` or `git` on msb exec's PATH): MWT takes a bounded part.
  test "a command printing without end is stopped, and its errors are cut short", %{dir: dir} do
    msb = fake_runtime(dir)
    File.write!(msb, "#!/bin/sh\nyes \"$1\"\n")

    # In a process killed the moment it holds more than 32 MiB.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(32 * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        exit({:done, Msb.run(@user, ["exec", "vm", "--", "git", "status"], 120)})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:done, {:error, message}}}, 30_000
    assert message == "msb exec printed more than 4 MiB, so MWT stopped it"

    File.write!(msb, "#!/bin/sh\nhead -c 1000000 /dev/zero | tr '\\\\0' e\nexit 1\n")
    assert {:error, error} = Msb.run(@user, ["exec", "vm", "--", "sh"], 60)
    assert byte_size(error) <= Msb.error_limit() + 4
    assert String.ends_with?(error, " …")
  end

  test "msb runs on this machine confined: the store, the CA bundle, and no KVM, network or file of yours",
       %{
         dir: dir
       } do
    msb = fake_runtime(dir)
    yours = Path.join(dir, "yours.txt")
    File.write!(yours, "secret")

    File.write!(msb, """
    #!/bin/sh
    [ -e /dev/kvm ] && echo kvm=yes || echo kvm=no
    echo interfaces=$(tail -n +3 /proc/net/dev | wc -l)
    [ -e #{yours} ] && echo yours=seen || echo yours=unseen
    grep '^Seccomp:' /proc/self/status | tr -d ' \t'
    touch "$MSB_HOME/written" && echo store=writable
    grep -q 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt && echo ca=yes || echo ca=no
    echo etc=$(ls -A /etc | tr '\n' ' ')
    """)

    assert {:ok, output} = Msb.run(@user, ["exec", "vm", "--", "true"])
    assert output =~ "kvm=no"
    # Loopback alone: a network namespace of its own.
    assert output =~ "interfaces=1"
    assert output =~ "yours=unseen"
    assert output =~ "Seccomp:2"
    assert output =~ "store=writable"
    assert File.exists?(Path.join(Msb.store(@user), "written"))
    # msb aborts as it starts without a CA certificate, even to load an
    # image: the system's bundle, and nothing else of /etc.
    assert output =~ "ca=yes"
    assert output =~ "etc=ssl\n"

    # A pull has the network, and still no KVM.
    assert {:ok, output} = Msb.run(@user, ["pull", "alpine"])
    assert output =~ "kvm=no"
    refute output =~ "interfaces=1\n"
  end

  test "without a runtime there is no msb, and nothing runs" do
    assert Msb.executable() == nil
    assert Msb.run(@user, ["ls"]) == {:error, "MWT's msb is missing"}
    assert Msb.write_launcher(@user) == {:error, :no_runtime}
    refute File.exists?(Msb.launcher(@user))
    refute List.keymember?(Msb.env(@user), "MSB_PATH", 0)
  end

  test "msb runs from MWT's runtime, in the identity's own home", %{dir: dir} do
    msb = fake_runtime(dir)

    assert Msb.executable() == msb
    assert Msb.store(@user) == Path.join([Accounts.dir(@user), "sandbox", "microsandbox"])
    refute Msb.store(@user) == Msb.store("someone-else")
    # msb keeps Unix sockets under its home, about 60 bytes deeper, and a
    # socket's path must fit in 108: so its home is a short link.
    assert byte_size(Msb.home(@user)) < 48
    assert {:ok, output} = Msb.run(@user, ["ls", "--format", "json"])
    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ls --format json\n"
    assert File.read_link!(Msb.home(@user)) == Msb.store(@user)
  end

  test "upgrading removes legacy VM exports without replacing them or restarting processes", %{
    dir: dir
  } do
    msb = fake_runtime(dir)
    File.write!(msb, ~S(#!/bin/sh
printf '%s\n' "$@" > "$MSB_HOME/cleanup-args"
))

    grant = %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      env: ["GH_TOKEN", "GITHUB_TOKEN"],
      file_env: ["GH_TOKEN_FILE"],
      placeholder: "ghp_placeholder"
    }

    assert :ok = Machine.clear_legacy_env(@user, "existing-vm", [grant])

    assert File.read!(Path.join(Msb.home(@user), "cleanup-args")) ==
             "modify\nexisting-vm\n--next-start\n--env-rm\nGH_TOKEN\n--env-rm\nGITHUB_TOKEN\n--env-rm\nGH_TOKEN_FILE\n"
  end

  test "every start resets the boot minimum after persisted live resizing", %{dir: dir} do
    msb = fake_runtime(dir)
    File.write!(msb, ~S(#!/bin/sh
printf '%s\n' "$@" > "$MSB_HOME/memory-args"
))
    assert {:ok, _} = MWTClient.Sandbox.MemoryControl.prepare(@user, "existing-vm", 24)

    assert File.read!(Path.join(Msb.home(@user), "memory-args")) ==
             "modify\nexisting-vm\n--next-start\n--memory\n4G\n--max-memory\n24G\n"
  end

  test "the store and the folders above it are yours alone, whatever umask made them", %{
    dir: dir
  } do
    fake_runtime(dir)
    store = Msb.store(@user)
    above = [store, Path.dirname(store), Accounts.dir(@user), Path.dirname(Accounts.dir(@user))]

    # As a login umask of 002 leaves them, which msb refuses a store under.
    File.mkdir_p!(store)
    for folder <- above, do: File.chmod!(folder, 0o775)

    Msb.ensure_home!(@user)

    for folder <- [Accounts.root() | above] do
      assert Bitwise.band(File.stat!(folder).mode, 0o777) == 0o700, folder
    end
  end

  test "an SSH entry is told apart when it reaches the VM through something else", %{dir: dir} do
    config = Path.join(dir, "ssh_config")

    Application.put_env(
      :mwt_client,
      Msb,
      Keyword.put(Application.get_env(:mwt_client, Msb), :ssh_config, config)
    )

    entry = fn command ->
      "Host mwt-sandbox\n  User root\n  ProxyCommand #{command} ssh serve vm --stdio\n"
    end

    File.mkdir_p!(dir)

    assert Msb.ssh_entry(@user, "mwt-sandbox") == :missing

    File.write!(config, entry.(Msb.launcher(@user)))
    assert Msb.ssh_entry(@user, "mwt-sandbox") == :ok

    # The launcher of the MWT before 2026-11-13, which ran a shared home.
    File.write!(config, entry.("/home/me/.mwt_client/bin/msb"))

    assert Msb.ssh_entry(@user, "mwt-sandbox") ==
             {:other, "/home/me/.mwt_client/bin/msb ssh serve vm --stdio"}

    # ssh takes the first ProxyCommand it finds for the host.
    File.write!(
      config,
      "Host mwt-sandbox other\n  ProxyCommand=nc x 22\n" <> entry.(Msb.launcher(@user))
    )

    assert Msb.ssh_entry(@user, "mwt-sandbox") == {:other, "nc x 22"}

    File.write!(config, "Host something-else\n  ProxyCommand nc x 22\n")
    assert Msb.ssh_entry(@user, "mwt-sandbox") == :missing
  end

  test "the launcher runs MWT's msb in the identity's home, whatever the caller's environment",
       %{dir: dir} do
    msb = fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok

    assert {output, 0} =
             System.cmd(Msb.launcher(@user), ["ls"],
               env: [{"MSB_HOME", "/home/someone/.microsandbox"}, {"MSB_PATH", "/usr/bin/msb"}]
             )

    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ls\n"
  end

  test "the launcher goes into the VM only while it runs", %{dir: dir} do
    msb = fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    ssh = ["ssh", "serve", "mwt-abc", "--stdio"]

    # msb would boot a stopped VM by itself, outside MWT's bubble.
    assert {output, 1} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)
    assert output =~ "isn't running"

    # A lock file nobody holds is a relay that ended.
    Sockets.ensure!(@user)
    File.write!(Sockets.path(@user, "relay.lock"), "")
    assert {_, 1} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)

    hold_lock()
    assert {output, 0} = System.cmd(Msb.launcher(@user), ssh, stderr_to_stdout: true)
    assert output == "home=#{Msb.home(@user)} path=#{msb} args=ssh serve mwt-abc --stdio\n"
  end

  test "the launcher won't start, stop or change the VM, running or not", %{dir: dir} do
    fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    hold_lock()

    for word <- ~w(start stop create run restart restore rm modify pull load) do
      assert {output, 1} = System.cmd(Msb.launcher(@user), [word, "x"], stderr_to_stdout: true)
      assert output =~ "msb #{word} isn't available here"
    end
  end

  test "the launcher follows the runtime when an update moves it", %{dir: dir} do
    fake_runtime(dir)
    assert Msb.write_launcher(@user) == :ok
    assert Msb.write_launcher(@user) == :ok

    moved = dir <> " moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    config = Application.get_env(:mwt_client, Msb)
    Application.put_env(:mwt_client, Msb, Keyword.put(config, :runtime_dir, moved))
    msb = fake_runtime(moved)
    assert Msb.write_launcher(@user) == :ok

    assert {output, 0} = System.cmd(Msb.launcher(@user), ["--version"])
    assert output =~ "path=#{msb} "
  end
end
