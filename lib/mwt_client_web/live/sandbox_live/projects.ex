defmodule MWTClientWeb.SandboxLive.Projects do
  @moduledoc """
  The projects page: the projects you work with now, each with your
  branches as its clone in the VM fetches them and its worktree slots,
  kept current while the page is open; and Open project, to bring back one
  you closed or open another repository from your shared folders.

  A project here is open: MWT follows your branches and shows its slots.
  Closing one takes it off the page and stops following it, and changes
  nothing in the VM (`MWTClient.Sandbox.Projects.close/2`). Open project
  lists the closed ones and the repositories found in your shared folders
  (`MWTClient.Sandbox.Projects.available/1`), and looks deeper in them one
  folder at a time (`MWTClient.Sandbox.Projects.browse/2`).
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{Slots, Zed}
  alias MWTClientWeb.SandboxLive.Servers

  attr :overview, :map, required: true, doc: "from `MWTClient.Sandbox.Projects.overview/1`"
  attr :mirror, :map, required: true
  attr :waiting_handoffs, :list, required: true, doc: "the handoffs waiting for you"

  attr :editing, :any,
    required: true,
    doc: "the project whose checks are being edited, `%{name: name, error: nil | text}`, or nil"

  attr :dialog, :any, required: true, doc: "the Open project dialog's state, or nil"

  attr :ports, :map,
    default: %{address: nil, status: :off, ports: []},
    doc: "the VM's servers on this machine (the snapshot's `ports`)"

  attr :worktrees, :map,
    required: true,
    doc: "project name => its slots and other worktrees, as last read (`Projects.slots/2`)"

  attr :leftovers, :any,
    default: nil,
    doc:
      "projects left in the VM (`MWTClient.Sandbox.Leftovers.list/1`'s answer), :loading, or nil when the VM is off"

  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <.page_header id="projects-header" title="Projects">
      <:help>
        The projects you work with now. Each is a git repository in a folder you share, cloned in the VM at /work/NAME: its host-origin is your repository on this machine, through MWT, so git fetch host-origin brings your committed branches there as host-origin/BRANCH, and its remote-origin is your repository's own remote origin, as remote-origin/BRANCH; a push is refused. The clone's branches are the VM's. Agents work in its worktree slots, one task branch at a time: slot-0 is the clone itself, and you add more beside it. Each task is based on the branch you name or they ask you for (mwt worktree new TASK --from BRANCH), and they leave their work uncommitted for you to review in Zed there. When you ask, they commit it as you, rebase it onto that base and hand it off (mwt handoff); you land it on the branch you choose: as it is (a fast-forward) when that branch hasn't moved, or as one commit. Only committed work travels; nothing of your working tree. Close a project you aren't working with: it leaves this page and MWT stops following it, while everything in the VM stays. Open project brings it back, or opens another repository from your shared folders.
      </:help>
      <:actions>
        <.button id="projects-open" variant="primary" phx-click="open_dialog">
          <.icon name="hero-plus-micro" class="size-3.5" /> Open project
        </.button>
      </:actions>
    </.page_header>

    <div class="space-y-4">
      <p
        :if={@vm.status != :running and @overview.open != []}
        id="projects-vm-off"
        class="flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-2 text-[12px] text-muted"
      >
        <.icon name="hero-information-circle-micro" class="size-4 text-faint" />
        The VM is off: clones and worktree slots live in it, and come back when it runs.
      </p>

      <div :if={@overview.open == []} class="rounded-xl border border-dashed border-line">
        <.empty id="projects-none-open" icon="hero-code-bracket-square">
          <%= if @overview.shares? do %>
            No project open. <button
              type="button"
              phx-click="open_dialog"
              class="cursor-pointer text-accent hover:underline"
            >Open one</button>: a repository from your shared folders, or one you closed.
          <% else %>
            No shared folder yet. Every git repository in a folder you share can be a project: <.link
              navigate={~p"/tools/sandbox/settings"}
              class="text-accent hover:underline"
            >
              share one
            </.link>.
          <% end %>
        </.empty>
      </div>

      <.project_card
        :for={%{project: project, share: share} <- @overview.open}
        project={project}
        shared?={share != nil}
        mirror={@mirror[project.name]}
        waiting_handoffs={Enum.filter(@waiting_handoffs, &(&1.project == project.name))}
        editing={@editing && @editing.name == project.name && @editing}
        worktrees={@worktrees[project.name]}
        ports={@ports}
        vm={@vm}
        now={@now}
      />

      <.leftovers leftovers={@leftovers} />
    </div>

    <.open_dialog :if={@dialog} dialog={@dialog} />
    """
  end

  ## One open project

  attr :project, :map, required: true
  attr :shared?, :boolean, required: true
  attr :mirror, :any, required: true
  attr :waiting_handoffs, :list, required: true
  attr :editing, :any, required: true
  attr :worktrees, :any, required: true
  attr :ports, :map, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp project_card(assigns) do
    assigns = assign(assigns, waiting: length(assigns.waiting_handoffs))

    ~H"""
    <section
      id={"project-#{@project.name}"}
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <header class="flex flex-wrap items-center gap-3 px-4 pt-3 pb-2">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-accent-soft/50 text-accent">
          <.icon name="hero-code-bracket-square-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="flex items-baseline gap-2">
            <span class="truncate text-[14px] font-semibold text-ink">{@project.name}</span>
            <span class="truncate font-mono text-[11px] text-faint" title={@project.path}>
              {home(@project.path)}
            </span>
          </p>
          <p id={"project-clone-#{@project.name}"} class="mt-0.5 truncate text-[11px] text-faint">
            <.clone_line
              project={@project}
              mirror={@mirror}
              shared?={@shared?}
              vm={@vm}
              now={@now}
            />
          </p>
        </div>
        <.link
          :if={@waiting > 0}
          id={"project-waiting-#{@project.name}"}
          patch={~p"/tools/sandbox/handoffs"}
          class="rounded-full bg-accent-soft px-2 py-0.5 text-[11px] font-semibold text-accent-strong transition-colors hover:bg-accent-soft/70"
          title="Handoffs waiting for your decision"
        >
          {count(@waiting, "handoff")} waiting
        </.link>
        <.button
          id={"project-zed-#{@project.name}"}
          variant="primary"
          class="whitespace-nowrap"
          phx-click="open_project"
          phx-value-path={@project.name}
          disabled={@vm.status != :running}
          phx-disable-with="Opening…"
          title="Open its clone, /work/#{@project.name} (slot-0), in Zed"
        >
          <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Open in Zed
        </.button>
        <.button
          :if={@shared?}
          id={"project-close-#{@project.name}"}
          variant="ghost"
          phx-click="close_project"
          phx-value-name={@project.name}
          title="Close: off this page, and your branches no longer followed. Its clone, slots and branches stay in the VM."
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" /> Close
        </.button>
        <.button
          :if={not @shared?}
          id={"project-forget-#{@project.name}"}
          variant="ghost"
          phx-click="forget_project"
          phx-value-name={@project.name}
          data-confirm={"Forget #{@project.name}'s settings? Its clone and worktrees stay in the VM."}
        >
          Forget
        </.button>
      </header>

      <.branches project={@project} mirror={@mirror} />
      <.identity_warning project={@project} mirror={@mirror} />
      <.checks project={@project} editing={@editing} />

      <.worktree_list
        project={@project}
        worktrees={@worktrees}
        ports={@ports}
        vm={@vm}
      />
    </section>
    """
  end

  attr :project, :map, required: true
  attr :mirror, :any, required: true
  attr :shared?, :boolean, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp clone_line(assigns) do
    ~H"""
    <%= cond do %>
      <% not @shared? -> %>
        <span class="text-warn-strong">
          Its folder is no longer shared: the VM's clone stays, but can't fetch from it. Share it again, or forget it.
        </span>
      <% @mirror && @mirror.error -> %>
        <span class="text-bad">The clone could not be prepared: {@mirror.error}</span>
      <% @mirror -> %>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-ok"></span>
          clone /work/{@project.name} · your branches read {ago(@mirror.at, @now)}
        </span>
      <% @vm.status != :running -> %>
        clone /work/{@project.name} · there when the VM runs
      <% true -> %>
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-arrow-path-micro" class="size-3 animate-spin" />
          clone /work/{@project.name} · preparing…
        </span>
    <% end %>
    """
  end

  attr :project, :map, required: true
  attr :mirror, :any, required: true

  # Your branches, host-origin/BRANCH in the VM once fetched: what a task can
  # start from and lands on.
  defp branches(assigns) do
    branches =
      case assigns.mirror do
        %{tips: tips, error: nil} -> tips |> Map.keys() |> Enum.sort()
        _ -> []
      end

    assigns = assign(assigns, branches: branches, shown: Enum.take(branches, 8))

    ~H"""
    <div
      :if={@branches != []}
      id={"project-branches-#{@project.name}"}
      class="flex flex-wrap items-center gap-1.5 px-4 pb-2.5"
    >
      <span class="mr-0.5 flex items-center gap-1 text-[11px] text-faint">
        <.icon name="hero-arrows-right-left-micro" class="size-3.5" />
        {count(length(@branches), "branch")} on host-origin
        <.help id={"project-branches-help-#{@project.name}"} label="About your branches in the VM">
          Every committed local branch of your repository, which the VM's clone fetches through MWT as host-origin/BRANCH: a task starts from one (mwt worktree new TASK --from BRANCH fetches first) and rebases onto it before its handoff. A fetch moves host-origin/* only: the clone's own branches and files stay as they are. Your repository's own remote's branches reach the VM apart, as remote-origin/BRANCH; a task starts from yours: check one out on your machine to start from it.
        </.help>
      </span>
      <code
        :for={branch <- @shown}
        class="rounded bg-deep px-1.5 py-px font-mono text-[11px] text-muted"
        title={"host-origin/#{branch} at #{String.slice(@mirror.tips[branch], 0, 10)}"}
      >
        {branch}
      </code>
      <span
        :if={length(@branches) > length(@shown)}
        class="text-[11px] text-faint"
        title={Enum.join(@branches, ", ")}
      >
        and {length(@branches) - length(@shown)} more
      </span>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :mirror, :any, required: true

  # Commits in the VM are yours, by the name and email your repository
  # uses; said only when it has none, which needs you to act.
  defp identity_warning(assigns) do
    mirror = assigns.mirror

    assigns =
      assign(
        assigns,
        :missing?,
        is_map(mirror) and Map.has_key?(mirror, :identity) and is_nil(mirror[:identity]) and
          is_nil(mirror[:error])
      )

    ~H"""
    <p
      :if={@missing?}
      id={"project-identity-#{@project.name}"}
      class="mx-4 mb-2.5 flex items-start gap-2 rounded-lg bg-warn-soft/30 px-3 py-2 text-[12px] text-warn-strong"
    >
      <.icon name="hero-exclamation-triangle-micro" class="mt-px size-4 shrink-0" />
      Your repository has no user.name and user.email, so commits in the VM have no author. Set them with git config on your machine; the clone picks them up when it is prepared again.
    </p>
    """
  end

  attr :project, :map, required: true
  attr :editing, :any, required: true

  # The one setting a project has: what mwt handoff runs before it sends.
  defp checks(assigns) do
    ~H"""
    <div class="border-t border-line-soft px-4 py-2 text-[12px]">
      <%= if @editing do %>
        <.form
          for={%{}}
          as={:project}
          id={"project-checks-form-#{@project.name}"}
          phx-submit="save_project"
          class="flex flex-wrap items-center gap-2"
        >
          <input type="hidden" name="name" value={@project.name} />
          <label for={"project-checks-#{@project.name}"} class="text-[11px] text-muted">
            Before a handoff, run
          </label>
          <input
            type="text"
            id={"project-checks-#{@project.name}"}
            name="project[checks]"
            value={@project.checks}
            placeholder="mix precommit"
            autocomplete="off"
            spellcheck="false"
            phx-mounted={JS.focus()}
            class={[input_classes(), "min-w-64 flex-1 font-mono text-xs"]}
          />
          <.button type="submit" id={"project-save-#{@project.name}"} variant="primary">
            Save
          </.button>
          <.button type="button" variant="ghost" phx-click="cancel_checks">Cancel</.button>
          <p
            :if={@editing.error}
            id={"project-settings-error-#{@project.name}"}
            class="basis-full text-[11px] text-bad"
          >
            {@editing.error}
          </p>
        </.form>
      <% else %>
        <div class="flex items-center gap-2">
          <.icon name="hero-check-badge-micro" class="size-3.5 shrink-0 text-faint" />
          <span class="text-faint">Before a handoff:</span>
          <code
            :if={@project.checks != ""}
            id={"project-checks-shown-#{@project.name}"}
            class="truncate font-mono text-[11px] text-ink"
          >
            {@project.checks}
          </code>
          <span :if={@project.checks == ""} class="text-faint italic">no checks</span>
          <.help id={"project-checks-help-#{@project.name}"} label="About the checks">
            The project's tests and checks, one command line. mwt handoff runs it in the agent's slot, after committing and rebasing, and sends nothing while it fails. Empty: none run.
          </.help>
          <button
            type="button"
            id={"project-checks-edit-#{@project.name}"}
            phx-click="edit_checks"
            phx-value-name={@project.name}
            class="ml-1 cursor-pointer rounded p-0.5 text-faint transition-colors hover:bg-hover hover:text-ink"
            title="Change the checks"
          >
            <.icon name="hero-pencil-square-micro" class="size-3.5" />
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :project, :map, required: true

  attr :worktrees, :any,
    required: true,
    doc: "`Projects.slots/2`'s answer, or `:reading` (or nil) until it comes"

  attr :ports, :map, required: true
  attr :vm, :any, required: true

  defp worktree_list(assigns) do
    assigns =
      assign(assigns,
        look: match?({:ok, _}, assigns.worktrees) && elem(assigns.worktrees, 1)
      )

    ~H"""
    <div class="border-t border-line-soft bg-deep/20">
      <div class="flex items-center gap-2 px-4 pt-2.5">
        <p class="flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
          Worktree slots
          <.help id={"project-slots-help-#{@project.name}"} label="About worktree slots">
            Fixed folders, one task at a time each, on a branch of its own: slot-0 is the clone itself, the others worktrees of it. A thread takes the slot you opened it in as its first step, even for a question, from the branch you want the work based on (mwt worktree new TASK --from BRANCH), and works only there. The slot is held from then until its handoff has landed or is closed; another thread you open there only reads. Release one sooner when its task is done or dropped. What git ignores stays between tasks, so builds stay warm, and each slot costs a checkout plus its build. A slot a Zed window has open is marked: a thread may be working there. A held slot no Zed window has open may belong to a thread that is gone: release it if so. Add one when agents run out; remove a free one to get its space back. A new slot takes the lowest number missing, and folders never move.
          </.help>
        </p>
        <p :if={@look} id={"project-slots-free-#{@project.name}"} class="text-[11px] text-faint">
          {Enum.count(@look.slots, & &1.free?)} of {length(@look.slots)} free
        </p>
        <div class="flex-1"></div>
        <.button
          id={"slot-add-#{@project.name}"}
          variant="ghost"
          phx-click="add_slot"
          phx-value-name={@project.name}
          disabled={length(@project.slots) >= 9}
          title={
            if(length(@project.slots) >= 9,
              do: "A project has at most 9 worktree slots",
              else: "Make another worktree slot, free for the next task"
            )
          }
        >
          <.icon name="hero-plus-micro" class="size-3.5" /> Add slot
        </.button>
      </div>
      <%= cond do %>
        <% @vm.status != :running -> %>
          <p class="px-4 pt-1 pb-3 text-[12px] text-faint">Shown while the VM runs.</p>
        <% @worktrees in [nil, :reading] -> %>
          <p
            id={"project-slots-reading-#{@project.name}"}
            class="flex items-center gap-2 px-4 pt-1 pb-3 text-[12px] text-faint"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5 animate-spin" />
            Reading the slots in the VM…
          </p>
        <% !@look -> %>
          <p id={"project-slots-error-#{@project.name}"} class="px-4 pt-1 pb-3 text-[12px] text-bad">
            {slots_error(@worktrees)}
          </p>
        <% @look.slots == [] -> %>
          <p id={"project-slots-none-#{@project.name}"} class="px-4 pt-1 pb-3 text-[12px] text-faint">
            No worktree slots: agents have nowhere to start a task. Add one.
          </p>
        <% true -> %>
          <ul id={"project-slots-#{@project.name}"} class="mt-1 divide-y divide-line-soft">
            <li
              :for={slot <- @look.slots}
              id={"slot-#{@project.name}-#{slot.name}"}
              class="group flex items-center gap-3 px-4 py-2 transition-colors hover:bg-deep/40"
            >
              <span class={["size-2 shrink-0 rounded-full", slot_dot(slot)]}></span>
              <div class="min-w-0 flex-1">
                <p class="flex items-center gap-2 text-[12px]" title={slot.path}>
                  <span class="font-mono text-ink">{slot.name}</span>
                  <span
                    :if={slot.name == "slot-0"}
                    class="text-[11px] text-faint"
                    title="The clone itself, /work/#{@project.name}"
                  >
                    the clone
                  </span>
                  <span
                    id={"slot-state-#{@project.name}-#{slot.name}"}
                    class={[
                      "rounded px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide",
                      slot_badge_class(slot)
                    ]}
                  >
                    {slot_badge(slot)}
                  </span>
                  <span
                    :if={slot.in_zed?}
                    id={"slot-in-zed-#{@project.name}-#{slot.name}"}
                    class="flex items-center gap-1 text-[10px] text-muted"
                    title="A Zed window has this folder open now: a thread may be working there"
                  >
                    <.icon name="hero-window-micro" class="size-3" /> open in Zed
                  </span>
                </p>
                <p class="truncate text-[11px] text-faint">
                  <%= cond do %>
                    <% slot.state == :absent -> %>
                      not made yet: made when the project is opened, or by the first task to take it
                    <% slot.state == :missing -> %>
                      its folder is gone; made again when taken
                      <span :if={slot.branch}>
                        · the branch <span class="font-mono">{slot.branch}</span> stays
                      </span>
                    <% slot.state == :foreign -> %>
                      <span class="text-bad">
                        a folder that isn't a worktree of the project is in the way
                      </span>
                    <% is_nil(slot.branch) -> %>
                      ready for the next task
                    <% true -> %>
                      <span class="font-mono text-muted">{slot.branch}</span>
                      <span
                        :if={slot[:base]}
                        id={"slot-base-#{@project.name}-#{slot.name}"}
                        title="The branch this task started from and catches up with"
                      >
                        from <span class="font-mono text-muted">{slot.base}</span>
                      </span>
                      ·
                      <%= case slot.handoff do %>
                        <% nil -> %>
                          no handoff yet
                        <% handoff -> %>
                          <.link
                            patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
                            class="text-accent hover:underline"
                          >
                            {handoff_label(handoff)}
                          </.link>
                      <% end %>
                      <span :if={slot.state == :dirty} class="text-warn-strong">
                        · uncommitted work
                      </span>
                      <span
                        :if={not slot.free? and slot.in_zed? == false}
                        id={"slot-no-zed-#{@project.name}-#{slot.name}"}
                        title="No Zed window has this folder open now: its thread may be gone. Release it if its task is done or dropped."
                      >
                        · no Zed window open
                      </span>
                  <% end %>
                </p>
                <Servers.slot_list ports={@ports} project={@project.name} slot={slot.name} />
              </div>
              <.button
                :if={freeable?(slot)}
                id={"slot-free-#{@project.name}-#{slot.name}"}
                variant="ghost"
                phx-click="free_slot"
                phx-value-name={@project.name}
                phx-value-slot={slot.name}
                disabled={slot.state == :dirty}
                title={
                  if(slot.state == :dirty,
                    do: "It has uncommitted work: commit or discard it first",
                    else:
                      "Take #{slot.name} off #{slot.branch}, so a thread there can start another task"
                  )
                }
                data-confirm={"Release #{slot.name}? It goes off #{slot.branch}, which stays with its commits. A thread still working there finds itself on no branch."}
              >
                Release
              </.button>
              <.button
                id={"slot-zed-#{@project.name}-#{slot.name}"}
                variant="ghost"
                phx-click="open_project"
                phx-value-path={@project.name}
                phx-value-folder={slot.path}
                disabled={slot.state in [:absent, :missing, :foreign]}
                title={Zed.command(slot.path)}
              >
                <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" /> Zed
              </.button>
              <.button
                id={"slot-remove-#{@project.name}-#{slot.name}"}
                variant="ghost"
                phx-click="remove_slot"
                phx-value-name={@project.name}
                phx-value-slot={slot.name}
                disabled={not removable?(slot)}
                title={remove_title(slot)}
                data-confirm={"Remove #{slot.name}? Its folder and build go; its branch stays while it holds commits not on your branches."}
                class="opacity-60 transition-opacity group-hover:opacity-100"
              >
                <.icon name="hero-trash-micro" class="size-3.5" />
              </.button>
            </li>
          </ul>
          <div :if={@look.others != []}>
            <p class="px-4 pt-3 text-[10px] font-semibold uppercase tracking-wide text-faint">
              Other worktrees
            </p>
            <ul id={"project-worktrees-#{@project.name}"} class="mt-1 divide-y divide-line-soft">
              <li :for={wt <- @look.others} class="flex items-center gap-3 px-4 py-2">
                <.icon name="hero-folder-micro" class="size-4 shrink-0 text-faint" />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-mono text-[12px] text-ink" title={wt.path}>
                    {Path.basename(wt.path)}
                  </p>
                  <p class="truncate text-[11px] text-faint">
                    {wt.branch || "no branch"}
                    <span :if={wt.missing?} class="text-warn-strong">· its folder is gone</span>
                    <%= case wt.handoff do %>
                      <% nil -> %>
                      <% handoff -> %>
                        ·
                        <.link
                          patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
                          class="text-accent hover:underline"
                        >
                          {handoff_label(handoff)}
                        </.link>
                    <% end %>
                  </p>
                </div>
                <.button
                  variant="ghost"
                  phx-click="open_project"
                  phx-value-path={@project.name}
                  phx-value-folder={wt.path}
                  disabled={wt.missing?}
                  title={Zed.command(wt.path)}
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" /> Zed
                </.button>
              </li>
            </ul>
          </div>
          <div class="h-1.5"></div>
      <% end %>
    </div>
    """
  end

  ## Open project

  attr :dialog, :map, required: true

  # The closed projects and the repositories in your shared folders, or,
  # while looking deeper, one folder of a shared folder at a time.
  defp open_dialog(assigns) do
    ~H"""
    <div
      id="open-project-dialog"
      class="fixed inset-0 z-50 flex items-start justify-center p-6 pt-[10vh]"
      role="dialog"
      aria-modal="true"
      aria-labelledby="open-project-title"
      phx-window-keydown="close_dialog"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_dialog"></div>
      <div class="relative flex max-h-[75vh] w-full max-w-xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 dark:shadow-black/60">
        <div class="flex items-center gap-3 border-b border-line-soft px-5 py-3.5">
          <p id="open-project-title" class="flex-1 text-[15px] font-semibold text-ink">
            Open a project
          </p>
          <button
            type="button"
            id="open-project-dismiss"
            phx-click="close_dialog"
            class="cursor-pointer rounded p-1 text-faint transition-colors hover:bg-hover hover:text-ink"
            aria-label="Close"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>

        <%= if @dialog.browse do %>
          <.browse_view browse={@dialog.browse} />
        <% else %>
          <.list_view dialog={@dialog} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :dialog, :map, required: true

  defp list_view(assigns) do
    q = String.downcase(String.trim(assigns.dialog.q))

    hit? = fn name, path ->
      q == "" or String.contains?(String.downcase(name <> " " <> path), q)
    end

    %{closed: closed, shared: shared} = assigns.dialog.available

    assigns =
      assign(assigns,
        closed: Enum.filter(closed, &hit?.(&1.project.name, &1.project.path)),
        shared:
          for %{share: share, repos: repos} <- shared do
            %{share: share, repos: Enum.filter(repos, &hit?.(&1.name, &1.path))}
          end,
        anything?: closed != [] or Enum.any?(shared, &(&1.repos != []))
      )

    ~H"""
    <.form
      for={%{}}
      as={:dialog}
      id="open-project-filter"
      phx-change="dialog_filter"
      phx-submit="dialog_filter"
      class="border-b border-line-soft px-5 py-3"
    >
      <div class="relative">
        <.icon
          name="hero-magnifying-glass-micro"
          class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-faint"
        />
        <input
          type="text"
          id="open-project-q"
          name="q"
          value={@dialog.q}
          placeholder="Filter by name or folder"
          autocomplete="off"
          spellcheck="false"
          phx-debounce="150"
          phx-mounted={JS.focus()}
          class={[input_classes(), "w-full pl-8 text-xs"]}
        />
      </div>
    </.form>

    <div class="min-h-0 flex-1 overflow-y-auto pb-2">
      <p :if={@dialog.available.shared == []} class="px-5 py-6 text-center text-[12px] text-muted">
        No shared folder yet: <.link
          navigate={~p"/tools/sandbox/settings"}
          class="text-accent hover:underline"
        >share one</.link>, and the repositories in it can be projects.
      </p>

      <div :if={@closed != []} id="open-project-closed">
        <p class="px-5 pt-3 pb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
          Closed
        </p>
        <ul>
          <li
            :for={%{project: project, share: share} <- @closed}
            id={"open-closed-#{project.name}"}
            class="flex items-center gap-3 px-5 py-2 transition-colors hover:bg-hover/40"
          >
            <.icon name="hero-code-bracket-square-micro" class="size-4 shrink-0 text-accent" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-[13px] font-medium text-ink">{project.name}</p>
              <p class="truncate font-mono text-[11px] text-faint" title={project.path}>
                {home(project.path)}
                <span :if={is_nil(share)} class="font-sans text-warn-strong">
                  · no longer in a shared folder
                </span>
              </p>
            </div>
            <%= if share do %>
              <.button
                id={"open-closed-button-#{project.name}"}
                variant="secondary"
                phx-click="reopen_project"
                phx-value-path={project.name}
              >
                Open
              </.button>
            <% else %>
              <.button
                variant="ghost"
                phx-click="forget_project"
                phx-value-name={project.name}
                data-confirm={"Forget #{project.name}'s settings? Its clone and worktrees stay in the VM."}
              >
                Forget
              </.button>
            <% end %>
          </li>
        </ul>
      </div>

      <div
        :for={%{share: share, repos: repos} <- @shared}
        id={"open-share-#{key(share.path)}"}
      >
        <div class="flex items-center gap-2 px-5 pt-3 pb-1">
          <.icon name="hero-folder-open-micro" class="size-3.5 text-faint" />
          <p class="min-w-0 flex-1 truncate font-mono text-[11px] text-muted" title={share.path}>
            {home(share.path)}
          </p>
          <button
            type="button"
            id={"open-share-browse-#{key(share.path)}"}
            phx-click="browse"
            phx-value-path={share.path}
            class="flex cursor-pointer items-center gap-1 rounded px-1.5 py-0.5 text-[11px] text-accent transition-colors hover:bg-accent-soft/40"
            title="Look in it folder by folder, deeper than this list goes"
          >
            Look inside <.icon name="hero-chevron-right-micro" class="size-3" />
          </button>
        </div>
        <p :if={repos == []} class="px-5 py-1.5 text-[12px] text-faint">
          {if @dialog.q == "", do: "Nothing else to open here.", else: "Nothing matches."}
        </p>
        <ul>
          <li
            :for={repo <- repos}
            id={"open-repo-#{key(repo.path)}"}
            class="flex items-center gap-3 px-5 py-2 transition-colors hover:bg-hover/40"
          >
            <.icon name="hero-code-bracket-micro" class="size-4 shrink-0 text-faint" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-[13px] text-ink">{repo.name}</p>
              <p class="truncate font-mono text-[11px] text-faint" title={repo.path}>
                {Path.relative_to(repo.path, share.path)}{if repo.branch,
                  do: " · on " <> repo.branch}
              </p>
            </div>
            <.button
              id={"open-repo-button-#{key(repo.path)}"}
              variant="secondary"
              phx-click="reopen_project"
              phx-value-path={repo.path}
            >
              Open
            </.button>
          </li>
        </ul>
      </div>

      <p
        :if={@dialog.available.shared != [] and not @anything?}
        class="px-5 pt-1 pb-3 text-[12px] text-muted"
      >
        Every repository found is open already. Look inside a folder to find one deeper down.
      </p>
    </div>
    """
  end

  attr :browse, :any, required: true, doc: "`Projects.browse/2`'s answer"

  defp browse_view(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-line-soft px-5 py-2.5">
      <button
        type="button"
        id="browse-back"
        phx-click="browse_back"
        class="flex cursor-pointer items-center gap-1 rounded px-1.5 py-0.5 text-[12px] text-muted transition-colors hover:bg-hover hover:text-ink"
      >
        <.icon name="hero-arrow-left-micro" class="size-3.5" /> All
      </button>
      <%= case @browse do %>
        <% {:ok, folder} -> %>
          <nav
            id="browse-path"
            class="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden font-mono text-[11px]"
          >
            <%= for {label, path, last?} <- crumbs(folder) do %>
              <span :if={path != folder.share.path} class="text-faint">/</span>
              <%= if last? do %>
                <span class="truncate text-ink">{label}</span>
              <% else %>
                <button
                  type="button"
                  phx-click="browse"
                  phx-value-path={path}
                  class="shrink-0 cursor-pointer rounded px-0.5 text-muted transition-colors hover:text-accent"
                >
                  {label}
                </button>
              <% end %>
            <% end %>
          </nav>
        <% {:error, _reason} -> %>
          <span class="flex-1"></span>
      <% end %>
    </div>

    <div class="min-h-0 flex-1 overflow-y-auto py-1">
      <%= case @browse do %>
        <% {:ok, folder} -> %>
          <p
            :if={folder.entries == []}
            id="browse-empty"
            class="px-5 py-6 text-center text-[12px] text-faint"
          >
            No folder here.
          </p>
          <ul id="browse-entries">
            <li :for={entry <- folder.entries} id={"browse-#{key(entry.path)}"}>
              <%= if entry.kind == :folder do %>
                <button
                  type="button"
                  phx-click="browse"
                  phx-value-path={entry.path}
                  class="flex w-full cursor-pointer items-center gap-3 px-5 py-1.5 text-left transition-colors hover:bg-hover/40"
                >
                  <.icon name="hero-folder-micro" class="size-4 shrink-0 text-faint" />
                  <span class="min-w-0 flex-1 truncate text-[13px] text-muted">{entry.name}</span>
                  <.icon name="hero-chevron-right-micro" class="size-3.5 text-faint" />
                </button>
              <% else %>
                <div class="flex items-center gap-3 px-5 py-1.5">
                  <.icon name="hero-code-bracket-micro" class="size-4 shrink-0 text-accent" />
                  <span class="min-w-0 flex-1 truncate text-[13px] text-ink">{entry.name}</span>
                  <%= cond do %>
                    <% entry.project && not entry.project.closed -> %>
                      <span class="text-[11px] text-faint">open</span>
                    <% true -> %>
                      <.button
                        id={"browse-open-#{key(entry.path)}"}
                        variant="secondary"
                        phx-click="reopen_project"
                        phx-value-path={entry.path}
                      >
                        Open
                      </.button>
                  <% end %>
                </div>
              <% end %>
            </li>
          </ul>
          <p :if={folder.cut?} class="px-5 py-2 text-[11px] text-faint">
            Only the first {length(folder.entries)} folders are shown.
          </p>
        <% {:error, reason} -> %>
          <p id="browse-error" class="px-5 py-6 text-center text-[12px] text-bad">
            {browse_error(reason)}
          </p>
      <% end %>
    </div>
    """
  end

  # The shared folder, then each folder down to this one.
  defp crumbs(folder) do
    root = folder.share.path
    parts = folder.path |> Path.relative_to(root) |> Path.split() |> Enum.reject(&(&1 == "."))

    {crumbs, _} =
      Enum.map_reduce(parts, root, fn part, at ->
        path = Path.join(at, part)
        {{part, path}, path}
      end)

    all = [{home(root), root} | crumbs]
    last = length(all) - 1
    for {{label, path}, i} <- Enum.with_index(all), do: {label, path, i == last}
  end

  defp browse_error(:not_shared), do: "That folder isn't in a shared folder."
  defp browse_error(:not_a_folder), do: "That isn't a folder to look in."

  ## Left in the VM

  attr :leftovers, :any, required: true

  # Clones and worktrees in the VM whose repository is no longer on your
  # machine: what each takes, what would go with it, and Remove.
  defp leftovers(assigns) do
    ~H"""
    <%= case @leftovers do %>
      <% {:ok, [_ | _] = left} -> %>
        <section
          id="projects-leftovers"
          class="overflow-hidden rounded-xl border border-line bg-panel"
        >
          <header class="flex items-start gap-2 border-b border-line-soft bg-deep/40 px-4 py-2.5">
            <div class="min-w-0 flex-1">
              <p class="text-[12px] font-medium text-ink">Only in the VM</p>
              <p class="text-[11px] text-faint">
                Clones and worktrees whose repository is no longer on your machine. They keep their space on the VM's Work disk until removed.
              </p>
            </div>
            <span class="shrink-0 font-mono text-[11px] text-muted">
              {bytes(Enum.sum(Enum.map(left, &(&1.size || 0))))}
            </span>
          </header>
          <ul class="divide-y divide-line-soft">
            <li
              :for={item <- left}
              id={"leftover-#{item.name}"}
              class="flex items-start gap-3 px-4 py-2.5"
            >
              <.icon name="hero-archive-box-micro" class="mt-0.5 size-4 shrink-0 text-faint" />
              <div class="min-w-0 flex-1">
                <p class="flex items-baseline gap-2 text-[13px]">
                  <span class="font-mono text-ink">{item.name}</span>
                  <span class="font-mono text-[11px] text-muted">{bytes(item.size)}</span>
                </p>
                <p class="truncate text-[11px] text-faint">
                  <%= if item.why == :repository_gone do %>
                    its repository is gone from {item.project.path}
                  <% else %>
                    no longer a project, and no shared folder has a repository by that name
                  <% end %>
                </p>
                <p
                  :if={item.uncommitted != [] or item.unmerged != []}
                  id={"leftover-risk-#{item.name}"}
                  class="mt-0.5 text-[11px] text-warn-strong"
                >
                  Would go with it: {risk_words(item)}
                </p>
              </div>
              <.button
                id={"leftover-remove-#{item.name}"}
                variant={
                  if(item.uncommitted != [] or item.unmerged != [], do: "danger", else: "ghost")
                }
                phx-click="remove_leftover"
                phx-value-name={item.name}
                data-confirm={"Remove #{item.name} from the VM: its clone and worktrees, with their builds?" <> if(item.uncommitted != [] or item.unmerged != [], do: " Lost with them: " <> risk_words(item) <> ".", else: "")}
              >
                <.icon name="hero-trash-micro" class="size-3.5" /> Remove
              </.button>
            </li>
          </ul>
        </section>
      <% {:error, reason} -> %>
        <p id="projects-leftovers-error" class="text-[11px] text-bad">
          {MWTClient.Sandbox.Leftovers.explain(reason)}
        </p>
      <% _none_or_loading -> %>
    <% end %>
    """
  end

  defp risk_words(item) do
    [
      item.uncommitted != [] &&
        count(length(item.uncommitted), "worktree") <> " with uncommitted work",
      item.unmerged != [] &&
        count(length(item.unmerged), "branch") <>
          " with commits on none of your branches (" <> Enum.join(item.unmerged, ", ") <> ")"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  ## Small parts

  defp slots_error({:error, reason}), do: MWTClient.Sandbox.Projects.explain(reason)
  defp slots_error(_), do: "The worktree slots couldn't be read."

  # A slot holding a task's branch, which you can take it off.
  defp freeable?(%{branch: branch, free?: free?, state: state}),
    do: branch != nil and not free? and state in [:clean, :dirty]

  # Only a free slot with nothing uncommitted goes; one whose folder is
  # gone just loses its number.
  defp removable?(%{name: "slot-0"}), do: false
  defp removable?(%{state: state}) when state in [:dirty, :foreign], do: false
  defp removable?(%{state: state}) when state in [:absent, :missing], do: true
  defp removable?(slot), do: slot.free?

  defp remove_title(%{name: "slot-0"}), do: "slot-0 is the clone itself: it stays"
  defp remove_title(%{state: :dirty}), do: "It has uncommitted work"
  defp remove_title(%{state: :foreign}), do: "A folder that isn't a worktree is in the way"

  defp remove_title(slot) do
    if removable?(slot),
      do: "Remove #{slot.name}: its folder and build",
      else: "A task holds it: release it first"
  end

  defp slot_badge(%{state: :dirty}), do: "uncommitted"
  defp slot_badge(%{state: :foreign}), do: "in the way"
  defp slot_badge(%{free?: true}), do: "free"
  defp slot_badge(_slot), do: "busy"

  defp slot_badge_class(%{state: :dirty}), do: "bg-warn-soft/60 text-warn-strong"
  defp slot_badge_class(%{state: :foreign}), do: "bg-bad-soft/40 text-bad"
  defp slot_badge_class(%{free?: true}), do: "bg-ok-soft/60 text-ok-strong"
  defp slot_badge_class(_slot), do: "bg-accent-soft/50 text-accent-strong"

  defp slot_dot(%{state: :dirty}), do: "bg-warn"
  defp slot_dot(%{state: :foreign}), do: "bg-bad"
  defp slot_dot(%{free?: true}), do: "bg-ok"
  defp slot_dot(_slot), do: "bg-accent"

  @doc "A short id for a path, for DOM ids."
  @spec key(Path.t()) :: String.t()
  def key(path),
    do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp handoff_label(handoff) do
    conflicts? =
      (handoff.stats[:conflicts] || 0) > 0 and handoff.status in [:open, :withdrawn]

    "handoff ##{handoff.id}, #{Slots.status_word(handoff.status)}" <>
      if(conflicts?, do: ", conflicts", else: "")
  end

  # A folder of yours, with your home folder as ~.
  defp home(path) do
    home = System.user_home!()

    cond do
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end

  defp count(1, word), do: "1 #{word}"
  defp count(n, "branch"), do: "#{n} branches"
  defp count(n, word), do: "#{n} #{word}s"
end
