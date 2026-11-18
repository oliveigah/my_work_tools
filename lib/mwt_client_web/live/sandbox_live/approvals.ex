defmodule MWTClientWeb.SandboxLive.Approvals do
  @moduledoc """
  The approvals page, and the cards it shares with the overview. Three types
  of approval wait in one queue:

    * **activations** - an agent in the VM asks for a grant to be turned on,
      or for access no grant gives yet;
    * **uses** - a request carrying a grant's placeholder, or a connection
      through a network grant, held by the proxy; or a call of MWT's own
      tools that changes a note, a diagram or a flash card;
    * **commands** - an agent asks to run a command on this machine, as you.
      Drawn in red: no allowance ever covers one. The full card is the only
      place to run it, so the script is always read in full first. A command
      whose output you chose to see first comes back with it, to send or
      keep; while it runs it sits above the queue with a Stop button.

  Every card is drawn the same way (`shell/1`), and says each thing once:
  who asked, on one line; what would happen, as its title; the thing itself
  in full (the request, the script, the change, the grant); what MWT worked
  out beside what the agent says; then your choices. What MWT saw sits in a
  plain list; the agent's words sit in a dashed box marked as unverified, so
  a commit message cannot pass for a description of the request. A held
  request shows every header, and which of them carry the grant's
  placeholder, with buttons to copy it as curl, as HTTP or just its body.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Sandbox.{
    Approval,
    Grant,
    HostCommand,
    Presets,
    RequestView
  }

  alias MWTClient.Sandbox.Instructions

  attr :waiting, :list, required: true
  attr :running, :list, default: []
  attr :history, :list, required: true
  attr :grants, :map, required: true, doc: "grants by id"
  attr :marks, :list, required: true, doc: "`RequestView.marks/1` of every grant"
  attr :now, DateTime, required: true
  attr :focus, :string, default: nil, doc: "the approval a desktop notification opened"

  def page(assigns) do
    ~H"""
    <.page_header id="approvals-header" title="Approvals">
      <:help>
        Agents asking for a grant or to run a command on this machine, and every use of a grant: requests carrying its placeholder, connections through a network grant. Each waits here until you decide, or gives up on its own.
      </:help>
    </.page_header>

    <div class="space-y-6">
      <.running :if={@running != []} running={@running} now={@now} />

      <section id="waiting-approvals" aria-label="Waiting for a decision" class="space-y-3">
        <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
          Waiting
          <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">
            {length(@waiting)}
          </span>
        </h2>
        <div :if={@waiting == []} class="rounded-xl border border-dashed border-line">
          <.empty icon="hero-hand-raised" id="no-waiting-approvals">
            Nothing is waiting. Asks from <code class="font-mono">mwt request</code>
            and <code class="font-mono">mwt run</code>, and uses of a grant that is on, show up here.
          </.empty>
        </div>
        <.approval
          :for={approval <- @waiting}
          approval={approval}
          grant={approval.grant_id && @grants[approval.grant_id]}
          marks={@marks}
          now={@now}
          focused={approval.id == @focus}
        />
      </section>

      <.card id="approval-history" title="Decided" body_class="">
        <:help>The latest 100 decisions, newest first.</:help>
        <div :if={@history == []}>
          <.empty icon="hero-clock">Decisions you make will be listed here.</.empty>
        </div>
        <ul class="divide-y divide-line-soft">
          <%= for approval <- @history do %>
            <%= if approval.kind == :command do %>
              <.decided_command approval={approval} now={@now} />
            <% else %>
              <li id={"decided-#{approval.id}"} class="flex items-center gap-3 px-4 py-2.5">
                <.decided_badge approval={approval} />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-xs text-ink">{history_title(approval, @grants)}</p>
                  <p class="truncate text-[11px] text-faint">
                    {grant_name(@grants, approval)} · {decision_words(approval)}
                    <span :if={approval.kind == :activation and approval.thread}>· {who(approval)}</span>
                  </p>
                </div>
                <span class="shrink-0 text-[11px] text-faint">
                  <.clock id={"decided-at-#{approval.id}"} since={approval.decided_at} now={@now} />
                </span>
              </li>
            <% end %>
          <% end %>
        </ul>
      </.card>
    </div>
    """
  end

  @doc "One waiting approval, of any type."
  attr :approval, Approval, required: true
  attr :grant, :any, required: true
  attr :marks, :list, default: []
  attr :now, DateTime, required: true

  attr :focused, :boolean,
    default: false,
    doc: "ringed and scrolled into view: the one a desktop notification opened"

  def approval(%{approval: %Approval{kind: :activation}} = assigns), do: activation_card(assigns)

  def approval(%{approval: %Approval{kind: :command, stage: :output}} = assigns),
    do: output_card(assigns)

  def approval(%{approval: %Approval{kind: :command}} = assigns), do: command_card(assigns)
  def approval(%{approval: %Approval{kind: :tool}} = assigns), do: tool_card(assigns)
  def approval(assigns), do: use_card(assigns)

  ## The card

  attr :approval, Approval, required: true
  attr :now, DateTime, required: true
  attr :focused, :boolean, default: false
  attr :alarm, :boolean, default: false, doc: "drawn in red: text the agent wrote, to run as you"
  attr :title_class, :any, default: "text-sm"
  attr :rest, :global
  slot :tile, required: true
  slot :meta, required: true, doc: "who asked, and for what grant, on one line"
  slot :title, doc: "what would happen"
  slot :subtitle
  slot :inner_block, doc: "the thing itself, then the facts and the agent's words"
  slot :footer, required: true, doc: "your choices"

  # Every approval is this card: the same parts in the same places, so each
  # kind reads alike and nothing is said twice.
  defp shell(assigns) do
    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class={[
        "rounded-xl border bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30",
        if(@alarm, do: "border-bad/50 border-l-4", else: "border-line"),
        @focused && "ring-2 ring-accent/70 ring-offset-2 ring-offset-app"
      ]}
      phx-mounted={@focused && JS.dispatch("mwt:reveal")}
      {@rest}
    >
      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        {render_slot(@tile)}
        <div class="min-w-0 flex-1">
          <p class="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5 text-[11px] leading-4 text-muted">
            {render_slot(@meta)}
          </p>
          <h3
            :if={@title != []}
            class={["mt-1 break-words font-semibold leading-5 text-ink", @title_class]}
          >
            {render_slot(@title)}
          </h3>
          <div :if={@subtitle != []} class="mt-0.5 text-xs leading-5 text-muted">
            {render_slot(@subtitle)}
          </div>
        </div>
        <p
          class="flex shrink-0 items-center gap-1 pt-px font-mono text-xs text-muted"
          title="It gives up on its own then, and the agent hears no."
        >
          <.icon name="hero-clock-micro" class="size-3.5 text-faint" />
          <.clock
            id={"approval-left-#{@approval.id}"}
            deadline={@approval.deadline}
            suffix=" left"
            done="0:00"
            now={@now}
          />
        </p>
      </header>

      <div :if={@inner_block != []} class="space-y-3 px-4 pb-4">
        {render_slot(@inner_block)}
      </div>

      <footer class="flex flex-wrap items-center gap-2 rounded-b-xl border-t border-line-soft bg-deep/40 px-4 py-2.5">
        {render_slot(@footer)}
      </footer>
    </article>
    """
  end

  attr :icon, :string, required: true
  attr :tone, :atom, values: [:use, :ask, :alarm], required: true

  # The square at a card's start: green for a use of a grant that is on,
  # violet for an ask, red for text the agent wrote to run as you.
  defp tile(assigns) do
    ~H"""
    <span class={[
      "flex size-8 shrink-0 items-center justify-center rounded-lg border",
      case @tone do
        :use -> "border-ok/35 bg-ok-soft/50 text-ok-strong"
        :ask -> "border-violet/30 bg-violet/10 text-violet-strong"
        :alarm -> "border-bad/40 bg-bad-soft/50 text-bad"
      end
    ]}>
      <.icon name={@icon} class="size-4" />
    </span>
    """
  end

  defp dot(assigns) do
    ~H"""
    <span class="text-faint" aria-hidden="true">·</span>
    """
  end

  attr :approval, Approval, required: true

  # Who asked, as the asking process told it: the agent, its thread and
  # folder. Claims, which help tell asks apart and prove nothing.
  defp asked_by(assigns) do
    ~H"""
    <span :if={@approval.agent} class="font-medium text-ink/80">{@approval.agent}</span>
    <.thread
      :if={@approval.thread}
      id={"approval-thread-#{@approval.id}"}
      thread={@approval.thread}
    />
    """
  end

  attr :id, :string, required: true
  attr :thread, :map, required: true

  # The thread an ask came from, as the agent's process tells it, so asks
  # from several threads can be told apart. A claim, like the agent's name.
  defp thread(assigns) do
    ~H"""
    <span
      id={@id}
      title={"The thread that asked, as its process says (not verified)" <> if(@thread.id, do: "\nThread id: " <> @thread.id, else: "") <> if(@thread.folder, do: "\nFolder: " <> @thread.folder, else: "")}
      class="inline-flex min-w-0 max-w-full flex-wrap items-center gap-x-2"
    >
      <span
        :if={@thread.title || @thread.id}
        id={"#{@id}-title"}
        class="inline-flex min-w-0 max-w-full items-center gap-1"
      >
        <.icon name="hero-chat-bubble-left-right-micro" class="size-3 shrink-0 text-faint" />
        <span class="truncate">{@thread.title || "thread " <> String.slice(@thread.id, 0, 8)}</span>
      </span>
      <span
        :if={@thread.folder}
        id={"#{@id}-folder"}
        class="inline-flex min-w-0 max-w-full items-center gap-1"
      >
        <.icon name="hero-folder-micro" class="size-3 shrink-0 text-faint" />
        <span class="truncate font-mono">{Approval.short_folder(@thread.folder)}</span>
      </span>
    </span>
    """
  end

  attr :approval, Approval, required: true
  attr :words, :string, required: true
  attr :title, :string, required: true

  defp retries(assigns) do
    ~H"""
    <span
      :if={@approval.retries > 0}
      id={"approval-retries-#{@approval.id}"}
      title={@title}
      class="rounded bg-deep px-1.5 py-px font-mono text-[10px] text-faint"
    >
      {@words}
    </span>
    """
  end

  attr :approval, Approval, required: true
  attr :facts, :list, required: true
  attr :hints, :list, default: []

  # What MWT worked out, beside what MWT guessed and what the agent says.
  defp evidence(assigns) do
    ~H"""
    <div
      :if={@facts != [] or @hints != [] or @approval.claims != []}
      class={[
        "grid gap-3",
        (@facts != [] and (@hints != [] or @approval.claims != [])) &&
          "lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
      ]}
    >
      <.facts :if={@facts != []} id={"approval-facts-#{@approval.id}"} facts={@facts} />
      <div :if={@hints != [] or @approval.claims != []} class="space-y-3">
        <.hints id={"approval-hints-#{@approval.id}"} hints={@hints} />
        <.claims id={"approval-claims-#{@approval.id}"} claims={@approval.claims} />
      </div>
    </div>
    """
  end

  attr :approval, Approval, required: true
  attr :grant, :any, required: true
  attr :allow, :string, default: "Allow once"
  attr :similar, :string, default: nil, doc: "what allowing similar covers; nil when not offered"
  attr :similar_detail, :string, default: nil
  attr :similar_pattern, :boolean, default: false, doc: "the detail is a pattern: shown as code"
  attr :every, :string, required: true, doc: "what every use of the grant is, in words"

  # A use's choices: once, for a while (uses like it, or every use of the
  # grant), deny, or deny and turn the grant off.
  defp use_choices(assigns) do
    ~H"""
    <button
      type="button"
      id={"allow-once-#{@approval.id}"}
      phx-click="decide"
      phx-value-id={@approval.id}
      phx-value-decision="allow_once"
      class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-ok px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ok"
    >
      <.icon name="hero-check-micro" class="size-3.5" /> {@allow}
    </button>

    <details
      :if={(@similar || @grant) && not always_asks?(@grant)}
      id={"allow-more-#{@approval.id}"}
      class="group relative"
    >
      <summary class="inline-flex cursor-pointer list-none items-center gap-1 rounded-md border border-line bg-panel px-2.5 py-1.5 text-xs font-medium text-ink transition-colors hover:bg-hover [&::-webkit-details-marker]:hidden">
        Allow for a while
        <.icon
          name="hero-chevron-down-micro"
          class="size-3.5 text-muted transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="absolute left-0 top-full z-30 mt-1.5 w-80 divide-y divide-line-soft rounded-lg border border-line bg-panel shadow-xl shadow-black/20">
        <.allow_scope
          :if={@similar}
          id={"allow-similar-#{@approval.id}"}
          approval={@approval}
          scope="similar"
          label={@similar}
          grant={@grant}
        >
          <span class={@similar_pattern && "font-mono text-[10px] text-ink"}>{@similar_detail}</span>
        </.allow_scope>
        <.allow_scope
          :if={@grant}
          id={"allow-all-#{@approval.id}"}
          approval={@approval}
          scope="all"
          label={"Every use of #{@grant.name}"}
          grant={@grant}
        >
          {@every}
        </.allow_scope>
      </div>
    </details>

    <div class="flex-1"></div>

    <button
      type="button"
      id={"deny-#{@approval.id}"}
      phx-click="decide"
      phx-value-id={@approval.id}
      phx-value-decision="deny"
      class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
    >
      Deny
    </button>
    <button
      :if={@grant}
      type="button"
      id={"deny-off-#{@approval.id}"}
      phx-click="decide"
      phx-value-id={@approval.id}
      phx-value-decision="deny_and_turn_off"
      title={"Deny, and turn #{@grant.name} off so nothing else uses it"}
      class="inline-flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium text-bad transition-colors hover:bg-bad-soft/40"
    >
      <.icon name="hero-no-symbol-micro" class="size-3.5" /> Deny and turn off
    </button>
    """
  end

  # A grant whose ceiling is `:ask` takes no allowance: its uses are
  # allowed once.
  defp always_asks?(%Grant{} = grant), do: Grant.ceiling(grant) == :ask
  defp always_asks?(_none), do: false

  attr :id, :string, required: true
  attr :approval, Approval, required: true
  attr :scope, :string, required: true
  attr :label, :string, required: true
  attr :grant, :any, required: true
  slot :inner_block, required: true

  # One scope an allowance can cover, with how long it lasts.
  defp allow_scope(assigns) do
    ~H"""
    <div id={@id} class="px-3 py-2.5">
      <p class="text-xs font-medium text-ink">{@label}</p>
      <p class="mt-0.5 break-words text-[11px] leading-4 text-muted">{render_slot(@inner_block)}</p>
      <div class="mt-2 flex flex-wrap gap-1">
        <button
          :for={
            {value, label} <- [
              {"10", "10 min"},
              {"60", "1 h"},
              {"grant", "While it's on"}
            ]
          }
          type="button"
          id={"#{@id}-#{value}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision={"allow_#{@scope}"}
          phx-value-minutes={value}
          title={
            if(value == "grant",
              do: "While #{(@grant && @grant.name) || "the grant"} stays on",
              else: nil
            )
          }
          class="inline-flex cursor-pointer items-center rounded-md border border-line bg-deep/60 px-2 py-1 text-[11px] font-medium text-ink transition-colors hover:border-ok/50 hover:bg-ok-soft/40 hover:text-ok-strong"
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  ## Uses

  defp use_card(assigns) do
    approval = assigns.approval
    request? = approval.kind == :request and is_map(approval.request)

    assigns =
      assign(assigns,
        carriers: if(request?, do: carriers(approval.request, assigns.marks), else: []),
        request?: request?
      )

    ~H"""
    <.shell approval={@approval} now={@now} focused={@focused}>
      <:tile><.grant_tile icon={Presets.icon(@grant)} on={true} /></:tile>
      <:meta>
        <span class="font-medium text-ink/80">{(@grant && @grant.name) || "Removed grant"}</span>
        <.dot />
        <span>{if @approval.kind == :connection, do: "Connection", else: "Request"}</span>
        <.retries
          approval={@approval}
          words={"+#{@approval.retries} " <> if(@approval.retries == 1, do: "retry", else: "retries")}
          title="The very same request, sent again while this waited. Your decision answers each."
        />
      </:meta>
      <:title>{@approval.title}</:title>
      <:subtitle :if={@carriers != []}>
        <span
          id={"approval-carriers-#{@approval.id}"}
          class="inline-flex flex-wrap items-center gap-1"
        >
          <.icon name="hero-key-micro" class="size-3.5 text-accent" />
          {(@grant && @grant.name) || "The grant"}'s placeholder is in
          <%= for {name, index} <- Enum.with_index(@carriers) do %>
            <span :if={index > 0} class="-ml-1">,</span>
            <code class="rounded bg-deep px-1 font-mono text-[11px] text-ink">{name}</code>
          <% end %>
        </span>
      </:subtitle>

      <.request_detail
        :if={@request?}
        id={@approval.id}
        request={@approval.request}
        marks={@marks}
      />
      <.evidence approval={@approval} facts={@approval.facts} />

      <:footer>
        <.use_choices
          approval={@approval}
          grant={@grant}
          similar={
            @approval.pattern &&
              if(@approval.kind == :connection,
                do: "Connections like this one",
                else: "Requests like this one"
              )
          }
          similar_detail={@approval.pattern}
          similar_pattern
          every={
            "Any #{if @approval.kind == :connection, do: "connection", else: "request"} it covers, without asking."
          }
        />
      </:footer>
    </.shell>
    """
  end

  # The headers that carry a grant's placeholder: where MWT swaps in its
  # real value once you allow the request.
  defp carriers(request, marks) do
    for {name, segments} <- RequestView.headers(request, marks),
        Enum.any?(segments, &match?({:mark, _label}, &1)),
        uniq: true,
        do: name
  end

  @doc """
  A held request in full: the request line, every header, and the body MWT
  holds, with buttons that copy it as curl, as HTTP, or just the body.
  Placeholders show as the name of their grant, and the headers that carry
  one are marked.
  """
  attr :id, :string, required: true
  attr :request, :map, required: true
  attr :marks, :list, required: true

  def request_detail(assigns) do
    request = assigns.request

    assigns =
      assign(assigns,
        url: RequestView.url(request),
        headers: RequestView.headers(request, assigns.marks),
        body: RequestView.body(request),
        curl: RequestView.curl(request, assigns.marks),
        raw: RequestView.raw(request, assigns.marks)
      )

    ~H"""
    <section
      id={"approval-request-#{@id}"}
      aria-label="The full request"
      class="overflow-hidden rounded-lg border border-line-soft bg-deep/50"
    >
      <div class="flex flex-wrap items-center gap-2 border-b border-line-soft px-3 py-1.5">
        <p class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={@url}>
          <span class="font-semibold">{@request.method}</span> {@url}
        </p>
        <div class="flex items-center gap-1">
          <.copy_button id={"copy-curl-#{@id}"} target={"copy-curl-text-#{@id}"} label="curl" />
          <.copy_button id={"copy-raw-#{@id}"} target={"copy-raw-text-#{@id}"} label="HTTP" />
          <.copy_button
            :if={@body.format not in [:none, :binary]}
            id={"copy-body-#{@id}"}
            target={"copy-body-text-#{@id}"}
            label="Body"
          />
        </div>
      </div>

      <dl
        id={"approval-headers-#{@id}"}
        aria-label="Headers"
        class="grid grid-cols-[minmax(0,auto)_minmax(0,1fr)] gap-x-4 gap-y-0.5 px-3 py-2 font-mono text-[11px] leading-5"
      >
        <%= for {{name, segments}, index} <- Enum.with_index(@headers) do %>
          <dt
            id={"approval-header-#{@id}-#{index}"}
            class={[
              "truncate",
              if(Enum.any?(segments, &match?({:mark, _}, &1)),
                do: "font-semibold text-accent-strong",
                else: "text-muted"
              )
            ]}
          >
            {name}
          </dt>
          <dd class="break-all text-ink">
            <%= for segment <- segments do %>
              <%= case segment do %>
                <% {:text, text} -> %>
                  {text}
                <% {:mark, label} -> %>
                  <span
                    class="inline-flex items-center gap-0.5 rounded border border-accent/30 bg-accent-soft/40 px-1 font-sans text-[10px] font-medium text-accent-strong"
                    title={"The placeholder of #{label}. MWT swaps in the real value only when you allow this."}
                  >
                    <.icon name="hero-key-micro" class="size-2.5" />{label}
                  </span>
              <% end %>
            <% end %>
          </dd>
        <% end %>
      </dl>

      <div
        :if={@body.format != :none}
        id={"approval-body-#{@id}"}
        class="border-t border-line-soft"
      >
        <p class="px-3 pt-1.5 text-[10px] text-faint">
          Body · {format_word(@body.format)} · {body_size(@body)}
        </p>
        <pre class={[
          "max-h-80 overflow-auto whitespace-pre-wrap break-all px-3 pb-3 pt-1 font-mono text-[11px] leading-5",
          if(@body.format == :binary, do: "text-muted", else: "text-ink")
        ]}>{@body.text}</pre>
      </div>
      <p
        :if={@body.format == :none}
        class="border-t border-line-soft px-3 py-1.5 text-[10px] text-faint"
      >
        No body
      </p>

      <pre id={"copy-curl-text-#{@id}"} hidden>{@curl}</pre>
      <pre id={"copy-raw-text-#{@id}"} hidden>{@raw}</pre>
      <pre :if={@body.format not in [:none, :binary]} id={"copy-body-text-#{@id}"} hidden>{@body.text}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :target, :string, required: true
  attr :label, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook="CopyText"
      phx-update="ignore"
      data-copy-target={@target}
      title={"Copy as #{@label}"}
      class="inline-flex cursor-pointer items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium text-muted transition-colors hover:bg-hover hover:text-accent active:scale-[0.97]"
    >
      <.icon name="hero-clipboard-document-micro" class="size-3.5" />
      <span data-copy-label>{@label}</span>
    </button>
    """
  end

  ## MWT's own tools

  # An agent in the VM changing a note, a diagram or a flash card (or,
  # past the hour's limit, adding one): what it would change, as a diff.
  defp tool_card(assigns) do
    tool = assigns.approval.tool || %{}

    assigns =
      assign(assigns,
        tool: tool,
        diff_kind:
          tool[:kind] in [:note, :diagram, :card] && tool[:from] && tool[:to] && tool.kind,
        open_path: tool_path(tool)
      )

    ~H"""
    <.shell approval={@approval} now={@now} focused={@focused}>
      <:tile><.grant_tile icon={Presets.icon(@grant)} on={true} /></:tile>
      <:meta>
        <span class="font-medium text-ink/80">{(@grant && @grant.name) || "Removed grant"}</span>
        <.dot />
        <.asked_by approval={%{@approval | agent: @approval.agent || "An agent"}} />
        <.retries
          approval={@approval}
          words={"+#{@approval.retries} " <> if(@approval.retries == 1, do: "retry", else: "retries")}
          title="The very same call, sent again while this waited. Your decision answers each."
        />
      </:meta>
      <:title>{@approval.title}</:title>
      <:subtitle :if={@tool[:words] || @open_path}>
        <span :if={@tool[:words]} id={"approval-words-#{@approval.id}"}>{@tool.words}</span>
        <span :if={@tool[:words] && @open_path} class="text-faint">·</span>
        <.link :if={@open_path} navigate={@open_path} class="text-accent hover:underline">
          Open it
        </.link>
      </:subtitle>

      <.evidence approval={@approval} facts={@approval.facts} />
      <div :if={@diff_kind}>
        <.difference
          id={"approval-diff-#{@approval.id}"}
          kind={@diff_kind}
          from={@tool.from}
          to={@tool.to}
        />
        <p class="mt-1.5 text-[11px] text-faint">
          What it replaces is kept as a version: restore it from the item's Versions.
        </p>
      </div>

      <:footer>
        <.use_choices
          approval={@approval}
          grant={@grant}
          allow="Allow"
          similar={@diff_kind && "Changes to this #{noun(@tool.kind)}"}
          similar_detail="Further changes to it from the VM go through without asking, each kept as a version."
          every="Any call it covers, without asking."
        />
      </:footer>
    </.shell>
    """
  end

  defp tool_path(%{kind: :note, id: id}) when is_binary(id), do: "/tools/notes?id=#{id}"
  defp tool_path(%{kind: :diagram, id: id}) when is_binary(id), do: "/tools/diagrams?id=#{id}"

  defp tool_path(%{kind: :card, id: id}) when is_binary(id),
    do: "/tools/flashcards/cards?id=#{id}"

  defp tool_path(_tool), do: nil

  defp noun(:note), do: "note"
  defp noun(:diagram), do: "diagram"
  defp noun(:card), do: "flash card"
  defp noun(_kind), do: "item"

  ## Commands

  # Two kinds of command, told apart at a glance, since they deserve
  # different care: an ad-hoc command is text the agent wrote, read it all;
  # a saved command is your own script, in your folder, and the agent only
  # chose when.
  defp command_card(assigns) do
    approval = assigns.approval
    saved? = approval.script_from == :grant

    assigns =
      assign(assigns,
        form: to_form(%{"id" => approval.id, "output" => "send"}, as: :run),
        saved?: saved?,
        name: (assigns.grant && assigns.grant.name) || approval.grant_id,
        # The badge says whose text it is and through which grant.
        facts:
          Enum.reject(approval.facts, fn {label, _} -> label in ["Grant", "Script", "Request"] end)
      )

    ~H"""
    <.shell
      approval={@approval}
      now={@now}
      focused={@focused}
      alarm={not @saved?}
      data-command={if(@saved?, do: "saved", else: "ad-hoc")}
    >
      <:tile>
        <.tile
          icon={if(@saved?, do: "hero-bookmark-square", else: "hero-command-line")}
          tone={if(@saved?, do: :ask, else: :alarm)}
        />
      </:tile>
      <:meta>
        <.command_kind id={"approval-kind-#{@approval.id}"} saved={@saved?} />
        <.help :if={not @saved?} id={"command-help-#{@approval.id}"} label="About ad-hoc commands">
          Ask to run commands never auto-approves: every command an agent writes asks, and only this full card runs it. Save one you trust as a subgrant, to be called by id.
        </.help>
        <.asked_by approval={@approval} />
        <span
          :if={@approval.saved_as}
          id={"approval-saved-#{@approval.id}"}
          class="inline-flex items-center gap-1 rounded border border-accent/30 bg-accent-soft/30 px-1.5 py-px text-[10px] font-medium text-accent-strong"
          title="The agent hears to run it by name next time."
        >
          <.icon name="hero-bookmark-square-micro" class="size-3" /> Saved as {@approval.saved_as}
        </span>
        <.retries
          approval={@approval}
          words={"asked #{@approval.retries + 1} times"}
          title="The agent asked again while this waited."
        />
      </:meta>
      <:title>
        <%= cond do %>
          <% @saved? -> %>
            {@name}
          <% true -> %>
            <span id={"approval-caution-#{@approval.id}"} class="text-bad">
              Written by the agent, not you
            </span>
        <% end %>
      </:title>
      <:subtitle :if={(@saved? and @grant) && @grant.purpose != ""}>
        <span id={"approval-purpose-#{@approval.id}"}>{@grant.purpose}</span>
      </:subtitle>
      <:subtitle :if={not @saved?}>
        Read all of it before you run it: it runs as you, outside the VM, with your files, keys and network. Its reason and MWT's hints are no review.
      </:subtitle>

      <%= if @saved? do %>
        <p
          id={"approval-trust-#{@approval.id}"}
          class="flex items-start gap-2 text-xs leading-5 text-muted"
        >
          <.icon name="hero-shield-check-micro" class="mt-0.5 size-3.5 shrink-0 text-violet" />
          <span>
            {if(@approval.call,
              do:
                "Your own request, as you saved it, sent by MWT with the real value. The agent sent only values.",
              else:
                "Your own script, as you saved it, in your folder. The agent sent no text: it only chose when."
            )}
            <.link
              :if={@grant}
              navigate={~p"/tools/sandbox/grants/#{@grant.id}"}
              class="text-accent underline-offset-2 hover:underline"
            >
              Auto-approve it on its page
            </.link>
            <span :if={@grant}>to skip this card while it's on.</span>
          </span>
        </p>
        <div :if={@approval.values != []} id={"approval-values-#{@approval.id}"}>
          <p class="mb-1.5 text-[11px] text-muted">
            {if(@approval.call,
              do:
                "The agent's values, all it chose. MWT put each in your request, encoded; the host and headers are as you saved them.",
              else:
                "The agent's values, all it chose. Your script reads them as variables; its text is as you saved it."
            )}
          </p>
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 rounded-lg border border-line-soft bg-deep/50 px-3 py-2 font-mono text-xs">
            <%= for {name, value} <- @approval.values do %>
              <dt class="text-violet-strong">${name}</dt>
              <dd
                id={"approval-value-#{@approval.id}-#{name}"}
                class="whitespace-pre-wrap break-all text-ink"
                phx-no-format
              >{value}</dd>
            <% end %>
          </dl>
        </div>
        <details
          id={"approval-script-#{@approval.id}"}
          class="group/script"
          open={@approval.values != []}
        >
          <summary class="flex cursor-pointer list-none items-center gap-1 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3.5 transition-transform group-open/script:rotate-90"
            /> {if(@approval.call, do: "Your request", else: "Your script")}
          </summary>
          <div class="mt-2">
            <.script id={@approval.id} script={@approval.script} label={script_label(@approval)} />
          </div>
        </details>
      <% else %>
        <div
          :if={@approval.suggest_save && is_nil(@approval.saved_as)}
          id={"approval-suggest-save-#{@approval.id}"}
          class="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-accent/30 bg-accent-soft/20 px-3 py-2"
        >
          <.icon name="hero-bookmark-square" class="size-4 shrink-0 text-accent" />
          <div class="min-w-0 flex-1 text-xs leading-5 text-ink">
            <p>
              The agent expects to run this again, and suggests saving it as <span class="font-mono font-semibold">{@approval.suggest_save}</span>. Saved, it runs by name, without the escape hatch.
            </p>
            <p
              :if={@approval.save_for}
              id={"approval-save-for-#{@approval.id}"}
              class="mt-0.5 text-muted"
            >
              For: <span class="italic">“{@approval.save_for}”</span>
            </p>
          </div>
          <.save_button approval={@approval} primary />
        </div>
        <.script id={@approval.id} script={@approval.script} label={script_label(@approval)} />
      <% end %>

      <.evidence approval={@approval} facts={@facts} hints={@approval.hints} />

      <:footer>
        <.form
          for={@form}
          id={"command-form-#{@approval.id}"}
          phx-submit="run_command"
          class="flex w-full flex-wrap items-center gap-x-3 gap-y-2"
        >
          <input type="hidden" name={@form[:id].name} value={@approval.id} />
          <.pills
            id={"command-output-#{@approval.id}"}
            name={@form[:output].name}
            options={[{"send", "Output to the agent"}, {"review", "Show me the output first"}]}
            checked="send"
            tone={if(@saved?, do: "violet", else: "bad")}
          />
          <button
            type="submit"
            id={"run-command-#{@approval.id}"}
            class={[
              "inline-flex cursor-pointer items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-semibold text-white transition-all hover:brightness-110 active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2",
              if(@saved?,
                do: "bg-violet focus-visible:outline-violet",
                else: "bg-bad focus-visible:outline-bad"
              )
            ]}
          >
            <.icon name="hero-play-micro" class="size-3.5" />
            {if(@saved?, do: "Run #{@name}", else: "Run once, as you")}
          </button>
          <div class="flex-1"></div>
          <.save_button
            :if={not @saved? and is_nil(@approval.saved_as) and is_nil(@approval.suggest_save)}
            approval={@approval}
          />
          <button
            :if={not @saved?}
            type="button"
            id={"simpler-#{@approval.id}"}
            phx-click="decide"
            phx-value-id={@approval.id}
            phx-value-decision="simpler"
            title="Decline, and tell the agent to send the smallest command that gets the raw data, and to do the rest in the VM."
            class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-warn/60 hover:bg-warn-soft/40 hover:text-warn-strong"
          >
            <.icon name="hero-scissors-micro" class="size-3.5" /> Ask for a simpler one
          </button>
          <.decline_button approval={@approval} />
        </.form>
      </:footer>
    </.shell>
    """
  end

  attr :id, :string, required: true
  attr :saved, :boolean, required: true

  # What kind of command it is, the first thing a card and its line in the
  # history say.
  defp command_kind(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center gap-1 rounded px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide",
        if(@saved,
          do: "border border-violet/35 bg-violet/10 text-violet",
          else: "border border-bad/45 bg-bad-soft/60 text-bad"
        )
      ]}
    >
      <.icon
        name={if(@saved, do: "hero-bookmark-square-micro", else: "hero-exclamation-triangle-micro")}
        class="size-3"
      />
      {if(@saved, do: "Subgrant", else: "Ad-hoc command")}
    </span>
    """
  end

  defp output_card(assigns) do
    assigns = assign(assigns, run: assigns.approval.run)

    ~H"""
    <.shell
      approval={@approval}
      now={@now}
      focused={@focused}
      alarm={true}
      title_class="font-mono text-[13px]"
    >
      <:tile><.tile icon="hero-document-text" tone={:alarm} /></:tile>
      <:meta>
        <.asked_by approval={@approval} />
        <.dot />
        <span>Ran on this machine; its output waits for you</span>
      </:meta>
      <:title>{@approval.title}</:title>
      <:subtitle>
        <.exit_status id={"output-exit-#{@approval.id}"} run={@run} /> · {run_words(@run)}
      </:subtitle>

      <.held id={"output-held-#{@approval.id}"} run={@run} />
      <.output id={@approval.id} run={@run} />
      <details id={"output-script-#{@approval.id}"} class="group/script">
        <summary class="flex cursor-pointer list-none items-center gap-1 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3.5 transition-transform group-open/script:rotate-90"
          /> The command
        </summary>
        <div class="mt-2">
          <.script
            id={"#{@approval.id}-ran"}
            script={@approval.script}
            label={script_label(@approval)}
          />
        </div>
      </details>

      <:footer>
        <button
          type="button"
          id={"send-output-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="send_output"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-ok px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
        >
          <.icon name="hero-paper-airplane-micro" class="size-3.5" /> Send it to the agent
        </button>
        <div class="flex-1"></div>
        <button
          type="button"
          id={"keep-output-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="keep_output"
          class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
        >
          Keep it
        </button>
      </:footer>
    </.shell>
    """
  end

  @doc "Commands running on this machine, each with a Stop button."
  attr :running, :list, required: true
  attr :now, DateTime, required: true

  def running(assigns) do
    ~H"""
    <section id="running-commands" aria-label="Running on this machine" class="space-y-2">
      <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
        <span class="relative flex size-2">
          <span class="absolute inline-flex size-full animate-ping rounded-full bg-bad/60"></span>
          <span class="relative inline-flex size-2 rounded-full bg-bad"></span>
        </span>
        Running on this machine
      </h2>
      <div
        :for={approval <- @running}
        id={"running-#{approval.id}"}
        class="flex items-center gap-3 rounded-xl border border-bad/30 bg-panel px-4 py-2.5"
      >
        <.icon name="hero-command-line" class="size-4 shrink-0 text-bad" />
        <div class="min-w-0 flex-1">
          <p class="truncate font-mono text-xs text-ink" title={approval.script}>
            {approval.title}
          </p>
          <p class="truncate text-[11px] text-faint">
            {who(approval)} · in {approval.dir} · output {if approval.run.output_to == :send,
              do: "to the agent",
              else: "to you first"}
            <span :if={approval.run.stopped} class="text-bad">· stopping…</span>
          </p>
        </div>
        <span class="shrink-0 text-[11px] text-muted">
          started
          <.clock id={"running-for-#{approval.id}"} since={approval.run.started_at} now={@now} />
          · limit {HostCommand.seconds_words(approval.timeout)}
        </span>
        <button
          :if={is_nil(approval.call)}
          type="button"
          id={"stop-command-#{approval.id}"}
          phx-click="stop_command"
          phx-value-id={approval.id}
          disabled={approval.run.stopped}
          class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-bad/40 px-2.5 py-1 text-xs font-medium text-bad transition-colors hover:bg-bad-soft/40 disabled:cursor-default disabled:opacity-50"
        >
          <.icon name="hero-stop-micro" class="size-3.5" /> Stop
        </button>
      </div>
    </section>
    """
  end

  attr :approval, Approval, required: true
  attr :now, DateTime, required: true

  defp decided_command(assigns) do
    ~H"""
    <li id={"decided-#{@approval.id}"}>
      <details class="group/decided">
        <summary class="flex cursor-pointer list-none items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/40 [&::-webkit-details-marker]:hidden">
          <.decided_badge approval={@approval} />
          <div class="min-w-0 flex-1">
            <p class="flex min-w-0 items-center gap-2">
              <.command_kind
                id={"decided-kind-#{@approval.id}"}
                saved={@approval.script_from == :grant}
              />
              <span class="truncate font-mono text-xs text-ink">{@approval.title}</span>
            </p>
            <p class="truncate text-[11px] text-faint">
              {who(@approval)} · on this machine · {decision_words(@approval)}
            </p>
          </div>
          <span class="shrink-0 text-[11px] text-faint">
            <.clock id={"decided-at-#{@approval.id}"} since={@approval.decided_at} now={@now} />
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="size-3.5 shrink-0 text-faint transition-transform group-open/decided:rotate-180"
          />
        </summary>
        <div class="space-y-3 px-4 pb-4">
          <.script
            id={"decided-#{@approval.id}"}
            script={@approval.script}
            label={script_label(@approval)}
          />
          <p class="text-[11px] text-muted">
            <span :if={@approval.dir}>In <span class="font-mono">{@approval.dir}</span></span>
            <span :if={@approval.call}>Sent to <span class="font-mono">{@approval.call.host}</span></span>
            <span :if={@approval.reason}>
              · the agent said: <span class="italic">“{@approval.reason}”</span>
            </span>
          </p>
          <.output
            :if={@approval.run && @approval.run.state == :done}
            id={"decided-#{@approval.id}"}
            run={@approval.run}
          />
        </div>
      </details>
    </li>
    """
  end

  defp script_label(%Approval{call: %{}}), do: "Exactly what MWT sends"
  defp script_label(_approval), do: "Exactly what runs, with bash -lc"

  attr :id, :string, required: true
  attr :script, :string, required: true
  attr :label, :string, default: "Exactly what runs, with bash -lc"

  defp script(assigns) do
    ~H"""
    <section
      id={"command-script-#{@id}"}
      aria-label="The command"
      class="overflow-hidden rounded-lg border border-bad/25 bg-deep/60"
    >
      <div class="flex items-center gap-2 border-b border-line-soft px-3 py-1">
        <.icon name="hero-command-line-micro" class="size-3.5 text-faint" />
        <p class="flex-1 text-[11px] text-muted">{@label}</p>
        <.copy_button
          id={"copy-script-#{@id}"}
          target={"copy-script-text-#{@id}"}
          label={if(@label == "Exactly what MWT sends", do: "Request", else: "Script")}
        />
      </div>
      <pre
        id={"command-script-text-#{@id}"}
        class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-3 py-2.5 font-mono text-[12px] leading-5 text-ink"
      >{@script}</pre>
      <pre id={"copy-script-text-#{@id}"} hidden>{@script}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true

  # Why an output that would have gone to the agent waits: what MWT found
  # in it, by line, never the text.
  defp held(assigns) do
    ~H"""
    <section
      :if={Map.get(@run, :findings, []) != []}
      id={@id}
      class="rounded-lg border border-bad/40 bg-bad-soft/30 px-3 py-2.5"
    >
      <p class="flex items-center gap-1.5 text-xs font-semibold text-bad">
        <.icon name="hero-key-micro" class="size-3.5" />
        {if Map.get(@run, :held),
          do: "Held: it may hold a credential",
          else: "It may hold a credential"}
      </p>
      <ul class="mt-1.5 space-y-0.5 text-[11px] leading-4 text-ink">
        <li :for={finding <- @run.findings}>{MWTClient.Sandbox.Inbound.words(finding)}</li>
      </ul>
      <p class="mt-1.5 text-[11px] leading-4 text-muted">
        Auto-approval never sends it. Read it below: send it if it is what the agent should see, or keep it.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true

  defp output(assigns) do
    ~H"""
    <section
      id={"command-output-#{@id}"}
      aria-label="Its output"
      class="overflow-hidden rounded-lg border border-line-soft bg-deep/60"
    >
      <div class="flex items-center gap-2 border-b border-line-soft px-3 py-1">
        <.icon name="hero-document-text-micro" class="size-3.5 text-faint" />
        <p class="flex-1 text-[11px] text-muted">
          Output
          <span class="ml-1 text-faint">
            <.exit_status id={"exit-#{@id}"} run={@run} />
            · {bytes(@run.bytes)}{if @run.cut > 0,
              do: ", #{bytes(@run.cut)} cut from the middle"}
          </span>
        </p>
        <.copy_button
          :if={@run.output != ""}
          id={"copy-output-#{@id}"}
          target={"copy-output-text-#{@id}"}
          label="Output"
        />
      </div>
      <p :if={@run.error} class="px-3 py-2.5 text-xs text-bad">{@run.error}</p>
      <p :if={!@run.error and @run.output == ""} class="px-3 py-2.5 text-[11px] text-faint">
        It printed nothing.
      </p>
      <pre
        :if={@run.output != ""}
        id={"command-output-text-#{@id}"}
        class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-3 py-2.5 font-mono text-[11px] leading-5 text-ink"
      >{@run.output}</pre>
      <pre :if={@run.output != ""} id={"copy-output-text-#{@id}"} hidden>{@run.output}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true

  defp exit_status(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "font-mono font-semibold",
        if(@run.exit == 0, do: "text-ok-strong", else: "text-bad")
      ]}
    >
      {cond do
        @run.error -> "didn't start"
        @run.stopped -> "stopped (exit #{@run.exit})"
        @run.timed_out -> "hit its limit (exit #{@run.exit})"
        true -> "exit #{@run.exit}"
      end}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :hints, :list, required: true

  defp hints(assigns) do
    ~H"""
    <div
      :if={@hints != []}
      id={@id}
      class="rounded-lg border border-warn/35 bg-warn-soft/25 px-3 py-2"
    >
      <p class="mb-1 flex items-center gap-1 text-[11px] font-medium text-warn-strong">
        <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /> Worth a second look
      </p>
      <ul class="space-y-1">
        <li :for={hint <- @hints} class="flex gap-1.5 text-xs leading-5 text-ink">
          <span class="text-warn-strong">•</span><span>{hint}</span>
        </li>
      </ul>
      <p class="mt-1 text-[11px] leading-4 text-faint">
        MWT's guesses from the text alone, not a review: a command can do anything its text allows.
      </p>
    </div>
    """
  end

  defp run_words(run) do
    seconds = DateTime.diff(run.finished_at, run.started_at)
    "took #{HostCommand.seconds_words(seconds)} · #{bytes(run.bytes)} of output"
  end

  ## Activations

  defp activation_card(assigns) do
    approval = assigns.approval

    durations =
      Enum.uniq_by(
        [{approval.minutes, "#{minutes_words(approval.minutes)} (asked)"}] ++
          [{15, "15 min"}, {60, "1 h"}, {240, "4 h"}, {"until_off", "Until off"}],
        &elem(&1, 0)
      )

    assigns =
      assign(assigns,
        durations: durations,
        form: to_form(%{"id" => approval.id}, as: :ask)
      )

    ~H"""
    <.shell approval={@approval} now={@now} focused={@focused}>
      <:tile>
        <.tile icon={if @grant, do: Presets.icon(@grant), else: "hero-sparkles"} tone={:ask} />
      </:tile>
      <:meta>
        <.asked_by approval={@approval} />
        <.dot />
        <span>Asks for access</span>
        <.retries
          approval={@approval}
          words={"asked #{@approval.retries + 1} times"}
          title="The agent asked again while this waited."
        />
      </:meta>
      <:title>
        <%= cond do %>
          <% @grant && @approval.proposal && Grant.to_review?(@grant) -> %>
            Review “{@grant.name}”, {if @approval.proposal.updated, do: "changed", else: "proposed"} by {@approval.agent}
          <% @grant && Grant.to_review?(@grant) -> %>
            Review “{@grant.name}” before it can turn on
          <% @grant -> %>
            Turn on {@grant.name} for {minutes_words(@approval.minutes)}
          <% true -> %>
            Access you haven't set up
        <% end %>
      </:title>
      <:subtitle :if={@grant && @grant.purpose != ""}>{@grant.purpose}</:subtitle>

      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <dl
          :if={@grant}
          id={"approval-facts-#{@approval.id}"}
          class="grid h-fit grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs"
        >
          <dt class="text-muted">Type</dt>
          <dd class="text-ink">{Presets.type_name(@grant)}</dd>
          <dt :if={@approval.proposal && @approval.proposal.parent_name} class="text-muted">
            Under
          </dt>
          <dd :if={@approval.proposal && @approval.proposal.parent_name} class="text-ink">
            {@approval.proposal.parent_name}
          </dd>
          <dt class="text-muted">The VM gets</dt>
          <dd class="break-words leading-5 text-ink">
            {Instructions.usage(@grant) |> String.replace_prefix("use: ", "")}
          </dd>
        </dl>
        <div :if={is_nil(@grant)} id={"approval-need-#{@approval.id}"}>
          <p class="max-h-48 overflow-y-auto overscroll-contain break-words rounded-lg border border-line-soft bg-deep/50 px-3 py-2 text-xs leading-5 text-ink">
            {@approval.need}
          </p>
          <p class="mt-1.5 text-[11px] leading-4 text-faint">
            No grant meets this yet. Set one up and it turns on for {minutes_words(@approval.minutes)}.
          </p>
        </div>
        <.claims id={"approval-claims-#{@approval.id}"} claims={@approval.claims} />
      </div>

      <:footer>
        <%= cond do %>
          <% @grant && Grant.to_review?(@grant) -> %>
            <.link
              patch={~p"/tools/sandbox/grants/#{@grant.id}"}
              id={"review-ask-#{@approval.id}"}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
            >
              <.icon name="hero-eye-micro" class="size-3.5" /> Review on its page
            </.link>
            <span id={"review-note-#{@approval.id}"} class="text-[11px] leading-4 text-muted">
              It is saved, off, until you accept it there. Declining removes it.
            </span>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
          <% @grant -> %>
            <.form
              for={@form}
              id={"activation-form-#{@approval.id}"}
              phx-submit="turn_on_ask"
              class="flex w-full flex-wrap items-center gap-x-3 gap-y-2"
            >
              <input type="hidden" name={@form[:id].name} value={@approval.id} />
              <.pills
                id={"activation-minutes-#{@approval.id}"}
                name={@form[:minutes].name}
                options={@durations}
                checked={@approval.minutes}
              />
              <.pills
                :if={Grant.auto_approvable?(@grant) and not Grant.always_auto?(@grant)}
                id={"activation-uses-#{@approval.id}"}
                name={@form[:uses].name}
                options={[{"ask", "Ask each time"}, {"all", "Auto-approve"}]}
                checked="ask"
              />
              <span
                :if={Grant.ask_to_run?(@grant)}
                id={"activation-asks-only-#{@approval.id}"}
                class="inline-flex items-center gap-1 text-[11px] text-warn-strong"
              >
                <.icon name="hero-hand-raised-micro" class="size-3.5" />
                It only lets the agent ask: you approve every run
              </span>
              <button
                type="submit"
                id={"turn-on-ask-#{@approval.id}"}
                class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
              >
                <.icon name="hero-bolt-micro" class="size-3.5" /> Turn on
              </button>
              <div class="flex-1"></div>
              <.decline_button approval={@approval} />
            </.form>
          <% true -> %>
            <button
              type="button"
              id={"setup-ask-#{@approval.id}"}
              phx-click="open_add_grant"
              phx-value-approval={@approval.id}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Set it up…
            </button>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
        <% end %>
      </:footer>
    </.shell>
    """
  end

  attr :approval, Approval, required: true
  attr :primary, :boolean, default: false

  # Saves a command run through Ask to run commands as a subgrant: the add
  # dialog, filled in from the card. The card keeps waiting.
  defp save_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"save-command-#{@approval.id}#{if @primary, do: "-suggested"}"}
      phx-click="save_command"
      phx-value-id={@approval.id}
      title="Save it as a subgrant: agents then call it by id, without the escape hatch. Turn what varies into parameters. This card still waits."
      class={[
        "inline-flex cursor-pointer items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
        if(@primary,
          do: "bg-accent text-white hover:brightness-110",
          else:
            "border border-line bg-panel text-ink hover:border-accent/50 hover:bg-accent-soft/30 hover:text-accent"
        )
      ]}
    >
      <.icon name="hero-bookmark-square-micro" class="size-3.5" /> Save as a subgrant
    </button>
    """
  end

  attr :approval, Approval, required: true

  defp decline_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"decline-ask-#{@approval.id}"}
      phx-click="decide"
      phx-value-id={@approval.id}
      phx-value-decision="decline"
      class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
    >
      Decline
    </button>
    """
  end

  ## Parts

  attr :id, :string, required: true
  attr :facts, :list, required: true

  defp facts(assigns) do
    ~H"""
    <div id={@id}>
      <p class="mb-1 flex items-center gap-1 text-[11px] font-medium text-muted">
        <.icon name="hero-eye-micro" class="size-3.5 text-faint" /> What MWT saw
      </p>
      <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
        <%= for {label, value} <- @facts do %>
          <dt class="text-muted">{label}</dt>
          <dd class="break-words font-mono text-[11px] leading-5 text-ink">{value}</dd>
        <% end %>
      </dl>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :claims, :list, required: true

  defp claims(assigns) do
    ~H"""
    <div
      :if={@claims != []}
      id={@id}
      class="rounded-lg border border-dashed border-line bg-deep/60 px-3 py-2"
    >
      <p class="mb-1 flex items-center gap-1 text-[11px] font-medium text-muted">
        <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3.5 text-faint" />
        The agent says <span class="text-faint">· not verified</span>
      </p>
      <ul
        id={"#{@id}-list"}
        tabindex="0"
        aria-label="What the agent says"
        class="-mr-1.5 max-h-56 space-y-1 overflow-y-auto overscroll-contain pr-1.5 focus-visible:outline-2 focus-visible:outline-accent"
      >
        <li :for={{label, text} <- @claims} class="text-xs leading-5">
          <span class="mr-1.5 text-[11px] text-faint">{label}</span>
          <span class="whitespace-pre-wrap break-words italic text-muted">“{text}”</span>
        </li>
      </ul>
    </div>
    """
  end

  # The agent and the thread it asked from, for one-line rows.
  defp who(%Approval{} = approval) do
    case Approval.asked_from(approval) do
      nil -> approval.agent
      from -> "#{approval.agent} #{from}"
    end
  end

  attr :approval, Approval, required: true

  defp decided_badge(%{approval: %Approval{kind: :activation}} = assigns) do
    ~H"""
    <span class={[
      "inline-flex w-[4.5rem] shrink-0 items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      case @approval.status do
        :allowed -> "bg-violet/15 text-violet-strong"
        :timed_out -> "bg-warn-soft/60 text-warn-strong"
        _ -> "bg-hover text-muted"
      end
    ]}>
      {case @approval.status do
        :allowed -> "Turned on"
        :timed_out -> "Gave up"
        _ -> "Declined"
      end}
    </span>
    """
  end

  defp decided_badge(%{approval: %Approval{kind: :command}} = assigns) do
    ~H"""
    <span class={[
      "inline-flex w-[4.5rem] shrink-0 items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      cond do
        @approval.run && @approval.run.state == :done -> "bg-bad-soft/50 text-bad"
        @approval.status == :timed_out -> "bg-warn-soft/60 text-warn-strong"
        true -> "bg-hover text-muted"
      end
    ]}>
      {cond do
        @approval.run && @approval.run.state == :done -> "Ran"
        @approval.status == :timed_out -> "Gave up"
        true -> "Declined"
      end}
    </span>
    """
  end

  defp decided_badge(assigns) do
    ~H"""
    <.outcome_badge outcome={@approval.status} />
    """
  end

  ## Words

  defp history_title(%Approval{kind: :activation} = approval, grants) do
    case approval.grant_id && grants[approval.grant_id] do
      %Grant{name: name} -> "#{approval.agent} asked for #{name}"
      nil -> "#{approval.agent} asked for: #{approval.need || "a grant since removed"}"
    end
  end

  defp history_title(approval, _grants), do: approval.title

  defp grant_name(_grants, %Approval{kind: :activation, grant_id: nil}), do: "No grant yet"

  defp grant_name(grants, %Approval{grant_id: id}) do
    case grants[id] do
      nil -> "Removed grant"
      grant -> grant.name
    end
  end

  @doc "What a decision did, in a few words."
  def decision_words(%Approval{kind: :command, status: :timed_out, stage: :output, run: run}),
    do: "#{exit_words(run)}, output kept: not released in time"

  def decision_words(%Approval{kind: :command, decision: {:run, to}, run: run}),
    do: "#{exit_words(run)}, output #{if to == :send, do: "sent to the agent", else: "to you"}"

  def decision_words(%Approval{kind: :command, decision: :auto, run: run}),
    do: "#{exit_words(run)}, auto-approved"

  def decision_words(%Approval{kind: :command, decision: :send_output, run: run}),
    do: "#{exit_words(run)}, you sent the output"

  def decision_words(%Approval{kind: :command, decision: :keep_output, run: run}),
    do: "#{exit_words(run)}, you kept the output"

  def decision_words(%Approval{status: :timed_out}), do: "gave up waiting"
  def decision_words(%Approval{decision: :allow_once}), do: "allowed once"

  def decision_words(%Approval{decision: {:allow, :similar, duration}}),
    do: "allowed similar #{duration_words(duration)}"

  def decision_words(%Approval{decision: {:allow, :all, duration}}),
    do: "allowed every use #{duration_words(duration)}"

  def decision_words(%Approval{decision: :deny}), do: "denied"
  def decision_words(%Approval{decision: :deny_and_turn_off}), do: "denied, grant turned off"
  def decision_words(%Approval{decision: :grant_off}), do: "refused: the grant turned off"
  def decision_words(%Approval{decision: :isolated}), do: "refused: the VM was isolated"
  def decision_words(%Approval{decision: :decline}), do: "declined"
  def decision_words(%Approval{decision: :simpler}), do: "declined, asked for a simpler one"

  def decision_words(%Approval{decision: {:turn_on, minutes, uses}}) do
    "turned on #{duration_words(minutes)}" <>
      if(uses == :all, do: ", auto-approve", else: ", each use asks")
  end

  def decision_words(%Approval{decision: {:set_up, _id}, minutes: minutes}),
    do: "set up and turned on for #{minutes_words(minutes)}"

  def decision_words(%Approval{}), do: "decided"

  defp exit_words(%{error: error}) when is_binary(error), do: "didn't start"
  defp exit_words(%{state: :running}), do: "running"
  defp exit_words(%{stopped: true, exit: exit}), do: "stopped (exit #{exit})"
  defp exit_words(%{timed_out: true, exit: exit}), do: "hit its limit (exit #{exit})"
  defp exit_words(%{exit: exit}), do: "exit #{exit}"

  defp duration_words(:grant), do: "while the grant is on"
  defp duration_words(:until_off), do: "until turned off"
  defp duration_words(minutes), do: "for " <> minutes_words(minutes)

  defp minutes_words(60), do: "1 h"
  defp minutes_words(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes_words(minutes), do: "#{minutes} min"

  defp format_word(:json), do: "JSON"
  defp format_word(:graphql), do: "GraphQL"
  defp format_word(:form), do: "Form"
  defp format_word(:git), do: "git"
  defp format_word(:text), do: "Text"
  defp format_word(:binary), do: "Binary"

  defp body_size(%{complete?: true, kept: kept}), do: bytes(kept)

  defp body_size(%{size: size, kept: kept}) when is_integer(size),
    do: "first #{bytes(kept)} of #{bytes(size)}"

  defp body_size(%{kept: kept}), do: "first #{bytes(kept)}"
end
