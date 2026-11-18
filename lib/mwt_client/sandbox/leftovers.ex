defmodule MWTClient.Sandbox.Leftovers do
  @moduledoc """
  Project clones left on the Work disk, with their worktrees,
  whose repository MWT no longer has on your machine. Each takes the space
  of a checkout per worktree plus their builds, and nothing removes them
  on its own.

  A project clone in the VM (`/work/<name>`, identified by its
  `mwt.project` setting, or an older mirror's `host/HEAD`) is left over when

    * its project's repository is gone from your machine: moved or
      deleted; or
    * it is no project's: you forgot it, and no repository in a shared
      folder would open as it.

  A `/work/<name>.wt` folder without its mirror is left over too.

  Removing one deletes its mirror and worktrees from the VM, and lets go of
  its project's record when it still has one. What would go with them is
  shown first: worktrees with uncommitted work, and branches with commits
  on none of your branches. A project whose repository is still on your
  machine is never offered: its mirror is in use, or it comes back the next
  time you open the repository.
  """

  alias MWTClient.Sandbox.{Discovery, Project, Projects, Server, Shown}

  @type t :: %{
          name: String.t(),
          mirror: Path.t(),
          worktrees: Path.t(),
          project: Project.t() | nil,
          why: :repository_gone | :not_a_project,
          size: non_neg_integer() | nil,
          uncommitted: [Path.t()],
          unmerged: [String.t()],
          external_worktrees: [Path.t()]
        }

  # Each mirror of MWT's on the Work disk $1 (`mirror NAME`), and each
  # worktrees folder whose mirror isn't there (`worktrees NAME`).
  @find """
  r=$1
  for d in "$r"/*; do
    [ -d "$d" ] || continue
    n=${d##*/}
    case "$n" in
      *.wt) [ -d "${d%.wt}/.git" ] || echo "worktrees ${n%.wt}" ;;
      *)
        if [ -d "$d/.git" ] &&
          { git -C "$d" config --get mwt.project >/dev/null 2>&1 ||
            git -C "$d" rev-parse -q --verify refs/remotes/host/HEAD >/dev/null 2>&1; }; then
          echo "mirror $n"
        fi
        ;;
    esac
  done
  exit 0
  """

  # For each name $2…, what removing it would delete: its size in bytes
  # (`size NAME BYTES`), each worktree with uncommitted work (`uncommitted
  # NAME PATH`), and each branch with commits on none of your branches
  # (`unmerged NAME BRANCH`).
  @look """
  r=$1
  shift
  for n in "$@"; do
    m="$r/$n" w="$r/$n.wt"
    s=$(du -sbc "$m" "$w" 2>/dev/null | tail -n 1 | cut -f1)
    echo "size $n ${s:-0}"
    [ -d "$m/.git" ] || continue
    git -C "$m" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do
      case "$p/" in
        "$m/"*|"$w/"*) ;;
        *) echo "external $n $p" ;;
      esac
      [ -d "$p" ] || continue
      if [ -n "$(git -C "$p" status --porcelain 2>/dev/null | head -n 1)" ]; then echo "uncommitted $n $p"; fi
    done
    yours=$(git -C "$m" for-each-ref --format='%(refname)' refs/remotes/origin/ refs/remotes/host/ | grep -vE '^refs/remotes/(origin|host)/HEAD$')
    git -C "$m" for-each-ref --format='%(refname)' refs/heads/ | sed 's|^refs/heads/||' | while IFS= read -r b; do
      if [ -n "$(git -C "$m" rev-list -n 1 "refs/heads/$b" --not $yours 2>/dev/null)" ]; then echo "unmerged $n $b"; fi
    done
  done
  exit 0
  """

  @remove """
  r=$1 n=$2
  rm -rf -- "$r/$n" "$r/$n.wt"
  """

  @doc """
  The projects left in the VM, by name, each with what removing it would
  delete. The VM must run.
  """
  @spec list(String.t()) :: {:ok, [t()]} | {:error, Projects.error()}
  def list(username) do
    %{projects: projects, vm: vm} = Server.call(username, :projects)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, found} <- exec(guest, @find, [guest.root]) do
      shared = shared_names(username)

      left =
        for line <- String.split(found, "\n", trim: true),
            [_kind, name] <- [String.split(line, " ", parts: 2)],
            plain?(name),
            # Generators, not matches: a match in a comprehension filters
            # out a nil project.
            project <- [Enum.find(projects, &(&1.name == name))],
            why <- [why(project, name, shared)],
            why != nil,
            do: %{
              name: name,
              mirror: Path.join(guest.root, name),
              worktrees: Path.join(guest.root, name <> ".wt"),
              project: project,
              why: why,
              size: nil,
              uncommitted: [],
              unmerged: [],
              external_worktrees: []
            }

      details(guest, Enum.sort_by(left, & &1.name))
    end
  end

  @doc """
  Removes the project `name` from the VM: its mirror and its worktrees,
  with their builds, and its project's record when it still has one. Only
  one `list/1` gives now.
  """
  @spec remove(String.t(), String.t()) :: :ok | {:error, :not_left_over | Projects.error()}
  def remove(username, name) do
    with {:ok, left} <- list(username),
         %{} = leftover <- Enum.find(left, &(&1.name == name)) || {:error, :not_left_over},
         true <-
           leftover.external_worktrees == [] ||
             {:error, {:external_worktrees, leftover.external_worktrees}},
         %{vm: vm} = Server.call(username, :projects),
         {:ok, guest} <- Projects.guest(username, vm),
         {:ok, _} <- exec(guest, @remove, [guest.root, leftover.name]) do
      if leftover.project,
        do: Server.call(username, {:remove_project, leftover.name}),
        else:
          Server.cast(
            username,
            {:log, %{outcome: :project, summary: "#{leftover.name} removed from the VM"}}
          )

      :ok
    end
  end

  @doc "Why a leftover can't be removed, in words."
  @spec explain(term()) :: String.t()
  def explain(:not_left_over),
    do: "That project isn't left over in the VM any more: its repository is on your machine."

  def explain({:external_worktrees, paths}),
    do:
      "This clone has linked worktrees outside its project folders: " <>
        Enum.join(Enum.map(paths, &Shown.text/1), ", ") <>
        ". Move or remove them with Git before removing the clone."

  def explain(reason), do: Projects.explain(reason)

  # A mirror whose repository is on your machine is in use, or comes back
  # when you open it again; it is never left over.
  defp why(%Project{path: path}, _name, _shared) do
    if File.exists?(Path.join(path, ".git")), do: nil, else: :repository_gone
  end

  defp why(nil, name, shared), do: if(MapSet.member?(shared, name), do: nil, else: :not_a_project)

  # The names repositories in your shared folders open as.
  defp shared_names(username) do
    %{shares: shares} = Server.call(username, :projects)

    for repo <- Discovery.repositories(shares),
        into: MapSet.new(),
        do: Path.basename(repo.path)
  end

  defp details(_guest, []), do: {:ok, []}

  defp details(guest, left) do
    with {:ok, output} <- exec(guest, @look, [guest.root | Enum.map(left, & &1.name)]) do
      facts =
        for line <- String.split(output, "\n", trim: true),
            [kind, name, value] <- [String.split(line, " ", parts: 3)],
            do: {name, kind, value}

      {:ok,
       Enum.map(left, fn leftover ->
         mine = for {name, kind, value} <- facts, name == leftover.name, do: {kind, value}

         %{
           leftover
           | size: Enum.find_value(mine, fn {kind, v} -> kind == "size" && to_integer(v) end),
             uncommitted: for({"uncommitted", path} <- mine, do: Shown.text(path)),
             unmerged: for({"unmerged", branch} <- mine, do: Shown.text(branch)),
             external_worktrees: for({"external", path} <- mine, do: path)
         }
       end)}
    end
  end

  defp exec(guest, script, args) do
    case guest.exec.(["sh", "-c", script, "mwt-leftovers" | args]) do
      {:ok, output} -> {:ok, output}
      {:error, text} -> {:error, "MWT couldn't look at the VM's Work disk: " <> Shown.text(text)}
    end
  end

  # A folder name of the Work disk, never a path.
  defp plain?(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, ["/", "\n", "\0"])

  defp to_integer(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> n
      :error -> nil
    end
  end
end
