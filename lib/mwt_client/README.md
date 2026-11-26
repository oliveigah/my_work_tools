# lib/mwt_client

MWT is a few apps on one platform. Each app keeps its own data and logic in
a folder of its own; what more than one app uses lives outside those folders,
here at the top, as the platform. An app may use the platform and nothing
from another app's folder. A piece an app grows that a second app needs moves
out of its folder, into the platform, before the second app uses it (as
`MWTClient.Markdown` did, out of notes).

Pages live in `lib/mwt_client_web`, where the same split holds: each app's
LiveView (`live/*_live.ex` and its folder) and the shared components
(`components/`).

## Apps

| Path            | App                  | Its page              |
| --------------- | -------------------- | --------------------- |
| `http_client/`  | HTTP Client          | `/tools/http`         |
| `diagrams/`     | Diagrams             | `/tools/diagrams`     |
| `notes/`        | Notes                | `/tools/notes`        |
| `flashcards/`   | Flashcards           | `/tools/flashcards/*` |
| `sandbox/`      | Agent Sandbox        | `/tools/sandbox/*`    |

The Git GUI (`/tools/git`) has no folder here: all it does is git, which is
the platform's `git/`.

## Platform

| Path                              | What it is                                                                          |
| --------------------------------- | ----------------------------------------------------------------------------------- |
| `git/`                            | git on a repository you opened: reading history, changes and worktrees, and every command the Git GUI runs (`MWTClient.Git.Core`) |
| `markdown.ex`                     | Markdown to safe HTML (`MWTClient.Markdown`); `MarkdownComponents` shows it          |
| `notifications.ex`, `notifications/` | what waits for you, from any app: listed in MWT (the bell, `/notifications`) and put on the desktop as your settings say (`MWTClient.Notifications`) |
| `dbus/`                           | the session bus client the desktop notifications go through                          |
| `accounts.ex`, `vault.ex`, `vault/` | identities, the key their password makes, and the stores an unlocked one runs        |
| `storage.ex`, `storage/`          | each identity's encrypted databases, `library.db` and `journal.db`, the journal of agent activity, the retention rules and what applies them, backups (`docs/architecture.md`); the Storage page is `StorageLive` |
| `preferences.ex`                  | app-wide settings readable before sign-in (theme, last username)                     |
| `transfer.ex`, `transfer/`        | export and import of everything an identity keeps; apps take part as participants    |
| `search.ex`                       | the word search of the apps that keep text, in memory and as SQL over their indexes  |
| `mcp/`                            | the tools agents in the VM save notes, diagrams, flash cards and HTTP samples with, over MCP (`mwt mcp`, `MWTClient.Sandbox.MwtTools`) |
| `save_timer.ex`                   | the save-after-a-pause timer the stores share                                        |
| `tools.ex`                        | the catalogue of apps the tool picker shows                                          |
| `updates.ex`, `log_file.ex`       | MWT's own updates and log                                                            |

The sandbox runs git through a runner of its own, `sandbox/host_git.ex`, and
not `git/`: it fetches from repositories an agent shaped, so it checks every
object, follows no submodule and caps what it reads. That is a rule of the
sandbox, not a second git library.
