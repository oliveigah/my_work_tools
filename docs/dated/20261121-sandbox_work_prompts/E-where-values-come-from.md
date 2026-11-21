# E. Where values come from

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- A grant an agent proposes is accepted only as you read it. A proposal
  that changed between your reading and your click is refused. Today
  *Accept* sends only the grant's id.
- A proposed mint command is shown for what it is: a script that will run
  as you, on every mint, without asking, with the hints a command's card
  has. Decided: proposals may carry one.
- Google's Python clients work through a proposed grant. The metadata
  server can be turned on when editing any token grant, and proposed with
  the grant (`--metadata-project`, `--metadata-account`). Today you had to
  add the grant again from the Google preset.
- A token that comes from a login (a password or an API key exchanged at
  an auth endpoint) is minted by MWT from another grant kept in your
  vault. No password lives outside MWT, and you don't paste tokens again
  when they expire.
- Tools that mint Google credentials themselves run in the VM as they
  are, with no real value entering it:
  - IAP clients that call `signJwt`;
  - CLIs that send the user's ID token from a refresh.

## Where it sits

- E1: round 2, slot 2. It needs A1, which changes the same files. A
  proposal must be bound to what you read before it can carry more.
- E2: round 6, slot 2. It needs E1; its re-mint on a `401` needs C2.
- E3: round 8, slot 2. It needs C2 (it is a stage that answers requests
  itself) and E2 (expiry read from the mint's answer, for a 5-minute ID
  token).

## Read

- The plan, workstream E.
- The review: *Proposed grants* among the smaller gaps; the lead that a
  proposal doesn't count toward the activation asks.
- `docs/todo.md`: "The metadata server on grants not added from the
  Google preset", "Mints that take another grant's value", "Tools that
  mint Google credentials themselves".
- `agent_sandbox.md`:
  - under *Grants*: *Grant kinds*, *Who uses its value*, *Where real
    values come from*, *Presentations*, *Presets*, *Setting up each kind
    of credential*, *Proposed grants*;
  - *Confined commands*;
  - the credential endpoints under *Firewall*'s *Rules*.
- Code:
  - `Proposal` (`attrs/3`, `preset_fields/1`), `Server.Grants`
    (`save_proposed/3`, the builder's `present_*` fields), proposal
    acceptance in `server.ex`;
  - `Presets.type_or_preset/1`, the metadata box in
    `sandbox_live/grants.ex`, `priv/sandbox/presets/google.json`;
  - `Server.Values` (`with_value/4`, `minted/1`), `Confine`, the `@mints`
    list in `firewall.ex`, `propose` in `priv/sandbox/mwt-cli`.
- Tests: `proposal_test.exs`, `presets_files_test.exs`,
  `secrets_test.exs`, `server_test.exs`, the grants page's LiveView tests.

## E1: proposals bound to what you read, the metadata server anywhere (S/M)

Task: `bind-proposals-and-metadata-server`.

- The proposal's page holds a digest of what it shows. *Accept* sends it,
  and saving refuses a proposal that changed since. Changing it means
  proposing again under the same `--name`.
- A proposed mint is shown as a script: the hints a command's card has
  (hidden characters, a long script), and the line that it runs as you,
  unconfined, on every mint, without asking.
- A proposal counts toward the activation asks.
- The metadata server's box shows when editing any token grant, not only
  when adding from the Google preset.
- `mwt propose token` takes `--metadata-project` and
  `--metadata-account`, shown on the proposal's page with the rest.
- The document: *Proposed grants*, *Presentations*, guarantee 9 reworded
  for proposed scripts and mints. Remove the todo's metadata server
  section.

**Done when:** tests show a proposal changed after it was shown refused at
*Accept*, a proposed grant with the metadata server serving it, and the
box on an edited grant.

## E2: a mint that takes other grants' values (M)

Task: `mint-with-other-grants`. After E1.

- A mint names the grants whose values it takes (`with`, as a command
  subgrant has). Their values go in its environment, never its arguments.
- A reach of *mints only*. Such a grant never reaches the VM. Its page
  says what uses it ("Used by the mint of: Y"), and the other grant's page
  says "Mints with: X".
- Values are fetched first, a stored or a minted one. A chain is allowed;
  a cycle is refused when the grant is saved. A value that can't be
  fetched fails the mint, and the agent hears which grant failed.
- A mint that takes values runs confined. One that takes none runs as
  you, as now, for your logins.
- Expiry read from the mint's answer (`expires_in`, a JWT's `exp`).
- One more mint on a `401` from the grant's host, as a stage, if C2 has
  landed; otherwise it goes to E3.
- Proposals can carry `with`, shown on the page, under E1's digest.
- Remove the todo's section.

## E3: MWT answering Google's credential endpoints (L)

Task: `answer-google-credential-endpoints`. After C2 and E2.

1. **`signJwt` first.** It ships on its own: with the metadata server MWT
   has, it is enough for IAP clients.
   - MWT answers it for an account the grant names, with an `aud` among
     the grant's hosts.
   - The answer is a placeholder JWT with the claims the VM sent.
   - On the way out to that host, the placeholder becomes a JWT signed on
     this machine for the same claims (`gcloud iam service-accounts
     sign-jwt`), kept until it expires.
2. **A login file, then the token endpoint.**
   - An `authorized_user` login file as a presentation:
     `GOOGLE_APPLICATION_CREDENTIALS` under `mwt exec`, holding the client
     id and placeholders.
   - The token endpoint answered by MWT for that refresh token, never
     forwarded. It mints here (`gcloud config config-helper
     --force-auth-refresh`) and answers with a placeholder access token
     and a placeholder ID token.
   - Placeholders shaped like a JWT: the real token's harmless claims
     under a header, with a signature that is a placeholder.
   - The real ID token goes only in the grant's carrier header, to its
     hosts, minted again within its 5 minutes.

`:credential_mint` and `:credential_inbound` stay as they are. MWT's own
answers are not the service's, and must not count as either.

**Done when:** stand-in tests cover both kinds of tool end to end. The
handoff says what is left to try against Google itself, with your IAP
service and the CLI that needs the ID token. Remove the todo's section.
