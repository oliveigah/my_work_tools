defmodule MWTClientWeb.GitLive.CommitsTest do
  use MWTClientWeb.ConnCase, async: true

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  setup {MWTClientWeb.GitLiveHelpers, :tool}

  ## Commits

  test "renders the graph and selects the head commit", context do
    %{view: view, path: path} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    assert count(view, "#git-commits [role=option]") == 2
    assert has_element?(view, "#git-commit-#{head}")
    assert has_element?(view, "#git-select-commit-#{head}[aria-selected=true]")
    assert has_element?(view, "#git-commit-details")
    assert render(view) =~ "second commit"

    # Its files are read as soon as the tab opens, not on the first click.
    render_async(view)
    assert view |> element("#git-commit-files") |> render() =~ "second.txt"
  end

  test "selecting a commit updates the inspector", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-select-commit-#{initial}") |> render_click()
    # The signature is checked on its own, after the commit is picked.
    render_async(view)

    details = view |> element("#git-commit-details") |> render()
    assert details =~ "initial commit"
    assert details =~ initial
    assert details =~ "MWT Test"
    assert details =~ "mwt@example.test"
    assert details =~ "Not signed"
    assert details =~ "A root commit"
  end

  test "a commit inspector links to its parents", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    view |> element("#git-parent-#{head}-#{initial}") |> render_click()

    assert has_element?(view, "#git-select-commit-#{initial}[aria-selected=true]")
    assert view |> element("#git-commit-details") |> render() =~ "initial commit"
  end

  test "the commit menu can check out a commit detached", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-commit-menu-button-#{initial}") |> render_click()
    assert has_element?(view, "#git-commit-menu-#{initial}[role=menu]")

    view |> element("#git-menu-detach-#{initial}") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "HEAD"]) == initial
    assert render(view) =~ "detached at"
  end

  test "a hard reset is confirmed before it runs", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    view |> element("#git-commit-menu-button-#{initial}") |> render_click()
    view |> element("#git-menu-hard-reset-#{initial}") |> render_click()

    assert has_element?(view, "#git-confirm")
    assert render(view) =~ "Hard reset"
    assert git!(path, ["rev-parse", "HEAD"]) != initial

    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "HEAD"]) == initial
    assert count(view, "#git-commits [role=option]") == 1
  end

  test "the commit limit can be raised", context do
    %{view: view, path: path} = context
    open(view, path)

    assert has_element?(view, "#git-graph-limit option[value='5000']")

    view
    |> element("form[phx-change=set_limit]")
    |> render_change(%{"limit" => "5000"})

    render_async(view)

    assert has_element?(view, "#git-graph-limit option[value='5000'][selected]")
  end

  test "editing a commit message rewrites it", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)

    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    view |> element("#git-menu-edit-message-#{head}") |> render_click()

    assert has_element?(view, "#git-action-form")
    assert view |> element("#git-action-form") |> render() =~ "initial commit"

    view |> form("#git-action-form", %{"value" => "a better message"}) |> render_submit()
    render_async(view)

    assert git!(path, ["log", "-1", "--format=%s"]) == "a better message"
    assert render(view) =~ "a better message"
  end

  ## Picking several commits

  defp picked_commit_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#git-commits [role=option][aria-selected=true]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "git-select-commit-", ""))
  end

  defp click_commit(view, id, modifiers \\ %{}) do
    view |> element("#git-select-commit-#{id}") |> render_click(modifiers)
    render_async(view)
    view
  end

  defp commit_menu(view, id) do
    render_hook(view, "open_menu", %{"kind" => "commit", "id" => id, "x" => 10, "y" => 10})
    render_async(view)
    view
  end

  test "commits are picked with a click, Ctrl and Shift", context do
    %{view: view, path: path, initial_commit: initial} = context
    [c2, c3, c4] = for n <- 2..4, do: commit_file(path, "#{n}.txt", "#{n}\n", "commit #{n}")
    open(view, path)

    assert picked_commit_ids(view) == [c4]

    click_commit(view, c2)
    assert picked_commit_ids(view) == [c2]

    click_commit(view, c4, %{"ctrlKey" => true})
    assert picked_commit_ids(view) == [c4, c2]
    assert view |> element("#git-commit-details") |> render() =~ "commit 4"

    # Shift runs from the commit clicked last, c4, down to the one clicked.
    click_commit(view, initial, %{"shiftKey" => true})
    assert picked_commit_ids(view) == [c4, c3, c2, initial]
    assert view |> element("#git-commit-selection") |> render() =~ "4 commits selected"

    # Dropping the commit on show hands the inspector to the newest one left.
    click_commit(view, initial, %{"metaKey" => true})
    assert picked_commit_ids(view) == [c4, c3, c2]
    assert view |> element("#git-commit-details") |> render() =~ "commit 4"

    view |> element("#git-clear-commits") |> render_click()
    assert picked_commit_ids(view) == [c4]
    refute has_element?(view, "#git-commit-selection")
  end

  test "the menu of a pick counts the commits it would act on", context do
    %{view: view, path: path} = context
    [c2, c3, c4] = for n <- 2..4, do: commit_file(path, "#{n}.txt", "#{n}\n", "commit #{n}")
    open(view, path)

    click_commit(view, c3, %{"shiftKey" => true})
    commit_menu(view, c3)

    assert has_element?(view, "#git-commits-menu[role=menu]")
    assert view |> element("#git-menu-cherry-pick-commits") |> render() =~ "Cherry-pick 2 commits"
    assert view |> element("#git-menu-squash-commits") |> render() =~ "Squash 2 commits"
    refute has_element?(view, "#git-menu-squash-commits[disabled]")

    # A right click outside the pick takes that commit alone, with its own menu.
    render_hook(view, "close_menu", %{})
    commit_menu(view, c2)

    assert picked_commit_ids(view) == [c2]
    assert has_element?(view, "#git-commit-menu-#{c2}[role=menu]")
    refute has_element?(view, "#git-commits-menu")
    assert git!(path, ["rev-parse", "HEAD"]) == c4
  end

  test "cherry-picks the picked commits in the order they were made", context do
    %{view: view, path: path, initial_commit: initial} = context
    git!(path, ["checkout", "-q", "-b", "feature"])
    f1 = commit_file(path, "f1.txt", "f1\n", "feature one")
    f2 = commit_file(path, "f2.txt", "f2\n", "feature two")
    git!(path, ["checkout", "-q", "main"])
    commit_file(path, "main.txt", "main\n", "main work")
    open(view, path)

    click_commit(view, f2)
    click_commit(view, f1, %{"ctrlKey" => true})
    commit_menu(view, f2)
    view |> element("#git-menu-cherry-pick-commits") |> render_click()
    render_async(view)

    assert git!(path, ["log", "--format=%s", "main"]) ==
             "feature two\nfeature one\nmain work\ninitial commit"

    assert git!(path, ["rev-parse", "main~3"]) == initial
  end

  test "squashes the picked commits under a message offered for editing", context do
    %{view: view, path: path, initial_commit: initial} = context
    [c2, c3, _c4] = for n <- 2..4, do: commit_file(path, "#{n}.txt", "#{n}\n", "commit #{n}")
    open(view, path)

    click_commit(view, c2)
    click_commit(view, c3, %{"shiftKey" => true})
    commit_menu(view, c3)
    view |> element("#git-menu-squash-commits") |> render_click()

    # The messages of both, oldest first, are there to start from.
    assert view |> element("#git-action-value") |> render() =~ "commit 2\n\ncommit 3"
    assert view |> element("#git-action-submit") |> render() =~ "Squash 2 commits"

    view |> form("#git-action-form", %{"value" => "two and three"}) |> render_submit()
    render_async(view)

    assert git!(path, ["log", "--format=%s", "main"]) == "commit 4\ntwo and three\ninitial commit"
    assert git!(path, ["symbolic-ref", "--short", "HEAD"]) == "main"
    assert git!(path, ["rev-parse", "HEAD~2"]) == initial
    assert render(view) =~ "two and three"
  end

  test "a squash that would be refused is not offered", context do
    %{view: view, path: path} = context
    [c2, _c3, c4] = for n <- 2..4, do: commit_file(path, "#{n}.txt", "#{n}\n", "commit #{n}")
    open(view, path)

    click_commit(view, c2)
    click_commit(view, c4, %{"ctrlKey" => true})
    commit_menu(view, c4)

    assert has_element?(view, "#git-menu-squash-commits[disabled]")
    assert view |> element("#git-squash-blocker") |> render() =~ "Only consecutive commits"
    # Cherry-picking does not care whether they are next to each other.
    refute has_element?(view, "#git-menu-cherry-pick-commits[disabled]")

    render_hook(view, "close_menu", %{})
    File.write!(Path.join(path, "README.md"), "dirty\n")
    view |> element("#git-refresh") |> render_click()
    render_async(view)

    click_commit(view, c4)
    click_commit(view, c2, %{"shiftKey" => true})
    commit_menu(view, c4)

    assert view |> element("#git-squash-blocker") |> render() =~ "Commit or stash"
  end

  test "a long graph only puts the rows around the viewport on the page", context do
    %{view: view, path: path, initial_commit: initial} = context
    head = empty_commits(path, 200)
    open(view, path)

    assert count(view, "#git-commits [role=option]") == 160
    assert has_element?(view, "#git-commit-rows[data-first='0'][data-total='201']")
    assert has_element?(view, "#git-commit-#{head}")
    refute has_element?(view, "#git-commit-#{initial}")

    # Scrolling to the bottom brings the oldest rows in and lets the newest go.
    render_hook(view, "graph_scroll", %{"top" => 190})

    assert count(view, "#git-commits [role=option]") == 160
    assert has_element?(view, "#git-commit-rows[data-first='41']")
    assert has_element?(view, "#git-commit-#{initial}")
    refute has_element?(view, "#git-commit-#{head}")

    # A row off the page can still be part of a range picked with Shift.
    view |> element("#git-select-commit-#{initial}") |> render_click()
    render_hook(view, "graph_scroll", %{"top" => 0})
    render_click(view, "select_commit", %{"id" => head, "shiftKey" => true})

    assert count(view, "#git-commits [role=option][aria-selected=true]") == 160
    assert view |> element("#git-commit-details") |> render() =~ "201 commits selected"
  end

  test "the graph draws one lane per concurrent branch", context do
    %{view: view, path: path} = context

    git!(path, ["checkout", "-b", "side"])
    commit_file(path, "side.txt", "side\n", "side work")
    git!(path, ["checkout", "main"])
    commit_file(path, "main.txt", "main\n", "main work")
    git!(path, ["merge", "--no-ff", "-m", "merge side", "side"])

    open(view, path)

    merge = head_commit(path)

    assert count(view, "#git-commits [role=option]") == 4
    # The merge row draws its own node plus the two edges leaving it.
    assert count(view, "#git-commit-#{merge} svg path") == 2
    assert count(view, "#git-commit-#{merge} svg circle") == 1
    assert view |> element("#git-commit-#{merge}") |> render() =~ "main"
  end

  test "right clicking a commit opens its menu at the pointer", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)

    # The row carries the data the list hook reads on contextmenu.
    assert has_element?(view, "#git-commit-#{head}[data-menu-kind=commit]")

    render_hook(view, "open_menu", %{"kind" => "commit", "id" => head, "x" => 412, "y" => 260})

    assert has_element?(view, "#git-commit-menu-#{head}[role=menu]")
    assert has_element?(view, "#git-commit-menu-#{head}[data-x='412'][data-y='260']")
    assert has_element?(view, "#git-menu-detach-#{head}")
    assert has_element?(view, "#git-menu-branch-here-#{head}")
    assert has_element?(view, "#git-menu-copy-sha-#{head}")
  end

  test "the menu is rendered outside the scrolling panels and over no backdrop", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-menu-button-#{head}") |> render_click()

    assert has_element?(view, "#git-commit-menu-#{head}")
    assert count(view, "#git-commits #git-commit-menu-#{head}") == 0
    assert count(view, "#git-branches #git-commit-menu-#{head}") == 0

    # A backdrop over the rows would eat the next right click, and the webview
    # would answer it with its own menu instead.
    assert count(view, "#git-menu-backdrop") == 0

    # Clicking the same trigger again closes it.
    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    refute has_element?(view, "#git-commit-menu-#{head}")
  end

  test "the selected commit keeps a visible action button", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    open(view, path)

    head = head_commit(path)

    # Selected rows keep the trigger on screen; the rest reveal it on hover.
    assert view |> element("#git-commit-menu-button-#{head}") |> render() =~ "opacity-100"
    assert view |> element("#git-commit-menu-button-#{initial}") |> render() =~ "opacity-0"

    view |> element("#git-select-commit-#{initial}") |> render_click()

    assert view |> element("#git-commit-menu-button-#{initial}") |> render() =~ "opacity-100"
  end

  test "the inspector opens the same menu for the selected commit", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-actions") |> render_click()

    assert has_element?(view, "#git-commit-menu-#{head}[data-anchor=git-commit-actions]")

    view |> element("#git-menu-branch-here-#{head}") |> render_click()
    assert has_element?(view, "#git-action-form")
  end

  test "escape closes an open menu", context do
    %{view: view, path: path} = context
    open(view, path)

    head = head_commit(path)
    view |> element("#git-commit-menu-button-#{head}") |> render_click()
    assert has_element?(view, "#git-commit-menu-#{head}")

    render_keydown(view, "close_overlays", %{"key" => "Escape"})
    refute has_element?(view, "#git-commit-menu-#{head}")
  end

  defp add_origin(base, path) do
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare"])
    git!(path, ["remote", "add", "origin", remote])
  end

  test "a branch level with its remote is one label marked with both places", context do
    %{view: view, path: path, base: base} = context
    add_origin(base, path)
    git!(path, ["push", "-u", "origin", "main"])

    open(view, path)

    head = head_commit(path)
    chip = "#git-ref-#{slug("refs/heads/main")}"

    # Nothing behind it to unfold: main and origin/main are the same label.
    assert count(view, "#git-refs-#{head} > *") == 1
    refute has_element?(view, "#git-ref-#{slug("refs/remotes/origin/main")}")

    assert has_element?(view, "#{chip}[title='Current branch main, same commit as origin/main']")
    assert has_element?(view, "#{chip} .hero-check-micro")
    assert has_element?(view, "#{chip} .hero-computer-desktop-micro")
    assert has_element?(view, "#{chip} .hero-cloud-micro")
    # The remote prefix lives in the tooltip; the chip reads as the name alone.
    assert view |> element(chip) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
             "main"

    assert has_element?(view, "#git-commit-columns")
  end

  test "a branch apart from its remote gets a label on each commit", context do
    %{view: view, path: path, base: base} = context
    add_origin(base, path)
    git!(path, ["push", "-u", "origin", "main"])
    pushed = head_commit(path)
    commit_file(path, "second.txt", "second\n", "not pushed yet")
    git!(path, ["branch", "feature"])
    git!(path, ["push", "origin", "feature"])
    git!(path, ["branch", "-D", "feature"])

    open(view, path)

    local = "#git-ref-#{slug("refs/heads/main")}"
    assert has_element?(view, "#{local} .hero-computer-desktop-micro")
    refute has_element?(view, "#{local} .hero-cloud-micro")

    # Only on the remote: no tick, no monitor, and it picks the remote branch.
    remote = "#git-ref-#{slug("refs/remotes/origin/main")}"

    assert has_element?(
             view,
             "#git-commit-#{pushed} #{remote}[title='Remote branch origin/main']"
           )

    assert has_element?(view, "#{remote} .hero-cloud-micro")
    refute has_element?(view, "#{remote} .hero-computer-desktop-micro")
    refute has_element?(view, "#{remote} .hero-check-micro")

    feature = "#git-ref-all-#{slug("refs/remotes/origin/feature")}"
    assert view |> element(feature) |> render() =~ ">feature<"

    view |> element(remote) |> render_click()

    assert has_element?(
             view,
             "#git-select-branch-#{slug("refs/remotes/origin/main")}[aria-selected=true]"
           )
  end

  test "a label is marked when any branch it stands for is selected", context do
    %{view: view, path: path, base: base} = context
    add_origin(base, path)
    git!(path, ["push", "-u", "origin", "main"])
    open(view, path)

    view
    |> element("#git-select-branch-#{slug("refs/remotes/origin/main")}")
    |> render_click()

    assert has_element?(view, "#git-ref-#{slug("refs/heads/main")}[aria-pressed=true]")
  end

  test "refs on one commit collapse behind the one that matters most", context do
    %{view: view, path: path} = context
    for name <- ~w(alpha beta gamma delta), do: git!(path, ["branch", name])

    open(view, path)

    head = head_commit(path)
    row = view |> element("#git-commit-#{head}") |> render()

    # One chip stands for the lot, and it is the branch HEAD is on.
    assert row =~ "Current branch main"
    assert row =~ "+4"

    # The rest are there to be picked once the column is hovered.
    assert has_element?(view, "#git-refs-#{head}")
    assert has_element?(view, "#git-ref-all-#{slug("refs/heads/alpha")}")

    view |> element("#git-ref-all-#{slug("refs/heads/alpha")}") |> render_click()

    assert has_element?(
             view,
             "#git-select-branch-#{slug("refs/heads/alpha")}[aria-selected=true]"
           )
  end

  test "the trunk branches come before the rest", context do
    %{view: view, path: path} = context
    # Made in an order that only matches if the ranking is doing the work.
    for name <- ~w(zebra dev master), do: git!(path, ["branch", name])

    git!(path, ["checkout", "-qb", "feature"])
    git!(path, ["tag", "v9"])
    open(view, path)

    # The current branch, then master, main and dev, then the rest, then tags.
    assert ref_order(view, head_commit(path)) == [
             "refs/heads/feature",
             "refs/heads/master",
             "refs/heads/main",
             "refs/heads/dev",
             "refs/heads/zebra",
             "v9"
           ]
  end

  defp ref_order(view, commit) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#git-refs-#{commit} > *")
    |> Enum.map(fn node ->
      # Branches are buttons that carry the ref they select; a tag is just a chip.
      case LazyHTML.attribute(node, "phx-value-name") do
        [name] -> name
        [] -> node |> LazyHTML.text() |> String.trim()
      end
    end)
  end

  test "tags are drawn in the graph alongside branches", context do
    %{view: view, path: path, initial_commit: initial} = context
    commit_file(path, "second.txt", "second\n", "second commit")
    git!(path, ["tag", "v1.0.0", initial])
    git!(path, ["tag", "-a", "v2.0.0", "-m", "release two"])

    open(view, path)

    tagged = view |> element("#git-commit-#{initial}") |> render()
    assert tagged =~ "Tag v1.0.0"
    assert tagged =~ "hero-tag-micro"

    head = view |> element("#git-commit-#{head_commit(path)}") |> render()
    assert head =~ "Annotated tag v2.0.0"

    # A tag is a label, not something to select as a branch.
    refute has_element?(view, "#git-ref-#{slug("refs/tags/v1.0.0")}")
  end
end
