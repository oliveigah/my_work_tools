# Proposing a grant or an action

Read this before you run `mwt propose`: when no grant fits and you know
exactly what the work needs, or when you will need the same job on the
user's machine again.

`mwt propose` saves what you propose at once in the user's grants: off,
never on at startup, tagged as proposed by you and to review. Nothing
turns it on until the user reads it on its page and accepts it; meanwhile
`mwt propose` waits as `mwt request` does (exit 2 and an ask id for
`mwt wait` while it waits, 0 once it is on, 3 if they decline it, which
removes it). Proposing again under the same `--name`, before they review
it, changes it. It never carries a value, an approval mode or a start
setting: those are the user's.

A whole grant, when none fits and you know what the work needs:

    mwt propose token --name "GitHub, read-only, klife" \
        --for "gh and git over HTTPS, reading oliveigah/klife" \
        --preset github \
        --reason "I need the open issues of klife for this task"

    mwt propose network --name "Staging database" \
        --for "Postgres on the staging network" \
        --destination 'db.staging.corp:5432' --resolver 10.8.0.1 --via wg0 \
        --reason "The migration has to be checked against staging"

A token grant is over a credential. It lists the hosts its value may go
to (`--host`, repeated; reaching them is a network grant's, the
Internet's for public hosts), the variables its placeholder is in under
`mwt exec` (`--env`, `--file-env`), the headers it travels in when not
`Authorization` (`--carrier`), `--git` for git over HTTPS, or
`--mint 'COMMAND'` for a short-lived value the user's machine prints.
Google's client libraries (Python's `google.auth` among them) look for
default credentials, not a token file: `--metadata-project PROJECT` gives
them a metadata server under `mwt exec`, and `--metadata-account EMAIL`
the service account it reports. A client of a service behind
Identity-Aware Proxy that has Google sign a JWT as a service account
(`signJwt`) needs `--sign-as ACCOUNT` and the service's host;
`--keep-minutes N` mints again after at most N minutes, for a service
that takes a token only while it is young.
A tool that refreshes a Google login itself, as one sending an ID token
does, needs `--login-file` (and `--id-token-header HEADER` when it sends
the ID token in a header of its own), with a `--mint` that prints the ID
token too: `gcloud config config-helper --force-auth-refresh --format=json`
(`--preset google-login`). Google's token and signing endpoints are
implied: don't list them. `--preset` starts from one of MWT's (`github`,
`github-app`, `google`, `google-login`, `hex`). Say in `--for` what the
token should be allowed to do: the user creates it, as narrow as the
service allows, and pastes it as they review it. A network grant lists
its destinations (`--destination`, repeated), the DNS server for their
names (`--resolver`) and the interface they go through on the user's
machine (`--via`). Propose the narrowest access that does the job.

When you expect to need the same job again, propose a saved command, an
action on the user's machine, instead of asking to run it ad hoc each
time:

    mwt propose commands --name "gh repo view" \
        --for "Shows a GitHub repository: description, default branch, visibility" \
        --param 'REPO_NAME:word:the repository, as owner/name' \
        --reason "I check several repositories while I work on this" \
        -- 'gh repo view "$REPO_NAME"'

The user reads it once, may change it, and accepts it; `mwt propose` then
says its id and how to call it. It needs no other grant to be on. They decide how
much to trust it, up to letting it run without asking from then on, so
design it for the person approving it. They should understand at a glance
everything it could ever do:

- **One job.** A name that says what it does, and a `--for` that describes
  it for any call ("Lists the pods of a namespace in the staging cluster"),
  not for this one: that is `--reason`.
- **A script read in seconds:** one command, a few words. Bring the raw
  output back and work on it in the VM.
- **The fewest parameters,** only for what really varies between calls.
  What is the same every time belongs in the script.
- **The narrowest shape that works:** a number for a number, a list
  (`staging|production`) when the values are few and known, a word for a
  name; `text` only for what must hold spaces. Say what each one is.
- **Read each parameter in double quotes,** `"$NAME"`, and give the script
  in single quotes so your shell leaves `$NAME` alone. Every parameter has
  to appear in the script.
- **Reading and changing apart.** One that only reads is easy to trust for
  good; don't add a flag that makes the same action write, delete or
  deploy. Propose that as another one.

A request action goes under its credential (`mwt propose CREDENTIAL`),
with the request instead of a script. The host is fixed, written out, and
reaching it needs a grant over its network; a parameter goes in the path
or the query, or as a whole JSON value in `--data`, never inside a longer
text. Headers are fixed: leave them out and MWT uses the ones the
service expects, with the token in its place.

    mwt propose github --name "pr view" \
        --for "Shows a pull request of a GitHub repository, as JSON" \
        --param 'REPO:word:the repository, as owner/name' \
        --param 'PR:number:the pull request' \
        --method GET --url 'https://api.github.com/repos/$REPO/pulls/$PR' \
        --reason "I review the open pull requests one by one"

Prefer one to a command when a credential serves the service: the user
reads the exact request on its card.
