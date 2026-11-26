defmodule MWTClient.QAProbes.Commands.PinsEvasionTest do
  @moduledoc """
  Probe: the files a command runs are pinned (docs/grant_mental_model.md,
  Q10 and "Pinning, step by step"): `./x` or `path/x` as the command,
  `bash x`, `sh x`, `source x`, `. x`, an interpreter and its file, each
  resolved in the folder the command runs in. A saved command keeps each
  file's hash "when you save or approve it"; a run that finds one changed
  asks, even when the command runs without asking.

  Each test writes a command that runs a file, then checks that the file
  is the one pinned. A failing one is a way to run a file MWT doesn't pin,
  so a change to it (a pull, an earlier command the agent wrote) runs
  unasked under a saved command set to run without asking. The race
  between check and run is out of scope, as the doc says.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Pins, Server}

  setup do
    base = Path.join(System.tmp_dir!(), "qa-pins-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "work")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.mkdir_p!(Path.join(dir, "scripts"))

    for path <- ["x.sh", "sub/x.sh", "scripts/deploy.sh", "x.py"] do
      File.write!(Path.join(dir, path), "echo one\n")
      File.chmod!(Path.join(dir, path), 0o755)
    end

    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    MWTClient.VaultHelpers.unlocked_identity("qa-pins")
    |> Map.merge(%{dir: dir, base: base})
  end

  # The paths pinned for `script` run in `dir`, those MWT could read.
  defp pinned(script, dir),
    do: for(%{path: path, hash: hash} <- Pins.of(script, dir, nil), is_binary(hash), do: path)

  describe "forms the doc lists: pinned" do
    test "./x, bash ./x, bash x, sh -e x, source x, . x, python -u x.py", %{dir: dir} do
      x = Path.join(dir, "x.sh")
      assert pinned("./x.sh", dir) == [x]
      assert pinned("bash ./x.sh", dir) == [x]
      assert pinned("bash x.sh", dir) == [x]
      assert pinned("sh -e x.sh", dir) == [x]
      assert pinned("source x.sh", dir) == [x]
      assert pinned(". x.sh", dir) == [x]
      assert pinned("sudo ./x.sh", dir) == [x]
      assert pinned("env ./x.sh", dir) == [x]
      assert pinned("python3 -u x.py", dir) == [Path.join(dir, "x.py")]
    end

    test "a symlink swapped after pinning is seen as a change", %{dir: dir} do
      File.write!(Path.join(dir, "other.sh"), "echo other\n")
      File.ln_s!(Path.join(dir, "x.sh"), Path.join(dir, "link.sh"))
      pins = Pins.of("./link.sh", dir, nil)
      assert [%{content: "echo one\n"}] = pins

      File.rm!(Path.join(dir, "link.sh"))
      File.ln_s!(Path.join(dir, "other.sh"), Path.join(dir, "link.sh"))
      assert [{_was, %{content: "echo other\n"}}] = Pins.changed(pins)
    end
  end

  describe "forms that run a file, not pinned" do
    # Step 1 says "`./x` or `path/x` as the command"; `command_name/1` keeps
    # only the basename of a path that doesn't start with ./ or ../.
    test "path/x as the command", %{dir: dir} do
      assert pinned("scripts/deploy.sh staging", dir) == [Path.join(dir, "scripts/deploy.sh")]
    end

    test "an absolute path, or one under ~, as the command", %{dir: dir} do
      abs = Path.join(dir, "x.sh")
      assert pinned("#{abs} staging", "/") == [abs]
    end

    test "./x in quotes", %{dir: dir} do
      assert pinned(~s("./x.sh" staging), dir) == [Path.join(dir, "x.sh")]
      assert pinned("'./x.sh'", dir) == [Path.join(dir, "x.sh")]
    end

    # The file is resolved in the command's folder, not where `cd` went:
    # MWT pins dir/x.sh (missing) and runs sub/x.sh unpinned; the card says
    # "./x.sh isn't there now: should it be there when this starts, nothing
    # runs", which is wrong: sub/x.sh runs.
    test "cd sub && ./x.sh", %{dir: dir} do
      assert pinned("cd sub && ./x.sh", dir) == [Path.join(dir, "sub/x.sh")]
    end

    test "timeout 30 ./x.sh; nice -n 5 ./x.sh", %{dir: dir} do
      assert pinned("timeout 30 ./x.sh", dir) == [Path.join(dir, "x.sh")]
      assert pinned("nice -n 5 ./x.sh", dir) == [Path.join(dir, "x.sh")]
    end

    # A flag holding a "c" (`--norc`, `--inspect`) ends the look for a file.
    test "bash --norc x.sh", %{dir: dir} do
      assert pinned("bash --norc x.sh", dir) == [Path.join(dir, "x.sh")]
    end

    # A flag that takes a value: the value is taken for the file.
    test "python3 -W ignore x.py", %{dir: dir} do
      assert pinned("python3 -W ignore x.py", dir) == [Path.join(dir, "x.py")]
    end

    test "the file fed to a shell on stdin", %{dir: dir} do
      assert pinned("bash < x.sh", dir) == [Path.join(dir, "x.sh")]
      assert pinned("cat x.sh | sh", dir) == [Path.join(dir, "x.sh")]
    end
  end

  describe "a saved command set to run without asking" do
    defp saved(context, script) do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "deploy",
          "purpose" => "Deploys",
          "script" => script,
          "dir" => context.dir
        })

      {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)
      grant
    end

    defp run(username, id) do
      ask = %{grant: id, script: nil, values: %{}, dir: nil, reason: "r", agent: "claude"}
      {:ok, approval} = Server.call(username, {:request_command, ask})
      approval
    end

    defp final(username, id) do
      {:ok, approval, _grant} = Server.call(username, {:await, id, 10_000}, 15_000)
      approval
    end

    defp waiting?(username, id),
      do: Enum.any?(Sandbox.snapshot(username).waiting, &(&1.id == id))

    test "./x.sh changed after saving asks (holds)", context do
      grant = saved(context, "./x.sh")
      File.write!(Path.join(context.dir, "x.sh"), "echo changed\n")
      card = run(context.username, grant.id)
      assert waiting?(context.username, card.id)
      assert card.repin
    end

    test "cd sub && ./x.sh: the file it runs changes, and it runs unasked", context do
      grant = saved(context, "cd sub && ./x.sh")
      first = run(context.username, grant.id)
      assert %{run: %{output: "one\n"}} = final(context.username, first.id)

      File.write!(Path.join(context.dir, "sub/x.sh"), "echo CHANGED-AFTER-SAVING\n")
      second = run(context.username, grant.id)

      ran =
        if waiting?(context.username, second.id),
          do: nil,
          else: final(context.username, second.id)

      assert is_nil(ran),
             "sub/x.sh changed since it was saved, and the run went unasked: #{inspect(ran && ran.run.output)}"
    end

    test "scripts/deploy.sh: the file it runs changes, and it runs unasked", context do
      grant = saved(context, "scripts/deploy.sh")
      File.write!(Path.join(context.dir, "scripts/deploy.sh"), "echo CHANGED-AFTER-SAVING\n")
      card = run(context.username, grant.id)

      ran =
        if waiting?(context.username, card.id), do: nil, else: final(context.username, card.id)

      assert is_nil(ran),
             "scripts/deploy.sh changed since it was saved, and the run went unasked: #{inspect(ran && ran.run.output)}"
    end
  end
end
