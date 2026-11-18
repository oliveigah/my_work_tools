# Overnight batch, 2026-11-14

Everything you asked for before going to sleep, one commit per group, on
the branch `overnight-batch` (worktree `.worktrees/overnight`), on top of
master `6fce41e`. Master is untouched. Delete this file once you've read it.

## Taking it

Your dev MWT runs from the main checkout, reloads `lib/` as it changes, and
owns the VM, so I worked in a worktree and didn't merge.

1. Stop MWT, or be ready to restart it.
2. In the main checkout: `git merge --ff-only overnight-batch`.
3. Restart MWT. **This step matters:** the notification process was renamed
   and moved (`MWTClient.Notifications.Center`), and a running app only
   starts new processes at boot. The code survives a hot reload (pages
   load, the sandbox server reads the new fields with defaults), but
   notifications stay off until the restart.

What reaches the VM:

- `mwt` itself (with `--asked`), `/mnt/mwt/AGENTS.md` and `mwt project`
  update as soon as MWT rewrites the inbox, which it does at start.
- The block in the VM's `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` is
  copied at VM boot, so threads see the new handoff wording after the VM's
  next start.

`mix precommit`: 942 tests and 23 doctests, all green (905 tests before: 37 new).

## What was built, and what I decided

| You asked | What it is now | Decisions to look at |
| --- | --- | --- |
| Markdown renderer with a raw/markdown tab | Handoff descriptions render as Markdown, with Markdown / Raw tabs; notes sent back render too. The renderer is `MWTClient.Markdown` (moved out of notes) and `MarkdownComponents` shows it anywhere. | The tab switches in the browser, default Markdown, not remembered. Agents are now asked to write the body in Markdown: what changed, why, how it was tested, what to check. |
| Open in Zed kills the previous session | MWT runs `zed --existing ssh://mwt-sandbox/…`: the project joins the Zed window already open (a Zed window holds several), or opens one when Zed isn't running. Zed starts through `setsid`, detached from MWT. | `--existing` overrides your `"cli_default_open_behavior": "new_window"`. **Not tried against your real Zed**: doing it would have touched your open windows and the VM. Detaching also means a Zed MWT started survives MWT restarts, which may have been the "killing" too. |
| Notifications for handoffs | Each open handoff notifies (“Claude handed off #4: …”), again when the agent updates it, and is withdrawn when you accept, close or send it back. | When MWT starts, handoffs still open are listed in MWT but **not** popped on the desktop again (each restart would flood it otherwise). |
| A global notification system | `MWTClient.Notifications`: any app calls `notify/4` / `withdraw/2` with a kind. Every notification is listed in MWT: a **bell** in the title bar with a count, and a `/notifications` page with the list and the settings (desktop on/off, each kind on/off, test). | Settings are per identity in `preferences.json` (plain, not the vault: nothing secret). The sandbox's old switch moved there; if you had turned it off, it stays off. One you dismiss on the desktop stays listed in MWT while it still waits. |
| Shared modules outside the app folders | `lib/mwt_client/README.md` lists apps and platform. Platform at the top of `lib/mwt_client/`: `git/` (it already was), `markdown.ex`, `notifications.ex` + `notifications/`. `switch` and the `?` help moved to `MWTClientWeb.UIComponents`. | I kept short names (`MWTClient.Git`, `MWTClient.Markdown`) instead of a `MWTClient.Platform.*` namespace: renaming every module would conflict with work in flight in the VM. Easy to change if you want the namespace. |
| Projects ordered by last use, with a timestamp | Most recently used first, “used 2 h ago” on each (the time on hover). Used = opened in Zed, a task started or resumed in a slot, a handoff from it, one accepted. | Never-opened repositories come after, by name. Projects from before start with their added time. |
| Composable push | The chevron next to Push opens a panel: Skip hooks, Set upstream (with a remote picker), and Keep / Force with lease / Force, in any combination, with the exact `git push …` shown. | Opens with nothing ticked every time (dangerous choices don't stick). Plain force still asks first. Forcing is greyed out until there is somewhere to push (an upstream, or one being set). |
| Merge worktree from a branch's menu | Right-click a local branch, “Merge a worktree into BRANCH…”: lists the other worktrees with their branch (or detached commit), how many commits they bring, and whether they have uncommitted changes (which stay there). | Into the branch checked out in the tab: a normal merge (conflicts as usual). Into a branch **checked out nowhere**: done without touching any worktree (fast-forward, or a merge commit via `git merge-tree`); refused, naming the files, when it conflicts. Into a branch checked out in another worktree: refused, “open that worktree”. `MWTClient.Git.Worktrees`. |
| The flow of returning work to the agent | You can now **send back an accepted handoff** with a note (after trying it on your machine). The thread reads it with `mwt handoffs` and its next `mwt handoff` updates the same handoff. | What you accepted stays where it went; sending back drops Undo for it (git can still revert it). |
| Agents hand off only when asked | Per project, on the Projects page: “Agents hand off: When their work is done / Only when you ask”. With the second, `mwt project` says so and `mwt handoff` refuses a new handoff without `--asked`, which the instructions allow only once you asked. | **Default: when their work is done**, as before, since you said you'd mostly accept and review on your machine; flip it per project. A handoff you sent back updates without `--asked`. |
| Choose the target branch when approving | The accept box has an “Onto” picker: the handoff's own target, or any branch checked out in a worktree of your repository; the preview and button follow it. | Only checked-out branches are offered, since a handoff lands in the worktree that has its branch checked out. The record keeps the branch it went onto. |
| Less text, more “?” | Moved behind `?`: Projects (target branches, worktree slots, why a read-write share can't be opened), the add-grant dialog, Agent access, the Git tool's SSH keys, the export's password note. | The sandbox pages had most of this already from the last pass; I left warnings and consent text (file grants, copying memory) visible. |
| YOLO mode | Approvals page: YOLO for 1/4/8/12 h or until off. Every grant counts as on, every use goes through and is logged “allowed by YOLO”, asks for a grant are answered at once, your own command scripts run at once. A red bolt in the title bar on every page while on; the Grants page says so. | **Default 8 h.** Commands the agent writes itself run only if you tick “Also commands the agent writes” (that's arbitrary code as you on your machine). **Refusals stay**: a placeholder to a host its grant doesn't list, two placeholders, private addresses no network grant lists, `--need` asks. No grant switch is flipped, so it ends by the clock (across restarts too) with nothing to undo. |

## Not verified here

- **Zed** (see above) and **GNOME notifications** (the tests use a fake
  notification service on a private bus, as before).
- **Anything needing the VM:** no handoff page, Projects page with
  projects, or real `mwt` in a VM was seen running. The handoff, project,
  CLI and YOLO flows are covered by tests with a folder standing in for the
  VM, and the real `mwt` script driven over the channel socket. `mix test
  --only vm` was not run (it starts VMs).
- Screenshots of what I could run (throwaway data, port 4150) are in
  `/tmp/mwt-run-overnight/shots/`: the notifications page, YOLO off and on
  (dark and light), the Grants banner, the push panel, the branch menu and
  the merge-worktree picker.

## Commits

    15ede65 feat: platform Markdown, rendered/raw view for handoff descriptions
    dc3dedb feat: notifications are MWT's own, and handoffs notify
    a673787 fix: Open in Zed adds the project to the open Zed window
    e359a22 feat: projects listed by last use
    3da40e6 feat: handoff flow: pick the target branch, send back after accepting, hand off when asked
    e47890d feat: composable git push
    fdfb2cd feat: merge a worktree into a branch from the Git tool
    f485cbd feat: YOLO mode for long unattended runs
    35080fe chore: explanations behind '?' markers
    5615dbc fix: new state survives a code reload into a running MWT
    0955259 fix: under YOLO, agents hear their grant is on with every use allowed
