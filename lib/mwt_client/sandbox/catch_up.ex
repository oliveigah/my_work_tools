defmodule MWTClient.Sandbox.CatchUp do
  @moduledoc """
  Catches a handoff up with its branch here, in MWT's review store
  (`MWTClient.Sandbox.HandoffStore`), as `git rebase` would: each of its
  commits since its comparison base, applied in turn onto the branch's
  tip, keeping its author, date and message. Nothing is written into your
  repository: the store borrows its objects, and the new commits live in
  the store until the handoff lands.

  Only where every commit applies cleanly. A conflict stops it with
  nothing changed, naming the files, for the handoff's thread to resolve;
  so does a merge commit in the handoff, since replaying one is a
  judgement, not a step. The checks the thread ran saw the commits before
  this: the handoff says so.
  """

  alias MWTClient.Sandbox.{HostGit, Shown}

  @type problem ::
          :up_to_date
          | :merges
          | {:conflicts, [String.t()]}
          | String.t()

  @doc """
  Rebases the commits `base..head` onto `tip` in `store`, the committer
  being `committer` (`%{name, email}`, you) or, when nil, each commit's
  own. Returns the new head and how many commits moved.
  """
  @spec rebase(Path.t(), String.t(), String.t(), String.t(), map() | nil) ::
          {:ok, %{head: String.t(), commits: pos_integer()}} | {:error, problem()}
  def rebase(store, base, head, tip, committer) do
    with :ok <- behind(store, head, tip),
         {:ok, commits} <- commits(store, base, head) do
      commits
      |> Enum.reduce_while({:ok, tip}, fn commit, {:ok, parent} ->
        case replay(store, commit, parent, committer) do
          {:ok, new} -> {:cont, {:ok, new}}
          {:error, problem} -> {:halt, {:error, problem}}
        end
      end)
      |> case do
        {:ok, new_head} -> {:ok, %{head: new_head, commits: length(commits)}}
        {:error, problem} -> {:error, problem}
      end
    end
  end

  # Nothing to do when the tip is in its history already.
  defp behind(store, head, tip) do
    if ancestor?(store, tip, head), do: {:error, :up_to_date}, else: :ok
  end

  defp commits(store, base, head) do
    with {:ok, merges} <-
           git(store, ["rev-list", "--count", "--min-parents=2", "#{base}..#{head}"]),
         true <- String.trim(merges) == "0" or {:error, :merges},
         {:ok, listed} <-
           git(store, ["rev-list", "--reverse", "--topo-order", "#{base}..#{head}"]) do
      case String.split(listed, "\n", trim: true) do
        [] -> {:error, :up_to_date}
        commits -> {:ok, commits}
      end
    end
  end

  # One commit onto `parent`: its own change (from its parent to it),
  # merged into `parent`'s tree, as a new commit with its words.
  defp replay(store, commit, parent, committer) do
    with {:ok, tree} <- tree(store, commit, parent),
         {:ok, info} <-
           git(store, [
             "log",
             "-1",
             "--format=%an%x00%ae%x00%ad%x00%cn%x00%ce",
             "--date=raw",
             commit
           ]),
         [name, email, date, own_name, own_email] <- String.split(String.trim(info), <<0>>),
         {:ok, message} <- git(store, ["log", "-1", "--format=%B", commit]),
         {:ok, new} <-
           git(store, ["commit-tree", tree, "-p", parent, "-F", "-"],
             input: message,
             env: [
               {"GIT_AUTHOR_NAME", name},
               {"GIT_AUTHOR_EMAIL", email},
               {"GIT_AUTHOR_DATE", date},
               {"GIT_COMMITTER_NAME", (committer && committer.name) || own_name},
               {"GIT_COMMITTER_EMAIL", (committer && committer.email) || own_email}
             ]
           ) do
      {:ok, String.trim(new)}
    else
      {:error, problem} -> {:error, problem}
      _other -> {:error, "git couldn't read #{String.slice(commit, 0, 12)}."}
    end
  end

  defp tree(store, commit, parent) do
    case HostGit.run(
           store,
           [
             "merge-tree",
             "--write-tree",
             "--name-only",
             "-z",
             "--merge-base=#{commit}^",
             parent,
             commit
           ],
           ok: [0, 1]
         ) do
      {:ok, output} ->
        case String.split(output, <<0>>) do
          [tree | rest] when byte_size(tree) >= 40 ->
            case rest |> Enum.take_while(&(&1 != "")) |> Enum.uniq() do
              [] -> {:ok, tree}
              files -> {:error, {:conflicts, Enum.map(files, &Shown.text/1)}}
            end

          _ ->
            {:error, "git could not apply it: " <> Shown.text(String.slice(output, 0, 300))}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp ancestor?(store, older, newer),
    do: match?({:ok, _}, HostGit.run(store, ["merge-base", "--is-ancestor", older, newer]))

  defp git(store, args, opts \\ []), do: HostGit.run(store, args, opts)

  @doc "Why it didn't catch up, in words for you."
  @spec explain(problem()) :: String.t()
  def explain(:up_to_date), do: "It has everything its branch has already."

  def explain(:merges),
    do:
      "It has a merge commit, which MWT doesn't replay: ask its thread, in Zed, to catch up, or land it as one commit."

  def explain({:conflicts, files}),
    do:
      "Its changes conflict with its branch in: " <>
        Enum.join(files, ", ") <>
        ". Ask its thread, in Zed, to catch up: it resolves them and hands off again."

  def explain(text) when is_binary(text), do: text
end
