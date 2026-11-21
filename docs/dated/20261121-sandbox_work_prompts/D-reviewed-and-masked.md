# D. Requests reviewed, personal data masked

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- On a service behind your VPN, often production, every HTTPS request
  the agent makes gets a card with the whole request, as a token grant's
  does, with *Allow similar* for repeats. Today the only card says
  "Connect to 10.x.y.z:443" and nothing of what goes through.
- The connection card names the host asked for, not only the address and
  the wildcard it matched.
- An answer can come to you first, decoded, for you to release or keep
  from the agent.
- You can hand an agent a person without the person's id entering the VM:
  "person `mwt:cpf:Xb3k…` fails on this API: check it". MWT puts the real
  id back only on the way to that data's hosts.
- Answers come back masked. An id becomes the same token every time, a
  field outside a host's allowlist becomes its type, and an answer MWT
  can't decode is held rather than passed. Masked access is enough for
  now (decided).

With D, an agent can work on production services holding personal data,
with you seeing what it does there.

## Where it sits

- D1: round 6, slot 1. It needs C1 (MWT connecting to private addresses
  through a grant's way out) and C2 (framing, and the stages D adds to).
- D3: round 7, slot 1. It needs C2. It may run while D1 is still open:
  both add stages, so rebase on whichever lands first.
- D2: round 8, slot 1. It needs D1.
- D4: round 9, slot 1. It needs D2 and D3.

## Read

- The plan, workstreams C and D.
- `docs/todo.md`: "Every request through a network grant, read and
  reviewed", and "Masking personal data", its order both ways included.
- `agent_sandbox.md`: *Private networks*, *Each intercepted request*,
  *What comes back*, *What the log keeps of a request*, *Approvals*,
  *Ask each time or auto-approve*, *Grant kinds*.
- Code: `Gate` (the `:intercept` route, `authorize/2`, the `:tunnel`
  outcome logged for requests MWT read), `Policy.decide/3`, `Exchange`,
  `Egress.Response`, `Egress.Scanner`, the review of command output
  (`output_to: :review` in `server/host_runs.ex`), the stages C2 added.
- Tests: `egress_test.exs`, `egress_response_test.exs`,
  `exchange_test.exs`, `gate_test.exs`, `policy_test.exs`,
  `server_test.exs`.

## D1: network grants read HTTPS (L)

Task: `read-network-grant-requests`.

- Each destination of a network grant has a mode: read requests, or
  connect only. Propose to the user which a new destination and an
  existing grant start with. Breaking a client that worked yesterday is a
  cost too.
- A destination in read mode is intercepted with MWT's certificate, which
  the VM trusts already. Each request gets a card like a token grant's,
  through the stages.
- The connection card is decided after the ClientHello. It shows the name
  asked for and the name MWT answered in DNS, and the entry it matched.
- A request MWT read is logged as `:read`, not `:tunnel`. That covers the
  requests to token hosts with no placeholder, which say "tunnel" today.
- What MWT can't read stays connect only, and the grant's page says so per
  destination: a database, SSH, pinned certificates, mutual TLS, HTTP/2.
- The document: *Private networks* and the grant's page; the todo's
  section goes when D2 is in too.

**Done when:** tests show a request on a read destination carded in full
and *Allow similar* covering its repeats, a connect-only destination
tunnelled as before, and `:read` in the log.

## D2: the answer to you first (M)

Task: `review-answers-first`. After D1.

- An answer held until you release it, shown decoded: status, headers, and
  the body up to a cap.
- You release it, or keep it from the agent, as a command's output can be
  kept.
- Auto-approve releases both halves. A held answer has a time limit, after
  which the agent gets a clear refusal.
- Remove the todo's network grant section.

## D3: unmasking what goes out (M/L)

Task: `unmask-ids-going-out`. After C2, beside D1.

- Tokens with a typed prefix (`mwt:cpf:…`), the same token for the same
  value, kept in the identity's vault. Don't use tokens shaped like real
  ids: they can be taken for one. Choose how tokens are made without a
  new dependency, or ask.
- A page where you make a token from a value, and read a pasted text with
  every token in it decrypted, to you only.
- Which grant the data belongs to, and so which hosts may get the real
  value. Propose how a grant says it (a kind, or a property of token and
  network grants).
- An unmask stage before the review stage. Your card shows the real id,
  since you may read it. A token going to any other host is refused, as a
  placeholder going where its grant doesn't is, with a reason of its own.
- What comes back, until D4: the real ids put into a request count as
  real values for its answer, so a body holding one is cut, as
  `Egress.Response` does for credentials.

## D4: masking answers (L)

Task: `mask-answers`. After D2 and D3.

- Patterns validated by their check digits (a CPF with and without
  punctuation), emails and phones.
- Fields by an allowlist per host: only the listed fields pass, the rest
  become `<string>`, `<number>` or `<date>`.
- An answer MWT can't decode is held, for a host whose grant masks.
- A value split across reads is still caught, as `Egress.Scanner` does.
- The order back is review, then mask, then the check for real values.
- The exchange log keeps answers masked, as the VM saw them.
- Remove the todo's masking section. The document says that pseudonymous
  data isn't anonymous.
