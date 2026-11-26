defmodule MWTClient.Sandbox.SavedCommandPinsTest do
  @moduledoc """
  Where the server pins a saved command's files (Q10): as you save it on
  its page, as you accept one an agent proposed, and, for one never pinned
  (saved before pins, imported), at the run you let go after it asked
  once. A file that changed, or was never pinned, makes the next run ask,
  whatever the command's setting.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server
  alias MWTClient.Vault.Store

  setup do
    base = Path.join(System.tmp_dir!(), "saved-pins-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "work")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "x.sh"), "echo as-proposed\n")
    File.chmod!(Path.join(dir, "x.sh"), 0o755)
    on_exit(fn -> MWTClient.TestFolders.remove!(base) end)

    context = MWTClient.VaultHelpers.unlocked_identity("saved-pins")
    {:ok, _share} = Sandbox.add_share(context.username, dir)
    Map.merge(context, %{dir: dir})
  end

  defp grant(username, id), do: Enum.find(Sandbox.snapshot(username).grants, &(&1.id == id))

  defp run(username, id) do
    ask = %{grant: id, script: nil, values: %{}, dir: nil, reason: "r", agent: "claude"}
    Server.call(username, {:request_command, ask})
  end

  defp waiting?(username, id),
    do: Enum.any?(Sandbox.snapshot(username).waiting, &(&1.id == id))

  defp final(username, id) do
    {:ok, approval, _grant} = Server.call(username, {:await, id, 10_000}, 15_000)
    approval
  end

  test "a saved command you accept is pinned as you accepted it", context do
    ask = %{
      grant: "commands",
      name: "run x",
      purpose: "Runs x",
      script: "./x.sh",
      params: [],
      dir: context.dir,
      reason: "I run it often",
      agent: "claude",
      set: %{},
      fill: %{}
    }

    {:ok, proposed} = Server.call(context.username, {:propose, ask})
    to_review = grant(context.username, proposed.grant_id)

    {:ok, accepted} =
      Sandbox.review(context.username, to_review.id, {60, :all}, to_review.proposal.revision)

    assert [%{file: "./x.sh", content: "echo as-proposed\n"}] = accepted.pins

    # Changed after you accepted it: its first run asks.
    File.write!(Path.join(context.dir, "x.sh"), "echo changed\n")
    {:ok, card} = run(context.username, accepted.id)
    assert waiting?(context.username, card.id)
    assert Enum.any?(card.warnings, &(&1 =~ "./x.sh changed since run x was pinned"))
  end

  test "one whose file MWT can't tell asks at every run, saying why", context do
    {:ok, saved} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "by variable",
        "purpose" => "Runs x through a variable",
        "script" => "cmd=./x.sh; $cmd",
        "dir" => context.dir
      })

    {:ok, _} = Sandbox.set_start(context.username, saved.id, :auto)

    for _run <- 1..2 do
      {:ok, card} = run(context.username, saved.id)
      assert waiting?(context.username, card.id)

      assert Enum.any?(
               card.warnings,
               &(&1 =~ "can't be pinned" and &1 =~ "each run of by variable asks")
             )

      :ok = Sandbox.decide(context.username, card.id, {:run, :send})
      assert %{run: %{exit: 0}} = final(context.username, card.id)
    end
  end

  test "one never pinned asks once, showing the file, and runs unasked once you let it go",
       context do
    {:ok, saved} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "old x",
        "purpose" => "Runs x",
        "script" => "./x.sh",
        "dir" => context.dir
      })

    {:ok, _} = Sandbox.set_start(context.username, saved.id, :auto)

    # As one saved before pins comes back: none kept.
    pid = GenServer.whereis(Store.via(Server, context.username))

    :sys.replace_state(pid, fn state ->
      grants = Enum.map(state.grants, &if(&1.id == saved.id, do: %{&1 | pins: []}, else: &1))
      %{state | grants: grants}
    end)

    {:ok, card} = run(context.username, saved.id)
    assert waiting?(context.username, card.id)

    assert Enum.any?(
             card.warnings,
             &(&1 =~ "./x.sh isn't pinned for old x yet" and &1 =~ "+ echo as-proposed")
           )

    :ok = Sandbox.decide(context.username, card.id, {:run, :send})
    assert %{run: %{exit: 0}} = final(context.username, card.id)
    assert [%{file: "./x.sh"}] = grant(context.username, saved.id).pins

    {:ok, again} = run(context.username, saved.id)
    assert %{run: %{exit: 0}} = final(context.username, again.id)
  end
end
