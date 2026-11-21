# B. Git on the VM's objects

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- A fetch from the VM gets your committed branches and tags and nothing
  else, whatever protocol version it asks for. Your stash, a commit you
  reset away and colleagues' branches you fetched stay out, even when the
  VM learns their ids. Today, under protocol v2, any object in your
  repository is served by id, and a handoff's fetch tells the VM the ids
  of your stash and remote-tracking branches.
- Git that MWT runs on objects the VM wrote runs without your global and
  system configuration: no textconv, external diff, filter or hook of
  yours runs on the VM's files. That covers the review store's fetch, the
  Handoffs page's diff and the fast-forward at landing.
- The review store stops growing for ever. The VM's objects reach your
  repository only when a landing goes ahead, and an open handoff is never
  dropped to make room.

With B, the threat model can list git as hardened in its attack-surface
table, and guarantee 28 is true again.

## Where it sits

- B1: round 2, slot 1. It needs nothing. J1 waits for it, since it changes
  the same diff code (`handoff.ex`).
- B2: round 8, slot 3. It needs B1.

## Read

- The plan, workstream B.
- The review: finding 2 and both of its appendix probes; *Landing* among
  the smaller gaps; under *Shared folders and handoffs*, the lines on your
  global configuration, `textconv` and git-lfs, objects entering your
  store at the click, the store that only grows, and the 100 records.
- `agent_sandbox.md`: *The VM's clone*, *Git as grants*, *Handoffs*,
  *Landing*, guarantee 28.
- Code: `GitTransport` (the `uploadpack` options, the protocol it accepts,
  the temporary bare repository and its alternates),
  `priv/sandbox/mwt-git-remote` (it answers `option git-protocol
  version=2`), `HostGit`, `HandoffStore`, `Accept`, `Handoff`,
  `Guest.git_env/0`, the 100-record limit in `server.ex`.
- Tests: `git_transport_test.exs`, `host_git_test.exs`,
  `handoffs_landing_test.exs`, `handoffs_accepting_test.exs`,
  `handoff_revisions_test.exs`.

## B1: only branches and tags, and none of your configuration (M)

Task: `harden-git-on-vm-objects`.

1. Both probes as tests that fail now: an object asked for by id under
   `GIT_PROTOCOL=version=2` (a stash, a commit reset away), and the store's
   fetch offering your stash and a remote-tracking branch as `have` lines.
2. `GitTransport` accepts v0 and v1 only, and `mwt-git-remote` stops
   asking for v2, so the `uploadpack.allow*InWant` options hold.
3. The review store's fetch offers only your branches and tags
   (`core.alternateRefsPrefixes=refs/heads/ refs/tags/`).
4. `HostGit` gets a way to run on the VM's objects: no global or system
   configuration (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`),
   diffs with `--no-textconv` and `--no-ext-diff`. Every call on the VM's
   objects uses it: the store's fetch, the diffs, the fast-forward.
5. The fast-forward runs no filter. Your repository's own configuration
   can still name one (`git lfs install --local`), and a commit from the
   VM can add a `.gitattributes` that uses it. Find a way to update the
   working tree with no filter or textconv running. If there isn't one,
   the landing panel says which filters your repository defines and that
   they will run.
6. Landing as one commit still gets the project's identity once the
   global configuration is gone: set it explicitly, from what the project
   records.
7. The document: guarantee 28 says *under every protocol version*; a new
   guarantee at the end, *git that MWT runs on the VM's objects reads none
   of your global or system configuration, and runs no textconv, external
   diff, filter or hook*; *Landing* and *Git as grants* say how.

**Done when:** both probes pass as tests, the landing and handoff suites
pass, and `mix precommit` passes.

## B2: the review store (S/M)

Task: `clean-up-the-review-store`. After B1.

- The VM's objects reach your repository's object store only when the
  landing goes ahead, not at the click.
- A revision's ref goes when its handoff lands or closes, and the store is
  collected now and then, in bounded time.
- Past 100 handoff records, landed and closed ones go first; an open one
  never goes.
- A store whose repository is gone is removed (from *Later*, under
  Handoffs).

**Done when:** a test shows a refused landing leaves your repository's
objects as they were, a closed handoff's ref goes, and an open handoff
survives the record limit.

**Not in B:** the Handoffs page's flags (J1), and bare repositories in
shared folders (L1).
