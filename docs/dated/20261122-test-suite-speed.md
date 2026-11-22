# Test suite speed: review of 2026-11-22

Where the suite's time goes, measured at commit `213f95d` on `main` on a
21-core Linux VM, what this branch changes in the tests, and what is left
for you to decide because it changes MWT itself.

## Summary

The suite takes 115 to 120 s, not the 90 s AGENTS.md says: about 80 s with
modules side by side (async), then about 37 s with the modules that must run
alone (sync). Two of eleven full runs had failures, caused outside the
failing tests (see [Flaky failures](#flaky-failures)).

The machine is not the limit: a run uses about 750 CPU-seconds of the 2,500
it has, with no steal and little iowait. What limits it is one Erlang
process, the file server (`file_server_2`). Every `File.read`, `File.exists?`,
`File.mkdir_p`, `File.rm_rf` and every `System.cmd` with a bare program name
goes through it, one at a time, for the whole BEAM. It is busy 100% of the
time from 10 s to 40 s into a run, and modules take 2.5 to 5 times longer
there than alone.

This branch changes only tests: **117 s → 110 s**, with the same tests and
assertions. Two changes to MWT would take it further. Resolving programs
once: about −10 s, measured. The Git tool's remembered tabs per identity: up
to −26 s, estimated.

`mix test --slowest N` is misleading here: it turns on `--trace`, which runs
every test one at a time (`max_cases: 1`), so the whole suite takes 6
minutes and the times it reports are those of a serial run.

## Afterwards, the same day

Proposals 1, 2 and 4 were built, with more of the same kind: the suite
takes **52 to 57 s** (about 46 s async, 7 s sync), from 117 s, with every
test kept.

| Change | What it does |
| ------ | ------------ |
| `MWTClientWeb.GitLive.Session` | The Git tool's tabs and SSH key pair are each identity's, two documents in its library (`git.tabs`, `git.ssh_key`). What `preferences.json` held goes, once, to the first identity that opens the tool, and leaves the file |
| Git tool tests | `async: true`, in five modules by subject; the six about background fetch, which set app config, run alone (`GitLive.BackgroundFetchTest`) |
| `MWTClient.Executable` | Finds a program as `System.find_executable/1` does, with raw `stat`s, and keeps what it found per `PATH`, checked before each use. Every lookup and bare-name `System.cmd` in `lib` goes through it |
| `MWTClient.Files` | Raw reads, writes, `chmod` and `rm`, and a `mkdir_p` that makes only the folders missing, for the inbox, the instructions, `HostGit`'s scratch files, opening a database and the sockets folder |
| `Storage.Database` | The connection that checks the key uses the configured `synchronous` too: in the suite it no longer waits 15 ms for the disk on each new database |
| Tests split | `PolicyTest` (with `MWTClient.PolicyCase`), the landing, accepting and slots handoff modules, `HttpClientLiveTest` (four tests that change app-wide state run alone) |
| Test cleanups | `MWTClient.TestFolders.remove!/1` (`rm -rf`); an identity's cleanup waits for its sandbox's tasks |

Races the faster suite showed, fixed in the tests: `ShareSyncTest`'s
cleanup (item 3's tasks), a tunnel target checked by name though a slow
client is dialled by address (`EgressEveryHostTest`), JWT claims built from
the clock twice (`CredentialEndpointTest`), and history entries opened as a
task and not waited for (`HttpClientLiveTest`).

Still open: item 3 (a locked identity's tasks keep running) is yours to
decide. The machine is now busy most of the run: what is left is work, not
waiting.

## Where the time goes

### The sync phase (37 s)

Modules with `async: false` run one after another, with nothing beside
them:

| Module                      | Time   | Why it runs alone                                                     |
| --------------------------- | ------ | --------------------------------------------------------------------- |
| `MWTClientWeb.GitLiveTest`  | 20.5 s | the Git tool's open tabs and SSH key live in app-wide `Preferences`   |
| `MWTClientWeb.GitLive.PushTest` | 5.0 s | same                                                             |
| `MWTClientWeb.HttpClientLiveTest` | 3.6 s | 4 of its 45 tests: `Req.default_options`, the layout preference |
| the 20 others               | 7.4 s  | application config (resolver, MCP deadline, runtime folder, …)        |

The first three call `VaultHelpers.reset_data_dir!/0` in their setup, which
removes every identity's data, so nothing else may run beside them.

### The async phase (80 s)

The phase ends when its longest module ends, and ExUnit runs each module's
tests one after another. Before this branch, three modules took 25 to 32 s
alone and 70 to 74 s in the suite, running from 5 s to 78 s, while the
number of modules running fell from 60 to 6.

Every module there is slower than alone, by 2.5 to 5 times, with CPU half
idle. Sampling every process during a run shows why: on average 6.5
processes were waiting on the file server, its queue was long in a third of
the samples, and it was busy all the time from 10 s to 40 s. What was
waiting in its queue:

| Asked of the file server                                                      | Share of the queue |
| ----------------------------------------------------------------------------- | ------------------ |
| `File.mkdir_p` (`MWTClient.Sandbox.Inbox.put/4` and `hold/3`, Exqlite's connect) | 40%             |
| finding a program for `System.cmd("git", …)`, `System.find_executable`         | 27%                |
| `File.rm_rf` (test cleanups, `Scratch`, `HostGit`)                             | 11%                |
| `Inbox.write`'s other calls: reading `priv/sandbox` files, writing, renaming  | about 5%           |
| one test reading a token file in a loop (`GuaranteesTest`)                    | 3%                 |

Finding a program walks `PATH`, one `stat` per folder, until the program is
there. Under `mix`, `PATH` has 38 folders (mise adds each tool's), and git,
timeout and bash are in `/usr/bin`, near the end: about 35 calls on the file
server before each command starts. `MWTClient.Sandbox.HostGit.run/3` runs
`System.cmd("timeout", …)` around every git command and makes, writes,
reads and removes a scratch folder for it: about 45 file server calls per
git command. One test of the Handoffs page runs 316 git commands.

Not the cause: dirty IO schedulers (64 instead of 10 changed nothing),
spawning processes (the BEAM starts 7,500 git processes a second in
parallel), the disk (`/tmp`, `/work` and tmpfs are within a third of each other)
or unlocking identities (about 50 ms each, 40 in parallel in 1.3 s).

### Single tests

| Test                                                         | Time   | What it waits on                                                  |
| ------------------------------------------------------------ | ------ | ----------------------------------------------------------------- |
| `DisksTest` "Home is copied whole, put back, and emptied"     | 14 s   | three `File.read!` of a 1 GiB image, through the file server      |
| `DisksTest` "a disk that exists is left as it is…"            | 8.4 s  | two of them                                                       |
| `PolicyTest`, 6 tests over the same 20,000+ cases             | 16 s   | `Policy.decide`, CPU                                              |
| `EgressLeaksTest` "a tunnel whose first byte is 0x16…"        | 5.1 s  | `@record_within 5_000` in `Egress.TCP`                            |
| `HostCommandChannelTest` "at most twenty wait for review"     | 3.6 s  | 21 runs of the `mwt` command, about 170 ms each                   |

Each 1 GiB `File.read!` also held the file server for about a second: every
file call of every other test waited for it.

## Changed in this branch

Only tests; every test and assertion is kept.

| Change | Before → after | Confidence |
| ------ | -------------- | ---------- |
| `DisksTest` compares images with `cmp` against a sparse copy made with `cp --sparse=always`, instead of md5 over `File.read!` | module 23 s → 2.8 s | the same, every byte. A mutant (`restore!` that copies nothing) fails it |
| `GuaranteesTest` "a token file never disappears…" reads with `:file.read_file(file, [:raw])`, in the reader's own process | the loop no longer queues on the file server | stricter: through the file server a read could never land in the middle of MWT's writes, which go through it too. It passes |
| `HandoffRevisionsTest` split: later revisions in `HandoffCatchingUpTest` | 27.6 s → 15.8 s side by side | the same tests, moved as they were |
| `SandboxHandoffsLiveTest` split: handoffs that can't land as they are in `SandboxHandoffsLiveBlockedTest`; the shared setup and `hand_off/6` in `test/support/handoffs_live_helpers.ex` | 32.1 s → 16.6 s | the same |
| `HostCommandChannelTest` split three ways: commands; subgrants (`SubgrantChannelTest`); what agents propose (`ProposalChannelTest`); the shared setup and helpers in `MWTClient.MwtCommandCase` | 24.7 s → 10.9 s | the same |

The suite, before and after: 117 s → 110 s (109.7 s in `mix precommit`,
1968 tests, 0 failures). The splits help less in the suite than alone,
because the file server is still saturated: the handoff modules are now the
end of the async phase, at 3.5 to 5 times their time alone.

## Proposed: changes to MWT

### 1. Find each program once

**The concept.** Every git command MWT runs (a handoff's facts, landing,
the mirror, the Git tool) first looks for `timeout`, `git` or `bash` along
`PATH`. With one user that costs microseconds; in the suite, 42 modules at
once queue on the file server for it.

**The mechanism.** A small module resolves a program's path the first time
it is asked and keeps it (`:persistent_term`); `HostGit`, `Bounded`,
`Git.Command`, `HostRun`, `GitTransport` and `Machine` ask it instead of
passing a bare name to `System.cmd` or calling `System.find_executable`
each time. A program not found is not kept, so one installed while MWT runs
is found on the next ask.

**The world.** Measured by putting `/usr/bin` first on `PATH`, which makes
every lookup one call: 110.9 s → 100.1 s on this branch (117 s → 106.5 s
before it). What it changes for you: a program removed or moved while MWT
runs is still run from its old path until MWT restarts, and fails there
with "no such file" rather than "not installed". The alternative, test-only,
is reordering `PATH` in `test_helper.exs`: it hides the cost rather than
removing it, and depends on each machine's `PATH`.

### 2. The Git tool's remembered tabs, per identity

**The concept.** The Git tool reopens the repositories you had open, in
their order, and keeps your SSH key choice. It keeps them in
`preferences.json`, which is app-wide and readable before anyone signs in,
for the theme and the last username.

**The mechanism.** Today `GitLive.Session.remember/2` and the SSH key
choice write `git_repositories`, `git_active_repository` and
`git_ssh_*_key` to `MWTClient.Preferences`. Kept with the identity instead
(one of its stores, or keyed by username), two identities would each have
their own tabs, and tests could run side by side, each with its own.

**The world.** `GitLiveTest`, `PushTest` and `MergeWorktreeTest` would run
with the async modules: up to −26 s, estimated (not measured), less what
they add to the async phase. What it changes for you: two identities on one
machine no longer share tabs, and the tabs you have now are gone once,
unless they are moved. It also takes the SSH key choice out of a file that
says "nothing secret belongs here". The alternative, test-only: a way for a
test to point `Preferences` at a file of its own, a seam in product code
for tests only, like `MWTClient.StandIns`.

### 3. A locked identity's tasks keep running

**The concept.** `MWTClient.Vault.Store` says locking terminates an
identity's processes, "so the key and the decrypted data leave memory
together".

**The mechanism.** `Sandbox.Server` runs its work (share syncs among it) in
tasks under the application-wide `MWTClient.Sandbox.TaskSupervisor`, with
`async_nolink`. `Server.terminate/2` stops running host commands, not these
tasks, so they go on after a lock.

**The world.** A share sync started just before a lock keeps writing into
the VM's copy. In the suite: `ShareSyncTest` "a path outside the shares is
refused" failed once removing its folder (`rm_rf!`: "file already exists")
while the sync its setup started was still writing into it. A task holding
anything decrypted outlives the lock the same way. Proposed: a task
supervisor per identity, started with its stores, so closing them stops its
tasks. Not changed here: it is the Store's premise, so it is yours to
decide.

### 4. The inbox, written with fewer file calls

**The concept.** `/mnt/mwt` is rewritten (`Sandbox.Inbox.write/4`) when the
sandbox starts, when a grant changes and on VM actions, so the VM always
reads whole files that say what is true now.

**The mechanism.** Each write reads about 15 files from `priv/sandbox`,
reads each file already there to compare, and writes the changed ones
aside, with a `File.mkdir_p!` of its folder, a `chmod` and a rename each;
`hold/3` lists and makes its folder too. Every one of these is a file
server call.

**The world.** In the sandbox tests, 42% of the calls waiting on the file
server were the inbox's: every test that adds or turns on a grant rewrites
it. Read at compile time (`@external_resource`), the `priv/sandbox` files
cost nothing, and the folders can be made once per write rather than once
per file. What it changes for you: nothing the VM sees; in `mix phx.server`,
an edit to a `priv/sandbox` file shows after a recompile, which the
`@external_resource` triggers. Not measured.

### 5. Smaller ones

* **`Egress.TCP`'s `@record_within`** as an option, as `:answer_within` and
  `:head_within` already are, so `EgressLeaksTest` waits 200 ms instead of
  5 s. Not on the suite's critical path.

## Proposed: changes to tests

* **`HttpClientLiveTest`**: move the 4 tests that change global state into
  a module of their own, `async: false`, and run the other 41 side by side:
  about −2.5 s. They share a long setup and helpers, which would go to
  `test/support`. Worth doing together with item 2.
* **More splits** once item 1 is in: `HandoffsSlotsTest`,
  `HandoffsAcceptingTest`, `HandoffsLandingTest` (about 17 s alone each) are
  now the end of the async phase.
* **`PolicyTest`**: tests 2, 3 and 6 of "a request" are each implied by test
  1, which checks the exact answer for every one of the 20,000+ cases.
  Tests 4 and 5 check what test 1 doesn't (the allowance used, later times).
  Either keep them as stated guarantees and compute the decisions once for
  the module, or fold them into test 1's loop as named assertions: about
  −4 s of CPU, not on the critical path.
* **AGENTS.md**: the suite's time (about 110 s now), and that
  `mix test --slowest 10` runs every test one at a time: on one file it is
  quick, on the whole suite it takes 6 minutes.

## Flaky failures

* **A database that doesn't open at unlock**, twice in one run
  (`SandboxLiveCommandsTest`, `MCP.ToolsTest`):
  `DBConnection.ConnectionError … dropped from queue after 4000ms` while
  `Storage.Database` ran its migrations. Exqlite's connect calls
  `File.mkdir_p` and `File.stat`, through the file server: while it is
  saturated, or held by a 1 GiB `File.read!` from `DisksTest`, a connection
  can take more than 4 s to open. Likely, not proven. This branch removes the
  1 GiB reads; item 1 lowers the load further.
* **`ShareSyncTest`'s cleanup**: item 3.

## Useless tests

None found. No test lacks an assertion (three that seem to assert through a
match or an `eventually`); none is skipped; tests that share a name across
modules are the same behaviour checked for each of the parallel tools
(notes, diagrams, flash cards). The only redundancy is in `PolicyTest`,
above.

## Not checked

The tests tagged `vm`, `bench`, `dpkg` and `rpmbuild` were not run.
Measurements are from this VM; your machine's `PATH`, disks and cores will
give other numbers, likely in the same proportions.
