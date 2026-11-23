# `mwt run` arguments are expanded in the VM first

- Found: 2026-11-23, MWT 0.3.0
- Kind: documentation, minor
- Status: open

## What happens

`mwt run commands -- ~/.local/bin/tool --help`, typed in the VM's shell,
sends `/root/.local/bin/tool --help`: the VM's shell expands `~`, `$VAR`
and globs before `mwt` sees the arguments. On the user's machine it ran and
failed with `Permission denied`. Sent as one quoted argument,
`'~/.local/bin/tool --help'`, it ran as meant.

## Proposal

Say it in `mwt help run`: quote what the user's shell should expand, or
pass the whole command as one argument. `mwt` could also warn when an
argument starts with the VM's home, which never exists on the user's
machine.
