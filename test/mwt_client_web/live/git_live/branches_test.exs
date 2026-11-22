defmodule MWTClientWeb.GitLive.BranchesTest do
  use MWTClientWeb.ConnCase, async: true

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  setup {MWTClientWeb.GitLiveHelpers, :tool}

  ## Branches

  test "lists local and remote branches with the current one marked", context do
    %{view: view, path: path, base: base} = context

    git!(path, ["branch", "feature"])
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "-u", "origin", "main"])

    open(view, path)

    assert has_element?(view, "#git-local-branches")
    assert has_element?(view, "#git-remote-branches")
    assert has_element?(view, "#git-branch-#{slug("refs/heads/feature")}")
    assert has_element?(view, "#git-branch-#{slug("refs/remotes/origin/main")}")
    assert render(view) =~ "origin/main"
  end

  test "filters the branch list", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature-one"])
    git!(path, ["branch", "other"])

    open(view, path)

    view
    |> element("#git-branch-search")
    |> render_change(%{"filter" => "feature"})

    assert has_element?(view, "#git-branch-#{slug("refs/heads/feature-one")}")
    refute has_element?(view, "#git-branch-#{slug("refs/heads/other")}")

    view |> element("#git-branch-search") |> render_change(%{"filter" => "nothing"})
    assert has_element?(view, "#git-branches-empty")
  end

  test "selecting a branch marks it and opens its actions", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature"])
    open(view, path)

    feature = slug("refs/heads/feature")

    view |> element("#git-select-branch-#{feature}") |> render_click()
    assert has_element?(view, "#git-select-branch-#{feature}[aria-selected=true]")

    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    assert has_element?(view, "#git-branch-menu-#{feature}[role=menu]")
    assert has_element?(view, "#git-menu-checkout-#{feature}")

    view |> element("#git-menu-checkout-#{feature}") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature"
    assert render(view) =~ "feature"
    refute has_element?(view, "#git-branch-menu-#{feature}")
  end

  test "checking out the current branch is disabled", context do
    %{view: view, path: path} = context
    open(view, path)

    main = slug("refs/heads/main")
    view |> element("#git-branch-menu-button-#{main}") |> render_click()

    assert has_element?(view, "#git-menu-checkout-#{main}[disabled]")
    assert has_element?(view, "#git-menu-merge-#{main}[disabled]")
  end

  test "creating a branch refreshes the snapshot", context do
    %{view: view, path: path} = context
    open(view, path)

    view |> element("#git-create-branch") |> render_click()
    assert has_element?(view, "#git-action-form")

    view
    |> form("#git-action-form", %{"value" => "from-ui", "checkout" => "true"})
    |> render_submit()

    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "from-ui"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/from-ui")}")
    refute has_element?(view, "#git-action-form")
  end

  test "deleting a branch asks first", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "doomed"])
    open(view, path)

    doomed = slug("refs/heads/doomed")
    view |> element("#git-branch-menu-button-#{doomed}") |> render_click()
    view |> element("#git-menu-delete-#{doomed}") |> render_click()

    assert has_element?(view, "#git-confirm")
    assert render(view) =~ "doomed"

    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert git!(path, ["branch", "--list", "doomed"]) =~ "doomed"

    view |> element("#git-branch-menu-button-#{doomed}") |> render_click()
    view |> element("#git-menu-delete-#{doomed}") |> render_click()
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["branch", "--list", "doomed"]) == ""
    refute has_element?(view, "#git-branch-#{doomed}")
  end

  test "deletes the MWT branches merged into the current branch, after listing them", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "mwt/landed-1"])
    git!(path, ["branch", "mwt/landed-2"])
    git!(path, ["branch", "feature"])
    git!(path, ["switch", "--quiet", "-c", "mwt/unmerged"])
    commit_file(path, "unmerged.txt", "work\n", "not on main")
    git!(path, ["switch", "--quiet", "main"])
    open(view, path)

    view |> element("#git-delete-merged-mwt") |> render_click()

    assert has_element?(view, "#git-confirm-items li", "mwt/landed-1")
    assert has_element?(view, "#git-confirm-items li", "mwt/landed-2")
    refute has_element?(view, "#git-confirm-items li", "mwt/unmerged")
    refute has_element?(view, "#git-confirm-items li", "feature")

    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["branch", "--list"]) =~ "mwt/unmerged"
    assert git!(path, ["branch", "--list"]) =~ "feature"
    refute git!(path, ["branch", "--list"]) =~ "mwt/landed"
    refute has_element?(view, "#git-branch-#{slug("refs/heads/mwt/landed-1")}")

    # Nothing left to clean: it says so instead of asking.
    view |> element("#git-delete-merged-mwt") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert render(view) =~ "No merged MWT branch"
  end

  test "the merged MWT branch cleanup only shows with MWT branches", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature"])
    open(view, path)

    refute has_element?(view, "#git-delete-merged-mwt")
  end

  test "renaming a branch through the action form", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "old-name"])
    open(view, path)

    old = slug("refs/heads/old-name")
    view |> element("#git-branch-menu-button-#{old}") |> render_click()
    view |> element("#git-menu-rename-#{old}") |> render_click()

    assert has_element?(view, "#git-action-form")

    view |> form("#git-action-form", %{"value" => "new-name"}) |> render_submit()
    render_async(view)

    assert git!(path, ["branch", "--list", "new-name"]) =~ "new-name"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/new-name")}")
    refute has_element?(view, "#git-branch-#{old}")
  end

  test "checking out a remote branch as a local tracking branch", context do
    %{view: view, path: path, base: base} = context

    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["push", "origin", "main"])
    git!(path, ["push", "origin", "main:refs/heads/shipped"])
    git!(path, ["fetch", "origin"])

    open(view, path)

    shipped = slug("refs/remotes/origin/shipped")
    view |> element("#git-branch-menu-button-#{shipped}") |> render_click()
    view |> element("#git-menu-checkout-remote-#{shipped}") |> render_click()

    assert has_element?(view, "#git-action-form")

    view |> form("#git-action-form", %{"value" => "shipped"}) |> render_submit()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "shipped"
    assert git!(path, ["rev-parse", "--abbrev-ref", "shipped@{upstream}"]) == "origin/shipped"
    assert has_element?(view, "#git-branch-#{slug("refs/heads/shipped")}")
  end

  test "checking out a remote branch a local one tracks brings that one in line", context do
    %{view: view, path: path, base: base} = context
    git!(path, ["branch", "feature"])
    elsewhere = origin!(base, path, ["main", "feature"])
    remote_head = push_commit!(elsewhere, "feature", "remote.txt", "remote work")
    git!(path, ["fetch", "--quiet", "origin"])

    open(view, path)

    feature = slug("refs/remotes/origin/feature")
    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    assert view |> element("#git-menu-checkout-remote-#{feature}") |> render() =~ "as feature"

    # Only trailing the remote, with nothing uncommitted: nothing to ask.
    view |> element("#git-menu-checkout-remote-#{feature}") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    refute has_element?(view, "#git-action-form")
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature"
    assert head_commit(path) == remote_head
    assert git!(path, ["branch", "--list", "--format=%(refname:short)"]) == "feature\nmain"

    # Checked out and level with it, there is nothing left to do.
    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    assert has_element?(view, "#git-menu-checkout-remote-#{feature}[disabled]")
  end

  test "with work at stake, it asks whether to stash, soft or hard reset", context do
    %{view: view, path: path, base: base} = context
    git!(path, ["branch", "feature"])
    elsewhere = origin!(base, path, ["main", "feature"])
    remote_head = push_commit!(elsewhere, "feature", "remote.txt", "remote work")
    git!(path, ["fetch", "--quiet", "origin"])
    git!(path, ["switch", "--quiet", "feature"])
    commit_file(path, "local.txt", "local\n", "local work")
    File.write!(Path.join(path, "README.md"), "uncommitted\n")

    open(view, path)

    feature = slug("refs/remotes/origin/feature")
    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    view |> element("#git-menu-checkout-remote-#{feature}") |> render_click()

    assert has_element?(view, "#git-confirm-choices")
    dialog = view |> element("#git-confirm") |> render()
    assert dialog =~ "1 commit origin/feature lacks"
    assert dialog =~ "1 file changed"

    for choice <- ~w(stash soft hard), do: assert(has_element?(view, "#git-confirm-#{choice}"))

    # Called off, nothing moved.
    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    refute head_commit(path) == remote_head

    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    view |> element("#git-menu-checkout-remote-#{feature}") |> render_click()
    view |> element("#git-confirm-stash") |> render_click()
    render_async(view)

    assert head_commit(path) == remote_head
    assert git!(path, ["status", "--porcelain"]) == ""
    assert git!(path, ["stash", "list"]) =~ "Before resetting feature to origin/feature"
    assert has_element?(view, "#git-stash-0")
  end

  test "a clean branch with commits of its own is offered no stash", context do
    %{view: view, path: path, base: base} = context
    git!(path, ["branch", "feature"])
    elsewhere = origin!(base, path, ["main", "feature"])
    remote_head = push_commit!(elsewhere, "feature", "remote.txt", "remote work")
    git!(path, ["fetch", "--quiet", "origin"])
    git!(path, ["switch", "--quiet", "feature"])
    commit_file(path, "local.txt", "local\n", "local work")
    git!(path, ["switch", "--quiet", "main"])

    open(view, path)

    feature = slug("refs/remotes/origin/feature")
    view |> element("#git-branch-menu-button-#{feature}") |> render_click()
    view |> element("#git-menu-checkout-remote-#{feature}") |> render_click()

    refute has_element?(view, "#git-confirm-stash")
    view |> element("#git-confirm-hard") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature"
    assert head_commit(path) == remote_head
    refute File.exists?(Path.join(path, "local.txt"))
  end

  test "a branch in the graph carries its own menu, checkout included", context do
    %{view: view, path: path} = context
    git!(path, ["branch", "feature"])
    open(view, path)

    feature = slug("refs/heads/feature")

    # The list hook reads these off whatever the pointer landed on.
    assert has_element?(
             view,
             "#git-ref-all-#{feature}[data-menu-kind=branch][data-menu-id='refs/heads/feature']"
           )

    render_hook(view, "open_menu", %{"kind" => "branch", "id" => "refs/heads/feature"})
    assert has_element?(view, "#git-branch-menu-#{feature}[role=menu]")

    view |> element("#git-menu-checkout-#{feature}") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature"
  end

  test "a label's menu keeps the unfolded list open until it is dealt with", context do
    %{view: view, path: path} = context
    for name <- ~w(alpha beta), do: git!(path, ["branch", name])
    open(view, path)

    head = head_commit(path)
    beta = slug("refs/heads/beta")
    pinned = "#git-refs-#{head}[data-pinned]"

    from_graph = %{"kind" => "branch", "id" => "refs/heads/beta", "x" => 10, "y" => 10}

    # Reaching the menu takes the pointer off the list, so the list holds on.
    render_hook(view, "open_menu", Map.put(from_graph, "anchor", "git-ref-all-#{beta}"))
    assert has_element?(view, pinned)

    render_hook(view, "close_menu", %{})
    refute has_element?(view, pinned)

    # The same branch opened from the branch panel leaves the graph alone.
    render_hook(view, "open_menu", Map.put(from_graph, "anchor", "git-branch-#{beta}"))
    assert has_element?(view, "#git-branch-menu-#{beta}[role=menu]")
    refute has_element?(view, pinned)
  end

  test "a lone ref keeps its chip on show", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)

    # Nothing sits behind it; the list holds the label alone, for the browser
    # to unfold only if the name was cut short.
    assert has_element?(view, "#git-ref-#{slug("refs/heads/main")}")
    assert count(view, "#git-refs-#{head} > *") == 1
  end

  test "a long branch name is cut short in its column and whole on hover", context do
    %{view: view, path: path, initial_commit: initial} = context
    long = "feature/a-branch-name-far-too-long-for-the-column-it-sits-in"
    commit_file(path, "second.txt", "second\n", "second commit")
    git!(path, ["branch", long, initial])
    open(view, path)

    chip = "#git-ref-#{slug("refs/heads/#{long}")}"
    assert has_element?(view, "#{chip}[title='Local branch #{long}'] [data-ref-name]")

    unfolded = "#git-refs-#{initial} #git-ref-all-#{slug("refs/heads/#{long}")} [data-ref-name]"
    assert view |> element(unfolded) |> render() =~ long
  end
end
