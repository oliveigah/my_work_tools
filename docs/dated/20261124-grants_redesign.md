# Grants redesigned: resources, grants, actions, drivers and adapters

A design for the next shape of the agent sandbox's grants, of 2026-11-24.
It starts from what setting up grants at work on 0.3.0 showed (the files in
[issues](../issues/README.md)) and from that setup's grant list. No code
changes with it. Once it is built, [agent_sandbox.md](../agent_sandbox.md)
takes its content, and this stays as the record of why.

## What grants are for

An agent in the VM does part of your work that needs your access: BigQuery
as you, a service behind Identity-Aware Proxy, GitHub, a host on a VPN. You
decide once which uses go through unattended, which ask and which never
happen, at the level you actually trust. You are asked only about what
falls outside that, and the real credential never enters the VM. When
something looks wrong, everything the VM reaches stops at once, and starts
again as it was when you release it.

The agent is root in the VM, so nothing that runs there proves anything.
MWT tells one use from another only by what it reads at the proxy and in
the VM's asks: where a request goes, which credential it carries, what the
protocol says it does, which action an agent calls.

## Decided so far

- The strictest say of the grants that cover a use decides, and nothing
  else does. Several grants asking about one use make one card.
- No command an agent writes runs on your machine unattended. Agents can
  always ask, and a card can save a command as an action.
- The core is generic. Drivers read wire protocols, adapters know families
  of credentials, and the core offers both fixed extension points.
- The Internet is a network like any other, with a built-in grant over all
  of it that lets everything through.
- Networks, credentials and your machine are resources, open by default.
  Each has a lock, and a locked one means something went wrong and waits
  for you. Isolating the VM locks them all and changes no grant. Everyday
  access is the grants' job.
- A grant is on, off or disabled. On, agents use it. Off, it refuses what
  it covers, even where a wider grant allows it. Disabled, it has no say,
  and the other grants decide.
- Your machine, the channel between the VM and MWT, is a resource of its
  own kind, shaped like a network.
- A grant you add starts disabled, so it changes nothing until you set it.
- A grant holds one scope and one state, with no exceptions. Asking about
  the whole Internet except a few hosts isn't supported for now.
- Grants that overlap are linked, by MWT working the overlap out from their
  scopes, never by you declaring it.
- Agents can find out why a use was refused or asked about, and what would
  change it, without sending anything. What they are shown is built from a
  list of what may be shown, and holds no value, body or firewall workings.
- A grant that narrows by an attribute MWT may fail to read covers the
  requests it can't read, unless its setting *Covers requests MWT can't
  read* is off. Agents never ask for it: cards are for uses and for turning
  grants on. An agent refused this way hears which grant and setting did
  it, and tells you to change it in MWT.
- Checks (*Only while…*) are dropped for now.
- What drivers read (a gRPC method, a GraphQL operation) is something a
  grant can narrow by.
- *Allow for a while* on a card naming several grants adds the allowance
  to each, and names each one.
- An import keeps grants' start settings.
- Credentials made the same way merge into one at migration, on their own.
- An export carries stored credential values only when you choose to.

## The second pass: grants give, resources limit

Decided with you on 2026-11-24, after trying the first build: it was too
confusing. It replaces what follows wherever they disagree: on, off and
disabled, the strictest say, Ask to run commands, a grant set off as a
block.

**What it is for.** An agent in the VM does part of your work with your
access. You keep a list of what it could use, the resources (the token
"GitHub personal", the prod VPN, your machine), and grants give it uses
of them, on for as long as a task needs and off after. You see at a
glance what is on and what each grant uses, and a lock on a resource
cuts everything that goes through it.

### Resources

- A **credential**, added on its own: its name and purpose, where its
  value comes from (pasted, or a command that mints it), how tools in
  the VM find its placeholder.
- A **network**, added on its own: its addresses, ranges and names, its
  DNS server, its interface, and its **host limits**: what a host on
  neither list gets (*Reachable* or *Blocked*) and two lists, Reachable
  and Blocked, as What MWT reads has. The entry naming a host most
  exactly decides, an entry covers the names under it, and a host is on
  one list at most. A blocked host is refused through that network,
  whatever any grant says.
- Built in: the **Internet** (every public address), **your machine**
  (where commands run) and **MWT's tools** (notes, diagrams, flash cards,
  HTTP samples).
- Each has a lock. Locked, every use through it is refused, whatever the
  grants say. Isolating the VM locks them all; releasing it unlocks what
  the isolation locked.

### Grants

- **Each grant mediates one resource**: a token grant its credential,
  and where the value may be used (the hosts it may go to, and commands
  on your machine if you allow it); a network grant its network, all of
  it or some of its hosts; a request action its credential, for one
  fixed request; a saved command your machine; MWT's tool grants MWT's
  tools.
- A grant is **on** (for a while or until turned off, asking or
  auto-approving) or **off**. Off has no say. When MWT starts, it is put
  off, on, or on and auto-approving, as its start setting says.
- Built in: the Internet's grant (over all of it, on and auto-approving
  at start, as before) and MWT's three tool grants. They can be turned
  off, not deleted.
- Agents can ask for any grant that is off, but one an agent proposed
  that you haven't reviewed. An ask for a grant whose resource is locked
  is refused at once, with no card.
- Actions sit under their resource: a request action under its
  credential, a saved command under your machine.

### The rule

1. **Nothing goes without a grant.** With no grant on, the agent reaches
   nothing.
2. A use goes through one or more resources, and **each of them needs a
   grant that is on and covers this use**. One missing, it is refused.
3. **Within one resource**, any grant covering the use is enough, and the
   most permissive counts: grants only give.
4. **Across resources**, the use goes unasked only if every one lets it
   through unasked. If any asks, **one card** names each grant that
   asks; *Allow for a while* adds an allowance to each.
5. **A locked resource or a blocked host refuses**, whatever the grants
   say.

| A use | goes through |
| ----- | ------------ |
| A connection, a request with no credential | its network |
| A request carrying a credential's placeholder | the credential (a token grant listing the host) and the network |
| A call of a request action | the credential (the action, or a token grant listing its host) and the network of its host |
| A saved command | your machine (the saved command) and each credential it runs with (a token grant allowing your machine) |
| A call of MWT's tools | MWT's tools |
| An agent's own command | nothing to grant: you approve each one; refused at once while your machine is locked |

A host is asked about only through its grants: a host reached with a
credential asks when that credential's grant asks. Always ask for one
host the Internet's grant lets through isn't expressible; block it, or
put the Internet on Ask and auto-approve the hosts you trust.

### The screen

The Grants page has three tabs: **On now** (every grant on, its time
left, Ask or Auto, the resources it uses, and any lock), **Resources**
(every resource with its lock and its grants; *Add resource*; a page of
its own each) and **All grants** (every grant with its switch, and its
resource as a link; *Add grant* starts from the resource).

### From what is saved

- Disabled becomes off; Ask to run commands goes, its saved commands
  staying as grants over your machine.
- A host list's Block and Ask entries become the network's Blocked list
  (nothing that waited for you goes unasked); Auto entries, grants over
  that host, auto-approving. A grant over part of a network that was off
  as a block, or always asked, becomes a Blocked entry too.
- A token grant only its actions used goes; its actions sit under its
  credential.
- A confined command's credentials are named by credential; the token
  grants it ran with allow your machine.

### Built (the second pass)

Built on 2026-11-24, the afternoon of the review. Where the build differs
from the above, or settles what it left open:

- **Which network a use goes through.** A connection goes under the
  network grant that opens its address, the most exact first. A request
  goes through the network its connection went under; a call of a request
  action, which MWT sends itself, through a network a network grant names
  its host in, else the Internet.
- **Host limits are judged by name.** A connection to an address one of
  whose names (those MWT's DNS answered) may be blocked is held until its
  first bytes say which host it is for; a name the Internet blocks is
  never looked up. With a network's default *Blocked*, every connection
  there is held for its name.
- **A token grant's form still edits what its credential presents** (the
  Google login file, the metadata server, signing as service accounts),
  as before: the credential's own page edits its name, how its value is
  made, its variables and git, and replaces its value.
- **A request action signs as its own accounts** (`signs_as`), those its
  token grant had copied onto it as it migrated, and sends with its
  credential's value directly: the token grant it was under no longer has
  a say.
- **Proposals name the resource:** `mwt propose machine` (or `commands`,
  as before) for a saved command, `mwt propose CREDENTIAL` (or a token
  grant over it) for a request action.
- **A resource lives on without grants**: removing the last grant over a
  credential keeps it and its value; removing the credential removes its
  grants.

## Built

Built on 2026-11-24, the same night and the day after, in the order
below. What it does is in [agent_sandbox.md](../agent_sandbox.md); what is
left is in [todo.md](../todo.md), "What the grants redesign left open".

1. Grants on, off or disabled, and one decision per request by the
   strictest say of every grant covering it: the network grant its
   connection went under and the grants over the credential it carries,
   one card naming every grant that asks (`Policy.strictest/1`).
2. Credentials (`MWTClient.Sandbox.Credential`), shared by the grants over
   them and minted once, the 0.3.0 grants given one each and merged where
   minted the same way; locks on credentials, networks and your machine;
   isolation as a lock that changes no grant; a Resources card with the
   locks.
3. Ask to run commands always there, every run asking; a request
   subgrant's call judged with the grants over its credential.
4. `mwt why URL`, `mwt why --recent`, `mwt why ID`
   (`MWTClient.Sandbox.Explain`), overlaps worked out from scopes
   (`MWTClient.Sandbox.Overlaps`), and *Try a use* on the Grants page.
5. The agent sandbox's section of an export, stored values only when you
   choose.
6. Attributes on grants over credentials, *Covers requests MWT can't
   read*, and *Allow similar, any id*.
7. Adapters (`MWTClient.Sandbox.Adapter`): bearer, github and google; the
   google adapter's implied endpoints, a refresh with no card, and the
   project under `mwt exec`; the github adapter's repository and a GitHub
   App's installation token.
8. The day after, from your review: checks removed (a grant saved with
   some loses them, the log naming them); isolation locking every
   resource as the isolation's lock, released with it, yours staying;
   refusals naming their decision, kept as made, for `mwt why ID`;
   subgrants called actions everywhere; request actions sending
   `{id_token}` and `{signed_jwt}`; networks as resources
   (`MWTClient.Sandbox.Network`), host lists made grants over hosts; the
   lock switch reading on as open; the export carrying networks and the
   folders confined commands may read, its ids checked and its values
   sealed.

Where the build differs from the design:

- Among the network grants that are on, a connection is still opened by
  the most exact one. The strictest of every grant over the network
  decides each request and holds a connection for its first bytes, and a
  grant off refuses what it lists, so only which grant a connection goes
  under is left to exactness.
- A name only disabled network grants list isn't sent to the Internet's
  resolver: the lookup is refused, naming the grant to ask for. Disabled
  has no say over connections only.
- The isolation stays the firewall's switch, refusing everything; locking
  every resource is what it does beside that, so the Resources card shows
  it.
- Credentials merge only where kept as long (`keep_minutes`): a grant kept
  4 minutes for a service that takes only young ID tokens stays apart, so
  the others aren't minted that often.
- A token grant keeps a copy of its credential's fields, and a network
  grant its network's (`Credential.attach/2`, `Network.attach/2`), so the
  code that read a grant's fields reads its resource's.
- Merging an export makes placeholders anew for the credentials that come
  in; replacing keeps the file's, since replacing is also how a failed
  import is put back.
- A host list's *Ask* became a grant that always asks: *Allow similar*
  no longer settles it.

## What 0.3.0 showed

The work setup has nine grants of its own beside the built-in ones.

| Grant                           | Kind                                               | Approval |
| ------------------------------- | -------------------------------------------------- | -------- |
| BigQuery, as me                 | token, Google login                                | auto     |
| Cloud Storage, as me            | token, Google login                                | auto     |
| Policy management (pm)          | token, Google login, signs as two service accounts | auto     |
| Research box                    | token, Google login, signs as one service account  | auto     |
| GitHub App, read-only, UME      | token, minted installation token                   | auto     |
| GitHub App, read-only, personal | token, minted installation token                   | auto     |
| UME datalake token (prod)       | token, pasted by hand                              | asks     |
| UME dev VPN: internal gateway   | network                                            | auto     |
| UME prod VPN: internal gateway  | network                                            | asks     |

What that list, the issues and the code show:

- The four Google grants share one login, and all four auto-approve. Trust
  didn't split them. A grant holds the credential, the way tools find it,
  the hosts it goes to and the approval together, and each of the four
  needed something different: the header its ID token travels in
  (`x-user-assertion` for pm), the accounts it signs as, how long a value is
  kept. So the same login is minted four times
  ([one-login-many-grants](../issues/one-login-many-grants.md)), and
  Google's token and signing hosts repeat on each
  ([google-endpoint-hosts-listed-by-hand](../issues/google-endpoint-hosts-listed-by-hand.md)).
  What the purposes ask for is narrow destinations for one login ("Only
  BigQuery: no other Google API").
- One request is judged twice. A datalake request to `internal.ume.com.br`
  is the prod network grant's to allow first and the datalake grant's next
  (`Gate.through/3`, then `Gate.decided/3`), so it makes two cards in a row.
- Each kind narrows differently. A token grant lists hosts, a network grant
  destinations, and neither a path (the prod grant's purpose says "A network
  grant can't narrow paths"). An allowance matches one exact route
  ([allow-similar-by-route](../issues/allow-similar-by-route.md)).
- Provider knowledge sits in the generic grant. `Grant` has `signs_as`,
  `presents` (a metadata server, a login file), the ID token's header,
  `mint_per` and `keep_minutes`. `Server.Grants` checks that a login file
  lists `oauth2.googleapis.com`, `Values.minted/2` reads gcloud's JSON, and
  `CredentialEndpoint` answers Google's endpoints.
- `mwt exec G -- CMD` reads as a scope and isn't one. It is a shell snippet
  in the VM (`priv/sandbox/mwt-cli`) that loads
  `/mnt/mwt/grant-env/G.sh` and runs the command. MWT never hears of it and
  you never see the command. G's placeholder sits in `/mnt/mwt/tokens/G`,
  mode 0644, whether G is on or off. The proxy decides each request by the
  placeholder it carries (`Policy.decide/3`), whatever process sent it
  ([placeholder-files-readable](../issues/placeholder-files-readable.md)).
- Isolating the VM changes your settings. It turns every grant off, and
  releasing turns back on those the incident remembers
  (`Server.Firewall.restore_grants/2`), so your grants' states pass through
  the firewall's record and back.
- A command subgrant's `with` reads the real value of a token grant that is
  off, since only the grant's existence is checked
  (`Server.HostRuns.run_confined/4`).
- An export carries no grants. `MWTClient.Transfer` exports HTTP requests,
  diagrams, notes and flash cards, and nothing of the sandbox.

## The model

| Part     | What it is                                                                                              | Switch                       |
| -------- | ------------------------------------------------------------------------------------------------------- | ---------------------------- |
| Resource | What the VM reaches through MWT: a network, a credential, or your machine (the channel).                | a lock, yours                |
| Grant    | A scope over uses of resources, and a state: off or on, asking or not.                                  | on and off, which agents ask for |
| Action   | A fixed thing MWT carries out when an agent calls it by id: a request MWT sends, or a script your machine runs. | through its grant      |
| Driver   | Reads a wire protocol (HTTP, gRPC, GraphQL, git) into uses and their attributes.                        | none                         |
| Adapter  | Knows a family of credentials (bearer tokens, GitHub, Google): how values are made, shown to tools and recognized. | none              |

Subgrants go away as a concept. Request and command subgrants become
actions, each with a grant of its own. How a narrow grant relates to a wide
one follows from what each covers, and nothing stores it.

### Resources

Three kinds, and each one has a lock.

- A network lists destinations (names, `*.` names, ranges, ports), the DNS
  server that answers its names and the interface its addresses are reached
  through, as a network grant does today. The Internet is a built-in
  network of every public address.
- A credential is where a real value comes from, through its adapter.
  - A stored value is pasted once and kept in your vault. A minted value
    comes from a command on your machine that prints it, run as you. A
    built value is made by the adapter from something a command prints,
    such as a GitHub App installation token from the App's private key.
  - It has one placeholder, made once, in the shape its adapter gives it
    (`ghs_…`, `ya29.mwt…`), and a minted value is minted once however many
    grants cover it.
  - Values made from it, such as an ID token or a signed JWT, keep their
    own expiry and narrower destinations (`Made`), as today.
  - The VM gets it only through `mwt exec CREDENTIAL -- COMMAND`
    ([mwt exec](#mwt-exec)).
- Your machine is the channel between the VM and MWT, and the services MWT
  carries out there: running a command an agent writes, calling an action,
  MWT's tools, the projects' git, syncing shared folders, the workspace,
  handoffs, forwarding the VM's servers, asking for a grant, proposing one.
  It has the shape of a network (a lock, and uses that grants cover), but
  it isn't one. A network carries the VM's own bytes to an address, and
  here MWT carries out each ask itself. What only reads (`mwt grants`,
  `mwt vm`, `mwt host`, `mwt why`, `mwt ports`) is no use of it, and always
  answers.

Resources are open by default. A lock stops every use of its resource,
whatever the grants say, and means something went wrong: it waits for you
to look and unlock it. Everyday access is the grants' job. Two things lock
one, each apart, and it stays locked while either holds:

- you, with its switch, or *Lock everything*;
- the isolation, which locks every resource at once.

Locking closes the resource's open connections, refuses the cards waiting
on uses of it, and stops the command actions running with it. Your locks
and the isolation's are kept across a restart. A lock is yours alone:
agents can ask for a grant, never for a lock to end. A use of a locked
resource is refused with `mwt_locked`, naming what locked it, and the agent
tells you.

### Checks

Today a check (*Only while…* on a grant's page, `MWTClient.Sandbox.Check`)
is a script of yours, run confined on your machine, whose exit 0 says a
condition holds; one that fails pauses its grant. It does two jobs, a
precondition ("the prod VPN is up") and a fence ("this GitHub token still
can't push"). Both go for now:

- A network's interface already does the precondition's job, at every
  connection rather than once a day. A network reached through `wg0` opens
  nothing while `wg0` is down, and `mwt why` tells the agent "a VPN that is
  down?" (`Why`, `Routes`).
- A fence could come back as something that locks a credential when it
  fails, since a credential that can do more than you set it up for means
  something went wrong. Nothing in the rule depends on it.

### Isolation

Isolating locks every resource and records the incident, as today: the
VM's connections close, the cards waiting are refused, commands running on
your machine stop, and you are notified. No grant changes. Releasing ends
the isolation's locks; what you locked stays locked, and every grant is as
you left it, for the time it has left.

### Grants

A grant is one scope and one state. It holds no exceptions and no rules of
its own: two behaviours are two grants. That keeps each grant readable as
one sentence ("Google: BigQuery's hosts, auto-approved"), and makes the
grant the unit you switch, time and set to ask, and the unit agents find
and ask for by name.

The scope says which uses it covers:

- over a network, the uses going to some of its destinations, with or
  without a credential;
- over a credential, the uses carrying that credential, or a value made
  from it, to some of its destinations, whoever sends them, the VM or one
  of MWT's actions;
- over an action, its calls, and what the action does with the credentials
  it names;
- over a service of your machine, its uses: MWT's tools, git, syncing,
  the workspace, handoffs, forwarding.

A grant narrows further by [attributes](#attributes): a path, a method, a
gRPC method, a GitHub repository. A grant over a credential also says which
headers the value may travel in, starting from its adapter's.

The state is one of three:

- **On**, for a time or until you change it: agents use it. It asks each
  time or auto-approves, with allowances while it is on, unless it has
  Always ask me, which no allowance or auto-approval passes.
- **Off**: it refuses every use it covers, even where a wider grant allows
  it. Agents can ask for it to be turned on (`mwt request`).
- **Disabled**: it has no say, and the other grants decide as if it weren't
  there.

Beside its state, a grant has:

- its start setting, one of the four (on and asking, on and
  auto-approving, off, disabled);
- whether agents may ask for it. An off grant agents may not ask for is a
  block, such as a host you never want reached; today a host list's block;
- *Covers requests MWT can't read*, on a grant that narrows by an
  attribute MWT may fail to read ([Unreadable uses](#unreadable-uses)).

Turned on for a time, a grant goes back to off or disabled, whichever it
was, when the time ends. A grant you add starts disabled, so adding one
changes nothing until you set it. A grant an agent proposes stays disabled
until you accept it, so a proposal can't refuse anything.

### The rule

1. A use of a locked resource is refused.
2. Every grant that covers the use and isn't disabled has a say:
   - no, from a grant that is off;
   - ask, from a grant on with Always ask me, or on and asking with no
     allowance covering this use;
   - yes, from a grant on that auto-approves, or whose allowance covers
     this use.
3. The strictest say decides: no wins over ask, and ask over yes. A use
   nobody has a say about is refused, and so is a use carrying a credential
   that no grant over that credential has a say about.

The last clause keeps a credential from travelling under a grant that
doesn't name it, such as the Internet's.

When the answer is ask, one card shows the use and names every grant that
said ask, with the ones that said yes beside them. Its answer applies to
each grant it names:

- *Allow once* lets this use through every grant on the card.
- *Allow for a while* names each asking grant it adds the allowance to, all
  of them ticked, and adds it to those still ticked. It is offered only when
  none of them is Always ask me.
- *Deny* refuses the use. *Deny and turn off* asks which of the grants to
  turn off.

At work it decides like this.

| Use                                                                | Grants with a say                                                     | Their says    | Result                     |
| ------------------------------------------------------------------ | --------------------------------------------------------------------- | ------------- | -------------------------- |
| `bq query`, to `bigquery.googleapis.com` with Google's placeholder | Internet's, auto; Google: BigQuery, auto                              | yes, yes      | goes                       |
| The same, with Google: BigQuery off and Google: all its hosts, auto | Internet's, auto; Google: all, auto; Google: BigQuery, off           | yes, yes, no  | refused                    |
| The same, with Google: BigQuery disabled                           | Internet's, auto; Google: all, auto                                   | yes, yes      | goes                       |
| An upload to `storage.googleapis.com` with Google's placeholder    | Internet's, auto; Google: all, auto; Google: Cloud Storage, Always ask me | yes, yes, ask | a card                 |
| A datalake request to `internal.ume.com.br`                        | prod gateway, asks; UME datalake, asks                                | ask, ask      | one card naming both       |
| The same, with UME datalake auto-approved                          | prod gateway, asks; UME datalake, auto                                | ask, yes      | a card naming prod gateway |
| The same, with the prod gateway grant off                          | prod gateway, off; UME datalake, auto                                 | no, yes       | refused                    |
| The same, with the prod gateway grant disabled                     | UME datalake, auto                                                    | yes           | goes                       |
| A GitHub request, with the Internet's grant disabled               | GitHub App UME, auto                                                  | yes           | goes                       |
| The same, with the Internet's grant off                            | Internet's, off; GitHub App UME, auto                                 | no, yes       | refused                    |
| `pip install`, to `pypi.org`, with the Internet's grant disabled   | none                                                                  |               | refused                    |
| A GitHub request, with every GitHub grant disabled                 | Internet's, auto                                                      | (none over the credential) | refused       |
| Anything, with the VM isolated                                     | (every resource locked)                                               |               | refused, `mwt_isolated`    |

What follows from the rule, which no single example shows:

- Grants that overlap only narrow each other. A narrow grant can't relax a
  wide one. To let BigQuery through unattended while the rest of Google
  asks, don't make a grant over all of Google. Make one over BigQuery's
  hosts that auto-approves, and one over the hosts that should ask.
- Off and disabled differ only where grants overlap. Off refuses what the
  grant covers; disabled lets the others decide. With no overlap, both
  leave the use to no one, and it is refused.
- Asking about the whole Internet except a few hosts isn't expressible. An
  auto-approving grant over those hosts still meets the Internet's ask.
  Refusing everything but a few is: disable the Internet's grant and add a
  grant over each host you allow.
- An action is never trusted more than the free use of the same credential
  at the same host, since the request it sends is covered by both. To trust
  a fixed call more than free use, have no grant over that host give the VM
  the credential.

### How grants compare

The rule never ranks one grant above another. Strictness is an order on
says (no, then ask, then yes), and only says are compared, one use at a
time. Each grant answers one question about a use on its own, whether it
covers it, and nothing about any other grant goes into that answer.

A grant covers a use when every part of its scope matches:

- the resource: the network the use goes to, the credential it carries,
  the action it calls, the service of your machine it uses;
- the destination: the host (exactly, or under a `*.` entry) and the port;
- each attribute the grant narrows by: a method, a path pattern, a gRPC
  method, a GitHub repository, a ref a push updates.

So two grants overlap by more than hosts. "GitHub: everything, auto" and
"GitHub: pushes to `main`, off" overlap on pushes to `main` only: a fetch
is covered by the first alone and goes, and a push to `main` is covered by
both and is refused.

What the rule doesn't need, and the systems that do:

- No order. A firewall list decides by the first rule that matches, so
  moving a rule changes the outcome. Here the order grants were made in, or
  are listed in, changes nothing.
- No specificity. Routing tables, CSS and Little Snitch let the most
  specific rule win, which needs a measure of specific (a longer prefix, a
  narrower host) that attributes of different kinds don't share: is "pushes"
  narrower than "repository X"? Here a narrow grant and a wide one simply
  both have their say.
- No ties. Two says are either equal or one is stricter.

It behaves the same way whatever grants you add:

- A grant that says yes can only let through uses no grant had a say about.
  It never loosens an ask or a no.
- A grant that says ask or no can only make what it covers stricter.

What MWT couldn't read counts against the use, unless you say otherwise
for a grant ([Unreadable uses](#unreadable-uses)). When an attribute is
unknown (a connection no driver reads, a body past what MWT holds), a grant
that narrows by it covers the use if its say is ask or no, and doesn't if
its say is yes. An unread push to GitHub meets "pushes to `main`, off", and
is refused.

### Unreadable uses

Counting what MWT can't read against the use keeps an off grant from being
walked around: an agent that can't query `credit-engine` by name can't
reach it through a node id either. It can also stop work that has nothing
to do with `credit-engine`, such as every GraphQL query whose repository
MWT can't read. So a grant that narrows by an attribute MWT may fail to
read has a setting, *Covers requests MWT can't read*, as part of what it
means, beside Always ask me:

- **On**, the default: a request whose attribute MWT couldn't read counts
  as matching the grant. An off grant refuses it, an asking one asks about
  it.
- **Off**: such a request doesn't match, so the grant doesn't cover it, and
  the other grants decide. The repository grant still refuses every query
  it can read the repository of.

It is a setting of the grant, not a state: it has no timer, travels in an
export with the grant, and changes only on the grant's page, as you edit
it. It touches only that grant; one setting for all grants would loosen
ones you weren't thinking about when you changed it to get one tool
working.

Only a grant that can meet an unread attribute has it. A grant that
narrows by resource, host and port alone never does, since those are known
for every use.

Agents never ask for it. Cards are for uses and for turning grants on;
how a grant is defined is yours to change in MWT. So the agent finds out,
and tells you where to change it:

- A use refused this way says so, and names the grant: "Refused by GitHub:
  `credit-engine` (off), which covers requests MWT can't read the
  repository of". `mwt why` says the same, and ends with "if this blocks
  the task, ask the user to turn off *Covers requests MWT can't read* on
  that grant's page in MWT".
- `mwt grants` lists the setting with the grant, so an agent can tell
  before it sends anything.
- The refusal's entry in the activity log links to the grant's page, where
  the setting is.
- While it is off, the grant's card says it lets requests MWT can't read
  pass to the other grants, so a setting changed to unblock one task
  doesn't go unseen.

Since every say is worked out on its own, MWT can show each one, to you
([Overlaps](#overlaps)) and to agents ([Finding out why](#finding-out-why)).

### Overlaps

Overlapping grants are where a use fails in a way that is hard to see: a
grant you turned off for one purpose refuses what a wider one was letting
through. So grants that may overlap are linked.

MWT works the link out from the two scopes, every time one changes. Nobody
declares it, so it can't be missing or stale. Two grants overlap when some
use could be covered by both:

- they touch the same resource, or one's network holds the other's
  destinations (the prod gateway and the datalake grant at
  `internal.ume.com.br`; the Internet's grant and every grant over a public
  host);
- their destinations meet: equal hosts, a host under the other's `*.`
  entry, ports in common;
- each attribute both narrow by has a value in common: methods in both
  lists, two path patterns one path could match.

Hosts and ports, lists of values and path patterns by segment can always be
intersected exactly. So can an attribute a driver or adapter reads from the
URL, as long as it declares how, as a path pattern: a gRPC method is the
path `/SERVICE/METHOD`, a git push is a path ending in
`/git-receive-pack`, a GitHub repository in the REST API is
`/repos/OWNER/NAME/…`. Each source must declare that whenever it holds, so
its attributes compare with paths exactly.

Two things can't be worked out from the scopes, and those links are *may
overlap*, each with its reason:

- **A name and an address range.** "UME datalake" names
  `internal.ume.com.br`, and a network grant over `10.20.0.0/16` covers
  addresses. They meet only if the name resolves into the range, which DNS
  decides at the time of use, and can change. The link says what the name
  answers now ("`internal.ume.com.br` is `10.20.3.4` now, inside").
- **An attribute read from the body, and anything else.** "GitHub:
  repository `credit-engine`, off" and "GitHub: GraphQL queries, auto". A
  GraphQL query names its repository in its body, as variables, a string
  in the document, or a node id that names no repository at all. Whether a
  query about `credit-engine` will come, and whether MWT will read its
  repository, is known only per request.

The second kind is why these links matter. What MWT couldn't read counts
against the use, so with `credit-engine` off, every GraphQL query whose
repository MWT can't read is covered by the off grant and refused, while
the queries it can read and that name other repositories go. The link
says so on both grants' pages: "may refuse GraphQL queries whose
repository MWT can't read", with *Covers requests MWT can't read* beside
it.

What the link shows:

- On a grant's page, *Overlaps*: each linked grant, what they share (the
  hosts, the methods, the paths), and which of them decides there now
  ("Google: Cloud Storage, off, refuses what Google: everything lets
  through at `storage.googleapis.com`").
- On the Grants page, linked grants as a group, with a mark where their
  says differ now. Links where every say is the same are there but quiet:
  the Internet's grant overlaps every grant over a public host, and matters
  only where one of them asks or refuses.
- Changing a state says what it changes through the links before it does
  it: "Turning this off refuses `bigquery.googleapis.com`, which Google:
  everything lets through."
- `mwt grants` lists, under each grant, the grants it overlaps, so an agent
  reading it sees the relation too.
- *Try a use* on the Grants page takes a URL and a method, or a curl line,
  and shows every grant's say and the result, without sending anything.

### Finding out why

When a use fails, the agent should find out why from MWT, and tell you
exactly what to change, rather than guess (an expired login, a provider's
IAM) or try again. Most tools hide MWT's answer: a client library turns the
JSON body of a refusal into "403 Forbidden" or "Permission denied". So the
explanation doesn't depend on the tool passing it on.

- Every refusal and card carries its decision: the use as MWT read it, the
  locks, and each grant's say with its name and the reason for it, with an
  id. The refusal's JSON body has all of it, for the tools that show it.
- `mwt why --recent` lists MWT's last decisions on the VM's uses (refused,
  asked, waiting, timed out), newest first, each with its id and one line.
- `mwt why ID` explains one: the use (method, host, path, the credential by
  name, the attributes read and those MWT couldn't read), each grant's say
  and why, the locks, and the result.
- `mwt why URL [--method M] [--with CREDENTIAL]`, or `mwt why -- curl …`,
  runs the rule on a use not made yet, and sends nothing. It is the same
  engine as *Try a use*, and as today's `mwt why HOST[:PORT]`, which it
  extends from destinations to whole uses.
- Every explanation ends with what would change the result, as things the
  agent can do or ask for: "Google: Cloud Storage is off and refuses this
  under Google: everything. Ask the user to turn it on (`mwt request
  google-cloud-storage`) or to disable it." A lock: tell the user. No grant
  over the credential: propose one.

At work: `gsutil cp` fails with "AccessDeniedException: 403". The agent
runs `mwt why --recent`, sees "POST storage.googleapis.com/upload/… refused:
Google: Cloud Storage (off) said no, Google: everything (auto) said yes",
and tells you which grant to turn on or disable, instead of looking for an
IAM role you don't lack.

What holds it:

- `Policy.decide/3` is pure today: it takes the grants, the use and the
  clock, and acts on nothing. A dry run is that same call, so it can't
  disagree with what a real use meets.
- A dry run sends nothing, waits on no one, makes no card and isn't a use:
  no grant's say about it is logged as one, and the firewall sees nothing.
- A dry run without a body leaves the attributes read from a body unknown
  (a GraphQL operation, the refs of a push), and says which grants that
  leaves undecided.

What it shows, and what it never does. An explanation is built from a list
of what it may hold, never by leaving things out of the activity log:

- It holds:
  - the VM's own uses: method, host, port, path and query, as the VM sent
    them, passed through `Shown` so no control character or reversed text
    reaches the agent's terminal;
  - attributes the drivers and adapters declared, read from those uses;
  - each grant's say, by its name and id, and why: its state, an allowance
    in force for this use, Always ask me;
  - locks, by what locked them;
  - the decision, and for one you made, that it was yours and when.
- It never holds:
  - a real value, or a placeholder (a credential shows by its name);
  - a body, a header's value, or an answer's body;
  - a command's output, or anything you kept from the agent;
  - what you write on a card or a grant beyond its name and purpose;
  - the firewall's workings: which rule saw what, its counts, its lists. A
    refusal by the firewall says only that, as `mwt_isolated` does today,
    so an explanation teaches nothing about getting past it;
  - anything outside the sandbox's decisions about this VM: your HTTP
    client's history, your notes, other identities;
  - uses from before this VM started.
- A dry run never looks up a name no grant names, and connects nowhere, as
  `mwt why HOST` already doesn't (`Why`). So a name built to carry data
  (`<secret>.example.com`) never reaches a DNS server through it.
- `--recent` keeps the last 50 decisions since this VM started, and `why ID`
  answers only an id from those.
- It tells the agent nothing `mwt grants` doesn't, beyond the allowances in
  force for the uses it asks about, which sending them would show.
- *Try a use*, on your side, keeps nothing of what you paste: a curl line
  holding a real token of yours is read, decided and dropped, never logged
  or sent.

### The Internet

The Internet is a network like any other. MWT builds in one grant over all
of it, on and auto-approving by default, as the Internet grant is today.
Grants over some of its hosts (Always ask me, off) narrow it; a grant over
a credential adds its own say about the hosts it names.

- Disabling the Internet's grant leaves the VM what other grants cover, as
  turning the Internet off does today.
- Turning it off refuses every public use, those other grants cover
  included.
- Locking the Internet does the same, as an emergency stop that waits for
  you.

Asking about every public host except a few isn't expressible, since a
grant holds no exceptions. Should it be needed, exceptions in a scope would
add it without changing the rule, since an exception only narrows what its
grant covers.

### Attributes

What a grant narrows by, beyond its resource and destinations, comes from
whoever read the use:

- the core: the resources it touches, the destination's name, port and
  address, the credential it carries, and who sends it (the VM or an
  action);
- a driver, per wire protocol, from what the protocol itself frames:
  - HTTP/1.1 and HTTP/2: the method, the path, the content type;
  - gRPC, over HTTP/2: the service and the method;
  - GraphQL, over HTTP: the operation's type and name, and the document's
    digest;
  - git over HTTPS: fetch or push, and the refs a push updates;
  - a connection no driver reads: nothing past its destination;
- an adapter, per family of credentials, from what its requests name: a
  GitHub repository, a Google project, the service account a `signJwt`
  signs as.

A later driver for Postgres or Kafka adds what those protocols frame (a
Kafka topic, a Postgres database and user), never what a statement means.
What a call does inside a service is the provider's to control, through the
credential it issues.

Each driver and adapter declares its attributes, and the core does the
rest:

- each has a name in its source's namespace (`http.path`, `grpc.method`,
  `github.repository`), a shape, and how a grant matches it: exactly, one
  of a list, or a path pattern by segments (`/repos/*/pulls/*`);
- its values are facts MWT read, never what the agent wrote, and a card
  shows each with its source;
- the driver says which attributes make two uses similar, and the widening
  steps a card offers for *Allow similar*: for HTTP, this path, then the
  path with its ids as wildcards (segments of digits, UUIDs, long hex),
  then the host.

What MWT couldn't read counts against the use. When an attribute is
unknown (a connection no driver reads, a body past what MWT holds), every
grant that would restrict by that attribute covers the use, and no grant
that would allow by it does, unless the grant's *Covers requests MWT
can't read* is off ([Unreadable uses](#unreadable-uses)).

This builds on what is there. `Egress.Request` already has an `operation`
and a `resource` for any protocol, and `Describe` already reads gRPC's
service and method and GraphQL's operations for cards and allowances.

### Actions

- A request action names its credential, a method, a URL template, fixed
  headers and a JSON body template, as a request subgrant does today. A
  header may name `{token}`, and the values its adapter makes:
  `{id_token}`, `{signed_jwt}`
  ([request-subgrant-signed-credentials](../issues/request-subgrant-signed-credentials.md)).
  MWT sends it. The call is a use of your machine, covered by the action's
  grant; the request it sends is a use of its credential and of the network
  it goes to, covered by the grants over those, the action's own included.
- A command action is a script, the folder it runs in, whether it is
  confined, and the credentials whose real values it runs with. Your machine
  runs it. Its grant covers the run and what it does with those
  credentials, since MWT can't see where a script on your machine sends a
  value. The locks hold, so with Google locked, an action that runs with
  Google's value doesn't run.
- Agents call one by id, with typed parameters (`Param`), and propose one
  with `mwt propose`. The rules on parameters and on proposals stay as they
  are.

### Asking to run commands

Running a command an agent writes is a use of your machine, under a
built-in grant that is always on and always asks. No allowance,
auto-approval or start setting changes it, and it has no switch to turn
off. Every ask is a card you read and approve, with at most ten waiting at
once. A card can save the command as a command action, confined, with a
grant of its own that starts off. Locking your machine, or isolating the
VM, stops the asks too.

## mwt exec

`mwt exec CREDENTIAL -- COMMAND` chooses which credential a command speaks
as, and decides nothing. The grants decide each request the command sends.
`aws-vault exec PROFILE -- COMMAND` works the same way. It hands a command
a profile's credentials, and AWS decides what they may do.

- It sets up what the credential's adapter presents (variables, files of
  placeholders, git's helper for its hosts, a local server) for the command
  and its children, as today.
- It names a credential, never a grant. Every grant over one credential
  shares its placeholder, so a grant's name there would read as a scope the
  command doesn't have.
- It still has a job. It chooses between credentials one tool would pick up
  alike, such as two GitHub Apps that both fill `GH_TOKEN`. And it keeps
  credentials out of commands that need none, so a public download carries
  no placeholder and makes no card.
- At the start it refuses, exiting 125, when the credential is locked
  (naming what locked it) or no grant over it is on (naming the grants to
  ask for). That spares an agent a long job that would fail. It isn't a
  boundary, and the guide says so.
- MWT still doesn't learn the command, so a card shows the request. A later
  step could give each run a placeholder of its own, made from the
  credential. A card could then show the command, marked as the agent's
  claim, and *Allow for this run* could end with it.

`mwt grants` lists each resource with its lock, how to use it and the
grants over it with their states, then actions. An off grant reads as
refusing what it covers until the user turns it on, a disabled one as
leaving the decision to the others. The agents' guides change with it,
within the byte budgets `instructions_test.exs` holds them to.

## Drivers and adapters

The core owns the flow: the locks, the rule, the cards, allowances, when to
mint, the values it keeps, swapping placeholders, what the VM gets, the
firewall, the activity log and export. Two kinds of extension plug into it.

A driver reads one wire protocol, whatever the credential (`Egress.Driver`,
which exists for HTTP/1.1, HTTP/2 and raw bytes). It breaks a call into the
uses it carries, declares their attributes, describes each for its card and
says what makes two of them similar. gRPC and GraphQL become drivers of
their own on top of HTTP's, as git's smart HTTP does, rather than branches
in `Describe`.

An adapter knows one family of credentials, whatever the protocol. Its
extension points:

| Extension point          | The core owns                                                              | The adapter supplies                                                                                               | Today in                                                  |
| ------------------------ | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------- |
| Settings and presets     | The forms and their checks, storage, proposals, export                     | Its settings and their checks; its presets: a credential with suggested grants and actions                         | `Presets`, `priv/sandbox/presets`, fields of `Grant`      |
| Making values            | When to mint, running the command as you, keeping values, failing visibly | Reading what a mint prints; a mint of its own; the values that come with one (an ID token) and how long each is kept | `Values.minted/2`, `Grant.mint_per`, `Grant.keep_minutes` |
| Presenting to the VM     | `/mnt/mwt`, `mwt exec`, a presentation's lifetime                          | Variables, files of placeholders (a login file), git's hosts, a local server (a metadata server)                   | `Grant.presents`, `Inbox`, `native/mwt_present`           |
| Endpoints it answers     | The rule first, fetching the real value, made values, swapping, refusals   | Which requests it answers (a refresh, `signJwt`), the answer, what it makes and where that may go                   | `CredentialEndpoint`, `Made`                              |
| Hosts it implies         | Showing them on the credential's page as what they are for                 | The hosts its endpoints need (`oauth2.googleapis.com`, `iamcredentials.googleapis.com`)                            | checks in `Server.Grants`                                 |
| Attributes               | Matching them in scopes and allowances, showing them on cards              | What its requests name, read on top of a driver's attributes (a repository, a project, an account it signs as)     | none yet                                                  |
| Recognizing its secrets  | The scanner and the firewall                                               | Token shapes, credential endpoints to refuse, its placeholder's shape                                              | `Inbound`, `Firewall`'s `@mints`, the form's `prefix`     |

Three adapters to ship:

- `bearer`: any token in `Authorization` or headers you name, Basic
  credentials included. Hex, the datalake token and anything simple.
- `github`: personal and fine-grained tokens, and a GitHub App's
  installation token, built from the App's id, the installation id and a
  command that prints its private key
  ([github-app-preset](../issues/github-app-preset.md)).
- `google`: an access token, a login file whose refresh MWT answers, the ID
  token, `signJwt` for the accounts its grants name, the metadata server,
  and a project exported as `GOOGLE_CLOUD_PROJECT`
  ([login-file-without-project](../issues/login-file-without-project.md)).

Git over HTTPS is a presentation the core offers every adapter.

Two limits hold:

- Drivers and adapters are code that ships with MWT, never plugins you
  install. They run in the process that holds every real value. Your
  presets stay data, on top of any adapter.
- They read only what a protocol frames or a request names, never what a
  query means.

What becomes of the issues found on 0.3.0:

| Issue                                                                                     | In this design                                                                                     |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [one-login-many-grants](../issues/one-login-many-grants.md)                                | One credential with many grants, minted once. The ID token's age is kept apart from the access token's. |
| [google-endpoint-hosts-listed-by-hand](../issues/google-endpoint-hosts-listed-by-hand.md)  | Hosts the google adapter implies.                                                                  |
| [request-subgrant-signed-credentials](../issues/request-subgrant-signed-credentials.md)    | A request action names `{id_token}` and `{signed_jwt}`.                                            |
| [allow-similar-by-route](../issues/allow-similar-by-route.md)                              | Path patterns from the HTTP driver, in a grant's scope and in an allowance.                        |
| [login-refresh-asks-for-approval](../issues/login-refresh-asks-for-approval.md)            | An endpoint an adapter answers that sends nothing isn't a use. It is answered while a grant over the credential is on and the credential unlocked, and refused otherwise. |
| [github-app-preset](../issues/github-app-preset.md)                                        | The github adapter's App installation token, and its preset.                                       |
| [login-file-without-project](../issues/login-file-without-project.md)                      | A google adapter setting.                                                                          |
| [placeholder-files-readable](../issues/placeholder-files-readable.md)                      | `mwt exec` described as what it is.                                                                |

## Export

The sandbox gets a section of its own in an export, through a participant
(`MWTClient.Sandbox.Transfer`, key `sandbox`), so a setup moves to another
machine or comes back from a backup.

It holds:

- resources: networks; credentials with their adapter, its settings, how
  values are made. Stored values travel only when you
  tick *Include stored credential values* as you export, off by default,
  and the file is sealed with your password either way. Minted values never
  travel, since they come from logins on the machine that minted them;
- grants (scope, start setting, Always ask me, whether agents may ask
  for it, *Covers requests MWT can't read*), actions and your presets;
- settings agents read: *This machine, for agents*, and the folders commands
  may read.

It leaves out placeholders, which import makes anew and the VM gets at its
next start. It leaves out what lasts a session, which is grants' states
and allowances (start settings carry what you meant) and locks. It also leaves
out proposals waiting for review, the activity log, handoffs, the VM's
disks and the CA.

Importing follows `MWTClient.Transfer`:

- `prepare/2` checks every definition as the forms do, runs nothing and
  changes nothing.
- The plan lists what will run on this machine (mints, command
  actions) and the credentials that arrive without a value.
- Merging keeps everything there. The same id with the same definition
  changes nothing, so importing twice is harmless. The same id with another
  definition comes in under a new id, marked *To review*.
- Grants come in with their start settings.

The file stays sealed. To show a setup to someone, `/mnt/mwt/grants.md`
holds no value and reads as text, as the work list for this design did.

Found along the way: `MWTClient.Transfer`'s documentation points at
`docs/transfer.md`, which doesn't exist.

## From 0.3.0's grants

- A grant that is on stays on. One that is off today gives nothing, which
  is what disabled does, so it becomes disabled; no two grants overlap
  today but a network grant and a token grant over one host, and those keep
  deciding as they did. Start settings map the same way.
- A token grant becomes a credential and one grant over its hosts. Its
  adapter comes from its preset or its fields: `google` for Google's,
  `github` for GitHub's, `bearer` otherwise. Its checks are dropped, and
  migration names each one.
- Its request subgrants become request actions, each with its grant.
- A network grant becomes a network and one grant. Its checks are dropped,
  and migration names each one. Its host list's entries become grants over
  the network: ask as Always ask me, block as off and not to be asked for,
  auto as a grant that auto-approves. Under a network that asks, an auto
  entry has no equivalent, and migration names each one.
- The Internet grant becomes the Internet's built-in grant.
- Ask to run commands becomes the built-in grant that always asks. Its
  saved commands become command actions, each with its grant.
- Credentials made the same way (the same adapter, mint and settings) merge
  into one. It keeps each one's old placeholder as its own, so a tool that
  holds one goes on working.

The work setup, migrated:

- resources: the Google login, GitHub App UME, GitHub App personal, UME
  datalake (prod); the dev gateway, the prod gateway, the Internet; your
  machine;
- grants: Google over BigQuery's hosts, over Cloud Storage, over pm's two
  hosts signing as the policy agents, and over the research box signing as
  its caller, all auto-approving; each GitHub App, auto-approving; UME
  datalake at `internal.ume.com.br`, asking; the dev gateway,
  auto-approving; the prod gateway, asking; the Internet's, auto-approving.

The login is minted once, Google's token and signing hosts leave the grants,
and a prod datalake request makes one card.

## Build order

Each step ships alone, with the suite green.

1. One card per use on today's grants: a network grant and a token grant
   over one request decided together, the strictest winning.
2. Resources with locks, isolation as locks; grants on, off or disabled
   over resources; overlaps; *Try a use* and `mwt why` on whole uses,
   recent decisions and dry runs; actions; the
   built-in grant for asking to run commands; `mwt exec` on credentials;
   the migration and its merge; `mwt grants` and the guides rewritten.
3. Attributes: declared by the drivers there are, gRPC and GraphQL as
   drivers of their own, matched in scopes and allowances, the widening
   steps on cards.
4. Adapters: `bearer`, `github` and `google` behind the extension points,
   moving Google's and GitHub's knowledge out of `Grant`, `Server.Grants`,
   `Values`, `CredentialEndpoint` and `Inbox`; the GitHub App token.
5. Export: the sandbox section, on the data of step 2.

## What this leaves out

- Telling processes in the VM apart. The agent is root there.
- What a call does inside a service. That is the provider's, through the
  credential it issues.
- Drivers and adapters from anyone but MWT.
- A placeholder per `mwt exec` run, which could come later on top of made
  values.

## Open questions

None left. What is still to be learned shows while building: the drivers'
and adapters' attributes, one by one, and how often a *may overlap* link
turns out to matter.
