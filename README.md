# MWT (My Work Tools)

MWT is a Linux desktop toolbox for the small developer tasks I use every day. I
am rebuilding familiar tools around a local-first workflow: keep past work easy
to find, keep saved data on my machine, and make backups simple without a hosted
account.

## Tools

- **HTTP Client:** Send requests, inspect responses, import or export curl
  commands, and search saved request history.
- **Git GUI:** Browse commits and diffs, manage branches and stashes, and work
  with the staging area across multiple repositories. Push prompts offer upstream
  setup, destination selection, or force retries when needed, with an option to
  abort. Force with lease protects the remote state shown when the prompt opened.
- **Diagrams:** Sketch boxes, ellipses, diamonds and arrows, and write on any of
  them or anywhere on the canvas. Tables of typed rows can be related row to
  row, for data models. Every diagram is kept, and search finds a word wherever
  it was written.
- **Notes:** Keep tasks and ideas as a title and a Markdown body, and mark
  them done as you go. Search finds a word in any note, open or done.
- **Flashcards:** Keep what is worth remembering as question and answer
  cards, written by you or by an agent at the end of a thread, labelled with
  tags such as the project and the topic. A remember session asks the cards
  of the tags (any or all of them) and days you pick; you vote on each
  (forgot, hard, good, easy), and the ones you forget come back sooner.
  Correct a card as you review it, or remove it as not important: an agent
  writing it again is told it was removed.
- **Backup and restore:** Export a local identity's saved data to one encrypted
  `.mwtexport` file, then import it on another installation.

## Architecture

- **Desktop shell:** Tauri starts a bundled Elixir release through ElixirKit and
  opens its Phoenix server on the local loopback address. It also provides
  native file pickers.
- **Interface:** Phoenix LiveView renders the tools and handles interaction;
  Tailwind CSS and JavaScript provide the desktop UI.
- **Tool logic:** Elixir modules execute HTTP requests with Req and Git
  operations through the installed Git executable.
- **Local data:** HTTP history, diagrams and notes are encrypted under a
  password-protected local identity in `~/.mwt_client/`. Git repositories
  remain in their own folders. The transfer system packages identity data for
  encrypted export and import.
- **Formerly MDT:** MWT was called MDT (My Dev Tools). An install made then
  keeps its data in `~/.mdt_client/` and its VMs under the names microsandbox
  recorded them by; saved data, exports (`.mdtexport`) and VM clones made then
  are read as MWT's (`MWTClient.FormerName`). The `mwt` package replaces the
  `mdt` one.

## Development

With Elixir, Erlang, Rust, and the Tauri Linux prerequisites installed:

```bash
mix setup
cargo tauri dev
```

The Agent Sandbox also needs its VM runtime, built once into
`priv/microsandbox`, plus `bwrap` (bubblewrap), `podman` and e2fsprogs on
the machine:

```bash
./scripts/build-microsandbox.sh   # msb and its guest kernel
./scripts/build-relay.sh          # MWT's relay, beside them
./scripts/build-acp.sh            # MWT's ACP shell for the VM (needs: rustup target add x86_64-unknown-linux-musl)
./scripts/build-present.sh        # the presentations mwt exec runs in the VM (the same musl target)
```

`mix compile` runs the last three itself when `native/mwt_relay`,
`native/mwt_acp` or `native/mwt_present` changed (`Mix.Tasks.Compile.Native`; `MWT_NATIVE_BUILD=0`
skips it), so after the first time you needn't think about them.

On Ubuntu (24.04 and later) AppArmor keeps the system's `bwrap` from doing
what the sandbox needs. MWT's deb sets that up when it is installed; for an
MWT run from source, once:

```bash
sudo sh scripts/deb/postinst.sh   # a copy of bwrap at /usr/lib/mwt/bwrap, and its profile
```

`mix test --only vm` then boots a real VM and checks what only one can
show: that its process is confined, that it reaches the network only through
MWT, and that its disks are kept.

## Connect an agent through MCP

Open **Connect an agent** from the tools page or the title bar, then choose
**Enable agent access**. Copy the generated server URL and Bearer token into
your agent's MCP settings using the **Streamable HTTP** transport. The screen
also provides a client configuration you can copy.

With MWT open and its vault unlocked, you can ask your connected agent to:

- "Make a diagram of our checkout flow on MWT."
- "Store this HTTP request sample in MWT."
- "Store this idea in a note in MWT."
- "Add flash cards to MWT with the key decisions of this thread."

The agent can create, search, and read these items in the identity that issued
the token. HTTP samples are saved without sending a request. New items appear
in open tool pages, and tool results include links to open them in MWT.

Agent access is local to this machine. Configure your agent once: its token
persists across locks and restarts and works whenever the vault is unlocked.
Generating a new token replaces the previous one; **Disable access** revokes
it immediately. See [the MCP integration guide](docs/mcp.md) for the
tool catalogue, native diagram examples, and protocol details.

## Linux packages

With Docker and Docker Compose, build Debian and RPM packages into `dist/`:

```bash
./scripts/build-linux.sh
```

The default target is `linux/amd64`. Set `PACKAGE_PLATFORM=linux/arm64` to build
ARM64 packages.

## Releases and updates

Publishing a GitHub release builds the Debian and Fedora packages and attaches
them with `SHA256SUMS` and its Ed25519 signature, `SHA256SUMS.sig`. The
installed app checks the latest release a minute after it starts, once a day
and from **Check for updates** in the settings menu; it installs a newer one
only when the signature verifies with the release key it ships
(`priv/release_signing_key.pub`) and the package matches its checksum.
**Install from a file…** installs a package you downloaded instead. See
[docs/releases.md](docs/releases.md) for the signing key and cutting a release.
