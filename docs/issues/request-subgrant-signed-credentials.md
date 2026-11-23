# A request subgrant can't send a signed JWT or an ID token

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: open

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
