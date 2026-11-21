# K. Host commands and subgrants

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- A parameter's value can't change how the tools in your script run. So a
  subgrant you trusted to run without asking does only what its script
  says. Today a parameter may be named `PYTHONPATH`, `NODE_OPTIONS`,
  `HTTPS_PROXY` or `KUBECONFIG`, and each of those changes what a tool
  loads or where it connects.
- A request subgrant's path can't climb out with `..`, and the whole
  request has one time limit.
- Output is looked through for credentials whole, before it is cut.
- Confined commands:
  - your home is compared by its real path;
  - the bubble has a seccomp filter;
  - a value is held back while its grant's condition holds the grant off.
- Running auto-approved calls are capped.
- The long-script hint counts every line.

With K, guarantee 9 holds for subgrants you trust to run without asking,
not only for the ones you approve each time.

## Where it sits

Round 5, slot 3. It needs C1, which sends a request subgrant's requests
through the one way out, in `saved_request.ex`.

## Read

- The plan, workstream K.
- The review:
  - the leads under *Host commands and the agent channel*;
  - *Confined commands* among the smaller gaps.
- `agent_sandbox.md`:
  - all of *Host commands*;
  - under *Grants and subgrants*: *Parameters*, *Calling one*, *Request
    subgrants*;
  - guarantee 9.
- Code: `Param`, `SavedRequest`, `HostCommand` (the hints), `HostRun`,
  `Confine`, `Server.HostRuns`, `sandbox_live/approvals.ex` (the command's
  card).
- Tests: `param_test.exs`, `saved_request_test.exs`,
  `saved_request_stream_test.exs`, `host_command_test.exs`,
  `host_run_test.exs`, `confine_test.exs`, `policy_test.exs`,
  `guarantees_test.exs`.

## K1: parameters that only carry values (M)

Task: `tighten-command-parameters`.

- **Parameter names.** Refuse whole families, not single names:
  - `LD_*`, `GIT_*`, `*_PROXY` in any case;
  - `PYTHON*`, `NODE_*`, `PERL*`, `RUBY*`, `KUBECONFIG`, `BASH_*`, and
    the like.

  Write the rule so a name nobody thought of is more likely refused than
  passed.

  A saved subgrant that a new rule refuses is shown as needing your edit,
  never changed silently and never run.
- **Values.** A `word` that starts with `@` or `file:` is read as a file
  by some tools. Refuse it, or flag it on the card, and say which in
  *Parameters*.
- **Request subgrants.**
  - A `text` value `..` (or one that becomes a path segment of `..`) is
    refused in a path.
  - The whole request gets one time limit, not a limit per chunk.
- **Confined commands.**
  - The folder is compared with your home by its real path.
  - The bubble gets the seccomp filter the VM's bubble has.
  - A value isn't given while its grant's condition holds the grant off.

  That a confined command shares this machine's network stays as it is,
  said in *Confined commands*: the script is yours.
- **Output and caps.**
  - Output is looked through for credentials before it is cut to its
    first and last 32 KiB.
  - Auto-approved calls that are running are capped, as waiting ones are.
- **The long-script hint** counts every line, blank ones included.
- The document: *Parameters*, *Request subgrants*, *Confined commands*,
  *Running*; guarantee 9 reworded if what it promises changed.

**Done when:** each item has a test, and a saved subgrant the new name
rule refuses shows as needing your edit.
