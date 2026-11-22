# Access: grants, subgrants, token grants, the network, MWT's answers

Read this before you first use a token grant, and when MWT refuses
something you need.

## Asking

`mwt request GRANT_ID --reason "what you are about to do, and why"` asks
the user to turn a grant on. Add `--minutes N` for how long you need it
(60 by default). `mwt` waits up to a minute for the answer; if it says the
ask is still waiting, keep working on what doesn't need it and run
`mwt wait ASK_ID` later. It exits with 0 when the grant is on, 1 when the
ask was wrong, 2 while it waits for the user, 3 when declined or given up,
4 when MWT is locked or closed.

Even with a grant on, each use (each request carrying the placeholder, each
connection to a private address) waits for the user's approval unless they
allowed it for a while. A request can hang for minutes: wait, and don't
retry in a loop.

## Subgrants

A subgrant is one fixed use of a grant, which MWT carries out for you when
you call it by its id, with a value for each of its parameters:

    mwt call gh-repo-view REPO_NAME=oliveigah/klife --reason "why now"

`mwt grants` lists them under their grant, with their parameters. Look for
one before anything else.

- **You send an id and values, never a command or a request.** A subgrant
  of Ask to run commands is the user's own script: it runs on their
  machine, in the folder they chose, and reads your values as variables.
  Its output comes back, with its exit status.
- **A subgrant of a token grant is a request MWT sends itself,** with that
  grant's real value: no tool or placeholder needed in the VM. The
  answer's body comes back on stdout and its HTTP status on stderr; `mwt`
  exits 0 for a 2xx answer, 22 for any other.
- **It has a switch of its own.** One that is off: `mwt request ID`. The
  user approves every call, unless its line says it runs without asking.
- **A value has a shape**, which its line says: a word (letters, digits and
  `_ . - @ : +`, in parts joined by `/`), a number, one of a list, or text.
  A value of another shape is refused before anything runs, and so is a
  value that starts with `-`.
- **MWT never takes a command for a subgrant.** Sending a subgrant's exact
  text through Ask to run commands is an ad-hoc command like any other, and
  waits for the user.

When you will need the same job again and no subgrant does it, propose
one: `mwt help propose`.

## Token grants

Token grants do not export credentials into the VM or ordinary shells. For
an API call, look first for a subgrant of the grant: MWT sends that request
for you, and nothing in the VM needs the token. Otherwise, after turning a
token grant on, run the command that needs it with
`mwt exec GRANT_ID -- COMMAND [ARG...]`, for example
`mwt exec github -- gh api user`. This runs here in the VM, unlike
`mwt run`, which asks to run on the user's machine. Shell expansion happens
before `mwt exec`: when using a variable in a command, put it inside the
child shell, e.g. `mwt exec github -- bash -c 'curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user'`.

Only that command and its children receive variables such as `GH_TOKEN` or
token-file variables. These hold placeholders, not real values. Git's MWT
credential helper also answers only within the selected grant's command.
MWT swaps the real value in on the way out, only toward that grant's hosts.
A placeholder is worthless anywhere else: don't copy it, print it or send
it elsewhere, and don't look for the real value. Run public downloads and
other commands that need no credentials normally, without `mwt exec`.
`mwt exec` passes the command's exit status through, and exits 125 only
when it didn't run it (the grant is off or unknown), with a line on
stderr. It nests: `mwt exec github -- mwt exec hex -- COMMAND` gives the
command both. Git run outside it says, for a host a grant covers, which
grant to run it through.

## The network

- Private addresses (10.x, 172.16-31.x, 192.168.x, VPN ranges) and the
  user's machine are refused unless a network grant lists them. A name a
  network grant lists resolves only while that grant is on: look it up
  after the grant turns on, not before, and connect to the address MWT
  answered.
- Public addresses are the Internet grant's (`internet`), usually always
  on. While it is off, only what other grants list is reached: a token
  grant's hosts, a network grant's destinations; other connections are
  refused or close, and DNS finds only those names. When a task needs
  more, ask for it: `mwt request internet --reason "..."`.
- When a lookup fails or a connection is refused, run
  `mwt why HOST[:PORT]` before anything else: it says which grant covers
  that destination and why it isn't reached now (off, another port, the
  Internet off, the firewall), and how to ask for it.
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
  call or save a subgrant, or to run a command there.

## MWT's answers

An HTTP error whose JSON body has `"by": "MWT agent sandbox"` comes from
MWT, not from the service. Its `code`:

- `mwt_grant_off`: the grant exists but is off. Ask for it with
  `mwt request`.
- `mwt_denied_by_user`: the user refused this use. Don't retry unless
  asked; tell the user what you were trying to do.
- `mwt_approval_timeout`: nobody answered in time. Tell the user, and try
  again when they're ready.
- `mwt_too_many_waiting`: too many of your requests already wait for the
  user. Wait for them to decide, then try again; don't retry in a loop.
- `mwt_placeholder_blocked`: the placeholder was sent to a host its grant
  doesn't cover.
- `mwt_no_value`, `mwt_mint_failed`: the grant can't give a value right
  now. Tell the user.
- `mwt_credential_endpoint`: the request would have sent a grant's value
  to an endpoint whose answer is a new credential (a token exchange, key
  creation). It wasn't sent. Tell the user if you need it.
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
