defmodule MWTClientWeb.GitLive.WorkingTreeTest do
  # The working tree, stashes and diffs, and the errors and conflicts that
  # come of acting on them.
  use MWTClientWeb.ConnCase, async: true

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  setup {MWTClientWeb.GitLiveHelpers, :tool}

  defp notice_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#notices > *")
    |> LazyHTML.attribute("id")
  end

  ## Errors and conflicts

  test "a failed command shows the typed error", context do
    %{view: view, path: path} = context
    open(view, path)

    render_hook(view, "request", %{"action" => "merge", "revision" => "does-not-exist"})
    render_async(view)

    assert count(view, "#notices > [role=alert]") == 1
    assert render(view) =~ "Git reported a problem"
  end

  test "successful actions stack and each notice can be dismissed", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    File.write!(Path.join(path, "two.txt"), "two\n")
    open(view, path)

    render_hook(view, "request", %{"action" => "stage_path", "path" => "one.txt"})
    render_async(view)
    [first] = notice_ids(view)

    render_hook(view, "request", %{"action" => "stage_path", "path" => "two.txt"})
    render_async(view)
    [^first, second] = notice_ids(view)

    assert first != second

    assert count(view, "#notices > [role=status][phx-hook=NoticeTimer][data-timeout='6000']") ==
             2

    view
    |> element("#dismiss-notice-#{String.replace_prefix(first, "notice-", "")}")
    |> render_click()

    assert notice_ids(view) == [second]
  end

  test "errors stay until dismissed and appear before successes", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    open(view, path)

    render_hook(view, "request", %{"action" => "stage_path", "path" => "one.txt"})
    render_async(view)
    [success] = notice_ids(view)

    render_hook(view, "request", %{"action" => "merge", "revision" => "does-not-exist"})
    render_async(view)
    [first_error, ^success] = notice_ids(view)
    assert has_element?(view, "##{first_error}[role=alert]")

    render_hook(view, "request", %{"action" => "merge", "revision" => "still-does-not-exist"})
    render_async(view)
    [^first_error, second_error, ^success] = notice_ids(view)

    render_hook(view, "request", %{"action" => "unstage_path", "path" => "one.txt"})
    render_async(view)
    [^first_error, ^second_error, ^success, later_success] = notice_ids(view)

    view |> element("#git-refresh") |> render_click()
    render_async(view)
    assert notice_ids(view) == [first_error, second_error, success, later_success]

    view
    |> element("#dismiss-notice-#{String.replace_prefix(first_error, "notice-", "")}")
    |> render_click()

    assert notice_ids(view) == [second_error, success, later_success]
  end

  test "notices float outside the panels and outlive switching tabs", context do
    %{view: view, path: path, base: base} = context

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    git!(other, ["config", "user.name", "MWT Test"])
    git!(other, ["config", "user.email", "mwt@example.test"])
    commit_file(other, "other.txt", "other\n", "other commit")

    open(view, path)
    open(view, other)

    render_hook(view, "request", %{"action" => "merge", "revision" => "does-not-exist"})
    render_async(view)

    [notice] = notice_ids(view)
    refute has_element?(view, "#git-inspector ##{notice}")
    assert has_element?(view, "##{notice}", "other")

    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    assert notice_ids(view) == [notice]
  end

  test "a conflict moves the inspector into resolution mode", context do
    %{view: view, path: path} = context

    git!(path, ["checkout", "-b", "side"])
    commit_file(path, "conflict.txt", "side\n", "side change")
    git!(path, ["checkout", "main"])
    commit_file(path, "conflict.txt", "main\n", "main change")

    open(view, path)

    render_hook(view, "request", %{"action" => "merge", "revision" => "side"})
    render_async(view)

    assert has_element?(view, "#git-operation")
    assert has_element?(view, "#git-operation-continue")
    assert has_element?(view, "#git-operation-abort")
    assert has_element?(view, "#git-operation-skip[disabled]")
    assert render(view) =~ "Merge in progress"
    assert has_element?(view, "#git-working-tree")
    assert render(view) =~ "conflict.txt"

    view |> element("#git-operation-abort") |> render_click()
    assert has_element?(view, "#git-confirm")
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-operation")
  end

  ## Working tree

  test "lists staged and unstaged changes with empty states", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()

    # Both sides stay on screen even when they are empty, unstaged first.
    assert has_element?(view, "#git-unstaged")
    assert has_element?(view, "#git-staged")
    assert has_element?(view, "#git-unstaged-empty")
    assert has_element?(view, "#git-staged-empty")
    assert has_element?(view, "#git-stashes-empty")

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "new.txt"), "new\n")
    git!(path, ["add", "--", "new.txt"])

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-staged")
    assert has_element?(view, "#git-unstaged")
    assert has_element?(view, "#git-file-staged-#{slug("new.txt")}")
    assert has_element?(view, "#git-file-unstaged-#{slug("README.md")}")
  end

  # What the file list's hook sends on a right click.
  defp file_menu(view, path, side \\ "unstaged") do
    render_hook(view, "open_menu", %{
      "kind" => "file",
      "id" => path,
      "side" => side,
      "anchor" => "git-file-row-#{side}-#{slug(path)}",
      "x" => 10,
      "y" => 10
    })

    view
  end

  defp click_file(view, path, modifiers \\ %{}, side \\ "unstaged") do
    view |> element("#git-file-#{side}-#{slug(path)}") |> render_click(modifiers)
    view
  end

  defp selected_files(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#git-working-tree [role=option][aria-selected=true]")
    |> LazyHTML.attribute("id")
  end

  defp file_ids(side, paths), do: Enum.map(paths, &"git-file-#{side}-#{slug(&1)}")

  test "a click picks one file, Ctrl adds or drops one, Shift takes a range", context do
    %{view: view, path: path} = context
    for name <- ~w(a b c d e), do: File.write!(Path.join(path, "#{name}.txt"), name)
    open(view, path)
    view |> element("#git-panel-changes") |> render_click()

    assert selected_files(view) == []

    click_file(view, "b.txt")
    assert selected_files(view) == file_ids("unstaged", ~w(b.txt))

    # A plain click starts over.
    click_file(view, "d.txt")
    assert selected_files(view) == file_ids("unstaged", ~w(d.txt))

    click_file(view, "a.txt", %{"ctrlKey" => true})
    click_file(view, "e.txt", %{"metaKey" => true})
    assert selected_files(view) == file_ids("unstaged", ~w(a.txt d.txt e.txt))

    click_file(view, "d.txt", %{"ctrlKey" => true})
    assert selected_files(view) == file_ids("unstaged", ~w(a.txt e.txt))

    # Shift reaches from the file clicked last, d, and replaces the rest.
    click_file(view, "b.txt", %{"shiftKey" => true})
    assert selected_files(view) == file_ids("unstaged", ~w(b.txt c.txt d.txt))

    # With Ctrl held too, the range adds to what is already picked.
    click_file(view, "a.txt", %{"ctrlKey" => true})
    click_file(view, "c.txt", %{"shiftKey" => true, "ctrlKey" => true})
    assert selected_files(view) == file_ids("unstaged", ~w(a.txt b.txt c.txt d.txt))

    view |> element("#git-clear-paths") |> render_click()
    assert selected_files(view) == []

    view |> element("#git-select-all-paths") |> render_click()
    assert length(selected_files(view)) == 5
  end

  test "a Shift range runs on from the unstaged list into the staged one", context do
    %{view: view, path: path} = context
    for name <- ~w(a b c), do: File.write!(Path.join(path, "#{name}.txt"), name)
    git!(path, ["add", "a.txt"])
    open(view, path)
    view |> element("#git-panel-changes") |> render_click()

    click_file(view, "c.txt")
    click_file(view, "a.txt", %{"shiftKey" => true}, "staged")

    assert selected_files(view) ==
             file_ids("unstaged", ~w(c.txt)) ++ file_ids("staged", ~w(a.txt))

    # A Shift click with nothing picked yet just picks the one file.
    view |> element("#git-clear-paths") |> render_click()
    click_file(view, "b.txt", %{"shiftKey" => true})
    assert selected_files(view) == file_ids("unstaged", ~w(b.txt))
  end

  test "the file menu counts what each action would touch", context do
    %{view: view, path: path} = context
    for name <- ~w(one two three), do: File.write!(Path.join(path, "#{name}.txt"), name)
    git!(path, ["add", "one.txt"])
    open(view, path)
    view |> element("#git-panel-changes") |> render_click()

    view |> element("#git-select-all-paths") |> render_click()
    file_menu(view, "two.txt")

    assert has_element?(view, "#git-file-menu[role=menu]")
    assert view |> element("#git-menu-stage-files") |> render() =~ "Stage 2 files"
    assert view |> element("#git-menu-unstage-files") |> render() =~ "Unstage 1 file"
    assert view |> element("#git-menu-stash-files") |> render() =~ "Stash 3 files"
    assert view |> element("#git-menu-discard-files") |> render() =~ "Discard 3 files"
    assert view |> element("#git-menu-view-file") |> render() =~ "two.txt"

    # A right click outside the selection picks that file alone, and with
    # nothing staged among the pick there is nothing to unstage.
    render_hook(view, "close_menu", %{})
    click_file(view, "one.txt", %{}, "staged")
    file_menu(view, "three.txt")

    assert selected_files(view) == file_ids("unstaged", ~w(three.txt))
    assert view |> element("#git-menu-stage-files") |> render() =~ "Stage 1 file"
    refute has_element?(view, "#git-menu-unstage-files")
  end

  test "stages and unstages the selected paths from the file menu", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "one.txt"), "one\n")
    File.write!(Path.join(path, "two.txt"), "two\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    click_file(view, "one.txt")
    file_menu(view, "one.txt")
    view |> element("#git-menu-stage-files") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == "one.txt"
    assert has_element?(view, "#git-file-staged-#{slug("one.txt")}")
    refute has_element?(view, "#git-file-staged-#{slug("two.txt")}")
    refute has_element?(view, "#git-file-menu")

    # The refresh keeps the path selected, so it can be sent straight back.
    assert has_element?(view, "#git-file-staged-#{slug("one.txt")}[aria-selected=true]")
    file_menu(view, "one.txt", "staged")
    view |> element("#git-menu-unstage-files") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == ""
  end

  test "the file menu opens a diff of the file under the pointer", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "changed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    file_menu(view, "README.md")
    view |> element("#git-menu-view-file") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-file-menu")
    assert render(view) =~ "changed"
    assert has_element?(view, "#git-diff-unstaged-#{slug("README.md")}")
  end

  test "stashes only the selected paths and lists the stash", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "untouched.txt"), "untouched\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    click_file(view, "README.md")

    # The message box only turns up once stashing is the decision.
    refute has_element?(view, "#git-stash-message")
    file_menu(view, "README.md")
    view |> element("#git-menu-stash-files") |> render_click()
    assert has_element?(view, "#git-stash-message")
    refute has_element?(view, "#git-file-menu")

    view
    |> form("#git-stash-form", %{"message" => "just the readme", "include_untracked" => "true"})
    |> render_submit()

    render_async(view)

    assert git!(path, ["status", "--porcelain", "--", "README.md"]) == ""
    assert File.exists?(Path.join(path, "untouched.txt"))
    assert has_element?(view, "#git-stash-0")
    assert render(view) =~ "just the readme"
    # And it folds away again once the stash exists.
    refute has_element?(view, "#git-stash-message")
    assert render(view) =~ "complete stash"

    view |> element("#git-stash-pop-0") |> render_click()
    render_async(view)

    assert File.read!(Path.join(path, "README.md")) == "changed\n"
    assert has_element?(view, "#git-stashes-empty")
  end

  test "discards only the selected paths once confirmed", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "scratch.txt"), "scratch\n")
    File.write!(Path.join(path, "keep.txt"), "keep\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    click_file(view, "README.md")
    click_file(view, "scratch.txt", %{"ctrlKey" => true})
    file_menu(view, "scratch.txt")
    view |> element("#git-menu-discard-files") |> render_click()

    # Nothing is lost until the question is answered.
    assert has_element?(view, "#git-confirm")
    assert render(view) =~ "Discard changes to 2 files?"
    assert File.read!(Path.join(path, "README.md")) == "changed\n"
    assert File.exists?(Path.join(path, "scratch.txt"))

    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert File.read!(Path.join(path, "README.md")) == "initial\n"
    refute File.exists?(Path.join(path, "scratch.txt"))
    assert File.read!(Path.join(path, "keep.txt")) == "keep\n"
    refute has_element?(view, "#git-file-unstaged-#{slug("README.md")}")
    assert has_element?(view, "#git-file-unstaged-#{slug("keep.txt")}[aria-selected=false]")
    assert selected_files(view) == []
  end

  test "a discard can be called off", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "changed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    file_menu(view, "README.md")
    view |> element("#git-menu-discard-files") |> render_click()
    view |> element("#git-confirm-cancel") |> render_click()

    refute has_element?(view, "#git-confirm")
    assert File.read!(Path.join(path, "README.md")) == "changed\n"
    assert has_element?(view, "#git-file-unstaged-#{slug("README.md")}[aria-selected=true]")
  end

  test "committing the staged files refreshes the graph", context do
    %{view: view, path: path} = context

    File.write!(Path.join(path, "committed.txt"), "committed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)

    view |> form("#git-commit-form", %{"message" => "from the inspector"}) |> render_submit()
    render_async(view)

    assert git!(path, ["log", "-1", "--format=%s"]) == "from the inspector"
    assert render(view) =~ "from the inspector"
    assert count(view, "#git-commits [role=option]") == 2
  end

  test "coming back finds a repository's selection and drafts as they were left", context do
    %{conn: conn, view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    File.write!(Path.join(path, "committed.txt"), "committed\n")
    open(view, path)

    view |> element("#git-select-commit-#{initial}") |> render_click()
    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)

    view
    |> form("#git-commit-form", %{"message" => "half written", "no_verify" => "true"})
    |> render_change()

    {:ok, view, _html} = live(conn, ~p"/tools/git")
    # The repository opens, then the commit picked has its files read.
    render_async(view, 2_000)
    render_async(view, 2_000)

    assert has_element?(view, "#git-select-commit-#{initial}[aria-selected=true]")
    assert has_element?(view, "#git-commit-message", "half written")
    assert has_element?(view, "#git-commit-no-verify[checked]")
  end

  test "a commit gone since is let go, for the head", context do
    %{conn: conn, view: view, path: path} = context
    gone = commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)
    view |> element("#git-select-commit-#{gone}") |> render_click()

    git!(path, ["reset", "--hard", "HEAD~1"])
    git!(path, ["reflog", "expire", "--expire=now", "--all"])

    {:ok, view, _html} = live(conn, ~p"/tools/git")
    render_async(view, 2_000)

    refute has_element?(view, "#git-select-commit-#{gone}")
    assert has_element?(view, "#git-select-commit-#{head_commit(path)}[aria-selected=true]")
  end

  test "a commit draft survives a refresh", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "committed.txt"), "committed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)

    view
    |> form("#git-commit-form", %{"message" => "half written", "no_verify" => "true"})
    |> render_change()

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-message", "half written")
    assert has_element?(view, "#git-commit-no-verify[checked]")
  end

  test "skipping hooks commits past a refusing pre-commit hook, once", context do
    %{view: view, path: path, initial_commit: initial} = context
    failing_hook!(path, "pre-commit")
    File.write!(Path.join(path, "committed.txt"), "committed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)

    view |> form("#git-commit-form", %{"message" => "checked"}) |> render_submit()
    render_async(view)
    assert git!(path, ["rev-parse", "HEAD"]) == initial
    assert has_element?(view, "#notices [role=alert]")

    view
    |> form("#git-commit-form", %{"message" => "unchecked", "no_verify" => "true"})
    |> render_submit()

    render_async(view)
    assert git!(path, ["log", "-1", "--format=%s"]) == "unchecked"

    File.write!(Path.join(path, "next.txt"), "next\n")
    view |> element("#git-refresh") |> render_click()
    render_async(view)
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-commit-no-verify[checked]")
  end

  ## Stashes, working tree and the WIP row

  test "stashes are listed in the branch panel", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "changed\n")
    open(view, path)

    assert count(view, "#git-branches #git-stashes-empty") == 1

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-select-all-paths") |> render_click()
    file_menu(view, "README.md")
    view |> element("#git-menu-stash-files") |> render_click()

    view
    |> form("#git-stash-form", %{"message" => "left panel stash", "include_untracked" => "true"})
    |> render_submit()

    render_async(view)

    # The list belongs to the branch panel, not the inspector.
    assert count(view, "#git-branches #git-stashes") == 1
    assert count(view, "#git-inspector #git-stashes") == 0
    assert view |> element("#git-branches #git-stash-0") |> render() =~ "left panel stash"

    view |> element("#git-stashes-toggle") |> render_click()
    refute has_element?(view, "#git-stashes")
  end

  test "a stash hangs off the commit it was made on, drawn as a box", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "parked\n")
    git!(path, ["stash", "push", "--quiet", "--message", "parked work"])
    stash = git!(path, ["rev-parse", "stash@{0}"])
    head = head_commit(path)

    open(view, path)

    row = "#git-graph-stash-#{stash}"
    assert has_element?(view, row)
    assert view |> element(row) |> render() =~ "parked work"
    assert has_element?(view, "#{row} svg rect")
    refute has_element?(view, "#{row} svg circle")
    assert has_element?(view, "#git-commit-#{head} svg circle")

    # The stash is its own row, right above its commit; Git's bookkeeping
    # commits for it are nowhere in the graph.
    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#git-commit-rows > [id]")
      |> LazyHTML.attribute("id")

    assert ids == ["git-graph-stash-#{stash}", "git-commit-#{head}"]
  end

  test "picking a stash shows what it holds, and its menu pops it", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "parked\n")
    git!(path, ["stash", "push", "--quiet", "--message", "parked work"])
    stash = git!(path, ["rev-parse", "stash@{0}"])

    open(view, path)

    view |> element("#git-select-stash-#{stash}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-select-stash-#{stash}[aria-selected=true]")
    assert has_element?(view, "#git-stash-details")
    refute has_element?(view, "#git-commit-details")
    assert has_element?(view, "#git-commit-file-#{slug("README.md")}")

    # Its files open the diff the stash made to them.
    view |> element("#git-commit-file-#{slug("README.md")}") |> render_click()
    render_async(view)
    assert view |> element("#git-diff-body") |> render() =~ "parked"
    view |> element("#git-close-diff") |> render_click()

    render_hook(view, "open_menu", %{"kind" => "stash", "id" => stash, "x" => 10, "y" => 10})
    assert has_element?(view, "#git-stash-menu-0[role=menu]")

    view |> element("#git-menu-pop-stash") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-graph-stash-#{stash}")
    refute has_element?(view, "#git-stash-details")
    assert File.read!(Path.join(path, "README.md")) == "parked\n"
  end

  test "a stash picked in the branch panel is the one inspected", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "parked\n")
    git!(path, ["stash", "push", "--quiet", "--message", "parked work"])

    open(view, path)

    view |> element("#git-stash-select-0") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-stash-details")
    assert has_element?(view, "#git-stash-select-0[aria-pressed=true]")

    # Dropping it from the inspector asks first, like the panel does.
    view |> element("#git-stash-details-drop") |> render_click()
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["stash", "list"]) == ""
    refute has_element?(view, "#git-stash-details")
    assert has_element?(view, "#git-commit-details")
  end

  test "a dirty worktree gets a WIP row above the newest commit", context do
    %{view: view, path: path} = context
    open(view, path)

    refute has_element?(view, "#git-wip-row")

    File.write!(Path.join(path, "README.md"), "changed\n")
    File.write!(Path.join(path, "fresh.txt"), "fresh\n")
    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-wip-row")
    row = view |> element("#git-wip-row") |> render()
    assert row =~ "WIP"
    assert row =~ "~2"

    # It is the way into the working tree from the graph.
    view |> element("#git-select-wip") |> render_click()
    assert has_element?(view, "#git-working-tree")
    assert has_element?(view, "#git-select-wip[aria-pressed=true]")
  end

  test "an empty repository with changes still shows the WIP row", context do
    %{view: view, base: base} = context
    fresh = Path.join(base, "unborn")
    File.mkdir_p!(fresh)
    git!(fresh, ["init", "--initial-branch=main"])
    File.write!(Path.join(fresh, "first.txt"), "first\n")

    open(view, fresh)

    assert has_element?(view, "#git-wip-row")
    refute has_element?(view, "#git-commits-empty")
  end

  test "stages one file from its own row", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    File.write!(Path.join(path, "two.txt"), "two\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-move-unstaged-#{slug("one.txt")}") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == "one.txt"

    view |> element("#git-move-staged-#{slug("one.txt")}") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == ""
  end

  test "stages and unstages every file on one side", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    File.write!(Path.join(path, "two.txt"), "two\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-unstaged-all") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == "one.txt\ntwo.txt"
    assert has_element?(view, "#git-unstaged-empty")

    view |> element("#git-staged-all") |> render_click()
    render_async(view)

    assert git!(path, ["diff", "--cached", "--name-only"]) == ""
    assert has_element?(view, "#git-staged-empty")
  end

  test "the stash message box can be dismissed without stashing", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "one.txt"), "one\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-select-all-paths") |> render_click()
    file_menu(view, "one.txt")
    view |> element("#git-menu-stash-files") |> render_click()
    assert has_element?(view, "#git-stash-form")
    refute has_element?(view, "#git-selection")

    view |> element("#git-cancel-stash") |> render_click()

    refute has_element?(view, "#git-stash-form")
    assert has_element?(view, "#git-selection")
    assert has_element?(view, "#git-stashes-empty")
  end

  ## Diffs

  test "opens a file diff in the middle panel and closes it again", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "changed line\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-diff-unstaged-#{slug("README.md")}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-diff")
    assert has_element?(view, "#git-diff-body")
    refute has_element?(view, "#git-commits")

    body = view |> element("#git-diff-body") |> render()
    assert body =~ "changed line"
    assert body =~ "initial"

    view |> element("#git-close-diff") |> render_click()

    refute has_element?(view, "#git-diff")
    assert has_element?(view, "#git-commits")
  end

  test "the diff follows a file across the index and reports an untracked one", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "brand new.txt"), "hello\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-diff-unstaged-#{slug("brand new.txt")}") |> render_click()
    render_async(view)

    assert view |> element("#git-diff-body") |> render() =~ "hello"

    # Staging empties the unstaged side, so the view moves to the staged one.
    view |> element("#git-move-unstaged-#{slug("brand new.txt")}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-diff-side-staged[aria-pressed=true]")
    assert view |> element("#git-diff-body") |> render() =~ "hello"

    view |> element("#git-diff-side-unstaged") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-diff-empty")
  end

  test "closing the diff hands the graph back, selection intact", context do
    %{view: view, path: path, initial_commit: initial} = context
    File.write!(Path.join(path, "README.md"), "changed\n")
    open(view, path)

    view |> element("#git-panel-changes") |> render_click()
    view |> element("#git-diff-unstaged-#{slug("README.md")}") |> render_click()
    render_async(view)
    assert has_element?(view, "#git-diff")

    view |> element("#git-close-diff") |> render_click()

    assert has_element?(view, "#git-select-commit-#{initial}")
    refute has_element?(view, "#git-diff")

    view |> element("#git-select-commit-#{initial}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-details")
    assert has_element?(view, "#git-commit-changes")
  end

  test "the commit tab shows what a commit did, and its files open a diff", context do
    %{view: view, path: path, initial_commit: initial} = context

    File.write!(Path.join(path, "README.md"), "rewritten\n")
    File.write!(Path.join(path, "added.txt"), "added\n")
    git!(path, ["add", "-A"])
    git!(path, ["commit", "-m", "second commit"])
    second = head_commit(path)

    # Something uncommitted too, so the two views cannot be confused.
    File.write!(Path.join(path, "dirty.txt"), "dirty\n")
    open(view, path)

    # The working tree tab stays about the working tree.
    view |> element("#git-panel-changes") |> render_click()
    assert has_element?(view, "#git-working-tree")
    assert has_element?(view, "#git-file-unstaged-#{slug("dirty.txt")}")
    refute has_element?(view, "#git-commit-changes")

    # Picking a commit shows its files with the rest of its metadata.
    view |> element("#git-select-commit-#{second}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-details")
    assert has_element?(view, "#git-commit-changes")
    assert has_element?(view, "#git-commit-file-#{slug("README.md")}")
    assert has_element?(view, "#git-commit-file-#{slug("added.txt")}")
    refute has_element?(view, "#git-commit-file-#{slug("dirty.txt")}")

    # Browsing on swaps the list for the other commit's files.
    view |> element("#git-select-commit-#{initial}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-file-#{slug("README.md")}")
    refute has_element?(view, "#git-commit-file-#{slug("added.txt")}")

    view |> element("#git-panel-changes") |> render_click()
    assert has_element?(view, "#git-working-tree")
  end

  test "a file in a commit opens that commit's diff", context do
    %{view: view, path: path} = context
    File.write!(Path.join(path, "README.md"), "rewritten\n")
    git!(path, ["commit", "-am", "rewrite"])
    head = head_commit(path)

    open(view, path)
    view |> element("#git-select-commit-#{head}") |> render_click()
    render_async(view)

    view |> element("#git-commit-file-#{slug("README.md")}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-diff")
    body = view |> element("#git-diff-body") |> render()
    assert body =~ "rewritten"
    assert body =~ "initial"

    # A commit diff has one side, so the working tree toggles stay away.
    assert view |> element("#git-diff") |> render() =~ short_id(head)
    refute has_element?(view, "#git-diff-side-staged")

    view |> element("#git-close-diff") |> render_click()
    assert has_element?(view, "#git-commit-changes")
  end

  defp short_id(id), do: String.slice(id, 0, 7)
end
