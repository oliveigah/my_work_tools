# Workspace copy-back fails on every file

- Found: 2026-11-23, MWT 0.3.0
- Kind: bug
- Status: open; reproduced from the VM

## What happens

`mwt sync "$MWT_WORKSPACE/from-vm"`, and a plain `mwt sync`, stop with

    <workspace>/from-vm: not synced. <file> didn't come from the VM: sync again

for any file, a 6-byte text file included, and nothing is copied. Syncing
again gives the same.

## Evidence

The message comes from `CopyBack.entries/5`: the archive read on the host
ended before the files it asked for. The VM's side packs them fine: in the
VM, the command MWT runs there,

    cd /work/.workspace/from-vm && printf 'probe.txt\0' |
      tar -c -f - --format=gnu --null --no-recursion --verbatim-files-from -T -

writes a 10 KiB archive holding `probe.txt`, and exits 0. So the list of
names or the archive is lost between the VM and the host: the list may not
reach tar's stdin through the guest stream, or tar's output may not reach
the file the host reads.

## Why it matters

The VM can't hand a file to the user's machine: an input a host command or
subgrant reads, or a report the user asked for.

## Workaround today

The user copies the file out of the VM by hand, from Zed over SSH.
