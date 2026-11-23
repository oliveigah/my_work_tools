# The Home and Cache disks started empty after an update

- Found: 2026-11-23, MWT 0.3.0
- Kind: bug, to confirm
- Status: to confirm: check whether the two disks were reset by hand

## What was seen

The VM's Home (`/root`) and Cache (`/cache`) disks are meant to survive
recreating the VM. In the first VM after the update to 0.3.0, both were
empty: their `lost+found` dated from the minute the VM was created, and
what earlier VMs had put there was gone:

- a static Docker under `~/.local/docker`, and its data under `/cache`;
- uv's managed Pythons under `~/.local/share/uv/python`, so a project's
  `.venv`, on the Work disk, pointed to a Python that no longer existed and
  had to be synced again.

The Work disk (`/work`) and the agents' memory disk kept their content.

## To check

Whether the update made new Home and Cache disks (a new path or name, say)
or the user reset them. If MWT did, keep the disks across updates, or say
in the release notes that they start over.
