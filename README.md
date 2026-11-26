<p align="center">
  <img src="src-tauri/icons/mwt-icon.svg" width="140" alt="MWT's logo: two crows facing each other, their wings and crossing beaks forming a W">
</p>

<h1 align="center">MWT · My Work Tools</h1>

<p align="center">
  My personal desktop toolbox, built around how I work,<br>
  with a control panel for the coding agents I work with.
</p>

---

MWT is the set of tools I use every day as a developer, rebuilt into one
Linux desktop app and shaped to my own workflow. It isn't a product, and it
doesn't try to fit everyone: each tool does what I need, the way I like it,
and changes when my work does.

It started as a place to explore ideas. The simple tools came first: an
HTTP client, a Git GUI, diagrams, notes, flash cards, each because I wanted
it my way. They are low stakes, and their code has had the poor review
that low-stakes tools for one person get. The Agent Sandbox came last, and
it is the first idea here I think could be worth something on its own.
It still lives in MWT, because this is where the things I use live.

I use MWT and change it every day: using it is how I find its bugs and
the next thing to improve in how I work. So there are next to no
guarantees of stability: things change, move or go, sometimes from one day
to the next.

A few things hold for every tool:

- **Local-first.** Everything lives on my machine, encrypted under a
  password. No account, no cloud, nothing to sign up for.
- **Easy to find again.** Requests, diagrams, notes and cards are kept, and
  search finds a word wherever it was written.
- **Agents welcome, on my terms.** Coding agents can use MWT's tools, and
  they do their work inside a sandbox where I decide what they can reach.

## The Agent Sandbox

The newest tool, and the one I think is most worth the focus, so it gets
the most space here. Like the rest of MWT it grew fast, as an exploration,
with plenty of poorly reviewed code along the way. It is the first part of
MWT I mean to review thoroughly and redesign, to sharpen its ideas, its
architecture and the guarantees it makes.

Coding agents work best when they can install packages, run code and use
real services. Doing that on my own machine, with my logins, my SSH keys and
my VPN within reach, is a risk I don't want to take. So my agents work in a
virtual machine instead, and MWT stands between that VM and everything else.

The VM is a [microsandbox](https://github.com/superradcompany/microsandbox)
microVM, which MWT starts, watches and controls. MWT ships
its own copy of microsandbox's `msb`, the stock release, and runs it in a
locked-down bubble with no access to my home folder or the network.

### Safe, and easy to live with

A VM keeps agents away from my machine, but working through one can be
tedious: repositories to get in and changes to get out, credentials to pass
along, servers to reach, an editor on the wrong side of the wall. Each step
is small, together they drain the day, and a sandbox that gets in the way
is one I would end up working around. So the Agent Sandbox is two things in
one: the **sandbox**, which makes it safe, and the **control panel**, which
makes it easy to work with.

### The sandbox: safe

- **My machine stays out of reach.** Whatever an agent installs or runs
  stays in the VM. Folders I share are copied into it, read-only; my
  repositories are cloned into it as projects. Nothing it writes comes back
  to my machine unless I choose it.
- **No credentials in the VM.** Access is a _grant_ over one of my
  _resources_ (a credential, a network, commands on my machine, MWT's own
  tools), described in my own words and on only for as long as a task
  needs it. The VM only ever sees a placeholder, which MWT swaps for the
  real value on the way out, and only towards the hosts a grant lists.
  How grants work is in
  [docs/architecture.md](docs/architecture.md#grants-the-mental-model).
- **I approve what matters.** Requests that use a credential, and commands
  an agent wants to run on my machine, wait for my yes on a card that shows
  exactly what will happen.
- **Everything leaves through MWT.** All of the VM's traffic and every DNS
  lookup go through MWT and into an activity log. Private networks stay
  closed unless a grant opens them.
- **A firewall watching for trouble.** It looks at what the VM does with
  the access it already has: large uploads, credentials going where they
  shouldn't, strange DNS. On the first sign of trouble it isolates the VM
  until I release it, and I can isolate it myself too.

### The control panel: easy

- **The VM is a clone of my machine,** as my machine is a clone of GitHub:
  my repositories are cloned in with my machine as `host-origin`, `git fetch`
  brings my branches, and a push is refused. Agents work on their own
  branch in a _worktree slot_, where builds start warm, and leave their
  changes uncommitted. I review them in Zed and ask for more there; when
  it's right they hand it off, and in MWT I land it or close it, much like
  a pull request.
- **Zed does the heavy lifting.** With Zed's remote development, the editor
  runs on my machine while the files, terminals, language servers and
  agents run in the VM, so it feels local. MWT only sets up SSH and opens
  projects in Zed.
- **My machine and the VM, a step apart.** What needs to cross does so
  easily, always through MWT. Servers an agent starts on ports 4100 to 4199
  open on my machine by themselves. Folders I share show up in the VM at
  the same paths, read-only, and sync at each start, when I ask, or when an
  agent asks. Agents read a description of my machine instead of probing
  it, reach my notes, diagrams and flash cards, and can ask to run a
  command on my machine, which waits for me.
- **Asking is cheap.** An agent asks for access from the VM, with its
  reason; I get a notification and a card, and one click lets it carry on.
  What I trust I allow for a while, or let run without asking.
- **Commands I can read easily.** Not the long shell lines agents usually
  ask to run: an agent sends the smallest command that gets the raw data
  (`kubectl get pods -o json`) and does the rest in the VM. I can see the
  output before the agent does, and keep it from it. Repeated jobs become
  saved commands, typed and confined, read once and then trusted.
- **Agents set up their own access, for me to check.** When no grant fits,
  an agent proposes one: a credential and the hosts it may go to, a network
  and its destinations, or a _fixed call_ (a script or an HTTP request MWT
  builds from the agent's typed values). It lands in my grants, off, for me
  to read, adjust, and accept or decline; values, whether each use asks and
  how a grant starts stay mine. Proposals are
  narrow, one job each, so they're quick to judge, and my grants grow from
  the tasks that needed them.
- **Agents know their way around.** Every agent is told how the VM works:
  where to work, how to ask, how to hand off, which grant a failed
  connection needs. No explaining the sandbox to each thread.

One place for all of it:

| Page               | What it is for                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Overview**       | The VM at a glance: start, stop or recreate it, what it uses, approvals waiting, a terminal into it, servers running, grants that are on, the latest activity. |
| **Approvals**      | The cards waiting for a decision, the commands running on my machine, and what was decided.                                                |
| **Projects**       | The repositories open in the VM, their branches and their worktree slots.                                                                  |
| **Handoffs**       | Where a task I reviewed in Zed becomes official: landed on my branch, or closed; more is asked in its thread.                              |
| **Grants**         | My resources, every grant over them, on or off, how long it stays on, whether each use asks, and a console to try one as the VM.          |
| **Activity log**   | Every connection, lookup and action the VM made, filterable, down to the request as the VM sent it and how it was decided.                 |
| **Firewall**       | The _VM isolated_ switch, the rules and what they found.                                                                                   |
| **Settings**       | Shared folders, CPUs, memory and disks, and the image the VM runs.                                                                         |
| **Setup**          | What this machine still needs, and the steps to get the VM and Zed ready.                                                                  |

### What it doesn't do

It keeps agents from acting as me beyond what I allow, and keeps what they
run off my machine. It doesn't stop an agent from uploading what I gave the
VM (the firewall only catches the obvious), and code from a handoff I land
runs when I build it: reviewing it is my part. The threat model is in
[docs/architecture.md](docs/architecture.md#what-it-defends-against).

All of this is what it is designed to do. Until that thorough review, read
its guarantees as intentions rather than promises.

### What it needs

Linux with KVM (`/dev/kvm`), `bwrap` (bubblewrap) allowed to use
user namespaces, `podman` to build the VM's image, and e2fsprogs for its
disks. The **Setup** page checks each one and says what is missing. To work
in the VM, [Zed](https://zed.dev).

How it works, and why it is built this way, is in
[docs/architecture.md](docs/architecture.md).

## The other tools

The first tools, and much simpler ones: each covers a part of my day I
wanted done my way, with little at stake when one gets something wrong.

### HTTP Client

For trying APIs while I build them. Compose requests with params, headers,
auth and bodies, keep several open in tabs, import and export curl commands,
and search everything I have ever sent.

### Git GUI

For the parts of Git that are easier to see than to type. Open several
repositories in tabs, walk the commit graph and diffs, manage branches and
stashes, and stage exactly the files I pick. Pushes offer to set the
upstream, pick a destination or retry with force, and force with lease
protects what was on the remote when I looked.

### Diagrams

For thinking with boxes and arrows. Sketch boxes, ellipses, diamonds and
arrows, and write on any of them or anywhere on the canvas. Tables of typed
rows can be related row to row, for data models.

### Notes

For tasks and ideas. A title and a Markdown body, marked done as I go, and
kept after that, so search still finds them.

### Flashcards

For keeping up. With agents doing much of the typing, work moves faster than
I can follow: a decision is made in a thread, lands in a commit, and is gone
from my head a week later. Flash cards are how I keep the ones that matter.

Agents write them as part of the work: when a task ends, they turn the few
decisions I made that are worth remembering, and the reasons behind them,
into question and answer cards tagged by project and topic, without my
asking. I write my own too. Remember sessions ask the cards of the projects
and days I pick, the ones I forget more often than the ones I know, and a
card I remove as not worth it isn't written again.

## Agents and MWT's tools

Agents in the sandbox can save notes, diagrams, flash cards and HTTP
request samples into MWT, and read what is there, through the `mwt`
command, under three grants (read, create, change), with every change kept
as a version I can restore. They add HTTP samples but never read any: my
request history holds the credentials I sent.

Then I can ask things like _"make a diagram of our checkout flow in MWT"_ or
_"add flash cards with the key decisions of this thread"_. The tools
describe themselves to the agent.

## My data

Each identity's data (requests, diagrams, notes, cards, the sandbox's
activity) is encrypted under its password in `~/.mwt_client/`, and Git
repositories stay in their own folders. **Export and import**, in the
settings menu, packs an identity into one encrypted `.mwtexport` file to
move it to another machine. How it is stored and encrypted is in
[docs/architecture.md](docs/architecture.md#storage).

## Install and updates

Download the `.deb` or `.rpm` from the
[latest release](https://github.com/oliveigah/my_work_tools/releases/latest)
and install it:

```bash
sudo apt install ./MWT_<version>.deb     # Debian, Ubuntu
sudo dnf install ./MWT_<version>.rpm     # Fedora
```

MWT then keeps itself up to date: it checks for a new release a minute after
it starts, once a day, and when I choose **Check for updates** in the
settings menu. It installs one only when its signature checks out against
the release key the app was built with. **Install from a file…** on the
sign-in screen installs a package downloaded by hand.

## Development

MWT is a [Phoenix](https://www.phoenixframework.org) LiveView app in Elixir,
wrapped in a [Tauri](https://tauri.app) desktop shell. You need the Erlang
and Elixir versions in `.tool-versions` (`mise install` sets them up), Rust,
and the Tauri prerequisites for Linux. Then:

```bash
mix setup          # dependencies and assets
cargo tauri dev    # the desktop app
```

The Agent Sandbox also needs its VM runtime, built once into
`priv/microsandbox`, plus `bwrap`, `podman` and e2fsprogs on the machine:

```bash
./scripts/build-microsandbox.sh   # msb and its guest kernel
./scripts/build-relay.sh          # MWT's relay, beside them
./scripts/build-present.sh        # the helpers the VM's `mwt exec` runs (needs: rustup target add x86_64-unknown-linux-musl)
```

After the first time, `mix compile` rebuilds the last two when their
source changes, and, in development (`cargo tauri dev`), msb too when
`scripts/microsandbox.pin` moves: the first start after that takes a few
minutes longer. On Ubuntu 24.04 and later, AppArmor keeps the system's
`bwrap` from doing what the sandbox needs: the packages set that up, and
for an MWT run from source, once:

```bash
sudo sh scripts/deb/postinst.sh
```

Tests:

```bash
mix test              # the whole suite, about a minute and a half
mix precommit         # format, compile warnings and tests, before a change goes in
mix test --only msb   # what MWT asks of msb, against the one in priv/microsandbox: seconds, no VM
mix test --only vm    # boots a real VM: confinement, network, disks
```

msb is built from the upstream release in `scripts/microsandbox.pin`,
which `scripts/build-microsandbox.sh` refuses to build anything but. To
move to another release:

```bash
mix microsandbox.update 0.8.2   # rewrites the pin, reports what changed upstream in tmp/
./scripts/install-runtime.sh    # or ./scripts/build-microsandbox.sh
mix test --only msb
mix test --only vm
```

The report starts with what to look at first: a kernel changed under the
same file name, where libkrun comes from, the store's migrations,
breaking changes, security fixes, a call the seccomp filter refuses.
Every msb command MWT runs is built in `MWTClient.Sandbox.Msb.Commands`,
which `--only msb` checks. When `priv/microsandbox` isn't the pinned
build, `mix compile` builds it in development and says so elsewhere.

To build the Debian and RPM packages into `dist/` (with Docker and Docker
Compose; `PACKAGE_PLATFORM=linux/arm64` for ARM):

```bash
./scripts/build-linux.sh
```

## Releases

Publishing a GitHub release whose tag is a version (`v1.2.3`) runs
`.github/workflows/linux-packages.yml`: it builds the `.deb` and `.rpm`,
signs their `SHA256SUMS` with the release key (`SHA256SUMS.sig`, Ed25519)
and attaches them. It refuses to publish when the `RELEASE_SIGNING_KEY`
secret is missing, or when its signature doesn't verify with the public key
committed at the tag (`priv/release_signing_key.pub`). Installed apps offer
the release at their next check.

To cut one: make sure `main` holds what goes out and `mix precommit`
passes, publish a release with a version tag newer than the last one (MWT
installs only a version newer than the one it runs), and wait for
*Release Linux packages* to attach the files.

The signing key is made once, on my own machine:

```bash
./scripts/release-signing-key.sh   # private key to ~/.config/mwt/release-signing-key.pem, public to priv/
gh secret set RELEASE_SIGNING_KEY --repo oliveigah/my_work_tools < ~/.config/mwt/release-signing-key.pem
```

Then commit the public key and keep the private one offline. To replace
it, run the script with a new path, commit the new public key and set the
secret again: installs from before only trust the old key, so their next
update comes from a file or is signed by the old key.
