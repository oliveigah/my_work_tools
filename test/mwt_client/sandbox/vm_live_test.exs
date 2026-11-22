defmodule MWTClient.Sandbox.VMLiveTest do
  @moduledoc """
  A real VM in the bubble, with MWT's own proxy, DNS forwarder and agent
  channel on the other side of its sockets: the guarantees that only a VM
  can show. Not part of `mix test`:

      mix test --only vm

  It needs KVM, `bwrap`, MWT's runtime in `priv/microsandbox`
  (`scripts/build-microsandbox.sh`, `scripts/build-relay.sh`; in the agent
  sandbox, with VMs inside the VM on, `scripts/install-runtime.sh`) and the
  internet, for a small Alpine image and for example.com. It makes a
  throwaway identity and removes its VM.
  """
  use ExUnit.Case, async: false

  alias MWTClient.Accounts
  alias MWTClient.Sandbox

  alias MWTClient.Sandbox.{
    Bubble,
    Disks,
    FolderSync,
    Guest,
    Handoff,
    Handoffs,
    Inbox,
    Memory,
    MemoryControl,
    Msb,
    Ports,
    Projects,
    Server,
    ShareMounts,
    Sockets
  }

  alias MWTClient.Sandbox.Monitor.Host
  alias MWTClient.Vault.Store
  alias MWTClient.Sandbox.Server.Machine

  @moduletag :vm
  @moduletag timeout: 600_000

  setup do
    # Other tests keep the runtime away; this one is about it.
    saved = Application.get_env(:mwt_client, Msb)

    Application.put_env(
      :mwt_client,
      Msb,
      Keyword.put(saved, :runtime_dir, Application.app_dir(:mwt_client, "priv/microsandbox"))
    )

    on_exit(fn -> Application.put_env(:mwt_client, Msb, saved) end)

    context = MWTClient.VaultHelpers.unlocked_identity("vm")
    username = context.username
    name = Server.vm_name(username)

    # Whatever the test leaves running ends with it.
    on_exit(fn -> Bubble.stop(username, 60) end)

    dir = Path.join(Accounts.dir(username), "sandbox")
    folders = dir |> Disks.paths() |> Map.put(:optmem, Path.join(dir, "optmem"))
    share = Path.join(System.tmp_dir!(), "vm-share-#{System.unique_integer([:positive])}")
    File.mkdir_p!(share)
    File.write!(Path.join(share, "hello.txt"), "from your machine\n")
    on_exit(fn -> File.rm_rf!(share) end)

    # A git repository in it, with a secret it ignores: never copied.
    app = Path.join(share, "app")
    File.mkdir_p!(app)
    File.write!(Path.join(app, "mix.exs"), "code\n")
    File.write!(Path.join(app, ".env"), "SECRET=1\n")
    {_, 0} = System.cmd("git", ["-C", app, "init", "-q"])

    Map.merge(context, %{name: name, folders: folders, share: share})
  end

  defp machine_pid(name) do
    Enum.find(File.ls!("/proc"), fn entry ->
      with true <- entry =~ ~r/^\d+$/,
           {:ok, raw} <- File.read("/proc/#{entry}/cmdline"),
           [_msb, "machine" | rest] <- String.split(raw, <<0>>) do
        Enum.chunk_every(rest, 2, 1, :discard) |> Enum.member?(["--name", name])
      else
        _ -> false
      end
    end)
  end

  # A memory as memo keeps it: one record of 320 bytes a line.
  defp write_memory(dir, texts) do
    File.mkdir_p!(dir)

    log =
      for {text, id} <- Enum.with_index(texts),
          do: String.pad_trailing("##{id} 2026-11-16 #{text}", 319) <> "\n"

    File.write!(Path.join(dir, "LOG.txt"), Enum.join(log))
  end

  defp events(username, outcome) do
    _ = :sys.get_state(Store.whereis(Server, username))
    for %{outcome: ^outcome} = event <- Sandbox.events(username), do: event
  end

  defp await_memory(exec, predicate, deadline \\ System.monotonic_time(:millisecond) + 45_000) do
    {:ok, text} = exec.("grep -E '^(MemTotal|MemAvailable):' /proc/meminfo")

    values =
      Map.new(
        Regex.scan(~r/^(MemTotal|MemAvailable):\s+(\d+)/m, text),
        fn [_, key, value] -> {key, String.to_integer(value) * 1024} end
      )

    reading = %{total: values["MemTotal"], available: values["MemAvailable"]}

    if predicate.(reading) do
      reading
    else
      assert System.monotonic_time(:millisecond) < deadline, "memory did not converge: #{text}"

      receive do
      after
        100 -> await_memory(exec, predicate, deadline)
      end
    end
  end

  defp resident(username) do
    pid =
      Sockets.host_path(username, "bubble.pid")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    Host.read(pid).rss
  end

  @tag :tmp_dir
  test "memory is returned under host pressure, restored, and remains resizable after restart",
       context do
    %{username: username, name: name, folders: folders, tmp_dir: root} = context
    gib = 1024 * 1024 * 1024
    assert Bubble.available() == :ok
    assert {:ok, _} = Msb.run(username, ["pull", "alpine"], 180)
    :ok = Disks.ensure!(folders, %{home: 1, cache: 1, work: 2, memory: 1})

    bubble = %{
      username: username,
      name: name,
      disks: folders.dir,
      memory_gib: 3,
      memory_min_gib: 1
    }

    args =
      Msb.create_args(%{
        name: name,
        image: "alpine",
        shell: "/bin/sh",
        cpus: 2,
        memory_gib: 3,
        disk_gib: 4,
        env: []
      })

    # A smaller boot floor keeps the real-memory regression inexpensive.
    args = List.replace_at(args, Enum.find_index(args, &(&1 == "--memory")) + 1, "1G")
    exec = fn script -> Msb.run(username, ["exec", name, "--", "sh", "-c", script], 120) end

    assert {:ok, _} = Bubble.start(bubble, args, 180)
    assert {:ok, _} = Bubble.resize_memory(username, 3072)
    await_memory(exec, &(&1.total > 2.8 * gib))

    assert {:ok, _} =
             exec.(
               "mount -o remount,size=2G /dev/shm && dd if=/dev/urandom of=/dev/shm/working bs=1M count=128 && dd if=/dev/zero of=/work/cache-fixture bs=1M count=1280 && sync"
             )

    assert {:ok, checksum} = exec.("sha256sum /dev/shm/working")

    before = resident(username)
    reading = await_memory(exec, &(&1.total > 2.8 * gib))
    File.write!(Path.join(root, "meminfo"), "MemTotal: 33554432 kB\nMemAvailable: 1048576 kB\n")
    assert %{error: nil, target_mib: target} = MemoryControl.balance(username, reading, root)
    assert target <= 1536
    await_memory(exec, &(&1.total < 1.6 * gib))
    after_shrink = resident(username)
    assert before - after_shrink > div(gib, 2), "RSS before=#{before}, after=#{after_shrink}"
    assert {:ok, ^checksum} = exec.("sha256sum /dev/shm/working")

    # Consume some of the retained headroom. Demand must allow regrowth
    # even though the desktop is still below its usual reserve.
    assert {:ok, _} = exec.("dd if=/dev/zero of=/dev/shm/demand bs=1M count=640")
    reading = await_memory(exec, &(&1.total < 1.6 * gib))
    assert reading.available < 384 * 1024 * 1024
    File.write!(Path.join(root, "meminfo"), "MemTotal: 33554432 kB\nMemAvailable: 4194304 kB\n")
    assert %{error: nil, target_mib: 3072} = MemoryControl.balance(username, reading, root)
    await_memory(exec, &(&1.total > 2.8 * gib))

    File.write!(Path.join(root, "meminfo"), "MemTotal: 33554432 kB\nMemAvailable: 10485760 kB\n")
    reading = await_memory(exec, &(&1.total > 2.8 * gib))
    assert %{error: nil, target_mib: 3072} = MemoryControl.balance(username, reading, root)
    await_memory(exec, &(&1.total > 2.8 * gib))

    assert {:ok, _} =
             exec.("dd if=/dev/zero of=/dev/shm/burst bs=1M count=768")

    assert {:ok, ^checksum} = exec.("sha256sum /dev/shm/working")

    assert {:error, _} = Bubble.resize_memory(username, 4096)
    assert {:ok, %{target_mib: 3072}} = Bubble.memory(username)

    IO.puts(
      "memory pressure regression: RSS #{div(before, 1024 * 1024)} -> #{div(after_shrink, 1024 * 1024)} MiB; regrowth and 768 MiB burst passed"
    )

    # Real production geometry: live requests persist, but a new boot must
    # retain the lower floor, rather than inheriting the last large target.
    assert {:ok, _} = Bubble.stop(username, 60)
    assert {:ok, _} = MemoryControl.prepare(username, name, 8)
    bubble = %{bubble | memory_gib: 8, memory_min_gib: 4}
    assert {:ok, _} = Bubble.start(bubble, ["start", name], 120)
    await_memory(exec, &(&1.total > 3.7 * gib and &1.total < 4.1 * gib))
    assert {:ok, _} = Bubble.resize_memory(username, 8192)
    await_memory(exec, &(&1.total > 7.5 * gib))
    assert {:ok, _} = Bubble.stop(username, 60)
    assert {:ok, _} = MemoryControl.prepare(username, name, 8)
    assert {:ok, _} = Bubble.start(bubble, ["start", name], 120)
    await_memory(exec, &(&1.total > 3.7 * gib and &1.total < 4.1 * gib))

    assert {:ok, %{minimum_mib: 4096, maximum_mib: 8192, target_mib: 4096}} =
             Bubble.memory(username)
  end

  test "a VM in the bubble: confined, reached only through MWT, its disks kept", context do
    %{username: username, name: name, folders: folders, share: share} = context
    assert Bubble.available() == :ok
    assert Bubble.relay(), "build the relay first: scripts/build-relay.sh"

    assert {:ok, _} = Msb.run(username, ["pull", "alpine"], 180)
    :ok = Disks.ensure!(folders, %{home: 1, cache: 1, work: 2, memory: 1})

    {:ok, token} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Download credential",
        "purpose" => "Exercise credential scoping",
        "hosts" => "api.github.com",
        "env" => "GITHUB_TOKEN",
        "prefix" => "ghp_",
        "source" => "stored",
        "value" => "unused-test-value"
      })

    bubble = %{username: username, name: name, disks: folders.dir}

    create =
      Msb.create_args(%{
        name: name,
        image: "alpine",
        shell: "/bin/sh",
        cpus: 2,
        memory_gib: 1,
        disk_gib: 4,
        # An older MWT installed every token on the VM, even while off.
        env: [{"MWT_TEST", "placeholder"}, {"GITHUB_TOKEN", token.placeholder}]
      })

    exec = fn script -> Msb.run(username, ["exec", name, "--", "sh", "-c", script], 120) end

    ## Created and started by the relay, in the bubble

    assert {:ok, _} = Bubble.start(bubble, create, 180)
    assert Bubble.status(username) == :running
    assert {:error, "The VM's bubble is already running."} = Bubble.start(bubble, create, 5)

    ## The bubble, from this machine: every process in it (the relay, msb,
    ## the VM's own) under the seccomp filter (`seccomp_test.exs` says what
    ## it refuses; `Bubble`'s test tries it).

    relay = Sockets.host_path(username, "bubble.pid") |> File.read!() |> String.trim()

    {children, 0} = System.cmd("pgrep", ["-P", relay])
    bubbled = [relay | String.split(children, "\n", trim: true)]
    {all, 0} = System.cmd("ps", ["-o", "pid=", "--ppid", Enum.join(bubbled, ",")])
    processes = Enum.uniq(bubbled ++ String.split(all))
    names = Enum.map(processes, &String.trim(File.read!("/proc/#{&1}/comm")))
    assert "mwt-relay" in names and "libkrun VM" in names, inspect(names)

    # bwrap itself loads the filter for what it starts, and isn't under it.
    for pid <- processes,
        String.trim(File.read!("/proc/#{pid}/comm")) != "bwrap",
        status = File.read!("/proc/#{pid}/status") do
      assert status =~ ~r/^Seccomp:\s+2$/m, "process #{pid} has no seccomp filter"
      assert status =~ ~r/^NoNewPrivs:\s+1$/m
    end

    ## Reached over SSH, as Zed and the port forwarding reach it: through
    ## the launcher, which authorizes the key and serves SSH with msb
    ## confined.

    assert :ok = Msb.write_launcher(username)
    Sockets.ensure_host!(username)
    key = Path.join(System.tmp_dir!(), "mwt-forward-key-#{System.unique_integer([:positive])}")
    on_exit(fn -> Enum.each([key, key <> ".pub"], &File.rm/1) end)

    assert {:ok, tunnel} =
             MWTClient.Sandbox.Forwarder.SSH.open(%{
               launcher: Msb.launcher(username),
               vm: name,
               key: key,
               control: Sockets.host_path(username, "forward-test.sock")
             })

    assert {:ok, _} =
             exec.(
               "setsid sh -c 'echo forwarded | nc -l -p 4105' >/dev/null 2>&1 </dev/null & sleep 0.5"
             )

    address = MWTClient.Sandbox.Ports.address(Accounts.id(username))
    assert :ok = MWTClient.Sandbox.Forwarder.SSH.forward(tunnel, address, 4105, "127.0.0.1")

    assert {:ok, socket} =
             :gen_tcp.connect(String.to_charlist(address), 4105, [:binary, active: false], 5_000)

    assert {:ok, "forwarded\n"} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    MWTClient.Sandbox.Forwarder.SSH.close(tunnel)

    ## What the VM is made of

    assert {:ok, mounts} = exec.("mount | awk '{print $3, $5}' | sort")
    mounts = String.split(mounts, "\n", trim: true)

    for expected <- ["/root ext4", "/cache ext4", "/work ext4", "/root/.optmem ext4"] do
      assert expected in mounts, "#{expected} is missing from:\n#{Enum.join(mounts, "\n")}"
    end

    # No folder of this machine is mounted: shared folders and MWT's files
    # are copied in, and the memory is a disk.
    refute Enum.any?(mounts, &String.starts_with?(&1, share)), Enum.join(mounts, "\n")
    refute Enum.any?(mounts, &String.starts_with?(&1, "/mnt/mwt ")), Enum.join(mounts, "\n")

    ## MWT's files, copied in at a start: a folder in the VM's memory

    # Before anything reads it, and with nothing but busybox: plain tar.
    sync_dir = Path.join(Accounts.dir(username), "sandbox")
    inbox_dir = Sandbox.snapshot(username).inbox

    copy_inbox = fn record, opts ->
      record = Inbox.into_vm(record, username, name, sync_dir, opts)
      assert record.status.error == nil
      record
    end

    _ = copy_inbox.(Inbox.record(inbox_dir, "vm-live"), fresh: true)
    assert {:ok, "tmpfs\n"} = exec.("stat -f -c %T /mnt/mwt")

    assert {:ok, "ok\n"} =
             exec.("test -s /mnt/mwt/ca-bundle.pem && test -x /mnt/mwt/bin/mwt && echo ok")

    assert {:ok, "placeholder\n"} = exec.("echo $MWT_TEST")
    assert {:ok, "legacy\n"} = exec.("test -n \"$GITHUB_TOKEN\" && echo legacy")

    ## Guarantee 11: the process running the VM

    pid = machine_pid(name)
    assert pid, "no msb machine process for #{name}"

    for namespace <- ~w(user mnt net pid ipc uts cgroup) do
      refute File.read_link!("/proc/#{pid}/ns/#{namespace}") ==
               File.read_link!("/proc/self/ns/#{namespace}"),
             "the VM's process shares this machine's #{namespace} namespace"
    end

    root = File.ls!("/proc/#{pid}/root")
    refute "home" in root
    refute "etc" in root
    assert File.ls!("/proc/#{pid}/root/run") == []

    cards =
      File.read!("/proc/#{pid}/net/dev")
      |> String.split("\n", trim: true)
      |> Enum.drop(2)
      |> Enum.map(&(&1 |> String.split(":") |> hd() |> String.trim()))

    assert cards == ["lo"]
    status = File.read!("/proc/#{pid}/status")
    assert status =~ ~r/^NoNewPrivs:\s+1$/m
    assert status =~ ~r/^CapEff:\s+0+$/m
    assert status =~ ~r/^CapBnd:\s+0+$/m

    ## Guarantees 6 and 12: out only through MWT, DNS included

    assert {:ok, "<!doctype html>"} = exec.("wget -q -T 30 -O - http://example.com/ | head -c 15")
    assert [%{port: 80} | _] = events(username, :tunnel)
    assert "example.com" in Enum.map(events(username, :lookup), & &1.host)

    assert {:ok, elsewhere} =
             exec.("nslookup -type=a example.org 8.8.8.8 2>&1 | tail -2; echo done")

    refute elsewhere =~ "Address"
    refute "example.org" in Enum.map(events(username, :lookup), & &1.host)

    ## The agent channel and the boot script, with tools fetched through MWT

    # bash and socat for the `mwt` command, python3 for memo: Alpine has none.
    assert {:ok, _} =
             exec.(
               "apk add --no-cache bash socat python3 >/dev/null 2>&1; bash --version | head -1"
             )

    ## A shared folder, copied in: one way, its repository left out

    # GNU find, stat and tar for the copy's side; MWT's image has them.
    assert {:ok, _} =
             exec.("apk add --no-cache findutils coreutils tar >/dev/null 2>&1; echo ok")

    # Its store on the work disk, shown read-only at the same path.
    guest = Guest.vm(username, name)
    later = [now: System.os_time(:second) + 10]
    assert :ok = ShareMounts.arrange(guest, [share])
    # Again: what is shown already stays as it is.
    assert :ok = ShareMounts.arrange(guest, [share])
    record = FolderSync.sync(FolderSync.new(share, "vm-live"), guest, sync_dir, later)

    assert record.status.error == nil
    assert record.status.trees == ["app"]
    assert {:ok, "from your machine\n"} = exec.("cat #{share}/hello.txt")
    assert {:ok, "hello.txt\n"} = exec.("ls -A #{share}")
    assert {:ok, gone} = exec.("cat #{share}/app/.env 2>&1; true")
    assert gone =~ "No such file or directory"
    store = ShareMounts.store(share)
    assert {:ok, "from your machine\n"} = exec.("cat #{store}/hello.txt")

    # Read-only in the VM, even for root: an edit fails instead of being
    # lost at the next sync, and nothing reaches your folder.
    assert {:ok, mounts} = exec.("grep ' #{share} ' /proc/mounts")
    assert mounts =~ ~r/\sro[,\s]/
    assert {:ok, refused} = exec.("(echo 'the VM wrote this' > #{share}/hello.txt) 2>&1; true")
    assert refused =~ "Read-only file system"
    assert {:ok, refused} = exec.("touch #{share}/planted 2>&1; true")
    assert refused =~ "Read-only file system"

    # Yours reaches the copy when synced, and only then.
    File.write!(Path.join(share, "hello.txt"), "changed on your machine\n")
    File.write!(Path.join(share, "new.txt"), "new\n")
    assert {:ok, "from your machine\n"} = exec.("cat #{share}/hello.txt")
    record = FolderSync.sync(record, guest, sync_dir, later)

    assert record.status.error == nil
    assert {record.status.sent, record.status.removed} == {2, 0}
    assert {:ok, "changed on your machine\n"} = exec.("cat #{share}/hello.txt")
    assert {:ok, "new\n"} = exec.("cat #{share}/new.txt")

    # No longer shared: unmounted, its store gone.
    assert :ok = ShareMounts.arrange(guest, [])
    assert {:ok, "gone\n"} = exec.("test -e #{share}/hello.txt || echo gone")
    assert {:ok, "gone\n"} = exec.("test -e #{Path.dirname(store)} || echo gone")

    # The built-in command grant is still off.
    assert {:ok, grants} = exec.("/mnt/mwt/bin/mwt grants")
    assert grants =~ "id: `commands` · Ask to run commands · off"

    ## Credential migration and scope in an actual running VM

    assert :ok = Machine.clear_legacy_env(username, name, [token])
    assert Bubble.status(username) == :running
    # Environment changes are staged without killing any process.
    assert {:ok, _} = Bubble.stop(username)
    assert {:ok, _} = Bubble.start(bubble, ["start", name], 180)
    assert {:ok, "anonymous\n"} = exec.("test -z \"${GITHUB_TOKEN+x}\" && echo anonymous")

    # A start begins without MWT's files: they are copied in again.
    assert {:ok, "gone\n"} = exec.("test -e /mnt/mwt/bin/mwt || echo gone")
    inbox = copy_inbox.(Inbox.record(inbox_dir, "vm-live"), fresh: true)
    assert {:ok, off} = exec.("cat /mnt/mwt/grant-env/#{token.id}.sh")
    assert off =~ "this token grant is off"

    # A change reaches the copy at the next look: each changed file replaced
    # whole, by a rename.
    assert {:ok, _} = Sandbox.turn_on(username, token.id, 60)
    inbox = copy_inbox.(inbox, [])
    assert inbox.status.error == nil
    assert {:ok, "gone\n"} = exec.("test -e /mnt/mwt/.mwt-incoming || echo gone")

    assert {:ok, "anonymous\n"} =
             exec.(
               "BASH_ENV=/mnt/mwt/profile.sh bash -c 'test -z \"${GITHUB_TOKEN+x}\" && echo anonymous'"
             )

    assert {:ok, "scoped\n"} =
             exec.(
               "/mnt/mwt/bin/mwt exec #{token.id} -- bash -c 'test \"$GITHUB_TOKEN\" = \"$(cat /mnt/mwt/tokens/#{token.id})\" && echo scoped'"
             )

    # The same automatic token attachment Zed uses, with normal VM defaults.
    assert {:ok, "200\n"} =
             exec.(~S"""
             python3 - <<'PY'
             import os, ssl, urllib.request
             req = urllib.request.Request('https://api.github.com/repos/expert-lsp/expert/releases')
             if 'GITHUB_TOKEN' in os.environ:
                 req.add_header('Authorization', 'Bearer ' + os.environ['GITHUB_TOKEN'])
             context = ssl.create_default_context(cafile='/mnt/mwt/ca-bundle.pem')
             with urllib.request.urlopen(req, context=context, timeout=30) as response:
                 print(response.status)
             PY
             """)

    assert {:ok, ""} = Msb.run(username, ["exec", name, "--", "/mnt/mwt/bin/mwt-boot"], 60)
    assert {:ok, block} = exec.("head -1 /root/.claude/CLAUDE.md; head -1 /root/.codex/AGENTS.md")
    assert block =~ ~r/\A<!-- mwt:begin.*\n<!-- mwt:begin/

    ## The VM's memory: its own disk, reached through the VM

    if Memory.host_memo() do
      assert {:ok, "ok\n"} = exec.("test -x /root/.optmem/memo && echo ok")
    end

    # A VM made before 2026-11-16 kept it in a folder here: it moves onto
    # the disk, once, and the folder is kept aside.
    write_memory(Path.join(folders.optmem, "memory"), ["kept here"])
    assert Memory.move_in(guest, folders.optmem) == :moved
    assert {:ok, %{entries: [%{text: "kept here"}], upto: 1, size: 320}} = Memory.fetch(guest, 0)
    assert Memory.move_in(guest, folders.optmem) == :none

    # Yours replaces it under memo's lock there, unless it noted more since.
    mine = Path.join(System.tmp_dir!(), "vm-mine-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(mine) end)
    write_memory(mine, ["one of mine", "another of mine"])
    assert {:error, :moved_on} = Memory.seed(guest, 0, mine)
    assert {:ok, 2} = Memory.seed(guest, 320, mine)

    assert {:ok, %{entries: [_, %{text: "another of mine"}], upto: 2}} =
             Memory.fetch(guest, 0)

    assert {:ok, aside} = exec.("cat /root/.optmem/memory.before-*/LOG.txt")
    assert aside =~ "kept here"

    ## A project: its clone, a task in a slot, a handoff back, through msb's pipe

    # Your projects folder, shared read-only in the settings: every
    # repository in it is a project.
    projects = Path.join(System.tmp_dir!(), "vm-projects-#{System.unique_integer([:positive])}")
    repo = Path.join(projects, "app")
    on_exit(fn -> File.rm_rf!(projects) end)
    File.mkdir_p!(repo)
    project = Path.basename(repo)
    {:ok, _} = Sandbox.add_share(username, projects)

    git = fn dir, args ->
      {out, 0} =
        System.cmd(
          "git",
          ["-C", dir, "-c", "user.name=Me", "-c", "user.email=me@example.test" | args],
          stderr_to_stdout: true
        )

      out
    end

    git.(repo, ["init", "-q", "-b", "master"])
    # Yours: a merge commit is made in your name.
    git.(repo, ["config", "user.name", "Me"])
    git.(repo, ["config", "user.email", "me@example.test"])
    File.write!(Path.join(repo, "a.txt"), "from your machine\n")
    git.(repo, ["add", "--all"])
    git.(repo, ["commit", "-q", "-m", "first"])

    # The sandbox doesn't run this VM, so it is named to it.
    MWTClient.StandIns.put_guest(username, Guest.vm(username, name))

    assert {:ok, _} = exec.("apk add --no-cache git >/dev/null 2>&1; git --version")
    assert {:ok, _project} = Projects.open(username, repo)
    assert {:ok, "slot-1"} = Projects.add_slot(username, project)
    assert {:ok, "from your machine\n"} = exec.("cat /work/#{project}/a.txt")
    assert {:ok, "master\n"} = exec.("git -C /work/#{project} branch --show-current")

    assert {:ok, "mwt::" <> _} =
             exec.("git -C /work/#{project} config --get remote.host-origin.url")

    # A task in a worktree slot, from a thread there, a commit, a handoff.
    tree = "/work/#{project}.wt/slot-1"

    assert {:ok, _, %{path: ^tree}, :started, "master", {:worktree, ^tree}} =
             Projects.take_slot(username, tree, :new, "fix", from: "master")

    # Commits in the VM are yours: the name and email your repository uses.
    assert {:ok, "Me me@example.test\n"} =
             exec.("""
             cd #{tree} && echo 'from the vm' >> a.txt && echo new > b.txt && git add --all &&
             git commit -q -m 'the fix' && git log -1 --format='%an %ae'
             """)

    refs = git.(repo, ["for-each-ref"])

    assert {:ok, %Handoff{onto: "master", stats: %{commits: 1, files: 2}} = handoff, :opened} =
             Handoffs.open(username, %{cwd: tree, title: "The fix", agent: "test"})

    assert git.(repo, ["for-each-ref"]) == refs

    head = git.(repo, ["rev-parse", "HEAD"])
    assert {:ok, landed} = Handoffs.accept(username, handoff.id, {:branch, "master", "fix"})
    assert landed.accepted.branch == "mwt/fix"
    assert File.read!(Path.join(repo, "a.txt")) == "from your machine\n"

    assert git.(repo, ["show", landed.accepted.branch <> ":a.txt"]) ==
             "from your machine\nfrom the vm\n"

    assert git.(repo, ["status", "--porcelain"]) == ""
    assert {:ok, _} = Handoffs.undo(username, handoff.id)
    assert git.(repo, ["rev-parse", "HEAD"]) == head

    # The clone is the VM's: what the VM plants in it runs there, never
    # here, through a revision and a landing.
    assert {:ok, _} =
             exec.("""
             cd /work/#{project} &&
             printf '#!/bin/sh\\ntouch /tmp/planted-hook-ran\\n' > .git/hooks/reference-transaction &&
             chmod +x .git/hooks/reference-transaction &&
             git config core.fsmonitor 'touch /tmp/planted-fsmonitor-ran; false' &&
             cd #{tree} && echo more >> b.txt && git commit -q -am more
             """)

    File.rm("/tmp/planted-hook-ran")
    File.rm("/tmp/planted-fsmonitor-ran")

    assert {:ok, %Handoff{revision: 2, status: :open}, :updated} =
             Handoffs.open(username, %{cwd: tree, agent: "test"})

    # Your master moved since: it lands as one commit on top, untested
    # with it.
    File.write!(Path.join(repo, "c.txt"), "yours\n")
    git.(repo, ["add", "--all"])
    git.(repo, ["commit", "-q", "-m", "second"])

    assert {:ok, %{behind: 1, conflicts: [], as: :one_commit}} =
             Handoffs.preview(username, handoff.id, {:commit, "master"})

    assert {:ok, landed} = Handoffs.accept(username, handoff.id, {:branch, "master", "fix"})
    assert landed.accepted.how == :commit
    refute File.exists?(Path.join(repo, "b.txt"))
    assert git.(repo, ["show", landed.accepted.branch <> ":b.txt"]) == "new\nmore\n"
    refute File.exists?("/tmp/planted-hook-ran")
    refute File.exists?("/tmp/planted-fsmonitor-ran")
    assert {:ok, "ran in the vm\n"} = exec.("test -e /tmp/planted-hook-ran && echo ran in the vm")
    MWTClient.StandIns.remove_guest(username)

    ## The disks across a stop, a start and a recreate

    assert {:ok, _} =
             exec.("echo work > /work/marker; echo home > /root/marker; echo root > /var/marker")

    assert {:ok, stopped} = Bubble.stop(username)
    assert stopped =~ "Stopped"
    assert Bubble.status(username) == :down
    assert machine_pid(name) == nil

    # msb boots a stopped VM by itself on `start` and `exec`. Outside the
    # bubble it can't: the VM's disks aren't there.
    assert {:error, _} = Msb.run(username, ["start", name], 60)
    assert {:error, _} = exec.("echo booted")
    assert machine_pid(name) == nil

    assert {:ok, _} = Bubble.start(bubble, ["start", name], 180)
    assert {:ok, "work\nhome\nroot\n"} = exec.("cat /work/marker /root/marker /var/marker")

    assert {:ok, _} = Bubble.stop(username)
    assert {:ok, _} = Bubble.start(bubble, create, 180)
    # A recreate keeps the three disks and starts the root disk empty.
    assert {:ok, "work\nhome\nthe root disk is new\n"} =
             exec.(
               "cat /work/marker /root/marker; test -e /var/marker || echo the root disk is new"
             )

    ## Guarantee 6: a locked MWT leaves the VM without internet

    :ok = Store.close(username)
    assert Bubble.status(username) == :running

    assert {:ok, offline} =
             exec.("wget -q -T 8 -O - http://example.com/ 2>&1 | head -c 60; echo; echo done")

    refute offline =~ "<!doctype"

    assert {:ok, _} = Bubble.stop(username)
    assert machine_pid(name) == nil
  end

  # The same VM, driven the way the pages drive it: through the sandbox of
  # an unlocked identity, which the other tests keep away from microsandbox.
  defp wait_vm(username, wanted) do
    Enum.find_value(1..1_200, fn _ ->
      vm = Sandbox.snapshot(username).vm

      cond do
        vm.busy -> Process.sleep(100) && nil
        vm.error -> flunk("the VM reported: #{vm.error}")
        vm.status == wanted -> vm
        true -> Process.sleep(100) && nil
      end
    end) || flunk("the VM never became #{wanted}")
  end

  defp pause_shared_copy(%{username: username, name: name, share: share}, server) do
    parent = self()
    guest = Guest.vm(username, name)

    guest = %{
      guest
      | stream: fn words ->
          unless Process.get(:copy_released) do
            send(parent, {:copy_paused, self()})

            receive do
              :continue -> Process.put(:copy_released, true)
            end
          end

          guest.stream.(words)
        end
    }

    :sys.replace_state(server, fn state ->
      vm = state.vm_record.id
      started_at = state.vm.started_at
      dir = state.dir

      Server.State.task(state, :sync, fn ->
        FolderSync.sync_all(%{share => FolderSync.new(share, vm)}, [share], guest, dir)
        |> Map.merge(%{vm: vm, started_at: started_at})
      end)
    end)

    assert_receive {:copy_paused, worker}, 5_000
    on_exit(fn -> send(worker, :continue) end)
    worker
  end

  defp wait_copy_drain(username, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
    if Sandbox.snapshot(username).vm.busy == "Finishing file copies…" do
      :ok
    else
      receive do
        {:sandbox_changed, :vm} -> wait_copy_drain(username, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("the VM never waited for its file copies")
      end
    end
  end

  defp wait_share_copy(username, path, deadline \\ System.monotonic_time(:millisecond) + 60_000) do
    case Sandbox.snapshot(username).sync[path] do
      %{status: %{files: 1, error: nil} = status} ->
        status

      _ ->
        receive do
          {:sandbox_changed, :sync} -> wait_share_copy(username, path, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk("the shared folder was never copied")
        end
    end
  end

  test "the sandbox creates, stops, starts and recreates its VM, and stops it when you lock",
       context do
    %{username: username, key: key, name: name} = context
    saved = Application.get_env(:mwt_client, Server)
    on_exit(fn -> Application.put_env(:mwt_client, Server, saved) end)

    # This identity's sandbox, started again as it runs outside the tests.
    :ok = Store.close(username)
    Application.put_env(:mwt_client, Server, Keyword.put(saved, :external, true))
    :ok = Store.open(username, key)

    assert Sandbox.snapshot(username).tools.needs == []
    assert {:ok, _} = Msb.run(username, ["pull", "alpine"], 180)
    server = Store.whereis(Server, username)
    :sys.replace_state(server, &%{&1 | image: %{&1.image | tag: "alpine", loaded?: true}})
    exec = fn script -> Msb.run(username, ["exec", name, "--", "sh", "-c", script], 120) end

    {:ok, token} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Scoped GitHub",
        "purpose" => "Test fresh VM defaults",
        "hosts" => "api.github.com",
        "env" => "GITHUB_TOKEN",
        "prefix" => "ghp_",
        "source" => "stored",
        "value" => "unused-test-value"
      })

    {:ok, _} = Sandbox.turn_on(username, token.id, 60)

    assert :ok = Sandbox.start_vm(username)
    assert %{exists?: true, record: %{id: first}} = wait_vm(username, :running)
    assert Bubble.status(username) == :running
    assert {:ok, "anonymous\n"} = exec.("test -z \"${GITHUB_TOKEN+x}\" && echo anonymous")
    # The VM knows which it is.
    assert {:ok, "id=" <> rest} = exec.("cat /etc/mwt-vm")
    assert String.starts_with?(rest, first <> "\n")
    assert {:ok, "ext4\n"} = exec.("stat -f -c %T /work | sed 's#ext2/ext3#ext4#'")
    assert {:ok, _} = exec.("echo mine > /work/marker; echo mine > /root/marker")

    Phoenix.PubSub.subscribe(MWTClient.PubSub, Server.State.topic(username))
    copy = pause_shared_copy(context, server)
    copy_ref = Process.monitor(copy)
    assert :ok = Sandbox.stop_vm(username)
    wait_copy_drain(username)
    assert Bubble.status(username) == :down
    assert Sandbox.start_vm(username) == {:error, :busy}
    send(copy, :continue)
    assert_receive {:DOWN, ^copy_ref, :process, ^copy, :normal}, 15_000
    wait_vm(username, :stopped)
    assert Bubble.status(username) == :down

    assert :ok = Sandbox.start_vm(username)
    wait_vm(username, :running)
    assert {:ok, "mine\nmine\n"} = exec.("cat /work/marker /root/marker")

    assert {:ok, "no stale copy\n"} =
             exec.("test ! -e #{context.share} && echo 'no stale copy'")

    # Home started empty; Work is never emptied; the Home it had is kept.
    copy = pause_shared_copy(context, server)
    copy_ref = Process.monitor(copy)
    assert :ok = Sandbox.recreate_vm(username, %{home: :empty})
    wait_copy_drain(username)
    assert Bubble.status(username) == :down
    assert Sandbox.snapshot(username).vm.record.id == first
    send(copy, :continue)
    assert_receive {:DOWN, ^copy_ref, :process, ^copy, :normal}, 15_000
    wait_vm(username, :running)

    assert {:ok, "no stale copy\n"} =
             exec.("test ! -e #{context.share} && echo 'no stale copy'")

    assert {:ok, "mine\nhome is new\n"} =
             exec.("cat /work/marker; test -e /root/marker || echo home is new")

    # A new VM, a new record, in MWT and in the VM.
    assert %{record: %{id: second}} = Sandbox.snapshot(username).vm
    assert second != first
    assert {:ok, "id=" <> ^second <> _} = exec.("cat /etc/mwt-vm")

    assert [%{id: _}] = Sandbox.snapshot(username).snapshots

    # A project, the agent's side done by the real `mwt` command in the VM.
    projects = Path.join(System.tmp_dir!(), "vm-flow-#{System.unique_integer([:positive])}")
    repo = Path.join(projects, "flow")
    on_exit(fn -> File.rm_rf!(projects) end)
    File.mkdir_p!(repo)
    project = Path.basename(repo)
    {:ok, _} = Sandbox.add_share(username, projects)

    git = fn args ->
      {out, 0} =
        System.cmd(
          "git",
          ["-C", repo, "-c", "user.name=Me", "-c", "user.email=me@example.test" | args],
          stderr_to_stdout: true
        )

      out
    end

    git.(["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "yours\n")
    git.(["add", "--all"])
    git.(["commit", "-q", "-m", "first"])
    # Who you commit as: a landing's commit is yours.
    git.(["config", "user.name", "Me"])
    git.(["config", "user.email", "me@example.test"])

    assert {:ok, _} =
             exec.(
               "apk add --no-cache git bash socat findutils coreutils tar python3 && git --version"
             )

    # The rest of the shared folder is copied in when synced; the
    # repository is not.
    File.write!(Path.join(projects, "README.txt"), "beside the repositories\n")
    assert :ok = Sandbox.sync_shares(username, [projects])

    assert %{files: 1, trees: ["flow"], error: nil} = wait_share_copy(username, projects)

    assert {:ok, "README.txt\n"} = exec.("ls -A #{projects}")
    assert {:ok, "beside the repositories\n"} = exec.("cat #{projects}/README.txt")

    # The VM's memory synced as the pages do it: what it noted since, then
    # yours copied in, while it runs. Yours is a test one here.
    if Memory.host_memo() do
      mine = Path.join(System.tmp_dir!(), "vm-mine-#{System.unique_integer([:positive])}")
      write_memory(mine, ["one of mine"])
      System.put_env("MEMORY_DIR", mine)

      on_exit(fn ->
        System.delete_env("MEMORY_DIR")
        File.rm_rf!(mine)
      end)

      assert {:ok, %{size: size}} = Sandbox.vm_memories(username)
      assert :ok = Sandbox.seed_memory(username, size)
      wait_vm(username, :running)
      assert %{seed_count: 1, reviewed: 1} = Sandbox.snapshot(username).memory
      assert {:ok, %{entries: [], upto: 1}} = Sandbox.vm_memories(username)
      assert {:ok, "1\n"} = exec.("grep -c 'one of mine' /root/.optmem/memory/LOG.txt")
    end

    # `mwt vm`, and the line an interactive login shell prints.
    assert {:ok, said} = exec.("/mnt/mwt/bin/mwt vm")
    assert said =~ "This is the VM MWT runs" and said =~ "vm #{second}"
    assert {:ok, login} = exec.("bash -lic true 2>&1")
    assert login =~ "This is the VM MWT runs"

    assert {:ok, _} = Projects.open(username, repo)
    # The clone is slot-0, free on its own master; one more slot beside it.
    assert {:ok, "slot-1"} = Projects.add_slot(username, project)
    assert {:ok, here} = exec.("cd /work/#{project} && /mnt/mwt/bin/mwt project")

    assert here =~
             "You are in slot-0 (the clone itself), /work/#{project}, which is free, on master."

    assert here =~ "slot-1  free  (open: zed ssh://mwt-sandbox/work/#{project}.wt/slot-1)\n"
    refute here =~ "slot-2"
    assert {:ok, ""} = exec.("git -C /work/#{project}.wt/slot-1 branch --show-current")

    # The clone fetches your branches through MWT, over the VM's channel; a
    # push is refused.
    assert {:ok, fetched} =
             exec.(
               "cd /work/#{project} && PATH=/mnt/mwt/bin:$PATH git fetch host-origin 2>&1 && git branch -r"
             )

    assert fetched =~ "host-origin/master"

    assert {:error, pushed} =
             exec.(
               "cd /work/#{project} && PATH=/mnt/mwt/bin:$PATH git push host-origin HEAD:refs/heads/elsewhere 2>&1"
             )

    assert pushed =~ "use mwt handoff"
    refute git.(["branch", "--list", "elsewhere"]) =~ "elsewhere"

    # A new task names the branch it is based on: the agent asks you.
    assert {:error, unnamed} =
             exec.(
               "cd /work/#{project}.wt/slot-1 && /mnt/mwt/bin/mwt worktree new serve-hello 2>&1"
             )

    assert unnamed =~ "--from BRANCH" and unnamed =~ "Their branches: master"

    assert {:ok, made} =
             exec.(
               "cd /work/#{project}.wt/slot-1 && /mnt/mwt/bin/mwt worktree new serve-hello --from master"
             )

    assert made =~ "Started the task serve-hello in slot-1" and made =~ "continue here"

    # A server the agent starts in its slot on a port of the range opens
    # here, at the VM's address: the watcher the boot script starts says it
    # listens, and MWT forwards it through msb's SSH server. One just outside
    # the range stays in the VM, unlisted. Alpine has no `ss` until iproute2,
    # and its httpd is in busybox-extras.
    assert {:ok, _} =
             exec.("apk add --no-cache iproute2 busybox-extras >/dev/null 2>&1; ss -V")

    assert {_status, _boot} = exec.("/mnt/mwt/bin/mwt-boot; echo done")
    www = "/work/#{project}.wt/slot-1/www"

    assert {:ok, _} =
             exec.(
               "mkdir -p #{www} && echo 'from the vm' > #{www}/hello.txt && " <>
                 "cd #{www} && httpd -p 127.0.0.1:4155 -h #{www} && httpd -p 127.0.0.1:4099 -h #{www}"
             )

    address = Ports.address(Accounts.id(username))

    entry =
      Enum.find_value(1..300, fn _ ->
        ports = Sandbox.snapshot(username).ports

        case Enum.find(ports.ports, &(&1.port == 4155 and &1.status == :forwarded)) do
          nil -> Process.sleep(100) && nil
          entry -> entry
        end
      end) || flunk("4155 was never forwarded: #{inspect(Sandbox.snapshot(username).ports)}")

    assert Ports.slot(entry.cwd) == {project, "slot-1"}
    assert {:ok, outside} = exec.("ss -ltnH 'sport = :4099'")
    assert outside =~ "127.0.0.1:4099"
    refute Enum.any?(Sandbox.snapshot(username).ports.ports, &(&1.port == 4099))

    assert {:ok, %{status: 200, body: "from the vm\n"}} =
             Req.get("http://#{address}:4155/hello.txt", retry: false)

    assert {:ok, listed} = exec.("/mnt/mwt/bin/mwt ports")
    assert listed =~ "- 4155: http://#{address}:4155 (httpd, slot-1 of #{project})"
    refute listed =~ "4099"

    # It stops, and its forward goes with it.
    assert {:ok, _} = exec.("pkill -x httpd; rm -rf #{www}; true")

    assert Enum.find_value(1..300, fn _ ->
             ports = Sandbox.snapshot(username).ports.ports
             (not Enum.any?(ports, &(&1.port == 4155)) and :gone) || (Process.sleep(100) && nil)
           end)

    assert {:error, _} = Req.get("http://#{address}:4155/hello.txt", retry: false)

    assert {:ok, handed} =
             exec.("""
             cd /work/#{project}.wt/slot-1 && echo 'the vm' >> a.txt &&
             /mnt/mwt/bin/mwt handoff --title 'The task' && /mnt/mwt/bin/mwt handoffs
             """)

    assert handed =~ "Handed off as #1" and handed =~ "open, waiting for the user (this branch)"

    assert [%Handoff{id: id, title: "The task", source: %{branch: "serve-hello"}, status: :open}] =
             Sandbox.snapshot(username).waiting_handoffs

    # It lands as it is: the commit mwt handoff made in the VM, as you.
    assert {:ok, %Handoff{status: :accepted, head: head, accepted: %{how: :as_is}}} =
             Handoffs.accept(username, id, {:branch, "master", "serve-hello"})

    assert File.read!(Path.join(repo, "a.txt")) == "yours\n"
    assert git.(["status", "--porcelain"]) == ""
    assert git.(["show", "mwt/serve-hello:a.txt"]) == "yours\nthe vm\n"
    assert git.(["log", "-1", "--format=%s %an", "mwt/serve-hello"]) == "The task Me\n"
    assert git.(["rev-parse", "mwt/serve-hello"]) == head <> "\n"

    # Landed, its slot is free: the next task takes it, through the real
    # mwt, and a freed slot goes off its branch.
    assert {:ok, next} =
             exec.(
               "cd /work/#{project}.wt/slot-1 && /mnt/mwt/bin/mwt worktree new next --from mwt/serve-hello"
             )

    assert next =~ "Started the task next in slot-1" and next =~ "continue here"

    # A task based on the landed branch lands on it again, through the real CLI.
    assert {:ok, continued} =
             exec.("""
             cd /work/#{project}.wt/slot-1 && echo 'continued' >> a.txt &&
             /mnt/mwt/bin/mwt handoff --title 'Continue the task'
             """)

    assert continued =~ "Handed off as #2"
    assert {:ok, continued_handoff} = Handoffs.accept(username, 2)
    assert continued_handoff.accepted.branch == "mwt/serve-hello"
    assert git.(["show", "mwt/serve-hello:a.txt"]) == "yours\nthe vm\ncontinued\n"
    assert File.read!(Path.join(repo, "a.txt")) == "yours\n"

    assert {:ok, freed} =
             exec.("cd /work/#{project}.wt/slot-1 && /mnt/mwt/bin/mwt worktree free")

    assert freed =~ "Freed slot-1"
    # On no branch, git prints nothing, not even a newline.
    assert {:ok, ""} = exec.("git -C /work/#{project}.wt/slot-1 branch --show-current")

    # A command grant, asked through the real `mwt` in the VM. A name no
    # grant has is refused with the ones there are; the built-in Ask to run
    # commands is off until you turn it on. With a script of yours, the agent
    # sends no text, and `mwt` doesn't sit waiting on a stdin nobody writes to.
    assert {:error, refused} =
             exec.("/mnt/mwt/bin/mwt run shell --reason r --wait 0 -- echo hi 2>&1")

    assert refused =~ "No command grant by that name. The command grants: commands."

    assert {:error, off} =
             exec.("/mnt/mwt/bin/mwt run commands --reason r --wait 0 -- echo hi 2>&1")

    assert off =~ "commands is off. Ask for it with: mwt request commands"

    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "where",
        "purpose" => "Say where it runs",
        "script" => "pwd",
        "dir" => repo
      })

    {:ok, _} = Sandbox.turn_on(username, "where", :until_off, :ask)
    assert {:error, waiting} = exec.("/mnt/mwt/bin/mwt run where --reason 'see it' --wait 0 2>&1")
    assert waiting =~ "mwt wait run-"

    assert [%{kind: :command, grant_id: "where", script: "pwd", dir: ^repo} = command] =
             Sandbox.snapshot(username).waiting

    :ok = Sandbox.decide(username, command.id, :decline)

    # The launcher goes into the VM while it runs, and only then.
    launcher = Sandbox.snapshot(username).tools.launcher
    assert {"in the vm\n", 0} = System.cmd(launcher, ["exec", name, "--", "echo", "in the vm"])

    :ok = Store.close(username)
    assert Bubble.status(username) == :down
    assert machine_pid(name) == nil

    assert {output, 1} =
             System.cmd(launcher, ["exec", name, "--", "true"], stderr_to_stdout: true)

    assert output =~ "isn't running"
    assert machine_pid(name) == nil
  end
end
