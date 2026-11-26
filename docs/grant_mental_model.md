# Grants: the mental model

A discussion doc, being sharpened (started 2026-11-25). Where MWT works
otherwise today, it says so. Questions keep their numbers (Q1…) once
asked; answered ones move to "Decided". How grants work today, for
setting them up, is in [grants.md](grants.md).

## The main operation

An agent in the VM works for you, and part of that work needs something
outside the VM: a service with your login, a network, a command on your
machine, your notes. You decide what it may reach and how, you see what
it did, and you can stop it. Each block below is here because one of
those needs it.

The typical case: the agent fixes a bug in klife. It reads the pull
request on GitHub with your token, queries the staging database over the
Office VPN, and asks to run `kubectl get pods` on your machine, where your
kubeconfig is. Each of those leaves the VM. Editing and testing the code
doesn't.

## Terms

- **Action:** anything the agent does that leaves the VM.
- **Channel:** the way an action leaves the VM. One of:
  - a network (the Internet, the Office VPN);
  - host commands (code run on your machine);
  - MWT (its own tools).
- **Credential:** a secret MWT holds and uses inside an action (GitHub's
  token, Stripe's key, a signing key). The VM never holds it.
- **Resource:** a channel or a credential. It is what exists, what a grant
  is over, and what you lock.
- **Open use:** the agent builds the action itself (any request to the
  Internet; a command it writes). Two kinds of grant give it:
  - an **open channel grant**: actions the agent builds may go through
    one channel (the Internet, Commands agents write);
  - an **open credential grant**: actions the agent builds may carry one
    or more credentials. They still need an open channel grant to leave.
- **Fixed call:** a grant holding a template. The agent gives only
  values, which must keep to the template's schema, and MWT builds the
  action. It covers the credentials its template names, for the actions
  built from it and nothing else; what it builds goes out through its
  channel as the agent's own would (Q5).
- **Condition:** what every grant has: on or off, until when, and whether
  each use asks.
- **Made value:** something MWT computed with a credential that is itself
  a credential, such as a signed JWT. The VM holds it only as a
  placeholder.

## The model, point by point

1. **Resources are what exists: channels and credentials.** Also what you
   lock: a lock refuses every action that uses the resource, whatever the
   grants say.
2. **Actions go through a channel and may use credentials inside it.** A
   credential is used in one of three ways: carried, computed with, or
   handed over (see "Credentials: three ways to use one"). Getting a
   placeholder (`mwt exec GitHub -- …`) is not an action. The request
   that carries it out of the VM is.
3. **Three channels: networks, host commands, MWT.** MWT is the first app
   to expose a channel of its own; others may later (Q2).
4. **MWT observes every action.** Sharpened: MWT is the only way out of
   the VM, so every action crosses it, and MWT decides, scans and logs it
   there. How much MWT sees after that depends on the channel (see "What
   MWT sees").
5. **Every action needs a grant over everything it uses.** An action the
   agent builds needs an open grant over its channel, and one over each
   credential it carries. An action MWT builds from a fixed call needs the
   fixed call, which covers the credentials it names, and goes out through
   its channel as the agent's own would: on a network, a grant that lets
   the agent's request to that host out has to let it out too (Q5). Locks
   and host limits refuse either way.

   There is no exception: a command the agent writes is open use of host
   commands, under a built-in grant that always asks (Q3). These are not
   actions:
   - work inside the VM (editing, building, tests, servers);
   - talking to MWT about grants (`mwt grants`, `request`, `why`, `wait`,
     `propose`);
   - you reaching into the VM (ports 4100–4199).
6. **A credential is narrowed in one of two places.**
   - *On the token itself:* a fine-grained token that can only read one
     repository. The service enforces it.
   - *By a fixed call:* the token goes only into what MWT builds from the
     template. MWT enforces it.

   Open use of a credential is a grant of its own, given on purpose: no
   fixed call ever opens its credential to anything else (Q5). A channel
   can also fix the condition for one kind of use: open use of host
   commands always asks, whatever a grant says.
7. **Two kinds of grant: open use and fixed call.** The kind says who
   builds the action, the agent or MWT. It doesn't say where the action
   runs; the channel does.
8. **Fixed calls are safer: every lever open use has, plus control of the
   values.** True only on two conditions:
   - they go through the same pipeline as the agent's own actions
     (decided);
   - the template is narrow for every value its schema allows.

   The second is the footgun. A template can be open use in disguise, and
   still look like a fixed call. So MWT grades every fixed call and shows
   the grade, as a warning only (see "How open a fixed call is").
9. **Open use runs inside the VM.** Sharpened: open means "the agent wrote
   it", not "it runs in the VM". A command the agent writes is open use,
   and it runs on your machine.
10. **MWT builds a fixed call from the agent's values, and sends the
    result through the same pipeline as the agent's own.** The build is
    logged, and what it sends is labelled as a fixed call in the activity
    log (see "A fixed call, step by step").
11. **Fixed calls can use any channel:**
    - requests, with or without a credential;
    - host commands (yours);
    - MWT: its tools, and its own git fetch, sync, workspace and handoff.
12. **On the network the agent just makes the call; host commands go
    through `mwt`.** `mwt run` sends a command the agent writes, and
    `mwt call` a fixed one. `mwt exec` runs a command in the VM with a
    credential's placeholders.
13. **A credential's real value never reaches anything the agent wrote,
    on any channel** (Q9). This holds everywhere:
    - the VM holds placeholders only;
    - a command the agent writes on your machine is handed no value;
    - what MWT sends back (answers, output, tool results) is scanned,
      and never carries one.

    A value only goes into what MWT sends on:
    - swapped into a request on its way to a host its grant names;
    - used by MWT to sign;
    - handed to a fixed call's script, which you saved or approved.

## Why the network is transparent and host commands aren't

Two separate questions decide how an action reaches MWT. Mixed together,
they look like one inconsistency.

**How the action reaches MWT.**

- **A network:** the VM's only way out is through MWT, so MWT stands in
  the path. The agent's tools work as they are, and MWT recognises the
  action from the traffic they send anyway.
- **Host commands and MWT:** nothing in the VM runs on your machine by
  itself, so there is no path to stand in. The agent asks MWT, and MWT
  carries the action out: `mwt run`, `mwt call`, `mwt mcp`. Git's
  `host-origin` and `mwt sync` lead to MWT because they are set up to.

**Who builds it.**

- **Open use:** the agent builds it. MWT finds the open-use grant that
  covers what the agent built.
- **Fixed call:** MWT builds it, from values. The agent always names the
  fixed call by its id, and MWT never infers one (Q4).

| | Open use | Fixed call |
|---|---|---|
| A network | the agent's tools as they are | `mwt call ID VALUES` |
| Host commands | `mwt run -- COMMAND` (always asks) | `mwt call ID VALUES` |
| MWT | none | `mwt mcp`, `git fetch host-origin`, `mwt sync`, `mwt handoff` |

## A fixed call, step by step

1. **Ask.** `mwt call gh-pr-view PR=12 REPO=oliveigah/klife --reason "…"`.
2. **Scan.** The ask is scanned like everything the VM sends MWT. If it
   holds one of your real values, it is refused, and the firewall is told.
3. **Values.** MWT's floor comes first: not blank, nothing hidden, no
   leading dash, no `..`. Then the schema. A value that fails is refused
   here, and the log names the parameter, never the value.
4. **Build.** MWT fills the template:
   - for a request: the method, URL, headers and body, with the
     credential's placeholder where its value goes;
   - for a host command: the script and folder, with the values as
     variables.

   The log shows the call, its values and what was built.
5. **Send.** MWT hands what it built to the channel's own pipeline,
   marked with the fixed call it came from. The mark is kept in MWT's
   memory, so nothing the VM sends can carry it. From there the action is
   decided, swapped, sent, scanned and logged like the agent's own. Two
   things differ:
   - the fixed call is the grant for the credentials in it; the network's
     grants decide where it goes, as they would for the agent's own;
   - its line in the activity log is labelled *Fixed call · gh-pr-view*
     and links to the call that built it, so you can tell it apart from
     the agent's own requests.
6. **One decision, one card.** If any grant the action needs asks, you get
   a single card showing the fixed call, its values and the full action.
7. **Answer.** It comes back to the agent through the same checks as the
   agent's own (see "Scanning").

## Credentials: three ways to use one

1. **Carried.** The value travels in the action, as a token in a request
   header. The VM holds a placeholder, and MWT swaps in the real value on
   the way out, only toward the hosts and headers the grant names. MWT
   sees every place it goes.
2. **Computed with.** The value signs or derives something and never
   leaves MWT. The agent can't hold the key, so MWT signs, or the service
   does for MWT. What comes back depends on what the result is:
   - **A result that is itself authority:** a JWT that logs in, or a
     signature over the request. It is kept as a made value. The VM gets a
     placeholder, which goes only where the result is for (the host its
     `aud` names) and only until it expires. *Today:*
     - for a GitHub App's key, MWT signs a JWT as the App and trades it
       for an installation token, which becomes the credential's value;
     - for a Google service account, the VM asks Google to sign claims,
       and MWT keeps the signed JWT. The VM gets the claims, with a
       placeholder where the signature goes.

     A signature over each request, as AWS's keys make, fits here too:
     MWT signs each request again on the way out, where it would swap a
     token (see "AWS: signing each request").
   - **A result meant to be published:** a signature on a commit, a tag or
     a release file. It goes back to the VM, and from there anywhere. Not
     now (Q7).
3. **Handed over.** A fixed call's script gets the real value in a
   variable, as refunds-report gets Stripe's key. From then on MWT can't
   see where the value goes, because the command runs outside its sight.
   That is why only a script you saved or approved is ever handed one
   (point 13).

**Signing is an action through MWT's channel:** the agent asks, MWT signs,
and the key never moves. As open use it is the most dangerous grant there
is. "Sign anything with my key" lets the agent sign anything as you for as
long as the grant is on: a commit you never wrote, a release. So a
signature should only come from a fixed call whose template says what may
be signed (a commit object of klife, claims with this `aud`), never raw
bytes. Its card should show what is signed in a form you can read: for a
commit, its author, message and the files it changes.

## How open a fixed call is

A fixed call is as narrow as its template, for every value its schema
allows. Your main use is reusable host commands, which is exactly where a
template can quietly be open:
- `kubectl logs "$POD" -n web` is narrow;
- `kubectl $ARGS` is open use with extra steps.

The page must say which, so a fixed call never looks safer than it is.

**The check.** When a fixed call is saved or proposed, MWT reads its
template with its schema and grades it:

- **Narrow:** each value only picks among what the template names: one of
  a list, a number, a date.
- **Wide:** a value can reach anything of a kind: any repository your
  token reaches, any pod in a namespace, any file under the folder. The
  grade says which kind.
- **Open:** a value can become code or a command. In a host command, that
  is a parameter in:
  - `eval`, `bash -c`, `sh -c`, `python -c` or `node -e`;
  - `ssh HOST "$P"` or `kubectl exec … -- $P`;
  - `xargs` or `find -exec`;
  - the command's first word;
  - or anywhere it is read bare, where the shell splits and globs it.

  In a request, it is a parameter that is a query the service runs
  (GraphQL's `query`, SQL), or that is the whole body.

Separately, a template that runs a file (`./deploy.sh`) is only as narrow
as that file. The check can't read it, and the file can change after you
saved the call (see the next section).

The grade shows on the fixed call's page, on the proposal card, on each
card the call raises, and in `mwt grants` for agents.

**Its premise:** it reads text and guesses, so it can miss things. It only
warns: it never lets anything through, and it doesn't make a call ask
(Q8). A mistake costs a missed warning, never a hole. You keep the other
lever, the token itself: a grade of Wide on a fine-grained token that can
only read one repository is fine.

*Today:* `Param.hints` warns when a text parameter is read bare or inside
single quotes. Nothing grades a fixed call.

## What a command's card can't show

On host commands, all of the control comes before the command starts. So
the card has to flag what its text doesn't show.

*Today*, the card hints (`HostCommand.hints`) that a command:
- runs a script file;
- downloads code and runs it (`curl | sh`);
- uses `sudo`;
- mixes alphabets;
- runs `rm -rf`;
- is long;
- uses the workspace.

To add, as warnings rather than hints, on every host command, fixed or
written:

- **Runs a file the VM wrote** (anything under `from-vm`). The agent chose
  every byte of what runs, and the card shows none of it. This is the
  strongest warning: the card should show the file itself.
- **Runs a file the card doesn't show:** a script in your repository, or in
  `~/bin`. What runs is the file as it is at that moment, and an earlier
  command the agent wrote may have changed it.

  Pinned (Q10, decided): what you approve is the file as it was when
  you looked, not whatever it holds later.

**Pinning, step by step.**

1. **Which files.** MWT reads the command's text for the files it runs,
   with the same reader as the hints:
   - `./x` or `path/x` as the command;
   - `bash x`, `sh x`, `source x`, `. x`;
   - an interpreter and its file (`python x.py`, `node x.js`, `ruby`,
     `perl`).

   Each one is resolved in the folder the command runs in.
2. **On a card** (a command the agent wrote, or a fixed call that asks):
   - the card shows each file's content, up to a size, and keeps its
     hash;
   - just before the command runs, MWT hashes the file again;
   - if the file changed or is gone, nothing runs, and the agent and the
     log say why.
3. **On a fixed call:**
   - when you save or approve it, MWT keeps each file's hash and content;
   - each run checks them;
   - if a file changed, that run asks, even if the call runs without
     asking, and the card shows the diff;
   - approving pins the new content.

**What it doesn't cover, said on the card:**
- what the file runs in turn (another script, a Makefile target);
- files the command only reads;
- a change in the instant between MWT's check and the shell opening the
  file.

It catches what happens between your look and the run, minutes or weeks
apart, not a race designed against it.

## AWS: signing each request

**What it's for.** You use AWS from the VM the way you do on your
machine: `aws s3 cp`, terraform, an SDK in klife's code, all as your work
account's role. AWS keys never travel. The tool signs each request with
the secret key, and AWS checks the signature. Swapping a placeholder on
the way out can't work, because the tool computed the signature in the
VM from whatever key it had there. So MWT signs each request again on its
way out.

**How it works.**

1. **The credential** has several parts: an access key id, a secret key,
   and, for temporary credentials, a session token and an expiry. MWT
   gets them in one of two ways (Q11):
   - *pasted:* a long-lived access key;
   - *minted on your machine:* `aws configure export-credentials
     --profile work` prints temporary credentials for any profile your CLI
     can use, SSO or a role. MWT mints again when they expire. If your SSO
     session has ended, the mint fails, and MWT tells you to run
     `aws sso login` on your machine.
2. **In the VM.** `mwt exec AWS -- aws s3 ls` gives the command
   placeholders in AWS's own variables (`AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`), and the region in
   `AWS_REGION`. The placeholders never expire; MWT keeps the real
   credentials fresh behind them.
3. **The tool signs** each request as usual, with the placeholder secret.
   Its `Authorization` header names the placeholder key id, the date, the
   region and service, the headers it signed, and its signature. A
   presigned URL carries the same in its query.
4. **MWT decides** as for any carried credential. The placeholder key id
   is the credential's mark: an open grant over it has to list the host,
   and the Internet's grant has to let the request out.
5. **MWT checks that it read the request right.** It knows the placeholder
   secret, so it recomputes the tool's signature from the request as MWT
   will send it.
   - *Equal:* MWT reads the request exactly as the tool signed it.
   - *Different:* the request is refused before it leaves. MWT says it
     couldn't reproduce the signature, and the log says which part
     differed.

   A bug in how MWT reads requests shows up as a clear refusal, never as
   a `SignatureDoesNotMatch` from AWS that nobody can explain.
6. **MWT signs again.** It puts the real key id where the placeholder
   was and the real session token in its header, then signs the same
   request with the real secret. Nothing else changes: MWT signs exactly
   what the tool signed, and no more.
7. **The log** shows the request with its AWS operation
   (`s3 GetObject klife-artifacts/build.tar.gz`), labelled *signed by MWT
   as AWS (work)*.

A fixed call that uses AWS goes the same way. MWT builds the request and
signs it with the placeholder, as a tool would, and the pipeline signs it
again.

Any service that uses AWS's signature works the same way, with its own
hosts in the grant: Cloudflare R2, MinIO and other S3-compatible stores.

**Where the narrowing is.** As Q8 says, on the token: your role's IAM
policy is the lever. MWT's grant narrows the hosts: `*.amazonaws.com`,
or only `s3.us-east-1.amazonaws.com` and `sts.amazonaws.com`. Narrowing by
bucket or operation could come later, as attributes, the way GitHub
grants name repositories.

**Refused at first, each with a message saying so** (Q12):

- **Chunk-signed uploads**, where each piece of the body carries its own
  signature (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`). Over HTTPS the CLI and
  SDKs send S3 bodies unsigned by default, so these should be rare (to be
  confirmed with the CLI). They can be supported later: each chunk's
  signature has a fixed length, so MWT can replace them in the stream
  without changing the body's length.
- **Signed event streams** (Transcribe's streaming input) and **SigV4a**
  (multi-region access points).
- **Answers that hand out new credentials:**
  - `sts assume-role` and `get-session-token`;
  - SSO's role credentials;
  - ECR's `get-login-password`;
  - CodeArtifact's token.

  Their answer would put a new credential in the VM, which point 13
  forbids. At first MWT refuses these operations before they are sent; a
  role you need is minted on your machine instead, through its profile.
  Later, MWT can keep what they return as made values, behind
  placeholders, as it does for Google's JWTs. An operation MWT doesn't
  know of that hands out a credential is your IAM policy's to forbid. The
  scan of what comes into the VM still catches AWS key ids.
- **Tokens built from a signature in the VM:** `aws eks get-token`
  presigns a URL in the VM and gives it to kubectl as a bearer token.
  Since it is signed with the placeholder, the cluster refuses it. MWT
  could later sign inside the token too.
- **A presigned URL opened outside MWT:** one the agent gives you to open
  in your browser is signed with the placeholder, and fails.

**Scenarios.**

- **The usual case:** `mwt exec AWS -- aws s3 cp
  s3://klife-artifacts/build.tar.gz .` makes one GET. MWT checks it,
  signs it again, and logs it with its bucket and key.
- **Your SSO session ends mid-task:** the mint fails, and the agent's next
  request is refused with that reason. You run `aws sso login --profile
  work`, and the next request works with the same placeholders.
- **MWT reads a request differently from the SDK** (an S3 key with
  unusual characters, say): the request is refused before it leaves, the
  part that differed is in the log, and it is a bug to fix. It is not an
  AWS 403 nobody can explain.
- **The agent runs `aws sts assume-role`:** refused, saying the answer
  would hand the VM a new key.

## Scanning: every action, both ways

Every action that crosses MWT is scanned, whatever its channel or kind.

*Today:*

- **What the VM asks of MWT**, scanned for your real values; one holding
  them is refused and the firewall is told:
  - asks, proposals and calls, with their values;
  - commands the agent writes;
  - arguments to MWT's tools.
- **Requests leaving the VM**, scanned for:
  - your real values;
  - a placeholder going where its grant doesn't send it;
  - names shaped to carry data;
  - large uploads.
- **Commands the agent writes**, also checked against protected paths
  (`~/.ssh`, …).
- **Handoffs and workspace copies**, scanned for your real values.
- **What comes into the VM** (command output, request action answers,
  tool results, synced files), scanned for your real values and for
  credential shapes: private keys, JWTs, well-known token prefixes.

A fixed call is scanned at the ask (its values), and then as what it
builds: its request on the way out and its answer on the way in, through
the same checks as the agent's own. Every answer MWT reads is looked
through for all of your values, not only those put into its request; one
that holds any is cut, and the firewall told (QA of 2026-11-25). What MWT
doesn't read (a host set to "Don't read", a protocol other than HTTP
inside TLS it ended) passes unscanned, and a value split across
WebSocket frames isn't seen.

## Which grants an action needs (as decided)

| The agent does | Grants it needs |
|---|---|
| `curl https://example.com` | the Internet (open channel grant) |
| `mwt exec GitHub -- gh pr view 12` | the Internet (open channel grant), and GitHub (open credential grant) |
| `mwt exec GitHub -- gh api -X DELETE …` | the same: refused unless an open credential grant over GitHub is on, whatever fixed calls use GitHub's token |
| `mwt call gh-pr-view PR=12 …` | gh-pr-view, for GitHub's token in its request, and the Internet (open channel grant), as the agent's own request to api.github.com would |
| `psql -h db.office.lan` | the Office VPN (open channel grant covering db.office.lan) |
| `mwt call refunds-report DAY=…` | refunds-report, for host commands and Stripe's key (not Commands agents write: see "Where today's code still differs") |
| `mwt run -- 'kubectl get pods'` | Commands agents write (built in, always asks); never handed a value |
| `git fetch host-origin` | Git: fetch (built in, a fixed call over MWT) |
| `update_note` through `mwt mcp` | MWT: change (built in) |
| `mwt exec AWS -- aws s3 ls` | the Internet (open channel grant), and AWS (open credential grant listing the S3 host); MWT signs each request again |

Turning off the Internet's open grant stops the agent's own requests and
gh-pr-view alike: its request goes out as the agent's would. A grant over
just api.github.com lets both out again. Locking the Internet, or GitHub's
token, stops both. A grant whose requests no network grant lets out says
so on its page, as an error.

## What MWT sees, channel by channel

- **A network.** MWT sees every lookup and connection. On a host it reads,
  it also sees every request and its answer, decides each one as it goes,
  and cuts the connection if one of your values comes back. On a host set
  to "Don't read", it sees only the connection: host, port and bytes.
- **Host commands.** MWT sees the command (or the fixed call and its
  values), its folder, its output and its exit status. It doesn't see what
  the command does while it runs: the files it touches, or the connections
  it makes, which leave from your machine rather than through MWT. A
  confined command runs in a bubble, but it still shares your network.
  Your machine's own secrets (SSH keys, a kubeconfig, gpg-agent) are
  within its reach too, though they aren't MWT's credentials.
- **MWT.** MWT sees each tool call and its result. A change shows as a
  diff, and the version it replaced is kept.

## Decided

- **Fixed calls go through the same pipeline as the agent's own actions**
  (2026-11-25). MWT hands what it built to the channel's pipeline, inside
  its own process, marked with the fixed call it came from.

  *Not chosen:* MWT signs the built request and the VM sends it through
  the proxy. That would need each signature to be used once and expire
  soon, to cover the whole request with nothing added, and to work only
  on hosts MWT reads. A mistake in the check would let an altered request
  through unnoticed.
- **Q1. The channel is "Host commands".** "Your machine" was too wide:
  the VM itself needs your machine, so locking it said nothing clear.
  Locking host commands means nothing the agent asks runs on your
  machine, written or fixed. The VM, git, sync and the workspace go on,
  because they are MWT's.
- **Q2. MWT is a channel of its own.** It is the first app to expose
  one. Whether and how other apps on your machine expose channels comes
  later. MWT's own git fetch, sync, workspace and handoff move under it,
  because they run MWT's code, not text you or the agent wrote.
- **Q3. Commands the agent writes go under a built-in open grant over
  host commands.** It always asks, and no setting can make it run without
  asking: that is a rule of the channel. Fixed calls over host commands may
  run without asking. A channel rule covers "always ask for open use", so
  grants over several resources aren't needed for it.
- **Q4. Explicit.** A fixed call answers only `mwt call ID`. MWT never
  infers that an action could have been a fixed call. Agents are told to
  check `mwt grants` first. The card's *Saved as X*, shown when a command
  equals a saved one, stays a hint: it never runs anything without asking.
- **Q5. A fixed call covers its credential, and its request goes out as
  the agent's would; open use of a credential is a grant of its own.**
  - gh-pr-view covers GitHub's token in its own request, and nothing else.
    No fixed call ever lets its credential into an action the agent
    built.
  - Its request goes out through the network as the agent's own request
    to that host would: a network grant has to let it out, and if that
    grant asks, the call asks too (revised 2026-11-25: "as the agent
    would", literally). Not chosen: the fixed call covering its network
    too. That let one call through with the Internet's grant off, so the
    shared pipeline didn't mean the same permission; it saved bookkeeping
    (no network grant needed for a call), which is the reason to revisit
    it if that bookkeeping bites.
  - For the agent's own actions to carry a credential, an open credential
    grant has to say so, given on purpose. It may cover several
    credentials, and the action still needs an open channel grant to
    leave.
- **Q6. Labels.**
  - Each grant shows its resource and its kind (open use or fixed call).
  - A fixed call also shows what it builds: a request on the Internet, a
    host command, or a tool of MWT's.
  - A command or script shows where it runs.
  - "Runs on VM" and "Runs on host" as labels of a grant's kind go away.
- **Q7. Signing: each request, yes; something to publish, not now.**
  - AWS's signature on each request is designed in "AWS: signing each
    request".
  - Signing something to publish (a commit, a tag, a release file) waits
    for a view that shows you exactly what is signed, which is the hard
    part.
- **Q8. The grade only warns.** A fixed call graded Open is not made to
  ask. The control you keep is on the token itself (a fine-grained token)
  and in reading the grade before you let a call run without asking.
- **Q9. A credential's real value never reaches anything the agent
  wrote, on any channel** (point 13). This is not a rule of host commands
  but of every channel. A value handed to text the agent wrote is a value
  given to the agent.
- **Q10. The files a command runs are pinned** (see "Pinning, step by
  step"). Scenario: deploy-klife runs `./deploy.sh` without asking.
  - After you pull a change to `deploy.sh`, the next deploy asks once,
    showing the diff.
  - After a host command the agent wrote has changed it, the same
    happens, and you see it.

## Open questions

**Q11. Where an AWS credential comes from.** A pasted access key, minted
with `aws configure export-credentials`, or both.

*Suggestion:* both, with minting first in the form. A pasted key never
expires, while a minted one lasts about an hour and goes away when your
SSO session does.

**Q12. Where phase 1 ends.** Either:
- refuse the cases listed under "Refused at first", and build each when
  you hit it (the refusal says which it was);
- or build chunk-signed uploads, and made values for STS and ECR, from
  the start.

*Suggestion:* refuse first. Each of those is a separate piece of work,
and your use will show which one matters.

## Built (2026-11-25)

- **Q3:** Commands agents write is a built-in grant (`agent-commands`),
  on, always asking: no start setting, mode or allowance lets a run
  through unasked. Off, agents can't ask.
- **Q5:** a request action covers its credential in its own request,
  and its request needs the network grant the agent's own would
  (`Policy.reach/3`); a grant page says so when none lets its host out. A
  saved command covers host commands and the credentials it runs with.
  `machine` (*Allow your machine*) is gone. Locks and blocked hosts still
  refuse.
- **Decided, the shared pipeline:** a request action is built with a
  placeholder made for the call and sent through the proxy's own code
  over a loopback connection, marked with the call
  (`MWTClient.Sandbox.Egress.FixedCall`). Address checks, the firewall,
  the swap, the answer cut and the exchange are the VM's; its log line
  reads *Fixed call · NAME*.
- **Q1, Q2:** the resource is *Host commands*; git fetch, handoff, sync
  and the workspace are MWT's tools.
- **Q6:** every grant shows its kind; *Runs on host* only where a command
  runs there.
- **Q8:** the grade (`MWTClient.Sandbox.Openness`) shows on a fixed call's
  page, its cards and in `mwt grants`, as a warning.
- **Warnings and Q10:** a command's card says what it can't show louder
  than a hint (the file the VM wrote first), shows each file it runs, and
  pins them (`MWTClient.Sandbox.Pins`).

## Where today's code still differs

- **A saved command doesn't go "as the agent would".** Read literally,
  it would also need Commands agents write, the open grant over host
  commands; that grant always asks (Q3), so every saved command would
  ask, which Q3 says it mustn't. So a saved command needs only itself and
  host commands unlocked. Open: whether to keep that exception, or give
  host commands an open grant that only says whether the channel is open
  (the way the Internet's grant does for a network), apart from asking.

- A fixed request's network is asked about the call (`call pr-view`),
  not about the request MWT builds from it. An allowance you add on the
  call's card goes on the network grant that asked too, and lets the next
  call out; one made for the agent's own request to the same endpoint
  doesn't cover the call, which asks there. Stricter than the agent's,
  never looser (QA of 2026-11-25).
- A request action is still listed on its credential's page, where you
  made it: it covers its network too, but its home didn't move.
- MWT's own calls for a credential (Google's `signJwt` when the VM asks
  for a signed JWT, a GitHub App's token trade) still go out by MWT's own
  HTTP client: they are MWT making a credential, not an agent's action.
- A fixed request to a network with a way out of its own (an anchor,
  `wg0`) goes wherever this machine routes it, not through the anchor.
- A fixed request without a credential (a POST to a host on the VPN) has
  no form yet.
- Open credential grants cover one credential each: several in one grant
  is left for when something needs it.
- AWS (Q11, Q12) is designed, not built.
