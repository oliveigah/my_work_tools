# The workspace: moving files to and from the user's machine

`$MWT_WORKSPACE` (`mwt host` says where) is at the same path in the VM
and on the user's machine, and set in every command and subgrant that
runs there. It is an escape hatch for files that aren't a project's code,
not storage and not a working directory: work in `/work`, and use it only
to move a file across. Two halves, each written by one side only:

- **`$MWT_WORKSPACE/from-vm`, from you to the user's machine:** a file a
  command or subgrant there will read (a config entry a CLI uploads, an
  input), or a report the user asked for. Write it there, then run
  `mwt sync` before you ask for what reads it: only then is it copied
  there, read-only. Only files and folders go; no name starting with `.`
  or `-`, nothing executable, at most 1 GiB in all, and never a
  credential. One entry breaking a rule stops the whole copy, and
  `mwt sync` says which.
- **`$MWT_WORKSPACE/to-vm`, from the user's machine to you:** read-only
  here. Have a command or subgrant there write its result into it, then
  run `mwt sync` to read it here; a command run with `--dir` inside it is
  synced when it ends. A file holding something shaped like a credential
  is held back for the user.

Neither side follows an edit in place: to send back a changed file, copy
it into `from-vm`. Remove what you put in `from-vm` once it served; MWT
keeps nothing there for you.
