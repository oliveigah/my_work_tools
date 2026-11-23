# "Allow similar" can't cover a REST resource with ids

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement
- Status: open

## What happens

An allowance covers every use of a grant, or the uses with the same method,
host and path as one approved: the pattern is `METHOD host/route`, the
query dropped (`Describe`, REST requests). A REST API whose paths carry ids
(`/versions/<id>`, `/drafts/<id>`) asks again for each id. So one tool's
calls on a host can't be trusted without trusting the whole grant; the way
around was a separate grant per tool, let through without asking (see
[one-login-many-grants](one-login-many-grants.md)).

## Proposal

Allowances by route template or prefix (`GET host/api/*/versions/*`), or by
method on a host (every `GET` and `HEAD`), chosen on the card.
