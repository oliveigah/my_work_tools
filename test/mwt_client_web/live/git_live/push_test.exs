defmodule MWTClientWeb.GitLive.PushTest do
  use MWTClientWeb.ConnCase, async: true

  import MWTClient.GitHelpers
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: conn} = sign_in(conn)
    context = initialized_repository(%{})
    {:ok, view, _html} = live(conn, ~p"/tools/git")
    Map.merge(context, %{view: view})
  end

  defp open_and_push(view, path) do
    render_hook(view, "open_repository", %{"path" => path})
    render_async(view)
    view |> element("#git-push") |> render_click()
    render_async(view)
  end

  defp open_repository(view, path) do
    render_hook(view, "open_repository", %{"path" => path})
    render_async(view)
  end

  # The push panel, with any of its options together.
  defp push_with(view, options) do
    view |> element("#git-push-options") |> render_click()
    view |> form("#git-push-form", push: options) |> render_submit()
    render_async(view)
  end

  # Publishes a commit, then rewrites it locally, so the next push replaces
  # remote history. Returns the commit the remote holds and the local one.
  defp diverge!(base, path, initial) do
    origin!(base, path)
    published = commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    git!(path, ["reset", "--hard", initial])
    {published, commit_file(path, "revised.txt", "revised\n", "revised")}
  end

  defp remote_head(base, branch \\ "main"),
    do: git!(Path.join(base, "remote.git"), ["rev-parse", branch])

  test "a first push offers every configured remote, can abort, and sets upstream only when chosen",
       context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "--initial-branch=main"])
    git!(path, ["remote", "add", "origin", remote])
    git!(path, ["remote", "add", "backup", remote])
    open_and_push(view, path)

    assert has_element?(view, "#git-confirm-upstream-b3JpZ2lu")
    assert has_element?(view, "#git-confirm-upstream-YmFja3Vw")
    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert git!(remote, ["for-each-ref"]) == ""
    assert {_, 1} = System.cmd("git", ["-C", path, "config", "--get", "branch.main.remote"])

    view |> element("#git-push") |> render_click()
    view |> element("#git-confirm-upstream-YmFja3Vw") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == initial
    assert git!(path, ["config", "branch.main.remote"]) == "backup"
  end

  test "an ordinary push succeeds without prompting", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    open_and_push(view, path)

    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "a rejected push can abort, then retry with lease", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    git!(path, ["reset", "--hard", initial])
    local = commit_file(path, "revised.txt", "revised\n", "revised")
    before = remote_head(base)
    open_and_push(view, path)

    assert has_element?(view, "#git-confirm-force-with-lease")
    assert has_element?(view, "#git-confirm-force")
    view |> element("#git-confirm-cancel") |> render_click()
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == before

    view |> element("#git-push") |> render_click()
    render_async(view)
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "a stale lease prompts again and only explicit force overwrites unseen remote work",
       context do
    %{base: base, path: path, view: view} = context
    elsewhere = origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    first = push_commit!(elsewhere, "main", "first.txt", "first")
    git!(path, ["fetch", "origin"])
    open_and_push(view, path)
    assert has_element?(view, "#git-confirm-force-with-lease")

    latest = push_commit!(elsewhere, "main", "latest.txt", "latest")
    # Even an external fetch while the prompt is open must not weaken the lease.
    git!(path, ["fetch", "origin"])
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)
    assert has_element?(view, "#git-confirm-force-with-lease")
    assert has_element?(view, "#git-confirm-title", "The remote branch changed")
    assert remote_head(base) == latest
    refute latest == first

    view |> element("#git-confirm-force") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == local
  end

  test "retries preserve the upstream option selected on a first push", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    git!(path, ["remote", "add", "backup", Path.join(base, "remote.git")])
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    git!(path, ["branch", "--unset-upstream"])
    git!(path, ["reset", "--hard", initial])
    local = commit_file(path, "revised.txt", "revised\n", "revised")
    open_and_push(view, path)
    view |> element("#git-confirm-upstream-b3JpZ2lu") |> render_click()
    render_async(view)
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert git!(path, ["config", "branch.main.remote"]) == "origin"
    assert remote_head(base) == local
  end

  for choice <- ["tracked-upstream", "same-name-upstream"] do
    @choice choice
    test "an upstream name mismatch offers an explicit destination: #{choice}", context do
      %{base: base, path: path, view: view, initial_commit: initial} = context
      origin!(base, path)
      git!(path, ["branch", "-m", "renamed"])
      local = commit_file(path, "local.txt", "local\n", "local")
      open_and_push(view, path)

      assert has_element?(view, "#git-confirm-tracked-upstream")
      assert has_element?(view, "#git-confirm-same-name-upstream")
      view |> element("#git-confirm-#{@choice}") |> render_click()
      render_async(view)
      refute has_element?(view, "#git-confirm")

      if @choice == "tracked-upstream" do
        assert remote_head(base) == local
        assert git!(path, ["config", "branch.renamed.merge"]) == "refs/heads/main"
      else
        assert remote_head(base) == initial
        assert remote_head(base, "renamed") == local
        assert git!(path, ["config", "branch.renamed.merge"]) == "refs/heads/renamed"
      end
    end
  end

  test "a server policy rejection shows an error without force choices", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    commit_file(path, "published.txt", "published\n", "published")
    git!(path, ["push"])
    before = remote_head(base)
    git!(path, ["reset", "--hard", initial])
    commit_file(path, "revised.txt", "revised\n", "revised")
    git!(Path.join(base, "remote.git"), ["config", "receive.denyNonFastForwards", "true"])
    open_and_push(view, path)
    view |> element("#git-confirm-force") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices [role=alert]")
    assert remote_head(base) == before
  end

  test "a transport failure shows an error without force choices", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    git!(path, ["remote", "set-url", "origin", Path.join(base, "missing.git")])
    open_and_push(view, path)

    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices [role=alert]")
  end

  ## The push panel

  test "pushing without hooks from the panel skips a pre-push hook a plain push runs", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    origin!(base, path)
    local = commit_file(path, "local.txt", "local\n", "local")
    failing_hook!(path, "pre-push")
    open_and_push(view, path)

    refute has_element?(view, "#git-confirm")
    assert has_element?(view, "#notices [role=alert]")
    assert remote_head(base) == initial

    push_with(view, %{no_verify: "true"})
    assert remote_head(base) == local
  end

  test "setting an upstream offers every remote even when the branch tracks one", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    git!(path, ["remote", "add", "backup", Path.join(base, "remote.git")])
    open_repository(view, path)

    view |> element("#git-push-options") |> render_click()
    assert has_element?(view, "#git-push-remote option[value=origin][selected]")
    assert has_element?(view, "#git-push-remote option[value=backup]")

    view
    |> form("#git-push-form", push: %{set_upstream: "true", remote: "backup"})
    |> render_change()

    assert has_element?(view, "#git-push-command", "git push --set-upstream backup main")

    view |> form("#git-push-form") |> render_submit()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert git!(path, ["config", "branch.main.remote"]) == "backup"
  end

  test "skipping hooks, setting an upstream and forcing with lease go in one push", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    {_published, revised} = diverge!(base, path, initial)
    git!(path, ["branch", "--unset-upstream"])
    failing_hook!(path, "pre-push")
    open_repository(view, path)

    view |> element("#git-push-options") |> render_click()

    # With no upstream, forcing waits for one to be set.
    assert has_element?(view, "#git-push-history-lease[disabled]")

    view
    |> form("#git-push-form", push: %{set_upstream: "true", remote: "origin"})
    |> render_change()

    view
    |> form("#git-push-form",
      push: %{no_verify: "true", set_upstream: "true", remote: "origin", history: "lease"}
    )
    |> render_change()

    assert has_element?(
             view,
             "#git-push-command",
             "git push --force-with-lease --set-upstream --no-verify origin main"
           )

    view |> form("#git-push-form") |> render_submit()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == revised
    assert git!(path, ["config", "branch.main.remote"]) == "origin"
  end

  test "the panel opens with nothing ticked each time", context do
    %{base: base, path: path, view: view} = context
    origin!(base, path)
    open_repository(view, path)

    view |> element("#git-push-options") |> render_click()

    view
    |> form("#git-push-form", push: %{no_verify: "true", history: "force"})
    |> render_change()

    assert has_element?(view, "#git-push-go", "Force push")
    view |> element("#git-push-options") |> render_click()
    refute has_element?(view, "#git-push-form")

    view |> element("#git-push-options") |> render_click()
    refute has_element?(view, "#git-push-no-verify[checked]")
    assert has_element?(view, "#git-push-history-keep[checked]")
  end

  test "force push with lease replaces what the last fetch saw and refuses unseen work",
       context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    {_published, revised} = diverge!(base, path, initial)
    open_repository(view, path)

    push_with(view, %{history: "lease"})
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == revised

    unseen = push_commit!(Path.join(base, "elsewhere"), "main", "unseen.txt", "unseen")
    commit_file(path, "again.txt", "again\n", "again")

    push_with(view, %{history: "lease"})
    assert has_element?(view, "#git-confirm-title", "The remote branch changed")
    assert remote_head(base) == unseen
  end

  test "a plain force push from the menu asks first", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    {published, revised} = diverge!(base, path, initial)
    open_repository(view, path)

    push_with(view, %{history: "force"})
    assert has_element?(view, "#git-confirm-accept", "Force push")
    view |> element("#git-confirm-cancel") |> render_click()
    assert remote_head(base) == published

    push_with(view, %{history: "force"})
    view |> element("#git-confirm-accept") |> render_click()
    render_async(view)
    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == revised
  end

  test "forcing needs an upstream on a remote", context do
    %{base: base, path: path, view: view} = context
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "--initial-branch=main"])
    git!(path, ["remote", "add", "origin", remote])
    open_repository(view, path)

    view |> element("#git-push-options") |> render_click()
    assert has_element?(view, "#git-push-history-lease[disabled]")
    assert has_element?(view, "#git-push-history-force[disabled]")
    refute has_element?(view, "#git-push-no-verify[disabled]")
    refute has_element?(view, "#git-push-set-upstream[disabled]")

    # Setting one gives forcing somewhere to go.
    view |> form("#git-push-form", push: %{set_upstream: "true"}) |> render_change()
    refute has_element?(view, "#git-push-history-lease[disabled]")
  end

  test "a first push without hooks keeps skipping them once a remote is chosen", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    remote = Path.join(base, "remote.git")
    File.mkdir_p!(remote)
    git!(remote, ["init", "--bare", "--initial-branch=main"])
    git!(path, ["remote", "add", "origin", remote])
    failing_hook!(path, "pre-push")
    open_repository(view, path)

    push_with(view, %{no_verify: "true"})
    view |> element("#git-confirm-upstream-b3JpZ2lu") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == initial
    assert git!(path, ["config", "branch.main.remote"]) == "origin"
  end

  test "a rejected push without hooks keeps skipping them on retry", context do
    %{base: base, path: path, view: view, initial_commit: initial} = context
    {_published, revised} = diverge!(base, path, initial)
    failing_hook!(path, "pre-push")
    open_repository(view, path)

    push_with(view, %{no_verify: "true"})
    view |> element("#git-confirm-force-with-lease") |> render_click()
    render_async(view)

    refute has_element?(view, "#git-confirm")
    assert remote_head(base) == revised
  end
end
