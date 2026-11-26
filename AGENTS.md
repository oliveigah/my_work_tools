This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- `.tool-versions` pins the Erlang and Elixir the project builds with: run
  `mise install` and build with those, never another (`mise exec elixir@...`).
- Format only Elixir, with `mix format` (`mix precommit` runs it), and Rust
  (`native/mwt_relay`, `src-tauri`), with `cargo fmt`. Never reformat
  Markdown, JavaScript, CSS, JSON or YAML: edit them in the style they have.
- To see the app running, use the run-mwt skill: it gives the dev server a
  port and a data folder of its own. Never run one against `~/.mwt_client`,
  and don't run `msb` yourself: both belong to the MWT the user runs.
- `docs/architecture.md` is the one document: the mental models and the
  decisions behind them. Change it when a model changes; what code and
  tests say stays there. Reviews, audits and plans aren't kept in the
  repository.
- What agents read has byte budgets (`instructions_test.exs`): this file,
  `priv/sandbox/agents.md`, its guides and the way-of-working example.
  Make room before adding; raising a budget is the user's call.

### Tests in this project

- The whole suite takes about a minute. While you work, run the files you
  change (`mix test test/x_test.exs`, seconds), `mix test --failed` after a
  failure, and `mix precommit` once, when you are done.
- A run that passes prints only dots and counts: what the app logs shows
  under the test that failed.
- Keep test modules `async: true`. Each test signs in as an identity of its
  own (`VaultHelpers.unlocked_identity/1`, `ConnCase.sign_in/1`); what stands
  in for that identity's VM or Zed goes through `MWTClient.StandIns`, never
  `Application.put_env`, which makes the whole module wait to run alone,
  after every other one.
- A test that fails in a full run and passes alone is a race: find it rather
  than run again until it passes. Ones found so far: a short wait for a
  message that comes after a write, a git command or D-Bus (the suite's
  `assert_receive` waits up to a second, `test_helper.exs`; don't pass less);
  two git commits with the same content in the same second being one commit;
  database files read right after a lock (`VaultHelpers.lock_settled/2`);
  the clock read twice for one value, once in each of two seconds; a page's
  `start_async` after a click, not waited for (`render_async/1`); a sandbox
  task still writing into a folder a cleanup removes (register that cleanup
  before signing in: `unlocked_identity/1` waits for the identity's tasks);
  a lock's work waited for with `assert_receive` while it runs elsewhere
  (lock in the test, and react to it from a process of your own); a restart
  checked with one `:sys.get_state` of the supervisor
  (`VaultHelpers.restarted/3`).
- `mix test test/x_test.exs --slowest 10` shows a test you made slow. On the
  whole suite it runs every test one at a time (it turns on `--trace`), for
  minutes.
- What keeps the suite fast: a module's tests run one after another, so
  split one that takes over about 10 s alone, with what its parts share in
  `test/support`. Erlang's file server is one process for the whole BEAM:
  in code that runs often, use `MWTClient.Files` and
  `MWTClient.Executable` rather than `File` and a bare name in
  `System.cmd`; in a test, remove a folder with
  `MWTClient.TestFolders.remove!/1`, and never read a big file whole.
- Tests tagged `vm` start real VMs and are left out unless asked for
  (`mix test --only vm`): they need `/dev/kvm` and MWT's runtime in
  `priv/microsandbox`, which `scripts/install-runtime.sh` puts there. Where
  they can't run, cover the change with the tests that run without msb, and
  say what is left to try on a real VM.
- Start processes with `start_supervised!/1`. Don't sleep to wait for one:
  `Process.monitor/1` and `assert_receive {:DOWN, ...}`, or
  `:sys.get_state/1` to know it handled what was sent before.
- LiveView tests use `Phoenix.LiveViewTest`: `element/2` and
  `has_element?/2` on the ids the template gives, rather than raw HTML or
  text that may change; `render_submit/2` and `render_change/2` for forms;
  `LazyHTML` to look into what rendered.

## Phoenix, LiveView and Elixir

Phoenix 1.8 and LiveView 1.x, as documented and as the code around you
does. What follows is what this code holds to and is easy to get wrong.

### Templates and components

- LiveView templates begin with `<Layouts.app flash={@flash} ...>`
  (`MWTClientWeb.Layouts`, aliased in `mwt_client_web.ex`). A missing
  `current_scope` assign means the route is outside its `live_session`,
  or `current_scope` wasn't passed to `<Layouts.app>`: fix that.
- `<.flash_group>` only in `layouts.ex`. Icons with
  `<.icon name="hero-...">`, never `Heroicons` modules.
- Forms: `to_form/2` assigned in the LiveView, `<.form for={@form} id="...">`
  and `<.input field={@form[:field]}>` from `core_components.ex`. Never a
  changeset in the template, never `<.form let={f}>`. A `class` given to
  `<.input>` replaces its own classes, so it must style the input fully.
- Give the elements a test looks for (forms, buttons) a unique `id`.

### HEEx

- `{...}` interpolates in attributes and bodies; block constructs (`if`,
  `cond`, `case`, `for`) in bodies use `<%= ... %>`. There is no
  `else if`: use `cond` or `case`.
- A class with several values is a list, with an `if` in parentheses:
  `class={["px-2", @flag && "py-5", if(@on, do: "a", else: "b")]}`.
- Collections with `:for` or `<%= for ... %>`, never `Enum.each`.
  Comments are `<%!-- ... --%>`. Literal `{` and `}` in `<pre>` or `<code>`
  need `phx-no-curly-interpolation` on the parent.

### LiveView

- Navigate with `<.link navigate={...}>`, `<.link patch={...}>`,
  `push_navigate/2` and `push_patch/2`, never `live_redirect` or
  `live_patch`. Avoid LiveComponents unless there's a strong, specific
  need.
- A stream's parent has `phx-update="stream"` and an `id`, and each child
  the `id` the stream gives it. A stream can't be enumerated, counted or
  filtered: re-stream it with `reset: true`, and keep a count in an assign
  of its own.
- No inline `<script>`: a colocated hook
  (`<script :type={Phoenix.LiveView.ColocatedHook} name=".Name">`, the
  name starting with `.`), or a hook in `assets/js` passed to the
  `LiveSocket`. An element with `phx-hook` needs a unique `id`, and
  `phx-update="ignore"` when the hook manages its own DOM. `push_event/3`
  returns the socket: rebind it.
- Only the `app.js` and `app.css` bundles exist: import vendor code into
  them, never link it from a layout.

### CSS

Tailwind v4, with no `tailwind.config.js`: keep the `@import` and `@source`
lines at the top of `app.css` as they are. No `@apply` and no daisyUI:
write components with Tailwind classes, polished, with subtle hover states
and transitions.

### Elixir

- Lists have no index access (`list[i]`): `Enum.at/2`, pattern matching or
  `List`. Structs have no access syntax (`struct[:field]`): `struct.field`,
  or `Ecto.Changeset.get_field/2` on a changeset.
- Bind the result of `if`, `case` or `cond`: a rebinding inside one is
  lost.
- One module per file. Predicates end in `?`; `is_` names are for guards.
  Never `String.to_atom/1` on user input.
- Name what a supervisor starts (`{DynamicSupervisor, name: ...}`). For
  concurrent enumeration, `Task.async_stream/3`, usually with
  `timeout: :infinity`.
- Dates and times with the standard library: no new dependency unless
  asked.
- A router `scope` prefixes its alias: inside `scope "/", MWTClientWeb`,
  `live "/x", XLive` is `MWTClientWeb.XLive`.
- Read `mix help TASK` before using a task. `mix deps.clean --all` is
  almost never needed.
