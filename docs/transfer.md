# Export and import

This is the design of MWT's export and import as it is built: what an
export is for, the file, what opening one trusts, and how each system's
data leaves and comes back. `MWTClient.Transfer` does the work, and
*Export and import* (`MWTClientWeb.TransferLive`) is its page.

## What it is for

Everything MWT keeps for you belongs to one identity, encrypted under its
password. An export puts your toolbox into one file you can carry: the
HTTP client's history (requests you sent, samples you saved), your notes,
diagrams and flash cards, and what you set up for the agent sandbox
(credentials, networks, grants, presets, the text agents read). You import it on
another machine, with the password you signed in with when you exported;
into another identity, which opens it only with that password too; or
later, from a copy you kept, merged with what you have or replacing it.
Backups (`MWTClient.Storage.Backups`) are another mechanism: copies of
one identity's databases, which no other identity imports.

## The file

    <<"MWTEXPORT", version::8, header_size::32, header::binary, payload::binary>>

| Part          | Holds                                                                    |
| ------------- | ------------------------------------------------------------------------ |
| `MWTEXPORT`   | Nine bytes that say it is an export                                      |
| `version`     | The file format's version, `1`                                           |
| `header_size` | The header's length in bytes, big endian                                 |
| `header`      | JSON: `kdf` (`algorithm`, `iterations`, `length`, base64 `salt`), `verifier` |
| `payload`     | The contents, compressed, then sealed                                    |

Opened, the contents are a map of `created_at` (UTC), `username`,
`app_version` and `sections`: one per participant, under its key, each
`%{version: n, data: term}`. Any other shape is refused as damaged.

The page offers `~/mwt-export-<username>-<date>.mwtexport`
(`Transfer.filename/2`) and adds `.mwtexport` to a path without an
extension. The file is written beside its destination as
`<path>.<n>.part` and renamed into place, so a failed export leaves an
earlier one at that path as it was.

### Sealing

The file is sealed under the identity's own key: the one its password
derives at sign in, PBKDF2-HMAC-SHA512 into 32 bytes with the salt and
iteration count of its `vault.json` (600,000 iterations for an identity
made now). `MWTClient.Vault.Keyring` holds that key while the identity is
unlocked and seals without handing it out. The header copies
`vault.json`'s parameters and salt (`Keyring.kdf/1`), so the password
derives the same key anywhere.

- Each sealed blob is `MWTClient.Vault.seal/2`: AES-256-GCM, a random
  12-byte nonce, a 16-byte tag, laid out `<<1, nonce, tag, ciphertext>>`.
- The **verifier** is the constant `mwt:export:verifier:v1`, sealed under
  the same key and opened first. It tells a wrong key from a damaged
  file: it doesn't open to the constant, `:bad_password`; it does and the
  payload doesn't, `:damaged`.
- The **payload** is `:erlang.term_to_binary(contents, compressed: 6)`,
  sealed: compressed first, since ciphertext doesn't compress.

`Archive.decode/2` takes an opener. `{:open, fun}` opens with the
identity's own key through the keyring: `Transfer.read/3` uses it unless
given a password, and derives nothing. `{:password, password}` derives
the key again from the header. Each identity has its own salt, so another
identity with the same password still has to type it.

### What the file shows without the password

That it is an export (MWT's or MDT's) and its format version; the KDF
parameters and salt, those of the identity's `vault.json`, so every
export an identity makes under one password carries the same salt and
two files can be told to come from one identity; the payload's size, the
compressed contents plus 35 bytes, which says roughly how much you keep;
and, if you kept the name the page offered, the identity and the date.
No section name, count or text is in the clear (`archive_test.exs`).
Someone with the file can guess passwords offline at the cost of PBKDF2
with those parameters, as a copy of `vault.json` allows: an export is as
strong as your password.

### Versions

| Version       | Where                                      | Newer than this build                             |
| ------------- | ------------------------------------------ | ------------------------------------------------- |
| File format   | The byte after the magic                   | Refused, `:unsupported_version`                   |
| Section       | Each participant's `version/0`, in the file | The whole file refused, `{:newer_section, label}` |
| `app_version` | In the contents                            | Shown on the preview, nothing else                |

A file of this version cut short inside its header is `:damaged`, not
newer. An older section goes to `prepare/2` with its version, which
reads it into today's shape; every participant is at version 1. A section whose
key no participant has (one a newer build added) is skipped and listed,
not refused.

### Exports from MDT

MWT was called MDT, and MDT's exports still import. They start
`MDTEXPORT`, seal `mdt:export:verifier:v1`, and name MDT's modules.
`Archive.decode/2` opens them as MWT's, then renames every atom in the
contents: `Elixir.MDTClient…` becomes `Elixir.MWTClient…`, `:mdt` becomes
`:mwt`; strings stay as they are. Each magic checks its own verifier, so
an `MWTEXPORT` file holding MDT's is refused as the wrong password. The
file picker offers `.mdtexport` beside `.mwtexport`. `archive.ex` is the
one place that reads anything of MDT's.

## What opening a file trusts

Opening a file and importing it are two steps; the first changes nothing.
`Transfer.read/3` reads the whole file into memory, matches the magic and
version, and parses the header. The KDF must be `pbkdf2-hmac-sha512`, 32
bytes, with 1 to 10,000,000 iterations (over 15 times today's setting),
or the file is `:damaged`: the header is read before anything is
authenticated, and this bound keeps a file from asking for a derivation
long enough to hang MWT when a password is typed. Then the verifier and
the payload are opened, AES-GCM checking each tag first, and the payload
is decoded with plain `:erlang.binary_to_term/1`, without `:safe`, for
the reason `MWTClient.Vault.open/2` gives. Last, the contents' shape and
each section's version are checked, and every section goes through its
participant's `prepare/2`, which checks each item and changes nothing.
One section that fails refuses the whole file.

So what is trusted is **whoever held the key**. A payload decodes only
once it authenticated, so it was written by someone who had the
password: you, elsewhere, or someone who gave you a file and its
password. Past the key, a file you made and one that person crafted look
the same:

- **Decoding makes whatever terms the payload holds**, atoms included,
  as many as it carries.
- **Participants check shapes, not intent.** Each item must have the
  fields and types MWT writes, and ids of the shape MWT gives; its
  content is taken as yours. A history entry keeps the `Req.Request` it
  holds, but sending it again builds a new request from its method, URL,
  headers and body (`Translation.to_req/1`).
- **The sandbox's section brings what acts on this machine.** Saved
  commands' scripts, credentials' mint commands and grants' start
  settings come as the file says, and new grants come in started: one set
  to start on, auto-approved, lets uses through as soon as the import
  ends. The preview names each of them before anything changes
  ([The preview](#importing-from-the-page)). Import a file you didn't
  make as you would type its author's setup in by hand.

Even with the key, a file can't write a preset outside the identity's
`sandbox/presets/` (names must pass `Presets.file_name?/1`, and the JSON
is checked when presets load, as a file you put there is), can't name a
file in the VM outside its folder ([ids are checked](#checked-on-the-way-in)),
and can't leave an identity half imported ([A failed import](#a-failed-import)).
No size is limited: export and import hold the whole contents in memory,
compressed and not, while they run.

## Participants

`MWTClient.Transfer` owns no data. Each system that does implements
`MWTClient.Transfer.Participant` and is listed in
`Transfer.participants/0`, in the order sections are imported.

| Participant                     | Key                   | Carries                                                                     | Same item when                          |
| ------------------------------- | --------------------- | --------------------------------------------------------------------------- | --------------------------------------- |
| `MWTClient.HttpClient.Transfer` | `http_client.history` | Every history entry, samples included: metadata, request, response or error | Same start and end instants, method, URL |
| `MWTClient.Diagrams.Transfer`   | `diagrams.library`    | Each diagram's id, title, elements and times                                | Same id                                 |
| `MWTClient.Notes.Transfer`      | `notes.library`       | Each note's id, title, body, done time and times                            | Same id                                 |
| `MWTClient.Flashcards.Transfer` | `flashcards.library`  | Each card's text, tags, source, schedule, answers, marks; session settings  | Same id                                 |
| `MWTClient.Sandbox.Transfer`    | `sandbox`             | [Its own section](#the-agent-sandboxs-section)                              | [Merging](#merging)                     |

| Callback      | Contract                                                                                  |
| ------------- | ----------------------------------------------------------------------------------------- |
| `key/0`       | Names the section; in every export, so it never changes once shipped                      |
| `label/0`     | What the page shows                                                                       |
| `version/0`   | The shape `export/1` produces; bump it when that changes, and teach `prepare/2` the older ones |
| `export/1`    | Everything the participant keeps for an identity                                          |
| `prepare/2`   | Checks and upgrades a section, rebuilds what is derived; changes nothing; errors are sentences the page shows |
| `describe/1`  | The preview's count, such as "42 requests"                                                |
| `merge/2`     | Combines with what is there, losing nothing; idempotent, so the same file twice changes nothing |
| `replace/2`   | Puts the section in place of what is there; also how a failed import is undone            |

`for_file/2` is optional and not a callback: where a participant has one
(only the sandbox), `Transfer.export/3` trims the section through it.
What `export/1` returns untrimmed is what a failed import puts back.

The libraries leave out the history's identifiers (a replace gives fresh
ones) and every search text (rebuilt by `prepare/2`), and carry notes,
diagrams and cards as plain maps, so a file never depends on a build's
structs. Each writes its items through its store's `rewrite/2`, in one
database transaction. Merging notes, diagrams and cards, the version
changed last wins; when that is the file's and yours differs, yours stays
beside it as a copy (titled "… (before import)" for notes and diagrams)
whose id derives from the version it keeps, so a second import finds it.
A card's answers alone make no copy. Merging keeps your flash card
settings; replacing takes the file's. A request both histories hold
keeps yours, gaining the tags it lacks and the file's description if it
has none; the history is ordered by when each request completed.

## The agent sandbox's section

`MWTClient.Sandbox.Transfer` checks the section;
`MWTClient.Sandbox.Server.Transfers` makes it from the sandbox's state
and imports it, inside the sandbox's server.

| Part          | What goes in                                                                                 |
| ------------- | -------------------------------------------------------------------------------------------- |
| `credentials` | Each credential your grants use: how its value is made, its placeholders, how `mwt exec` presents it |
| `values`      | Their stored values, only when you tick *Include stored credential values*; empty otherwise  |
| `networks`    | Each network your grants are over, the Internet aside, which is MWT's: its id, name, destinations, DNS server and interface |
| `grants`      | Your grants and actions as you defined them, start setting and *Always ask me* included, the grants over one host of a network (the Internet's included) among them |
| `built_in`    | Ask to run commands, MWT's tools, the Internet: each one's start setting, *Always ask me* and host list, not its definition, which is MWT's. The host list is empty since hosts became grants of their own; a file from before holds the Internet's there |
| `presets`     | Your preset files (`sandbox/presets/*.json`), by name, as text                               |
| `settings`    | *This machine, for agents*, your way of working, the folders confined commands may read      |

Each grant is put to rest, with no time left, allowance or use count,
and each credential's `locked` is cleared. Grants agents proposed
that you haven't reviewed stay out, as do credentials only they use and
every minted value.

The folders confined commands may read (`confine_reads`) go as paths
only, never what they hold. Your home folder is written `~`
(`~/.local/share/mise`), so the list fits another machine, and is
expanded against that machine's home on the way in. Left unset (the
folders your login shell's `PATH` runs tools from), it goes unset.

### Checked on the way in

`prepare/2` reads version 1 and refuses the file when:

- a credential or a network lacks a string id and name, or a grant a
  string id, name, or a kind among token, network, command and request;
- a credential's id, a network's id, a grant's id or the credential a
  grant names isn't lowercase letters and digits in words joined by
  single dashes, at most 100 bytes. Ids name files in the VM
  (`/mnt/mwt/grant-env/<id>.sh`, `/mnt/mwt/tokens/<id>`) and elements on
  MWT's pages, so `../../etc/x` or `a b` must never reach them
  (`sandbox/transfer_test.exs`);
- a network is the Internet, which is MWT's, or its destinations aren't
  a list of strings;
- a command grant has no script. That is Ask to run commands' shape,
  which is MWT's own: one from a file would be a second escape hatch;
- an entry of a built-in grant's host list isn't a host of at most 255
  bytes with an action among ask, auto and block (`host_rule?/1`);
- a preset's name fails `Presets.file_name?/1`.

The settings are checked as their form checks them: host notes up to
4,000 characters, way of working up to 20,000, and 1 to 50 folders, each
`~`, `~/…` or `/…`. One that fails is `:invalid`, and leaves yours as it
is whichever way you import. One the file doesn't have is blank, or, for
the folders, unset. A stored value under an id of another shape, or not
a string, is dropped. A built-in grant's start setting and *Always ask
me* are checked as they are applied. Credentials, networks and grants
then go through `Credential.upgrade/1`, `Network.upgrade/1` and
`Grant.upgrade/1`, as saved state does: a grant's reach saved as
`:subgrants` is read as `:actions`, and a preset `request_subgrant` as
`request_action`. A grant's checks, in a file from before 2026-11-24,
are left behind, without the activity log line MWT's own start writes
for them.

From `prepare/2` on, the stored values travel sealed in a function
(`values: fn -> values end`), as a value on its way to the vault does.
`describe/1` and `Server.Transfers` open it (`prepared.values.()`) where
they need the values. A crash report or an exit reason that prints the
prepared section, or the message carrying it to the sandbox's server,
prints a function, not the values.

### Merging

Merging keeps everything there, and the same file twice changes nothing,
but for the Internet's host list of a file from before networks (step 4).

1. **Credentials.** One with a new id comes in, with its stored value if
   the file has one. One with your id, made the same way (the same name
   and the fields its grants copy, `Credential.copied/0`, placeholders
   aside), is yours already. One with your id made another way comes in
   beside yours as `<id>-imported` (then `<id>-imported-3`, and on).
2. **Grants and actions.** Each follows its credential or parent if
   that came in under a new id. One with a new id comes in started, as
   MWT starts grants (`Server.Grants.start/1`): its start setting makes
   it on (each use asking, or auto-approved), off or disabled, and it
   rests where you set it to. One with your id, the same scope (name,
   kind, hosts, carriers, destinations, credential, signs as, reach) and
   the same definition
   (`Grant.definition/1`: a saved command's script and confinement, a
   request action's request) is yours: nothing changes, even if its
   start setting or *Always ask me* differ. One with your id and another
   scope or definition comes in beside yours under a new id, disabled, to
   review, as a grant an agent proposed waits for you.
3. **Networks.** One with a new id comes in. One with your id stays
   yours, and the file's grants over it take its DNS server and
   interface, and, over all of it, its destinations
   (`Network.attach/2`).
4. **Built-in grants** take the file's start setting where they can (it
   applies from MWT's next start) and its *Always ask me*. A file from
   before networks may hold the Internet's host list: each entry becomes a
   grant over that host of the Internet, as below. Yours being empty by
   then, merging such a file again makes them again, under new ids
   (`internet-paste-example-2`).
5. **Presets** are written only where none of yours has the name.
6. **Settings** are taken only where yours are blank or unset, and never
   from one the section found `:invalid`.

Every credential that comes in, new or beside one of yours, gets
placeholders made anew (`Server.Transfers.fresh/1`): its placeholder in
the shape of the old one, the same prefix (`ghp_`) and new random
characters (`Server.Grants.fresh_placeholder/1`); its login's refresh
placeholder, where it has one (`Grant.new_login_placeholder/0`); and no
earlier placeholders (`aliases`, `login_aliases`). A placeholder from a
file could be one of yours, and two credentials must never answer to
the same one. Since "made the same way" sets placeholders aside,
importing a file again still changes nothing.

Then a network grant from a file of before networks is given its
network, and each host list, a grant's or the built-in Internet's, becomes
grants over those hosts (`Network.migrate/2`, as MWT does with saved
state as it starts: Ask on and always asking, Auto on and auto-approving,
Block off and not askable); every network grant takes its network's
fields, every token grant its credential's (`Credential.attach_all/2`);
the activity log gets one event ("Grants imported (merged): N grants, M
credentials"); and what the VM reads at `/mnt/mwt` is written again
(`State.write_inbox/1`).

### Replacing

The file's credentials, stored values, networks and grants take the
place of yours: every grant of yours goes, proposals waiting for review
included, and the file's come in started, as above; the Internet stays
MWT's. Placeholders stay as the section has them, not made anew, since
replacing is also how a failed import puts back what was there. A file
without stored values leaves every stored credential without one, to
paste again. The built-in grants take the file's settings whole, an old
file's Internet host list becoming grants over its hosts as in merging.
Host notes, way of working and the folders become the file's, blank or
unset included (no folders means those your login shell's `PATH` runs
tools from); one the section found `:invalid` leaves yours.

Replacing removes no preset: the file's are written over yours of the
same name, and yours the file lacks stay.

## Importing from the page

The page works in paths on this machine: the desktop app's file dialogs
pick them, and in a browser you type them.

**Opening.** *Open file* runs `Transfer.read/3` with your own key. A file
that key doesn't open (another identity's) comes back as the wrong
password, and the page asks for the one it was made with; *Use a
different password* asks up front.

**The preview** (`MWTClient.Transfer.Plan`) shows when the file was made,
by which identity and MWT version (and, when that identity isn't you,
that its data goes into yours); each section to import, with its
participant's `describe/1`; and each section skipped. The sandbox's
summary counts grants, credentials, networks (when it has any) and
stored values, then names what acts on this machine:

    3 grants, 2 credentials, 1 network. Runs on this machine: mints for BigQuery.
    Saved commands, run on this machine when called: Deploy. Starts on:
    Datalake, Search (auto-approving). Arrives without a value: Datalake

Each list is left out when empty. They describe the file, not what
merging will change: a grant identical to yours is listed though it
changes nothing. A file with nothing to import can't be confirmed. The
plan holds the decrypted data until you confirm or cancel; its sections
are left out of `inspect`, so a log line or crash report that prints
the plan shows none of it.

**Merge or replace.** Merge is the default, since it can't lose anything.

| Mode    | Each section in the file                        | What you had                                          |
| ------- | ----------------------------------------------- | ----------------------------------------------------- |
| Merge   | Combined with yours, by its participant's rules | Kept; where the file's item wins, yours stays beside it |
| Replace | Takes the place of yours                        | Gone, with no undo, as the page warns                 |

Either way, a participant the file has no section for is left alone, and
so is one whose section was skipped.

### A failed import

`Transfer.import/3` writes the sections in order. Before each but the
last, it takes what the participant holds (`export/1`, then
`prepare/2`). When a write fails, raises or exits, the sections already
written are put back, newest first, through `replace/2`, and the page
names the section that failed. A put back that fails is logged, not
retried.

The section that failed isn't put back, so its write has to fail whole.
The libraries' item writes are transactions, but flash cards' `replace/2`
saves the settings in a second step, and the sandbox writes preset files
before it changes its state. The sandbox's section comes last, so it is
never put back, which matters: its `export/1` leaves out proposals and
grants' current states, and putting it back would lose them.

## What isn't carried

- **What lasts a session**: grants' states beyond their start settings,
  time left, allowances, use counts, and your locks.
- **Minted values**, the ID tokens beside them and the values made from
  them, which belong to logins on the machine that minted them; stored
  values unless you tick the box.
- **Grants agents proposed that you haven't reviewed**, and credentials
  only they use.
- **The activity log, handoffs, projects, and the VM**: its disks (the
  agents' memory on them included), builds and snapshots.
- **The CA.** The code gives no reason; `docs/agent_sandbox.md` lists how
  it moves as still open.
- **The sandbox's other settings**: shared folders, the image, CPUs and
  memory, the firewall's settings, which hosts MWT reads.
- **Versions of notes, diagrams and cards.** Only current items go, and
  an item a replace removes loses its versions.
- **Anything outside the five participants**, such as the MCP token
  (`MWTClient.MCP.Access`).
