defmodule MWTClient.Sandbox.HostRunTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.HostRun

  setup do
    dir = Path.join(System.tmp_dir!(), "host-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp run(script, dir, timeout \\ 10) do
    me = self()
    HostRun.run(%{script: script, dir: dir, timeout: timeout}, &send(me, {:group, &1}))
  end

  test "runs in the directory, with stdout and stderr together and its exit status", %{dir: dir} do
    # Over before MWT could ask for its process group, maybe: the test that
    # stops a command is the one about its group.
    result = run("pwd; echo out; echo err >&2; exit 3", dir)
    assert result.exit == 3
    assert result.output == "#{dir}\nout\nerr\n"
    assert result.cut == 0
    refute result.timed_out
    assert result.error == nil
  end

  test "in tests, commands see a home without the login profile of whoever runs them",
       %{dir: dir} do
    home = Application.fetch_env!(:mwt_client, HostRun)[:home]
    assert %{exit: 0, output: ^home} = run(~S(printf %s "$HOME"), dir)
  end

  test "a pipe closed early ends the writer quietly, as in a terminal", %{dir: dir} do
    # Killed by SIGPIPE (141), not left to print "write error: Broken pipe".
    assert %{exit: 0, output: "1\n141 0\n"} =
             run(~S(seq 1 1000000 | head -n 1; echo "${PIPESTATUS[*]}"), dir)
  end

  test "stdin is empty, so a command reading it doesn't hang", %{dir: dir} do
    assert %{exit: 0, output: "0\n"} = run("wc -c", dir)
  end

  test "MWT's and the BEAM's own variables are kept from the command", %{dir: dir} do
    System.put_env("MWT_HOST_RUN_TEST", "secret")
    on_exit(fn -> System.delete_env("MWT_HOST_RUN_TEST") end)

    assert %{output: output} = run("env", dir)
    refute output =~ "MWT_HOST_RUN_TEST"
    refute output =~ "RELEASE_COOKIE"
    refute output =~ "BINDIR="
    assert output =~ "HOME="

    assert HostRun.scrubbed?("RELEASE_COOKIE")
    assert HostRun.scrubbed?("SECRET_KEY_BASE")
    refute HostRun.scrubbed?("PATH")
    refute HostRun.scrubbed?("KUBECONFIG")
  end

  test "the workspace is in MWT_WORKSPACE, as in the VM", %{dir: dir} do
    me = self()

    # What the shell was started with, read before the login profile runs:
    # the machine's own, under /etc, may set the variable too, as an MWT
    # VM's does for its shells.
    started_with = ~S(sed -zn 's/^MWT_WORKSPACE=//p' /proc/$$/environ | tr -d '\0')

    job = %{script: started_with, dir: dir, timeout: 10, workspace: "/home/me/mwt-vm"}

    assert %{output: "/home/me/mwt-vm", exit: 0} = HostRun.run(job, &send(me, {:group, &1}))
    assert %{output: "", exit: 0} = run(started_with, dir)
  end

  test "a long output keeps its first and last 32 KiB", %{dir: dir} do
    keep = HostRun.keep()
    # 100 KiB of numbered lines.
    result = run("seq 1 20000 | head -c 102400; echo; echo the-end", dir)

    assert result.bytes == 102_400 + 1 + 8
    assert result.cut == result.bytes - 2 * keep
    assert String.starts_with?(result.output, "1\n2\n3\n")
    assert String.ends_with?(result.output, "the-end\n")
    assert result.output =~ "[… #{result.cut} bytes cut …]"
  end

  test "output that isn't UTF-8 is made so", %{dir: dir} do
    assert %{output: output} = run(~S"printf 'a\xff\xfeb'", dir)
    assert String.valid?(output)
    assert output =~ "a"
  end

  test "the time limit ends it with 124, like timeout", %{dir: dir} do
    assert %{exit: 124, timed_out: true} = run("sleep 30", dir, 1)
  end

  test "stopping kills the whole process group", %{dir: dir} do
    me = self()

    task =
      Task.async(fn ->
        HostRun.run(%{script: "sleep 60 & sleep 60; wait", dir: dir, timeout: 120}, fn group ->
          send(me, {:group, group})
        end)
      end)

    assert_receive {:group, group}, 2_000
    # timeout, bash and both sleeps.
    assert Enum.find_value(1..200, fn _ ->
             length(group_pids(group)) >= 4 || (Process.sleep(10) && nil)
           end)

    :ok = HostRun.stop(group, "TERM")

    assert %{exit: exit, timed_out: false} = Task.await(task, 5_000)
    # Some versions of timeout answer 124 to being stopped too.
    assert exit in [124, 137, 143]
    assert group_pids(group) == []
  end

  defp group_pids(group) do
    {out, _} = System.cmd("pgrep", ["-g", Integer.to_string(group)])
    String.split(out, "\n", trim: true)
  end

  describe "confined" do
    @describetag :bwrap

    defp confined(script, dir, confine \\ %{}, extra \\ %{}) do
      me = self()

      job =
        Map.merge(
          %{
            script: script,
            dir: dir,
            timeout: 10,
            confine: Map.merge(%{reads: [], path: "/usr/local/bin:/usr/bin:/bin"}, confine)
          },
          extra
        )

      HostRun.run(job, &send(me, {:group, &1}))
    end

    test "home is empty, and a file under the real one can't be read", %{dir: dir} do
      home = Application.fetch_env!(:mwt_client, HostRun)[:home]
      File.mkdir_p!(home)
      File.write!(Path.join(home, "secret"), "mine")

      assert %{exit: 0, output: output} =
               confined(~S(ls -A "$HOME" | wc -l; cat "$HOME/secret" 2>&1; echo "$HOME"), dir)

      assert output =~ ~r/\A0\n/
      assert output =~ "No such file"
      refute output =~ "mine"
      assert output =~ home
    end

    test "a tool from a folder it may read runs; others of home don't show", %{dir: dir} do
      home = Application.fetch_env!(:mwt_client, HostRun)[:home]
      tools = Path.join(home, "tools-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tools)
      File.write!(Path.join(tools, "hello-tool"), "#!/bin/sh\necho hello from a tool\n")
      File.chmod!(Path.join(tools, "hello-tool"), 0o755)

      assert %{exit: 0, output: "hello from a tool\n"} =
               confined("hello-tool", dir, %{reads: [tools], path: tools <> ":/usr/bin:/bin"})

      assert %{exit: 127} = confined("hello-tool", dir, %{path: tools <> ":/usr/bin:/bin"})
    end

    test "parameters and grants' values are there; MWT's variables aren't", %{dir: dir} do
      System.put_env("MWT_SHOULD_NOT_LEAK", "1")
      on_exit(fn -> System.delete_env("MWT_SHOULD_NOT_LEAK") end)

      script =
        ~S(echo "$REPO $GH_TOKEN"; cat "$GH_TOKEN_FILE"; echo; env | grep -c -e MWT_ -e RELEASE_ -e MIX_ || true)

      assert %{exit: 0, output: output} =
               confined(
                 script,
                 dir,
                 %{
                   values: [
                     {"GH_TOKEN", "real-value"},
                     {"GH_TOKEN_FILE", "/mnt/mwt/tokens/github"},
                     {"MWT_FILE_1", "real-value"}
                   ],
                   files: [{"MWT_FILE_1", "/mnt/mwt/tokens/github"}]
                 },
                 %{env: [{"REPO", "o/r"}]}
               )

      assert output == "o/r real-value\nreal-value\n0\n"
    end

    test "the folder is read-only unless it may write there", %{dir: dir} do
      assert %{output: output} = confined("touch made 2>&1; ls", dir)
      assert output =~ "Read-only file system"

      assert %{exit: 0} = confined("touch made", dir, %{writes: true})
      assert File.exists?(Path.join(dir, "made"))
    end

    test "the workspace: what the VM left read-only, to-vm writable", %{dir: dir} do
      root = dir <> "-workspace/mwt-vm"
      on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)
      File.mkdir_p!(Path.join(root, "to-vm"))
      File.mkdir_p!(Path.join(root, "from-vm"))
      File.write!(Path.join(root, "from-vm/in.txt"), "from the VM\n")

      script = ~S"""
      cat "$MWT_WORKSPACE/from-vm/in.txt"
      touch "$MWT_WORKSPACE/from-vm/planted" 2>&1 | grep -o "Read-only file system"
      echo result > "$MWT_WORKSPACE/to-vm/out.txt"
      """

      assert %{output: output, exit: 0} = confined(script, dir, %{}, %{workspace: root})
      assert output == "from the VM\nRead-only file system\n"
      assert File.read!(Path.join(root, "to-vm/out.txt")) == "result\n"
      refute File.exists?(Path.join(root, "from-vm/planted"))
    end

    test "names resolve, and the time limit ends everything in it", %{dir: dir} do
      assert %{exit: 0} = confined("getent hosts localhost >/dev/null", dir)

      me = self()

      job = %{
        script: "sleep 60 & sleep 60; wait",
        dir: dir,
        timeout: 1,
        confine: %{reads: [], path: "/usr/bin:/bin"}
      }

      assert %{exit: 124, timed_out: true} = HostRun.run(job, &send(me, {:group, &1}))
      assert_received {:group, group}
      assert group_pids(group) == []
    end
  end

  test "a directory that doesn't exist is an error, not a crash", %{dir: dir} do
    assert %{exit: nil, error: error} = run("true", Path.join(dir, "missing"))
    assert is_binary(error)
  end
end
