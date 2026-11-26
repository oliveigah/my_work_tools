defmodule MWTClientWeb.SandboxLive.VmConsole do
  @moduledoc """
  Try it as the VM: a command you type, run in the VM where agents run
  theirs, optionally with one of your credentials (`mwt exec`), with
  what it printed, its exit status, and what MWT decided about each request
  it made while it ran (`MWTClient.Sandbox.Console`). For checking, by
  hand, that the VM can do what a task needs: `gh repo view OWNER/REPO`,
  `curl -sS -i URL`, `git ls-remote URL`.

  Each run is kept in the console's history (`MWTClient.Sandbox.ConsoleHistory`),
  ten a page, the one opened showing what it printed and what MWT decided
  while it ran; any runs again as it did.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components, only: [clock: 1, pages: 1, paged: 3, where: 1]

  @per_page 10

  attr :credentials, :list, required: true
  attr :history, :list, required: true, doc: "the runs kept, newest first"
  attr :term, :string, default: "", doc: "the words the history is searched for"
  attr :page, :integer, default: 1, doc: "the page of the history shown"
  attr :open, :any, default: nil, doc: "the id of the run opened, or nil"
  attr :decisions, :list, default: [], doc: "what MWT decided while the opened run ran"
  attr :error, :string, default: nil, doc: "why the last run didn't happen"
  attr :running, :any, required: true, doc: "the run going on now, or nil"
  attr :vm_running, :boolean, required: true
  attr :console_with, :map, default: %{}, doc: "what the form held at the last run"
  attr :waiting, :list, default: [], doc: "the approvals waiting for you"
  attr :now, DateTime, required: true

  @doc "The console: a command, the credential it runs with, what came back, and the runs before."
  def panel(assigns) do
    credentials = Enum.reject(assigns.credentials, &match?(%{proposal: %{reviewed_at: nil}}, &1))
    mode = if assigns.console_with["mode"] == "http", do: "http", else: "command"
    found = MWTClient.Sandbox.ConsoleHistory.matching(assigns.history, assigns.term)
    {shown, page, pages} = paged(found, assigns.page, @per_page)

    assigns =
      assign(assigns,
        credentials: credentials,
        mode: mode,
        preview: preview(mode, assigns.console_with, credentials),
        found: length(found),
        shown: shown,
        page: page,
        pages: pages,
        per_page: @per_page
      )

    ~H"""
    <section id="vm-console" aria-label="Try it as the VM" class="space-y-4">
      <header class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <h2 class="flex items-center gap-2 text-[15px] font-semibold tracking-tight text-ink">
          Try it as the VM <.where id="console-where" place={:vm} />
        </h2>
        <p class="text-[11px] text-muted">
          A command runs in the VM as an agent's would: through MWT, decided by your grants, recorded in the activity log.
        </p>
      </header>

      <div
        :if={not @vm_running}
        id="console-vm-stopped"
        class="flex items-center gap-2 rounded-lg border border-line-soft bg-deep/50 px-3 py-2.5 text-xs text-muted"
      >
        <.icon name="hero-pause-circle" class="size-4 shrink-0 text-faint" />
        The VM isn't running: start it to run commands here.
      </div>

      <form
        id="console-form"
        phx-submit="console_run"
        phx-change="console_change"
        class="space-y-2 rounded-xl border border-line bg-panel p-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <div
            id="console-mode"
            role="radiogroup"
            aria-label="What to run"
            class="flex items-center rounded-lg border border-line bg-deep p-0.5"
          >
            <label
              :for={{value, label} <- [{"command", "Command"}, {"http", "HTTP request"}]}
              id={"console-mode-#{value}"}
              class={[
                "cursor-pointer rounded-md px-2.5 py-1 text-[12px] transition-colors has-focus-visible:outline-2 has-focus-visible:outline-accent",
                if(@mode == value,
                  do: "bg-panel font-medium text-ink shadow-sm",
                  else: "text-muted hover:text-ink"
                )
              ]}
            >
              <input
                type="radio"
                name="console[mode]"
                value={value}
                checked={@mode == value}
                class="sr-only"
              />
              {label}
            </label>
          </div>
          <label
            for="console-with"
            class="ml-2 text-[11px] text-muted"
            title="As an agent's mwt exec CREDENTIAL -- COMMAND: the command gets the credential's placeholders, never its value, and MWT puts the value in as a request leaves, where a grant over it lets it."
          >
            With credential
          </label>
          <select
            name="console[with]"
            id="console-with"
            class="rounded-md border border-line bg-deep px-2 py-1 text-xs text-ink focus:border-accent focus:outline-none"
          >
            <option value="">none</option>
            <option
              :for={credential <- @credentials}
              value={credential.id}
              selected={@console_with["with"] == credential.id}
            >
              {credential.name}
            </option>
          </select>
        </div>

        <div :if={@mode == "command"} class="flex items-start gap-2">
          <span class="select-none pt-2 font-mono text-xs text-faint">$</span>
          <textarea
            name="console[command]"
            id="console-command"
            rows="2"
            placeholder="gh repo view oliveigah/klife"
            autocomplete="off"
            spellcheck="false"
            class="min-h-10 flex-1 resize-y rounded-md border border-line bg-deep px-2.5 py-2 font-mono text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
          >{@console_with["command"]}</textarea>
        </div>

        <div :if={@mode == "http"} id="console-http" class="space-y-2">
          <div class="flex gap-2">
            <select
              name="console[method]"
              id="console-method"
              class="rounded-md border border-line bg-deep px-2 py-1.5 font-mono text-xs text-ink focus:border-accent focus:outline-none"
            >
              <option
                :for={method <- ~w(GET POST PUT PATCH DELETE HEAD)}
                value={method}
                selected={(@console_with["method"] || "GET") == method}
              >
                {method}
              </option>
            </select>
            <input
              type="text"
              name="console[url]"
              id="console-url"
              value={@console_with["url"]}
              placeholder="https://api.github.com/repos/oliveigah/klife"
              autocomplete="off"
              class="min-w-0 flex-1 rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
            />
          </div>
          <div class="grid gap-2 sm:grid-cols-2">
            <textarea
              name="console[headers]"
              id="console-headers"
              rows="2"
              placeholder="Headers, one a line (optional)"
              class="resize-y rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
            >{@console_with["headers"]}</textarea>
            <textarea
              name="console[body]"
              id="console-body"
              rows="2"
              placeholder="Body (optional)"
              class="resize-y rounded-md border border-line bg-deep px-2.5 py-1.5 font-mono text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
            >{@console_with["body"]}</textarea>
          </div>
        </div>

        <p
          :if={@preview != ""}
          id="console-preview"
          class="truncate font-mono text-[10px] text-faint"
          title={@preview}
        >
          Runs: {@preview}
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <p class="min-w-0 flex-1 text-[10px] leading-4 text-faint">
            What you type goes into the VM, where agents can read it: pick a credential rather than paste its value. The command then gets its placeholders, as an agent's does.
          </p>
          <span :if={@running} id="console-running" class="text-[11px] text-muted">
            <.icon name="hero-arrow-path" class="size-3.5 animate-spin" /> Running…
          </span>
          <.button
            :if={@running}
            type="button"
            id="console-stop"
            phx-click="console_stop"
          >
            Stop
          </.button>
          <.button
            type="submit"
            id="console-run"
            variant="primary"
            disabled={not @vm_running or @running != nil}
          >
            <.icon name="hero-play-micro" class="size-3.5" /> Run
          </.button>
        </div>
      </form>

      <p
        :if={@error}
        id="console-error"
        class="flex items-start gap-2 rounded-lg border border-bad/30 bg-bad-soft/20 px-3 py-2 text-xs text-bad"
      >
        <.icon name="hero-exclamation-circle-micro" class="mt-0.5 size-3.5 shrink-0" /> {@error}
      </p>

      <div
        :if={@running && asks(@waiting) != []}
        id="console-asks"
        class="space-y-2 rounded-xl border border-warn/45 bg-warn-soft/20 p-3"
      >
        <p class="text-[11px] font-medium text-ink">
          MWT asks you before letting these through; the command waits for your answer:
        </p>
        <div
          :for={ask <- asks(@waiting)}
          id={"console-ask-#{ask.id}"}
          class="flex flex-wrap items-center gap-2 text-[11px]"
        >
          <span class="min-w-0 flex-1 truncate font-mono text-ink" title={ask.title}>
            {ask.method} {ask.host}{ask.path}
          </span>
          <.button
            type="button"
            id={"console-allow-#{ask.id}"}
            phx-click="decide"
            phx-value-id={ask.id}
            phx-value-decision="allow_once"
          >
            Allow once
          </.button>
          <.button
            type="button"
            id={"console-deny-#{ask.id}"}
            variant="danger"
            phx-click="decide"
            phx-value-id={ask.id}
            phx-value-decision="deny"
          >
            Deny
          </.button>
        </div>
      </div>

      <section id="console-history" aria-label="History" class="space-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="text-[13px] font-semibold text-ink">History</h3>
          <span id="console-history-count" class="text-[11px] tabular-nums text-muted">
            {length(@history)} {if(length(@history) == 1, do: "run", else: "runs")}
          </span>
          <span class="flex-1"></span>
          <form
            :if={@history != []}
            id="console-search"
            phx-change="console_search"
            phx-submit="console_search"
            class="relative"
          >
            <.icon
              name="hero-magnifying-glass-micro"
              class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
            />
            <input
              type="search"
              name="term"
              id="console-search-term"
              value={@term}
              placeholder="Search commands"
              phx-debounce="300"
              autocomplete="off"
              class="w-52 rounded-md border border-line bg-deep py-1 pl-7 pr-2 text-xs text-ink placeholder:text-faint focus:border-accent focus:outline-none"
            />
          </form>
          <.button
            :if={@history != []}
            type="button"
            id="console-clear"
            variant="ghost"
            phx-click="console_clear"
            title="Forget every run kept here. The activity log keeps its line of each."
          >
            Clear
          </.button>
        </div>
        <p class="text-[10px] leading-4 text-faint">
          Kept in memory, with what each printed, until MWT locks or stops; the activity log keeps a line of each run, never its output.
        </p>

        <ol
          :if={@shown != []}
          id="console-runs"
          class="divide-y divide-line-soft overflow-hidden rounded-xl border border-line bg-panel"
        >
          <li :for={run <- @shown} id={"console-run-#{run.id}"}>
            <div class={[
              "flex items-center gap-2 px-3 py-2 transition-colors",
              if(@open == run.id, do: "bg-deep/50", else: "hover:bg-hover/40")
            ]}>
              <button
                type="button"
                id={"console-open-#{run.id}"}
                phx-click="console_open"
                phx-value-id={run.id}
                aria-expanded={to_string(@open == run.id)}
                aria-controls={"console-output-#{run.id}"}
                class="flex min-w-0 flex-1 cursor-pointer items-center gap-2 text-left"
              >
                <.icon
                  name="hero-chevron-right-micro"
                  class={[
                    "size-3.5 shrink-0 text-faint transition-transform",
                    @open == run.id && "rotate-90"
                  ]}
                />
                <code class="min-w-0 flex-1 truncate font-mono text-xs text-ink" title={run.command}>
                  $ {run.command}
                </code>
              </button>
              <span :if={run.credential} class="shrink-0 text-[10px] text-muted">
                as <span class="font-mono">{run.credential}</span>
              </span>
              <.run_status run={run} />
              <.clock
                id={"console-at-#{run.id}"}
                since={run.finished_at}
                now={@now}
                class="w-16 shrink-0 text-right text-[10px] text-faint"
              />
              <button
                type="button"
                id={"console-again-#{run.id}"}
                phx-click="console_again"
                phx-value-id={run.id}
                disabled={not @vm_running or @running != nil}
                title="Run it again, as it ran"
                aria-label="Run it again"
                class="inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-accent disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-muted"
              >
                <.icon name="hero-arrow-path-micro" class="size-3.5" />
              </button>
            </div>
            <div
              :if={@open == run.id}
              id={"console-output-#{run.id}"}
              class="border-t border-line-soft"
            >
              <p
                :if={run.stopped}
                class="px-3 py-2 text-xs text-muted"
              >
                Stopped from MWT before it ended: what it started in the VM may have finished there.
              </p>
              <pre
                :if={not run.stopped}
                id={"console-output-text-#{run.id}"}
                phx-no-curly-interpolation
                class="max-h-96 overflow-auto whitespace-pre-wrap break-words bg-deep/30 px-3 py-2 font-mono text-[11px] leading-4 text-ink"
              ><%= if run.output == "" do %>(no output)<% else %><MWTClientWeb.Ansi.text text={run.output} /><% end %></pre>
              <div
                :if={@decisions != []}
                id={"console-decisions-#{run.id}"}
                class="border-t border-line-soft px-3 py-2"
              >
                <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
                  What MWT decided while it ran
                </p>
                <ul class="space-y-0.5">
                  <li :for={event <- @decisions} class="flex items-baseline gap-2 text-[11px]">
                    <span class={["w-16 shrink-0 font-medium", outcome_tone(event.outcome)]}>
                      {outcome_word(event.outcome)}
                    </span>
                    <span class="min-w-0 flex-1 truncate text-muted" title={event.summary}>
                      {event.summary}
                    </span>
                  </li>
                </ul>
              </div>
            </div>
          </li>
        </ol>
        <.pages
          :if={@pages > 1}
          name="console"
          label="Pages of runs"
          page={@page}
          pages={@pages}
          per_page={@per_page}
          total={@found}
          event="console_page"
        />
        <p
          :if={@shown == []}
          id="console-no-runs"
          class="rounded-xl border border-dashed border-line px-3 py-6 text-center text-xs text-muted"
        >
          {if(@history == [],
            do: "No runs yet: each command you run shows here, with what it printed.",
            else: "No run matches those words."
          )}
        </p>
      </section>
    </section>
    """
  end

  @doc """
  The command a run of the form sends: what was typed, or the HTTP
  request as a `curl` command (`MWTClient.Sandbox.Console.http_command/2`).
  """
  def command(params, credentials) do
    if params["mode"] == "http",
      do:
        MWTClient.Sandbox.Console.http_command(
          params,
          Enum.find(credentials, &(&1.id == params["with"]))
        ),
      else: to_string(params["command"])
  end

  # The command an HTTP request runs as, shown before it runs; a typed one
  # is shown as typed.
  defp preview("http", params, credentials) do
    if String.trim(to_string(params["url"])) == "", do: "", else: command(params, credentials)
  end

  defp preview(_command, _params, _credentials), do: ""

  # The uses waiting for you: a request or a connection, as a command run
  # here makes them.
  defp asks(waiting), do: Enum.filter(waiting, &(&1.kind in [:request, :connection]))

  attr :run, :map, required: true

  defp run_status(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium",
      cond do
        @run.stopped -> "bg-warn-soft/50 text-warn-strong"
        @run.timed_out -> "bg-warn-soft/50 text-warn-strong"
        @run.cut -> "bg-warn-soft/50 text-warn-strong"
        @run.status == 0 -> "bg-ok-soft/50 text-ok-strong"
        true -> "bg-bad-soft/50 text-bad"
      end
    ]}>
      <%= cond do %>
        <% @run.stopped -> %>
          stopped
        <% @run.timed_out -> %>
          stopped: out of time
        <% @run.cut -> %>
          stopped: too much output
        <% true -> %>
          exit {@run.status}
      <% end %>
    </span>
    """
  end

  defp outcome_word(outcome) when outcome in [:allowed, :swapped, :tunnel, :read], do: "allowed"
  defp outcome_word(outcome) when outcome in [:denied, :refused, :blocked], do: "refused"
  defp outcome_word(:timed_out), do: "timed out"
  defp outcome_word(outcome), do: outcome |> to_string() |> String.replace("_", " ")

  defp outcome_tone(outcome) when outcome in [:allowed, :swapped, :tunnel, :read],
    do: "text-ok-strong"

  defp outcome_tone(_outcome), do: "text-bad"
end
