defmodule MWTClient.QAProbes.Handoffs.SlotRaceTest do
  # Probe: two threads opened in the same free slot both take it at once.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Projects}

  setup {MWTClient.HandoffsCase, :with_slots}

  test "two threads taking the same free slot at once are both told they hold it",
       %{username: username, mirror: mirror, repo: repo} do
    one = slot(mirror, 1)
    git(mirror, ["fetch", "-q", repo, "+refs/heads/*:refs/remotes/host-origin/*"])

    results =
      [{"fix-login", "thread-a"}, {"add-cart", "thread-b"}]
      |> Enum.map(fn {name, thread} ->
        Task.async(fn ->
          Channel.answer(
            "worktree",
            %{
              "cwd" => one,
              "action" => "new",
              "name" => name,
              "from" => "master",
              "thread_id" => thread
            },
            username
          )
        end)
      end)
      |> Task.await_many(60_000)

    for {status, words} <- results,
        do: IO.puts("\n[slot race] #{status}: #{String.slice(words, 0, 160)}")

    {:ok, %{slots: slots}} = Projects.slots(username, "app")
    slot1 = Enum.find(slots, &(&1.name == "slot-1"))
    IO.puts("[slot race] slot-1 is on #{slot1.branch}, held by #{slot1.thread}")
    IO.puts("[slot race] branches: " <> git(mirror, ["branch", "--list"]))

    # Either both were told "Started" (one holds a task whose branch is no
    # longer in the slot it works in), or git's own index lock collided and
    # one got git's raw words: never "slot-1 isn't free".
    both_started? = Enum.all?(results, &match?({0, _}, &1))
    lock_collision? = Enum.any?(results, fn {_, words} -> words =~ "index.lock" end)
    assert both_started? or lock_collision?
    refute Enum.any?(results, fn {_, words} -> words =~ "isn't free" end)
  end
end
