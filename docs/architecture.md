# How MWT works

The mental models behind MWT, and the decisions that would be costly to
make again without knowing why. It is the one document here, for people
and agents alike: what a module does is in its moduledoc, what it
promises is in its tests, and how it got here is in git. When this and
the code disagree, the code is right and this gets fixed.

What MWT is and how to use it is in the [README](../README.md).

## One app, several tools

- **A local web app in a desktop shell.** MWT is a Phoenix LiveView app
  that a Tauri window opens. Nothing of it runs anywhere but your
  machine: no account, no cloud.
- **Apps on a platform.** Each tool (HTTP client, diagrams, notes, flash
  cards, the Agent Sandbox) keeps its data and logic in a folder of its
  own under `lib/mwt_client`. What more than one app needs lives at the
  top, as the platform. An app uses the platform and never another app's
  folder: a piece a second app needs moves into the platform first.
  `lib/mwt_client/README.md` maps the folders.
- **Everything belongs to an identity:** a username and a password.
  Unlocking derives its key and starts its processes (its databases, its
  stores, the sandbox's server). Locking stops them, drops the key and
  stops the VM. Nothing of an identity runs while it is locked.

## Storage

**Two encrypted databases per identity,** in
`~/.mwt_client/identities/<id>/`, which differ in how they grow:

| Database     | Holds | Writes |
| ------------ | ----- | ------ |
| `library.db` | what you make: notes, diagrams, flash cards, their versions, small state | each save its own transaction, durable when it returns |
| `journal.db` | what happens: HTTP history and samples, the sandbox's activity log | batched about once a second: a power cut may lose that second, never consistency |

Memory is a bounded cache, not the store (each connection's page cache
is capped), so memory stays flat as data grows and a save costs what it
changes. Each kind of data has a retention rule of its own, and the
Storage page shows what everything takes, the VM's disks included.

**Keys:**

```
password ──PBKDF2-SHA512, 600,000 rounds──▶ password key ──seals──▶ the data key (vault.json), the verifier, exports
data key (32 random bytes) ──HMAC-SHA256(data key, "mwt:storage:<name>:v1")──▶ one key per database
database key ──SQLite3 Multiple Ciphers, ChaCha20-Poly1305 per page──▶ library.db, journal.db, their WAL and temp files
```

A password change re-seals the data key and re-encrypts nothing.

**Decisions:**

- **Pages encrypted by SQLite, not rows encrypted by MWT.** Rows MWT
  encrypted itself couldn't be searched or queried. exqlite links
  SQLite3 Multiple Ciphers in place of its own SQLite
  (`scripts/build-sqlite3mc.sh`, the flags in `mix.exs`). Search is FTS5's
  trigram tokenizer: every word, anywhere in the text.
- **A build that doesn't encrypt is refused.** Stock SQLite takes
  `PRAGMA key` without a word and writes plain text. So the first
  connection asks `PRAGMA cipher`, which only SQLite3 Multiple Ciphers
  answers, and the answer must be the cipher `vault.json` names.
- **Opening refuses rather than guesses.** The key is checked on one
  connection before a pool starts, since a pool retries a wrong key
  forever. A file the right key can't read is set aside as `.corrupt`
  and a new one made; any other failure fails the unlock and touches
  nothing.
- **No `auto_vacuum`.** Under an authenticated cipher it corrupted the
  FTS5 tables as they were created. Freed pages are reused by later
  writes, and Compact gives space back to the disk.

**Not covered:** plaintext in memory while unlocked (SQLite's page
cache, BEAM binaries), which only root reads (MWT's process isn't
dumpable: [Other programs on this machine](#other-programs-on-this-machine)); file sizes, which say how much you keep; an older
page put back by someone who can write your home folder (integrity is
per page, not per file); a data key that leaked, since it never rotates.

### Export and import

- **An export is one file,** `.mwtexport`, sealed (AES-256-GCM) with the
  identity's password key. Its header carries the KDF's parameters, so
  the password opens it on any machine. The header is read before
  anything is authenticated, so its iteration count is bounded: a crafted
  file can't ask for a derivation long enough to hang MWT.
- **Apps take part as participants** (`MWTClient.Transfer`), each with a
  versioned section. Every item goes through its participant's
  `prepare/2` before anything changes, and one bad section refuses the
  whole file.
- **What opening a file trusts is whoever held the key.** Past it, a file
  you made and one crafted by someone who gave you its password look the
  same. The sandbox's section brings what acts on this machine (saved
  commands' scripts, mint commands, grants that start on), and the
  preview names each before anything changes. Credentials' values travel
  only when you ask.
- **Backups are another thing:** copies of one identity's databases,
  which no other identity imports.

## The Agent Sandbox

Agents work in a [microsandbox](https://github.com/superradcompany/microsandbox)
microVM that MWT starts, watches and stands in front of. It is two things
in one: the **sandbox**, which makes letting an agent loop safe, and the
**control panel**, which makes working through a VM bearable. Most of
this document is about the first, because that is where a wrong
mental model costs the most.

### What it defends against

**Whatever runs in the VM, as root:** an agent following instructions
planted in a web page or a repository, or a package it installed. It can
do anything inside the VM and send any bytes on the channels it opens to
MWT. It isn't assumed to hold a working exploit against KVM or
microsandbox; if it does, the bubble decides what it reaches. Not
defended: what you approve, leaks of what you gave the VM, and other
programs running as you, beyond what
[Other programs on this machine](#other-programs-on-this-machine) says.

| Promise | Kept by |
| ------- | ------- |
| The VM never holds a credential | placeholders, which MWT swaps for real values on the way out |
| Nothing leaves the VM except through MWT, DNS included | the process running the VM has no network: its only ways out are MWT's sockets |
| Nothing the VM writes runs on your machine unless you chose it | work comes back only as a handoff you land, and landing runs no hook; shared folders are copied one way, in; every command an agent asks to run waits for you |
| A VM escape reaches no home folder and no network | the bubble msb runs in |
| An approval shows what will happen, with nothing hidden | facts MWT works out itself, the agent's words kept apart, hidden text written out |
| What you turned off stays off | a restart after a crash puts every grant back as it was (`UnlockState`); only unlocking starts grants from their start settings |

**Not covered, on purpose:**

- **Leaking what the VM has.** Outbound traffic is open by default, so
  an agent can upload anything in a shared folder's copy or a project's
  clone. The firewall isolates the VM on 4 MiB sent to one destination
  in 10 minutes; less, spread over many destinations or through a
  trusted one, still goes. So can data spelled into DNS names.
- **Code you run from a handoff you landed.** The commits are the VM's,
  and building them runs what they hold. Your review is the check.
- **A value MWT can't read:** in a connection it tunnels unread, or
  encoded before it is sent (base64, in pieces).
- **What survives in Home.** A planted `~/.bashrc` or agent hook
  outlives a recreate that keeps Home; starting empty is the real reset.

### The picture

```
VM ──all TCP──▶ msb ──CONNECT──▶ relay ──proxy.sock──▶ MWT's proxy ──▶ the Internet, a VPN, a LAN
VM ──DNS──────▶ msb ───────────▶ relay ──dns.sock────▶ MWT's DNS ────▶ this machine's resolver
VM ──vsock────▶ channel.sock ──▶ the agent channel: `mwt` (grants, request, call, run, why, handoff, mcp…), git fetches

MWT ──msb exec───────▶ the VM: boot, /mnt/mwt and shared folders copied in, slots, handoffs, samples
MWT, Zed ──msb ssh───▶ the VM: ports 4100-4199 forwarded here, Zed's remote project

msb and the relay run in a bubble (bwrap): no home folder, no network but loopback
the VM's three sockets let in only the bubble's processes (Sandbox.Peer)
```

**Six channels, each because msb offers nothing else for its job.** The
VM opens three (proxy, DNS, agent channel); MWT opens three (`msb exec`,
`msb ssh serve`, the relay's control socket). What the VM sends on its
three is decided and logged by MWT. What it answers on MWT's three is
the VM's word and read as such: output capped, numbers range-checked, a
handoff only commits you review. One channel would need a VM without a
network card, which msb doesn't offer.

### The VM

- **msb, confined.** MWT ships the stock `msb` release, never a fork and
  never one you installed, and runs it with the relay in a bwrap bubble:
  namespaces of its own, a seccomp filter, no home folder, no network but
  loopback, reaching MWT only over Unix sockets. On Ubuntu that is MWT's
  own copy of bwrap under an AppArmor profile the package installs.
- **msb, pinned.** One file, `scripts/microsandbox.pin`, names the
  release, its commit and the digests of the files taken as they are; the
  build checks every line of it against the source. Every msb command MWT
  runs is built in one module (`Msb.Commands`), so an update is checked in
  seconds against the new msb's flags (`mix test --only msb`) before a VM
  boots (`--only vm`). `mix microsandbox.update` moves the pin and writes
  what changed upstream, to read before building.
- **Disks, not writable folders.** The VM's Home, Cache and Work are ext4
  images that nothing on your machine mounts (`e2fsck` and `resize2fs`
  run in a bubble too). A folder the VM could write let a planted git
  hook run the next time you used git there, and a disk is several times
  faster.
- **Copies, not mounts.** Nothing of your machine is mounted in the VM.
  `/mnt/mwt` (MWT's CA, the placeholders, the `mwt` command, what agents
  are told) is copied into the VM's memory. Shared folders are copied one
  way and shown read-only at their own paths, synced when asked. A mount
  handed the VM what a repository keeps beside its code (`.git`, `.env`).
- **The workspace** (`~/mwt-vm`) moves files that aren't code, in two
  halves each written by one side only: `to-vm/` is yours; `from-vm/` is
  the VM's, copied out as plain read-only files, nothing executable.
- **The image is three layers:** MWT's base (Ubuntu, and what MWT runs in
  the VM), your layer, versioned, and MWT's final layer, which checks that
  what MWT needs survived yours. Built here with podman, nothing
  published.
- **MWT owns the VM's life.** It creates, starts and stops the VM, which
  stops when MWT quits or locks. Servers on ports 4100 to 4199 in the VM
  open on your machine by themselves.

### The network path

**The proxy reads each connection as far as it can, decides each
request, and puts a real value in only where a grant says.**

1. **The destination first.** Loopback, link-local, cloud metadata and
   this machine's own addresses are refused. Private ranges (a VPN, a
   LAN) open only under a network grant; public addresses under the
   Internet's.
2. **Then reading.** MWT ends TLS with its own CA, which the VM trusts,
   when the host names itself and MWT has a driver for what is inside
   (HTTP/1.1, HTTP/2); plain HTTP is read too. Each request is decided
   (`Policy.decide/3`), its placeholders swapped, sent, and its answer
   looked through for every real value MWT holds: an answer holding one
   is cut. Anything else is a tunnel, logged by host and bytes, with why
   it wasn't read. A host you set as *Don't read* is tunnelled, for
   clients that pin certificates.
3. **Every request is in the activity log** with what came back (up to a
   size, never a real value) and how it was decided.

Decisions behind it:

- **MWT's own HTTP reader, strict.** Bandit and Finch read leniently what
  MWT must refuse (a request two parsers could read two ways is refused
  whole), and neither takes a connection MWT decrypted. Each protocol is
  a pure driver (`Egress.Driver`); the core does the rest the same way
  for every protocol (`Egress.Tcp`).
- **The path never waits on the server.** Connections are decided from a
  view the sandbox's server publishes, so a busy server slows no lookup
  or connection.
- **DNS goes through MWT.** Every name is logged, a query aimed at another
  resolver gets no answer, and with the Internet off only names that
  network grants list resolve. A network grant's names are bound to
  MWT's own answers: an address opens under a name only when MWT's DNS
  gave that address for it.

### Grants: the mental model

**Terms:**

- **Action:** anything the agent does that leaves the VM. Not actions:
  work inside the VM; talking to MWT about grants (`mwt grants`,
  `request`, `why`, `propose`); you reaching into the VM.
- **Resource:** what exists and what you lock. A **channel** (a network,
  host commands, MWT's own tools) or a **credential** (a secret MWT holds
  and the VM knows only by its placeholder).
- **Grant:** gives uses of one resource while it is on. It has a name,
  *what it's for* in your words (agents pick grants by it, you approve by
  it), and a condition: on or off, until when, whether each use asks,
  how it starts with MWT.
- **Two kinds of grant, by who builds the action:**
  - **open use:** the agent builds it with its own tools (`gh`, `curl`,
    `psql`), and MWT checks each request as it leaves;
  - **fixed call:** a template you saved or accepted. The agent sends only
    values (`mwt call ID NAME=VALUE`), which must keep to the call's JSON
    Schema, and MWT builds the action: a **fixed request** (HTTP, over a
    credential) or a **saved command** (your script, on your machine).

**How MWT decides,** in one pure function of the grants, the use and the
clock (`Policy.decide/3`):

1. Each resource an action goes through needs a grant that is on and
   covers it. A request carrying your GitHub token goes through two: the
   credential and the network.
2. Within one resource, the most permissive grant counts: grants only
   give.
3. Across resources, the strictest answer wins: a refusal over an ask,
   an ask over a yes. Several asks make one card.
4. A lock refuses everything through its resource, whatever the grants
   say. MWT saves a manual lock or unlock before confirming it, and reads
   the saved locks when the sandbox server restarts. Isolation locks everything.

| The agent does | Grants it needs |
| -------------- | --------------- |
| `curl https://example.com` | the Internet |
| `mwt exec github -- gh pr view 12` | the Internet, and an open-use grant over GitHub listing `api.github.com` |
| `mwt call pr-view REPO=… PR=12` | the fixed request `pr-view`, and the Internet, as the agent's own request would |
| `psql -h db.office.lan` | a grant over the Office VPN covering `db.office.lan` |
| `mwt call kubectl-pods NAMESPACE=web` | the saved command, and host commands and its credentials unlocked |
| `mwt run -- 'kubectl get pods'` | *Commands agents write*: always asks |
| `git fetch host-origin`, `mwt mcp` | MWT's built-in grants over its own tools |

**What holds on every channel:**

- **A credential's real value never reaches anything the agent wrote.**
  It goes only into a request toward a host its grant names, into what
  MWT signs, or to a saved command's script you saved or approved.
  `mwt exec` gives a command placeholders, never values.
- **A fixed call goes through the same pipeline as the agent's own**
  (`Egress.FixedCall`), marked as a fixed call in MWT's memory, where
  nothing the VM sends can forge the mark. It covers the credentials it
  names, in what it builds and nothing else, and its request still
  leaves under the network's grants. Its HTTPS port must fit the grant's
  scope, and it uses the network's resolver and outbound interface where
  configured. The proxy checks the route before dialing and checks the
  grant again before inserting credentials. *Not
  chosen:* the VM sending a request MWT signed (a mistake in the check
  lets an altered request through), and a fixed call covering its
  network too (it let a call out with the Internet off).
- **MWT never infers a fixed call.** The agent names it by id; a command
  that equals a saved one is only a hint on its card.
- **Commands an agent writes always ask** and are never handed a value.
  No setting changes that. A saved command needs only itself, not this
  grant, or every saved command would ask.
- **A fixed call is only as narrow as its template.** Each is graded
  *Narrow*, *Wide* or *Open* (`Openness`, from what `ScriptRuns` reads of
  the script): a value that can become code, as in `bash -c "$P"`, makes
  it open use in disguise. The grade only warns, never decides. The
  files a saved command runs are pinned (`Pins`): changed since you
  looked, its next run asks and shows the change.
- **A credential is narrowed in one of two places:** on the token itself
  (a fine-grained token, enforced by the service, the strongest limit
  you have) or by a fixed call (enforced by MWT).

**Why the network is transparent and host commands aren't.** The VM's
only way out is through MWT, so on a network MWT stands in the path and
the agent's tools work as they are. Nothing in the VM runs on your
machine by itself, so there is no path to stand in: the agent asks
(`mwt run`, `mwt call`, `mwt mcp`) and MWT carries the action out.

**A credential is used in one of three ways:**

1. **Carried:** the VM holds a placeholder, which MWT swaps for the
   value on the way out, only toward the hosts and headers its grant
   names.
2. **Computed with:** the value signs and never leaves MWT. A result that
   is itself authority (a GitHub App's installation token, a JWT Google
   signed) is kept as a made value, with a placeholder of its own.
   Signing something to publish (a commit, a release) waits for a view
   that shows exactly what is signed.
3. **Handed over:** a saved command's script gets the value in a
   variable. From then on MWT can't see where it goes, which is why only
   a script you saved or approved gets one.

What MWT knows of a family of credentials (`bearer`, `github`, `google`)
is an adapter shipped with MWT (`Sandbox.Adapter`), never a plugin.

### Approvals

- **A card shows facts MWT worked out itself,** with the agent's words
  kept apart. Text that hides anything (a right-to-left override, a
  zero-width character) is written out where it enters MWT
  (`Sandbox.Shown`), and a script for your machine that hides anything
  is refused rather than shown changed.
- **An ask joins a waiting card only when it is the very same,**
  compared whole. Two requests whose body MWT holds only the start of
  never share one.
- **No rules by method or path built into MWT:** what a request does
  depends on the API. From a card you allow uses like this one, or every
  use of the grant, for a while.
- **Agents propose, you decide.** When no grant fits, an agent proposes a
  resource or a grant (`mwt propose`). It lands off and tagged, never
  with a value, an approval mode or a start setting, and is accepted
  only as its page showed it.

### Host commands

- **Move the work to where the value is,** not the value to the VM:
  agents send the smallest command that gets the raw data
  (`kubectl get pods -o json`) and do the rest in the VM. They learn your
  machine from `mwt host`, never by probing it.
- **MWT sees a host command's text, folder, output and exit status, not
  what it does while it runs.** A command run as you has your SSH keys,
  cloud logins and network in reach. A confined saved command runs in a
  bubble with an empty home, your tools read-only and only the
  credentials it names, but still on your network.

### The firewall

Approvals stop what you can see coming. The firewall watches what the VM
does with the access it already has: the shape of its DNS names, large
uploads, a placeholder going where its grant doesn't send it, a real
value in anything it sends, what it asks for after you declined. On the
first sign of trouble it isolates the VM: every resource locked, nothing
leaves through MWT until you release it. Its rules are pure
(`Sandbox.Firewall`); the server acts on them. It catches the obvious,
not a patient leak.

### Projects and handoffs

**The VM is a clone of your machine, as your machine is a clone of
GitHub.**

```
the VM                           your machine                  a Git server
/work/app ── host-origin ──▶     your repository ── origin ──▶ GitHub, …
  │          fetch, through MWT                                   ▲
  └───────── remote-origin ──▶ (as your machine fetches it) ──────┘
  ├─ slot-0 (the clone)
  ├─ /work/app.wt/slot-1
  └─ /work/app.wt/slot-2
        │ mwt handoff                       ▲
        └──▶ MWT's review store ── Land ────┘ (as it is, or as one commit)
```

- **Each remote is named for the level it reaches.** `host-origin` is
  your repository through MWT; `remote-origin` is its own remote as your
  machine fetches it. There is no `origin`: with one, `origin/main` meant
  your `main` in the VM and GitHub's on your machine, and everyone mixed
  them up.
- **A fetch brings your committed branches and tags, nothing else.**
  Configuration, hooks, other refs, ignored files and uncommitted work
  don't travel. Git on your machine reads the VM's objects without your
  configuration or hooks, follows no submodule and caps what it reads
  (`HostGit`).
- **A push is refused,** saying work goes back by `mwt handoff`: a push
  that answered "ok" while your branch didn't move would lie, and a
  handoff carries what a push can't (title, notes, checks, its thread).
- **The clone is the VM's.** MWT never moves or resets a branch there.
  The one it deletes is a task's, once its handoff landed with nothing
  done on it since.
- **Worktree slots** hold one task each: slot-0 is the clone itself, the
  others its worktrees. Builds stay warm and Zed's paths never move.
- **A review is someone's work as uncommitted changes in a slot.**
  `mwt review` puts a pull request, a branch or a commit on a branch
  `review-…` at where it parts from the branch it merges into, always
  named (`--onto`): projects merge into different branches. Your machine
  fetches a pull request's head (forks' too) into MWT's store, under Git:
  fetch from your remotes, and `remote-origin` serves it. That is all:
  it is no task, so the slot is taken while those changes are there and
  free once you discard them.
- **A handoff is a task's exact commit,** with a title and notes, sent
  only when you ask. `mwt handoff` does every step that needs no
  judgment: fetch, commit, rebase onto the base, run the project's
  checks, send. Until then the work stays uncommitted, for you to review
  in Zed.
- **Landing** is a fast-forward to the handoff's own commit, the one its
  checks ran on, when the branch hasn't moved; otherwise one commit on
  top. It moves the branch with a compare-and-swap, never over your
  changes, and no hook runs.
- **Commits are yours.** A clone takes your repository's `user.name` and
  `user.email`, and nothing in the history mentions the VM.
- **More work happens in the handoff's thread, in Zed.** MWT doesn't
  reach agent threads: Zed can't post into a given thread from outside,
  and the ACP proxy that did sat in every message for one use, so it was
  dropped.

### What agents in the VM are told

- **`priv/sandbox/agents.md` every session; a guide when a task needs
  one** (`priv/sandbox/guides/`, `mwt help TOPIC`). What agents read
  costs tokens on every turn, so both have byte budgets that
  `instructions_test.exs` checks.
- **Agents reach MWT only through `mwt`, over vsock,** with no setup and
  no token. MWT's notes, diagrams and flash cards come over MCP
  (`mwt mcp`) under three built-in grants: read, create, change. HTTP
  samples are added, never read, since your history holds the
  credentials you sent.
- **MWT's tools are open to agents in the VM only.** Agents work there,
  so an endpoint on this machine would be a second way in, with a token
  of its own, for agents that no longer run here.

## Other programs on this machine

MWT is one person's, on their machine: other accounts and other machines
get nothing of it, and programs running as you get as little as one
process of yours can keep from another.

- **Other accounts and machines.** The server listens on loopback and
  takes only loopback names (DNS rebinding). A session is a random token
  kept in memory, in a cookie signed with a key made at each start: one
  written into the app was the same in every copy. The release never
  starts as an Erlang node (`rel/env.sh.eex`): epmd listens on every
  interface, and the cookie, the same in every copy of a package and on
  the process's command line, let whoever reached it run code in MWT.
  Identities' folders and the VM's sockets are yours only.
- **Programs running as you** are you to the kernel. MWT keeps them out
  of two things:
  - its memory: its process isn't dumpable (`ProcessGuard`), so none
    traces it or reads it through `/proc`;
  - the VM's sockets: the kernel says which process connected, and only
    the bubble's get in (`Sandbox.Peer`), so connecting doesn't make a
    program the VM to MWT.

  Still in their reach: MWT's files (the VM's disks and msb's keys; the
  databases are encrypted), the VM the way Zed reaches it
  (`ssh mwt-sandbox`), the bubble's namespaces, which you own (from in
  there, the relay carries a program's connections as the VM's), host
  commands and the tools they run, and a window made to look like MWT's
  that asks your password.
- **Not chosen: MWT as a user of its own.** The kernel would keep your
  programs out of its files, memory, sockets and bubble, with nothing
  for MWT to get right, and a program running as you would reach only
  what the VM does, through Zed. It takes a system user and a service
  installed as root, a helper running as you for all MWT does with your
  account (host commands, git on your repositories, shared folders,
  notifications, Zed, updates), and a fake window still gets the
  password. Worth it once MWT should hold against a compromised account.

## Updates

A release tag builds the `.deb` and `.rpm` on GitHub Actions and signs
their `SHA256SUMS` with the release key (Ed25519). The installed app
installs an update only when that signature verifies with the public
key it was built with (`priv/release_signing_key.pub`), the package
matches its checksum, and it is MWT at the release's version
(`MWTClient.Updates`). An app built without the key checks no release.

## Where the promises are checked

- `test/mwt_client/sandbox/guarantees_test.exs`: the sandbox's
  guarantees, one test per sentence, each naming the gap it closed.
- `egress_leaks_test.exs`, `policy_test.exs`, `hostile_text_test.exs`:
  values, decisions and text the VM chooses.
- `vm_live_test.exs` (`mix test --only vm`): confinement, the network and
  disks, on a real VM.
