# L. Shared folders and the workspace

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

Decided: every shared folder goes one way, from your machine into the VM,
read-only there. The workspace goes the other way only, from the VM onto
your machine, read-only on your machine. No file changes on both sides, so
"Conflicts in shared folders' copies" is closed (M1 removes it from the
todo).

## What it makes possible

- **L1.** A shared folder never brings a repository's insides into the
  VM:
  - a bare repository, or the target of `--separate-git-dir`, is
    recognised as a repository;
  - a repository that appears in a share later is removed from the VM's
    copy;
  - more folders that hold credentials are refused as shares.

  Today such a repository is copied whole: its `config` with remote URLs,
  its `packed-refs` and its hooks.
- **L2 and L3.** Agents can leave you files that aren't code, in one
  folder MWT makes on your machine, at the same path on both sides:
  - a report or an export you asked for;
  - a config entry a CLI of yours uploads;
  - the input a subgrant's script reads.

  A command or subgrant of yours finds it by `$MWT_WORKSPACE`. Today
  there is no way: the agent passes it in a parameter, or the job can't
  be done.

## Where it sits

- L1: round 4, slot 3. It needs nothing.
- L2: round 7, slot 3. It needs M1, which edits the same todo section. It
  is the threat model of the workspace, worked out with you, before any
  code.
- L3: the workspace itself. Round 9, slot 2. It needs L2, F1 (the pages'
  CSP), G1 (threads bound to tasks, for a part per task) and J1 (the
  handoff's checks on files from the VM).

## Read

- The plan, workstream L.
- `docs/todo.md`: "A workspace for agents, on your machine", and
  "Conflicts in shared folders' copies" for what `FolderSync` already
  knows.
- The review:
  - *Shared folders* among the smaller gaps;
  - the leads on a repository appearing later and on the credential
    folders;
  - *Ways out through your own programs*, and *Items the VM writes that
    agents here read*, under *Gaps in the threat model*.
- `agent_sandbox.md`: *Shared folders*, *What MWT hands to the VM*, *Your
  machine, as agents see it*, *Handoffs*, *Firewall*, the threat model's
  promise *Nothing the VM writes runs on your machine unless you chose
  it*.
- Code: `FolderSync`, `Shares`, `ShareMounts`, `Server.ShareSync`,
  `Handoffs` (the limits on what a handoff brings), `HostInfo`,
  `priv/sandbox/agents.md`, `sync` and `host` in `priv/sandbox/mwt-cli`.
- Tests: `folder_sync_test.exs`, `folder_sync_bounds_test.exs`,
  `shares_test.exs`, `share_sync_test.exs`.

## L1: shared folders bring no repository's insides (S)

Task: `treat-bare-repos-as-repositories`.

- A repository is recognised by its shape, not only by a `.git` entry: a
  folder holding `HEAD`, `objects/` and `refs/` is a bare repository, and
  a `.git` file pointing elsewhere is one too.
- A repository that appears in a share removes what was copied of it from
  the VM. `folder_sync_test.exs` asserts the opposite today: change that
  test.
- The refused credential folders include `~/.claude`, `~/.codex`,
  `~/.cargo`, `~/.m2`, `~/.terraform.d`, `~/.config/op`, `~/.config/gcloud`
  if it isn't there yet, and browser profiles.
- The document: *Shared folders*.

## L2: the workspace's threat model, with you (S)

Task: `workspace-threat-model`.

The workspace is the first way the VM writes onto your disk without a
handoff you land. It touches the promise *Nothing the VM writes runs on
your machine unless you chose it*: files land without a click, and some
programs here act on files without one. Work out the answers below with
the user, then write the settled design into the todo's workspace
section. It moves into `agent_sandbox.md` when L3 builds it. Propose an
answer for each; the user decides.

1. **A grant of its own?** The user's suggestion. A built-in grant, *The
   VM writes to your machine*, would make it:
   - off, or on for a while, like any access;
   - logged at each sync, with the files, their sizes and types;
   - turned off by an isolation;
   - optionally asked about at each sync, on a card listing what changes.

   Weigh which start setting it gets, and what happens to files already
   there when it goes off.
2. **When does it sync?** Watched, as the todo has it, or only when the
   agent asks (`mwt sync`, out), and always before a command or subgrant
   of yours runs. Asked-for is fewer moving parts, and each sync is an
   event the agent can tell you about.
3. **Who reads it here without a click?** Each is a way for a file to run
   or be parsed with no choice of yours:
   - **Git.** A shell prompt runs `git status` in any folder it enters.
     A `.git`, a `.git` file, or a folder shaped like a bare repository,
     at any depth, can name a command in its config (`core.fsmonitor`).
     Your user owns the files, so `safe.directory` doesn't stop it.
   - **Tools that read their files when you `cd` in**, or open the
     folder: direnv's `.envrc`; mise's `mise.toml`, `.mise.toml` and
     `.tool-versions`; editors' project settings (`.zed/`, `.vscode/`,
     `.idea/`, `.nvim.lua`, `.exrc`). An editor's project settings can
     name a language server's binary.
   - **File managers and indexers.** Thumbnailers parse what a file
     manager shows, and desktop search parses what it indexes; both have
     had memory bugs on crafted files. Which folders does Fedora's GNOME
     index, and which marker does it honour to skip one?
   - **Sync and backup clients.** A workspace inside Dropbox, Google
     Drive, Nextcloud or OneDrive uploads what the VM wrote, past the
     proxy and the firewall's upload rule.
   - **Your agents here.** An agent on your machine asked to read a
     report there reads whatever instructions it holds, with your
     credentials in reach. This is the review's *Items the VM writes that
     agents here read*, made larger.
   - **Your commands and subgrants.** A tool given a file from there may
     treat it as code: a kubeconfig's `exec`, `npm install`'s scripts,
     `git -C` on a folder holding a repository. The card of a command or
     subgrant that reads the workspace says so.
4. **So what is refused?** The handoff's limits:
   - a size cap and a count cap;
   - no symlinks, hard links or special files;
   - executable bits dropped;
   - names that hide something refused (control characters, look-alikes,
     `..`).

   And from the list above: every dotfile, or at least the names it
   lists, and any folder shaped like a repository.
5. **How files cross.** MWT reads the VM's files itself, with those
   limits, and writes them with no symlink followed (relative to the
   folder it opened). Never with `tar` or another tool unpacking an
   archive the VM made.
6. **Where it lives.** A folder MWT owns, never a symlink, per identity:
   - outside every shared folder, so it isn't copied back into the VM;
   - outside every place an indexer or a sync client looks;
   - at the same path in the VM.
7. **Your changes there.** Mode bits make it read-only, but you can undo
   them. Is a file you changed put back at the next sync, or kept aside
   and said?
8. **The other direction.** What your commands write for the VM goes in
   a shared folder, as today. Should MWT make one by default, beside the
   workspace (`to-vm`, shared like any other), so a command always has a
   place to leave output for the VM?
9. **The threat model's lines.** The new way onto your machine in the
   attack-surface table, a promise for it, and *Not covered* for what
   stays: you opening a file there, and what your own tools then do with
   it.

## L3: the workspace (L)

Task: `vm-workspace`. After L2, F1, G1 and J1.

1. The handoff's limits on files from the VM move into a module of their
   own, with what L2 added. Handoffs and the workspace both use it.
2. The workspace as L2 settled it:
   - made by MWT, one per identity, `MWT_WORKSPACE` in the VM and in
     every command and subgrant MWT runs here;
   - a part per task (`<project>/<task>/`, bound to the task through
     G1), removed or kept when its handoff lands or closes;
   - the grant, if L2 chose one;
   - shown on the Overview page with a button to open it.
3. Agents told to use it in `priv/sandbox/agents.md` and `mwt host`:
   outputs you asked for, inputs for your commands, never `/tmp` or a
   project's clone for those.
4. The document: the design moves from the todo into `agent_sandbox.md`,
   with guarantees for the limits and the grant. The todo's section goes.

**Done when:** tests show each refused kind of file never reaching your
disk, a symlinked workspace refused, a part per task, and a command
running here reading what the VM wrote last.
