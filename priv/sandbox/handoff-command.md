---
description: Hand off this task's work to the user now, through MWT
argument-hint: "[notes for this handoff]"
---

The user is asking you to hand off your work now: don't ask them again
whether to. `mwt handoff` does every step that needs no judgment; yours
are the words, and what it stops at.

1. Write a title, which becomes the commit message: the change, in the
   project's style (`git log`), never the VM or the handoff. And, in a
   file outside the repository (`/tmp/handoff-BRANCH.md`), notes in
   Markdown: what changed, why, how you tested it, what the user should
   check, and any choice you made that is theirs to decide.
2. `git add` the new files that belong to the work. `mwt handoff`
   commits the changes to files git has, and stops at new ones it wasn't
   told about.
3. Run it from your slot, with a time limit long enough for the
   project's checks (`mwt project` names them): it fetches origin,
   commits, with your title (a new revision folds into the handoff's
   commit), rebases onto the task's chosen base, `origin/BASE`, runs the
   checks, if any, and sends that exact commit.

       mwt handoff --title "What this is" --body /tmp/handoff-BRANCH.md

4. When it stops (new files, a conflict, failing checks, files the
   checks changed), do what it says, and run it again: after a conflict,
   `git add` what you resolved; it goes on with the rebase. If what fails
   isn't yours to fix, tell the user and stop.
5. Tell the user the handoff's number and what `mwt handoff` said.
6. Only if a decision the user made in this task passes the tests in
   "Only what will be worth it", write its flash cards, one to three, and
   say so in a line with the url. Most tasks have none: then say nothing.

The user's notes for this handoff, if any, come first where they differ
from the above (to skip the checks, `--no-checks`). The user lands it in
MWT on the task's base unless they choose another branch, or on a new
`mwt/` branch: as it is (a fast-forward) when that branch hasn't moved,
else as one commit. `--onto BASE` changes the base it catches up with,
when the user asks for another: $ARGUMENTS
