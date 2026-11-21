# I. The VM's image, its disks and the bubble

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- Projects whose tests start containers (testcontainers) run in the VM
  out of the box: Docker in the image, its data on the Cache disk, started
  with the VM, and a setting to leave it out. Today it takes a static
  install by hand, and a start script after every boot.
- No disk tool runs on your machine on a file system the VM wrote.
  Reclaiming and growing happen inside the VM, or in a bubble with only
  the image bound. Today `e2fsck` and `resize2fs` run here, as you,
  unconfined, on images that root in the VM wrote byte for byte
  (finding 6).
- On Ubuntu, MWT's bwrap copy no longer gives `CAP_NET_ADMIN` to anything
  a local program starts with it, and it follows bubblewrap's security
  updates. Your machine is Fedora, so this is for whoever installs the
  `.deb`.
- The bubble doesn't start without a seccomp filter, msb calls have time
  limits, and the files the bubble writes are read with a size limit.

## Where it sits

- I1: round 4, slot 2. It needs nothing. It comes this early because
  testcontainers hold up your work.
- I2 and I3: fillers, for a slot with nothing to take. They need nothing,
  and are about the release more than your daily work. If I1 confined the
  disk tools in `bubble.ex`, take I3 after it.

## Read

- The plan, workstream I.
- The review:
  - finding 6;
  - among the smaller gaps: *Seccomp*, *The bubble*;
  - the leads under *The bubble*: the disks folder following symlinks,
    `msb` calls without `timeout`, the AppArmor profile adding no
    confinement, the VM with no record of its making.
- `docs/todo.md`: "Docker in the VM", "The bubble's AppArmor profile on
  Ubuntu".
- `agent_sandbox.md`:
  - under *The VM*: *The bubble* and *Which bwrap*, *Runtime*, *Creating
    the VM*, *Disks*, *The image*, *Where things live*, *Developing MWT*;
  - *Later*, for containers in the VM.
- Code:
  - the image: `priv/sandbox/Containerfile`, `mwt-layer.Containerfile`,
    `mwt-boot`, `Image`;
  - the disks and the VM: `Disks`, `Server.Machine`, `Bubble`, `Seccomp`,
    `Msb`, `Confine`;
  - the bubble's install: `scripts/deb/postinst.sh`, `native/mwt_relay`.
- Tests: `image_test.exs`, `disks_test.exs` (slow: it copies a 1 GiB
  image), `bubble_test.exs`, `seccomp_test.exs`, `msb_test.exs`, and the
  `vm` suite where `/dev/kvm` is there.

## I1: Docker in the image, and the disks kept from inside (M)

Task: `docker-and-disks-in-the-vm`. It changes the image's boot and the
Cache disk twice over. If it grows too big, hand off Docker first and the
disks second, as two revisions.

- **Docker.**
  - Docker's static release in the image, checked against its published
    SHA-256, with `iptables`.
  - `data-root` on the Cache disk.
  - Started by the boot script, or on the first use of its socket. The
    VM's init is `init.krun`, with no systemd.
  - A setting to leave it out.
  - Check that a container's traffic still goes through MWT's proxy: it is
    NATed by the VM's kernel, so it should. Say so in *The image*.
  - Registries' logins aren't in this step (*Later*: a registry's
    credential helper as a presentation).
- **The disks.**
  - Check first whether libkrun passes discards through to the image
    file.
  - If it does: reclaim with `fstrim` in the VM, and grow with an online
    `resize2fs` in the VM after the file grew here. Growing a file here is
    only a truncate.
  - If it doesn't: run `e2fsck` and `resize2fs` in a bubble like
    `msb-confined`'s, with no home folder, no network, and the one image
    bound.
  - Either way: operations in the disks folder don't follow symlinks.
  - *Disks* says what runs where. "Nothing on this machine opens them"
    becomes true, or is changed.
- Remove the todo's Docker section.

**Done when:**

- the image builds;
- a test shows no disk tool runs here unconfined;
- the `vm` suite runs a container and reclaims a disk, if `/dev/kvm` is
  there;
- otherwise the handoff says what is left to try on a real VM.

## I2: the bubble on Ubuntu (M)

Task: `narrow-the-ubuntu-bubble-profile`.

1. **A spike first.** Why does msb give the VM IPv4 only when a public
   address has a route? Is there an option, or another way, that needs no
   route? If so, the relay needs no capability. Then the profile and the
   bwrap copy go, and MWT uses the system's bwrap on Ubuntu too.
2. **If not:**
   - only a root-owned `/usr/lib/mwt/mwt-relay` moves into `mwt-bubble`,
     and anything else the copy starts gets no capability;
   - a dpkg trigger on `/usr/bin/bwrap` refreshes the copy;
   - the copy is executable by an `mwt` group only;
   - say what runs from source get.

Remove the todo's AppArmor section when done. What is left (the spike's
answer, if it was no) goes to *Later*.

## I3: the bubble, bounded (S)

Task: `bound-the-bubble`.

- On an architecture the seccomp filter isn't written for, the bubble
  doesn't start. Or, if the user prefers, the page says so plainly before
  every start: ask which.
- `msb load`, `ssh authorize` and the relay's `msb` calls run under
  `timeout`.
- What MWT reads from the bubble's own folder (`control.sock`,
  `start.out`, `relay.lock`) is read with a size limit, and *The bubble*
  says that MWT believes these files.
