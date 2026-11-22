defmodule MWTClient.Sandbox.Slots do
  @moduledoc """
  A project's worktree slots: the checkouts of its clone in the VM that
  agents take one task at a time. `slot-0` is the clone itself,
  `/work/<name>`; the others are worktrees of it,
  `/work/<name>.wt/slot-N`, one for each number in `Project.slots`, added
  and removed on the Projects page. They share the clone's branches and
  its `origin/*`, so a fetch in one is seen in all.

  A slot keeps its folder between tasks, so what git ignores (`deps`,
  `_build`, `node_modules`, `target`) stays warm, and the line that opens
  it in Zed stays the same. Each task gets a branch of its own, since
  handoffs go by branch.

  The numbered slots are made when the project's clone is opened, and
  when added (`ensure/2`): on no branch, at `origin/<default branch>`, so
  each is there to open in Zed before any task. One whose folder went is
  made again then, or when taken.

  Git keeps every slot's state; MWT keeps none of its own:

    * **absent** (not made yet, or its folder is gone): free, made when
      taken or when the project is opened again;
    * **clean, and on no branch or on a branch no task started** (one
      `mwt worktree new` didn't make, such as the clone's own `master`):
      free;
    * **on a task branch**: busy, until that branch's latest handoff is
      landed or closed with nothing done in the slot since (no change, no
      newer commit). Then it is free, without MWT touching it: the next
      `mwt worktree new` takes it. The VM may be stopped when you land it,
      and the thread may still be open there;
    * **with uncommitted work**: busy, whatever its branch. Nothing here
      ever discards work: taking or freeing such a slot is refused.

  A thread takes its slot as its first step, even for a question or a
  review that may change no code (its instructions, `priv/sandbox/agents.md`
  and `mwt project`), on a branch named for what the user asked (`take/5`
  refuses names that say nothing, as `task` or `wip`): a thread that only
  reads leaves its slot free for another. The task branch is the hold, and
  the thread that took it is recorded with it, in git config
  (`branch.NAME.mwt-thread`, the agent's own thread id, which `mwt` sends:
  Claude Code's session id or Codex's thread id), beside the base it
  started from (`branch.NAME.mwt-base`), which is what makes it a task.
  So MWT tells the thread holding a slot from another opened in it, which
  is told it only reads there, and can't take, free or hand off that task
  (`holder/2`). A hold ends only when its handoff lands or is closed, or
  when the slot is freed; `mwt worktree resume` in the slot moves it to
  another thread, when you ask that thread to carry on the task. A slot
  held by a thread that is gone is freed on the Projects page, which marks
  the held slots no Zed window has open.

  Taking a slot starts a new branch from the task's base, `origin/<base>`
  as the clone last fetched it (`mwt worktree new` fetches first), or
  checks out an existing branch, such as one whose handoff was sent back
  after its slot went to another task (`:resume`). A thread takes only the
  slot it is in, never another: the folder a thread was opened in is where
  it works, and another slot may be another thread's, even a free one. A
  busy slot is never switched under the thread working in it.

  A slot is freed by its own thread (`mwt worktree free`) or by you on
  the Projects page (`free/4`), never by another thread.

  A numbered slot is removed only when it is free and clean (`remove/4`):
  its folder goes, with what git ignores there; its branch stays. The
  others keep their numbers, and the next slot added takes the lowest
  number missing. Folders never move, so nothing open in Zed breaks.
  `slot-0`, the clone, is never removed.

  The branches are the VM's: MWT never deletes one. A landed task's branch
  stays until someone deletes it, in the VM, with git.

  Numbered slots are locked (`git worktree lock`): `git worktree remove`
  and `git worktree prune` leave them alone unless forced twice. Zed's
  worktree picker and thread archive remove worktrees with at most one
  `--force`, which is how earlier per-task worktrees vanished.

  Other worktrees of the clone (made with `git worktree add`, or by Zed)
  are listed apart: no task starts there, and nothing is handed off from
  one.
  """

  alias MWTClient.Sandbox.{Handoff, Project, Shown, TaskBase, Zed}

  @type state :: :absent | :missing | :foreign | :clean | :dirty

  @type slot :: %{
          name: String.t(),
          path: Path.t(),
          state: state(),
          branch: String.t() | nil,
          head: String.t() | nil,
          handoff: Handoff.t() | nil,
          thread: String.t() | nil,
          base: String.t() | nil,
          free?: boolean(),
          in_zed?: boolean() | nil
        }

  @type worktree :: %{
          path: Path.t(),
          branch: String.t() | nil,
          head: String.t() | nil,
          locked?: boolean(),
          missing?: boolean(),
          handoff: Handoff.t() | nil
        }

  @typedoc """
  The latest handoff from a branch of the project, or nil: how a look
  finds the handoff of each branch it sees, kept apart from it
  (`MWTClient.Sandbox.HandoffRecords.latest/3`).
  """
  @type latest :: (String.t() -> Handoff.t() | nil)

  @type look :: %{
          mirror: Path.t(),
          slots: [slot()],
          others: [worktree()],
          worktrees: [worktree()],
          branch: String.t() | nil
        }

  @type error ::
          {:not_in_a_slot, [slot()]}
          | {:slot_taken, slot(), [slot()]}
          | {:held_by_another, slot(), [slot()]}
          | {:yours_already, slot()}
          | {:vague_task, String.t()}
          | {:not_your_slot, slot()}
          | {:no_such_slot, String.t(), [String.t()]}
          | {:slot_busy, slot()}
          | {:not_a_slot, String.t()}
          | {:branch_exists, String.t()}
          | {:no_branch, String.t()}
          | {:checked_out, String.t(), Path.t()}
          | {:is_a_target, String.t()}
          | {:bad_task, String.t()}
          | :base_needed
          | :the_clone
          | String.t()

  @lock "MWT worktree slot: MWT keeps it. Free it with: mwt worktree free"

  # The project's worktrees, `git worktree list --porcelain`; then, after a
  # line `--states`, each worktree's folder and the slots' as `missing PATH`, `dirty PATH` or `clean PATH`; after `--branch`,
  # the commit of the branch $2 when one is named and it exists; after
  # `--threads`, the thread holding each task branch and the base it
  # started from, as git config has them (`branch.NAME.mwt-thread ID`,
  # `branch.NAME.mwt-base REF`).
  @look """
  m=$1 b=$2
  shift 2
  list=$(git -C "$m" worktree list --porcelain) || exit 1
  printf '%s\\n--states\\n' "$list"
  { printf '%s\\n' "$list" | sed -n 's/^worktree //p'; for p in "$@"; do printf '%s\\n' "$p"; done; } |
    sort -u | while IFS= read -r p; do
      if [ ! -d "$p" ]; then echo "missing $p"
      elif [ -n "$(git -C "$p" status --porcelain 2>/dev/null | head -n 1)" ]; then echo "dirty $p"
      else echo "clean $p"; fi
    done
  echo "--branch"
  if [ -n "$b" ]; then git -C "$m" rev-parse -q --verify "refs/heads/$b" || true; fi
  echo "--threads"
  git -C "$m" config --get-regexp '^branch[.].*[.]mwt-(thread|base)$' || true
  """

  # Puts the slot $2 on a new branch $4 from $5 ($3 = new), or on the
  # existing branch $4 ($3 = resume), made again at the commit $7 first
  # when it was deleted. A slot whose folder is gone loses its
  # record first; git's records of other worktrees whose folders are gone
  # are pruned, as git gc would, so their branches can be checked out.
  # Uncommitted work is checked again here: it is never switched away.
  # The thread $8 taking it is recorded as the branch's holder, or none.
  @take """
  set -e
  m=$1 p=$2 mode=$3 b=$4 start=$5 lock=$6 restore=$7 thread=$8
  git -C "$m" worktree prune
  if [ "$mode" = resume ] && [ -n "$restore" ] && ! git -C "$m" rev-parse -q --verify "refs/heads/$b" >/dev/null; then
    git -C "$m" branch "$b" "$restore"
  fi
  if [ -d "$p" ]; then
    if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
      echo "$p has uncommitted work." >&2
      exit 1
    fi
    if [ "$mode" = new ]; then git -C "$p" switch -q --no-track -c "$b" "$start"
    else git -C "$p" switch -q "$b"; fi
    git -C "$m" worktree lock --reason "$lock" "$p" 2>/dev/null || true
  else
    git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
    mkdir -p "$(dirname "$p")"
    if [ "$mode" = new ]; then git -C "$m" worktree add -q --no-track -b "$b" "$p" "$start"
    else git -C "$m" worktree add -q "$p" "$b"; fi
    git -C "$m" worktree lock --reason "$lock" "$p"
  fi
  if [ "$mode" = new ]; then git -C "$m" config "branch.$b.mwt-base" "$start"; fi
  if [ -n "$thread" ]; then git -C "$m" config "branch.$b.mwt-thread" "$thread"
  else git -C "$m" config --unset "branch.$b.mwt-thread" 2>/dev/null || true; fi
  """

  # Records the thread $3 as holding the branch $2 of the clone $1.
  @hold ~S"""
  git -C "$1" config "branch.$2.mwt-thread" "$3"
  """

  # Makes each slot $4… whose folder isn't there, on no branch at $2, and
  # locks it with the reason $3. A folder that is there is left alone,
  # whatever it holds. A slot whose folder went loses its record first, as
  # when it is taken.
  @make """
  set -e
  m=$1 start=$2 lock=$3
  shift 3
  for p in "$@"; do
    [ -e "$p" ] && continue
    git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
    mkdir -p "$(dirname "$p")"
    git -C "$m" worktree add -q --detach "$p" "$start"
    git -C "$m" worktree lock --reason "$lock" "$p"
  done
  """

  # Removes the slot $2 of the clone $1: its folder, with what git
  # ignores there, and git's record of it. Its branch stays. Uncommitted
  # work is checked again here: it is never removed.
  @remove """
  set -e
  m=$1 p=$2
  if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then
    if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
      echo "$p has uncommitted work." >&2
      exit 1
    fi
  fi
  git -C "$m" worktree unlock "$p" 2>/dev/null || true
  git -C "$m" worktree remove -f -f "$p" 2>/dev/null || true
  rm -rf "$p"
  git -C "$m" worktree prune
  """

  # Takes the slot $1 off its branch, at the same commit, unless it has
  # uncommitted work.
  @free """
  set -e
  p=$1
  if [ -n "$(git -C "$p" status --porcelain | head -n 1)" ]; then
    echo "$p has uncommitted work." >&2
    exit 1
  fi
  git -C "$p" switch -q --detach
  """

  @doc "The folder of the project's slot `name` (`slot-0`, the clone; `slot-1`, …) in the VM."
  @spec path(Project.t(), %{root: Path.t()}, String.t()) :: Path.t()
  def path(project, guest, "slot-0"), do: Project.mirror_path(project, guest)
  def path(project, guest, name), do: Path.join(Project.worktrees_path(project, guest), name)

  @doc "The names of the project's slots, in order: `slot-0`, the clone, first."
  @spec names(Project.t()) :: [String.t()]
  def names(%Project{slots: numbers}), do: ["slot-0" | Enum.map(numbers, &"slot-#{&1}")]

  @doc "A slot's number from its name (`slot-2`, `2`), or nil."
  @spec number(term()) :: pos_integer() | nil
  def number(name) do
    case Regex.run(~r/\Aslot-(\d)\z/, slot_name(name)) do
      [_, digit] -> String.to_integer(digit)
      nil -> nil
    end
  end

  @doc """
  Makes the project's numbered slots that aren't there, in the VM: on no
  branch, at `origin/<default branch>`, so they are free and can be opened
  in Zed before any task. Run once the clone is there, which has that
  branch.
  """
  @spec ensure(Project.t(), map()) :: :ok | {:error, String.t()}
  def ensure(project, guest) do
    clone = Project.mirror_path(project, guest)
    start = "refs/remotes/origin/" <> project.mirrored_branch
    paths = for name <- names(project), name != "slot-0", do: path(project, guest, name)

    case guest.exec.(["sh", "-c", @make, "mwt-slots", clone, start, @lock | paths]) do
      {:ok, _} -> :ok
      {:error, text} -> {:error, "MWT couldn't make the worktree slots: " <> Shown.text(text)}
    end
  end

  @doc """
  The project's slots and other worktrees as the VM has them now, each
  with its branch's latest handoff (asked of `latest`), and each slot
  with whether it is free. With `branch`, also whether that
  branch exists (`:branch`, its commit, or nil).
  """
  @spec look(Project.t(), map(), latest(), String.t() | nil) ::
          {:ok, look()} | {:error, String.t()}
  def look(project, guest, latest, branch \\ nil) when is_function(latest, 1) do
    mirror = Project.mirror_path(project, guest)
    paths = Enum.map(names(project), &path(project, guest, &1))

    case guest.exec.(["sh", "-c", @look, "mwt-slots", mirror, branch || "" | paths]) do
      {:ok, output} ->
        {:ok, read(output, project, guest, latest)}

      {:error, text} ->
        {:error, "MWT couldn't read the project's worktrees: " <> Shown.text(text)}
    end
  end

  defp read(output, project, guest, latest) do
    sections = sections(output)
    mirror = Project.mirror_path(project, guest)

    states =
      for line <- sections.states,
          [word, path] <- [String.split(line, " ", parts: 2)],
          state = Map.get(%{"missing" => :missing, "dirty" => :dirty, "clean" => :clean}, word),
          state != nil,
          into: %{},
          do: {path, state}

    worktrees =
      sections.list
      |> Enum.join("\n")
      |> String.split("\n\n", trim: true)
      |> Enum.map(&worktree(&1, states))
      |> Enum.reject(&is_nil(&1.path))
      |> Enum.map(&Map.put(&1, :handoff, &1.branch && latest.(&1.branch)))

    registered = Map.new(worktrees, &{&1.path, &1})

    threads =
      for line <- sections.threads,
          [_, branch, id] <- [Regex.run(~r/\Abranch\.(.+)\.mwt-thread (\S+)\z/, line)],
          into: %{},
          do: {Shown.text(branch), id}

    bases =
      for line <- sections.threads,
          [_, branch, ref] <- [Regex.run(~r/\Abranch\.(.+)\.mwt-base (\S+)\z/, line)],
          into: %{},
          do: {Shown.text(branch), Shown.text(TaskBase.ref_label(ref))}

    slots =
      for name <- names(project) do
        path = path(project, guest, name)
        state = Map.get(states, path, :missing)
        slot(name, path, registered[path], state, {threads, bases})
      end

    slot_paths = MapSet.new(slots, & &1.path)

    branch =
      case sections.branch |> Enum.join() |> String.trim() do
        "" -> nil
        sha -> sha
      end

    %{
      mirror: mirror,
      slots: slots,
      others: Enum.reject(worktrees, &MapSet.member?(slot_paths, &1.path)),
      worktrees: worktrees,
      branch: branch
    }
  end

  # The look script's output by section, each a list of its lines.
  defp sections(output) do
    {_last, lines} =
      output
      |> String.split("\n")
      |> Enum.reduce({:list, %{list: [], states: [], branch: [], threads: []}}, fn
        "--states", {_, acc} -> {:states, acc}
        "--branch", {_, acc} -> {:branch, acc}
        "--threads", {_, acc} -> {:threads, acc}
        line, {section, acc} -> {section, Map.update!(acc, section, &[line | &1])}
      end)

    Map.new(lines, fn {section, lines} -> {section, lines |> Enum.reverse()} end)
    |> Map.update!(:states, &Enum.reject(&1, fn line -> line == "" end))
    |> Map.update!(:threads, &Enum.reject(&1, fn line -> line == "" end))
  end

  defp worktree(block, states) do
    fields = String.split(block, "\n", trim: true)

    Enum.reduce(
      fields,
      %{path: nil, branch: nil, head: nil, locked?: false, missing?: false},
      fn
        "worktree " <> path, acc ->
          %{acc | path: Shown.text(path), missing?: Map.get(states, path) == :missing}

        "HEAD " <> sha, acc ->
          %{acc | head: sha}

        "branch refs/heads/" <> branch, acc ->
          %{acc | branch: Shown.text(branch)}

        "locked" <> _, acc ->
          %{acc | locked?: true}

        _other, acc ->
          acc
      end
    )
  end

  defp slot(name, path, worktree, state, {threads, bases}) do
    state =
      case {worktree, state} do
        {nil, :missing} -> :absent
        {nil, _there} -> :foreign
        {_worktree, state} -> state
      end

    branch = worktree && worktree.branch
    handoff = worktree && worktree.handoff

    slot = %{
      name: name,
      path: path,
      state: state,
      branch: branch,
      head: worktree && worktree.head,
      handoff: handoff,
      thread: branch && threads[branch],
      base: branch && bases[branch],
      task?: branch != nil and (Map.has_key?(bases, branch) or Map.has_key?(threads, branch))
    }

    slot |> Map.put(:free?, free?(slot)) |> Map.put(:in_zed?, nil)
  end

  @doc """
  `slots` with `in_zed?` set from `opened`, what Zed has open in the VM
  (`MWTClient.Sandbox.Zed.opened/1`): whether a Zed window connected now
  has the slot's folder open, so a thread may be working there. Left nil
  when that isn't known.
  """
  @spec mark_zed([slot()], map() | :unknown) :: [slot()]
  def mark_zed(slots, %{folders: folders}),
    do: Enum.map(slots, &%{&1 | in_zed?: &1.path in folders})

  def mark_zed(slots, :unknown), do: slots

  @doc """
  Whether a slot can take a task: absent, its folder gone, or clean and on
  no branch, on a branch no task started, or on a task branch whose latest
  handoff was landed or closed at the commit it is on.
  """
  @spec free?(map()) :: boolean()
  def free?(%{state: state}) when state in [:absent, :missing], do: true
  def free?(%{state: :clean, branch: nil}), do: true
  def free?(%{state: :clean, task?: false}), do: true

  def free?(%{state: :clean, head: head, handoff: %Handoff{status: status, head: head}})
      when status in [:accepted, :closed],
      do: true

  def free?(_slot), do: false

  @doc """
  The thread recorded as holding `branch` of the repository whose git
  folder is `folder`, in the VM (`take/5` records it), or nil.
  """
  @spec thread_of(map(), String.t(), String.t() | nil) :: String.t() | nil
  def thread_of(_guest, _folder, branch) when branch in [nil, ""], do: nil

  def thread_of(guest, folder, branch) do
    case guest.exec.([
           "git",
           "--git-dir",
           folder,
           "config",
           "--get",
           "branch.#{branch}.mwt-thread"
         ]) do
      {:ok, id} -> blank_to_nil(String.trim(id))
      {:error, _none} -> nil
    end
  end

  @doc """
  Whether `branch` of the repository whose git folder is `folder`, in the
  VM, is a task's: `take/5` recorded the base it started from.
  """
  @spec task?(map(), String.t(), String.t() | nil) :: boolean()
  def task?(_guest, _folder, branch) when branch in [nil, ""], do: false

  def task?(guest, folder, branch) do
    match?(
      {:ok, _},
      guest.exec.(["git", "--git-dir", folder, "config", "--get", "branch.#{branch}.mwt-base"])
    )
  end

  @doc """
  Who holds `slot`, as the thread `thread` (the asking agent's id, or nil)
  sees it: `:yours`, `:another` thread's, or `:unknown` (none recorded,
  as for a branch taken before MWT recorded threads, or none asking).
  `:none` when it is free.
  """
  @spec holder(slot(), String.t() | nil) :: :yours | :another | :unknown | :none
  def holder(%{free?: true}, _thread), do: :none
  def holder(%{branch: nil}, _thread), do: :none
  def holder(%{thread: nil}, _thread), do: :unknown
  def holder(_slot, thread) when thread in [nil, ""], do: :unknown
  def holder(%{thread: thread}, thread), do: :yours
  def holder(_slot, _thread), do: :another

  @doc "The slot whose folder `top` is, or nil."
  @spec slot_at(look(), Path.t() | nil) :: slot() | nil
  def slot_at(%{slots: slots}, top), do: Enum.find(slots, &(&1.path == top))

  @doc """
  Takes a slot for a task, in the VM.

  `how` is `:new` (a new branch `task` from the resolved `:base`) or `:resume`
  (the existing branch `task`, as it is). `opts`:

    * `:base`: a branch or commit resolved by `TaskBase`, which a new task
      needs: without it, once the slot is known to be free, nothing starts
      (`:base_needed`);
    * `:here`: the folder the agent is in, the only slot it may take;
    * `:latest`: the latest handoff of a branch (`t:latest/0`);
    * `:restore`: for `:resume`, the commit to make the branch again at
      when it was deleted: its latest handoff's;
    * `:thread`: the asking agent's thread id, recorded as the branch's
      holder (nil when the agent names none).

  Returns the slot taken, and `:started`, `:resumed`, or `:already` when
  the branch to resume is in a slot already (nothing changes then), or
  `:adopted` when it is in the thread's own slot, held by another thread:
  this one holds it from then on, as when you ask a new thread to carry
  on a task.
  """
  @spec take(Project.t(), map(), :new | :resume, String.t(), keyword()) ::
          {:ok, slot(), :started | :resumed | :already | :adopted} | {:error, error()}
  def take(project, guest, how, task, opts) do
    thread = blank_to_nil(Keyword.get(opts, :thread))

    with true <- ref?(task) or {:error, {:bad_task, Shown.text(task)}},
         true <- how == :resume or not vague?(task) or {:error, {:vague_task, task}},
         {:ok, look} <- look(project, guest, Keyword.fetch!(opts, :latest), task),
         {:ok, slot, outcome} <- choose(look, how, task, opts),
         true <- how == :resume or Keyword.get(opts, :base) != nil or {:error, :base_needed} do
      mirror = Project.mirror_path(project, guest)
      here? = slot.path == Keyword.get(opts, :here)

      case outcome do
        :already when here? and thread != nil and slot.thread != thread ->
          # In its own slot, a thread carries on a task another one held,
          # or one taken before MWT recorded threads.
          case guest.exec.(["sh", "-c", @hold, "mwt-slot", mirror, task, thread]) do
            {:ok, _} ->
              {:ok, %{slot | thread: thread}, if(slot.thread, do: :adopted, else: :already)}

            {:error, text} ->
              {:error, Shown.text(text)}
          end

        :already ->
          {:ok, slot, :already}

        outcome ->
          start =
            case Keyword.get(opts, :base) do
              %{ref: ref} -> ref
              nil -> "refs/remotes/origin/" <> project.mirrored_branch
            end

          mode = if how == :new, do: "new", else: "resume"

          case guest.exec.([
                 "sh",
                 "-c",
                 @take,
                 "mwt-slot",
                 mirror,
                 slot.path,
                 mode,
                 task,
                 start,
                 @lock,
                 Keyword.get(opts, :restore) || "",
                 thread || ""
               ]) do
            {:ok, _} ->
              {:ok, %{slot | state: :clean, branch: task, free?: false, thread: thread}, outcome}

            {:error, text} ->
              {:error, Shown.text(text)}
          end
      end
    end
  end

  defp choose(look, :new, task, opts) do
    if look.branch,
      do: {:error, {:branch_exists, task}},
      else: with({:ok, slot} <- pick(look, opts), do: {:ok, slot, :started})
  end

  defp choose(look, :resume, task, opts) do
    held = Enum.find(look.worktrees, &(&1.branch == task))
    slot = held && slot_at(look, held.path)

    cond do
      is_nil(look.branch) and is_nil(Keyword.get(opts, :restore)) ->
        {:error, {:no_branch, task}}

      slot && slot.state == :missing ->
        {:ok, slot, :resumed}

      slot ->
        {:ok, slot, :already}

      held && not held.missing? ->
        {:error, {:checked_out, task, held.path}}

      true ->
        with {:ok, slot} <- pick(look, opts), do: {:ok, slot, :resumed}
    end
  end

  # Only the slot the thread is in (see the module's notes).
  defp pick(look, opts) do
    case slot_at(look, Keyword.get(opts, :here)) do
      %{free?: true} = slot ->
        {:ok, slot}

      nil ->
        {:error, {:not_in_a_slot, look.slots}}

      slot ->
        case holder(slot, blank_to_nil(Keyword.get(opts, :thread))) do
          :yours -> {:error, {:yours_already, slot}}
          :another -> {:error, {:held_by_another, slot, look.slots}}
          _unknown -> {:error, {:slot_taken, slot, look.slots}}
        end
    end
  end

  defp blank_to_nil(text) when text in [nil, ""], do: nil
  defp blank_to_nil(text), do: text

  # Names that say nothing of the work: a task is named for what the user
  # asked, so the branch, the handoff and the slot say what it is.
  @vague ~w(task tasks work wip tmp temp test tests new branch thread question questions
            explore exploration investigate investigation research misc scratch todo untitled
            draft agent claude codex slot)

  defp vague?(task) do
    String.replace(String.downcase(task), ~r/[-_]?\d+\z/, "") in @vague
  end

  @doc """
  Removes the slot `name` from the VM: its folder, with what git ignores
  there (its build), and git's record of it. Only a free numbered slot
  with no uncommitted work, or one whose folder is gone already; its
  branch stays. `slot-0`, the clone, is never removed. The project's
  record is the caller's to change.
  """
  @spec remove(Project.t(), map(), String.t(), latest()) :: :ok | {:error, error()}
  def remove(_project, _guest, "slot-0", _latest), do: {:error, :the_clone}

  def remove(project, guest, name, latest) do
    with {:ok, look} <- look(project, guest, latest) do
      case Enum.find(look.slots, &(&1.name == name)) do
        nil ->
          {:error, {:no_such_slot, Shown.text(name), names(project)}}

        %{state: state} = slot when state in [:dirty, :foreign] ->
          {:error, {:slot_busy, slot}}

        %{free?: false} = slot ->
          {:error, {:slot_busy, slot}}

        slot ->
          clone = Project.mirror_path(project, guest)

          case guest.exec.(["sh", "-c", @remove, "mwt-slot", clone, slot.path]) do
            {:ok, _} -> :ok
            {:error, text} -> {:error, Shown.text(text)}
          end
      end
    end
  end

  @doc "A slot's name from what an agent typed: `2`, `slot-2` or its folder."
  @spec slot_name(term()) :: String.t()
  def slot_name(n) when is_integer(n), do: "slot-#{n}"

  def slot_name(text) when is_binary(text) do
    text = text |> String.trim() |> Path.basename()
    if text =~ ~r/\A\d+\z/, do: "slot-" <> text, else: text
  end

  def slot_name(_other), do: ""

  @doc """
  Frees a slot: takes it off its branch, which stays with all its commits,
  so the next task can take it. Refused with uncommitted work. `which` is a
  slot's name or number, or nil for the slot `here` is. An agent's ask
  passes `:here`, the folder it is in, and frees only
  that slot, and only when no other thread holds it (`:thread`, its own
  id); without `:here` (you, on the Projects page), any.
  """
  @spec free(Project.t(), map(), String.t() | nil, keyword()) ::
          {:ok, slot()} | {:error, error()}
  def free(project, guest, which, opts) do
    with {:ok, look} <- look(project, guest, Keyword.fetch!(opts, :latest)),
         {:ok, slot} <- named_or_here(look, which, Keyword.get(opts, :here)),
         :ok <- yours(slot, look.slots, opts) do
      case slot do
        %{state: state} when state in [:absent, :missing] ->
          {:ok, slot}

        %{state: :dirty} ->
          {:error, {:slot_busy, slot}}

        %{state: :foreign} ->
          {:error, {:slot_busy, slot}}

        %{branch: nil} ->
          {:ok, slot}

        # On a branch no task started (the clone's own master): free as it
        # is, and left on it.
        %{task?: false} ->
          {:ok, slot}

        slot ->
          case guest.exec.(["sh", "-c", @free, "mwt-slot", slot.path]) do
            {:ok, _} -> {:ok, slot}
            {:error, text} -> {:error, Shown.text(text)}
          end
      end
    end
  end

  defp yours(slot, slots, opts) do
    case Keyword.fetch(opts, :here) do
      {:ok, here} when here != slot.path ->
        {:error, {:not_your_slot, slot}}

      {:ok, _here} ->
        if holder(slot, blank_to_nil(Keyword.get(opts, :thread))) == :another,
          do: {:error, {:held_by_another, slot, slots}},
          else: :ok

      :error ->
        :ok
    end
  end

  defp named_or_here(look, which, here) when which in [nil, ""] do
    case slot_at(look, here) do
      nil -> {:error, {:not_a_slot, Shown.text(here || "")}}
      slot -> {:ok, slot}
    end
  end

  defp named_or_here(look, which, _here) do
    name = slot_name(which)

    case Enum.find(look.slots, &(&1.name == name)) do
      nil -> {:error, {:no_such_slot, Shown.text(name), Enum.map(look.slots, & &1.name)}}
      slot -> {:ok, slot}
    end
  end

  # A branch name, and nothing git or a shell would read otherwise.
  defp ref?(task) do
    task =~ ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z" and
      not String.contains?(task, ["..", "//", "@{"]) and
      not String.ends_with?(task, ["/", ".", ".lock"])
  end

  @doc "What a slot holds, in words: `free`, `fix-login, handoff #4 open`, …"
  @spec words(slot()) :: String.t()
  def words(%{state: :absent}), do: "free, not made yet"

  def words(%{state: :missing, branch: nil}),
    do: "free, its folder is gone; made again when taken"

  def words(%{state: :missing, branch: branch}),
    do: "free, its folder is gone (the branch #{branch} stays); made again when taken"

  def words(%{state: :foreign}),
    do: "in the way: its folder is there but isn't a worktree of the project"

  def words(%{state: :dirty, branch: nil}), do: "on no branch, with uncommitted work"
  def words(%{state: :dirty} = slot), do: "#{task(slot)}, with uncommitted work"

  def words(%{branch: nil}), do: "free"
  def words(%{task?: false, branch: branch}), do: "free, on #{branch}"

  def words(%{handoff: handoff, free?: free?} = slot) do
    held =
      case handoff do
        nil -> "#{task(slot)}, no handoff yet"
        %Handoff{id: id, status: status} -> "#{task(slot)}, handoff ##{id} #{status_word(status)}"
      end

    if free?, do: "free (#{held})", else: held
  end

  # A task branch, with the base it started from when git config has it.
  defp task(%{branch: branch} = slot) do
    case Map.get(slot, :base) do
      nil -> branch
      base -> "#{branch}, based on #{base}"
    end
  end

  @doc "A handoff's status, in words."
  @spec status_word(Handoff.status()) :: String.t()
  def status_word(:open), do: "open"
  def status_word(:sent_back), do: "sent back"
  def status_word(:accepted), do: "landed"
  def status_word(:closed), do: "closed"
  def status_word(:withdrawn), do: "withdrawn"

  @doc "Why a slot couldn't be taken or freed, in words."
  @spec explain(error()) :: String.t()
  def explain({:not_in_a_slot, slots}),
    do:
      "A task starts only in the worktree slot its thread is in, and you are in none. " <>
        elsewhere(slots)

  def explain({:slot_taken, slot, slots}) do
    own =
      case slot do
        %{state: :dirty} ->
          "That work is someone's: ask the user whether it is done or dropped. They hand it off, commit or discard it; then free the slot (mwt worktree free) and start the task here again."

        %{state: :foreign} ->
          "Ask the user to move that folder away."

        _held ->
          "If #{slot.branch} is your thread's task, do the new work on it (mwt project says how). If it isn't, another thread holds this slot: tell the user, and go on here only read-only (no edits, no git changes, no builds or tests, no mwt worktree or mwt handoff)."
      end

    """
    #{slot.name}, where you are, isn't free: #{words(slot)}. A task starts only in the slot its thread is in. #{own}
    #{elsewhere(slots)}\
    """
  end

  def explain({:held_by_another, slot, slots}) do
    """
    Another thread holds #{slot.name}, for its task #{slot.branch} (#{held_words(slot)}). Tell the user.
    #{read_only_words(slot)}
    #{elsewhere(slots)}\
    """
  end

  def explain({:yours_already, slot}),
    do: "#{slot.name} is yours already, on your task #{slot.branch}. #{more_work_words(slot)}"

  def explain({:vague_task, task}),
    do:
      "\"#{task}\" says nothing of the work. Name the task for what the user asked, in a few words: fix-login-timeout, explain-handoff-sync, review-pr-34."

  def explain({:not_your_slot, slot}),
    do:
      "#{slot.name} isn't the slot you are in. Only its own thread frees a slot (mwt worktree free, in it), or the user on MWT's Projects page."

  def explain({:no_such_slot, name, []}),
    do:
      "There is no slot #{name}: the project has none. The user adds one on MWT's Projects page."

  def explain({:no_such_slot, name, names}),
    do: "There is no slot #{name}: the project has #{Enum.join(names, ", ")}."

  def explain({:slot_busy, %{state: :dirty} = slot}),
    do:
      "#{slot.name} has uncommitted work (#{slot.branch || "on no branch"}). Ask the user what becomes of it first: hand it off, or let them commit or discard it in #{slot.path}."

  def explain(:the_clone),
    do: "slot-0 is the project's clone itself: it can't be removed."

  def explain({:slot_busy, %{state: :foreign} = slot}),
    do: "#{slot.path} is there but isn't a worktree of the project. Move it away, then try again."

  def explain({:slot_busy, slot}),
    do: "#{slot.name} holds #{words(slot)}: free it first."

  def explain({:not_a_slot, _here}),
    do:
      "You are in no worktree slot. Only its own thread frees a slot (mwt worktree free, in it), or the user on MWT's Projects page."

  def explain({:branch_exists, task}),
    do:
      "There is a branch #{task} already. To continue it here: mwt worktree resume #{task}. For a new task, choose another name."

  def explain({:no_branch, task}),
    do:
      "There is no branch #{task}. Start a task on a new one with: mwt worktree new #{task} --from BRANCH"

  def explain({:checked_out, task, path}),
    do: "#{task} is checked out in #{path}: continue it there."

  def explain({:is_a_target, task}),
    do:
      "#{task} is the project's default branch. Start a task from it: mwt worktree new TASK --from #{task}"

  def explain({:bad_task, task}),
    do: "\"#{task}\" can't be a branch name. Use letters, digits, dots, dashes and slashes."

  def explain(text) when is_binary(text), do: text

  @doc """
  What a thread may do in a slot another thread holds: read, never write,
  so the holder's work and build stay as it left them.
  """
  @spec read_only_words(slot()) :: String.t()
  def read_only_words(slot),
    do:
      "You may go on in this thread read-only: read and search the code, git log, diff, show and status, answer questions, and work outside the project (/tmp). Change nothing in #{slot.path}: no edits, no git command that changes anything (commit, switch, checkout, reset, stash, merge), no builds or tests (they write the build the other thread uses), no mwt worktree or mwt handoff. Only if the user asks this thread to carry on #{slot.branch} instead: mwt worktree resume #{slot.branch}."

  @doc """
  What the thread holding a slot does when the user asks it for more:
  the work goes onto its task, and an open handoff is taken back first.
  """
  @spec more_work_words(slot()) :: String.t()
  def more_work_words(%{handoff: nil} = slot),
    do:
      "It has no handoff yet: do the new work on #{slot.branch} too, and it goes into its handoff. A new task starts here once that handoff has landed or is closed."

  def more_work_words(%{handoff: %Handoff{status: :open, id: id}} = slot),
    do:
      "Its handoff ##{id} is open, waiting for the user, as it was when you handed it off: more work doesn't change it. Do the new work on #{slot.branch}, uncommitted for review, and hand off again once the user asks: that updates handoff ##{id} with a new revision. A new task starts here once it has landed or is closed."

  def more_work_words(%{handoff: %Handoff{status: :withdrawn, id: id}} = slot),
    do:
      "You took its handoff ##{id} back: do the new work on #{slot.branch}, and hand off again once the user asks."

  def more_work_words(%{handoff: %Handoff{status: :sent_back, id: id}} = slot),
    do:
      "Its handoff ##{id} was sent back: do the new work on #{slot.branch}, and hand off again once the user asks."

  def more_work_words(%{handoff: %Handoff{id: id, status: status}} = slot),
    do:
      "Its handoff ##{id} #{status_word(status)}, and #{slot.name} has work done since. Ask the user whether that work goes into #{slot.branch}'s next handoff."

  defp held_words(%{handoff: nil}), do: "no handoff yet"

  defp held_words(%{handoff: %Handoff{id: id, status: status}}),
    do: "handoff ##{id} #{status_word(status)}"

  # Where a task can start instead: the free slots, each with the line that
  # opens it in Zed, for the user to start a thread there.
  defp elsewhere([]),
    do: "The project has no worktree slots: ask the user to add one on MWT's Projects page."

  defp elsewhere(slots) do
    case Enum.filter(slots, & &1.free?) do
      [] ->
        held = Enum.map_join(slots, "\n", &"  #{&1.name}: #{words(&1)}")

        """
        No slot is free:
        #{held}
        Ask the user to free one on MWT's Projects page, or to add one.\
        """

      free ->
        width = free |> Enum.map(&String.length(&1.name)) |> Enum.max()

        lines =
          Enum.map_join(free, "\n", fn slot ->
            zed = if slot.in_zed?, do: "  (open in Zed: a thread may be working there)", else: ""
            "  #{String.pad_trailing(slot.name, width)}  #{Zed.command(slot.path)}#{zed}"
          end)

        """
        Ask the user to start a thread in a free slot and give it the task there:
        #{lines}
        Don't work in another slot from here.\
        """
    end
  end
end
