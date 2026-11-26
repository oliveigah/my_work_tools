defmodule MWTClientWeb.SandboxHandoffsLiveTest do
  # The Handoffs page: the list, what a handoff shows, and landing it where
  # and how you choose. Those that can't land as they are have
  # sandbox_handoffs_live_blocked_test.exs, so the two run side by side.
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MWTClientWeb.HandoffsLiveHelpers

  alias MWTClient.Sandbox.{Channel, HandoffRecords, Handoffs}

  setup {MWTClientWeb.HandoffsLiveHelpers, :project}

  test "the list shows what agents handed off, open and closed apart", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert has_element?(view, "#handoffs-empty")

    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Fix the login")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "based on master")
    assert has_element?(view, "#handoff-row-#{handoff.id}", "Fix the login thread")
    assert has_element?(view, "#sandbox-nav-handoffs-open", "1")

    {:ok, _} = Handoffs.close(username, handoff.id)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?filter=closed")
    assert has_element?(view, "#handoff-row-#{handoff.id}")
  end

  test "an open handoff is notified until you accept, close or send it back", %{
    username: username,
    vm: vm
  } do
    handoffs = fn ->
      for %{kind: "sandbox.handoffs"} = item <- MWTClient.Notifications.list(username), do: item
    end

    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    assert [%{summary: "Claude handed off #" <> _, open: open}] = handoffs.()
    assert open == "/tools/sandbox/handoffs?id=#{handoff.id}"

    # Handed off again, its notification says so, still one.
    {0, _} =
      Channel.answer(
        "handoff",
        %{"cwd" => Path.join(vm, "app.wt/slot-1"), "agent" => "claude"},
        username
      )

    assert [%{summary: "Claude updated #" <> _}] = handoffs.()

    {:ok, _} = Handoffs.close(username, handoff.id)
    assert handoffs.() == []
  end

  test "one keeps your decision apart from what it is; it lands on a click", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
        File.write!(Path.join(tree, "mix.exs"), "# the build, changed\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-title", "Fix the login")
    assert has_element?(view, "#handoff-state", "Waiting to land")
    assert has_element?(view, "#handoff-information #handoff-thread", "Fix the login thread")
    assert has_element?(view, "#handoff-information #handoff-description", "Done, with tests.")

    # The decision, apart: land it, more work, or close it, Land chosen first.
    assert has_element?(view, "#handoff-decision-state", "Waiting for you")
    assert has_element?(view, "#handoff-choose-land[aria-selected=true]")
    assert has_element?(view, "#handoff-choose-more[aria-selected=false]")
    assert has_element?(view, "#handoff-choose-close[aria-selected=false]")
    refute has_element?(view, "#handoff-information #handoff-accept")

    # It lands as it is on the branch it was based on, unless you choose:
    # that branch hasn't moved, so its own commit goes there.
    assert has_element?(view, "#handoff-decision #handoff-merges", "Ready to land on master")
    assert has_element?(view, "#handoff-as-is", "Its commit, as it is")
    refute has_element?(view, "#handoff-as")
    assert has_element?(view, "#handoff-onto option[value=master][selected]", "base")
    assert has_element?(view, "#handoff-how-commit[checked]")
    refute has_element?(view, "#handoff-new-branch")
    assert has_element?(view, "#handoff-accept-button", "Land on master")
    assert has_element?(view, "#handoff-decision", "Landing ends the handoff")
    assert has_element?(view, "#handoff-baseline", "Based on master")
    assert has_element?(view, "#handoff-hints", "mix.exs, which runs when you build")

    # The other two show only once chosen; choosing does nothing else.
    refute has_element?(view, "#handoff-more-work")
    view |> element("#handoff-choose-more") |> render_click()
    assert has_element?(view, "#handoff-open-thread", "Open its thread in Zed")
    assert has_element?(view, "#handoff-more-work-thread", "Fix the login thread")
    refute has_element?(view, "#handoff-accept")
    view |> element("#handoff-choose-close") |> render_click()
    assert has_element?(view, "#handoff-close", "Close without landing")
    assert has_element?(view, "#handoff-state", "Waiting to land")
    view |> element("#handoff-choose-land") |> render_click()

    # What lands, on the same page: its commits and files; the diff on asking.
    assert has_element?(view, "#handoff-commits", "work on fix")
    assert has_element?(view, "#handoff-file-list", "a.txt")
    assert has_element?(view, "#handoff-file-list", "mix.exs")
    refute has_element?(view, "#handoff-files")
    view |> element("#handoff-diff-toggle") |> render_click()
    assert has_element?(view, "#handoff-file-0", "two, from the vm")
    view |> element("#handoff-diff-toggle") |> render_click()
    refute has_element?(view, "#handoff-files")

    # Nothing brings it to your machine to look at: that is done in the VM.
    refute has_element?(view, "#handoff-save-branch")

    first = git(repo, ["rev-parse", "HEAD"])
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#notices", "Landed")
    assert has_element?(view, "#handoff-state", "Landed")
    assert has_element?(view, "#handoff-decision-state", "Landed")
    assert has_element?(view, "#handoff-accepted", "Its commit as it is onto master")
    refute has_element?(view, "#handoff-choices")
    assert has_element?(view, "#handoff-what", "What landed")
    refute has_element?(view, "#handoff-vm")
    assert git(repo, ["rev-parse", "HEAD"]) == git(repo, ["rev-parse", handoff.head])
    assert git(repo, ["log", "-1", "--format=%s"]) == "work on fix\n"
    assert git(repo, ["rev-parse", "HEAD~1"]) == first
    assert git(repo, ["show", "HEAD:mix.exs"]) == "# the build, changed\n"
    assert git(repo, ["status", "--porcelain"]) == ""

    view |> element("#handoff-undo") |> render_click()
    assert git(repo, ["rev-parse", "HEAD"]) == first
    assert has_element?(view, "#handoff-accept-button", "Land on master")
  end

  test "a task based on a landed branch lands on it by default", %{
    conn: conn,
    username: username,
    vm: vm,
    repo: repo
  } do
    first =
      hand_off(username, vm, "login-feature", "Login", fn tree ->
        File.write!(Path.join(tree, "login.txt"), "first\n")
      end)

    {:ok, landed} = Handoffs.accept(username, first.id, {:branch, "master", "login-feature"})
    feature = landed.accepted.branch
    assert feature == "mwt/login-feature"

    second =
      hand_off(
        username,
        vm,
        "tweak-login",
        "Tweak login",
        fn tree -> File.write!(Path.join(tree, "login.txt"), "second\n") end,
        feature
      )

    {:ok, view, _} = live(conn, ~p"/tools/sandbox/handoffs?id=#{second.id}")
    assert has_element?(view, "#handoff-onto option[value='#{feature}'][selected]", "base")
    assert has_element?(view, "#handoff-accept-button", "Land on #{feature}")
    assert has_element?(view, "#handoff-merges", feature)
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-accepted", feature)
    assert git(repo, ["show", feature <> ":login.txt"]) == "second\n"
    assert git(repo, ["show", "master:mix.exs"]) == "# the build\n"
  end

  test "while it waits, its worktree in the VM opens in Zed, to look at it again", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    test = self()

    MWTClient.StandIns.on_zed(username, fn address ->
      send(test, {:zed, address})
      :ok
    end)

    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-worktree[title$='app.wt/slot-1']", "slot-1")
    assert has_element?(view, "#handoff-information #handoff-vm", "slot-1")

    # The VM is stopped in tests, so the button is off; the event is sent as it would be.
    assert has_element?(view, "#handoff-open-zed[disabled]")
    render_click(view, "open_handoff_worktree", %{})
    assert_received {:zed, address}
    assert address =~ "app.wt/slot-1"
    assert has_element?(view, "#notices", "Opened in Zed")

    # Freed, its branch is in no worktree: its thread resumes it.
    {0, _} =
      Channel.answer(
        "worktree",
        %{"cwd" => Path.join(vm, "app.wt/slot-1"), "action" => "free"},
        username
      )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-worktree", "mwt worktree resume fix")
    refute has_element?(view, "#handoff-open-zed")

    # More work still opens the folder it was handed off from, where its
    # thread is in Zed's list.
    view |> element("#handoff-choose-more") |> render_click()
    view |> element("#handoff-open-thread") |> render_click()
    assert_received {:zed, address}
    assert address =~ "app.wt/slot-1"
    assert has_element?(view, "#notices", "its thread is “Fix the login thread”")
  end

  test "where it lands and how are chosen on the page: a new mwt/ branch", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    # Another worktree of your repository, on a branch of its own.
    side = repo <> "-release"
    git(repo, ["worktree", "add", "-q", side, "-b", "release"])
    on_exit(fn -> File.rm_rf!(side) end)

    handoff =
      hand_off(username, vm, "fix", "Fix the login", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-onto option[value=master][selected]")
    assert has_element?(view, "#handoff-onto option[value=release]", "checked out")

    # A new commit on a branch checked out elsewhere lands there.
    view |> form("#handoff-accept", accept: %{onto: "release"}) |> render_change()
    assert has_element?(view, "#handoff-merges", "Ready to land on release")
    assert has_element?(view, "#handoff-preview", "checked out at")

    # A new branch: its name starts with mwt/, then the task's branch.
    view |> form("#handoff-accept", accept: %{how: "branch"}) |> render_change()
    assert has_element?(view, "#handoff-how-branch[checked]")
    assert has_element?(view, "#handoff-branch-prefix", "mwt/")
    assert has_element?(view, "#handoff-new-branch[value=fix]")
    assert has_element?(view, "#handoff-merges", "Ready to create mwt/fix")
    assert has_element?(view, "#handoff-preview", "on top of release")
    assert has_element?(view, "#handoff-accept-button", "Create mwt/fix")

    view |> form("#handoff-accept", accept: %{name: "bad name"}) |> render_change()
    assert has_element?(view, "#handoff-preview", "Enter a valid Git branch name")
    assert has_element?(view, "#handoff-accept-button[disabled]")

    view |> form("#handoff-accept", accept: %{name: "login"}) |> render_change()
    view |> form("#handoff-accept") |> render_submit()

    assert has_element?(
             view,
             "#handoff-accepted",
             "Its commit as it is on a new branch, mwt/login, from release"
           )

    assert git(side, ["log", "-1", "--format=%s"]) == "first\n"
    assert git(repo, ["log", "-1", "--format=%s"]) == "first\n"
    assert git(repo, ["log", "-1", "--format=%s", "mwt/login"]) == "work on fix\n"

    assert {:ok, %{onto: "mwt/login", status: :accepted}} =
             HandoffRecords.get(username, handoff.id)
  end

  test "one made to break or mislead the page is shown with all it holds", %{
    conn: conn,
    username: username,
    vm: vm
  } do
    turn = <<0x202E::utf8>>

    handoff =
      hand_off(username, vm, "odd", "Tidy " <> turn <> "eteled", fn tree ->
        File.write!(Path.join(tree, <<"caf", 0xE9, ".txt">>), "a name that isn't UTF-8\n")
        File.write!(Path.join(tree, "safe" <> turn <> "txt.sh"), "echo hi\n")
        File.write!(Path.join(tree, "a.txt"), <<"one\n", 0xFF, 0xFE, " two\e[2J\nthree\n">>)
      end)

    {:ok, view, html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}&diff=1")

    # What the page is sent as: JSON, which takes UTF-8 only.
    assert String.valid?(html)
    assert {:ok, _} = Jason.encode(render(view))
    assert has_element?(view, "#handoff-title", "Tidy \\u{202E}eteled")
    assert has_element?(view, "#handoff-files", "\\u{1B}[2J")
    refute render(view) =~ turn
  end
end
