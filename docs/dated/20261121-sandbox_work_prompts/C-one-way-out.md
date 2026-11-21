# C. One way out, requests read in full

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- MWT connects for the VM only to addresses the VM could have been let
  through to. A token grant that lists an internal name no longer opens
  that host without its network grant, its approval and its way out, and
  no name leads MWT to loopback. Today a host on a token grant's list is
  reached by name, with no address check, the Internet off included.
- With the Internet off, a token grant's hosts are reached only while that
  grant is on.
- When two network grants cover a name, the most specific one decides, so
  an exact grant's approval mode isn't passed over for a wildcard's.
- An approval card shows the whole request it approves. A body sent late
  is waited for, and what goes out after you click is exactly what the
  card showed: nothing is sent behind it.
- Each HTTP exchange MWT reads goes through a list of stages. Workstream D
  (network grants read and reviewed, masking) and E3 (MWT answering
  Google's credential endpoints) add a stage instead of a branch in
  `Connection`.
- The firewall counts uploads where they go, request bodies to hosts MWT
  reads included.
- DNS answers are checked, and a split-horizon resolver doesn't map your
  private network for the VM.

With C, the most wanted feature of the todo, a VPN-only production service
read and reviewed (D1), can be built safely.

## Where it sits

- C1: round 3, slot 1. It needs nothing.
- C2: round 4, slot 1. It needs C1, which changes the same file
  (`egress/connection.ex`).
- C3: round 5, slot 1. It needs C1 and C2.
- C4: round 3, slot 3. It needs nothing, and changes `dns.ex` only.

Waiting on C: K1 (C1); D1 and D3 (C1, C2); E3 (C2).

## Read

- The plan, workstream C.
- The review:
  - findings 3 and 4;
  - among the smaller gaps: DNS, TLS name, Upload rule, Firewall off,
    Upgrade;
  - the leads under *Connections and DNS* and *Intercepted requests*;
  - under *Firewall, MWT's tools…*: the domain and the public-suffix list,
    the upload rule's ways past it, `sts.<region>.amazonaws.com`.
- `docs/todo.md`, "Every request through a network grant", its bullet
  "The most specific grant should win".
- `agent_sandbox.md`:
  - under *Network*: *Each connection*, *DNS*, *Private networks*, *Each
    intercepted request*, *What comes back*, *Describing requests*;
  - *Firewall*, its *Rules*;
  - guarantees 2, 3, 12 and 22.
- Code:
  - `Gate.route/5`, `Gate.destination/3` and `name_mismatch/6`;
  - in `Egress.Connection`: `upstream/1`, `read_at_least/4`, forwarding
    after a decision, the method overrides, HTTP/1.0, `Upgrade`, CONNECT
    by name, the ClientHello's wait and its records;
  - `Destinations`, `Routes`, `Policy.decide/3`, `Describe`,
    `RequestView`, `Approval`'s digest, `Server.Approvals`' joining;
  - `SavedRequest`'s send, `Firewall`'s upload rule and domains, `Dns`.
- Tests: `gate_test.exs`, `egress_test.exs`, `egress_leaks_test.exs`,
  `egress_bounds_test.exs`, `egress_corpus_test.exs`,
  `destinations_test.exs`, `describe_test.exs`, `firewall_test.exs`,
  `dns_test.exs`, `saved_request_test.exs`, `guarantees_test.exs`.

## C1: one place MWT connects from (M)

Task: `route-read-hosts-through-destinations`.

- A module that is the only way MWT opens a connection for the VM:
  1. it resolves the name with MWT's own resolver, so Gate's answered
     names stay true;
  2. it classifies the address with `Destinations`;
  3. it refuses loopback and this machine's own addresses;
  4. a private or reserved address needs a network grant that is on and
     covers it, with that grant's approval and way out, as a tunnel's
     does (reuse that path, don't copy it).
- `Connection.upstream/1` uses it instead of `:ssl.connect` by name. So
  do a request subgrant's send and a CONNECT that names a host. That
  CONNECT is resolved only after the view, an isolation and the
  Internet's state were looked at.
- With the Internet off, a request with no placeholder to a token grant's
  host needs that grant on.
- When several network grants cover a name: an exact name first, then
  the longest wildcard, and on a tie the grant that asks.
- The document: *Each connection* and *Each intercepted request* say it;
  a new guarantee at the end, *MWT connects to a read host only at an
  address the VM could have been let through to*; guarantee 22 reworded
  for requests without a placeholder.

**Done when:** tests show a token grant's internal name refused without
its network grant, a name resolving to loopback refused, a token host
refused with the Internet off and its grant off, the most specific grant
winning, and a request subgrant's send to a private address refused
without a grant.

## C2: framing first, then the card, then the stages (M/L)

Task: `read-requests-in-full`. After C1.

- No card until the declared body has arrived, up to 64 KiB. A request
  that doesn't send it within 10 s is refused.
- Forwarding stops at the declared length or the last chunk. Remove the
  *Not covered* entry on what the VM sends behind a request MWT read.
- A request MWT couldn't describe gets no *Allow similar*. A cut body is
  said among the card's facts, and the digest a waiting card is joined on
  covers all of the body read.
- The first bytes, read the same way:
  - a ClientHello split over two TLS records is read whole;
  - a connection whose name can't be read (split, or sent after 1.5 s of
    silence) gets no pass from a rule keyed on a name;
  - a network grant opened by a name refuses such a connection: today
    `name_mismatch/6` lets a connection with no name through.

  Protocols where the server speaks first still need the 1.5 s wait to
  end in a tunnel where a grant allows one.
- The parsing leads, since they are the same reader:
  - HTTP/1.0 with chunked bodies;
  - `Upgrade` keeping the client's `Connection`;
  - `_method` in a query or a form, and header names with underscores;
  - `TRACE` and `CONNECT` in any case;
  - GraphQL beyond `POST /graphql` exactly;
  - Basic credentials shown in any case.

  For each: refuse, or normalise, and say which in the document.
- The stages: once a request is framed, `Connection` calls a list of
  stages over it and its answer, each going on or answering itself.
  - The order is the todo's: out, unmask, review, swap, send; back,
    review, mask, check for real values.
  - Today's card and `Egress.Response` become stages, and nothing else
    changes behaviour.
  - A stage sees the framed part. Bodies past 64 KiB still stream, as
    "first X of Y".
- The document: *Each intercepted request* describes the stages; a new
  guarantee, *a card is made only from a request whose declared body, up
  to the limit, was read*.

**Done when:**

- tests show a late body waited for and shown, then refused past 10 s;
- bytes past the declared length are never forwarded;
- an undescribed request has no *Allow similar*;
- a split ClientHello is read;
- a nameless connection under a named network grant is refused;
- the egress suites pass unchanged otherwise.

## C3: the firewall counts what goes out where it goes (M)

Task: `count-uploads-where-they-go`. After C1 and C2.

- Request bodies to hosts MWT reads count in the upload rule. Today only
  tunnels call `Gate.upload/5`.
- Uploads are keyed by the resolved address and its registrable domain,
  not by the name the VM gave. A public-suffix list is a dependency, or
  data to keep current: ask the user which.
- With the firewall's switch off, plaintext tunnels are still looked
  through for real values. That check is a guarantee, not a rule.
- The review's ways past the upload rule, each with the change you chose
  and why: the 1,000 flows, the quarter sent back, the 10,000 keys.
- `sts.<region>.amazonaws.com` among the credential endpoints.

**Done when:** tests show an upload to a read host counted, many made-up
names for one address counted once, and a plaintext tunnel with the
firewall off still refused for a real value.

## C4: DNS (S/M)

Task: `check-dns-answers`. Round 3, slot 3.

- A UDP answer is checked for its source, its id and its question.
- A message cut after its name doesn't crash its task.
- Messages refused for their shape are logged, as guarantee 12 says.
- A name no grant lists, whose answer holds a private or reserved
  address, gets REFUSED.

**Done when:** each has a test in `dns_test.exs`, and guarantee 12 is
true as written.
