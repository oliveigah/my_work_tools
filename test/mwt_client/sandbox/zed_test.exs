defmodule MWTClient.Sandbox.ZedTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Guest, Zed}

  @moduletag :tmp_dir

  describe "folder?/2" do
    test "takes a folder under the VM's /work, named in plain characters" do
      for folder <-
            ~w(/work/app /work/app.wt/slot-1 /work/my_work_tools.wt/slot-0 /work/café/x+y@z) do
        assert Zed.folder?(folder, "/work"), folder
      end
    end

    # The address is the host followed by the path, and the VM prints the
    # paths of its worktrees.
    test "refuses a path that would change what the address names" do
      for folder <- [
            ".evil.example/work/slot-1",
            "@evil.example/work/slot-1",
            ":2222/work/slot-1",
            "/work",
            "/workshop/x",
            "/etc/passwd",
            "/work/../etc",
            "/work/./app",
            "/work/app?x=1",
            "/work/app#x",
            "/work/my app",
            "/work/app\n",
            "/work//app",
            nil
          ] do
        refute Zed.folder?(folder, "/work"), inspect(folder)
      end
    end

    test "nothing is opened for a folder it refuses" do
      guest = Guest.local("/work")
      assert {:error, said} = Zed.open("nobody", ".evil.example/work/slot-1", guest)
      assert said =~ "under /work"
    end
  end

  describe "args/2" do
    @opened %{connected?: true, folders: ["/work/app", "/work/app.wt/slot-1"]}

    test "a folder Zed has open is brought forward, never opened twice" do
      assert Zed.args("/work/app", @opened) == ["--existing", "ssh://mwt-sandbox/work/app"]
    end

    test "with a Zed window connected to the VM, another folder joins it" do
      assert Zed.args("/work/app.wt/slot-2", @opened) ==
               ["--reuse", "ssh://mwt-sandbox/work/app.wt/slot-2"]
    end

    test "with no Zed window connected, or no way to tell, Zed opens a window of its own" do
      for opened <- [%{connected?: false, folders: []}, :unknown] do
        assert Zed.args("/work/app", opened) == ["--existing", "ssh://mwt-sandbox/work/app"]
      end
    end
  end

  describe "opened/1" do
    test "counts the folders of connected projects only" do
      guest =
        fake_guest(
          {:ok,
           """
           connected setup-8
           open setup-8 /work/app.wt/slot-1
           open setup-8 /work/folder with spaces
           open workspace-12 /work/app
           something else Zed said
           """}
        )

      assert Zed.opened(guest) == %{
               connected?: true,
               folders: ["/work/app.wt/slot-1", "/work/folder with spaces"]
             }
    end

    test "a server whose window went is not a connected Zed" do
      guest = fake_guest({:ok, "open workspace-12 /work/app\n"})
      assert Zed.opened(guest) == %{connected?: false, folders: []}
    end

    test "when the VM can't be asked, it is unknown" do
      assert Zed.opened(fake_guest({:error, "the VM isn't running"})) == :unknown
    end

    test "reads Zed's servers from the processes they run as", %{tmp_dir: dir} do
      # Zed's server stand-in: sh under the server's name, so the process
      # runs the program the script looks for, reading its `run` or `proxy`
      # script from `dir`. Each blocks until its port closes with the test.
      server = Path.join(dir, "zed-remote-server-test")
      File.ln_s!(System.find_executable("sh"), server)
      File.write!(Path.join(dir, "run"), ~s(exec 3<"$FOLDER"\nread -r line\n))
      File.write!(Path.join(dir, "proxy"), "read -r line\n")

      [connected, gone] = for _ <- 1..2, do: "test-#{System.unique_integer([:positive])}"
      [shown, hidden] = for name <- ["shown", "hidden"], do: Path.join(dir, name)
      Enum.each([shown, hidden], &File.mkdir!/1)

      run_server(server, dir, connected, shown)
      run_server(server, dir, gone, hidden)
      start(server, dir, ["proxy", "--identifier", connected], [])

      assert %{connected?: true, folders: folders} = Zed.opened(Guest.local(dir))
      assert shown in folders
      refute hidden in folders
    end
  end

  test "opens with Zed's command when there is no setsid" do
    assert Zed.command_line("/usr/bin/zed", ["--reuse", "ssh://mwt-sandbox/work/app"], nil) ==
             {"/usr/bin/zed", ["--reuse", "ssh://mwt-sandbox/work/app"]}
  end

  test "Zed runs in a session of its own, and MWT doesn't wait for it", %{tmp_dir: dir} do
    setsid = System.find_executable("setsid") || flunk("setsid is needed for this test")
    seen = Path.join(dir, "seen")
    zed = Path.join(dir, "zed")

    # A Zed that stays up, as one MWT starts does.
    File.write!(zed, """
    #!/bin/sh
    echo "$* $(ps -o sid= -p $$)" > "#{seen}.part" && mv "#{seen}.part" "#{seen}"
    sleep 30
    """)

    File.chmod!(zed, 0o755)

    {program, args} = Zed.command_line(zed, ["--reuse", "ssh://mwt-sandbox/work/app"], setsid)
    {elapsed, {_output, 0}} = :timer.tc(fn -> System.cmd(program, args) end)
    assert elapsed < 5_000_000

    line =
      Enum.find_value(1..300, fn _ ->
        case File.read(seen) do
          {:ok, line} -> line
          {:error, _} -> Process.sleep(10) && nil
        end
      end) || flunk("the fake Zed never ran")

    [flag, address, sid] = String.split(line)
    assert {flag, address} == {"--reuse", "ssh://mwt-sandbox/work/app"}

    {our_sid, 0} = System.cmd("ps", ["-o", "sid=", "-p", System.pid()])
    refute String.trim(our_sid) == sid

    System.cmd("pkill", ["-f", zed])
    :ok
  end

  defp fake_guest(result), do: %{Guest.local("/nowhere") | exec: fn _words -> result end}

  # A `run` server of project `id`, holding `folder` open as Zed's does;
  # back once it does.
  defp run_server(server, dir, id, folder) do
    pid_file = Path.join([dir, "server_state", id, "server.pid"])

    port =
      start(server, dir, ["run", "--log-file", "/dev/null", "--pid-file", pid_file], [
        {~c"FOLDER", String.to_charlist(folder)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    Enum.find_value(1..300, fn _ ->
      File.read_link("/proc/#{os_pid}/fd/3") == {:ok, folder} || (Process.sleep(10) && nil)
    end) || flunk("the stand-in server never opened #{folder}")
  end

  defp start(server, dir, args, env),
    do: Port.open({:spawn_executable, server}, [:binary, args: args, cd: dir, env: env])
end
