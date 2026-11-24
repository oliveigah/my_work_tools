# Running a command you write on the user's machine

Read this before you ask to run one.

The last resort, for what no action and no grant can do: a job that
needs the user's SSH keys, a kubeconfig, a signing key, their VPN, or tools
only their machine has. Use a grant whenever one fits: through it the
user sees what each request does, while a command shows only its text.

It needs no grant: you may always ask. You write the text, as below, and
the user reads and approves every run, on a card; none runs unattended.
While the user's machine is locked, an ask is refused at once.

So keep the command the smallest that gets what you need:

- Run on their machine only what must run there: the step that needs their
  keys, VPN or tools. Fetch, then stop.
- Bring the raw output back and do the rest here in the VM: filter, parse,
  sort, transform, summarise. No `jq`, `awk`, `sed` chains, loops or
  here-documents of logic on their machine.
- One command, read in a few seconds: `kubectl get pods -n web -o json`,
  not a script that loops over pods and greps their logs. Several small
  runs beat one long one.
- The user can decline it with "ask for a simpler one". Then send the
  smallest command that gets the raw data.

1. Run `mwt host` (or read `/mnt/mwt/host.md`) first: OS, architecture,
   shell, shared folders and tools there. Don't probe the machine with
   commands to find out.
2. Ask: `mwt run --reason "what it does, and why it must run there" -- COMMAND ARGS`,
   or pass a script on stdin (`mwt run --reason "..." <<'EOF' ... EOF`).
   Options go before the `--`. The user approves the exact text, once,
   and it runs as them with `bash -lc`. Your shell here expands `~`,
   `$VAR` and globs before `mwt` sees them, and several words are sent
   quoted: for their shell to expand one, send the whole command as one
   argument in single quotes (`-- 'ls ~/x'`). A word in this VM's home is
   refused.
3. Where it runs: `--dir`, by default your current directory. Shared folders
   are at the same path there: the command sees the user's own files, and
   once it ends, MWT syncs that folder's copy, so what it wrote there
   reaches yours; `mwt sync PATH` waits for that. Anything else runs in the
   user's home folder.
4. Prefer text the user can read to a script file: `mwt run -- ./x.sh` runs
   whatever the file holds when they click, and the card says so.
5. When you expect to run the same again, don't run it ad hoc: propose it
   as a saved command (`mwt help propose`), then call it. The user can also
   save a run as an action from its card; `mwt run` then says its id:
   call that one next time.
6. `--timeout` is the time limit in seconds (120 by default, 3600 at most).
   `mwt` waits up to `--wait` seconds (60) for it to be approved and run;
   if it says it is still waiting, keep working on what doesn't need it and
   run `mwt wait RUN_ID` later.

`mwt run` and `mwt call` exit with the command's own status once it ran and
its output came back (124 if it hit the time limit). Otherwise, with a line
on stderr: 120 still waiting, 121 it didn't run or the user kept its
output, 122 the ask was wrong, 123 MWT isn't answering. The user may choose
to see the output before you get it, or keep it. Don't ask again for
something they declined unless they say so.
