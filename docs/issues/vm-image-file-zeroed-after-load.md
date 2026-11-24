# A file in the VM image reads as zeros after loading

- Found: 2026-11-23, MWT 0.3.0, microsandbox 0.7.15 (MWT's pinned build)
- Kind: bug
- Status: cause unknown; since 2026-11-24 MWT notices it (below)

## What happened

In a VM created from a fresh build, `/usr/local/bin/mise` (170 MiB) held
its real bytes only up to offset `0x17FA000`, about 24 MiB: the rest, 147
of its 171 MiB, read as zeros. Its ELF program headers sit in the zeroed
part, so the kernel mapped nothing and every run segfaulted at the entry
point (`0x882a7ce`), the same address every time. Every mise shim (python3,
uv, gh, node, and the agents' memory tool, a Python script) crashed with
it. No other file over 2 MiB in the image was damaged.

## Where it was damaged

- The build was fine: the Containerfile checks the release's SHA-256 and
  runs `mise --version`, and MWT's layer ran `mise ls` after it.
- podman's image was fine: `sha256sum` and `mise --version` in a container
  of the same tag gave the release's binary.
- The archive MWT hands to microsandbox was fine: the layer tar from
  `podman save --format docker-archive` held the intact binary.
- microsandbox's file for that layer, `cache/layers/sha256_<layer>.erofs`,
  had the right size (178,520,064 bytes). Whether its bytes were zero is
  unknown: the build was deleted before checking.
- In the VM, reads gave zeros with `O_DIRECT` and after dropping the page
  cache: the VM was served zeros, it didn't cache them.

The VM's root is a read-only EROFS disk (`/dev/vda`) that microsandbox
puts together from its layer files, `fsmeta` and a VMDK. The damage came
in there: while converting the layer, or while assembling the disk.

The same Containerfile, built and loaded again, gave an intact binary.

## Why it matters

Nothing notices. The build checks the tools inside podman, and nothing
checks the image after microsandbox loads it: the VM starts, and every tool
that goes through the damaged file fails with a segfault that points
nowhere.

## Possible fixes

- Record checksums of the image's executables in MWT's layer at build
  time, and check them in the VM after a load, or at its first start.
- If it happens again: before deleting the build, count the all-zero MiB
  chunks of the layer's `.erofs` file in the store. Many means the
  conversion wrote zeros; none means the disk's assembly lost them.

## Also found while repairing it

- MWT has no way to delete a build, or to build without podman's cache.
- microsandbox won't remove an image that a stopped VM references: the VM's
  record had to go first.

## What was done (2026-11-24)

- MWT's final layer lists the checksum of every file of the image
  (`/etc/mwt/image.sha256`). After a VM's first start, MWT mounts its image
  disk read-only in the VM, apart from its root, and checks every file
  (`MWTClient.Sandbox.ImageCheck`): 7 s warm, about 17 s cold, for this
  4.8 GB image of 80,000 files. Damage shows on the Overview, naming the
  files.
- **Rebuild without cache** (`podman build --no-cache --pull=always`) and
  **Delete** on each kept build but the current one and the VM's.

If it happens again, the check names the files; the step above, counting
the all-zero MiB chunks of the layer's `.erofs`, still tells where.
