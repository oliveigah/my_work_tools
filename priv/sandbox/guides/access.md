# Access: grants, actions, credentials, the network, MWT's answers

Read this before you first use a credential, and when MWT refuses
something you need.

## Asking

`mwt request GRANT_ID --reason "what you are about to do, and why"` asks
the user to turn a grant on. Add `--minutes N` for how long you need it
(60 by default). `mwt` waits up to a minute for the answer; if it says the
ask is still waiting, keep working on what doesn't need it and run
`mwt wait ASK_ID` later. It exits with 0 when the grant is on, 1 when the
ask was wrong, 2 while it waits for the user, 3 when declined or given up,
4 when MWT is locked or closed.

A grant gives uses of one resource: a credential, a network, the user's
machine or MWT's tools. Off, it gives nothing. A use needs a grant that is
on over each resource it goes through: a request with a placeholder needs
one over the credential listing the host and one over the host's network
(usually the Internet's). It goes unasked only if each lets it through
unasked; otherwise it waits for the user's approval, for minutes: wait,
and don't retry in a loop. A locked resource refuses everything, and an
ask for a grant over it is refused at once.

## Actions

An action is one fixed use of a resource, which MWT carries out for you
when you call it by its id, with a value for each of its parameters:

    mwt call gh-repo-view REPO_NAME=oliveigah/klife --reason "why now"

`mwt grants` lists them under their resource, with their parameters. Look
for one before anything else.

- **You send an id and values, never a command or a request.** A saved
  command is the user's own script: it runs on their machine, in the
  folder they chose, and reads your values as variables. Its output comes
  back, with its exit status.
- **A request action is a request MWT builds** and sends through its
  proxy, as your requests go, with its credential's real value put in on
  the way out: no tool or placeholder needed in the VM. An answer that
  echoes the value is cut. The body comes back on stdout, the HTTP status
  on stderr; `mwt` exits 0 for 2xx, 22 for any other.
- **It covers its credential for its own call, nothing else;** its
  request goes out as yours would: a network grant must let its host out.
- **It has a switch of its own.** One that is off: `mwt request ID`. The
  user approves every call, unless its line says it runs without asking.
- **A value has a shape**, which its line says: a word (letters, digits and
  `_ . - @ : +`, in parts joined by `/`), a number, one of a list, or text.
  A value of another shape is refused before anything runs, and so is a
  value that starts with `-`.
- **MWT never takes a command for an action.** Sending an action's exact
  text with `mwt run` is a command of yours like any other, and waits for
  the user.

When you will need the same job again and no action does it, propose
one: `mwt help propose`.

## Credentials

No credential enters the VM. For an API call, look first for an action:
MWT sends it for you. Otherwise run the command with
`mwt exec CREDENTIAL -- COMMAND [ARG...]` (`mwt grants` names each), e.g.
`mwt exec github -- gh api user`. It runs here in the VM. Shell expansion
happens first: put a variable inside the child shell, e.g. `mwt exec github -- bash -c 'curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user'`.

That command and its children get placeholders (variables like
`GH_TOKEN`, a token file, git's helper). `mwt exec` decides nothing: the
grants decide each request by where it goes. A placeholder is worthless
anywhere else: don't copy, print or send it, and don't look for the real
value. Run what needs no credential without `mwt exec`. It passes the
exit status through, and exits 125 only when it didn't run the command
(no grant over it on, locked, unknown). It nests:
`mwt exec github -- mwt exec hex -- COMMAND`.

## The network

- Private addresses (10.x, 172.16-31.x, 192.168.x, VPN ranges) and the
  user's machine are refused unless a network grant lists them. A name a
  network grant lists resolves only while that grant is on: look it up
  after the grant turns on, not before, and connect to the address MWT
  answered.
- The Internet's grant (`internet`), usually on, opens public addresses.
  Off, only what other grants over the Internet name is reached, and DNS
  finds only those names: a token grant's hosts need it too. When a task
  needs more, ask for it: `mwt request internet --reason "..."`. A host the
  user blocked on its network is refused whatever the grants say.
- When a lookup fails or a connection is refused, run
  `mwt why HOST[:PORT]` before anything else: which grant covers it, why
  it isn't reached now, and how to ask for it. `mwt why URL [--method M]
  [--with CREDENTIAL]` decides a request without sending it, each grant's
  say shown; `mwt why --recent` lists what was refused or asked about,
  `mwt why ID` explains one as it was decided. A refusal names its id
  (`"decision"`, `"why"` in its JSON).
- MWT's firewall watches what the VM does through MWT: uploads, lookups,
  placeholders, commands you ask to run. On a sign of trouble it isolates
  the VM: connections close, lookups fail, and `mwt` refuses anything that
  acts, saying so. `mwt grants` and `mwt vm` still answer.
- When the network or `mwt` stops answering ("connection refused" from
  everything), run `mwt vm`. It says whether this VM is still the one MWT
  runs. If it isn't, nothing you do in here fixes it: tell the user to
  reconnect.
- Nothing you run reaches the user's machine, except `mwt`, which can only
  read the grants and the machine's description, and ask: for a grant, to
  call or save an action, or to run a command there.

## MWT's answers

An HTTP error whose JSON body has `"by": "MWT agent sandbox"` comes from
MWT, not from the service. Its `code`:

- `mwt_grant_off`: a grant it needs is off. Ask for it with
  `mwt request`.
- `mwt_not_covered`, `mwt_locked`: no grant covers this use (propose one),
  or the user locked what it needs (only they unlock it). Tell the user.
- `mwt_denied_by_user`: the user refused this use. Don't retry unless
  asked; tell the user what you were trying to do.
- `mwt_approval_timeout`: nobody answered in time. Tell the user, and try
  again when they're ready.
- `mwt_too_many_waiting`: too many of your requests already wait for the
  user. Wait for them to decide, then try again; don't retry in a loop.
- `mwt_placeholder_blocked`: the placeholder was sent to a host no grant
  over its credential lists.
- `mwt_host_blocked`: the user blocked this host on its network. Every
  request there is refused, whatever the grants say. Don't work around
  it; tell the user if you need it.
- `mwt_plain_http`: the request is plain HTTP and carries a placeholder.
  MWT puts no real value in plain HTTP: use `https://`.
- `mwt_no_value`, `mwt_mint_failed`: the grant can't give a value right
  now. Tell the user.
- `mwt_credential_endpoint`: the request would have sent a value to an
  endpoint whose answer is a new credential. It wasn't sent.
- `mwt_upstream_tls`: MWT couldn't make TLS with the host (a certificate
  the user's machine doesn't trust, one that expired, a client certificate
  it wants). Nothing went out. Tell the user the host.
- `mwt_isolated`: MWT's firewall isolated this VM. Nothing it sends leaves
  through MWT until the user releases it, and they have been told. Stop,
  and tell them what you were doing; don't look for a way around it.

## MWT's own tools

The MCP server `mwt` works with no token; three grants decide each call:
`mwt-read` (the `list_*` and `get_*` tools; HTTP requests can't be read
from the VM, the user's or yours: their history holds the credentials
they sent), `mwt-create` (the `create_*` tools and `import_http_request`,
which add and change nothing already there) and `mwt-change` (the
`update_*` tools, with the `version` the `get_*` tool returned). A call
whose grant is off says so: ask with `mwt request GRANT --reason`. The
user sees each change as a diff and usually approves it: a call can wait
up to a minute, then says it is still waiting, with an id for `mwt wait`.
Don't send it again.
