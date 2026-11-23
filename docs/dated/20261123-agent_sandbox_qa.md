# Agent Sandbox QA: review of 2026-11-23

A quality review of the Agent Sandbox at commit `f09c684` on `main`: bugs,
problems, and places where the code doesn't do what
[agent_sandbox.md](../agent_sandbox.md) and the sandbox's purpose intend.
Nothing in `lib/`, `priv/` or the rest of `docs/` was changed for it; the
probes that show each finding are in `test/review/qa_20261123/`.

The main operation it was read against: an agent in the VM works on your
project; everything it does outside the VM goes through MWT, which you see
and decide, request by request, without the VM holding a credential; and
its work comes back only as a handoff you review and land, exactly what you
reviewed, with nothing of the VM running on your machine.

## Summary

The everyday path works: from inside the VM, HTTP/1.1, HTTP/2 offers,
`Expect: 100-continue` and chunked uploads, streamed and compressed
answers, WebSockets, a 50 MB download (71 MB/s), `git clone`, npm and hex
all went through MWT unharmed, and the suite is green (2082 tests).

What isn't right gathers in five patterns, each a rule that one block would
hold for every caller (see [Patterns](#patterns)):

1. **A decision outlives what it was made under.** A card, an allowance or
   a landing is carried out against what the grant or handoff is *now*,
   or against nothing at all, rather than what you saw.
2. **One decision, several effects.** A retry joins a card, and every
   joined caller then acts: one approval, two POSTs or two notes.
3. **HTTP/2 lags HTTP/1.1.** The rules MWT built for HTTP/1.1 (strict
   heads, decoding compressed answers, 50 ms holds, bounded buffers) aren't
   all in the HTTP/2 driver.
4. **Git on your machine isn't one block.** Some commands in your
   repository run with hooks off, others with them on; landing writes over
   ignored files.
5. **Failures read as something else.** A slow relay reads as a stopped
   VM, an unreadable ask as a declined one, a failed resize as done.

The findings that matter most:

| # | Area | What happens | Checked |
| - | ---- | ------------ | ------- |
| 1 | Landing | A hook the VM wrote runs on your machine when you click Land, in a repository whose `core.hooksPath` is a tracked folder | Proven |
| 2 | Landing | Landing overwrites a file you keep ignored (`.env`) with the VM's, and Undo then deletes it | Proven |
| 3 | Commands | A waiting command card still runs after you turn its grant off, it expires, or you remove it; a removed *confined* subgrant then runs unconfined, as you | Proven |
| 4 | Network | A network grant set to Ask doesn't ask for TLS connections that carry no HTTP (`rediss://`, AMQPS, LDAPS): no card, the bytes go | Proven |
| 5 | Approvals | *Allow similar* on a GraphQL mutation lets a different mutation through: the pattern keeps 32 bits of the document's hash | Proven |
| 6 | Approvals | *Allow every use* (or Auto) on a network grant also lets through waiting cards its host list holds for asking | Proven |
| 7 | Network | Over HTTP/2, a real value quoted in a gzip-compressed answer reaches the VM (guarantee 19) | Proven |
| 8 | Network | A request whose client gave up while its card waited still goes on approval; a joined retry makes one approval send it twice | Proven |
| 9 | Network | HTTP/2 lets the VM make MWT hold memory without limit: windows not enforced, HPACK expansion unbounded (guarantee 16) | Proven |
| 10 | Network | HTTP/2 heads aren't read as strictly as HTTP/1.1's: a second `host`, CR LF in a value, a `content-length` that lies (guarantee 17) | Proven |
| 11 | Commands | The time limit and Stop don't end a run whose background child holds its output (`kubectl port-forward &`, `ssh -f`) | Proven |
| 12 | Grants | After you edit a mint command, requests keep the old command's value until it expires (up to an hour) | Proven |
| 13 | Handoffs | Land isn't tied to the revision on your screen: a revision arriving just before your click lands unseen | Read |
| 14 | VM | Locking or quitting MWT while the VM is Starting or Creating leaves it running (guarantee 6) | Read |
| 15 | Shares | One file that vanishes during a sync (an editor's lock file) fails the sync, and the next one sends everything again | Proven |
| 16 | Firewall | Releasing without trusting isolates the VM again on its next connection to the same domain: the rule's window is still full | Proven |
| 17 | Firewall | An agent whose model runs on Vertex AI, Bedrock or OpenRouter is isolated after about 26 turns by *Large upload*, and the dialog offers to trust all of `googleapis.com` | Proven |
| 18 | Activity log | A journal write that fails (the write lock held over 5 s, by a trim or a Clear) drops the whole batch, findings included, after the pages showed them | Proven |

None of them is in `docs/todo.md` or the
[threat model review of 2026-11-21](20261121-threat_model_fable5.2_review.md),
whose findings another task is fixing.

### Fixed on this branch

All 18 rows above, with regular tests; the probes of fixed findings were
turned into those tests and removed. What the review says below is the
code as it was at `f09c684`.

| # | The fix | Tests |
| - | ------- | ----- |
| 1 | `HostGit` runs every git command in your repository and the review store with `core.hooksPath=/dev/null`; so does what bypasses it (`HandoffStore`'s init and `cat-file`) | `host_git_test.exs`, `handoffs_landing_files_test.exs` |
| 2 | Landing into a checkout refuses, naming them, where a file git doesn't track (ignored ones included) stands; `--no-overwrite-ignore` as a second guard; Undo refuses to write over one you made since | `handoffs_landing_files_test.exs`, `sandbox_handoffs_live_landing_test.exs` |
| 3 | Turning off, expiry, a start setting of off, a failing check and removal settle waiting commands and calls; a card keeps how it runs (`definition`, `confine`), and Run and a call's send check the grant still allows it (`HostRuns.still/2`); an edit refuses the cards it changes; the agent hears why | `waiting_command_test.exs`, `command_refused_channel_test.exs` |
| 4 | TLS carrying no HTTP is decided as a connection MWT can't read (`Tcp.unread_inside/3`); a request after empty lines is refused, `400` | `egress_network_test.exs`, `egress_host_rules_test.exs` |
| 5 | The GraphQL digest is the whole SHA-256 | `describe_test.exs` |
| 6 | What a new allowance settles is decided as a new use would be (`Policy.settles?/3`): every use never settles a card a host list asks about | `allowance_settles_test.exs` |
| 7 | One decode-or-refuse rule for answers, both drivers (`Egress.AnswerBody`); `grpc-accept-encoding` stripped where a value goes | `http2_driver_test.exs` |
| 8 | The VM is read while a request is judged: a client that gives up ends its request, and one approval sends it once | `egress_held_request_test.exs`, `http1_driver_test.exs` |
| 9 | HTTP/2 windows enforced both ways (FLOW_CONTROL_ERROR), a 64 KiB decoded header list announced and enforced, the connection window 2 MiB, a dropped stream's window given back | `http2_driver_test.exs` |
| 10 | One set of head rules for both drivers (`Egress.RequestHead`); HTTP/2 adds `host` once and equal to `:authority`, no CR, LF or NUL, `content-length` checked against the DATA | `http2_driver_test.exs` |
| 11 | The command's output goes through a `cat` in its process group, and the run watches its program: gone, or past the limit, what is left of the group is killed and the run ends | `host_run_test.exs` |
| 12 | An edit to how a value is made drops what was minted and made the old way; a mint under way as you edit keeps nothing | `grant_edit_values_test.exs` |
| 13 | Land sends the head the page showed and is refused on another; close, send back and withdraw take the handoffs' lock; a revision applies to the record as it is | `handoffs_revision_pinned_test.exs`, `sandbox_handoffs_live_landing_test.exs` |
| 14 | On a lock or quit, a start or create under way is ended and its bubble stopped, even one not yet listening (`Machine.shut_down/2`, `Bubble.stop_by/3`) | `server_crash_test.exs` |
| 15 | Each changed file is checked before the send: a vanished one counts as removed, an unreadable one is named (to the agent too) and tried again; a file that vanishes while tar runs fails only itself | `folder_sync_unsent_test.exs`, `share_sync_test.exs` |
| 16 | Findings carry the window they were counted in, and a release forgets it, in the Watch and the server | `firewall_release_test.exs`, `firewall_test.exs` |
| 17 | In part: Trust offers and adds the exact name, never the folded domain, and a name trusted later stops counting toward its domain. Whether a token grant's hosts are spared is left to you: the Google preset lists `*.googleapis.com` | `firewall_test.exs`, `firewall_release_test.exs`, `sandbox_firewall_live_test.exs` |
| 18 | A failed batch is kept and tried again (5 tries, 10,000 rows, 64 MiB at most), then a `lost` row says what wasn't kept; the Firewall page reads its findings itself | `journal_test.exs`, `server_firewall_test.exs`, `sandbox_activity_live_test.exs` |

Found while handing these fixes off, and fixed: **an ask over 9,216 bytes
was unreadable.** The channel reads lines with `packet_size` 64 KiB, but
Erlang's line mode cuts a line at its driver buffer, 9,216 bytes unless set
(`buffer`): a `mwt run` script, a `--reason` or a handoff's notes past that
were answered "MWT couldn't read that ask", exit 121 for a run. The buffer
is now the line limit (`channel.ex`; `channel_test.exs`).

Fixed with them, as the same code: HTTP/2's 50 ms release of held bytes
([Network 6](#n6)) and its window given back on a reset (Network 7); a
Trust entry without a tunnel's port (Firewall 7); a disk whose check fails
is no longer grown ([VM 3](#v3), the check's half).

## Method and coverage

- Six area reviews, each reading its sections of the document, the
  guarantees it touches and its modules in full: the network path (the
  egress core, drivers, gate, policy, DNS); grants and approvals; projects,
  slots and handoffs; the VM's lifecycle and file copies; host commands, the
  agent channel, MWT's tools and agent threads; the firewall, the activity
  log and the pages. Each wrote probes against the real modules.
- Every finding below was checked again at the lines cited, and every probe
  run again, before it went in.
- Live, from inside the VM this review ran in: the network flows in the
  summary, `mwt why`, `mwt grants`, `mwt vm`, `mwt ports`, `mwt host`, and the
  instructions and guides against what the commands do.
- Not checked: anything only a real VM shows (`mix test --only vm`), msb,
  bwrap, Zed, a browser rendering the pages, D-Bus notifications, and real
  servers' handling of the HTTP/2 and leading-empty-line cases.

What each finding rests on:

| Label  | Meaning                                                    |
| ------ | ---------------------------------------------------------- |
| Proven | A probe ran against MWT's own modules and showed it        |
| Live   | Seen from inside the VM, against the MWT you run           |
| Read   | The code path was read at the lines given; nothing was run |

## Patterns

### A decision outlives what it was made under

A card is asked under a grant as it was; it is carried out under the grant
as it is, or under none. The cases:

- Waiting command cards (and request-subgrant calls) aren't settled when
  their grant turns off, expires or is removed, and Run checks nothing:
  [Commands 1](#c1).
- *Allow every use* settles cards a host list holds for asking:
  [Grants 2](#g2).
- An edit applies to the next use, but minted values, ID tokens and open
  connections keep the old definition: [Grants 3](#g3), [Grants 6](#g6).
- A check that runs "before the grant turns on" runs after:
  [Grants 5](#g5).
- Land lands whatever revision is current, not the one you reviewed:
  [Handoffs 7](#h7); Release releases whatever incident is current, not the
  one the dialog showed ([Firewall 9](#f9)).

**The rule one block would hold:** what a card or a landing will do is
fixed when it is shown (the grant's definition, how it is confined, the
revision's commit), and carrying it out first checks that the world still
allows it, refusing with a reason when it doesn't. Today each path decides
for itself whether to look again (`HostRuns.send_call/2` doesn't, the
proxy's path does, with `still/3` in `server/values.ex`), and each settle
lists the kinds it covers (`settle_waiting/4` defaults to requests,
connections and tools, not commands). One check of that kind, a new
`still_allowed?` every execution path calls, and settles that cover every
kind unless told otherwise, would make the next kind of card safe by
default.

### One decision, several effects

"The same call sent again joins its card" is built as "every caller waits
on one card, and each then acts". So a client's retry doubles what goes:
two POSTs through the proxy ([Network 2](#n2)), two notes through MWT's
tools ([Commands 6](#c6)). The rule: a card has one effect; a joined
caller gets that effect's result, and a caller that went away takes
nothing with it.

### HTTP/2 lags HTTP/1.1

Most of the network findings are rules the HTTP/1.1 driver holds and the
HTTP/2 driver doesn't: decode or refuse compressed answers
([Network 3](#n3)), strict heads ([Network 5](#n5)), the 50 ms release of
held bytes ([Network 6](#n6)), bounded buffers ([Network 4](#n4)). The
head check and the look at an answer are the same rule over two framings:
shared blocks the two drivers call (`Response`'s decode-or-refuse already
is one) would keep them from drifting again.

### Git on your machine isn't one block

`HostGit`'s fixed options don't turn hooks off, so each caller adds
`-c core.hooksPath=/dev/null` or forgets to ([Handoffs 1](#h1)); landing
relies on git's default of overwriting ignored files ([Handoffs 2](#h2));
and both sides find checkouts with `git worktree list`, which doesn't see a
branch mid-rebase ([Handoffs 3](#h3)). Hooks off, ignored files kept, and
a branch counted as checked out wherever git itself would refuse to move
it belong in `HostGit`, once.

### Failures read as something else

A relay slow to answer reads as a stopped VM ([VM 8](#v8)); a failed
resize as a resized disk ([VM 3](#v3)); a failed boot script only in
MWT's log ([VM 7](#v7)); an ask MWT can't parse as one the user declined
([Commands 3](#c3)); MCP busy as "MWT is locked" ([Commands 5](#c5)); a
journal write that failed as events kept ([Firewall 3](#f3)); counts over
the newest 500 or 20,000 events as counts over the hour or the window
([Firewall 4](#f4)). Each costs the user or the agent a wrong next step.

## Findings by area

Each finding: what is intended, what happens, a scenario, the evidence, and
the direction of a fix.

### Projects, slots and handoffs

<a id="h1"></a>

**1. A hook the VM writes runs on your machine when you click Land.** Bug.

- *Intended:* "landing runs no hook" (Threat model; Landing).
- *Happens:* only the fast-forward and the Undo's reset get
  `-c core.hooksPath=/dev/null` (`accept.ex:337`, `:367`). The cleanup
  `update-ref -d refs/mwt/handoffs/<id>` (`accept.ex:315`), landing on a
  branch that isn't checked out (`:353`) and its Undo (`:385`), and the
  review store's fetch in `copy_into` (`handoff_store.ex:339`) run with
  hooks on; `HostGit`'s fixed options (`host_git.ex:23`) don't turn them
  off.
- *Scenario:* your repository sets `core.hooksPath` to a tracked folder
  (`.githooks`, a common setup). The handoff adds an executable
  `.githooks/reference-transaction`. Land fast-forwards your checkout,
  writing that file, and the cleanup `update-ref` runs it, as you. Every
  later landing's fetch runs it again.
- *Evidence:* Proven, `handoffs/tracked_hooks_path_probe.exs`: the VM's
  script ran 3 times in your repository during one `Handoffs.accept`.
- *Fix:* `-c core.hooksPath=/dev/null` on every command `HostGit` runs in
  your repository.

<a id="h2"></a>

**2. Landing overwrites files you keep ignored, and Undo deletes them.**
Bug, data loss.

- *Intended:* the fast-forward never goes over pending changes; ignored
  files (a `.env`) are yours and never travel.
- *Happens:* `git merge --ff-only` (`accept.ex:337`) overwrites untracked
  ignored files by default; `pending/1` looks only at tracked ones.
- *Scenario:* the handoff force-adds `.env`. Its diff shows a new file;
  Land replaces your `.env` with the VM's, without a word. Undo
  (`reset --keep`) then removes it: your original is gone.
- *Evidence:* Proven, `handoffs/ignored_files_probe.exs`; also in plain git:
  `--no-overwrite-ignore` refuses and keeps your file.
- *Fix:* `--no-overwrite-ignore` on the merge; the preview could list the
  ignored paths a handoff would write.

<a id="h3"></a>

**3. A branch mid-rebase counts as checked out nowhere.** Bug.

- *Intended:* a checked-out branch moves only by a fast-forward there; a
  task branch with work where it is checked out is kept.
- *Happens:* both sides read `git worktree list`, which shows a worktree
  mid-rebase as detached: `Accept.worktrees/1` and `target/2`
  (`accept.ex:61`, `:147`) here, the `@delete_landed` script
  (`slots.ex:273-286`) in the VM. `update-ref` then moves the branch where
  `git branch -f` would refuse.
- *Scenario:* you are rewording a commit on `master` (`rebase -i`, stopped)
  and click Land: `master` moves by `update-ref`, and your `rebase --abort`
  puts it back without the landed commit, while the record says Landed. In
  the VM, a thread mid-rebase loses its branch when its handoff lands, and
  its `rebase --continue` fails.
- *Evidence:* Proven, `handoffs/rebase_in_progress_probe.exs` (both sides).
- *Fix:* count a branch named in `rebase-merge/head-name`,
  `rebase-apply/head-name` or `BISECT_START` of any worktree as checked
  out, as git does.

**4. After "Catch up here", landing keeps the VM's branch for a false
reason and leaves the slot held.** Bug.

- *Happens:* `delete_landed_branch` (`projects.ex:704`) and `Slots.free?`
  (`slots.ex:498`) compare with `handoff.head`, which after `catch_up/2`
  (`handoffs.ex:642-643`) is a commit only MWT's store has.
- *Scenario:* you catch a handoff up and land it. The timeline says "it has
  commits since this revision" (it hasn't); the slot stays held, and its own
  thread is told another thread holds it, until you Release it.
- *Evidence:* Proven, `handoffs/catch_up_land_probe.exs`.
- *Fix:* keep the VM commit each revision came from, and compare with it.

**5. Two threads taking the same free slot both hear "Started".** Risk.

- *Happens:* `Projects.take_slot/5` and `free_slot/4` (`projects.ex:601`,
  `:661`) take no lock, unlike release, delete and add; the `@take` script
  (`slots.ex:189`) re-checks only for uncommitted work.
- *Scenario:* two threads opened in one slot both take it first, as told.
  One works on the other's branch, and its handoff is later refused as
  `not_your_task`; or git's `index.lock` collides.
- *Evidence:* Proven, `handoffs/slot_race_probe.exs` (timing-dependent: 2
  runs of 3).
- *Fix:* take and free under `locked/3`; `@take` checks HEAD is what the
  look saw.

**6. A task started `--from login` (another task, short name) loses its
base when `login` lands.** Bug.

- *Happens:* `TaskBase.resolve_at` records `login` as given
  (`task_base.ex:54`); `@delete_landed` keeps a branch only for
  `refs/heads/login` (`slots.ex:271`). The thread was also told it came from
  "host-origin/login, the user's login" (`channel.ex:730`).
- *Scenario:* `login` lands and is deleted; the next `mwt handoff` of the
  task based on it is refused: "No comparison branch or commit login is
  available".
- *Evidence:* Proven, `handoffs/based_on_task_probe.exs`.
- *Fix:* record the full ref the base resolved to.

<a id="h7"></a>

**7. Land isn't tied to the revision on screen; a revision being received
overwrites a Close or a send-back.** Risk.

- *Intended:* "a revision is pinned"; you land what you reviewed.
- *Happens:* the Land event sends only the id (`sandbox_live.ex:1964`), and
  `Handoffs.accept/4` (`handoffs.ex:573`) lands the current head.
  `close/2`, `send_back/4` and `withdraw/2` don't take the lock `open/2`
  holds, and `open_revision` writes back the whole record it read before its
  fetch.
- *Scenario:* a thread hands off again by itself just before your click:
  Land lands a revision you never saw. A Close during that fetch is lost,
  and the handoff is open again.
- *Evidence:* Read.
- *Fix:* Land sends the head it previewed, refused on a mismatch; close,
  send back and withdraw under the same lock, and a revision applied as an
  update to the record as it is.

**8. After you rename `master` to `main`, no slot can be made.** Bug.

- *Happens:* `Slots.ensure` adds slots at
  `refs/remotes/host-origin/<default>` (`slots.ex:221`), and nothing
  fetches into the VM's clone first.
- *Scenario:* Add slot fails ("invalid reference"), yet the project keeps
  the new slot number; every mirror update that would remake a slot fails
  the same way, and skips the refresh of handoff stats.
- *Evidence:* Proven, `handoffs/default_branch_rename_probe.exs`.
- *Fix:* fetch `host-origin` in the VM first, or make slots at a commit id
  the clone has.

**9. Undo refuses once you switched your checkout to another branch.**
Misaligned.

- *Happens:* a merge-kind Undo requires the branch still checked out there
  (`accept.ex:366`); a branch-kind Undo refuses when it now is (`:377`).
  You are told "Your branch has moved since it landed" while it sits at the
  landed commit.
- *Evidence:* Proven, `handoffs/undo_after_switch_probe.exs`.
- *Fix:* check only the tip; undo by compare-and-swap `update-ref` where it
  isn't checked out.

### Host commands, the agent channel and MWT's tools

<a id="c1"></a>

**1. A waiting command card survives its grant being turned off, expiring
or being removed, and Run still works; a removed confined subgrant then
runs unconfined, as you.** Bug, guarantees 9 and 26.

- *Intended:* "Nothing the VM wrote runs on your machine unless Ask to run
  commands is on"; a command subgrant runs "while it is on"; a confined one
  sees none of your home.
- *Happens:* the settles leave command cards out: `settle_waiting/4`
  defaults to `[:request, :connection, :tool]` (`server/approvals.ex:786`),
  used by turning off (`server/grants.ex:413`), expiry (`:1176`) and a start
  setting of off (`:307`); deleting refuses only
  `[:activation, :request, :connection]` (`:151`). `Approvals.run/4`
  (`server/approvals.ex:382-410`) looks the grant up again: when it is gone,
  `match?(%Grant{confined: true}, nil)` is false, and the script runs as
  plain `bash -lc`. The card still says "Runs: Confined: no home of yours"
  (`host_runs.ex:445`). An edit while a run waits mixes the two: the old
  script with the new grant's confinement. A waiting request-subgrant call
  is sent with the real value whatever the subgrant's state, and whether
  the grant still lists the host (`host_runs.ex:139-167`; the proxy's path
  re-checks in `server/values.ex:283-293`).
- *Scenario:* an agent asks; you turn Ask to run commands off, or remove the
  subgrant, and the card stays on the Approvals page. Later you click Run:
  it runs, or runs with your home, keys and logins in reach under a card
  that says confined.
- *Evidence:* Proven, `channel/waiting_after_off_probe.exs` and
  `grants/stale_command_card_probe.exs`: after `turn_off("commands")` Run
  returned `:ok` and the marker was written; the removed confined subgrant
  printed a file from `$HOME`; an off request subgrant's mint ran on the way
  to sending.
- *Fix:* settle `:command` cards with the rest; freeze how a run is
  confined, and with which grants, into the card; Run and `send_call`
  refuse when the grant is gone, off or no longer covers the host. See
  [the pattern](#a-decision-outlives-what-it-was-made-under).

**2. The time limit and Stop don't end a run whose background child keeps
its output open.** Risk.

- *Intended:* "TERM at the limit, KILL 5 seconds later, to its whole process
  group"; Stop kills the group.
- *Happens:* when `bash` exits, `timeout` exits too and signals nobody; the
  port waits for end-of-file (`host_run.ex:159`, `:264`); Stop and lock
  (`server.ex:2010`) reach only `-pgid`, which a child that called `setsid`
  (`ssh -f`) has left.
- *Scenario:* `kubectl port-forward … &`, `ssh -fN -L …`, `nohup x &`: the
  card says "Time limit 2 min", the run shows running for good, `mwt wait`
  answers 120 forever, and Stop does nothing for the `setsid` case.
- *Evidence:* Proven, `channel/host_run_probe.exs`: with a 1 s limit,
  `sleep 8 & echo started` lasted 8 s, not timed out; after KILL to the
  group, a `setsid sleep 6` run still lasted 5.7 s.
- *Fix:* enforce the limit outside `timeout` (close the port and kill when it
  passes or `timeout` exits); a cgroup or systemd scope reaches detached
  children; or give the command a stdout that ends with the shell.

<a id="c3"></a>

**3. An ask MWT can't parse is told "MWT couldn't read that ask. Use the
mwt command.", exit 121 for `run` and `call`.** Bug.

- *Intended:* bytes that aren't UTF-8 are "refused before it waits for
  you, and the agent is told which"; 122 is "the ask was wrong".
- *Happens:* `Jason.decode` fails on invalid UTF-8 anywhere, and a line over
  64 KiB is cut by `packet_size`; both end as `:unreadable` (`channel.ex:294`),
  which the CLI reads as 121, "declined or didn't run" (`mwt-cli:690`).
- *Scenario:* `mwt run commands < legacy.sh` with a Latin-1 comment, or a
  `--reason` of 68 KB: exit 121, with advice to use the command already in
  use. `mwt handoff --body FILE` over about 60 KB commits, rebases and runs
  the checks, then fails the same way.
- *Evidence:* Proven, `channel/script_bytes_probe.exs`,
  `channel/channel_line_probe.exs`.
- *Fix:* say "not UTF-8" or "over 64 KiB", with 122; the CLI checks its own
  sizes, and trims a handoff body before the steps.

**4. The CLI deletes control characters from every field, so the card shows
a script the agent didn't write.** Misaligned.

- *Happens:* `json()` strips `\001-\010`, `\013`, `\014`, `\016-\037`
  (`mwt-cli:333`), so the server's check for hidden characters never sees
  them. `printf '\e[31mred\e[0m'` becomes `printf '[31mred[0m'` on the
  card, with no word to the agent. What runs is still what the card shows.
- *Evidence:* Proven, `channel/script_bytes_probe.exs`.
- *Fix:* escape them as `\u00XX` and let the server refuse and name them.

<a id="c5"></a>

**5. Some MCP refusals reach the client as the wrong answer.** Bug.

- *Happens:* a message over 2 MB is answered with `Protocol.error(nil, …)`
  (`channel.ex:369`): `"id": null`, so the client's request never resolves.
  "MWT is reading 8 MCP messages…" and "no whole MCP message in time" start
  with `1`, which `mcp_server` in the CLI turns into "MWT isn't answering: it
  may be locked or closed. Tell the user" (`mwt-cli:749-754`).
- *Scenario:* a large `update_diagram` hangs the agent's tool call until its
  client times out; a burst of writes makes the agent ask you to unlock an
  MWT that is unlocked.
- *Evidence:* Proven for the null id, `channel/channel_line_probe.exs`;
  Read for the busy mapping.
- *Fix:* echo the id (`mcp_id` already extracts it); give busy and too-slow
  answers of their own.

<a id="c6"></a>

**6. An addition that asks, sent again while its card waits, is made twice
on one decision.** Bug.

- *Happens:* each joined caller gets `:ok` and runs its own `apply`
  (`mwt_tools.ex:119-155`); a `create_*` has no version to stop the second.
  It arises when `mwt-create` is set to ask, or past the hour's limit.
- *Evidence:* Proven, `channel/tools_retry_probe.exs`: one card,
  `retries: 1`, one Allow, two notes "Release checklist".
- *Fix:* apply once per approval and hand every joined caller that result.

### Grants and approvals

**1. A different GraphQL mutation passes under an earlier *Allow
similar*.** Bug.

- *Intended:* *Allow similar* covers "the same GraphQL operation";
  "another document with the same name is not" (`Describe`).
- *Happens:* the pattern is `POST host/graphql · <kind name> · <digest>`
  (`describe.ex:346-349`), and `GraphQL.digest/1` keeps 8 hex characters of
  the SHA-256, 32 bits (`graphql.ex:58-63`). The label names the operation,
  not what it changes.
- *Scenario:* an agent following planted instructions prepares, ahead of
  time, `mutation AddComment { deleteIssue(…) }` with a string that gives
  the same 32 bits as its `mutation AddComment { addComment(…) }`. You
  choose *Allow similar, 1 h* on the comment; the deletion goes through
  without a card.
- *Evidence:* Proven, `grants/graphql_similar_probe.exs`: a search on 18
  threads found the string in 1 min 49 s; both documents get the same
  pattern, and `Allowance.covers?` is true.
- *Fix:* the full SHA-256 in the pattern; the label could list every
  top-level field.

<a id="g2"></a>

**2. *Allow every use* (or Auto-approve) lets through cards a host list
holds for asking.** Bug.

- *Intended:* *Allow every use* is "Not a host its host list asks about".
- *Happens:* `add_allowance` settles every waiting use the new allowance
  covers, and `covers?(:all, _)` is always true, whatever the card's
  `host_entry` (`server/grants.ex:49-72`). Over-limit `mwt-create` cards
  go the same way.
- *Scenario:* "Corp" has `admin.corp.example` set to Ask, and two cards
  wait. You pick *Allow every use, 1 h* on the wiki's card; the admin
  request goes through too.
- *Evidence:* Proven, `grants/host_entry_allow_all_probe.exs`: the admin
  card settled `{:allowed, {:allow, :all, 60}}`, while a new request there
  still asks.
- *Fix:* skip cards with a `host_entry` (and over-limit tool cards) for an
  `:all` allowance, as `Policy.host_ask/4` does.

<a id="g3"></a>

**3. After you edit a mint command, requests keep the old command's value.**
Bug.

- *Intended:* an edit "applies to the next use".
- *Happens:* `update_grant` leaves `minted`, `id_tokens` and `made` alone
  (`server.ex:915-943`); the kept value lives until it expires, up to about
  59 minutes for a gcloud token.
- *Scenario:* you notice the mint impersonates `deployer@`, change it to
  `reader@`, and the agent keeps the deployer's token for the hour.
- *Evidence:* Proven, `grants/edited_mint_probe.exs`.
- *Fix:* an edit that changes `source`, `mint_per` or `keep_minutes` drops
  the grant's minted values, ID tokens and what was made from them, as
  `Grants.delete` does.

**4. The VM can start any number of mint commands at once.** Risk,
guarantee 16.

- *Happens:* a grant minted per host keys its values by `{id, host}`, and
  the VM picks the name under a `*.` host; nothing caps mints running at
  once or values kept (`values.ex:430-451`), and every kept value joins the
  set scanned on each request.
- *Scenario:* an auto-approved `*.run.app` grant minted per host: requests
  to 1,000 made-up names start 1,000 `gcloud` processes, as you, unconfined.
- *Evidence:* Proven, `grants/mint_per_host_fanout_probe.exs`: 40 names
  started 40 concurrent mints in 1.5 s.
- *Fix:* cap concurrent mints per grant (queue the rest) and distinct hosts
  kept per grant; refuse past it, saying why.

<a id="g5"></a>

**5. *Only while…* lets uses through while the turn-on check runs.**
Misaligned.

- *Intended:* checks run "before the grant turns on".
- *Happens:* `turn_on` turns the grant on, then starts its checks without
  waiting (`server/grants.ex:183-200`); `Check.failing/3` takes a pass from
  up to 25 hours ago as holding (`check.ex:135-139`).
- *Scenario:* "the VPN is up" passed this morning; you turn the grant on
  this afternoon with the VPN down, and uses go until the check fails.
- *Evidence:* Proven, `grants/check_window_probe.exs`.
- *Fix:* the grant counts as paused while an `:enable` check runs.

<a id="g6"></a>

**6. Narrowing a grant by editing it keeps open what it let through.**
Misaligned.

- *Happens:* connections close only when a grant stops being live
  (`server/grants.ex:1127-1135`, `gate.ex:448-460`); `update_grant` closes
  nothing.
- *Scenario:* you remove `prod-db.corp:5432` from a network grant, keeping
  staging; the agent's open session to prod stays connected.
- *Evidence:* Read.
- *Fix:* after an edit, close the grant's connections whose destination it
  no longer covers.

### The network path

**1. TLS that carries no HTTP skips the network grant's ask and the host
lists.** Bug.

- *Intended:* "Not read, the connection is the card" (Private networks); a
  host set to Block closes "a connection MWT can't read" (Host lists).
- *Happens:* `intercept/3` hands a TLS connection whose first bytes aren't
  HTTP, or that stays silent, straight to `Raw` with
  `{:passed, :inside_tls}` (`egress/tcp.ex:541-555`), never through
  `asked/6` (`:663`), which only the not-TLS path calls (`:628`). And a
  request after one empty line, which servers must ignore (RFC 9112 §2.2),
  isn't detected as HTTP.
- *Scenario:* a network grant set to Ask opens a production Redis over TLS
  (`rediss://`); the agent runs `FLUSHALL`: no card, it reaches Redis.
  AMQPS, Kafka over TLS, LDAPS, IMAPS and SMTPS the same. A host set to Block
  on the Internet's list is reached by a TLS client that offers no ALPN and
  sends an empty line first.
- *Evidence:* Proven, `egress/inside_tls_unasked_probe.exs`: 0 cards and the
  `FLUSHALL` arrived; on the blocked host, a normal request got 403, the same
  after an empty line `200`.
- *Fix:* the inside-TLS `Raw` start goes through `asked/6`
  (`Gate.unread`); `Http1.detect` skips leading empty lines, or refuses
  them.

<a id="n2"></a>

**2. A held request whose client gave up still goes; a joined retry makes
one approval send it twice.** Bug.

- *Intended:* a retry "joins that approval, and your decision answers both";
  the request goes once, for a client still there.
- *Happens:* while judging, the driver asks only for `{:judge, _}` and arms
  no read of the VM (`http1.ex:561`), so a close isn't seen; on allow,
  `send_upstream` writes the request anyway (`http1.ex:632`), and every
  waiter is answered `let_through` (`server/approvals.ex:465-468`).
- *Scenario:* `gh issue create` waits on a card, times out and retries.
  You approve once: two issues.
- *Evidence:* Proven, `egress/abandoned_approval_probe.exs`: one card,
  retries 1, the host got 2 POSTs.
- *Fix:* keep reading the VM while judging (capped), so a close ends the
  request before it is sent; drop a waiter whose caller died, and a card
  nobody waits for.

<a id="n3"></a>

**3. Over HTTP/2, a real value quoted in a compressed answer reaches the
VM.** Bug, guarantee 19.

- *Intended:* gzip and deflate are "decoded for the look"; "however framed
  or compressed".
- *Happens:* `looked/3` (`http2.ex:899-910`) scans DATA as it came, neither
  decoding nor refusing a content encoding, as `Http1.Response` does;
  `grpc-accept-encoding` passes, so a gRPC server may gzip each message.
- *Evidence:* Proven, `egress/http2_gzip_probe.exs`: a gzip 401 echoing the
  value wasn't cut, and the VM's bytes, decompressed, hold it.
- *Fix:* `Response`'s decode-or-refuse for HTTP/2 streams that carry a
  value; strip `grpc-accept-encoding` on them.

<a id="n4"></a>

**4. HTTP/2 lets the VM make MWT hold memory without limit.** Risk,
guarantee 16.

- *Happens:* `vm_data/5` (`http2.ex:464`) keeps whatever DATA arrives,
  whatever windows MWT granted; the 64 KiB limit applies to the compressed
  header block, decoding (`http2.ex:386`) has no cap and MWT sends no
  `SETTINGS_MAX_HEADER_LIST_SIZE`; up to 16 MiB of a host's answers per
  connection waits for a VM that doesn't read.
- *Evidence:* Proven: one stream awaiting its verdict held 64 MiB against
  1 MiB and 16 MiB windows (`egress/http2_window_probe.exs`); a 19 KB block
  decoded to 15,001 fields, 57 MiB sent upstream in 50 ms
  (`egress/http2_head_probe.exs`); 15 MiB held for a VM not reading
  (`egress/http2_flow_probe.exs`).
- *Fix:* FLOW_CONTROL_ERROR on an overrun; announce and enforce a decoded
  header-list limit; a smaller connection window.

<a id="n5"></a>

**5. HTTP/2 heads aren't read as strictly as HTTP/1.1's.** Misaligned,
guarantee 17.

- *Intended:* a stream's headers are read "as an HTTP/1.1 head's".
- *Happens:* `acceptable/2` (`http2.ex:1145-1186`) ignores `host` when
  `:authority` is there, and `List.keydelete` removes only the first;
  values aren't checked for CR, LF or NUL; `content-length` is never
  compared with the DATA sent.
- *Scenario:* a front end that routes by `Host`, or converts to HTTP/1.1,
  acts on another request than the card's; `Shown` turns the CR LF into a
  new line, so the card shows a fake `authorization:` line.
- *Evidence:* Proven, `egress/http2_head_probe.exs`: `host: evil.example`
  beside `:authority: api.example.com` went up; so did a value with
  `\r\nauthorization: Bearer injected`, and a `content-length: 0` with a
  body.
- *Fix:* refuse a `host` header unless once and equal to `:authority`;
  refuse CR, LF and NUL; refuse a `content-length` that differs from the
  DATA.

<a id="n6"></a>

**6. HTTP/2: bytes that could start a value are held with no 50 ms
release.** Bug.

- *Intended:* "held back only while the last of them could start the value,
  50 ms at most".
- *Happens:* `http2.ex:901-905` releases held bytes only at END_STREAM;
  `handle_timeout(:host)` (`:255`) doesn't.
- *Scenario:* a server-streaming gRPC call with a token (Firestore Listen):
  a message whose last bytes match the value's start waits for the next
  message, minutes later.
- *Evidence:* Proven, `egress/http2_hold_probe.exs`: the host sent 12 bytes,
  the VM got 10.
- *Fix:* a 50 ms host deadline while bytes are held, as HTTP/1.1 does.

**7. HTTP/2: a stream that ends early never gives its held data back to the
connection window.** Bug.

- *Happens:* RST_STREAM goes to `finish/3` (`http2.ex:357-366`, `:1087`),
  which drops what the stream held with no WINDOW_UPDATE on stream 0;
  `answer_self` does give it back (`:985`). A host's reset and streams a
  GOAWAY refuses leak the same way.
- *Scenario:* gRPC uploads cancelled by their deadline while they wait for
  approval: each leaks up to 1 MiB of the 16 MiB window; after about 16 the
  channel stalls.
- *Evidence:* Proven, `egress/http2_flow_probe.exs`.

**8. HTTP/2: every stream carrying a value registers the connection
again, with a timer of its own.** Risk.

- *Happens:* `tcp.ex:1004` calls `Gate.held_by` on every verdict; the
  registry allows duplicates and `Gate.check` sets a timer per call
  (`gate.ex:449-461`).
- *Evidence:* Proven, `egress/http2_held_by_probe.exs`: 200 calls, 200
  registrations for one connection.
- *Fix:* register once per connection and grant.

**9. HTTP/1.1: a kept link that fails under a write resends any method,
missing the middle of its body.** Bug, a rare race.

- *Intended:* resent only "when doing it twice changes nothing (GET, HEAD,
  OPTIONS, PUT, DELETE, with its whole body held)".
- *Happens:* `http1.ex:306-307` ignores `retry?` and whether the answer
  began; what it resends holds the head and the first 64 KiB (`:615`).
- *Evidence:* Proven, `egress/http1_resend_probe.exs`: a 200,000-byte POST
  failed after 120,072 bytes; the new link got the head and 150,000 bytes,
  the 50,000 between lost.

**10. A tunnel whose client half-closes never gets the host's reply.**
Risk.

- *Happens:* the sockets don't set `exit_on_close: false`; when the VM's
  side closes, `Raw` ends and closes both.
- *Evidence:* Proven on MWT's side, `egress/half_close_probe.exs`; whether
  msb passes the VM's FIN to the CONNECT stream wasn't checked.
- *Fix:* `exit_on_close: false`, and pass the half-close on.

**11. After an `Upgrade` the host doesn't take, the next request goes up
unjudged.** Bug. The threat model review lists the `Upgrade` header's
`Connection` handling; this is worse: a DELETE after a refused upgrade was
sent with no `{:judge}`, under MWT's head `connection: keep-alive, Upgrade`.
Proven, `egress/http1_upgrade_probe.exs`. *Fix:* hold back what the VM sends
until a `101` comes, and judge whatever follows another answer.

**12. Chunked request bodies are scanned with their chunk-size lines in
them.** Read, low. A placeholder or a real value split across two chunks
isn't found, unlike across WebSocket or HTTP/2 frames.

### The VM and its file copies

**1. One file that vanishes or can't be read during a sync fails the whole
sync, and the next one sends everything again.** Bug.

- *Intended:* "files changing during a copy" are sent again at the next
  sync.
- *Happens:* `@send` accepts the host tar's exit 0 or 1 only
  (`folder_sync.ex:211-214`); a file deleted after the scan makes it exit 2
  ("Cannot stat"). The VM has already put the rest in place, but `bring/8`
  marks the whole send unknown (`:359-365`).
- *Scenario:* `~/Documents` is shared while an editor makes and deletes lock
  files. The first copy of a few GB fails at the end; the next sends it all
  again and can fail the same way. A file you can't read (root-owned, 0600)
  would fail every sync for good (not shown: the probe runs as root).
- *Evidence:* Proven, `vm/folder_sync_vanish_probe.exs`: the sync
  failed on `~lock.report.odt#` with all 51 files already in the copy; the
  next, with nothing changed, sent all 51.
- *Fix:* `--ignore-failed-read`, or a vanished file treated as removed;
  only the paths that failed marked unknown.

**2. Locking or quitting MWT while the VM is Starting, Creating or
Recreating leaves it running.** Bug, guarantee 6.

- *Intended:* "Locking or quitting MWT stops the VM."
- *Happens:* `terminate` stops the VM only when `vm.exists?` and the status
  is `:running` or `:starting` (`server.ex:2018`). A start or create task
  changes only `busy` (`machine.ex:76`); the status stays `:stopped`. The
  task runs under the app-wide task supervisor with `async_nolink`
  (`state.ex:296`), so it outlives the server and boots the VM in its
  detached bubble. A first create (`exists?` false) is never stopped.
- *Scenario:* you click Start or Recreate, then lock: the VM and its agents
  run on, without internet, until the next unlock takes them back.
- *Evidence:* Read.
- *Fix:* in `terminate`, stop the VM whenever a VM task is in flight; or
  the task watches the server and stops the bubble when it goes.

<a id="v3"></a>

**3. A disk that failed to grow is never grown again.** Bug.

- *Intended:* sizes apply "at the next start, bigger only".
- *Happens:* `grow!` makes the file bigger first, then runs `e2fsck` and
  `resize2fs` (`disks.ex:208-218`); `ensure!` compares only the file's size
  (`:99-103`). After a failed check or resize, the next start finds the file
  big enough. Exit 1 from `e2fsck` ("errors corrected") is swallowed with
  its output, at growing and at reclaiming (`:167-169`), where `-y` may
  move files to `lost+found` unseen.
- *Scenario:* you raise Home to 32 GiB with the host disk nearly full;
  `resize2fs` fails, so the start fails; the second Start succeeds with the
  old file system size, while Settings says 32 GiB.
- *Evidence:* Proven, `vm/disks_grow_probe.exs`: after a check that
  failed with exit 4, the next `ensure!` returned `:ok` on a 2 GiB file
  holding a 1 GiB file system.
- *Fix:* compare the file system's size (its superblock) with the setting;
  show what `e2fsck` corrected.

**4. A chmod made while the VM was stopped, or across an MWT restart, never
reaches the copy.** Bug.

- *Intended:* "one whose ctime or inode moved is sent anyway".
- *Happens:* entries hold kind, size and mtime (`folder_sync.ex:137`,
  `:785`); the ctime and inode stamps live only in memory, start empty in
  `new/3`, and `ShareSync.reset/1` drops them at each start.
- *Scenario:* you `chmod +x tools/deploy.sh` with the VM stopped, then
  start it. The read-only copy stays non-executable: the agent gets
  "Permission denied" and can't fix it, until the file's content changes.
- *Evidence:* Proven, `vm/folder_sync_mode_probe.exs`.
- *Fix:* the mode in the entry (and `%m` in the VM's list), or the stamps
  kept with the sent record.

**5. Hard links in `from-vm/` block the whole copy back.** Bug.

- *Happens:* a hard-linked file passes `check/1`, but `@pack` lacks
  `--hard-dereference` (`copy_back.ex:84-88`; FolderSync's `@send` has it),
  so tar sends the second name as a link entry, which `TarReader` refuses
  (`tar_reader.ex:74-75`).
- *Scenario:* an agent's `cp -l`, or a pnpm-deduped tree in `from-vm/`:
  nothing lands, and the error names neither a file nor a rule.
- *Evidence:* Proven, `vm/copy_back_hardlink_probe.exs`.
- *Fix:* `--hard-dereference` in `@pack`.

**6. A failure after the VM is up is reported as a failed start, and the
boot is skipped.** Risk.

- *Happens:* the start resizes memory after `Bubble.start`
  (`machine.ex:107-110`; create at `:250-256`). If that fails, the VM runs
  but `boot/1` doesn't: no boot script, no ports watcher (no forwarding),
  no `/etc/mwt-vm`. A create's failure path also skips recording
  `created_spec`, `created_ref` and the VM's record (`:592-593`), so the page
  says "recreate to apply", `mwt vm` mismatches, and `Image.keep` protects
  the wrong image.
- *Evidence:* Read.
- *Fix:* once msb started the VM, a resize failure is a warning: boot, and
  record.

<a id="v7"></a>

**7. A failing boot script is only logged.** Risk.

- *Happens:* `machine.ex:330-338` sends it to `Logger.warning`; inside it,
  `timeout 60 claude mcp add-json` shares the outer 60 s `msb exec`, so a
  slow `claude` gets the whole script killed before memo, Zed's agents,
  Chromium's CA and the ports watcher.
- *Scenario:* servers in the VM never open on your machine, and nothing
  says why.
- *Evidence:* Read.
- *Fix:* the boot's result on the VM card; a budget per step.

<a id="v8"></a>

**8. A relay that doesn't answer within 2 s reads as stopped.** Risk.

- *Happens:* `Bubble.status` maps a timeout or an empty answer to `:down`
  (`bubble.ex:296-302`). One slow poll marks the VM stopped, stops
  forwarding, answers `mwt sync` "The VM isn't running", and forces a whole
  resync after. Then Start runs `prepare` (which may resize the disks of
  the running VM) before `Bubble.start` checks again (`machine.ex:101`,
  `bubble.ex:219`); if that check times out too, `kill_strays` power-cuts
  the running VM (`bubble.ex:224`).
- *Scenario:* a host under memory pressure answers late twice; you click
  Start on a VM that is running.
- *Evidence:* Read.
- *Fix:* only a refused or missing `control.sock` means down; check the
  bubble is down before `prepare`.

Smaller: Stop calls `Bubble.stop` before `Copying.drain`
(`machine.ex:115-116`), against "first wait for copies under way" (cut
copies fail cleanly); after a recreate, the forwarder keeps the old VM's
forwards up to 60 s.

### The firewall, the activity log and the pages

**1. Releasing without trusting isolates the VM again at once.**
Misaligned.

- *Intended:* Release ends the isolation and turns the grants back on;
  Trust is a separate choice, "for a rule that fired on something you
  know".
- *Happens:* `Server.Firewall.release/2` (`server/firewall.ex:309-349`)
  leaves the Watch's windows as they were, and `Gate.route/5` checks the
  upload window on every new connection (`gate.ex:695`): it still sums to
  4 MiB or more.
- *Scenario:* *Large upload* fires on `files.example`; you look and release
  without trusting. The agent's next connection to any `*.files.example`
  isolates the VM again: a new incident, a new notification, every grant
  off, for up to 10 minutes (the DNS rule likewise; scanning, 1 minute).
  The way out is a permanent, domain-wide Trust, or waiting.
- *Evidence:* Proven, `firewall_ui/release_reisolates_probe.exs`: after
  release, `Gate.route(…, "cdn.files.example")` refuses, and the second
  incident says "5.0 MiB sent to cdn.files.example", bytes that name never
  sent.
- *Fix:* on release, clear the incident's rule and key windows, in the
  Watch and in the server.

**2. *Large upload* isolates ordinary model traffic through cloud APIs, and
offers to trust the whole cloud.** Risk.

- *Intended:* the firewall stops a leak without stopping normal work. The
  model hosts trusted by default are `*.anthropic.com`, `*.claude.ai`,
  `*.claude.com`, `*.openai.com`, `*.chatgpt.com` (`firewall.ex:162`).
- *Happens:* requests MWT reads count toward the rule (`tcp.ex:939`). An
  agent sends its whole context each turn and gets a short stream back.
- *Scenario:* at 160 KiB up and 6 KiB back a turn, a turn every 15 s, the
  VM is isolated at turn 26 (6.5 minutes) when the model is reached through
  `us-east5-aiplatform.googleapis.com`, `bedrock-runtime.…amazonaws.com`,
  `generativelanguage.googleapis.com` or `openrouter.ai`. The dialog offers
  "Trust googleapis.com" (the folded domain), which spares
  `storage.googleapis.com` too, from every destination rule. `git push` and
  `docker push` through a token grant have the same shape.
- *Evidence:* Proven for the arithmetic, `firewall_ui/model_api_upload_probe.exs`
  (pure `Firewall.check/4`); the sizes per turn are an estimate.
- *Fix:* spare the hosts of a token grant that is on; offer Trust for the
  exact name, not the folded domain.

<a id="f3"></a>

**3. A failed journal write drops its events silently, and the Firewall
page makes the sandbox server wait on the journal.** Risk.

- *Happens:* `Journal.write/1` rescues the error, logs it, and throws away
  the batch, up to 1,000 events with their exchanges
  (`storage/journal.ex:272-287`). The journal has 2 connections and a 5 s
  busy timeout (`storage/database.ex:62`, `:89`); retention deletes 10,000
  rows a statement with cascading triggers, and Clear is big `DELETE`s.
  `Firewall.view/1` reads findings inside the server, through
  `Journal.flush` (`server/firewall.ex:88-102`), on every refresh of the
  page, every 150 ms while events come.
- *Scenario:* an hourly trim of a big journal, or a Clear, while the VM
  works: events, findings among them, vanish after the pages showed them;
  with the Firewall page open, swaps and approvals wait seconds.
- *Evidence:* Proven: with the write lock held 6.5 s, a firewall event
  shown live is missing afterwards (`firewall_ui/journal_drop_probe.exs`;
  held 1 s, it is there, `journal_drop_control_probe.exs`); with it held,
  `Sandbox.firewall/1` took 5,030 ms and an unrelated `waiting_count`
  behind it 5,019 ms (`firewall_ui/server_waits_journal_probe.exs`).
- *Fix:* keep the batch and retry it within a bound, logging a visible gap;
  read findings from the page's process, not the server's.

<a id="f4"></a>

**4. Figures from a sample, shown as figures for the whole.** Bug.

- The Activity page's figures cover the newest 20,000 events
  (`@stats_most`, `activity.ex:33`, `:98-103`) while the timeline and its
  text say "from the oldest kept to now" (`sandbox_live/activity.ex:494`).
  5,000 reads with 5 GiB up, then 20,000 lookups: "0 events, ↑0 B" above a
  log listing traffic rows. Proven, `firewall_ui/stats_cap_probe.exs`.
- The Overview's "Last hour" is counted from the newest 500 events
  (`sandbox_live.ex:2626-2638`): 40 blocked 20 minutes ago, then 600
  lookups, reads "0 blocked". It hides blocks exactly when the VM is busy.
  Proven, `firewall_ui/overview_counts_probe.exs`.
- *Fix:* count in SQL over the window, or say the cap on the page.

**5. Re-renders erase what exists only in the browser.** Bug; the server
side Proven, the browser side Read.

- *Intended:* "a list half edited stays as you left it while you look at
  another" (The Firewall page).
- *Happens:* the page re-assigns `firewall` on every render
  (`sandbox_live/firewall.ex:53`), and `list_panel` rebuilds its form from
  `draft || entries` (`:589-605`), a draft being kept only after a failed
  save. LiveView spares only the focused input, so a textarea that lost
  focus (another tab) gets the saved text back with the next event. The
  release dialog's Trust box goes the same way, and `<details>` without
  `JS.ignore_attributes(["open"])` close on any patch: the card's "Allow
  for a while" menu (`sandbox_live/approvals.ex:340`), the script folds
  (`:849`, `:993`), decided commands (`:1094`).
- *Evidence:* `firewall_ui/list_draft_probe.exs`: one unrelated finding
  re-sends the full text of both lists.
- *Fix:* `phx-change` keeps drafts and ticks in assigns;
  `ignore_attributes(["open"])` on those `<details>`.

**6. "N refused since" counts MWT's own monitor samples.** Bug.

- *Happens:* while isolated, every observation counts as refused
  (`server/firewall.ex:46-47`), the monitor's `{:processes, …}` every 5 s
  included (`monitor.ex:145`, `server.ex:1695`).
- *Scenario:* an idle isolated VM reads "720 refused" after an hour, as if
  it kept trying to get out.
- *Evidence:* Proven, `firewall_ui/refused_count_probe.exs`.
- *Fix:* count only what the VM sent.

**7. Trusting a tunnel's finding puts `host:port` on the trusted list,
which then can't be saved.** Bug.

- *Happens:* `tcp.ex:1267` reports `"dest:port"`, which becomes the
  finding's host (`firewall.ex:1115`), and release appends it unchecked
  (`firewall.ex:783-786`). The entry matches nothing, and trust spares no
  credential rule anyway.
- *Evidence:* Proven, `firewall_ui/trust_entry_probe.exs`: after "Trust
  paste.example.net:80", saving the list as shown fails, "Line 6 isn't a
  name or address".
- *Fix:* strip the port; offer Trust only for destination rules; check the
  entry on release.

**8. "Found lately" fills with your own setting changes.** Misaligned.
Every `:firewall` event counts as a finding (`server/firewall.ex:91`),
rule and list edits and releases included (`:140-151`): one finding, then 8
edits, and the finding is gone from the card. Proven,
`firewall_ui/overview_counts_probe.exs`. *Fix:* findings get a marker of
their own.

<a id="f9"></a>

**9. Release isn't tied to the incident you read.** Risk, Read.
`firewall_release` sends only `trust?` (`sandbox_live.ex:1433`,
`sandbox.ex:427`): an isolation that began between render and click is
released, and maybe trusted, unseen. *Fix:* send the incident's id, refused
on a mismatch.

**10. Scanning isolates on refused private addresses from normal work.**
Risk, Read. Five distinct refused private address:ports in a minute
isolate (`firewall.ex:987-1007`). With a split-horizon resolver (a known
gap) handing the VM internal addresses, an integration test touching
Postgres, Redis, Kafka and two internal hosts, while their grant is off,
turns every grant off though nothing left. *Fix:* Block, not isolate, by
default for refused private addresses.

**11. Turning off a grant that is already gone crashes the page.** Bug,
Read. `{:ok, _} = Sandbox.turn_off(...)` (`sandbox_live.ex:963-966`), and
`revoke_allowance` the same way, while both can answer
`{:error, :not_found}` (another window removed it).

### The agent's view, live

**1. `mwt why` answers "reached now" for any name no grant lists.**
Misaligned.

- *Intended:* agents are told to run it first "when a lookup fails or a
  connection is refused", to learn why.
- *Happens:* a name no grant covers is never looked up (by design), and
  the headline then takes the Internet's state as the answer
  (`why.ex:207-214`): `mwt why nonexistent.invalid` and
  `mwt why printer.local:631` both say "reached now".
- *Scenario:* `curl https://wiki.corp.example` fails because the name
  resolves to a private address; `mwt why` says it is reached, and the agent
  looks elsewhere or retries.
- *Evidence:* Live.
- *Fix:* for an unlooked-up name, a headline that says it depends on the
  address ("reached if it is public"), and the hint to run `mwt why` on the
  address it resolved to.

**2. The git-fetch grants still speak of `origin` and `upstream`.**
Misaligned. Since the remotes became `host-origin` and `remote-origin`
(53ebeb7), the *for* texts of `git-fetch` and `git-fetch-remote`
(`grant.ex:520-529`) still say "fetch from origin … and from upstream",
on the Grants page and in `mwt grants`, while the clone has no `origin`.
Live.

### Supervision

**A few crashes in a row lock the identity, and whoever shares its
partition.** Risk.

- *Intended:* the comment in `Server.terminate/2` accepts it: "If the
  restarts give up, the vault locks" (`server.ex:2014`). Guarantee 16 wants
  nothing the VM sends to make the sandbox fail.
- *Happens:* every per-identity store (the sandbox server, channel, DNS,
  egress, keyring, storage, notes…) is a child of one `DynamicSupervisor`
  partition with the default limit of 3 restarts in 5 s
  (`vault/store.ex:55`). Four crashes of any of them in 5 s end the
  partition, which shuts down every store in it: the identity locks, and
  so does any other identity hashed to the same partition.
- *Scenario:* any crash the VM can cause in the server (the 2026-11-21
  review found one; it is fixed) becomes, sent four times, a lock of all of
  MWT for you, and for your other identity if it shares the partition.
- *Evidence:* Proven, `lead/crash_blast_radius_probe.exs`: four kills of
  the server, then the keyring was down and the identity locked.
- *Fix:* the sandbox's processes under a supervisor of their own per
  identity, whose giving up stops the sandbox (and its VM) and says so,
  leaving the vault, the notes and other identities alone. Which boundary
  is yours to choose: what the sandbox lives and dies with.

## The probes

`test/review/qa_20261123/`, one folder per area (`handoffs`, `channel`,
`grants`, `egress`, `vm`, `firewall_ui`, `lead`), for the findings not
fixed yet. Named `*_probe.exs`, they stay out of the suite (which loads
`*_test.exs`, `test/review/` included; `mix.exs` only keeps the rest of
that folder from being warned about); run one by naming it:

    mix test test/review/qa_20261123/handoffs/based_on_task_probe.exs

Two kinds: most assert what happens today, so they pass while the bug is
there and fail once it is fixed; the `channel` probes and
`lead/crash_blast_radius_probe.exs` assert what is intended, so they fail
today (6 failures of 31 tests in all). Each says what it shows in its
first comment. Fixing a finding is a good moment to turn its probe into a
regular test.

- Run `lead/crash_blast_radius_probe.exs` alone: it locks every identity in
  its partition, so probes running beside it may fail for that reason.
- `handoffs/slot_race_probe.exs` is timing-dependent (the race showed in 2
  runs of 3).
- `firewall_ui/search_cost_probe.exs` and `watch_cost_probe.exs` measure,
  and show no bug.
