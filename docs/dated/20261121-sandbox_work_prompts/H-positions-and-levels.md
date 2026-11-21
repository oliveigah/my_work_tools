# H. Projects: the level said, the position shown

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- You and the agents see how far each slot is behind its base, and
  whether the VM has fetched your latest: "2 behind your `main`". It shows
  on the Projects page, in `mwt project` and on the Handoffs page, and the
  thread holding a slot hears when its base moved. On 2026-11-21 a slot a
  commit behind `main` was found only by looking.
- You see how your branch stands against its own remote (a landing not
  pushed, a pull not made), so a task isn't started on a `main` you
  haven't caught up.
- Every message says which level it means: "your `main`" for your
  machine, "`main` on GitHub, as your machine last fetched it" for its
  remote. No bare `origin/main` is left in what MWT says. The remotes keep
  their names until the redesign (decided).
- You can do the whole loop by hand in the VM, with no agent:
  - a working tree of your own in each project;
  - `mwt pull`;
  - `mwt handoff` that asks for a title and opens `$EDITOR`;
  - any branch made into a task.

## Where it sits

- H1: round 3, slot 2. It needs nothing.
- H2: round 7, slot 2. It needs G1 (a person at the terminal named as one)
  and H1.

## Read

- The plan, workstream H.
- `docs/todo.md`: "Telling your machine from its remote, in the VM's Git",
  and "Working in the VM yourself, without an agent".
- `agent_sandbox.md`, under *Projects and handoffs*: *Terms*, *The VM's
  clone*, *Git as grants*, *Worktree slots*, *Handoffs*.
- `priv/sandbox/agents.md`, which the VM's agents read as their
  instructions.
- Code: `Slots` (`look/4` and the script it runs in the VM), `Projects`,
  `TaskBase`, `CatchUp`, `HostGit`, `project`, `worktree`, `handoff` and
  `help` in `priv/sandbox/mwt-cli`, `sandbox_live/projects.ex`,
  `sandbox_live/handoffs.ex`, `AgentThreads` (to tell a thread).
- Tests: `handoffs_slots_test.exs`, `projects_clone_test.exs`,
  `instructions_test.exs`, the Projects page's LiveView tests.

What the VM reports from `look/4` is the VM's word. It is fine to show,
but nothing is decided on it. What can be worked out here is worked out
here: your branch against its remote, and the clone's `origin/BASE`
against your branch.

## H1: positions and words (M)

Task: `show-slot-positions`.

- `look/4` counts each task's commits behind and ahead of
  `origin/BASE`, in the script it already runs.
- MWT compares the clone's `origin/BASE` with your branch now, and
  `HostGit` gives how your branch stands against its remote.
- `mwt project`, the Projects page and the Handoffs page say it in words.
- The thread holding a slot is told when its base moved.
- Every place MWT speaks says the level: `agents.md`, `mwt project`,
  `mwt handoffs`, `mwt worktree`, the pages, the notes MWT sends threads.
  "your `main`", and "`main` on GitHub, as your machine last fetched it".
- The document: *Terms* says the words, and *Worktree slots* says what
  is shown.

**Done when:** tests show the counts for a slot behind and one ahead, the
clone not having fetched your latest, and no bare `origin/BRANCH` left in
the text `mwt project` and `mwt handoffs` print.

## H2: working by hand (L)

Task: `work-in-the-vm-by-hand`. After G1.

- A working tree of your own per project (`/work/NAME.me`), outside the
  slots and never a thread's. A branch can be checked out in one tree
  only, and a free slot sits on `main` today: settle which gives way.
- `mwt pull [BRANCH]` fetches, then fast-forwards that branch to yours. It
  refuses, saying so, when the VM's branch has commits of its own.
- `mwt handoff` for a person:
  - with no `--title`, it asks for one;
  - with no `--body`, it opens `$EDITOR`;
  - on a branch that isn't a task, it offers to make it one, based on the
    branch it came from.
- A section of `mwt help` for a person: start, catch up, hand off, see
  what happened. And a page in the docs on working in the VM yourself.
- Remove the todo's "Working in the VM yourself" section, and the parts of
  "Telling your machine from its remote" that H1 and H2 did. What is left
  for the redesign stays.

**Done when:** a test walks the loop by hand: own tree, pull, change, a
handoff with a title asked for and a body from a stand-in `$EDITOR`.
