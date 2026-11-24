# A request subgrant can't send a signed JWT or an ID token

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: resolved (2026-11-24): request actions take `{id_token}` and `{signed_jwt}`

## What happens

A request subgrant's headers are fixed, with `{token}` standing for the
grant's real value (`SavedRequest`). A service behind Identity-Aware Proxy
that takes a JWT signed as a service account in `Authorization`, and the
caller's ID token in a header of its own, can't be called that way: neither
value is the grant's own. So a trusted, fixed call to such a service can't
be a subgrant: it needs a grant of its own, let through without asking.

## Proposal

Let a request subgrant of a grant that signs, or has a login, name those
values in its headers: `{signed_jwt}`, signed as one of the grant's
accounts with the request's own URL as `aud`, and `{id_token}`.

## Resolution

Request subgrants are now called actions, and a request action's headers
may name the values the credential's adapter makes beside `{token}`
(`MWTClient.Sandbox.SavedRequest`):

- `{id_token}`, the ID token the Google login's mint prints, for a grant
  over a Google credential;
- `{signed_jwt}`, a JWT signed as the grant's one account, or
  `{signed_jwt:ACCOUNT}` naming one of several (`Grant.signs_as`), by IAM
  Credentials' `signJwt` with the credential's access token, its `aud`
  the call's URL without the query, good for an hour
  (`MWTClient.Sandbox.Adapter.Google.sign_jwt/4`).

The form checks that the grant can make each one it names. MWT signs off
its server's process as it sends the call, and writes each value out of
the answer, as it does the token.
