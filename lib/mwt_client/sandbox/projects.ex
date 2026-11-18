defmodule MWTClient.Sandbox.Projects do
  @moduledoc """
  The projects of one identity, as the pages and the agent channel use
  them: the repositories in your shared folders (`MWTClient.Sandbox.Discovery`),
  opening its writable clone in the VM, its settings and ordinary Git worktrees.

  Every repository in a shared folder is a project. The sandbox keeps a
  record of one (its name in the VM and its settings) from the first time
  you open it, and only then makes its clone. A repository reaches the VM
  only so: shared folders are copied without their repositories
  (`MWTClient.Sandbox.FolderSync`), and the VM writes none of them.

  The sandbox (`MWTClient.Sandbox.Server`) keeps the records; the git work
  runs here, in the caller's process, or in the server's mirror task
  (`follow/5`), so the server never waits on it.

  Everything that reaches into the VM needs it running. Tests set
  `config :mwt_client, MWTClient.Sandbox.Projects, guest: fun`, a function
  of the username that returns what stands in for that identity's VM (a
  folder of this machine) or nil, for its own VM.
  """

  import Kernel, except: [inspect: 2]

  alias MWTClient.Sandbox.{
    Discovery,
    Guest,
    Handoffs,
    HostGit,
    Mirror,
    Project,
    Server,
    Share,
    Shares,
    Shown,
    Slots,
    TaskBase,
    Zed
  }

  @type error ::
          :vm_not_running
          | :not_found
          | :not_in_a_project
          | :not_shared
          | {:base_needed, String.t(), [String.t()]}
          | Slots.error()
          | Project.error()
          | Zed.error()
          | String.t()

  @doc "Every project with a record, in the order they were first opened."
  @spec list(String.t()) :: [Project.t()]
  def list(username), do: Server.call(username, :projects).projects

  @doc """
  What the projects page shows: the open projects, the most recently used
  first (`MWTClient.Sandbox.Project.by_use/2`), each with the shared
  folder it is in (nil once it is in none: then MWT doesn't follow it);
  and whether any folder is shared. Reads no folder: what there is to
  open is `available/1`'s.
  """
  @spec overview(String.t()) :: %{
          open: [%{project: Project.t(), share: Share.t() | nil}],
          shares?: boolean()
        }
  def overview(username) do
    %{projects: projects, shares: shares} = Server.call(username, :projects)

    open =
      for project <- Project.by_use(projects),
          not project.closed,
          do: %{project: project, share: share_of(project.path, shares)}

    %{open: open, shares?: shares != []}
  end

  @doc """
  What there is to open, for the Open project dialog: the closed projects,
  the most recently used first, each with the shared folder it is in (nil
  once in none: it can't be opened then, only forgotten); and each shared
  folder with the repositories found in it that aren't projects yet
  (`MWTClient.Sandbox.Discovery.repositories/1`), by path. Reads the
  shared folders.
  """
  @spec available(String.t()) :: %{
          closed: [%{project: Project.t(), share: Share.t() | nil}],
          shared: [%{share: Share.t(), repos: [map()]}]
        }
  def available(username) do
    %{projects: projects, shares: shares} = Server.call(username, :projects)
    known = MapSet.new(projects, & &1.path)
    found = Discovery.repositories(shares)

    %{
      closed:
        for(
          project <- Project.by_use(projects),
          project.closed,
          do: %{project: project, share: share_of(project.path, shares)}
        ),
      shared:
        for share <- shares do
          repos =
            for %{share: ^share} = repo <- found,
                not MapSet.member?(known, repo.path),
                do: Map.put(repo, :name, Path.basename(repo.path))

          %{share: share, repos: repos}
        end
    }
  end

  @doc """
  One folder of a shared folder, to look deeper than the dialog's list
  (`MWTClient.Sandbox.Discovery.folder/2`), with each repository in it
  marked as a project (open or closed) when it is one.
  """
  @spec browse(String.t(), Path.t()) ::
          {:ok, Discovery.folder()} | {:error, :not_shared | :not_a_folder}
  def browse(username, path) do
    %{projects: projects, shares: shares} = Server.call(username, :projects)
    by_path = Map.new(projects, &{&1.path, &1})

    with {:ok, folder} <- Discovery.folder(shares, path) do
      {:ok,
       %{
         folder
         | entries: Enum.map(folder.entries, &Map.put(&1, :project, by_path[&1.path]))
       }}
    end
  end

  @doc """
  The host branches as the last metadata refresh had them, by
  name, or nil before its first.
  """
  @spec mirrored(String.t(), String.t()) :: [String.t()] | nil
  def mirrored(username, name) do
    case Server.call(username, :projects).mirror[name] do
      %{tips: tips, error: nil} -> tips |> Map.keys() |> Enum.sort()
      _ -> nil
    end
  end

  @doc "The shared folder `path` is in, or nil."
  @spec share_of(Path.t(), [Share.t()]) :: Share.t() | nil
  def share_of(path, shares), do: Enum.find(shares, &Shares.within?(path, &1.path))

  @doc """
  The project of the repository at `path`, made the first time: the
  repository must be in a read-only shared folder (`Project.check/2`).
  """
  @spec ensure(String.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def ensure(username, path) do
    %{projects: projects, shares: shares} = Server.call(username, :projects)

    with {:ok, top} <- Project.check(path, shares: shares),
         %Share{} <- share_of(top, shares) || {:error, :not_shared} do
      case Enum.find(projects, &(&1.path == top)) do
        %Project{} = project ->
          {:ok, project}

        nil ->
          with {:ok, project} <- Project.new(top, projects, shares: shares) do
            Server.call(username, {:add_project, project})
          end
      end
    end
  end

  @doc """
  Opens a project in Zed: its writable clone, or `folder`, a VM worktree.
  `project` is a project's name, or the path of a
  repository in a shared folder, which becomes a project the first time.
  The clone is initialized first when absent, and a closed project is
  open again on the Projects page.
  """
  @spec open(String.t(), String.t(), String.t() | nil) :: {:ok, Project.t()} | {:error, error()}
  def open(username, project, folder \\ nil) do
    with {:ok, project} <- named_or_ensured(username, project),
         {:ok, project, %{vm: vm}} <- find(username, project.name),
         {:ok, guest} <- guest(username, vm),
         :ok <- open_checkout(username, project, guest, folder),
         :ok <- Zed.open(username, folder || Project.mirror_path(project, guest), guest) do
      set_closed(username, project, false)
    end
  end

  @doc "Notes that a project was used just now, which puts it first on the Projects page."
  @spec used(String.t(), String.t()) :: :ok
  def used(username, name), do: Server.call(username, {:used_project, name})

  # An existing clone stays usable while its host source is unavailable.
  # Only creating a missing clone requires access to the shared source.
  defp open_checkout(username, project, guest, folder) do
    path = folder || Project.mirror_path(project, guest)

    case inspect(username, path) do
      {:ok, %{project: %{name: name}}} when name == project.name ->
        # Your branches and identity as they are now, for the page; the
        # clone opens even when its source can't be read.
        _ = mirror(username, project.name)
        :ok

      _absent when is_nil(folder) ->
        case mirror(username, project.name) do
          {:ok, _} -> :ok
          error -> error
        end

      _unknown ->
        {:error, :not_in_a_project}
    end
  end

  defp named_or_ensured(username, name_or_path) do
    case Enum.find(list(username), &(&1.name == name_or_path or &1.path == name_or_path)) do
      nil -> ensure(username, name_or_path)
      project -> {:ok, project}
    end
  end

  @doc "Saves a project's settings (`MWTClient.Sandbox.Project.update/2`)."
  @spec update(String.t(), String.t(), map()) :: {:ok, Project.t()} | {:error, error()}
  def update(username, name, attrs) do
    with {:ok, project, _} <- find(username, name),
         {:ok, updated} <- Project.update(project, attrs) do
      Server.call(username, {:put_project, updated, "Settings of #{name} saved"})
    end
  end

  @doc """
  Opens the project of the repository at `path` (or named so) on the
  Projects page: made a project the first time (`ensure/2`), and followed
  again if it was closed. Its mirror is made or brought up to date by the
  server's next look, while the VM runs.
  """
  @spec reopen(String.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def reopen(username, name_or_path) do
    with {:ok, project} <- named_or_ensured(username, name_or_path) do
      set_closed(username, project, false)
    end
  end

  @doc """
  Closes a project on the Projects page. Host branch metadata is no longer
  refreshed in the background. Its VM clone, branches, worktrees and handoffs stay.
  """
  @spec close(String.t(), String.t()) :: {:ok, Project.t()} | {:error, error()}
  def close(username, name) do
    with {:ok, project, _} <- find(username, name), do: set_closed(username, project, true)
  end

  # Already so: nothing to save, but opening one counts as using it.
  defp set_closed(username, %Project{closed: closed} = project, closed) do
    if not closed, do: used(username, project.name)
    {:ok, project}
  end

  defp set_closed(username, project, closed) do
    verb = if closed, do: "closed", else: "opened"

    with {:ok, project} <-
           Server.call(
             username,
             {:put_project, %{project | closed: closed}, "#{project.name} #{verb}"}
           ) do
      if not closed, do: used(username, project.name)
      {:ok, project}
    end
  end

  @doc """
  Adds a worktree slot to the project, the lowest number it doesn't have,
  and makes it in the VM at once when the VM runs (else when it starts):
  free, on no branch at `origin/<default branch>`. Returns its name.
  """
  @spec add_slot(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def add_slot(username, name) do
    with {:ok, _project, %{vm: vm}} <- find(username, name) do
      locked(username, name, fn ->
        with {:ok, project, _} <- find(username, name),
             {:ok, updated, n} <- Project.add_slot(project),
             {:ok, updated} <-
               Server.call(username, {:put_project, updated, "slot-#{n} added to #{name}"}) do
          case guest(username, vm) do
            {:ok, guest} ->
              with :ok <- Slots.ensure(updated, guest), do: {:ok, "slot-#{n}"}

            {:error, :vm_not_running} ->
              {:ok, "slot-#{n}"}
          end
        end
      end)
    end
  end

  @doc """
  Removes the worktree slot `slot` (`slot-2`) from the project: its folder
  in the VM, with its build, and its number, which the next slot added
  takes again. Only a free slot with no uncommitted work
  (`MWTClient.Sandbox.Slots.remove/4`); the VM must run.
  """
  @spec remove_slot(String.t(), String.t(), String.t()) :: :ok | {:error, error()}
  def remove_slot(username, name, slot) do
    with {:ok, _project, %{vm: vm}} <- find(username, name),
         {:ok, guest} <- guest(username, vm) do
      locked(username, name, fn ->
        with {:ok, project, %{handoffs: handoffs}} <- find(username, name),
             n when is_integer(n) <-
               Slots.number(slot) ||
                 {:error, {:no_such_slot, Shown.text(to_string(slot)), Slots.names(project)}},
             :ok <- Slots.remove(project, guest, "slot-#{n}", handoffs),
             {:ok, _} <-
               Server.call(
                 username,
                 {:put_project, Project.remove_slot(project, n), "slot-#{n} removed from #{name}"}
               ) do
          :ok
        end
      end)
    end
  end

  @doc """
  Lets go of a project's record: its name and settings. A repository still
  in a shared folder stays listed, and is a project again when opened.
  Its clone and worktrees in the VM stay, for the VM to delete.
  """
  @spec forget(String.t(), String.t()) :: :ok | {:error, error()}
  def forget(username, name) do
    with {:ok, _project} <- Server.call(username, {:remove_project, name}), do: :ok
  end

  @doc """
  Initializes the writable clone when necessary and refreshes host branch
  metadata and handoff previews. An existing clone's refs, checkout,
  index and files stay as they are. Fetching is an ordinary Git operation.
  """
  @spec mirror(String.t(), String.t()) :: {:ok, Mirror.result()} | {:error, error()}
  def mirror(username, name) do
    with {:ok, project, %{vm: vm, shares: shares}} <- find(username, name),
         :ok <- workable(project, shares),
         {:ok, guest} <- guest(username, vm) do
      locked(username, name, fn ->
        # As it is once the lock is held: its settings may have changed.
        with {:ok, project, _} <- find(username, name),
             do: update_mirror(username, project, guest, vm)
      end)
    end
  end

  @doc """
  Makes sure the clone has been initialized and host branch metadata is
  current. It never fetches into or changes a VM-owned checkout.
  """
  @spec fresh(String.t(), String.t()) :: :ok | {:error, error()}
  def fresh(username, name) do
    with {:ok, project, %{vm: vm, shares: shares, mirror: entries}} <- find(username, name),
         :ok <- workable(project, shares),
         {:ok, guest} <- guest(username, vm) do
      case update_when_due(username, project, guest, vm, 0, Map.get(entries, name)) do
        {:error, text} -> {:error, text}
        _current_or_updated -> :ok
      end
    end
  end

  # Initialization is one-time. A refresh never changes a VM checkout; it
  # makes the numbered slots whose folders aren't there.
  defp update_mirror(username, project, guest, vm) do
    result =
      with {:ok, done} <- Mirror.run(project, guest),
           project = checkout_picked(username, project, done.default),
           :ok <- Slots.ensure(project, guest) do
        {:ok, done}
      end

    entry =
      case result do
        {:ok, done} ->
          Map.put(done, :error, nil)

        {:error, text} ->
          %{
            tips: Mirror.tips(project),
            default: project.mirrored_branch,
            rescued: nil,
            identity: nil
          }
          |> Map.put(:error, text)
      end
      |> Map.merge(%{at: now(), vm_started_at: vm[:started_at]})

    Server.call(username, {:mirrored, project.name, entry})
    if match?({:ok, _}, result), do: Handoffs.refresh(username, project.name)
    result
  end

  # A missing host default chooses another landing fallback. The VM's
  # current branch is independent and stays where its developer put it.
  defp checkout_picked(_username, %Project{mirrored_branch: branch} = project, branch),
    do: project

  defp checkout_picked(username, project, branch) do
    picked = %{project | mirrored_branch: branch}

    summary =
      "Default host branch for #{project.name} is #{branch}: #{project.mirrored_branch} is gone"

    case Server.call(username, {:put_project, picked, summary}) do
      {:ok, picked} -> picked
      {:error, _gone} -> picked
    end
  end

  # A project is worked on only while its repository is in a shared folder.
  defp workable(project, shares) do
    case share_of(project.path, shares) do
      nil -> {:error, :not_shared}
      %Share{} -> :ok
    end
  end

  @doc """
  One look at every mirror, for the server's task: each whose branches
  moved, whose settings changed, or that the VM hasn't had since it
  started, is updated. A failed one is tried again after `retry` seconds.
  Only open projects (`Project.closed`) still in a shared folder are
  followed.
  """
  @spec follow(String.t(), [Project.t()], map(), map(), pos_integer(), [Share.t()]) :: :ok
  def follow(username, projects, mirror, vm, retry, shares) do
    with {:ok, guest} <- guest(username, vm) do
      for project <- projects,
          not project.closed,
          workable(project, shares) == :ok,
          do: update_when_due(username, project, guest, vm, retry, Map.get(mirror, project.name))
    end

    :ok
  end

  # Updates the mirror when `last`, its last update, says it is due; looked
  # at again once the lock is held, since the update the caller waited for
  # may have done it. `:current` when nothing was due.
  defp update_when_due(username, project, guest, vm, retry, last) do
    if due?(last, project, Mirror.tips(project), vm, retry) do
      locked(username, project.name, fn ->
        # The project and its last update as they are once the lock is
        # held: a slot added or removed meanwhile counts.
        %{projects: projects, mirror: entries} = Server.call(username, :projects)
        last = Map.get(entries, project.name)

        case Enum.find(projects, &(&1.name == project.name)) do
          nil ->
            :current

          project ->
            if due?(last, project, Mirror.tips(project), vm, retry),
              do: update_mirror(username, project, guest, vm),
              else: :current
        end
      end)
    else
      :current
    end
  end

  # Whether a mirror needs an update: never made, your branches or its
  # settings moved, the VM started since, or the last update failed at
  # least `retry` seconds ago.
  defp due?(nil, _project, _tips, _vm, _retry), do: true

  defp due?(last, project, tips, vm, retry) do
    moved? =
      last.tips != tips or last.default != project.mirrored_branch or
        last.vm_started_at != vm[:started_at]

    moved? or (last.error != nil and DateTime.diff(now(), last.at) >= retry)
  end

  # One update of a project's mirror at a time, whoever asks: the server's
  # task, a page, or an agent's command. Two at once would fight over the
  # mirror's checkout. The lock goes with the process holding it, if it dies.
  defp locked(username, name, fun),
    do: :global.trans({{__MODULE__, username, name}, self()}, fun, [node()])

  @doc """
  The project's worktree slots and its other worktrees, as the VM has them
  now (`slot-0` is the clone itself), each slot with its branch's latest handoff, whether it is free, and
  whether a Zed window has it open (`MWTClient.Sandbox.Slots.look/4`,
  `MWTClient.Sandbox.Slots.mark_zed/2`).
  """
  @spec slots(String.t(), String.t()) :: {:ok, Slots.look()} | {:error, error()}
  def slots(username, name) do
    with {:ok, project, %{vm: vm, handoffs: handoffs}} <- find(username, name),
         {:ok, guest} <- guest(username, vm) do
      # Two trips into the VM, side by side: each is mostly msb exec's.
      opened = Task.async(fn -> Zed.opened(guest) end)

      case Slots.look(project, guest, handoffs) do
        {:ok, look} ->
          {:ok, %{look | slots: Slots.mark_zed(look.slots, Task.await(opened, :infinity))}}

        error ->
          Task.shutdown(opened, :brutal_kill)
          error
      end
    end
  end

  ## What agents ask through the channel

  @inspect ~S"""
  set -e
  cd "$1"
  top=$(git rev-parse --show-toplevel)
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  branch=$(git symbolic-ref -q --short HEAD || true)
  head=$(git rev-parse --verify --quiet HEAD || true)
  origin=$(git config --get remote.origin.url || true)
  id=$(git config --get mwt.project || true)
  printf '%s\0' "$top" "$common" "$branch" "$head" "$origin" "$id"
  """

  @doc """
  Inspects an ordinary VM checkout without changing it. A linked worktree
  is recognized by its common Git directory; another clone by its registered
  MWT origin. No branch, reservation or task record is required.
  """
  @spec inspect(String.t(), String.t() | nil) :: {:ok, map()} | {:error, error()}
  def inspect(username, cwd) do
    %{projects: projects, vm: vm} = Server.call(username, :projects)

    with {:ok, guest} <- guest(username, vm),
         {:ok, output} <- guest.exec.(["sh", "-c", @inspect, "mwt-project", cwd || ""]),
         [top, common, branch, head, origin, id, ""] <- String.split(output, <<0>>),
         %Project{} = project <-
           Project.of_folder(projects, guest, common) ||
             Enum.find(projects, &(Project.remote_url(&1) == origin or Project.id(&1) == id)) do
      {:ok,
       %{
         project: project,
         guest: guest,
         top: top,
         common_dir: common,
         branch: blank(branch),
         head: blank(head),
         origin: blank(origin)
       }}
    else
      {:error, :vm_not_running} -> {:error, :vm_not_running}
      _ -> {:error, :not_in_a_project}
    end
  end

  @doc "The registered project and checkout containing a folder in the VM."
  @spec locate(String.t(), String.t() | nil) ::
          {:ok, Project.t(), {:worktree, String.t()}, Guest.t()} | {:error, error()}
  def locate(username, cwd) do
    with {:ok, %{project: project, guest: guest, top: top}} <- inspect(username, cwd) do
      # The clone itself is slot-0, a worktree like the others.
      {:ok, project, {:worktree, top}, guest}
    end
  end

  @doc "The project and its worktrees; reading never refreshes or moves a checkout."
  def place(username, cwd) do
    with {:ok, project, where, guest} <- locate(username, cwd) do
      look =
        case Slots.look(project, guest, handoffs(username)) do
          {:ok, look} -> look
          {:error, _} -> nil
        end

      {:ok, project, where, look}
    end
  end

  @doc """
  Takes a worktree slot of the project the folder `cwd` of the VM is in,
  for the task `task` (`MWTClient.Sandbox.Slots.take/5`): `:new` starts the
  branch `task` from the base named in `opts` (`:from`, `TaskBase`), as
  the clone last fetched it, `origin/<base>` (`mwt worktree new` fetches
  first). A new task with no base named is
  refused, listing your branches: the agent asks you which unless you
  said. `:resume` puts the existing branch `task` back, with the base it
  started from. Only in the slot `cwd` is in, when it is free: from
  anywhere else nothing is taken, and the refusal lists the free slots,
  each marked when a Zed window has it open. `opts` also takes
  `:thread`, the asking agent's thread id, recorded as the task's holder.
  """
  @spec take_slot(String.t(), String.t() | nil, :new | :resume, String.t(), keyword()) ::
          {:ok, Project.t(), Slots.slot(), :started | :resumed | :already | :adopted, String.t(),
           {:worktree, String.t()}}
          | {:error, error() | MWTClient.Sandbox.Handoff.refusal()}
  def take_slot(username, cwd, how, task, opts \\ []) do
    task = task |> to_string() |> String.trim()
    from = Keyword.get(opts, :from) || Keyword.get(opts, :onto)

    with {:ok, project, where, guest} <- locate(username, cwd),
         {:ok, base} <- slot_base(project, guest, how, from),
         handoffs = handoffs(username),
         {:ok, slot, outcome} <-
           project
           |> Slots.take(guest, how, task,
             base: base,
             here: here(where, project, guest),
             handoffs: handoffs,
             restore: if(how == :resume, do: restore(handoffs, project, task)),
             thread: Keyword.get(opts, :thread)
           )
           |> with_zed(guest)
           |> with_branches(project) do
      used(username, project.name)
      {:ok, project, slot, outcome, base.branch || base.ref, where}
    end
  end

  defp with_branches({:error, :base_needed}, project),
    do: {:error, {:base_needed, project.mirrored_branch, Project.branches(project)}}

  defp with_branches(result, _project), do: result

  # A new task names its base; without one, `Slots.take/5` says so once it
  # knows the slot is free, and the refusal lists your branches.
  defp slot_base(_project, _guest, :new, from) when from in [nil, ""], do: {:ok, nil}
  defp slot_base(project, guest, :new, from), do: TaskBase.resolve(project, guest, from)
  defp slot_base(project, guest, :resume, _from), do: TaskBase.resolve(project, guest)

  # The free slots a refusal lists, with which a Zed window has open.
  defp with_zed({:error, {:not_in_a_slot, slots}}, guest),
    do: {:error, {:not_in_a_slot, Slots.mark_zed(slots, Zed.opened(guest))}}

  defp with_zed({:error, {:slot_taken, slot, slots}}, guest),
    do: {:error, {:slot_taken, slot, Slots.mark_zed(slots, Zed.opened(guest))}}

  defp with_zed(result, _guest), do: result

  # The commit a deleted task branch is made again at when resumed: its
  # latest handoff's, such as one sent back after you accepted it.
  defp restore(handoffs, project, task) do
    handoffs
    |> Enum.filter(&(&1.project == project.name and &1.source.branch == task))
    |> Enum.max_by(& &1.id, fn -> nil end)
    |> case do
      nil -> nil
      handoff -> handoff.head
    end
  end

  @doc """
  Frees the worktree slot the folder `cwd` of the VM is in, for its own
  thread (`MWTClient.Sandbox.Slots.free/4`): `which`, when given (a name
  or number), must be that slot, and `thread`, the asking agent's id, the
  one holding it when one is recorded. Returns the slot as it was.
  """
  @spec free_slot(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, Project.t(), Slots.slot()} | {:error, error()}
  def free_slot(username, cwd, which, thread \\ nil) do
    with {:ok, project, where, guest} <- locate(username, cwd),
         {:ok, slot} <-
           Slots.free(project, guest, which,
             here: here(where, project, guest),
             handoffs: handoffs(username),
             thread: thread
           ) do
      {:ok, project, slot}
    end
  end

  @doc """
  Frees the worktree slot `slot` (`slot-2`) of the project, from MWT's
  Projects page: off its branch, which stays with its commits, so the next
  thread there can start a task. Refused with uncommitted work; the VM
  must run.
  """
  @spec release_slot(String.t(), String.t(), String.t()) ::
          {:ok, Slots.slot()} | {:error, error()}
  def release_slot(username, name, slot) do
    with {:ok, _project, %{vm: vm}} <- find(username, name),
         {:ok, guest} <- guest(username, vm) do
      locked(username, name, fn ->
        with {:ok, project, %{handoffs: handoffs}} <- find(username, name) do
          Slots.free(project, guest, slot, handoffs: handoffs)
        end
      end)
    end
  end

  defp here({:worktree, top}, _project, _guest), do: top

  defp blank(""), do: nil
  defp blank(value), do: value
  defp handoffs(username), do: Server.call(username, :projects).handoffs

  ## Shared

  defp find(username, name) do
    %{projects: projects} = context = Server.call(username, :projects)

    case Enum.find(projects, &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> {:ok, project, context}
    end
  end

  @doc "The VM to reach into, or `{:error, :vm_not_running}`."
  @spec guest(String.t(), map()) :: {:ok, Guest.t()} | {:error, :vm_not_running}
  def guest(username, vm) do
    case stand_in(username) do
      nil when vm.status == :running -> {:ok, Guest.vm(username, vm.name)}
      nil -> {:error, :vm_not_running}
      guest -> {:ok, guest}
    end
  end

  defp stand_in(username) do
    case Application.get_env(:mwt_client, __MODULE__, [])[:guest] do
      nil -> nil
      guest -> guest.(username)
    end
  end

  @doc "The branch your repository has checked out, or nil."
  @spec checked_out(Project.t()) :: String.t() | nil
  def checked_out(%Project{path: path}), do: HostGit.branch(path)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:not_found), do: "That project is gone."

  def explain(:not_shared),
    do:
      "That repository isn't in a shared folder. Share the folder it is in, read-only, to work on it in the VM."

  def explain(:not_in_a_project),
    do:
      "This folder isn't in a registered project clone. The user opens a repository from MWT's Projects page; it appears at /work/NAME."

  def explain(reason)
      when is_tuple(reason) and
             elem(reason, 0) in [
               :not_in_a_slot,
               :slot_taken,
               :not_your_slot,
               :no_such_slot,
               :slot_busy,
               :not_a_slot,
               :branch_exists,
               :no_branch,
               :checked_out,
               :is_a_target,
               :bad_task,
               :held_by_another,
               :yours_already,
               :vague_task
             ],
      do: Slots.explain(reason)

  def explain(:the_clone), do: Slots.explain(:the_clone)

  def explain(reason)
      when reason in [:no_zed, :no_ssh_entry] or
             (is_tuple(reason) and elem(reason, 0) == :other_ssh_entry),
      do: Zed.explain(reason)

  def explain({:no_base, _ref} = reason),
    do: MWTClient.Sandbox.Handoff.explain(reason)

  def explain({:base_needed, _checkout, branches}) do
    shown = Enum.take(branches, 30)
    listed = Enum.join(shown, ", ")

    more = if length(branches) > length(shown), do: ", …", else: ""

    "Nothing was started: name the branch this task starts from, mwt worktree new TASK --from BRANCH. " <>
      "Unless the user named one, ask them which branch to base the work on. " <>
      "Their branches: #{listed}#{more}. A task in the VM is refs/heads/TASK; a commit ID pins a snapshot."
  end

  def explain(reason) when is_binary(reason), do: reason
  def explain(reason), do: Project.explain(reason)
end
