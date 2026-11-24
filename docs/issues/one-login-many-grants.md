# Grants built on the same login each mint their own copy

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: resolved by the grants redesign (2026-11-24), but for the ID token's own age

## What happens

To let some uses of one login through without asking while the rest still
ask, the only way is a grant per area (BigQuery, Cloud Storage, a service
behind Identity-Aware Proxy, a CLI's own service), each with the same mint.
Each keeps and mints its value apart (`Values.with_value/4`, keyed by
grant), so the same login is minted once per grant in use.

A grant's `keep_minutes` also holds for the access token and the ID token
together. A service that refuses ID tokens older than 5 minutes needs
`--keep-minutes 4`, which mints the access token again every 4 minutes for
every use of that grant, even uses that never send the ID token. One broad
grant that also served that service minted every 4 minutes for everything.

## Proposals

- A login, or mint, shared by several grants, each with its own hosts,
  carriers and approval: minted once, wielded under each grant's rules.
- An age limit for the ID token alone: mint again only when a request
  carries the ID token and the one kept is older.

## Resolution

Grants are now over a credential (`MWTClient.Sandbox.Credential`), which
holds where the value comes from and is minted once for every grant over
it; each grant keeps its own hosts, carriers, attributes and approval.
Grants saved before were merged into one credential where they were minted
the same way (same preset, mint command and keep time), keeping their
placeholders.
See [the redesign](../dated/20261124-grants_redesign.md).

Not done: an age limit for the ID token alone. Grants kept for different
times (`keep_minutes`) stay separate credentials, so that login is still
minted once for each: merging them would have every grant minted as often
as the one kept shortest.
