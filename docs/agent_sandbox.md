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
2. **You see and decide what the VM does outside it, one request at a
   time.** Everything the VM sends out goes through MWT, which reads it
   down to the requests it carries, in each protocol it has a driver for:
   an HTTP request, a query on a database you shared. Each request is in
   the log with what came back, and any grant can hold its requests for
   your approval, each on a card of its own, so sharing a database or an
   API with an agent doesn't mean sharing everything it could do there.
   What MWT can't read as requests, it can only let through or stop whole,
   and says so.
3. **Agents cannot act as you beyond what you allow.** The VM never holds a
   credential when there is any way to avoid it: MWT puts the real value
   into a request only where a grant says, one more thing reading each
   request makes possible. You turn access on and off on the spot.

<a id="threat-model"></a>

## Threat model

**Who it defends against:** whatever runs in the VM, as root: an agent
following instructions planted in a web page or a repository, or a package
it installed. It can do anything inside the VM, and send any bytes to the
three channels it can open to MWT: the proxy, DNS and the agent channel
(git fetches included). Over the channels MWT opens into it (`msb exec`,
`msb ssh serve`) it answers what MWT asks, and what it answers is read as
the VM's word ([Channels](#channels)).

- It is not assumed to hold a working exploit against KVM or microsandbox.
  If it does, [the bubble](#the-bubble) decides what it reaches.
- Not defended: what you approve; leaks of what you gave the VM (below);
  other programs running as you.

**Promises**, each a numbered line in [Guarantees to test](#guarantees-to-test):

| Promise                                                         | Kept by                                                                                                               |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| The VM never holds a credential                                 | Placeholders, swapped by the proxy                                                                                    |
| Nothing leaves the VM except through MWT, DNS included          | The process running the VM has no network; its ways out are MWT's sockets; MWT's own pages load nothing from an address the VM chose (a Content-Security-Policy, and Markdown's images shown as links) |
| Nothing the VM writes runs on your machine unless you chose it  | The VM's work reaches your repository only as a [handoff](#handoffs) you land, and landing runs no hook; shared folders are copied one way, into the VM; the [workspace](#the-workspace)'s `from-vm/` lands only files and folders, read-only, nothing executable, no name a tool acts on by being there; every command an agent asks to run waits for you, its exact text on a card, and locking your machine stops even the asks |
| A VM escape reaches no home folder and no network               | [The bubble](#the-bubble), and msb confined wherever MWT runs it on this machine                                      |
| An approval shows what will happen, with nothing hidden in it   | Facts MWT works out itself, the agent's words kept apart, and text that is written out wherever it hides something ([Text the VM chooses](#text-the-vm-chooses)) |
| What you turned off stays off                                   | A restart of the sandbox's server after a failure puts each grant back as it was, with the firewall's counts (`MWTClient.Sandbox.UnlockState`); only opening or unlocking MWT starts grants from their start settings; your [locks](#locks) are saved with the sandbox, and isolating or releasing changes no grant |

**Not covered:**

- **Leaking what the VM has.** Outbound traffic is passed through by
  default, so an agent can upload anything in a shared folder's copy or a
  project's clone. The [firewall](#firewall) isolates the VM on 4 MiB sent
  to one destination in 10 minutes; less than that, spread over many
  destinations, or through a trusted one, still goes.
- **Code you run from a handoff you landed.** Landing runs no hook, but the
  commits are the VM's: building or testing them on your machine runs what
  they hold. Your review is the check.
- **What your programs do with a file of the workspace's `from-vm/`**
  once you open or run it (a viewer's parser, `bash` on a script), as with
  a download; and a command or action that takes it as its input runs on
  what the VM chose. Its card says when a script names the workspace
  ([The workspace](#the-workspace)).
- **Data sent out through DNS** while the Internet is on. Every lookup goes
  through MWT and is in the activity log, and a query aimed at another
  resolver gets no answer. But MWT passes on every name, so query names can
  still carry data out. The [firewall](#firewall) judges their shape (long
  labels, many names under one domain), not their content; a little at a
  time still goes. With the Internet off, only names network grants that
  are on list go out.
- **A real value the VM got anyway, sent where MWT can't read.** The
  firewall looks for real values wherever MWT reads what the VM sends, and
  MWT reads every Internet connection it can. What it can't (TLS naming no
  host or offering only protocols no driver speaks, a host you set as *Not
  read*, a server that speaks first, plain bytes that aren't HTTP) and a
  network grant's connections it can't read are tunnelled unread, and a
  value changed before it is sent (base64, in pieces) isn't recognised
  anywhere.
- **A body past its first 64 KiB** goes to the host as it streams, looked
  through for real values but never shown: a card holds the start of the
  body, and says so when that is all it holds
  ([Each intercepted request](#each-intercepted-request)).
- **A passed-through connection is logged under the name the VM gave** (the
  TLS name), which MWT doesn't check against the address: the VM can make a
  connection to any public address read as `github.com` in the log. A
  connection MWT read is logged under a name the host proved, with its
  certificate, to the TLS MWT started.
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
                                               ├─ public addresses → the Internet's grant; off, only a network grant on listing them
                                               ├─ TLS to a host a token grant lists → read
                                               │     read request → a grant on for each resource it uses, its network's limits → swap → forward
                                               ├─ TLS to any other public host, naming it, offering HTTP/1.1, HTTP/2 or nothing,
                                               │  and plain HTTP, not set as Not read → read, each request judged (the Internet's
                                               │  grants and its host limits), logged with what it carried
                                               └─ anything else → blind byte tunnel (log host, bytes, duration, why unread)

VM ──DNS──▶ msb ──▶ relay ──dns.sock──▶ MWT DNS forwarder ──▶ this machine's resolver (every name logged;
                                                              with the Internet off, only names network grants on list)

VM ──vsock:5000──▶ $XDG_RUNTIME_DIR/mwt/<id>/channel.sock ──▶ agent channel: `mwt` (grants, request, call,
                                                                │  run, host, why, ports, project, worktree,
                                                                │  handoff, mcp) and git fetches (`mwt::<id>`)
                                                                └─ `mwt run`, once you approve it ──▶ bash -lc here, as you

MWT ──msb exec──▶ msb's agent in the VM: the boot script, /mnt/mwt and shared folders copied in, the monitor's
                                        samples, slots, handoffs (git over ext::), the VM's OptMem, Kill
MWT, Zed ──msb ssh serve──▶ msb's agent in the VM: ports 4100-4199 forwarded here, Zed's remote project

/mnt/mwt (copied in, in the VM's memory): CA bundle, placeholders, the `mwt` command, git's credential helper,
                                          host.md, the boot script
/root, /cache, /work, /root/.optmem: the VM's own disks (ext4 images here, which nothing here opens)
shared folders: copied one way onto /work/.shares, shown read-only at their paths; the repositories in them are clones on /work
the workspace (~/mwt-vm): to-vm/ yours, copied in as a shared folder; from-vm/ the VM's, on /work/.workspace, copied out under its rules

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

<a id="channels"></a>

## Channels

Six channels join the VM and MWT. The VM opens three, over two of its
devices: its network card carries the proxy and DNS, vsock the agent
channel. MWT opens the other three: two through msb's own agent in the VM,
one to the relay alone. Each is there because msb offers nothing else for
its job:

| Channel | Opened by | Path | Carries | Why it is a channel of its own |
| ------- | --------- | ---- | ------- | ------------------------------ |
| **Proxy** | the VM | network card → msb (`--proxy`) → relay, `127.0.0.1:3128` in the bubble → `proxy.sock` | every TCP connection ([Network](#network)) | msb's only hook for TCP, which the VM can't go around |
| **DNS** | the VM | network card → msb (`--dns-nameserver`) → relay, `127.0.0.1:5353` → `dns.sock` | every lookup ([DNS](#dns)) | msb sends lookups to a nameserver of its own, never through the proxy |
| **Agent channel** | the VM | vsock port 5000 → msb (`--vsock`) → `channel.sock` | `mwt` and its MCP, git fetches from `host-origin` and `remote-origin` (`mwt::`), Zed's threads (`mwt-acp`), the ports report ([Agent channel](#agent-channel)) | the proxy refuses this machine's own addresses, so nothing on the network reaches MWT |
| **`msb exec`** | MWT | msb's agent in the VM | the boot script; `/mnt/mwt`, shared folders and OptMem copied in; the monitor's samples; slots and handoffs (git over `ext::`); Kill | msb's vsock carries the VM's connections to this machine, never this machine's into the VM |
| **`msb ssh serve`** | MWT, and Zed | the launcher → msb's SSH server → msb's agent in the VM | ports 4100 to 4199 forwarded here ([Servers in the VM](#servers-in-the-vm-on-your-machine)), Zed's remote project | msb's only way to carry TCP into the VM, and Zed needs an SSH server |
| **Relay control** | MWT | `control.sock`, to the relay | `status`, `stop`, the VM's memory resized | msb records the VM's pid as the bubble sees it, so only something inside can stop it |

- **The relay** joins the ports msb is given to MWT's Unix sockets. msb
  wants TCP and UDP addresses, and MWT listens only on sockets in a folder
  only you can open, so no other program on this machine reaches the
  proxy ([The bubble](#the-bubble)).
- **What the VM sends on its three** is decided by MWT and logged: a
  connection, a lookup, an ask. **What it answers on MWT's three** is the
  VM's word, read as such: output is capped (`Msb.max_output/0`), the
  ports report holds numbers in the range, a handoff is commits you review.
- **msb's agent** carries `msb exec` and `msb ssh serve` both, over
  virtio-console. A VM that broke out of msb's agent protocol reaches msb's
  process in the bubble, as any escape does.
- **msb's runtime share,** `/.msb` in the VM, is a virtiofs folder of
  16 MiB served by msb in the bubble, which the VM can write: msb's agent
  keeps `heartbeat.json` there, and the root filesystem's layers are
  mounted beneath it. It holds nothing of MWT's, and nothing of this
  machine's outside the bubble.
- **One channel** would mean a VM with no network card, reaching MWT over
  vsock alone, both ways, as the spike of a second backend did
  (`test/review/vm_spike`). msb always gives the VM a network card, and
  only its agent reaches into the VM, so under msb the six stay; a second
  backend is where to revisit it ([Later](#later)).

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
  and a recreate reuses the name. Locking or quitting MWT while a start,
  create or recreate is under way ends it and stops what it launched,
  asking the relay again until it listens (`Machine.shut_down/2`); a crash
  leaves both alone.
- **Not started from Zed:** `msb ssh` would boot a stopped VM outside the
  bubble; the launcher refuses it, and there it has neither the disks'
  paths nor KVM.

<a id="disks"></a>

### Disks

Sparse ext4 images in `…/sandbox/disks` (`MWTClient.Sandbox.Disks`), made
with `mkfs.ext4 -E root_owner=0:0` (no root needed), attached with
`--mount-disk`. Nothing on this machine mounts them or runs what is in
them, so a hook or `.git/config` line an agent writes runs nowhere here;
and they are several times faster than a shared folder (10,000 files made
in 0.85 s, not 3.51 s). Two tools do read the file system root in the VM
wrote: `e2fsck`, when you reclaim a disk's space or a disk grows, and
`resize2fs`, when it grows. They run in a bubble of their own: no network,
no home, the system read-only, nothing of MWT's environment, and the one
image, writable (`Disks.check_words/3`); without `bwrap` they don't run.

| Disk   | In the VM       | Holds                                                                                           | Default      | Recreating                                            |
| ------ | --------------- | ----------------------------------------------------------------------------------------------- | ------------ | ----------------------------------------------------- |
| Home   | `/root`         | Codex and Claude logins, shell history, Zed's server, agent settings, your mise config            | 16 GiB       | Keep (default), go back to a snapshot, or start empty |
| Cache  | `/cache`        | Runtime tool versions (`MISE_DATA_DIR`); hex/mix, npm/pnpm, cargo, go, uv and pip caches         | 64 GiB       | Keep (default) or clear                               |
| Work   | `/work`         | Project clones, their worktrees and builds, shared folders' copies (`/work/.shares`)            | 64 GiB       | Always kept; emptied only when you ask                |
| Memory | `/root/.optmem` | [The VM's OptMem](#the-vms-optmem), mounted after Home                                          | 2 GiB, fixed | Kept, whatever happens to Home                        |
| Root   | `/`             | The image's copy; apt packages, `/tmp`, `/var`                                                  | 64 GiB       | Starts empty                                          |

- **Sizes** are settings, and the limit on what the VM writes: the root
  disk's applies by recreating (microsandbox's default is 4 GiB), the
  others' at the next start, bigger only. A disk is checked (`e2fsck -p`)
  before its file grows: one whose check fails stays as it was, and each
  start says why.
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

Three parts, in this order (`MWTClient.Sandbox.Image`), all in
`priv/sandbox`:

1. **MWT's base** (`mwt-base.Containerfile`), MWT's, read-only: Ubuntu
   26.04 and what MWT itself runs in the VM: bash, coreutils, GNU find and
   tar, sed, grep, awk, util-linux, git, socat, iproute2 (`ss`), python3
   (`memo`), ca-certificates with openssl, bubblewrap.
2. **Your layer** (`your-layer.Containerfile` is MWT's default), yours to
   edit on the Build page, with no `FROM`: it starts after the base. Each
   save keeps the layer it replaced, as a note's versions are
   (`MWTClient.Sandbox.LayerVersions`, the `image_layer_versions` rule).
3. **MWT's final layer** (`mwt-final-layer.Containerfile`), MWT's: it
   checks that your layer left what MWT runs, and stops the build naming
   what is missing; points the VM at `/mnt/mwt` and `/cache`
   ([What MWT hands to the VM](#what-mwt-hands-to-the-vm)); keeps podman's
   storage on `/cache`; and, last, lists the checksum of every file in
   `/etc/mwt/image.sha256`, for the image check.

The Build page shows the three as one text, what podman builds
(`Image.full/1`), and each build keeps it. MWT builds it with rootless
podman here, `--format docker` (else podman ignores `SHELL`, and
`pipefail` with it), and loads it into microsandbox. Nothing comes from a
registry of MWT's.

- **Base: Ubuntu 26.04,** fixed by MWT: hex.pm builds Erlang only for
  Ubuntu (`MISE_ERLANG_PRECOMPILED_OS=ubuntu-26.04`, seconds rather than
  minutes per version; Debian, Fedora and Alpine have none), Playwright
  supports it, and it is patched until 2031.
- **apt only for what mise can't do,** in the default layer: the C
  toolchain, openssh-client, curl, unzip, xz, postgresql-client, sqlite3,
  inotify-tools, tmux, bash-completion, Playwright's libraries, and podman
  with `podman-docker` and nftables.
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
- **Your layer across updates:** it is kept, so it gets no new defaults by
  itself. In **Agent Sandbox → Settings → Build**: review it, **Start from
  MWT's default**, **Save**; **Build** (a running VM doesn't change);
  **Recreate**, keeping Home and Cache if you like (a stop and start runs
  the same image); reconnect Zed. A recipe from before the base was MWT's
  (2026-11-24), a whole Containerfile, became the newest version of your
  layer, replaced by MWT's default; the Build page says so until you save.
- **Containers in the VM:** podman, rootful, as `docker` too. Its storage
  is on `/cache` (`/etc/containers/storage.conf`, from the final layer):
  on the root overlay, podman's own overlay can't mount, and `/cache`
  survives recreating. Its network needs nftables (netavark). They trust
  MWT's CA through `/etc/containers/containers.conf.d/50-mwt.conf`, which
  the boot script writes, the CA's hash being the identity's: every
  container and build gets the CA mounted as `/etc/ssl/certs/HASH.0`, the
  name OpenSSL looks it up by, so a build that installs ca-certificates
  replaces nothing of it, and the bundle and CA at `/run/mwt`; `podman
  run`, not a build, also gets `SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
  `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` pointing there. Nothing of
  it is committed into an image built in the VM. Mounting the bundle over
  `/etc/ssl/certs/ca-certificates.crt` instead broke every build that
  installs ca-certificates (it can't replace a mounted file). In a build,
  tools that carry their own CAs (Node, Java, gcloud's installer, Python's
  certifi) still need it named in the step: gcloud's install failed so in a
  build of MWT's own image in the VM. The boot script also
  clears podman's runtime state, since `/run` is on the VM's disk.
- **The image check** (`MWTClient.Sandbox.ImageCheck`): after a VM's
  first start, MWT mounts its image disk (`/dev/vda`, EROFS) read-only in
  the VM, apart from its root, and checks every file against the build's
  list, in a task of its own (7 to 20 s for 5 GB). The result goes on the
  VM's record; damage shows on the Overview, naming the files, with
  **Rebuild without cache** (`--no-cache --pull=always`) on the Build page.
  It catches a damaged image, not a hostile VM, which reports it. Seen once:
  `docs/issues/vm-image-file-zeroed-after-load.md`.
- **Deleting a build:** any kept but the current one and the VM's.

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
  MWT makes is copied (`Server.Copying`), and a look every 3 s checks it. Files are replaced whole, by rename. A grant turned on reaches
  an agent waiting on `mwt request` once that copy ended, within 10 s.
- **The VM's own changes** to it change nothing MWT does; the whole
  comparison at the next start puts it back, setting nothing aside. Past the
  first copy it needs
  bash and GNU `find`, `stat`, `mv`, `chmod`, `tar`; a failed copy shows in
  the VM's status.

| In `/mnt/mwt`                                        | What                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------- |
| `ca.pem`, `ca-bundle.pem`                            | The identity's CA, alone and appended to this machine's trusted roots           |
| `java-truststore.jks`                                | The same roots as `ca-bundle.pem`, as a JVM reads them (`MWTClient.Sandbox.JavaTrust`) |
| `profile.sh`, `bashrc.sh`, `env.sh`                  | Tool paths and interactive defaults; no credential exports                      |
| `grant-env/<id>.sh`, `tokens/<id>`, `logins/<id>.json` | A [credential](#credentials)'s environment, for `mwt exec <id> -- COMMAND` while a grant over it is on; its placeholder; its Google login file |
| `bin/git-credential`, `git/<id>`                     | git's credential helper; the hosts a selected credential answers git for        |
| `bin/mwt`, `bin/mwt-acp`, `bin/mwt-present`          | The [`mwt` command](#agent-channel); the ACP shell; the presentations           |
| `bin/mwt-boot`, `agents-block.md`, `handoff-command.md`, `bin/memo` | What the boot script copies; `memo` when you have OptMem       |
| `AGENTS.md`, `grants.md`, `host.md`                  | What agents are told; what `mwt grants` prints; [your machine](#host-commands)  |
| `guides/<topic>.md`                                  | What only some tasks need, which `mwt help TOPIC` prints                        |

**MWT's final layer** points only into `/mnt/mwt`, so one image serves any
identity, the CA changes without a rebuild, and old tags keep working:
`/etc/ssl/certs/ca-certificates.crt` links to `ca-bundle.pem` (a hook in
`/etc/ca-certificates/update.d` restores it when a package regenerates it),
and the per-tool CA variables (`HEX_CACERTS_PATH`,
`CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` and others) point there too.
`JAVA_TOOL_OPTIONS` points every JVM at `java-truststore.jks`: a JVM reads
neither the system's bundle nor those variables, only the `cacerts` of its
own install, so Gradle, Maven and the rest would refuse MWT's certificate
on a host MWT reads. Each JVM says so on stderr as it starts ("Picked up
JAVA_TOOL_OPTIONS"); a build made before 2026-11-22 lacks it until it is
rebuilt;
`/etc/profile.d/mwt.sh` and `BASH_ENV` point at `profile.sh`, so every
`bash -c` reads it, and `/etc/bash.bashrc` loads `bashrc.sh`; git's
credential helper is `bin/git-credential`, which answers with a placeholder
only within `mwt exec CREDENTIAL -- COMMAND`, and GitHub's SSH URLs are
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
the VM's `~/.config/zed/settings.json`; MWT's CA in Chromium's certificate
store (`~/.pki/nssdb`), when the image has `certutil` (`libnss3-tools`, in
the default Containerfile), since Chromium, Playwright's included, trusts
that store and not the system's bundle. It starts `mwt ports --watch`.

**What agents are told** comes in two parts. `priv/sandbox/agents.md`
holds what every task needs, and is kept short: Claude Code and Codex load
it whole into every session, subagent and approval review, and a rule
every task needs is followed less often among pages that only some tasks
need. The rest is in guides, `priv/sandbox/guides/TOPIC.md`, which reach
the VM at `/mnt/mwt/guides` and which `mwt help TOPIC` prints: `projects`
(slots in detail, another thread's task, catching up), `handoff` (the
steps, which `/handoff` follows, and what comes after), `access` (token
grants, actions, the network, every `mwt_*` code), `propose`,
`resources` (writing resources and grants: the model, credentials, the
two kinds of grant, networks and their hosts, saved commands, parameters
and their rules, for you and agents alike), `run` and `workspace`. Each
line of `agents.md` that leaves something to a guide
names it, as what to read before doing that.

In short, `agents.md` says:

- work in `/work`, not in shared folders' read-only copies, and `mwt sync`
  before relying on what one holds now; the [workspace](#the-workspace)
  only to move a file to or from your machine, never as storage; a worktree slot
  per task, work left uncommitted for your review, a handoff only when you
  ask, and the VM kept out of the history
  ([Projects and handoffs](#projects-and-handoffs));
- access only from grants (`mwt grants`, `mwt request`,
  `mwt exec CREDENTIAL`; no logins, no pasted or written tokens), each use
  possibly waiting for you; `mwt why --recent` when a tool fails with a
  bare 403; a refusal by you, a lock or an isolation never worked around;
  actions (`mwt call`) before `mwt run`, the last resort;
- `mise install` first, ports 4100 to 4199 for what you'll open, notes and
  flash cards only when asked, and their memory (the OptMem block).

`agents.md` holds only how to work in the VM. How you like to work with
agents is your taste, not a fact of the VM: **Your way of working**
(Settings), your own text, empty until you write it, which MWT adds after
`agents.md` in the same block under a heading saying it is yours, and
which reaches agents at the VM's next start, when the boot script writes
the block again. Up to 20,000 characters, since agents read it in every
session. MWT offers an example to start from
(`priv/sandbox/way-of-working-example.md`): concepts only, with no worked
examples, since agents read it in every session. In three parts:

- **The main operation, first:** what the system exists for in your world
  and what it actually needs, which agents state back and get your yes on
  before they design, tracing every component to it, and bringing back at
  once when the work shows it is other than you both thought.
- **Decisions:** agents ask you only what is yours to decide and costly if
  wrong (what others rely on, data that is kept, how it behaves in
  production, who carries the work or the risk), early, and decide the
  rest, presenting in the handoff's body the costly choices they made.
  Each comes on three levels: what it is for, how it works here step by
  step, and what each option would do in your world, in plausible
  scenarios (the usual case, more load, a failing dependency, a broken
  assumption).
- **Building blocks:** a component per job the main operation needs,
  named for that job (never a character, a metaphor or a name that says
  nothing), cut where what they live with or what their failure stops
  differs; few simple blocks, one meaning each, premises stated and held
  where the choice is made, composed and reused, with what comes in the
  hundreds as data; a block shared when its callers need the same
  concept, each supplying what differs through a callback, split when one
  needs another meaning, and asked about when in doubt.

<a id="shared-folders"></a>

### Shared folders

You pick each folder. A **git working tree** in it (a `.git` folder or
file, a linked worktree included) reaches the VM only as a
[project](#projects-and-handoffs), a clone of its commits: never in a copy,
wherever it sits, one appearing later included, since a copy would carry
what a repository keeps beside its code (`.env`, ignored secrets, a token
in a remote's URL). **Everything else** is copied one way into the VM and
shown there **read-only**, at the same path as here. The VM never writes to
your folders, and nothing of a copy comes back.

- **Synced when asked, never on a timer** (`Server.ShareSync`): when you
  add the folder, at each start of the VM (every share, each copy compared
  whole), with **Sync** or **Sync all** (Overview and Settings), after a
  command you approved ran in it (so what it left reaches the copy), and
  when an agent runs `mwt sync [PATH]`, which waits for it, through the
  built-in grant *Shared folders: sync* (`share-sync`), enabled and
  auto-approved at start. Between those the copy stays as it was, which
  agents are told. One sync runs at a time; what is asked meanwhile runs
  next, whole, and whoever waits hears when the sync that started after
  their ask ends. A folder with files still being written gets one sync
  more, 3 s later, which asks for no other.
- **Read-only** (`MWTClient.Sandbox.ShareMounts`): each copy lives on the
  work disk, `/work/.shares/ID/files`, and a read-only bind mount shows it
  at the folder's path, so an edit there fails (`Read-only file system`)
  instead of being lost at the next sync, and the copy outlives a
  recreate. Root in the VM could mount it writable again; that reaches
  nothing of yours, and the next whole comparison puts the copy back. Each
  sync first makes the VM show exactly the folders shared: a folder no
  longer shared is unmounted and its copy deleted.
- **How** (`MWTClient.Sandbox.FolderSync`): MWT scans the folder (`lstat`)
  against what it last sent this VM (kind, size, mtime to the second, a
  link's target), kept in `…/sandbox/sync/` so a restarted MWT sends only
  what changed. A file changed in the last 2 s is sent again at the next
  sync; one whose ctime or inode moved is sent anyway. Through `msb exec
  --stream`, a short bash script in the VM removes what you deleted and
  what is in the way; `tar` here feeds `tar -x` there, each file renamed
  into place. A file gone by the time it is sent (a lock or swap file)
  counts as removed, and one this machine won't let MWT read is named in
  the folder's status and the activity log and tried again at each sync:
  neither fails the sync, and what went counts as sent. MWT reads back
  only a file list (`find -printf`, at the first sync after a start or a
  failure), and runs or parses nothing else. A result from before a
  restart or recreate is dropped.
- **Limits:** 400,000 files and folders, and half the work disk in bytes,
  outside the folder's repositories; past either, nothing of it is copied,
  and Overview and Settings say why. Overview and Settings show each
  folder's last sync and what a sync under way is doing.
- **Not handled yet:** a file changed on both sides. Nothing in the VM
  changes a copy, so there is no conflict to settle; if copies ever become
  writable, this needs a rule (see `docs/todo.md`).
- **Refused picks** (`MWTClient.Sandbox.Shares`, after resolving every
  symlink): two that overlap, your home folder, credential folders and
  folders holding one (`~/.ssh`, `~/.gnupg`, `~/.optmem`, `~/.aws`,
  `~/.kube`, MWT's data folder, …), a folder inside a git working tree
  (share the repository), a path the VM uses (`/work`, `/cache`, `/root`,
  `/mnt`).
- **Settings** shows per folder: the VM's file count, when last sent, the
  repositories left to projects, what was set aside, any error.

<a id="the-workspace"></a>

### The workspace

An inbox and outbox between the VM and your machine, for files that
aren't a project's code (`MWTClient.Sandbox.Workspace`): an agent leaves a
file a program of yours reads (a config entry a CLI uploads, an input an
action takes, a report you asked for); a command or action of yours
leaves its result for the agent. It moves files, nothing more: agents are
told to work in `/work`, use it only to move a file across, and remove what
they put there once it served. MWT keeps nothing there for any time, and
knows nothing of projects or tasks.

- **`~/mwt-vm`**, made by MWT at the first sync with the VM running, at
  the same path in the VM, named by **`MWT_WORKSPACE`** in every shell
  there (`profile.sh`) and in every command and action here, confined
  ones included. A second identity's is `~/mwt-vm-<name>`. MWT uses only a
  folder it made (`.mwt-workspace` holds the identity's id): one already
  there, or a symlink, stays as it is, and the Overview says to move it
  away. It can't be shared, nor a folder holding it (`Shares`).
- **Two halves, each written by one side only,** so a file never changes
  on both, and nothing is reconciled:

  | Half       | Written by    | In the VM                                       | Here                                       |
  | ---------- | ------------- | ----------------------------------------------- | ------------------------------------------ |
  | `to-vm/`   | your machine  | a read-only copy, exactly as a shared folder    | yours                                      |
  | `from-vm/` | the VM        | the VM's own, `/work/.workspace/from-vm`, writable | a copy, read-only (files 0444, folders 0555) |

  In the VM, `~/mwt-vm` itself is a read-only frame with each half shown
  over it, so a file left anywhere else in it fails at once. Beside the
  halves here, MWT's own: the marker, a `.trackerignore` that keeps GNOME's
  indexer out, and `.mwt-incoming`, where a copy back stages files.
- **Synced with the shared folders, both halves each time**
  (`Server.ShareSync`): at each start of the VM, with **Sync** (Overview,
  this card's alone or Sync all), after a command you approved ran in a
  half, and with an agent's `mwt sync`, a path inside a half syncing only
  that one. Nothing on a timer. So an agent that wrote into `from-vm/`
  runs `mwt sync` before asking for the command that reads it, and one
  whose command wrote into `to-vm/` from another folder runs it after.
- **The Overview** shows where it is, each half's last sync, files held
  back (below), **Open** (your file manager, `xdg-open`) and **Sync**.

**Grants.** `to-vm/` is a shared folder's copy, under *Shared folders:
sync* (`share-sync`). `from-vm/` is the one way the VM writes onto your
disk without a handoff you land, so it has a built-in grant of its own,
**Workspace: write to your machine** (`workspace`), enabled and
auto-approved at start, as *Git: hand off* is. Off, nothing of `from-vm/`
comes, whoever asks, and what came already stays; an agent's `mwt sync`
with no path syncs the rest and says why `from-vm/` didn't come, and asks
the grant like any use when it is set to ask. Each copy back that changed
something is an event in its activity. It never runs while the VM is
isolated.

**Who writes `from-vm/`:** whatever runs in the VM, as root: any bytes,
names and kinds of file, as often as it asks to sync. **Programs here read
a new file without a click**, and the rules keep out what they act on:

| Program                              | Reads                                       | Kept out by                                   |
| ------------------------------------ | ------------------------------------------- | --------------------------------------------- |
| A shell prompt showing git's state   | a `.git` folder: `core.fsmonitor` and hooks run as you, and `safe.directory` doesn't stop them, since MWT writes the files as you | no name starting with `.`; the workspace is never inside a working tree |
| direnv, mise, asdf, as you `cd` in or run a tool there | `.envrc`, `.tool-versions`, `.mise.toml`, `mise.toml` | no name starting with `.`; `mise.toml`, `mise.*.toml` and `mise/config*.toml` refused by name |
| Zed, VS Code, opening the folder     | `.zed/`, `.vscode/`                         | no name starting with `.`                     |
| Your scripts globbing `*`            | a file named `--checkpoint-action=exec=…`   | no name starting with `-`                     |
| Your file manager, on a double-click | an executable file, a `.desktop` launcher   | no executable bit                             |
| Thumbnailers and indexers            | a file's contents                           | not covered, as with a download; GNOME's indexer reads the home folder's top level only, and `.trackerignore` keeps it out of `~/mwt-vm` |
| Your disk                            | the bytes                                   | 1 GiB and 20,000 entries in all               |

The rule against names starting with a dot keeps out almost everything a
tool acts on by location, `.` and `..` included; a list of known names is
always one short. Its cost: an output that must be named `.something`
comes under another name, and the command reading it renames it.

**A copy back** (`MWTClient.Sandbox.CopyBack`), so the VM chooses bytes and
names but never where MWT writes or what runs here:

1. The VM lists `from-vm/` (`find -printf`, as a shared folder's list,
   bounded), and MWT checks every entry before anything is written:
   regular files and folders only (a symlink, device, FIFO or socket is
   refused); each name valid UTF-8, with nothing that doesn't show and no
   control character, not starting with `.` or `-`, at most 255 bytes;
   at most 32 levels deep and 1024 bytes; 1 GiB and 20,000 entries in
   all. One entry breaking a rule lands nothing of that copy back, and
   `mwt sync` and the Overview name it and say why.
2. It compares the list with what it brought last (kept per VM in
   `…/sandbox/sync/copy-back.bin`) and with `from-vm/` here, read with
   `lstat`: a file comes again when the VM's changed, or when the one here
   isn't the one MWT wrote (you made it writable and changed it).
3. The VM's `tar` sends the changed files (`--format=gnu`) into a file
   here, under `ulimit -f` for what was asked. MWT reads it itself
   (`MWTClient.Sandbox.TarReader`): only file entries, each one asked for,
   once; anything else (a link, a pax header, a wrong checksum) stops it.
   No `tar -x` runs here on the VM's bytes. Each file goes into the
   staging folder (0700), opened exclusively, so never through a link, and
   is looked through for every token grant's real value as it is written,
   a value cut between two chunks included.
4. Then, with every folder of `from-vm/` writable for as long as it takes:
   what the VM hasn't is removed (a link removed as a link, never
   followed, a file of yours included), the folders it has are made, and
   each file is renamed into place, 0444. Folders go back to 0555. A
   program reading a file sees it whole, old or new; a set of files changes
   one file at a time. A file's time here is when it was written here.

A file holding a grant's real value lands nothing: the VM already holds
it, which no switch takes back, so the firewall hears it (*Real credential
in traffic*, Isolate by default) and the finding says to replace it.

**What `to-vm/` hands the VM:** a shared folder's rules (copied one way,
read-only there, a repository in it not copied). Unlike a shared folder,
each changed file is looked through as a command's output is
(`MWTClient.Sandbox.Inbound`), since a confined action holding a grant's
value writes its result there, which would otherwise skip what its output
goes through: a real value holds the file back, never sent; a credential's
shape does as the rule *Credential entering the VM* says (Block holds it,
Alert sends it and tells you). A held file stays out of the VM, what the
VM had of it staying, until it changes or you choose **Send it to the
VM** on the Overview, which sends it as it is then; each is in the log,
and the firewall hears of it.

**Commands and actions:** `MWT_WORKSPACE` in their environment, after
MWT's own variables are removed. Confined, `from-vm/` is bound read-only
and `to-vm/` writable, the one folder outside its own a confined command
may write to; its own folder's bind comes after. A command may run in
either half (`--dir`), as in a shared folder. A script naming
`MWT_WORKSPACE` or the folder gets a hint on its card: what it reads in
`from-vm/` the VM wrote, last copied here at the time it gives; what it
writes in `to-vm/`, the VM reads.

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

- **Encrypted, like other MWT data:** credentials, networks, grants,
  stored values, allowances, locks, VM settings and MWT's CA key, as the `sandbox`
  document of `library.db`; the
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
| `Policy`, `Gate`, `Attributes`, `Overlaps`                            | Through, ask or refuse: a grant on for each resource a use goes through; the network path's view; what a grant narrows by; grants that may cover one use |
| `Proposal`                                                            | A grant an agent proposes, as the add form's fields          |
| `Grant`, `Resource`, `Credential`, `Network`, `HostLimits`, `Param`, `SavedRequest`, `Allowance`, `Approval`, `Presets` | Records of access, of the resources it is to and their limits, and of what waits for you; grant types |
| `Adapter`, `Adapter.Bearer`, `Adapter.GitHub`, `Adapter.Google`       | What MWT knows of each family of credentials                 |
| `Transfer`, `Server.Transfers`                                        | The sandbox's section of an export                           |
| `Egress`, `Egress.*`, `Dns`, `Destinations`, `Routes`                 | The proxy; lookups; where an address may go                  |
| `Placeholder`, `Secrets`, `CertificateAuthority`, `Roots`             | Swapping values in; finding them; MWT's CA; the system roots |
| `CredentialEndpoint`, `Made`                                          | Credential endpoints MWT answers; the values it made there   |
| `Describe`, `GraphQL`, `RequestView`, `Chunked`, `Shown`, `Inbound`   | A request as facts; text the VM chose, made safe to show     |
| `Channel`, `Why`, `Explain`, `MwtTools`, `AgentThreads`               | The `mwt` socket; `mwt why`; `mwt mcp`; Zed's agent threads  |
| `HostCommand`, `HostRun`, `HostInfo`, `Confine`, `Bounded`            | Commands on this machine: checked, run, confined; `host.md`  |
| `Bubble`, `Seccomp`, `Sockets`, `Msb`, `VM`                           | The bubble, its filter and sockets; `msb`; the VM's record   |
| `Settings`, `Resources`, `MemoryControl`, `NestedVirt`, `Monitor`     | How the VM is built; CPUs and memory; nesting; the monitor   |
| `Disks`, `Snapshot`, `Image`, `Build`                                 | The disks and Home's copies; the image and its builds        |
| `Inbox`, `Instructions`, `FolderSync`, `Share`, `Shares`, `Memory`    | `/mnt/mwt`; agents' text; copies in; picks; the VM's OptMem  |
| `Workspace`, `CopyBack`, `TarReader`                                  | The workspace; its `from-vm/` copied out, and the archive read here |
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

**What MWT decides is as fine as what it reads.** A connection it reads is
broken into the requests it carries ([Drivers](#drivers)), and each one is
judged, logged and, where a grant asks, held for you on its own: the
finest control there is, since a request is what the agent does. What it
can't read it decides as a whole connection, by its address, port and TLS
name. So every protocol MWT learns to read moves its traffic from the
second kind to the first. Putting a real value into a request, and looking
for one in what goes out, are uses of that reading, not its reason.

Each lookup, connection and request is decided in its own process, from the
**view** the server publishes after every change, before it answers
(`MWTClient.Sandbox.Gate`: grants, [locks](#locks), the firewall's
settings and isolation, what the scanners look for, the CA), so a call
that turned a grant off returns once every new decision sees it off.
Only what waits for you or puts a real value in a request asks the
server, so a busy one makes
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
3. **Public addresses** are the Internet's: opened while its grant is on,
   held under it. A connection to an address MWT's DNS answered for a name
   the Internet's limits block, or a name a grant over one of its hosts
   names, waits for its first bytes to say which host it is for
   ([Host limits](#host-lists)). With the Internet's grant off, a network
   grant that is on and lists the address opens it, a grant over a host of
   the Internet included, waiting for your approval unless it
   auto-approves or an allowance covers it ([Approvals](#approvals)). A
   token grant's hosts are no exception: a request carrying a placeholder
   needs a grant over its network too ([The rule](#the-rule)). Anything
   else closes, logged as *The Internet is off*; MWT connects nowhere for
   it first, even for a server that speaks first.
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
7. A host **any token grant lists, on or off,** or its
   credential's adapter implies ([Adapters](#adapters)), is read
   ([Each intercepted request](#each-intercepted-request)), so a grant not
   on gives a clear answer instead of the provider's auth failure. A network
   grant's check of the TLS name ([Private networks](#private-networks))
   comes first, read or not.
8. **Every other connection to the Internet MWT can read, it reads**
   (`Gate.reading/3`, `MWTClient.Sandbox.Egress.Driver`), for you to see
   and decide each request that goes out: TLS whose ClientHello names a
   host and offers HTTP/1.1, HTTP/2 or no protocol at all, and plain HTTP,
   as *What MWT reads* says ([Not read](#not-read)). A client offering no
   protocol speaks what it speaks: MWT looks at its first bytes once TLS
   is ended, and what isn't HTTP (or a server that greets first, IMAP over
   TLS) goes on as it came, to the host over TLS MWT starts again, looked
   through as a tunnel is: decrypted, a placeholder or a real value in it
   is found. It is a connection MWT can't read, so it is decided as step 9
   says before anything is connected to: of the grants over its network
   that cover it, the most permissive counts, and one that asks asks about
   it ("not HTTP inside its TLS"); a host its network blocks is refused. A
   request after an
   empty line (which servers skip) is still HTTP's, and refused (`400`),
   never passed on as bytes.
9. Anything else is **tunnelled**, unread both ways; the log keeps its
   host, bytes and duration, and why it wasn't read ("Not read: the client
   offered imap, which MWT doesn't read"), and the firewall hears the bytes
   as they flow. A connection MWT can't read is decided as one, by the
   grants over its network that cover a name it may be for, and refused
   when its network blocks one of those names
   ([Private networks](#private-networks), [Host limits](#host-lists)).

<a id="drivers"></a>

**Drivers.** A driver turns one protocol's bytes into the requests they
carry, so that each is seen, judged and kept on its own: an HTTP request,
a database query. What MWT reads it reads through a driver, one per
protocol (`MWTClient.Sandbox.Egress.Driver`): `Driver.Http1` (HTTP/1.1,
inside TLS and as plain bytes, and the messages of a WebSocket it
upgrades to), `Driver.Http2` (HTTP/2 inside TLS, gRPC's), and
`Driver.Raw` for what no driver reads, which steps 8 and 9 call
tunnelled, and which is judged only as a connection. A driver
runs on a call, whatever carries it; the core carrying the call is the
same whatever the protocol. For TCP, the only transport msb carries but
DNS, that is `MWTClient.Sandbox.Egress.Tcp`: it holds the sockets, ends
TLS, connects only where steps 2 to 4 approved, judges, logs, and looks
through and counts every byte. A driver holds no socket: bytes come in, and it answers with
what to do (judge this request, send these bytes up, read the host, this
request ended). So a driver can't send anything anywhere else, nor skip
the look for real values and placeholders, nor the firewall's count.

- **Picking one**: the protocol settled in TLS picks the driver speaking
  it; otherwise each driver is shown the first bytes, decrypted when MWT
  ended TLS, and the first to claim them takes the connection (`Raw`
  claims anything, last). MWT offers inside TLS the protocols its drivers
  speak and picks the first, in the drivers' order, that the client
  offers too: HTTP/1.1 before HTTP/2, so only a client that offers no
  HTTP/1.1 (gRPC's) speaks HTTP/2 to MWT. One that can speak either is
  read request by request over HTTP/1.1 all the same, so HTTP/2 for it
  would add nothing seen or decided.
- **Each request**, whatever the protocol, is one shape
  (`MWTClient.Sandbox.Egress.Request`: where it goes, the grant it went
  under, what it does and to what), and its driver describes it for its
  card; so the judge, the cards, *Allow similar* and the log serve every
  protocol without a line for each.
- **A real value** goes in only as the judge says: it names each
  placeholder to replace and with what, in which places (an HTTP request's
  carriers), and, for the answer, each form of the value to send back to
  the VM as its placeholder; the driver does the replacing, in its
  protocol. Only HTTP (HTTP/1.1 inside TLS, HTTP/2) carries a value: a
  placeholder in another driver's request is a string out of place, and
  the connection's look stops it.
- **What the core looks through**: every byte a driver sends up as the
  VM's, a stream of text at a time. A driver that frames the VM's text
  (HTTP/2's streams, a WebSocket's frames) sends each stream's text apart
  (`{:send, :host, bytes, stream}`), looked through with that request's
  own list, and its framing as its own (`{:frame, :host, bytes}`), so
  frame headers or other streams between two pieces never hide a value
  split across them. HTTP/2's headers go up written again without Huffman
  coding, and a WebSocket's frames masked with zeros, so what goes up *is*
  the text looked through. A request a driver refuses is looked through
  for real values all the same (`{:look, bytes}`): the firewall hears of
  one as if it had gone.
- **Plain bytes**: plain HTTP is read (`Driver.Http1`), each request
  judged and logged as one inside TLS is. Nothing proves which host is
  there: the host is the one its `Host` names, the client's word, so its
  card says the address it goes to, *Allow similar* for it covers that
  address only, its network's limits and the grants over some of its hosts
  go by its name and those MWT's DNS answered for the address, and no
  placeholder goes in it (`403` `mwt_plain_http`). What else comes as
  plain bytes is tunnelled.
- **UDP**: a core for it would sit beside `Tcp` and run the same drivers,
  each told which transport it is on (`ctx.transport`). None is built,
  since msb carries no UDP but DNS.
- **A first draft**: the interface was written for HTTP/1.1 and bytes
  passed on, over TCP. A protocol that doesn't fit it changes it,
  proposed with its driver, keeping the core's guarantees whole. The
  module's docs say what each callback is for, and where the interface is
  known not to fit yet: a switch mid-call to another driver (STARTTLS),
  refusals in HTTP's terms, values put only into HTTP, datagrams.

<a id="not-read"></a>

**Not read.** Reading a connection means the client sees a certificate
from MWT's CA, which the VM trusts: the system's bundle, the usual CA
variables (`AWS_CA_BUNDLE` and `DENO_CERT` among them), a Java truststore
([The image](#the-image)), Chromium's own store (the boot script). A client that
trusts something else (a CA of its own, as a kubeconfig's
`certificate-authority-data`; a pinned certificate) refuses it, and nothing
goes out: its line in the activity log is *Cert refused* (`read_failed`),
with why, as far as TLS said.

**What MWT reads** is yours to set, in a dialog the activity log's header
opens (`MWTClient.Sandbox.Reading`, saved with the sandbox): set now and
then, it takes no room on the page the rest of the time.

- **Hosts on neither list**: *Read* (every host it can, at first) or *Not
  read*, as before 2026-11-22, should reading get in the way. The header's
  button says *others not read* while they aren't.
- **Two lists, *Read* and *Not read***, each host on one at most, whatever
  any other host does: `example.com` covers it and every name under it,
  and the entry naming a host most exactly decides, so `api.example.com`
  under Read with `example.com` under Not read reads that one host of the
  domain. Added to a list in the dialog (adding it to one takes it off the
  other, as its arrow does), or in a click: each busiest destination shows
  *read* or *not read* and switches it, and an opened line offers **Don't
  read HOST** or **Read HOST** (a failed one first among them).
- **Only you set it**, from MWT's pages: a failed handshake never adds a
  host, or the VM could choose what goes unread by failing one. A token
  grant's hosts are read whatever it says, for their value to go in, and
  what MWT can't read (no host name, HTTP/2 only, not TLS) passes whatever
  it says.

<a id="what-reading-costs"></a>

**What reading costs**, measured on 2026-11-22
(`test/bench/proxy_reading_bench_test.exs`, run with `mix test
test/bench/proxy_reading_bench_test.exs --only bench`): the same client
and HTTPS server through the proxy's own code, its decisions and its log,
a host read against one passed through, on this VM's 21 schedulers with
client, server and MWT in one BEAM. Not in it: microsandbox and the relay,
the same both ways, and a real host's round trips, which a new connection
pays once more when read (MWT starts its own TLS with the host).

| | Read | Passed through |
| - | -: | -: |
| A request on a kept connection, median (p99) | 0.41 ms (0.9) | 0.12 ms (0.25) |
| A request on a connection of its own, median (p99) | 4.6 ms (8) | 2.8 ms (5) |
| 32 clients at once, kept connections | 12,000 requests/s, p99 13 ms | 65,000 requests/s, p99 1 ms |
| CPU a request, every scheduler, kept connection | 0.5 ms | 0.1 ms |
| Download, upload | 540, 390 MB/s | 700, 530 MB/s |
| A streamed answer's chunk, added delay | 0.6 ms | 0.5 ms |
| A host's first certificate | 0.1 ms | |
| Log on disk a request (1 KiB answers) | 1.4 KB | |

So reading adds about 0.3 ms to a request on a kept connection and 1.9 ms
to a new one, and the most it serves is a hundred times what an agent
makes at its busiest (a package install: hundreds a second). The bound is
the log: the sandbox server writes each read request's line and exchange,
two messages, one process, at about 14,000 a second, so past some 7,000
read requests a second it falls behind (half a second behind after the
32 clients' burst), and an approval waits behind what it hasn't written.
The test fails when reading gets several times slower than this.

**MWT connects only where it approved** (`MWTClient.Sandbox.Egress.Tcp`),
for a tunnel and a read request alike: to the address and port in the
CONNECT, which steps 2 to 4 judged, through the grant's way out. Never to a
name resolved again here, which could lead elsewhere, a private address
included.

A connection a grant let through (a tunnel a network grant opened, a
request carrying a token grant's value, the session it upgrades to) is held
under it (`MWTClient.Sandbox.Connections`), and closes when the grant is
turned off, removed or out of time, or what it reaches is locked
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
- **REFUSED, never leaving this machine**: with the Internet's grant off,
  every name no network grant that is on lists, a token grant's host
  included, so lookups can't carry data out either; a name a grant over a
  private network lists while none listing it is on: it is a name of that
  network, not sent to the Internet's resolver, and the log names the
  grant to ask for (`Gate.lookup/2`, [Private networks](#private-networks));
  every name while the VM is isolated or there is no view. A grant over
  one of the Internet's hosts that is on lists its name, answered while
  the Internet's grant is off as any listed name is; off, it holds no name
  back.

<a id="private-networks"></a>

### Private networks

A network grant opens destinations of its network: addresses, ranges and
names, each with its ports ([Networks](#networks)). Its names lead only where MWT's own
DNS said (`Dns`, `Gate`, `MWTClient.Sandbox.Routes`): a connection there
may carry what MWT doesn't read (a database's password, SSH), and a dropped
VPN would leave the grant's ranges to whatever LAN this machine is on,
often one using the same ranges.

**What goes through it is asked as MWT can show it.** For a service on a
private network, often production, a card saying "Connect to 10.x.y.z:443"
says nothing of what is done there. So a network grant's connection is
read when MWT can, as an Internet one is ([Each connection](#each-connection)):

- **Read, each request is a card of its own** under the grant, in full, as
  a token grant's request is (method, URL, headers, body, the client),
  with the grant's approval mode and *Allow similar* (the same method and
  endpoint) for the repeats; no card for the connection. Every grant over
  the network that is on and covers its host can let it through, the most
  permissive counting, and the network's limits can refuse it
  ([Host limits](#host-lists)); a request carrying a credential also needs
  a grant over that credential, one decision for both, with one card
  naming every grant that asks ([The rule](#the-rule)). Each one is in the
  log, read, with what it carried and what came back.
- **Not read, the connection is the card**, asked only once its first
  bytes have come, so it says what MWT saw: the name the client asked for
  (its TLS name), the names MWT's DNS answered for the address, and why
  MWT can't show more ("it isn't TLS": a database, SSH; "on your list of
  hosts MWT doesn't read"; "the server speaks first"). Nothing is
  connected to before you decide: a client that stays quiet (a server
  that greets first, MySQL) is asked about by its silence.
- **The entry that says it most exactly holds the connection**, of the
  grants that are on and open the same address: an exact address or name,
  then the longest name under a wildcard, then the narrowest range, one
  naming ports before one that doesn't; on a tie, the grant that lets it
  through (`Policy`'s `opening`). It is the grant whose end closes the
  connection. A grant that is off opens nothing and refuses nothing. Each
  request the connection carries is then decided by every grant over its
  network that covers its host, the most permissive counting
  ([The rule](#the-rule)); a connection MWT can't read, by the grant
  holding it and every grant over part of the network naming a name it
  may be for. Its network, locked, refuses (`mwt_locked`).
- **A host whose certificate this machine's roots don't vouch for** (an
  internal CA your machine doesn't trust) can't be read: MWT starts TLS
  with the host itself and checks it. Its line is *Not read*, the agent
  gets `502` `mwt_upstream_tls` saying so, and **Don't read HOST** (Proxy
  activity) passes
  it through as bytes, judged by the VM's client.

- **A destination may be a name, or every name under one**:
  `db.corp.example:5432`, `*.corp.example:443` (the name and every name
  under it, as a token grant's hosts).
- **Names are bound by MWT's own DNS answers.** A name a network grant
  lists is answered only while a grant listing it is on, the Internet's
  on or not; otherwise it is refused and logged ("Not looked up: Corp is
  off"). The
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
- **Its own DNS server**, the network's (`resolver`, copied to each grant
  over it as `Grant.resolver`; `10.8.0.1` or `10.8.0.1:5353`), is asked its
  names instead of this machine's resolver.
- **A way out**, the network's (`anchor`, copied as `Grant.anchor`; `wg0`,
  `tun0`, `utun4`): the interface its addresses are reached through. MWT asks the system which interface routes
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

<a id="host-lists"></a>

### Host limits

Some hosts of a network the agent must never reach, whatever any grant
says: a paste site on the Internet, one production host on a VPN whose
other hosts are fine. That is a limit of the network's, not a grant
(`MWTClient.Sandbox.HostLimits`), set on the network's page as *What MWT
reads* is ([Not read](#not-read)):

- **Hosts on neither list**: *Reachable* (the default) or *Blocked*.
  Reachable with a few blocked is a block list; blocked with a few
  reachable is the only hosts the VM may ever reach there.
- **Two lists, *Reachable* and *Blocked***, each host on one at most: an
  entry `example.com` covers that name and every name under it
  (`*.example.com` the same), and the entry naming a host most exactly
  decides, so `api.example.com` under Reachable with `example.com` under
  Blocked leaves that one host of the domain reachable.
- **A blocked host is refused** through that network, `403`
  `mwt_host_blocked`, saying you set it so, whatever any grant says; a
  connection MWT can't read is closed. Logged as blocked. Agents can't ask
  for it to change.
- **A limit only takes away.** A host it leaves reachable still needs a
  grant over the network that is on and covers it ([The rule](#the-rule)).
- **Only you set it**, from MWT's pages, as *What MWT reads*.

Which hosts go unasked is the grants' job. A grant over part of a
network, one host of the Internet say (its *Request targets*, added from
*Add grant* over the network or from the Internet's grant page), gives
uses of that host beside the grant over all of it, and within one network the most permissive grant
counts: with the Internet's grant asking, a grant over `api.example.com`
that auto-approves lets that host through unasked.

**A grant leaves hosts out** with *Except these hosts*
(`Grant.except`, `Network.excepted/2`): it covers its part of the
network but those, so it has no say about them, and another grant over
them decides, on its own terms. This is how one host always asks while
the Internet's grant lets everything else through: list the host under
the Internet's *Except these hosts* (its page's Settings, the one field
of it you change), and add a grant over the host, its *Request targets*,
that asks. Grants still only give: with the grant over the host off or
ended, the host is refused, never let through by the Internet's.

- **Hosts by name**, as *What MWT reads* and host limits write them:
  `example.com` covers it and every name under it; an address can't be
  one (`Network.except_entries/1`, at most 200).
- **Every grant over a network may**, the Internet's and yours, set
  with the rest of its form. Over part of a network, it leaves out of
  that part (`*.corp.example` but `secret.corp.example`).
- **Where it holds:** a request, by its host
  (`{:refuse, {:excepted, grant, entry}}`, `mwt_not_covered`, naming the
  grant and the entry); a lookup of a name left out that no grant that is
  on names is never sent (`Gate.lookup/2`); a connection to an address
  MWT's DNS answered for a name left out waits for its first bytes, and
  one MWT can't read is judged by every name it may be for, as limits
  judge one. The same gap as limits: an address learned elsewhere and
  reached over what MWT can't read isn't recognised as the host.
- **Agents read it** in `mwt grants` (the hosts a grant leaves out, and
  that only a grant naming them gives them), and `mwt why HOST` says
  which grant leaves it out and whether another gives it.

- **A host is a name** as clients ask for it, never an address, the same
  form as *What MWT reads* (`MWTClient.Sandbox.HostRules.entry/1`).
- **A read request** is judged by its host: inside TLS, the name its
  certificate proved; over plain HTTP, its `Host` and the names MWT's DNS
  answered for its address, so no name chosen for the purpose gets it
  past a block.
- **A connection MWT can't read** is judged by every name it may be for:
  the TLS name it asked for and the names MWT's DNS answered for its
  address. One of them blocked, it is refused.
- **Held until its first bytes:** a connection to an address MWT's DNS
  answered for a name its network may block, or a grant over part of the
  network names, waits for its first bytes before anything is connected
  to (`Policy.remembers?/4`): read, each request is decided as above; not
  read, the connection is. So a server that greets first is judged by its
  silence, and an address many names share opens for the others.
- **Agents hear it**: `mwt why HOST` says when a network blocks it, and
  that asking for a grant won't change it.
- **From grants saved before** (`Network.migrate/2`, as MWT starts): a
  host list's Block and Ask entries become the network's Blocked list, so
  nothing that waited for you goes unasked; its Auto entries become grants
  over those hosts, auto-approving. A grant over part of a network that
  was off as a block, or always asked, becomes a Blocked entry too.

What it doesn't hold: an address the agent learned elsewhere (not from
MWT's DNS), reached with no name or another name, over what MWT can't read
(not TLS it ends, not plain HTTP), isn't recognised as the host it is: a
limit names hosts, not their addresses. Read connections have no such gap:
TLS MWT ends is verified for the name it asked for.

<a id="each-intercepted-request"></a>

### Each intercepted request

1. **Finish the TLS handshake** with a certificate MWT's CA makes for that
   host name, offering HTTP/1.1 and HTTP/2, HTTP/1.1 first: a client that
   offers only HTTP/2 (gRPC's) speaks it, each of its streams a request
   read as these steps say (`Driver.Http2`), its headers as an HTTP/1.1
   head's (`MWTClient.Sandbox.Egress.RequestHead`, the rules both share), a
   value going only in a carrier, its answer read back the same way. Its
   `:authority` is its `Host`: a `host` header besides it, unless one
   saying the same, is refused, and so is a `content-length` its DATA
   doesn't add up to. A header block holds at most 64 KiB decoded, as MWT
   announces (`SETTINGS_MAX_HEADER_LIST_SIZE`, `431` past it), and either
   peer sending past the windows MWT gave it (1 MiB a stream, 2 MiB a
   connection) ends the connection (`FLOW_CONTROL_ERROR`): MWT holds no
   more than that of one side's bytes for the other. A client that gives
   up (a CA of its own, a pinned certificate) is logged under the host
   with why, as far as TLS said: nothing went out, and the next try fails
   the same way.
2. **Read the request head, strictly.** MWT judges a request by what it
   read, and the host must act on the same thing, so a request two parsers
   could read two ways is refused (`400`, `mwt_bad_request`):
    - the target a path, not a full URL, in visible ASCII as HTTP says
      (anything else arrives percent-encoded or not at all);
    - exactly one `Host`, the TLS host name, with the connection's port or
      none (`421` otherwise): a mismatch would let a request say "github"
      to MWT while going somewhere else. A port other than 443 is part of
      the host on its card and its pattern
      ([Describing requests](#describing-requests));
    - one numeric `Content-Length` or `Transfer-Encoding: chunked`, never
      both;
    - every header line `name: value`, a name of token characters only, no
      folded lines, no space before the colon; a value of visible bytes,
      spaces and tabs, only those around it dropped, no other control
      character, no bare CR or LF;
    - lines ending in CR LF, a head of at most 64 KiB (`431`), and no
      empty line before the request line: a host skips one (RFC 9112),
      so what follows is a request MWT must read, not bytes;
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
    - A [credential](#credentials)'s placeholder (its own, or one it had
      before a merge) to a host no grant over it lists, nor its adapter
      implies, in a header, the target or the body (as it streams too):
      blocked (`403`, `mwt_placeholder_blocked`) and recorded as a
      violation ([Rules](#rules): *Credential sent elsewhere*).
    - Only a header gets a value. One in a header that isn't one of the
      grant's carriers is refused (`403`, `mwt_not_a_carrier`, naming the
      header and the carriers); one in the target or the body of a host a
      grant over it lists goes on as it is. A request carries one
      credential's placeholder at most (`403`, `mwt_multiple_grants`).
    - A value made from a grant's ([Credential endpoints MWT
      answers](#credential-endpoints-answered)) is a use of that grant,
      with hosts and carriers of its own: its placeholder elsewhere is
      blocked as a grant's is; one MWT no longer holds (expired, from
      before MWT started, or no longer covered by its grant) is refused,
      `403` `mwt_placeholder_expired`, never sent as it is.
    - A login's placeholder, in its credential's login file, belongs only
      in the body of a refresh at Google's token endpoint, which MWT
      answers with no card ([Credential endpoints MWT
      answers](#credential-endpoints-answered)); anywhere else it is
      blocked as any placeholder moved where it doesn't go.
    - A request to a credential endpoint the grant takes is checked here
      and, let through, answered by MWT itself, never forwarded.
5. **No placeholder**: the network the connection went under decides
   alone, its grants covering the host, the most permissive counting
   ([The rule](#the-rule)); let through, it goes unchanged, the rest of
   the body still looked through for real values
   ([What comes back](#what-comes-back)).
6. **Refused before anyone is asked**: the credential, or the network the
   connection went under, locked, `403` `mwt_locked` ([Locks](#locks));
   its host blocked by that network, `403` `mwt_host_blocked`
   ([Host limits](#host-lists)); no grant over the credential listing the
   host covers the request (none whose [attributes](#attributes) match),
   `403` `mwt_not_covered`; no grant that covers it on, over the
   credential or over the network, `403` with
   `{"code": "mwt_grant_off", "grant": "...", "error": "... mwt request <id> ..."}`,
   naming a grant that would.
   Each refusal also names the decision as made, kept with its event
   (`"decision": "event-…"`, `"why": "mwt why event-…"`,
   [Finding out why](#finding-out-why)).
7. **One decision for both resources**: the request is described
   ([Describing requests](#describing-requests)); of the grants over the
   credential that cover it the most permissive counts, and so of the
   grants over the network covering its host. It goes unasked only if
   both let it through unasked ([The rule](#the-rule)); otherwise an ask
   holds it, on one card naming every grant that asks.
    - **Ask** holds the request: MWT reads the head and the body, all of
      it or its first 64 KiB, before making the card, then reads at most
      64 KiB more until you decide, kept to go behind it: past that, TCP
      flow control makes the client wait, so a large upload is not
      buffered. A client that gives up meanwhile (its own timeout) ends its
      request: what you then decide sends it only for a client still
      there, a retry that joined the card. A body that hasn't come within
      10 seconds is refused (`408`): a card never says *No body* for one
      that was only late. One holding the start of a body says so among
      its facts.
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
8. **On allow**: get the credential's value (minting it if needed, once
   for every grant over it), put it in the carrier, ask for an answer
   without content encoding
   (`Accept-Encoding: identity`), and connect to the address and port the
   VM asked for, through the grant's way out, starting TLS again with the
   host name and verifying its certificate against this machine's roots.
   The address is the VM's choice, judged as any connection's, and the
   certificate is what makes it the host: a forged `/etc/hosts` entry can
   send the value only to a server that proves it is that name.
9. **Read the response back** as HTTP, letting none of the real value
   through ([What comes back](#what-comes-back)).

Each request is judged on its own, as it comes. MWT sends the head it
wrote itself, and nothing past the body's end goes with it: its
`Content-Length`, or its last chunk and trailers
(`MWTClient.Sandbox.Egress.Driver.Http1.Framing`). Bytes after it are the next
request, which MWT reads and judges in turn, or, after a request alone on
its connection, none at all.

- **A request carrying a real value goes alone**, on a connection of its
  own with `Connection: close`, and the VM's connection ends after its
  answer. The real value is written once, into that head; the rest of the
  body goes on as bytes MWT never wrote a value into.
- **A request with nothing to judge alone** (no real value, no `Upgrade`,
  from a client that keeps its own connection: HTTP/1.1 without
  `Connection: close`) **shares a kept connection**: the one to the same
  address the request before used, when the host kept it. Its answer is
  read only to know where it ends (`MWTClient.Sandbox.Egress.Driver.Http1.Answer`): an
  answer whose end only its close tells, or that says `Connection: close`,
  ends the kept connection, and the next request goes on a new one. So
  reading a host costs a TLS handshake a connection, not a request: 200
  requests in a row through the proxy took 4.6 ms each with a connection
  apiece, 0.27 ms on one kept connection (a local host, so no round
  trips; a real one adds its own to the first figure).
- **A grant's time running out** while a kept connection waits is looked
  at before its next request, which goes only if the grant still is on;
  turning a grant off closes the connections it let through, as always.
- **A kept connection the host closed as a request went on it**, before
  any of the answer came, is what any client meets with its own: the
  request goes again on a new connection, once, when doing it twice
  changes nothing (`GET`, `HEAD`, `OPTIONS`, `PUT`, `DELETE`, with its
  whole body held). Any other gets `502`, saying the host closed the
  connection without answering, for the client to decide.
- **Idle**, the VM's connection waits 30 seconds for its next request,
  then closes.
`Upgrade` (WebSockets): the handshake goes through these steps. Then a
WebSocket with no value in it is read message by message
(`Driver.Http1.WebSocket`): MWT takes the client's extensions offer out of
the handshake, so no message comes compressed; it sends the VM's frames up
masked with zeros, so what MWT looks through is their text, a value split
across two frames included; and the log keeps each side's messages, one a
line, up to the body limit. One with a value in it, and any other
protocol, is tunnelled, still looked through as below. What the VM sends
after a request asking to switch protocols waits for the host's answer:
only a `101` switches, and what waited goes up as the new protocol's; any
other answer makes it an ordinary request, its answer read to its end, and
what waited the next request, judged as any. HTTP leaves the switch to the
host, and a host that ignores `Upgrade` keeps reading requests: passed on
before the answer, they would be requests no card showed.

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
  to the close; HTTP/2's DATA), gzip and deflate decoded for the look only
  (`MWTClient.Sandbox.Egress.AnswerBody`, for both HTTP versions), so a
  value split by chunks or compressed is still found. Found, the connection is
  cut before any byte of the value goes: the answer stops short, the log
  says why, and the firewall hears of it ([Rules](#rules)). Replacing it
  would change the body's length, and an answer that copies credentials
  isn't worth keeping.
- Bytes are held back only while the last of them could start the value,
  50 ms at most, and go before a head that follows them (gRPC's
  trailers). A stream that pauses mid-value lets that start through;
  what would complete it never follows.
- **What MWT can't read is refused, not passed on**: a head over 64 KiB,
  framing that doesn't parse, an encoding other than gzip or deflate (MWT
  asked for none), gRPC messages compressed (MWT drops the request's
  `grpc-accept-encoding`). `502` `mwt_unreadable_response` while nothing
  has gone to the VM; cut after (over HTTP/2, that stream reset).
- Once the final response is whole, the connection ends; after
  `101 Switching Protocols` the bytes are looked through the same way. A
  request MWT put no value in comes back untouched.

The other way, the rest of the request body is looked through for every
grant's real value as it streams (`MWTClient.Sandbox.Egress.Scanner`):
found, the connection is cut before the chunk carrying it goes.

<a id="exchanges"></a>

### What the log keeps of a request

Each request MWT reads (a token grant's host's, and since 2026-11-22 every
Internet host's it can, [Each connection](#each-connection)) keeps what it
carried and what came back
(`MWTClient.Sandbox.Exchange`), so an agent's failing call can be read in
MWT: the activity log shows both side by side when its line opens. A
request that went out as the VM sent it, with no credential in it, is
*Read*; a tunnel, *Not read*, keeps nothing (TLS MWT never opened), and its
line says so.

- **The request as the VM sent it**: method, path, headers and its body,
  what MWT read before deciding and what the VM sent after it,
  placeholders as the VM wrote them, copied before the swap, so the real
  value is never kept.
- **The response as it reached the VM**, scrubbed as above: status, reason,
  headers, and the body with chunked framing and gzip or deflate undone. A
  refusal, a denial or an unreadable answer is MWT's own JSON, marked as
  from MWT; a cut says why.
- **At most your setting of each body** (Settings, *What the log keeps*:
  64 KiB at first, 0 for heads only, 1 MiB at most, since a connection
  holds it in memory until its exchange ends), inflating no more however
  small the compressed body; a cut one says how long its headers said it
  was. A body that isn't text is kept as bytes; one in an encoding MWT
  doesn't decode (`br`) isn't kept. Every request MWT reads is kept, and
  a package install makes hundreds, most of them packages already
  compressed: about 40 MB of log for a fresh `npm install` of a mid-size
  project at 64 KiB, by estimate. How long the log is kept is its
  retention rule's (*Agent activity*, Storage page). A card still shows
  what MWT read before deciding, at most 64 KiB, whatever the setting.
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
same method, host (with its port, when it isn't 443) and path (not the
query) through the same header; for GraphQL, the same document. A request
MWT couldn't describe (a GraphQL document it can't read, or holds only the
start of) is similar to nothing, and its card has no *Allow similar*:
once, or every use, still.

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
| A proxy answer                  | [What comes back](#what-comes-back) (`Egress.Driver.Http1.Response`): a real value in it cuts the connection  |
| A command's output              | Looked through. A real value holds it for you; a shape holds it when the firewall rule blocks    |
| A request action's answer       | Through MWT's proxy: the connection is cut where one of the values it sent comes back, as for the VM's own requests; then every other grant's value written out as `[NAME's token]`, in every form; a shape holds it as above |
| A result of MWT's tools         | Every grant's value written out. Shapes aren't looked for: your notes are yours                  |
| MWT's own files in `/mnt/mwt`   | Nothing: MWT wrote them, and none holds a real value                                             |
| Shared folders                  | Not looked through (see [Later](#later))                                                         |
| The workspace's `to-vm/`        | Each changed file, as a command's output. Held, it stays out of the VM until you send it from the Overview ([The workspace](#the-workspace)) |

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

You keep a list of what the VM could use, the resources (the token
"GitHub personal", the prod VPN, your machine), and grants give it uses
of them. A grant is one piece of access you turn on and off, for a time or
until turned off, with your own words for what it is for, which agents
read (`mwt grants`) to find the one they need. Each grant mediates
exactly one resource the VM reaches through MWT: a
[credential](#credentials), a [network](#networks), your machine, or
MWT's tools. It is on or off, and off has no say ([On and off](#states)).
Grants only give: with no grant on, nothing goes, and a use needs, for
every resource it goes through, a grant that is on and covers it
([The rule](#the-rule)). Resources limit: each has a lock, for when
something went wrong, yours or the isolation's ([Locks](#locks)), and a
network has host limits, hosts it blocks whatever any grant says
([Host limits](#host-lists)). Changing a grant's state, allowances or
value never restarts the VM.

This is the design of 2026-11-24
(`docs/dated/20261124-grants_redesign.md`), with its second pass, *grants
give, resources limit*; what it leaves for later is said where it matters
and in [Later](#later).

<a id="grant-kinds"></a>

<a id="open-use-and-fixed-calls"></a>

### Open use and fixed calls

The model behind this section is in
[grant_mental_model.md](grant_mental_model.md). A grant's kind
(`Grant.kind_of/1`) says who builds what it lets through, the agent or
MWT; where that goes is its channel's: a network, host commands (code
run on your machine), or MWT's tools. Every grant says its kind, on its
row, its page and the cards about it; *Runs on host* is said only where
a command runs there (`Grant.host_command?/1`): beside a saved command's
script, on Commands agents write, and on a credential's mint command.

- **Open use** (a token grant over a credential, a network grant over a
  network, Commands agents write over host commands): the agent builds
  it. Its own tools in the VM (`mwt exec CREDENTIAL -- gh pr create …`,
  `git push`, `curl`) hold a placeholder, and each request leaves the VM
  carrying it; MWT's proxy decides it by what it reads there (the host
  and port, the method and path, what the credential's adapter reads,
  Ask or Auto, the locks) and swaps the real value in on the way out. A
  command it writes (`mwt run`) runs on your machine, as you, after you
  read it: no setting lets one through unasked, and none gets a
  credential's value. The agent's own use through two resources (its
  request carrying a token, over the Internet) needs an open grant over
  each.
- **Fixed call** (an action: a request action over a credential, a saved
  command over host commands, MWT's own tools): you write it, once (or an
  agent proposes it and you accept it), and the agent only fills in
  values (`mwt call pr-view REPO=oliveigah/klife PR=12`). MWT checks each
  value (its floor, then the schema), builds the request or the command
  from yours, and sends it the way the agent's own would go: a request
  through the same proxy (`MWTClient.Sandbox.Egress.FixedCall`), a
  command through the same runner. It covers the credentials it names in
  what it builds, and nothing else: no fixed call ever lets its credential
  into anything the agent built. A request goes out as the agent's own
  would: a network grant over its host has to let it out
  (`Policy.reach/3`), and one that asks makes the call ask; a grant whose
  requests none lets out says so on its page. A saved command needs only
  itself, host commands unlocked (Commands agents write always asks, so
  requiring it would make every saved command ask). Locks and a network's
  blocked hosts refuse either.
- **Never recognised from what the agent sent.** A fixed call answers
  only `mwt call ID`: MWT never infers that a request or a command the
  agent built could have been one. Agents look for one first in `mwt
  grants`.
- **Only as narrow as its template.** A template can be open use in
  disguise (`kubectl $ARGS`), so MWT grades each fixed call
  (`MWTClient.Sandbox.Openness`): *Narrow*, each value only picks among
  what the template names; *Wide*, a value reaches anything of a kind;
  *Open*, a value can become code or a command (the command run, `eval`,
  `bash -c`, `ssh`, `kubectl exec`, text read bare, a query the service
  runs, the whole body). The grade shows on its page, on every card it
  raises and in `mwt grants`; with the files a command runs, which can
  change after it was saved (see [Pinned files](#pinned-files)). It only
  warns: it never lets anything through and never makes a call ask; the
  token's own scopes are the other lever.
- **Both over one credential**, side by side: "klife only" (open use,
  asking) and "pr view" (fixed call, auto-approved) over one GitHub App.
  The open one is a grant of its own: turning it off leaves "pr view"
  working. Turning the Internet's grant off stops both, as it would any
  request the agent sends there, until a grant over api.github.com lets
  them out; locking either stops "pr view".

### Grant kinds

You add grants of three generic types, none tied to a provider, each
over one resource: token (over a credential), network (over a network)
and command, a saved command (over your machine). A request action, one
fixed request MWT sends with a credential's value, is a fourth kind, over
its credential, and MWT's own built-in tools a fifth. Agents may propose
any of the first four, and the credentials and networks they are over;
what they propose waits for you to review
([Proposed resources and grants](#proposed-grants)). The table's last column is what
happens when a grant stops being on.

| Type      | What the VM gets                                                              | Approval                             | Turning it off                                                                                                                         |
| --------- | ----------------------------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| `token`   | A placeholder, only for a command run with `mwt exec`                         | Per request                          | Takes effect on the next request; one still open (an upload, an upgraded WebSocket) is cut. Complete, since the VM never had the value. |
| `network` | Reachability to its network's hosts, ranges and ports, all of them or some ([Networks](#networks)) | Per request read; else connection    | New connections refused, open ones closed                                                                                              |
| `command` | Nothing: agents call your script on your machine by id ([Grants and actions](#grants-and-actions)) | Per run; may auto-approve | New asks refused, and runs waiting for you. A command already running goes on until it ends or you stop it.                              |
| `request` | Nothing: an action over a credential ([Request actions](#request-actions))     | Per call; may auto-approve           | New calls refused, and calls waiting for you; one whose value is being minted sends nothing                                            |
| `mwt`     | Nothing: MWT carries out each call itself                                     | Per use; may auto-approve            | The next call is refused, naming the grant and how to ask for it                                                                       |

Expiry and removal end a grant the same way, at once
(`Server.Grants.close_ended/1`), and so does a lock on what it reaches.

**Built in**, for every identity: **the Internet's grant** (`internet`),
below, over the Internet; MWT's tools, `mwt-read`, `mwt-create`,
`mwt-change`, over MWT's tools ([MWT's tools](#mwt-tools-in-the-vm));
and over your machine, the projects' Git, `git-fetch`,
`git-fetch-remote`, `git-handoff` ([Git grants](#git-grants)), syncing
the shared folders, `share-sync` ([Shared folders](#shared-folders)), and
the workspace's copy onto this machine, `workspace`
([The workspace](#the-workspace)); the last eight `kind: :mwt`. They are
never removed, hold no value, keep MWT's words and have no *Edit*. They
can be turned off: their switch, duration, approval mode and start
setting work as any grant's, but Commands agents write's, which always
asks ([Commands agents write](#ask-to-run-commands)).

**The Internet's grant** is a network grant over all of the Internet,
every public address; private and reserved addresses are never its. It
is on and auto-approving on startup unless you choose otherwise, and
never asks about an address alone, which is all a card could show: set
to ask each time, it asks about each request MWT reads, and a connection
it can't read by the names it may be for. The Internet's host limits
block hosts whatever any grant says, and grants over some of its hosts
give those hosts beside it ([Host limits](#host-lists)). Off, it gives
nothing: the VM reaches only the destinations of network grants that are
on, public ones included (a grant over one host of the Internet among
them), and DNS answers only names those grants list ([DNS](#dns)). A
token grant's hosts are no exception: a request carrying a placeholder
needs a grant over its network too ([The rule](#the-rule)). In this
document *the Internet off* means its grant off. Turning it off, its
time running out, locking the Internet or an isolation closes every
connection it let through; releasing changes no grant, so it is on again
if it was. Agents reach their model's API over the internet: with it off
they stop, unless a network grant lists it (`api.anthropic.com:443`).

A token grant is over one [credential](#credentials), which holds the
value, and names:

- the **hosts** its value may go to, beside those the credential's
  adapter implies for its own endpoints ([Adapters](#adapters));
- its **carriers**, the headers the value travels in: `Authorization`
  unless you name others (`X-Api-Key`), Basic credentials included. A
  placeholder in any other header is refused (`mwt_not_a_carrier`): a
  header the service copies into its answer would hand the value back;
- **only these uses**, the [attributes](#attributes) it narrows by (a
  method, a path, a GitHub repository), and *Covers requests MWT can't
  read*;
- the **service accounts** MWT signs JWTs as for it, answering Google's
  `signJwt` itself ([Credential endpoints MWT
  answers](#credential-endpoints-answered)).

Reaching its hosts is not its to give: the agent's request carrying its
placeholder also needs a grant over the network the host is on, usually
the Internet's ([The rule](#the-rule)). A fixed call over the credential
needs no token grant, it covers the credential in its own request; its
request still needs the network's grant, as the agent's would.

Its credential holds the rest, the same for every grant over it:

- **variables** holding the placeholder (`GH_TOKEN`), and variables naming
  the **token file**, `/mnt/mwt/tokens/<credential>`, always there
  (`CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`);
- whether **git** over HTTPS gets it, from MWT's credential helper, for
  its grants' exact hosts (not their `*.` entries);
- how the placeholder **starts** (`ghp_`, `sk-`), for clients that check;
- where its real value comes from, and its presentations, below.

**`mwt exec CREDENTIAL -- COMMAND [ARG...]`** is the only way a
placeholder reaches a command (`mwt exec github -- gh api user`,
`mwt exec github -- git push`). It chooses which credential a command
speaks as, and decides nothing: the grants over that credential decide
each request the command sends, at the proxy, by where it goes, as
`aws-vault exec PROFILE -- COMMAND` hands a command a profile and AWS
decides what it may do.

- It runs here in the VM, with exact arguments, stdin and exit status. It
  loads `/mnt/mwt/grant-env/<credential>.sh`, which MWT rewrites when a
  grant over the credential changes: while one is on, the placeholder in
  its variables, the token file in its file variables, and what its
  adapter adds (`GOOGLE_CLOUD_PROJECT`); with none on, a refusal naming
  the grants to ask for; with the credential locked, a refusal saying you
  locked it.
- It names a credential, never a grant: every grant over one shares its
  placeholder. A grant's own id, when it isn't its credential's, loads a
  script that says to run `mwt exec CREDENTIAL` instead.
- When it doesn't run the command (no grant over the credential on, the
  credential locked or unknown, a wrong use) it exits 125, as `env` and
  `timeout` do, with a line on stderr; any other status is the command's
  own. Nested, `mwt exec github -- mwt exec hex -- COMMAND` gives both
  credentials, and `MWT_TOKEN_GRANT` lists them.
- Git's credential helper answers only inside it, for the selected
  credentials' hosts. Outside, for a host a grant covers, it answers
  nothing and says on stderr which credential to run git through: git
  alone would only fail to read a username, which reads like a login to
  set up.
- Ordinary shells, editors' environment probes and public downloaders get
  no token variables, a grant on or off, and a new grant doesn't change
  the VM's environment. That keeps credentials out of commands that need
  none, and chooses between two that one tool would pick up alike (two
  GitHub Apps that both fill `GH_TOKEN`).
- The scope is explicit, never inferred from process names, and no
  security boundary: its refusal at the start spares an agent a long job
  that would fail, and the command's requests still meet the proxy's
  checks (a grant over the credential listing the host, one over its
  network, your approval). MWT doesn't learn the command, so a card shows
  the request.

<a id="credentials"></a>

### Credentials

A credential is where a real value comes from, and how tools in the VM
find its placeholder (`MWTClient.Sandbox.Credential`). It decides
nothing: the grants over it say where its value may go and how each use
is approved. Several token grants can be over one credential
(`Grant.credential`), each with its own hosts, attributes, approval and
state: "Google: BigQuery, auto" and "Google: Cloud Storage, asking" over
one Google login. Its request actions are grants over it too, listed
under it ([Request actions](#request-actions)).

- **What it holds:** the service it is for (`adapter`), its `source`
  (`:stored`, a value pasted into your vault; or `{:minted, command}`),
  its one placeholder, made once, how values are made and kept
  (`mint_per`, `keep_minutes`, a GitHub App's ids), what `mwt exec`
  presents (`env`, `file_env`, `git`, `presents`), what a preset gave,
  `aliases`, the placeholders it had before a merge, still its own so a
  tool holding one goes on working, and, for one an agent proposed, its
  `proposal` ([Proposed resources and grants](#proposed-grants)).
- **One value for all its grants.** Stored and minted values are kept
  under the credential's id (`Server.Values`): one mint serves every
  grant over it, or one a host for one minted per host.
- **A token grant keeps a copy** of its credential's fields
  (`Credential.attach/2`), filled in whenever the credential changes, so
  code reading a grant's placeholder or mint reads its credential's. The
  copy is a view: how the value is made and how tools find it are edited
  on the credential's page, and every grant over it follows; a grant's
  own form holds only the grant's fields, and editing it leaves its
  credential as it is (`Server.Grants.edit_grant/4`).
- **Added on its own, first**, on the Grants page's *Resources* tab
  (*Add credential*), from a credential preset or by hand
  ([Presets](#presets)): its name and purpose, the service it is for and
  that service's fields (a GitHub App's ids; a Google login file or
  metadata server), where its value comes from, how tools in the VM find
  its placeholder (variables, a token file, git's credential helper, for
  any git host over HTTPS), and what its placeholder starts with; a page
  of its own, with its lock and the grants over it
  ([The Grants page](#the-grants-page)). A grant over it is added from
  that page or from *Add grant*: it says only where the value may go and
  how each use is approved (hosts, carriers, attributes, the accounts it
  signs as, your machine), and holds no value of its own.
- **Its value may come later.** A stored credential can be added, or an
  agent's accepted, before its value is pasted: until it is, every use
  of it is refused (`mwt_no_value`), and no grant over it turns on or is
  accepted on (*Paste its value first*, `Server.Grants.turn_on_refusal/2`).
- **Removing it** removes the grants over it, its actions included, with
  its value and what was minted from it (`Server.Resources.delete/2`).
- **Nothing of it is in the VM without a token grant over it**: `/mnt/mwt`
  holds its placeholder, token file and git hosts only for a credential a
  token grant is over (`MWTClient.Sandbox.Inbox`). One only request
  actions use leaves the VM nothing to hold.
- **Its adapter** is the service it is for, `bearer`, `github`, `google`
  or `hex`, chosen in its form or by its preset ([Adapters](#adapters));
  one saved before 2026-11-25 gets the one its preset and fields said
  (`Credential.upgrade/1`). Its row on the *Resources* tab names it.
- **From grants saved before 2026-11-24** (`Credential.migrate/2`): each
  token grant becomes a credential under its own id, and grants minted
  the same way (the same preset, mint command and `mint_per`) merge into
  one, under the first one's id, named after the preset. The merged
  credential keeps every old placeholder and login placeholder as its
  own, presents what each presented (variables, token files, git), keeps
  a value as long as the shortest `keep_minutes` among them, and, where
  their logins' ID tokens travelled in different headers, sends it in
  each grant's carriers, that header added to them. Stored values never
  merge: two can't be told the same without reading them.

<a id="who-uses-its-value"></a>

### Who uses its value

A credential's value goes only where a grant over it lets it, and three
kinds of use reach it, each through a grant of its own:

| Use                                   | How the value goes                                                    | The grant over the credential it needs                       |
| ------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------ |
| A request a command in the VM sends   | its placeholder, under `mwt exec CREDENTIAL`, swapped at the proxy    | a token grant listing the host                               |
| A call of a request action            | MWT builds it and puts it in at the proxy ([Request actions](#request-actions)) | the action itself                                 |
| A saved command on your machine       | the real value, in its bubble ([Confined commands](#confined-commands)) | the saved command alone                                    |

- **A token grant lets the VM use the value**, through `mwt exec`, at the
  hosts it lists: open use of the credential, a grant of its own. Each
  such use also needs a grant over the network of the host
  ([The rule](#the-rule)). A saved command that runs with the credential
  needs no token grant: it covers the credentials it names (*Allow your
  machine*, `Grant.machine`, went on 2026-11-25).
- **A request action is a grant of its own over the credential**, so a
  few fixed API calls need no token grant: the VM then holds nothing of
  the value, not even a placeholder ([Credentials](#credentials)).
- **From grants saved before 2026-11-24** (`Grant.upgrade_all/1`): a
  token grant only its actions used (reach `:actions`, before that
  `:subgrants`) gave the VM nothing and goes, its actions staying under
  its credential; a token grant a confined command ran with allows your
  machine.

<a id="where-real-values-come-from"></a>

### Where real values come from

A value is its [credential](#credentials)'s, kept under its id, whichever
grant over it a use goes through.

- **Stored** in the identity's vault.
- **Minted:** a command run on the host that prints a short-lived token
  (`gcloud auth print-access-token --impersonate-service-account=…
  --lifetime=1800s`), once for every grant over the credential. Prefer
  this: the long-lived credential never leaves your host tools. It runs
  as you, unconfined: the one place that touches your login.
  - It is told `MWT_GRANT`, the credential's id, and, for a credential
    minted **per host** (`mint_per`), `MWT_HOST`: one credential then
    serves tokens bound to where they go, each kept apart. A confined
    command, which has no single host, can't name a grant minted per
    host.
  - It prints the bare value, kept 10 minutes, or
    `{"value": "…", "expires_in": 1800}`, kept until a minute before it
    expires; JSON with no `value` is an error. Beside its value it may
    print an `id_token`, kept as long, for a credential with a login file
    ([Credential endpoints MWT answers](#credential-endpoints-answered))
    or a request action that sends it ([Request actions](#request-actions)).
    Its adapter reads what it prints ([Adapters](#adapters)): Google's
    reads what `gcloud config config-helper --format=json` prints as it
    is (`credential.access_token`, `credential.id_token`,
    `credential.token_expiry`), so that needs no reshaping here.
  - A credential may keep each value at most N minutes (`keep_minutes`),
    whatever the mint says of its expiry, for a service that takes a token
    only while it is young: one that refuses an ID token issued more than
    5 minutes before keeps it 4. The ID token and the access token are
    kept as long as each other: no keep time of the ID token's own yet.
- **Made by its adapter** from what a command prints: a GitHub App's
  installation token, from the App's private key ([Adapters](#adapters)).
  The command runs as a mint does; the key is held only while MWT signs
  with it.
  - The grant is looked at again once the value is at hand: one turned
    off, out of time or no longer listing the host while it ran sends
    nothing (`mwt_grant_off`).
  - Every value kept, each host's included, is among what the proxy looks
    for. A value that depends on the request itself (its path, its method)
    is a signature, which a mint can't make.

<a id="presentations"></a>

### Presentations

Every credential has three ways to reach a tool: variables, the token
file, git's helper. Tools that find credentials otherwise (a helper they
call, a local server they ask) get a presentation: a small program,
`/mnt/mwt/bin/mwt-present` (`native/mwt_present`, static, built as
`mwt-acp` is), that shows a placeholder the way a tool family expects. It
holds only placeholders, so adding one is no trust decision. A credential
names the ones it needs (`presents`, edited on its page, as a Google
credential's login file or metadata server);
`mwt exec` runs the command under it,
so it owns the child, its signals (passed on) and its exit status, and
nothing of it is left once the command ends.

Two there are. **A cloud metadata server** on a loopback port, with
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
presentation, never the command. Its project is also the command's
`GOOGLE_CLOUD_PROJECT`, set by the google adapter: google-auth warns
without one, and some clients need it. The form offers it on a token grant
whose hosts are Google's APIs (under `googleapis.com`), added or edited,
or that has it on: gcloud reads the token file, and only Google's client
libraries look for a metadata server. An agent proposes it with
`--metadata-project` and `--metadata-account` ([Proposed
grants](#proposed-grants)).

**A Google login file** (*Give it a Google login file*): within `mwt
exec`, `GOOGLE_APPLICATION_CREDENTIALS` names
`/mnt/mwt/logins/<credential>.json`, an `authorized_user` login whose
refresh token is a placeholder of its own (`1//mwt…`, made once, kept
across edits), with gcloud's public client id and a secret that is none.
It is
for tools that refresh a login themselves rather than take a token, as
one that needs an ID token must. That refresh never goes out: MWT answers
it ([Credential endpoints MWT answers](#credential-endpoints-answered)).
Google's libraries take the file before a metadata server. An agent
proposes it with `--login-file` and `--id-token-header`.

<a id="credential-endpoints-answered"></a>

### Credential endpoints MWT answers

Some tools don't send a grant's token to the service: they trade it, in
process, at a credential endpoint for another credential, and send that.
The firewall refuses such a request ([Rules](#rules): *Minting a
credential*), since the answer would be a credential in the VM. For a
grant that takes the endpoint, MWT answers it itself instead
(`MWTClient.Sandbox.CredentialEndpoint`): it makes the credential with
the grant's real value, keeps it as a **value made from the grant**
(`MWTClient.Sandbox.Made`), and the VM gets a placeholder for it. The
endpoint's host is plumbing, not access: the google adapter implies it for
every grant that needs it, so no grant has to list it
([Adapters](#adapters)).

A made value belongs to its grant: a request carrying its placeholder is a
use of that grant, asking or allowed as the grant is, refused while it is
off. It goes where it was made for, narrower than its grant: its own
hosts, its own carriers, until its own expiry. It is kept in memory only,
as minted values are, and is among the values the proxy looks for. Its
placeholder sent where it doesn't go is blocked as a grant's is; one MWT
no longer holds is refused (`mwt_placeholder_expired`), so a tool told to
sign again is told why, rather than getting the service's `401`. A JWT's
placeholder is the JWT with its signature replaced (`mwt` and 43
base64url characters): its header and claims say nothing secret, and a
client that reads them locally still works.

Two there are.

**Google's token endpoint**, for a credential with a login file
([Presentations](#presentations)):

1. The request: `POST oauth2.googleapis.com/token`, its body carrying the
   login's placeholder (its own, or one it had before a merge), which
   makes it the credential's; that placeholder anywhere else is blocked
   as any is.
2. Checked: a refresh (`grant_type=refresh_token`) of that very login,
   read whole.
3. Nothing goes out, and the VM gets placeholders only, so the refresh is
   no use of a grant: no card, no allowance. It is answered while a grant
   over the credential is on and the credential isn't locked, and refused
   otherwise (`mwt_grant_off`, `mwt_locked`). MWT fetches the
   credential's value (minting it when it must) and answers
   `{"access_token": the placeholder, "expires_in": as long as MWT keeps
   it, "token_type": "Bearer", "id_token": …}`. The access token is the
   credential's own placeholder, swapped on the way out as always, where
   the grants over it say.
4. The `id_token`, when the mint printed one, is a placeholder made from
   the grant that stands for *its current ID token*: on the way out MWT
   puts in the one the mint gives now, minting again once the kept one is
   older than the grant keeps its values, so a service that refuses old ID
   tokens gets a fresh one however long ago the tool refreshed. It goes to
   the grant's hosts, in the header the login names (*Header its ID token
   travels in*), or in the grant's carriers. Its claims are the real
   token's `iss`, `aud`, `iat`, `exp`, `email` and `hd`, no more: the
   email and domain are that grant's own login's, which needn't be the
   one your commits use.

**IAM Credentials' `signJwt`**, for a grant that names
the service accounts it may sign as (*May sign as*, `Grant.signs_as`). A
client of a service behind Identity-Aware Proxy loads default credentials
(the [metadata server](#presentations)), asks Google to sign claims it
builds as a service account, and sends the JWT as its bearer:

1. The request: `POST
   iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/ACCOUNT:signJwt`,
   carrying the credential's placeholder.
2. Checked before anyone is asked, against every grant over the
   credential that is on, together (their accounts and their hosts): the
   account is one of them names (`mwt_not_a_signer`); the claims' `aud`
   is an `https` URL on a host one of them lists, the only place the
   signed JWT will go (`mwt_placeholder_blocked`); no `delegates`, which
   would sign as an account none of them names; the whole body read.
3. Let through by [the rule](#the-rule), as any use of the credential,
   MWT sends the same request itself with the real value: the very
   request the tool makes on your machine, with the same token. No grant
   needs to list `iamcredentials.googleapis.com`: the google adapter
   implies it for every grant that signs.
4. Google's answer: the signed JWT is kept, going only to the `aud` host,
   in `Authorization`, until its `exp` (12 hours at most); the VM gets
   `{"keyId": …, "signedJwt": placeholder}`. A refusal of Google's goes to
   the VM as it came; no other answer does.

Naming an account is a trust decision, unlike a presentation: while the
grant is on, the VM may act as that account, through MWT and the grants'
approval, toward every host a grant over the credential that is on lists,
Google's APIs among them where one lists them. Your login needs *Service
Account Token Creator* on the account; without it the agent gets Google's
`403`.

<a id="adapters"></a>

### Adapters

An adapter is what MWT knows of one family of credentials, whatever the
protocol (`MWTClient.Sandbox.Adapter`). The core owns the flow: the locks,
the rule, the cards, when to mint and what is kept, swapping
placeholders, what the VM gets, the firewall. An adapter supplies, behind
fixed extension points:

- `read_mint/2`: reading what a mint prints, the value, a value that comes
  with it (an ID token), and how long it lasts;
- `implied_hosts/1`: the hosts its own endpoints need, which a grant needn't
  list, since they are plumbing, not access;
- `env/1`: variables `mwt exec` sets beside the credential's own;
- `attributes/1`: what its requests name that a grant may narrow by
  ([Attributes](#attributes)), read only from a URL or a documented field;
- `exchange/3`, for one that makes its value from what a mint prints;
- `sign_jwt/4`, optional: a JWT signed as one of the accounts a grant
  names, with the credential's value, for a request action that sends one
  (`{signed_jwt}`, [Request actions](#request-actions)). Google's alone
  has it.

A credential names its adapter (`Credential.adapter`), chosen in its
form or by the preset it starts from. One saved before 2026-11-25, or a
grant still being built, goes by what its preset and fields say
(`Adapter.of/1`): Google's when it signs, presents a login file or a
metadata server, or comes from a Google preset; GitHub's when it has a
GitHub App or comes from a GitHub preset; Hex's from Hex's; `bearer`
otherwise. Four ship:

| Adapter | Knows | Implies | Adds |
| ------- | ----- | ------- | ---- |
| `bearer` (`Adapter.Bearer`) | any token in `Authorization` or headers you name, Basic credentials included: a bare value or MWT's JSON from a mint | nothing | nothing |
| `github` (`Adapter.GitHub`) | personal and fine-grained tokens, a GitHub App's installation token | nothing | the attribute `github.repository`, from the REST API's `/repos/OWNER/NAME/…` and git's `/OWNER/NAME(.git)/…` |
| `google` (`Adapter.Google`) | an access token; what `gcloud config config-helper --format=json` prints, ID token included; a login file whose refresh MWT answers; `signJwt`, answered for the VM or called for a request action's `{signed_jwt}` | `oauth2.googleapis.com` for a credential with a login file, `iamcredentials.googleapis.com` for a grant that signs | `GOOGLE_CLOUD_PROJECT` under `mwt exec`, from its metadata server's project |
| `hex` (`Adapter.Hex`) | a Hex API key, sent as the whole `Authorization` value; read as `bearer` reads one | nothing | nothing: it is its own so a Hex credential is offered Hex's grant presets |

- **Implied hosts** are among the hosts a grant's value may go to
  (`Adapter.hosts/1`), read by the proxy and named by `mwt why`; reaching
  them is the network's grants' to give, as any host's. The form no longer asks a Google
  grant to list them.
- **A GitHub App's installation token** (`ghs_…`, an hour, no person's):
  the credential holds the App's id and the installation's id
  (`Credential.app`), and its mint is a command that prints the App's
  private key, run on your machine as any mint, from where you keep the
  key. MWT signs a JWT as the App with it (RS256, ten minutes) and trades
  it at `POST api.github.com/app/installations/ID/access_tokens` for an
  installation token, kept until a minute before it expires
  (`GitHub.exchange/3`). The key is held only while MWT signs, never
  logged. The *GitHub App* credential preset fills it in, or the GitHub
  App fields of a GitHub credential's form. Both ids, the GitHub adapter
  and a minted value are needed together: one id alone, or the ids on
  another adapter or a stored value, is refused, never dropped (a key
  printed by a plain mint would be taken for the token itself).
- **Shipped with MWT, never plugins:** an adapter runs in the process that
  holds every real value. Your presets stay data, on top of any adapter.
- **Not yet behind an adapter:** the token shapes the scanner looks for,
  the credential endpoints the firewall refuses and how a placeholder
  looks. Presets name the adapters they are for; adapters don't declare
  them ([Presets](#presets)).

<a id="networks"></a>

### Networks

A network is a resource of its own, as a credential is
(`MWTClient.Sandbox.Network`): what network grants are over. It holds
what is the network's and no grant's: an `id` and a `name`, its
`destinations` (addresses, ranges and names, each with its ports), its
`resolver` (the DNS server that answers its names, nil for this
machine's), its `anchor` (the interface its addresses are reached
through, nil for wherever this machine routes them) and its `limits`,
the hosts it blocks ([Host limits](#host-lists)). The Internet is built
in: every public address, listing none (`internet: true`). Grants over a
network give its uses and say how each is approved; you lock the
network, not a grant ([Locks](#locks)), and block its hosts on its page.

- **All of it or part.** A network grant names its network
  (`Grant.network`) and covers all of it (`Grant.scope` nil) or part of
  it (`scope`, a list written as destinations are): one host of the
  Internet set apart, say. It holds a copy of its network's resolver and
  interface, and, over all of it, its destinations (`Network.attach/2`),
  so code reading a grant's reads its network's; one over part keeps its
  scope as its destinations.
- **Added on its own**, on the Grants page's *Resources* tab (*Add
  network*), with a page of its own: its destinations, DNS server and
  interface, its lock, its host limits and the grants over it. Editing
  it edits what every grant over it reaches, each taking its fields
  again; removing it removes the grants over it
  (`Server.Resources.delete/2`). The Internet is MWT's: no edit changes
  what it is, and it stays.
- **Grants over it only give.** Of those on that cover a use, the most
  permissive counts ([The rule](#the-rule)); the most exact one holds a
  connection ([Private networks](#private-networks)). A grant over one
  host of the Internet that auto-approves lets that host through while
  the Internet's grant asks.
- **From before 2026-11-24** (`Network.migrate/2`, as MWT starts): each
  network grant becomes a network under its own id and the grant over all
  of it. Its host list's Block and Ask entries become the network's
  Blocked list, so nothing that waited for you goes unasked; its Auto
  entries, grants over those hosts, auto-approving, under an id made of
  the grant's and the host's (`internet-api-example`). An entry
  `example.com` becomes the scope `*.example.com`, the name and every
  name under it, as the entry covered. A grant over part of a network
  that was off as a block, or always asked, becomes a Blocked entry too.
- **On the *Resources* tab**, each network, the Internet first, with
  what it is (every public address, or its destinations, DNS server and
  interface), the grants over it and its lock.

<a id="presets"></a>

### Presets

You add a resource first, then grants over it, and a preset fills each
form for a service whose details are known: a credential preset the
credential's (chosen first in *Add credential*), a grant preset a
grant's over a credential of that service (chosen first in *Add grant*,
once you pick the credential). Each shows what it is, what it sets and
what it asks you for, with a search when there are many; *By hand* is
always first. A
preset only fills the form: what it makes is a plain credential or grant
you can edit, and nothing looks at the preset again. A preset is a JSON
file (`MWTClient.Sandbox.Presets`): MWT's under `priv/sandbox/presets/`,
yours in the identity's folder, `sandbox/presets/*.json`. It holds:

- `makes`: `credential`, `grant`, `network` or `command`; a grant preset's
  `over` lists the adapters and credential presets it is for (none: any
  credential), and a credential preset's `adapter` the service it sets;
- `name`, `icon`, a one-line `blurb` and the `guide` shown when adding;
- `fields`, the form's fields (`MWTClient.Sandbox.FormFields`: a
  credential's variables, mint command, App ids…; a grant's hosts,
  carriers, attributes…), never one of yours (a value, a start setting),
  and `fill`, fields you fill first, each with a label and an example,
  `{name}` marking where it goes in its fields and its actions' (only one
  still written somewhere must be filled);
- what the form doesn't hold: a credential preset's `request_headers`
  (what its request actions start from) and `tools` (what a command's
  card says it covers), a grant preset's `actions` (read from `subgrants`
  in a file written before actions were called so).

Everything it gives is copied onto what it makes (`Credential.icon`,
`request_headers`, `cli_tools`, a grant's actions), so removing the file
changes nothing. A file that can't be read is left out, with its path and
why (`Presets.load/1`). A file written before 2026-11-25, with a `kind`
and a `grant` object, a credential and a grant in one, is read as a
credential preset under its id and a grant preset over it, `ID-grant`,
each with the fields of its own (`Presets.read/1`).

| Credential preset | Adapter | Its value | VM side |
| ----------------- | ------- | --------- | ------- |
| GitHub token (`github`) | `github` | pasted, placeholder `ghp_…` | `GITHUB_TOKEN`, `GH_TOKEN`, git's credential helper |
| GitHub App (`github-app`) | `github` | made from the App's private key a command prints, with the App's and the installation's ids you fill ([Adapters](#adapters)), placeholder `ghs_…` | `GITHUB_TOKEN`, `GH_TOKEN`, git's credential helper |
| Hex (`hex`) | `hex` | pasted | `HEX_API_KEY` |
| Google Cloud (`google`) | `google` | minted (`gcloud auth print-access-token`), placeholder `ya29.mwt…` | `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` naming the token file |
| Google login, with ID token (`google-login`) | `google` | minted (`gcloud config config-helper --force-auth-refresh --format=json`), placeholder `ya29.mwt…` | a login file (`GOOGLE_APPLICATION_CREDENTIALS`), its refresh answered by MWT |

| Grant preset | Over | Hosts | Narrowed by |
| ------------ | ---- | ----- | ----------- |
| Everything it reaches (`github-everything`) | `github` | `api.github.com`, `github.com`, `uploads.github.com` | nothing: the token's own permissions |
| One repository (`github-repository`) | `github` | the same | `github.repository`, the repository you fill |
| Google APIs (`google-apis`) | `google` | `*.googleapis.com` | nothing: the login's roles |
| Hex packages (`hex-packages`) | `hex` | `hex.pm`, `repo.hex.pm` | nothing: the key's own permissions |

Placeholders look like the real thing where a preset says so, since some
clients check the format. Each credential's placeholder is made once and
never changes.

<a id="setting-up-credentials"></a>

### Setting up each kind of credential

The rule each type's and preset's guide follows: keep the long-lived
credential on the host, give MWT something it can put on the wire, and
give the VM only a placeholder.

| You have                                                                   | Grant                     | How                                                                                                                                                                                                           |
| -------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A token or API key                                                         | token, stored             | Paste it once; it lives in your vault.                                                                                                                                                                        |
| A CLI login on the host (`gcloud auth login`, `gh auth login`, `az login`) | token, minted             | A command that prints a short-lived token, run on the host when needed (`gcloud auth print-access-token`, `gh auth token`, `az account get-access-token --query accessToken -o tsv`). The login stays there. |
| A credential you gave MWT already, for another use (BigQuery beside Cloud Storage) | token, over that credential | *Add grant* over it, from its page or by picking it: the new grant says only where the value may go and how each use is approved, and the value is minted once for both ([Credentials](#credentials)). |
| A GitHub App                                                               | token, made by the github adapter | The *GitHub App* credential preset: the App's id, the installation's id, a command that prints the App's private key ([Adapters](#adapters)); then a grant over it, *Everything it reaches* or *One repository*. |
| A token for a few fixed API calls                                          | request actions over the credential | Request actions, which MWT sends itself, and no token grant: the VM holds nothing of it.                                                                                                             |
| Something only reachable from here (VPN, a database through a tunnel)      | network                   | List the destinations; for a database, run the tunnel on the host and list its exact address.                                                                                                                 |
| A key or file a tool reads for one job (SSH keys, a kubeconfig, signing)   | saved command             | Your script runs here, confined with the values it names, and only its output goes back.                                                                                                                      |
| Something a process in the VM must read for long (a client certificate)    | saved command             | No grant hands the VM a file's value: the job runs here, where the file is, and only its output goes back.                                                                                                    |
| Something none of these covers                                             | no grant: a command the agent writes | One command the agent writes runs here, with your approval each time ([Commands agents write](#ask-to-run-commands)).                                                                       |

Agents don't see the guides. They see each grant's own words (`mwt
grants`), and describe what's missing in theirs (`mwt request --need`).

<a id="states"></a>

### On and off

A grant is on or off (`Grant.state`):

- **On**, for a time or until you turn it off: agents use it. It asks
  each time or auto-approves, with allowances while it is on.
- **Off**: it has no say. It gives nothing and refuses nothing. Agents
  can ask for it to be turned on (`mwt request`), but for a proposal you
  haven't reviewed, whose card only leads to its review, and a grant
  whose resource is locked, an ask refused at once, with no card.

The clock decides, not a timer: a grant on for a time is off once the
time ends (`Grant.state_at/2`).

- **Deny by default.** With no grant on, the VM reaches nothing through
  MWT: it can only ask you, for a grant or to run a command it wrote.
  What it has from the start is the grants whose start setting turns
  them on, the Internet's among them ([When MWT starts](#when-mwt-starts)).
- **A grant you add starts off**, so adding one changes nothing until
  you turn it on. A grant an agent proposes stays off until you accept
  it, and its resource, when the agent proposed that too
  ([Proposed resources and grants](#proposed-grants)).
- **Holding a use back is a resource's job**, not a grant's: lock the
  resource ([Locks](#locks)), or block the host on its network
  ([Host limits](#host-lists)).
- **From what is saved** (`Grant.upgrade/1`): a grant saved disabled, and
  a start setting saved as Disabled or *Off, refusing*, are off now.

<a id="the-rule"></a>

### The rule

Grants give, resources limit (`MWTClient.Sandbox.Policy`):

1. **Nothing goes without a grant.** With no grant on, the agent reaches
   nothing.
2. A use goes through one or more resources, and **each of them needs a
   grant that is on and covers this use**. One missing, it is refused:
   `mwt_grant_off`, naming a grant that is off and would cover it, or
   `mwt_not_covered` when none would.
3. **Within one resource**, any grant covering the use is enough, and the
   most permissive counts: grants only give (`Policy.most_permissive/1`).
4. **Across resources**, the use goes unasked only if every one lets it
   through unasked. If any asks, **one card** names each grant that asks;
   *Allow for a while* adds an allowance to each (`Policy.all_of/1`).
5. **A locked resource or a blocked host refuses**, whatever the grants
   say (`mwt_locked`, [Locks](#locks); `mwt_host_blocked`,
   [Host limits](#host-lists)), and so does every use while the VM is
   isolated.

A grant lets a use through unasked when it auto-approves or an allowance
of its covers the use; it asks when it is on and asking with no
allowance covering the use.

| A use | goes through |
| ----- | ------------ |
| A connection, a request with no credential | its network |
| A request carrying a credential's placeholder | the credential (a token grant listing the host) and the network |
| A call of a request action | the action, which covers its credential in its own request, and the network of its host, as the agent's own request would (`Policy.reach/3`) |
| A saved command | the saved command alone, which covers host commands and the credentials it runs with; a lock on any refuses |
| A call of MWT's tools | MWT's tools: notes, diagrams and cards, the projects' git, the shared folders and the workspace |
| An agent's own command | Commands agents write, on: then you approve each one; refused at once while host commands are locked |

An HTTP request MWT reads is one decision (`Policy.decide/3`): the grants
over the credential it carries that cover it, and the grants over the
network its connection went under, those over all of it and those over
part of it naming its host. So a request to a host behind your VPN that
carries a token is one card, not two in a row. With no credential, the
network's grants decide alone.

At work it decides like this:

| Use | Grants on that cover it | Each resource | Result |
| --- | ----------------------- | ------------- | ------ |
| `bq query`, to `bigquery.googleapis.com` with Google's placeholder | Google: BigQuery, auto; Internet's, auto | credential: yes; network: yes | goes |
| The same, with Google: BigQuery off | Internet's, auto | credential: none | refused, `mwt_grant_off` naming Google: BigQuery |
| The same, with Google: BigQuery off and Google: all its hosts, auto | Google: all, auto; Internet's, auto | credential: yes; network: yes | goes: off gives nothing and refuses nothing |
| The same, with the Internet's grant off | Google: BigQuery, auto | credential: yes; network: none | refused, `mwt_grant_off` naming the Internet's grant |
| A datalake request to `internal.ume.com.br` | UME datalake, asks; prod gateway, asks | credential: ask; network: ask | one card naming both |
| The same, with UME datalake auto-approved | UME datalake, auto; prod gateway, asks | credential: yes; network: ask | a card naming the prod gateway |
| A GitHub request, with no grant over the GitHub credential on | Internet's, auto | credential: none | refused |
| A request to `paste.example`, on the Internet's Blocked list | Internet's, auto | network: blocked | refused, `mwt_host_blocked` |
| A request to `api.example.com`, with the Internet's grant asking and a grant over `api.example.com` auto-approving | Internet's, asks; Internet: api.example.com, auto | network: yes, the most permissive | goes unasked |

What follows from the rule:

- **Grants only give.** A narrow grant can't hold back a wide one: to let
  BigQuery through unattended while the rest of Google asks, make a
  grant over BigQuery's hosts that auto-approves beside one over all of
  Google's hosts that asks. To hold back a use whatever the grants say,
  lock its resource or block its host.
- **No order and no ranking** among the grants over a resource: the order
  grants were made or listed in changes nothing, and a narrow grant and a
  wide one both give.
- **One card.** When the answer is ask, one card shows the use and names
  every grant that asked (*Asking*), the network grant it came through
  (*Through*) and those that let it through (*Let through by*); your
  answer goes to each ([Approvals](#approvals)). Once it is allowed, the
  credential's value goes in, whichever grant led the card.
- **A host is asked about only through its grants**: a host reached with
  a credential asks when that credential's grant asks. To have one host
  ask while the Internet's grant lets the rest through, the Internet's
  grant leaves it out and a grant over it asks
  ([Host limits](#host-lists)).
- **Pure.** `Policy.decide/3` takes the grants, the resources' locks and
  limits, the use and the clock, and acts on nothing, so a dry run is the
  same call ([Finding out why](#finding-out-why)).

A connection opens under a network grant that is on and covers its
address, the most exact one holding it
([Private networks](#private-networks)); each request it carries is then
decided by every grant over its network that covers the host. Network
grants narrow by no attribute.

<a id="locks"></a>

### Locks

Resources are open by default. A lock stops every use of its resource,
whatever its grants say, and means something went wrong: it waits for you
to look and unlock it. Everyday access is the grants' job.

- **What can be locked** (`Grant.resource/1`, `MWTClient.Sandbox.Resource`):
  a credential, for every grant over it, its request actions included; a
  network ([Networks](#networks)), the Internet included, for every grant
  over it, all of it or part (`{:network, Network.id_of(grant)}`); your
  machine, for what MWT carries out there: the commands agents write,
  saved commands, the projects' git, the shared folders' sync and the
  workspace's copy; and MWT's tools, for notes, diagrams and flash
  cards.
- **Two hold locks, each apart** (`MWTClient.Sandbox.Server.Locks`): you
  (`:you`), with a resource's *Lock* (*Unlock* to end it), and the
  isolation (`:isolation`). A
  resource stays locked while either holds it (`Locks.holders/2`).
  Releasing the VM never ends a lock of yours, and unlocking never ends
  the isolation's.
- **Locking** (`MWTClient.Sandbox.lock/2`) refuses every use of it, `403`
  `mwt_locked`, saying the user locked it and that asking won't change
  it; closes the connections its grants let through; refuses the cards
  waiting on them; stops the commands running with it, TERM then KILL
  5 s later (`HostRuns.running_with/2`, `HostRuns.stop_running/3`): for
  your machine every command running there, for a credential those
  confined with its value; and changes no grant. `mwt exec` on a locked
  credential refuses at the start.
- **Checked again as a value arrives.** A mint takes time, so a request
  decided before it looks at the lock again once the value is at hand
  (`Server.Values`' `still/3`): a credential locked meanwhile sends
  nothing (`{:locked, resource}`, `mwt_locked`).
- **Only you unlock it** (`MWTClient.Sandbox.unlock/2`), on the Grants
  page's *Resources* tab or the resource's page. Agents can ask for a
  grant, never for a lock to end, and are told to tell you what they were
  doing; an ask for a grant whose resource is locked is refused at once,
  with no card.
- **Kept** with the sandbox, each with who holds it, so a restart keeps
  them; a lock saved before the isolation locked anything is yours
  (`Locks.upgrade/1`).
- **Isolating the VM locks everything** at once, each credential, each
  network, your machine and MWT's tools, as the isolation's lock (`Locks.lock_all/2`),
  beside any lock of yours, and changes no grant
  ([Isolating](#isolating)). Releasing ends only the isolation's
  (`Locks.unlock_all/2`): what you locked stays locked.
- **On the *Resources* tab** each resource's switch reads as the
  resource working: on, open, as it is by default; off, locked, with a
  *Locked* badge. A lock only the isolation holds shows *Isolated*
  instead, its switch disabled until you release the VM on the Firewall
  page.

<a id="attributes"></a>

### Attributes

A token grant may narrow by attributes MWT reads from the use, beyond its
hosts (`Grant.attributes`, `MWTClient.Sandbox.Attributes`): it covers a
use only when each it names matches. On its form, *Only these uses*, one a
line, `name = pattern, pattern`.

| Name                | Read by                  | A use's value                                    |
| ------------------- | ------------------------ | ------------------------------------------------ |
| `http.method`       | the HTTP driver          | its method                                       |
| `http.path`         | the HTTP driver          | its path, without the query                      |
| `grpc.method`       | gRPC, on HTTP/2          | `Service/Method`, from a gRPC call's path        |
| `graphql.operation` | GraphQL, on HTTP         | `query`, `mutation` or `subscription`, and the operation's name |
| `git.direction`     | git over HTTPS           | `fetch` or `push`                                |
| `github.repository` | the github adapter       | `owner/name`, from the REST or git path          |

- **Patterns** match exactly, in any case, or by segment for a path: `*`
  stands for one segment, `**` for any number (`/repos/*/pulls/**`). An
  attribute a use doesn't have (no gRPC method on a REST call) doesn't
  match.
- **What MWT couldn't read is unknown,** and counts against the use: a
  GraphQL body it holds only the start of, a repository a GraphQL query
  names in its variables. With *Covers requests MWT can't read*
  (`Grant.covers_unread`, on by default), an unknown attribute matches a
  grant that would ask (always asking, or not auto-approving), so such a
  use waits for you rather than go, and doesn't match one that would let
  the use through. Off, it matches neither, and the other grants over the
  credential decide. It is part of what the grant means: changed only on
  its form, no timer, never asked for by agents, and `mwt grants` lists
  it.
- **None covering is a refusal:** a request no grant over its credential
  covers is refused, `403` `mwt_not_covered`, naming the grant and what it
  covers only.
- **At work:** "GitHub: repository `credit-engine`, asking" and "GitHub:
  repository `klife`, auto" over one GitHub credential. A REST call about
  `klife` goes; one about `credit-engine` asks; one about another
  repository is covered by neither and refused. A GraphQL query's
  repository is unknown, so the asking grant covers it and it waits for
  you, unless that grant's *Covers requests MWT can't read* is off.
- **Not yet:** network grants narrow by no attribute, and drivers don't
  declare theirs: one module reads them all (`Attributes.of/1`), the
  github adapter adding the repository.

<a id="overlaps"></a>

### Overlaps

Overlapping grants are where a use goes in a way that is hard to see:
of the grants over one resource that cover a use, the most permissive
counts, so turning one off doesn't stop a use another still gives. So MWT
works out which grants over the same resource may cover the same use from
their scopes, every time it is asked (`MWTClient.Sandbox.Overlaps`).
Nobody declares a link, so none can be missing or stale. Two grants
overlap when:

- both are token grants over one credential and their hosts meet: equal
  hosts, a host under the other's `*.` entry, or one `*.` entry under
  another;
- both are network grants over one network and their destinations meet,
  the one over all of it meeting every one over part of it.

Grants over different resources never overlap: a use that goes through
both needs each (a token grant and the grant over its host's network). A
name and an address range meet only if the name resolves into the range,
which DNS decides when the use is made: those *may overlap*, with why. A
grant's page has an *Overlaps* card: each grant it overlaps, and where.
`mwt grants` lists `- overlaps:` under each grant. Not yet:
attributes aren't compared (two grants over the same hosts overlap
whatever their attributes), the Grants page doesn't group linked grants,
and changing a state doesn't say first what it changes through them.

<a id="grants-and-actions"></a>

### Grants and actions

An **action** is a grant for one fixed use of a resource, listed under
that resource, which MWT carries out when an agent calls it by id: a
function, with a body that never changes and parameters the agent fills
in.

```
mwt call gh-repo-view REPO_NAME=oliveigah/klife --reason "check the default branch"
```

| Resource            | Action type | Its body                               | Who carries it out                                                         |
| ------------------- | ----------- | -------------------------------------- | -------------------------------------------------------------------------- |
| Host (your machine) | `command`   | Your script, and the folder it runs in | This machine, confined or as you ([Confined commands](#confined-commands)) |
| A credential        | `request`   | Method, URL, headers and body          | MWT, from this machine, with the real value ([Request actions](#request-actions)) |
| A network           | none        |                                        | The VM connects itself: nothing to stand in for                            |

**A saved command is a grant over your machine**: your script, in your
folder, which agents call by id and send no text for. It starts off like
any grant (saved from a card, on for 1 hour, asking each time), new ones
run confined, and the Grants page shows it under your machine. Each
credential it runs with needs a token grant over it that allows your
machine ([Who uses its value](#who-uses-its-value)). Asking, approving
and running are in [Host commands](#host-commands).

- **Never in the VM.** The agent is root there and can replace any tool,
  so a command MWT started there would prove nothing. What VM tools do
  with a grant (`mwt exec github -- git push`) stays a use of the grant;
  for an API call, a request action is better: nothing in the VM holds
  even a placeholder, and you read the exact request.
- **By id, never by match.** MWT never takes a command or a request as
  "the same as" an action: an ad-hoc command with an action's exact text
  still waits for you, with a hint naming the action. A name is not
  enough.
- **A grant of its own**, on or off, for a time, asking or
  auto-approved: `gh-repo-view` can be enabled on startup and
  auto-approved while every command an agent writes still asks, and a
  request action can run with no token grant over its credential on.
- **Removing a resource** removes its actions
  ([Credentials](#credentials)).

#### Parameters

A call's parameters are one JSON Schema (2020-12, checked by the `jsv`
library: `MWTClient.Sandbox.ParamSchema`), as an MCP tool says its
input: an object whose properties are the parameters, each with its
`description`, which you and agents both read, and what its values may
be. JSON Schema rather than a language of MWT's: a standard everyone
knows, agents included. On the form it is *Parameters*; in a proposal,
`--set schema='…'`, or `--param 'NAME:shape:what it is'` lines, a
shorthand for the same (`Param.parse/1`): `word` (MWT's `word` format),
`number` (an integer, 0 or more), `decimal` (a number), `date`, `time`
(`date-time`), `text` (a string), `a|b|c` (an `enum`).

    {
      "type": "object",
      "properties": {
        "REPO": {"description": "the repository", "type": "string",
                 "format": "word", "pattern": "^oliveigah/"},
        "PR": {"description": "the pull request", "type": "integer", "minimum": 1}
      }
    }

- **What a schema is held to,** refused as you save it: each name a
  parameter's (below); each property with a `description`; every one
  required (a `required` leaving one out is refused); a `type` of
  `string` (or none), `integer`, `number` or `boolean`, one value each;
  formats checked, the standard ones and MWT's **`word`**: letters,
  digits and `_ . - @ : +`, in parts joined by `/`, no part `.` or `..`,
  no leading `/` or `-`, up to 200 bytes (`ParamSchema.Formats`); a
  parameter's schema reads nothing outside itself (`$ref` only to `#…`,
  no `$id` or `$schema`), at most 2 KiB; at most 8 parameters.
- **MWT's floor, whatever the schema says** (`Param.check/2`): a value is
  given and not blank, shows all it holds, is at most 4 KiB, never
  starts with `-` (but a number) and never goes up a folder (no part
  between `/` that is `.` or `..`). A schema can't loosen it, so one an
  agent proposes can't make a call less safe.
- **Typed by its schema:** an `integer` or `number` reaches the schema as
  a JSON number, a `boolean` as `true` or `false`, the rest as a string;
  the script or the request still gets the text as given, and a request's
  body takes a parameter alone as its type.
- **Checked in a process of its own,** unlinked, at most 10 million
  reductions of work and 8 MiB (a check takes a few thousand), so a schema
  whose checks fan out fails the call instead of holding MWT. Work, not
  time: on a busy machine a valid value still passes;
  `pattern`s run with `jsv`'s backtracking budget. A schema saved or
  imported is checked again as it loads; a parameter whose schema isn't
  one keeps the floor alone. Parameters saved with a shape (and a rule,
  2026-11-25) take the schema they make.
- **Said in words:** the grant's page and `mwt grants` say each
  parameter's schema ("an integer, from 1 to 10", "one of: staging,
  production"); a value that breaks it is refused before anything runs,
  the agent told why ("value 11 is higher than maximum 10"), and the log
  says which parameter and its schema in words, never the value.
- Why not CUE, which reads better: it is a 25 MB Go program to ship and
  sign, run for each check, with errors only as text, and a schema of a
  few hundred bytes can take gigabytes to evaluate, so every run would
  need a memory cap macOS doesn't enforce.
- **Names** are capitals, digits and underscores (`REPO_NAME`). One the
  environment already has, or the shell, the loader or git give a meaning
  to (`PATH`, `IFS`, `LD_…`, `GIT_…`, `BASH_…`), is refused.
- **A command reads them as environment variables**, its script run
  exactly as saved, so a value can't add a command, a pipe or a redirect.
  Every parameter must appear in the script as `$NAME` or `${NAME}`: a
  value reaches a tool only where you see it go. Saving hints at a
  parameter that may hold spaces outside double quotes (spaces would
  split it) and one inside single quotes (left as it is): hints, not a
  review.
- **A call is checked before anything runs or waits:** every parameter
  given once, none unknown, each value over MWT's floor and showing all
  it holds ([Text the VM chooses](#text-the-vm-chooses)), then its schema.
  The agent hears what is wrong, with the parameter's line.
- No defaults and no optional parameters: two uses that differ in more than
  values are two actions.

#### Calling one

```
mwt call ID [NAME=value …] --reason "why now" [--timeout 120] [--wait 60]
```

The action must be on; off, the agent asks with `mwt request ID`. The
card shows the script unchanged, each value under it: run it, with the
output sent back or shown to you first, or decline. An auto-approved one
runs at once, and the log keeps its values. The same action with the
same values as a call already waiting joins it. Exit statuses are those of
`mwt run` ([Host commands](#host-commands)); `mwt run ID` also calls an
action with no parameters.

A card is carried out only under what it was asked under
(`Server.HostRuns.still/2`). How a saved command runs (its script, folder,
confinement and the grants it runs with) is fixed into its card as it is
asked, and the card says it. An action turned off, out of time or removed
refuses the calls waiting on it; an edit of what it runs refuses them too,
rather than running the old script under the new grant (`Grant.definition/1`).
*Run* looks again before anything runs or is sent, deciding the call
again (`Policy.decide/3`): the action still on, each other resource it
goes through still granted (the network of a request's host, the
credentials a saved command runs with), nothing it goes through locked,
no host blocked, the VM not isolated. Refused, nothing
runs, the card says why, and the agent hears it was refused, not declined
(exit 121).

#### Proposing one

```
mwt propose commands --name NAME --for "what it does, any time it runs" \
    [--param 'NAME:shape:what it is' …] [--dir DIR] --reason "why you need it" -- SCRIPT
```

- It is saved at once, off and to review, as every grant an agent
  proposes is ([Proposed grants](#proposed-grants)), and confined, as an
  action you add starts. Its page shows the script, folder, parameters
  and hints; *Accept and enable* turns it on, asking each time, for the
  agent's `--minutes` (60 by default). The agent hears its id and how to
  call it.
- It needs nothing else to be on. The word after `mwt propose` says
  which resource it goes under: `commands`, your machine, for a saved
  command, or a credential for a request
  ([Request actions](#request-actions)).
- Agents are told to design one for whoever approves it: one job, a name
  that says it, the fewest parameters of the narrowest shapes, a script
  read at a glance, nothing that changes anything unless that is its job,
  raw output to work on in the VM.
- *Save as an action*, on the card of an ad-hoc run, opens the same form
  with the command as sent, to turn what varies into parameters.
  `--suggest-save` on `mwt run` still leads the card with it; agents are
  told to propose instead.

#### Editing

Every grant and action but the built-in ones is edited on its page, in
its *Settings*: the form it was added with, in place, checked as adding
checks it, kept with *Save* and put back with *Cancel*. Saving *When MWT
starts* applies it now too, as it always did. An edit keeps
its id, its credential, placeholder and value (replaced on its page), its
kind, the resource it is over, and its state, duration, approval mode
and start setting. An edit to one that is auto-approved
applies to the next use without asking: the form says so. An edit to
how a token grant's value is made (its mint, per host or not, how long a
value is kept, the header its ID token travels in; `Grant.how_made/1`) is
its credential's, for every grant over it, and drops what MWT minted and
made the old way: the next use mints again, and a mint under way as you edit
keeps nothing, the requests waiting on it answered `mwt_no_value`. An edit
to what an action runs or sends refuses the calls still waiting on it.
The log records the edit.

<a id="request-actions"></a>

### Request actions

A request action is a grant over a credential, listed under it: one
HTTP request MWT sends itself, with the credential's real value
(`MWTClient.Sandbox.SavedRequest`):

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
- **The URL** is `https://` to a host written out, on the usual port,
  with no user or `#` part. Parameters go in the path or the query as `$NAME`, never the host,
  each percent-encoded where it sits; a `word` keeps its `/` in the path,
  so `$REPO` can be `owner/name`.
- **Headers are fixed**, with no parameters. `{token}` stands for the real
  value where the service takes it (`Authorization: Bearer {token}`). The
  values the credential's adapter makes from it may stand there too:
  `{id_token}`, the ID token the Google login's mint prints beside its
  value; `{signed_jwt}`, a JWT signed as the action's one account (*May
  sign as*, `Grant.signs_as`), or `{signed_jwt:ACCOUNT}` naming one of its
  accounts. One header at least carries one of them; saving refuses an
  `{id_token}` or `{signed_jwt}` on a credential that isn't Google's, and
  an account the action doesn't name. MWT writes `Host`, `Content-Length`
  and the like. A new action starts with the headers its credential's
  preset gave.
- **A signed JWT is made for the call** (`HostRuns`' `fetch_and_send/5`):
  once the credential's value is at hand, MWT asks IAM Credentials'
  `signJwt` to sign, as that account, claims with `iss` and `sub` the
  account, `aud` the call's URL without its query
  (`SavedRequest.audience/1`), valid one hour
  (`Adapter.Google.sign_jwt/4`, the optional `sign_jwt/4` of
  `MWTClient.Sandbox.Adapter`). Your login needs *Service Account Token
  Creator* on the account; Google's refusal ends the call, saying so. The
  JWT is used for this call only, never kept.
- **The body** is JSON. A parameter in it is a whole value, `"$TITLE"`,
  never part of a longer string or a key, so a value can't change the
  body's shape or a query written inside a string. A `number` alone goes
  in as a number. Every parameter appears in the URL or the body.
- **The call's card** shows the request as it will go, every value in place
  and the token as `[GitHub's token]` (the ID token as `[GitHub's ID
  token]`, a JWT as `[a JWT signed as ACCOUNT]`), the values apart, and
  who sends it.
  *Run* sends it: nothing to stop, no output to see first.
- **Sending, through MWT's proxy** (`MWTClient.Sandbox.Egress.FixedCall`),
  as the VM's own requests go: MWT builds the request with a placeholder
  made for this call alone where each mark is (`SavedRequest.build/3`),
  opens a connection to itself on the loopback and serves the other end
  with the proxy's own code (`Egress.Tcp.run/3`), marked with the call
  (the `:fixed` option, which nothing in the VM can set). From there it
  is the VM's path: the host resolved and its address checked (a host on
  the Internet goes only to a public address; this machine and reserved
  addresses never), the firewall, TLS to the service, the values put in
  where the marks were, the answer read, the exchange kept, and its line
  in the log labelled *Fixed call · NAME*. The server decides it by the
  call again as it leaves (`:authorize_fixed`): still there as approved,
  still allowed, the request the one it builds. No redirects, no
  retries; 30 s by default (`--timeout`, up to 300). With no value set, a
  mint that fails, an `{id_token}` whose mint printed none, or a JWT
  Google wouldn't sign, it doesn't go, and the agent hears why. A network
  with a way out of its own (an anchor) isn't followed: the connection
  goes wherever this machine routes it.
- **What comes back:** the body's first 256 KiB on stdout; an answer
  that echoes a value the call sent (the token, the ID token, a JWT) is
  cut there, as the VM's own requests' are; status and host on stderr. `mwt call` exits 0 for a 2xx, 22 for any other status
  (as `curl --fail`), 124 on timeout, 121 when it couldn't be sent. The log
  keeps the status, never the body.
- **Checked at each call,** and again as it is sent, before its value is
  fetched and once the value is at hand: the action must still be on and
  its host's network still granted, or the call is refused and the agent
  told why. Once the value is at hand, the action must also still sign as
  each account the call names (`SavedRequest.accounts/2`).
- **Judged as a use of its credential and its host's network**
  ([The rule](#the-rule)). Over the credential, the action itself gives
  it, and so does a token grant over the credential listing the host,
  the most permissive counting; over the network, a grant covering the
  host, usually the Internet's. It goes unasked only if both let it
  through unasked; otherwise one card names each grant that asks. A lock
  on the credential or the network, or the host blocked, refuses the
  call.

<a id="when-mwt-starts"></a>

### When MWT starts

Every grant and action has a setting for the state it is in when MWT
starts or unlocks (`Grant.start`):

| Setting                       | At each start                                                                                         |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Off** (`:off`)              | Off: it gives nothing. The default. You, or an agent's ask, turn it on for a time.                   |
| **On, ask** (`:on`)           | On until turned off. Every use still waits for you.                                                   |
| **On, auto** (`:auto`)        | On until turned off, every use through without asking, still logged. For what you fully trust.      |

- Not every grant takes all three (`Grant.starts/1`): a grant to review
  takes Off only; one that always asks, no *On, auto*. *On, auto* asks you
  to confirm.
- Choosing a setting puts the grant in that state at once and at every
  start; in between its switch, duration and approval mode change it.
  Every start begins from the settings: a grant left on goes back to its
  setting, and every allowance ends with the session. A setting saved as
  Disabled or *Off, refusing* is Off.
- A row or card whose setting turns it on says *Starts on*; its Ask/Auto
  switch shows how uses are approved.

<a id="approvals"></a>

### Approvals

Every use a grant that is on covers waits for you, unless an allowance
covers it: a request carrying a placeholder, a request or connection
through a network grant ([Private networks](#private-networks)), a call
of an action, a change through `mwt-change`. No rules decide by method
or path on their own: what a request does depends on the API, and
guessing per provider doesn't generalize; a grant you narrow by
[attributes](#attributes) says it for one credential. The shortcuts are
allowances (`MWTClient.Sandbox.Allowance`), added on purpose:

- **Allow similar:** uses like this one (the same method and endpoint, the
  same GraphQL operation, the same address and port, the same item of
  MWT's), for 10 minutes, 1 hour or while the grant stays on. For a
  request the header carrying the credential is part of it, shown among
  the facts; other headers aren't, as they change between runs of one
  tool. A method override is refused for every request
  ([Each intercepted request](#each-intercepted-request)), and the value
  goes only in a carrier.
- **Allow similar, any id:** the same, with each segment of the path that
  looks like an id (digits, a UUID, long hex, a long token holding a
  digit) as `*`, so one allowance covers the endpoint whatever its ids:
  `GET api.github.com/repos/o/r/pulls/*` (`Allowance.widen/1`). Offered
  only where the path has such a segment.
- **Allow every use:** everything the grant covers, as long; also
  *Auto-approve* ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)).
- An allowance added while cards wait settles those it would have let
  through had it been there when they were asked, no others
  (`Policy.settles?/3`): no allowance settles an add of MWT's tools past
  the hour's limit. The card you decide goes by your decision.
- For GraphQL, similar is the same operation in the same document, by the
  whole SHA-256 of its tokens: the agent writes the documents, and a
  shorter digest would let it find a second document sharing one.
- Past its time an allowance covers nothing: the clock decides, across a
  restart or a suspend too.

A card's choices: *Allow once*; *Allow for a while*, one menu with the
allowances (this one's pattern written out, any id where it applies, and
every use), each for 10 minutes, 1 hour or while the grant stays on;
deny; *Deny and turn off*, which turns the grant off: it gives nothing
from then on, though another grant on may still give the same use
([Overlaps](#overlaps)). **Activations**, agents asking for a
grant (`mwt request`), wait in the same queue: you choose how long it
stays on and whether each use still asks ([Agent channel](#agent-channel)).

**One card for several grants.** Where more than one grant asks about one
use ([The rule](#the-rule)), one card answers for all of them
(`Approval.also`, `Approval.grant_ids/1`): its facts say *Asking* (each
grant that asked), *Through* (the network grant the request came
through) and *Let through by* (those that said yes).

- *Allow once* lets this use through every grant on the card.
- *Allow for a while* lists each grant that asked, each with a checkbox,
  all ticked, and adds the allowance to those still ticked: one you untick
  gets none, and asks again next time. It is offered only when none of
  them always asks.
- *Deny and turn off* becomes one button per grant, *Deny, turn X off*:
  you choose which one turns off.
- An allowance added on one of them settles a waiting card several asked
  about only once each of its grants allows it.

**A decision answers only what its card shows.** A second ask joins a
waiting card only when it is the very same: a request as MWT read it,
every header in order ([Each intercepted request](#each-intercepted-request));
a command, an action's call or a call of MWT's tools compared whole, by
SHA-256. A request whose body MWT holds only the start of joins none: two
that differ only past it would share one card.

**Every card is drawn the same way,** each thing once: who asked and for
which grants, with the time left, on one line; what would happen, as its
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
  MWT's tool calls go through; an action's call runs at once, a command's
  output straight to the agent, shown running on the Approvals page with
  Stop and logged as auto-approved with its exit status.
- **Duration:** 15 min, 1 h, 4 h or until turned off. Picked while on, it
  counts again from now: more time, or less.
- Commands agents write takes neither Auto nor an allowance: every run
  waits for you ([Commands agents write](#ask-to-run-commands)).

<a id="ceiling"></a>

### No "never allow without asking"

There was one, under *Advanced* (`Grant.ceiling`, 2026-11-17 to
2026-11-25): every use a card you allowed once, no allowance or Auto
covering one. It said what *Ask* says, but for the cards' *Allow for a
while*, which you choose on each card anyway, so it went: *Ask* asks for
each use until you let a card allow more. A grant saved with it keeps
asking (`Grant.upgrade/1` drops the field); nothing it had goes through
unasked.

<a id="proposed-grants"></a>

### Proposed resources and grants

An agent that knows what its work needs proposes it, instead of
describing it with `mwt request --need`, the way you add things: a
resource first, then grants over it, each proposed and reviewed apart.

```
mwt propose credential --name NAME --for "what it is" [--preset ID [--fill NAME=VALUE …]] \
    [--env VAR …] [--file-env VAR …] [--git] [--mint 'COMMAND' [--keep-minutes N]] \
    [--login-file [--id-token-header HEADER]] [--metadata-project PROJECT [--metadata-account EMAIL]] \
    [--set FIELD=VALUE …] --reason "why"
mwt propose network --name NAME --for "what it is" --destination 'HOST_OR_RANGE:PORTS' [--destination …] \
    [--resolver ADDRESS] [--via INTERFACE] [--set FIELD=VALUE …] --reason "why"
mwt propose grant --over RESOURCE --name NAME --for "what it gives" [--preset ID [--fill NAME=VALUE …]] \
    [--host HOST …] [--carrier HEADER …] [--sign-as ACCOUNT …] [--destination …] [--set FIELD=VALUE …] --reason "why"
mwt propose commands|CREDENTIAL --name … --for … …   an action (Proposing one, Request actions)
```

- **Any field, checked as the form checks yours.** Each kind starts from
  a preset of what it makes, when it names one; its options set their
  fields over the preset's, and `--set FIELD=VALUE` any field of its form
  over both (`MWTClient.Sandbox.FormFields`), so an agent can propose a
  GitHub App with no preset at all (`--set adapter=github --set app_id=…
  --set installation_id=… --mint '…'`); `--fill` fills a preset's
  blanks. The result is the form's fields (`MWTClient.Sandbox.Proposal.attrs/3`),
  built as yours are (`Server.Resources.build_credential/3`,
  `build_network/1`, `Server.Grants.build_new/4`); an option or a field
  the kind doesn't have, a field that is yours (the value, start,
  state, *Covers requests MWT can't read*, your machine,
  how a saved command runs), or one that wouldn't pass, is refused before
  anything is saved, naming the option or field and the fields there are.
  `mwt propose token`, a credential and a grant in one until 2026-11-25,
  is refused with the two commands to use instead.
- **A grant may be over a resource still to review.** The agent sends
  both at once; you accept the resource first, on its page, and a grant
  over it can't be accepted or turned on until you have
  (`Server.Grants.turn_on_refusal/2`): its review says which resource,
  with a link.
- **Saved at once, to review** (`proposal` on the grant, credential or
  network: who proposed it, from which thread, why, for how long, when,
  and when you reviewed it). A grant is off, never enabled on startup
  (`Grant.starts/1` offers only Off), and nothing turns it on until you
  accept it: its switch says to review it first, and an agent's `mwt
  request` for it makes a card that only leads to its page. `mwt grants`
  says it waits for you. Nothing proposed carries a value, an approval
  mode or a start setting. A proposed credential needs no value to be
  accepted: you paste it whenever you have it, and until then every use
  of it is refused and no grant over it turns on.
- **Tagged** *Proposed by AGENT* wherever it shows, and *To review* until
  you accept it (*Proposed · to review* on the *Resources* tab). The
  Grants page says how many wait, grants and resources apart, *To review*
  is a status of All grants, and Overview counts them. The tag stays once
  you accept it.
- **A resource's page** leads with its review: the agent and its reason,
  for a stored credential that its value is yours to paste, for a minted
  one the command the agent wrote and the hints for it (it runs as you,
  outside any bubble, each time a value is needed), and *Accept* and
  *Decline* (`Sandbox.review_resource/3`, against the revision the page
  showed). Its card on the Approvals page leads there.
- **A grant's page** leads with the review: the agent's reason and
  thread, the hints for a script, and *Accept and enable for N* (the time
  the agent asked; its credential needs its value first), *Accept, keep
  off*, *Edit* and *Remove*. Editing keeps it to review. Accepted, it is
  yours, as any other.
- **The agent waits** as for `mwt request`: exit 0 once you accept a
  resource, or a grant and it is on, 2 while it waits (`mwt wait ID`), 3
  if you decline its card, which removes it; removing it from its page
  before you accept it says the same. Declining a resource removes it
  with every grant and action proposed over it, their agents hearing so.
  Its ask gives up after 30 minutes and the proposal stays, to review.
  Proposing again under the same name while it waits changes it in place
  and joins the same ask.
- **At most 20** wait for review at once, resources and grants together;
  the 21st is refused.

<a id="finding-out-why"></a>

### Finding out why

When a use fails, the agent should find out why from MWT and tell you
exactly what to change, rather than guess (an expired login, a
provider's IAM) or try again. Most tools hide MWT's answer: a client
library turns a refusal's JSON into "403 Forbidden". So the agent asks
(`MWTClient.Sandbox.Explain`, on the agent channel):

- **`mwt why URL [--method M] [--with CREDENTIAL]`** decides a request not
  made yet, as it would be decided now: each resource it goes through,
  the grants over it that cover it and what each says, the locks and
  host limits, the result, and what would change it. A dry run is
  the very decision a request would meet (`Policy.decide/3`): it sends
  nothing, resolves no name, waits on no one, makes no card, and is no use
  of any grant. Without `--with`, the request carries no credential. Its
  answer starts "Dry run, with the grants as they are now: nothing was
  sent, no card was made, no grant was used."
- **`mwt why --recent`** lists the last 50 decisions on this VM's
  requests since it started, newest first: refused, blocked, denied,
  timed out, and the cards still waiting, each with its id.
- **Each refused request keeps its decision.** A request MWT read and
  refused records how it was decided at that moment
  (`MWTClient.Sandbox.Explain.record/2`, from what the decision read),
  kept in its event's details as *The decision, as made*, and the refusal
  the agent gets names it: `"decision": "event-…"` and
  `"why": "mwt why event-…"` beside its code and error
  (`Server.Values.kept_refusal/3`).
- **`mwt why ID`** (`event-…` or `approval-…`, from that list or a
  refusal) explains one. An event gives back its decision as made, *As
  decided then*, whatever changed since; only one without it (from
  before decisions were kept) is decided again, with the grants as they
  are now, and says it is a dry run. A card is explained with the grants
  as they are now.
- **`mwt why HOST[:PORT]`** stays as it was, for destinations
  ([Agent channel](#agent-channel)).
- **Decide a request without sending it**, folded under the console, is
  the same engine for you: a URL, a method and a credential, decided and
  dropped, never logged or sent ([The console](#console)).

<a id="console"></a>

### The console

The Grants page's *Live Test* runs what you type in the VM as an agent's
command would run (`MWTClient.Sandbox.Console`, through `msb exec`): as
the user agents run as, in `/work`, in a login shell, its errors with its
output. *With credential* wraps it in `mwt exec ID`, as an agent runs a
command with one: the command gets that credential's placeholders, never
its value, and the grants over it decide what each request may carry
out. *HTTP request* builds the `curl -sS -i` command for a
method, URL, headers and body, the credential's `Authorization` (or the
headers its service expects) taken from its token file, and shows it
before it runs. *Try it as the VM*, on a grant's or a credential's page,
opens it with that credential.

The Overview's *Terminal* is the same console as a terminal shows it
(`MWTClientWeb.SandboxLive.Terminal`): a prompt with the folder, Enter
runs the line, ↑ and ↓ bring back what ran, Ctrl+C stops a run (or drops
the line; with text selected it copies), Ctrl+L or `clear` empties the
screen. Each command starts in the folder the last one ended in, which
the script prints as its shell exits, and which the page keeps as you
leave. Its screen and the Live Test's history are the same runs. What
ran keeps its colours (`MWTClientWeb.Ansi`, drawn in the app's palette)
and a line a carriage return went back over shows as it ended. It is a
line at a time: the output shows once the command ends, and nothing reads
what you type while it runs, so no editor or prompt; Zed is for those.

- **What you see**: what it printed (escaped, a terminal's colours
  dropped, anything else that doesn't show written out; at most 256 KiB),
  its exit status, or that it ran out of time (60 s) or printed too much;
  and what MWT decided about each request while it ran, from the activity
  log. A request waiting for your approval shows there with *Allow once*
  and *Deny*. The proxy can't tell an agent's requests from the console's:
  an agent's of the same moments show too.
- **What it reaches** is what an agent's would: through MWT, decided by
  your grants as they are, auto-approved ones going through. It is a
  command of yours: nothing asks about the command itself.
- **What it keeps**: a line in the activity log per run (`You ran in the
  VM, as ID: COMMAND (exit N)`), never its output; and its *History*
  (`MWTClient.Sandbox.ConsoleHistory`, kept by the sandbox's server):
  each run with what it printed, newest first, ten a page, searched by
  command or credential. The newest opens when it ends; any opens to
  show what it printed and what MWT decided while it ran (read again
  from the activity log, from its start to a moment after its end), and
  *Run again* runs it as it ran. It is kept in memory only, at most 100
  runs and 8 MiB of output, the oldest going first, until the identity
  locks, MWT stops or the server fails; *Clear* forgets it. The output is
  the VM's, which may hold what a service answered, so it never reaches
  the disk; the activity log, which does, keeps only the line.
- **What it refuses**: a command holding the real value of a credential
  of yours (what you type goes into the VM, where agents can read it:
  speak as the credential instead); anything while the VM is stopped.
  *Stop* ends the wait here, and the run is kept as stopped (`(stopped
  from MWT)` in the log); what it started in the VM may still finish
  there. A refused command is no run: the form says why, and the history
  doesn't keep it.

What an explanation holds is built from a list of what may be shown,
never by leaving things out of the activity log: the VM's own uses
(method, host, port, path and query, made safe to show by `Shown`), each
grant's say by its name and id and why (its state, an allowance in force
for this use), the locks, a host a network blocks,
whether the VM is isolated, and the decision. It never holds a real value or a placeholder (a
credential shows by its name), a body, a header's value, a command's
output, the firewall's workings (which rule saw what), or anything but
this VM's uses since it started. Not yet: `mwt why -- curl …`, and the
attributes read from a body, which a dry run without one leaves unknown.

<a id="the-grants-page"></a>

### The Grants page

Three tabs, and a page for each grant and each resource. One shape
throughout: a page is sections one under the other (`page_section`),
what applies now apart from what it is, the common fields first and the
rest under *Advanced*, whose summary says what of it is set; a tag is one
of a few (`badge`); a preset is chosen from a list that says what each
one sets (`preset_picker`).

The tabs are *Resources*, *Grants* and *Live Test*, in that order, what
grants are over first; *Grants* is the one shown when the page opens.

1. **Grants**: every grant in one list, 20 rows a page, each with its
   time left or last use, duration, Ask or Auto, and switch, all
   changeable there, its resource as a link, its kind (*Open use* or
   *Fixed call*), *Runs on host* where a command runs there, and at most
   one tag of its own (*Proposed* or
   *Starts on*); one to review has *Review* in place of its controls.
   MWT's own grants (the Internet's, MWT's tools) carry no tag for it:
   their page says they can't be removed. A bar over it narrows it: a
   status (*On*, the default, *Off*, *To review*, *All*, each with how
   many), a search over each one's name, purpose, type, hosts,
   variables, destinations, script, folder and parameters (every word,
   any case), and *Labels*, the tags the rows show, picked in a
   dropdown, each with how many rows picking it shows: its kind (*Open
   use*, *Fixed call*), *Starts on*, *Runs on host*, *Proposed* and the
   resource it is over. A grant needs one label picked from each group
   that has any (two resources: a grant over either); each picked label
   shows as a chip that drops it. *Clear* puts it all back.
   The list has one order whatever the bar says: what ends soonest
   first, then what is on until off, then the rest by last use. The search and filters are kept as you leave.
   Nothing on, it says so and offers every grant. *Add grant*, on the
   bar, starts from the resource: pick a credential, a network or your
   machine (a saved command), or add a credential or network there, which
   comes back to the grant over it. Over a credential, its kind comes
   next, each said in a line: open use (then the grant presets for its
   service, when it has some, or *By hand*) or a fixed call (a request
   MWT sends). Over the list, one strip says what waits for you:
   resources and grants agents proposed, and what is locked.
2. **Resources**: every resource in one list, 20 a page: each
   credential with `mwt exec ID` and how its value is made, each network,
   the Internet first, your machine and MWT's tools, each with how many
   grants are over it and how many are on, its last use, and *Lock*
   (*Locked* and *Unlock* once locked; [Locks](#locks)). A bar narrows it
   by kind (*Credentials*, *Networks*, *Others*), state (*Open*,
   *Locked*, *To review*, *No grant*) and words; *Add credential* (a
   preset, or *By hand*, first) and *Add network* are on it. One an
   agent proposed shows *Proposed · to review*.
3. **Live Test**: a command run in the VM as an agent's would be, and
   the history of those runs, with what each printed
   ([The console](#console)); and, folded, a request decided without
   being sent ([Finding out why](#finding-out-why)).
4. **A grant's page**: its head (name, over a credential its kind and
   where it runs, its resource as a link, what it is for); for one an agent proposed, the
   review first ([Proposed resources and grants](#proposed-grants)); then
   two columns. The main one is its **Settings**, a panel holding its form
   (the add form's, the same component), *When MWT starts* and, under
   *Advanced*, what narrows it, with *Save*, *Cancel* and *Remove* at
   its foot; and *Remove* under it. The side one is what it is now:
   **Now** (its switch, time left, duration and Ask or Auto, each change
   at once; what holds it back: its resource locked, without its value,
   or still to review; another grant that is on and covers the same uses,
   [Overlaps](#overlaps); what it allows without asking for now), its
   kind in a line, with the line agents run and *Try it as the VM*, its
   last five uses, and, folded, what the VM gets. A built-in grant's
   settings are only when it starts and whether it always asks.
5. **A resource's page**: its head (name, kind, service, what it is,
   *Lock*); for one an agent proposed, its review; then the same two
   columns. The main one holds the **grants over it**, open use and fixed
   calls together, each with its switch, and *Add grant*; a network's
   host limits ([Host limits](#host-lists)); its **Settings** in a panel,
   the common fields first and the rest under *Advanced*, with *Save* and
   *Cancel*; and *Remove*. The side one: a credential's **value** (stored,
   none yet with the field to paste it, or the mint command, *On your
   machine*), its **use** (how many grants, how many on, the last use,
   its lock, *Try it as the VM*), and what the VM gets (`mwt exec ID`, its
   variables, git) or, for a network, what it reaches.

<a id="export"></a>

### Export

An export (`MWTClient.Transfer`, the transfer page, a `.mwtexport` file
sealed with your password) holds a section *Agent sandbox grants*
(`MWTClient.Sandbox.Transfer`, key `sandbox`), so a setup moves to
another machine or comes back from a backup:

- your credentials, how each value is made and how tools find it; their
  stored values only when you tick *Include stored credential values* as
  you export (`Transfer.export(…, values: true)`), off by default; minted
  values never, since they come from logins on the machine that mints
  them;
- your grants and actions as you defined them, with their start
  settings and attributes, the grants over one host of a
  network among them; a grant an agent proposed that you haven't
  reviewed is left out;
- your networks with their host limits, and the Internet's host limits,
  not the Internet itself, which is MWT's;
- the built-in grants' start settings and the hosts the Internet's leaves out, not their
  definitions, which are MWT's;
- your presets, *This machine, for agents*, your way of working, and the
  folders confined commands may read, as paths.

It leaves out what lasts a session (states, allowances, locks), so grants
come in as their start settings say, off unless a setting turns them on;
and the activity log, handoffs, the VM's disks and the CA.

**Importing** checks the section first and changes nothing
(`Sandbox.Transfer.prepare/2`): ids of the shape MWT gives, a network
that isn't the Internet, a command grant with its script. Merging
(`Server.Transfers`) keeps everything there: the same id with the same
definition changes nothing, so importing twice is harmless; the same id
with another definition comes in under a new id ending in `-imported`,
to review, as a proposal waits for you. A network whose id you have
stays yours. Values come only for the credentials that come in, a preset
is written only where none has its name, and the settings only where
yours are empty. Replacing puts the file's grants and networks in place
of yours. A file from before networks holds host lists, in its grants or
in the built-in Internet's settings: their Block and Ask entries become
the network's Blocked list and their Auto entries grants over those
hosts, as saved state does as MWT starts (`Network.migrate/2`); merged
again, such a file's Auto entries come in again, under new ids.
Merging makes new placeholders for each credential that comes in, in the
shape of its old one, since one from a file could be one of yours;
replacing keeps the section's, since replacing is also how a failed
import puts back what was there. `docs/transfer.md` has the rest.

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

### Commands agents write

A command an agent writes is open use of host commands, under a grant
built in: *Commands agents write* (`agent-commands`,
`Grant.agent_commands/0`). While it is on, agents may ask to run one on
your machine, and you read and approve every run, its exact text, once
(`MWTClient.Sandbox.Server.HostRuns`).

- **Every run asks, whatever is set** (`Grant.always_asks?/1`): it starts
  on or off, never auto-approved, and takes no allowance; *Auto* isn't
  offered, and a request for it is refused (`:always_asks`). A command
  the agent wrote can do anything you can, and MWT sees nothing of it once
  it runs. Off, agents can't ask (`mwt request agent-commands`).
- **No credential's value, ever.** A value handed to text the agent wrote
  is a value given to the agent: a job that needs one is a saved command.
- **Locking host commands refuses them at once** ([Locks](#locks)): `mwt
  run` is refused, saying you locked it, what waited is refused, and the
  commands running are stopped, as isolating does. MWT's own git, sync
  and workspace go on: they are MWT's tools.
- **Saved commands are grants over host commands:** your script, in your
  folder, with parameters it reads as variables, which agents call by id
  (`mwt call ID NAME=value`; `mwt run ID` also runs one without
  parameters) and propose with `mwt propose commands`; see
  [Grants and actions](#grants-and-actions). Each is on or off, for a
  time, asking or auto-approving, and may run
  [confined](#confined-commands), with the values of the credentials it
  names, which it covers itself. The files it runs are
  [pinned](#pinned-files).
- **Save as an action,** on the card of a run, opens the add form filled
  in: the script, the folder it would run in, a name (the agent's
  suggestion, else the command's first words) and what it's for (the
  agent's `--save-for`, else empty for you to write; never the agent's
  reason, which is about this run). Saving doesn't decide the card. The
  action turns on for 1 h, asking each time (one set to start enabled
  is on already), and the agent hears, with this run's answer, to call it
  by id next time.
- **An agent may suggest the save** with `--suggest-save NAME --save-for
  "what it does"`: the reason says why this run, the description what the
  command is for any time it runs, so `--suggest-save` alone is refused.
  The card then leads with the save. Agents are told to `mwt propose`
  instead.
- **The same text as an action:** a run whose script and folder match a
  saved command's gets a hint saying so, and the agent hears to call that
  one by id.
- **From what is saved:** Ask to run commands, the grant these asks went
  through until 2026-11-24 (`commands`, before it `any-command`), goes as
  MWT starts, Commands agents write taking its place
  (`Grant.upgrade_all/1`). An ask naming either id, or `agent-commands`,
  is a command the agent writes, as one naming none is
  (`Grant.former_command_ids/0`).
- **Small commands.** A card should take seconds to read. Agents are told
  to send the smallest command that gets what they need, to run on your
  machine only what must run there, and to bring the raw output back and
  work on it in the VM. A script over 5 lines, or with 3 pipes or more,
  gets a hint that it is long. *Ask for a simpler one* declines it and
  tells the agent to send the smallest command that gets the raw data.

### Pinned files

What you approve is each file a command runs as it was when you looked,
not whatever it holds when it runs (`MWTClient.Sandbox.Pins`): a command's
text shows `./deploy.sh`, not what that file holds, and a pull, an edit or
an earlier command the agent wrote can change it between your look and
the run.

- **Which files:** those the text names (`HostCommand.files_run/1`): a
  path run as a command, one `source`d, one a shell or an interpreter is
  given (`bash x.sh`, `python3 tool.py`), resolved in its folder, with
  `$MWT_WORKSPACE` and `~` put in. Not pinned, and said so: what a file
  runs in turn, a file it only reads, a path holding another variable,
  and a change in the instant between the check and the shell opening it.
- **On a card:** each file shows, as it is now, under *What this card
  can't show you*: the one the VM wrote (`from-vm`) first and loudest,
  then the others, and code downloaded and run (`curl … | sh`). Just
  before the command runs, MWT hashes each file again: one changed or
  gone runs nothing, the card reads *refused: a file it runs changed
  after you approved it*, and the agent hears to ask again.
- **On a saved command:** its files are pinned as you save or edit it. A
  run that finds one changed asks, whatever its setting, its card showing
  the lines that changed; running it pins what is there now, and the next
  runs as set. One saved before pins is pinned at its first run.

### Asking

```
mwt host                                       your machine, as agents see it
mwt run --reason "…" [--dir DIR] [--timeout 120] [--wait 60] [--suggest-save NAME --save-for "…"] -- COMMAND [ARG…]
mwt run --reason "…" [options] <<'EOF'            the script from stdin
…
EOF
mwt wait RUN_ID [--wait 60]
```

- **Options go before `--`, the command after it.** A word before `--`
  names a saved command to run (`mwt run ID`); `commands` and
  `any-command`, the ids Ask to run commands had, still work and name
  none. A saved command takes no text: sent one, it is refused, saying to
  `mwt call` it.
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

A command is an approval of its own kind, in the same queue, named as
the agent's own or by its saved command, and drawn apart (red, a
terminal icon; a saved command's violet):

- **Facts:** the script in full, with a copy button; who it runs as; the
  folder and what it is (a shared folder, your home folder, the action's
  own); the time limit.
- **Hints,** from the script's text and marked as hints, not a review: it
  runs a script file, whose content the card doesn't show; it downloads
  code and runs it; it uses `sudo`; it deletes recursively (`rm -rf`); it
  mixes alphabets; it is long; a grant already covers a host or tool it
  uses.
- **The agent's reason,** as a claim.
- **Choices:** *Run once, as you*, with the output sent to the agent or
  shown to you first; decline; *Ask for a simpler one*; for a command the
  agent wrote, *Save as an action*. No "allow similar": each command runs
  once, as you, outside the VM. An action turned on with Auto-approve runs
  without a card ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)).
- Commands are decided on the Approvals page only, where the card shows
  the script in full; the Overview counts them.

### Running

- `bash -lc SCRIPT` as you, in the directory, with stdin from `/dev/null`,
  under `timeout`: TERM at the limit, KILL 5 seconds later, to its whole
  process group.
- **A run ends when its shell does,** at its limit, or when you stop it,
  whatever it started. The command writes into a pipe of its own, which a
  `cat` in its process group copies to MWT, and MWT looks every 200 ms
  whether `timeout` is still there. Once it isn't, what the command left
  in its group (a server started with `&`) gets half a second, then is
  killed, and the run reports the shell's status: a background job doesn't
  hold the run open past its limit. A process that left the group
  (`setsid`, `ssh -f`) is out of reach without a cgroup: it goes on after
  the run, its output closed, so its next write fails, or ends it. In a
  [confined](#confined-commands) run it ends with the bubble.
- The directory on the card is a real path; the command starts there after
  `cd -P` and a check that the path still leads there. A folder swapped for
  a link since you looked runs nothing, and the agent gets exit 126.
- The environment is MWT's own, without MWT's and the BEAM's variables
  (`RELEASE_*`, `ERL_*`, `ELIXIR_*`, `MIX_*`, `PHX_*`, `MWT_*`,
  `SECRET_KEY_BASE`, `PORT`…), plus an action's parameters; the login
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
parameter used carelessly. So a command action can run **confined**
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
- **`with`: the credentials whose real values it gets**, under the same
  variables the VM sees their placeholders in, and in their token files,
  `/mnt/mwt/tokens/<credential>`, written from a variable unset before the
  script runs, so a script reads `$SOME_TOKEN` the same way on both sides.
  The saved command covers them: no token grant over them has a say, and
  a lock on one refuses the run ([The rule](#the-rule)). Each
  value is fetched (minted where it is) before the run starts; one that
  can't be ends the run, and the agent hears why.

The time limit stays outside `bwrap`, so it still ends the whole command.
There is no silent fallback: where `bwrap` can't make the bubble (on
Ubuntu, a `bwrap` without MWT's AppArmor profile may get no user
namespaces), a confined command doesn't run and says why. Its card says
*Runs: Confined, with the value of: X*, or *Runs: As you*, with what that
puts in reach; the grant's page says the same. New saved commands start
confined; one saved before confinement existed runs as you until you tick
*Runs confined* on its form. **Mint commands still run as you**: they are
the one place that touches your login. Commands agents write aren't
confined.

### What the agent hears

`mwt run`, `mwt call` of a command action, and `mwt wait` on either exit
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
mwt help [TOPIC]                             this list, or a guide on what only some tasks need
mwt grants                                   every grant: id, what it is for, how to use it, state
mwt exec CREDENTIAL -- COMMAND [ARG…]        a command in the VM speaking as a credential (Grant kinds, Credentials)
mwt request GRANT_ID --reason "…" [--minutes 60] [--wait 60]
mwt request --need "the access, and the host" --reason "…" [--minutes 60]
mwt wait ID [--wait 60]                      an earlier ask, run, call, or change to MWT's items
mwt call ID [NAME=value …] --reason "…"      an action, by id (Grants and actions)
mwt propose credential|network --name … --for … …      a resource, saved for you to review (Proposed resources and grants)
mwt propose grant --over RESOURCE --name … --for … …   a grant over it, saved off for you to review
                                             each takes --preset ID, --fill NAME=VALUE, --set FIELD=VALUE
mwt propose commands --name … --for … [--param …] [--dir DIR] --reason "…" -- 'SCRIPT'
mwt propose CREDENTIAL --name … --for … --method … --url … [--param …] [--header …] [--data …] --reason "…"
                                             an action, saved off for you to review (Grants and actions, Request actions)
mwt run --reason "…" -- COMMAND              a command you approve, no grant needed (Host commands)
mwt host                                     your machine, as agents see it (Host commands)
mwt why HOST[:PORT]                          which grant covers a destination, and why it isn't reached now
mwt why URL [--method M] [--with CREDENTIAL] how a request would be decided now, sending nothing (Finding out why)
mwt why --recent | ID                        the last decisions on this VM's requests, or one explained (Finding out why)
mwt ports                                    the VM's servers, and where they open on your machine
mwt mcp                                      MWT's tools over MCP, on stdio (MWT's tools for agents in the VM)
mwt project                                  where you are in a project (Projects and handoffs)
mwt worktree new TASK --from BASE | resume BRANCH | free     take, continue in, or free this slot (Worktree slots)
mwt handoff --title "…" [--body FILE] [--onto BASE] [--no-checks] | withdraw --reason "…"    (Handoffs)
mwt handoffs                                 the project's handoffs and what you did with them
mwt vm                                       which VM this is, and whether MWT runs it
```

The sections named tell the rest ([Grant kinds](#grant-kinds),
[Credentials](#credentials), [Finding out why](#finding-out-why),
[Grants and actions](#grants-and-actions), [Request actions](#request-actions),
[Host commands](#host-commands), [Servers in the VM, on your machine](#servers-in-the-vm-on-your-machine),
[MWT's tools](#mwt-tools-in-the-vm), [Projects and handoffs](#projects-and-handoffs),
[Worktree slots](#worktree-slots), [Handoffs](#handoffs)). The others:

- **`grants`** prints `/mnt/mwt/grants.md`
  (`MWTClient.Sandbox.Instructions`): first the rule in a few lines (a use
  needs a grant on for each resource it goes through, so a request
  carrying a credential needs one over its host's network too; a
  credential is used through `mwt exec CREDENTIAL`; a command the agent
  writes asks while Commands agents write is on; and `mwt why --recent` when a use fails), then
  each grant with its id, what it is for, how to use it, its state in
  words (on or off), `- only:` its
  [attributes](#attributes) and whether it covers requests MWT can't read,
  its approval, and `- overlaps:` the grants it may share uses with
  ([Overlaps](#overlaps)).
- **`request`** asks you to turn a grant on, by id or name, for
  `--minutes` (1 to 1440, 60 by default). It shows as an activation
  approval with the agent's reason, marked unverified, and who asked (the
  agent, its thread and folder, read from the processes above `mwt`, so
  also a claim). It waits up to `--wait` seconds (60 by default, 0 not at
  all, 600 at most), then says the ask is still waiting, with its id, and
  exits 2; the agent comes back with `mwt wait`. The ask stays 30 minutes.
  An ask for a grant whose resource is locked is refused at once, with
  no card, saying only you unlock it; one for a proposal you haven't
  reviewed makes a card that only leads to its page
  ([Proposed resources and grants](#proposed-grants)).
- An ask for a grant that doesn't exist yet (`--need`) offers "Set it
  up…", which opens the add dialog at its first step, the resource; a
  credential or network added from there comes back to the grant over
  it, and the new grant answers the ask and turns on.
  Asking again for the same grant joins the waiting ask; one waits per
  grant, ten in all. Turning the grant on yourself answers agents waiting
  for it.
- **`why HOST[:PORT]`** (`MWTClient.Sandbox.Why`) says, a line each, which
  grant covers a host or an address and why the VM doesn't reach it now:
  the firewall isolated the VM or blocks it; a network blocks it (asking
  for a grant won't change that); a token grant lists the name, or its
  credential's adapter implies it (a request carrying its placeholder
  needs it on, and a grant over the host's network too); a network grant
  covers it and is off (with the `mwt request` to send) or lists other
  ports; the Internet's grant is off; the address is
  private or reserved, which the Internet never opens; no grant covers it
  (with the `mwt request --need` to send). It reads the view the network
  path decides from, by the same rules (`Policy`), and looks up a name
  only when some grant names it. Agents are told to run it when a lookup
  or a connection fails, and `mwt why --recent` when a tool fails with a
  bare 403 ([Finding out why](#finding-out-why)).
- **`vm`** tells an old VM from the one MWT runs. MWT gives each VM it
  creates an id and records when, and from which image (`VM`'s `record`);
  the boot script writes the same at `/etc/mwt-vm`, which `mwt vm` sends
  for MWT to compare. Interactive login shells (Zed's terminals) print the
  answer in a line, dim, or red when it isn't the VM MWT runs; agents'
  shells print nothing. The Overview shows the same id.
- While the firewall has [isolated](#isolating) the VM, what acts
  (`request`, `run`, `call`, `propose`, `handoff`) is refused, saying so;
  `grants` and `vm` still answer. While a resource is [locked](#locks),
  what goes through it is refused (`mwt_locked`), saying asking won't
  change it: your machine for commands, saved commands, git, syncs and
  the workspace; MWT's tools for `mwt mcp`'s calls; a credential or a
  network for what uses it.

| Commands                                         | Exit statuses |
| ------------------------------------------------ | ------------- |
| `grants`, `request`, `propose`, `wait` on an ask | 0 the grant is on, 1 the ask was wrong, 2 still waiting for you, 3 declined or given up, 4 MWT isn't answering (locked or closed) |
| `project`, `worktree`, `handoff`, `handoffs`     | 0 done, 1 not done (the reason is printed), 4 MWT isn't answering |
| `vm`                                             | 0 this is the VM MWT runs, 1 there is no record to compare, 3 it isn't (or MWT's is stopped), 4 MWT isn't answering |
| `run`, `call`, `wait` on either                  | the command's own status, else 120 to 123 ([Host commands](#host-commands)); a request action 0 for a 2xx answer, 22 for any other |
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

Built in like the Internet's grant: always there, over MWT's tools, with
no value, no Edit, no Remove, and MWT's words. Each tool belongs to one.

| Grant        | Tools                                  | Starts, by default   |
| ------------ | -------------------------------------- | -------------------- |
| `mwt-read`   | `list_*` and `get_*`                   | On, auto             |
| `mwt-create` | `create_*` and `import_http_request`   | On, auto             |
| `mwt-change` | `update_*`                             | On, ask              |

- They are plain grants (`kind: :mwt`, `tools` saying which): a switch, a
  duration, Ask each time or Auto-approve, and a start setting, changed as
  for any other; the table says only how they start. The projects' Git has
  three more of the same kind, `git-fetch`, `git-fetch-remote` and
  `git-handoff` ([Git as grants](#git-grants)), and so do syncing the
  shared folders, `share-sync` ([Shared folders](#shared-folders)), and the
  workspace's copy onto this machine, `workspace`
  ([The workspace](#the-workspace)): those are over your machine, not
  MWT's tools, so locking your machine stops them.
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
repositories: its `host-origin` is your repository on this machine,
through MWT, as your repository's own `origin` is a Git server, and its
`remote-origin` is that server, as your machine fetches it. The VM works in
its clone as you work in yours; the one difference is how work comes
back: not by a push, but by a handoff you review and land. Work lands
only on your machine for now.

### Terms

| Term | Meaning |
| --- | --- |
| **Project** | A git repository of yours, in a shared folder, and its clone in the VM, `/work/<name>`, with its settings on the Projects page. Submodules and LFS are left out for now. |
| **host-origin** | In the VM, your repository on your machine, through MWT (`mwt::<project id>`): its branches are `host-origin/<branch>` there. |
| **remote-origin** | In the VM, your repository's own remote `origin` (GitHub, say), as your machine fetches it, read through MWT (`mwt::<project id>/remote-origin`): `remote-origin/<branch>` there. The VM's clone has no `origin`. |
| **Worktree slot** | A checkout of the clone that holds one task at a time: `slot-0` is the clone itself, `/work/<name>`; the others are worktrees of it, `/work/<name>.wt/slot-N`, which you add and remove. |
| **Task** | A branch `mwt worktree new` started in a slot, from a base (`host-origin/<branch>`, another task's branch or a commit), for one thread. Its branch goes once its handoff lands with nothing done on it since. |
| **Handoff** | A task's exact commit, with its title and notes, which an agent sends once you reviewed it in the VM and asked (`mwt handoff`). Handing off again makes a revision. |
| **Catch up** | The agent rebasing its task onto its base as you have it now: `git fetch host-origin`, `git rebase host-origin/<base>` (`mwt handoff` does both); or MWT replaying a handoff's commits there, from the Handoffs page, where they apply cleanly. |
| **Land** | Putting a handoff on a branch of yours, once you click Land: as it is (a fast-forward) when that branch hasn't moved, else as one commit (`accept` in the code). |
| **Send back** | Returning a handoff to its thread with a note. |

```
the VM                           your machine                  a Git server
/work/app ── host-origin ──▶     your repository ── origin ──▶ GitHub, …
  │          fetch, through MWT    your own workflow              ▲
  └───────── remote-origin ──▶ (your machine fetches it) ─────────┘
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
  branches and tags, once, as `host-origin/*`, and its default branch (main,
  master, then the one you have checked out) checked out in slot-0.
- **Open in Zed** opens the clone (slot-0), or a slot, over the VM's SSH
  connection. An existing clone opens even when its folder is no longer
  shared: it just can't fetch.
- **Close** takes a project off the page; its clone, slots, branches and
  handoffs stay in the VM. **Forget** lets go of its settings; the VM's
  work stays too.
- **The page shows** each open project's branches as host-origin has them, its
  checks, a warning when commits in the VM would have no author, and its
  slots: which are free, what the others hold (task, base, handoff,
  uncommitted work, the thread holding it, whether a Zed window has it
  open, servers running there), with Release, Open in Zed and Remove.

<a id="the-vms-clone"></a>

### The VM's clone

- **The clone is the VM's.** Its branches, commits, index and files follow
  Git: MWT never moves or resets a branch there, switches a busy
  checkout, or sets edits aside. The one branch it deletes is a task's,
  once its handoff lands with nothing done on it since ([After
  landing](#after-landing)); every other branch stays until someone
  deletes it in the VM.
- **Each remote is named for the level it reaches,** `host-origin` and
  `remote-origin`, and the clone has no `origin`. With `origin` as your
  repository in the VM, `origin/main` meant your `main` there and
  GitHub's on your machine, and agents, MWT's messages and you mixed them
  up ("solve the conflicts with host master" meant your `main`). MWT's
  messages name the level too: "the user's `main` (`host-origin/main`
  here)". The cost is Git's default: a bare `git fetch` or `git pull` on
  a branch that tracks nothing names no remote, and an agent's habit of
  `git fetch origin` fails, saying there is no `origin`, until it reads
  its instructions.
- **A clone made before the rename** (`mwt.clone-version` 1, with `origin`
  and `upstream`) is renamed in place the next time MWT updates it (each
  VM start, or when your branches move): its tracking branches and tasks'
  recorded bases follow, and nothing checked out moves. A remote of that
  name the VM pointed elsewhere stays the VM's. Handoff records keep the
  base they were made with (`refs/remotes/origin/main`), read as your
  branch.
- **A clone made from an older mirror** keeps its checkout and slots; its
  `host/*` branches become `host-origin/*`, and its `host` remote goes,
  since nothing would update it.
- **`host-origin` is your repository, through MWT.** Its URL, `mwt::<project
  id>`, runs MWT's remote helper (`git-remote-mwt`, in `/mnt/mwt/bin`):
  the VM names a registered project, never a path on your machine, and
  MWT runs `git upload-pack` on a view of your repository holding only
  its branches and tags (`MWTClient.Sandbox.GitTransport`). Its
  configuration, hooks, other refs, ignored files and uncommitted work
  don't travel. A fetch moves `host-origin/*` and nothing else; `git pull`
  fetches through MWT, then merges or rebases in the VM.
- **A push is refused**, saying work goes back by `mwt handoff`. A push
  that answered "ok" while your branch didn't move would lie; a handoff
  carries what a push can't: its title, notes, checks and thread.
- **`remote-origin` is your repository's own remote, as your machine has
  it** (`mwt::<project id>/remote-origin`): its `refs/remotes/origin/*`,
  so a task
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

What the VM does with your repositories goes through grants over your
machine, built in, like the Internet's ([Grant kinds](#grant-kinds)):

| Grant | What it allows | When MWT starts |
| --- | --- | --- |
| **Fetch from your repositories** | `git fetch`, `git ls-remote` and clones of `host-origin` and `remote-origin`: your committed branches and tags, and your remote branches as your machine last fetched them. Reads only. | On, auto |
| **Fetch from your remotes** | Before `remote-origin` answers, your machine fetches your repository's own remote into MWT's store (never into your repository), with your credentials, non-interactively, at most once a minute. The VM never sees a credential or chooses a URL. | On, auto |
| **Hand off** | `mwt handoff`: commits into MWT's review store, never into your repository. Your review is the gate. | On, auto |

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
  branch at `host-origin/<default branch>`, locked (`git worktree lock`, so
  Zed's `git worktree remove` leaves it); **Remove** takes a free one out,
  with its build. slot-0 is never removed. Folders never move, so a Zed
  window or a thread open on one never breaks. A slot keeps its folder
  between tasks, so what git ignores stays warm.
- **Git keeps the state; MWT keeps none** (`Slots.look/4`): a slot is
  *free* when its folder is absent or gone; clean and on no branch, or on
  a branch no task started (slot-0 on its own `master`); or on a task's
  branch whose latest handoff landed or was closed at the commit it is on,
  clean. Uncommitted work makes any slot busy. A slot is free as soon as
  its handoff lands; with nothing done on it since, MWT takes it off the
  branch, at the same commit, and deletes the branch ([After
  landing](#after-landing)).
- **A thread takes its slot first,** before anything else, even for a
  question: `mwt worktree new TASK --from BASE` fetches host-origin, then
  starts the branch TASK from `host-origin/BASE` (or another task's branch, or
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
  a sent-back task's branch in a free slot, making it again at its latest
  handoff's commit, with its base, when landing deleted it; or, in the
  slot that has it, moves the hold to the thread running it.
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
mwt handoff --title "fix(login): …" [--body FILE] [--onto BASE] [--no-checks]
mwt handoff withdraw --reason "…"   keep the open handoff from landing until the next
mwt handoffs                        the project's handoffs and what the user did
mwt project                         where you are, the slots, the rules
```

- **Agents never commit unless you say so,** and hand off only once you
  ask (`/handoff`): you review their work uncommitted in Zed, in the VM.
  You may commit pieces yourself there.
- **A handoff's title is its commit message,** written, like every
  commit message an agent writes, as a Conventional Commit:
  `type(scope): summary`, with the scopes your history uses.
- **`mwt handoff` does every step that needs no judgment,** in the slot:
  it fetches host-origin; commits the changes to files git has with the
  title, and stops at new files it wasn't told about; catches up by
  rebasing the task onto `host-origin/<base>` (going on with a rebase the
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
  (`git reset $(git merge-base HEAD host-origin/<base>)`).
- **Handing off yourself,** at a terminal in the VM (Zed's, or
  `msb ssh`): `mwt handoff` asks for what it wasn't given, and only
  there, where every standard stream is a terminal and no agent is above
  it but Zed's server. On a branch you made (`git switch -c`), it offers to
  make it a task, based on the branch it came from as git's reflog has it,
  or your default branch when that isn't known; then it asks the title,
  and once every step went through opens git's editor for the notes. It
  goes from any worktree of the clone, and finishes a task an agent left,
  out of quota say. A branch named like one of yours is refused: a landed
  task's branch is deleted.

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
  fetch finds it on `host-origin/<branch>`, so the clone and your repository
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
  changes to tracked files, nor where a file git doesn't track is in the
  way, ignored ones included (a `.env`): the preview names them, and
  nothing lands there until they are moved; a new branch writes no file
  of yours. No hook runs: MWT runs git on your repository and its review
  store with `core.hooksPath=/dev/null`, so a hook folder in your tree
  (`.githooks`, `.husky`), which a landing writes into, runs nothing
  either, and neither does a hook of your own. **Undo** puts it back
  while it still has what landed, never over a file you made since.
- **What you saw is what lands:** Land names the revision the page
  shows; one its thread handed off since lands nothing, and the page
  says so and shows the new one. A revision being received holds your
  clicks on that identity's handoffs (Land, Close, Send back) and the
  thread's withdrawal until it is in, and then adds to the record as it
  is, so nothing done meanwhile is lost.
- **Send back** works before and after landing, and MWT tells the thread
  when it can reach it. Closing and sending back leave the VM's branches
  and files alone; landing leaves its files alone, and deletes the task's
  branch when nothing was done on it since (below).

<a id="after-landing"></a>

### After landing

Every task is a branch in the project's clone, and nothing else removed
one, so they piled up, task after task. Landing is the moment a task's
work is done and safely on your branch, so it is when the branch goes
(`Slots.delete_landed/4`, from `Handoffs.accept/4`):

- **Deleted when nothing was done on it since:** still at the revision
  that landed, which your branch now holds (as it is, or squashed into one
  commit), and checked out in no folder with uncommitted work. The slot on
  it goes on no branch, at that same commit, free as it already was; its
  files and build don't change. The branch's `branch.NAME.*` settings go
  with it. The deletion only happens while the branch is still at that
  revision (`git update-ref -d` with it), so a commit made meanwhile keeps
  it.
- **Kept**, with the reason on the handoff's timeline: commits since that
  revision; uncommitted work where it is checked out; another task based
  on it (`--from refs/heads/BRANCH`), whose base would be gone; checked out
  in a worktree that isn't a slot, where someone works that MWT doesn't
  know; that worktree's folder gone; the VM not running when you landed
  it. A branch kept stays until someone deletes it in the VM: nothing
  sweeps the clone later.
- **Sent back after landing,** its thread is told first that the branch
  went, and to run `mwt worktree resume BRANCH` in its slot before it
  changes anything (`mwt handoffs` says it too): resume makes the branch
  again at the handoff's commit, with its base and the thread's hold, and
  needs a slot with no uncommitted work. Git keeps a deleted branch's
  commits in the VM for weeks before pruning them; a handoff sent back
  later than that can't be resumed from the VM, and MWT doesn't bring the
  commit back from its review store.
- **Undo** of a landing reopens the handoff without its branch in the VM:
  it lands again from MWT's review store, and its thread resumes it if
  you send it back.

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
| The workspace          | real values in the files of `from-vm/` coming here; credentials in `to-vm/` going in |
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
| Credential sent elsewhere         | a credential's placeholder to a host no grant over it lists (in a header, the target or the body), in a tunnel, or inside a DNS name | Isolate |
| Real credential in traffic        | a token grant's real value in what the VM sends that MWT reads, or coming back to it in an answer         | Isolate |
| Blocked services                  | a name on the blocked list, looked up or connected to                                                     | Isolate |
| Data in DNS names                 | a label of 50 characters or more, or 100 or more before the domain (one refused, three under a domain in 10 min isolate); over 40 names, or 1.5 KiB of names, under one domain in 10 min. Cloud providers' own domains aren't judged | Isolate |
| Large upload                      | 4 MiB or more sent in 10 min to one public destination, through tunnels or in read requests (counted by domain, so subdomains fold together), with less than a quarter of it coming back | Isolate |
| Scanning                          | 5 private or reserved address:ports refused in a minute, 20 ports of one public address in a minute, or 20 public addresses on one non-web port in a minute | Isolate |
| Mail, IRC and Tor ports           | a public address on 25, 465, 587, 2525, 6667, 6697, 9001, 9030, 9050 or 9150                              | Isolate |
| Command touching secrets          | an ad-hoc command (text the agent wrote) naming a path on the protected list                              | Isolate |
| DNS around MWT                    | DNS straight to a public address (port 53 or 853), or a public DNS-over-HTTPS resolver by name or address | Block   |
| A process pegging a CPU           | one process in the VM at 90% of a CPU or more for 30 min                                                   | Alert   |
| Asking again after you declined   | asking twice more, within 30 min, for a grant or a command you declined (the same command, however its spacing differs) | Alert   |
| Reading many notes                | 100 reads of notes, diagrams or flash cards in 10 min                                                     | Alert   |
| Minting a credential              | a request that would carry a grant's real value to an entry of the credential endpoints list: refused before its value is fetched, and the upstream never hears of it | Block   |
| Credential entering the VM        | a command's output or a request action's answer, on its way to the VM, holding something shaped like a credential ([What enters the VM](#what-enters-the-vm)). Block holds it for you; never isolates, the VM did nothing wrong | Block   |

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
    *is* a credential would bring a new one into the VM, and a grant's
    hosts don't say which endpoints those are. So *Minting a credential* refuses a
    request that would carry a grant's value to one, request actions'
    calls included, before the value is fetched (`mwt_credential_endpoint`);
    one with no value in it is the upstream's to answer. A grant that signs
    as a service account has `signJwt` answered by MWT instead, with a
    placeholder ([Credential endpoints MWT
    answers](#credential-endpoints-answered)). The add-grant form
    says when a grant's hosts, or an action's URL, cover an entry. A
    registry pull that trades a grant's token for the registry's is refused
    too: take the entry off the list, or set the rule to Alert, for that.
  - An entry `example.com` or `*.example.com` covers that name and every
    name under it; an address covers itself.
- **Real credential in traffic** looks for every token grant's real value,
  stored or minted and still at hand, on or off, wherever MWT reads what
  the VM sends: read requests (every header, Basic decoded, the whole
  body), plaintext tunnels, DNS names, asks on the agent channel, what
  MWT's tools are asked to write, handoffs (title, notes, commit
  messages, every file they add or change), and the files of the
  workspace's `from-vm/`. In a request or a tunnel it never goes, whatever
  the rule's action; an ask, a write, a handoff or a copy back is
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
- **Large uploads** count what goes to public addresses, through tunnels
  and in read requests (head and body, with what comes back), not a
  private address, one you opened with a network grant. The check runs as
  the bytes flow: the chunk that crosses 4 MiB waits for the verdict and
  doesn't go. The finding names the host it saw, though it counted the
  domain; a name trusted since no longer counts toward its domain. An
  agent that reaches its model through a cloud's API (Vertex AI, Bedrock,
  …) sends its whole context with every turn and gets a short answer
  back, so that host needs to be trusted, by its exact name
  (`us-east5-aiplatform.googleapis.com`, not `googleapis.com`, which
  would spare the cloud's storage too).
- **A finding is an event** in the activity log (`firewall`, its own group
  on the activity log); an alert is said once per rule and destination in 10
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
`:you`), at once, in the server. Isolating locks every resource there is
then, each credential, each network, your machine and MWT's tools, as
the isolation's lock (`Server.Locks.lock_all/2`), beside any lock of yours,
and changes no grant ([Locks](#locks)), in this order:

1. The firewall records the incident: who isolated it (`by`, `:firewall`
   or `:you`), the rule and what it saw (none for yours), when, and the 30
   events before it. It is saved sealed, so a restart of MWT comes back
   isolated. An incident saved before you could isolate was the
   firewall's.
2. Every connection the proxy holds open is closed
   (`MWTClient.Sandbox.Connections`, a registry the connections join), new
   ones are refused, and DNS answers REFUSED to every name.
3. Every approval waiting is refused (`mwt_isolated`), and every command
   running on your machine is stopped (TERM, then KILL). No grant changes:
   every decision refuses while the VM is isolated, whatever the grants
   say. Forwarding the VM's ports to your machine stops.
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
rule and what it saw, that releasing undoes nothing the VM did, that
isolating changed no grant, and, for a finding with a destination,
*Trust HOST from now on*; **Keep it isolated** leaves the switch on.
Only the isolation's locks end (`Server.Locks.unlock_all/2`): what you
locked yourself stays locked. No grant changed, so each is as you left
it, for the time it has left, with its allowances; one whose time ran
out meanwhile is off.
Releasing also starts over what the rule counted for what it fired on
(`Firewall.forget/3`: the domain's uploads, its names, the address's
ports, …), in the watch and in the server, before the isolation lifts:
the next connection or lookup is judged from zero, never isolated again
on what you just reviewed. Trusting adds the destination to the trusted
list, for a rule that fired on something you know: the name or address
the finding saw, never the domain a rule counted it under, and a
tunnel's port dropped (`Firewall.trust_entry/1`). **Stop the VM**,
beside the switch while the VM runs, stops it and keeps the isolation.
The last 20 incidents stay listed, folded under the switch.

<a id="screens-firewall"></a>

### The Firewall page

`/tools/sandbox/firewall`, *Firewall* in the sandbox's menu, with a red
*Isolated* badge while isolated. *Watching* On or Off at the top, then:

- **The isolation card:** the *VM isolated* switch. Off, a line on what
  turns it on (or that the firewall is off, so only you do). On, who
  isolated it and why, since when and how much it refused; what releasing
  does: isolating locked every resource and changed no grant, and
  releasing ends those locks, yours staying, every grant as you left it;
  and what came before (open for the firewall's isolation). The past
  isolations fold under it. On the Grants page's *Resources* tab, a lock
  only the isolation holds shows *Isolated*
  ([Locks](#locks)).
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
  ([Servers in the VM](#servers-in-the-vm-on-your-machine)); *Shared
  right now*, a summary that stays short however many grants are on: how
  many are on, over how many resources, how many end within the hour, and
  the first five resources, what ends soonest first, each with how many
  of its grants are on, when the first ends and whether it is locked,
  linking to its page; the Memory card ([The VM's OptMem](#the-vms-optmem));
  the latest activity.
- **Approvals:** the waiting cards of every kind ([Approvals](#approvals));
  the commands running on this machine above them, with Stop; what was
  decided below, where a command opens
  to its script and output.
- **Projects:** each open project with its branches as host-origin has them, its
  checks, a warning when commits would have no author, and its slots (Add
  slot; Release, Open in Zed, Remove); Close, Forget, *Open project*, and
  "Only in the VM". Read again every 5 s while open ([Projects and
  handoffs](#projects-and-handoffs), [Worktree slots](#worktree-slots)).
- **Handoffs:** the open ones and the closed. A handoff's page: the agent's
  notes (Markdown, with a Raw tab), its timeline and thread, its worktree to
  open in Zed, what lands (commits, files, the diff when you ask), and the
  decision apart, kept in view: Land, Send back or Close; Undo and Reopen
  after ([Handoffs](#handoffs), [Landing](#landing)).
- **Grants:** three tabs, *Resources* (each resource with *Lock* and
  its grants, *Add credential* and *Add network*, from a preset or by
  hand: [Locks](#locks), [Presets](#presets)), *Grants*, shown first
  (one list, what ends soonest first, with *Add grant*, which starts
  from the resource) and *Live Test* ([The console](#console))
  ([The Grants page](#the-grants-page)). A resource's page: what it is,
  *Lock*, Now, its grants and actions, a network's host limits
  ([Host limits](#host-lists)), its settings in place, and the review of
  one an agent proposed. A grant's page (`/tools/sandbox/grants/ID`):
  Now (its switch, [On and off](#states); what holds it back; what else
  covers it, [Overlaps](#overlaps); what is allowed for now; its last
  uses), its settings in place (the start setting,
  [When MWT starts](#when-mwt-starts)), what the VM gets, and Remove
  beside Save.
- **Activity log:** everything the VM did through MWT and the changes
  around it, so not *Proxy activity*, which it was called until
  2026-11-22. Filters (groups with their counts, words, a grant); a
  timeline of the matching events by series (traffic, credentials, blocked,
  other) from the oldest kept to now; the busiest destinations, each a
  filter; the log, a line per event that opens to all it recorded, a request
  MWT read to it as the VM sent it beside the response as it reached the VM,
  with Copy as JSON ([What the log keeps of a request](#exchanges)). The
  figures come from the server (`MWTClient.Sandbox.EventStats`), at most
  once a second while activity comes in. Each line's badge says what
  happened in a word or two, its meaning shown when hovered, on the line
  opened, and for every badge at once by the "?" in the log's head, by the
  filters' groups (`outcome_style/1`, `outcome_meaning/1`). Traffic says
  whether MWT read it, as the lists of What MWT reads do: *Read*, *Not
  read*, and *Cert refused* for a client that refused MWT's certificate;
  the rest name what changed (*VM change*, *Grant change*, *Host
  command*). What MWT reads opens from the header ([Not read](#not-read)).
  A line opens to the same few rows for every event: when; where (host,
  port, method and path); traffic and how long it was open; who asked,
  linking to its thread's lines. An action's line then has its audit card
  (below), and an event with a page of its own links to it (a handoff's,
  the project's, the firewall's, the VM's), rather than inline it. What MWT knew when it happened
  (`MWTClient.Sandbox.EventDetails`: the ask, a command and how it ran, a
  grant's change, a handoff, a tool call, a firewall finding, the build,
  the agent's words apart as its claims) is folded under *More about it*,
  one click away; a request MWT read opens to what it carried, request
  beside response, as it was. Details are words written when the event is
  logged, kept with it in the journal and read when its line opens, at
  most 16 KiB each; a builder that fails says so in them and in MWT's log,
  rather than stop the event or the sandbox.
- **Audit** (`MWTClient.Sandbox.Decision`): an action's line (a request,
  a connection, a lookup, a command, a fixed call, a call of MWT's tools,
  git and sync) has one small card, the same rows for every action:
  *Outcome* (allowed or not), *Decided by* (you on a card, Auto-approve, a
  grant that is on, MWT, nobody when its card timed out), *Because* in a
  few words (what you chose, where the standing yes came from, why MWT
  refused), *Grant*, a link to its page, marked *changed since* when the
  grant changed after it decided, leading to its changes, and *Card*, a
  link that opens it as it was decided, read-only, on the Approvals
  page. *Decided by* filters the log by it.
  Each allowance keeps its origin (`Allowance.origin`); a card is kept
  from the data it was drawn with, and goes when no line names it any
  more ([Storage](storage.md)).
- **Firewall:** the *VM isolated* switch with the isolation and the past
  ones, the rules by group, the last findings, the lists in tabs; a red
  badge in the menu while isolated ([The Firewall page](#screens-firewall)).
- **Settings,** only what you can change, each with a "?" for what it is
  and when it applies, in two tabs. *Runtime:* shared folders
  ([Shared folders](#shared-folders)); CPUs and memory against this machine
  and the suggestion, the disks, how long an approval waits; VMs inside the
  VM; the VM's memory; *This machine, for agents* (your notes, the folders
  confined commands may read). *Build:* the image's name, your layer and its
  versions, what podman builds whole, the builds kept ([The image](#the-image)).
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
9. Nothing the VM wrote runs on your machine unless you approve that exact
   text, each time, on its card (a command an agent writes always asks,
   and your machine locked refuses even the ask); what runs is the text on the
   card. A command action runs only your script, while it is on, its
   values as variables, never in its text (`guarantees_test.exs`,
   `policy_test.exs`).
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
    repository, nor a folder in one, is in a shared folder's copy, and a
    copy is read-only in the VM, root included, until root mounts it
    writable again (a real VM; `guarantees_test.exs`, `vm_live_test.exs`,
    `folder_sync_test.exs`).
14. Whether a use goes through, asks or is refused depends only on the
    grants, the resources' locks and limits, the use and the clock. For
    every combination of grant state, allowances, host and placeholder:
    with no grant on nothing goes, no placeholder goes to a host no grant
    over its credential lists, a grant not on by the clock lets through and
    asks nothing, a lapsed allowance allows nothing, a reserved address
    opens only for an entry naming it, a command an agent writes is always
    an ask, and a grant
    to review lets nothing through (`policy_test.exs`).
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
22. With the Internet's grant off, the VM reaches no public address but
    those network grants that are on list, a token grant's hosts no more
    than any other, and DNS answers only names those grants list; turning
    it off closes what it let through (`gate_test.exs`, `dns_test.exs`).
23. A network grant opens an address by a name only when MWT's DNS answered
    it for a name it covers while it was on, and nothing while its way out
    doesn't carry the route (`policy_test.exs`, `dns_test.exs`,
    `egress_test.exs`).
24. A grant's value never goes to a listed credential endpoint while the rule
    blocks (`egress_test.exs`, `firewall_test.exs`,
    `host_command_channel_test.exs`), but in the one request MWT sends there
    itself for a grant that signs, whose answer stays with MWT
    (`credential_endpoint_test.exs`).
25. For a credential no token grant is over, one only request actions
    use, nothing holding its placeholder is in `/mnt/mwt`
    (`credential_scope_test.exs`, `policy_test.exs`).
26. A confined command sees none of your home but the folders you listed, none
    of MWT's environment, and only the values of the credentials it names,
    the saved command covering them (`host_run_test.exs`,
    `host_command_channel_test.exs`, `confine_test.exs`, `policy_test.exs`).
27. A grant saved with checks (*Only while…*, gone since 2026-11-24) keeps
    none once MWT starts, and the activity log names each one once
    (`saving_test.exs`).
28. A fetch from the VM carries your committed branches and tags, and from
    `remote-origin` your remote branches as last fetched; never configuration,
    hooks, other refs, ignored files or uncommitted work, under any version
    of git's protocol. A push is refused and moves nothing
    (`git_transport_test.exs`). A handoff's fetch tells the VM of no ref of
    yours it doesn't see already (`hostile_text_test.exs`).
29. A hook or `core.fsmonitor` planted in the VM's clone runs in the VM, never
    here, through a handoff, its revision and its landing (a real VM).
30. No HTTP request saved in MWT is read from the VM (`mwt_tools_test.exs`).
31. A copy back of the workspace writes only inside its `from-vm/`, and
    lands no symlink, special file, name starting with `.` or `-`, or
    executable bit; an entry breaking a rule, or a file holding a real
    value, lands nothing of it; with its grant off or the VM isolated,
    nothing lands (`copy_back_test.exs`, `tar_reader_test.exs`,
    `workspace_sync_test.exs`).
32. A file of the workspace's `to-vm/` holding a real value, or a
    credential's shape while the rule blocks, never reaches the VM unless
    you send it from the Overview (`workspace_sync_test.exs`,
    `inbound_test.exs`).
33. A JWT MWT had signed never reaches the VM; its placeholder goes only to
    the host its `aud` names, and only while its grant still signs as its
    account and lists that host (`credential_endpoint_test.exs`).
34. A login's refresh never goes out, and its placeholder makes only a
    refresh at Google's token endpoint its credential's; an ID token's
    placeholder holds only `iss`, `aud`, `iat`, `exp`, `email` and `hd`,
    and goes only in its header to the grant's hosts
    (`credential_endpoint_test.exs`, `credential_scope_test.exs`).
35. A restart of the sandbox's server after a failure turns on nothing you
    turned off, nor off what you turned on: each grant comes back as it
    was, its time left and its allowances included, and the firewall's
    counts with it. Only opening or unlocking MWT puts grants in their start
    settings. No command the agent channel answers, whatever its fields
    hold, makes the server fail (`server_restart_test.exs`,
    `channel_hostile_test.exs`).
36. A card is made from a request whose declared body, up to 64 KiB, was
    read; one for an HTTP/2 stream whose body hadn't come says so, never
    "No body". What the VM sends after a request asking to switch protocols
    goes on only once the host switched (`101`); otherwise it is the next
    request, judged as any (`http1_driver_test.exs`, `request_view_test.exs`).
37. A body whose JSON names a key twice, at any depth, is one MWT can't
    describe: no pattern, so no *Allow similar* (`describe_test.exs`).
38. MWT's pages load images, media, fonts and scripts only from MWT; an
    image in Markdown shows as a link to its address
    (`content_security_policy_test.exs`, `markdown_test.exs`).
39. With the Internet's grant off, MWT connects for the VM to a host a
    grant over part of the Internet names only at an address its DNS
    answered for that name, and to a token grant's host only through such
    a grant (`gate_test.exs`, `egress_read_test.exs`).
40. A network grant that opened an address by a name lets through there
    only names MWT answered for it that the grant covers: the name in a
    ClientHello, split over records or not, and a plain HTTP request's
    `Host` (`tcp_test.exs`, `egress_plain_http_test.exs`).
41. A proposed grant is accepted only as its page showed it: one the agent
    proposed again since is not (`proposal_channel_test.exs`,
    `sandbox_live_test.exs`).
42. A handoff MWT couldn't look through whole for real values isn't opened
    (`hostile_text_test.exs`). A bare repository, or any git folder, in a
    shared folder is left out of its copy as a repository is
    (`folder_sync_test.exs`).
43. `e2fsck` and `resize2fs` read the VM's disks only in a bubble with no
    network, no home and nothing writable but that disk (`disks_test.exs`).
44. Git on this machine runs on the VM's objects no configuration of yours
    but the repository's own, and none of your repository's hooks: the
    review store's fetch, a handoff's facts and diff, its landing
    (`hostile_text_test.exs`, `host_git_test.exs`).
45. A call of MWT's tools that answers with an item goes through the read
    grant, a change that changes nothing included (`mwt_tools_test.exs`).
46. MWT opens in Zed only a folder under the VM's `/work` named in plain
    characters, whatever the VM printed (`zed_test.exs`).
47. Grants only give: a use needs, for each resource it goes through, a
    grant that is on and covers it, a request carrying a credential one
    over the credential and one over its host's network; within one
    resource the most permissive grant counts and one that is off has no
    say; across resources a use goes unasked only if each lets it through
    unasked, and one several grants ask about makes one card naming each
    (`policy_says_test.exs`, `credential_test.exs`, `attributes_test.exs`).
48. A locked resource refuses every use, whatever its grants say, and
    changes no grant; a value minted while its credential was locked
    isn't sent; isolating and releasing the VM change no grant either
    (`locks_test.exs`, `server_firewall_test.exs`, `server_test.exs`).
49. A request action's call goes only while the action is on, which
    covers its credential in its own request, and a grant over its host's
    network lets it out as it would the agent's own request; never
    through a locked resource or to a blocked host, and through MWT's
    proxy, as the VM's requests go (`action_channel_test.exs`,
    `waiting_command_test.exs`).
50. A login's refresh is answered without a card only while a grant over
    its credential is on (`credential_endpoint_test.exs`).
51. A dry run (`mwt why URL`, the console's *Decide a request without sending it*) sends nothing, and no
    explanation holds a value, a placeholder or a control character
    (`explain_test.exs`).
52. An export holds a credential's stored value only when you ask for it
    (`sandbox/transfer_test.exs`).
53. Isolating locks every resource beside your locks, and releasing ends
    only the isolation's (`locks_test.exs`).
54. Of the grants over one network, the most permissive that covers a
    host counts: a grant over a host that auto-approves lets it through
    while one over all of the network asks; a host the network's limits
    block is refused whatever its grants say; and a lock on the network
    holds every grant over it (`network_test.exs`).
55. A refused request's decision is kept with its event, and `mwt why ID`
    gives back that decision, not one made again (`explain_test.exs`).
56. A request action's answer reaches the VM with each value the call
    sent (its token, ID token or signed JWT) written out as what it is
    (`saved_request_test.exs`, `action_channel_test.exs`).

<a id="decisions"></a>

## Decisions

One row per decision in force, dated when it took its current form; the
history is in git.

| Date       | Decision |
| ---------- | -------- |
| 2026-11-11 | The VM gets placeholders, never real values: MWT alone holds the values and swaps them in on the way out, and microsandbox's own secret feature is unused ([Grant kinds](#grant-kinds)). |
| 2026-11-12 | Host commands move the work to where a value is instead of the value to the VM, and agents learn your machine from `mwt host`, never by probing it ([Host commands](#host-commands)). |
| 2026-11-13 | The image is Ubuntu 26.04 with its tools from mise (Erlang prebuilt), built on your machine with podman from your Containerfile and MWT's layer, its last three builds kept, since rebuilding the same recipe later gives other versions; nothing is published, so podman is a dependency ([The image](#the-image)). |
| 2026-11-24 | The image is three parts: MWT's base (Ubuntu 26.04, fixed, and what MWT runs in the VM), your layer, versioned, with no `FROM`, and MWT's final layer, which checks MWT's needs survived and lists every file's checksum; the Build page shows what podman builds whole. A VM's image disk is checked once after its first start, since a damaged one crashed tools with nothing noticing. Containers are podman's, storage on `/cache`, MWT's CA mounted by hash ([The image](#the-image)). |
| 2026-11-13 | MWT creates, starts and stops the VM, which stops when MWT quits or locks; the launcher Zed uses only looks at it and goes in while it runs ([Creating the VM](#creating-the-vm)). |
| 2026-11-13 | The proxy, TLS interception and HTTP reading are MWT's own Elixir, with a strict reader of its own: Bandit and Finch read leniently what MWT must refuse, and can't take a connection MWT decrypted ([Each intercepted request](#each-intercepted-request)). |
| 2026-11-13 | The VM's work lives on its own ext4 disks (Home, Cache, Work), which nothing on your machine opens: a folder the VM could write let a planted hook run when you used git there, and a disk is several times faster ([Disks](#disks)). |
| 2026-11-13 | DNS goes through MWT, which logs every name, and a query aimed at another resolver gets no answer ([DNS](#dns)). |
| 2026-11-13 | msb and the VM run in a bubble (`bwrap`), with namespaces of their own, no home folder and no network, reaching MWT over Unix sockets, since libkrun's guest reaches whatever its VMM can; on Ubuntu it is MWT's copy of bwrap, `/usr/lib/mwt/bwrap`, under an AppArmor profile the deb installs that lets what runs inside hold `CAP_NET_ADMIN` and `CAP_SETPCAP` and nothing else ([The VM runs in a bubble](#the-bubble)). |
| 2026-11-13 | Text the VM chooses is made to show all it holds where it enters MWT, and a script for your machine that hides anything is refused rather than shown changed ([Text the VM chooses](#text-the-vm-chooses)). |
| 2026-11-14 | Every use of a grant waits for you unless you allowed it: no rules of MWT's by method or path, since what a request does depends on the API, only allowances (uses like this one, or every use, for a while) and *Auto-approve*, chosen with a duration as a grant turns on and changed while it stays on ([Ask each time or auto-approve](#ask-each-time-or-auto-approve)). |
| 2026-11-14 | A command's text travels in the ask and is exactly what runs, its output going straight back or waiting for you as you choose, and agents send the smallest command that gets the raw data and work on it in the VM, since a card should take seconds to read ([Commands agents write](#ask-to-run-commands)). |
| 2026-11-14 | The Overview shows what the VM uses and what it costs this machine, sampled every 5 s while it runs, the last 10 minutes in memory only ([VM monitor](#vm-monitor)). |
| 2026-11-14 | Open in Zed brings an open folder forward (`zed --existing`), adds another to a Zed window already connected to the VM (`--reuse`), or opens a new window, never replacing a window's project, which would end the agent thread in it ([Projects and handoffs](#projects-and-handoffs)). |
| 2026-11-15 | What you save is an action, one fixed use of a grant that MWT carries out when an agent calls it by id with typed values (`mwt call`): your script on this machine under Ask to run commands, or one HTTP request MWT sends with a token grant's real value, each with a switch of its own, and agents only propose them (`mwt propose`) ([Grants and actions](#grants-and-actions)). |
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
| 2026-11-17 | Each grant and action has one switch, *Always ask me*, under which every use is a card you allow once, no allowance or Auto-approve covering it ([Never allow without asking](#ceiling)). |
| 2026-11-17 | The Grants page is a catalog: what is enabled first and apart, in full with its controls, so you always see what the VM can use, then every grant and action as a card, with a search, filters and a sort ([The Grants page](#the-grants-page)). |
| 2026-11-17 | A token grant names the presentations `mwt exec` runs for it, small programs that show a placeholder the way a tool family expects (the first, a cloud metadata server, for Google Cloud grants), which hold only placeholders, so adding one is no trust decision ([Presentations](#presentations)). |
| 2026-11-17 | A mint command is told which grant it mints for and, for a grant minted per host, which host (`MWT_HOST`), may say when its value expires, and runs as you, the one place that touches your login ([Where real values come from](#where-real-values-come-from)). |
| 2026-11-17 | New command actions run confined, in a bubble on this machine with an empty home, your tools read-only and only the values of the token grants they name, since a script run as you had your whole home in reach ([Confined commands](#confined-commands)). |
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
| 2026-11-18 | Agents propose whole grants (`mwt propose token`, `mwt propose network`) as well as actions, and what they propose is saved at once, disabled, never enabled on startup, tagged as proposed and to review; nothing turns it on until you accept it on its page, and declining or removing it before then tells the agent ([Proposed grants](#proposed-grants)). |
| 2026-11-18 | There is no YOLO mode and no file grant: nothing counts a grant as on but its own switch, and no grant hands the VM a real value. A file grant saved before is dropped as MWT starts, with its value, and Activity says which. |
| 2026-11-18 | Every field of the grant form has a *?* saying what its value means and what it is for; All grants shows six cards a page ([The Grants page](#the-grants-page)). |
| 2026-11-18 | Catching a handoff up with its moved branch takes a click: MWT replays its commits there itself where they apply cleanly, or sends it back to catch up with a note that is also the ask to hand off again, so its thread resolves the conflicts and hands off without another `/handoff`. A revision is measured from where its branch meets the base now, and `mwt handoff` goes on with a rebase it stopped before anything else ([Landing](#landing)). |
| 2026-11-18 | The firewall's rules were hardened against evasion and against false alarms. A connection claiming a trusted name over TLS is spared only at an address MWT's own DNS resolved for it, so the trust can't be borrowed to tunnel out unread. Uploads are counted by domain, so spreading them across subdomains folds together. DNS-name data is weighed by bytes, not just a count; a single long name is refused rather than isolating the VM, and names under cloud providers' own domains and the reverse names of addresses are no longer mistaken for exfiltration. Credential-endpoint paths are read as the host would (percent-decoded, `.`/`..` resolved), and a protected path is caught through quotes or backslashes slipped between its letters. A horizontal sweep (many addresses on one non-web port) joins Scanning, and DNS straight to a public port 53 joins DNS around MWT. The blocked, resolver, credential-endpoint and protected-path lists grew, more credential shapes are recognised entering the VM, and new default protected paths and credential endpoints reach a saved firewall on upgrade ([Firewall](#firewall)). |
| 2026-11-18 | One *VM isolated* switch on the Firewall page: the firewall turns it on, and so can you, to cut the VM off yourself; turning it off releases the VM, asking first, with what the firewall saw and whether to trust its destination, only when the firewall isolated it. The page is shorter: rules grouped a line each, their full text behind a "?", the lists in tabs, past isolations folded under the switch ([Isolating](#isolating), [The Firewall page](#screens-firewall)). |
| 2026-11-18 | The app is MWT (My Work Tools): the app, its package, the VM's `mwt` CLI, `/mnt/mwt`, its agents in Zed and its tools over MCP all take that name. Nothing under the former name is read or brought over: an install starts fresh. |
| 2026-11-18 | Shared folders are synced when asked, not every 3 s: when added, at each start, with Sync or Sync all, after a command you approved ran in one, and by an agent's `mwt sync` (the built-in grant `share-sync`), since walking a large folder every few seconds cost this machine all the time and capped a share at 4 GiB. Copies live on the work disk, shown read-only at their paths, so nothing the VM changes in one needs setting aside: `/work/.rescued` is gone, and a share holds up to half the work disk ([Shared folders](#shared-folders)). |
| 2026-11-19 | Agents write every commit message, a handoff's title included, as a Conventional Commit (`type(scope): summary`), taking scopes and length from the project's history even where its older commits don't follow the convention, so every project's history reads the same way ([Handoffs](#handoffs)). |
| 2026-11-21 | `agents.md` tells agents only how to work in the VM; how you like to work with agents (which decisions to bring you, how to build from building blocks) is your way of working, a text you write in Settings, empty by default, since it is your taste rather than a fact of the VM ([What MWT hands to the VM](#what-mwt-hands-to-the-vm)). |
| 2026-11-21 | The workspace, `~/mwt-vm`, moves files that aren't code between the VM and your machine in two halves, each written by one side only, so nothing is reconciled: `to-vm/` yours, copied in as a shared folder; `from-vm/` the VM's, copied here read-only under a grant of its own and rules that keep out what your tools act on by being there (no name starting with a dot or a dash, no link, nothing executable), since it is the first way the VM writes onto your disk without a handoff you land ([The workspace](#the-workspace)). |
| 2026-11-21 | The metadata server is offered on every token grant whose hosts are Google's APIs, however the grant was made, and an agent may propose it (`--metadata-project`, `--metadata-account`), since it holds only placeholders and a Google grant proposed, or added without it, left Google's client libraries with no default credentials and no way to turn it on ([Presentations](#presentations)). |
| 2026-11-22 | A credential endpoint a grant takes is answered by MWT itself rather than refused: it makes the credential with the grant's value, keeps it as a value made from the grant, going only where it was made for, and hands the VM a placeholder. The first is `signJwt`, for the service accounts a grant names, the signed JWT going only to its `aud` host; values made for one tool's request belong to one grant, since a request may carry one credential's placeholders ([Credential endpoints MWT answers](#credential-endpoints-answered)). |
| 2026-11-22 | A token grant may give a Google login file whose refresh MWT answers from its credential's mint, the access token its own placeholder and the ID token, when the mint prints one, a placeholder standing for the grant's current ID token, minted fresh on the way out, holding only its `iss`, `aud`, `iat`, `exp`, `email` and `hd`; values made for one tool's request belong to one grant ([Credential endpoints MWT answers](#credential-endpoints-answered)). |
| 2026-11-22 | A minted grant may keep each value at most N minutes, whatever its expiry says, since a service may take a token only while it is young ([Where real values come from](#where-real-values-come-from)). |
| 2026-11-22 | What agents are told every session shrank from 34 KB to 10 KB: the rules every task needs stay in `agents.md`, and what only some tasks need (slots in detail, handing off, token grants and MWT's refusals, proposing, host commands, the workspace) moved to guides that `mwt help TOPIC` prints, which the rules name as what to read first. With your way of working and a project's own `AGENTS.md`, Codex warned of the total, and every session, subagent and approval review read all of it ([What MWT hands to the VM](#what-mwt-hands-to-the-vm)). MWT's example way of working asks for a component per job, named for it, rather than roles people would play, and keeps only the concepts: 7.9 KB instead of 14.8 KB. |
| 2026-11-22 | MWT reads every connection it can, the Internet's and a network grant's, so you can read what went out on your behalf: TLS ended with its CA's certificate, the request read and judged one by one, the host reached at the address the destination check approved with TLS MWT starts again. What it can't read is passed through with why; which hosts it reads is yours to set on the activity log, per host and for any other, never by a failure, since the VM would then choose what goes unread; reading adds about 0.3 ms a request on a kept connection, 1.9 ms on a new one ([Each connection](#each-connection), [Not read](#not-read), [What reading costs](#what-reading-costs)). |
| 2026-11-22 | On a network grant, each request MWT reads is a card of its own under the grant, and a connection it can't read is asked about after its first bytes, with the name it asked for and why, before anything is reached; of two grants opening an address, the one naming it most exactly decides ([Private networks](#private-networks)). |
| 2026-11-22 | The log keeps every exchange MWT reads, the Internet's included, as much of each body as your setting says (64 KiB at first), for as long as the activity's retention rule; a request with nothing to judge alone shares a kept connection, so reading every host costs a TLS handshake a connection, not a request ([What the log keeps of a request](#exchanges), [Each intercepted request](#each-intercepted-request)). |
| 2026-11-22 | The VM and MWT keep six channels, each there because msb offers nothing else for its job; one channel waits for a second backend with no network card ([Channels](#channels)). |
| 2026-11-22 | The proxy reads each protocol through a driver of its own, pure, and does everything else itself, the same for every protocol: one way out, every byte looked through and counted, each request judged as one shape its driver describes, a real value put in only where the judge says, the driver doing the replacing. A new protocol is one driver; reading through the core costs a kept request about 0.05 ms more than before. The core is TCP's, and a driver is told its transport, so a core for UDP would run the same drivers; the interface is a first draft, changed by the first protocol that doesn't fit it ([Drivers](#drivers)). |
| 2026-11-22 | The proxy's purpose is that you see and decide what the VM does outside it at the finest grain there is, the request: each one logged with what came back and, where a grant asks, held on a card of its own, in every protocol a driver reads. Keeping credentials out of the VM is one use of that reading, not its reason, so a protocol with no credential to carry (a database you shared, whose queries you want to approve) is worth a driver too ([What it is for](#what-it-is-for), [Network](#network)). |
| 2026-11-22 | Plain HTTP is read, each request judged and logged; its host is the one its `Host` names, the client's word, so no placeholder goes in one, its card names the address it goes to and *Allow similar* covers that address only. HTTP/2 is read too, offered only to a client that offers no HTTP/1.1 (gRPC's): one that speaks either is read over HTTP/1.1 all the same, so HTTP/2 for it would add only risk; each stream is a request of its own, a value going only in a carrier ([Drivers](#drivers), [Each intercepted request](#each-intercepted-request)). |
| 2026-11-22 | What the core looks through is the VM's text: HTTP/2 headers go up written again without Huffman coding, a WebSocket's frames masked with zeros (its extensions offer taken out, so nothing comes compressed), and each stream's text is looked through apart from the framing and other streams, so a value split across two frames is found. A request MWT refuses is looked through for real values too ([Drivers](#drivers)). |
| 2026-11-22 | Two requests whose body MWT holds only the start of never share a card: what follows may differ, and one decision would let through a body nobody saw ([Approvals](#approvals)). |
| 2026-11-22 | The Proxy activity page is the Activity log, the name the agents' instructions and the firewall already gave it, since it holds the VM's changes, host commands and handoffs as well as its traffic. What MWT reads is a dialog opened from its header, two lists (*Read*, *Not read*) and what a host on neither gets, rather than a card always on the page. The badges say what happened: *Read* and *Not read* for traffic, *Cert refused* (was *Not read*) for a client refusing MWT's certificate, *Swapped*, *No answer*, *Wrong host*, *VM change*, *Grant change*, *Host command*, *MWT tool*, each with its meaning on hover and in a legend ([Pages](#pages), [Not read](#not-read)). |
| 2026-11-22 | Every event of the activity log keeps what MWT knew when it happened, since the log is where you watch what the VM does: details written as labelled words when it is logged, stored beside it in the journal like a request's exchange, and read when its line opens. Words rather than the records they came from, so the log says what was true then and a later MWT draws a months-old event; the cost is that a detail is searched as words, not filtered as a field. An event naming a grant keeps that grant as it was. The agent's own words are kept, shown apart as claims ([Pages](#pages), [docs/storage.md](storage.md)). |
| 2026-11-22 | The VM's clone names each remote for the level it reaches, `host-origin` (your repository on your machine) and `remote-origin` (its own remote `origin`, as your machine fetches it), and has no `origin`, since `origin/main` meant your `main` in the VM and GitHub's on your machine, and agents, messages and you mixed them up; clones made before are renamed in place ([The VM's clone](#the-vms-clone)). |
| 2026-11-22 | Landing a handoff deletes its task's branch in the VM when nothing was done on it since, taking its slot off the branch at the same commit, so task branches don't pile up; a branch with anything on it stays, and the handoff's timeline says why. Nothing sweeps the clone periodically ([After landing](#after-landing)). |
| 2026-11-23 | You hand off work you did yourself in the VM: at a terminal, `mwt handoff` offers to make a branch of yours a task, based on the branch it came from, asks the title and opens git's editor for the notes, and finishes a task an agent left ([Handoffs](#handoffs)). |
| 2026-11-23 | From the threat model review of 2026-11-21 (`docs/dated/`), checked again against the code: a restart of the sandbox's server after a failure puts each grant back as it was, with the firewall's counts, kept by a process of the identity's that lives as long as the unlock (`UnlockState`), rather than coming back with every grant off, which would stop an agent's work at each failure, or from saved state, which would lose a change made in the last 250 ms; only opening or unlocking MWT is a start. Git's upload-pack never speaks protocol version 2, which serves any object by id whatever the settings say; a client asking for it is answered in version 0. MWT's pages carry a Content-Security-Policy, and Markdown's images show as links, also in your own notes, since the renderer doesn't know who wrote the text. With the Internet off, a token grant's host is reached only at an address MWT's DNS gave. A proposed grant is accepted only at the revision its page showed. `e2fsck` and `resize2fs` run in a bubble. Landing runs with git-lfs's smudge off: a file stored in LFS lands as its pointer, for `git lfs pull` to fetch from your remote ([Guarantees to test](#guarantees-to-test), 35 to 46). |
| 2026-11-24 | A grant is on, off or disabled: off refuses every use it covers, even where another grant lets it through, and disabled has no say. Every grant covering a use has a say and the strictest wins (no, then ask, then yes), so overlapping grants only narrow each other and nothing ranks one grant above another; a use carrying a credential needs a say from a grant over it. An HTTP request is one decision of the grants over its credential and the network grant it came through, and one card names every grant that asks, *Allow for a while* adding the allowance to each one left ticked. A grant you add or an agent proposes starts disabled; one saved off before gave nothing, so it is disabled now ([On, off and disabled](#states), [The rule](#the-rule), [Approvals](#approvals)). |
| 2026-11-24 | A credential is a resource apart from the grants over it: where its value comes from, its one placeholder, how tools find it. Several token grants can be over one, each with its own hosts, attributes and approval, and its value is minted once for all; grants saved before were given one each, those minted the same way merged into one keeping their old placeholders, since the same Google login was minted four times for four purposes ([Credentials](#credentials)). |
| 2026-11-24 | `mwt exec CREDENTIAL -- COMMAND` chooses which credential a command speaks as and decides nothing, the grants over it deciding each request at the proxy; it refuses at the start while the credential is locked or no grant over it is on, as a courtesy, not a boundary ([Grant kinds](#grant-kinds)). |
| 2026-11-24 | Credentials, networks and your machine have locks, for when something went wrong: a locked resource refuses every use whatever its grants say and changes no grant, stops the commands running with it, holds back a value minted while it was locked, and agents can't ask for it to end. Two hold locks, each apart: you, and the isolation, which locks every resource beside your locks as the firewall isolates the VM; releasing ends only the isolation's, so every grant is as you left it and what you locked stays locked, rather than turning back on what the incident remembered. The lock switch reads on as open ([Locks](#locks), [Isolating](#isolating), [Releasing](#releasing)). |
| 2026-11-24 | Ask to run commands is always on and always asks, with no switch, duration or start setting: nothing it allows runs without your approval of its exact text, so an off switch only stopped agents from asking. Locking your machine stops the asks; saved commands keep switches of their own ([Commands agents write](#ask-to-run-commands)). |
| 2026-11-24 | Every grant and action has a start setting, *Disabled* (the default), *Off, refusing*, *Enabled, ask* or *Enabled, auto*, and every start of MWT begins from these, every allowance ending with the session ([When MWT starts](#when-mwt-starts)). |
| 2026-11-24 | A token grant may narrow by attributes MWT reads (a method, a path pattern, a gRPC method, a GraphQL operation, git's direction, a GitHub repository); what MWT couldn't read counts against the use unless the grant's *Covers requests MWT can't read* is off, so an off grant can't be walked around, and agents never ask for that setting. *Allow similar, any id* covers an endpoint whatever its ids ([Attributes](#attributes), [Approvals](#approvals)). |
| 2026-11-24 | What MWT knows of a family of credentials is an adapter (`bearer`, `github`, `google`) behind fixed extension points, shipped with MWT, never a plugin: it reads a mint, implies the hosts its endpoints need (Google's token and signing hosts, which no grant lists now), adds variables (`GOOGLE_CLOUD_PROJECT`) and attributes (a GitHub repository), and may make a value (a GitHub App's installation token from its key). A login's refresh MWT answers is no use of a grant, so it makes no card ([Adapters](#adapters), [Credential endpoints MWT answers](#credential-endpoints-answered)). |
| 2026-11-24 | Agents find out why a use was refused or asked about from MWT, since tools hide its answer: `mwt why --recent`, `mwt why ID`, and `mwt why URL`, a dry run of the same decision that sends nothing and says so, with *Try a use* for you; what they are shown is built from a list of what may be shown, never a value, placeholder, body or the firewall's workings. A refused request keeps its decision as made with its event, its refusal naming it (`"decision"`, `"why"`), so `mwt why ID` gives back what decided then rather than deciding again with grants that changed since. Grants that may cover one use are linked by MWT from their scopes, never declared ([Finding out why](#finding-out-why), [Overlaps](#overlaps)). |
| 2026-11-24 | An export holds the sandbox's setup as a section of its own: credentials, networks, grants and their start settings, the built-in grants' settings, your presets, host notes, way of working and the folders confined commands may read; stored values only when you tick it, minted values never, and nothing of a session. Importing merges, a differing definition coming in beside the old under a new id, to review; a credential that comes in gets placeholders made anew, since one from a file could be one of yours ([Export](#export), [docs/transfer.md](transfer.md)). |
| 2026-11-24 | Networks are resources of their own, the Internet among them, and each entry of a host list a grant over that host of its network: Ask, on and always asking; Auto, on and auto-approving; Block, off and not askable. Every grant over a network with a say about a use speaks and the strictest wins, so a host set to Auto no longer loosens an Internet that asks, and a network grant off refuses every address it lists, the Internet's every public one. Which grant opens a connection is still the most exact one ([Networks](#networks), [Hosts of a network](#host-lists), [The rule](#the-rule)). |
| 2026-11-24 | Checks (*Only while…*) are gone, since a network reached through an interface of its own already opens nothing while it is down, and a credential that turns out to do more than you set it up for is yours to lock. A grant saved with checks loses them as MWT starts, and the activity log names them once ("Checks removed, which no longer run: …") ([Private networks](#private-networks), [Locks](#locks)). |
| 2026-11-24 | What was called a subgrant is an action everywhere: the pages, `mwt` (`--actions-only`, with `--subgrants-only` still accepted), the guides and the code (`Grant.action?/1`, reach `:actions`, preset `request_action`); state, presets and files saved under the old names are read under the new ([Grants and actions](#grants-and-actions)). |
| 2026-11-24 | A request action may send the values its credential's adapter makes beside `{token}`: `{id_token}`, the ID token the Google login's mint prints, and `{signed_jwt}` or `{signed_jwt:ACCOUNT}`, a JWT Google signs as an account the grant names for the call's URL, valid an hour, so a fixed call to a service behind Identity-Aware Proxy needs no grant of its own let through without asking ([Request actions](#request-actions)). |
| 2026-11-24 | Grants give, resources limit, since the first build's on, off and disabled and the strictest say were too confusing to set up: each grant mediates one resource (a credential, a network, your machine, MWT's tools) and is only on or off, off having no say; with no grant on nothing goes. A use needs, for each resource it goes through, a grant on that covers it (a request carrying a credential one over the credential and one over its host's network, so a token grant no longer opens its hosts with the Internet's grant off); within a resource the most permissive grant counts, across resources it goes unasked only if each lets it through unasked, and one card names every grant that asks. Holding back is the resources' job: a lock, and a network's host limits, a default and two lists, Reachable and Blocked, the most exact entry deciding, a blocked host refused whatever any grant says, so always asking about one host the Internet's grant lets through isn't expressible ([On and off](#states), [The rule](#the-rule), [Host limits](#host-lists)). |
| 2026-11-24 | A command an agent writes needs no grant: Ask to run commands is gone, agents can always ask (`mwt run --reason … -- COMMAND`, the old ids still accepted), you approve each run, and it is refused at once while your machine is locked. Saved commands are grants over your machine, each credential they run with needing a token grant that allows your machine; request actions are grants over their credential, so a token grant only its actions used is gone. Actions sit under their resource, and the Grants page has three tabs, *On now*, *Resources* (credentials and networks added on their own, each with a page, its lock and its grants) and *All grants*, each grant linking to its resource ([Commands agents write](#ask-to-run-commands), [Grants and actions](#grants-and-actions), [The Grants page](#the-grants-page)). |
| 2026-11-25 | Resource first: you add a credential or a network on its own, from a preset or by hand, then grants over it. Credentials name their adapter (`bearer`, `github`, `google`, `hex`) and show its fields (a GitHub App's ids, a Google login file or metadata server); a pasted value may come later, until then every use is refused and no grant over it turns on. Presets say what they make: credential presets, and grant presets over the credentials of a service (*Everything it reaches*, *One repository*); an older file splits into one of each ([Presets](#presets)). *Add grant* moves into All grants and starts by picking the resource; a grant's form and edit hold only the grant's fields; a grant's page shows *The resource it gives a use of*; All grants filters by resource. Agents propose resources and grants apart (`mwt propose credential`, `network`, `grant --over RESOURCE`), any field of the form with `--set FIELD=VALUE` and a preset's blanks with `--fill`; `mwt propose token` is gone; you accept a resource before a grant over it ([Proposed resources and grants](#proposed-grants)). |
| 2026-11-25 | A simpler Grants area: one Grants list (what is on first, what ends soonest at the top, 20 a page, a bar of status, search, resource, type and sort) in place of On now and All grants; a grant's and a resource's page in two parts, Now and Settings, edited in place with Save and Cancel instead of Edit, the common fields first and the rest under Advanced, whose summary says what is set; presets chosen from a list that says what each sets and asks for, *By hand* first, in place of name chips; *Lock* in place of the open switch; *Always ask me* is *Never allow without asking*, under Advanced. *Try a use* became the Console: a command or an HTTP request run in the VM as an agent's, speaking as a credential, with what it printed, its exit status and what MWT decided while it ran ([The Grants page](#the-grants-page), [The console](#console)). Every credential's real value is looked for in what the VM sends, one with no grant over it yet included. |
| 2026-11-25 | Two kinds of grant, named everywhere: open use (agents' own tools in the VM, each request checked by MWT as it leaves) and fixed call (one request MWT sends, or a script of yours it runs, on your machine, agents giving only values), what were actions; every grant, approval card, activity row and the console say where things run, *In the VM* or *On your machine* ([Open use and fixed calls](#open-use-and-fixed-calls)). A grant's and a resource's page: their settings in a main panel with *Save* and *Cancel*, what they are now in a side panel. The Grants list filters by kind and whether a grant starts on; the Resources tab is one list too, with how many grants are over each, how many are on and its last use, found by kind, state and words. Add grant over a credential asks which kind. |
| 2026-11-25 | Where a grant runs reads *Runs on VM* or *Runs on host*, and your machine as a resource is the *Host*; a grant's page says its kind decides where it runs. The console keeps a *History* of its runs, with what each printed, ten a page, searched, opened and run again, in memory only ([The console](#console)). *Remove* on a grant's or a resource's page is a button, in a section of its own. |
| 2026-11-25 | Only a grant over a credential says its kind and where it runs, on its row, its page and the cards about it: a network's grants are always open use, the host's and MWT's tools' always fixed calls. MWT's own grants lose their *Built in* tag; their page says they can't be removed. The Grants list drops its kind filter and its sort, in one order: what ends soonest first. The tabs read *Resources*, *Grants*, *Console*, Grants shown first. A network grant's hosts are its *Request targets*. The console's *Speaking as* is *With credential*. The Overview's *Shared right now* sums up by resource instead of listing every grant ([Open use and fixed calls](#open-use-and-fixed-calls), [The Grants page](#the-grants-page)). |
| 2026-11-25 | A network grant may leave hosts out (*Except these hosts*), the Internet's included: it covers its part of the network but those, and another grant over them decides. So one host can always ask while the Internet's grant lets everything else through; with that grant off, the host is refused. A request to a host left out is refused with `mwt_not_covered`, its lookup isn't sent, and a connection that may be for it waits for its first bytes; `mwt grants` and `mwt why` say it ([Host limits](#host-lists)). |
| 2026-11-25 | A fixed call's parameters may have rules: a JSON Schema per parameter (from 1 to 10, one of a list, matching a pattern, at most so many characters), checked with `jsv` after the shape, in a bounded process of its own; the page and `mwt grants` say each in words, and a value that breaks one is refused before anything runs. A guide, `mwt help resources`, says how to write resources, grants and rules, for you and for agents ([Parameters](#parameters)). |
| 2026-11-25 | A fixed call's parameters are one JSON Schema, in place of shapes and rules: an object whose properties are the parameters, each with its description and what its values may be, `word` a format of MWT's; `--param` lines are a shorthand for it. MWT's floor holds whatever it says: no leading `-` (but a number), nothing up a folder, nothing hidden. *Never allow without asking* is gone: *Ask*, and what each card allows, say it. *Remove* sits beside *Save*. A script, a command or a mint command says where it runs wherever it shows. The console no longer decides a request without sending it ([Parameters](#parameters)). |
| 2026-11-25 | The grants' model is written down ([grant_mental_model.md](grant_mental_model.md)): a grant's kind is who builds what it lets through, the agent (open use) or MWT (a fixed call), and every grant says it; *Runs on host* is said only where a command runs there. Your machine as a resource is *Host commands*; MWT's own git fetch, handoff, sync and workspace moved to *MWT's tools*, so locking host commands leaves them going ([Open use and fixed calls](#open-use-and-fixed-calls)). |
| 2026-11-25 | A command an agent writes goes under a built-in grant, *Commands agents write* (`agent-commands`): on, agents may ask, and every run waits for you, whatever is set; off, they can't ask; never handed a credential's value ([Commands agents write](#ask-to-run-commands)). |
| 2026-11-25 | A fixed call covers the credentials it names in what it builds, and no token grant has a say in it; a saved command no longer needs a token grant that allows your machine (*Allow your machine* is gone). A request action's request goes out as the agent's own would: a grant over its host's network has to let it out, and a grant whose requests none lets out says so on its page ([Open use and fixed calls](#open-use-and-fixed-calls)). |
| 2026-11-25 | A request action goes through MWT's proxy, as the VM's own requests do: the address checks, the firewall, the values put in on the way out, an answer that echoes one cut, and a request line labelled *Fixed call · NAME* ([Request actions](#request-actions)). |
| 2026-11-25 | Each fixed call is graded *Narrow*, *Wide* or *Open*, on its page, its cards and in `mwt grants`, a warning only; a command's card says what it can't show louder than a hint, and the files a command runs are pinned: one changed after you approved it runs nothing, one changed since a saved command was saved makes that run ask ([Pinned files](#pinned-files)). A parameter's schema check is bounded by its work, not by time. |
| 2026-11-25 | An opened action's line has an audit card, the same rows for every action: outcome, who or what decided it (you on a card, Auto-approve, a grant that is on, MWT, a timeout), why in one line, a link to the grant (marked when it changed since) and to the card as it was decided, read-only, on the Approvals page. The log filters by *Decided by*; a line no longer carries a copy of its grant ([Pages](#pages)). |
| 2026-11-25 | An opened line of the activity log says less, the same way for every event: when, where, traffic, who asked, an action's audit card (with links to the grant and the card), a link to the event's page; what MWT knew of it is folded under *More about it*. What a request carried, request beside response, is as it was ([Pages](#pages)). |
| 2026-11-25 | From the grants QA (`docs/dated/20261125-grants_qa.md`): one reader of what a script runs (`ScriptRuns`) behind pins, hints and the grade, a file it can't tell making each run of a saved command ask; a saved command pinned as you accept it, one never pinned asking once; `*` in an allowance never a dot segment, and a request carrying a credential refused when its path has one; every answer MWT reads looked through for all your values, cut and the firewall told, at about a third of a large download's throughput, and an answer it can't read refused while it holds values; the grade still only warns (Q8), *Narrow* only for what a value provably can't break out of; names the VM chooses scanned like values; every refused call or command logged; a call's card names every grant that asked. Agents read *fixed call* (a *fixed request* or a *saved command*) where they read *action*, and *Host commands* where they read *your machine*; the start setting reads *On, ask* and *On, auto* ([grants.md](grants.md)). |
| 2026-11-26 | The Overview has a *Terminal*: the console, a line at a time, with a prompt, history on ↑ and ↓, Ctrl+C and Ctrl+L, each command starting where the last ended; one history with the Live Test, as the Grants page's *Console* is now called. A run keeps its colours and shows a line written over as it ended. A terminal over a PTY was set aside: a long-lived session streamed both ways, and a second way into the VM beside Zed ([The console](#console)). A `<details>` you opened stays open as the page updates, every one of them, by one rule in `app.js`. |

<a id="later"></a>

## Later

Open: not built, or not tried yet.

- **`resign` and `signing` grants:** AWS SigV4 re-signed by MWT (the VM signs
  with dummy keys); an SSH agent over vsock, approval per signature.
- **More presentations** in `mwt-present`: a container registry's credential
  helper, a Kubernetes exec credential, a `credential_process`.
- **Finer allowances,** if asking about every use proves too much: the
  widening steps a driver declares for *Allow similar*, beyond *any id*.
- **The rest of the grants redesign** of 2026-11-24
  (`docs/dated/20261124-grants_redesign.md`): always asking about one
  host a wider grant lets through, which grants that only give can't
  express; attributes on network grants, declared by each driver (gRPC and GraphQL
  as drivers of their own) and compared when working out overlaps; the ID
  token kept for a time of its own; token shapes, credential endpoints
  and presets declared by adapters; linked grants grouped on the Grants
  page, and a change of state saying first what it changes through them;
  `mwt why -- curl …`; a placeholder per `mwt exec` run, so a card could
  show the command, marked as the agent's claim.
- **Confined ad-hoc commands,** as a choice on their card.
- **Names beside addresses** in the activity log, from the DNS answers,
  saying when a TLS name and its address never met.
- **More firewall rules:** a credential of yours used from the VM with no
  grant, a connection to an address no lookup gave, a handoff touching files
  that run on their own (hooks, CI).
- **Secrets in shared folders** (`.env`, `*.pem`, tokens in remote URLs)
  looked for, with a warning when you pick one.
- **The VM:** a second backend from stock parts (QEMU or Cloud Hypervisor,
  vsock; spiked in `test/review/vm_spike`), with no network card and one
  channel to MWT instead of six ([Channels](#channels)); a published default image, so
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
- **Export:** the sandbox's credentials, networks, grants and settings
  are in it ([Export](#export), `docs/transfer.md`); still not: the VM's
  OptMem read through the running VM, items' versions, and how the CA
  moves.
- **The VM's OptMem:** its review offered in the Approvals queue, not only on
  the Memory card; seeding it with only some projects' memories.
- **Projects:** a folder picker and the upstream branches on the Projects
  page; submodules and LFS files; your uncommitted work sent by git, as a
  snapshot beside `host-origin/BRANCH`.
- **Handoffs:** landing on a repository's own remote; revisions read through
  `host-origin`; handoffs in MWT's Git tool, and that tool on repositories in the
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
