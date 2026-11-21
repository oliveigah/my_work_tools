# Agent Sandbox: work plan of 2026-11-21

How to take on what [todo.md](../todo.md) set aside this week and what the
[threat model review](20261121-threat_model_fable5.2_review.md) found, in
an order where each step leaves the code more coherent than before. It was
planned against `main` at `bc46c80`. Two findings were checked there again
and are still in the code: `Approvals.place/3` still matches two elements
(`server/approvals.ex:660`), and `MWTClient.Markdown` still renders remote
images with no Content-Security-Policy on the pages.

Your machine is Fedora (`mwt host`), so the Ubuntu AppArmor item is about
what the `.deb` installs for others, not about your own setup.

Each workstream has a prompt to start it with, for an agent and for you:
[20261121-sandbox_work_prompts/](20261121-sandbox_work_prompts/README.md).

## How to read it

- **Workstreams** (A to N) each build one thing the code doesn't have yet,
  or tighten one place every path goes through. Most findings and todo
  items become steps of one of them, so a fix lands where the next fix
  needs it.
- **Steps** (A1, B1, B2, …) are one task each: one slot, one handoff. Size is
  rough: S is a day or less, M is a few days, L is a week or more.
- **Rounds** say what runs at the same time: three steps per round, one
  per slot, none needing another in its round. Your review is the real
  limit, so the plan assumes three slots, not ten. The rounds and what
  each step needs first are in [the prompts' README](20261121-sandbox_work_prompts/README.md#the-order).
- [Coverage](#coverage) maps every todo section and every finding to its
  step, so nothing is dropped.

## What the building blocks are for

Each promise in the threat model should rest on one place in the code that
every path goes through. Today several rest on many places that each have
to remember. The workstreams build these:

1. **One way out.** Every connection MWT makes for the VM (a tunnel, a host
   MWT reads, a request subgrant's send) goes through one function that
   resolves the name itself, classifies the address, and applies the
   network grants and their way out. Today the tunnel path classifies and
   the read path doesn't (finding 4). Workstream C.
2. **One exchange pipeline.** An HTTP exchange MWT reads is framed in full
   before anything is decided, then goes through stages in a fixed order:
   unmask, review, swap, send; then on the way back: review, mask, check
   for real values. The review cards, the network grants' reading, masking
   and MWT answering requests itself (Google's token endpoint) are stages
   of it, not branches in `Connection`. Workstreams C and D.
3. **What the VM wrote is input to programs on this machine.** The review's
   attack-surface table lists them: git, `e2fsck`, MWT's pages, Zed's
   address, the monitor. Each one is either confined or hardened, and each
   has a test that says which. `HostGit` is already the one way git runs
   on the VM's objects; it gets a profile for them. Workstreams B, F and I.
4. **A crash is a clean reset, and nothing the VM sends causes one.** A
   restart after a crash puts every grant in its start setting, as a start
   does, and you are told. So a crash the VM could cause would undo what
   you turned off: the VM must not be able to cause one, and a test sends
   every channel command with hostile fields to show it can't.
   Workstream A.
5. **A decision binds to what you saw.** Your click carries a digest of
   what the card or the page showed, so what changed between your reading
   and your click isn't what gets accepted. Approvals have a digest
   already; proposed grants get one. Workstreams C and E.
6. **Who asks is a claim, so MWT binds what it can.** A thread is the one
   its `mwt-acp` connection opened, not an id an ask names, and a person at
   the VM's terminal is named as one. Workstream G.
7. **Positions are shown, not found by looking.** How far a slot is behind
   its base, and how your branch stands against its remote, are worked out
   once and shown wherever MWT speaks of them. Workstream H.

## Workstreams

### A. A crash is a clean reset

From finding 1 and the todo's crash on `mwt propose commands --dir`.
Decided: a restart after a crash is a clean reset, as a start is.

**A1 (S/M): the crash, the message, and the restart said.**

- `Approvals.place/3` matches both answers of `HostCommand.place/3`
  (`{:share, dir, _share}` and `{:home, dir}`).
- `Channel.serve_ask/3` says "locked" only when the store is locked;
  otherwise that MWT failed answering, nothing changed, and the reason is
  in MWT's log.
- A test that sends every channel command with hostile fields and checks
  the server is still the same process. It catches the next crash of this
  kind before an agent does.
- A restart after a crash stays a start (`Grants.start/1`), and is said:
  a crash leaves Gate's published view in place (`terminate/2` forgets it
  only on a deliberate stop, `server.ex:1727`), so a view found at init
  means one. You get a notification that grants are back at their start
  settings, and agents whose asks were lost hear that MWT restarted and to
  ask again, not that it is locked.
- Guarantee 16 cites the new test; a new guarantee: *a restart of the
  sandbox, after a crash as after an unlock, puts every grant in its start
  setting, keeps an isolation, and tells you*.

### B. Git on the VM's objects

From finding 2 and the landing and diff lines of the review.

**B1 (M): the fetch serves branches and tags only, and git runs on the VM's
objects without your config.**

- `GitTransport.request/1` accepts protocol v0 and v1 only, and
  `mwt-git-remote` never asks for v2. The `uploadpack.allow*InWant`
  options are enforced again.
- The review store's fetch sets `core.alternateRefsPrefixes` to
  `refs/heads/ refs/tags/`, so your stash and remote-tracking branches are
  never offered as `have` lines.
- `HostGit` gets a profile for work on the VM's objects (fetch into the
  store, diffs, the fast-forward): `GIT_CONFIG_GLOBAL=/dev/null` and
  `GIT_CONFIG_NOSYSTEM=1` (`Guest.git_env/0` has them already),
  `--no-textconv` and `--no-ext-diff` on diffs, no filters at the
  fast-forward. Check that landing as one commit still gets the project's
  identity, set explicitly.
- `git_transport_test.exs` asks for a hidden object under
  `GIT_PROTOCOL=version=2` too, and for a stash's id.
- New guarantee: *a fetch serves only objects your branches and tags
  reach, under every protocol version*.

**B2 (S/M): the review store.** The VM's objects reach your repository's
store only once the landing's checks pass (today they do at the click,
`handoff_store.ex:343-348`); a revision's ref is removed when its handoff
closes or lands, with a `git gc` now and then; past 100 records, closed
ones go first and open ones stay.

### C. One way out, and requests framed in full

From finding 4, finding 3, the firewall and DNS lines of the review, and
the "most specific grant" part of the todo's network grant section. C1 and
C2 both change `egress/connection.ex`, so they go one after the other.

**C1 (M): `Upstream`, the one place MWT connects for the VM.**

- A host MWT reads is connected to only at an address MWT resolved and
  classified: loopback and this machine's own addresses are refused; a
  private or reserved one needs a network grant that is on, its approval
  and its way out, as a tunnel does. `Connection.upstream/1`
  (`egress/connection.ex:557-576`) calls it instead of `:ssl.connect` by
  name.
- A request subgrant's send goes through it too (`saved_request.ex:524`
  checks no address class), and so does a CONNECT that names a host
  instead of an address, resolved only after the view, an isolation and
  the Internet's state were looked at.
- With the Internet off, a request with no placeholder to a token grant's
  host needs that grant on.
- When two network grants cover a name, the most specific entry wins (an
  exact name, then the longest wildcard), and on a tie the grant that
  asks.
- New guarantee: *MWT connects to a read host only at an address the VM
  could have been let through to*.

**C2 (M/L): framing first, then the card, then the stages.**

- No card until the declared body has arrived, up to 64 KiB; a request
  that doesn't send it within 10 s is refused (`read_at_least/4`,
  `egress/connection.ex:714-721`).
- Forwarding stops at the declared length or the last chunk. That closes
  the *Not covered* entry on what the VM sends behind a request MWT read.
- A request MWT couldn't describe gets no *Allow similar*; a cut body is
  said among the card's facts; the digest a waiting card is joined on
  covers the whole body read.
- The first bytes, read the same way: a ClientHello split over two TLS
  records is read whole; and a connection whose name can't be read (split,
  or sent after 1.5 s of silence) gets no pass from a rule keyed on the
  name: a network grant opened by a name refuses it
  (`name_mismatch/6` lets a connection with no name through today).
- The parsing leads of the review, since they are the same reader: HTTP/1.0
  with chunked bodies, a request with `Upgrade` keeping the client's
  `Connection`, `_method` in a query or a form and header names with
  underscores, `TRACE` and `CONNECT` in any case, GraphQL beyond
  `POST /graphql` exactly, Basic credentials in any case on the card.
- The stages, written down, once a request is framed: `Connection` calls
  a list of stages over a framed request and its answer, each one going on
  or answering itself, in the todo's order (out: unmask, review, swap,
  send; back: review, mask, check for real values). Today's card and
  `Egress.Response` move into it; D and E3 add stages to it instead of
  branches to `Connection`.
- New guarantee: *a card is made only from a request whose declared body,
  up to the limit, was read*.

**C3 (M): the firewall counts what goes out where it goes.** After C1 and
C2, since it needs the resolved address and framed bodies.

- Request bodies to hosts MWT reads count in the upload rule (today only
  tunnels call `Gate.upload/5`).
- Uploads are keyed by where they go (the resolved address and its
  registrable domain from a public-suffix list), not by the name the VM
  gave.
- With the firewall's switch off, plaintext tunnels are still looked
  through for real values: that check is a guarantee, not a rule.
- The review's thresholds (1,000 flows, the quarter returned, 10,000 keys)
  and `sts.<region>.amazonaws.com` on the credential endpoints.

**C4 (S/M): DNS.** Independent of C1 to C3 (`dns.ex` only).

- A UDP answer is checked for its source, id and question.
- A message cut after its name no longer crashes its task.
- Messages refused for their shape are logged, as guarantee 12 says.
- A name no grant lists whose answer holds a private or reserved address
  gets REFUSED, so a split-horizon resolver doesn't map your network for
  the VM.

### D. The exchange pipeline: reviewed and masked

The todo's "Every request through a network grant, read and reviewed" and
"Masking personal data". Both need C1 (MWT connects to private addresses
through the grant's way out) and C2 (framing, and the stages each of these
adds to).

**D1 (L): network grants read HTTPS.**

- A destination of a network grant has a mode: read requests, or connect
  only. Read is intercepted with MWT's certificate, and every request gets
  a card like a token grant's, with *Allow similar*.
- The connection card is decided after the ClientHello, so it shows the
  name asked for and the one MWT answered in DNS, not only the entry.
- A request MWT read is logged with an outcome of its own, `:read`, not
  `:tunnel` (`gate.ex:770`).
- What can't be read (a database, SSH, pinned certificates, mutual TLS,
  HTTP/2) stays connect only, and the grant says so per destination.

**D2 (M): the answer to you first.** An answer held until you release it,
shown decoded (status, headers, body up to a cap), the way a command's
output can come to you first (`output_to: :review`). Auto-approve releases
both halves.

**D3 (M/L): unmasking what goes out.** Can start once C2 is in, beside D1.

- Tokens you make from a person's id in MWT (deterministic: AES-SIV or a
  keyed table in the vault), shown and decrypted only to you.
- A token in a request becomes the real value only toward the hosts of the
  data's grant; anywhere else it is refused, as a placeholder going where
  its grant doesn't is.
- What comes back, until D4: the real ids unmasked into a request count as
  real values for its answer, so `Egress.Response` cuts a body holding
  one, as it does for credentials today.

**D4 (L): masking answers.** Patterns validated by check digits, fields by
an allowlist per host, a held answer when MWT can't decode it, and the
stream scanner's handling of a value split across reads
(`Egress.Scanner`). Last in D: it needs D2, and whether masked access is
enough is your organization's call.

### E. Where values come from: proposals, presentations, mints

The todo's metadata server, "Mints that take another grant's value" and
"Tools that mint Google credentials themselves", with the review's line on
proposed grants. E1 comes first: E2 and E3 widen what a grant can do, and
a proposal should be bound to what you read before it can carry more.

**E1 (S/M): proposals bound to what you read, and the metadata server
anywhere.**

- *Accept* sends a digest of what the proposal's page showed, and
  `save_proposed` refuses one that changed since (`server.ex:954-966`,
  `server/grants.ex:87-96`).
- A proposed `--mint` is shown as a script, with the hints a command's card
  has, and says that it will run as you on every mint, without asking.
- A proposal counts toward the activation asks.
- The metadata server's box shows when editing any token grant, not only
  when adding from the Google preset (`sandbox_live/grants.ex:2680`), and
  `mwt propose token` takes `--metadata-project` and `--metadata-account`
  (`Proposal.attrs/3`).

**E2 (M): a mint that takes other grants' values.**

- `with:` on a mint, as a command subgrant has; the values go in the
  environment.
- A reach of *mints only*, so a password grant never reaches the VM, and
  its page says what uses it ("Used by the mint of: Y"; "Mints with: X" on
  the other).
- Values fetched first; a chain allowed, a cycle refused at save.
- The mint runs confined when it takes values, and as you, as now, when it
  takes none.
- Expiry read from the answer (`expires_in`, a JWT's `exp`), and one more
  mint on a `401` from the grant's host.

**E3 (L): MWT answering Google's credential endpoints.** After C2 (it is a
stage that answers) and E2 (expiry from the answer, for a 5-minute ID
token).

1. `signJwt` answered by MWT for an account the grant names and an `aud`
   it lists, the JWT signed here on the way out. With the metadata server
   MWT has, this alone makes the first kind of tool work (IAP clients), so
   it ships first.
2. An `authorized_user` login file as a presentation, the token endpoint
   answered by MWT for its refresh token, and JWT-shaped placeholders with
   the real token's harmless claims. This makes the second kind work.

`:credential_mint` and `:credential_inbound` stay as they are; MWT's own
answers simply aren't the service's.

### F. MWT's pages and tools, on what the VM wrote

From finding 5 and the review's lines on Zed, `Shown` and MWT's tools.

**F1 (S): a Content-Security-Policy, and no remote images.**

- Every page gets `default-src 'self'; img-src 'self' data:;
  script-src 'self'`, with what LiveView's socket needs in `connect-src`,
  from the router's `put_secure_browser_headers`; the desktop shell sets
  the same instead of `"csp": null`. Check colocated hooks and any inline
  style against it.
- `MWTClient.Markdown` turns a remote image into a link.
- New guarantee: *MWT's pages load nothing from an address the VM chose*.

**F2 (S): the small checks.**

- Zed's address takes only an absolute path under `/work`, of plain
  characters (`zed.ex:58`).
- An `update_*` call that changes nothing goes through the read grant
  (`mcp/tools.ex:99-102`).
- `Shown` covers variation selectors, combining marks, the Unicode spaces
  and blank letters; process names and the firewall's incident text go
  through it.
- A forward connects, inside the VM, only to a loopback address or the
  VM's own, not to whatever address the VM reported (`ports.ex:187-193`).

**F3 (M): what the VM made, marked.** MWT's tools say who made an item, and
its page shows it; an HTTP sample the VM saved is marked until you open
it, and Send says when it points at loopback, a private address or a
metadata address; `mwt-create`'s limit counts items, not calls.

### G. Who asks

From the review's lines on agent threads and the channel, and the first
item of the todo's "Working in the VM yourself".

**G1 (M):**

- A handoff's note goes to the thread MWT bound to the slot when an
  `mwt-acp` connection opened it, not the thread id the ask claimed
  (`handoffs.ex:826-850`); an `mwt-acp` can't take over another's thread
  (`agent_threads.ex:295-327`).
- With no agent above `mwt`, the card says it is you, at the VM's
  terminal. It is decided the same way, under the same grants.
- While isolated, the channel answers what only reads; a request
  subgrant's call under way stops.
- The catch-up note MWT writes is bounded.

### H. Projects: the level said, the position shown

The todo's "Telling your machine from its remote" and the rest of "Working
in the VM yourself".

**H1 (M): positions and words.**

- `Slots.look/4` counts `origin/BASE...HEAD` per task in the script it
  already runs, and compares the clone's `origin/BASE` with your branch
  here; `HostGit` gives how your branch stands against its own remote.
- `mwt project`, the Projects page and the Handoffs page say "2 behind
  your main", "your main is 3 ahead of GitHub's"; MWT tells the thread
  holding a slot when its base moved.
- Everywhere MWT speaks (`agents.md`, `mwt project`, `mwt handoffs`, the
  pages), "your `main`" and "`main` on GitHub, as your machine last
  fetched it", never a bare `origin/main`. Renaming the remotes waits for
  the redesign.

**H2 (L): working by hand.** After G1 (a person is named as such).

- A working tree of your own per project (`/work/NAME.me`), never a slot.
- `mwt pull [BRANCH]`: fetch and fast-forward, refused with a reason when
  the VM's branch has commits of its own.
- `mwt handoff` asks for a title, opens `$EDITOR` for the body, and offers
  to make a branch that isn't a task into one.
- A section of `mwt help` for a person, and a page in the docs.

### I. The VM's image, its disks and the bubble

The todo's Docker and AppArmor sections, finding 6, and the review's lines
on seccomp and the bubble.

**I1 (M): Docker in the image, and the disks kept from inside the VM.** Both
change the image's boot and the Cache disk.

- Docker's static release in the image, with `iptables`, its data on the
  Cache disk, started with the VM or on the first use of its socket, and a
  setting to leave it out.
- Reclaiming with `fstrim` in the VM and growing with an online
  `resize2fs` after the file grew, so no `e2fsck` or `resize2fs` runs here
  on a file system the VM wrote. Check first that libkrun passes discards
  through to the image. If it doesn't, both tools run in a bubble like
  `msb-confined`'s, with the one image bound.
- Operations in the disks folder don't follow symlinks (`disks.ex:99`).
- The sentence "Nothing on this machine opens them" made true, or changed.

**I2 (M): the bubble on Ubuntu.**

1. A spike on msb: can it give the VM IPv4 without the default route? If
   so, the relay needs no capability, and the AppArmor profile and the
   bwrap copy go.
2. If not: only a root-owned `/usr/lib/mwt/mwt-relay` moves into
   `mwt-bubble`, a dpkg trigger on `/usr/bin/bwrap` refreshes the copy,
   and the copy is executable by an `mwt` group only.

**I3 (S):** on an architecture the seccomp filter isn't written for, the
bubble doesn't start, or the page says so; `msb load`, `ssh authorize` and
the relay's `msb` calls run under `timeout`; what MWT reads from the
bubble's own folder (`control.sock`, `start.out`, `relay.lock`) is read
with a size limit.

### J. A handoff's review on this machine

From the review's section "Review of a handoff" and its handoff lines. It
waits for your call on where the check is ([Decisions](#decisions-for-you)).
After B1, which changes the same diff code.

**J1 (M):**

- The scan for real values refuses when it can't read the handoff
  (`handoffs.ex:250-253`).
- Flags for symlinks, the executable bit, submodule links, and files that
  run by themselves: `.gitattributes`, `.gitmodules`, `.lfsconfig`,
  `.cargo/config.toml`, `AGENTS.md`, `CLAUDE.md`, CI workflows,
  `config/*.exs`.
- A cut diff, a failed file count ("unknown", not 0) and more than 250
  commits said in the decision panel.
- A commit's body, author, committer and signature shown.

### K. Host commands and subgrants

The review's lines on host commands. After C1, which takes the request
subgrant's send.

**K1 (M):**

- The names a parameter may not take cover the families that change how a
  tool runs (`PYTHONPATH`, `NODE_OPTIONS`, `PERL5OPT`, `RUBYOPT`, every
  `*_PROXY`, `KUBECONFIG`, `GIT_*`, `LD_*`), not a list of single names
  (`param.ex:67-69`).
- A `text` value `..` refused in a request subgrant's path; one time limit
  for the whole request.
- A confined command's folder compared with your home by real path.
- Output looked through for credentials before it is cut to its first and
  last 32 KiB.
- The long-script hint counts every line.
- Auto-approved calls that are running are capped.
- A confined command doesn't get a value while that grant's condition
  holds it off.
- The confined bubble gets the seccomp filter the VM's bubble has; that it
  shares this machine's network stays, said in the document, since the
  script is yours (`confine.ex:69-81`).

### L. Shared folders, and a workspace

The review's lines on shared folders, then the todo's "A workspace for
agents" and "Conflicts in shared folders' copies". Decided: every shared
folder goes one way, from your machine into the VM; the workspace goes the
other way only, from the VM onto your machine. No file changes on both
sides, so "Conflicts in shared folders' copies" is closed.

**L1 (S):** a bare repository and the target of `--separate-git-dir` are
treated as repositories (`folder_sync.ex:828`); a repository that appears
in a share removes what was copied of it from the VM; the refused
credential folders include `~/.claude`, `~/.codex`, `~/.cargo`, `~/.m2`,
`~/.terraform.d`, `~/.config/op` and browser profiles.

**L2 (S, with you): the workspace's threat model, before its code.** It is
the first way the VM writes onto your disk without a handoff you land, so
what it changes in the threat model is written and agreed first:

- Whether writing there is a grant of its own (a built-in one, with the
  usual states: off, ask at each sync with a card of what changes, auto).
- Who reads it here without a click: file managers' thumbnailers and
  desktop indexers parse new files; a shell prompt runs `git status` in a
  folder holding a `.git` (whose config can name a command), and direnv
  and mise read their files when you `cd` in.
- So which files are refused: dotfiles, or at least `.git`, `.envrc` and
  the files tools run by themselves; symlinks, hard links and special
  files; executable bits; names that hide something; past a size and a
  count.
- Where it lives: a folder MWT owns, never a symlink, outside every shared
  folder and every place an indexer looks.
- What a command or subgrant reading it says on its card.

**L3 (L): the workspace.** Last: it opens a new way onto your machine.

- First, the handoff's limits on files from the VM (a size cap, no
  symlinks or special files, executable bits dropped) move into a module
  of their own, which handoffs and the workspace both use, with what L2
  added.
- Then the workspace as L2 settled it: made by MWT, `MWT_WORKSPACE` on
  both sides, read-only on your machine (a change of yours is put back at
  the next sync), a part per task (`<project>/<task>/`, which needs G1's
  binding of threads to tasks), synced when it changes and before every
  command or subgrant runs here, and agents told to use it.

### M. The document

**M1 (S, now):** the parts of the review that only change
[agent_sandbox.md](../agent_sandbox.md):

- The attack-surface table: the programs here that read what the VM wrote.
- What the VM holds by default: notes, diagrams and flash cards through
  `mwt-read`, your OptMem copy, `host.md`, what came back through grants.
- The exceptions to "the VM never holds a credential": the agents' logins
  in Home, and what you type in the VM.
- The assumptions: an encrypted disk, one user, an architecture the filter
  is written for, an honest resolver, a global git config that is safe on
  the VM's files.
- The stale passages: file grants, "what was set aside", the 2026-11-16
  decision row, `*.claude.com` among the trusted destinations.
- A column in the promises table naming the guarantees that keep each one.
- *Not covered*: the agents' own logins; VM pages opened in your browser;
  remote images until F1; items the VM writes that agents here read;
  standing access given at a service; the upload rule keyed on a name,
  until C3.

M1 touches the threat model's section; the steps above touch the sections
of their own areas and add their guarantees at the end of the list, as it
asks. Every step updates its guarantee and adds its test; a *Not covered*
entry gets a test that pins the limit as it is.

### N. Diagrams: groups and order

The todo's diagram section. Nothing in the sandbox depends on it, and it
depends on nothing here: `assets/js/diagram_editor.js`, the MCP element
schema in `lib/mwt_client/mcp/catalogue.ex`, and `mwt://guides/diagrams`.
Order (forward, back, front, back) first, then the right-click menu, then
groups, since the menu is where groups are made.

## The order

The rounds, and what each step needs landed before it starts, are in
[the prompts' README](20261121-sandbox_work_prompts/README.md#the-order),
which you and the agents work from:

| Round | Slot 1: the network path | Slot 2: work in the VM | Slot 3: the rest |
| ----- | ------------------------ | ---------------------- | ---------------- |
| 1     | A1                       | F1                     | M1               |
| 2     | B1                       | E1                     | F2               |
| 3     | C1                       | H1                     | C4               |
| 4     | C2                       | I1                     | L1               |
| 5     | C3                       | G1                     | K1               |
| 6     | D1                       | E2                     | J1               |
| 7     | D3                       | H2                     | L2               |
| 8     | D2                       | E3                     | B2               |
| 9     | D4                       | L3                     | F3               |

Fillers, for an idle slot: I2, I3, N1 to N3.

Why this order:

- **A1, F1 and B1 first.** They are the findings an agent can use with the
  least: A1 by accident from any shared folder, and it turns your grants
  back on; F1 through a flash card, auto-approved, the moment you open it;
  B1 with one handoff and a git option. Each is small. F1 takes slot 2 in
  round 1 because E1 waits for A1.
- **M1 in round 1** so every later step adds its guarantees to a document
  that is already right.
- **E1, H1 and I1 next in slot 2** because you hit them at work: the
  proposed Google grant with no metadata server, the slot a commit behind
  that nobody saw, testcontainers.
- **Slot 1 is one chain.** Its steps change the same files
  (`gate.ex`, `egress/connection.ex`), so they go one after the other.
  Reading a network grant's requests (D1) means MWT connecting to private
  addresses, which only C1 does safely, and every new stage needs a
  request framed in full and the stage list C2 ends with.
- **The VPN-only production service** (D1) is the most wanted feature in
  the todo and the deepest: it waits for C1 and C2 because they are what
  make it safe, and it ships before masking because masking needs its
  answer review.
- **L3 last.** It opens a new way onto your machine; by then the ingest
  limits, the bound threads and the pages' CSP are in place. Its threat
  model (L2) is a document, settled with you in round 7.

## Decided on 2026-11-21

1. **A crash is a clean reset** (A1): every grant back at its start
   setting, as at a start; an isolation stays. The defence is that nothing
   the VM sends crashes the server, and that you are told when it
   restarts.
2. **A handoff's check** (J1, M1): you review in Zed, and the threat model
   says that Zed shows what the VM's server tells it. The Handoffs page
   stays small: J1's flags and warnings, no review tool before the
   redesign.
3. **The remotes keep their names** (H1): words in every message now,
   names in the redesign.
4. **One way each** (L): every shared folder goes from your machine into
   the VM only; the workspace goes from the VM onto your machine only.
   Whether writing there is a grant of its own is L2's question.
5. **Proposed mint commands are allowed** (E1), shown as a script and
   accepted only as you read them.
6. **Masked access to personal data is enough for now** (D3, D4).

## Leave for the redesign

- The remotes' names, and MWT's Git tool on the VM's repositories.
- The Handoffs page as a review tool.
- Pacing the approvals: a first use of a destination marked as one, a
  pause when cards come faster than they can be read.
- HTTP/2 on hosts MWT reads, and everything under *Later* in
  `agent_sandbox.md`.

## Coverage

| Source                                              | Step       |
| --------------------------------------------------- | ---------- |
| todo: Conflicts in shared folders' copies           | Closed by decision 4; M1 removes it |
| todo: The bubble's AppArmor profile on Ubuntu       | I2         |
| todo: Telling your machine from its remote          | H1, redesign |
| todo: The metadata server on grants not from the preset | E1     |
| todo: Tools that mint Google credentials themselves | E3         |
| todo: A workspace for agents, on your machine       | L2, L3     |
| todo: Mints that take another grant's value         | E2         |
| todo: Every request through a network grant         | C1 (most specific grant), D1, D2 |
| todo: Masking personal data                         | D3, D4     |
| todo: Proposing with a folder in a share crashes    | A1         |
| todo: Docker in the VM                              | I1         |
| todo: Working in the VM yourself                    | G1, H1, H2 |
| todo: Diagrams: groups and order                    | N          |
| Finding 1: crash and grants reset                   | A1         |
| Finding 2: objects served by id under v2            | B1         |
| Finding 3: "No body" for a late body                | C2         |
| Finding 4: token grants' hosts skip network checks  | C1, C3     |
| Finding 5: remote images in Markdown                | F1         |
| Finding 6: disk tools on the VM's images            | I1         |
| Smaller gaps: proposed grants                       | E1         |
| Smaller gaps: Open in Zed                           | F2         |
| Smaller gaps: MWT's tools                           | F2, F3     |
| Smaller gaps: handoffs' scan                        | J1         |
| Smaller gaps: shared folders                        | L1         |
| Smaller gaps: DNS, TLS name                         | C4, C2     |
| Smaller gaps: upload rule, firewall off             | C3         |
| Smaller gaps: text that hides                       | F2         |
| Smaller gaps: confined commands' network            | K1         |
| Smaller gaps: seccomp, the bubble                   | I3         |
| Smaller gaps: landing                               | B1         |
| Smaller gaps: Upgrade                               | C2         |
| Smaller gaps: port forwarding's address             | F2         |
| Stale passages, threat model gaps                   | M1         |
| Leads: connections and DNS                          | C1, C3, C4 |
| Leads: intercepted requests                         | C2, C3     |
| Leads: host commands and the agent channel          | K1, E1, G1 |
| Leads: shared folders and handoffs                  | L1, B1, B2, J1 |
| Leads: firewall, tools, forwarding, threads         | C3, F3, G1 |
| Leads: the bubble                                   | I1, I2, I3 |
