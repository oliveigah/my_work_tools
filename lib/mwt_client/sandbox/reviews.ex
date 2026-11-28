defmodule MWTClient.Sandbox.Reviews do
  @moduledoc """
  `mwt review`: someone's work (a pull request, a branch, a commit) put in
  the free slot you are in as uncommitted changes, over the commit where
  it parts from the branch it merges into, for you to read in Zed. No step
  needs an agent's judgment.

  What is reviewed is always named by its kind, never guessed from its
  shape (`123` is a number and a short commit id):

    * `pr NUMBER|URL`: a pull request's head. This machine fetches
      `refs/pull/N/head` from your repository's own remote into MWT's
      store (`MWTClient.Sandbox.GitTransport.fetch_review/3`), under the
      grant Git: fetch from your remotes, and the VM fetches it from
      `remote-origin`. A URL must be of that remote's repository;
    * `branch NAME`: `host-origin/NAME` or `remote-origin/NAME`, as the
      clone fetched them. A bare NAME on both at different commits is
      refused, for the asker to say which;
    * `commit ID`: one commit, against its parent. One on none of either
      remote's branches is fetched by its full id, as a pull request is.

  The branch it merges into, `--onto`, is named too: a pull request or a
  branch is refused without one (projects merge into different branches),
  and the refusal lists the branches. A bare name is the one on the side
  the work comes from (`remote-origin` for a pull request), else the other.

  The slot goes on a branch `review-…` at the merge base (what GitHub
  diffs a pull request against), its working tree the reviewed commit's,
  nothing staged: new files are marked intent-to-add (`git reset -N`), so
  Zed shows every change as one. That is all. The branch is no task, so
  the slot is taken only while those changes are there: discarded, it is
  free again, and a review of the same work there later makes the branch
  again, unless commits only it has are on it. What git ignores (`_build`,
  `deps`) stays, warm.
  """

  alias MWTClient.Sandbox.{
    GitTransport,
    HandoffRecords,
    HandoffStore,
    HostGit,
    MwtTools,
    Project,
    Projects,
    Server,
    Shown,
    Slots,
    Zed
  }

  @type error ::
          {:not_in_a_slot, [Slots.slot()]}
          | {:slot_taken, Slots.slot(), [Slots.slot()]}
          | {:bad_target, String.t(), String.t()}
          | {:onto_needed, String.t(), [String.t()]}
          | {:bad_onto, String.t()}
          | {:no_onto, String.t(), [String.t()]}
          | {:pr_elsewhere, String.t(), String.t()}
          | :pr_url_unchecked
          | {:pull_fetch, pos_integer(), String.t()}
          | {:commit_unknown, String.t()}
          | {:commit_fetch, String.t(), String.t()}
          | {:no_branch, String.t()}
          | {:ambiguous, String.t(), String.t(), String.t()}
          | {:not_fetched, String.t()}
          | {:branch_kept, String.t()}
          | {:branch_elsewhere, String.t(), String.t()}
          | {:nothing, String.t()}
          | :root
          | :unrelated
          | Projects.error()
          | String.t()

  @lock "MWT worktree slot: MWT keeps it. Free it with: mwt worktree free"

  # `COMMIT REF` for each ref $2…, `-` for a commit there is none of, in
  # the clone $1.
  @resolve ~S"""
  m=$1
  shift
  for r in "$@"; do
    c=$(git -C "$m" rev-parse -q --verify "$r^{commit}" 2>/dev/null) || c=-
    printf '%s %s\n' "$c" "$r"
  done
  """

  # The branches of both remotes in the clone $1, for a refusal to list.
  @branches ~S"""
  git -C "$1" for-each-ref --format='%(refname)' refs/remotes/remote-origin/ refs/remotes/host-origin/
  """

  # Puts the slot $p on the branch $b at the commit $h, then moves the
  # branch to where $h parts from $o (a commit, or `-` for its parent),
  # the working tree kept, nothing staged and new files intent-to-add.
  # A branch $b there already is made again only when it is no task's,
  # in no other worktree, and every commit on it is on a remote's branch
  # too. Prints `started BASE` and git's count of the changes, or why
  # not, on one line.
  @start ~S"""
  set -e
  m=$1 p=$2 b=$3 h=$4 o=$5 lock=$6 thread=$7
  if [ "$o" = - ]; then
    base=$(git -C "$m" rev-parse -q --verify "$h^1^{commit}") || { echo root; exit 0; }
  else
    base=$(git -C "$m" merge-base "$h" "$o") || { echo unrelated; exit 0; }
  fi
  [ "$base" != "$h" ] || { echo nothing; exit 0; }
  if tip=$(git -C "$m" rev-parse -q --verify "refs/heads/$b"); then
    git -C "$m" worktree list --porcelain | while IFS= read -r line; do
      case $line in
        "worktree "*) w=${line#worktree } ;;
        "branch refs/heads/$b") [ "$w" = "$p" ] || echo "elsewhere $w" ;;
      esac
    done | head -n 1 | grep . && exit 0
    if git -C "$m" config --get "branch.$b.mwt-base" >/dev/null ||
      git -C "$m" config --get "branch.$b.mwt-thread" >/dev/null ||
      [ -z "$(git -C "$m" for-each-ref --count=1 --contains "$tip" refs/remotes/)" ]; then
      echo kept
      exit 0
    fi
  fi
  if [ -d "$p" ]; then
    if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
      echo "$p has uncommitted work." >&2
      exit 1
    fi
    git -C "$p" switch -q --no-track -C "$b" "$h"
    git -C "$m" worktree lock --reason "$lock" "$p" 2>/dev/null || true
  else
    git -C "$m" worktree prune
    git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
    mkdir -p "$(dirname "$p")"
    git -C "$m" worktree add -q --no-track -B "$b" "$p" "$h"
    git -C "$m" worktree lock --reason "$lock" "$p"
  fi
  git -C "$p" reset -q -N "$base"
  git -C "$m" config --unset-all "branch.$b.mwt-summary-id" 2>/dev/null || true
  git -C "$m" config --unset-all "branch.$b.mwt-summary-0" 2>/dev/null || true
  if [ -n "$thread" ]; then git -C "$m" config "branch.$b.mwt-review-thread" "$thread"
  else git -C "$m" config --unset "branch.$b.mwt-review-thread" 2>/dev/null || true; fi
  echo "started $base"
  git -C "$p" diff --shortstat "$base" "$h"
  """

  ## The steps

  @doc """
  What `mwt review` needs before it sets up a review, once it fetched both
  remotes: the slot it runs in is checked (free), what to review is read,
  and what neither remote's branches have is fetched on this machine into
  MWT's store, a pull request's head every time. Returns the refspec the
  VM then fetches from `remote-origin`, if any. Nothing in the VM changes.
  """
  @spec prepare(String.t(), map()) :: {:ok, %{fetch: String.t() | nil}} | {:error, error()}
  def prepare(username, ask) do
    with {:ok, at} <- place(username, ask["cwd"]),
         {:ok, wanted} <- wanted(at, ask) do
      case wanted do
        %{kind: :pull, target: n} ->
          fetch_review(username, at.project, {:pull, String.to_integer(n)})

        %{kind: :commit, target: id} ->
          case commits(at, [id]) do
            [{_ref, commit}] when commit != nil ->
              {:ok, %{fetch: nil}}

            _missing ->
              if full_id?(id),
                do: fetch_review(username, at.project, {:commit, id}),
                else: {:error, {:commit_unknown, id}}
          end

        %{kind: :branch} ->
          {:ok, %{fetch: nil}}
      end
    end
  end

  @doc """
  Sets up a review in the slot `ask["cwd"]` is in, once `prepare/2` and
  the fetches went through. Returns what `mwt review` says.
  """
  @spec start(String.t(), map()) :: {:ok, String.t()} | {:error, error()}
  def start(username, ask) do
    with {:ok, at} <- place(username, ask["cwd"]),
         {:ok, wanted} <- wanted(at, ask),
         {:ok, head, wanted} <- head(at, wanted),
         {:ok, onto, wanted} <- onto(at, wanted, text(ask["onto"])),
         name = branch_name(wanted),
         {:ok, output} <-
           at.guest.exec.([
             "sh",
             "-c",
             @start,
             "mwt-review",
             at.mirror,
             at.slot.path,
             name,
             head,
             onto || "-",
             @lock,
             text(ask["thread_id"])
           ]) do
      Projects.used(username, at.project.name)

      case outcome(output) do
        {"started", base, stat} -> {:ok, started_words(at, wanted, name, head, base, stat)}
        {"elsewhere", path, _} -> {:error, {:branch_elsewhere, name, Shown.text(path)}}
        {"kept", _, _} -> {:error, {:branch_kept, name}}
        {"nothing", _, _} -> {:error, {:nothing, what_words(wanted)}}
        {"root", _, _} -> {:error, :root}
        {"unrelated", _, _} -> {:error, :unrelated}
        {other, _, _} -> {:error, "Unexpected answer: " <> Shown.text(other)}
      end
    end
  end

  ## Where it runs

  # The project, the slot `cwd` is in and a look at the slots.
  defp place(username, cwd) do
    with {:ok, project, {:worktree, top}, guest} <- Projects.locate(username, cwd),
         {:ok, look} <-
           Slots.look(project, guest, &HandoffRecords.latest(username, project.name, &1)) do
      case Slots.slot_at(look, top) do
        nil ->
          {:error, {:not_in_a_slot, look.slots}}

        slot ->
          {:ok,
           %{
             project: project,
             guest: guest,
             look: look,
             slot: slot,
             mirror: Project.mirror_path(project, guest)
           }}
      end
    end
  end

  # What the ask reviews, in a free slot.
  defp wanted(%{slot: slot} = at, %{"action" => kind} = ask)
       when kind in ["pr", "branch", "commit"] do
    if slot.free?,
      do: target(at, kind, text(ask["target"]), text(ask["onto"])),
      else: {:error, {:slot_taken, slot, at.look.slots}}
  end

  defp wanted(_at, _ask),
    do:
      {:error,
       "mwt review pr NUMBER|URL --onto BRANCH, mwt review branch NAME --onto BRANCH, or mwt review commit ID [--onto BRANCH]"}

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp target(_at, kind, "", _onto), do: {:error, {:bad_target, kind, ""}}

  defp target(at, kind, _target, "") when kind in ["pr", "branch"],
    do: {:error, {:onto_needed, kind, branches(at)}}

  defp target(at, kind, value, onto) do
    with :ok <- onto_name(onto) do
      case kind do
        "pr" -> pull(at.project, value)
        "branch" -> branch(value)
        "commit" -> commit(value)
      end
    end
  end

  defp pull(project, value) do
    case Regex.run(~r/\A#?([1-9][0-9]{0,8})\z/, value) do
      [_, n] -> {:ok, %{kind: :pull, target: n, onto: nil}}
      nil -> pull_url(project, value)
    end
  end

  # A pull request's page, of your repository's own remote: GitHub's
  # `https://HOST/OWNER/REPO/pull/N`, anything after it ignored.
  defp pull_url(project, value) do
    with %URI{scheme: scheme, host: host, path: path}
         when scheme in ["http", "https"] and is_binary(host) and is_binary(path) <-
           URI.parse(value),
         [_, slug, n] <- Regex.run(~r"\A/([^/]+/[^/]+)/pull/([1-9][0-9]{0,8})(?:/.*)?\z", path) do
      asked = String.downcase(host) <> "/" <> String.downcase(slug)

      case remote_slug(project) do
        nil -> {:error, :pr_url_unchecked}
        ^asked -> {:ok, %{kind: :pull, target: n, onto: nil}}
        remote -> {:error, {:pr_elsewhere, Shown.text(asked), remote}}
      end
    else
      _ -> {:error, {:bad_target, "pr", Shown.text(value)}}
    end
  end

  # `HOST/OWNER/REPO` of your repository's remote origin, lowercased, from
  # its URL (`https://`, `ssh://` or `git@HOST:OWNER/REPO`), or nil.
  defp remote_slug(project) do
    url = HostGit.line(project.path, ["config", "--get", "remote.origin.url"]) || ""

    {host, path} =
      case Regex.run(~r"\A(?:[^@/]+@)?([^:/]+):(?!//)(.+)\z", url) do
        [_, host, path] ->
          {host, path}

        nil ->
          %URI{host: host, path: path} = URI.parse(url)
          {host, path}
      end

    slug =
      (path || "")
      |> String.trim("/")
      |> String.replace_suffix(".git", "")
      |> String.downcase()

    if is_binary(host) and slug =~ ~r"\A[^/]+/[^/]+\z",
      do: String.downcase(host) <> "/" <> slug
  end

  defp branch(value) do
    if branch_name?(value),
      do: {:ok, %{kind: :branch, target: value, onto: nil}},
      else: {:error, {:bad_target, "branch", Shown.text(value)}}
  end

  defp commit(value) do
    if commit_id?(value),
      do: {:ok, %{kind: :commit, target: String.downcase(value), onto: nil}},
      else: {:error, {:bad_target, "commit", Shown.text(value)}}
  end

  defp onto_name(""), do: :ok

  defp onto_name(onto),
    do: if(branch_name?(onto) or commit_id?(onto), do: :ok, else: {:error, {:bad_onto, onto}})

  # A branch name as git and a shell take it, with or without its remote.
  defp branch_name?(name) do
    name =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z" and
      not String.contains?(name, ["..", "//", "@{"]) and
      not String.ends_with?(name, ["/", ".", ".lock"])
  end

  defp commit_id?(text), do: text =~ ~r/\A[0-9a-fA-F]{7,64}\z/
  defp full_id?(text), do: text =~ ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  ## What it is in the clone

  # The commit reviewed, and what is reviewed with a branch's ref as found.
  defp head(at, %{kind: :pull, target: n} = wanted) do
    case commits(at, ["refs/review/pull/#{n}"]) do
      [{_, commit}] when commit != nil -> {:ok, commit, wanted}
      _ -> {:error, {:not_fetched, "PR ##{n}"}}
    end
  end

  defp head(at, %{kind: :commit, target: id} = wanted) do
    case commits(at, [id, "refs/review/commit/#{id}"]) do
      [{_, commit}, _] when commit != nil -> {:ok, commit, %{wanted | target: commit}}
      [_, {_, commit}] when commit != nil -> {:ok, commit, %{wanted | target: commit}}
      _ -> {:error, {:commit_unknown, id}}
    end
  end

  defp head(at, %{kind: :branch, target: name} = wanted) do
    case sides(name) do
      [ref] ->
        case commits(at, [ref]) do
          [{_, commit}] when commit != nil -> {:ok, commit, %{wanted | target: ref}}
          _ -> {:error, {:no_branch, label(ref)}}
        end

      [remote, host] ->
        case commits(at, [remote, host]) do
          [{_, nil}, {_, nil}] -> {:error, {:no_branch, name}}
          [{_, same}, {_, same}] -> {:ok, same, %{wanted | target: remote}}
          [{_, commit}, {_, nil}] -> {:ok, commit, %{wanted | target: remote}}
          [{_, nil}, {_, commit}] -> {:ok, commit, %{wanted | target: host}}
          [{_, theirs}, {_, yours}] -> {:error, {:ambiguous, name, yours, theirs}}
        end
    end
  end

  # The refs a branch name may be: the one its remote names, else
  # remote-origin's, then host-origin's.
  defp sides("refs/remotes/" <> _ = ref), do: [ref]
  defp sides("remote-origin/" <> _ = name), do: ["refs/remotes/" <> name]
  defp sides("host-origin/" <> _ = name), do: ["refs/remotes/" <> name]

  defp sides(name),
    do: ["refs/remotes/remote-origin/" <> name, "refs/remotes/host-origin/" <> name]

  # What the review merges into, as a commit, with what is reviewed
  # naming it: nil for a commit's own parent, else `--onto`, a bare branch
  # name on the side the work comes from first.
  defp onto(_at, %{kind: :commit} = wanted, ""), do: {:ok, nil, wanted}

  defp onto(at, wanted, onto) do
    named = preferred(wanted, onto)
    candidates = if commit_id?(onto), do: [onto | named], else: named

    case Enum.find(commits(at, candidates), fn {_ref, commit} -> commit != nil end) do
      {ref, commit} ->
        kept = if String.starts_with?(ref, "refs/"), do: ref, else: commit
        {:ok, commit, %{wanted | onto: kept}}

      nil ->
        {:error, {:no_onto, Shown.text(onto), branches(at)}}
    end
  end

  defp preferred(wanted, name) do
    case sides(name) do
      [ref] ->
        [ref]

      [remote, host] ->
        case wanted do
          %{kind: :branch, target: "refs/remotes/host-origin/" <> _} -> [host, remote]
          _ -> [remote, host]
        end
    end
  end

  # `{ref, commit or nil}` for each ref, as the clone has them now.
  defp commits(at, refs) do
    case at.guest.exec.(["sh", "-c", @resolve, "mwt-review", at.mirror | refs]) do
      {:ok, output} ->
        found =
          for line <- String.split(output, "\n", trim: true),
              [commit, ref] <- [String.split(line, " ", parts: 2)],
              into: %{},
              do: {ref, if(commit == "-", do: nil, else: commit)}

        Enum.map(refs, &{&1, Map.get(found, &1)})

      {:error, _text} ->
        Enum.map(refs, &{&1, nil})
    end
  end

  defp branches(at) do
    case at.guest.exec.(["sh", "-c", @branches, "mwt-review", at.mirror]) do
      {:ok, output} ->
        for "refs/remotes/" <> name <- String.split(output, "\n", trim: true),
            not String.ends_with?(name, "/HEAD"),
            do: Shown.text(name)

      {:error, _} ->
        []
    end
  end

  # The review's branch: named for what it reviews.
  defp branch_name(%{kind: :pull, target: n}), do: "review-pr-#{n}"
  defp branch_name(%{kind: :commit, target: id}), do: "review-#{short(id)}"

  defp branch_name(%{kind: :branch, target: ref}) do
    name =
      ref
      |> String.replace(~r"\Arefs/remotes/(host|remote)-origin/", "")
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.replace("..", "-")
      |> String.slice(0, 80)
      |> String.trim_trailing(".lock")
      |> String.trim_trailing(".")

    "review-" <> name
  end

  # A script's answer: its first word, what follows it on the line, and the
  # lines after.
  defp outcome(output) do
    [first | rest] = String.split(output, "\n", trim: true) ++ [""]
    rest = Enum.reject(rest, &(&1 == ""))

    case String.split(first, " ", parts: 2) do
      [word, value] -> {word, value, rest}
      [word] -> {word, nil, rest}
    end
  end

  ## On this machine

  defp fetch_review(username, project, target) do
    %{dir: dir} = Server.call(username, :projects, 1_000)
    store = HandoffStore.path(dir, project.path)

    with :ok <-
           MwtTools.authorize(username, %{
             grant: :git_fetch_remote,
             tool: "git fetch (your machine)",
             title: project.name,
             args: Map.new([{"project", project.name}, target_arg(target)])
           }),
         :ok <- HandoffStore.ensure(store, project.path) do
      case GitTransport.fetch_review(store, project.path, target) do
        {:ok, ref} -> {:ok, %{fetch: "+#{ref}:#{ref}"}}
        {:error, message} -> {:error, fetch_refusal(target, message)}
      end
    end
  end

  defp target_arg({:pull, n}), do: {"pull_request", Integer.to_string(n)}
  defp target_arg({:commit, id}), do: {"commit", id}

  defp fetch_refusal({:pull, n}, message), do: {:pull_fetch, n, Shown.text(message)}
  defp fetch_refusal({:commit, id}, message), do: {:commit_fetch, id, Shown.text(message)}

  ## In words

  defp what_words(%{onto: nil} = wanted), do: target_words(wanted) <> " against its parent"
  defp what_words(wanted), do: "#{target_words(wanted)} against #{label(wanted.onto)}"

  defp target_words(%{kind: :pull, target: n}), do: "PR ##{n}"
  defp target_words(%{kind: :branch, target: ref}), do: label(ref)
  defp target_words(%{kind: :commit, target: id}), do: "commit #{short(id)}"

  defp label("refs/remotes/" <> name), do: name
  defp label(other), do: if(commit_id?(other), do: short(other), else: other)

  defp short(id), do: binary_part(id, 0, min(12, byte_size(id)))

  defp started_words(at, wanted, name, head, base, stat) do
    head_words = if wanted.kind == :commit, do: "", else: "its head #{short(head)} "

    onto_words =
      if wanted.onto, do: "where it parts from #{label(wanted.onto)}", else: "its parent"

    stat_words =
      case stat do
        [line | _] -> ": " <> String.trim(line)
        [] -> ""
      end

    Enum.join(
      [
        "Reviewing #{target_words(wanted)} in #{at.slot.name}, #{at.slot.path}: " <>
          "#{head_words}compared with #{short(base)}, #{onto_words}#{stat_words}.",
        "Its changes are uncommitted on the branch #{name}, nothing staged and new files included, for the user to read in Zed. " <>
          "The slot is taken while they are there: once discarded, it is free again.",
        "In Zed: #{Zed.command(at.slot.path)}"
      ],
      "\n"
    )
  end

  @doc "Why a review wasn't set up, in words."
  @spec explain(error()) :: String.t()
  def explain({:bad_target, kind, ""}),
    do: "Name what to review: mwt review #{kind} #{target_hint(kind)}"

  def explain({:bad_target, kind, value}),
    do: "\"#{value}\" isn't a #{kind_words(kind)}: mwt review #{kind} #{target_hint(kind)}"

  def explain({:onto_needed, kind, branches}),
    do:
      "Nothing was set up: name the branch the #{kind_words(kind)} merges into, mwt review #{kind} #{target_hint(kind)}. " <>
        "Unless the user named one, ask them which. " <> listed(branches)

  def explain({:bad_onto, onto}),
    do: "\"#{Shown.text(onto)}\" isn't a branch or a commit id. Nothing was set up."

  def explain({:no_onto, onto, branches}),
    do: "There is no branch or commit #{onto} here. Nothing was set up. " <> listed(branches)

  def explain({:pr_elsewhere, asked, remote}),
    do:
      "That pull request is in #{asked}, but this project's remote is #{remote}. Review it in a slot of that project. Nothing was set up."

  def explain(:pr_url_unchecked),
    do:
      "MWT can't tell which repository the user's remote origin is from its URL, so it can't check that pull request's link: give its number instead (mwt review pr 123 --onto BRANCH). Nothing was set up."

  def explain({:pull_fetch, n, message}),
    do:
      "Fetching PR ##{n} (refs/pull/#{n}/head) from the user's remote failed: #{message} Nothing was set up."

  def explain({:commit_unknown, id}) do
    more =
      if full_id?(id),
        do: "",
        else:
          " Give its full id: one on no branch is fetched from the user's remote by its full id."

    "There is no commit #{id} on host-origin's or remote-origin's branches.#{more} Nothing was set up."
  end

  def explain({:commit_fetch, id, message}),
    do:
      "Commit #{short(id)} is on no branch here, and fetching it by id from the user's remote failed: #{message} Nothing was set up."

  def explain({:no_branch, name}),
    do:
      "There is no branch #{name} on host-origin or remote-origin (as just fetched). Nothing was set up."

  def explain({:ambiguous, name, yours, theirs}),
    do:
      "host-origin/#{name} (#{short(yours)}) and remote-origin/#{name} (#{short(theirs)}) differ: say which, mwt review branch host-origin/#{name} or mwt review branch remote-origin/#{name}. Nothing was set up."

  def explain({:not_fetched, what}),
    do:
      "#{what} isn't in the clone: mwt review fetches it before it sets one up, so run mwt review again. Nothing was set up."

  def explain({:branch_elsewhere, name, path}),
    do:
      "#{name} is checked out in #{path}: that review is there. Discard its changes there to review it here. Nothing was set up."

  def explain({:branch_kept, name}),
    do:
      "There is a branch #{name} already, holding a task or commits only it has, so it isn't made again. Nothing was set up."

  def explain({:nothing, what}),
    do:
      "There is nothing to review: #{what} has no commit that isn't in it already. Nothing was set up."

  def explain(:root),
    do:
      "That commit has no parent: name what it is compared with, mwt review commit ID --onto BRANCH. Nothing was set up."

  def explain(:unrelated),
    do:
      "That work and its base share no history, so there is no commit to compare it from. Nothing was set up."

  def explain(reason)
      when is_tuple(reason) and elem(reason, 0) in [:not_in_a_slot, :slot_taken],
      do: Slots.explain(reason)

  def explain(reason), do: Projects.explain(reason)

  defp kind_words("pr"), do: "pull request"
  defp kind_words("branch"), do: "branch"
  defp kind_words("commit"), do: "commit id"

  defp target_hint("pr"), do: "NUMBER|URL --onto BRANCH"
  defp target_hint("branch"), do: "NAME --onto BRANCH"
  defp target_hint("commit"), do: "ID [--onto BRANCH]"

  defp listed([]), do: "Neither remote has a branch in the clone yet."

  defp listed(branches) do
    shown = Enum.take(branches, 30)
    more = if length(branches) > length(shown), do: ", …", else: ""
    "The branches: #{Enum.join(shown, ", ")}#{more}."
  end
end
