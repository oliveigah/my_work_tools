defmodule MWTClient.Sandbox.HandoffsLandedBranchTest do
  @moduledoc """
  What landing does to the task's branch in the VM: deleted when nothing
  was done on it since, so task branches don't pile up in the clone; kept,
  saying why on the handoff's timeline, when something was. Deleted and
  resumed is in handoffs_slots_test.exs.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoff, Handoffs}
  alias MWTClient.StandIns

  setup {MWTClient.HandoffsCase, :with_slots}

  test "a branch with commits since the revision that landed stays", %{
    username: username,
    mirror: mirror
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    commit(one, [{"b.txt", "more\n"}], "more, not handed off")
    head = sha(one, "HEAD")

    assert {:ok, %Handoff{status: :accepted} = landed} =
             Handoffs.accept(username, 1, {:commit, "master"})

    assert git(one, ["branch", "--show-current"]) == "fix\n"
    assert sha(mirror, "fix") == head
    assert kept(landed) == "Its branch fix stays in the VM: it has commits since this revision."
  end

  test "a branch with uncommitted work on it stays, and so does its slot", %{
    username: username,
    mirror: mirror
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    File.write!(Path.join(one, "c.txt"), "started\n")

    {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert git(one, ["branch", "--show-current"]) == "fix\n"
    assert File.read!(Path.join(one, "c.txt")) == "started\n"
    assert kept(landed) == "Its branch fix stays in the VM: #{one} has uncommitted work on it."
  end

  test "a branch another task is based on stays", %{username: username, mirror: mirror} do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "login"})
    commit(one, [{"a.txt", "login\n"}], "login")
    {0, _} = Channel.answer("handoff", ask(one), username)
    two = slot(mirror, 2)
    {0, _} = worktree(username, two, "new", %{"name" => "tweak", "from" => "refs/heads/login"})
    # Its own slot moved on to another task, so nothing has it checked out.
    git(one, ["switch", "-q", "--detach"])

    {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert git(mirror, ["branch", "--list", "login"]) =~ "login"
    assert kept(landed) == "Its branch login stays in the VM: the task tweak is based on it."
  end

  test "a branch checked out in a worktree that isn't a slot stays", %{
    username: username,
    mirror: mirror
  } do
    side = new_worktree(mirror, "side-work")
    commit(side, [{"a.txt", "side\n"}], "side work")
    {0, _} = Channel.answer("handoff", ask(side), username)

    {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert git(side, ["branch", "--show-current"]) == "side-work\n"

    assert kept(landed) ==
             "Its branch side-work stays in the VM: #{side}, which isn't a slot, has it checked out."
  end

  test "landed while the VM is stopped, the branch stays, and the landing too", %{
    username: username,
    mirror: mirror,
    repo: repo
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    StandIns.remove_guest(username)

    assert {:ok, %Handoff{status: :accepted} = landed} =
             Handoffs.accept(username, 1, {:commit, "master"})

    assert git(repo, ["show", "master:a.txt"]) == "the fix\n"
    assert git(mirror, ["branch", "--list", "fix"]) =~ "fix"

    assert kept(landed) ==
             "Its branch fix stays in the VM: the VM wasn't running when you landed it."
  end

  defp kept(%Handoff{timeline: timeline}) do
    assert %{kind: :branch_kept, text: text} = List.last(timeline)
    text
  end
end
