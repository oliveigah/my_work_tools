# Projects: the clone, its slots, and other threads' tasks

Read this when a slot isn't free, when the user asks you to carry on
another thread's task, to catch up with their branch, or to free a slot.
How to hand off is `mwt help handoff`.

## The clone is the VM's

A project's clone, `/work/NAME`, has the user's repository on their
machine as its `origin`, through MWT: `git fetch origin` brings their
committed branches as `origin/BRANCH` (`git branch -r`; `mwt project`
lists them), and moves nothing else. The clone's own branches, commits and
files are yours to work with: MWT never moves, resets or deletes one. Only
committed history travels from the user's machine; their configuration,
hooks, ignored files and uncommitted work don't. A push to `origin` is
refused: work goes back by `mwt handoff`.

## Slots

Tasks run in the project's worktree slots, each holding one task at a
time: `slot-0` is the clone itself, `/work/NAME`, and the others are
worktrees of it, `/work/NAME.wt/slot-N` (`mwt project` lists them).

`mwt worktree new TASK --from BASE` fetches origin, then starts a new
branch TASK from BASE in the slot you are in, when it is free, and records
your thread as the slot's holder. BASE is the user's branch the work is
based on (`origin/BASE` here), `refs/heads/TASK` for another VM task, or a
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

A handoff sent back after its slot went to another task: ask the user to
start a thread in a free slot to continue it; that thread runs
`mwt worktree resume BRANCH`. Never switch another task's slot.

## Freeing a slot

Your slot is free again once its handoff lands or is closed. Free it
yourself (`mwt worktree free`; refused with uncommitted work, the branch
stays) only when the user says its task is done or dropped with no
handoff to come. Other slots are freed by their own threads, or by the
user on the Projects page.

## Catching up with the user's branch

Each task records its base in Git configuration
(`git config branch.TASK.mwt-base`). To bring the user's newer commits
into your task: `git fetch origin`, then `git rebase origin/BASE`, with
`git add` and `git rebase --continue` at each conflict. `mwt handoff` does
so itself, and goes on with a rebase you resolved. Never merge their
branch in: the history would carry the merge.

## A thread MWT can't reach

`mwt project` and `mwt worktree new` say whether MWT can reach your
thread. One started with Zed's own Claude or Codex, or an agent in a
terminal, gets nothing from MWT: a handoff the user sends back, and other
news from MWT, won't arrive by themselves. Tell the user once, early: to
have that, they start a thread with **Claude (MWT)** or **Codex (MWT)** in
Zed's agent panel, in the same folder, and give it the task there; a task
this thread already holds moves there with `mwt worktree resume BRANCH`.
Until then, look at `mwt handoffs` yourself when the user mentions a
handoff.
