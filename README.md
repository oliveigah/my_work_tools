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
with plenty of vibe coding along the way. It is the first part of MWT I mean
to review thoroughly and redesign, to sharpen its ideas, its architecture
and the guarantees it makes.

Coding agents work best when they can install packages, run code and use
real services. Doing that on my own machine, with my logins, my SSH keys and
my VPN within reach, is a risk I don't want to take. So my agents work in a
virtual machine instead, and MWT stands between that VM and everything else.

The VM is a [microsandbox](https://github.com/superradcompany/microsandbox)
microVM (libkrun on KVM), which MWT starts, watches and controls. MWT ships
its own copy of microsandbox's `msb`, the stock release, and runs it in a
locked-down bubble with no access to my home folder or the network.

### What it gives me

- **My machine stays out of reach.** Whatever an agent installs or runs
  stays in the VM. Folders I share are copied into it, read-only; my
  repositories are cloned into it as projects. Nothing it writes comes back
  to my machine unless I choose it.
- **No credentials in the VM.** Access is a _grant_: a token, a private
  network, a command on my machine, each described in my own words and
  turned on only for as long as a task needs it. The VM only ever sees a
  placeholder, which MWT swaps for the real value on the way out, and only
  towards the hosts that grant is for.
- **I approve what matters.** Requests that use a credential, and commands
  an agent wants to run on my machine, wait for my yes on a card that shows
  exactly what will happen, with a desktop notification, unless I allowed
  them for a while.
- **Everything leaves through MWT.** All of the VM's traffic and every DNS
  lookup go through MWT and into an activity log. Private networks stay
  closed unless a grant opens them.
- **A firewall watching for trouble.** It looks at what the VM does with
  the access it already has: large uploads, credentials going where they
  shouldn't, strange DNS. On the first sign of trouble it isolates the VM
  until I release it, and I can isolate it myself too.
- **The VM is a clone of my machine.** The same way my machine is a clone
  of a remote such as GitHub: my repositories are cloned into the VM with
  my machine as their `origin`, `git fetch` there brings my branches, and a
  push is refused. Work comes back the way it reaches a shared repository,
  much like a pull request: agents work on their own branch in a project's
  _worktree slot_ and leave their changes uncommitted. I review them in
  Zed, connected to the VM, where I have the whole project and the best
  tools for it, and ask for more until it's right. Then they hand it off,
  and MWT is where I make it official: land it on my branch, send it back
  with a note, or close it.
- **Agents in my editor.** MWT adds **Claude (MWT)** and **Codex (MWT)** to
  Zed's agent panel, with their threads running in the VM, and opens
  projects in Zed over SSH. Servers an agent starts on ports 4100 to 4199
  open on my machine by themselves, so I can try what it built.

### The control panel

| Page               | What it is for                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Overview**       | The VM at a glance: start, stop or recreate it, what it uses, approvals waiting, servers running, grants that are on, the latest activity. |
| **Approvals**      | The cards waiting for a decision, the commands running on my machine, and what was decided.                                                |
| **Projects**       | The repositories open in the VM, their branches and their worktree slots.                                                                  |
| **Handoffs**       | Where a task I reviewed in Zed becomes official: landed on my branch, sent back with a note, or closed.                                    |
| **Grants**         | Every grant, on or off, with what the VM gets, how long it stays on, what is allowed for now and its recent use.                           |
| **Proxy activity** | Every connection and lookup the VM made, filterable, down to the request as the VM sent it.                                                |
| **Firewall**       | The _VM isolated_ switch, the rules and what they found.                                                                                   |
| **Settings**       | Shared folders, CPUs, memory and disks, and the image the VM runs.                                                                         |
| **Setup**          | What this machine still needs, and the steps to get the VM and Zed ready.                                                                  |

### What it doesn't do

It keeps agents from acting as me beyond what I allow, and keeps what they
run off my machine. It doesn't stop an agent from uploading what I gave the
VM (the firewall only catches the obvious), and code from a handoff I land
runs when I build it: reviewing it is my part. The full threat model is in
[docs/agent_sandbox.md](docs/agent_sandbox.md#threat-model).

All of this is what it is designed to do. Until that thorough review, read
its guarantees as intentions rather than promises.

### What it needs

Linux with KVM (`/dev/kvm`), `bwrap` (bubblewrap) allowed to use
user namespaces, `podman` to build the VM's image, and e2fsprogs for its
disks. The **Setup** page checks each one and says what is missing. To work
in the VM, [Zed](https://zed.dev).

The whole design, part by part, is in
[docs/agent_sandbox.md](docs/agent_sandbox.md).

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

Agents can save notes, diagrams, flash cards and HTTP request samples into
MWT, and read what is there:

- **In the sandbox,** through the `mwt` command, under three grants
  (read, create, change), with every change kept as a version I can
  restore. They add HTTP samples but never read any: my request history
  holds the credentials I sent.
- **On this machine,** over MCP: open **Connect an agent** from the tools
  page or the title bar, choose **Enable agent access**, and copy the
  server URL and token into the agent's MCP settings (Streamable HTTP).
  **Disable access** revokes it at once.

Then I can ask things like _"make a diagram of our checkout flow in MWT"_ or
_"add flash cards with the key decisions of this thread"_. The tools and
their details are in [docs/mcp.md](docs/mcp.md).

## My data

Each identity's data (requests, diagrams, notes, cards, the sandbox's
activity) is encrypted under its password in `~/.mwt_client/`, and Git
repositories stay in their own folders. **Export and import**, in the
settings menu, packs an identity into one encrypted `.mwtexport` file to
move it to another machine. How it is stored is in
[docs/storage.md](docs/storage.md).

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
sign-in screen installs a package downloaded by hand. The details are in
[docs/releases.md](docs/releases.md).

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
./scripts/build-acp.sh            # MWT's shell for Zed's agents (needs: rustup target add x86_64-unknown-linux-musl)
./scripts/build-present.sh        # the helpers the VM's `mwt exec` runs (same target)
```

After the first time, `mix compile` rebuilds the last three when their
source changes. On Ubuntu 24.04 and later, AppArmor keeps the system's
`bwrap` from doing what the sandbox needs: the packages set that up, and
for an MWT run from source, once:

```bash
sudo sh scripts/deb/postinst.sh
```

Tests:

```bash
mix test              # the whole suite, about a minute and a half
mix precommit         # format, compile warnings and tests, before a change goes in
mix test --only vm    # boots a real VM: confinement, network, disks
```

To build the Debian and RPM packages into `dist/` (with Docker and Docker
Compose; `PACKAGE_PLATFORM=linux/arm64` for ARM):

```bash
./scripts/build-linux.sh
```

## Releases

Publishing a GitHub release with a version tag builds the `.deb`and `.rpm`,
signs their checksums with the release key, and attaches them.
Installed apps offer it at their next check. Setting up the signing key and
cutting a release, step by step, are in [docs/releases.md](docs/releases.md).
