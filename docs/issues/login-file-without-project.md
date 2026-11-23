# A login file names no project

- Found: 2026-11-23, MWT 0.3.0
- Kind: improvement, minor
- Status: open

## What happens

A grant's login file (`GOOGLE_APPLICATION_CREDENTIALS` under `mwt exec`)
holds no project, and nothing in the grant's environment names one. So:

- google-auth warns `No project ID could be determined` at every start;
- gcsfs with `token="google_default"` refuses a `project=` argument ("does
  not match the google default project 'None'"), and works without one;
- a client that needs a default project needs it passed every time.

## Proposal

An optional project on the grant, exported as `GOOGLE_CLOUD_PROJECT` under
`mwt exec`. Not as `quota_project_id` in the login file: google-auth would
send it as `x-goog-user-project` on every call, which changes who is billed
and can need `serviceusage.services.use`.
