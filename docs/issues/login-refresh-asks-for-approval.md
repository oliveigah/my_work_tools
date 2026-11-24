# A login refresh MWT answers itself still asks for approval

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: resolved by the grants redesign (2026-11-24)

## What happens

A token grant with a login file (`--login-file`) gives the VM a Google
`authorized_user` file of placeholders. A client library refreshes it with
`POST oauth2.googleapis.com/token`; MWT finds the login's placeholder in
the body and answers the refresh itself (`Values.answer/4`), with the
grant's access-token placeholder and, when the mint printed one, an
ID-token placeholder. Nothing is sent to Google.

The request still goes through `Policy.decide/3` like any use of the grant
and ends in `allow_or_ask/3`: unless an allowance covers it, it waits on a
card. Every start of a tool, and for a grant kept a few minutes every few
minutes, shows one more card that decides nothing.

## Why the card protects nothing

- Nothing real leaves MWT, and the VM gets only placeholders. Every request
  that later carries them is checked as before: the grant's hosts, its
  carriers, the approval setting.
- The mint it may set off is bounded: MWT mints only once the kept value is
  older than the mint said or than `--keep-minutes`, and the VM chooses
  nothing of the command. Refreshing more often doesn't mint more often.
- What it discloses is small: the ID-token placeholder keeps the real
  `iss`, `aud`, `iat`, `exp`, `email` and `hd` claims.

## Proposal

Let a login refresh through without a card while its grant is on, logged
as today ("login refreshed · answered by MWT"), and refuse it while the
grant is off. Cards stay where a real value leaves: the API calls, and
`signJwt`, which makes a credential that acts as a service account.

## Workaround today

*Allow similar* on the first refresh card of each grant: the endpoint is
always `POST oauth2.googleapis.com/token`, so one allowance covers every
later refresh until the grant turns off.

## Resolution

A refresh MWT answers itself is no use of a grant: it goes without a
card while a grant over the credential is on, and is refused otherwise
(`MWTClient.Sandbox.Policy`, the `refresh?` branch).
