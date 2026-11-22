# To do

Features set aside, with what is known about them, so they can be picked up
again without starting over.

Port forwarding from the VM, set aside on 2026-11-13, was built on
2026-11-15: see "Servers in the VM, on your machine" in
`docs/agent_sandbox.md`.

The metadata server on grants not added from the Google preset, set aside
on 2026-11-19, was built on 2026-11-21: see "Presentations" in
`docs/agent_sandbox.md`.

Tools that mint Google credentials themselves, set aside on 2026-11-19,
were built on 2026-11-22: see "Credential endpoints MWT answers" in
`docs/agent_sandbox.md`.

## Conflicts in shared folders' copies

Set aside on 2026-11-18. Shared folders reach the VM one way, read-only
there (`MWTClient.Sandbox.ShareMounts`), on the assumption that agents never
change a file git doesn't manage: what they change lives in a project's
clone, and comes back by handoff. So a file can't change on both sides, and
a sync simply puts your version in place.

If agents ever need to change shared files outside a repository, the copy
becomes writable and a file can change on both sides between syncs. Then a
sync needs a rule for it. What is known:

- `FolderSync` already tells the VM's changes from yours: what it last sent
  per VM is kept (`…/sandbox/sync/`), and the VM's file list is compared
  against it at a whole comparison.
- Until 2026-11-18 a share's copy was writable, and the VM's version of a
  path you changed was moved to `/work/.rescued/TIME/PATH` before yours
  replaced it (git history before the read-only change: `@prepare` in
  `folder_sync.ex` with a rescue folder). That never lost the VM's work,
  but nothing showed it, and nothing brought it back to you.
- Bringing a change back to your machine is the larger question: today
  nothing of the VM is ever written there but by a handoff you land.

Decided on 2026-11-21: shared folders stay one way, from your machine into
the VM. What the VM makes comes back by handoff, or through the workspace's
`from-vm/`, which goes the other way only ("The workspace" in
`docs/agent_sandbox.md`).


## The bubble's AppArmor profile on Ubuntu

Set aside on 2026-11-19, for the sandbox's redesign. On Ubuntu 24.04 and
later, a process in a user namespace may hold capabilities only when an
AppArmor profile says so, and Ubuntu's own profile for `/usr/bin/bwrap`
gives what it starts none. MWT's relay needs two in the bubble:
`CAP_NET_ADMIN`, once, to add a default route into loopback (msb gives the
VM IPv4 only when a public address has a route), and `CAP_SETPCAP`, to then
drop every capability. So `scripts/deb/postinst.sh` copies the system's
bwrap to `/usr/lib/mwt/bwrap` and installs `/etc/apparmor.d/mwt-bwrap`,
modelled on Ubuntu's `bwrap-userns-restrict`, whose child profile
(`mwt-bubble`) keeps those two and refuses the rest. See "Which bwrap" in
`docs/agent_sandbox.md`.

The approach is a standard one: libkrun asks for its VMM to be confined in
namespaces, since the guest reaches whatever the VMM can; Anthropic's
sandbox-runtime for Claude Code is bwrap and a proxy on Linux; and an
AppArmor profile is Ubuntu's way to allow user namespaces, which it ships
for other applications, some with every capability. What is weak:

- **A generic bypass.** `allow pix /** -> &mwt-bwrap//&mwt-bubble` gives
  `CAP_NET_ADMIN` to whatever the copy starts, and the copy is
  world-executable: any local program can get it in a user and network
  namespace of its own. That is what nf_tables privilege escalations need
  (CVE-2024-1086 among them), the attack surface Ubuntu's restriction
  aims at, and why Ubuntu's own bwrap profile strips the capabilities.
  It gives no root and nothing over the machine's network. In perspective:
  Qualys published three bypasses of the restriction in 2025 (`aa-exec`,
  busybox, `LD_PRELOAD`) that give every capability, and Debian and Fedora
  don't restrict user namespaces at all; still, the hole is MWT's and
  needn't be there.
- **A stale copy.** The copy is refreshed only when MWT is installed again,
  so a bubblewrap security update doesn't reach it until then.
- **From source, a root script in a repository agents change.** Read
  `scripts/deb/postinst.sh` before running it again after landing a
  handoff that touches `scripts/`.

What could be done, best first:

1. **Need no capability.** The route is there only for msb to give the VM
   IPv4. If msb can be made to without it (an option, or another way to
   get there), the relay needs no capability, and the profile and the copy
   go: MWT would use the system's bwrap on Ubuntu too.
2. **Scope it to the relay.** Let only MWT's relay, installed root-owned
   (`/usr/lib/mwt/mwt-relay`), move into `mwt-bubble`; anything else the
   copy starts gets no capability, as under Ubuntu's profile. A local
   program could then only run the relay, which adds its route and drops
   its capabilities. Runs from source build the relay in the checkout, a
   path the profile can't trust, so the script would install it too, or
   development keeps the wider profile.
3. **Keep the copy current.** A dpkg file trigger on `/usr/bin/bwrap`
   makes `postinst.sh` copy it again whenever bubblewrap is updated.
4. **Keep other accounts out.** The copy executable only by an `mwt`
   group: other users can't use it, but code running as you still can.

## Telling your machine from its remote, in the VM's Git

Noted on 2026-11-19. The VM's clone is a clone of your repository the way
your repository is a clone of its remote (GitHub, say), and that model
keeps things simple. But the names don't say which level they mean:

- In the VM, `origin` is your repository on your machine
  (`mwt::<project id>`), and `upstream` is your repository's own remote, as
  your machine last fetched it (`mwt::<project id>/upstream`). On your
  machine, `origin` is that remote. So `origin/main` is your local `main`
  in the VM and GitHub's `main` on your machine.
- `upstream` already means something else in most Git workflows: the
  repository a fork was made from.
- Agents, messages and you mix them up: "solve the conflicts with host
  master" meant your `main`, which the VM calls `origin/main`; "their main"
  in `mwt handoffs` means the same.
- An older mirror called your repository `host`; it became `origin` so that
  Git's defaults and every tool's habits (`git pull`, `origin/HEAD`, an
  agent reaching for `origin`) just work. Any new name gives some of that
  up.

Ideas, not settled:

- Name the remote branch views after where they are: `upstream` becoming
  something that says "your machine's remote" (`remote`, or your remote's
  own name under a prefix, such as `host-origin/main`), keeping `origin` as
  your machine.
- Say the level in words wherever MWT speaks: `mwt project`, `mwt
  handoffs`, the Projects and Handoffs pages and the agents' instructions
  saying "your `main`" and "`main` on GitHub, as your machine last fetched
  it", never a bare `origin/main`.
- Show how the two levels stand: your `main` ahead of or behind its remote
  (not pushed after a landing, not pulled before a task starts), so a task
  isn't based on a `main` you haven't caught up yet.

Decided on 2026-11-21: the names stay until the sandbox's redesign; until
then, MWT's messages say which level they mean.

## Cleaning up the VM's branches

Noted on 2026-11-21. Every task is a branch in the project's clone
(`mwt worktree new`), and nothing removes one: freeing a slot keeps its
branch, and MWT promises never to move, reset or delete a branch there
(`priv/sandbox/agents.md`, "The VM's clone" in `docs/agent_sandbox.md`).
So they pile up, task after task.

Wanted: **every couple of days, MWT removes the branches whose work has
landed, or that hold nothing, and never one that isn't safe to delete.**

What is known:

- **Merged isn't always visible to git.** A handoff landed as one commit
  leaves the branch's commits off your branch, so `git branch --merged`
  misses it. MWT's handoff records know: a branch whose tip is a revision
  that landed has nothing more. A branch whose tip your branches reach
  (`origin/*`) is merged as git sees it; so is a task that never committed
  (a question, a review), whose tip is its base.
- **Never deleted**: a branch a slot holds; one whose handoff is open or
  was sent back; one with commits that no landed revision and none of your
  branches hold, however old, since that work would be lost.
- **It changes a promise**: the agents' instructions and the document
  would say which branches MWT deletes, and when.
- **The same on your machine**: MWT's review store keeps a ref per
  handoff revision and only grows (the threat model review of 2026-11-21);
  the refs of landed and closed handoffs could go in the same sweep.

## Mints that take another grant's value

Set aside on 2026-11-19. A mint command gets only `MWT_GRANT`, and
`MWT_HOST` when minted per host (`Values.with_value/4`,
`server/values.ex:219`), so it can't use a secret MWT keeps. A service
whose tokens come from a login (a username and a password, or an API key,
exchanged at its auth endpoint for a short-lived bearer) then has three
ways today, none good: the password lives outside MWT for the mint to read
(a keyring, a file), with nothing on MWT's side showing it; a request
subgrant logs in, and its answer brings the token into the VM (stopped by
`:credential_inbound`); or you mint by hand and paste the token, again
whenever it expires.

The idea: **a mint that names the grants it takes**, as a command
subgrant's `with` does (Confined commands in `docs/agent_sandbox.md`):
the password is a token grant of its own, stored in your vault, and the
token grant's mint gets its value under that grant's variable, in the
environment, never the arguments.

What it would take:

- **A grant that reaches only mints** (and subgrants): never the VM, the
  way `--subgrants-only` keeps one out of it today; a reach of its own, so
  its page says what uses it.
- **Values fetched first**: a stored value, or one minted itself, before
  the mint runs; a chain is allowed, a cycle refused when the grant is
  saved; one that can't be fetched fails the mint, and the agent hears
  which.
- **The mint runs confined when it takes values** (no home, its own PATH,
  the values only), while a mint that takes none keeps running as you for
  your logins, as now.
- **Its expiry from the answer**: a login answer usually says how long the
  token lives (`expires_in`), so a mint can print it as it is, or MWT reads
  a JWT's `exp`; and a `401` from a grant's host could mint again once,
  instead of waiting out the keep time.
- **Shown on the card and the grant's page**: "Mints with: X", and on X's
  page, "Used by the mint of: Y", so you see where a password goes.

Decided on 2026-11-21: an agent may propose a mint command. It is shown as
a script, and accepted only as you read it: today a proposal's Accept
isn't bound to what its page showed (the threat model review's smaller
gaps), so a change between your reading and your click would go through.

## Every HTTPS request read by MWT, network grants' included

Noted on 2026-11-21, with the network grant section of 2026-11-19 (below)
as its first case.

The idea: **MWT terminates every TLS connection the VM opens**, not only
those to a token grant's hosts, so it reads, logs and can stop what goes
out to any host. Hosts whose clients pin certificates or use mutual TLS go
on a list of hosts MWT connects to without reading. This revisits a choice
in `docs/agent_sandbox.md`, whose list of threats says that "reading every
TLS connection would break clients that pin certificates".

What is known:

- The VM already trusts MWT's certificate authority, which signs the
  certificates of the hosts MWT reads today; `Gate.route` chooses, per
  connection, to read it or tunnel it.
- It puts every connection on the path MWT reads, which the threat model
  review of 2026-11-21 (`docs/dated/`) found weaker than the tunnel's. So
  these come first:
  - a host MWT reads is connected to by name, with no address check
    (finding 4): a token grant listing an internal name opens it without a
    network grant, the Internet off included;
  - a card can be made before the request's body arrived, and say "No
    body" (finding 3);
  - the firewall's upload rule counts only tunnels (`Gate.upload/5`).
- What breaks unless it is listed or supported: pinned certificates,
  mutual TLS, HTTP/2 and gRPC (MWT reads HTTP/1.1 only). Every byte is
  decrypted and encrypted again on this machine, and the exchange log
  holds far more.
- Reading isn't asking: a card for every request on the Internet would
  bury you. The grant's approval mode can keep deciding what gets a card,
  and the rest is read by the firewall and logged.
- One list could serve both cases: the hosts left unread on the Internet
  (a pinned client) and a network grant's destinations MWT can't read (a
  database, SSH), rather than a mode per destination and a list beside it.

**On a network grant**, set aside on 2026-11-19. A network grant is asked
about a connection, not a request: `Connection.run/3` approves it in
`destination/5`, before the TLS handshake, so its card says "Connect to
10.x.y.z:443", the entry it matched ("Listed as") and the grant, and
nothing of what goes through.
What happens next depends on the host:

- **A token grant lists the name**: `Gate.route` intercepts, and a request
  carrying the placeholder gets a card with the whole request (method,
  URL, headers, where the credential is). A request carrying none is read
  but goes out with no card (`Policy.decide/3` answers `:pass`), logged
  afterwards as "Read by MWT, no credential in it".
- **None does**: a tunnel of bytes MWT never reads.

So for a service on a private network, often production, the one gate is
a card that doesn't say what is done there.

Wanted: **every request to a host a network grant opens is read in plain
text and reviewed in plain text, and its answer is checked too**, as a
command's output can come to you first (`output_to: :review`,
`server/host_runs.ex:408`).

What it would take:

- **Read every HTTPS request on such a grant**: intercepted with MWT's
  certificate, as a token grant's hosts are, credential or not. Each one
  a card like a token grant's request card; "Allow similar" (method and
  endpoint) still there for repeats.
- **The answer to you first**: held until you release it, shown decoded
  (status, headers, body up to a cap), as a command's output can be;
  release, or keep it from the agent. `Egress.Response` already reads
  answers to requests MWT put a value in; this reads them all.
- **On hosts MWT reads already, the data is there**: the Proxy activity
  record of a request with no credential in it holds the whole exchange
  (`Exchange`: method, URL, headers and body with its size and whether it
  was cut, and the answer's status, headers and body), written after it
  went out. The cards above are that record shown before: the request
  from `Exchange.request/1` while `Gate.authorize/2` waits for you instead
  of answering `:pass`, the answer from the same capture held before it
  is sent on. What is missing is only for tunnels: reading them at all.
- **The log's outcome says "tunnel" for a request MWT read**:
  `Gate.authorize/2` logs `outcome: :tunnel` with the summary "Read by
  MWT, no credential in it" (`gate.ex:770`), so the record says both. An
  outcome of its own (`:read`) would tell it from a tunnel MWT never
  read.
- **Not HTTP, not readable**: a database, SSH or any protocol MWT can't
  read stays a connection card, and the grant says so per destination
  (a mode per port: read requests, or connect only), so nothing reachable
  is silently unread. A client that pins certificates or uses mutual TLS
  fails when intercepted; HTTP/2 and gRPC are out as on token grants
  (HTTP/1.1 only).
- **The connection card itself**: decided after the TLS ClientHello, so it
  shows the name asked for (SNI) and the one MWT answered in DNS, not
  only the entry the address matched. Its "Listed as" line is that entry
  (`spec.source`, `Policy.decide/3` for `{:connection, …}`): with a
  wildcard destination (`*.internal.example:443`) every card reads the
  same, an address and the wildcard, and you approve a connection without
  knowing which host under it is asked for.
- **The most specific grant should win**: when two network grants cover a
  name (an exact `dev.internal.example:443`, and `*.internal.example:443`
  on another grant), MWT takes the first in its list whose way out routes
  the address (`Enum.find(candidates, &way_out?/2)`), not the most
  specific. With two VPNs on two interfaces the route sorts it; on one
  interface the list's order decides, so the exact grant's approval mode
  (auto-approve, say) may be passed over for the wildcard's (ask). Pick
  the most specific entry first (an exact name, then the longest
  wildcard), and on a tie the grant that asks.
- **Kept in the exchange log** (`Exchange`), request and answer, as for
  token grants, so what went to the service can be read back later.

Found on a VPN-only production service: the request carrying a token
grant's placeholder got its full card, and the same request without one
went out after a connection card that showed only the address, the entry
and the grant.

## Masking personal data in what comes back to the VM

Set aside on 2026-11-19. Work on services that take a person's national
id (a CPF, say) as input can't be handed to an agent without the agent
seeing those ids, and everything the services answer about the person. A
grant per person is no answer: the ids aren't known in advance, and there
are many.

The idea: **MWT masks what comes back, and unmasks what goes out**.

- **Answers masked**: every answer on a host MWT reads (a token grant's,
  and a network grant's once it reads them, see "Every HTTPS request read
  by MWT"), and every command or subgrant output, is scanned for patterns
  (an id, with and without punctuation, validated by its check digits so
  that any 11 digits don't match; an email; a phone), and each match is
  replaced by a token, `mwt:cpf:Xb3k…`.
- **The same value, the same token**: deterministic (AES-SIV, or a keyed
  table in the vault), so the agent can follow one person across answers
  and services, and never learns who it is.
- **Requests unmasked**: a token in a request going out (path, query,
  body or header) becomes the real value again, only toward the hosts the
  data's grant lists; anywhere else it is refused, as a placeholder going
  where its grant doesn't is (`:credential_leak`).
- **Yours to read**: decrypt one token, or many at once (paste a text, a
  report, a handoff's body: shown with every token decrypted, to you
  only); and encrypt one, to hand the agent a person to look at ("person
  `mwt:cpf:Xb3k…` fails on this API: check it").

**A first step, before masking answers: unmasking only what goes out.**
You encrypt a person's id in MWT and hand the agent the token; the agent
writes the calls with it, and MWT decrypts it on the way out, toward the
data grant's hosts only. That alone lets you say "run this for person
`mwt:cpf:Xb3k…`" and have the agent build and send the requests, without
the id ever entering the VM. What comes back isn't masked yet, so it
needs one of:

- the answer to you first, with the agent getting only what you release
  ("Every HTTPS request read by MWT", on a network grant);
- the agent getting the status, the timings and the headers MWT allows,
  never the body;
- the body cut whenever it holds the id itself, as an answer holding a
  real value is today (`Egress.Response`), which most answers about a
  person do.

The decryption on the way out is the half that is the same whatever
masking answers becomes, so it can come first; and the agent learns from
it how the calls are made, which a person's id doesn't change.

**The order, both ways**, with the reviews of "Every HTTPS request read
by MWT":

1. Out: the agent's request → **unmask** (tokens become the real ids) →
   **your review** → **placeholders swapped** for the grants' real values
   → the service.
2. Back: the service's answer → **your review** → **mask** (ids become
   tokens, fields by their rules) → **the check for real values** (one
   in a head becomes its placeholder, one in the body cuts the answer, as
   `Egress.Response` does today) → the agent.

You review in clear what is personal (you may read it), but never a
credential: a card shows a grant's value as the grant's name, as a token
grant's request card does now, going out and coming back. Auto-approve
approves both reviews, the request and its answer; unmasking, masking and
the check for real values always run, approved or not.

What is known:

- **Patterns find ids, not everything personal**: a name, an address, a
  birth date or a score next to a token still say a lot. Masking by field
  (JSON paths per host, or an allowlist: only the listed fields pass, the
  rest become `<string>`, `<number>`, `<date>`) has to come with it; an
  allowlist is the one that can't leak a field nobody thought of.
- **What MWT can't scan**: an answer it can't decode (compressed in a way
  it doesn't read, binary) passes unmasked or is held; for a host whose
  grant masks, held (fail closed).
- **Streams**: a pattern split across two reads has to be caught, as the
  value scanner does for real values (`Egress.Scanner`).
- **A token in code the VM runs**: a local check of the id's format
  (check digits) fails on a token; format-preserving tokens would pass it,
  but can be taken for real ids: a typed prefix is safer.
- **Kept the same way in the exchange log**: masked as the VM saw it, the
  real values readable only by you.
- **Pseudonymous isn't anonymous**: data-protection law may still count it
  as personal data, since you can reverse it. Whether masked access is
  enough is the organization's call, not MWT's. Decided on 2026-11-21:
  masked access is enough for now.

## A crash of the sandbox server, and the grants after it

Set aside on 2026-11-19, widened on 2026-11-21.
`mwt propose commands --dir DIR`, with `DIR` inside a shared folder,
crashes the sandbox's server: `Approvals.place/3`
matches two elements, `{_where, dir} = HostCommand.place(...)`
(`server/approvals.ex:660`), and `HostCommand.place/3` returns three for a
folder in a share, `{:share, dir, share}` (`host_command.ex:229`, its
`@spec` says so); a folder outside every share gives `{:home, home}` and
works. The agent then hears "MWT is locked. Ask the user to unlock it.":
`Channel.serve_ask/3` (`channel.ex:288`) catches every `:exit` from
answering and reports it as a lock. Nothing is saved, and the server
restarts.

The way around today: propose without `--dir` and `cd` into the folder in
the script, or set the folder on the subgrant's page as you review it.

The fix: match both shapes (`{:share, dir, _share}`, `{:home, dir}`); and
in `serve_ask`, say "locked" only when the store is, otherwise that MWT
failed answering and nothing changed, with the reason in MWT's log.

What the restart does matters more than the crash (the threat model
review of 2026-11-21, finding 1, in `docs/dated/`): `Server.init/1` puts
every grant in its start setting (`Grants.start/1`), after a crash as
after an unlock. The review's probe turned the Internet and `mwt-read`
off, sent the proposal, and both were on again. So a crash the VM can
cause undoes what you turned off.

Wanted:

- **A restart after a crash keeps the grants as they were**: on or off,
  their approval modes, and the time left on those turned on for a while;
  an isolation stays. Only a start (opening MWT, unlocking) puts them in
  their start settings. You are told the sandbox restarted, and an agent
  whose ask was lost hears that MWT restarted and to ask again, not that
  it is locked.
- **A button on the Grants page: "Reset to start settings"**, which puts
  every grant in its start setting, as a start does, without restarting
  anything.
- **No channel command crashes the server**: a test that sends every
  command the channel answers with hostile fields (missing, of the wrong
  type, huge, nested, control characters), built from the channel's own
  list so a new command is covered, and checks the server is the same
  process afterwards.

## Docker in the VM

Set aside on 2026-11-19. The VM's image has neither Docker nor Podman, so
a project whose tests start containers (testcontainers) can't run them.
The kernel has what Docker needs (overlay, bridge, netfilter, cgroup v2),
but the root is an overlay, which Docker's `overlay2` can't sit on, nothing
starts a daemon (the VM's init is `init.krun`, no systemd), and what apt
installs is gone when the VM is recreated.

The way around today, in the VM:

- Docker's static release (`download.docker.com/linux/static/stable/`,
  checked against its published SHA-256) unpacked in
  `/root/.local/docker/bin`, kept on the Home disk; `docker` linked into
  `~/.local/bin`.
- `data-root` on the Cache disk (`/cache/docker`, ext4), set in a
  `daemon.json` beside the binaries, so images survive a recreate.
- A start script, `~/.local/bin/docker-up`: installs `iptables` from apt
  when it is missing, starts `dockerd` with `nohup` (log in
  `/cache/docker.log`) and waits for `docker info`. Run after every start
  of the VM.

What it would take in MWT: Docker (or Podman) in the image the recipe
builds, with `iptables`, its data on the Cache disk, started with the VM
(or on the first use of its socket); a setting to leave it out for whoever
doesn't need it.

## Working in the VM yourself, without an agent

Set aside on 2026-11-21. Everything in the VM is written for an agent:
`mwt help` speaks to one ("ask the user"), and a person at the VM's
terminal is a guest in a workflow built around threads. You should be able
to do the whole loop by hand, with no agent: bring the work on your
machine into the VM, change it, and hand it back. Not a bypass: what you
do by hand is asked and decided like an agent's ask, and approving your
own asks is fine.

Why: the VM has what developing needs, the project's tools and
dependencies as well as its agents, so sending the work back to your
machine to carry on there loses all that; work shouldn't stop when the
agent's credits run out; and the git you know is MWT's Git tool, which
opens repositories on your machine only, so in the VM it is the git CLI.

The pieces are there, but not put together for a person:

- **Who asks.** `mwt` finds the asker in the processes above it
  (`identify` in `priv/sandbox/mwt-cli`): with no agent there, the card
  says "an agent", with no thread. Only `MWT_AGENT` changes that.
- **Your main branch in the VM.** `git fetch origin` already works from
  any shell, through the remote helper (`mwt-git-remote`, fetch only) and
  the grant Git: fetch. The clone even has a `main` that tracks
  `origin/main`. But it has nowhere to live: every working tree is a slot,
  and a slot holds a thread's task. So `git pull` on your own `main` means
  switching a slot out from under its task.
- **A handoff by hand.** `mwt handoff` from a terminal gets past
  `Handoffs.holding/3`, since an ask with no thread id is let through.
  But it only goes from a task branch that `mwt worktree new` made
  (`:not_a_task` otherwise), and it takes its body from a file. A branch
  you made with `git switch -c` can't be handed off.
- **Git, by hand.** MWT's Git tool runs git on your machine only
  (`MWTClient.Git.Command.capture_path/3`, `git -C PATH`). In the VM there
  is the git CLI, Zed's git panel, which runs git in the VM over Zed's
  connection, or a terminal UI such as `lazygit` (in mise's registry). The
  loop needs little of git: status, diff, `add -p`, fetch, a rebase onto
  `origin/BRANCH` and its conflicts, with `mwt` to start a task and hand
  it off. Landing and pushing stay on your machine, in the Git tool.
- **A slot falling behind, unseen.** A task branch stays where it started
  until something rebases it (`mwt handoff` does), and the clone's
  `origin/*` move only on a fetch (`git fetch`, `mwt worktree new` or
  `resume`, `mwt handoff`). Neither the Projects page nor `mwt project`
  says how far behind a slot is; the Handoffs page says "Behind base" only
  once there is a handoff. On 2026-11-21 a slot was a commit behind `main`,
  with the clone already fetched, and it was found only by looking.

What it would take:

- **A person at the terminal is named as such.** When no agent is found
  above `mwt`, the card says it is you, from the VM's terminal, not "an
  agent". It is decided the same way, under the same grants.
- **A working tree of your own in each project.** For example
  `/work/NAME.me`, outside the slots and never a thread's, on your `main`
  or any branch you choose. Plus `mwt pull [BRANCH]`: it fetches, then
  fast-forwards that branch to yours on your machine, and refuses, saying
  so, when the VM's branch has commits of its own (then
  `git rebase origin/BRANCH`). Plain `git pull` works there too.
- **How far behind each slot is.** `Slots.look/4` already runs one script
  in the VM per look: it can also count `origin/BASE...HEAD` for each
  task, and compare the clone's `origin/BASE` with your branch here. The
  Projects page and `mwt project` then say "2 behind main", or that the
  clone hasn't fetched your latest, and MWT can tell the thread holding
  the slot that its base moved.
- **`mwt handoff` for a person.** Run from your own tree or any branch:
  - with no `--title`, it asks for one;
  - with no `--body`, it opens `$EDITOR`;
  - on a branch that isn't a task, it offers to make it one, based on the
    branch it came from.
- **A guide for doing it by hand.** `mwt help` gets a section for a person
  (start, catch up, hand off, see what happened, as four commands), and
  MWT's docs get a page on working in the VM yourself.

MWT's Git tool on the VM's repositories was weighed on 2026-11-21 and set
aside: for now, the git CLI. Two ways to it, should the Git tool still be
missed:

- **Your Git tool, running git in the VM.** Every git call goes through
  `Git.Command.capture_path/3`: a VM repository would send the same
  arguments through `msb exec`, as `Slots.look/4` does, and the few files
  `Git.Core` reads itself (the `MERGE_HEAD` kind of markers, the stash
  log's stat) would be read there. The page stays MWT's, on your machine,
  and git, with the hooks and config agents can change, stays in the VM.
  Unknown: speed. A refresh is many git calls, each a round trip into the
  VM: one script per refresh, or a helper that stays up there. What git
  prints is the VM's to choose: bounded, as `HostGit` bounds it.
- **A Git-only MWT served from the VM,** on a forwarded port
  (`http://127.77.X.Y:41xx`). Git runs beside the repository, as fast as
  on your machine. But the page is the VM's word (agents are root there
  and can replace it), as Zed's view over SSH already is: fine to work
  with, never for the review before landing, which stays on the Handoffs
  page. It needs your installed MWT mounted read-only, not the clone agents
  change; a mode with the Git tool alone (no vault, accounts or SSH keys,
  repositories under `/work`, Push gone or made a handoff); and a token in
  the URL, since every program on your machine reaches loopback. It can be
  tried with no new code: this repository's dev server in a slot (`41N0`)
  already has the Git tool.

Either way, a slot an agent works in is shared: the tool shows who holds it
(`branch.NAME.mwt-thread`) and asks before changing it. Your own working
tree, above, has no such conflict.

## From the threat model review of 2026-11-21

Its findings that no section above covers. The review
(`docs/dated/20261121-threat_model_fable5.2_review.md`) has the details,
the code each touches, and probes for findings 1 and 2.

- **A fetch serves objects no branch or tag reaches** (finding 2). Under
  Git protocol v2 the `uploadpack.allow*InWant` options aren't enforced, so
  any object of your repository is served by id (a stash, a commit you
  reset away); and a handoff's fetch tells the VM the ids of your stash and
  remote-tracking branches.
- **Git here runs your global configuration on the VM's objects**: a
  `textconv`, external diff or filter of yours runs on the VM's files at
  the review store's fetch, the Handoffs page's diff and the landing.
- **Markdown the VM wrote makes your webview fetch addresses it chose**
  (finding 5): a remote image in a note, diagram or flash card loads, and
  MWT's pages have no Content-Security-Policy.
- **Disk tools run here on images the VM wrote** (finding 6): `e2fsck` and
  `resize2fs` parse the Home and Cache disks' file systems, as you, with no
  bubble.
- **Smaller gaps** are listed under its *Smaller gaps* and *Reported by the
  area audits only*, and what the document itself misses under *Gaps in
  the threat model*.
