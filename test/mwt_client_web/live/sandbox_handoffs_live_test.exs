defmodule MWTClientWeb.SandboxHandoffsLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Handoffs, Projects}

  @me [
    {"GIT_AUTHOR_NAME", "Someone"},
    {"GIT_AUTHOR_EMAIL", "someone@example.test"},
    {"GIT_COMMITTER_NAME", "Someone"},
    {"GIT_COMMITTER_EMAIL", "someone@example.test"}
  ]

  defp git(dir, args) do
    {output, 0} =
      System.cmd("git", ["-C", dir | args], env: @me ++ Guest.git_env(), stderr_to_stdout: true)

    output
  end

  setup %{conn: conn} do
    context = sign_in(conn)
    base = Path.join(System.tmp_dir!(), "handoffs-live-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    repo = Path.join(base, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\nthree\n")
    File.write!(Path.join(repo, "mix.exs"), "# the build\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])
    # Who you commit as: a landing's commit is yours.
    git(repo, ["config", "user.name", "Someone"])
    git(repo, ["config", "user.email", "someone@example.test"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    MWTClient.StandIns.put_guest(context.username, Guest.local(vm))

    {:ok, _} = MWTClient.Sandbox.add_share(context.username, repo)
    {:ok, _} = Projects.open(context.username, repo)
    # Tasks go in slot-1, beside the clone (slot-0).
    {:ok, "slot-1"} = Projects.add_slot(context.username, "app")
    Map.merge(context, %{repo: repo, vm: vm})
  end

  # An agent's handoff: a task in a free worktree slot, from a thread
  # there, based on your master unless it says, with one commit, then
  # `mwt handoff`. `mwt worktree new` fetches origin first, as here.
  defp hand_off(username, vm, task, title, change, base \\ "master") do
    project = Enum.find(Sandbox.snapshot(username).projects, &(&1.name == "app"))

    git(Path.join(vm, "app"), ["fetch", "-q", project.path, "+refs/heads/*:refs/remotes/origin/*"])

    {:ok, %{slots: slots}} = Projects.slots(username, "app")
    %{path: free} = Enum.find(slots, &(&1.free? and &1.name != "slot-0"))

    {:ok, _project, %{path: tree}, :started, _onto, _where} =
      Projects.take_slot(username, free, :new, task, from: base)

    change.(tree)
    git(tree, ["add", "--all"])
    git(tree, ["commit", "-q", "-m", "work on #{task}"])

    {0, _} =
      Channel.answer(
        "handoff",
        %{
          "cwd" => tree,
          "title" => title,
          "body" => "Done, with tests.",
          "agent" => "claude",
          "thread" => "Fix the login thread"
        },
        username
      )

    [handoff | _] = Sandbox.snapshot(username).handoffs
    handoff
  end

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

    {:ok, _} = Handoffs.send_back(username, handoff.id, "add a test")
    assert handoffs.() == []

    # Handed off again, it waits for you again.
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

    # The decision, apart: the three ways it can end, Land chosen first.
    assert has_element?(view, "#handoff-decision-state", "Waiting for you")
    assert has_element?(view, "#handoff-choose-land[aria-selected=true]")
    assert has_element?(view, "#handoff-choose-send_back[aria-selected=false]")
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
    refute has_element?(view, "#handoff-send-back")
    view |> element("#handoff-choose-send_back") |> render_click()
    assert has_element?(view, "#handoff-send-back-button", "Send back to its thread")
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
    assert [%{onto: "mwt/login", status: :accepted}] = Sandbox.snapshot(username).handoffs
  end

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

  test "a landed handoff can be sent back for more; what landed stays", %{
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

    view
    |> form("#handoff-send-back", send_back: %{note: "The **login** page still 500s."})
    |> render_submit()

    assert has_element?(view, "#handoff-state", "Sent back")
    assert has_element?(view, "#handoff-timeline", "after landing it")
    assert has_element?(view, "#handoff-timeline strong", "login")
    assert git(repo, ["log", "-1", "--format=%s"]) == "work on fix\n"

    # The thread hears of it.
    {0, listed} =
      Channel.answer("handoffs", %{"cwd" => Path.join(vm, "app.wt/slot-1")}, username)

    assert listed =~ "The **login** page still 500s."
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

  test "one that conflicts can't land by accident; it goes back to its thread", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
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

    # Or it goes back, from the conflict's own words.
    view |> form("#handoff-accept", accept: %{onto: "release"}) |> render_change()
    view |> element("#handoff-conflicts button", "send it back") |> render_click()
    assert has_element?(view, "#handoff-choose-send_back[aria-selected=true]")

    view
    |> form("#handoff-send-back", send_back: %{note: "Catch up with my branch."})
    |> render_submit()

    # Its thread can't be told here (no VM runs), so the agent reads the
    # note in mwt handoffs; the word after it and the timeline say so.
    assert has_element?(view, "#notices", "Sent back. The VM isn't running.")
    assert has_element?(view, "#handoff-state", "Sent back")
    assert has_element?(view, "#handoff-timeline", "Catch up with my branch.")
    assert has_element?(view, "#handoff-timeline [id$='-delivery']", "mwt handoffs")
    # Sent, the panel is back on Land, the decision still yours.
    assert has_element?(view, "#handoff-decision-state", "Sent back")
    assert has_element?(view, "#handoff-choose-land[aria-selected=true]")
  end

  test "its branch moved under it: caught up here, or its thread asked to catch up, in one click",
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
    assert has_element?(view, "#handoff-ask-catch-up")
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

  test "where its changes conflict with its own branch, its thread is asked to catch up", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "a.txt"), "one\ntwo, from the vm\nthree\n")
      end)

    File.write!(Path.join(repo, "a.txt"), "one\ntwo, mine\nthree\n")
    git(repo, ["commit", "-q", "-am", "mine"])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-conflicts", "a.txt")
    # MWT can't resolve it: only its thread can, asked in one click.
    refute has_element?(view, "#handoff-catch-up-here")

    view |> element("#handoff-ask-catch-up") |> render_click()
    assert has_element?(view, "#notices", "Asked to catch up")
    assert has_element?(view, "#handoff-timeline", "You asked its thread to catch up")
    assert has_element?(view, "#handoff-timeline", "Catch up with master")
    assert has_element?(view, "#handoff-timeline", "a.txt")
    assert has_element?(view, "#handoff-decision-state", "Sent back")
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
