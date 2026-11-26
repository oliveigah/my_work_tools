defmodule MWTClientWeb.SandboxLive.Terminal do
  @moduledoc """
  The Overview's terminal: commands you type, run in the VM one at a time
  as the Live Test runs them (`MWTClient.Sandbox.Console`), shown as a
  terminal shows them: a prompt with the folder, what each printed with
  its colours (`MWTClientWeb.Ansi`), and the next prompt.

  It is a view of the console's history (`MWTClient.Sandbox.ConsoleHistory`),
  which the Live Test lists too: what scrolls back, and what ↑ and ↓ bring
  back, is the runs kept there. `cd` carries over: each command starts in
  the folder the last one ended in. *Clear* (Ctrl+L, or `clear`) hides
  what came before from this screen only.

  What it can't do, a terminal can: a command's output shows once it
  ends, at most `Console.max_output/0` of it after `Console.max_seconds/0`,
  and nothing reads what you type while it runs (no editors, no prompts).
  For those, open the VM in Zed.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components, only: [where: 1]

  alias MWTClient.Sandbox.Console

  @shown 50

  attr :history, :list, required: true, doc: "the console's runs, newest first"
  attr :since, :integer, default: 0, doc: "the last run cleared from the screen"
  attr :running, :any, default: nil, doc: "the run going on, `%{command:, dir:}`, or nil"
  attr :cwd, :string, required: true, doc: "the folder the next command starts in"
  attr :error, :string, default: nil
  attr :vm_running, :boolean, required: true

  def panel(assigns) do
    assigns =
      assign(assigns,
        runs:
          assigns.history
          |> Enum.filter(&(&1.id > assigns.since))
          |> Enum.take(@shown)
          |> Enum.reverse(),
        # What ↑ brings back, newest first, a command repeated once.
        recall: assigns.history |> Enum.map(& &1.command) |> Enum.dedup() |> Enum.take(100)
      )

    ~H"""
    <section
      id="terminal"
      phx-hook=".Terminal"
      tabindex="-1"
      data-running={to_string(@running != nil)}
      data-recall={Jason.encode!(@recall)}
      class="mb-6 overflow-hidden rounded-xl border border-line bg-panel outline-none"
      aria-label="Terminal"
    >
      <header class="flex flex-wrap items-center gap-2 border-b border-line-soft px-4 py-2">
        <h2 class="text-[13px] font-semibold text-ink">Terminal</h2>
        <.where id="terminal-where" place={:vm} />
        <span class="flex-1"></span>
        <span class="hidden text-[10px] text-faint sm:inline">
          ↑ ↓ history · Ctrl+C stop · Ctrl+L clear
        </span>
        <button
          type="button"
          id="terminal-clear"
          phx-click="terminal_clear"
          class="cursor-pointer rounded px-1.5 py-0.5 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
        >
          Clear
        </button>
      </header>
      <div
        id="terminal-screen"
        data-screen
        class="h-72 cursor-text overflow-y-auto bg-deep px-3 py-2 font-mono text-[12px] leading-5 text-ink"
      >
        <div :for={run <- @runs} id={"terminal-run-#{run.id}"}>
          <p phx-no-format class="whitespace-pre-wrap break-all"><span class="select-none text-ok-strong">{prompt(run.dir)}</span>{run.command}</p>
          <pre
            :if={run.output != ""}
            id={"terminal-output-#{run.id}"}
            phx-no-curly-interpolation
            class="whitespace-pre-wrap break-words font-mono"
          ><MWTClientWeb.Ansi.text text={run.output} /></pre>
          <p :if={ending(run)} class="text-[11px] text-warn-strong">{ending(run)}</p>
        </div>

        <div :if={@running} id="terminal-running">
          <p phx-no-format class="whitespace-pre-wrap break-all"><span class="select-none text-ok-strong">{prompt(@running[:dir])}</span>{@running.command}</p>
          <p class="flex items-center gap-1.5 text-[11px] text-muted">
            <.icon name="hero-arrow-path-micro" class="size-3 animate-spin" />
            Running: its output shows when it ends. Ctrl+C stops it.
          </p>
        </div>

        <p :if={@error} id="terminal-error" class="whitespace-pre-wrap text-bad">{@error}</p>

        <form
          :if={is_nil(@running)}
          id="terminal-form"
          phx-submit="terminal_run"
          class="flex items-baseline"
          autocomplete="off"
        >
          <label phx-no-format for="terminal-input" class="select-none whitespace-pre text-ok-strong">{prompt(@cwd)}</label>
          <input
            type="text"
            name="command"
            id="terminal-input"
            spellcheck="false"
            autocapitalize="off"
            disabled={not @vm_running}
            placeholder={
              if(@vm_running, do: "", else: "The VM isn't running: start it to type here.")
            }
            class="min-w-0 flex-1 border-0 bg-transparent p-0 font-mono text-[12px] leading-5 text-ink outline-none placeholder:text-faint focus:ring-0"
          />
        </form>
      </div>
    </section>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Terminal">
      // The keys a terminal has, on a line-at-a-time console: Enter runs
      // the line, ↑ and ↓ walk back through what ran (newest first, the
      // line you were typing kept), Ctrl+C stops what runs (or drops the
      // line; with text selected it copies, as the browser does), Ctrl+L
      // clears the screen. The screen follows new output while you are at
      // its bottom, and a click on it puts you back on the line.
      export default {
        mounted() {
          this.at = -1
          this.draft = ""
          this.follow = true
          this.screen = this.el.querySelector("[data-screen]")
          this.screen.addEventListener("scroll", () => {
            const s = this.screen
            this.follow = s.scrollHeight - s.scrollTop - s.clientHeight < 24
          })
          this.screen.addEventListener("mouseup", () => {
            if (window.getSelection().toString() === "") this.input()?.focus()
          })
          this.el.addEventListener("keydown", (e) => this.key(e))
          this.toBottom()
        },
        updated() {
          if (this.follow) this.toBottom()
          // Back on the line once a run ends, if you were on the terminal:
          // while it runs the line is gone, and the terminal itself holds
          // the focus, for Ctrl+C.
          const here = this.refocus || this.el.contains(document.activeElement)
          if (this.el.dataset.running === "false" && here) {
            this.input()?.focus()
            this.refocus = false
          }
        },
        input() { return this.el.querySelector("#terminal-input") },
        toBottom() { this.screen.scrollTop = this.screen.scrollHeight },
        recall() { return JSON.parse(this.el.dataset.recall || "[]") },
        key(e) {
          const input = this.input()
          const selected = window.getSelection().toString() !== ""

          if (e.ctrlKey && e.key === "c" && !selected) {
            e.preventDefault()
            if (this.el.dataset.running === "true") this.pushEvent("console_stop", {})
            else if (input) { input.value = ""; this.at = -1 }
            return
          }

          if (e.ctrlKey && e.key === "l") {
            e.preventDefault()
            this.pushEvent("terminal_clear", {})
            return
          }

          if (!input || e.target !== input) return

          if (e.key === "Enter") {
            e.preventDefault()
            const command = input.value
            if (command.trim() === "") return
            this.pushEvent("terminal_run", {command})
            input.value = ""
            this.at = -1
            this.follow = true
            this.refocus = true
            this.el.focus({preventScroll: true})
            return
          }

          if (e.key === "ArrowUp" || e.key === "ArrowDown") {
            const recall = this.recall()
            if (recall.length === 0) return
            e.preventDefault()
            if (this.at === -1) this.draft = input.value
            this.at = e.key === "ArrowUp"
              ? Math.min(this.at + 1, recall.length - 1)
              : this.at - 1
            if (this.at < 0) { this.at = -1; input.value = this.draft }
            else input.value = recall[this.at]
            input.setSelectionRange(input.value.length, input.value.length)
          }
        },
      }
    </script>
    """
  end

  # The prompt for a folder, as bash shows it under /work.
  defp prompt(nil), do: prompt("/work")
  defp prompt(dir), do: "vm:#{dir}$ "

  # How a run ended, when it didn't end by itself or ended in an error.
  defp ending(%{stopped: true}), do: "Stopped from MWT."
  defp ending(%{timed_out: true}), do: "Stopped: past #{Console.max_seconds()} s."

  defp ending(%{cut: true}),
    do: "Stopped: over #{div(Console.max_output(), 1024)} KiB of output."

  defp ending(%{status: status}) when is_integer(status) and status != 0, do: "exit #{status}"
  defp ending(_run), do: nil
end
