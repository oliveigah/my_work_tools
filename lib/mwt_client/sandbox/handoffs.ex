defmodule MWTClient.Sandbox.Handoffs do
  @moduledoc """
  The handoffs of one identity, as the agent channel and the pages use
  them: opened by agents with `mwt handoff` once you reviewed their work
  in the VM and asked, then landed on your branch (`accept/3`) or closed
  by you. Landing syncs what you reviewed there; it isn't where you review
  it, nor where you ask for more: that is its thread, in Zed.

  The sandbox (`MWTClient.Sandbox.Server`) keeps the records. The git work
  (in the VM, the store, your repository) runs here, in the caller's
  process, so the sandbox never waits on it. Opening one goes into the VM,
  which must be running (`MWTClient.Sandbox.Projects.guest/2`).
  """

  alias MWTClient.Sandbox.{
    Accept,
    CatchUp,
    Handoff,
    HandoffRecords,
    HandoffStore,
    HostGit,
    MwtTools,
    Project,
    Projects,
    Secrets,
    Server,
    Slots,
    TaskBase
  }

  require Logger

  @type error ::
          :vm_not_running
          | :not_found
          | :not_open
          | :withdrawn
          | {:not_your_task, String.t()}
          | {:not_a_task, String.t()}
          | {:named_like_yours, String.t()}
          | {:a_task_already, String.t()}
          | {:not_withdrawable, Handoff.t() | nil, String.t()}
          | :not_accepted
          | :not_closed
          | {:revised, pos_integer()}
          | {:unscanned, String.t()}
          | Handoff.refusal()
          | Accept.problem()
          | String.t()

  ## What agents ask through the channel

  @doc """
  Opens a handoff from the branch the agent is on, in the folder `ask.cwd`
  in the VM, or makes a new revision of the one that branch has open.

  `ask` holds the agent's words: `cwd`, `title`, `body`, `agent`,
  `thread`, `thread_id`. The baseline is the task's chosen branch or commit. Agents
  are told to hand off only once you ask (`priv/sandbox/agents.md`); one
  that hands off too soon is closed and told so in its thread. Returns the
  handoff and whether it was `:opened` or `:updated`.
  """
  @spec open(String.t(), map()) :: {:ok, Handoff.t(), :opened | :updated} | {:error, error()}
  def open(username, ask) do
    exclusive(username, fn -> open_revision(username, ask) end)
  end

  # One change of an identity's handoffs at a time: a revision being
  # received (its fetch may take minutes), a landing, a catch-up, a close
  # or a withdrawal. Each reads a handoff, works on it, then
  # writes it; two at once would each write what it read, and the one
  # written last would undo the other. The cost: a click waits for a
  # revision being received. The lock goes with the process holding it.
  defp exclusive(username, fun), do: :global.trans({{__MODULE__, username}, self()}, fun)

  defp open_revision(username, ask) do
    %{waiting_handoffs: handoffs, vm: vm, dir: dir} = Server.call(username, :projects)
    words = Handoff.words(ask)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{project: project}} <- submission_project(username, Map.get(ask, :cwd)),
         {:ok, %{source: source, head: current}} <- Handoff.look(guest, Map.get(ask, :cwd)),
         :ok <- holding(guest, source, words.thread_id),
         :ok <- handing_off(username, project, source),
         {:ok, submitted} <- submitted_commit(ask, current),
         existing = open_from(handoffs, source),
         true <- words.title != "" or existing != nil or {:error, :no_title},
         {:ok, base} <- task_base(project, guest, source, ask, existing),
         store = HandoffStore.path(dir, project.path),
         :ok <- HandoffStore.ensure(store, project.path),
         id = if(existing, do: existing.id, else: Server.call(username, :next_handoff_id)),
         :ok <- keep_previous(store, existing),
         {:ok, head} <-
           HandoffStore.receive(
             store,
             guest,
             source.folder,
             submitted,
             id,
             Handoff.size_limit_mib()
           ) do
      handoff = build(existing, id, words, project, base, source, head)
      handoff = %{handoff | base_commit: comparison_base(base)}

      result =
        with {:ok, facts} <- Handoff.facts(store, handoff),
             :ok <- caught_up(handoff, facts),
             nil <- real_value(username, store, handoff, facts.merge_base) do
          handoff = %{handoff | base_commit: facts.merge_base, stats: Handoff.stats(facts)}

          with :ok <- HandoffStore.keep_revision(store, id, handoff.revision, head) do
            opened(username, project, existing, handoff)
          end
        else
          {:error, {:catch_up, _, _, _}} = refused ->
            refused

          {:error, _} ->
            {:error, :unrelated}

          {:unscanned, reason} ->
            {:error, {:unscanned, reason}}

          {grant, where} ->
            Server.call(username, {:found, {:value, grant}, "handoff ##{id}, #{where}", :handoff})
            {:error, {:real_value, grant, where}}
        end

      if match?({:error, _}, result), do: restore(store, id, existing)
      result
    end
  end

  # The grant Git: hand off decides it, as any use of MWT's own tools.
  defp handing_off(username, project, source) do
    MwtTools.authorize(username, %{
      grant: :git_handoff,
      tool: "mwt handoff",
      title: "#{source.branch} of #{project.name}",
      args: %{"project" => project.name, "branch" => source.branch}
    })
  end

  # Behind its base, it was never built or tested with what the user
  # committed since, even when it merges cleanly: refused, and the next
  # `mwt handoff` catches up (it fetches and rebases) before it sends.
  defp caught_up(_handoff, %{behind: 0, conflicts: []}), do: :ok

  defp caught_up(handoff, %{behind: behind, conflicts: files}),
    do: {:error, {:catch_up, Handoff.base_label(handoff), behind, files}}

  # Only the thread holding a task's branch hands it off or takes its
  # handoff back, and only from a task branch (`mwt worktree new` made it,
  # in a slot, or you made one yours a task, `make_task/2`): another
  # thread opened in the same slot only reads there. An ask with no thread
  # is yours, from a terminal, and goes through: as when an agent ran out
  # of quota and you finish its task by hand.
  defp holding(guest, source, thread_id) do
    holder = Slots.thread_of(guest, source.folder, source.branch)

    cond do
      holder != nil and thread_id not in [nil, ""] and holder != thread_id ->
        {:error, {:not_your_task, source.branch}}

      not task?(holder, guest, source) ->
        {:error, {:not_a_task, source.branch}}

      true ->
        :ok
    end
  end

  # A task's branch: a thread holds it (`holder`, as `Slots.thread_of/3`
  # read it), or its base is recorded.
  defp task?(holder, guest, source),
    do: holder != nil or Slots.task?(guest, source.folder, source.branch)

  defp submission_project(username, cwd) do
    with {:ok, %{project: project} = info} <- Projects.inspect(username, cwd) do
      %{shares: shares} = Server.call(username, :projects)

      cond do
        project.closed ->
          {:error, "This project is closed. Open it in MWT before submitting."}

        is_nil(Projects.share_of(project.path, shares)) ->
          {:error, "This project's host folder is no longer shared."}

        true ->
          {:ok, info}
      end
    end
  end

  defp submitted_commit(ask, current) do
    case Map.get(ask, :head) || current do
      head when is_binary(head) ->
        if head =~ ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/,
          do: {:ok, head},
          else: {:error, "The submitted commit is invalid."}

      _ ->
        {:error, "The submitted commit is invalid."}
    end
  end

  defp keep_previous(_store, nil), do: :ok

  defp keep_previous(store, handoff),
    do: HandoffStore.keep_revision(store, handoff.id, handoff.revision, handoff.head)

  defp restore(store, id, nil), do: HandoffStore.drop(store, id)
  defp restore(store, id, previous), do: HandoffStore.point(store, id, previous.head)

  # What a revision is measured from: a base commit as it is; a base branch
  # where it is now (nil), never where the last revision's was, since the
  # thread may have caught up with it since. Reusing the old one counted
  # the branch's own new commits as the handoff's, and called them
  # conflicts.
  defp comparison_base(%{branch: nil, commit: commit}), do: commit
  defp comparison_base(_base), do: nil

  # What a new revision sets on its handoff's record (`opened/4`); the
  # rest stays as the record has it, its timeline gaining the revision's
  # event.
  @revised [
    :title,
    :body,
    :agent,
    :thread,
    :thread_id,
    :onto,
    :mirrored_branch,
    :base_branch,
    :base_ref,
    :base_commit,
    :source,
    :head,
    :status,
    :updated_at,
    :revision,
    :stats
  ]

  defp opened(username, project, nil, handoff) do
    :ok =
      Server.call(
        username,
        {:put_handoff, handoff, "#{who(handoff)} handed off ##{handoff.id}: \"#{handoff.title}\""}
      )

    Projects.used(username, project.name)
    {:ok, handoff, :opened}
  end

  # A new revision changes what it says of the work, and adds its event,
  # on the record as it is now: what changed on it while the revision was
  # received (an event marked, its size worked out again) stays.
  defp opened(username, project, _existing, revised) do
    summary = "#{who(revised)} updated ##{revised.id}: \"#{revised.title}\""
    event = List.last(revised.timeline)

    result =
      update(username, revised.id, summary, fn record ->
        record
        |> struct(Map.take(revised, @revised))
        |> Map.update!(:timeline, &(&1 ++ [event]))
      end)

    handoff =
      case result do
        {:ok, handoff} ->
          handoff

        # Gone from the records meanwhile (past the kept ones): kept again whole.
        {:error, :not_found} ->
          :ok = Server.call(username, {:put_handoff, revised, summary})
          revised
      end

    Projects.used(username, project.name)
    {:ok, handoff, :updated}
  end

  # The grant whose real value the handoff brings, and where, or nil: in
  # its words, its commits or its files. Nothing in the VM should hold one.
  # What MWT couldn't look through is `{:unscanned, why}`, never nil: a
  # handoff it couldn't read whole isn't one it found nothing in.
  defp real_value(username, store, handoff, base) do
    secrets = Server.call(username, :secrets)
    words = [handoff.title, handoff.body] |> Enum.filter(&is_binary/1)

    case Enum.find_value(words, &Secrets.find(secrets, &1)) do
      {:value, grant} ->
        {grant, "its title or notes"}

      nil ->
        case HandoffStore.find(store, handoff.head, base, secrets) do
          nil -> nil
          {{:value, grant}, where} -> {grant, where}
          {:error, reason} -> {:unscanned, reason}
        end
    end
  end

  @doc "Preparation selects a comparison base and checks without changing the clone."
  @spec prepare(String.t(), map()) :: {:ok, map()} | {:error, error()}
  def prepare(username, ask) do
    %{waiting_handoffs: handoffs, vm: vm} = Server.call(username, :projects)
    words = Handoff.words(ask)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{project: project}} <- submission_project(username, Map.get(ask, :cwd)),
         {:ok, %{source: source, head: head}} <-
           Handoff.look(guest, Map.get(ask, :cwd), uncommitted: :allowed),
         :ok <- holding(guest, source, words.thread_id),
         existing = open_from(handoffs, source),
         title = if(words.title != "", do: words.title, else: existing && existing.title),
         true <- title not in [nil, ""] or {:error, :no_title},
         {:ok, base} <- task_base(project, guest, source, ask, existing),
         :ok <- TaskBase.remember(guest, source, base) do
      {:ok,
       %{
         onto: TaskBase.label(base),
         ref: base.ref,
         title: title,
         checks: project.checks,
         amend: amend(existing, head)
       }}
    end
  end

  # The commit a new revision folds its changes into: the last revision's,
  # while the branch is still at it (nothing committed on it since, by
  # the user or anyone). Its revision stays in the store as it was; a
  # commit made after it is never rewritten. Only a handoff waiting for
  # you gets a revision, so none has landed.
  defp amend(%Handoff{head: head}, head), do: head
  defp amend(_existing, _head), do: nil

  # A revision of a handoff taken back out after it landed goes on from
  # the branch it landed on, while that branch is there: its catch-up
  # brings what you added to it since.
  defp task_base(project, guest, source, ask, existing) do
    continuation =
      existing && existing.host_branch && Accept.tip(project.path, existing.host_branch) &&
        existing.host_branch

    override = Map.get(ask, :onto)
    override = if override in [nil, ""], do: continuation, else: override
    TaskBase.read(project, guest, source, override, existing)
  end

  ## What you are asked, at a terminal in the VM

  @doc """
  What `mwt handoff` asks you when you run it yourself, at a terminal in
  the VM, in the folder `ask.cwd`: from your own branch, or to finish a
  task an agent left (out of quota, say). An agent is never asked: it
  gives the title and notes, and hands off only from its task.

  For a task's branch: the handoff it has open, if any, whose title and
  notes are what you start from. For any other branch: the base it would
  have as a task (`make_task/2`), from the branch it came from
  (`TaskBase.came_from/3`), and what git said that was, or nil when that
  isn't known and the base is your default branch. Refused for a branch
  named like one of yours (`:named_like_yours`): see `make_task/2`.
  Nothing changes.
  """
  @spec about_branch(String.t(), map()) ::
          {:ok, %{task?: true, open: Handoff.t() | nil}}
          | {:ok, %{task?: false, base: map(), from: String.t() | nil}}
          | {:error, error()}
  def about_branch(username, ask) do
    %{waiting_handoffs: handoffs, vm: vm} = Server.call(username, :projects)
    cwd = Map.get(ask, :cwd)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{project: project}} <- submission_project(username, cwd),
         {:ok, %{source: source}} <- Handoff.look(guest, cwd, uncommitted: :allowed) do
      if task?(Slots.thread_of(guest, source.folder, source.branch), guest, source) do
        {:ok, %{task?: true, open: open_from(handoffs, source)}}
      else
        with :ok <- not_named_like_yours(project, source.branch),
             {:ok, base, from} <- offered_base(project, guest, source) do
          {:ok, %{task?: false, base: base, from: from}}
        end
      end
    end
  end

  @doc """
  Makes the branch you are on, in the folder `ask.cwd` in the VM, a task,
  so it hands off: its base recorded as `mwt worktree new` records one
  (`TaskBase.remember/3`), `ask.onto` or else the one `about_branch/2`
  offers. No thread holds it, so you hand it off from any terminal, and a
  thread opened in its slot only reads there, as in one another thread
  holds.

  Refused for a branch that is a task already, and for one named like a
  branch of yours (your `main`, in the VM): once its handoff lands, MWT
  deletes a task's branch.
  """
  @spec make_task(String.t(), map()) :: {:ok, String.t(), map()} | {:error, error()}
  def make_task(username, ask) do
    %{vm: vm} = Server.call(username, :projects)
    cwd = Map.get(ask, :cwd)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{project: project}} <- submission_project(username, cwd),
         {:ok, %{source: source}} <- Handoff.look(guest, cwd, uncommitted: :allowed),
         false <-
           task?(Slots.thread_of(guest, source.folder, source.branch), guest, source) &&
             {:error, {:a_task_already, source.branch}},
         :ok <- not_named_like_yours(project, source.branch),
         {:ok, base} <- chosen_base(project, guest, source, Map.get(ask, :onto)),
         :ok <- TaskBase.remember(guest, source, base) do
      {:ok, source.branch, base}
    end
  end

  defp chosen_base(project, guest, source, onto) when onto in [nil, ""] do
    with {:ok, base, _from} <- offered_base(project, guest, source), do: {:ok, base}
  end

  defp chosen_base(project, guest, source, onto), do: TaskBase.read(project, guest, source, onto)

  # The branch it came from, else your default branch.
  defp offered_base(project, guest, source) do
    case TaskBase.came_from(project, guest, source) do
      {:ok, base, from} ->
        {:ok, base, from}

      :unknown ->
        with {:ok, base} <- TaskBase.resolve(project, guest), do: {:ok, base, nil}
    end
  end

  # A task's branch is deleted once its handoff lands: one named like a
  # branch of yours would take the VM's copy of it (its `main`) along.
  defp not_named_like_yours(project, branch) do
    if HostGit.line(project.path, [
         "rev-parse",
         "--verify",
         "--quiet",
         "--end-of-options",
         "refs/heads/#{branch}^{commit}"
       ]),
       do: {:error, {:named_like_yours, branch}},
       else: :ok
  end

  @doc """
  Takes back the open handoff of the branch the agent is on, in the folder
  `ask.cwd` in the VM: as when you ask its thread for more work before
  landing it. Withdrawn, it can't be landed; the agent's next
  `mwt handoff` from that branch makes a new revision of it, open again.
  You can still close it. Only the thread holding the
  branch takes it back. `ask` holds `cwd`, `reason` (what you asked for
  now) and who asks.
  """
  @spec withdraw(String.t(), map()) :: {:ok, Handoff.t()} | {:error, error()}
  def withdraw(username, ask), do: exclusive(username, fn -> withdraw_open(username, ask) end)

  defp withdraw_open(username, ask) do
    %{vm: vm} = Server.call(username, :projects)
    words = Handoff.words(ask)

    with {:ok, guest} <- Projects.guest(username, vm),
         {:ok, %{project: project}} <- submission_project(username, Map.get(ask, :cwd)),
         {:ok, %{source: source}} <-
           Handoff.look(guest, Map.get(ask, :cwd), uncommitted: :allowed),
         :ok <- holding(guest, source, words.thread_id),
         %Handoff{status: :open, id: id} <-
           HandoffRecords.latest(username, project.name, source.branch) ||
             {:error, {:not_withdrawable, nil, source.branch}} do
      reason = ask |> Map.get(:reason) |> to_string() |> String.trim() |> String.slice(0, 500)

      update(username, id, "##{id} withdrawn", fn handoff ->
        %{
          handoff
          | status: :withdrawn,
            timeline:
              handoff.timeline ++
                [event(:withdrawn, "#{who(words)} took it back for more work", %{note: reason})]
        }
      end)
    else
      %Handoff{} = handoff -> {:error, {:not_withdrawable, handoff, handoff.source.branch}}
      # A slot whose handoff landed with nothing since is on no branch.
      {:error, :detached} -> {:error, {:not_withdrawable, nil, nil}}
      error -> error
    end
  end

  defp build(nil, id, words, project, base, source, head) do
    now = now()

    %Handoff{
      id: id,
      title: words.title,
      body: words.body,
      agent: words.agent,
      thread: words.thread,
      thread_id: words.thread_id,
      project: project.name,
      repo: project.path,
      onto: base.branch || base.ref,
      mirrored_branch: base.branch,
      base_branch: base.branch,
      base_ref: base.ref,
      base_commit: base.commit,
      source: source,
      head: head,
      opened_at: now,
      updated_at: now,
      timeline: [event(:opened, "#{who(words)} handed it off")]
    }
  end

  # A new revision may come from another folder than the last: its branch
  # moved to another worktree slot.
  defp build(%Handoff{} = handoff, _id, words, _project, base, source, head) do
    moved? = handoff.head != head

    %{
      handoff
      | title: if(words.title == "", do: handoff.title, else: words.title),
        body: if(words.body == "", do: handoff.body, else: words.body),
        agent: words.agent || handoff.agent,
        thread: words.thread || handoff.thread,
        thread_id: words.thread_id || handoff.thread_id,
        onto: base.branch || base.ref,
        mirrored_branch: base.branch,
        base_branch: base.branch,
        base_ref: base.ref,
        base_commit: base.commit,
        source: source,
        head: head,
        status: :open,
        updated_at: now(),
        revision: if(moved?, do: handoff.revision + 1, else: handoff.revision),
        timeline:
          handoff.timeline ++
            [
              event(
                :updated,
                if(moved?,
                  do: "#{who(words)} handed off new commits (revision #{handoff.revision + 1})",
                  else: "#{who(words)} updated it, with no new commits"
                )
              )
            ]
    }
  end

  # One handoff per branch of a repository in the VM while it is open:
  # among those waiting for you.
  defp open_from(handoffs, source) do
    Enum.find(handoffs, fn handoff ->
      Handoff.waiting?(handoff) and
        handoff.source.folder == source.folder and
        handoff.source.branch == source.branch
    end)
  end

  @doc """
  The handoffs of the project `cwd` is in, in the VM, that aren't archived
  (`HandoffRecords.current/3`), newest first, each with what MWT can say
  of it now; the folder `cwd` is in; and the
  project's worktrees as the VM has them now (`Projects.place/2`), to say
  where each handoff's branch is.
  """
  @spec for_agent(String.t(), String.t()) ::
          {:ok, Project.t(), [{Handoff.t(), map() | nil}], {:worktree, String.t()},
           MWTClient.Sandbox.Slots.look() | nil}
          | {:error, error()}
  def for_agent(username, cwd) do
    %{dir: dir} = Server.call(username, :projects)

    with {:ok, project, where, look} <- Projects.place(username, cwd) do
      mine =
        username
        |> HandoffRecords.current(project.name, DateTime.utc_now())
        |> Enum.map(fn handoff ->
          facts =
            if handoff.status in [:open, :withdrawn],
              do: ok(Handoff.facts(HandoffStore.path(dir, handoff.repo), handoff))

          {handoff, facts}
        end)

      {:ok, project, mine, where, look}
    end
  end

  ## What you do with one

  @doc """
  What MWT works out about one against your repository as it is now. The
  size and conflicts the list shows are kept up to date with it.
  """
  @spec facts(String.t(), pos_integer()) :: {:ok, Handoff.facts()} | {:error, error()}
  def facts(username, id) do
    with {:ok, handoff, store} <- find(username, id),
         {:ok, facts} <- Handoff.facts(store, handoff) do
      stats = Handoff.stats(facts)

      if handoff.status in [:open, :withdrawn] and stats != handoff.stats,
        do: Server.call(username, {:handoff_stats, id, stats})

      {:ok, facts}
    end
  end

  @doc "Works out again the size and conflicts of a project's open handoffs, as after your branch moved."
  @spec refresh(String.t(), String.t()) :: :ok
  def refresh(username, project) do
    for %Handoff{project: ^project, id: id} <- Server.call(username, :projects).waiting_handoffs,
        do: facts(username, id)

    :ok
  end

  @doc "Its change, file by file, against the commit it was built on."
  @spec diff(String.t(), pos_integer(), String.t()) :: {:ok, map()} | {:error, error()}
  def diff(username, id, merge_base) do
    with {:ok, handoff, store} <- find(username, id),
         do: Handoff.diff(store, handoff, merge_base)
  end

  @doc """
  What the landing form offers for a handoff: every host branch (with
  the worktree it is checked out in, and which is the project's default
  branch), the branch it lands on unless you choose another (`onto`: the
  task's base, the branch an earlier revision landed on being its base
  by then; the default branch when the base is no host branch), and for
  a new branch, the prefix MWT puts before its name and the name it
  suggests: the task's branch.
  """
  @spec landing(String.t(), pos_integer()) :: {:ok, map()} | {:error, error()}
  def landing(username, id) do
    with {:ok, handoff, _store} <- find(username, id) do
      trees = Map.new(Accept.worktrees(handoff.repo), &{&1.branch, &1.path})
      default = default_branch(username, handoff)

      branches =
        for branch <- Project.branches(handoff.repo) do
          %{branch: branch, worktree: trees[branch], default?: branch == default}
        end

      names = MapSet.new(branches, & &1.branch)

      onto =
        Enum.find([handoff.base_branch, default], &MapSet.member?(names, &1)) ||
          Enum.find_value(branches, & &1.branch)

      {:ok,
       %{
         branches: branches,
         onto: onto,
         prefix: Accept.prefix(handoff.repo),
         name: handoff.source.branch
       }}
    end
  end

  defp default_branch(username, handoff) do
    case Enum.find(Projects.list(username), &(&1.name == handoff.project)) do
      nil -> nil
      project -> project.mirrored_branch
    end
  end

  @doc """
  What landing would do (`Accept.preview/4`): on `destination`, or on the
  branch `landing/2` offers first; as it is when it can, unless `opts`
  says `one_commit: true`.
  """
  @spec preview(String.t(), pos_integer(), Accept.destination() | nil, keyword()) ::
          {:ok, map()} | {:error, error()}
  def preview(username, id, destination \\ nil, opts \\ []) do
    with {:ok, handoff, store} <- find(username, id),
         {:ok, destination} <- destination(username, id, destination) do
      Accept.preview(store, handoff, destination, opts)
    end
  end

  @doc """
  Lands an open handoff (`Accept.run/4`): on `destination`, or on the
  branch `landing/2` offers first; as it is (a fast-forward, its own
  commits) when that branch hasn't moved, else as one commit, or as one
  commit anyway with `one_commit: true` in `opts`.

  `head: COMMIT` in `opts` names the revision you looked at, as the page
  showed it: when the handoff's head is another by then (its thread
  handed it off again meanwhile), nothing lands (`{:revised, revision}`).
  Without it, the latest revision lands.
  """
  @spec accept(String.t(), pos_integer(), Accept.destination() | nil, keyword()) ::
          {:ok, Handoff.t()} | {:error, error()}
  def accept(username, id, destination \\ nil, opts \\ []) do
    {shown, opts} = Keyword.pop(opts, :head)

    exclusive(username, fn ->
      with {:ok, %Handoff{status: status} = handoff, store} <- find(username, id),
           true <- status != :withdrawn or {:error, :withdrawn},
           true <- status == :open or {:error, :not_open},
           true <- shown in [nil, handoff.head] or {:error, {:revised, handoff.revision}},
           {:ok, destination} <- destination(username, id, destination),
           {:ok, accepted} <- Accept.run(store, handoff, destination, opts) do
        Projects.used(username, handoff.project)

        result =
          with {:ok, landed} <-
                 update(username, id, "##{id} landed", fn record ->
                   %{
                     record
                     | status: :accepted,
                       onto: accepted.branch,
                       host_branch: accepted.branch,
                       host_head: accepted.undo.after,
                       landed: %{
                         commit: accepted.undo.after,
                         head: record.head,
                         branch: accepted.branch
                       },
                       accepted: accepted,
                       timeline:
                         record.timeline ++
                           [event(:accepted, "You landed " <> accepted_words(accepted))]
                   }
                 end) do
            {:ok, delete_branch(username, landed)}
          end

        # Mirror following also runs in the background; make this landing visible now.
        _ = Projects.fresh(username, handoff.project)
        _ = refresh(username, handoff.project)
        result
      end
    end)
  end

  @doc """
  Catches an open handoff up with the branch it is on (`CatchUp`): its
  commits replayed onto the branch's tip in MWT's store, never in your
  repository, as a new revision, which then lands as it is. Only for a
  handoff on one of your branches that moved under it, where every commit
  applies cleanly; the committer is you. Its thread's own branch keeps
  the commits it had; its next handoff catches up the same way.
  """
  @spec catch_up(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def catch_up(username, id) do
    exclusive(username, fn ->
      with {:ok, %Handoff{status: status} = handoff, store} <- find(username, id),
           true <- status == :open or {:error, :not_open},
           branch when is_binary(branch) <- handoff.base_branch || {:error, :no_branch},
           tip when is_binary(tip) <-
             Accept.tip(handoff.repo, branch) || {:error, {:branch_gone, branch}},
           {:ok, facts} <- Handoff.facts(store, handoff),
           {:ok, moved} <-
             caught_up(
               CatchUp.rebase(
                 store,
                 facts.merge_base,
                 handoff.head,
                 tip,
                 HostGit.identity(handoff.repo)
               )
             ),
           :ok <- HandoffStore.keep_revision(store, id, handoff.revision, handoff.head),
           :ok <- HandoffStore.point(store, id, moved.head),
           :ok <- HandoffStore.keep_revision(store, id, handoff.revision + 1, moved.head),
           next = %{handoff | head: moved.head, base_commit: tip},
           {:ok, after_facts} <- Handoff.facts(store, next) do
        commits = if moved.commits == 1, do: "its commit", else: "its #{moved.commits} commits"

        update(username, id, "##{id} caught up with #{branch}", fn record ->
          %{
            record
            | head: moved.head,
              base_commit: tip,
              revision: record.revision + 1,
              stats: Handoff.stats(after_facts),
              updated_at: now(),
              timeline:
                record.timeline ++
                  [
                    event(
                      :caught_up,
                      "You caught it up with #{branch}: MWT replayed #{commits} onto it " <>
                        "(revision #{record.revision + 1}). Its checks ran before that.",
                      %{onto: tip, commits: moved.commits}
                    )
                  ]
          }
        end)
      end
    end)
  end

  # Its task's branch in the VM, once it landed: deleted when nothing was
  # done on it since (`Projects.delete_landed_branch/2`), so task branches
  # don't pile up in the clone. Either way the timeline says what became of
  # it, so a branch that stays says why. The landing stands whatever
  # happens here: a timeline that can't be written is logged, not returned.
  defp delete_branch(username, handoff) do
    case Projects.delete_landed_branch(username, handoff) do
      {:ok, :gone} ->
        handoff

      outcome ->
        {kind, text} = branch_event(handoff.source.branch, outcome)

        case update(username, handoff.id, "##{handoff.id} #{kind}", fn record ->
               %{record | timeline: record.timeline ++ [event(kind, text)]}
             end) do
          {:ok, updated} ->
            updated

          {:error, reason} ->
            Logger.warning("Handoff ##{handoff.id}: #{text} Not kept: #{inspect(reason)}")
            handoff
        end
    end
  end

  defp branch_event(branch, {:ok, {:deleted, slot}}) do
    where = if slot, do: "; #{slot} is on no branch now, free for the next task", else: ""

    {:branch_deleted,
     "MWT deleted its branch #{branch} in the VM, as nothing was done on it since#{where}. " <>
       "mwt worktree resume #{branch} makes it again."}
  end

  defp branch_event(branch, {:ok, {:kept, why}}),
    do: {:branch_kept, "Its branch #{branch} stays in the VM: #{kept_words(why)}."}

  defp branch_event(branch, {:error, :vm_not_running}),
    do:
      {:branch_kept,
       "Its branch #{branch} stays in the VM: the VM wasn't running when you landed it."}

  defp branch_event(branch, {:error, reason}),
    do:
      {:branch_kept,
       "Its branch #{branch} stays in the VM: MWT couldn't delete it. #{Projects.explain(reason)}"}

  defp kept_words(:commits), do: "it has commits since this revision"
  defp kept_words({:base_of, task}), do: "the task #{task} is based on it"
  defp kept_words({:uncommitted, path}), do: "#{path} has uncommitted work on it"
  defp kept_words({:other, path}), do: "#{path}, which isn't a slot, has it checked out"
  defp kept_words({:missing, path}), do: "the worktree that has it, #{path}, is gone"

  defp caught_up({:ok, moved}), do: {:ok, moved}
  defp caught_up({:error, problem}), do: {:error, {:catch_up, problem}}

  defp destination(username, id, nil) do
    case landing(username, id) do
      {:ok, %{onto: onto}} when is_binary(onto) -> {:ok, {:commit, onto}}
      {:ok, _no_branch} -> {:error, :bad_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp destination(_username, _id, {:commit, branch}) when is_binary(branch),
    do: {:ok, {:commit, String.trim(branch)}}

  defp destination(_username, _id, {:branch, from, name})
       when is_binary(from) and is_binary(name),
       do: {:ok, {:branch, String.trim(from), String.trim(name)}}

  defp destination(_username, _id, _other), do: {:error, :bad_destination}

  @doc "What landed and where, in words."
  @spec accepted_words(Handoff.accepted()) :: String.t()
  def accepted_words(%{how: :as_is, new_branch?: true, branch: branch, from: from} = accepted),
    do: "#{commits_words(accepted)} on a new branch, #{branch}, from #{from}"

  def accepted_words(%{how: :as_is, branch: branch} = accepted),
    do: "#{commits_words(accepted)} onto #{branch} (a fast-forward)"

  def accepted_words(%{how: :commit, new_branch?: true, branch: branch, from: from}),
    do: "one commit on a new branch, #{branch}, from #{from}"

  def accepted_words(%{how: :commit, branch: branch}), do: "one commit onto #{branch}"

  # Older MWTs landed a handoff's own commits.
  def accepted_words(%{how: :commits, branch: branch}), do: "its commits onto #{branch}"

  # Older MWTs also took a handoff as uncommitted changes.
  def accepted_words(%{how: :changes, branch: branch}),
    do: "the changes onto #{branch}, uncommitted"

  defp commits_words(%{commits: 1}), do: "its commit as it is"
  defp commits_words(%{commits: n}) when is_integer(n), do: "its #{n} commits as they are"
  defp commits_words(_accepted), do: "its commits as they are"

  @doc """
  Where an unfinished handoff's branch is in the VM now, to open it in Zed
  and look at it again: the worktree that has it checked out, with its
  slot's name when it is a slot; nil when no worktree has it. The VM must
  be running.
  """
  @spec worktree(String.t(), pos_integer()) ::
          {:ok, %{path: String.t(), slot: String.t() | nil} | nil} | {:error, error()}
  def worktree(username, id) do
    with {:ok, handoff, _store} <- find(username, id),
         {:ok, look} <- Projects.slots(username, handoff.project) do
      case Enum.find(look.worktrees, &(&1.branch == handoff.source.branch and not &1.missing?)) do
        nil ->
          {:ok, nil}

        %{path: path} ->
          slot = Slots.slot_at(look, path)
          {:ok, %{path: path, slot: slot && slot.name}}
      end
    end
  end

  @doc "Takes a landed handoff back out, and opens it again."
  @spec undo(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def undo(username, id) do
    with {:ok, %Handoff{status: :accepted, accepted: %{} = accepted} = handoff, _store} <-
           find(username, id),
         :ok <- Accept.undo(handoff.repo, accepted) do
      update(username, id, "##{id} taken back out", fn handoff ->
        %{
          handoff
          | status: :open,
            host_head:
              if(handoff.host_branch == handoff.accepted.branch,
                do: handoff.accepted.undo.before,
                else: handoff.host_head
              ),
            landed: nil,
            accepted: nil,
            timeline: handoff.timeline ++ [event(:reopened, "You took it back out")]
        }
      end)
    else
      {:ok, _handoff, _store} -> {:error, :not_accepted}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "What a thread does first to carry on a handoff whose branch MWT deleted when it landed."
  @spec resume_words(String.t()) :: String.t()
  def resume_words(branch),
    do:
      "Its branch #{branch} was deleted in the VM when it landed. Run mwt worktree resume #{branch} " <>
        "in your slot before you change anything: it makes the branch again at the handoff's commit."

  @doc "Closes an open handoff without landing it."
  @spec close(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def close(username, id) do
    exclusive(username, fn ->
      with {:ok, %Handoff{status: status}, _store} <- find(username, id),
           true <- status in [:open, :withdrawn] or {:error, :not_open} do
        update(username, id, "##{id} closed", fn handoff ->
          %{
            handoff
            | status: :closed,
              timeline: handoff.timeline ++ [event(:closed, "You closed it")]
          }
        end)
      end
    end)
  end

  @doc "Opens a closed handoff again."
  @spec reopen(String.t(), pos_integer()) :: {:ok, Handoff.t()} | {:error, error()}
  def reopen(username, id) do
    case find(username, id) do
      {:ok, %Handoff{status: :closed}, _store} ->
        update(username, id, "##{id} reopened", fn handoff ->
          %{
            handoff
            | status: :open,
              timeline: handoff.timeline ++ [event(:reopened, "You reopened it")]
          }
        end)

      {:ok, _handoff, _store} ->
        {:error, :not_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update(username, id, summary, fun),
    do: Server.call(username, {:update_handoff, id, fun, summary})

  defp find(username, id) do
    %{dir: dir} = Server.call(username, :projects)

    case HandoffRecords.get(username, id) do
      {:ok, handoff} -> {:ok, handoff, HandoffStore.path(dir, handoff.repo)}
      :error -> {:error, :not_found}
    end
  end

  defp event(kind, text, extra \\ %{}), do: Map.merge(%{at: now(), kind: kind, text: text}, extra)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Who handed it off, in words."
  @spec who(map()) :: String.t()
  def who(%{agent: agent}) when agent in [nil, ""], do: "An agent"
  def who(%{agent: agent}), do: agent

  defp ok({:ok, value}), do: value
  defp ok(_), do: nil

  @doc "Why something here didn't happen, in words."
  @spec explain(error()) :: String.t()
  def explain(:vm_not_running), do: "The VM isn't running."

  def explain({:real_value, grant, where}),
    do:
      "MWT refused this handoff: #{where} holds #{grant}'s real value, which nothing in the VM should have. Nothing was handed off. The user has been told; don't send it again."

  def explain({:unscanned, reason}),
    do:
      "MWT couldn't look through everything this handoff brings for real values (#{reason}), so it wasn't handed off. Try again; if it fails again, tell the user."

  def explain(:not_found), do: "That handoff is gone."

  def explain(:not_open), do: "That handoff isn't open any more."

  def explain(:withdrawn),
    do: "Its agent took it back for more work: it can be landed once handed off again, or closed."

  def explain({:not_a_task, branch}),
    do:
      "#{branch} isn't a task's branch: a handoff goes from the branch mwt worktree new started for the task, in its slot. If this work belongs to a task, ask the user how to carry it there."

  def explain({:named_like_yours, branch}),
    do:
      "#{branch} is also the name of one of your branches (host-origin/#{branch}), so it can't be made a task: once a task's handoff lands, MWT deletes its branch, and this one is the VM's #{branch}. Put the work on a branch of its own (git switch -c NAME) and run mwt handoff again. Nothing was handed off."

  def explain({:a_task_already, branch}),
    do: "#{branch} is a task already: mwt handoff hands it off as it is."

  def explain({:not_your_task, branch}),
    do:
      "Another thread holds #{branch}: only that thread hands it off or takes its handoff back. Tell the user, and go on in this thread only read-only (mwt project says what that allows). Nothing was handed off."

  def explain({:not_withdrawable, nil, nil}),
    do:
      "This worktree is on no branch, so it has no handoff to take back: a task's branch goes once its handoff lands. For more work, take your slot again for it, named for what the user asked now: mwt worktree new TASK --from BRANCH."

  def explain({:not_withdrawable, nil, branch}),
    do:
      "#{branch} has no handoff to take back: do the work on it, and hand off once the user asks."

  def explain({:not_withdrawable, %Handoff{id: id, status: :withdrawn}, _branch}),
    do:
      "You took handoff ##{id} back already: do the work, and hand off again once the user asks."

  def explain({:not_withdrawable, %Handoff{id: id, status: status}, branch}),
    do:
      "Handoff ##{id} #{Slots.status_word(status)}: there is nothing to take back. For more work, take your slot again for it, named for what the user asked now: mwt worktree new TASK --from BRANCH (#{branch} stays as it is)."

  def explain(:not_closed), do: "That handoff isn't closed."
  def explain(:not_accepted), do: "That handoff hasn't landed, so there is nothing to undo."
  def explain(:not_in_a_project), do: Handoff.explain(:not_in_a_project)

  def explain({kind, _} = reason) when kind in [:branch_exists, :branch_gone, :changed],
    do: Accept.explain(reason)

  def explain({:conflicts, _, _} = reason), do: Accept.explain(reason)
  def explain({:catch_up, problem}), do: CatchUp.explain(problem)

  def explain(:no_branch),
    do: "It isn't on one of your branches, so there is nothing to catch up with."

  def explain({kind, _, _, _} = reason) when kind in [:pending, :untracked],
    do: Accept.explain(reason)

  def explain({:revised, revision}),
    do:
      "It was handed off again since the page showed it: revision #{revision} waits now, and nothing landed. Look at what it brings, then land it."

  def explain(reason)
      when reason in [:bad_destination, :up_to_date, :no_identity, :nothing_to_undo, :moved],
      do: Accept.explain(reason)

  def explain(reason), do: Handoff.explain(reason)
end
