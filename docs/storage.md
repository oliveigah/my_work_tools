# Storage

Status (2026-11-16): all eight steps are built. Every identity opens an
encrypted `library.db` and `journal.db` when it unlocks; notes, diagrams, flash cards,
their versions and the small state live in `library.db`, the HTTP client's
history and samples in `journal.db`, all imported from the `.bin` files at
the first unlock, and agent activity in `journal.db` for as long as its
rule says. No sealed file of an identity's data is written any more; the password's key seals only the verifier, the data key and
exports. See [Spike 1](#spike-1-the-build) and
[Order of work](#order-of-work).

## What it is for

MWT keeps what you make (notes, diagrams, flash cards, saved requests) and
what happens (HTTP history, what agents do in the VM). Both should be able
to grow for years without MWT using more memory, and without one save
costing more as the rest grows.

1. **Memory stays flat as data grows.** What is on screen and what was
   read recently is in memory. Everything else is on disk.
2. **A change costs what it changes.** Saving one note writes that note,
   and recording one event writes that event.
3. **Nothing reaches the disk in the clear.** Every file is encrypted. The
   key comes from your password, and locking MWT closes the files and
   drops the key.
4. **You decide what is kept.** Each kind of data has a retention rule you
   set, and the Storage page shows what everything takes, the VM's disks
   included.

## Not covered

- **Hiding how much you keep.** File sizes are visible to anyone who can
  read your home folder, as they are now.
- **Plaintext in memory while unlocked.** SQLite's page cache holds
  decrypted pages, and the BEAM can't wipe binaries. Locking closes the
  databases, which frees their memory.
- **Syncing between machines.** Exports and backups move data; nothing
  merges two machines.
- **An old page put back.** Integrity is per page, not per file: someone
  who can write the files and kept an older copy can put back an older
  version of a page, and the database becomes a mix of two of MWT's own
  writes that never existed together. A page moved to another place is
  caught. Write access to your home folder beats MWT in other ways anyway.
- **Which pages each save touched.** The write-ahead log's frame headers
  and its `-shm` index (page numbers, counts, checksums, no content) and
  the page size in page 1 can be read. Someone copying the disk again and
  again can see which pages each save touched, not what they hold.
- **A key that leaked.** The data key never changes: a password change
  (not built yet) re-seals it, which doesn't lock out someone who already
  has an old `vault.json` and the old password, or the data key itself.
  When a password change is built, "my password leaked" should make a new
  data key and re-encrypt with `PRAGMA rekey`.

## Decisions

| Date       | Decision                                                                                                                                                       |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-11-16 | Data lives in SQLite databases encrypted page by page, through Ecto and exqlite, linked against SQLite3 Multiple Ciphers. Memory is a bounded cache, not the store. |
| 2026-11-16 | Two databases per identity: `library.db` for what you make, `journal.db` for what happens. They differ in how they grow, how durable each write must be, and what retention means. |
| 2026-11-16 | A random data key per identity, wrapped by the key derived from your password. Changing the password re-wraps the data key; it never re-encrypts the data. |
| 2026-11-16 | Exports stay sealed with the password-derived key, in today's format, so a password opens them on any machine.                                                 |
| 2026-11-16 | Plain SQLite with rows encrypted by MWT was rejected: nothing inside the content could be searched or queried. Turso was rejected for now: 0.x, local encryption experimental, unofficial Elixir bindings. |
| 2026-11-16 | Search keeps today's meaning (every word, anywhere in the text) through FTS5's trigram tokenizer.                                                              |
| 2026-11-16 | Agent activity is kept as one row per event. Request and response bodies are not kept unless you turn that on.                                                |
| 2026-11-16 | The Storage page shows and manages MWT's data and the VM's disk space on one page.                                                                              |
| 2026-11-16 | Every kind of thing kept has its own retention rule; none is shared between kinds. The defaults in [Retention](#retention) are a starting point, changed later. |
| 2026-11-16 | HTTP request samples saved but never sent stay with the history, in `journal.db`: the client lists them with it, under one numbering. Retention never removes one. |
| 2026-11-16 | Terms in the databases are compressed with zstd (OTP 28's `:zstd`), level 3: a 1 MB response in about 2 ms, where zlib took 8 (level 1) to 20 (level 6), for a similar size. |
| 2026-11-16 | No `auto_vacuum`. With a cipher that reserves bytes in each page (chacha20, sqlcipher, ascon128, aegis: every authenticated one), SQLite3 Multiple Ciphers 2.7.1 reported "database disk image is malformed" while creating the library's FTS5 tables under `auto_vacuum`, incremental or full; plain SQLite and the ciphers that reserve nothing did not. Freed pages are reused by later writes, and Compact gives space back to the disk. See [Why no auto_vacuum](#why-no-auto_vacuum). |

## Today, and why it changes

Each store is a process holding all its data decrypted. 250 ms after a
change it encrypts the whole store into one term (`MWTClient.Vault.seal/2`)
and writes the file again. Measured on 2026-11-16 with the real stores
(`notes.bin`, `http_history.bin`):

| What                         | 2,000 notes (13 MB) | 10,000 notes (65 MB) | History, 100 × 1 MB |
| ---------------------------- | ------------------- | -------------------- | ------------------- |
| Unlock (read and decrypt)    | 26 ms               | 125 ms               | 69 ms               |
| One save, whatever changed   | 19 ms               | 104 ms               | 159 ms              |
| A read waiting on that save  | 15 ms               | 97 ms                | not blocked (ETS)   |
| Extra memory while saving    | about 26 MB (estimate) | about 130 MB (estimate) | about 217 MB     |

The estimates are the plain and the encrypted copy, both held while
writing. Gets, lists and searches are microseconds to a few milliseconds,
because everything is in memory. That is also the limit: nothing can be
kept that doesn't fit in memory, and every save costs the size of the
store. HTTP history has no bound, and its save writes over the file in
place, so a crash during it leaves half a file.

## Files

Per identity, in `identities/<id>/`:

| File          | Holds                                                                                              | Writes                                              |
| ------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `vault.json`  | KDF parameters, salt, verifier, the wrapped data key, the databases' cipher settings               | at sign-up, password change, migration              |
| `library.db`  | notes, diagrams, flash cards, versions, and the small state that is a blob today                   | each change, in its own transaction, `synchronous=FULL` |
| `journal.db`  | HTTP history and samples, agent activity                                                           | batched once a second, `synchronous=NORMAL`        |
| `backups/`    | copies made by "Back up now", each with a copy of `vault.json`                                     | on demand                                           |
| `legacy/`     | the `.bin` files and `versions/` folder from before, moved here after import                      | once                                                |

Both databases run in WAL mode, without `auto_vacuum` (see
[Decisions](#decisions)): pages freed by retention are reused by later
writes, so a database settles at the size of what its rules keep, and
Compact gives the rest back to the disk.

`journal.db` can lose its last second on a power cut, never its
consistency. `library.db` doesn't lose a save that returned.

## Keys

- **The password key** is derived as today: PBKDF2-SHA512, 600,000
  iterations (about 150 ms). It opens the verifier and the data key, and
  seals exports.
- **The data key** is 32 random bytes, made at sign-up (or at migration),
  sealed with the password key into `vault.json`.
- **Each database's key** is `HMAC-SHA256(data key, "mwt:storage:<name>:v1")`,
  so each file has its own key.
- **Opening a database** passes its key as hex in `PRAGMA key`, with the
  cipher in the URI: `file:…/library.db?cipher=chacha20&kdf_iter=1`. The
  key is random, so SQLite3 Multiple Ciphers' own KDF adds nothing; at its
  default (64,007 rounds) it costs 25 to 31 ms per connection. The cipher
  settings are kept in `vault.json`, since a file opens only with the ones
  it was made with.
- **The encryption itself** is SQLite3 Multiple Ciphers' C code (its
  chacha20 cipher comes from sqleet), not OpenSSL: the file's key is
  derived from the database key with PBKDF2-SHA256, one round, and the
  file's salt; each page is encrypted with ChaCha20 and authenticated with
  Poly1305, with a random 16-byte nonce per write and the page number in
  the counter; the tag is checked before a page is decrypted. Write-ahead
  log frames and temporary files go through the same code
  (`SQLITE3MC_ENCRYPT_TEMP_FILES=1`, pinned in the build, as is
  `SQLITE_TEMP_STORE=2`: temporary tables in memory unless a connection
  asks for a file). Sealing the data key is still `:crypto`
  (`MWTClient.Vault`).
- **A wrong key** fails the first read with "file is not a database". The
  key is checked on one connection before a pool starts, because a pool
  given a wrong key retries forever.
- **A build that doesn't encrypt** is refused. Stock SQLite takes `PRAGMA
  key` and the URI's cipher without a word and writes plain text, so a
  package linked against it by mistake would. The check connection asks
  `PRAGMA cipher`, which only SQLite3 Multiple Ciphers answers, and the
  answer must be the cipher in `vault.json`.
- **Changing your password** re-seals the data key and nothing else.
  `PRAGMA rekey` exists for rotating the data key itself, which is not
  planned.

## Connections, reads and writes

`MWTClient.Vault.Store` opens both databases at unlock and closes them at
lock, as it starts and stops the stores now.

- **One Ecto repo per database per identity**, started as a dynamic repo
  (`name: nil`) under the vault's supervisor: `library.db` with 4
  connections, `journal.db` with 2. Transactions are `IMMEDIATE`, with a
  5-second busy timeout.
- **Reads run in the caller** (a LiveView, the MCP server), as ETS reads do
  now. Nothing waits behind a write: WAL lets reads go on while one
  writer writes.
- **Writes go through the app's process** (`Notes.Library.save/3` and the
  rest), one per app per identity, which makes each change one
  transaction, durable before it returns, and remembers between calls
  what the version rule asks (who changed an item last, when a version
  was last kept). Each module's public functions keep their names and
  results, so pages don't change. The process holds no data.
- **Memory:** each connection's page cache is capped at 8 MiB
  (`cache_size=-8192`), so 48 MiB in all, whatever the data's size.
  Measured: scanning 182 MB with a 16 MiB cache added 15 MB to the
  process; with 64 MiB, 50 MB.
- **Migrations** are Ecto migration modules in
  `lib/mwt_client/storage/migrations/`, compiled in like the rest, listed
  per database in `MWTClient.Storage.Database` and run at unlock, before
  anything reads.
- **The write-ahead log** is cut back to 64 MiB after each checkpoint
  (`journal_size_limit`); without it, it stays the size of the largest
  transaction (an import, a mass delete) until the identity locks. A read
  held open holds checkpoints back, so reads stay short; the Storage page
  shows each log's size.
- **What is deleted from `library.db`** is overwritten (`secure_delete`),
  not left in a free page for whoever has the key later.
- **Opening refuses rather than guesses.** A file the right key can't read
  ("not a database", "malformed") is set aside as `.corrupt` and a new one
  made; any other failure (a second MWT on the same folder, permissions,
  the disk) fails the unlock, touching nothing, and the sign-in page says
  so. The check connection waits up to 5 seconds for a lock, as the pool
  does.

## What goes where

### Notes, diagrams, flash cards

`MWTClient.Storage.Migrations.LibraryItems` makes the tables. Each item
keeps the `id` it always had, and a `seq`, its row's own number, which the
search index points at. Times are microseconds since 1970, UTC.

- **Notes:** `notes` holds what a list shows (title, excerpt, done,
  times, version); `note_texts` holds the body and its search text, so a
  list never reads a body.
- **Diagrams:** `diagrams` holds the title, the number of elements, the
  times and the version; `diagram_contents` holds the elements, as one
  term per diagram, and their search text.
- **Flash cards:** one row each in `flashcards`, review state included,
  the back and search text last; lists, tags, counts and session picks
  read every column but those two. The session settings are a document
  (see [Small state](#small-state)). `FlashcardsUncertain` (version 3)
  adds the mark of a card the user doubts: `uncertain_at` and
  `uncertain_note`, null while it isn't marked.

### Handoffs

`MWTClient.Storage.Migrations.LibraryHandoffs` (library version 2) makes
the tables; `MWTClient.Sandbox.HandoffRecords` reads and writes them.
Every handoff is kept, with no cap: `handoffs` holds what the list picks
and orders rows by (whether it waits for you, when it changed last, its
project and branch), and `handoff_records` the handoff itself, a term,
with its search text. The sandbox writes one row when that handoff
changes, durable before it answers, and keeps only those waiting for you
in memory.

One landed or closed more than 30 days ago is archived: the Handoffs page
leaves it out unless you include the archived ones, and can then bound
them by the days they changed in. Nothing moves when one is archived; it
is a date the queries compare. One waiting for you is never archived.

They were part of the `sandbox` document until then, the latest 100:
those still there move into the tables the first time MWT starts, or when
a running MWT loads the code that has them.

### Search

An FTS5 table per searchable kind (`note_search`, `diagram_search`,
`flashcard_search`, `handoff_search`), using the trigram tokenizer over
the item's search text, which the app normalizes as it always did. The
index folds nothing itself (`case_sensitive 1`), so it matches exactly
what `MWTClient.Search.matches?/2` matches. Triggers keep it in step, in
the transaction that writes the item. A word of 3 or more characters is
found through the index, anywhere in the text; a shorter one is read in
the search text of each row the rest of the query leaves, which, with
nothing else to narrow it, is every row (`MWTClient.Search.where/4`).

Measured on 10,000 handoffs of about 2.8 KB each (2026-11-22): a search
through the index with both halves' counts and one page took 1 to 6 ms;
a word of 2 letters alone over all of them, 98 ms, and over the last
month, 13 ms. The file took 151 MB, 81 of them the index.

Trigram indexes are large: 10,000 notes of 3 KB made a 109 MB file, where
the text was 30 MB. The Storage page shows it as part of each kind's size.

### Versions

`versions(kind, item_id, version, content, content_hash, saved_at,
replaced_at, replaced_by, how)`, written in the same transaction as the
change it records. `content` is the term compressed (`term_to_binary`,
level 6). A version equal to the one before is not kept twice.

Today's rule for what is kept stays: every change by an agent, every
restore, and your own editing at most once per item per 10 minutes. The
cap of 50 per item stays until age-based thinning (see
[Retention](#retention)) takes its place in step 7, so nothing grows
unbounded in between.

### HTTP history

`MWTClient.Storage.Migrations.JournalHttpHistory` keeps an entry in
three rows sharing its id, the history id the client always showed, given
in order and never given twice, even after a clear:

- `http_requests`: what a list shows (when, how long, description, tags,
  method, URL, status, response size). A status of 0 is a sample never
  sent, 599 a request that failed.
- `http_request_details`: the metadata, the request and the response's
  outline (status, headers, size), as terms, and the search text, under
  a trigram index as the library's.
- `http_responses`: the whole response, as a term.

Lists and searches read the first table only; opening an entry reads the
second; only `get/2` (a tab, an export) reads the third. Search keeps its
meaning: the whole term, spaces and all, anywhere in the search text.

### Agent activity

`events` (`MWTClient.Storage.Migrations.JournalEvents`) holds every event
the sandbox logs (`MWTClient.Sandbox.Event`), one row each: its id, when,
its outcome (the kind: traffic, lookup, swap, ask and answer, block,
grant, VM, host command, project, handoff, tool call), its summary, the
grant, host, port, method and path, bytes each way, how long it took, and
the agent and thread that asked, as they claimed, when it came from one.
Indexed by time, and by outcome, thread and grant, newest first.

Events are written by `MWTClient.Storage.Journal`, one process per
identity, started with the databases, which keeps them and inserts once
a second or every 1,000 events, whichever comes first, and writes what
waits when the identity locks. The sandbox server's in-memory list of the
last 1,000 events is gone: `Sandbox.events/2` and the activity page read
the journal (`MWTClient.Sandbox.Activity`), after the server has taken
what was sent to it and the journal has written what waits, so a read
sees every event logged before it. The server keeps the last 30 in memory
too, for the record the firewall makes when it isolates the VM: that
can't wait on the journal, or fail with it. The Firewall page reads its
findings from the journal.

What a request MWT read carried and what came back
(`MWTClient.Sandbox.Exchange`, `MWTClient.Storage.Migrations.JournalEventExchanges`)
is kept in `events_exchanges(event_id, exchange)`: one compressed term per
event that names it in `events.exchange_id`, each body up to 64 KB. The
journal writes it after the events of its batch, and only for events that
name it; a trigger deletes it with its event, so retention and clearing
cover it, and its size counts as the activity's.

What an event says when its line opens (`MWTClient.Sandbox.EventDetails`,
`MWTClient.Storage.Migrations.JournalEventDetails`, `journal.db` version
4) is kept the same way, in `events_details(event_id, details)`: one
compressed term per event that has some, marked by `events.detailed = 1`
so a page knows to read it, at most 16 KiB of words each before
compression. Written after its event in the same batch, read only when a
line opens, deleted with its event by a trigger. Events from before have
none. The first 2 KiB of them go into `search_text`, so the log's word
filter finds what only the details say (a command's script, a file a
copy back wrote).

Who or what decided each action (`MWTClient.Sandbox.Decision`,
`MWTClient.Storage.Migrations.JournalDecisions`, `journal.db` version 5)
is kept with its line: `events.decided_by` (`you`, `allowance`, `grant`,
`refused`, `timeout`), which the log's *Decided by* filters on, and the
whole decision as a compressed term in `events.decision`, the grant's
state then as a hash, so the log can say it changed since. Each card you
decided, or that timed out, is kept whole with what was chosen on it, in
`events_cards(id, at, card)`, named by `events.card_id`; a sweep of the
retention rule deletes those no line names any more, and a Clear deletes
them all.

Measured: a million events take 7.7 s to insert (129,000 a second; 7.1 s
unencrypted) and 155 MB on disk. One kind in one hour: 0.4 ms. Top hosts
over 100,000 events: 47 ms. A scan of every row's details: 175 ms.

### Small state

The sandbox's state (grants, values, CA, projects), MCP access,
agent threads and the flash cards' settings are small and are read whole.
Each stays a term, in a `documents(name, term, updated_at)` row of
`library.db` (`MWTClient.Storage.Documents`), written as before: the
sandbox and agent threads a moment after a change, MCP access and the
settings at once.

| Document              | Was               | Written by                         |
| --------------------- | ----------------- | ---------------------------------- |
| `sandbox`             | `sandbox.bin`     | `MWTClient.Sandbox.Server.State`   |
| `agent_threads`       | `agent_threads.bin` | `MWTClient.Sandbox.AgentThreads` |
| `mcp.access`          | `mcp_access.bin`  | `MWTClient.MCP.Access`             |
| `flashcards.settings` | `flashcards.bin`  | `MWTClient.Flashcards.Library`     |

A document's file from before is read once, written as the document, and
moved into `legacy/`. A file found beside a document is one whose move
never finished, or one put back by hand, and replaces it. A write that
fails comes back as an error, which MCP access reports as it reported a
file it couldn't write.

## Why no auto_vacuum

Reproduced twice, the second time in C with a SQLite3 Multiple Ciphers
shell built from the same 2.7.1 amalgamation, no Elixir involved: a fresh
database, chacha20, `auto_vacuum` on, then the `LibraryItems` migration
fails at the second FTS5 table with "fts5: error creating shadow table
diagram_search_config: database disk image is malformed".

- It fails with chacha20 (also `legacy=1`), sqlcipher, aegis and
  ascon128; `INCREMENTAL` and `FULL`; WAL and rollback journal; inside a
  transaction or not; any cache size.
- It passes without `auto_vacuum`; with aes128cbc, aes256cbc and rc4,
  which reserve no bytes per page (and so have no tag and no fresh nonce
  per write); and with **plain SQLite reserving 32 bytes per page**
  (`.filectrl reserve_bytes 32`): the bug is in SQLite3 Multiple Ciphers'
  codec, not in SQLite.
- Sixty plain tables with long SQL pass; heavy churn with
  `incremental_vacuum` passes. It takes this migration's FTS5 tables.
- 1 KB pages fail sooner, 8 KB pages pass: a threshold, not a fix.
- Turning `auto_vacuum` on later, by `VACUUM`, then adding three more FTS5
  tables fails again: it would break the next migration that adds a
  search index.
- The failure is loud: the tag check refuses the page, the statement rolls
  back, and a fresh connection's `integrity_check` is `ok`. Possibly
  related upstream: utelle/SQLite3MultipleCiphers#119. Not reported.

What going without costs, simulated over a year (1.5 MB a day, 90 days
kept, ten times as much on days 150 to 152, chacha20): the file levels off
at the most it ever held (223 MB) while what is kept goes back to 170 MB;
retention's frees are reused, and only a burst stays until Compact. Memory
doesn't depend on the file's size (free pages are never read): 13 MB at
most with `auto_vacuum` on or off. Size limits count the pages in use
(`dbstat`), never the file, which never shrinks on its own.

Compact runs `VACUUM` with the connection's temporary store in a file,
which SQLite3 Multiple Ciphers encrypts: with it in memory, compacting a
392 MB database held 322 MB of memory, the whole of it decrypted; in a
file, under 10 MB. (`VACUUM INTO` a new file and swapping it in costs as
little, but swapping needs every connection closed; for a rare action, a
write waiting is the simpler price.)

## Retention

Every kind of thing MWT keeps has a rule of its own, set on the Storage
page (`/storage`, from the header). No setting applies to several kinds at once: note versions and
diagram versions, history entries and history bodies, are each set apart.
The defaults below are where each starts; changing one changes that kind
only, and the page can put it back to its default.

A rule is made of the limits that make sense for its kind, any of which
can be off:

- **age:** keep what is newer than N days;
- **size:** keep at most N GB, the oldest removed first;
- **count:** keep the newest N;
- **thinning** (versions only): every version for N days, then one a day
  until M days, then one a month or none, and at most K of one item.

| Kind (key)                                | Kept in      | Default                                                                                   | Applied by |
| ----------------------------------------- | ------------ | ----------------------------------------------------------------------------------------- | ---------- |
| Note versions (`note_versions`)           | `library.db` | every version for 90 days, then one a day until 365 days, then one a month; at most 100 an item | `Versions.thin/4`, and the most as each is kept |
| Diagram versions (`diagram_versions`)     | `library.db` | the same                                                                                  | the same |
| Flash card versions (`flashcard_versions`) | `library.db` | the same                                                                                 | the same |
| HTTP history (`http_history`)             | `journal.db` | 90 days; size off                                                                         | `Resources.trim/3` |
| HTTP response bodies (`http_bodies`)      | `journal.db` | off: as long as their entry                                                               | `Resources.drop_bodies/3` |
| Agent activity (`agent_activity`)         | `journal.db` | 180 days, at most 5 GB                                                                    | `Journal.trim/3` |
| Backups (`backups`)                       | `backups/`   | the newest 5                                                                              | `Backups.trim/2` |
| Files from before (`legacy`)              | `legacy/`    | off: until you delete them                                                                | `Legacy.trim/3` |
| VM Home snapshots (`vm_snapshots`)        | VM disks     | the newest 3                                                                              | the sandbox, as it takes one |
| VM image builds (`vm_images`)             | msb          | the newest 3, and the one the VM was made from                                            | the sandbox, as it builds one |

Agent activity bodies (`events_exchanges`) have no rule of their own:
they go with their event, under the agent activity rule, and count in its
size.

Notes, diagrams, cards and HTTP samples (`status` 0) are never removed by
retention; the page lists their sizes all the same.

Rules are kept per identity as the `storage.rules` document of
`library.db` (`MWTClient.Storage.Retention`): only the kinds changed, so a
kind left alone follows its default, and a new default reaches it.
`MWTClient.Storage.Janitor` applies them a minute after unlock and every
hour, in batches, and when the page asks. The pages it frees are reused
by what is written next; Compact gives them back to the disk. A size limit
measures (`dbstat`) only when the whole file is over it.

A dropped HTTP body leaves the entry with its status, headers and search
text. Files from before count their days from when they moved into
`legacy/`.

## The Storage page

MWT has no settings page of its own; Storage is a page beside Export and
import and Agent access, opened from the header (`/storage`,
`MWTClientWeb.StorageLive`).

1. **What you made.** Notes, diagrams, flash cards and saved state: how
   many, and what they take. No rule removes them.
2. **What is kept for a while.** One row per kind of the table above: what
   it holds (items, size, the oldest), its rule in words, Changed when it
   isn't the default (which is shown beside it), a form with the kind's
   own limits, a way back to the default, and Clear, which asks first.
3. **Files.** `library.db` and `journal.db`, with the space free inside
   them; Compact (`VACUUM`), Back up now (`VACUUM INTO` into
   `backups/<time>/`, with `vault.json`), Check (`PRAGMA quick_check`),
   Apply the rules now; the data folder and the last backup.
4. **The VM.** Each disk's size against what it takes on this machine,
   the copies of Home (each deleted on its own, asking first), the rules
   for copies and builds, and Reclaim disk space while the VM is stopped
   (`e2fsck -f -y -E discard` on each image, in the background; a test
   image of 366 MB with a 300 MB file deleted came back as 66 MB).

Measuring reads every page of both databases, so the page measures in the
background (`MWTClient.Storage.Usage`).

## Moving from the `.bin` files

At the first unlock with a build that has this:

1. A data key is made and sealed into `vault.json`.
2. Each app, as it starts, reads its `.bin` file and its `versions/`
   folder as it always did, and writes what they hold into the database,
   in one transaction (`MWTClient.Storage.Legacy`).
3. Only once that transaction is committed do the old files move to
   `legacy/`. A file still in place is one whose import never finished:
   it is imported again at the next unlock. An item already in the
   database is kept as it is, with its versions, so importing again
   changes nothing that came in before.
4. A file that won't decrypt, or holds what its app can't read, is set
   aside as `<file>.<time>.corrupt`, as the stores always did. A failure
   to write the database (a full disk) fails the unlock, and leaves the
   files where they were.

Versions of items deleted since their file was written are left in
`legacy/versions/`, unimported.

Each record goes in under a savepoint of its own: one an older build kept
that doesn't fit the tables (a time missing, a field of another type) is
rolled back alone, kept sealed with the password in
`legacy/<file>.not-imported-<time>`, logged, and counted on the Storage
page. No record stops an unlock.

The `vault.json` from before the data key is kept too, as
`legacy/vault.json`. A data key is never made beside databases already
there: they were made with one that `vault.json` lost (an older copy put
back), and a new key would set them aside as unreadable and start empty.
The unlock is refused instead, saying why.

### No going back, and the way back

An older build started after the upgrade finds no `.bin` files (they are
in `legacy/`) and shows empty libraries. What is made there is written to
new `.bin` files, which the next unlock with this build imports: new items
come in, but changes made there to items that came across are dropped
(the database's are kept). Until this lands, try it on a copy of the data
folder only.

The way back, with MWT quit: move everything in `legacy/` back into the
identity's folder (`vault.json` included), and set `library.db` and
`journal.db` (with their `-wal` and `-shm`) aside. A build from before
then opens the identity as it was at the upgrade.

A rollback-safe import, as Nerves updates firmware, would leave the `.bin`
files in place until this build has proven itself and merge back what an
older build wrote meanwhile. Considered, not built: it would make every
library's import a merge, kept for good, against a risk that a copy of the
data folder covers while testing, and that ends once this lands.

### Checking the import on real data

The tests use made-up data; real files written by older builds are what
can surprise. `scripts/check-storage-import.exs` checks an import on a
**copy** of a data folder, never on `~/.mwt_client` (it refuses that one):

    mkdir -p /tmp/mwt-real/data
    cp -a ~/.mwt_client/identities /tmp/mwt-real/data/
    cp -a /tmp/mwt-real /tmp/mwt-real.orig
    mix run --no-start scripts/check-storage-import.exs /tmp/mwt-real/data USERNAME

It asks for the password (not echoed), reads the identity's files as an
older build would, unlocks it (which imports them the first time), and
compares what each app reads with what the files held: counts, ids missing
on either side, fields that differ by name, versions per item, files set
aside as `.corrupt`, records not imported, and how long the first unlock
took. No titles, bodies or other content. Run against data the build from
before made (`de1da69`): every kind matched, first unlock 0.46 s.

Then, on the copy, with MWT started against it on a port of its own
(`PORT=4999 elixir --erl '-mwt_client data_dir <<"/tmp/mwt-real/data">>'
-S mix phx.server`, never `mix phx.server` bare, which opens
`~/.mwt_client`): sign in and compare counts and a few searches with the
installed MWT; lock, start again, sign in, nothing doubled; check that
`library.db` doesn't start with `SQLite format 3` and that a word from a
note is in neither `library.db` nor its `-wal`. Delete both copies after.

The Storage page offers to delete `legacy/`. Exports keep their format, so
an export from before imports after, and the other way.

## Spike 1: the build

Done 2026-11-16 on Ubuntu 26.04, x86-64, in a scratch project.

| Check                                                                            | Result |
| -------------------------------------------------------------------------------- | ------ |
| SQLite3 Multiple Ciphers 2.7.1 (SQLite 3.54.1) builds as a static, `-fPIC`, `-fvisibility=hidden` library | Pass, 27 s |
| exqlite 0.43 links it: `EXQLITE_USE_SYSTEM=1` and the include and link flags, set at the top of `mix.exs` | Pass   |
| The same flags in a `deps.compile` alias                                          | Fail: `mix compile` doesn't run the alias, and downloads exqlite's own NIF |
| The NIF needs only `libc` and `libm`, and exports no `sqlite3_` symbol            | Pass   |
| `mix release` carries it                                                          | Pass   |
| A marker string appears neither in the file nor in its WAL; no SQLite header      | Pass   |
| Wrong key and no key refused; the right key reopens                               | Pass   |
| FTS5 trigram finds a substring                                                    | Pass   |
| `VACUUM INTO` writes an encrypted copy that opens with the same key               | Pass   |
| `PRAGMA rekey`; the old key refused after                                         | Pass   |
| `dbstat` gives the size of each table                                             | Pass   |
| Ecto dynamic repo with `key:`, a migration, WAL                                   | Pass; a fresh file opened by 2 connections at once logged one "database is locked" before retrying |

## Order of work

| Step | What                                                                                                                                       | Done when                                                                                             |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| 1    | The build: the amalgamation pinned by version and SHA-256, downloaded once and built into `_build/sqlite3mc-<version>/` by `scripts/build-sqlite3mc.sh`, which `mix.exs` runs when the library is missing. | `mix precommit` passes from a clean checkout; the deb, rpm and app bundle open an encrypted database on Fedora 44 and Ubuntu 24.04. |
| 2    | `MWTClient.Storage`: the data key, opening and closing both databases with the vault, migrations, the key check before the pool.          | Tests: unlock, lock, wrong password, files opaque, a lock frees the repos.                             |
| 3    | Notes, diagrams, flash cards and versions on `library.db`, with FTS5 and the move from `.bin`.                                            | The apps' tests pass unchanged; the benchmark above rerun at 2,000 and 10,000 notes.                   |
| 4    | HTTP history and samples on `journal.db`.                                                                                                  | The HTTP client's tests pass; 100 × 1 MB history: saving one entry is under 10 ms.                    |
| 5    | Small state in `documents`.                                                                                                                | The sandbox, MCP and agent-thread tests pass.                                                          |
| 6    | Agent activity: the journal writer, every event source, the activity page reading from the journal.                                       | A day of real agent work is in the journal and filterable by thread, kind and time.                    |
| 7    | Retention, the janitor, and the Storage page, the VM's space included.                                                                       | Each kind's rule and each action has a test; the page shows real sizes.                                |
| 8    | `legacy/` removal from the page; exports both ways between a build before and after.                                                       | An export from before imports after, and the other way.                                               |

Steps 1 and 2 were built on 2026-11-16:

- **The build.** `scripts/build-sqlite3mc.sh` and the top of `mix.exs`,
  which pins SQLite3 Multiple Ciphers 2.7.1 by SHA-256 and hands the
  script the Erlang running mix (a version manager's shim may not know
  which `erl` to run outside the project). Both package stages copy the
  script. Checked: a missing library is rebuilt by any `mix` command; a
  wrong checksum is refused; the library also builds on Ubuntu 24.04
  (gcc 13, glibc 2.39). Not checked: the deb, rpm and app bundle
  themselves, which need `scripts/build-linux.sh` on a machine with
  Docker.
- **The foundation.** `MWTClient.Storage` (one supervisor per unlocked
  identity, started by `MWTClient.Vault.Store` before the stores and
  stopped after them), `MWTClient.Storage.Database`, the two repos, and
  `MWTClient.Accounts.data_key/2`. An existing data key is never
  replaced, even beside missing settings. Neither database has a
  migration yet: step 3 adds the first. `test/mwt_client/storage_test.exs`
  covers the rest of step 2's "done when", plus each database's own key,
  keys whose hex starts with a digit (exqlite puts its `:key` option into
  the statement unquoted), paths with `%`, `?` and `#`, and cipher
  settings that try to add to the URI.

Step 3 was built on 2026-11-16:

- **The schema.** `MWTClient.Storage.Migrations.LibraryItems`, the first
  migration of `library.db` (see [What goes where](#what-goes-where)).
  `MWTClient.Storage.Values` turns times and terms into columns and back;
  `MWTClient.Storage.transaction/3` runs a function in a transaction that
  takes the write lock when it starts.
- **The apps.** `Notes.Library`, `Diagrams.Library` and
  `Flashcards.Library` keep their public functions, names and results.
  Reads run in the caller; writes go through each library's process, one
  transaction each, and broadcast once committed. The save-after-a-pause
  timer and the whole-file seal are gone from all three. A time comes
  back to the microsecond whatever precision it went in with, and a write
  answers with what a later read gives.
- **Search.** `MWTClient.Search.where/4` builds the condition; the
  meaning is unchanged, short words included.
- **Versions.** `MWTClient.Versions` keeps its rule and its functions, on
  the `versions` table, written in the transaction of the change. A
  version the same as the newest kept is not kept twice.
- **The move from `.bin`.** `MWTClient.Storage.Legacy`, and an import in
  each library, as [Moving from the `.bin` files](#moving-from-the-bin-files)
  says.
- **No `auto_vacuum`**, after the corruption in [Decisions](#decisions).
  The repro is a fresh database, a cipher that reserves bytes,
  `auto_vacuum` on, and this migration's statements in order; any of them
  left out, it passes.
- **Tests.** Every behaviour test of the three apps, transfer and MCP
  passes unchanged. The five that read `notes.bin`, `diagrams.bin`,
  `flashcards.bin` or `versions/` to check they were encrypted now read
  `library.db` and its WAL, and two `Versions` tests open it without the
  key it no longer needs. `test/mwt_client/storage/library_items_test.exs` adds the
  import (versions, settings, `legacy/`, an import made again, a file that
  can't be read), search (every word, short words, case, quotes, edits,
  deletes, rewrites) and `integrity_check` on the database and its three
  indexes.

The benchmark of [Today](#today-and-why-it-changes), rerun on
`library.db` with notes of 3 KB, in the same VM:

| What                                   | 2,000 notes | 10,000 notes | Before (2,000 / 10,000) |
| -------------------------------------- | ----------- | ------------ | ----------------------- |
| `library.db`, file and WAL             | 32 MB       | 129 MB       | 13 / 65 MB              |
| First unlock, importing `notes.bin`    | 1.0 s       | 4.9 s        | once only               |
| Unlock                                 | 7 ms        | 8 ms         | 26 / 125 ms             |
| One save                               | 4.2 ms      | 4.3 ms       | 19 / 104 ms, after a pause |
| List all                               | 3.4 ms      | 22 ms        | in memory               |
| Search, two words in every note        | 5.8 ms      | 24 ms        | in memory               |
| Search, a word in none                 | 0.1 ms      | 0.2 ms       | in memory               |
| Search, a two-letter word              | 20 ms       | 89 ms        | in memory               |
| Get one note                           | 43 µs       | 77 µs        | in memory               |
| A search while 200 saves run           | 6.7 ms      | 34 ms        | waits for the seal: 15 / 97 ms |
| Memory after 200 saves                 | no growth   | no growth    | a second copy per save  |

A save costs the same whatever the library holds, a read never waits for
it, and memory holds no notes. What grows with the library is reading many
rows: a list of all 10,000 notes, or a search most of them match, takes
tens of milliseconds, where memory took a few. Two-letter words read
every note's text. The file is about four times the text: the body, its
search text, and the trigram index.

Step 4 was built on 2026-11-16:

- **History.** `MWTClient.HttpClient.Resources` keeps its functions and
  results, less `table/1`, `counter/1` and `touch/1`, which handed out its
  ETS table; `update/3` changes an entry's metadata and search text in
  one transaction instead, for `MWTClient.HttpClient.Core`. Recording,
  updating, deleting and clearing run in the caller; only `rewrite/2`
  goes through the store's process. The ETS tables, the counter, the
  save-after-a-pause timer and the background reindex are gone: the
  import builds every entry's search text afresh.
- **The move from `http_history.bin`**, as the libraries' (see
  [Moving from the `.bin` files](#moving-from-the-bin-files)), keeping
  each entry's id.
- **Tests.** The client's, MCP's and transfer's tests pass unchanged but
  for the four that read `http_history.bin`: two now check `journal.db`
  is encrypted, one that an entry and a tag edit are committed when they
  return, and the one that put an old search text in the ETS table now
  imports it from a `http_history.bin`, with a sample, and checks ids,
  search and `legacy/`.

The history benchmark of [Today](#today-and-why-it-changes), rerun on
`journal.db` with JSON-like bodies:

| What                            | 500 × 10 KB | 200 × 100 KB | 100 × 1 MB | Before, 100 × 1 MB      |
| ------------------------------- | ----------- | ------------ | ---------- | ----------------------- |
| `journal.db`, file and WAL      | 22 MB       | 27 MB        | 36 MB      | about 100 MB, uncompressed |
| First unlock, importing         | 0.8 s       | 0.7 s        | 0.7 s      | once only               |
| Unlock                          | 12 ms       | 9 ms         | 9 ms       | 69 ms                   |
| Record one entry                | 2.6 ms      | 3.0 ms       | 9.3 ms     | 159 ms, sealing all     |
| Summaries, all                  | 4.9 ms      | 1.6 ms       | 0.9 ms     | in memory               |
| Search, no match                | 0.3 ms      | 0.1 ms       | 0.1 ms     | in memory               |
| Outline of one                  | 0.2 ms      | 0.1 ms       | 0.1 ms     | in memory               |
| Get one, body and all           | 0.2 ms      | 0.2 ms       | 1.1 ms     | in memory               |
| Memory after 20 more records    | no growth   | no growth    | no growth  | about 217 MB held while sealing |

Recording a 1 MB response is about 3 ms of encoding (1 ms building its
search text, 2 ms compressing it) and 6 ms of writing, most of it
indexing the 32 KB of the body that is searchable, as before.

Step 8 was built on 2026-11-16:

- **`legacy/` from the page.** Files from before is a kind of its own:
  Clear (which asks first) deletes it, and its rule, off at first, can
  delete it some days after the import. A `versions/` folder emptied by
  the import goes with it.
- **Exports both ways, and the upgrade itself, with the real build from
  before** (`de1da69`, unpacked and built outside the project). That build
  made an identity with every file it keeps: notes (one changed by an
  agent, so with a version), a diagram, cards with an answer and session
  settings, HTTP history and a sample, an MCP token, the sandbox's state.
  This build then opened it: the first unlock imported everything in
  0.5 s; notes, versions, diagrams, cards, settings and history came back
  equal, field for field; the token still worked; the sandbox kept its CA;
  every `.bin` and `versions/` moved into `legacy/`; a second unlock
  imported nothing again. The old build's export imported here, and this
  build's export imported into the old build, each into a new identity.

Step 7 was built on 2026-11-16:

- **Rules.** `MWTClient.Storage.Retention`: ten kinds, each with its own
  limits and default, changed and put back one at a time. The fixed caps
  they replace are gone: 50 versions an item, 3 copies of Home, 3 builds.
- **Applying them.** `MWTClient.Storage.Janitor` (under
  `MWTClient.Storage`, after the journal's writer) and each kind's own
  function in the table; the VM's two through the sandbox. Off in tests
  (`config/test.exs`), which sweep when they mean to.
- **Actions.** `MWTClient.Storage.Maintenance` (compact, check, clear),
  `MWTClient.Storage.Backups`, and in the sandbox `Sandbox.space/1`,
  `reclaim_space/1` (a VM task, as start and stop are) and
  `delete_snapshot/2`, with `Disks.reclaim!/1`.
- **The page.** `MWTClientWeb.StorageLive`, linked from the header.
- **Tests.** Rules and thinning (`retention_test.exs`), every kind's
  applier, backups that open with the identity's key, a sweep, compact,
  check, clear and the usage summary (`janitor_test.exs`), reclaiming a
  real ext4 image (`disks_test.exs`), the VM's space and its copies of
  Home (`space_test.exs`), and the page (`storage_live_test.exs`).

Not built: removing msb image layers no kept build uses (it needs msb's
own command, to check on your machine); recording agent activity bodies,
and so their rule.

Step 6 was built on 2026-11-16:

- **The journal.** `JournalEvents`, `journal.db`'s second migration, and
  `MWTClient.Storage.Journal`, under `MWTClient.Storage`, whose children
  now restart rest-for-one: a database failing restarts the writer too.
- **Every event source** goes through `Sandbox.Server.State.log/2`, which
  now writes to the journal. Asks and their answers, host commands, tool
  calls and handoffs carry the agent and thread they named. Event ids are
  random now: the ones from before were unique only until MWT restarted.
- **The activity page** reads from the journal, with two more filters:
  the thread that asked, and how far back (the last hour, 24 hours, 7
  days, or everything kept; 24 hours at first). Its figures cover the
  window, at most the newest 20,000 events of it.
- **Tests.** `test/mwt_client/storage/journal_test.exs` (batches, the
  one-second write, a thousand at once, a lock, an id twice),
  `test/mwt_client/sandbox/activity_test.exs` (events outlive a lock;
  thread, kind and time filters; paging; threads; who asked) and a page
  test for the new filters. The two page tests that put events into the
  server's memory now record them in the journal.

Not done: "a day of real agent work in the journal" needs MWT and its VM
running, which this VM can't. Measured instead, with 100,000 synthetic
events of 12 threads: recorded through the writer at 47,000 a second,
34 MB; a page of one thread, one kind or the last hour in 0.3 ms; a word
found in none of them, 31 ms (it reads every row); a thread, a kind and
a day together, 26 ms.

Step 5 was built on 2026-11-16:

- **`MWTClient.Storage.Documents`**: `get/2`, `put/3`, `delete/2`, and
  `load/5` for an app starting, which brings in the file from before. The
  four documents above use it.
- **The sandbox and agent threads** no longer hold the password's key:
  only their old file needed it, and it is passed to `load/5` once, at
  start. A saved state that can't be read is kept as
  `sandbox.<time>.unreadable` and the sandbox starts empty, as an
  unreadable file was set aside.
- **Tests.** The sandbox's, MCP's and agent threads' tests pass, but for
  the eleven that read or rewrote `sandbox.bin` or `mcp_access.bin`:
  those that edit what an earlier MWT left saved now open the identity's
  databases alone while it is locked (`with_storage/3` in
  `test/support/vault_helpers.ex`); those that made the disk refuse a
  write now make the database refuse it, with a trigger.
  `test/mwt_client/storage/documents_test.exs` covers the module, and an
  `agent_threads.bin` imported at unlock; the MCP tests, an
  `mcp_access.bin`.

## Open

- **Trigram index size**: 10,000 notes of 3 KB made a 129 MB
  `library.db`. FTS5's word tokenizer with prefix queries would be smaller
  (not measured), but a search for `ash` would no longer find `hash`.
- **Long lists**: the notes page asks for every summary. Past several
  thousand notes, asking for a page at a time would keep lists in single
  milliseconds.
- **The import on your real data**: run the check above on a copy of your
  data folder before this lands. Only real files written by older builds
  can show what the tests can't.
- **A rollback-safe import**: considered and not built (see
  [No going back, and the way back](#no-going-back-and-the-way-back)).
  Worth it only if older builds will keep opening data this build has
  opened.
- **Reporting the `auto_vacuum` bug upstream**, with the C repro: your
  call.
- **Compacting on its own** when a database is idle with a quarter of it
  free, and showing how much Compact would give back: not built.
