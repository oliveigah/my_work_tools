# Agent Sandbox

This is the design of MWT's Agent Sandbox as it is built: what it is for,
what it defends against, and how each part works. It describes the current
design only; how it got here is in git.

<a id="what-it-is-for"></a>

## What it is for

LLM agents run inside a microsandbox VM. MWT starts that VM, copies chosen
folders into it, clones your repositories into it as projects, and sits
between it and the network.

1. **The host stays safe from what agents install and run.** Packages,
   scripts and tools live in the VM.
2. **Agents cannot act as you beyond what you allow.** The VM never holds a
   credential when there is any way to avoid it. You turn access on and off
   on the spot, and requests that use a credential can wait for your approval.

<a id="threat-model"></a>

## Threat model

**Who it defends against:** whatever runs in the VM, as root: an agent
following instructions planted in a web page or a repository, or a package
it installed. It can do anything inside the VM, and send any bytes to the
three things MWT offers it: the proxy, DNS and the agent channel (git
fetches included).

- It is not assumed to hold a working exploit against KVM or microsandbox.
  If it does, [the bubble](#the-bubble) decides what it reaches.
- Not defended: what you approve; leaks of what you gave the VM (below);
  other programs running as you.

**Promises**, each a numbered line in [Guarantees to test](#guarantees-to-test):

| Promise                                                         | Kept by                                                                                                               |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| The VM never holds a credential                                 | Placeholders, swapped by the proxy                                                                                    |
| Nothing leaves the VM except through MWT, DNS included          | The process running the VM has no network; its ways out are MWT's sockets                                             |
| Nothing the VM writes runs on your machine unless you chose it  | The VM's work reaches your repository only as a [handoff](#handoffs) you land, and landing runs no hook; shared folders are copied one way, into the VM; Ask to run commands is off until you turn it on, and then every run it asks for waits for you |
| A VM escape reaches no home folder and no network               | [The bubble](#the-bubble), and msb confined wherever MWT runs it on this machine                                      |
| An approval shows what will happen, with nothing hidden in it   | Facts MWT works out itself, the agent's words kept apart, and text that is written out wherever it hides something ([Text the VM chooses](#text-the-vm-chooses)) |

**Not covered:**

- **Leaking what the VM has.** Outbound traffic is passed through by
  default, so an agent can upload anything in a shared folder's copy or a
  project's clone. The [firewall](#firewall) isolates the VM on 4 MiB sent
  to one destination in 10 minutes; less than that, spread over many
  destinations, or through a trusted one, still goes.
- **Code you run from a handoff you landed.** Landing runs no hook, but the
  commits are the VM's: building or testing them on your machine runs what
  they hold. Your review is the check.
- **Data sent out through DNS** while the Internet is on. Every lookup goes
  through MWT and is in the activity log, and a query aimed at another
  resolver gets no answer. But MWT passes on every name, so query names can
  still carry data out. The [firewall](#firewall) judges their shape (long
  labels, many names under one domain), not their content; a little at a
  time still goes. With the Internet off, only names grants list go out.
- **A real value the VM got anyway, sent where MWT can't read.** The
  firewall looks for real values wherever MWT reads what the VM sends, but
  TLS to hosts no token grant lists is tunnelled unread, and a value changed
  before it is sent (base64, in pieces) isn't recognised. Reading every TLS
  connection would break clients that pin certificates, and would turn
  "passed through unread" into "read by MWT" for all of them.
- **What the VM sends behind a request MWT read** goes to the host unread
  and unlogged. It carries a placeholder at most
  ([Each intercepted request](#each-intercepted-request)).
- **A passed-through connection is logged under the name the VM gave** (the
  TLS name), which MWT doesn't check against the address: the VM can make a
  connection to any public address read as `github.com` in the log.
- **An address MWT answered for a network grant's name stays open under
  it** for as long as the answer is kept (1 to 10 minutes, by its TTL), even
  if the name moves meanwhile ([Private networks](#private-networks)).
- **The activity log has a size limit.** It is kept encrypted in the
  identity's journal and survives a restart, but a VM that makes enough
  noise reaches its retention rule's size (5 GB at first), past which the
  oldest events go first.
- **Letters that look alike.** A script mixing alphabets gets a hint;
  everywhere else such text is shown as it is.
- **What survives in Home.** Anything there that runs code (an agent's
  hooks, a planted `~/.bashrc`) outlives a recreate that keeps Home; "start
  empty" is the real reset ([Disks](#disks)).
- **VMs inside the VM** widen how much of this machine's KVM code the VM
  reaches. Off unless you turn it on ([Creating the VM](#creating-the-vm)).
- **Memory sharing isn't enforcement.** A guest can refuse to give memory
  back; the ceiling you set is what bounds it.

<a id="overview"></a>

## Overview

```
VM ──all TCP──▶ msb ──HTTP CONNECT ip:port──▶ relay ──proxy.sock──▶ MWT egress proxy
                                               │   (decided from the view the sandbox publishes, never waiting on it)
                                               ├─ loopback, link-local, this machine's own addresses → deny
                                               ├─ private ranges (VPN, LAN) → deny unless a network grant is on
                                               ├─ public addresses → the Internet grant; off, only a grant listing them
                                               ├─ TLS to a host a token grant lists → intercept (with the Internet off too)
                                               │     read request → placeholder? → allowance or approve → swap → forward
                                               └─ anything else → blind byte tunnel (log host, bytes, duration)

VM ──DNS──▶ msb ──▶ relay ──dns.sock──▶ MWT DNS forwarder ──▶ this machine's resolver (every name logged;
                                                              with the Internet off, only names grants list)

VM ──vsock:5000──▶ $XDG_RUNTIME_DIR/mwt/<id>/channel.sock ──▶ agent channel: `mwt` (grants, request, call,
                                                                │  run, host, why, ports, project, worktree,
                                                                │  handoff, mcp) and git fetches (`mwt::<id>`)
                                                                └─ `mwt run`, once you approve it ──▶ bash -lc here, as you

/mnt/mwt (copied in, in the VM's memory): CA bundle, placeholders, the `mwt` command, git's credential helper,
                                          host.md, the boot script
/root, /cache, /work, /root/.optmem: the VM's own disks (ext4 images here, which nothing here opens)
shared folders: copied one way onto the VM's root disk; the repositories in them are clones on /work

msb and the relay run in a bubble (bwrap): no home folder of yours, no network but loopback
```

The VM is created with `--proxy http://127.0.0.1:3128` and
`--dns-nameserver 127.0.0.1:5353`: ports that exist only in the bubble
microsandbox runs in, where MWT's relay joins them to MWT's sockets. All of
the VM's TCP goes through MWT, and it cannot opt out the way it could ignore
`HTTPS_PROXY`; the bubble has no network of its own to go around MWT with.
When MWT is not running, the VM has no internet and resolves no name. With
an HTTP CONNECT proxy, microsandbox blocks UDP other than DNS, so HTTP/3
cannot go around the proxy.

<a id="the-vm"></a>

## The VM

Each identity has one microsandbox VM (libkrun on KVM), run by MWT in a
[bubble](#the-bubble), from an [image](#the-image) built on your machine,
with [disks](#disks) of its own. MWT drives it through the `msb` command
line (`MWTClient.Sandbox.Msb`; no Elixir SDK), every call under `timeout`
so a stuck `msb` can't stall the sandbox. Locking or quitting MWT stops the
VM; a crash of the sandbox process leaves it running, and the restarted
one takes it back.

<a id="the-bubble"></a>

### The bubble

The process running the VM (`msb machine`) runs in `bwrap` (bubblewrap, a
package dependency). libkrun's security model says the guest reaches
whatever the VMM can, so this bubble, not the VM, is the boundary:

```
bubble: own user, mount, network, PID, IPC, UTS and cgroup namespaces
  a seccomp filter (MWTClient.Sandbox.Seccomp); no new user namespace
  /usr and msb's runtime read-only; no /etc or /run of yours; of /home only msb's store; only `lo`
  read-write: this identity's microsandbox home, its disks, its sockets

  msb ── 127.0.0.1:3128 ────────▶ relay ──▶ proxy.sock ──▶ MWT egress proxy
  msb ── 127.0.0.1:5353 (DNS) ──▶ relay ──▶ dns.sock ───▶ MWT DNS forwarder
  msb ── vsock 5000 ───────────────────────▶ channel.sock ▶ MWT agent channel
```

- **Sockets:** `$XDG_RUNTIME_DIR/mwt/<id>/`, mode 0700: `proxy.sock`,
  `dns.sock`, `channel.sock`, `control.sock`. The proxy has no port, so no
  other program can use it. The bubble may change that folder, so what MWT
  trusts (the forwarding's SSH control socket, the bubble's pid and log)
  sits beside it in `<id>-host/`, which the bubble never mounts.
- **The seccomp filter,** handed to bwrap on a descriptor, denies what a
  VMM never calls and kernel exploits reach for, other ABIs, and new user
  namespaces (`unshare`, `setns`, `clone` with `CLONE_NEWUSER`; `clone3`
  gets ENOSYS so glibc uses `clone`). Not bwrap's `--disable-userns`: its
  nested namespace keeps the relay's `CAP_NET_ADMIN` from the network
  namespace it routes.
- **The relay** (`native/mwt_relay`) is process 1 (`bwrap --as-pid-1`), so
  the kernel ends the VM whenever the relay ends. It adds a default route
  into loopback that leads nowhere (msb gives the VM IPv4 only when a
  public address has a route) and drops its capabilities; joins the ports
  to the sockets, at most 1024 connections on the proxy's and 256 on DNS's
  (one more is closed); runs the `msb create` or `msb start` MWT gave it,
  writing how it went to `start.out`; answers `status` and `stop` on
  `control.sock`; exits when the VM's process ends. It holds `relay.lock`,
  so a second relay for the same sockets refuses to start.
- **`/mwt`,** a path only the bubble has, holds the VM's parts:
  `/mwt/runtime` (read-only), `/mwt/sockets`, `/mwt/disks`, so msb, which
  boots a stopped VM by itself on `exec` and `ssh`, can't boot it outside.
  A VM made before 2026-11-16 also mounts `/mwt/inbox` (read-only) and
  `/mwt/optmem`, and gets no shared-folder copy, until it is recreated.
- **Stop and status go through the relay** (msb records the VM's pid as the
  bubble sees it); `msb exec` works from outside, through sockets in the
  microsandbox home. The bubble is detached (`setsid`): MWT crashing leaves
  it running, without internet, until MWT listens again and finds it
  through `control.sock`. DNS goes through MWT ([DNS](#dns)).
- **The microsandbox home is per identity**
  (`~/.mwt_client/identities/<id>/sandbox/microsandbox`: the VM, images,
  msb's SSH keys), so a bubble never holds another identity's VM, and an
  `msb` you install neither sees MWT's VMs nor migrates their database.
  Images are stored once per identity. `MSB_HOME` is a short link to it
  beside the sockets (msb's sockets sit about 60 bytes below its home, and
  a socket path must fit in 108), and the bubble has both paths, since msb
  records images by the real one. Every call sets `MSB_PATH` too.
- **The launcher** (`…/sandbox/bin/msb`, for Zed's SSH entry and you) only
  looks at the VM and goes into it: `exec`, `ssh` and `cp` are refused
  while nobody holds `relay.lock`, and what starts, stops or changes a VM
  always. MWT rewrites it on start, so it survives an update.
- **msb on this machine runs confined:** the launcher and every `msb` MWT
  runs (`Msb.run/3`, the git transport, streams into the VM, an image's
  load) go through
  `…/sandbox/bin/msb-confined`, a bubble with the store, the runtime and
  the seccomp filter: no KVM, no network (but for `msb pull`), no file of
  yours but one named in `MWT_MSB_READ` (an image's archive, a key to
  authorize). A VM that broke out can rewrite
  the store so that `msb exec` or `msb ssh serve` would start it; without
  KVM, they can't.
- **Which bwrap:** the deb installs a copy at `/usr/lib/mwt/bwrap` with an
  AppArmor profile for the bubble, since Ubuntu 24.04 and later deny
  `/usr/bin/bwrap` capabilities in a user namespace; elsewhere, the
  system's. What the machine lacks (bwrap or its namespaces, the relay,
  `mkfs.ext4` and friends) is said on the Setup page and at start.

<a id="runtime"></a>

### Runtime

MWT brings its own microsandbox and programs, and never uses the `msb` on
your PATH. The machine needs `bwrap`, podman and e2fsprogs, which the
packages depend on.

- **msb:** the stock v0.7.15 release of
  [superradcompany/microsandbox](https://github.com/superradcompany/microsandbox),
  commit `f9ae8e23d`, and its `libkrunfw.so.5.6.1` (the guest kernel), built
  by `scripts/build-microsandbox.sh` into `priv/microsandbox` (`bin/`,
  `lib/`), which the release carries. Pinned there: the commit (fetched by
  hash, refused with local changes), the SHA-256 of the guest agent and of
  `libkrunfw`. A `VERSION` other than the pin (`0.7.15+f9ae8e23d`) means
  rebuild. The package build runs it on Ubuntu 22.04, the older glibc of
  the two (`msb` links only glibc); in a checkout, run it once. Upgrading
  means changing the revision, `UPSTREAM` and the two checksums; a VM keeps
  its binary until it stops, and going back to an older `msb` isn't safe
  once a newer one migrated the database.
- **MWT's programs,** with no dependencies, so built without network: the
  relay (`native/mwt_relay`, `scripts/build-relay.sh`, `bin/mwt-relay`),
  the ACP shell (`native/mwt_acp`, `build-acp.sh`, `bin/mwt-acp`;
  [Agent threads](#agent-threads)) and the presentations
  (`native/mwt_present`, `build-present.sh`, `bin/mwt-present`;
  [Presentations](#presentations)). The last two run in the VM, linked
  statically (`x86_64-unknown-linux-musl`). `mix compile`
  (`Mix.Tasks.Compile.Native`) rebuilds one missing or older than its
  script or crate; one it can't build (no `cargo`, no musl target) is said,
  with what to do, and compiling goes on. `MWT_NATIVE_BUILD=0` skips it,
  the code reloader doesn't run it, and the package build has a stage for
  them.

<a id="creating-the-vm"></a>

### Creating the VM

- **Checks:** KVM, MWT's `msb` and relay, `bwrap` allowed user namespaces,
  the disk tools, podman, the image.
- **Created with** (`Msb.create_args/1`), paths as the bubble has them:
  `--proxy` and `--dns-nameserver` at the relay's ports; `--net
  public,private`, so private ranges reach MWT, which gates them (the host
  stays blocked); `--mount-disk` per [disk](#disks), and no `--volume`;
  `--vsock` for the agent channel; `--shell /bin/bash`; `--cpus`,
  `--memory`, `--max-memory`, `--root-disk`; `--nested-virt` only with VMs
  inside the VM.
- **CPUs and memory** start at what this machine can spare
  (`MWTClient.Sandbox.Resources`): every core but an eighth (one at least),
  the memory but a fifth (4 to 16 GiB kept back); at most every core, and
  the memory less an eighth (2 to 8 GiB). Settings shows both against this
  machine and offers the suggestion again. A vCPU is a thread the scheduler shares, so a busy VM slows the
  desktop but can't stop it; running out of memory kills programs, so
  memory is a ceiling, shared live (`MWTClient.Sandbox.MemoryControl`,
  microsandbox's virtio-mem, no balloon, nothing clearing caches):
    - The VM boots with at most 4 GiB under the ceiling, then asks for the
      ceiling; the [monitor](#vm-monitor)'s 5-s sample sets the target with
      `msb modify --memory` through the confined relay.
    - Below a fifth of this machine's RAM available (2 to 8 GiB), the
      target shrinks in steps of at most 2 GiB, leaving the guest its
      working memory and headroom (a quarter of the ceiling, 256 MiB to
      4 GiB), and waits for the guest to follow before the next. It grows
      when the guest's headroom is low or the host recovers (2 GiB above the
      shrink threshold, so a step isn't undone at once). A missing reading
      never shrinks it.
    - Hotplug is asynchronous: an allocation larger than the headroom can
      fail before the next sample, and the ceiling isn't promised while the
      desktop needs memory too. Live targets persist in msb's
      configuration, so MWT resets the boot allocation before each start.
- **VMs inside the VM,** off unless you turn it on (Settings → Runtime):
  the VM sees AMD SVM or Intel VMX and gets `/dev/kvm`, for microsandbox
  (MWT's VM tests, a slot's MWT), QEMU or an Android emulator; containers
  don't need it. It hands every process in the VM this machine's KVM code
  that emulates virtualization for a guest's hypervisor, where published
  guest-to-host escapes were (on AMD, CVE-2021-29657, CVE-2021-3653,
  CVE-2021-3656); clouds keep it opt-in. Without it, a bug in
  microsandbox's devices lands in the bubble; a KVM bug lands in this
  machine's kernel either way. Changing it marks the VM for recreating.
  `MWTClient.Sandbox.NestedVirt` reads the CPU flags in `/proc/cpuinfo` and
  `nested` of `kvm_amd` or `kvm_intel` in `/sys/module` (Fedora has it on);
  when this machine has it off, Settings shows the
  `options kvm_amd nested=1` line for `/etc/modprobe.d`, and creating with
  it on is refused.
- **Recreating** is how anything but a disk's size changes: `msb modify`
  can't change mounts, proxy, vsock or network, and the root filesystem
  isn't kept (apt packages installed at runtime vanish: put them in the
  Containerfile). It takes seconds with the image cached. Settings shows
  "recreate to apply"; "Recreate…" is on the VM card whenever the VM
  exists, so "start empty" is always within reach.
- **Lifecycle** (`MWTClient.Sandbox.Bubble`): MWT starts the bubble with
  `msb create` or `msb start` in it, and stops the VM through the relay,
  waiting before it removes one: the disks are block devices, and a forced
  remove is a power cut. Stopping, starting, recreating and reclaiming disk
  space first wait for shared-folder and `/mnt/mwt` copies under way, with
  no new one starting ("Finishing file copies…"): `msb exec` names a VM,
  and a recreate reuses the name.
- **Not started from Zed:** `msb ssh` would boot a stopped VM outside the
  bubble; the launcher refuses it, and there it has neither the disks'
  paths nor KVM.

<a id="disks"></a>

### Disks

Sparse ext4 images in `…/sandbox/disks` (`MWTClient.Sandbox.Disks`), made
with `mkfs.ext4 -E root_owner=0:0` (no root needed), attached with
`--mount-disk`. Nothing on this machine opens them, so a hook or
`.git/config` line an agent writes runs nowhere here; and they are several
times faster than a shared folder (10,000 files made in 0.85 s, not 3.51 s).

| Disk   | In the VM       | Holds                                                                                           | Default      | Recreating                                            |
| ------ | --------------- | ----------------------------------------------------------------------------------------------- | ------------ | ----------------------------------------------------- |
| Home   | `/root`         | Codex and Claude logins, shell history, Zed's server, agent settings, your mise config            | 16 GiB       | Keep (default), go back to a snapshot, or start empty |
| Cache  | `/cache`        | Runtime tool versions (`MISE_DATA_DIR`); hex/mix, npm/pnpm, cargo, go, uv and pip caches         | 64 GiB       | Keep (default) or clear                               |
| Work   | `/work`         | Project clones, their worktrees and builds, `/work/.rescued`                                    | 64 GiB       | Always kept; emptied only when you ask                |
| Memory | `/root/.optmem` | [The VM's OptMem](#the-vms-optmem), mounted after Home                                          | 2 GiB, fixed | Kept, whatever happens to Home                        |
| Root   | `/`             | The image's copy; apt packages, `/tmp`, `/var`; shared folders' copies                          | 64 GiB       | Starts empty                                          |

- **Sizes** are settings, and the limit on what the VM writes: the root
  disk's applies by recreating (microsandbox's default is 4 GiB), the
  others' at the next start, bigger only.
- **Not readable here** while the VM is stopped: files come out through git
  ([Handoffs](#handoffs)), or `msb cp` while it runs.
- **Snapshots of Home:** before each recreate MWT copies `home.img` (a
  reflink where the filesystem has them, else sparse), labelled with the
  image tag the VM ran, readable by you only. It keeps 3 (the
  `vm_snapshots` retention rule, at first); going back to a tag offers the
  Home from when it was current. Not msb's snapshots: `msb restore` can't
  set `--proxy`.
- **Keeping Home has a cost:** what in it runs code survives (hooks in
  `~/.claude/settings.json`, MCP servers in `~/.codex/config.toml`, a
  planted `~/.bashrc`), as do poisoned packages in Cache. "Start empty" is
  the real reset; the shell setup is in `/etc` and `/mnt/mwt`, so an empty
  Home works.

<a id="the-image"></a>

### The image

The settings page holds your Containerfile (the default ships in
`priv/sandbox`). MWT appends its layer
([What MWT hands to the VM](#what-mwt-hands-to-the-vm)), builds it with
rootless podman here, `--format docker` (else podman ignores `SHELL`, and
`pipefail` with it), and loads it into microsandbox
(`MWTClient.Sandbox.Image`). Nothing comes from a registry of MWT's.

- **Base: Ubuntu 26.04,** with `MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04`,
  so mise takes hex.pm's prebuilt Erlang (seconds) rather than compiling
  it (minutes per version).
- **apt only for what mise can't do:** the C toolchain, git,
  openssh-client, curl, ca-certificates (without it Erlang finds no CAs),
  unzip, xz, locales, postgresql-client, sqlite3, inotify-tools, tmux,
  Bash, bash-completion.
- **The rest through mise,** in `/usr/local/share/mise`
  (`mise install --system`, `mise reshim --system`), versions in
  `/etc/mise/config.toml` with majors pinned: Erlang, Elixir, Node, Python
  with uv, Rust, Go, Java with Kotlin; gh, gcloud, kubectl, pulumi, pnpm,
  rebar3, jq, yq, ripgrep, fd, shellcheck; Claude Code and Codex as native
  binaries (Zed installs its ACP adapters in Home). Rust comes through
  rustup, with `CARGO_HOME` in Cache; Hex and rebar for the default Elixir
  are in the image, since mise keeps Mix's archives per Elixir version. The
  default recipe then checks mise with an empty runtime data directory: it
  fails if a configured version would need installing, or a tool, Hex,
  Java, Python or Node is missing.
- **Switching versions:** runtime installs go to `/cache/mise`. Run
  `mise install` in a project first (it honours `.tool-versions` and
  `mise.toml`; a tool whose version is missing fails rather than installs),
  `mise exec elixir@1.18 -- …` for one-offs; another Elixir may need
  `mix local.hex --force` and `mix local.rebar --force`. Both shim folders,
  `~/.local/bin`, package managers' binaries and rustup's proxies are on
  `PATH`, restored after a login shell resets it, so `bash -c` and Zed's
  probe find the tools. Nothing goes in `/root`: Home is mounted over it.
- **Shell:** `--shell /bin/bash`, since microsandbox's SSH bridge otherwise
  starts `/bin/sh` whatever the image says; `SHELL=/bin/bash` for Zed's
  terminals. Bash loads `/mnt/mwt/bashrc.sh` (completion, an
  `mwt:<directory>` prompt, append-only history in Home), so a new Home
  needs no dotfiles; `~/.bashrc` overrides it. The profile is silent for SSH
  probes and works under `sh`.
- **Tags:** the name is a setting (`mwt_agent_sdb_image`); each build is
  tagged by date and number (`2026-11-12.1`), recording its time,
  Containerfile, tool versions (`mise ls`) and size. The newest becomes
  current, and the VM, which shows its actual image apart from the next,
  says "recreate to apply" (so does a changed shell); any kept tag can be
  made current again. 3 are kept: a build deletes the oldest from
  microsandbox and podman, never the VM's own. Rebuilding a recipe later
  gives other versions, so going back needs the images.
- **A bad image is undone by going back a tag:** agents can't change it
  (it is built here, and the VM's root filesystem is a copy a recreate
  discards), so a bad one comes from what the build downloaded. Rootless
  podman isolates less than the VM (your Containerfile's install scripts
  run there), so the build runs little third-party code: apt packages are
  signed, mise checks checksums and attestations, and the agents come as
  binaries, with no npm install scripts.
- **An old VM's recipe:** your saved Containerfile is kept across MWT
  updates, so it gets no new defaults by itself. In **Agent Sandbox →
  Settings**: review it, **Start from MWT's default**, **Save**; **Build**
  (a running VM doesn't change); **Recreate**, keeping Home and Cache if
  you like (a stop and start runs the same image); reconnect Zed.

<a id="what-mwt-hands-to-the-vm"></a>

### What MWT hands to the VM

MWT writes what it has for the VM into a folder here
(`MWTClient.Sandbox.Inbox`), copied to `/mnt/mwt` in the VM by the same copy
as shared folders, as MWT's own kind. MWT writes nothing onto the VM's
disks.

- **In the VM's memory:** a tmpfs (256 MiB at most) that MWT's first copy
  after each start mounts, so nothing of it is ever on a VM disk. It holds
  no real value. It is filled whole with a plain `tar` before anything reads it (an
  image without bash still gets its CA and boot script); then each change
  MWT makes is copied (`Server.Copying`), and the shared folders' 3-s look
  checks it. Files are replaced whole, by rename. A grant turned on reaches
  an agent waiting on `mwt request` once that copy ended, within 10 s.
- **The VM's own changes** to it change nothing MWT does; the whole
  comparison every 5 minutes puts it back, setting nothing aside. Past the
  first copy it needs
  bash and GNU `find`, `stat`, `mv`, `chmod`, `tar`; a failed copy shows in
  the VM's status.

| In `/mnt/mwt`                                        | What                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------- |
| `ca.pem`, `ca-bundle.pem`                            | The identity's CA, alone and appended to this machine's trusted roots           |
| `profile.sh`, `bashrc.sh`, `env.sh`                  | Tool paths and interactive defaults; no credential exports                      |
| `grant-env/<id>.sh`, `tokens/<grant>`                | A token grant's environment, for `mwt exec <id> -- COMMAND` while it is on; its placeholder |
| `bin/git-credential`, `git/<id>`                     | git's credential helper; the hosts a selected token grant answers git for       |
| `bin/mwt`, `bin/mwt-acp`, `bin/mwt-present`          | The [`mwt` command](#agent-channel); the ACP shell; the presentations           |
| `bin/mwt-boot`, `agents-block.md`, `handoff-command.md`, `bin/memo` | What the boot script copies; `memo` when you have OptMem       |
| `AGENTS.md`, `grants.md`, `host.md`                  | What agents are told; what `mwt grants` prints; [your machine](#host-commands)  |

**MWT's layer** is only pointers into `/mnt/mwt`, so one image serves any
identity, the CA changes without a rebuild, and old tags keep working:
`/etc/ssl/certs/ca-certificates.crt` links to `ca-bundle.pem` (a hook in
`/etc/ca-certificates/update.d` restores it when a package regenerates it),
and the per-tool CA variables (`HEX_CACERTS_PATH`,
`CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` and others) point there too;
`/etc/profile.d/mwt.sh` and `BASH_ENV` point at `profile.sh`, so every
`bash -c` reads it, and `/etc/bash.bashrc` loads `bashrc.sh`; git's
credential helper is `bin/git-credential`, which answers with a placeholder
only within `mwt exec GRANT_ID -- COMMAND`, and GitHub's SSH URLs are
rewritten to HTTPS. It also sets the Cache variables, `HEX_HTTP_TIMEOUT`
(Hex's default 15 s is shorter than any approval), Zed's file watcher to
poll every 5 s, and `MWT_SANDBOX=1`.

**The boot script,** `bin/mwt-boot` (POSIX sh, so an image without bash
runs it), runs as root in the VM after each boot (`msb exec`) and copies
what tools expect elsewhere, so a symlink the VM planted leads only inside
the VM: MWT's instructions as a block between markers at the top of
`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, the rest left alone; the
`/handoff` command (`~/.claude/commands/`, `~/.codex/prompts/`); `mwt mcp`
as the MCP server `mwt` for Codex and Claude Code, unless one is there
([MWT's tools in the VM](#mwt-tools-in-the-vm)); `memo` onto the memory
disk, with an empty memory when there is none; `/etc/mwt-vm`, which
`mwt vm` checks against the VM MWT runs; Claude (MWT) and Codex (MWT) in
the VM's `~/.config/zed/settings.json`. It starts `mwt ports --watch`.

**What agents are told** (`priv/sandbox/agents.md`), in short:

- work in `/work`, not in shared folders' one-way copies; a worktree slot
  per task, work left uncommitted for your review, a handoff only when you
  ask, and the VM kept out of the history
  ([Projects and handoffs](#projects-and-handoffs));
- access only from grants (`mwt grants`, `mwt request`, `mwt exec`; no
  logins, no pasted or written tokens), each use possibly waiting for you;
  what the `mwt_*` codes mean; subgrants (`mwt call`, `mwt propose`) before
  `mwt run`, the smallest last resort;
- `mise install` first, ports 4100 to 4199 for what you'll open, notes and
  flash cards only when asked, and their memory (the OptMem block).

<a id="shared-folders"></a>

### Shared folders

You pick each folder. A **git working tree** in it (a `.git` folder or
file, a linked worktree included) reaches the VM only as a
[project](#projects-and-handoffs), a clone of its commits: never in a copy,
wherever it sits, one appearing later included, since a copy would carry
what a repository keeps beside its code (`.env`, ignored secrets, a token
in a remote's URL). **Everything else** is copied one way onto the VM's
root disk, at the same path as here. The VM never writes to your folders.

- **Every 3 s** while the VM runs (less often for a slow folder), MWT sends
  what changed: files, folders and symlinks (as links); other kinds are
  skipped.
- **What the VM changes in a copy stays there:** when MWT next writes a
  path the VM changed, added or removed, the VM's version is first moved to
  `/work/.rescued/TIME/PATH`. At each start and every 5 minutes MWT
  compares the whole copy and puts it right the same way.
- **How** (`MWTClient.Sandbox.FolderSync`): MWT scans the folder (`lstat`)
  against what it last sent this VM (kind, size, mtime to the second, a
  link's target), kept in `…/sandbox/sync/` so a restarted MWT still tells
  your changes from the VM's. A file changed in the last 2 s is sent again
  until it settles; one whose ctime or inode moved is sent anyway. Through
  `msb exec --stream`, a short bash script in the VM sets aside what
  doesn't match what MWT expects where it will write or delete, and deletes
  what you deleted; `tar` here feeds `tar -x` there. MWT reads back only a
  file list (`find -printf`, at a start and every 5 minutes) and a count of
  what was set aside, and runs or parses nothing else. Each boot clears
  earlier delays and asks for a whole comparison at once; a result from
  before a restart or recreate is ignored, and an OptMem sync meanwhile
  doesn't void one.
- **Limits:** 200,000 entries and 4 GiB per folder; past either, nothing
  more is copied, and Settings says why.
- **The copy is the VM's,** sent again after a recreate. A folder you stop
  sharing, or that becomes a repository, keeps its copy as it was, no
  longer updated; nothing at a repository's path is removed or set aside.
  Changing shared folders doesn't recreate the VM.
- **Refused picks** (`MWTClient.Sandbox.Shares`, after resolving every
  symlink): two that overlap, your home folder, credential folders and
  folders holding one (`~/.ssh`, `~/.gnupg`, `~/.optmem`, `~/.aws`,
  `~/.kube`, MWT's data folder, …), a folder inside a git working tree
  (share the repository), a path the VM uses (`/work`, `/cache`, `/root`,
  `/mnt`).
- **Settings** shows per folder: the VM's file count, when last sent, the
  repositories left to projects, what was set aside, any error.

<a id="the-vms-optmem"></a>

### The VM's OptMem

The VM's memory is its own disk at `/root/.optmem` ([Disks](#disks)),
unencrypted like the others and in no backup. MWT reaches it only through
the running VM (`MWTClient.Sandbox.Memory`) and runs nothing from it. After
each boot the VM copies `memo` onto it from `/mnt/mwt/bin/memo` (yours) and
runs `memo init` when it holds no memory. **Syncing with yours,** from the
Memory card (Settings and the overview) while the VM runs:

1. MWT reads the VM's `LOG.txt` through the VM, at most 64 MiB, as data
   (fixed 320-byte records, a partial last one skipped), and lists what it
   noted since the seed point or your last review, at most 1,000 at a time,
   each made to show all it holds. With more, yours goes in only once you
   have seen them all.
2. You tick which to keep; MWT adds them to your memory with `memo note`,
   marked `[vm]`, and memo asks your next agent session for summaries.
   Never automatic: your agents act on their memory, so a planted note
   would be a way out of the VM. For the same reason the VM never gets your
   memory's git repo.
3. Yours goes in: `LOG.txt`, `TREE/` and `config` (what `memo sync` shares,
   work memories included), copied under memo's lock here into
   `memory.incoming` there, and swapped in under memo's lock in the VM (by
   python3), part by part in the same folder, so the lock file stays where
   memo looks. What the VM had moves to `memory.before-TIME`.
4. If the VM's log changed size since step 1, nothing is replaced: it says
   so, and you sync again.

"Only add ticked" does steps 1 and 2. The count the copy held is the seed
point. **Starting from yours** is a checkbox when creating the VM (step 3,
after the first boot). A live swap can't rule out one thing: an agent that
woke with the old memory and runs `memo nap` could have its summary saved
against the new log, if that log's next block has the same numbers (memo
takes only the next block by position); `memo forget` drops it.

<a id="servers-in-the-vm-on-your-machine"></a>

### Servers in the VM, on your machine

A server an agent starts in the VM on a port from 4100 to 4199 opens on
your machine by itself: port 4100 there is `http://127.77.12.34:4100` here
within seconds, gone when it stops.

- **The address:** a fixed `127.77.X.Y` per identity
  (`MWTClient.Sandbox.Ports`). Linux sends all of `127.0.0.0/8` to loopback,
  so it needs no setup, and ports keep their numbers without colliding with
  yours (`localhost:4000` stays yours). No name: one needs root
  (`/etc/hosts`), and every `*.localhost` is `127.0.0.1`. Browsers treat the
  address as a site of its own and a secure context.
- **Only 4100 to 4199** (`Ports.range/0`), as agents are told; other ports
  stay in the VM, unlisted, since language servers, Erlang nodes and test
  listeners take random ones. The range is above Phoenix's 4000 and epmd's
  4369, far below Linux's random ports (32768 up), needs no root, and holds
  this repository's dev servers (`41N0` to `41N9` in slot N).
- **The VM says what listens:** `mwt ports --watch` (bash, `ss`, socat)
  reads `ss -ltnpH` for the range every 2 s and sends the ports, with each
  process's folder, over the agent channel when they change and once a
  minute anyway. Nothing here polls the VM. The report is the VM's word:
  ports must be numbers in the range, names and folders are only shown, and
  a false one can only make MWT listen on the VM's own address.
- **Forwarded:** each such TCP port, on any VM address (`127.0.0.1`, `::1`),
  to the same port on the VM's address here. One something here holds is
  listed with that reason, and tried again after 30 s.
- **The tunnel** (`MWTClient.Sandbox.Forwarder`, `…Forwarder.SSH`): one
  OpenSSH control master to the VM through the launcher running
  `msb ssh serve VM --stdio`, as Zed's entry does; msb carries the
  connections (`direct-tcpip`) to the VM's agent, which connects inside.
  Forwards are added and removed on the master (`ssh -O forward|cancel`).
  Its own key, made on first use and authorized with `msb ssh authorize` on
  each open; no `~/.ssh/config`, no prompt. Dropped, it reopens every 5 s
  with the last report. Only forwards run over it: msb's SSH server frees a
  command's agent connection only when the whole connection ends, and the
  VM's agent relay takes 128 clients, so commands would end the session and
  every forward with it; forwards share one.
- **Where you see them:** the Overview's *Servers in the VM* card, an Open
  link each; each checkout's servers on the Projects page, by their
  process's folder; `host.md` and `mwt ports` for agents. **Kill**, after a
  confirmation, looks up in the VM what holds the port (`ss`) and sends it
  SIGTERM (`MWTClient.Sandbox.stop_server/2`), for range ports only; it is
  logged, and the server leaves the list with the next report.
- **An MWT run in a slot** opens too: in development, the host check and
  `check_origin` take any `127.x.y.z` (`MWTClientWeb.Plugs.LoopbackHost`),
  since an address is never a name DNS rebinding could use; the installed
  MWT keeps the strict list.
- **Safety:** connections go one way, into the VM, on the VM's address
  only, so other machines can't reach them. Any program here can connect,
  as to any dev server, and a VM page is untrusted content. MWT's pages stay
  out of its reach: a `SameSite=Strict` session cookie, the VM's address is
  another site, and LiveView needs a token from MWT's own page. MWT's key
  opens SSH to every VM in its microsandbox home (msb keeps one key list per
  home); it is readable by you only, and anything running as you can run
  `msb exec` anyway.

<a id="vm-monitor"></a>

### VM monitor

The Overview's **Resources** card (`MWTClient.Sandbox.Monitor`, one process
per identity) shows what the VM uses and what it costs your machine.

- **Every 5 s while the VM runs,** one `sh` script in the VM reads `/proc`
  (CPU, memory, load, network, every process's ticks and memory) and `df`
  for Home, Cache and Work: about 5 KB through `msb exec`. The last 10
  minutes stay in memory, never on disk; a gap shows where the VM wasn't
  running. The same sample drives memory sharing.
- **Inside the VM:** CPU busy across its CPUs, load; memory used without
  the file cache (shown apart: programs get it back); bytes per second in
  and out, loopback aside; each disk's use, a meter warning "nearly full"
  at 85% and "full" at 95%; the six busiest processes by CPU (a share of
  one CPU, like `top`) or memory.
- **On your machine:** what the bubble and all under it hold (`/proc`),
  often far less than the VM's figures suggest, and their CPU as a share of
  one core; the space each sparse disk takes (`Disks.used/1`).
- **Shown** as stat tiles (now, out of what, a sparkline whose points give
  value and time), a meter per disk and a process table. What each means,
  the memory target and ceiling, and the disks' total here are behind a
  "?", with a warning sign there on a memory control failure. A failed
  sample says why and keeps the last.

<a id="where-things-live"></a>

### Where things live

Everything belongs to the signed-in identity, in
`~/.mwt_client/identities/<id>/`:

- **Encrypted, like other MWT data:** grants, stored values, allowances, VM
  settings and MWT's CA key, as the `sandbox` document of `library.db`; the
  activity log in `journal.db`: grant changes, swaps, approvals, denials,
  violations and connections (host, IP, port, bytes, duration), never a
  real value. Approvals are in memory only; real values never appear in the
  sandbox process's state dumps (`format_status/1`).
- **Plaintext, in `sandbox/`:** the microsandbox home (the VM, images,
  msb's SSH keys), the disks and Home's snapshots (readable by you only),
  the copies' records, the launchers, and the folder `/mnt/mwt` is copied
  from, with no real value. Home holds the VM's own logins
  (Codex, Claude). On this machine the disk itself is encrypted.

The main modules, `MWTClient.Sandbox.*` in `lib/mwt_client/sandbox/`:

| Modules                                                               | Job                                                          |
| --------------------------------------------------------------------- | ------------------------------------------------------------ |
| `Server`, `Server.*`                                                  | One identity's sandbox: its state, every message, a part per concern |
| `Policy`, `Gate`                                                      | Through, ask or refuse; the network path's view              |
| `Proposal`                                                            | A grant an agent proposes, as the add form's fields          |
| `Grant`, `Param`, `SavedRequest`, `Allowance`, `Approval`, `Check`, `Presets` | Records of access and of what waits for you; grant types |
| `Egress`, `Egress.*`, `Dns`, `Destinations`, `Routes`                 | The proxy; lookups; where an address may go                  |
| `Placeholder`, `Secrets`, `CertificateAuthority`, `Roots`             | Swapping values in; finding them; MWT's CA; the system roots |
| `Describe`, `GraphQL`, `RequestView`, `Chunked`, `Shown`, `Inbound`   | A request as facts; text the VM chose, made safe to show     |
| `Channel`, `Why`, `MwtTools`, `AgentThreads`                          | The `mwt` socket; `mwt why`; `mwt mcp`; Zed's agent threads  |
| `HostCommand`, `HostRun`, `HostInfo`, `Confine`, `Bounded`            | Commands on this machine: checked, run, confined; `host.md`  |
| `Bubble`, `Seccomp`, `Sockets`, `Msb`, `VM`                           | The bubble, its filter and sockets; `msb`; the VM's record   |
| `Settings`, `Resources`, `MemoryControl`, `NestedVirt`, `Monitor`     | How the VM is built; CPUs and memory; nesting; the monitor   |
| `Disks`, `Snapshot`, `Image`, `Build`                                 | The disks and Home's copies; the image and its builds        |
| `Inbox`, `Instructions`, `FolderSync`, `Share`, `Shares`, `Memory`    | `/mnt/mwt`; agents' text; copies in; picks; the VM's OptMem  |
| `Guest`, `Forwarder`, `Ports`                                         | Reaching into the VM; its servers on your machine            |
| `Projects`, `Project`, `Discovery`, `Slots`, `Mirror`, `GitTransport`, `HostGit`, `Zed` | Projects, clones, slots, fetches; opening Zed |
| `Handoffs`, `Handoff`, `HandoffStore`, `Accept`, `TaskBase`           | Handoffs, their store, landing one                           |
| `Firewall`, `Watch`, `Event`, `Exchange`, `Activity`, `Notices`       | The firewall; the activity log; notifications                |

<a id="developing-mwt"></a>

### Developing MWT

- **Your MWT** is the installed package, from a release or
  `./scripts/build-linux.sh`. It holds your real vault and the VM agents
  work in, and loads no code from a folder a VM can write: the VM's work
  reaches your checkout only as handoffs you land. CI builds the packages
  (deb, rpm) when a release is published; a landed change reaches your MWT
  once you install a new build (about 8 minutes for an rpm here).
- **Agents in the VM** work on MWT as a [project](#projects-and-handoffs),
  in a worktree slot, run `mix precommit`, leave the work uncommitted for
  your review in Zed, and hand off when you ask.
- **Trying a change:** a dev MWT with a data folder of its own
  (`MWT_RUN_DIR`: its own identities, microsandbox home and VM), in the VM
  on its slot's ports (`41N0` to `41N9`), which open here. A change to the
  VM is tried on your machine once landed, unless VMs inside the VM is on:
  then `scripts/install-runtime.sh` builds msb once per version into
  `/work/mwt-runtime/runtimes/VERSION` (`MWT_RUNTIME_CACHE`, with its
  source, downloads and Cargo target), copies it into the slot's
  `priv/microsandbox`, and builds the relay, ACP shell and presentations
  from the slot's checkout each time, since branches change them; then
  `mix test --only vm` runs real VMs, in about a minute.

<a id="network"></a>

## Network

All of the VM's TCP reaches MWT as HTTP CONNECT, through the relay to
`proxy.sock`, MWT's proxy (`MWTClient.Sandbox.Egress`), and its DNS goes to
MWT's forwarder ([The VM runs in a bubble](#the-bubble)). msb resolves names
itself and doesn't decrypt TLS, so a CONNECT carries an address and MWT
reads the host name from the ClientHello; msb blocks every other UDP, so
HTTP/3 can't go around the proxy. The bubble has no other network: the VM
can't opt out as it could ignore `HTTPS_PROXY`, and while MWT isn't
listening it has no internet and resolves no name.

Each lookup, connection and request is decided in its own process, from the
**view** the server publishes after every change, before it answers
(`MWTClient.Sandbox.Gate`: grants, the firewall's settings and
isolation, what the scanners look for, the CA), so a call that turned a
grant off returns once every new decision sees it off. Only what waits for
you or puts a real value in a request asks the server, so a busy one makes
nothing wait; the firewall's counts go to `MWTClient.Sandbox.Watch`, which
only counts. With no view (identity locked, server starting), everything is
refused.

<a id="each-connection"></a>

### Each connection

MWT receives `CONNECT <ip>:<port>` and decides, in this order:

1. **At most 512 connections at once** per identity; one more is closed as
   it is accepted, logged once a minute. Heads have deadlines, not idle
   times: the CONNECT within 10 seconds, a read request's head within 30,
   the start of its body read before deciding within 10, so trickling bytes
   can't keep a connection, and what MWT holds for it, alive. Nothing
   moving for 5 minutes closes it.
2. **Deny** loopback, link-local, cloud metadata (`169.254.0.0/16`,
   Oracle's `192.0.0.192` in `192.0.0.0/24`, Alibaba's `100.100.100.200`,
   AWS's `fd00:ec2::254`), multicast, `240.0.0.0/4`, and every address of
   this machine's interfaces, docker bridges included, read each time
   (`:inet.getifaddrs/0`): otherwise the VM reaches anything here that
   listens on all interfaces. An IPv6 address carrying an IPv4 one (mapped,
   SIIT, IPv4-compatible, NAT64's `64:ff9b::/96`, 6to4's `2002::/16`) is
   judged as the stricter of the two, since a host that translates it
   reaches the address inside. Only a network grant that is on and names
   the exact address and port opens one (a database tunnel on loopback,
   say). The VM gets a plain "connection refused"; agents learn why from
   `mwt grants` and `mwt why`.
3. **Public addresses** are the Internet grant's while it is on, held under
   it. Off, a network grant that is on and lists the address opens it,
   waiting for your approval unless an allowance covers it
   ([Approvals](#approvals)). Otherwise the CONNECT is answered 200 and the
   connection may still reach a host a token grant lists: its ClientHello
   must name one, and MWT connects to that host by name. Anything else
   closes, logged as *The Internet is off*; MWT connects nowhere for it
   first, even for a server that speaks first.
4. **Private ranges** (RFC 1918, ULA, site-local `fec0::/10`,
   `100.64.0.0/10`, `198.18.0.0/15`, which local proxies such as Clash hand
   out as fake addresses mapped anywhere, NAT64 prefixes a network chose,
   `64:ff9b:1::/48`) and any address in this machine's own networks
   (`Routes.networks/0`: what its main routing tables send somewhere more
   specific than the default route, such as a LAN neighbour's global IPv6
   address or a VPN's public-numbered network): only when a network grant
   that is on matches the address and port, a name only through MWT's DNS
   answers ([Private networks](#private-networks)). It waits for your
   approval unless an allowance covers the address and port.
5. **Answer within 3 seconds**, because msb gives up on a CONNECT after 10.
   One still waiting for you then gets its 200 and the open tunnel waits;
   a "no" closes it. At most 20 connections wait for you, 10 callers on any
   one; one more is closed.
6. **Peek** at the first bytes: a TLS ClientHello names its host (SNI). A
   client that speaks first does so at once; after 100 ms of silence MWT
   also connects and takes the first bytes from whichever side speaks, so a
   server that greets first (SSH, SMTP, MySQL) is heard in 0.1 s, not 1.5.
7. A host **any token grant lists, on or off,** is read
   ([Each intercepted request](#each-intercepted-request)), so an off grant
   gives a clear answer instead of the provider's auth failure.
8. Anything else is **tunnelled**, unread both ways; the log keeps its
   host, bytes and duration, and the firewall hears the bytes as they flow.

A connection a grant let through (a tunnel a network grant opened, a
request carrying a token grant's value, the session it upgrades to) is held
under it (`MWTClient.Sandbox.Connections`), and closes when the grant is
turned off, removed or out of time
(`MWTClient.Sandbox.Server.Grants.close_ended/1`). It looks at the
grant itself when its time is up, so expiry cuts it even while the server
is busy.

<a id="dns"></a>

### DNS

msb is told `--dns-nameserver 127.0.0.1:5353`, which the relay joins to
`dns.sock`. MWT's forwarder (`MWTClient.Sandbox.Dns`, one listener per
unlocked identity) decides each name from the view, shows it to the
firewall, and passes it to this machine's resolver (the first `nameserver`
of `/etc/resolv.conf`, so VPN names keep working). The answer comes back
unchanged; one cut short over UDP is asked again over TCP. A query aimed at
another resolver gets no answer: msb has no network to send it.

- **Only a standard query of one name goes on**, rebuilt from what MWT
  read: header, question, and EDNS's OPT record without its options. Other
  operations (UPDATE, NOTIFY) get NOTIMP, a zone transfer or a query
  carrying records REFUSED, without reaching the resolver, which may be
  your LAN's. A name not of visible ASCII labels isn't answered. Every name
  is logged with its type, a name again only after 10 minutes.
- **REFUSED, never leaving this machine**: with the Internet off, every
  name no grant lists (a token grant's host, a network grant's name), so
  lookups can't carry data out either; a name a network grant lists while
  none listing it is on ([Private networks](#private-networks)); every name
  while the VM is isolated or there is no view.

<a id="private-networks"></a>

### Private networks

A network grant opens destinations: addresses, ranges and names, each with
its ports ([Grant kinds](#grant-kinds)). Its names lead only where MWT's own
DNS said (`Dns`, `Gate`, `MWTClient.Sandbox.Routes`): a connection there
carries what MWT doesn't read (a database's password, SSH), and a dropped
VPN would leave the grant's ranges to whatever LAN this machine is on,
often one using the same ranges.

- **A destination may be a name, or every name under one**:
  `db.corp.example:5432`, `*.corp.example:443` (the name and every name
  under it, as a token grant's hosts).
- **Names are bound by MWT's own DNS answers.** A name a network grant
  lists is answered only while one listing it is on, the Internet on or
  not; off, it is refused and logged ("Not looked up: Corp is off"). The
  addresses answered (A and AAAA, through CNAMEs) are kept for that name
  for the answer's shortest TTL, held between 1 and 10 minutes, 64 names an
  address at most. A connection goes under the grant by a name only to an
  address kept for a name it covers, on a port it lists; nothing is
  resolved at connect time. The table sits beside the view, written by DNS
  and read by connections, never through the server.
- **TLS goes on only with a name answered for that address.** A connection
  the grant opened by a name, whose ClientHello names a host, is refused
  unless that name was answered for the address and the grant covers it,
  so an address shared by many names (a load balancer, an ingress) opens
  for the grant's names only. One opened by a listed address or range isn't
  checked; one without a TLS name (a database, SSH) goes on.
- **Its own DNS server** (`Grant.resolver`, `10.8.0.1` or `10.8.0.1:5353`)
  is asked its names instead of this machine's resolver.
- **A way out** (`Grant.anchor`, `wg0`, `tun0`, `utun4`): the interface its
  addresses are reached through. MWT asks the system which interface routes
  an address (`ip -j route get` on Linux, `route -n get` on macOS, kept 3
  seconds); while it isn't the anchor the grant opens nothing
  (`{:refuse, {:network_down, grant}}`) and its DNS server isn't asked. On
  Linux the connection and the query to its DNS server are also bound to
  the interface (`SO_BINDTODEVICE`), so a route that changes after the
  check can't take them elsewhere; macOS has the check only. A range with
  no way out opens on any network this machine is on. The form calls it
  *Only through the VPN interface*, with the DNS server under *More*.
- **Agents hear it**: `mwt grants` says a grant's names resolve only while
  it is on, and nothing opens while its way out is down; `mwt why NAME`
  says whether MWT answered it, or "its network isn't connected".

<a id="each-intercepted-request"></a>

### Each intercepted request

1. **Finish the TLS handshake** with a certificate MWT's CA makes for that
   host name, offering HTTP/1.1 only. A gRPC client fails on a host MWT
   reads and works tunnelled, so keep gRPC hosts off token grants.
2. **Read the request head, strictly.** MWT judges a request by what it
   read, and the host must act on the same thing, so a request two parsers
   could read two ways is refused (`400`, `mwt_bad_request`):
    - the target a path, not a full URL, in visible ASCII as HTTP says
      (anything else arrives percent-encoded or not at all);
    - exactly one `Host`, the TLS host name (`421` otherwise): a mismatch
      would let a request say "github" to MWT while going somewhere else;
    - one numeric `Content-Length` or `Transfer-Encoding: chunked`, never
      both;
    - every header line `name: value`, a name of token characters only, no
      folded lines, no space before the colon; a value of visible bytes,
      spaces and tabs, only those around it dropped, no other control
      character, no bare CR or LF;
    - lines ending in CR LF, a head of at most 64 KiB (`431`);
    - no `TRACE` or `CONNECT` (`405`): a host answers `TRACE` with the
      request it got, real value included;
    - no method override (`X-HTTP-Method-Override`, `X-HTTP-Method`,
      `X-Method-Override`; `400`): MWT would show, and an allowance would
      match, a `POST` the host carries out as a `DELETE`.

   A TLS name that isn't a host name (letters, digits, dots, dashes,
   underscores) names nothing: the connection is passed through unread,
   under its address.
3. **Look for real values** in every header, Basic decoded, and the start
   of the body. One there means the VM holds a credential it should never
   have had: refused (`403`, `mwt_value_blocked`), never described, logged
   or shown, and the firewall hears of it ([Rules](#rules)).
4. **Look for placeholders** in every header; Basic auth, whatever the case
   of its scheme, is decoded and checked inside.
    - One of a grant that doesn't list this host, in a header, the target
      or the body (as it streams too): blocked (`403`,
      `mwt_placeholder_blocked`) and recorded as a violation
      ([Rules](#rules): *Credential sent elsewhere*).
    - Only a header gets a value. One in a header that isn't one of its
      grant's carriers is refused (`403`, `mwt_not_a_carrier`, naming the
      header and the carriers); one in the target or the body of a host its
      grant lists goes on as it is. A request carries one grant's
      placeholder at most (`403`, `mwt_multiple_grants`).
5. **No placeholder**: forwarded unchanged, the rest of the body still
   looked through for real values ([What comes back](#what-comes-back)).
6. **Grant off or expired**: `403` with
   `{"code": "mwt_grant_off", "grant": "...", "error": "... mwt request <id> ..."}`;
   held off by its checks, `403` `mwt_check_failing` ([Checks](#checks)).
7. **Grant on**: the request is described
   ([Describing requests](#describing-requests)); an allowance covering it
   lets it through, otherwise it asks.
    - **Ask** holds the request: MWT reads the head and the start of the
      body (at most 64 KiB, enough to describe it), then stops reading
      until you decide. TCP flow control makes the client wait, so a large
      upload is not buffered.
    - Not decided within the hold timeout (3 minutes by default): `403`,
      `mwt_approval_timeout`. Hex gives up after 15 seconds on its own, so
      the image sets `HEX_HTTP_TIMEOUT` above the hold ([The image](#the-image)).
    - Clients retry (Hex after its timeout, gcloud after an error). A
      request the very same as one waiting, as MWT read it (grant, method,
      target, every header in order, the body read so far), joins that
      approval, and your decision answers both. One that differs in
      anything, if only where the placeholder sits, is another card: a
      decision covers what its card shows.
    - Each held request keeps what MWT read, shows on Approvals and raises
      a notification, and the VM decides how many it sends: at most 20
      wait at once, 10 callers on any one; one more gets `429`
      `mwt_too_many_waiting` at once.
8. **On allow**: get the value (minting it if needed), put it in the
   carrier, ask for an answer without content encoding
   (`Accept-Encoding: identity`), and connect to the real host, resolved
   with MWT's own DNS, verifying TLS normally. The address the VM asked for
   is ignored, so a forged `/etc/hosts` entry can't redirect a credential.
9. **Read the response back** as HTTP, letting none of the real value
   through ([What comes back](#what-comes-back)).

One request per connection: MWT sends the head it wrote itself, with
`Connection: close`, so each request is judged on its own and turning a
grant off affects the very next one. The real value is written once, into
that head; what the VM sends after it (the body, and anything behind it)
goes on as bytes MWT never wrote a value into, so a second request hidden
there reaches the host with its placeholder, which opens nothing.
`Upgrade` (WebSockets): the handshake goes through these steps, then the
bytes are tunnelled, still looked through as below.

<a id="what-comes-back"></a>

### What comes back

MWT reads the whole response, not only its first head: a service may copy
the header it got into its answer, echo it in a body, or send it in the
head after a `103 Early Hints`. Looking costs less than the TLS the bytes
already go through (about 8 GiB/s a core for one value). It looks for each
form the value left in, in this request: as it is, as the carrier's value
MWT wrote (a Basic credential's base64), and JSON-escaped and
percent-encoded where those differ.

- **Every head** (`1xx` answers, the final head, a chunked body's
  trailers): the value is replaced with the placeholder.
- **The body**, read through its framing (`Content-Length`, chunked, or up
  to the close), gzip and deflate decoded for the look only, so a value
  split by chunks or compressed is still found. Found, the connection is
  cut before any byte of the value goes: the answer stops short, the log
  says why, and the firewall hears of it ([Rules](#rules)). Replacing it
  would change the body's length, and an answer that copies credentials
  isn't worth keeping.
- Bytes are held back only while the last of them could start the value,
  50 ms at most. A stream that pauses mid-value lets that start through;
  what would complete it never follows.
- **What MWT can't read is refused, not passed on**: a head over 64 KiB,
  framing that doesn't parse, an encoding other than gzip or deflate (MWT
  asked for none). `502` `mwt_unreadable_response` while nothing has gone
  to the VM; cut after.
- Once the final response is whole, the connection ends; after
  `101 Switching Protocols` the bytes are looked through the same way. A
  request MWT put no value in comes back untouched.

The other way, the rest of the request body is looked through for every
grant's real value as it streams (`MWTClient.Sandbox.Egress.Scanner`):
found, the connection is cut before the chunk carrying it goes.

<a id="exchanges"></a>

### What the log keeps of a request

Each request MWT reads keeps what it carried and what came back
(`MWTClient.Sandbox.Exchange`), so an agent's failing call can be read in
MWT: Proxy activity shows both side by side when its line opens. A tunnel
keeps nothing (TLS MWT never opened), and its line says so.

- **The request as the VM sent it**: method, path, headers and the start
  of the body read before deciding, placeholders as the VM wrote them,
  copied before the swap, so the real value is never kept.
- **The response as it reached the VM**, scrubbed as above: status, reason,
  headers, and the body with chunked framing and gzip or deflate undone. A
  refusal, a denial or an unreadable answer is MWT's own JSON, marked as
  from MWT; a cut says why.
- **At most 64 KiB of each body**, inflating no more however small the
  compressed body; a cut one says how long its headers said it was. A body
  that isn't text is kept as bytes; one in an encoding MWT doesn't decode
  (`br`) isn't kept.
- **Real values hidden once more**: the server replaces any token grant's
  real value in it (`Secrets`) with `[real credential withheld by MWT]`
  before keeping it, though none should be there.
- **Kept with its events** (`events.exchange_id`): the connection sends
  it to the server when it ends, and the journal keeps it once per event
  naming it, compressed, in `events_exchanges`, dropped when none does (a
  retry that joined a waiting approval). It goes with its event: by
  retention, by Clear, and in the activity's size.
- **Read when its line first opens**, a body shown up to 4,000 characters.
  Copy as JSON copies the event with its request and response: headers as
  an object, a JSON body as JSON, other text as text, bytes as base64.

<a id="describing-requests"></a>

### Describing requests

An approval shows facts MWT worked out from the request
(`MWTClient.Sandbox.Describe`), not what the agent says.

| Request                                                     | Facts                                                                                                    |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| git over HTTP (`info/refs`, `git-upload-pack`, `git-receive-pack`) | the repository; for a push, each ref update read from the receive-pack commands (`refs/heads/main abc123→def456`); a fetch or a ref listing as such |
| GraphQL (`POST /graphql`)                                   | the type and the fields of the operation a server would run (`mutation`, `createPullRequest`), and the repository its variables name |
| Any other                                                   | method and path (`POST /repos/o/r/pulls`)                                                                |

Every card also names the client (its `User-Agent`) and the header the
credential is in. Text the agent wrote (commit messages, a JSON body's
title, body, message, description or name, a stated reason) is shown in a
separate, labeled area: a claim, never a fact. *Allow similar* covers the
same method, host and path (not the query) through the same header; for
GraphQL, the same document.

A push's ref updates are read from its body as the host reads it:
de-chunked when sent chunked (git does past 1 MiB; a chunk's extension is
skipped, never read as data), and no further than its `Content-Length`
(bytes after it are the next request). Framing two parsers could read two
ways (a signed size, a bare CR or LF, a chunk not followed by CR LF), an
encoded body, or a line git's receive-pack would refuse shows *refs not
read* instead of a guess; a ref list longer than MWT holds says how many it
shows.

A GraphQL document is read with a tokenizer (`MWTClient.Sandbox.GraphQL`),
not matched as text: the operation is the one `operationName` selects, a
comment or a string can't pose as one, an alias is read through to its
field, and fields behind fragments count. An operation's name is its
author's, so *allow similar* goes by the whole document: the same document
with other variables is similar, another with the same name is not.

<a id="text-the-vm-chooses"></a>

### Text the VM chooses

Most of what an approval shows was picked by the agent: paths, header
values, ref and file names, reasons, commit messages, scripts. A raw byte
would break the JSON every page is sent as (UTF-8 only), and a
right-to-left override (U+202E) makes a line read as something else. So
`MWTClient.Sandbox.Shown` makes such text show all it holds: what isn't
UTF-8 becomes `�`, a control or format character is written out (as
`\u{202E}`), tabs and new lines stay. It is applied where the text enters
MWT, so the pages don't have to think about it:

| Way in                         | What happens there                                                              |
| ------------------------------ | ------------------------------------------------------------------------------- |
| A request MWT reads            | The target must be visible ASCII; titles, facts and claims are made to show all |
| The TLS name of a connection   | A host name, or the connection is passed through under its address              |
| A DNS question                 | Visible ASCII labels, or it isn't answered                                      |
| An ask on the agent channel    | Text, whole numbers and yes or no; anything else in it counts as nothing        |
| A script for your machine      | Never changed: one that hides anything is refused, and the agent is told what   |
| A folder for that script       | One whose real name hides anything isn't used: the command runs in your home    |
| A handoff                      | Its title, body, thread, commit messages, file names and diff                   |
| What git says when it fails    | Shown text; what it prints on success stays git's bytes, for MWT to read        |
| A held request, read or copied | Headers, body, the HTTP text and the curl command                               |

A request's pattern, which an allowance is matched on, is compared, so two
that differ stay different once made safe to show: one that had to change
carries a digest of what it was. A script that mixes alphabets in one word
(`gіthub.com` with a Cyrillic `і`) gets a hint on its card, not a check.

Sizes are the VM's to choose too. MWT reads at most 32 MiB of what one git
command prints and fails past that; of a handoff's diff it reads the first
2 MiB and 6,000 lines and says so; and a handoff may bring at most 1 GiB of
new data into MWT's store (the fetch runs under a file size limit, and what
a stopped fetch left is removed).

<a id="what-enters-the-vm"></a>

### What enters the VM

`Shown` covers every way into MWT; `MWTClient.Sandbox.Inbound` covers every
way MWT moves something into the VM. It looks for:

- **real values**: every token grant's value at hand, in every form MWT
  knows (as it is, JSON-escaped, percent-encoded);
- **credential shapes**: a PEM private-key block (an OpenSSH, RSA, EC or
  PGP private key), a three-segment JWT, and a short list of well-known
  prefixes followed by a long token (`ghp_`, `github_pat_`, `glpat-`,
  `xox?-`, `sk-`, `sk_live_`, `AKIA`, `AIza`, `ya29.`, `npm_`, `pypi-`,
  `hf_`, `tskey-`, `dop_v1_`, `SG.`, `shpat_`, `glc_`, `lin_api_`,
  `dp.pt.`, `PMAK-`). Prefix and length, never a regex you write. A
  grant's own placeholder is not one.

| Way in                          | What happens                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------ |
| A proxy answer                  | [What comes back](#what-comes-back) (`Egress.Response`): a real value in it cuts the connection  |
| A command's output              | Looked through. A real value holds it for you; a shape holds it when the firewall rule blocks    |
| A request subgrant's answer     | Every grant's value written out as `[NAME's token]`, in every form; a shape holds it as above    |
| A result of MWT's tools         | Every grant's value written out. Shapes aren't looked for: your notes are yours                  |
| MWT's own files in `/mnt/mwt`   | Nothing: MWT wrote them, and none holds a real value                                             |
| Shared folders                  | Not looked through (see [Later](#later))                                                         |

- **Held, it waits on its card**, with which line and what it looked like,
  never the text: *Send it to the agent* or *Keep it*. Auto-approve never
  releases it. The agent hears what it hears for output you
  kept.
- **The firewall rule** *Credential entering the VM* (Block by default)
  decides for shapes: Alert sends it and tells you, Off sends it. A real
  value in a command's output always waits. It never isolates: the VM did
  nothing wrong.

<a id="grants"></a>

## Grants

A grant is one piece of access you turn on and off, for a time or until
turned off, with your own words for what it is for, which agents read
(`mwt grants`) to find the one they need. Changing a grant's state,
allowances or value never restarts the VM.

<a id="grant-kinds"></a>

### Grant kinds

You add grants of three generic types, none tied to a provider: token,
network and command. A token grant's request subgrants are a fourth kind,
and MWT's own built-in tools a fifth. Agents may propose any of the first
four; what they propose waits off for you to review
([Proposed grants](#proposed-grants)).

| Type      | What the VM gets                                                              | Approval                             | Turning it off                                                                                                                         |
| --------- | ----------------------------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| `token`   | A placeholder, only for a command run with `mwt exec`                         | Per request                          | Takes effect on the next request; one still open (an upload, an upgraded WebSocket) is cut. Complete, since the VM never had the value. |
| `network` | Reachability to listed hosts, ranges and ports ([Private networks](#private-networks)) | Per connection                       | New connections refused, open ones closed                                                                                              |
| `command` | Nothing. It may ask MWT to run a command on your machine ([Host commands](#host-commands)) | Per run; a subgrant may auto-approve | New asks refused. A command already running goes on until it ends or you stop it.                                                       |
| `request` | Nothing: a token grant's subgrant ([Request subgrants](#request-subgrants))   | Per call; may auto-approve           | New calls refused                                                                                                                      |
| `mwt`     | Nothing: MWT carries out each call itself                                     | Per use; may auto-approve            | The next call is refused, naming the grant and how to ask for it                                                                       |

Expiry and removal end a grant the same way, at once
(`Server.Grants.close_ended/1`).

**Built in**, for every identity: the **Internet** (`internet`), below;
**Ask to run commands** (`commands`), the escape hatch, disabled by
default ([Ask to run commands](#ask-to-run-commands)); MWT's tools,
`mwt-read`, `mwt-create`, `mwt-change`
([MWT's tools](#mwt-tools-in-the-vm)); and the projects' Git, `git-fetch`,
`git-fetch-remote`, `git-handoff` ([Git grants](#git-grants)), the last
six `kind: :mwt`. They are never removed, hold no value, keep MWT's words
and have no *Edit*; their switch, duration, approval mode and start
setting work as any grant's.

**The Internet** is a network grant for every public address; private and
reserved addresses are never its. It is enabled on startup unless you
choose otherwise, and never asks per connection: a card could show only an
address. Off, the VM reaches only a token grant's hosts (read by MWT, which
connects by name) and network grants' destinations, public ones included,
and DNS answers only names some grant lists ([DNS](#dns)). Turning it off,
its time running out or an isolation closes every connection it let
through; a release turns it back on when it was on as the VM was isolated. Agents reach their model's API over the internet: with it off
they stop, unless a network grant lists it (`api.anthropic.com:443`).

A token grant names:

- the **hosts** its value may go to;
- its **carriers**, the headers the value travels in: `Authorization`
  unless you name others (`X-Api-Key`), Basic credentials included. A
  placeholder in any other header is refused (`mwt_not_a_carrier`): a
  header the service copies into its answer would hand the value back;
- **variables** holding the placeholder (`GH_TOKEN`), and variables naming
  the **token file**, `/mnt/mwt/tokens/<grant>`, always there
  (`CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`);
- whether **git** over HTTPS gets it, from MWT's credential helper, for its
  exact hosts (not its `*.` entries);
- how the placeholder **starts** (`ghp_`, `sk-`), for clients that check;
- where its real value comes from, who uses it, and its presentations,
  below.

**`mwt exec GRANT_ID -- COMMAND [ARG...]`** is the only way a placeholder
reaches a command (`mwt exec github -- gh api user`,
`mwt exec github -- git push`):

- It runs here in the VM, with exact arguments, stdin and exit status. It
  loads `/mnt/mwt/grant-env/<id>.sh`, which MWT rewrites when the grant
  changes: on, the placeholder in its variables and the token file in its
  file variables; off or expired, a refusal.
- When it doesn't run the command (the grant off or unknown, a wrong use)
  it exits 125, as `env` and `timeout` do, with a line on stderr; any
  other status is the command's own. Nested,
  `mwt exec github -- mwt exec hex -- COMMAND` gives both grants, and
  `MWT_TOKEN_GRANT` lists them.
- Git's credential helper answers only inside it, for the selected grants'
  hosts. Outside, for a host a grant covers, it answers nothing and says
  on stderr which grant to run git through: git alone would only fail to
  read a username, which reads like a login to set up.
- Ordinary shells, editors' environment probes and public downloaders get
  no token variables, a grant on or off, and a new grant doesn't change
  the VM's environment.
- The scope is explicit, never inferred from process names, and no
  security boundary: the command's requests still meet the proxy's checks
  (the grant on, the host listed, your approval).

<a id="who-uses-its-value"></a>

### Who uses its value

A request subgrant needs a token grant above it; if the VM could always
send that grant's placeholder, "MWT sends this one request" would come
with "the VM may send any request", one switch away. So a token grant
says who wields its value (`Grant.reach`):

| Reach                                             | The VM gets                                             | Its own switch           |
| ------------------------------------------------- | ------------------------------------------------------- | ------------------------ |
| **The VM, through mwt exec** (`:vm`, the default) | a placeholder, variables, the token file, git's helper | as any grant             |
| **Only its subgrants** (`:subgrants`)             | nothing: no placeholder, no variable, no file          | none: nothing to turn on |

- **Only its subgrants:** `/mnt/mwt` holds no `tokens/<id>` and no
  `git/<id>`; `grant-env/<id>.sh` only says no, so `mwt exec ID` exits 125
  naming the subgrants to call; `mwt request ID` answers there is nothing
  to turn on; `mwt grants` says "for its subgrants only". Its request
  subgrants depend only on their own switches, and a
  confined command may name it ([Confined commands](#confined-commands)).
- **Its hosts aren't read** on the VM's connections (`Policy.reads?/2`),
  and with the Internet off DNS doesn't answer them for it. Its
  placeholder, made once, is refused with `mwt_subgrants_only` wherever
  MWT reads it, and sent to a host it doesn't list is still *Credential
  sent elsewhere* ([Rules](#rules)); sent to its own host it is refused
  only if another grant lists that host, since nothing else reads it.
- **Changing it to Only its subgrants** turns it off as turning it off
  does: allowances end, what waited is refused, what it let through is
  closed. Its form then hides the variables, token file, git and prefix;
  the hosts stay, since a subgrant's URL must be on one.

<a id="where-real-values-come-from"></a>

### Where real values come from

- **Stored** in the identity's vault.
- **Minted:** a command run on the host that prints a short-lived token
  (`gcloud auth print-access-token --impersonate-service-account=…
  --lifetime=1800s`). Prefer this: the long-lived credential never leaves
  your host tools. It runs as you, unconfined: the one place that touches
  your login.
  - It is told `MWT_GRANT`, and, for a grant minted **per host**
    (`Grant.mint_per`), `MWT_HOST`: one grant then serves tokens bound to
    where they go, each kept apart. A confined command, which has no
    single host, can't name a grant minted per host.
  - It prints the bare value, kept 10 minutes, or
    `{"value": "…", "expires_in": 1800}`, kept until a minute before it
    expires; JSON with no `value` is an error.
  - The grant is looked at again once the value is at hand: one turned
    off, out of time or no longer listing the host while it ran sends
    nothing (`mwt_grant_off`).
  - Every value kept, each host's included, is among what the proxy looks
    for. A value that depends on the request itself (its path, its method)
    is a signature, which a mint can't make.

<a id="presentations"></a>

### Presentations

Every token grant has three ways to reach a tool: variables, the token
file, git's helper. Tools that find credentials otherwise (a helper they
call, a local server they ask) get a presentation: a small program,
`/mnt/mwt/bin/mwt-present` (`native/mwt_present`, static, built as
`mwt-acp` is), that shows a placeholder the way a tool family expects. It
holds only placeholders, so adding one is no trust decision. A grant names
the ones it needs (`Grant.presents`); `mwt exec` runs the command under it,
so it owns the child, its signals (passed on) and its exit status, and
nothing of it is left once the command ends.

The one there is: **a cloud metadata server** on a loopback port, with
`GCE_METADATA_HOST` and `GCE_METADATA_IP` set (with only the first, a
client library's detection ping goes elsewhere). Every path but `/` needs
`Metadata-Flavor: Google`, as the real one does:

| Path                                        | Answer                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| `/`                                         | 200, with `Metadata-Flavor: Google`                                       |
| `…/project/project-id`                      | the project you named                                                     |
| `…/instance/service-accounts/default/`      | JSON: `email`, `scopes`, `aliases`                                        |
| `…/instance/service-accounts/default/token` | `{"access_token": placeholder, "expires_in": 600, "token_type": "Bearer"}` |
| `…/universe/universe-domain`                | `googleapis.com`                                                          |

Its settings travel in variables (`MWT_PRESENT…`) that reach the
presentation, never the command. The add form offers it on Google Cloud
grants only: gcloud reads the token file, and only Google's client
libraries look for a metadata server.

<a id="presets"></a>

### Presets

Adding a grant, you pick its type, or a preset for a tool whose details
are known. A preset only fills the form: what it makes is a plain grant you
can edit, and nothing looks at the preset again. A preset is a JSON file
(`MWTClient.Sandbox.Presets`): MWT's under `priv/sandbox/presets/`, yours
in the identity's folder, `sandbox/presets/*.json`, both in the add
dialog. It holds:

- `name`, `icon`, a one-line `blurb` and the `guide` shown when adding;
- `grant`, the form's fields (hosts, carriers, variables, a presentation,
  a mint command…), and `fill`, fields you fill first, each with a label
  and an example, `{name}` marking where it goes in the grant's fields and
  its subgrants' (only one still written somewhere must be filled);
- what the form doesn't hold: `request_headers` (what its request
  subgrants start from), `tools` (what a command's card says it covers),
  `checks` and `subgrants`.

Everything it gives is copied onto the grant (`Grant.icon`,
`request_headers`, `cli_tools`, `checks`, its subgrants), so removing the
file changes no grant. A file that can't be read is left out, with its
path and why (`Presets.load/1`).

| Preset       | Type                                                                        | VM side                                                 | Hosts                                                |
| ------------ | --------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------- |
| GitHub       | `token`, placeholder `ghp_…`                                                | `GITHUB_TOKEN`, `GH_TOKEN`, git's credential helper     | `api.github.com`, `github.com`, `uploads.github.com` |
| Hex          | `token`                                                                     | `HEX_API_KEY`                                           | `hex.pm`, `repo.hex.pm`                              |
| Google Cloud | `token`, minted (`gcloud auth print-access-token`), placeholder `ya29.mwt…` | `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` naming the token file | `*.googleapis.com`                                   |

Placeholders look like the real thing where a preset says so, since some
clients check the format. Each grant's placeholder is made once and never
changes.

<a id="setting-up-credentials"></a>

### Setting up each kind of credential

The rule each type's and preset's guide follows: keep the long-lived
credential on the host, give MWT something it can put on the wire, and
give the VM only a placeholder.

| You have                                                                   | Grant                     | How                                                                                                                                                                                                           |
| -------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A token or API key                                                         | token, stored             | Paste it once; it lives in your vault.                                                                                                                                                                        |
| A CLI login on the host (`gcloud auth login`, `gh auth login`, `az login`) | token, minted             | A command that prints a short-lived token, run on the host when needed (`gcloud auth print-access-token`, `gh auth token`, `az account get-access-token --query accessToken -o tsv`). The login stays there. |
| A token for a few fixed API calls                                          | token, only its subgrants | Request subgrants, which MWT sends itself; the VM holds nothing of it.                                                                                                                                        |
| Something only reachable from here (VPN, a database through a tunnel)      | network                   | List the destinations; for a database, run the tunnel on the host and list its exact address.                                                                                                                 |
| A key or file a tool reads for one job (SSH keys, a kubeconfig, signing)   | command subgrant          | Your script runs here, confined with the values it names, and only its output goes back.                                                                                                                      |
| Something a process in the VM must read for long (a client certificate)    | file                      | Last resort, labelled: the VM holds the value while the grant is on.                                                                                                                                          |
| Something none of these covers                                             | Ask to run commands       | One command the agent writes runs here, with your approval each time.                                                                                                                                         |

Agents don't see the guides. They see each grant's own words (`mwt
grants`), and describe what's missing in theirs (`mwt request --need`).

<a id="checks"></a>

### Checks: *Only while…*

MWT can't know whether what a grant depends on is there; you do. So a
grant can carry conditions, *Only while…* on its page (`Grant.checks`,
`MWTClient.Sandbox.Check`): scripts of yours whose exit 0 says the
condition holds, named as the condition ("the VPN is up").

- **When:** before the grant turns on (by you, an agent's ask, its start
  setting, the firewall's release), once a day while it is on, and on *Run now* or when
  added. Results are kept, so a restart doesn't make a grant that passed
  wait; an enabled grant's checks run again as MWT starts.
- **A condition pauses the grant until it holds**: never run, failed last,
  or, daily, not run in over a day. Paused, every use is refused
  (`mwt_check_failing`), and a network grant opens nothing.
  One that fails turns the grant off, refuses what waited on it, and tells
  you. (A check saved as not gating only tells you; the form makes none.)
- **It runs confined** ([Confined commands](#confined-commands)), in a
  folder of its own, for at most a minute, with a token grant's own real
  value in its variables and token file.
- **Its output, the first 4 KiB, is for you only**, on the grant's page.
  Agents hear its name: `mwt grants` says *paused: its check "the VPN is
  up" doesn't hold*, and so does every refusal.
- **On the page:** each condition with a dot (holds, failed, running, not
  run), when it last ran, *Remove* and *Run now*; *Add a condition* takes a
  name and the script. A paused grant has *Paused* on its card.

<a id="grants-and-subgrants"></a>

### Grants and subgrants

A **subgrant** is one fixed use of a grant, stored under it, which MWT
carries out when an agent calls it by id: a function, with a body that
never changes and parameters the agent fills in.

```
mwt call gh-repo-view REPO_NAME=oliveigah/klife --reason "check the default branch"
```

| Grant               | Subgrant type | Its body                               | Who carries it out                                                                    |
| ------------------- | ------------- | -------------------------------------- | ------------------------------------------------------------------------------------- |
| Ask to run commands | `command`     | Your script, and the folder it runs in | This machine, confined or as you ([Confined commands](#confined-commands))            |
| A token grant       | `request`     | Method, URL, headers and body          | MWT, from this machine, with the real value ([Request subgrants](#request-subgrants)) |
| Network, file       | none          |                                        | The VM connects or reads the file itself: nothing to stand in for                     |

**A saved command is a command subgrant of Ask to run commands**: your
script, in your folder, which agents call by id and send no text for. It
starts off like any grant (saved from a card, on for 1 hour, asking each
time), new ones run confined, and `mwt grants` and the Grants page show it
under Ask to run commands. Asking, approving and running are in
[Host commands](#host-commands).

- **Never in the VM.** The agent is root there and can replace any tool,
  so a command MWT started there would prove nothing. What VM tools do
  with a grant (`mwt exec github -- git push`) stays a use of the grant;
  for an API call, a request subgrant is better: nothing in the VM holds
  even a placeholder, and you read the exact request.
- **By id, never by match.** MWT never takes a command or a request as
  "the same as" a subgrant: an ad-hoc command with a subgrant's exact text
  still waits for you, with a hint naming the subgrant. A name is not
  enough.
- **A switch of its own**, on or off, for a time, asking or auto-approved,
  apart from its grant's: `gh-repo-view` can be enabled on startup and
  auto-approved while Ask to run commands stays disabled.
- **Removing a grant** removes its subgrants.

#### Parameters

Each has a name, a shape and a line saying what it is, which you and
agents both read.

| Shape     | A value is                                                                                                                                                                                                                             |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `word`    | Letters, digits and `_ . - @ : +`, in parts joined by `/`: `oliveigah/klife`, `v1.2.0`, `lib/app.ex`. No spaces, no part `.` or `..`, no leading `/` or `-`: it goes deeper, never up or to the root, and never reads as an option. Up to 200 bytes. |
| `number`  | Digits only, up to 18.                                                                                                                                                                                                                 |
| `date`    | `YYYY-MM-DD`, a real day.                                                                                                                                                                                                              |
| `time`    | RFC 3339: `2026-11-17T12:00:00Z`, or with an offset and a fraction of a second.                                                                                                                                                        |
| `decimal` | Digits, with a leading `-` and a fraction if it has them: `-12.50`.                                                                                                                                                                    |
| `a\|b\|c` | One of the values you listed.                                                                                                                                                                                                          |
| `text`    | Anything that shows, spaces and lines included, up to 4 KiB, not starting with `-`.                                                                                                                                                    |

- **Names** are capitals, digits and underscores (`REPO_NAME`). One the
  environment already has, or the shell, the loader or git give a meaning
  to (`PATH`, `IFS`, `LD_…`, `GIT_…`, `BASH_…`), is refused.
- **A command reads them as environment variables**, its script run
  exactly as saved, so a value can't add a command, a pipe or a redirect.
  Every parameter must appear in the script as `$NAME` or `${NAME}`: a
  value reaches a tool only where you see it go. Saving hints at a `text`
  or list parameter outside double quotes (spaces would split it) and one
  inside single quotes (left as it is): hints, not a review.
- **A call is checked before anything runs or waits:** every parameter
  given once, none unknown, each value of its shape and showing all it
  holds ([Text the VM chooses](#text-the-vm-chooses)). The agent hears
  what is wrong, with the parameter's line.
- No defaults and no optional parameters: two uses that differ in more than
  values are two subgrants.

#### Calling one

```
mwt call ID [NAME=value …] --reason "why now" [--timeout 120] [--wait 60]
```

The subgrant must be on; off, the agent asks with `mwt request ID`. The
card shows the script unchanged, each value under it: run it, with the
output sent back or shown to you first, or decline. An auto-approved one
runs at once, and the log keeps its values. The same subgrant with the
same values as a call already waiting joins it. Exit statuses are those of
`mwt run` ([Host commands](#host-commands)); `mwt run ID` also calls a
subgrant with no parameters.

#### Proposing one

```
mwt propose GRANT --name NAME --for "what it does, any time it runs" \
    [--param 'NAME:shape:what it is' …] [--dir DIR] --reason "why you need it" -- SCRIPT
```

- It is saved at once, off and to review, as every grant an agent proposes
  is ([Proposed grants](#proposed-grants)), and confined, as a subgrant you
  add starts. Its page shows the script, folder, parameters and hints;
  *Accept and enable* turns it on, asking each time, for the agent's
  `--minutes` (60 by default). The agent hears its id and how to call it.
- It needs nothing to be on: Ask to run commands can stay off for good.
  `GRANT` is the grant it would sit under: `commands`, or a token grant
  for a request ([Request subgrants](#request-subgrants)).
- Agents are told to design one for whoever approves it: one job, a name
  that says it, the fewest parameters of the narrowest shapes, a script
  read at a glance, nothing that changes anything unless that is its job,
  raw output to work on in the VM.
- *Save as a subgrant*, on the card of an ad-hoc run, opens the same form
  with the command as sent, to turn what varies into parameters.
  `--suggest-save` on `mwt run` still leads the card with it; agents are
  told to propose instead.

#### Editing

Every grant and subgrant but the built-in ones has *Edit*, which opens the
form it was added with, filled in, and checks it as adding does. It keeps
its id, its placeholder and value (replaced on its page), its kind, the
grant it sits under, and its state, duration, approval mode and start
setting. An edit to one that is auto-approved applies to the next use
without asking: the form says so. The log records the edit.

<a id="request-subgrants"></a>

### Request subgrants

A subgrant of a token grant is one HTTP request MWT sends itself, with the
grant's real value (`MWTClient.Sandbox.SavedRequest`):

```
mwt propose github --name "pr view" --for "Shows a pull request" \
    --param 'REPO:word:the repository' --param 'PR:number:the pull request' \
    --method GET --url 'https://api.github.com/repos/$REPO/pulls/$PR' --reason "…"
mwt call pr-view REPO=oliveigah/klife PR=7 --reason "review it"
```

- **The template:** a method (GET, POST, PUT, PATCH, DELETE), a URL, fixed
  headers and, unless a GET, an optional JSON body. Proposed with
  `--header 'Name: value'` (repeatable; without it, the preset's) and
  `--data 'JSON'`; a proposal that breaks a rule below is refused before it
  waits for you.
- **The URL** is `https://` to a host the grant lists, written out (a `*.`
  entry covers a name under it), on the usual port, with no user or `#`
  part. Parameters go in the path or the query as `$NAME`, never the host,
  each percent-encoded where it sits; a `word` keeps its `/` in the path,
  so `$REPO` can be `owner/name`.
- **Headers are fixed**, with no parameters. `{token}` stands for the real
  value where the service takes it (`Authorization: Bearer {token}`), in
  one header at least. MWT writes `Host`, `Content-Length` and the like. A
  new subgrant starts with the headers its grant's preset gave.
- **The body** is JSON. A parameter in it is a whole value, `"$TITLE"`,
  never part of a longer string or a key, so a value can't change the
  body's shape or a query written inside a string. A `number` alone goes
  in as a number. Every parameter appears in the URL or the body.
- **The call's card** shows the request as it will go, every value in place
  and the token as `[GitHub's token]`, the values apart, and who sends it.
  *Run* sends it: nothing to stop, no output to see first.
- **Sending:** no redirects, no retries, no decompression; 30 s by default
  (`--timeout`, up to 300). With no value set, or a mint that fails, it
  doesn't go, and the agent hears why.
- **What comes back:** the body's first 256 KiB on stdout, the real value
  written as the grant's name wherever the service echoed it; status and
  host on stderr. `mwt call` exits 0 for a 2xx, 22 for any other status
  (as `curl --fail`), 124 on timeout, 121 when it couldn't be sent. The log
  keeps the status, never the body.
- **Checked at each call:** the grant must still list the host, or the call
  is refused and the agent told to ask you. The token grant's own switch
  doesn't matter: the subgrant's does.

<a id="when-mwt-starts"></a>

### When MWT starts

Every grant and subgrant has a setting for the state it is in when MWT
starts or unlocks (`Grant.start`):

| Setting                     | At each start                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Disabled** (`:off`)       | Disabled, the default. You, or an agent's ask, enable it for a time.                                  |
| **Enabled, ask** (`:on`)    | Enabled until turned off. Every use still waits for you.                                              |
| **Enabled, auto** (`:auto`) | Enabled until turned off, every use through without asking, still logged. For what you fully trust. |

- Where only one is offered it is just **Enabled**: Ask to run commands has
  nothing to auto-approve, and the Internet never asks. A token grant only
  for its subgrants, and a grant to review, are Disabled only. *Enabled, auto* asks
  you to confirm.
- Choosing a setting puts the grant in that state at once and at every
  start; in between its switch, duration and approval mode change it.
  Every start begins from the settings: a grant left on goes back to its
  setting, and every allowance ends with the session.
- A row or card whose setting isn't Disabled says *Enabled on startup*; its
  Ask/Auto switch shows how uses are approved.

<a id="approvals"></a>

### Approvals

Every use of a grant waits for you: a request carrying a placeholder, a
connection through a network grant, a call of a subgrant, a change through
`mwt-change`. No rules decide by method or path: what a request does
depends on the API, and guessing per provider doesn't generalize. The
shortcuts are allowances (`MWTClient.Sandbox.Allowance`), added on
purpose:

- **Allow similar:** uses like this one (the same method and endpoint, the
  same GraphQL operation, the same address and port, the same item of
  MWT's), for 10 minutes, 1 hour or while the grant stays on. For a
  request the header carrying the credential is part of it, shown among
  the facts; other headers aren't, as they change between runs of one
  tool. A method override is refused for every request
  ([Each intercepted request](#each-intercepted-request)), and the value
  goes only in a carrier.
- **Allow every use:** everything the grant covers, as long; also
  *Auto-approve* ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)).
- Past its time an allowance covers nothing: the clock decides, across a
  restart or a suspend too.

A card's choices: *Allow once*; *Allow for a while*, one menu with both
allowances (this one's pattern written out, and every use), each for
10 minutes, 1 hour or while the grant stays on; deny; *Deny and turn off*.
**Activations**, agents asking for a grant (`mwt request`), wait in the
same queue: you choose how long it stays on and whether each use still
asks ([Agent channel](#agent-channel)).

**A decision answers only what its card shows.** A second ask joins a
waiting card only when it is the very same: a request as MWT read it,
every header in order ([Each intercepted request](#each-intercepted-request));
a command, a subgrant's call or a call of MWT's tools compared whole, by
SHA-256.

**Every card is drawn the same way,** each thing once: who asked and for
which grant, with the time left, on one line; what would happen, as its
title; the thing in full (the request, the script, the change, the grant);
what MWT saw beside what the agent says; your choices. One calm frame;
only text the agent wrote to run as you (an ad-hoc command, its output) is
red.

**A held request shows in full**, as MWT received it: the request line,
every header (placeholders shown as their grant's name, never folded
away), and up to 64 KiB of body, decoded. A line under the title names each
header carrying the placeholder, so one moved to an unusual header shows.
It copies as curl (`$GH_TOKEN` in place of the placeholder, to run with
your own token), as HTTP, or just the body. It stays in memory, never on
disk.

<a id="ask-each-time-or-auto-approve"></a>

### Ask each time or auto-approve

A grant turning on gets a duration and an approval mode (on its row, its
page, an agent's ask), both changed while it is on without turning it off:

- **Ask each time**, the default: every use waits for you.
- **Auto-approve**: every use goes through, still logged in the activity
  log and on the grant's page. It is the *every use* allowance while the
  grant stays on, shown under *Allowed for now*; *Ask each time*, *End
  now* there, or turning the grant off ends it. Requests, connections and
  MWT's tool calls go through; a subgrant's call runs at once, a command's
  output straight to the agent, shown running on the Approvals page with
  Stop and logged as auto-approved with its exit status.
- **Duration:** 15 min, 1 h, 4 h or until turned off. Picked while on, it
  counts again from now: more time, or less.
- Ask to run commands takes a duration only: every ad-hoc run waits for
  you, as its row says.
  A grant that [always asks](#ceiling) has no mode.

<a id="ceiling"></a>

### Always ask me

How unattended a grant may run is one switch on its page, **Always ask
me** (`Grant.ceiling`: `:ask`; off, `:allow`): every use is a card you
allow once, and no allowance or Auto-approve covers one.

- Every grant and subgrant has it (`Grant.ceilings/1`) but the Internet,
  which never asks. Ask to run commands always asks.
- Turning it on, once you confirm, ends every allowance, Auto-approve
  included, and makes a start of *Enabled, auto* *Enabled, ask*.
- Its card has only *Allow once*, its grant no Ask/Auto switch; it has an
  *Always asks* badge, and `mwt grants` says "always asks", so an agent
  doesn't wait for an allowance there.

<a id="proposed-grants"></a>

### Proposed grants

An agent that knows what its work needs proposes the grant, instead of
describing it with `mwt request --need`:

```
mwt propose token --name NAME --for "what it is for" --host HOST [--host …] \
    [--env VAR …] [--file-env VAR …] [--carrier HEADER …] [--git] [--mint 'COMMAND'] \
    [--subgrants-only] [--preset ID] --reason "why"
mwt propose network --name NAME --for "what it is for" --destination 'HOST_OR_RANGE:PORTS' [--destination …] \
    [--resolver ADDRESS] [--via INTERFACE] --reason "why"
mwt propose GRANT --name … --for … …        a subgrant (Proposing one, Request subgrants)
```

- **Checked as the form checks yours.** The ask becomes the add form's
  fields (`MWTClient.Sandbox.Proposal.attrs/3`) and goes through
  `Server.Grants.build_grant/3`; a field that wouldn't pass is refused
  before anything is saved, naming the option it came from. `--preset`
  starts a token or network grant from a preset, MWT's or yours, whose
  fields the agent's override. A token grant needs no value: you paste it
  as you review it. A command subgrant starts confined.
- **Saved at once, off, to review** (`Grant.proposal`: who proposed it,
  from which thread, why, for how long, when, and when you reviewed it).
  It is never enabled on startup (`Grant.starts/1` offers only Disabled),
  and nothing turns it on until you accept it: its switch says to review it
  first, an agent's `mwt request` for it makes a card that only leads to its
  page, and a release from the firewall leaves it off. `mwt grants` says it
  waits for you. It never carries a value, a condition, an approval mode or
  a start setting.
- **Tagged** *Proposed by AGENT* wherever it shows, and *To review* until
  you accept it. The Grants page says how many wait, *To review* is a
  status of All grants, and Overview counts them. The tag stays once you
  accept it.
- **Its page** leads with the review: the agent's reason and thread, the
  hints for a script, and *Accept and enable for N* (the time the agent
  asked; a token grant needs its value first), *Accept, keep disabled*,
  *Edit* and *Remove*. Editing keeps it to review. Accepted, it is yours,
  as any other.
- **The agent waits** as for `mwt request`: exit 0 once you accept it and
  it is on, 2 while it waits (`mwt wait ID`), 3 if you decline its card,
  which removes it; removing it from its page before you accept it says
  the same. Its ask gives up after 30 minutes and the proposal stays, to
  review. Proposing again under the same name while it waits changes it in
  place and joins the same ask.
- **At most 20** wait for review at once; the 21st is refused.

<a id="the-grants-page"></a>

### The Grants page

A catalog: a card for every grant and subgrant.

1. **Enabled**, first and apart, whatever the search or filters: each
   grant and subgrant that is on, with its time left, duration, approval
   mode and switch, all changeable there. Each row has four tags at most:
   *Enabled on startup*, its type, *Subgrant of* its grant, *Built in* or
   *Yours*. Those enabled on startup and still on until off, as MWT left
   them, fold into one row (their icons and names, how many auto-approve,
   how many ask) that opens to their rows and stays open once opened; one
   you changed has a row of its own above it.
2. **All grants**, below, with what narrows it:
   - **Search** over each grant and subgrant's name, purpose, type, hosts,
     variables, destinations, file name, script, folder and parameters:
     every word must match, in any case, as you type; × clears it.
     **Sort**: recently used (the default; never used last, by name), by
     name, or enabled first.
   - **Filters** down the side, status and type, each option with how many
     cards it would show; *Clear search and filters*.
   - **The cards**: type (a subgrant's grant too), name and purpose, what
     it reaches (hosts and variables, destinations, a script, how to call
     a subgrant), its badges (what the VM holds, *Built in*, *Enabled on
     startup*, *Auto-approve*, *Always asks*, *Paused*), and its time left
     or when it was last used. The footer has Enabled's controls, compact.
     A grant that takes subgrants has *+ Subgrant*.
   All grants shows six cards a page, with the pages below it; searching or
   filtering starts again from the first.
3. **A grant's page**: for one an agent proposed and you haven't accepted,
   the review first ([Proposed grants](#proposed-grants)); its start setting, *Always ask me*, *Only while…*,
   its allowances and its own activity, and its subgrants, each with a
   page that leads back to it and shows the script or the request, each
   parameter's shape in words, and how to call it.

<a id="desktop-notifications"></a>

### Desktop notifications

Agents ask while you work in another window, so every approval waiting for
you is also a notification: an agent asking for a grant or to run a
command (saying whose text it is), a held request, a connection, a command
whose output waits for you. It says who asked, for what, the agent's
reason in quotes, and when it gives up. It closes once the approval is
decided or gives up, from any window, and when the vault locks; a command
coming back with its output gets a new one. One you dismiss on the desktop
stays listed in MWT while it waits. Every open handoff is one too (who,
what, onto which branch, its size), withdrawn once you land, close or send
it back, made again for a new revision; as MWT starts, open handoffs are
listed in MWT, not put on the desktop again.

Notifications are MWT's own (`MWTClient.Notifications`), for every app:
the bell in the title bar counts them, and `/notifications` lists them and
holds their switches, per identity, on by default: the desktop as a whole
and each kind (approvals, handoffs), with a test button and what the
desktop answered. Nothing is decided from one: clicking it, or *Review*,
brings MWT forward on the Approvals page with that approval ringed and in
view, where facts sit beside claims. A notification can show neither the
full script nor the request.

On GNOME, MWT keeps one connection open to `org.freedesktop.Notifications`
on the session bus (`MWTClient.DBus.Connection`, a small D-Bus client: SASL
`EXTERNAL`, the wire format for the types it needs): GNOME sends
`ActionInvoked`, `ActivationToken` and `NotificationClosed` only to the
connection that showed a notification, and drops an app's notifications
when it goes away, so `notify-send` can't do it. Notifications name
`desktop-entry` `MWT` (`MWT.desktop`, from the packages), so GNOME shows
MWT's name and icon and lists them under MWT in its settings, where
banners and sounds can be turned off. On Wayland a window takes focus only
with the activation token GNOME sends with the click: MWT passes it to the
page, the page to the shell's `present_window`, the shell to GTK
(`gdk_wayland_display_set_startup_notification_id`, then `present`); on
X11 it is a startup id, and a browser on `mix phx.server` still opens the
approval. With no session bus or service, MWT keeps what it would show and
tries again every 30 seconds. Signals count only from the service that
showed the notification.

<a id="host-commands"></a>

## Host commands

The escape hatch for anything no grant can express. An agent asks to run
one command on your machine; it runs only after you approve that exact
text, once.

It also moves work to where a value is, instead of the value to the VM: a
job that needs your SSH keys, a kubeconfig, a signing key or your VPN runs
here, and only its output goes back. That is why there are no file
grants: the value stays where it is, and the work comes to it. Agents are told to use a grant first: a request through a grant
shows what it does (the describers, the full request), and a shell line
shows only its text.

<a id="ask-to-run-commands"></a>

### Ask to run commands

A command grant (`kind: :command`) gives the VM nothing: it lets agents
ask MWT to run a command on your machine. **Ask to run commands** (id
`commands`) is the one MWT builds in: always there, off at first, with
MWT's name and words, no Edit and no Remove. It turns on for a time like
any grant, is listed by `mwt grants`, and has its own activity.

- **Off, `mwt run commands` is refused,** saying to ask with
  `mwt request commands`. On, it only lets agents *ask*: you read and
  approve every run, and its row says so. No allowance or Auto-approve
  covers one. Turned off, it refuses new asks; a command already running goes
  on until it ends or you stop it.
- **Saved commands are its command subgrants:** your script, in your
  folder, with parameters it reads as variables, which agents call by id
  (`mwt call ID NAME=value`; `mwt run ID` also runs one without
  parameters) and propose with `mwt propose`; see
  [Grants and subgrants](#grants-and-subgrants). They may run
  [confined](#confined-commands), and need no escape hatch, so Ask to run
  commands can stay off.
- **Save as a subgrant,** on the card of a run, opens the add form filled
  in: the script, the folder it would run in, a name (the agent's
  suggestion, else the command's first words) and what it's for (the
  agent's `--save-for`, else empty for you to write; never the agent's
  reason, which is about this run). Saving doesn't decide the card. The
  subgrant turns on for 1 h, asking each time (one set to start enabled
  is on already), and the agent hears, with this run's answer, to call it
  by id next time.
- **An agent may suggest the save** with `--suggest-save NAME --save-for
  "what it does"`: the reason says why this run, the description what the
  command is for any time it runs, so `--suggest-save` alone is refused.
  The card then leads with the save. Agents are told to `mwt propose`
  instead.
- **The same text as a subgrant:** a run whose script and folder match a
  saved command's gets a hint saying so, and the agent hears to call that
  one by id.
- **Small commands.** A card should take seconds to read. Agents are told
  to send the smallest command that gets what they need, to run on your
  machine only what must run there, and to bring the raw output back and
  work on it in the VM. A script over 5 lines, or with 3 pipes or more,
  gets a hint that it is long. *Ask for a simpler one* declines it and
  tells the agent to send the smallest command that gets the raw data.

### Asking

```
mwt host                                       your machine, as agents see it
mwt run commands --reason "…" [--dir DIR] [--timeout 120] [--wait 60] [--suggest-save NAME --save-for "…"] -- COMMAND [ARG…]
mwt run commands --reason "…" [options] <<'EOF'   the script from stdin
…
EOF
mwt wait RUN_ID [--wait 60]
```

- **The one word before `--` is the grant,** so a typo is never run as a
  command. A saved command takes no text: sent one, it is refused, saying
  to `mwt call` it.
- **The script travels in the ask.** Arguments after `--` are quoted for
  the shell and joined; a single argument is a shell line as it is; with
  none, the script is read from stdin. At most 16 KiB. What you read on the
  card is what runs. A script holding anything that doesn't show (a control
  character, a zero-width one, a right-to-left override, bytes that aren't
  UTF-8) is refused before it waits for you, and the agent is told which
  ([Text the VM chooses](#text-the-vm-chooses)).
- **Where it runs:** `--dir`, by default the agent's current directory.
  Shared folders sit at the same path on both sides, so a directory inside
  one runs there, in your folder, once its symlinks are resolved on the
  host. Any other directory (the VM's Work disk, which your machine
  doesn't have), one whose real path leaves its share, or one whose name
  hides something, falls back to your home folder, and the card says so.
- **Time limit:** `--timeout`, 1 to 3600 seconds, 120 by default.
- The same script, directory and limit as an ask already waiting joins
  it. At most ten wait at once.
- The agent waits up to `--wait` seconds (60 by default), then hears the
  ask is still waiting and comes back with `mwt wait`. The ask waits 30
  minutes for you. `mwt host` needs no grant: it only reads.

### Approving

A command is an approval of its own kind, in the same queue, named by its
grant and drawn apart (red, a terminal icon; a subgrant's violet):

- **Facts:** the script in full, with a copy button; who it runs as; the
  folder and what it is (a shared folder, your home folder, the subgrant's
  own); the time limit.
- **Hints,** from the script's text and marked as hints, not a review: it
  runs a script file, whose content the card doesn't show; it downloads
  code and runs it; it uses `sudo`; it deletes recursively (`rm -rf`); it
  mixes alphabets; it is long; a grant already covers a host or tool it
  uses.
- **The agent's reason,** as a claim.
- **Choices:** *Run once, as you*, with the output sent to the agent or
  shown to you first; decline; *Ask for a simpler one*; through Ask to run
  commands, *Save as a subgrant*. No "allow similar": each command runs
  once, as you, outside the VM. A subgrant turned on with Auto-approve runs
  without a card ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)).
- Commands are decided on the Approvals page only, where the card shows
  the script in full; the Overview counts them.

### Running

- `bash -lc SCRIPT` as you, in the directory, with stdin from `/dev/null`,
  under `timeout`: TERM at the limit, KILL 5 seconds later, to its whole
  process group.
- The directory on the card is a real path; the command starts there after
  `cd -P` and a check that the path still leads there. A folder swapped for
  a link since you looked runs nothing, and the agent gets exit 126.
- The environment is MWT's own, without MWT's and the BEAM's variables
  (`RELEASE_*`, `ERL_*`, `ELIXIR_*`, `MIX_*`, `PHX_*`, `MWT_*`,
  `SECRET_KEY_BASE`, `PORT`…), plus a subgrant's parameters; the login
  shell then sets up your usual tools. SIGPIPE, which the BEAM ignores, is
  back to its default (`env --default-signal`, where `env` has it), so
  `cmd | head` ends quietly, as in a terminal.
- Output, stdout and stderr together, keeps its first and last 32 KiB,
  made valid UTF-8; what's between is cut, and the agent is told how much.
- Running commands show at the top of the Approvals page with a Stop
  button, which kills the process group. Locking or quitting MWT stops
  them too.
- **Output shown first:** when the command ends, its card comes back with
  the exit status and the output, to send or keep; not deciding within 30
  minutes keeps it. Output holding a token grant's real value always comes
  to you first, and so does something shaped like one when the firewall's
  rule says so; no auto-approval lets it go
  ([What enters the VM](#what-enters-the-vm)).
- The output stays in memory with the approval (the latest 100 decisions)
  and is never written to disk. The activity log records the ask's fate
  and the exit status, never the output; crash reports leave it out too.
- Some versions of `timeout` exit 124 when stopped from outside as well, so
  MWT counts a run as timed out only when it lasted its whole limit, and
  tells the agent when you stopped it.

<a id="confined-commands"></a>

### Confined commands

As you, a saved command has your home, SSH keys, cloud logins and every
tool's stored session in reach, for one mistake in its script or one
parameter used carelessly. So a command subgrant can run **confined**
(`Grant.confined`, `MWTClient.Sandbox.Confine`), in a bubble on this
machine made with `bwrap`, as the VM's own is:

- user, PID, IPC, UTS and cgroup namespaces of its own. The network is
  shared: it may need your VPN;
- the system read-only (`/usr`, `/etc`, and `/opt`, `/nix`, `/snap` where
  they exist), with the folder `/etc/resolv.conf` leads to, often under
  `/run`, so names resolve;
- an **empty home**, on tmpfs, at your home's path; the folders of it
  commands may read, read-only, each with what it links to one level
  down: where your tools live (Settings, *This machine, for agents*; by
  default those your login shell's `PATH` runs tools from);
- **its folder read-only**, unless it may write there (`writes_dir`). One
  that runs in your home folder itself runs in the empty one;
- **no environment of MWT's**: its home, the `PATH` your login shell has
  (it gets no login profile), your user and language, its parameters, and
  the values below. A value travels in the environment, never the
  arguments, which every account on this machine can read;
- **`with`: the token grants whose real values it gets**, under the same
  variables the VM sees their placeholders in, and in their token files,
  `/mnt/mwt/tokens/<id>`, written from a variable unset before the script
  runs, so a script reads `$SOME_TOKEN` the same way on both sides. Each
  value is fetched (minted where it is) before the run starts; one that
  can't be ends the run, and the agent hears why. Any token grant can be
  named, one only its subgrants use included.

The time limit stays outside `bwrap`, so it still ends the whole command.
There is no silent fallback: where `bwrap` can't make the bubble (on
Ubuntu, a `bwrap` without MWT's AppArmor profile may get no user
namespaces), a confined command doesn't run and says why. Its card says
*Runs: Confined, with the value of: X*, or *Runs: As you*, with what that
puts in reach; the grant's page says the same. New saved commands start
confined; one saved before confinement existed runs as you until you tick
*Runs confined* on its form. **Mint commands still run as you**: they are
the one place that touches your login. Ad-hoc commands (Ask to run
commands) aren't confined.

### What the agent hears

`mwt run`, `mwt call` of a command subgrant, and `mwt wait` on either exit
with the command's own status when it ran and its output came back: 124
when it hit the time limit, as with `timeout`. MWT's own outcomes use
codes commands rarely use, with a line on stderr saying which:

| Status | Meaning                                                    |
| ------ | ---------------------------------------------------------- |
| 120    | Still waiting for you. Come back with `mwt wait RUN_ID`.    |
| 121    | It didn't run, or its output didn't come back: declined (or a simpler one asked for), not answered in 30 minutes, couldn't start, or you kept the output. |
| 122    | The ask was wrong.                                         |
| 123    | MWT isn't answering: locked or closed.                     |

### Your machine, as agents see it

`mwt host` prints, and `/mnt/mwt/host.md` holds: OS and version,
architecture, kernel, your user and home folder, login shell, the shared
folders (a copy in the VM, your folder here), which of a fixed list of
command-line tools are on your login shell's `PATH`, with their versions,
and where servers started in the VM open on your machine
([Servers in the VM, on your machine](#servers-in-the-vm-on-your-machine)).
Then your own notes, from Settings, *This machine, for agents*. MWT looks
for the tools in the background when it unlocks, and when you ask from
Settings; agents are told never to probe the host to find out.

<a id="agent-channel"></a>

## Agent channel

MWT listens on a Unix socket per identity,
`$XDG_RUNTIME_DIR/mwt/<id>/channel.sock` (Unix socket paths are short, so
not the identity's folder; `MWTClient.Sandbox.Sockets`), which
`msb create --vsock /mwt/sockets/channel.sock:5000`, run in the bubble,
joins to the VM's vsock port 5000 (`MWTClient.Sandbox.Channel`). The VM has
no network route to the host. Microsandbox opens the socket for each
connection, so when MWT restarts, the channel works again without touching
the VM. While MWT is locked or closed, the VM gets "connection refused".

Agents use it through `/mnt/mwt/bin/mwt` (`priv/sandbox/mwt-cli`), a Bash
script that talks with socat (in the default image), on every shell's
`PATH`. No agent needs setting up: any agent or script that runs commands
can use it. `mwt help` prints the list:

```
mwt grants                                   every grant: id, what it is for, how to use it, state
mwt exec GRANT_ID -- COMMAND [ARG…]          a command in the VM with a token grant's placeholders (Who uses its value)
mwt request GRANT_ID --reason "…" [--minutes 60] [--wait 60]
mwt request --need "the access, and the host" --reason "…" [--minutes 60]
mwt wait ID [--wait 60]                      an earlier ask, run, call, or change to MWT's items
mwt call ID [NAME=value …] --reason "…"      a subgrant, by id (Grants and subgrants)
mwt propose token|network --name … --for … …           a grant, saved off for you to review (Proposed grants)
mwt propose commands --name … --for … [--param …] [--dir DIR] --reason "…" -- 'SCRIPT'
mwt propose TOKEN_GRANT --name … --for … --method … --url … [--param …] [--header …] [--data …] --reason "…"
                                             a subgrant, saved off for you to review (Grants and subgrants, Request subgrants)
mwt run commands --reason "…" -- COMMAND     a command you approve (Host commands)
mwt host                                     your machine, as agents see it (Host commands)
mwt why HOST[:PORT]                          which grant covers a destination, and why it isn't reached now
mwt ports                                    the VM's servers, and where they open on your machine
mwt mcp                                      MWT's tools over MCP, on stdio (MWT's tools for agents in the VM)
mwt project                                  where you are in a project (Projects and handoffs)
mwt worktree new TASK --from BASE | resume BRANCH | free     take, continue in, or free this slot (Worktree slots)
mwt handoff --title "…" [--body FILE] [--onto BASE] [--no-checks] | withdraw --reason "…"    (Handoffs)
mwt handoffs                                 the project's handoffs and what you did with them
mwt vm                                       which VM this is, and whether MWT runs it
```

The sections named tell the rest ([Who uses its value](#who-uses-its-value),
[Grants and subgrants](#grants-and-subgrants), [Request subgrants](#request-subgrants),
[Host commands](#host-commands), [Servers in the VM, on your machine](#servers-in-the-vm-on-your-machine),
[MWT's tools](#mwt-tools-in-the-vm), [Projects and handoffs](#projects-and-handoffs),
[Worktree slots](#worktree-slots), [Handoffs](#handoffs)). The others:

- **`request`** asks you to turn a grant on, by id or name, for
  `--minutes` (1 to 1440, 60 by default). It shows as an activation
  approval with the agent's reason, marked unverified, and who asked (the
  agent, its thread and folder, read from the processes above `mwt`, so
  also a claim). It waits up to `--wait` seconds (60 by default, 0 not at
  all, 600 at most), then says the ask is still waiting, with its id, and
  exits 2; the agent comes back with `mwt wait`. The ask stays 30 minutes.
- An ask for a grant that doesn't exist yet (`--need`) offers "Set it
  up…", which opens the add dialog; the new grant answers it and turns on.
  Asking again for the same grant joins the waiting ask; one waits per
  grant, ten in all. Turning the grant on yourself answers agents waiting
  for it.
- **`why`** (`MWTClient.Sandbox.Why`) says, a line each, which grant
  covers a host or an address and why the VM doesn't reach it now: the
  firewall isolated the VM or blocks it; a token grant lists the name (a
  request carrying its placeholder needs it on); a network grant covers it
  and is off (with the `mwt request` to send) or lists other ports; the
  Internet grant is off; the address is private or reserved, which the
  Internet never opens; no grant covers it (with the `mwt request --need`
  to send). It reads the view the network path decides from, by the same
  rules (`Policy`), and looks up a name only when some grant names it.
  Agents are told to run it when a lookup or a connection fails.
- **`vm`** tells an old VM from the one MWT runs. MWT gives each VM it
  creates an id and records when, and from which image (`VM`'s `record`);
  the boot script writes the same at `/etc/mwt-vm`, which `mwt vm` sends
  for MWT to compare. Interactive login shells (Zed's terminals) print the
  answer in a line, dim, or red when it isn't the VM MWT runs; agents'
  shells print nothing. The Overview shows the same id.
- While the firewall has [isolated](#isolating) the VM, what acts
  (`request`, `run`, `call`, `propose`, `handoff`) is refused, saying so;
  `grants` and `vm` still answer.

| Commands                                         | Exit statuses |
| ------------------------------------------------ | ------------- |
| `grants`, `request`, `propose`, `wait` on an ask | 0 the grant is on, 1 the ask was wrong, 2 still waiting for you, 3 declined or given up, 4 MWT isn't answering (locked or closed) |
| `project`, `worktree`, `handoff`, `handoffs`     | 0 done, 1 not done (the reason is printed), 4 MWT isn't answering |
| `vm`                                             | 0 this is the VM MWT runs, 1 there is no record to compare, 3 it isn't (or MWT's is stopped), 4 MWT isn't answering |
| `run`, `call`, `wait` on either                  | the command's own status, else 120 to 123 ([Host commands](#host-commands)); a request subgrant 0 for a 2xx answer, 22 for any other |
| `exec`                                           | the command's own status, 125 when `mwt` didn't run it |

The protocol is one connection per ask: one line of JSON in
(`{"command": "request", ...}`, at most 64 KiB, within 10 seconds), the
exit status on the first line back, then text, then close; a run answers
`ran STATUS`, a note for stderr, then the output. Only `attach`, from
`mwt-acp`, keeps its connection ([Agent threads](#agent-threads)). Any
process in the VM can ask; that is accepted, since all it can do is ask.
It can also connect as often as it likes, so what it holds of MWT is
bounded: 64 connections served at once (one more is closed unanswered, and
`mwt` says MWT isn't answering), and MCP messages as
[MWT's tools](#mwt-tools-in-the-vm) say.

<a id="agent-threads"></a>

## Agent threads

MWT's link to the agent threads you run in Zed
(`MWTClient.Sandbox.AgentThreads`). MWT sees each thread of an MWT agent
(its agent, folder, title, and whether it is working) and can say
something in an open one: it arrives in the thread as a message and the
agent acts on it. It knows nothing about handoffs or grants; they use it.
The first use is a handoff you send back: its note goes to the thread that
made it, instead of waiting for you to tell the thread to look.

### Why through ACP

Zed talks to every agent through ACP (Agent Client Protocol): JSON-RPC,
one message per line, over the agent process's stdin and stdout. Zed's
remote server in the VM starts each agent's adapter (`claude-agent-acp`,
`codex-acp`) and pipes to it. A program in that pipe sees every thread of
every agent, and can start a turn in one with the same messages Zed sends.
Nothing else fits both agents: Claude Code's background wake-ups are
Claude's only and die with the session, no Codex hook runs in the
background, MCP has nothing that starts a turn, and Zed has no way to post
into a thread from outside.

### mwt-acp, a thin shell

`mwt-acp` is what Zed starts instead of the adapter. It starts the adapter
and passes every line both ways as it came, unparsed where it doesn't
need to look, so new fields and each adapter's own extensions go through.

- **What it reads**, without changing it: `session/new`, `session/load`
  and `session/resume`, and their answers (a thread opened, its id and
  folder); `session/close` (closed); a `session/prompt` and its answer
  (working, idle); `session_info_update` (the title).
- **What it adds**, only when MWT says so: the message to the agent, and
  a `session/update` of type `user_message_chunk` to Zed, so it shows in
  the thread as a message. When the agent offers `_session/steering`
  (both adapters do, in `initialize`'s `_meta`), the shell steers first,
  opting in to `idleBehavior: "promptRequired"`: the message joins the
  turn that runs, or, with none running, the agent hands it back and the
  shell starts the turn with a `session/prompt` of its own. Otherwise it
  is that prompt at once (an adapter queues it behind a running turn).
  Its requests have ids Zed never uses (`mwt-acp-N`), and their answers
  stay with the shell. Its own prompt counts as working until its answer.
- **What it knows of each agent:** which adapter to start, and its
  environment as Zed gives it (Claude's adapter gets an empty
  `ANTHROPIC_API_KEY`). An adapter's new version needs no change here,
  only a new ACP version does.
- One process per agent per Zed window, serving all its threads, as the
  adapters do. Rust with no dependencies (`native/mwt_acp`), linked
  statically (musl), so it runs whatever your image is; the rest goes
  through the VM's own tools (socat for the channel, curl, sha256sum, tar
  and npm for installs). `scripts/build-acp.sh`, which `install-runtime.sh`
  and the package build run, builds it beside msb and the relay
  (`priv/microsandbox/bin/mwt-acp`), and the inbox carries it to the VM as
  `bin/mwt-acp` when the build has it.
- `mwt-acp --resolve AGENT` says which adapter it would start, installing
  it if needed; `--zed-settings FILE` writes its agents into Zed's
  settings; `MWT_ACP_COMMAND` starts another adapter (tests).

### Its agents in Zed

`mwt-boot` puts two agents in the VM's own Zed settings
(`~/.config/zed/settings.json`, which Zed's remote server merges after
yours), beside Zed's own: **Claude (MWT)** and **Codex (MWT)**, each a
`custom` agent whose command is `mwt-acp` with the adapter's registry id
(`claude-acp`, `codex-acp`). It writes only those two entries. Zed's own
Claude and Codex stay as they are, a fallback; their threads aren't agent
threads.

### The adapters follow the registry

Zed installs or updates a registry agent only when you start a thread with
its own entry, then deletes the older versions, so a variant that ran
Zed's copy would fall behind. `mwt-acp` follows the registry itself, and
nobody updates anything by hand:

- It reads the version from the ACP registry
  (`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`):
  Zed's copy in the VM
  (`~/.local/share/zed/external_agents/registry/registry.json`), which Zed
  refreshes hourly, or its own fetch when that copy is missing or more
  than a day old.
- It starts Zed's installed copy when that is the version; otherwise its
  own, in `/cache/mwt-acp/<agent>/<version>`, installed as the registry
  says (Claude's archive, checked against its `sha256`; Codex's npm
  package), removing its older ones. The downloads are public and go
  through MWT's proxy like any other.

### MWT's side

Each `mwt-acp` keeps one connection open on the agent channel:
`{"command": "attach", "agent": "claude-acp", "pid": …}`, then one JSON
message per line, both ways. Up: `opened` (thread, folder, title,
working), `closed`, `working`, `idle`, `title`, and `said` or `failed`
(with why) for what MWT said. Down: `say` (id, thread, text). The channel
hands the connection to `AgentThreads`, whose loop runs in the channel's
task for it. When it drops (MWT restarted), `mwt-acp` connects again,
sooner at first, and sends its open threads again; one that has exited
closes all of its threads. The lines are the VM's word: only known events
are taken, ids must look like ids, and titles and folders are made safe to
show (`Shown`). At most 64 threads are open through one `mwt-acp` and 128
in all; an `opened` past them is dropped, and MWT can't speak in that
thread.

`AgentThreads`, one per unlocked identity, holds the open threads and a
record of every thread it has seen:

```
AgentThreads.list(username)        every thread: agent, folder, title, open or closed, working or idle, dates
AgentThreads.get(username, id)     one thread, or nil when MWT never saw it
AgentThreads.say(username, thread_id, text, from: "handoff #21 sent back")
  -> :ok                           delivered: into the turn that runs, or starting one
  -> {:error, :closed}             seen, now closed (archived or closed in Zed, its mwt-acp gone)
  -> {:error, :unknown}            never seen through mwt-acp: Zed's own agents, a terminal
  -> {:error, :vm_not_running}     not open, and the VM isn't running
  -> {:error, :timeout}            no word from mwt-acp in 10 s
  -> {:error, {:failed, why}}      the agent refused it
AgentThreads.explain(error)        what an error means, for you
```

- **A thread's id** is its ACP session id, which is Claude Code's session
  id or Codex's thread id: the id `mwt` sends (`CLAUDE_CODE_SESSION_ID`,
  `CODEX_THREAD_ID`), handoffs record, and a slot's hold names
  (`branch.TASK.mwt-thread`).
- **Delivered at once or refused.** A thread that is working gets the
  message in its running turn; agents handle being interrupted. Nothing is
  queued for a thread that isn't open: the caller hears why, and decides.
- **The message says it is MWT's,** with the caller's `from`, so neither
  you nor the agent takes it for something you typed:
  `MWT (handoff #21 sent back): <the note>`.
- **The record** keeps each thread's agent, folder, title, when it opened
  and was last active, and the last 20 things MWT said in it, for the 500
  most recently active threads, across restarts: the `agent_threads`
  document of the identity's encrypted `library.db`. It outlives Zed's
  sidebar: archiving a thread in Zed (a mark in Zed's list on your
  machine) only closes it here; Zed removes a worktree with the last
  thread it archives only when Zed created it, and the conversation stays
  in the VM's Home, in `~/.claude/projects` and `~/.codex/sessions`.
  Pages hear `{:agent_threads_changed, id}` on the sandbox's topic.

### First uses

- **Send back** says the note to the thread recorded on the handoff, after
  the handoff says it is sent back, so the agent that hears it finds it so
  in `mwt handoffs`. The send back's line on the handoff's page says
  whether it went ("The note went to its thread in Zed", or why not: its
  thread isn't open, isn't an MWT thread, the VM isn't running). The note
  stays on the handoff either way.
- **The Projects page** shows each held slot's thread: its title, and
  whether it is working, idle or closed, or that MWT can't reach it.
- **A thread's state moves no slot.** A slot is held by its task's branch
  ([Worktree slots](#worktree-slots)): a thread that closes never makes MWT
  switch or free one.

### What agents are told

`mwt project` and `mwt worktree new` end with a line saying whether MWT
can reach the thread, by the id `mwt` sent. When it can't (Zed's own
Claude or Codex, an agent in a terminal), the agent tells you once, early,
that a handoff you send back and other news from MWT won't arrive by
themselves; to have that, you start a thread with **Claude (MWT)** or
**Codex (MWT)** in the same folder and give it the task there, where
`mwt worktree resume BRANCH` moves the task's hold. Until then, the agent
looks at `mwt handoffs` itself when you mention a handoff.

### Limits

- **Zed shows the thread as idle** while a turn MWT started runs: no
  spinner, no Stop button. Zed 1.28 (ACP v1) shows a turn as running only
  when it sent the prompt itself. Typing then sends a second prompt, which
  Claude's adapter queues behind the turn and Codex's runs after it.
  Claude Code's own background wake-ups look the same.
- **Only threads in Zed's agent panel**, started with an MWT agent. An
  agent run in a terminal doesn't speak ACP.
- **Only open threads** get messages.
- **ACP v2** (behind a flag in Zed 1.28) changes the protocol; `mwt-acp`
  follows when Zed moves.

### Open

- Claude's adapter, after a plan-mode restart with a fresh context, gives
  Claude Code a new session id under the same ACP id: `mwt` would then
  send an id MWT doesn't know.
- Whether Zed lets go of threads you didn't close or archive, which would
  make an open-looking thread closed.
- Keeping whole conversations in the record, not only their facts.

<a id="mwt-tools-in-the-vm"></a>

## MWT's tools for agents in the VM

Agents in the VM read and write your notes, diagrams and flash cards in
MWT, and add HTTP request samples, with the MCP tools agents on your
machine get from `/mcp` ([docs/mcp.md](mcp.md)). Nothing in the VM holds a
token or a placeholder for them.

### How agents reach it

`mwt mcp` is an MCP server on stdio, inside the VM. It carries each
message over the [agent channel](#agent-channel), one per connection like
every other `mwt` command: a line `{"command": "mcp", "agent": "…",
"thread": "…", "thread_id": "…", "folder": "…"}`, then the JSON-RPC
message as a line of its own. MWT answers with the response as one line,
or nothing for a notification, and closes.

- Being in the VM is all a message proves, as for every ask on the
  channel. The grants below decide what it may do.
- One connection per message, so `mwt mcp` outlives MWT restarting or
  locking, and the server keeps no sessions. A request MWT doesn't answer
  (locked or closed) gets a JSON-RPC error from `mwt mcp` itself, with the
  request's id, which it reads without a JSON parser (clients write it
  first, or last); the next message works, with no agent restarted.
- A message is at most 2 MB, as on `/mcp`, and arrives whole within 30
  seconds; at most 8 are read at once, within the channel's 64
  connections, so what any process in the VM holds of MWT is bounded.
- Every boot registers it with the VM's agents, in the VM's Home, as it
  installs `/handoff`: for Codex, a `[mcp_servers.mwt]` table appended to
  `~/.codex/config.toml`; for Claude Code, its own command (`claude mcp
  add-json --scope user mwt …`), since the image has no tool to edit JSON
  with. One there already, MWT's or one you changed, is left as it is. The
  agents' instructions (`/mnt/mwt/agents-block.md`) say the tools are
  there, and that changing an existing item waits for you.
- Results' `url` opens the item in MWT on your machine, for the agent to
  give you.
- `/mcp` and its token stay for agents on your machine. The VM can't reach
  it: the proxy refuses loopback and your machine's own addresses, and
  `/mcp` takes local peers only.

### Three built-in grants

Built in like Ask to run commands: always there, with no value, no Edit,
no Remove, and MWT's words. Each tool belongs to one.

| Grant        | Tools                                  | Starts, by default   |
| ------------ | -------------------------------------- | -------------------- |
| `mwt-read`   | `list_*` and `get_*`                   | Enabled, auto        |
| `mwt-create` | `create_*` and `import_http_request`   | Enabled, auto        |
| `mwt-change` | `update_*`                             | Enabled, ask         |

- They are plain grants (`kind: :mwt`, `tools` saying which): a switch, a
  duration, Ask each time or Auto-approve, and a start setting, changed as
  for any other; the table says only how they start. The projects' Git has
  three more of the same kind, `git-fetch`, `git-fetch-remote` and
  `git-handoff` ([Git as grants](#git-grants)).
- Three, not a read grant and a write grant: adding an item can't lose
  anything, and changing one can, so they get different defaults, and each
  behaves as every grant does, with no mode of its own.
- `initialize`, `tools/list` and the guides need no grant, so an agent
  always sees what there is. A tool whose grant is off answers an error
  naming the grant and how to ask (`mwt request mwt-change --reason "…"`),
  as the proxy does for a token grant that is off. Agents on this machine,
  with the token, aren't affected.
- **Reads cover everything** in the identity but HTTP requests: your notes
  and diagrams as much as agents', and every card. A secret written in a
  note reaches the VM.
- **No item is marked as an agent's.** You edit what an agent made; an
  agent changes what you made, through `mwt-change`. Who made each change
  is kept in its [version](#mwt-tools-versions), as a label.
- `create_flashcards` checks duplicates against every card: with
  `mwt-read` off, an answer of `existing` still tells the agent a card with
  that text is there; accepted.

### HTTP requests: added, never read

Your HTTP history holds what you sent, `Authorization` headers, keys in
query strings and login forms included, and the proxy forwards a request
with no placeholder unchanged: a real token read from history would leave
the VM past every token grant and approval. So the VM never reads an HTTP
request, yours or one an agent saved. From the VM, `tools/list` leaves out
`list_http_requests` and `get_http_request`, and a call naming either is
refused, saying so (`MWTClient.MCP.Tools.open_to_vm?/1`). Agents only add
samples, with `create_http_request` and `import_http_request` under
`mwt-create`, and are told to do it only when you ask for one; the result
of an addition gives back what the agent sent. Agents on your machine,
with the token, read them.

### Changing what exists

A change waits for you unless Auto-approve or an allowance covers it.

- **The card** shows the item's title and what would change: a note's
  title and body as a text diff, a diagram drawn before and after with the
  elements added, removed and moved counted, a card's fields side by side.
  Then who asks (the agent and thread `mwt mcp` sent, a claim). Its text
  goes through `Shown` ([Text the VM chooses](#text-the-vm-chooses)).
- **Your choices:** allow once; *Allow for a while*: changes to this item
  for 10 minutes, 1 hour or while the grant stays on (an agent revising one
  diagram), or every use of the grant for as long; deny; deny and turn the
  grant off.
- **The agent waits** up to 50 seconds, under Codex's default limit of 60
  for a tool call. Then it hears the change is still waiting, with the
  ask's id: approved later (the card waits 30 minutes), it is still made,
  and `mwt wait ID` tells the agent how it went.
- **Based on what it read.** `get_*` returns the item's `version`, which
  every update tool requires, on `/mcp` too. A change based on an older
  version is refused, with the current one, so it never overwrites an edit
  the agent hasn't seen: yours while it waited for you, or another agent's.
  It is checked before it asks, and again when it is made. One that changes
  nothing, as a change made and sent again, answers as the item is,
  without asking.
- **Ten wait at most.** The same call sent again joins its card: the same
  tool, arguments and caller, compared whole (a SHA-256 digest, never a
  short hash the VM could match with another call). Past ten cards, a new
  call is refused, with nothing changed, so an agent in a loop can't bury
  the Approvals page.

<a id="mwt-tools-versions"></a>

### Versions

Every note, diagram and flash card keeps its earlier versions, so a change
you regret is undone in a click, whoever made it.

- **When one is kept:** before every change by an agent (in the VM or
  through `/mcp`), before every restore, and for your own editing at most
  one per item per 10 minutes, since notes save as you type; but always
  before your first edit after someone else's change, so what an agent
  wrote isn't lost to your next keystroke. Who changed what last is known
  while MWT runs: after a restart, your first edit keeps one. One the same
  as the newest kept isn't kept twice.
- **Each says** when, and who: you, an agent on this machine, or an agent
  in the VM with the agent and thread it claimed. A label, not a
  permission.
- **The item's page** lists them, newest first, each with its diff against
  the current one. *Restore* makes it current, and keeps what it replaces
  as a version, so a restore is undone the same way.
- **Kept** as rows of `versions` in the identity's encrypted `library.db`,
  in the transaction of the change they record. How many is each kind's
  retention rule ([docs/storage.md](storage.md)): by default every version
  for 90 days, then one a day until 365 days, then one a month, at most 100
  per item. Deleting an item forgets its versions, and so does an import
  that replaces it. Exports and backups carry the current items only.
- **A card's version** holds its front, back, tags and source. Review
  progress isn't versioned: restoring doesn't undo your reviews.
- **HTTP requests** need none: nothing changes one, and a new sample is a
  new item.

### Limits

`mwt-create` is enabled on startup, auto-approved, so an agent in a loop
could fill your disk. From the VM, past 200 items or 50 MB created in an
hour, each create asks like a change, whatever its allowances, and its
card says why, until the hour has room again. The count is kept in memory: a restart starts it again.

### Where it lives

- Versions and their diff: `MWTClient.Versions`, `MWTClient.Versions.Diff`;
  the Versions panel and a change's diff: `MWTClientWeb.VersionsComponents`.
- Who calls, and the gate: `MWTClient.MCP.Caller`, `MWTClient.MCP.Tools`.
- The grants deciding a call from the VM: `MWTClient.Sandbox.MwtTools`,
  `MWTClient.Sandbox.Server.Tools`, `MWTClient.Sandbox.Policy`.
- `mwt mcp` and the channel's `mcp` ask: `priv/sandbox/mwt-cli`,
  `MWTClient.Sandbox.Channel`; registering it with the agents:
  `priv/sandbox/mwt-boot`.

<a id="projects-and-handoffs"></a>

## Projects and handoffs

The VM is a development machine with a clone of each of your
repositories: its `origin` is your repository on this machine, through
MWT, as your repository's own `origin` is a Git server. The VM works in
its clone as you work in yours; the one difference is how work comes
back: not by a push, but by a handoff you review and land. Work lands
only on your machine for now.

### Terms

| Term | Meaning |
| --- | --- |
| **Project** | A git repository of yours, in a shared folder, and its clone in the VM, `/work/<name>`, with its settings on the Projects page. Submodules and LFS are left out for now. |
| **Origin** | In the VM, your repository through MWT (`mwt::<project id>`): its branches are `origin/<branch>` there. From your machine, your repository's own remote. |
| **Upstream** | In the VM, your repository's own remote branches, as your machine fetched them, read through MWT (`mwt::<project id>/upstream`). |
| **Worktree slot** | A checkout of the clone that holds one task at a time: `slot-0` is the clone itself, `/work/<name>`; the others are worktrees of it, `/work/<name>.wt/slot-N`, which you add and remove. |
| **Task** | A branch `mwt worktree new` started in a slot, from a base (`origin/<branch>`, another task's branch or a commit), for one thread. |
| **Handoff** | A task's exact commit, with its title and notes, which an agent sends once you reviewed it in the VM and asked (`mwt handoff`). Handing off again makes a revision. |
| **Catch up** | The agent rebasing its task onto its base as you have it now: `git fetch origin`, `git rebase origin/<base>` (`mwt handoff` does both); or MWT replaying a handoff's commits there, from the Handoffs page, where they apply cleanly. |
| **Land** | Putting a handoff on a branch of yours, once you click Land: as it is (a fast-forward) when that branch hasn't moved, else as one commit (`accept` in the code). |
| **Send back** | Returning a handoff to its thread with a note. |

```
the VM                       your machine                  a Git server
/work/app ── origin ──▶      your repository ── origin ──▶ GitHub, …
  fetch, through MWT           your own workflow
  ├─ slot-0 (the clone)
  ├─ /work/app.wt/slot-1
  └─ /work/app.wt/slot-2
        │ mwt handoff                       ▲
        └──▶ MWT's review store ── Land ────┘ (as it is, or as one commit)
```

### Opening a project

- **Shared folders decide what the VM sees, and every git repository in
  one is a project.** A repository reaches the VM only so, never in a
  shared folder's copy ([Shared folders](#shared-folders)).
- **The Projects page shows the open projects.** **Open project** lists
  the closed ones and the repositories in your shared folders that aren't
  projects yet, and looks deeper in a shared folder one folder at a time,
  never out of it. Opening one makes its clone in the VM: your committed
  branches and tags, once, as `origin/*`, and its default branch (main,
  master, then the one you have checked out) checked out in slot-0.
- **Open in Zed** opens the clone (slot-0), or a slot, over the VM's SSH
  connection. An existing clone opens even when its folder is no longer
  shared: it just can't fetch.
- **Close** takes a project off the page; its clone, slots, branches and
  handoffs stay in the VM. **Forget** lets go of its settings; the VM's
  work stays too.
- **The page shows** each open project's branches as origin has them, its
  checks, a warning when commits in the VM would have no author, and its
  slots: which are free, what the others hold (task, base, handoff,
  uncommitted work, the thread holding it, whether a Zed window has it
  open, servers running there), with Release, Open in Zed and Remove.

### The VM's clone

- **The clone is the VM's.** Its branches, commits, index and files follow
  Git: MWT never moves, resets or deletes a branch there, switches a
  checkout, or sets edits aside. A landed task's branch stays until
  someone deletes it in the VM.
- **A clone made from an older mirror** keeps its checkout and slots; its
  `host/*` branches become `origin/*`, and its `host` remote goes, since
  nothing would update it.
- **`origin` is your repository, through MWT.** Its URL, `mwt::<project
  id>`, runs MWT's remote helper (`git-remote-mwt`, in `/mnt/mwt/bin`):
  the VM names a registered project, never a path on your machine, and
  MWT runs `git upload-pack` on a view of your repository holding only
  its branches and tags (`MWTClient.Sandbox.GitTransport`). Its
  configuration, hooks, other refs, ignored files and uncommitted work
  don't travel. A fetch moves `origin/*` and nothing else; `git pull`
  fetches through MWT, then merges or rebases in the VM.
- **A push is refused**, saying work goes back by `mwt handoff`. A push
  that answered "ok" while your branch didn't move would lie; a handoff
  carries what a push can't: its title, notes, checks and thread.
- **`upstream` is your repository's own remote, as your machine has it**
  (`mwt::<project id>/upstream`): its `refs/remotes/origin/*`, so a task
  can start from a colleague's branch you fetched. MWT doesn't fetch from
  that remote for the VM unless the grant below is on.
- **Who commits:** opening the clone sets its
  `user.name` and `user.email` to those git reads in your repository on
  your machine (`HostGit.identity/1`), unless the VM has its own. Commits
  in the VM, by agents or by you in Zed, are yours. With no identity on
  your machine, none is set, agents are told to ask you before
  committing, and the Projects page says how to set one.

<a id="git-grants"></a>

### Git as grants

What the VM does with your repositories goes through grants, built in,
like the Internet ([Grant kinds](#grant-kinds)):

| Grant | What it allows | When MWT starts |
| --- | --- | --- |
| **Fetch from your repositories** | `git fetch`, `git ls-remote` and clones of `origin` and `upstream`: your committed branches and tags, and your remote branches as your machine last fetched them. Reads only. | Enabled, auto |
| **Fetch from your remotes** | Before `upstream` answers, your machine fetches your repository's own remote into MWT's store (never into your repository), with your credentials, non-interactively, at most once a minute. The VM never sees a credential or chooses a URL. | Enabled, auto |
| **Hand off** | `mwt handoff`: commits into MWT's review store, never into your repository. Your review is the gate. | Enabled, auto |

Landing, on your machine or later on a remote, is yours, on the Handoffs
page: never a grant the VM asks for.

<a id="worktree-slots"></a>

### Worktree slots

Worktrees are how parallel work happens, and a slot keeps one task in
each: a new worktree per task would leave every build cold, and a new Zed
path each time.

- **slot-0 is the clone itself; the others are worktrees of it,**
  `/work/<name>.wt/slot-N` for each number the project has
  (`Project.slots`, 1 to 9). A new project has slot-0 alone; the Projects
  page's **Add slot** makes the lowest number missing, at once, free, on no
  branch at `origin/<default branch>`, locked (`git worktree lock`, so
  Zed's `git worktree remove` leaves it); **Remove** takes a free one out,
  with its build. slot-0 is never removed. Folders never move, so a Zed
  window or a thread open on one never breaks. A slot keeps its folder
  between tasks, so what git ignores stays warm.
- **Git keeps the state; MWT keeps none** (`Slots.look/4`): a slot is
  *free* when its folder is absent or gone; clean and on no branch, or on
  a branch no task started (slot-0 on its own `master`); or on a task's
  branch whose latest handoff landed or was closed at the commit it is on,
  clean. Uncommitted work makes any slot busy. A slot is free as soon as
  its handoff lands, without MWT touching it.
- **A thread takes its slot first,** before anything else, even for a
  question: `mwt worktree new TASK --from BASE` fetches origin, then
  starts the branch TASK from `origin/BASE` (or another task's branch, or
  a commit) in the slot the thread is in, records the base
  (`branch.TASK.mwt-base`) and the thread (`branch.TASK.mwt-thread`).
  Names that say nothing (`task`, `wip`, …) are refused; with no base
  named, nothing starts and the answer lists your branches, for the agent
  to ask you.
- **A second thread in a held slot only reads.** `mwt project` and `mwt
  worktree new` tell it which task holds the slot; MWT refuses its `mwt
  worktree new` and `free`, and its `mwt handoff` and `withdraw` of that
  task. A thread id is a claim, as everything an agent sends: this guards
  against mistakes, not an agent set on writing elsewhere.
- **The hold lasts until the handoff lands or is closed,** or the slot is
  freed (`mwt worktree free` by its thread when you say the task is done,
  or **Release** on the Projects page). `mwt worktree resume BRANCH` puts
  a sent-back task's branch in a free slot, or, in the slot that has it,
  moves the hold to the thread running it.
- **A thread works only in the slot it was opened in.** Every thread in
  the VM can write every folder, so agents are told never to change,
  build or run things in another slot, not even by absolute path.
- **Other worktrees** (made with `git worktree add`, or by Zed) are listed
  apart: no task starts there.

<a id="handoffs"></a>

### Handoffs

```
mwt worktree new TASK --from BASE   take the slot you are in for a task
mwt worktree resume BRANCH          continue a task in a free slot, or take over its hold
mwt worktree free                   free your slot, when the user says the task is done
mwt handoff --title "Fix the login" [--body FILE] [--onto BASE] [--no-checks]
mwt handoff withdraw --reason "…"   keep the open handoff from landing until the next
mwt handoffs                        the project's handoffs and what the user did
mwt project                         where you are, the slots, the rules
```

- **Agents never commit unless you say so,** and hand off only once you
  ask (`/handoff`): you review their work uncommitted in Zed, in the VM.
  You may commit pieces yourself there.
- **`mwt handoff` does every step that needs no judgment,** in the slot:
  it fetches origin; commits the changes to files git has with the
  title, and stops at new files it wasn't told about; catches up by
  rebasing the task onto `origin/<base>` (going on with a rebase the
  agent resolved, first, before anything else: until it ends the worktree
  is on no branch), only replaying what came after a task's earlier
  landing as one commit; runs the project's checks once per commit
  (`--no-checks` when you say so); and sends that exact commit. Behind
  its base, a handoff is refused: it wasn't checked with your newer
  commits.
- **One handoff per task, revised in place.** Handing off again from the
  same branch makes a revision. The changes for a revision fold into the
  handoff's own commit while the branch is still at it (nothing committed
  after it), so a handoff is one commit and lands as one, as it is. A
  commit you made yourself in the meantime stays as you made it; the next
  revision is a commit on top. A revision is measured from where its
  branch meets your base now, so one that caught up brings only its own
  work, never your newer commits as its changes or conflicts. Each
  revision stays in MWT's review store
  (`refs/handoff-revisions/<id>/<n>`), so work done after a handoff never
  changes what you review, and a task's branch can go without its
  handoff going.
- **The review store is MWT's,** a bare repository apart from yours that
  borrows its objects: handoffs never enter your repository until you
  land one. Objects are checked on receipt and size-capped, and a handoff
  holding a grant's real value is refused.
- **Withdraw is optional:** a revision is pinned, so landing it never
  takes work done since; the decision panel says when the task moved on.
- **A handoff that came too soon:** you close it and say so in its
  thread; it undoes its commits and keeps the work uncommitted
  (`git reset $(git merge-base HEAD origin/<base>)`).

<a id="landing"></a>

### Landing

- **The Handoffs page** shows a handoff's notes, commits, files and diff,
  and keeps the decision apart: **Land** (where and how), **Send back**
  (with a note) or **Close**.
- **Where:** the task's base by default, or any branch of yours where it
  applies without conflicts, or a new `mwt/` branch from one.
- **How:** **as it is** when that branch hasn't moved since the handoff
  caught up with it and has all the task started from: a fast-forward to
  the handoff's own commit, the very one its checks ran on. The VM's next
  fetch finds it on `origin/<branch>`, so the clone and your repository
  agree, and `git branch --merged` says so. With several commits, you may
  choose **as one** instead. When the branch moved since, it lands **as
  one commit** with its changes on top, marked untested with what came
  since. A task based on another task's branch lands its own changes
  only, as one commit.
- **Catching up,** when its own branch moved under it, takes a click
  (`Handoffs.catch_up/2`, `Handoffs.ask_to_catch_up/2`):
    - **Catch up here**, where its changes apply cleanly: MWT replays its
      commits onto the branch's tip in its review store, never in your
      repository (`MWTClient.Sandbox.CatchUp`), keeping each commit's
      author, date and words, you as committer; a new revision, which
      lands as it is. Its checks ran before that, and the timeline says
      so. A merge commit in it stops it. The thread's own branch keeps
      the commits it had; its next handoff catches up the same way.
    - **Ask its thread to catch up**, the only way where they conflict:
      it is sent back with a note MWT writes, naming the branch, how far
      it moved and the files that conflict, and saying the note is your
      ask to hand off again. The thread hears *sent back to catch up*,
      rebases with `mwt handoff`, resolves the conflicts, runs the checks
      and hands off again by itself, with no `/handoff` from you.
- **Safety:** landing checks the branch is still where the preview saw
  it and moves it with a compare-and-swap; a branch checked out in a
  worktree of yours moves by a fast-forward there, never over pending
  changes to tracked files. No hook runs. **Undo** puts it back while it
  still has what landed.
- **Send back** works before and after landing, and MWT tells the thread
  when it can reach it. Landing, closing and sending back leave the VM's
  branches and files alone.

### Left in the VM

Clones and worktrees whose repository is gone from your machine stay on
the VM's Work disk until removed (`Leftovers`). The Projects page lists
them under "Only in the VM", with their size and what would go with them
(uncommitted work, commits on none of your branches); **Remove** asks
first.

<a id="firewall"></a>

## Firewall

Approvals stop what you can see coming: a use of a grant, a command on your
machine. The firewall watches for what you can't: what the VM does with the
access it already has, and how it behaves while it does. On the first sign
of trouble it **isolates** the VM: nothing it sends leaves through MWT
until you release it. You can isolate it yourself too, with the same
switch the firewall turns on ([Isolating](#isolating)).
`MWTClient.Sandbox.Firewall` holds the rules, pure
(what was seen, against the windows so far, gives findings);
`MWTClient.Sandbox.Server.Firewall` acts on them, in the server.

It watches every way the VM reaches past itself, not only the network:

| Sensor                 | What it hears                                                        |
| ---------------------- | -------------------------------------------------------------------- |
| DNS (`Dns`)            | every name looked up, before it is passed on                         |
| Proxy, each connection | the address and port, before MWT connects                            |
| Proxy, first bytes     | the name a TLS connection is for (SNI)                               |
| Proxy, tunnels         | bytes up and down as they flow, every 256 KiB; every byte going up looked through for placeholders and real values, whatever the first byte says (in TLS only the handshake can hold one) |
| Proxy, read requests   | a placeholder going where its grant doesn't send it; a real value in the request, or in the answer |
| Agent channel          | asks for grants and commands, and the text of an ad-hoc command; real values in any of it |
| MWT's tools (MCP)      | reads of your notes, diagrams and flash cards; real values in what is written |
| Handoffs               | real values in what a handoff brings: its words, commit messages and files |
| VM monitor             | the busiest processes, every 5 s                                     |
| Your decisions         | what you declined, against what the agent asks next                  |

<a id="rules"></a>

### Rules

Each rule has an action: **Isolate**, **Block** (refuse this one use and
say so, nothing else), **Alert** (log it and notify you, let it through)
or **Off**. *A process pegging a CPU* and *Asking again after you declined*
have no Block, and *Credential entering the VM* no Isolate. The defaults:

| Rule                              | Fires on                                                                                                  | Default |
| --------------------------------- | --------------------------------------------------------------------------------------------------------- | ------- |
| Credential sent elsewhere         | a placeholder to a host its grant doesn't list (in a header, the target or the body), in a tunnel, or inside a DNS name | Isolate |
| Real credential in traffic        | a token grant's real value in what the VM sends that MWT reads, or coming back to it in an answer         | Isolate |
| Blocked services                  | a name on the blocked list, looked up or connected to                                                     | Isolate |
| Data in DNS names                 | a label of 50 characters or more, or 100 or more before the domain (one refused, three under a domain in 10 min isolate); over 40 names, or 1.5 KiB of names, under one domain in 10 min. Cloud providers' own domains aren't judged | Isolate |
| Large upload                      | 4 MiB or more sent in 10 min to one public destination through tunnels (counted by domain, so subdomains fold together), with less than a quarter of it coming back | Isolate |
| Scanning                          | 5 private or reserved address:ports refused in a minute, 20 ports of one public address in a minute, or 20 public addresses on one non-web port in a minute | Isolate |
| Mail, IRC and Tor ports           | a public address on 25, 465, 587, 2525, 6667, 6697, 9001, 9030, 9050 or 9150                              | Isolate |
| Command touching secrets          | an ad-hoc command (text the agent wrote) naming a path on the protected list                              | Isolate |
| DNS around MWT                    | DNS straight to a public address (port 53 or 853), or a public DNS-over-HTTPS resolver by name or address | Block   |
| A process pegging a CPU           | one process in the VM at 90% of a CPU or more for 30 min                                                   | Alert   |
| Asking again after you declined   | asking twice more, within 30 min, for a grant or a command you declined (the same command, however its spacing differs) | Alert   |
| Reading many notes                | 100 reads of notes, diagrams or flash cards in 10 min                                                     | Alert   |
| Minting a credential              | a request that would carry a grant's real value to an entry of the credential endpoints list: refused before its value is fetched, and the upstream never hears of it | Block   |
| Credential entering the VM        | a command's output or a request subgrant's answer, on its way to the VM, holding something shaped like a credential ([What enters the VM](#what-enters-the-vm)). Block holds it for you; never isolates, the VM did nothing wrong | Block   |

- **By behaviour and by lists you edit, not by signatures.** No rule knows
  attack tools or their command lines: those change every week and are
  easy to dress up. A rule looks at what happens (bytes one way, names
  that carry data, a placeholder where it doesn't belong) or at a list on
  the Firewall page.
- **The lists** start filled and are yours to change, one entry a line, at
  most 500 a list:
  - *Trusted destinations*: the model APIs agents talk to
    (`*.anthropic.com`, `*.claude.ai`, `*.openai.com`, `*.chatgpt.com`).
    The rules on destinations (blocked services, DNS names, uploads, ports)
    skip them. *Credential sent elsewhere* never does. A connection
    claiming a trusted name over TLS is only spared when MWT's own DNS
    resolved that name to that address (answers kept an hour); a trusted
    name pointed at an address MWT never answered for it is a spoof and
    refused, so the trust can't be borrowed to tunnel out unread.
  - *Blocked services*: paste sites, file drops, request catchers, tunnels
    into the VM and mining pools.
  - *Protected paths*: your private keys and credential stores (SSH and
    GPG keys, cloud and registry credentials, `.kube/config`, `.npmrc`,
    `.pypirc`, `.pgpass`, `.vault-token`, a password manager's config,
    OptMem's memory), browser profiles and keychains, MWT's own data
    (`.mwt_client`), and the places things start from again (crontab,
    shell startup files, autostart, systemd user units, launch agents). A
    command naming one is caught however it is spelled around it, quotes
    or backslashes between the letters included; one that hides the name
    is still read by you on its card. High-traffic files that rarely hold
    a secret alone (`.env`, `.gitconfig`) are left off, so ordinary
    commands aren't refused.
  - *Credential endpoints*: hosts and paths whose answers are credentials
    (a token exchange, key creation, a registry's token:
    `sts.amazonaws.com`, `oauth2.googleapis.com/token`,
    `iamcredentials.googleapis.com`, `api.github.com/user/keys`,
    `*.pkg.dev/v2/token`, …), as `host` or `host/path`; `*` is one segment
    of the path, the request's path may go on after the entry's, the query
    isn't read. The swap protects a grant's own value, but an answer that
    *is* a credential would bring a new one into the VM, and no host list
    says which endpoints those are. So *Minting a credential* refuses a
    request that would carry a grant's value to one, request subgrants'
    calls included, before the value is fetched (`mwt_credential_endpoint`);
    one with no value in it is the upstream's to answer. The add-grant form
    says when a grant's hosts, or a subgrant's URL, cover an entry. A
    registry pull that trades a grant's token for the registry's is refused
    too: take the entry off the list, or set the rule to Alert, for that.
  - An entry `example.com` or `*.example.com` covers that name and every
    name under it; an address covers itself.
- **Real credential in traffic** looks for every token grant's real value,
  stored or minted and still at hand, on or off, wherever MWT reads what
  the VM sends: read requests (every header, Basic decoded, the whole
  body), plaintext tunnels, DNS names, asks on the agent channel, what
  MWT's tools are asked to write, and handoffs (title, notes, commit
  messages, every file they add or change). In a request or a tunnel it
  never goes, whatever the rule's action; an ask, a write or a handoff is
  refused. It also fires on a value coming back in an answer, which MWT cut
  before it reached the VM ([What comes back](#what-comes-back)). Values
  shorter than 16 characters aren't looked for: too many strings would
  match.
  - Out, it means the VM already holds the value, which no switch takes
    back: the finding tells you to replace that credential at its service.
  - It is a tripwire, not a wall: a VM holding a value can change it before
    sending it (base64, reversed, in pieces), and TLS to hosts no token
    grant lists passes unread. It catches the careless leak, an agent
    pasting a token it saw into a commit, an issue or a note. The wall is
    that the VM never gets the value ([Grant kinds](#grant-kinds)).
- **Large uploads** count tunnels to public addresses only: read requests
  are judged one by one already, and a private address is one you opened
  with a network grant. The check runs as the bytes flow: the chunk that
  crosses 4 MiB waits for the verdict and doesn't go.
- **A finding is an event** in the activity log (`firewall`, its own group
  on Proxy activity); an alert is said once per rule and destination in 10
  minutes.
- The firewall is on by default, with a switch on its page. Off, nothing is
  watched and nothing is isolated.

<a id="isolating"></a>

### Isolating

One switch, *VM isolated* on the Firewall page, says whether the VM is
isolated, and both the firewall and you turn it: the firewall on a rule
set to Isolate, you whenever you want the VM cut off
(`MWTClient.Sandbox.firewall_isolate/1`, no question asked). Either way
it is the same isolation (`Server.Firewall.isolate/2`, given the finding or
`:you`), at once, in the server, in this order:

1. The firewall records the incident: who isolated it (`by`, `:firewall`
   or `:you`), the rule and what it saw (none for yours), when, and the 30
   events before it. It is saved sealed, so a restart of MWT comes back
   isolated. An incident saved before you could isolate was the
   firewall's.
2. Every connection the proxy holds open is closed
   (`MWTClient.Sandbox.Connections`, a registry the connections join), new
   ones are refused, and DNS answers REFUSED to every name.
3. Every approval waiting is refused (`mwt_isolated`), every command
   running on your machine is stopped (TERM, then KILL), and every grant
   that is on turns off, the Internet included; the incident keeps which,
   as they were (`grants_on`), for the release. Forwarding the
   VM's ports to your machine stops.
4. The agent channel refuses everything that acts: `mwt request`, `run`,
   `call`, `propose`, `handoff`, and MWT's tools over MCP. What only reads
   (`mwt grants`, `host`, `vm`, `wait`) still answers, so an agent can say
   what happened. It is told the VM is isolated and that you have been
   told, never which rule fired.
5. A notification (*Agent Sandbox · Firewall*, its own kind), only when
   the firewall isolated it, and a red banner on every sandbox page saying
   who did.

The VM keeps running, so you can look at what it did (open it in Zed, or
stop it from the incident). Nothing leaves while you do.

<a id="releasing"></a>

### Releasing

Turning the *VM isolated* switch off releases the VM. An isolation you
made ends at once. One the firewall made asks first, in a dialog: the
rule and what it saw, that releasing undoes nothing the VM did, the grants
that come back, and, for a finding with a destination, *Trust HOST from
now on*; **Keep it isolated** leaves the switch on. Releasing ends
the isolation and turns back on every grant that was on as it began, the
Internet among them, as it was: until the same end, with its allowances
and Auto-approve (`Server.Firewall.restore_grants/2`), even after a
restart. One whose time ran out meanwhile, one removed and one to review
stay as they are; each runs its conditions as turning it on does.
Trusting adds the destination to the trusted list, for a rule that fired
on something you know. **Stop the VM**, beside the switch while the VM
runs, stops it and keeps the isolation. The last 20 incidents stay
listed, folded under the switch.

<a id="screens-firewall"></a>

### The Firewall page

`/tools/sandbox/firewall`, *Firewall* in the sandbox's menu, with a red
*Isolated* badge while isolated. *Watching* On or Off at the top, then:

- **The isolation card:** the *VM isolated* switch. Off, a line on what
  turns it on (or that the firewall is off, so only you do). On, who
  isolated it and why, since when and how much it refused, the grants
  releasing turns back on, and what came before (open for the firewall's
  isolation). The past isolations fold under it.
- **Rules,** by group (*Credentials*, *Network*, *Agent and VM*), each in
  a line: its name, what sets it off in a few words, a "?" with the whole
  of it, and its action. Every action shows in the same column on every
  row; one a rule can't take is struck through.
- **Found lately,** the last 8 findings, and **Lists,** a tab each, with
  its count: one editor at a time, switched in the browser, so a list half
  edited stays as you left it while you look at another.

<a id="pages"></a>

## Pages

The sandbox is a tool of MWT's (an entry in `MWTClient.Tools`) at
`/tools/sandbox`, a page per item of its menu (`MWTClientWeb.SandboxLive`).
A red banner on every sandbox page says the VM is isolated. Approvals and open handoffs also raise a
notification ([Desktop notifications](#desktop-notifications)).

- **Overview:** the VM (status, Start, Stop, *Recreate…* at any time, the
  image it runs beside the one a recreate takes, its id, "recreate to
  apply": [Creating the VM](#creating-the-vm)); its resources, each figure
  with a "?" ([VM monitor](#vm-monitor)); how many approvals wait, linking
  to the page that decides them; the servers in the VM with Open and Kill
  ([Servers in the VM](#servers-in-the-vm-on-your-machine)); the grants
  enabled, with time left; the Memory card ([The VM's OptMem](#the-vms-optmem));
  the latest activity.
- **Approvals:** the waiting cards of every kind ([Approvals](#approvals));
  the commands running on this machine above them, with Stop; what was
  decided below, where a command opens
  to its script and output.
- **Projects:** each open project with its branches as origin has them, its
  checks, a warning when commits would have no author, and its slots (Add
  slot; Release, Open in Zed, Remove); Close, Forget, *Open project*, and
  "Only in the VM". Read again every 5 s while open ([Projects and
  handoffs](#projects-and-handoffs), [Worktree slots](#worktree-slots)).
- **Handoffs:** the open ones and the closed. A handoff's page: the agent's
  notes (Markdown, with a Raw tab), its timeline and thread, its worktree to
  open in Zed, what lands (commits, files, the diff when you ask), and the
  decision apart, kept in view: Land, Send back or Close; Undo and Reopen
  after ([Handoffs](#handoffs), [Landing](#landing)).
- **Grants:** the catalog ([The Grants page](#the-grants-page)) and *Add
  grant*, by type or preset ([Presets](#presets)). A grant's page
  (`/tools/sandbox/grants/ID`): what the VM gets, the real value, the start
  setting ([When MWT starts](#when-mwt-starts)), *Always ask me*
  ([Always ask me](#ceiling)), *Only while…* ([Checks](#checks)), what is
  allowed for now, its subgrants, its recent use, Edit and Remove.
- **Proxy activity:** filters (groups with their counts, words, a grant); a
  timeline of the matching events by series (passed, credentials, blocked,
  other) from the oldest kept to now; the busiest destinations, each a
  filter; the log, a line per event that opens to all it recorded, a request
  MWT read to it as the VM sent it beside the response as it reached the VM,
  with Copy as JSON ([What the log keeps of a request](#exchanges)). The
  figures come from the server (`MWTClient.Sandbox.EventStats`), at most
  once a second while activity comes in.
- **Firewall:** the *VM isolated* switch with the isolation and the past
  ones, the rules by group, the last findings, the lists in tabs; a red
  badge in the menu while isolated ([The Firewall page](#screens-firewall)).
- **Settings,** only what you can change, each with a "?" for what it is
  and when it applies, in two tabs. *Runtime:* shared folders
  ([Shared folders](#shared-folders)); CPUs and memory against this machine
  and the suggestion, the disks, how long an approval waits; VMs inside the
  VM; the VM's memory; *This machine, for agents* (your notes, the folders
  confined commands may read). *Build:* the image's name, the Containerfile,
  MWT's layer, the builds kept ([The image](#the-image)).
- **Setup:** what this machine lacks (`bwrap` and its user namespaces, the
  relay, the tools that make disks); build, share, start; then what Zed
  needs: your key let in once and the SSH entry, with a warning when
  `~/.ssh/config` reaches the VM through anything but this identity's
  launcher. Projects open the VM in Zed.

<a id="guarantees-to-test"></a>

## Guarantees to test

Each is checked in the suite, by the files named, or on a real VM (`mix test
--only vm`, `vm_live_test.exs`). Tests cite some by number: add at the end.

1. No real value is written to `/mnt/mwt`, the activity log (the requests and
   responses it keeps included), application logs or the VM's environment
   (`guarantees_test.exs`).
2. MWT never connects for the VM to loopback, link-local, cloud metadata,
   multicast, reserved or this machine's own addresses, unless a network
   grant that is on names that exact address.
3. A value goes in only through a grant's carriers, on requests MWT itself
   sends to one of the grant's hosts, by name, resolved by MWT's DNS, TLS
   verified. A placeholder in another header is refused, and no allowance
   covers a credential moved to another header or a method override
   (`egress_leaks_test.exs`, `server_test.exs`).
4. A placeholder going to a host outside its grant, in a header, the target
   or the body, is blocked and logged.
5. Turning a grant off, its expiry or its removal stops the next request and
   closes the connections it let through, an upgraded one included; a value
   minted meanwhile isn't sent (`egress_revocation_test.exs`,
   `server_test.exs`). Expiry, of grants and allowances alike, is read from
   the clock at each decision, so it holds across a restart and a suspend;
   timers only refresh screens, and the clock is read again as MWT starts and
   every 30 s (`guarantees_test.exs`).
6. A locked MWT swaps nothing, and the sandbox stops the VM. A VM whose MWT is
   locked, stopped or gone has no internet and resolves no name (a real VM).
7. Nothing in the VM reaches MWT's web server, `/mcp` included. The agent
   channel hands out no real value: it reads, asks, and carries what built-in
   grants allow (fetches, handoffs, MWT's tools).
8. Nothing in the VM can approve its own requests.
9. Nothing the VM wrote runs on your machine unless Ask to run commands is on
   (it starts off) and you approve that exact text, each time; what runs is the text on the card. A command subgrant
   runs only your script, while it is on, its values as variables, never in
   its text (`guarantees_test.exs`, `policy_test.exs`).
10. Port forwarding opens nothing from the VM to your machine: connections go
    only into the VM, for ports 4100 to 4199, on the VM's own address here
    (`127.77.X.Y`).
11. The process running the VM has all seven namespaces of its own, no
    `/home` or `/etc` of this machine, an empty `/run`, only loopback and no
    capability it can regain, and runs, as all its bubble does, under MWT's
    seccomp filter (a real VM; `seccomp_test.exs`).
12. Every DNS query from the VM reaches MWT and is logged; one aimed at
    another resolver gets no answer (a real VM).
13. Nothing of this machine is mounted in the VM, and MWT writes no storage
    the VM can write: the VM's own `tar` unpacks what MWT puts there. No
    repository, nor a folder in one, is in a shared folder's copy, and what
    the VM changed in a copy is set aside in `/work/.rescued` before your
    change replaces it (a real VM; `guarantees_test.exs`,
    `folder_sync_test.exs`).
14. Whether a use goes through, asks or is refused depends only on the
    grants, the use and the clock. For every combination of grant state,
    allowances, host and placeholder: no placeholder goes to a host its grant
    doesn't list, a grant off by the clock lets through and asks nothing, a
    lapsed allowance allows nothing, a reserved address opens only for an
    entry naming it, a command is always an ask, a grant set to *Always ask
    me* takes no allowance, and a grant to review lets nothing through
    (`policy_test.exs`).
15. What an approval, the log, a notification or a page shows of the VM's
    text is UTF-8 and holds nothing that doesn't show; a script that does is
    refused (`hostile_text_test.exs`).
16. Nothing the VM sends (an ask, a request, a repository, its connections)
    makes the sandbox fail or MWT read without limit; the relay closes what
    it can't take instead of ending (`egress_bounds_test.exs`, its tests).
17. A request two parsers could read two ways is refused whole, or reaches
    the host as one request with the head MWT wrote (`egress_corpus_test.exs`).
18. While the VM is isolated, nothing it sends leaves through MWT: no
    connection, lookup, request, command, fetch, handoff or change through
    MWT's tools, across a restart too (`firewall_test.exs`,
    `server_firewall_test.exs`, `git_transport_test.exs`).
19. No real value reaches the VM: not in any head or body of an answer to a
    request MWT put it in, however framed or compressed, nor in what MWT
    couldn't read (refused), nor in anything else MWT moves in unless you
    send it on its card (`egress_response_test.exs`, `inbound_test.exs`,
    `host_command_channel_test.exs`, `mwt_tools_test.exs`).
20. A real value in what the VM sends that MWT reads never goes on, and an
    ask, a write through MWT's tools or a handoff holding one is refused; the
    firewall hears of each (`egress_leaks_test.exs`, `secrets_test.exs`,
    `firewall_test.exs`, `server_firewall_test.exs`, `handoffs_test.exs`).
21. With the sandbox's server busy, lookups, connections, tunnels' reports and
    requests needing neither you nor a real value go on at once, and a grant
    running out still closes what it let through (`gate_test.exs`,
    `egress_revocation_test.exs`, `dns_test.exs`, `egress_bounds_test.exs`).
22. With the Internet off, the VM reaches no public address but network
    grants' and token grants' hosts, and DNS answers only names some grant
    lists; turning it off closes what it let through (`gate_test.exs`,
    `dns_test.exs`).
23. A network grant opens an address by a name only when MWT's DNS answered
    it for a name it covers while it was on, and nothing while its way out
    doesn't carry the route (`policy_test.exs`, `dns_test.exs`,
    `egress_test.exs`).
24. A grant's value never goes to a listed credential endpoint while the rule
    blocks (`egress_test.exs`, `firewall_test.exs`,
    `host_command_channel_test.exs`).
25. For a grant only its subgrants use, nothing holding its placeholder is in
    `/mnt/mwt`, and its placeholder opens nothing
    (`credential_scope_test.exs`, `policy_test.exs`).
26. A confined command sees none of your home but the folders you listed, none
    of MWT's environment, and only the values of the grants it names
    (`host_run_test.exs`, `host_command_channel_test.exs`, `confine_test.exs`).
27. A grant paused by *Only while…* refuses every use (`check_test.exs`).
28. A fetch from the VM carries your committed branches and tags, and from
    `upstream` your remote branches as last fetched; never configuration,
    hooks, other refs, ignored files or uncommitted work. A push is refused
    and moves nothing (`git_transport_test.exs`).
29. A hook or `core.fsmonitor` planted in the VM's clone runs in the VM, never
    here, through a handoff, its revision and its landing (a real VM).
30. No HTTP request saved in MWT is read from the VM (`mwt_tools_test.exs`).

<a id="decisions"></a>

## Decisions

One row per decision in force, dated when it took its current form; the
history is in git.

| Date       | Decision |
| ---------- | -------- |
| 2026-11-11 | The VM gets placeholders, never real values: MWT alone holds the values and swaps them in on the way out, and microsandbox's own secret feature is unused ([Grant kinds](#grant-kinds)). |
| 2026-11-12 | Host commands move the work to where a value is instead of the value to the VM, and agents learn your machine from `mwt host`, never by probing it ([Host commands](#host-commands)). |
| 2026-11-13 | The image is Ubuntu 26.04 with its tools from mise (Erlang prebuilt), built on your machine with podman from your Containerfile and MWT's layer, its last three builds kept, since rebuilding the same recipe later gives other versions; nothing is published, so podman is a dependency ([The image](#the-image)). |
| 2026-11-13 | MWT creates, starts and stops the VM, which stops when MWT quits or locks; the launcher Zed uses only looks at it and goes in while it runs ([Creating the VM](#creating-the-vm)). |
| 2026-11-13 | The proxy, TLS interception and HTTP reading are MWT's own Elixir, with a strict reader of its own: Bandit and Finch read leniently what MWT must refuse, and can't take a connection MWT decrypted ([Each intercepted request](#each-intercepted-request)). |
| 2026-11-13 | The VM's work lives on its own ext4 disks (Home, Cache, Work), which nothing on your machine opens: a folder the VM could write let a planted hook run when you used git there, and a disk is several times faster ([Disks](#disks)). |
| 2026-11-13 | DNS goes through MWT, which logs every name, and a query aimed at another resolver gets no answer ([DNS](#dns)). |
| 2026-11-13 | msb and the VM run in a bubble (`bwrap`), with namespaces of their own, no home folder and no network, reaching MWT over Unix sockets, since libkrun's guest reaches whatever its VMM can; on Ubuntu it is MWT's copy of bwrap, `/usr/lib/mwt/bwrap`, under an AppArmor profile the deb installs that lets what runs inside hold `CAP_NET_ADMIN` and `CAP_SETPCAP` and nothing else ([The VM runs in a bubble](#the-bubble)). |
| 2026-11-13 | Text the VM chooses is made to show all it holds where it enters MWT, and a script for your machine that hides anything is refused rather than shown changed ([Text the VM chooses](#text-the-vm-chooses)). |
| 2026-11-14 | Every use of a grant waits for you unless you allowed it: no rules by method or path, since what a request does depends on the API, only allowances (uses like this one, or every use, for a while) and *Auto-approve*, chosen with a duration as a grant turns on and changed while it stays on ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)). |
| 2026-11-14 | A command's text travels in the ask and is exactly what runs, its output going straight back or waiting for you as you choose, and agents send the smallest command that gets the raw data and work on it in the VM, since a card should take seconds to read ([Ask to run commands](#ask-to-run-commands)). |
| 2026-11-14 | The Overview shows what the VM uses and what it costs this machine, sampled every 5 s while it runs, the last 10 minutes in memory only ([VM monitor](#vm-monitor)). |
| 2026-11-14 | Open in Zed brings an open folder forward (`zed --existing`), adds another to a Zed window already connected to the VM (`--reuse`), or opens a new window, never replacing a window's project, which would end the agent thread in it ([Projects and handoffs](#projects-and-handoffs)). |
| 2026-11-15 | What you save is a subgrant, one fixed use of a grant that MWT carries out when an agent calls it by id with typed values (`mwt call`): your script on this machine under Ask to run commands, or one HTTP request MWT sends with a token grant's real value, each with a switch of its own, and agents only propose them (`mwt propose`) ([Grants and subgrants](#grants-and-subgrants)). |
| 2026-11-15 | Agents hand off only when you ask (`/handoff`) and leave their work uncommitted until then, so you review every change in Zed in the VM; MWT doesn't gate it, and a handoff that came too soon you close, the agent undoing its commits but keeping the work ([Handoffs](#handoffs)). |
| 2026-11-15 | A handoff can be sent back with a note, before or after landing, which MWT says in its thread when it can reach it, and the agent's next `mwt handoff` from that branch revises the same handoff ([Handoffs](#handoffs)). |
| 2026-11-15 | Servers in the VM on ports 4100 to 4199 open on your machine by themselves, at the VM's own address (`127.77.X.Y`, same port), over an SSH tunnel through the launcher; only that range, since forwarding every port listed each language server and test listener ([Servers in the VM, on your machine](#servers-in-the-vm-on-your-machine)). |
| 2026-11-15 | The VM's CPUs and memory start at what this machine can spare, its memory shared with the desktop by resizing it live, and VMs inside the VM stay off unless you turn them on, since they put KVM's nested-virtualization code, where guest-to-host escapes were found, within the VM's reach ([Creating the VM](#creating-the-vm)). |
| 2026-11-15 | Agents in the VM use MWT's notes, diagrams and flash cards over MCP (`mwt mcp`, on the agent channel, no token) under three built-in grants, `mwt-read`, `mwt-create` and `mwt-change`, and every item keeps its versions instead of being marked as an agent's, so any change is undone by restoring one ([MWT's tools in the VM](#mwt-tools-in-the-vm)). |
| 2026-11-15 | MWT reaches agent threads in Zed through `mwt-acp`, a thin ACP proxy Zed starts for Claude (MWT) and Codex (MWT), which installs the adapters the ACP registry names, passes every message through, tells MWT which threads are open and puts MWT's messages in an open one at once, a thread that isn't open being an error, not a queue ([Agent threads](#agent-threads)). |
| 2026-11-15 | The MWT you use every day is the installed package, which loads no code from a folder a VM can write; agents work on MWT in the VM and hand it off, formatting only what Zed formats on save, the same way, so a file you save stays as it is ([Developing MWT](#developing-mwt)). |
| 2026-11-16 | Shared folders are copied into the VM one way, every few seconds, never mounted, since a mount handed the VM what a repository keeps beside its code and needed a microsandbox fork to stay coherent; what the VM changes in a copy stays there, set aside in `/work/.rescued` when MWT next writes that path ([Shared folders](#shared-folders)). |
| 2026-11-16 | Starting, stopping and recreating the VM wait for its file copies to finish or fail, since `msb exec` names a VM by a name a recreate reuses ([Shared folders](#shared-folders)). |
| 2026-11-16 | Nothing of your machine is mounted in the VM: `/mnt/mwt`, MWT's files for it, is copied into a folder in its memory, whole at each start and within moments of each change, and the image holds only pointers into it, so one image serves any identity and a new CA needs no rebuild ([What MWT hands to the VM](#what-mwt-hands-to-the-vm)). |
| 2026-11-16 | The VM has an OptMem of its own, on a disk of its own, which can start from a copy of yours and syncs with yours from the Memory card, only what you tick joining yours, since your agents act on their memory ([The VM's OptMem](#the-vms-optmem)). |
| 2026-11-16 | MWT ships its own `msb`, the stock v0.7.15 release (commit `f9ae8e23d`), no fork, with a microsandbox home per identity, never an `msb` you install, and microsandbox on Linux is its one VM backend for now ([Runtime](#runtime)). |
| 2026-11-16 | A firewall watches what the VM does through MWT and, on the first sign of trouble, isolates it until you release it, its rules going by behaviour and by lists you edit, never by attack signatures, which change every week and are easy to dress up ([Firewall](#firewall)). |
| 2026-11-16 | Your history tells what changed, never that it was made in the VM: a handoff's title is a commit message about the change, in the project's style, agents' messages and comments never mention the VM, slots, handoffs, grants or MWT, and the handoff's body stays out of git ([Handoffs](#handoffs)). |
| 2026-11-16 | Agents add an HTTP request sample only when you ask and never read one, since your history holds the credentials you sent, and make notes, diagrams and flash cards when you ask, unasked only the rare flash card of a settled, costly decision of yours that the code can't show ([MWT's tools in the VM](#mwt-tools-in-the-vm)). |
| 2026-11-17 | Agents reach MWT only through the `mwt` command over vsock, which any agent or script runs with no setup, and are told access comes only from grants: `mwt grants` and `mwt why` say which grant they need, `mwt vm` whether this is the VM MWT runs ([Agent channel](#agent-channel)). |
| 2026-11-17 | Grants have generic types (token, network, command, and MWT's built-in ones), none tied to a provider, each with your words for what it is for, which agents read, and each kept to what a sentence explains ([Grant kinds](#grant-kinds)). |
| 2026-11-17 | Presets are JSON files that only fill the add form: what one gives is copied onto the grant, and nothing looks at the preset again ([Presets](#presets)). |
| 2026-11-17 | The Internet is a built-in network grant for every public address, enabled on startup and never asking per connection, since a card could show only an address; off, the VM reaches only what other grants list and DNS answers only names some grant lists, and an address in this machine's own networks is never public, whatever its range ([Grant kinds](#grant-kinds)). |
| 2026-11-17 | A network grant's names are bound by MWT's own DNS answers, and TLS goes on only with a name answered for that address, since resolving at connect time let what the VM was told and what MWT checked differ; a grant may name its DNS server and its way out, opening nothing while that interface doesn't carry the route ([Private networks](#private-networks)). |
| 2026-11-17 | Whether a use goes through, asks or is refused is one pure function of the grants, the use and the clock (`Policy.decide/3`), and the network path decides from a view the server publishes, in each connection's own process, so a busy server makes nothing wait ([Each connection](#each-connection)). |
| 2026-11-17 | A token grant's real value goes only into its carriers, the answer to a request MWT put it in is read whole (every head scrubbed, a body carrying the value cut), and everything else MWT moves into the VM is looked through for real values and credential shapes, a command's output holding one waiting for you whatever its approval mode ([What comes back](#what-comes-back), [What enters the VM](#what-enters-the-vm)). |
| 2026-11-17 | TLS to hosts no token grant lists is passed through unread: reading every connection would break clients that pin certificates and turn "passed through unread" into "read by MWT" for all of them ([What comes back](#what-comes-back)). |
| 2026-11-17 | The activity log keeps what a request MWT read carried and what came back to the VM, at most 64 KiB of each body and never the real value, so an agent's failing call can be read in MWT ([What the log keeps of a request](#exchanges)). |
| 2026-11-17 | The firewall refuses a request carrying a grant's value to a credential endpoint, a host or path whose answer is a credential, before the value is fetched, since that answer would bring a new credential into the VM ([Rules](#rules)). |
| 2026-11-17 | An approval is decided only on the Approvals page and answers only what its card shows: an ask joins a waiting card only when it is the very same, compared whole by SHA-256, a held request shows in full, every header shown and the placeholder's carriers named, kept in memory only, and a notification, MWT's own, only brings MWT forward on it ([Approvals](#approvals), [Desktop notifications](#desktop-notifications)). |
| 2026-11-17 | Ask to run commands (`commands`) is built in, off and can't be removed: only while it is on may agents ask to run a command they wrote, every such run waits for your approval of its exact text on a card drawn in red, as only an agent's own command is, and nothing runs one unasked ([Ask to run commands](#ask-to-run-commands)). |
| 2026-11-17 | Every grant and subgrant has a start setting, *Disabled* (the default), *Enabled, ask* or *Enabled, auto*, and every start of MWT begins from these, every allowance ending with the session ([When MWT starts](#when-mwt-starts)). |
| 2026-11-17 | Each grant and subgrant has one switch, *Always ask me*, under which every use is a card you allow once, no allowance or Auto-approve covering it ([Always ask me](#ceiling)). |
| 2026-11-17 | The Grants page is a catalog: what is enabled first and apart, in full with its controls, so you always see what the VM can use, then every grant and subgrant as a card, with a search, filters and a sort ([The Grants page](#the-grants-page)). |
| 2026-11-17 | Token grants reach a command only through `mwt exec GRANT -- COMMAND`, with no token variable in the VM's environment or profiles and git's helper answering only for the selected grant, and a grant can keep its value for its subgrants alone, the VM then holding no placeholder of it ([Who uses its value](#who-uses-its-value)). |
| 2026-11-17 | A token grant names the presentations `mwt exec` runs for it, small programs that show a placeholder the way a tool family expects (the first, a cloud metadata server, for Google Cloud grants), which hold only placeholders, so adding one is no trust decision ([Presentations](#presentations)). |
| 2026-11-17 | A mint command is told which grant it mints for and, for a grant minted per host, which host (`MWT_HOST`), may say when its value expires, and runs as you, the one place that touches your login ([Where real values come from](#where-real-values-come-from)). |
| 2026-11-17 | A grant can hold conditions, *Only while…*: scripts of yours, run confined, whose failure pauses it for every use, since MWT can't know whether what a grant depends on, such as a VPN, is there ([Checks](#checks)). |
| 2026-11-17 | New command subgrants run confined, in a bubble on this machine with an empty home, your tools read-only and only the values of the token grants they name, since a script run as you had your whole home in reach ([Confined commands](#confined-commands)). |
| 2026-11-17 | Every process of a VM's bubble runs under a seccomp filter MWT writes, refusing what a VMM never calls and kernel exploits reach for, and any new user namespace, since bwrap's `--disable-userns` would nest the sandbox where the relay's `CAP_NET_ADMIN` can't reach its network ([The VM runs in a bubble](#the-bubble)). |
| 2026-11-17 | Every `msb` MWT runs on this machine, the launcher's included, runs confined with no KVM, and what MWT trusts of a VM (the forwarding's SSH control socket, the bubble's process id and log) sits outside the folder its bubble mounts, so a VM that broke out can neither boot itself through msb nor add listeners here ([The VM runs in a bubble](#the-bubble)). |
| 2026-11-17 | Every git repository in a shared folder is a project and reaches the VM only as a clone of its own, never in a folder's copy; the Projects page shows those you work with now, *Open project* the rest, and a clone whose repository is gone stays in the VM until you remove it ([Projects and handoffs](#projects-and-handoffs)). |
| 2026-11-17 | The VM's clone has your repository, through MWT, as its `origin` (`mwt::<id>`), so a fetch brings your committed branches and nothing else travels, and a push is refused, since work comes back only by handoff, which carries title, notes, checks and thread ([Projects and handoffs](#projects-and-handoffs)). |
| 2026-11-17 | Fetching from your repositories, fetching from their own remotes and handing off are built-in grants (`git-fetch`, `git-fetch-remote`, `git-handoff`), enabled and auto-approved at start, while landing is yours, never a grant the VM asks for ([Git as grants](#git-grants)). |
| 2026-11-17 | Commits in the VM are yours: opening a clone sets its `user.name` and `user.email` to those your repository uses on your machine, and agents never change them, pass `--author` or add `Co-Authored-By` lines ([Projects and handoffs](#projects-and-handoffs)). |
| 2026-11-17 | Agents work in worktree slots, one task each, slot-0 the clone itself and the others worktrees you add and remove, so builds stay warm and Zed paths never move; MWT keeps no state of them but git's, and never moves, resets or deletes a branch in the VM ([Worktree slots](#worktree-slots)). |
| 2026-11-17 | A thread works only in the slot it was opened in, takes it first even for a question, on a branch named for what you asked and based on the branch you name, and holds it until its handoff lands or is closed, a second thread there only reading ([Worktree slots](#worktree-slots)). |
| 2026-11-17 | `mwt handoff` does every step that needs no judgment: it fetches, commits the changes to files git has, rebases onto `origin/<base>`, runs the project's checks and sends that exact commit, pinned in MWT's review store, which borrows your repository's objects, so nothing enters your repository until you land it ([Handoffs](#handoffs)). |
| 2026-11-17 | A handoff's page is about landing, since you reviewed the work in the VM before asking for it: it lands as it is, a fast-forward to the commit its checks ran on, when the branch hasn't moved, so the clone and your repository agree, else as one commit marked untested with what came since, onto the task's base, any branch you choose or a new `mwt/` branch ([Landing](#landing)). |
| 2026-11-18 | Agents propose whole grants (`mwt propose token`, `mwt propose network`) as well as subgrants, and what they propose is saved at once, off, never enabled on startup, tagged as proposed and to review; nothing turns it on until you accept it on its page, and declining or removing it before then tells the agent ([Proposed grants](#proposed-grants)). |
| 2026-11-18 | There is no YOLO mode and no file grant: nothing counts a grant as on but its own switch, and no grant hands the VM a real value. A file grant saved before is dropped as MWT starts, with its value, and Activity says which. |
| 2026-11-18 | Releasing the VM from the firewall turns back on what was on when it was isolated, as it was, for the time it has left ([Releasing](#releasing)). |
| 2026-11-18 | Every field of the grant form and of a grant's conditions has a *?* saying what its value means and what it is for; All grants shows six cards a page ([The Grants page](#the-grants-page)). |
| 2026-11-18 | Catching a handoff up with its moved branch takes a click: MWT replays its commits there itself where they apply cleanly, or sends it back to catch up with a note that is also the ask to hand off again, so its thread resolves the conflicts and hands off without another `/handoff`. A revision is measured from where its branch meets the base now, and `mwt handoff` goes on with a rebase it stopped before anything else ([Landing](#landing)). |
| 2026-11-18 | The firewall's rules were hardened against evasion and against false alarms. A connection claiming a trusted name over TLS is spared only at an address MWT's own DNS resolved for it, so the trust can't be borrowed to tunnel out unread. Uploads are counted by domain, so spreading them across subdomains folds together. DNS-name data is weighed by bytes, not just a count; a single long name is refused rather than isolating the VM, and names under cloud providers' own domains and the reverse names of addresses are no longer mistaken for exfiltration. Credential-endpoint paths are read as the host would (percent-decoded, `.`/`..` resolved), and a protected path is caught through quotes or backslashes slipped between its letters. A horizontal sweep (many addresses on one non-web port) joins Scanning, and DNS straight to a public port 53 joins DNS around MWT. The blocked, resolver, credential-endpoint and protected-path lists grew, more credential shapes are recognised entering the VM, and new default protected paths and credential endpoints reach a saved firewall on upgrade ([Firewall](#firewall)). |
| 2026-11-18 | One *VM isolated* switch on the Firewall page: the firewall turns it on, and so can you, to cut the VM off yourself; turning it off releases the VM, asking first, with what the firewall saw and whether to trust its destination, only when the firewall isolated it. The page is shorter: rules grouped a line each, their full text behind a "?", the lists in tabs, past isolations folded under the switch ([Isolating](#isolating), [The Firewall page](#screens-firewall)). |
| 2026-11-18 | The app is MWT (My Work Tools): the app, its package, the VM's `mwt` CLI, `/mnt/mwt`, its agents in Zed and its tools over MCP all take that name. Nothing under the former name is read or brought over: an install starts fresh. |

<a id="later"></a>

## Later

Open: not built, or not tried yet.

- **`resign` and `signing` grants:** AWS SigV4 re-signed by MWT (the VM signs
  with dummy keys); an SSH agent over vsock, approval per signature.
- **More presentations** in `mwt-present`: a container registry's credential
  helper, a Kubernetes exec credential, a `credential_process`.
- **Finer allowances,** if asking about every use proves too much: what to
  auto-approve or always ask, by method, path or pattern, or per provider.
- **Confined ad-hoc commands,** as a choice on their card.
- **HTTP/2 on hosts MWT reads:** spiked, not built (frames, per-stream
  decisions, an HTTP/2 answer scan); until then gRPC hosts stay off token
  grants.
- **Names beside addresses** in the activity log, from the DNS answers,
  saying when a TLS name and its address never met.
- **More firewall rules:** a credential of yours used from the VM with no
  grant, a connection to an address no lookup gave, a handoff touching files
  that run on their own (hooks, CI).
- **Secrets in shared folders** (`.env`, `*.pem`, tokens in remote URLs)
  looked for, with a warning when you pick one.
- **The VM:** a second backend from stock parts (QEMU or Cloud Hypervisor,
  vsock; spiked in `test/review/vm_spike`); a published default image, so
  podman is needed only to change it; containers inside it (klife's Kafka
  test clusters), not checked.
- **msb's SSH channel leak** reported upstream (a fix with tests is stashed
  in `~/projects/microsandbox`).
- **The release:** the deb and rpm built with the install scripts and tried
  on fresh Fedora and Ubuntu, the real-VM suite run from them, signed
  checksums, a page on what MWT protects and what it doesn't, how to report
  a security problem.
- **Not tried yet:** the real-VM suite on MWT's own image (it uses Alpine);
  the live VPN check (a VPN name resolved, a VPN host reached, a grant's way
  out); a large repository through the clone; Claude (MWT) live in Zed.
- **Export:** `.mwtexport` with grants (their values only if you ask, if at
  all), settings, the VM's OptMem read through the running VM, and items'
  versions; how the CA moves.
- **The VM's OptMem:** its review offered in the Approvals queue, not only on
  the Memory card; seeding it with only some projects' memories.
- **Projects:** a folder picker and the upstream branches on the Projects
  page; submodules and LFS files; your uncommitted work sent by git, as a
  snapshot beside `origin/BRANCH`.
- **Handoffs:** landing on a repository's own remote; revisions read through
  `origin`; handoffs in MWT's Git tool, and that tool on repositories in the
  VM; MWT's review store cleaned up when its repository is gone.
- **Agent threads:** telling the thread that asked when you turn its grant
  on; the threads on the Overview; saying when one waits for your permission
  (`session/request_permission`); keeping whole conversations in the record.
- **Zed and ACP:** a turn MWT started shown as running (a fix on Zed's side
  is being looked into); `mwt-acp` following Zed to ACP v2; whether Zed lets
  go of threads you didn't close; the new session id Claude's adapter gives
  Claude Code under the same ACP id after a plan-mode restart.
- **Notifications** elsewhere than GNOME (KDE, macOS), and a sound or urgency
  per kind of approval.
