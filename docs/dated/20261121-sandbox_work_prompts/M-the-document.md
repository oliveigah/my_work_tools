# M. The threat model, written down

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- `agent_sandbox.md`'s threat model says everything it rests on. You can
  read it and know the limits, and every later step adds to it instead of
  finding them again. It says:
  - which programs on your machine read what the VM wrote, and how each
    is confined or hardened;
  - what the VM holds by default;
  - where the VM does hold credentials;
  - what it assumes about your machine;
  - what isn't covered yet.
- Each promise names the guarantees that keep it, and no passage describes
  code that is gone.
- The decisions of 2026-11-21 are in the *Decisions* table, in force.
- `docs/todo.md` no longer asks questions those decisions answered.

The other steps rebase on M1: it goes early, so their guarantees and
sections land on a document that is already right.

## Where it sits

Round 1, slot 3. It needs nothing, and changes documents only. It goes
first so the other steps' guarantees and sections land on a document that
is already right. L2 waits for it.

## Read

- The plan, workstream M, and the plan's *Decided on 2026-11-21*.
- The review, all of it, above all:
  - *Gaps in the threat model*;
  - *Additions to the document*;
  - *Passages of the document that no longer describe the code*.
- `agent_sandbox.md`: *What it is for*, *Threat model*, *Guarantees to
  test*, *Decisions*, *Later*, and the sections a stale passage sits in.
- `docs/todo.md`, "Conflicts in shared folders' copies" and "A workspace
  for agents, on your machine".

## M1: the threat model's gaps, and the decisions (S)

Task: `update-the-threat-model`.

- **The attack surface.** The review's table of programs on your machine
  that read what the VM wrote, each with how it is confined or hardened
  today. Keep it true as it is now; later steps change their rows.
- **What the VM holds by default:**
  - every note, diagram and flash card of the identity, through
    `mwt-read`;
  - a copy of your OptMem, when the VM was started from yours;
  - `host.md`: your user name, home path, tools and versions;
  - whatever came back through a grant.
- **The exceptions to "The VM never holds a credential":**
  - the agents' own logins in Home, kept in Home's snapshots;
  - anything you type into a VM terminal.
- **The assumptions:**
  - this machine's disk is encrypted;
  - you are its only user;
  - its architecture is one the seccomp filter is written for;
  - its resolver answers honestly;
  - your global git configuration is safe on the VM's files, until B1.
- **The review of a handoff:**
  - Zed shows what the VM's server tells it;
  - the diff MWT computes here, on the Handoffs page, is the check MWT
    vouches for;
  - decided: you review in Zed, and the page stays small.
- **Restarts:** a restart after a crash is a clean reset, every grant at
  its start setting (decided). Put it under *Not covered* until A1 tells
  you of one.
- **Standing access at a service:** a deploy key, a collaborator, an IAM
  binding, a webhook or a CI workflow, given with a token grant's value.
  Nothing marks it as more than a request.
- **Under *Not covered*, as things are now:**
  - pages of the VM's servers opened in your browser;
  - remote images in Markdown the VM wrote, until F1;
  - items the VM writes that agents on your machine read;
  - the upload rule keyed on a name the VM chooses, until C3;
  - a fetch under protocol v2, until B1.
- **The promises table** gets a column naming the guarantees that keep
  each promise.
- **The stale passages:**
  - file grants: the credentials table's *file* row, "Network, file" in
    the subgrants table, "file name" in the Grants page's search;
  - "what was set aside" under *Shared folders*;
  - the 2026-11-16 row of *Decisions*;
  - `*.claude.com` missing from the trusted destinations.
- **The *Decisions* table:** the six decisions of 2026-11-21, each with
  its reason, in the table's form.
- **`docs/todo.md`:**
  - remove "Conflicts in shared folders' copies", closed by decision 4;
  - in "A workspace for agents", replace the wish for both directions
    with the decision, and leave the rest for L2.

Edit Markdown in the style it has; don't reformat it. Describe the design
as built: a gap that isn't fixed yet is said as a gap, never as fixed.

**Done when:** every item above is in, and every guarantee the document
names still exists. Run `mix test` on the files the guarantees cite only
if a number changed.
