defmodule MWTClient.Git.Worktrees do
  @moduledoc """
  The worktrees of a repository, and bringing the work of one into a branch.

  Every worktree of a repository shares its branches, so the work in one is
  its branch (or, detached, its commit). Merging a worktree into a branch is
  merging that, and only what is committed: uncommitted changes stay where
  they are.

  Where the merge happens depends on the branch it goes into:

    * checked out in the worktree you have open: a plain merge there (the
      Git tool runs `MWTClient.Git.Core.merge/3`), which stops for you to
      resolve conflicts;
    * checked out in another worktree: refused, since that worktree is
      where it belongs (open it and merge there);
    * checked out nowhere: done without touching any worktree
      (`merge_into/4`): a fast-forward when it can be, else a merge commit
      made with `git merge-tree`. One that conflicts is refused, naming the
      files: check the branch out to resolve them.
  """

  alias MWTClient.Git.{Command, CommandResult, Error, Repository}

  @type t :: %{
          path: Path.t(),
          branch: String.t() | nil,
          head: String.t() | nil,
          current?: boolean()
        }

  @doc """
  The repository's worktrees: each one's folder, its branch (nil when
  detached), the commit it is at, and whether it is the one `repository`
  opened. Bare and missing ones are left out.
  """
  @spec list(Repository.t()) :: {:ok, [t()]} | {:error, Error.t()}
  def list(%Repository{} = repository) do
    with {:ok, output} <- Command.run(repository, ["worktree", "list", "--porcelain", "-z"]) do
      here = Path.expand(repository.path)

      {:ok,
       output
       |> String.split(<<0, 0>>, trim: true)
       |> Enum.map(&String.split(&1, <<0>>, trim: true))
       |> Enum.flat_map(&entry/1)
       |> Enum.map(&Map.put(&1, :current?, Path.expand(&1.path) == here))}
    end
  end

  defp entry(["worktree " <> path | fields]) do
    if "bare" in fields or Enum.any?(fields, &String.starts_with?(&1, "prunable")) or
         not File.dir?(path) do
      []
    else
      field = fn prefix ->
        Enum.find_value(
          fields,
          &if(String.starts_with?(&1, prefix), do: String.replace_prefix(&1, prefix, ""))
        )
      end

      [%{path: path, branch: field.("branch refs/heads/"), head: field.("HEAD ")}]
    end
  end

  defp entry(_fields), do: []

  @doc "Whether the worktree at `path` has uncommitted changes to files git tracks."
  @spec dirty?(Path.t()) :: boolean()
  def dirty?(path) do
    case Command.capture_path(path, ["status", "--porcelain", "--untracked-files=no"]) do
      {output, 0} -> String.trim(output) != ""
      _unreadable -> false
    end
  end

  @doc "How many commits `tip` has that `base` doesn't."
  @spec ahead(Repository.t(), String.t(), String.t()) :: non_neg_integer()
  def ahead(%Repository{} = repository, base, tip) do
    case Command.run(repository, ["rev-list", "--count", "#{base}..#{tip}"]) do
      {:ok, count} -> count |> String.trim() |> String.to_integer()
      {:error, _} -> 0
    end
  end

  @doc """
  Merges `source`, a commit, into the local branch `target`, which no
  worktree has checked out, without touching any worktree. `label` names
  the work in the merge commit's message (a branch, or a worktree's
  folder).
  """
  @spec merge_into(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def merge_into(%Repository{} = repository, target, source, label) do
    with {:ok, worktrees} <- list(repository),
         :ok <- nowhere(worktrees, target),
         {:ok, ours} <- commit(repository, "refs/heads/#{target}"),
         {:ok, theirs} <- commit(repository, source) do
      cond do
        ancestor?(repository, theirs, ours) ->
          {:error, Error.new(:invalid_argument, "#{target} already has everything in #{label}.")}

        ancestor?(repository, ours, theirs) ->
          with {:ok, _} <- move(repository, target, theirs, ours, "fast-forward to #{label}") do
            result("Fast-forwarded #{target} to #{label} (#{short(theirs)}).")
          end

        true ->
          merge_commit(repository, target, ours, theirs, label)
      end
    end
  end

  defp nowhere(worktrees, target) do
    case Enum.find(worktrees, &(&1.branch == target)) do
      nil ->
        :ok

      %{path: path} ->
        {:error,
         Error.new(
           :invalid_argument,
           "#{target} is checked out at #{path}. Open that worktree and merge there."
         )}
    end
  end

  defp merge_commit(repository, target, ours, theirs, label) do
    case Command.capture(repository, [
           "merge-tree",
           "--write-tree",
           "--name-only",
           "--no-messages",
           ours,
           theirs
         ]) do
      {output, 0} ->
        [tree | _] = String.split(output, "\n", trim: true)
        message = "Merge #{label} into #{target}"

        with {:ok, merged} <-
               Command.run(repository, [
                 "commit-tree",
                 tree,
                 "-p",
                 ours,
                 "-p",
                 theirs,
                 "-m",
                 message
               ]),
             merged = String.trim(merged),
             {:ok, _} <- move(repository, target, merged, ours, message) do
          result("Merged #{label} into #{target} (#{short(merged)}).")
        end

      {output, 1} ->
        [_tree | files] = String.split(output, "\n", trim: true)

        {:error,
         Error.new(
           :invalid_argument,
           "#{label} conflicts with #{target} in #{Enum.join(Enum.uniq(files), ", ")}. " <>
             "Check out #{target} and merge there to resolve them."
         )}

      {:system_error, error} ->
        {:error, error}

      {output, status} ->
        {:error, Error.command(["merge-tree"], status, output)}
    end
  end

  # Moves the branch only if it is still where it was read.
  defp move(repository, target, new, old, why),
    do: Command.run(repository, ["update-ref", "-m", why, "refs/heads/#{target}", new, old])

  defp commit(repository, revision) do
    case Command.run(repository, ["rev-parse", "--verify", "--quiet", revision <> "^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _} -> {:error, Error.new(:invalid_argument, "#{revision} is not a commit")}
    end
  end

  defp ancestor?(repository, older, newer),
    do: match?({_, 0}, Command.capture(repository, ["merge-base", "--is-ancestor", older, newer]))

  defp short(sha), do: String.slice(sha, 0, 7)

  defp result(text), do: {:ok, %CommandResult{action: :merge_worktree, output: text}}
end
