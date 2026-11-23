defmodule MWTClient.QAProbes.Handoffs.BasedOnTaskTest do
  # Probe: a task started from another task's branch by its short name
  # (`--from login`, which MWT accepts) records `mwt-base login`; the check
  # that keeps a landed branch another task is based on only knows
  # `refs/heads/login`.
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs}

  setup {MWTClient.HandoffsCase, :with_slots}

  test "--from login: landing login deletes it, and tweak can no longer hand off",
       %{username: username, mirror: mirror} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "login"})
    commit(one, [{"a.txt", "login\n"}], "login")
    {0, _} = Channel.answer("handoff", ask(one), username)

    two = slot(mirror, 2)
    {0, started} = worktree(username, two, "new", %{"name" => "tweak", "from" => "login"})
    IO.puts("\n[based-on probe] " <> String.slice(started, 0, 140))
    IO.puts("[based-on probe] tweak's base: " <> git(mirror, ["config", "branch.tweak.mwt-base"]))
    commit(two, [{"b.txt", "tweak\n"}], "tweak")
    git(one, ["switch", "-q", "--detach"])

    {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    IO.puts("[based-on probe] " <> List.last(landed.timeline).text)
    assert git(mirror, ["branch", "--list", "login"]) == ""

    assert {1, refused} = Channel.answer("handoff", ask(two, %{"title" => "Tweak"}), username)
    IO.puts("[based-on probe] tweak hands off: " <> refused)
  end
end
