defmodule MWTClient.Sandbox.Accept do
  @moduledoc """
  Lands a handoff on a host branch, in one of two ways:

    * **as it is**, a fast-forward, when the branch hasn't moved since the
      handoff caught up with it (its tip is in the handoff's history) and
      has all the task started from (its base): the branch moves to the
      handoff's own commit, so what lands is exactly
      what was checked in the VM, with the same commit IDs, and the VM's
      clone finds it on `origin/<branch>` at its next fetch. The default
      whenever it can;
    * **as one commit**: its changes since the captured comparison base
      (`base_commit`), applied onto the branch as it is now, with the
      handoff's title as the message and you as its author. When the
      branch has moved, the only way; when it hasn't, your choice
      (`one_commit: true`), as for a handoff of several commits you want as
      one.

  You choose the branch:

    * `{:commit, branch}`: the commit goes onto `branch`;
    * `{:branch, from, name}`: it starts a new branch, `mwt/` and `name`,
      from `from` (`mwt-` when a branch called `mwt` is in the way).

  Any branch can be chosen, not only the task's base, while the changes
  apply there without conflicts (a three-way merge with the task's base
  as the merge base). A branch with commits the task doesn't have gets
  them under the change, untested with it: the preview counts them.

  Previews compute the commit's tree in a scratch folder (`HandoffStore`)
  and change nothing. Landing works it out again in your repository,
  checks the branch is still where the preview saw it, and moves it with
  a compare-and-swap: a branch checked out in a worktree of yours by a
  fast-forward there, which needs no uncommitted changes to tracked files
  and no file git doesn't track, ignored ones included, where it writes
  (`clear/4`); any other by `update-ref`. No hook runs (`HostGit`).
  Undo puts the branch back (or deletes a new one) while it still has the
  landed commit, never over a file git doesn't track either.
  """

  alias MWTClient.Sandbox.{Handoff, HandoffStore, HostGit, Shown}

  @type worktree :: %{path: Path.t(), branch: String.t() | nil, head: String.t() | nil}

  @typedoc "Where a handoff lands: a new commit on a branch, or a new branch from one."
  @type destination :: {:commit, String.t()} | {:branch, String.t(), String.t()}

  @type problem ::
          {:conflicts, String.t(), [String.t()]}
          | {:branch_exists, String.t()}
          | {:branch_gone, String.t()}
          | {:pending, String.t(), Path.t(), [String.t()]}
          | {:untracked, String.t(), Path.t(), [String.t()]}
          | :bad_destination
          | :up_to_date
          | {:changed, String.t()}
          | :no_identity
          | :nothing_to_undo
          | :moved
          | String.t()

  @doc "The repository's worktrees, with the branch each has checked out."
  @spec worktrees(Path.t()) :: [worktree()]
  def worktrees(repo) do
    case HostGit.run(repo, ["worktree", "list", "--porcelain", "-z"]) do
      {:ok, output} ->
        output
        |> String.split(<<0, 0>>, trim: true)
        |> Enum.map(&String.split(&1, <<0>>, trim: true))
        |> Enum.flat_map(&worktree/1)

      {:error, _} ->
        []
    end
  end

  defp worktree(["worktree " <> path | fields]) do
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

  defp worktree(_fields), do: []

  # Uncommitted changes to tracked files, by name: staged or not.
  defp pending(path) do
    case HostGit.run(path, ["status", "--porcelain", "-z", "--untracked-files=no"]) do
      {:ok, output} ->
        output
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&(&1 |> String.slice(3..-1//1) |> Shown.text()))
        |> Enum.take(20)

      {:error, message} ->
        [message]
    end
  end

  @doc "The commit a host branch is at, or nil when there is no such branch."
  @spec tip(Path.t(), String.t()) :: String.t() | nil
  def tip(repo, branch),
    do: HostGit.line(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}^{commit}"])

  @doc """
  What a new branch's name starts with: `mwt/`, or `mwt-` when a branch
  called `mwt` is there, as git can't have both `mwt` and `mwt/NAME`.
  """
  @spec prefix(Path.t()) :: String.t()
  def prefix(repo), do: prefix_among(if tip(repo, "mwt"), do: ["mwt"], else: [])

  @doc "`prefix/1` for a repository whose local branches are `names`."
  @spec prefix_among([String.t()]) :: String.t()
  def prefix_among(names), do: if("mwt" in names, do: "mwt-", else: "mwt/")

  @doc "The host branch a destination writes: the chosen one, or the new one's full name."
  @spec branch(Path.t(), destination()) :: String.t()
  def branch(_repo, {:commit, branch}), do: branch
  def branch(repo, {:branch, _from, name}), do: prefix(repo) <> String.trim(name)

  @doc """
  What landing on `destination` would do, changing nothing: the branch it
  writes, the commit that branch is at (`tip`), the worktree it is checked
  out in, the files that conflict, whether it has the change already
  (`up_to_date?`), how many commits it has that the task doesn't
  (`behind`), whether it can land as it is (`fast_forward?`, then
  `commits`, how many), and how it would (`as`: `:as_is` or `:one_commit`).
  `opts`: `one_commit: true` lands as one commit even when it could as it
  is.
  """
  @spec preview(Path.t(), Handoff.t(), destination(), keyword()) ::
          {:ok, map()} | {:error, problem()}
  def preview(store, %Handoff{} = handoff, destination, opts \\ []) do
    with {:ok, target} <- target(handoff.repo, destination) do
      HandoffStore.view(store, fn env ->
        plan(store, handoff, handoff.head, target, env, opts)
      end)
    end
  end

  defp target(repo, {:commit, branch}) do
    with :ok <- valid_name(repo, branch),
         tip when is_binary(tip) <- tip(repo, branch) || {:error, {:branch_gone, branch}} do
      case Enum.find(worktrees(repo), &(&1.branch == branch)) do
        nil ->
          {:ok, %{branch: branch, from: branch, tip: tip, worktree: nil, new_branch?: false}}

        %{path: path} ->
          case pending(path) do
            [] ->
              {:ok, %{branch: branch, from: branch, tip: tip, worktree: path, new_branch?: false}}

            files ->
              {:error, {:pending, branch, path, files}}
          end
      end
    end
  end

  defp target(repo, {:branch, from, name} = destination) do
    new = branch(repo, destination)

    with :ok <- valid_name(repo, from),
         true <- String.trim(name) != "" or {:error, :bad_destination},
         :ok <- valid_name(repo, new),
         :ok <- free_name(repo, new),
         tip when is_binary(tip) <- tip(repo, from) || {:error, {:branch_gone, from}} do
      {:ok, %{branch: new, from: from, tip: tip, worktree: nil, new_branch?: true}}
    end
  end

  defp valid_name(repo, branch) do
    case HostGit.run(repo, ["check-ref-format", "--branch", branch]) do
      {:ok, name} -> if String.trim(name) == branch, do: :ok, else: {:error, :bad_destination}
      {:error, _} -> {:error, :bad_destination}
    end
  end

  # Neither the name itself nor a branch it would have to be a folder of,
  # or that would have to be a folder of it.
  defp free_name(repo, name) do
    taken? =
      Enum.any?(
        MWTClient.Sandbox.Project.branches(repo),
        &(&1 == name or String.starts_with?(&1, name <> "/") or
            String.starts_with?(name, &1 <> "/"))
      )

    if taken?, do: {:error, {:branch_exists, name}}, else: :ok
  end

  # The new commit's tree: what the task changed since its base, merged
  # into the target's tip. Run in the store with a scratch environment for
  # a preview, or in your repository, where its objects stay, to land.
  defp plan(repo, handoff, head, target, env, opts) do
    base = handoff.base_commit || git_line(repo, ["merge-base", head, target.tip], env)

    with base when is_binary(base) <-
           base || {:error, "It shares no history with #{target.from}."},
         {:ok, tree, conflicts} <- squash(repo, base, target.tip, head, env) do
      # As it is only when what it brings onto the branch is the task's
      # own work: the branch is in its history (it hasn't moved since), and
      # has everything the task started from. A task based on another
      # task's branch brings only its own changes, as one commit.
      fast_forward? =
        target.tip != head and ancestor?(repo, target.tip, head, env) and
          ancestor?(repo, base, target.tip, env)

      as =
        if fast_forward? and not Keyword.get(opts, :one_commit, false),
          do: :as_is,
          else: :one_commit

      plan =
        Map.merge(target, %{
          base: base,
          tree: tree,
          conflicts: Enum.map(conflicts, &Shown.text/1),
          up_to_date?:
            conflicts == [] and
              tree == git_line(repo, ["rev-parse", target.tip <> "^{tree}"], env),
          behind: count(repo, ["rev-list", "--count", "#{head}..#{target.tip}"], env),
          fast_forward?: fast_forward?,
          commits: count(repo, ["rev-list", "--count", "#{target.tip}..#{head}"], env),
          as: as
        })

      # What the branch's files become: the handoff's own commit as it is,
      # else the merged tree.
      with :ok <- clear(repo, plan, if(as == :as_is, do: head, else: tree), env),
           do: {:ok, plan}
    end
  end

  # Landing into a worktree of yours writes its files there, and git's
  # fast-forward overwrites a file it doesn't track that it finds in the
  # way when that file is one it ignores: your `.env`, a build's output.
  # So a landing that would write where such a file is, or where an
  # untracked one is, is refused, naming them, as pending changes to
  # tracked files are; a conflict, or nothing to land, says so first.
  # The cost: a file you would gladly lose (a stale build) stops it too,
  # until you move it, or land on a new branch.
  defp clear(repo, %{worktree: path, conflicts: [], up_to_date?: false} = plan, landed, env)
       when is_binary(path) do
    case in_the_way(repo, path, plan.tip, landed, env) do
      {:ok, []} -> :ok
      {:ok, files} -> {:error, {:untracked, plan.branch, path, files}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear(_repo, _plan, _landed, _env), do: :ok

  # The files of the worktree `path` that git doesn't track there, ignored
  # ones included, where moving its checkout from `from` to `to` (commits
  # or trees `repo` has, with `env`) would write: a path `to` adds that is
  # there already, or a folder of it that is a file there, or what git
  # doesn't track in a folder `to` puts a file in place of. At most 20, as
  # pending changes are named. Only the paths `to` adds are looked at, one
  # lstat each, so a landing of a few files reads a few.
  defp in_the_way(repo, path, from, to, env \\ []) do
    case HostGit.run(
           repo,
           ["diff-tree", "-r", "-z", "--no-renames", "--name-status", from, to],
           env: env
         ) do
      {:ok, output} ->
        changes =
          output |> String.split(<<0>>, trim: true) |> Enum.chunk_every(2, 2, :discard)

        # A file of yours that goes, so its place is free for a folder.
        gone = for ["D", file] <- changes, into: MapSet.new(), do: file

        files =
          for(["A", file] <- changes, do: file)
          |> Stream.flat_map(&blocking(path, &1, gone))
          |> Stream.uniq()
          |> Enum.take(20)
          |> Enum.map(&Shown.text/1)

        {:ok, files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What stands where `file` would go: a folder of it that is something
  # other than a folder there (and not a file of yours that goes), or the
  # file itself, or what git doesn't track in a folder at its place. The
  # folders are looked at from the top down, never through a link.
  defp blocking(root, file, gone) do
    parts = String.split(file, "/")

    folders =
      for n <- 1..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Enum.join("/")

    walked =
      Enum.reduce_while(folders, :there, fn folder, :there ->
        case kind(Path.join(root, folder)) do
          :directory -> {:cont, :there}
          :none -> {:halt, :absent}
          _other -> if folder in gone, do: {:halt, :absent}, else: {:halt, {:blocked, folder}}
        end
      end)

    case walked do
      :absent ->
        []

      {:blocked, folder} ->
        [folder]

      :there ->
        case kind(Path.join(root, file)) do
          :none -> []
          :directory -> untracked_in(root, file)
          _other -> [file]
        end
    end
  end

  # One lstat, raw: a path from the handoff, never followed through a link.
  defp kind(path) do
    case :file.read_link_info(path, [:raw]) do
      {:ok, info} -> File.Stat.from_record(info).type
      {:error, reason} when reason in [:enoent, :enotdir] -> :none
      {:error, _unreadable} -> :other
    end
  end

  # With no exclude patterns, `--others` lists ignored files too.
  defp untracked_in(root, folder) do
    case HostGit.run(root, ["--literal-pathspecs", "ls-files", "--others", "-z", "--", folder]) do
      {:ok, output} -> output |> String.split(<<0>>, trim: true) |> Enum.take(20)
      {:error, _reason} -> [folder]
    end
  end

  defp squash(repo, base, tip, head, env) do
    case HostGit.run(
           repo,
           ["merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=#{base}", tip, head],
           ok: [0, 1],
           env: env
         ) do
      {:ok, output} ->
        case String.split(output, <<0>>) do
          [tree | rest] when byte_size(tree) >= 40 ->
            {:ok, tree, rest |> Enum.take_while(&(&1 != "")) |> Enum.uniq()}

          _ ->
            {:error, "git could not apply it: " <> Shown.text(String.slice(output, 0, 300))}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp ancestor?(repo, older, newer, env),
    do:
      match?({:ok, _}, HostGit.run(repo, ["merge-base", "--is-ancestor", older, newer], env: env))

  defp git_line(repo, args, env) do
    case HostGit.run(repo, args, env: env) do
      {:ok, output} -> output |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      {:error, _} -> nil
    end
  end

  defp count(repo, args, env) do
    case Integer.parse(git_line(repo, args, env) || "") do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp landable(%{conflicts: [_ | _] = files, branch: branch}),
    do: {:error, {:conflicts, branch, files}}

  defp landable(%{up_to_date?: true}), do: {:error, :up_to_date}
  defp landable(_plan), do: :ok

  @doc """
  Lands it: moves the branch to the handoff's own commit (as it is), or
  makes one commit in your repository and moves the branch to it; for a
  new branch, makes it there. What undoing it needs comes back with where
  it went. `opts` as for `preview/4`.
  """
  @spec run(Path.t(), Handoff.t(), destination(), keyword()) ::
          {:ok, map()} | {:error, problem()}
  def run(store, %Handoff{repo: repo, id: id} = handoff, destination, opts \\ []) do
    with {:ok, plan} <- preview(store, handoff, destination, opts),
         :ok <- landable(plan),
         true <- plan.as == :as_is or HostGit.identity(repo) != nil or {:error, :no_identity},
         {:ok, head} <- HandoffStore.copy_into(store, repo, id, handoff.head) do
      try do
        with {:ok, target} <- target(repo, destination),
             true <- target.tip == plan.tip or {:error, {:changed, target.branch}},
             {:ok, again} <- plan(repo, handoff, head, target, [], opts),
             true <- again.as == plan.as or {:error, {:changed, target.branch}},
             :ok <- landable(again),
             {:ok, commit} <- landed_commit(repo, again, head, handoff.title),
             {:ok, undo} <- land(repo, again, commit) do
          plan = again

          {:ok,
           %{
             how: if(plan.as == :as_is, do: :as_is, else: :commit),
             commits: if(plan.as == :as_is, do: plan.commits, else: 1),
             worktree: plan.worktree,
             branch: plan.branch,
             from: plan.from,
             new_branch?: plan.new_branch?,
             undo: undo,
             at: now()
           }}
        end
      after
        HostGit.run(repo, ["update-ref", "-d", "refs/mwt/handoffs/#{id}"])
      end
    end
  end

  # As it is, the handoff's own commit; else one new commit on the tip.
  defp landed_commit(_repo, %{as: :as_is}, head, _title), do: {:ok, head}
  defp landed_commit(repo, plan, _head, title), do: commit(repo, plan, title)

  defp commit(repo, plan, title) do
    case HostGit.run(repo, ["commit-tree", plan.tree, "-p", plan.tip, "-m", title]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  # Checked out: a fast-forward in its worktree, which updates its files.
  defp land(_repo, %{worktree: path, branch: branch, tip: before}, commit) when is_binary(path) do
    with true <- HostGit.branch(path) == branch or {:error, {:changed, branch}},
         true <- tip(path, branch) == before or {:error, {:changed, branch}},
         [] <- pending(path),
         # Never over an ignored file, should one appear since the plan
         # looked: git refuses then, as it does for an untracked one.
         # git-lfs fetches what a file it checks out points at, from where
         # the VM's `.lfsconfig` says: not at landing (`git lfs pull` does it
         # after, from your remote).
         {:ok, _} <-
           HostGit.run(path, ["merge", "--ff-only", "--no-overwrite-ignore", commit],
             env: [{"GIT_LFS_SKIP_SMUDGE", "1"}],
             seconds: 300
           ) do
      {:ok, %{kind: :merge, before: before, after: commit}}
    else
      [_ | _] = files -> {:error, {:pending, branch, path, files}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Not checked out (or new): the ref alone, only from where it was.
  defp land(repo, %{branch: branch, tip: tip, new_branch?: new?}, commit) do
    before = if new?, do: nil, else: tip
    old = before || String.duplicate("0", byte_size(commit))

    with false <- Enum.any?(worktrees(repo), &(&1.branch == branch)),
         {:ok, _} <- HostGit.run(repo, ["update-ref", "refs/heads/#{branch}", commit, old]) do
      {:ok, %{kind: :branch, before: before, after: commit}}
    else
      _ -> {:error, {:changed, branch}}
    end
  end

  @doc "Undo a landing only while its branch still has the landed commit."
  def undo(_repo, %{
        branch: branch,
        undo: %{kind: :merge, before: before, after: after_},
        worktree: path
      }) do
    # The files it puts back go where landing took tracked ones away; one
    # you made there since, git would overwrite when it ignores it. What it
    # removes, landing added where nothing of yours was (`clear/4`), and
    # `--keep` refuses to remove one you changed since.
    with true <-
           (HostGit.branch(path) == branch and tip(path, branch) == after_) or {:error, :moved},
         {:ok, []} <- in_the_way(path, path, after_, before) do
      case HostGit.run(path, ["reset", "--keep", before]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, files} -> {:error, {:untracked, branch, path, files}}
      {:error, reason} -> {:error, reason}
    end
  end

  def undo(repo, %{branch: branch, undo: %{kind: :branch, before: before, after: after_}}) do
    if Enum.any?(worktrees(repo), &(&1.branch == branch)) or tip(repo, branch) != after_ do
      {:error, :moved}
    else
      args =
        if before,
          do: ["refs/heads/#{branch}", before, after_],
          else: ["-d", "refs/heads/#{branch}", after_]

      case HostGit.run(repo, ["update-ref" | args]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def undo(_repo, _accepted), do: {:error, :nothing_to_undo}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "What stopped a landing, in words for you."
  @spec explain(problem()) :: String.t()
  def explain({:conflicts, branch, files}),
    do:
      "Its changes conflict with #{branch} in: " <>
        Enum.join(files, ", ") <>
        ". Choose another branch, or ask its thread, in Zed, to catch up with #{branch} and hand off again."

  def explain({:pending, onto, path, files}),
    do:
      "Your #{onto} at #{path} has work you haven't committed: " <>
        Enum.join(files, ", ") <> ". Commit or stash it first, or land it on a new branch."

  def explain({:untracked, onto, path, files}),
    do:
      "Your #{onto} at #{path} has files git doesn't track, ignored ones included, where it would write: " <>
        Enum.join(files, ", ") <>
        ". Move them away first, or land it on a new branch."

  def explain({:branch_exists, branch}),
    do: "The branch #{branch} exists already. Choose another name, or land a new commit on it."

  def explain({:branch_gone, branch}),
    do: "The branch #{branch} is gone. Choose where it lands again."

  def explain(:bad_destination),
    do: "Enter a valid Git branch name. The name cannot be empty or contain spaces."

  def explain(:up_to_date), do: "That branch has all of it already."

  def explain({:changed, branch}),
    do: "Your #{branch} changed just now, so nothing landed. Look at what landing would do again."

  def explain(:no_identity),
    do:
      "The commit is yours, and git doesn't know who you are in this repository: set user.name and user.email."

  def explain(:nothing_to_undo), do: "There is nothing to undo."
  def explain(:moved), do: "Your branch has moved since it landed, so MWT leaves it to you."
  def explain(text) when is_binary(text), do: text
end
