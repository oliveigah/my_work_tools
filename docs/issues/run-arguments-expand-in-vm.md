# `mwt run` arguments are expanded in the VM first

- Found: 2026-11-23, MWT 0.3.0
- Kind: documentation, minor
- Status: fixed on 2026-11-24 (below)

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

## What was done

Worse than it looked: with several words, `mwt` escapes each one
(`printf %q`) before joining them, so even a quoted `'~/x'` among other
words reaches the user's shell as a literal `~/x`. Only a command sent as
one argument (or on stdin) reaches `bash -lc` as written.

- `mwt run` refuses, with exit 122 and before any card, a word that is the
  VM's home or starts with it (`/root`, `/root/…`, `--opt=/root/…`), and
  says to send the command as one argument in single quotes. One argument
  is never checked: a command that names `/root` on purpose (over ssh, say)
  goes that way.
- `mwt help run` and `mwt --help` say where `~`, `$VAR` and globs expand.
