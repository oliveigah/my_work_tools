# F. MWT's pages, on what the VM wrote

Read [README.md](README.md) first: it holds what every step shares and the
decisions of 2026-11-21.

## What it makes possible

- Opening a note, a flash card or a handoff the VM wrote can't make your
  machine fetch anything. Today a flash card from the VM, auto-approved
  through `mwt-create`, can hold an image whose address is your loopback,
  your LAN or a VPN host. Your webview fetches it when you open the page,
  and the address can carry data out past the proxy and the firewall, with
  the Internet off or the VM isolated.
- A Content-Security-Policy on every page and in the desktop shell catches
  what a missed check would let through.
- *Open in Zed* opens the VM's worktree, never another host the VM
  printed into the path.
- Text the VM chose can't hide characters from you on a card or a page,
  process names included.
- With every MWT grant off, the VM can't read items through an update
  that changes nothing.
- Items the VM made say so, to you and to agents on your machine reading
  through `/mcp`. An HTTP sample the VM saved is marked, and Send warns
  you before it reaches loopback, a private address or a metadata
  address.

With F, the attack-surface table can list MWT's pages as hardened, and a
new guarantee holds: *MWT's pages load nothing from an address the VM
chose*.

## Where it sits

- F1: round 1, slot 2. It needs nothing. It goes first: it is the finding
  an agent can use most easily.
- F2: round 2, slot 3. It needs nothing.
- F3: round 9, slot 3. It needs F1 and F2, which change the same pages and
  `mcp/tools.ex`.

## Read

- The plan, workstream F.
- The review:
  - finding 5 and its appendix probe for the renderer;
  - among the smaller gaps: *Open in Zed*, *MWT's tools*, *Text that
    hides*, *Port forwarding*;
  - the leads on process names, HTTP samples from the VM, who made an
    item, and `mwt-create`'s limit.
- `agent_sandbox.md`: *Text the VM chooses*, *MWT's tools for agents in
  the VM*, *Servers in the VM, on your machine*, *Pages*, guarantee 2.
- Code:
  - pages: the router's `:browser` pipeline, `MWTClient.Markdown`,
    `MWTClientWeb.MarkdownComponents`, the root layout,
    `src-tauri/tauri.conf.json`;
  - Zed and text: `Zed`, `Slots`, `sandbox_live/projects.ex`, `Shown`,
    `monitor/sample.ex`, `Firewall`'s incident text, `Ports`;
  - MWT's tools: `MCP.Tools`, `MCP.Catalogue`, and the notes, diagrams
    and flash cards storage (`docs/storage.md`).
- Tests: `hostile_text_test.exs`, `mwt_tools_test.exs`, the notes and
  flash cards LiveView tests, `forwarding_test.exs`.

## F1: a Content-Security-Policy, and no remote images (S)

Task: `add-csp-and-drop-remote-images`.

- A policy on every page:
  - `default-src 'self'`, `img-src 'self' data:`, `script-src 'self'`,
    `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'self'`;
  - `connect-src` with what LiveView's socket needs. Check it in the
    desktop shell: WebKitGTK may not count `ws:` as `'self'`.
- The desktop shell sets the same, instead of `"csp": null`.
- Find what the policy breaks: colocated hooks, `style` attributes in
  templates (there are some), the diagram editor, the theme script, the
  update check. Fix each, or allow it narrowly and say why.
- In Markdown, an image whose address isn't `data:` becomes a link
  showing its address. A relative one too: `img-src 'self'` would let it
  make a GET to MWT's own routes with your cookie.
- The document: *Text the VM chooses* and *Pages*, the new guarantee, and
  the remote-images limit removed from *Not covered* if M1 added it.

**Done when:**

- a test shows Markdown with remote and relative images rendering no
  `<img>` but `data:`;
- a test shows every browser response carrying the policy;
- you checked the pages and the desktop shell with the run-mwt skill and
  found nothing broken;
- the handoff lists what you checked.

## F2: the small checks (S)

Task: `check-zed-paths-and-hidden-text`.

- Zed's address takes only an absolute path under `/work`, of plain
  characters. Anything else is refused, and the row says so.
- An `update_*` call that changes nothing goes through the read grant, and
  counts as a read.
- `Shown` covers variation selectors, combining marks, the Unicode spaces
  and blank letters such as U+3164.
- Process names on the monitor's page and the firewall's incident text go
  through `Shown`.
- A forward connects, inside the VM, only to a loopback address or the
  VM's own.

## F3: what the VM made, marked (M)

Task: `mark-what-the-vm-made`. After F1.

- Each note, diagram and flash card records who made it: you, the VM, or
  an agent on your machine. Its page shows it, and MWT's tools return it.
  It is a storage change: follow `docs/storage.md`.
- An HTTP sample the VM saved is marked until you open it. Send says when
  its address is loopback, a private address or a metadata address.
- `mwt-create`'s hourly limit counts items, not calls.
- The document: *MWT's tools for agents in the VM*, and the threat model's
  entry on items the VM writes that agents here read.
