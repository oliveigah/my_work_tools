defmodule MWTClient.Sandbox.HandoffsLandingFilesTest do
  @moduledoc """
  What landing writes in a checkout of yours: never a hook that runs,
  even where your repository keeps its hooks in the tree, and never over
  a file git doesn't track there, ignored ones included; nor does Undo.
  The sandbox, VM stand-in and helpers are `MWTClient.HandoffsCase`'s.
  """
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Handoffs}

  setup {MWTClient.HandoffsCase, :with_slots}

  test "a hook a handoff writes where your core.hooksPath points never runs here", %{
    username: username,
    mirror: mirror,
    repo: repo,
    base: base
  } do
    # Your repository keeps its hooks in the tree.
    File.mkdir_p!(Path.join(repo, ".githooks"))
    commit(repo, [{".githooks/README", "our hooks\n"}], "hooks in the tree")
    git(repo, ["config", "core.hooksPath", ".githooks"])
    marker = Path.join(base, "hook-ran")

    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    hook = Path.join(one, ".githooks/reference-transaction")
    File.write!(hook, "#!/bin/sh\necho \"$1\" >> '#{marker}'\n")
    File.chmod!(hook, 0o755)
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)

    # It lands in your checkout, the hook among its files: every ref MWT
    # moves then (the handoff fetched in, your branch, the ref it goes
    # from) runs none.
    assert {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    assert landed.accepted.worktree == repo
    assert File.exists?(Path.join(repo, ".githooks/reference-transaction"))
    refute File.exists?(marker)

    # The next handoff comes in, lands and is undone with it there.
    two = slot(mirror, 2)
    {0, _} = worktree(username, two, "new", %{"name" => "more"})
    commit(two, [{"b.txt", "more\n"}], "more")
    {0, _} = Channel.answer("handoff", ask(two, %{"title" => "More"}), username)
    assert {:ok, _} = Handoffs.accept(username, 2, {:commit, "master"})
    assert {:ok, _} = Handoffs.undo(username, 2)
    refute File.exists?(marker)
  end

  test "a file git ignores where it would write stops it, named, and stays yours", %{
    username: username,
    mirror: mirror,
    repo: repo
  } do
    commit(repo, [{".gitignore", "_build/\n.env\n"}], "ignore .env")
    File.write!(Path.join(repo, ".env"), "API_KEY=only-here\n")
    before = sha(repo, "master")

    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    File.write!(Path.join(one, ".env"), "API_KEY=from-the-vm\n")
    git(one, ["add", "-f", ".env"])
    commit(one, [{"a.txt", "the fix\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)

    assert {:error, {:untracked, "master", ^repo, [".env"]} = refused} =
             Handoffs.preview(username, 1, {:commit, "master"})

    assert Handoffs.explain(refused) =~ "files git doesn't track, ignored ones included"
    assert Handoffs.explain(refused) =~ ".env"

    assert {:error, {:untracked, "master", ^repo, [".env"]}} =
             Handoffs.accept(username, 1, {:commit, "master"})

    assert File.read!(Path.join(repo, ".env")) == "API_KEY=only-here\n"
    assert sha(repo, "master") == before

    # A new branch writes no file of yours.
    assert {:ok, %{accepted: %{branch: "mwt/fix"}}} =
             Handoffs.accept(username, 1, {:branch, "master", "fix"})

    assert File.read!(Path.join(repo, ".env")) == "API_KEY=only-here\n"
  end

  test "an untracked file, one where a folder of it goes, or one in a folder it replaces stops it",
       %{username: username, mirror: mirror, repo: repo} do
    File.mkdir_p!(Path.join(repo, "old"))
    commit(repo, [{".gitignore", "_build/\n*.tmp\n"}, {"old/a.txt", "old\n"}], "an old folder")

    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    git(one, ["rm", "-q", "-r", "old"])
    File.mkdir_p!(Path.join(one, "docs"))

    commit(
      one,
      [{"docs/guide.md", "guide\n"}, {"notes.txt", "notes\n"}, {"old", "a file\n"}],
      "the fix"
    )

    {0, _} = Channel.answer("handoff", ask(one), username)

    # Yours: a file where its folder goes, a file where its file goes, and
    # an ignored one in the folder it makes a file.
    File.write!(Path.join(repo, "docs"), "my docs\n")
    File.write!(Path.join(repo, "notes.txt"), "my notes\n")
    File.write!(Path.join(repo, "old/cache.tmp"), "cache\n")

    assert {:error, {:untracked, "master", ^repo, ["docs", "notes.txt", "old/cache.tmp"]}} =
             Handoffs.preview(username, 1, {:commit, "master"})

    # Taken away, it lands, and the tracked file it replaces is no obstacle.
    File.rm!(Path.join(repo, "docs"))
    File.rm!(Path.join(repo, "notes.txt"))
    File.rm!(Path.join(repo, "old/cache.tmp"))
    assert {:ok, _} = Handoffs.accept(username, 1, {:commit, "master"})
    assert File.read!(Path.join(repo, "old")) == "a file\n"
  end

  test "Undo never writes over a file you made since where landing took one away", %{
    username: username,
    mirror: mirror,
    repo: repo
  } do
    one = slot(mirror, 1)
    {0, _} = worktree(username, one, "new", %{"name" => "fix"})
    git(one, ["rm", "-q", "a.txt"])
    commit(one, [{"b.txt", "instead\n"}], "the fix")
    {0, _} = Channel.answer("handoff", ask(one), username)
    {:ok, landed} = Handoffs.accept(username, 1, {:commit, "master"})
    refute File.exists?(Path.join(repo, "a.txt"))

    # Yours since, and ignored (git's reset would overwrite it).
    File.write!(Path.join(repo, ".git/info/exclude"), "a.txt\n")
    File.write!(Path.join(repo, "a.txt"), "mine, since\n")

    assert {:error, {:untracked, "master", ^repo, ["a.txt"]}} = Handoffs.undo(username, 1)
    assert File.read!(Path.join(repo, "a.txt")) == "mine, since\n"
    assert sha(repo, "master") == landed.landed.commit

    File.rm!(Path.join(repo, "a.txt"))
    assert {:ok, %{status: :open}} = Handoffs.undo(username, 1)
    assert File.read!(Path.join(repo, "a.txt")) == "one\ntwo\nthree\n"
    refute File.exists?(Path.join(repo, "b.txt"))
  end
end
