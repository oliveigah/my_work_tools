# "Only that command gets it" reads as secrecy

- Found: 2026-11-23, MWT 0.3.0
- Kind: documentation
- Status: open

## What happens

`mwt grants` says of each token grant: "Only that command and its children
get $GH_TOKEN, …, /mnt/mwt/tokens/<grant>". `mwt exec` only sources
`/mnt/mwt/grant-env/<grant>.sh` and runs the command, and the files it
points to (`/mnt/mwt/tokens/*`, `/mnt/mwt/logins/*.json`) are mode 0644:
any process in the VM can read them, with or without `mwt exec`.

That is safe by design: a placeholder is worth something only through MWT,
toward the grant's hosts, while the grant is on and its use allowed. But
the wording suggests that the files are what keeps it safe.

## Proposal

Say what `mwt exec` decides, which credentials a command starts with, and
where the protection is: placeholders are worthless outside MWT, and MWT
checks every request that carries one.
