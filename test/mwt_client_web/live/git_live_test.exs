defmodule MWTClientWeb.GitLiveTest do
  # The Git tool around its repositories: opening one, its tabs, what comes
  # back on the next visit, cloning, SSH keys and refreshing what changed
  # outside. Branches, commits, the working tree and background fetch have
  # git_live/*_test.exs, so they run side by side.
  use MWTClientWeb.ConnCase, async: true

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  alias MWTClientWeb.GitLive.Session

  setup {MWTClientWeb.GitLiveHelpers, :tool}

  ## Empty state and folder selection

  test "starts on an empty state with a folder picker", %{view: view} do
    assert has_element?(view, "#git-empty-state")
    assert has_element?(view, "#git-open-folder")
    assert has_element?(view, "#git-empty-open")
    refute has_element?(view, "#git-branches")
    refute has_element?(view, "#git-graph")
  end

  test "falls back to a typed path when the native picker cannot run", %{view: view} do
    refute has_element?(view, "#git-open-dialog")

    render_hook(view, "folder_dialog_unavailable", %{
      "reason" => "The native folder picker is only available in the desktop app."
    })

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-manual-open")
    assert render(view) =~ "only available in the desktop app"

    view |> element("#git-close-open-dialog") |> render_click()
    refute has_element?(view, "#git-open-dialog")
  end

  test "the fallback is reachable while a repository is already open", context do
    %{view: view, path: path} = context
    open(view, path)

    refute has_element?(view, "#git-open-dialog")

    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-manual-open")
  end

  test "a bad path typed in the fallback keeps the dialog open with the error", context do
    %{view: view, path: path, base: base} = context
    open(view, path)
    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    view |> form("#git-manual-open", %{"path" => Path.join(base, "nope")}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#git-open-dialog")
    assert has_element?(view, "#git-open-dialog-error")
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "the fallback opens a repository and closes itself", context do
    %{view: view, path: path} = context
    render_hook(view, "folder_dialog_unavailable", %{"reason" => "no picker here"})

    view |> form("#git-manual-open", %{"path" => path}) |> render_submit()
    render_async(view)

    refute has_element?(view, "#git-open-dialog")
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "shows the typed backend error for a folder that is not a worktree", context do
    %{view: view, base: base} = context
    outside = Path.join(base, "not-a-repo")
    File.mkdir_p!(outside)

    open(view, outside)

    assert has_element?(view, "#git-open-error")
    assert view |> element("#git-open-error") |> render() =~ "Not a Git worktree"
    assert view |> element("#git-open-error") |> render() =~ "not a git repository"
    assert has_element?(view, "#git-empty-state")
  end

  ## Tabs

  test "opening a folder creates a tab with the three panels", context do
    %{view: view, path: path} = context

    open(view, path)

    assert has_element?(view, "#git-tabs [role=tab]")
    assert render(view) =~ Path.basename(path)
    assert has_element?(view, "#git-branches")
    assert has_element?(view, "#git-graph")
    assert has_element?(view, "#git-inspector")
    assert has_element?(view, "#git-branches-resizer")
    assert has_element?(view, "#git-inspector-resizer")
    refute has_element?(view, "#git-empty-state")
  end

  test "opening a nested folder opens the worktree root once", context do
    %{view: view, path: path} = context
    nested = Path.join(path, "deeply/nested")
    File.mkdir_p!(nested)

    open(view, nested)
    assert count(view, "#git-tabs [role=tab]") == 1

    open(view, path)
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "opens, switches between and closes repository tabs", context do
    %{view: view, base: base, path: path} = context
    assert page_title(view) == "Git GUI · MWT"

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    git!(other, ["config", "user.name", "MWT Test"])
    git!(other, ["config", "user.email", "mwt@example.test"])
    commit_file(other, "other.txt", "other\n", "other commit")

    open(view, path)
    open(view, other)

    assert count(view, "#git-tabs [role=tab]") == 2
    assert page_title(view) == "Git GUI - other"
    assert render(view) =~ "other commit"

    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    assert render(view) =~ "initial commit"
    assert page_title(view) == "Git GUI - #{Path.basename(path)}"
    assert has_element?(view, "#git-tab-#{first}[aria-selected=true]")

    view |> element("#git-close-tab-#{first}") |> render_click()
    assert count(view, "#git-tabs [role=tab]") == 1
    assert page_title(view) == "Git GUI - other"
    assert render(view) =~ "other commit"

    [last] = tab_ids(view)
    view |> element("#git-close-tab-#{last}") |> render_click()
    assert has_element?(view, "#git-empty-state")
    assert page_title(view) == "Git GUI"
  end

  test "tabs can be dragged into another order", context do
    %{view: view, path: path, base: base} = context

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    git!(other, ["config", "user.name", "MWT Test"])
    git!(other, ["config", "user.email", "mwt@example.test"])
    commit_file(other, "other.txt", "other\n", "other commit")

    open(view, path)
    open(view, other)

    [first, second] = tab_ids(view)
    assert has_element?(view, "#git-tabs [data-sortable-id=#{first}][draggable=true]")

    render_hook(view, "reorder_tabs", %{"order" => [second, first]})
    assert tab_ids(view) == [second, first]

    # An order naming tabs that are gone leaves the rest alone.
    render_hook(view, "reorder_tabs", %{"order" => ["tab-gone", first]})
    assert tab_ids(view) == [first, second]
  end

  test "a dragged order is what comes back next time", context do
    %{view: view, path: path, base: base, conn: conn} = context

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    open(view, path)
    open(view, other)

    [first, second] = tab_ids(view)
    render_hook(view, "reorder_tabs", %{"order" => [second, first]})

    {:ok, reopened, _html} = live(conn, ~p"/tools/git")
    render_async(reopened)

    assert [restored | _] = tab_ids(reopened)
    assert reopened |> element("#git-tab-#{restored}") |> render() =~ Path.basename(other)
  end

  ## Sessions and background refresh

  test "the folders that were open come back", context do
    %{view: view, path: path, base: base, conn: conn} = context

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])
    git!(other, ["config", "user.name", "MWT Test"])
    git!(other, ["config", "user.email", "mwt@example.test"])
    commit_file(other, "other.txt", "other\n", "other commit")

    open(view, path)
    open(view, other)
    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    {:ok, reopened, _html} = live(conn, ~p"/tools/git")
    render_async(reopened)

    assert count(reopened, "#git-tabs [role=tab]") == 2
    assert render(reopened) =~ Path.basename(path)
    assert render(reopened) =~ "other"

    # Order and the tab that was in front are both restored.
    assert [restored_first, _] = tab_ids(reopened)
    assert has_element?(reopened, "#git-tab-#{restored_first}[aria-selected=true]")
    assert render(reopened) =~ "initial commit"
  end

  test "a folder that has gone away is dropped quietly", context do
    %{view: view, base: base, conn: conn} = context

    doomed = Path.join(base, "doomed")
    File.mkdir_p!(doomed)
    git!(doomed, ["init", "--initial-branch=main"])
    open(view, doomed)
    assert count(view, "#git-tabs [role=tab]") == 1

    File.rm_rf!(doomed)

    {:ok, reopened, _html} = live(conn, ~p"/tools/git")
    render_async(reopened)

    assert has_element?(reopened, "#git-empty-state")
    refute has_element?(reopened, "#git-open-error")

    # And it is not tried again on the next visit.
    {:ok, again, _html} = live(conn, ~p"/tools/git")
    render_async(again)
    assert has_element?(again, "#git-empty-state")
  end

  test "closing a tab forgets it", context do
    %{view: view, path: path, conn: conn} = context
    open(view, path)
    [id] = tab_ids(view)
    view |> element("#git-close-tab-#{id}") |> render_click()

    {:ok, reopened, _html} = live(conn, ~p"/tools/git")
    render_async(reopened)

    assert has_element?(reopened, "#git-empty-state")
  end

  test "another identity has tabs of its own", context do
    %{view: view, path: path} = context
    open(view, path)

    %{conn: theirs} = sign_in(build_conn())
    {:ok, their_view, _html} = live(theirs, ~p"/tools/git")
    render_async(their_view)

    assert has_element?(their_view, "#git-empty-state")
    assert count(view, "#git-tabs [role=tab]") == 1
  end

  test "work done outside the app is picked up on its own", context do
    %{view: view, path: path} = context
    open(view, path)

    assert count(view, "#git-commits [role=option]") == 1

    commit_file(path, "outside.txt", "outside\n", "made outside")

    send(view.pid, :auto_refresh)
    render_async(view)

    assert count(view, "#git-commits [role=option]") == 2
    assert render(view) =~ "made outside"
    # A background refresh stays quiet: no spinner, no result banner.
    refute has_element?(view, "#git-operation-status")
    refute has_element?(view, "#notices")
  end

  test "a background refresh holds off while a dialog is open", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-open-folder") |> render_click()
    assert has_element?(view, "#git-open-dialog")

    commit_file(path, "outside.txt", "outside\n", "made outside")
    send(view.pid, :auto_refresh)
    render_async(view)

    assert count(view, "#git-commits [role=option]") == 1
  end

  ## Snapshot refresh

  test "a mutation made outside the app is picked up by a refresh", context do
    %{view: view, path: path} = context
    open(view, path)

    assert count(view, "#git-commits [role=option]") == 1

    commit_file(path, "outside.txt", "outside\n", "made outside")

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert count(view, "#git-commits [role=option]") == 2
    assert render(view) =~ "made outside"
  end

  test "the selection survives a refresh", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-select-commit-#{initial}") |> render_click()
    render_async(view)

    view |> element("#git-refresh") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-select-commit-#{initial}[aria-selected=true]")
  end

  test "an empty repository renders its panels without commits", context do
    %{view: view, base: base} = context
    empty = Path.join(base, "empty")
    File.mkdir_p!(empty)
    git!(empty, ["init", "--initial-branch=main"])

    open(view, empty)

    assert has_element?(view, "#git-commits-empty")
    assert has_element?(view, "#git-branches-empty")
    assert has_element?(view, "#git-inspector-empty")
  end

  ## SSH credentials

  test "saves an SSH key pair for every repository tab", context do
    %{view: view, path: path, base: base, username: username} = context
    {private_key, public_key} = ssh_key_pair(base)

    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--initial-branch=main"])

    open(view, path)
    open(view, other)

    view |> element("#git-ssh-keys") |> render_click()
    assert has_element?(view, "#git-ssh-popover")

    view
    |> form("#git-ssh-form", %{"private_key" => private_key, "public_key" => public_key})
    |> render_submit()

    assert render(view) =~ "SSH ready"
    refute has_element?(view, "#git-ssh-popover")
    assert Session.ssh_key(username) == %{private_key: private_key, public_key: public_key}

    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()

    assert render(view) =~ "SSH ready"

    view |> element("#git-ssh-keys") |> render_click()
    assert has_element?(view, "#git-ssh-private-key[value='#{private_key}']")
    assert has_element?(view, "#git-ssh-public-key[value='#{public_key}']")

    view |> element("#git-clear-ssh") |> render_click()
    assert render(view) =~ "SSH keys"
    assert Session.ssh_key(username) == nil
  end

  test "rejects empty SSH key paths", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-ssh-keys") |> render_click()

    view
    |> form("#git-ssh-form", %{"private_key" => "", "public_key" => ""})
    |> render_submit()

    assert has_element?(view, "#git-ssh-error")
    assert has_element?(view, "#git-ssh-popover")
    assert render(view) =~ "Private key path cannot be empty"
  end

  test "changes an HTTP remote to SSH from the key settings", context do
    %{view: view, path: path} = context
    git!(path, ["remote", "add", "origin", "https://github.com/example/project.git"])

    git!(path, [
      "remote",
      "set-url",
      "--push",
      "origin",
      "https://github.com/example/project.git"
    ])

    open(view, path)

    view |> element("#git-ssh-keys") |> render_click()

    assert has_element?(view, "#git-ssh-remote-#{slug("origin")}")
    assert has_element?(view, "#git-use-ssh-#{slug("origin")}")
    assert render(view) =~ "SSH keys cannot authenticate this HTTP remote"

    view |> element("#git-use-ssh-#{slug("origin")}") |> render_click()
    render_async(view)

    assert git!(path, ["remote", "get-url", "origin"]) == "git@github.com:example/project.git"

    assert git!(path, ["remote", "get-url", "--push", "origin"]) ==
             "git@github.com:example/project.git"

    refute has_element?(view, "#git-use-ssh-#{slug("origin")}")
    assert view |> element("#git-ssh-remote-kind-#{slug("origin")}") |> render() =~ "ssh"
  end

  ## Cloning

  test "clones a repository into a new folder and opens it", context do
    %{view: view, path: path, base: base} = context

    view |> element("#git-open-folder") |> render_click()
    view |> element("#git-open-mode-clone") |> render_click()
    assert has_element?(view, "#git-clone-form")

    destination = Path.join(base, "clones")

    view
    |> form("#git-clone-form", %{"url" => path, "parent" => destination, "name" => "copy"})
    |> render_submit()

    render_async(view)

    assert File.exists?(Path.join([destination, "copy", "README.md"]))
    refute has_element?(view, "#git-open-dialog")
    assert count(view, "#git-tabs [role=tab]") == 1
    assert render(view) =~ "copy"
    assert render(view) =~ "initial commit"
  end

  test "a clone that cannot run keeps the form and says why", context do
    %{view: view, base: base} = context

    view |> element("#git-open-folder") |> render_click()
    view |> element("#git-open-mode-clone") |> render_click()

    view
    |> form("#git-clone-form", %{"url" => "", "parent" => base, "name" => "nope"})
    |> render_submit()

    assert has_element?(view, "#git-open-dialog-error")
    assert render(view) =~ "address of the repository"

    view
    |> form("#git-clone-form", %{
      "url" => Path.join(base, "missing.git"),
      "parent" => base,
      "name" => "nope"
    })
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#git-clone-form")
    assert has_element?(view, "#git-open-dialog-error")
  end

  test "the clone name defaults to the one Git would use", context do
    %{view: view, path: path, base: base} = context

    view |> element("#git-open-folder") |> render_click()
    view |> element("#git-open-mode-clone") |> render_click()

    view
    |> form("#git-clone-form", %{
      "url" => path,
      "parent" => Path.join(base, "defaulted"),
      "name" => ""
    })
    |> render_submit()

    render_async(view)

    assert File.dir?(Path.join([base, "defaulted", Path.basename(path), ".git"]))
  end
end
