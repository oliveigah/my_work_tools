defmodule MWTClient.Sandbox.Project do
  @moduledoc """
  A registered host repository with a writable clone at `/work/<name>` in
  the VM, whose `host-origin` is your repository through MWT. Its branches,
  commits and files are the VM's; your branches reach it as
  `host-origin/*`.

  `slots` are the numbers of its worktree slots beside the clone,
  `/work/<name>.wt/slot-N` (`MWTClient.Sandbox.Slots`); the clone itself is
  `slot-0`, so a new project has none. Closing or forgetting a project
  leaves its clone, slots and work in the VM unchanged.
  """

  alias MWTClient.Sandbox.{EventDetails, HostGit, Shares}

  @enforce_keys [:name, :path, :mirrored_branch]
  defstruct [
    :name,
    :path,
    :mirrored_branch,
    :added_at,
    :last_used_at,
    slots: [],
    checks: "",
    closed: false
  ]

  @max_slots 9
  # What a project saved before slots were numbered had: the first three.
  @slots_before [1, 2, 3]

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          mirrored_branch: String.t(),
          slots: [pos_integer()],
          checks: String.t(),
          closed: boolean(),
          added_at: DateTime.t() | nil,
          last_used_at: DateTime.t() | nil
        }

  @type error ::
          {:not_a_repository, String.t()}
          | {:no_commit, String.t()}
          | {:refused, String.t(), String.t()}
          | :detached
          | :already_added
          | :no_more_slots
          | :bad_checks

  @doc """
  The project for the repository `path` is in, not one of `existing`. Its
  mirrored branch defaults to main, master, then the checked-out branch. Options: `:shares`,
  `:home`, `:data_dir` (`check/2`).
  """
  @spec new(String.t(), [t()], keyword()) :: {:ok, t()} | {:error, error()}
  def new(path, existing, opts \\ []) do
    with {:ok, top} <- check(path, opts),
         false <- Enum.any?(existing, &(&1.path == top)) && {:error, :already_added},
         branch when is_binary(branch) <- initial_branch(top) || {:error, :detached} do
      {:ok,
       %__MODULE__{
         name: name(Path.basename(top), existing),
         path: top,
         mirrored_branch: branch,
         added_at: DateTime.utc_now() |> DateTime.truncate(:second),
         last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end

  defp initial_branch(path), do: default_branch(branches(path), HostGit.branch(path))

  @doc """
  The initial clone checkout and landing fallback, of `branches`: main, master, then
  `checked_out` (your repository's current branch), then the first by
  name. Nil when there is no branch.
  """
  @spec default_branch([String.t()], String.t() | nil) :: String.t() | nil
  def default_branch(branches, checked_out) do
    Enum.find(["main", "master"], &(&1 in branches)) ||
      if(checked_out in branches, do: checked_out) ||
      branches |> Enum.sort() |> List.first()
  end

  # Letters, digits, dot, dash and underscore: a folder name that needs no
  # quoting anywhere. Two repositories with one name get a number.
  defp name(base, existing) do
    slug =
      base
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.trim_leading(".")
      |> then(&if(&1 == "", do: "project", else: &1))

    taken = MapSet.new(existing, & &1.name)
    Enum.find([slug | Enum.map(2..999, &"#{slug}-#{&1}")], &(not MapSet.member?(taken, &1)))
  end

  @doc """
  Checks the folder `path` on your machine: the top folder of its
  repository, when that is one MWT may mirror and run git in.

  The repository, its git folder and the folder its worktrees share must
  not be in or hold MWT's data folder or a folder shares refuse
  (`MWTClient.Sandbox.Shares.refused/2`). The VM writes none of them: no
  shared folder is mounted (`MWTClient.Sandbox.FolderSync`).

  Options: `:home`, `:data_dir`.
  """
  @spec check(String.t(), keyword()) :: {:ok, Path.t()} | {:error, error()}
  def check(path, opts \\ []) do
    path = path |> to_string() |> String.trim()
    shown = String.slice(path, 0, 300)

    with true <- String.starts_with?(path, ["/", "~/"]) || {:error, {:not_a_repository, shown}},
         {:ok, real} <- Shares.realpath(Path.expand(path)),
         true <- File.dir?(real) || {:error, {:not_a_repository, shown}},
         top when is_binary(top) <- HostGit.top(real) || {:error, {:not_a_repository, shown}},
         {:ok, top} <- Shares.realpath(top),
         paths = [top | git_dirs(top)],
         :ok <- not_refused(paths, opts),
         true <-
           HostGit.line(top, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) != nil ||
             {:error, {:no_commit, top}} do
      {:ok, top}
    else
      {:error, :loop} -> {:error, {:not_a_repository, shown}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The repository's own folder and the one its worktrees share.
  defp git_dirs(top) do
    for flag <- ["--git-dir", "--git-common-dir"],
        dir = HostGit.line(top, ["rev-parse", "--path-format=absolute", flag]),
        is_binary(dir),
        {:ok, real} <- [Shares.realpath(dir)],
        uniq: true,
        do: real
  end

  defp not_refused(paths, opts) do
    Enum.find_value(paths, :ok, fn path ->
      case Shares.refused(path, Keyword.take(opts, [:home, :data_dir])) do
        nil -> nil
        {folder, what} -> {:error, {:refused, folder, what}}
      end
    end)
  end

  @doc """
  The project with the checks a form sent; not sent, they stay as they are.
  """
  @spec update(t(), map()) :: {:ok, t()} | {:error, error()}
  def update(%__MODULE__{} = project, attrs) do
    checks = attrs |> Map.get("checks", project.checks) |> to_string() |> String.trim()

    # One line, run with sh in the VM, in the agent's own worktree.
    if String.length(checks) > 300 or checks =~ ~r/[[:cntrl:]]/u,
      do: {:error, :bad_checks},
      else: {:ok, %{project | checks: checks}}
  end

  @doc """
  The project with one more worktree slot, the lowest number it doesn't
  have, and that number.
  """
  @spec add_slot(t()) :: {:ok, t(), pos_integer()} | {:error, :no_more_slots}
  def add_slot(%__MODULE__{slots: slots} = project) do
    case Enum.find(1..@max_slots//1, &(&1 not in slots)) do
      nil -> {:error, :no_more_slots}
      n -> {:ok, %{project | slots: Enum.sort([n | slots])}, n}
    end
  end

  @doc "The project without the worktree slot `n`; the others keep their numbers."
  @spec remove_slot(t(), pos_integer()) :: t()
  def remove_slot(%__MODULE__{slots: slots} = project, n), do: %{project | slots: slots -- [n]}

  @doc """
  A project as saved by an older MWT: the fields added since at their
  defaults, those dropped since (`accept`, `handoff_when`) left out, and
  a count of slots (or none, from before slots) as the numbers it had.
  """
  @spec upgrade(t() | map()) :: t()
  def upgrade(project) do
    fields =
      project
      |> Map.from_struct()
      |> Map.put_new(:mirrored_branch, Map.get(project, :default_target))
      |> Map.drop([:__struct__, :default_target, :targets])
      |> Map.update(:slots, @slots_before, &slot_numbers/1)

    struct(__MODULE__, fields)
  end

  # Slots were a count before they were numbered.
  defp slot_numbers(count) when is_integer(count), do: Enum.to_list(1..min(count, @max_slots)//1)

  defp slot_numbers(numbers) when is_list(numbers),
    do:
      numbers
      |> Enum.filter(&(is_integer(&1) and &1 in 1..@max_slots))
      |> Enum.uniq()
      |> Enum.sort()

  defp slot_numbers(_other), do: @slots_before

  @doc "When the project was last used; one never used since this was kept, when it was added."
  @spec used_at(t()) :: DateTime.t() | nil
  def used_at(%__MODULE__{last_used_at: nil, added_at: added_at}), do: added_at
  def used_at(%__MODULE__{last_used_at: at}), do: at

  @doc """
  Sorts projects, or anything holding one under `:project` (nil for a
  repository never opened), the most recently used first; those never
  opened come last, by name.
  """
  @spec by_use([t() | map()], (term() -> String.t())) :: [t() | map()]
  def by_use(items, name \\ & &1.name) do
    Enum.sort_by(items, fn item ->
      case project_of(item) do
        nil -> {1, 0, name.(item)}
        project -> {0, -unix(used_at(project)), name.(item)}
      end
    end)
  end

  defp project_of(%__MODULE__{} = project), do: project
  defp project_of(%{project: project}), do: project

  defp unix(nil), do: 0
  defp unix(at), do: DateTime.to_unix(at)

  @doc "Your repository's local branches, by name."
  @spec branches(t() | Path.t()) :: [String.t()]
  def branches(%__MODULE__{path: path}), do: branches(path)

  def branches(path) when is_binary(path) do
    case HostGit.run(path, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) do
      {:ok, output} -> String.split(output, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc "The stable identifier used by the host's project transport."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{path: path}),
    do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)

  @doc "The VM's host-origin, resolved by MWT to this registered host repository."
  @spec remote_url(t()) :: String.t()
  def remote_url(%__MODULE__{} = project), do: "mwt::" <> id(project)

  @doc "The writable project clone in the VM."
  @spec mirror_path(t(), %{root: Path.t()}) :: Path.t()
  def mirror_path(%__MODULE__{name: name}, guest), do: Path.join(guest.root, name)

  @doc "The conventional location of optional Git worktrees; Git permits other paths."
  @spec worktrees_path(t(), %{root: Path.t()}) :: Path.t()
  def worktrees_path(project, guest), do: mirror_path(project, guest) <> ".wt"

  @doc "The project whose repository in the VM has the git folder `folder`, or nil."
  @spec of_folder([t()], %{root: Path.t()}, String.t()) :: t() | nil
  def of_folder(projects, guest, folder),
    do: Enum.find(projects, &(Path.join(mirror_path(&1, guest), ".git") == folder))

  @doc "Why a folder can't be a project, or settings can't be saved, in words."
  @spec explain(error()) :: String.t()
  def explain({:not_a_repository, path}),
    do: "#{path} is not a folder in a git repository on your machine."

  def explain({:no_commit, path}), do: "The repository at #{path} has no commit yet."

  def explain({:refused, folder, what}),
    do: "That repository is in or holds #{folder}, which holds #{what}."

  def explain(:detached),
    do:
      "That repository is on no branch. Check out the branch agents hand their work to, then open it."

  def explain(:already_added), do: "That repository is a project already."
  def explain(:no_more_slots), do: "A project has at most #{@max_slots} worktree slots."

  def explain(:bad_checks),
    do: "The checks are one command line, of at most 300 characters."

  @doc """
  The project as it is, for an event about it (`MWTClient.Sandbox.EventDetails`):
  its folder, the branch its clone follows, its slots, its checks.
  """
  @spec details(t()) :: EventDetails.t()
  def details(%__MODULE__{} = project) do
    EventDetails.safely("a project", fn ->
      EventDetails.new([EventDetails.section("The project", described(project))])
    end)
  end

  @doc "What a change of its settings changed, `[]` for nothing."
  @spec changes(t(), t()) :: EventDetails.t()
  def changes(%__MODULE__{} = before, %__MODULE__{} = now) do
    EventDetails.safely("a project's settings", fn ->
      EventDetails.new([EventDetails.changes(described(before), described(now))])
    end)
  end

  defp described(project) do
    [
      {"Name", project.name},
      {"Folder", project.path},
      {"Clone follows", project.mirrored_branch},
      {"Slots", {:list, Enum.map(project.slots || [], &"slot-#{&1}")}},
      {"Checks before a handoff", {:code, project.checks}},
      {"Closed", project.closed && "yes"}
    ]
  end
end
