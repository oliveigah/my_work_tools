# G. Who asks

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- A handoff you send back with a note reaches the thread that holds the
  task, never another thread an ask named. One agent's `mwt-acp` can't
  take over another's thread or settle its messages.
- When you work at the VM's terminal with no agent, the card says it came
  from the VM's terminal with no agent found, not "an agent". It is
  decided the same way, under the same grants. This is the first piece of
  working in the VM by hand (H2).
- While the VM is isolated, the channel answers only what reads, and a
  request subgrant's call under way stops.

G gives H2 its person at the terminal, and L3 its part of the workspace
per task, bound to the right task.

## The one rule

Everything the VM says about who it is remains a claim: the VM is root,
and it can set `MWT_AGENT`, name any process, and claim any thread id.
MWT binds what it can see itself:

- which `mwt-acp` connection opened a thread;
- which thread took a slot.

What it can't see stays a label, worded as one. That includes "no agent
found": an agent can claim it to look like you. The card must not read
as more trustworthy for it.

## Where it sits

Round 5, slot 2. It needs A1 (`channel.ex`). H2 and L3 wait for it.

## Read

- The plan, workstream G.
- The review, under *Firewall, MWT's tools, forwarding, agent threads*:
  the thread a note is sent to, an attached `mwt-acp` taking over another's
  thread, the channel answering while isolated, a request subgrant's call
  not stopped, the catch-up note's length.
- `docs/todo.md`, "Working in the VM yourself, without an agent": *Who
  asks*, and *A person at the terminal is named as such*.
- `agent_sandbox.md`: *Agent channel*, *Agent threads* (*MWT's side*,
  *Limits*), *Worktree slots*, *Isolating*.
- Code: `identify` in `priv/sandbox/mwt-cli`, `Channel`, `AgentThreads`,
  `Handoffs`' send-back and catch-up notes, `Slots` (the
  `branch.NAME.mwt-thread` record), the isolation path in
  `server/host_runs.ex`.
- Tests: `agent_threads_test.exs`, `channel_test.exs`,
  `handoffs_slots_test.exs`, `server_firewall_test.exs`.

## G1: threads bound to their connection (M)

Task: `bind-threads-to-their-connection`.

- MWT records which `mwt-acp` connection opened each thread, and which
  thread took each slot, from what it saw rather than from the ask.
- A note on a sent-back handoff goes to the slot's holder as recorded,
  through that thread's connection. A thread id claimed by an ask isn't
  used to deliver anything.
- An `mwt-acp` can't attach to, or settle messages of, a thread another
  connection opened.
- With no agent found above `mwt`, the card says "from the VM's terminal,
  no agent found", and the same grants decide.
- While isolated, define which commands only read (`grants`, `why`,
  `project`, the list of `handoffs`, `ports`), answer those, and refuse
  the rest. A request subgrant's call under way stops.
- The catch-up note MWT writes is bounded.
- The document: *Agent threads* and *Agent channel* say what is bound and
  what is a claim. *Isolating* lists what still answers.

**Done when:** tests show a send-back delivered to the recorded holder
while an ask claims another thread, an attach refused for a thread another
connection opened, the terminal card's wording, and an acting command
refused while isolated.
