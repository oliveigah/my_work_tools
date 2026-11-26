defmodule MWTClientWeb.SandboxHandoffsLiveBlockedTest do
  # The Handoffs page for handoffs that can't land as they are: taken back
  # for more work, held by pending work, conflicting, or behind a branch
  # that moved; and what the page offers then, its thread in Zed included.
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MWTClientWeb.HandoffsLiveHelpers

  alias MWTClient.Sandbox.Channel

  setup {MWTClientWeb.HandoffsLiveHelpers, :project}

  test "one its thread took back for more work waits, and can't land as it is", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix-login", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {0, _} =
      Channel.answer(
        "handoff",
        %{
          "stage" => "withdraw",
          "cwd" => Path.join(vm, "app.wt/slot-1"),
          "reason" => "The signup form too.",
          "agent" => "claude"
        },
        username
      )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert has_element?(view, "#handoff-withdrawn-#{handoff.id}", "Taken back")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-state", "Taken back")
    assert has_element?(view, "#handoff-decision-state", "took it back for more work")
    assert has_element?(view, "#handoff-withdrawn", "it can't land as it is")
    refute has_element?(view, "#handoff-accept")
    assert has_element?(view, "#handoff-timeline", "took it back for more work")
    assert has_element?(view, "#handoff-timeline", "The signup form too.")

    # You can still drop it.
    view |> element("#handoff-choose-close") |> render_click()
    view |> element("#handoff-close") |> render_click()
    assert has_element?(view, "#handoff-state", "Closed")
  end

  test "a landed one offers no more work: its slot may be another task's by then", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-state", "Landed")
    refute has_element?(view, "#handoff-close")
    refute has_element?(view, "#handoff-choose-close")

    refute has_element?(view, "#handoff-more-work")
    refute has_element?(view, "#handoff-open-thread")
    assert git(repo, ["log", "-1", "--format=%s"]) == "work on fix\n"

    # Its thread stays named, with where it worked, to find it by hand.
    assert has_element?(view, "#handoff-thread", "Fix the login thread")
    assert has_element?(view, "#handoff-thread-folder", "app.wt/slot-1")
  end

  test "pending work on your branch stops it from landing", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "b.txt"), "new\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "pending\n")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-preview", "work you haven't committed: a.txt")
    assert has_element?(view, "#handoff-accept-button[disabled]")

    # A new branch leaves your checkout alone.
    view |> form("#handoff-accept", accept: %{how: "branch"}) |> render_change()
    assert has_element?(view, "#handoff-merges", "Ready to create mwt/fix")
    refute has_element?(view, "#handoff-accept-button[disabled]")

    # Committed, master has a commit the task lacks: it lands on top, said untested.
    git(repo, ["commit", "-q", "-am", "mine"])
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-merges", "Ready to land on master")

    assert has_element?(
             view,
             "#handoff-untested",
             "1 commit this task wasn't built or tested with"
           )

    refute has_element?(view, "#handoff-accept-button[disabled]")
  end

  test "one that conflicts can't land by accident; its thread opens in Zed", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    zed_opens(username)

    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    git(repo, ["checkout", "-q", "-b", "release"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")
    git(repo, ["commit", "-q", "-am", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    view |> form("#handoff-accept", accept: %{onto: "release"}) |> render_change()
    assert has_element?(view, "#handoff-conflicts", "Its changes conflict with your release")
    assert has_element?(view, "#handoff-conflicts", "a.txt")
    assert has_element?(view, "#handoff-accept-button[disabled]")

    # It doesn't conflict with master: it can land there instead.
    view |> form("#handoff-accept", accept: %{onto: "master"}) |> render_change()
    refute has_element?(view, "#handoff-accept-button[disabled]")

    # Or its thread rebases, asked in Zed, from the conflict's own words.
    view |> form("#handoff-accept", accept: %{onto: "release"}) |> render_change()
    view |> element("#handoff-conflicts-open-thread") |> render_click()
    assert_received {:zed, address}
    assert address =~ "app.wt/slot-1"
    # Nothing changed: the decision is still yours.
    assert has_element?(view, "#handoff-state", "Waiting to land")
    assert has_element?(view, "#handoff-decision-state", "Waiting for you")
  end

  test "its branch moved under it: caught up here, or its thread opened in Zed to catch up",
       %{conn: conn, username: username, repo: repo, vm: vm} do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "b.txt"), "from the vm\n")
      end)

    # Something else lands on master, apart from its change.
    File.write!(Path.join(repo, "c.txt"), "mine\n")
    git(repo, ["add", "c.txt"])
    git(repo, ["commit", "-q", "-m", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-untested", "master moved since its checks ran")
    assert has_element?(view, "#handoff-catch-up-here")
    assert has_element?(view, "#handoff-catch-up-thread", "Open its thread in Zed")
    assert has_element?(view, "#handoff-one-commit")

    view |> element("#handoff-catch-up-here") |> render_click()
    assert has_element?(view, "#notices", "Caught up with master")
    assert has_element?(view, "#handoff-timeline", "You caught it up with master")
    refute has_element?(view, "#handoff-untested")
    assert has_element?(view, "#handoff-as-is")

    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-decision-state", "Landed")
    assert File.read!(Path.join(repo, "b.txt")) == "from the vm\n"
    assert File.read!(Path.join(repo, "c.txt")) == "mine\n"
  end

  test "where its changes conflict with its own branch, its thread opens in Zed to catch up", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    zed_opens(username)

    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")
    git(repo, ["commit", "-q", "-am", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-conflicts", "a.txt")
    # MWT can't resolve it: only its thread can, asked in Zed.
    refute has_element?(view, "#handoff-catch-up-here")
    assert has_element?(view, "#handoff-conflicts", "open it in Zed and ask it to catch up")

    view |> element("#handoff-catch-up-thread") |> render_click()
    assert_received {:zed, address}
    assert address =~ "app.wt/slot-1"
    assert has_element?(view, "#handoff-decision-state", "Waiting for you")
  end

  # Zed opening, for this test's identity: the address comes back as a message.
  defp zed_opens(username) do
    test = self()

    MWTClient.StandIns.on_zed(username, fn address ->
      send(test, {:zed, address})
      :ok
    end)
  end
end
