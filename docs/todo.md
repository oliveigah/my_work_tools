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
