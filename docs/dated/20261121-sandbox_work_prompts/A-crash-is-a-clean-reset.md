# A. A crash is a clean reset

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- An agent can propose a command subgrant from any folder, a shared one
  included, and the proposal waits for you as it should. Today
  `mwt propose commands --dir` inside a shared folder crashes the sandbox
  server, and the agent hears "MWT is locked".
- No channel command the VM can send crashes the sandbox server, and a
  test sends every one with hostile fields to keep it that way.
- When the server does restart after an error elsewhere, you are told,
  and so are the agents whose asks were lost.

Why it matters more than a crash usually does: a restart puts every grant
in its start setting (decided: a crash is a clean reset). A crash the VM
can cause is a way to turn the Internet back on after you turned it off.
The defence is that the VM can't cause one, and that you see it when one
happens.

## Where it sits

Round 1, slot 1. It needs nothing. E1 and G1 change the same files
(`server.ex`, `server/approvals.ex`, `channel.ex`) and wait for it.

## Read

- The plan, workstream A.
- The review, finding 1, and its appendix probe *Finding 1: the crash and
  the grant states*.
- `docs/todo.md`, "Proposing a command subgrant with a folder in a share
  crashes the server".
- `agent_sandbox.md`: *When MWT starts*, *Agent channel*, *Desktop
  notifications*, guarantee 16.
- Code: `Server.Approvals.place/3`, `HostCommand.place/3` and its
  `@spec`, `Channel.serve_ask/3`, `Server.init/1` and `terminate/2`,
  `Server.Grants.start/1`, `Gate.forget/1`, `MWTClient.Sandbox.Notices`.
- Tests: `server_crash_test.exs`, `channel_test.exs`,
  `channel_bounds_test.exs`, `host_command_channel_test.exs`.

## A1: the crash, the message, and the restart said (S/M)

Task: `fix-propose-dir-crash`.

1. The review's probe as a test that fails now: a proposal with `--dir`
   in a shared folder, after grants were turned off. It should end with
   the server alive and the proposal saved, with that folder.
2. `place/3` takes both answers of `HostCommand.place/3`
   (`{:share, dir, _share}` and `{:home, dir}`).
3. `serve_ask/3` says "MWT is locked" only when the identity's store is
   locked. Any other exit answers that MWT failed to answer this ask and
   nothing changed, and logs why. Log the reason's kind and message, not
   the state it carried: a crash's reason can hold a minted value.
4. A test that sends every command the channel answers, with fields
   missing, of the wrong type, huge, nested, or holding control
   characters, and checks that each gets an error and that the server is
   the same process afterwards. Build the list of commands from the
   channel's own, so a command added later fails the test until it is
   covered. Fix every crash it finds; note in the handoff anything else it
   shows.
5. A restart after a crash stays a start: `Grants.start/1` runs as it
   does now. But it is told apart: `terminate/2` forgets Gate's view only
   on a deliberate stop, so a view found at init means a restart after a
   crash. Then:
   - you get a notification that the sandbox restarted after an error and
     that grants are back at their start settings;
   - an ask that was waiting when it crashed is answered that MWT
     restarted and to ask again, where the channel's own process is still
     there to answer it.
6. The document:
   - guarantee 16 names the new test;
   - a new guarantee at the end: *a restart of the sandbox, after a crash
     as after an unlock, puts every grant in its start setting, keeps an
     isolation, and tells you*;
   - *When MWT starts* says that a restart after a crash is a start;
   - remove the todo's section on this crash.

**Done when:** the probe passes as a test, the hostile-fields test passes
with the server's process unchanged, a restart after a crash raises the
notification, and `mix precommit` passes.

**Not in this step:** keeping grants as they were across a crash (decided
against), and what other workstreams own that the hostile-fields test
happens to touch, beyond fixing crashes.
