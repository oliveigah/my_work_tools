defmodule MWTClientWeb.SandboxProjectsLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Guest, Projects}
  alias MWTClientWeb.SandboxLive.Projects, as: Page

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
    base = Path.join(System.tmp_dir!(), "projects-live-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    shared = Path.join(base, "projects")
    repo = Path.join(shared, "app")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git(repo, ["add", "--all"])
    git(repo, ["commit", "-q", "-m", "first"])

    vm = Path.join(base, "vm")
    File.mkdir_p!(vm)
    MWTClient.StandIns.put_guest(context.username, Guest.local(vm))
    test = self()

    MWTClient.StandIns.on_zed(context.username, fn address ->
      send(test, {:zed, address})
      :ok
    end)

    Map.merge(context, %{repo: repo, shared: shared, vm: vm})
  end

  test "with no shared folder, the page says where projects come from", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-none-open", "No shared folder yet")
  end

  test "the page shows the open projects; Open project lists the others and opens one", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#projects-none-open", "No project open")
    refute has_element?(view, "#open-project-dialog")

    view |> element("#projects-open") |> render_click()
    assert has_element?(view, "#open-share-#{Page.key(shared)}", "projects")
    assert has_element?(view, "#open-repo-#{Page.key(repo)}", "app")
    assert has_element?(view, "#open-repo-#{Page.key(repo)}", "on master")

    # Filtered by what you type.
    view |> form("#open-project-filter", %{q: "nothing like it"}) |> render_change()
    refute has_element?(view, "#open-repo-#{Page.key(repo)}")
    assert has_element?(view, "#open-share-#{Page.key(shared)}", "Nothing matches.")
    view |> form("#open-project-filter", %{q: "APP"}) |> render_change()

    view |> element("#open-repo-button-#{Page.key(repo)}") |> render_click()
    refute has_element?(view, "#open-project-dialog")
    assert has_element?(view, "#notices", "app opened")
    assert has_element?(view, "#project-app", "app")
    assert [%{name: "app", closed: false}] = Sandbox.snapshot(username).projects

    # Opened, it isn't offered again.
    view |> element("#projects-open") |> render_click()
    refute has_element?(view, "#open-repo-#{Page.key(repo)}")
    render_click(view, "close_dialog", %{})

    # The VM is stopped in tests, so the button is off; the event is sent as it would be.
    assert has_element?(view, "#project-zed-app[disabled]")
    render_click(view, "open_project", %{"path" => "app"})

    mirror = Path.join(vm, "app")
    assert_received {:zed, "ssh://mwt-sandbox" <> ^mirror}
    assert has_element?(view, "#notices", "app opened in Zed")
    assert has_element?(view, "#project-clone-app", "clone /work/app")
    assert File.read!(Path.join(mirror, "a.txt")) == "one\n"
  end

  test "a closed project leaves the page and comes back from Open project", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-app")

    view |> element("#project-close-app") |> render_click()
    assert has_element?(view, "#notices", "app closed")
    refute has_element?(view, "#project-app")
    assert [%{name: "app", closed: true}] = Sandbox.snapshot(username).projects

    view |> element("#projects-open") |> render_click()
    assert has_element?(view, "#open-project-closed #open-closed-app", "app")
    refute has_element?(view, "#open-repo-#{Page.key(repo)}")
    view |> element("#open-closed-button-app") |> render_click()
    assert has_element?(view, "#project-app")
    assert [%{name: "app", closed: false}] = Sandbox.snapshot(username).projects
  end

  test "Open project looks deeper in a shared folder, one folder at a time", %{
    conn: conn,
    username: username,
    shared: shared
  } do
    deep = Path.join(shared, "a/b/c/d/e")
    File.mkdir_p!(deep)
    git(deep, ["init", "-q", "-b", "main"])
    File.write!(Path.join(deep, "x.txt"), "x\n")
    git(deep, ["add", "--all"])
    git(deep, ["commit", "-q", "-m", "x"])

    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    view |> element("#projects-open") |> render_click()
    refute has_element?(view, "#open-repo-#{Page.key(deep)}")

    view |> element("#open-share-browse-#{Page.key(shared)}") |> render_click()
    assert has_element?(view, "#browse-#{Page.key(Path.join(shared, "a"))}", "a")
    assert has_element?(view, "#browse-open-#{Page.key(Path.join(shared, "app"))}")

    render_click(view, "browse", %{"path" => Path.join(shared, "a/b/c/d")})
    assert has_element?(view, "#browse-path", "d")
    view |> element("#browse-open-#{Page.key(deep)}") |> render_click()
    assert has_element?(view, "#project-e")

    # Out of a shared folder, nothing is listed.
    view |> element("#projects-open") |> render_click()
    render_click(view, "browse", %{"path" => Path.dirname(shared)})
    assert has_element?(view, "#browse-error", "isn't in a shared folder")
    view |> element("#browse-back") |> render_click()
    assert has_element?(view, "#open-project-filter")
  end

  test "projects are listed by when they were last used, most recent first", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    other = Path.join(shared, "zeta")
    File.mkdir_p!(other)
    git(other, ["init", "-q", "-b", "master"])
    File.write!(Path.join(other, "a.txt"), "one\n")
    git(other, ["add", "--all"])
    git(other, ["commit", "-q", "-m", "first"])

    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, app} = Projects.open(username, repo)
    {:ok, zeta} = Projects.open(username, other)

    order = fn ->
      {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")

      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("section[id^=project-]")
      |> LazyHTML.attribute("id")
    end

    hour_ago = DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)
    {:ok, _} = Sandbox.Server.call(username, {:put_project, %{app | last_used_at: hour_ago}, "t"})
    assert order.() == ["project-zeta", "project-app"]

    {:ok, _} =
      Sandbox.Server.call(username, {:put_project, %{zeta | last_used_at: hour_ago}, "t"})

    :ok = Projects.used(username, app.name)
    assert order.() == ["project-app", "project-zeta"]
  end

  test "an open project shows your branches, as host-origin has them", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    git(repo, ["branch", "develop"])
    {:ok, _} = Projects.mirror(username, "app")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-branches-app", "2 branches on host-origin")
    assert has_element?(view, "#project-branches-app code", "develop")

    assert has_element?(
             view,
             "#project-branches-app code[title^='host-origin/master at']",
             "master"
           )

    # No setting picks a branch any more.
    refute has_element?(view, "#project-mirrored-branch-app")
  end

  test "an open project says so when commits in the VM would have no author", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    git(repo, ["config", "user.name", "You"])
    git(repo, ["config", "user.email", "you@example.test"])
    {:ok, _} = Projects.open(username, repo)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    refute has_element?(view, "#project-identity-app")

    # An empty name here hides any global one: none, and the page says how to set it.
    git(repo, ["config", "user.name", ""])
    {:ok, _} = Projects.open(username, repo)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-identity-app", "no user.name and user.email")
  end

  test "an open project's checks are edited in place, and checked", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-app", "no checks")
    refute has_element?(view, "#project-checks-form-app")
    view |> element("#project-checks-edit-app") |> render_click()

    view
    |> form("#project-checks-form-app", project: %{checks: String.duplicate("x", 301)})
    |> render_submit()

    assert has_element?(view, "#project-settings-error-app", "at most 300 characters")

    view
    |> form("#project-checks-form-app", project: %{checks: " mix precommit "})
    |> render_submit()

    assert has_element?(view, "#notices", "Checks of app saved")
    refute has_element?(view, "#project-checks-form-app")
    assert has_element?(view, "#project-checks-shown-app", "mix precommit")

    assert [%{mirrored_branch: "master", slots: [], checks: "mix precommit"}] =
             Sandbox.snapshot(username).projects
  end

  test "the page opens at once; the slots follow, read from the VM apart from the page", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    server = MWTClient.Vault.Store.whereis(Sandbox.Server, username)
    :sys.replace_state(server, &%{&1 | vm: %{&1.vm | exists?: true, status: :running}})
    test = self()
    local = Guest.local(vm)

    # A VM whose answers about the slots and Zed's windows come only when
    # the test says so. The server's own updates of the mirror, which make
    # slots, go through.
    slow = %{
      local
      | exec: fn words ->
          case words do
            ["sh", "-c", script, "mwt-slots" | _] ->
              if script =~ "worktree list --porcelain",
                do: wait(test, :slots, words, local),
                else: local.exec.(words)

            ["/bin/sh", "-c", script] ->
              if script =~ "zed-remote-server",
                do: wait(test, :zed, words, local),
                else: local.exec.(words)

            words ->
              local.exec.(words)
          end
        end
    }

    MWTClient.StandIns.put_guest(username, slow)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")

    assert has_element?(view, "#project-app")
    assert has_element?(view, "#project-slots-reading-app")
    refute has_element?(view, "#project-slots-app")

    # Its two trips into the VM go side by side.
    assert_receive {:reading, :slots, slots}
    assert_receive {:reading, :zed, zed}
    Enum.each([slots, zed], &send(&1, :go))
    # Real git reads, slower than render_async's 100 ms under a full run.
    render_async(view, 5_000)

    refute has_element?(view, "#project-slots-reading-app")
    assert has_element?(view, "#slot-state-app-slot-0", "free")
    assert has_element?(view, "#slot-app-slot-0", "the clone")

    # Every few seconds the page reads them again, by itself.
    MWTClient.StandIns.put_guest(username, local)

    cwd = Path.join(vm, "app")
    thread = "test-thread"

    {:ok, _, _, :started, _, _} =
      Projects.take_slot(username, cwd, :new, "fix", from: "master", thread: thread)

    send(view.pid, :projects_tick)
    render_async(view, 5_000)
    assert has_element?(view, "#slot-state-app-slot-0", "busy")
    assert has_element?(view, "#slot-timeline-app-slot-0 option[value=default][selected]", "off")

    view |> form("#slot-timeline-app-slot-0-form", mode: "on") |> render_change()
    assert has_element?(view, "#slot-timeline-app-slot-0 option[value=on][selected]")

    assert {0, _} =
             Channel.answer("summary", %{"cwd" => cwd, "text" => "Checked the mirror."}, username)

    view |> form("#slot-timeline-app-slot-0-form", mode: "off") |> render_change()

    assert {1, _} =
             Channel.answer("summary", %{"cwd" => cwd, "text" => "Do not record."}, username)

    view |> form("#slot-timeline-app-slot-0-form", mode: "default") |> render_change()
    assert has_element?(view, "#slot-timeline-app-slot-0 option[value=default][selected]")
    send(view.pid, :projects_tick)
    render_async(view, 5_000)

    view |> element("#slot-summary-app-slot-0 li button", "Details") |> render_click()
    assert has_element?(view, "#summary-entry-document-rendered", "Checked the mirror.")

    send(view.pid, :projects_tick)
    render_async(view, 5_000)
    assert has_element?(view, "#summary-entry-dialog-title", "Checked the mirror.")

    render_patch(view, ~p"/tools/sandbox/handoffs")
    refute has_element?(view, "#summary-entry-dialog")
  end

  defp wait(test, what, words, local) do
    send(test, {:reading, what, self()})

    receive do
      :go -> local.exec.(words)
    end
  end

  test "slots are added and removed from the page, one at a time", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")

    view |> element("#slot-add-app") |> render_click()
    assert has_element?(view, "#notices", "slot-1 added to app")
    assert File.dir?(Path.join(vm, "app.wt/slot-1"))
    assert [%{slots: [1]}] = Sandbox.snapshot(username).projects

    view |> element("#slot-add-app") |> render_click()
    assert has_element?(view, "#notices", "slot-2 added to app")
    assert File.dir?(Path.join(vm, "app.wt/slot-2"))
    assert [%{slots: [1, 2]}] = Sandbox.snapshot(username).projects

    render_click(view, "remove_slot", %{"name" => "app", "slot" => "slot-1"})
    assert has_element?(view, "#notices", "slot-1 removed from app")
    refute File.exists?(Path.join(vm, "app.wt/slot-1"))
    assert [%{slots: [2]}] = Sandbox.snapshot(username).projects

    # A slot a task holds stays, until you free it.
    two = Path.join(vm, "app.wt/slot-2")
    {:ok, _, _, :started, _, _} = Projects.take_slot(username, two, :new, "fix", from: "master")
    render_click(view, "remove_slot", %{"name" => "app", "slot" => "slot-2"})
    assert has_element?(view, "#notices", "slot-2 stays")
    assert [%{slots: [2]}] = Sandbox.snapshot(username).projects

    render_click(view, "free_slot", %{"name" => "app", "slot" => "slot-2"})
    assert has_element?(view, "#notices", "slot-2 of app released")
    # Nothing of its own: its branch goes with the release.
    assert has_element?(view, "#notices", "fix was deleted: nothing needed it.")
    assert git(two, ["branch", "--show-current"]) == ""
    assert git(Path.join(vm, "app"), ["branch", "--list", "fix"]) == ""
  end

  test "Prune branches deletes the task branches nothing needs, and says why the rest stay", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    clone = Path.join(vm, "app")

    # Left behind by tasks before MWT pruned on free: one with nothing of
    # its own, one with a commit found nowhere else; and a branch of the
    # VM's own, which no task started.
    for task <- ["explored", "spike"] do
      git(clone, ["branch", "--no-track", task, "host-origin/master"])
      git(clone, ["config", "branch.#{task}.mwt-base", "refs/remotes/host-origin/master"])
    end

    git(clone, ["branch", "--no-track", "mine", "host-origin/master"])
    spike = Path.join(Path.dirname(vm), "spike")
    git(clone, ["worktree", "add", "-q", spike, "spike"])
    File.write!(Path.join(spike, "b.txt"), "spike\n")
    git(spike, ["add", "--all"])
    git(spike, ["commit", "-q", "-m", "spike"])
    git(clone, ["worktree", "remove", spike])

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    view |> element("#branches-prune-app") |> render_click()

    assert has_element?(view, "#notices", "Deleted 1 task branch of app")
    assert has_element?(view, "#notices", "explored.")

    assert has_element?(
             view,
             "#notices",
             "Kept: spike, as 1 commit on it is on none of your branches."
           )

    assert git(clone, ["branch", "--list", "explored"]) == ""
    refute git(clone, ["config", "--list", "--local"]) =~ "branch.explored."
    assert git(clone, ["branch", "--list", "spike", "mine"]) =~ "spike"
    assert git(clone, ["branch", "--list", "mine"]) =~ "mine"
  end

  test "a project left in the VM is listed with what would go with it, and removed", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    File.rm_rf!(repo)
    {:ok, left} = MWTClient.Sandbox.Leftovers.list(username)

    html =
      render_component(&Page.page/1,
        overview: Projects.overview(username),
        mirror: %{},
        waiting_handoffs: [],
        editing: nil,
        dialog: nil,
        worktrees: %{},
        leftovers: {:ok, left},
        vm: %{status: :running},
        now: DateTime.utc_now()
      )

    page = LazyHTML.from_fragment(html)
    assert page |> LazyHTML.query("#leftover-app") |> LazyHTML.text() =~ "its repository is gone"
    assert page |> LazyHTML.query("#leftover-remove-app[data-confirm]") |> Enum.count() == 1

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    render_click(view, "remove_leftover", %{"name" => "app"})
    assert has_element?(view, "#notices", "app removed from the VM")
    refute File.exists?(Path.join(vm, "app"))
  end

  test "a project whose folder is no longer shared says so, and is forgotten", %{
    conn: conn,
    username: username,
    repo: repo,
    shared: shared
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    :ok = Sandbox.remove_share(username, shared)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/projects")
    assert has_element?(view, "#project-clone-app", "no longer shared")
    refute has_element?(view, "#project-close-app")
    view |> element("#project-forget-app") |> render_click()
    refute has_element?(view, "#project-app")
    assert Sandbox.snapshot(username).projects == []
  end

  test "an opened project shows its worktree slots: which are free, and what the others hold", %{
    username: username,
    repo: repo,
    shared: shared,
    vm: vm
  } do
    {:ok, _} = Sandbox.add_share(username, shared)
    {:ok, _} = Projects.open(username, repo)
    {:ok, "slot-1"} = Projects.add_slot(username, "app")
    {:ok, "slot-2"} = Projects.add_slot(username, "app")
    {:ok, "slot-3"} = Projects.add_slot(username, "app")
    mirror = Path.join(vm, "app")

    {:ok, _, _, :started, _, _} =
      Projects.take_slot(username, "#{mirror}.wt/slot-1", :new, "fix", from: "master")

    {:ok, _, _, :started, _, _} =
      Projects.take_slot(username, "#{mirror}.wt/slot-2", :new, "cart", from: "master")

    assert {:ok, _} = Sandbox.update_settings(username, %{"timeline_recording" => true})

    for line <- ["Started", "Chose a design", "Implemented it", "Ready for review"] do
      assert {0, _} =
               Channel.answer(
                 "summary",
                 %{"cwd" => "#{mirror}.wt/slot-1", "text" => line},
                 username
               )
    end

    File.write!(Path.join(vm, "app.wt/slot-2/a.txt"), "changed\n")
    old = Path.join(vm, "app.wt/push-options")

    git(mirror, [
      "worktree",
      "add",
      "-q",
      "--no-track",
      "-b",
      "push-options",
      old,
      "host-origin/master"
    ])

    snapshot = Sandbox.snapshot(username)
    # A Zed window with slot-1 open.
    {:ok, look} = Projects.slots(username, "app")

    look =
      update_in(
        look.slots,
        &Enum.map(&1, fn slot -> %{slot | in_zed?: slot.name == "slot-1"} end)
      )

    html =
      render_component(&Page.page/1,
        overview: Projects.overview(username),
        mirror: snapshot.mirror,
        waiting_handoffs: snapshot.waiting_handoffs,
        editing: nil,
        dialog: nil,
        worktrees: %{"app" => {:ok, look}},
        vm: %{status: :running},
        now: DateTime.utc_now()
      )

    page = LazyHTML.from_fragment(html)
    text = fn selector -> page |> LazyHTML.query(selector) |> LazyHTML.text() end

    assert String.trim(text.("#slot-summary-app-slot-1-label")) == "Summary timeline"
    assert text.("#slot-summary-app-slot-1 > summary") =~ "Ready for review"
    assert page |> LazyHTML.query("#slot-summary-app-slot-1 li") |> Enum.count() == 4

    assert page |> LazyHTML.query("#slot-summary-app-slot-1 li time[datetime]") |> Enum.count() ==
             4

    assert text.("#slot-summary-app-slot-1 li:first-child") =~ "Started"
    assert text.("#slot-summary-app-slot-1 li:last-child") =~ "Ready for review"
    assert Enum.empty?(LazyHTML.query(page, "#slot-summary-app-slot-3"))

    # slot-0, the clone, on its own master, and slot-3 are free.
    assert text.("#project-slots-free-app") =~ "2 of 4 free"
    assert text.("#slot-app-slot-0") =~ "the clone"
    assert LazyHTML.query(page, "#slot-remove-app-slot-0[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-free-app-slot-0") |> Enum.count() == 0
    assert text.("#slot-state-app-slot-1") =~ "busy"
    assert text.("#slot-app-slot-1") =~ "fix" and text.("#slot-app-slot-1") =~ "no handoff yet"
    # Each task says the branch it started from.
    assert text.("#slot-base-app-slot-1") =~ "from master"
    assert text.("#slot-state-app-slot-2") =~ "uncommitted"
    # Made with the mirror: free, and it opens in Zed before any task.
    assert text.("#slot-state-app-slot-3") =~ "free"
    assert text.("#slot-app-slot-3") =~ "ready for the next task"
    assert LazyHTML.query(page, "#slot-zed-app-slot-3:not([disabled])") |> Enum.count() == 1
    assert text.("#project-worktrees-app") =~ "push-options"

    # Only the free one can be removed; one more can be added.
    assert LazyHTML.query(page, "#slot-remove-app-slot-3:not([disabled])") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-remove-app-slot-1[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-remove-app-slot-2[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-add-app:not([disabled])") |> Enum.count() == 1

    # The one a task holds can be freed; one with uncommitted work can't
    # yet; a free one needs nothing.
    assert LazyHTML.query(page, "#slot-free-app-slot-1:not([disabled])") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-free-app-slot-2[disabled]") |> Enum.count() == 1
    assert LazyHTML.query(page, "#slot-free-app-slot-3") |> Enum.count() == 0

    # A thread may be working where a Zed window has the slot open; a held
    # one no window has open may be a gone thread's, for you to free.
    assert text.("#slot-in-zed-app-slot-1") =~ "open in Zed"
    assert LazyHTML.query(page, "#slot-in-zed-app-slot-3") |> Enum.count() == 0
    assert text.("#slot-no-zed-app-slot-2") =~ "no Zed window open"
    assert LazyHTML.query(page, "#slot-no-zed-app-slot-1") |> Enum.count() == 0
    assert LazyHTML.query(page, "#slot-no-zed-app-slot-3") |> Enum.count() == 0
  end
end
