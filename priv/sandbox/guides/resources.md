# Writing resources and grants

For the user setting up MWT, and for agents proposing what the user then
reviews (`mwt help propose` has the commands). What you write decides
what an agent in the VM can reach, so write the narrowest thing that does
the job, in words the person approving it reads at a glance.

## The model

- A **resource** is something of the user's an agent could use: a
  credential, a network (the Internet among them), host commands (code
  run on the user's machine), MWT's tools. The user can lock one: every
  use refused.
- A **grant** gives a use of one resource while it is on; off, nothing.
  Grants only give: of those that are on and cover a use, the most
  permissive counts. A use through two resources (a request carrying a
  credential, over the Internet) needs a grant over each; across them, a
  refusal beats an ask and an ask beats a yes. A fixed request is the
  credential's grant for its own call, and its request goes out as the
  agent's would, under a network grant.
- Each grant says what it is for (`purpose`, `--for`): the service, the
  access and the job, such as "Push to github.com/me/site and open pull
  requests". Agents pick grants by it, and the user approves by it.

## Credentials

The value never enters the VM: tools there get a placeholder, which MWT
swaps for the value on the way out, where a grant lets it.

- **How the value is made.** Prefer one minted on demand and short-lived
  (a GitHub App's installation token, `gcloud auth print-access-token`)
  to a stored one. A stored value is the user's to paste, made as narrow
  as the service allows: one repository, read-only, an expiry.
- **The service** (`adapter`: github, google, hex, bearer) decides what
  MWT reads in each request, so grants can narrow by it.
- **Where tools find it** in the VM: the variables (`GH_TOKEN`), a file,
  git's credential helper. Presets fill these in: github, github-app,
  google, google-login, hex.

## Grants over a credential: two kinds

The kind says who builds what goes out: the agent (open use) or MWT,
from a template (fixed call). Host commands take both too: Commands
agents write is open use, a saved command a fixed call.

**Open use** (the agent builds it): agents run their own tools with the
placeholder (`mwt exec CREDENTIAL -- gh pr create …`), and MWT checks
each request as it leaves. For open-ended work. Write:

- the hosts its value may go to: only those the service needs;
- the headers it travels in, when not `Authorization`;
- *Only these uses* (`attributes`), a line each:
  `github.repository = oliveigah/klife`, `http.method = GET`,
  `git.direction = fetch`, `graphql.operation = query`;
- Ask, until the user trusts it; Auto once its limits are tight.

**Fixed request** (MWT builds it): one request MWT builds and sends
through its proxy, the agent giving only values (`mwt call ID
NAME=value`). It covers its credential for its own call, nothing else
(open use of the credential is a grant of its own), and its request
goes out as the agent's would: a grant over the host's network has to
let it out. What can happen is exactly the call, as far as its template
is narrow (below). Write the method and URL, `$NAME` where a value goes
(the path, the query, or a whole JSON value in the body, never inside a
longer text), and the headers with `{token}` where the value goes, or
none for the service's own.

Pick open use when the calls can't be known beforehand, a fixed call for
one narrow job done again and again.

## Networks and their grants

The Internet is built in. Add a network for a VPN or a LAN: its
destinations (`db.corp.example:5432`, `*.corp.example`, `10.20.0.0/16`),
the DNS server for its names, the interface it goes through.

A grant over a network gives all of it, or its **request targets**: the
hosts, names under a domain (`*.corp.example`), addresses or ranges it
lists, `:ports` optional. Its **except these hosts** (`except`) leaves
host names out: the grant has no say about them, so another grant over
them decides, and with none on they are refused.

- One host always asks, the rest goes through: the Internet's grant on
  Auto, the host under its *Except these hosts*, and a grant over the
  host that asks.
- Only some hosts: the Internet's grant off, a grant over those hosts.
- Never this host, whatever grants say: the network's host limits
  (Blocked), on its page, not a grant.

## Saved commands: fixed calls on host commands

A script of the user's, run exactly as saved, in a folder they choose;
agents call it by id with values. Keep it to one job, read in seconds:
one command, the raw output brought back to the VM. *Runs confined* puts
it in a bubble: an empty home, the user's tools and system read-only,
none of their SSH keys or cloud logins; not confined, it runs as the
user, with all they can reach. A confined one may take credentials' real
values (`with`): the saved command covers them. The files it runs are
pinned as it is saved: one changed since makes the next run ask. Reading
and changing apart: a command that only reads is easy to trust for good.

## Parameters: one JSON Schema

What an agent chooses on each call is one JSON Schema, as an MCP tool
says its input: an object whose properties are the parameters, each with
its `description` and what its values may be. On the form it is
*Parameters*; in a proposal, `--set schema='…'`, or `--param 'NAME:
shape: what it is'` lines, a shorthand for the same.

    {
      "type": "object",
      "properties": {
        "REPO": {"description": "the repository, as owner/name",
                 "type": "string", "format": "word",
                 "pattern": "^oliveigah/[a-z0-9-]+$"},
        "COUNT": {"description": "how many", "type": "integer",
                  "minimum": 1, "maximum": 10},
        "TARGET": {"description": "where it deploys", "type": "string",
                   "enum": ["staging", "production"]}
      }
    }

- Names are capitals (`REPO_NAME`); a script reads each as `"$NAME"`, in
  double quotes, and every one must appear in it; a request puts each
  where `$NAME` is, encoded. All are required, at most 8.
- `type` is `string`, `integer`, `number` or `boolean`: one value each.
- `format`: `date`, `date-time`, `email`… and MWT's `word` (letters,
  digits, `_ . - @ : +`, parts joined by `/`, nothing else): the safe
  default for a name or a path under a folder.
- `pattern` matches anywhere unless anchored with `^` and `$`.
- Whatever it says, MWT refuses a value that starts with `-` (but a
  number), goes up a folder (`..`), or hides characters.
- A call whose values break it is refused before anything runs, and the
  agent is told why (`value 11 is higher than maximum 10`).
- A parameter's schema reads nothing outside itself: `$ref` only to
  `#/$defs/…`, no `$id`; at most 2 KiB.
- Give every parameter that could reach something dangerous a narrow
  schema: a repository of the user's, an environment that isn't
  production, a count with a ceiling.

## Before you save or propose

- Its purpose names the service, the access and the job.
- Hosts, targets and attributes are the fewest that do the job.
- A narrow fixed call over a broad open use, when the job is one call.
- Every parameter of a fixed call has the narrowest schema that does
  the job. MWT grades each call: *Narrow* (values pick among what the
  template names), *Wide* (any word, any text as one argument), *Open*
  (a value becomes code: `eval`, `bash -c`, the command's name, `ssh`,
  text read bare). Open is open use in disguise: don't write one.
- What must never be reached quietly is left out (*except*) or blocked,
  not hoped away.
