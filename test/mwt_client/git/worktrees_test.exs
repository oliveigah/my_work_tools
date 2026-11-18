defmodule MWTClient.Git.WorktreesTest do
  use ExUnit.Case, async: true

  import MWTClient.GitHelpers

  alias MWTClient.Git.Worktrees

  setup :initialized_repository

  # A worktree beside the repository, on a branch of its own with one commit.
  defp worktree!(%{base: base, path: path}, branch, file, contents) do
    tree = Path.join(base, branch)
    git!(path, ["worktree", "add", "-q", tree, "-b", branch])
    commit = commit_file(tree, file, contents, "work on #{branch}")
    {tree, commit}
  end

  test "lists every worktree with its branch and commit, the opened one marked", context do
    %{repository: repository, path: path} = context
    {tree, commit} = worktree!(context, "feature", "f.txt", "f\n")
    git!(tree, ["checkout", "-q", "--detach"])

    assert {:ok, [main, other]} = Worktrees.list(repository)
    assert %{path: ^path, branch: "main", current?: true} = main
    assert %{path: ^tree, branch: nil, head: ^commit, current?: false} = other

    refute Worktrees.dirty?(tree)
    File.write!(Path.join(tree, "f.txt"), "changed\n")
    assert Worktrees.dirty?(tree)
  end

  test "into a branch checked out nowhere: a fast-forward, touching no worktree", context do
    %{repository: repository, path: path, initial_commit: initial} = context
    git!(path, ["branch", "release"])
    {_tree, commit} = worktree!(context, "feature", "f.txt", "f\n")

    assert Worktrees.ahead(repository, "release", commit) == 1
    assert {:ok, result} = Worktrees.merge_into(repository, "release", commit, "feature")
    assert result.output =~ "Fast-forwarded release to feature"
    assert git!(path, ["rev-parse", "release"]) == commit
    assert git!(path, ["rev-parse", "HEAD"]) == initial

    assert {:error, error} = Worktrees.merge_into(repository, "release", commit, "feature")
    assert error.message =~ "already has everything in feature"
  end

  test "into a branch that moved on: a merge commit with both as parents", context do
    %{repository: repository, path: path} = context
    git!(path, ["branch", "release"])
    {_tree, commit} = worktree!(context, "feature", "f.txt", "f\n")

    git!(path, ["checkout", "-q", "release"])
    release = commit_file(path, "r.txt", "r\n", "release work")
    git!(path, ["checkout", "-q", "main"])

    assert {:ok, result} = Worktrees.merge_into(repository, "release", commit, "feature")
    assert result.output =~ "Merged feature into release"

    assert git!(path, ["log", "-1", "--format=%P%n%s", "release"]) ==
             "#{release} #{commit}\nMerge feature into release"

    assert git!(path, ["show", "release:f.txt"]) == "f"
    assert git!(path, ["show", "release:r.txt"]) == "r"
    assert git!(path, ["status", "--porcelain"]) == ""
  end

  test "work that conflicts is refused, naming the files; the branch stays", context do
    %{repository: repository, path: path} = context
    git!(path, ["branch", "release"])
    {_tree, commit} = worktree!(context, "feature", "README.md", "from feature\n")

    git!(path, ["checkout", "-q", "release"])
    release = commit_file(path, "README.md", "from release\n", "release work")
    git!(path, ["checkout", "-q", "main"])

    assert {:error, error} = Worktrees.merge_into(repository, "release", commit, "feature")
    assert error.message =~ "feature conflicts with release in README.md"
    assert error.message =~ "Check out release"
    assert git!(path, ["rev-parse", "release"]) == release
  end

  test "a branch checked out in a worktree is merged there, not from here", context do
    %{repository: repository} = context
    {tree, _commit} = worktree!(context, "feature", "f.txt", "f\n")
    initial = context.initial_commit

    assert {:error, error} = Worktrees.merge_into(repository, "feature", initial, "main")
    assert error.message =~ "feature is checked out at #{tree}"
  end
end
