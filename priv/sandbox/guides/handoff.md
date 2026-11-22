# Handing off

A handoff is the user deciding the work is done, not you: hand off only
when they ask, with `/handoff` (a message that is only `/handoff` is that
ask, whatever your tool makes of it) or in words. `mwt handoff` does every
step that needs no judgment; yours are the words, and what it stops at.

## Steps

1. **Write a title,** which becomes the commit message: the change, never
   its trip ("Handoff from slot-2", "Work done in the VM"). It is a
   Conventional Commit, `type(scope): summary`: the type says what kind of
   change it is (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`,
   `build`, `ci`, `chore`); the scope, optional, the part it touches; the
   summary, lowercase and imperative, what it does, with no period. A
   change that breaks what others rely on takes a `!` before the colon
   (`feat(api)!: …`). Take scopes and length from the project's
   `git log`; where its older commits don't follow the convention, yours
   still do. `fix(consumer): retry fetches when the partition leader
   moves`.
2. **Write notes,** in Markdown, in a file outside the repository
   (`/tmp/handoff-BRANCH.md`): what changed, why, how you tested it, what
   the user should check, and any choice you made that is theirs to
   decide. They are for the user, in MWT, and stay out of git: what you
   tried and tested in the VM goes there.
3. **`git add` the new files that belong to the work.** `mwt handoff`
   commits the changes to files git has, and stops at new ones it wasn't
   told about.
4. **Run it from your slot,** with a time limit long enough for the
   project's checks (`mwt project` names them):

       mwt handoff --title "fix(scope): what it does" --body /tmp/handoff-BRANCH.md

   It fetches host-origin; commits the changes with your title (for a new
   revision, folded into the handoff's commit, while nothing was committed
   after it); catches up with the task's recorded base by rebasing onto
   `host-origin/BASE`; runs the project's checks, if it has any; and sends that
   exact commit.
5. **When it stops** (new files, a conflict, failing checks, files the
   checks changed), do what it says, and run it again: after a conflict,
   `git add` what you resolved, and it goes on with the rebase. If what
   fails isn't yours to fix, tell the user and stop.
6. **Tell the user** the handoff's number and what `mwt handoff` said.
7. Only if a decision the user made in this task passes "Cards nobody
   asked for" in `mwt://guides/flashcards`, write its flash cards, one to
   three, and say so in a line with the url. Most tasks have none: then
   say nothing.

`--no-checks` only when the user says so. When they ask for another base,
`mwt handoff --onto BRANCH` catches up with that one. A checkpoint of work
in progress is handed off the same way, with a title that says it isn't
finished.

## After it is sent

The user lands it on the task's base unless they choose another branch,
or on a new `mwt/` branch from one: as it is, these very commits (a
fast-forward), when that branch hasn't moved since; else as one commit
with its changes. Your next fetch brings what landed. A revision after a
landing catches up with the branch it landed on.

`mwt handoffs` says what the user did: landed it, closed it, or sent it
back with a note, even after it landed.

- **More work while it waits for them** goes on the same branch: the
  handoff they have stays as it was, and your next `mwt handoff`, once
  they ask, updates it with a new revision.
  `mwt handoff withdraw --reason "..."` takes it back meanwhile, only when
  the user wants it kept from landing.
- **Sent back with a note:** do what it asks, uncommitted for them to
  review as before, and hand off again once they ask: that updates the
  same handoff.
- **Sent back to catch up:** their branch moved under the handoff. The
  note is also their ask to hand off again: run `mwt handoff`; where it
  stops at conflicts, resolve each keeping what both sides meant, `git add`
  it, and run `mwt handoff` again, until it hands off. Don't wait for
  `/handoff` this time.
- **It came too soon** (the user says so, and closes it): undo its commits
  but keep the work, uncommitted for them to see again:
  `git reset $(git merge-base HEAD BASE_REF)`, using the task's recorded
  base ref (`git config branch.TASK.mwt-base`). Then wait until they ask.
- **Landed or closed:** the slot is free again. A new ask takes it first,
  named for that ask: `mwt worktree new NEXT --from BRANCH`.
