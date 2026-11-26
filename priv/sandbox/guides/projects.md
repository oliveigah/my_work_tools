# Projects: the clone, its slots, and other threads' tasks

Read this when a slot isn't free, when the user asks you to carry on
another thread's task, to catch up with their branch, or to free a slot.
How to hand off is `mwt help handoff`.

## The clone is the VM's

A project's clone, `/work/NAME`, has two remotes through MWT, each named
for where it reaches: `host-origin`, the user's repository on their
machine (`git fetch host-origin` brings their committed branches as
`host-origin/BRANCH`; `mwt project` lists them), and `remote-origin`, that
repository's own remote `origin` (GitHub, say), as their machine fetches
it. There is no `origin`. A fetch moves nothing else. The clone's own
branches, commits and files are yours to work with: MWT never moves or
resets one, and deletes a task's branch only once its handoff landed with
nothing done on it since (below). Only committed history travels from the
user's machine; their configuration, hooks, ignored files and uncommitted
work don't. A push is refused: work goes back by `mwt handoff`.

## Slots

Tasks run in the project's worktree slots, each holding one task at a
time: `slot-0` is the clone itself, `/work/NAME`, and the others are
worktrees of it, `/work/NAME.wt/slot-N` (`mwt project` lists them).

`mwt worktree new TASK --from BASE` fetches host-origin, then starts a new
branch TASK from BASE in the slot you are in, when it is free, and records
your thread as the slot's holder. BASE is the user's branch the work is
based on (`host-origin/BASE` here), `refs/heads/TASK` for another VM task, or a
commit ID; the user's branch names resolve before local VM task names.
When the slot isn't free, nothing starts: it says why and lists the free
slots. Ask the user to start a thread in one, or to add a slot on MWT's
Projects page. What git ignores (`deps`, `_build`, `node_modules`) stays
in a slot from its last task, so builds start warm.

## A slot another thread holds

`mwt project` and `mwt worktree new` say so. Tell the user, then go on
only reading if they want you to: read and search the code, `git log`,
`diff`, `show`, `status`, answer questions, and work outside the project
(`/tmp`). Change nothing in that slot: no edits, no git command that
changes anything (commit, switch, checkout, reset, stash, merge, rebase,
fetch), no builds or tests (they write the build the other thread uses),
no `mwt worktree` or `mwt handoff`.

Only if the user asks your thread to carry on that task instead of the
other: `mwt worktree resume BRANCH`, which moves the hold to you.

More work on a handoff whose slot went to another task: ask the user to
start a thread in a free slot to continue it; that thread runs
`mwt worktree resume BRANCH`. Never switch another task's slot.

## Freeing a slot

Your slot is free again once its handoff lands or is closed. Landed with
nothing done on it since, its branch is deleted and your slot is on no
branch, at the same commit. If the user takes the landing back out and
asks for more, run `mwt worktree resume BRANCH` in your slot before you
change anything: it makes the branch again at the handoff's commit. Free it
yourself (`mwt worktree free`; refused with uncommitted work, the branch
stays) only when the user says its task is done or dropped with no
handoff to come. Other slots are freed by their own threads, or by the
user on the Projects page.

## Catching up with the user's branch

Each task records its base in Git configuration
(`git config branch.TASK.mwt-base`). To bring the user's newer commits
into your task: `git fetch host-origin`, then
`git rebase host-origin/BASE`, with
`git add` and `git rebase --continue` at each conflict. `mwt handoff` does
so itself, and goes on with a rebase you resolved. Never merge their
branch in: the history would carry the merge.
