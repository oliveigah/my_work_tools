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

