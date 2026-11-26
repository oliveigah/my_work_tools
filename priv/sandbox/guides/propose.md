# Proposing a resource, a grant or a fixed call

Read this before you run `mwt propose`: when nothing fits and you know
exactly what the work needs, or when you will need the same job on the
user's machine again.

`mwt propose` saves what you propose at once in the user's MWT, tagged
as proposed by you and to review, the way they add things: a resource
(a credential, a network) first, then grants over it. Nothing is usable
until the user reads it on its page and accepts it; meanwhile `mwt
propose` waits as `mwt request` does (exit 2 and an ask id for `mwt
wait` while it waits; 0 once accepted, or for a grant once it is on; 3
if they decline it, which removes it). Proposing again under the same
`--name`, before they review it, changes it. It never carries a value,
an approval mode or a start setting: those are the user's.

A credential and a grant over it, sent together: the user accepts the
credential first, then the grant.

    mwt propose credential --name "GitHub App" \
        --for "My App's installation token, for gh and git" \
        --preset github-app --fill app_id=Iv23liABCD \
        --fill installation_id=12345678 \
        --fill key_command='pass show github/app-key' \
        --reason "The task opens pull requests on klife"

    mwt propose grant --over "GitHub App" --name "klife only" \
        --for "gh and git on oliveigah/klife" \
        --preset github-repository --fill repository=oliveigah/klife \
        --reason "The task opens pull requests on klife"

    mwt propose network --name "Staging" \
        --for "The staging network, through the VPN" \
        --destination 'db.staging.corp:5432' --resolver 10.8.0.1 --via wg0 \
        --reason "The migration has to be checked against staging"

Each starts from a preset of what it makes, when you name one; its
options set their fields; `--set FIELD=VALUE` sets any field of its form
over both, and `--fill NAME=VALUE` fills a preset's blanks. A field you
name wrong, or one of the user's, is refused with the list of fields.

A credential says the service it is for (`--set adapter=github`,
`google`, `hex` or `bearer`), the variables its placeholder is in under
`mwt exec CREDENTIAL` (`--env`, `--file-env`), `--git` for git over
HTTPS, or `--mint 'COMMAND'` for a short-lived value the user's machine
prints. A GitHub App is `adapter=github` with `app_id`,
`installation_id` and a `--mint` that prints its private key: MWT trades
it for an hour's token. Google's client libraries look for default
credentials: `--metadata-project PROJECT` gives them a metadata server,
and `--metadata-account EMAIL` the account it reports. A tool that
refreshes a Google login itself needs `--login-file` (and
`--id-token-header HEADER` when it sends the ID token in a header of its
own), with a `--mint` that prints the ID token too (`--preset
google-login`). `--keep-minutes N` mints again after at most N minutes.
Credential presets: `github`, `github-app`, `google`, `google-login`,
`hex`. A pasted value is the user's: say in `--for` what it should be
allowed to do, and they create it as narrow as the service allows.

A grant over a credential lists the hosts its value may go to (`--host`,
repeated; reaching them is a network grant's, the Internet's for public
hosts), the headers it travels in when not `Authorization`
(`--carrier`), and the service accounts MWT may sign a JWT as with it
for a client of a service behind Identity-Aware Proxy (`--sign-as`).
`--set attributes='github.repository = owner/name'` narrows it further.
Grant presets: `github-everything`, `github-repository`, `google-apis`,
`hex-packages`. A network lists its destinations (`--destination`), the
DNS server for their names (`--resolver`) and the interface they go
through on the user's machine (`--via`); a grant over it opens all of
it, or the destinations it lists. Propose the narrowest access that
does the job.

When you expect to need the same job again, propose a saved command, a
fixed call over host commands, instead of asking to run a command you
write each time:

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
- **A schema where a wrong value would hurt:** `--set schema='…'`, one
  JSON Schema for all the parameters, instead of `--param` lines
  (`"pattern"`, `"enum"`, `"minimum"`…).
  `mwt help resources` says how to write it, resources and grants.
- **Read each parameter in double quotes,** `"$NAME"`, and give the script
  in single quotes so your shell leaves `$NAME` alone. Every parameter has
  to appear in the script.
- **Reading and changing apart.** One that only reads is easy to trust for
  good; don't add a flag that makes the same call write, delete or
  deploy. Propose that as another one.

A fixed request goes under its credential (`mwt propose CREDENTIAL`),
with the request instead of a script. The host is fixed, written out, and
reaching it needs a grant over its network; a parameter goes in the path
or the query, or as a whole JSON value in `--data`, never inside a longer
text. Headers are fixed: leave them out and MWT uses the ones the
service expects, with the credential's value in its place.

    mwt propose github --name "pr view" \
        --for "Shows a pull request of a GitHub repository, as JSON" \
        --param 'REPO:word:the repository, as owner/name' \
        --param 'PR:number:the pull request' \
        --method GET --url 'https://api.github.com/repos/$REPO/pulls/$PR' \
        --reason "I review the open pull requests one by one"

Prefer one to a command when a credential serves the service: the user
reads the exact request on its card.
