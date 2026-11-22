defmodule MWTClient.Sandbox.Handoff do
  @moduledoc """
  A revision submitted from a VM-owned clone for review on the host.
  `head` pins the submitted commit and `base_commit` pins its comparison
  base. Work in the VM may continue independently. The host branch is
  checked again at landing; submission never rewrites the VM's history.
  Commits wait in `HandoffStore` until the user chooses to land them.
  """

  alias MWTClient.Git.{FileDiff, Files}
  alias MWTClient.Sandbox.{EventDetails, Guest, HandoffStore, HostGit, Shown}
  alias MWTClient.Search

  @enforce_keys [:id, :title, :project, :repo, :onto, :source, :head, :opened_at]
  defstruct [
    :id,
    :title,
    :agent,
    :thread,
    :thread_id,
    :project,
    :repo,
    :onto,
    :mirrored_branch,
    :base_branch,
    :base_ref,
    :host_branch,
    :host_head,
    :source,
    :head,
    :opened_at,
    :updated_at,
    :accepted,
    :base_commit,
    :landed,
    body: "",
    status: :open,
    revision: 1,
    stats: %{},
    timeline: []
  ]

  @typedoc """
  `:open`, waiting for you; `:sent_back`, by you, with a note;
  `:withdrawn`, taken back by its agent for more work (`mwt handoff
  withdraw`), and not landed until handed off again; `:accepted` (landed);
  `:closed`.
  """
  @type status :: :open | :sent_back | :withdrawn | :accepted | :closed

  @typedoc "Where it comes from: the repository in the VM (its git folder), its worktree, its branch."
  @type source :: %{folder: String.t(), top: String.t(), branch: String.t()}

  @typedoc """
  How and where it was accepted, and what undoing it needs: `:as_is`, its
  own `commits`, by a fast-forward; `:commit`, one new commit; on
  `branch`, a new branch when `new_branch?`, made from `from`. Older
  records have `:commits` (its own commits) or `:changes`.
  """
  @type accepted :: %{
          required(:how) => :changes | :commits | :commit | :as_is,
          required(:worktree) => Path.t() | nil,
          required(:branch) => String.t(),
          optional(:from) => String.t(),
          optional(:new_branch?) => boolean(),
          required(:undo) => map() | nil,
          required(:at) => DateTime.t()
        }

  @type event :: %{at: DateTime.t(), kind: atom(), text: String.t()}

  @type t :: %__MODULE__{
          id: pos_integer(),
          title: String.t(),
          body: String.t(),
          agent: String.t() | nil,
          thread: String.t() | nil,
          thread_id: String.t() | nil,
          project: String.t(),
          repo: Path.t(),
          onto: String.t(),
          mirrored_branch: String.t() | nil,
          base_branch: String.t() | nil,
          base_ref: String.t() | nil,
          host_branch: String.t() | nil,
          host_head: String.t() | nil,
          source: source(),
          head: String.t(),
          opened_at: DateTime.t(),
          updated_at: DateTime.t() | nil,
          accepted: accepted() | nil,
          base_commit: String.t() | nil,
          landed: %{commit: String.t(), head: String.t(), branch: String.t()} | nil,
          status: status(),
          revision: pos_integer(),
          stats: map(),
          timeline: [event()]
        }

  @type facts :: %{
          tip: String.t(),
          merge_base: String.t(),
          commits: [map()],
          files: [map()],
          added: non_neg_integer(),
          removed: non_neg_integer(),
          behind: non_neg_integer(),
          conflicts: [String.t()],
          hints: [String.t()]
        }

  @type refusal ::
          :not_a_repository
          | :not_in_a_project
          | {:no_base, String.t()}
          | {:catch_up_ref, String.t()}
          | {:catch_up, String.t(), pos_integer(), [String.t()]}
          | :detached
          | {:uncommitted, String.t()}
          | :bad_branch
          | :unrelated
          | :too_large
          | :no_title

  @title_limit 200
  @body_limit 16 * 1024
  @size_limit_mib 1024
  @diff_shown 2 * 1024 * 1024
  @diff_lines 6_000
  @commits_shown 250

  # Read one checkout without changing its index, branch, or history.
  @look """
  cd "$1" 2>/dev/null || exit 3
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 3
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  branch=$(git symbolic-ref --quiet --short HEAD || true)
  head=$(git rev-parse --verify HEAD 2>/dev/null) || exit 3
  printf '%s\\n%s\\n%s\\n%s\\n' "$(cd "$top" && pwd -P)" "$common" "$branch" "$head"
  git config --get-regexp '^remote\\..*\\.url$' | head -20
  echo --
  git status --porcelain | head -20
  """

  # Files that run on your machine when you build, commit or open the
  # project. A hint, not a review.
  @runs [
    {~r{(^|/)(mix\.exs|Makefile|GNUmakefile|makefile|justfile|Justfile|Rakefile|package\.json|build\.gradle(\.kts)?|build\.rs|Cargo\.toml|setup\.py|pyproject\.toml|CMakeLists\.txt)$},
     "which runs when you build"},
    {~r{(^|/)(\.envrc|\.tool-versions|mise\.toml|\.mise\.toml)$},
     "which your shell and tools read"},
    {~r{^(\.husky|\.githooks)/|(^|/)\.pre-commit-config\.yaml$}, "which runs when you commit"},
    {~r{^(\.vscode|\.zed|\.idea)/}, "which your editor reads"},
    {~r{^\.github/workflows/|(^|/)\.gitlab-ci\.yml$}, "which runs in CI"}
  ]

  @doc "The most new data one handoff may bring, in MiB."
  def size_limit_mib, do: @size_limit_mib

  @doc """
  Reads a VM checkout and pins its current HEAD. A submission requires a
  named branch and committed work; preparation may inspect dirty work.
  """
  @spec look(Guest.t(), String.t() | nil, keyword()) ::
          {:ok, %{source: source(), head: String.t(), copy?: boolean(), remotes: [String.t()]}}
          | {:error, refusal()}
  def look(guest, cwd, opts \\ []) do
    with {:ok, output} <- guest.exec.(["sh", "-c", @look, "mwt-handoff", text(cwd)]),
         [top, folder, branch, head | rest] when top != "" and folder != "" <-
           String.split(output, "\n"),
         true <- head =~ ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/,
         {remotes, ["--" | dirty]} <- Enum.split_while(rest, &(&1 != "--")) do
      dirty = dirty |> Enum.join("\n") |> String.trim_trailing()

      cond do
        branch == "" ->
          {:error, :detached}

        dirty != "" and Keyword.get(opts, :uncommitted) != :allowed ->
          {:error, {:uncommitted, dirty}}

        not ref?(branch) ->
          {:error, :bad_branch}

        true ->
          {:ok,
           %{
             source: %{folder: folder, top: top, branch: branch},
             head: head,
             copy?: false,
             remotes:
               for(
                 line <- remotes,
                 [_key, url] <- [String.split(line, " ", parts: 2)],
                 do: String.trim(url)
               )
           }}
      end
    else
      _ -> {:error, :not_a_repository}
    end
  end

  # The branch's name comes from the VM and goes into refs and commands.
  defp ref?(branch) do
    branch =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z" and
      not String.contains?(branch, ["..", "//", "@{"]) and
      not String.ends_with?(branch, ["/", ".", ".lock"])
  end

  @doc "Keeps handoffs made with the mirror (`host/<branch>` bases) readable."
  def upgrade(handoff) do
    fields = Map.delete(handoff, :__struct__)
    branch = Map.get(fields, :mirrored_branch) || handoff.onto

    struct(
      __MODULE__,
      fields
      |> Map.put_new(:base_branch, branch)
      |> Map.put_new(:base_ref, "refs/remotes/host/" <> branch)
    )
  end

  @doc "The agent's words, cleaned for showing: title, body, agent, thread and thread id."
  @spec words(map()) :: map()
  def words(ask) do
    line = fn key, limit ->
      case ask |> Map.get(key) |> shown() |> String.trim() |> String.slice(0, limit) do
        "" -> nil
        text -> text
      end
    end

    %{
      title: line.(:title, @title_limit) || "",
      body: ask |> Map.get(:body) |> shown() |> String.slice(0, @body_limit),
      agent: line.(:agent, 60),
      thread: line.(:thread, 200),
      thread_id: line.(:thread_id, 100)
    }
  end

  @doc """
  What MWT works out about a handoff against your repository as it is now:
  the commits it brings, the files it changes, how far the mirrored branch
  has moved since, and whether the two merge.

  Once accepted, its commits and files are read from the commit it was
  built on (`base_commit`), since the mirror may hold them by then.
  """
  @spec facts(Path.t(), t()) :: {:ok, facts()} | {:error, String.t()}
  def facts(store, %__MODULE__{repo: repo, head: head} = handoff) do
    handoff =
      if is_nil(handoff.base_ref) and is_nil(handoff.base_branch),
        do: %{handoff | base_branch: handoff.mirrored_branch || handoff.onto},
        else: handoff

    onto = base_label(handoff)

    tip =
      if handoff.base_branch do
        HostGit.line(repo, [
          "rev-parse",
          "--verify",
          "--quiet",
          "refs/heads/#{handoff.base_branch}^{commit}"
        ])
      else
        handoff.base_commit
      end

    tip = tip || if(handoff.status == :accepted, do: handoff.base_commit)

    with tip when is_binary(tip) <- tip || {:error, "The base #{onto} is gone."} do
      HandoffStore.view(store, fn env ->
        merge_base =
          if is_binary(handoff.base_commit),
            do: handoff.base_commit,
            else: line(store, ["merge-base", head, tip], env)

        with merge_base when is_binary(merge_base) <-
               merge_base || {:error, "It shares no history with #{onto} any more."} do
          files = numstat(store, merge_base, head, env)

          {:ok,
           %{
             tip: tip,
             merge_base: merge_base,
             commits: commits(store, merge_base, head, env),
             files: Enum.map(files, &%{&1 | path: Shown.text(&1.path)}),
             added: files |> Enum.map(&(&1.added || 0)) |> Enum.sum(),
             removed: files |> Enum.map(&(&1.removed || 0)) |> Enum.sum(),
             behind: number(store, ["rev-list", "--count", "#{head}..#{tip}"], env),
             conflicts:
               store
               |> comparison_conflicts(merge_base, tip, head, env)
               |> Enum.map(&Shown.text/1),
             hints: hints(files)
           }}
        end
      end)
    end
  end

  def base_label(handoff) do
    handoff.base_branch ||
      case handoff.base_ref do
        "refs/heads/" <> branch -> branch
        nil -> handoff.mirrored_branch || handoff.onto
        ref -> ref
      end
  end

  @doc "Whether the handoff waits for you: open, sent back, or taken back by its agent."
  @spec waiting?(t()) :: boolean()
  def waiting?(%__MODULE__{status: status}), do: status in [:open, :sent_back, :withdrawn]

  @doc """
  What a search of the handoffs looks in, normalized
  (`MWTClient.Search.normalize/1`): the words its page shows of it, its
  number (`#12`), title, agent and thread, project, branches, the agent's
  notes, and its history with the notes it carries.

  Its commits and files aren't among them: its record doesn't keep them,
  and working them out runs git.
  """
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{} = handoff) do
    handoff |> searched() |> Enum.join("\n") |> Search.normalize()
  end

  @doc """
  The words around the first of `terms` in what the list doesn't show of
  the handoff, its agent's notes then the notes of its history, as
  `{before, match, after}`. Nil when there are no terms, or when only what
  the list shows holds them.
  """
  @spec snippet(t(), [String.t()]) :: {String.t(), String.t(), String.t()} | nil
  def snippet(%__MODULE__{} = handoff, terms) do
    Search.snippet(Stream.concat(String.splitter(handoff.body, "\n"), notes(handoff)), terms)
  end

  defp searched(handoff) do
    [
      "##{handoff.id}",
      handoff.title,
      handoff.agent,
      handoff.thread,
      handoff.project,
      handoff.source.branch,
      base_label(handoff),
      handoff.onto,
      handoff.body
    ] ++
      Enum.map(handoff.timeline, &Map.get(&1, :text)) ++ Enum.to_list(notes(handoff))
  end

  defp notes(handoff) do
    handoff.timeline
    |> Stream.map(&Map.get(&1, :note))
    |> Stream.filter(&(is_binary(&1) and &1 != ""))
  end

  @doc """
  What an event about this handoff says when its line opens
  (`MWTClient.Sandbox.EventDetails`): where it comes from and goes, its
  size, how it landed, the last of its timeline, and apart, what the agent
  wrote of it: its title and description.
  """
  @spec details(t()) :: EventDetails.t()
  def details(%__MODULE__{} = handoff),
    do: EventDetails.safely("a handoff", fn -> describe(handoff) end)

  defp describe(handoff) do
    stats = handoff.stats || %{}
    accepted = handoff.accepted || %{}
    landed = handoff.landed || %{}

    EventDetails.new([
      EventDetails.section("The handoff", [
        {"Handoff", {:link, "##{handoff.id}", "/tools/sandbox/handoffs?id=#{handoff.id}"}},
        {"Project", handoff.project},
        {"Status", status_words(handoff.status)},
        {"Revision", handoff.revision},
        {"Branch in the VM", handoff.source && Map.get(handoff.source, :branch)},
        {"Based on", base_label(handoff)},
        {"Lands onto", handoff.onto},
        {"Commit", handoff.head},
        {"Size", size_words(stats)},
        {"Conflicts", Map.get(stats, :conflicts, 0) > 0 && "#{stats.conflicts} files"},
        {"Behind its base", Map.get(stats, :behind, 0) > 0 && "#{stats.behind} commits"},
        {"Landed",
         accepted[:how] &&
           "#{landed_words(accepted.how)} on #{accepted[:branch]}" <>
             if(accepted[:new_branch?], do: " (new)", else: "")},
        {"Landed commit", landed[:commit]},
        {"In the worktree", accepted[:worktree]}
      ]),
      EventDetails.section("Latest", [
        {"Timeline",
         {:list,
          handoff.timeline
          |> Enum.take(-4)
          |> Enum.map(&"#{Calendar.strftime(&1.at, "%H:%M")} #{&1.text}")}}
      ]),
      EventDetails.agent("In the agent's words", [
        {"Agent", handoff.agent},
        {"Thread", handoff.thread},
        {"Title", handoff.title},
        {"Description", {:code, handoff.body}}
      ])
    ])
  end

  defp status_words(:open), do: "waiting for you"
  defp status_words(:sent_back), do: "sent back"
  defp status_words(:withdrawn), do: "taken back by its agent"
  defp status_words(:accepted), do: "landed"
  defp status_words(:closed), do: "closed"
  defp status_words(_other), do: nil

  defp landed_words(:as_is), do: "as it is, by a fast-forward"
  defp landed_words(:commit), do: "as one commit"
  defp landed_words(:commits), do: "its own commits"
  defp landed_words(:changes), do: "as changes"
  defp landed_words(_other), do: "landed"

  defp size_words(%{commits: commits, files: files} = stats),
    do:
      "#{commits} commits, #{files} files, +#{Map.get(stats, :added, 0)} −#{Map.get(stats, :removed, 0)}"

  defp size_words(_stats), do: nil

  @doc """
  The base in words that say which level it is: one of your branches as
  "the user's main (host-origin/main here)", else a VM branch or commit as
  it is named there.
  """
  @spec base_words(t()) :: String.t()
  def base_words(handoff) do
    case yours(handoff) do
      nil -> base_label(handoff)
      branch -> "the user's #{branch} (host-origin/#{branch} here)"
    end
  end

  @doc """
  The base as git in the VM's clone names it now: `host-origin/main` for
  one of your branches, whatever a record made before the remotes were
  renamed kept (`refs/remotes/origin/main`); else the VM ref or commit.
  """
  @spec base_in_vm(t()) :: String.t()
  def base_in_vm(handoff) do
    case yours(handoff) do
      nil -> handoff.base_ref || base_label(handoff)
      branch -> "host-origin/" <> branch
    end
  end

  @doc """
  Whether MWT deleted the handoff's branch in the VM when it landed, and no
  revision came from it since: a thread carrying it on, once it is sent
  back, makes it again first (`mwt worktree resume`).
  """
  @spec branch_deleted?(t()) :: boolean()
  def branch_deleted?(%{timeline: timeline}) do
    match?(
      %{kind: :branch_deleted},
      timeline
      |> Enum.reverse()
      |> Enum.find(&(&1.kind in [:branch_deleted, :opened, :updated, :caught_up]))
    )
  end

  # Your branch the handoff is based on, or nil for a VM branch or commit.
  defp yours(%{base_branch: branch}) when is_binary(branch), do: branch
  defp yours(%{base_ref: nil} = handoff), do: handoff.mirrored_branch || handoff.onto
  defp yours(_handoff), do: nil

  @doc "The size of a handoff, kept on its record for the list."
  @spec stats(facts()) :: map()
  def stats(facts) do
    %{
      commits: length(facts.commits),
      files: length(facts.files),
      added: facts.added,
      removed: facts.removed,
      conflicts: length(facts.conflicts),
      behind: facts.behind
    }
  end

  defp numstat(store, from, to, env) do
    case HostGit.run(store, ["diff", "--numstat", "--no-renames", "-z", from, to], env: env) do
      {:ok, output} ->
        for entry <- String.split(output, <<0>>, trim: true),
            [added, removed, path] <- [String.split(entry, "\t", parts: 3)] do
          %{path: path, added: count(added), removed: count(removed)}
        end

      {:error, _} ->
        []
    end
  end

  defp commits(store, tip, head, env) do
    format = "--format=%H%x1f%an%x1f%aI%x1f%s%x1e"

    case HostGit.run(
           store,
           ["log", format, "--max-count=#{@commits_shown}", "#{tip}..#{head}"],
           env: env
         ) do
      {:ok, output} ->
        for record <- String.split(output, "\x1e", trim: true),
            [sha, author, at, subject] <- [record |> String.trim() |> String.split("\x1f")] do
          %{
            sha: sha,
            author: Shown.text(author),
            at: datetime(at),
            subject: Shown.text(subject)
          }
        end

      {:error, _} ->
        []
    end
  end

  defp datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp comparison_conflicts(repo, base, tip, head, env) do
    args = ["merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=#{base}", tip, head]

    case HostGit.run(repo, args, ok: [0, 1], env: env) do
      {:ok, output} ->
        output
        |> String.split(<<0>>)
        |> Enum.drop(1)
        |> Enum.take_while(&(&1 != ""))
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  @doc """
  The files that hold conflicts when `theirs` is merged into `ours`: empty
  when it merges cleanly. Run with a `HandoffStore.view/2` environment.
  """
  @spec conflicts(Path.t(), String.t(), String.t(), list()) :: [String.t()]
  def conflicts(repo, ours, theirs, env) do
    case merge_tree(repo, ours, theirs, env) do
      {:ok, _tree, conflicts} -> conflicts
      {:error, _} -> []
    end
  end

  @doc """
  The merge of `theirs` into `ours`, computed without touching any working
  tree: the tree it makes, and the files in it that hold conflict markers.
  """
  @spec merge_tree(Path.t(), String.t(), String.t(), list()) ::
          {:ok, String.t(), [String.t()]} | {:error, String.t()}
  def merge_tree(repo, ours, theirs, env \\ []) do
    case HostGit.run(repo, ["merge-tree", "--write-tree", "--name-only", "-z", ours, theirs],
           ok: [0, 1],
           env: env
         ) do
      {:ok, output} ->
        case String.split(output, <<0>>) do
          [tree | rest] when byte_size(tree) >= 40 ->
            {:ok, tree, rest |> Enum.take_while(&(&1 != "")) |> Enum.uniq()}

          _ ->
            {:error, "git could not merge it: " <> Shown.text(String.slice(output, 0, 300))}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp hints(files) do
    for %{path: path} <- files,
        {pattern, why} <- @runs,
        path =~ pattern,
        uniq: true,
        do: "It changes #{Shown.text(path)}, #{why}."
  end

  @doc """
  The change, file by file, against the commit it was built on: each a
  `MWTClient.Git.FileDiff` (side `:commit`). At most the first 2 MiB and
  #{@diff_lines} lines are read; `cut?` says there was more.
  """
  @spec diff(Path.t(), t(), String.t()) ::
          {:ok, %{files: [FileDiff.t()], cut?: boolean()}} | {:error, String.t()}
  def diff(store, %__MODULE__{head: head}, merge_base) do
    HandoffStore.view(store, fn env ->
      args = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff"]

      case HostGit.run(store, args ++ ["--find-renames", merge_base, head],
             env: env,
             max: @diff_shown,
             cut: true
           ) do
        {:ok, output} -> {:ok, %{files: files(output), cut?: false}}
        {:cut, output} -> {:ok, %{files: files(output), cut?: true}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # A unified diff of many files, split at each file's header and read by
  # the Git tool's own reader.
  defp files(output) do
    output
    |> Shown.text()
    |> String.split(~r/^(?=diff --git )/m, trim: true)
    |> Enum.filter(&String.starts_with?(&1, "diff --git "))
    |> Enum.map_reduce(@diff_lines, fn chunk, budget ->
      diff = Files.parse_diff(chunk, path(chunk), :commit, max(budget, 1))
      used = diff.hunks |> Enum.map(&length(&1.lines)) |> Enum.sum()
      {%{diff | truncated?: diff.truncated? or budget <= 0}, budget - used}
    end)
    |> elem(0)
  end

  defp path(chunk) do
    lines = String.split(chunk, "\n", parts: 12)

    Enum.find_value(lines, fn
      "+++ b/" <> path -> path
      "rename to " <> path -> path
      _ -> nil
    end) ||
      Enum.find_value(lines, fn
        "--- a/" <> path -> path
        _ -> nil
      end) ||
      case Regex.run(~r{^diff --git a/(.*) b/}, hd(lines)) do
        [_, path] -> path
        _ -> hd(lines)
      end
  end

  @doc "Why a handoff was not taken, in words for the agent."
  @spec explain(refusal() | String.t()) :: String.t()
  def explain(:no_title), do: "Give it a title: mwt handoff --title \"what this is\""

  def explain(:not_a_repository),
    do: "This folder isn't in a git repository. Run mwt handoff in your worktree."

  def explain(:not_in_a_project),
    do:
      "This repository has no registered host origin. Open a project in MWT or clone its mwt:: origin, then submit from that clone."

  def explain({:no_base, ref}),
    do:
      "No comparison branch or commit #{ref} is available. Use --onto with a host branch or a commit from this clone."

  def explain({:catch_up_ref, ref}),
    do:
      "This task is behind its base #{ref}, so it wasn't built or tested with its latest commits. Run mwt handoff again to catch up and run the checks."

  def explain({:catch_up, onto, behind, []}),
    do:
      "The user's #{onto} has #{commit_count(behind)} this branch doesn't have, so it wasn't built or tested with them. Run mwt handoff again: it fetches and catches up with host-origin/#{onto}, and runs the checks again first."

  def explain({:catch_up, onto, _behind, files}),
    do:
      "This doesn't apply to the user's #{onto} as it is now, in: #{Enum.join(files, ", ")}. Run mwt handoff again: it fetches, rebases onto host-origin/#{onto} and stops at the conflicts for you to resolve."

  def explain(:detached), do: "This worktree is on no branch. Hand off a branch."

  def explain({:uncommitted, files}),
    do: "Commit or discard these first; a handoff is what you committed:\n" <> files

  def explain(:bad_branch),
    do: "MWT can't take a branch with that name. Use letters, digits, dots, dashes and slashes."

  def explain(:unrelated),
    do:
      "This branch shares no history with the user's branch, so there is nothing to compare it to."

  def explain(:too_large),
    do:
      "This brings more than #{div(@size_limit_mib, 1024)} GiB of new data, which is more than MWT takes. Leave large generated files out of the commits."

  def explain(text) when is_binary(text), do: text

  defp line(repo, args, env) do
    case HostGit.run(repo, args, env: env) do
      {:ok, output} -> output |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
      {:error, _} -> nil
    end
  end

  defp number(repo, args, env) do
    case line(repo, args, env) do
      nil -> 0
      text -> String.to_integer(text)
    end
  end

  defp commit_count(1), do: "1 commit"
  defp commit_count(n), do: "#{n} commits"

  defp count("-"), do: nil
  defp count(text), do: String.to_integer(text)

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  # The agent's words, for you to read.
  defp shown(value), do: value |> text() |> Shown.text()
end
