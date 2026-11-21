# Prompts for the sandbox work of 2026-11-21

One prompt per workstream of the
[work plan](../20261121-sandbox_work_plan.md). Each says what the
workstream makes possible once it has landed, what to read, and what each
of its steps does. They are written for an agent starting on a step and
for you deciding what to start next.

To start a step, open a thread in a free slot and give it the file and the
step:

> Do step C1 of `docs/dated/20261121-sandbox_work_prompts/C-one-way-out.md`.

## The order

Three slots at a time, which is about what your review can keep up with.
Each round is three steps that run at the same time: none needs another
in the same round, and none changes the same code as another.

| Round | Slot 1: the network path        | Slot 2: work in the VM                 | Slot 3: the rest                    |
| ----- | ------------------------------- | -------------------------------------- | ----------------------------------- |
| 1     | [A1](A-crash-is-a-clean-reset.md) a crash is a clean reset | [F1](F-pages-on-what-the-vm-wrote.md) CSP, no remote images | [M1](M-the-document.md) the threat model written down |
| 2     | [B1](B-git-on-the-vms-objects.md) git on the VM's objects | [E1](E-where-values-come-from.md) proposals, metadata server | [F2](F-pages-on-what-the-vm-wrote.md) Zed paths, hidden text |
| 3     | [C1](C-one-way-out.md) one way out | [H1](H-positions-and-levels.md) slot positions, words | [C4](C-one-way-out.md) DNS answers checked |
| 4     | [C2](C-one-way-out.md) requests read in full, stages | [I1](I-image-disks-bubble.md) Docker, disks from inside | [L1](L-shared-folders-and-workspace.md) bare repositories in shares |
| 5     | [C3](C-one-way-out.md) uploads counted where they go | [G1](G-who-asks.md) threads bound to their connection | [K1](K-host-commands.md) command parameters |
| 6     | [D1](D-reviewed-and-masked.md) network grants read HTTPS | [E2](E-where-values-come-from.md) mints with other grants | [J1](J-handoff-review.md) a handoff's flags |
| 7     | [D3](D-reviewed-and-masked.md) unmasking ids going out | [H2](H-positions-and-levels.md) working in the VM by hand | [L2](L-shared-folders-and-workspace.md) the workspace's threat model, with you |
| 8     | [D2](D-reviewed-and-masked.md) answers to you first | [E3](E-where-values-come-from.md) Google's credential endpoints | [B2](B-git-on-the-vms-objects.md) the review store |
| 9     | [D4](D-reviewed-and-masked.md) masking answers | [L3](L-shared-folders-and-workspace.md) the workspace | [F3](F-pages-on-what-the-vm-wrote.md) what the VM made, marked |

Fillers, for a slot with nothing to take: [I2](I-image-disks-bubble.md)
and [I3](I-image-disks-bubble.md) (the bubble on Ubuntu, bounded), and
[N1 to N3](N-diagram-groups-and-order.md) (diagrams), in that order. They
need nothing and nothing needs them.

How to use it:

- **A round isn't a gate.** When a slot's step lands, that slot takes its
  next step in its column, as soon as that step's needs (below) have
  landed. A slow step holds up only the steps that need it.
- **Needs cross slots.** E1, in slot 2, waits for A1 in slot 1; J1 waits
  for B1; L3 waits for steps of all three columns.
- **One slot:** take the rounds in order, left to right.
- **A fourth slot:** take the next step in the table whose needs have
  landed.

| Step | Needs landed first    | Shares code with, so rebase on whichever lands first |
| ---- | --------------------- | ------------------------------------------------------ |
| A1   | nothing               | E1, G1 (`server.ex`, `server/approvals.ex`, `channel.ex`) |
| B1   | nothing               | J1 (`handoff.ex`)                                      |
| B2   | B1                    |                                                        |
| C1   | nothing               | C2 (`egress/connection.ex`), K1 (`saved_request.ex`)   |
| C2   | C1                    | C3, D1, D3                                             |
| C3   | C1, C2                |                                                        |
| C4   | nothing               |                                                        |
| D1   | C1, C2                | D3, D2 (the stages)                                    |
| D2   | D1                    | E3 (the stages)                                        |
| D3   | C2                    | D1 (the stages)                                        |
| D4   | D2, D3                |                                                        |
| E1   | A1                    | H1 (`mwt-cli`)                                         |
| E2   | E1; C2 for its re-mint on a `401` |                                            |
| E3   | C2, E2                | D2 (the stages)                                        |
| F1   | nothing               |                                                        |
| F2   | nothing               | F3 (`mcp/tools.ex`)                                    |
| F3   | F1, F2                |                                                        |
| G1   | A1                    | J1 (`handoffs.ex`)                                     |
| H1   | nothing               | E1 (`mwt-cli`)                                         |
| H2   | G1, H1                |                                                        |
| I1   | nothing               | I3 (`bubble.ex`, if I1 confines the disk tools)        |
| I2   | nothing               |                                                        |
| I3   | nothing               | I1                                                     |
| J1   | B1                    | G1 (`handoffs.ex`)                                     |
| K1   | C1                    |                                                        |
| L1   | nothing               |                                                        |
| L2   | M1                    |                                                        |
| L3   | L2, F1, G1, J1        |                                                        |
| M1   | nothing               | every step adds to `agent_sandbox.md`                  |
| N1   | nothing               |                                                        |
| N2   | N1                    |                                                        |
| N3   | N2                    |                                                        |

Why this order is in the [plan](../20261121-sandbox_work_plan.md#the-order).

## For every step

- **One step, one task.** Take the slot with the task name the prompt
  gives, from `main` unless the user names another branch. Do that step
  only, and stop when it is ready for review; the next step is another
  task.
- **Check what has landed.** `git log origin/main` against the step's
  needs in [the order](#the-order): a step whose needs haven't landed
  waits, unless the user says to go on anyway.
- **Read before changing.** The sources each prompt lists: its part of the
  plan, the review's finding, the todo's section, the sections of
  [agent_sandbox.md](../../agent_sandbox.md) for the area. Line numbers
  were right at `bc46c80` and may have moved; find the code by its name.
- **Show the gap first.** A test that fails because of it (the review's
  appendix has probes for findings 1 and 2), then the change that makes it
  pass.
- **Keep the document true.** `agent_sandbox.md` describes the design as
  built. Change the sections of your area so they describe it after your
  change, add new guarantees at the end of *Guarantees to test* (tests
  cite them by number), reword the ones you changed in place, and name the
  test that keeps each. A limit you leave in place stays under *Not
  covered*. When the step closes a section of `docs/todo.md`, remove that
  section.
- **Stay in your area.** What you find that belongs to another workstream
  goes in the handoff's body, not into the change.
- **Tests as `AGENTS.md` says:** `async: true`, an identity per test,
  stand-ins through `MWTClient.StandIns`. Run the files you change while
  you work, and `mix precommit` once at the end. Tests tagged `vm` need
  `/dev/kvm`; where they can't run, say what is left to try on a real VM.
- **No new dependency** without asking the user.
- **The handoff's body** says what changed, how it was tested, what the
  user should check, and what is left for a later step.

## Decided on 2026-11-21

Every prompt takes these as given:

1. A crash of the sandbox server is a clean reset: every grant back at its
   start setting, an isolation kept. The defence is that nothing the VM
   sends causes one, and that the user is told when one happens.
2. The user reviews the VM's work in Zed. The threat model says Zed shows
   what the VM's server tells it; the Handoffs page stays small, with
   flags and warnings, not a review tool.
3. The remotes keep their names until the redesign: MWT's messages say
   which level they mean instead.
4. Every shared folder goes one way, from the user's machine into the VM.
   The workspace goes the other way only, from the VM onto the user's
   machine. Whether writing there is a grant of its own is for L2 to
   settle.
5. Proposed mint commands are allowed, shown as a script, and accepted
   only as the user read them.
6. Masked access to personal data is enough for now.
