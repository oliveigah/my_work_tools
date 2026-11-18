defmodule MWTClientWeb.GitLive.MergeWorktreeTest do
  use MWTClientWeb.ConnCase, async: false

  import MWTClient.GitHelpers
  import Phoenix.LiveViewTest

  alias MWTClient.VaultHelpers
  alias MWTClientWeb.GitLive.Components

  setup %{conn: conn} do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    %{conn: conn} = sign_in(conn)
    context = initialized_repository(%{})

    # Another worktree, on its own branch, with work main doesn't have.
    tree = Path.join(context.base, "agent")
    git!(context.path, ["worktree", "add", "-q", tree, "-b", "agent-task"])
    commit = commit_file(tree, "agent.txt", "from the agent\n", "agent work")
    File.write!(Path.join(tree, "README.md"), "uncommitted\n")

    {:ok, view, _html} = live(conn, ~p"/tools/git")
    render_hook(view, "open_repository", %{"path" => context.path})
    render_async(view)

    Map.merge(context, %{view: view, tree: tree, commit: commit})
  end

  defp pick(view, branch) do
    render_hook(view, "open_menu", %{"kind" => "branch", "id" => "refs/heads/#{branch}"})

    view
    |> element("#git-menu-merge-worktree-#{Components.slug("refs/heads/#{branch}")}")
    |> render_click()
  end

  test "lists the other worktrees with what they bring, and merges one into the branch here",
       context do
    %{view: view, path: path, commit: commit} = context
    pick(view, "main")

    assert has_element?(view, "#git-confirm-title", "Merge a worktree into main")
    assert has_element?(view, "#git-confirm-worktree-0", "Merge agent-task")
    assert has_element?(view, "#git-confirm-worktree-0", "1 commit main doesn't have")
    assert has_element?(view, "#git-confirm-worktree-0", "its uncommitted changes stay there")

    view |> element("#git-confirm-worktree-0") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "main"]) == commit
    assert git!(path, ["status", "--porcelain"]) == ""
    assert git!(context.tree, ["status", "--porcelain"]) == " M README.md"
  end

  test "a branch checked out nowhere gets the work without a checkout", context do
    %{view: view, path: path, commit: commit, initial_commit: initial} = context
    git!(path, ["branch", "release"])
    render_click(view, "request", %{"action" => "refresh"})
    render_async(view)

    pick(view, "release")
    assert has_element?(view, "#git-confirm", "merged without touching any worktree")
    assert has_element?(view, "#git-confirm-worktree-0", "main")
    assert has_element?(view, "#git-confirm-worktree-1", "agent-task")

    view |> element("#git-confirm-worktree-1") |> render_click()
    render_async(view)

    assert git!(path, ["rev-parse", "release"]) == commit
    assert git!(path, ["rev-parse", "HEAD"]) == initial
  end

  test "with no other worktree, it says so", context do
    %{view: view, path: path, tree: tree} = context
    git!(path, ["worktree", "remove", "--force", tree])
    render_click(view, "request", %{"action" => "refresh"})
    render_async(view)

    pick(view, "main")
    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices", "no other worktree")
  end
end
