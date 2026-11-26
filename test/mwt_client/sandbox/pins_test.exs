defmodule MWTClient.Sandbox.PinsTest do
  @moduledoc """
  The files a command runs, pinned (`MWTClient.Sandbox.Pins`): what you
  approve is each file as it was when you looked. A card shows it and
  runs nothing should it change before the run; a saved command keeps
  it as saved, and a run that finds it changed asks, showing how, and
  pins it again as you let it go.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Pins, Server}

  doctest Pins

  setup do
    base = Path.join(System.tmp_dir!(), "pins-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "work")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "x.sh"), "#!/bin/sh\necho one\n")
    File.chmod!(Path.join(dir, "x.sh"), 0o755)
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    MWTClient.VaultHelpers.unlocked_identity("pins")
    |> Map.merge(%{dir: dir, base: base})
  end

  test "a file is found where the command runs it, and what it holds is kept",
       %{dir: dir, base: base} do
    workspace = Path.join(base, "ws")
    File.mkdir_p!(Path.join(workspace, "from-vm"))
    File.write!(Path.join([workspace, "from-vm", "y.sh"]), "echo vm")

    assert [mine, vm, unknown, gone] =
             Pins.of(
               "./x.sh && bash $MWT_WORKSPACE/from-vm/y.sh; sh $OTHER/z.sh; ./none.sh",
               dir,
               workspace
             )

    assert %{file: "./x.sh", vm?: false, content: "#!/bin/sh\necho one\n", size: 19} = mine
    assert is_binary(mine.hash)
    assert %{vm?: true, content: "echo vm"} = vm
    assert %{path: nil, hash: nil} = unknown
    assert %{file: "./none.sh", hash: nil} = gone

    assert Pins.changed([mine, vm, unknown, gone]) == []

    File.write!(Path.join(dir, "x.sh"), "echo two\n")
    File.write!(Path.join(dir, "none.sh"), "echo here now\n")

    assert [{^mine, %{content: "echo two\n"}}, {^gone, %{content: "echo here now\n"}}] =
             Pins.changed([mine, vm, unknown, gone])
  end

  test "each file is found in the folder its command runs in, after the cds before it",
       %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/x.sh"), "echo sub\n")

    assert [%{file: "sub/x.sh", content: "echo sub\n"} = pin] =
             Pins.of("cd sub && ./x.sh", dir, nil)

    assert pin.path == Path.join(dir, "sub/x.sh")

    # A cd whose failure doesn't stop it: found, while the folder is there.
    assert [%{path: path}] = Pins.of("cd sub; ./x.sh", dir, nil)
    assert path == Path.join(dir, "sub/x.sh")

    assert [%{path: nil, why: why}] = Pins.of("cd gone; ./x.sh", dir, nil)
    assert why =~ "isn't there now"

    # One that stops it when it fails: the file it would run is pinned, gone.
    assert [%{path: path, hash: nil}] = Pins.of("cd gone && ./x.sh", dir, nil)
    assert path == Path.join(dir, "gone/x.sh")

    assert [%{path: nil, why: "after a cd MWT can't follow"}] =
             Pins.of("cd - && ./x.sh", dir, nil)
  end

  test "a file it can't tell is a pin of its own: never looked at on a card, always moved for a saved command",
       %{dir: dir} do
    pins = Pins.of(~s(./x.sh; bash -c "$CODE"), dir, nil)

    assert [
             %{file: "./x.sh"} = mine,
             %{path: nil, hash: nil, why: "shell code built from a variable"}
           ] =
             pins

    assert Pins.changed(pins) == []
    assert [{_was, %{why: "shell code built from a variable"}}] = Pins.moved(pins, pins)

    # A file not pinned yet counts as changed; one missing then and now doesn't.
    assert [{%{hash: nil}, ^mine}] = Pins.moved([], [mine])
    gone = hd(Pins.of("./none.sh", dir, nil))
    assert Pins.moved([gone], [gone]) == []
  end

  defp saved(context, start) do
    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "x",
        "purpose" => "Runs x",
        "script" => "./x.sh",
        "dir" => context.dir
      })

    {:ok, _} = Sandbox.set_start(context.username, grant.id, start)
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

  test "a card runs nothing when a file it runs changed after you saw it", context do
    grant = saved(context, :on)
    card = run(context.username, grant.id)

    # The card shows the file, and says it runs only as it is now.
    assert [%{file: "./x.sh", content: "#!/bin/sh\necho one\n"}] = card.pins
    assert Enum.any?(card.warnings, &(&1 =~ "Runs ./x.sh: read it below"))

    File.write!(Path.join(context.dir, "x.sh"), "#!/bin/sh\necho changed\n")
    :ok = Sandbox.decide(context.username, card.id, {:run, :send})

    assert %{decision: :pin_changed, run: nil} = final(context.username, card.id)
  end

  test "a saved command whose file changed since it was saved asks, shows how, and is pinned again",
       context do
    grant = saved(context, :auto)

    assert [%{file: "./x.sh"}] =
             Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == grant.id)).pins

    # As saved: it runs without asking.
    first = run(context.username, grant.id)
    assert %{run: %{exit: 0, output: "one\n"}} = final(context.username, first.id)

    # Changed: this run asks, whatever its setting, and says how.
    File.write!(Path.join(context.dir, "x.sh"), "#!/bin/sh\necho two\n")
    second = run(context.username, grant.id)
    assert waiting?(context.username, second.id)
    assert second.repin

    assert Enum.any?(
             second.warnings,
             &(&1 =~ "changed since x was pinned" and &1 =~ "+ echo two")
           )

    :ok = Sandbox.decide(context.username, second.id, {:run, :send})
    assert %{run: %{exit: 0, output: "two\n"}} = final(context.username, second.id)

    # Pinned again as you let it go: the next runs without asking.
    third = run(context.username, grant.id)
    refute third.repin
    assert %{run: %{exit: 0, output: "two\n"}} = final(context.username, third.id)
  end
end
