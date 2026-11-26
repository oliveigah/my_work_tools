# Grants

How you decide what agents in the VM may reach, as it works today. The
reasoning behind each choice is in [grant_mental_model.md](grant_mental_model.md);
the whole design is in [agent_sandbox.md](agent_sandbox.md#grants).

## What it is for

An agent in the VM works for you, and part of that work leaves the VM: a
request to GitHub with your token, a query to the staging database over
the office VPN, `kubectl get pods` on your machine, where your kubeconfig
is. Grants are how you say which of those it may do, whether each one
waits for you, and for how long. Editing, building and testing inside the
VM need no grant.

## The pieces

**A resource** is something of yours that an action goes through:

| Resource | What it is | Built in |
|---|---|---|
| A credential | A token, an API key, a GitHub App, a login a command on your machine mints. Its value never enters the VM: tools there get a placeholder. | no |
| A network | The Internet, or one you add: a VPN, a LAN, with its destinations, DNS server and interface. | the Internet |
| Host commands | Code run on your machine. | yes |
| MWT's tools | Notes, diagrams and flash cards (`mwt mcp`), and MWT's own git fetch, handoff, sync and workspace. | yes |

**A grant** gives uses of one resource while it is on. Off, it gives
nothing. Each has a name, *What it's for* (agents pick grants by it, and
you approve by it), and an id agents use in `mwt request`, `mwt exec` and
`mwt call`.

**Two kinds of grant**, by who builds what goes out:

- **Open use:** the agent builds it with its own tools (`gh`, `git`,
  `curl`, `psql`), and MWT checks each request or connection as it leaves.
  An open-use grant over a credential lists the hosts its value may go to,
  and may narrow further (*Only these uses*: `github.repository =
  oliveigah/klife`, `http.method = GET`). One over a network opens all of
  it or only the hosts it lists.
- **Fixed call:** MWT builds it from a template you saved or accepted, and
  the agent only sends values (`mwt call pr-view REPO=oliveigah/klife
  PR=12`). Two forms:
  - a **fixed request**, over a credential: one HTTP request, with the
    credential's value put in on the way out;
  - a **saved command**, over host commands: your script, run on your
    machine in a folder you chose, confined or as you.

  Each value must keep to the call's parameters (one JSON Schema: a word, a
  number, one of a list, a pattern…).

**Commands agents write** is a built-in open-use grant over host commands:
while it is on, agents may *ask* to run a command they wrote
(`mwt run -- COMMAND`). Every run waits for you, whatever you set, and none
is ever handed a credential's value.

**Each grant's condition:**

- *On for*: 15 min, 1 h, 4 h, or until you turn it off.
- *Each use*: **Ask me** (a card waits for you) or **Auto** (it goes
  through, and is logged).
- *When MWT starts*: off, or on (asking, or auto) from each start.
- *Allowed for now*: from a card, you can let uses like it, or every use
  of the grant, through for 10 minutes, an hour, or while it is on.

## How MWT decides

Every action that leaves the VM goes through MWT. For each one:

1. **Each resource it goes through needs a grant that is on and covers
   it.** A request carrying your GitHub token goes through two: the GitHub
   credential (a grant listing `api.github.com`) and the Internet (its
   grant, or one over that host).
2. **Within one resource, the most permissive grant counts.** Grants only
   give: one that lets a use through without asking wins over one that
   asks.
3. **Across resources, the strictest answer wins:** a refusal over an ask,
   an ask over a yes. When several grants ask, you get one card naming each.
4. **A lock refuses everything** that goes through its resource, whatever
   the grants say. So does a host you blocked on a network, and isolation
   locks everything.

A fixed request is the grant for the credential *in its own request*, and
nothing else: your agent's own `mwt exec github -- gh api …` still needs an
open-use grant over GitHub. Its request leaves as the agent's own would, so
the Internet's grant (or one over its host) has to let it out too; a grant
page says so in red when nothing does.

| The agent does | Grants it needs |
|---|---|
| `curl https://example.com` | the Internet |
| `mwt exec github -- gh pr view 12` | the Internet, and an open-use grant over GitHub listing `api.github.com` |
| `mwt call pr-view REPO=… PR=12` | the fixed request `pr-view`, and the Internet |
| `psql -h db.office.lan` | a grant over the Office VPN covering `db.office.lan` |
| `mwt call kubectl-pods NAMESPACE=web` | the saved command `kubectl-pods`; host commands, and each credential it runs with, unlocked |
| `mwt run -- 'kubectl get pods'` | Commands agents write (always asks) |
| `git fetch host-origin` | Git: fetch (MWT's tools) |
| `update_note` through `mwt mcp` | MWT: change (MWT's tools) |

## Common setups

- **GitHub, one repository.** Add a GitHub credential (paste a
  fine-grained token, or use the GitHub App preset, which mints an hour's
  token). Add an open-use grant over it from the *One repository*
  preset. Keep it on *Ask me* until you trust it.
- **One repeated API call, without asking.** A fixed request over the
  credential, with narrow parameters, set to *Auto*. Agents call it by id.
- **The Internet, but one host always asks.** Keep the Internet's grant on
  *Auto*, list the host under its *Except these hosts*, and add a grant
  over that host that asks.
- **Only a few hosts.** Turn the Internet's grant off, and add a grant over
  the Internet listing them. DNS then answers only those names.
- **A database behind your VPN.** Add the network (destinations, its DNS
  server, its interface such as `wg0`), then a grant over it listing
  `db.office.lan:5432`.
- **A job on your machine you do often.** A saved command: one command,
  read in seconds, each value a narrow parameter, confined when it doesn't
  need your logins.

## Reading a fixed call's grade

A fixed call is only as narrow as its template. MWT reads each one and
grades it, as a warning that never changes what asks:

- **Narrow:** each value only picks among what the template names.
- **Wide:** a value reaches anything of a kind (any repository your token
  reaches, any pod in a namespace).
- **Open:** a value can become code or a command (`bash -c "$P"`, `$CMD` as
  the first word, a parameter read unquoted). That is open use in
  disguise: don't let it run on *Auto*.

The files a saved command runs (`./deploy.sh`, `python x.py`) are pinned
when you save or accept it: changed since, its next run asks and shows
the change. A file MWT can't name from the text (a path in a variable)
makes every run ask.

## When an agent asks

- `mwt request ID` asks you to turn a grant on, with its reason.
- `mwt request --need "…"` asks for access no grant gives.
- `mwt propose` adds a resource or grant, tagged as proposed, to review. It
  stays off until you accept it on its page, and it never carries a value,
  an approval mode or a start setting.

Each card says what will happen and which grants asked. *Allow once*,
*Allow for a while* (uses like it, or every use of the grant), *Deny*, or
*Deny and turn off*.

## Finding out why

- **Activity log:** every action, with *How it was decided*: by you, by an
  allowance, by a grant on Auto, or refused, and why.
- **Try it as the VM** (Grants › Live Test): run a command in the VM, with a
  credential if you like, and see what MWT decided for each request.
- Agents run `mwt why HOST`, `mwt why URL --with CREDENTIAL` or
  `mwt why --recent`, and get the same reasons.

## What a grant can't promise

- **A saved command that isn't confined runs as you,** with your SSH keys,
  cloud logins and network in reach. MWT sees its text, output and exit
  status, not what it does while it runs.
- **A credential is only as narrow as the token itself.** A fine-grained,
  read-only, one-repository token is the strongest limit you have; MWT's
  hosts and attributes come on top of it.
- **A mint command runs on your machine, as you,** each time a value is
  needed, without a card. Read it before you accept a credential an agent
  proposed.
- **An open fixed call is open use** whatever its kind says: its grade is
  the warning.
- **What the VM already holds can leave** through any grant that lets it
  out. The firewall catches the obvious (large uploads, a placeholder going
  elsewhere), not everything.
- **Your values are looked for in what MWT reads.** An answer holding one
  is cut; a host set to *Don't read* isn't looked through.
