# To do

Features set aside, with what is known about them, so they can be picked up
again without starting over.

Port forwarding from the VM, set aside on 2026-11-13, was built on
2026-11-15: see "Servers in the VM, on your machine" in
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

## The metadata server on grants not added from the Google preset

Set aside on 2026-11-19. "Serve it as a cloud metadata server" (a
presentation, `Grant.presents`) can be turned on only in the add form, with
the Google Cloud preset picked: the box shows when
`@adding.preset.id == "google"` or when it is already on
(`sandbox_live/grants.ex:2680`). Editing a grant opens the same form with
`Presets.type_or_preset/1` (`sandbox_live.ex:1059`), which gives the
grant's type, never the preset that made it (`presets.ex:333`), so on a
grant where it is off the box never shows again. Every proposed grant is
one: `mwt propose token` can't ask for it (`Proposal.attrs/3` takes name,
purpose, hosts, env, file_env, carriers, git, mint and reach,
`proposal.ex:64-86`), and MWT's `google.json` preset doesn't set it.

What is known:

- Found with a proposed Google grant (BigQuery and Cloud Storage, minted
  with `gcloud config config-helper --force-auth-refresh`): `bq` and
  `gcloud storage` worked through the token file, Google's Python clients
  didn't (`google.auth.default()` raised `DefaultCredentialsError`), and
  its page had no box to turn the server on. The way around: add the grant
  again from the Google Cloud preset, then remove the proposed one.
- The grant builder already reads `present_metadata`, `present_project`
  and `present_email` from the form's fields, whatever filled them
  (`server/grants.ex:975`), and a proposal copies the fields of the preset
  it names (`Proposal.preset_fields/1`). So today a preset of yours that
  sets them is the only way a proposal carries the server.
- Two changes would close it: show the box when editing any token grant
  (or any whose hosts are under `googleapis.com`), not only when adding
  from the Google preset; and let `mwt propose token` ask for it
  (`--metadata-project PROJECT`, `--metadata-account EMAIL`), shown on the
  proposal's page with the rest for you to accept. It serves only
  placeholders ("no trust decision", Presentations in
  `docs/agent_sandbox.md`), so proposing it needs no new rule.

## Tools that mint Google credentials themselves

Set aside on 2026-11-19. Some tools don't take a token: they make their own
from a Google login, in process, and those steps can't run in the VM. Two
seen:

- **A self-signed service-account JWT.** A client of a service behind IAP
  loads default credentials, then calls IAM Credentials `signJwt` as a
  service account, with claims it builds (`iss` = `sub` = the account,
  `aud` = the service's URL with `/*`, one hour), and sends the JWT as
  its bearer.
- **The user's ID token beside it.** A CLI sends, on every request, that
  JWT and the user's Google ID token in a header of its own. It takes the
  ID token from `credentials.refresh()` of an `authorized_user` login
  (`credentials.id_token`; a metadata server's credentials have none),
  reads its claims locally without verifying them (`hd`, `email`), and the
  service rejects one issued more than 5 minutes before.

In the VM both fail where they start: the refresh
(`oauth2.googleapis.com/token`) and `signJwt`
(`iamcredentials.googleapis.com`) are on the firewall's credential endpoints
(`@mints` in `firewall.ex:188`), and their answers are credentials the VM
would hold. Nothing in MWT can stand in for them today,
so such a tool runs only through Ask to run commands, or after a change to
the tool itself (take the values from variables, and mint them with
grants).

What MWT would need, so that they run as they are and no real value enters
the VM:

1. **A Google login file as a presentation**, beside the metadata server
   (Presentations in `docs/agent_sandbox.md`): under `mwt exec`,
   `GOOGLE_APPLICATION_CREDENTIALS` names an `authorized_user` file holding
   the client id and placeholders for its secret and refresh token.
2. **MWT answering the token endpoint itself** for that refresh token: never
   forwarded, it mints on this machine
   (`gcloud config config-helper --force-auth-refresh`) and answers with a
   placeholder access token and a placeholder ID token. Nothing real goes
   to a credential endpoint, so `:credential_mint` has nothing to stop; its
   own answer must not count as `:credential_inbound`.
3. **Placeholders shaped like a JWT**: the real token's harmless claims
   (`email`, `hd`, `aud`, `iat`, `exp`) under a header, with a signature
   that is a placeholder, so a tool reading them locally works. The real
   ID token goes only in the grant's carrier header, to its hosts. With a
   5-minute limit on the service's side, it is minted again within that:
   `expires_in` from the mint (`Values.minted/1`), not the 10-minute
   default.
4. **MWT answering `signJwt` itself**: the account must be one the grant
   names, and `aud` one of its hosts; the answer is a placeholder JWT with
   the claims the VM sent. On the way out to that host, it becomes a JWT
   signed on this machine for the same claims
   (`gcloud iam service-accounts sign-jwt`). The VM chooses the claims, but
   the signed JWT goes only to the host its `aud` names, which the grant
   lists.

Item 4 alone, with the metadata server MWT has, is enough for the first
kind (a client that takes default credentials and calls `signJwt`); the
second needs all four.

## A workspace for agents, on your machine

Set aside on 2026-11-19. Shared folders go one way, from your machine into
the VM, read-only there (`MWTClient.Sandbox.ShareMounts`,
`MWTClient.Sandbox.FolderSync`); nothing of the VM reaches your machine but
a handoff you land. Work that isn't code has no way back: a file an agent
writes for a command of yours to read (a config entry a CLI uploads, a
report, an input a subgrant's script takes) can't get there, so the agent
passes it in a parameter, or the job can't be done. And a host tool's
output reaches the VM only if it lands in a shared folder, which you have
to make and share for it.

The idea: **a workspace for agents, built into MWT**: a folder on your
machine that MWT makes and shares by itself, at the same path on both
sides (`~/mwt-vm`, say), the agents' working directory for everything that
isn't a project's code. Changes come only from the VM: written there,
read-only on your machine, kept up to date by MWT on its own, so the
conflicts of "Conflicts in shared folders' copies" can't happen here.

What it would take:

- **Built in, nothing to set up**: made with the identity's VM, shared
  without being added under Shared folders in Settings, shown on the
  Overview page with a button to open it. One variable names it on both sides
  (`MWT_WORKSPACE`, say): in the VM, and in every command and subgrant MWT
  runs on your machine, so a script writes `"$MWT_WORKSPACE/…"` instead of
  a path of yours.
- **Agents are told to use it** (`priv/sandbox/agents.md`, `mwt host`):
  outputs you asked for (reports, exports, generated files), inputs a
  command of yours will read, and anything a host tool fetches for the VM
  go there, never `/tmp` or a project's clone; and a subgrant that makes
  files points its tool there (a CLI's output folder, say). Then
  `mwt sync` (or MWT on its own) is the only way a file needs to travel.
- **A part per task**, `<project>/<task>/`, so threads don't step on each
  other, and a task's files are found next to its handoff; removed, or
  kept, when its handoff lands or is closed.
- **Both directions in one place** is the wish: what your commands write
  there reaches the VM, what the VM writes reaches you. Both at once
  brings the conflicts back, unless each side has its own part
  (`from-vm/` and `to-vm/`, say).
- **Read-only on your machine** needs a rule for when you change a file
  anyway: the VM's version put back at the next sync, or the folder's
  files kept read-only (mode bits, which you can still undo).
- **It is a way out of the VM onto your machine**, where your own tools may
  read and run what lands: the firewall's limits for a handoff apply (a
  size cap, no symlinks or special files, executable bits dropped), and a
  command or subgrant reading from it should say so on its card.
- **Synced when it changes** (watched in the VM), and always before a
  command or subgrant runs on your machine, so it reads what the VM wrote
  last.

Found when an agent needed a host CLI's output in the VM: the CLI writes
its files inside your checkout, which isn't copied (projects aren't), so a
folder was made and shared by hand for the VM (`~/mwt-vm`, read-only there
as every share is today), and the CLI pointed at it.

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

## Every request through a network grant, read and reviewed

Set aside on 2026-11-19. A network grant is asked about a connection, not
a request: `Connection.run/3` approves it in `destination/5`, before the
TLS handshake, so its card says "Connect to 10.x.y.z:443", the entry it
matched ("Listed as") and the grant, and nothing of what goes through.
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
  and a network grant's once it reads them, see "Every request through a
  network grant, read and reviewed"), and every command or subgrant
  output, is scanned for patterns (an id, with and without punctuation,
  validated by its check digits so that any 11 digits don't match; an
  email; a phone), and each match is replaced by a token,
  `mwt:cpf:Xb3k…`.
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
  ("Every request through a network grant, read and reviewed");
- the agent getting the status, the timings and the headers MWT allows,
  never the body;
- the body cut whenever it holds the id itself, as an answer holding a
  real value is today (`Egress.Response`), which most answers about a
  person do.

The decryption on the way out is the half that is the same whatever
masking answers becomes, so it can come first; and the agent learns from
it how the calls are made, which a person's id doesn't change.

**The order, both ways**, with the reviews of "Every request through a
network grant, read and reviewed":

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
  enough is the organization's call, not MWT's.

## Proposing a command subgrant with a folder in a share crashes the server

Set aside on 2026-11-19. `mwt propose commands --dir DIR`, with `DIR`
inside a shared folder, crashes the sandbox's server: `Approvals.place/3`
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
- **`mwt handoff` for a person.** Run from your own tree or any branch:
  - with no `--title`, it asks for one;
  - with no `--body`, it opens `$EDITOR`;
  - on a branch that isn't a task, it offers to make it one, based on the
    branch it came from.
- **A guide for doing it by hand.** `mwt help` gets a section for a person
  (start, catch up, hand off, see what happened, as four commands), and
  MWT's docs get a page on working in the VM yourself.

## Diagrams: groups, and bringing to front or sending to back

Set aside on 2026-11-21. In the diagram editor, what is on top is decided
by the order of the diagram's elements: `renderScene` in
`assets/js/diagram_editor.js` draws them in that order, so a later element
covers an earlier one. A new element always lands on top. Nothing in the
editor changes the order. Today the only way is `update_diagram` through
the MCP server, which rewrites the whole list. And elements can't be
grouped: several shapes meant to move together (a box and its label, a
legend) have to be selected again each time, with shift-click or a
marquee.

What it would take:

- **A menu on the right click.** Where these actions, and the others
  that act on what is selected, live.
  - Today the editor turns the browser's menu off (`contextmenu`, in
    `mounted`), and a press of the right button starts moving around the
    canvas (`pointerDown`).
  - Both stay, but a right click that doesn't move (released within a
    few pixels of where it was pressed) opens MWT's menu at the pointer.
  - On an element that isn't selected, the right click selects it first.
    On empty canvas, the menu offers what applies there (paste, select
    all).
  - It lists:
    - the order and group actions below;
    - duplicate, copy, paste and delete;
    - each action's shortcut beside it.
  - Actions that don't apply are greyed out, not hidden: ungroup on
    elements in no group, bring to front on what is already on top.
  - `Escape` or a click elsewhere closes it, and the arrow keys move
    through it.
- **Order.**
  - Bring forward, send backward, bring to front, send to back, on the
    selection, from the right-click menu.
  - Shortcuts: `Ctrl+]` and `Ctrl+[`, with `Shift` for all the way.
  - Several selected elements keep their order among themselves.
  - It is saved as the elements' order, so versions, the diff and the MCP
    tools see it with no new field.
- **Groups.**
  - Group the selection from the right-click menu or with `Ctrl+G`;
    ungroup the same way, or with `Ctrl+Shift+G`.
  - Clicking a member selects the whole group, and a double-click goes
    inside it to pick one.
  - Moving, resizing, deleting, duplicating and restyling act on all its
    members.
  - It moves in the stacking order as one block (its members kept next to
    each other).
  - Groups can be nested. Arrows bound to a member stay bound.
- **Stored where agents see it.** A `group` id on each member (a list, for
  nested groups), in the element schema the MCP tools check
  (`lib/mwt_client/mcp/catalogue.ex`, whose elements allow no other
  fields). `mwt://guides/diagrams` explains it, so an agent drawing a
  diagram can group what belongs together.
