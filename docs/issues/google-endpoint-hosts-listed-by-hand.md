# Google's token and signing hosts must be listed on every grant

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: open

## What happens

A grant with a login file must list `oauth2.googleapis.com`, and one that
signs (`--sign-as`) must list `iamcredentials.googleapis.com`, or it is
refused (the `:present_login` and `:signs_as` checks in `Server.Grants`).
With several narrow Google grants, one per tool, each let through on its
own, both hosts repeat on almost every grant, and someone reading a grant
can't tell that they are plumbing rather than access.

## Why they are there

- `oauth2.googleapis.com`: MWT must read the refresh to answer it, and it
  always reads a token grant's hosts.
- `iamcredentials.googleapis.com`: for `signJwt`, MWT sends the grant's
  real value there itself, and a value goes only to hosts its grant lists.

What they add is small: the firewall refuses every credential endpoint
there but `signJwt` for the accounts the grant names, and a refresh never
leaves MWT.

## Proposal

Imply them: a login file implies the token endpoint, and `--sign-as` the
signing host, each shown on the grant's page for what it is ("Login
refreshes, answered by MWT", "Signs as …") rather than in the host list. Or
keep the checks, and fill the host in when the option is set.
