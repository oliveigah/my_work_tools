# J. A handoff's review on this machine

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- Before you land, the Handoffs page tells you what the VM's work does
  that a read in Zed won't make plain:
  - symlinks, executable bits and submodule links;
  - files that run by themselves: `.gitattributes`, `.gitmodules`,
    `.lfsconfig`, `.cargo/config.toml`, `AGENTS.md`, `CLAUDE.md`, CI
    workflows, git hooks, `config/*.exs`.
- It never says "no real values" or "0 files" when it couldn't look:
  - the scan refuses when it can't read the handoff;
  - a count that failed says "unknown";
  - a cut diff and more than 250 commits are said in the decision panel.
- A commit's body, author, committer and signature are shown.

Decided: you review the work in Zed, and the threat model says that Zed
shows what the VM's server tells it. The Handoffs page stays small: these
flags and warnings, worked out here from the review store's objects, are
what MWT vouches for. No review tool before the redesign.

## Where it sits

Round 6, slot 3. It needs B1, which changes the same diff code
(`handoff.ex`) and makes git on the VM's objects run without your
configuration. L3 waits for it.

## Read

- The plan, workstream J.
- The review:
  - *Review of a handoff* under *Gaps in the threat model*;
  - *Handoffs* among the smaller gaps;
  - the leads under *Shared folders and handoffs*: the hidden diff, the
    faint cut, a failed count shown as 0, files not flagged, the path
    hints, the commit's body and author.
- `agent_sandbox.md`: *Handoffs*, *Landing*, *Left in the VM*.
- Code: `Handoffs` (the scan for real values), `Handoff` (path hints,
  counts, commits), `MWTClient.Git.Files`, `sandbox_live/handoffs.ex`.
- Tests: `handoffs_test.exs`, `handoffs_landing_test.exs`,
  `handoff_revisions_test.exs`, the Handoffs page's LiveView tests.

## J1: what a handoff touches, flagged (M)

Task: `flag-what-a-handoff-touches`.

- The scan for real values refuses, saying so, when it can't read what the
  handoff brings.
- The flags are worked out here, from the store's objects (`git diff --raw`
  modes `120000`, `100755`, `160000`, and the paths), never from what the
  VM reports:
  - symlinks, executable bits and submodule links;
  - the files above that run by themselves.
- In the decision panel, not only inside the diff:
  - a cut diff;
  - a file count that failed, as "unknown";
  - more than 250 commits.
- A commit's body, its author's email, its committer and its signature
  shown. A handoff landed as it is keeps what the VM chose, so the panel
  says so.
- The document: *Handoffs* says what the page flags. The threat model's
  line on the review says which check MWT vouches for (M1 writes it; keep
  it true).

**Done when:** tests show each flag for a handoff that adds a symlink, an
executable, a submodule and a `.gitattributes`; the scan refusing on an
unreadable handoff; and the panel's warnings.
