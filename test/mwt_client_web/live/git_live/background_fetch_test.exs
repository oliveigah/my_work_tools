defmodule MWTClientWeb.GitLive.BackgroundFetchTest do
  # Not async: automatic fetch is turned on, and its interval set, through
  # the application env (config/test.exs turns it off for every other test,
  # whose remotes don't exist).
  use MWTClientWeb.ConnCase, async: false

  import MWTClient.GitHelpers
  import MWTClientWeb.GitLiveHelpers
  import Phoenix.LiveViewTest

  setup {MWTClientWeb.GitLiveHelpers, :tool}

  ## Background fetch

  defp auto_fetch(interval \\ :timer.seconds(30)) do
    Application.put_env(:mwt_client, :git_auto_fetch, true)
    Application.put_env(:mwt_client, :git_fetch_interval, interval)

    on_exit(fn ->
      Application.put_env(:mwt_client, :git_auto_fetch, false)
      Application.delete_env(:mwt_client, :git_fetch_interval)
    end)
  end

  test "there is no Fetch button: opening a tab fetches its remotes", context do
    %{view: view, path: path, base: base} = context
    auto_fetch()
    elsewhere = origin!(base, path)
    remote_head = push_commit!(elsewhere, "main", "remote.txt", "made elsewhere")

    open(view, path)
    render_async(view)

    refute has_element?(view, "#git-fetch")

    assert git!(path, ["rev-parse", "origin/main"]) == remote_head
    assert has_element?(view, "#git-fetch-status[data-state=idle]")
    assert has_element?(view, "#git-commit-#{remote_head}")
    # It is done quietly.
    refute has_element?(view, "#notices")
  end

  test "a repository without remotes has nothing to fetch", context do
    %{view: view, path: path} = context
    auto_fetch()
    open(view, path)

    refute has_element?(view, "#git-fetch-status")
  end

  test "fetches again as the reader works, but not more often than the interval", context do
    %{view: view, path: path, base: base} = context
    auto_fetch()
    elsewhere = origin!(base, path)

    open(view, path)
    render_async(view)

    later = push_commit!(elsewhere, "main", "later.txt", "later")
    view |> element("#git-panel-changes") |> render_click()
    render_async(view)

    # Just fetched: the click is not reason enough to go again.
    refute has_element?(view, "#git-commit-#{later}")

    Application.put_env(:mwt_client, :git_fetch_interval, 0)
    view |> element("#git-panel-commit") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-#{later}")
  end

  test "switching to a tab fetches it", context do
    %{view: view, path: path, base: base} = context
    auto_fetch(0)
    elsewhere = origin!(base, path)
    other = Path.join(base, "other")
    File.mkdir_p!(other)
    git!(other, ["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(other, "other.txt"), "other\n")

    open(view, path)
    render_async(view)
    open(view, other)

    later = push_commit!(elsewhere, "main", "later.txt", "later")
    [first, _second] = tab_ids(view)
    view |> element("#git-tab-#{first}") |> render_click()
    render_async(view)

    assert has_element?(view, "#git-commit-#{later}")
  end

  test "a failed background fetch stays quiet and shows in the toolbar", context do
    %{view: view, path: path, base: base} = context
    auto_fetch()
    git!(path, ["remote", "add", "origin", Path.join(base, "missing.git")])

    open(view, path)
    render_async(view)

    assert has_element?(view, "#git-fetch-status[data-state=failed]")
    assert view |> element("#git-fetch-status") |> render() =~ "The last background fetch failed"
    refute has_element?(view, "#notices")
    refute has_element?(view, "#git-ssh-popover")
  end

  test "a push asked for while a fetch runs goes once it is done", context do
    %{view: view, path: path, base: base} = context
    auto_fetch()
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local work")

    # The fetch the tab opened with is most likely still running: the push
    # waits for it, and starts once it is done.
    open(view, path)
    view |> element("#git-push") |> render_click()

    render_async(view)
    render_async(view)

    assert git!(path, ["rev-parse", "origin/main"]) == local
    refute has_element?(view, "#git-operation-status")
  end
end
