# No preset for a GitHub App installation token

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: resolved by the grants redesign (2026-11-24)

## What happens

A GitHub App's installation token (`ghs_…`, an hour) is the narrowest
GitHub credential that belongs to no person, and it can be narrowed further
as it is minted (`permissions`, `repositories`). MWT has no preset for it:
the `github` preset is a stored fine-grained token (prefix `ghp_`), a stored
grant can't be changed into a minted one, and the mint (sign a JWT with the
App's key, exchange it for an installation token) is a script the user
writes and keeps.

Finding the installation id is a step of its own: it shows only in the URL
of the App's Configure page, or in `GET /app/installations` with an App
JWT.

## Proposal

A `github-app` preset: the App's client id, the installation id, a command
that prints the private key, the permissions to narrow to; prefix `ghs_`;
the mint built in, printing `{"value", "expires_in"}`.

## Resolution

The `github-app` preset asks for the App's id, the installation's id and
a command that prints the App's private key. MWT signs a JWT as the App
with it and trades it for an installation token, kept until a minute
before it expires (`MWTClient.Sandbox.Adapter.GitHub.exchange/3`). The key
never leaves your machine. Not done: narrowing the token further as it is
minted (`permissions`, `repositories`).
