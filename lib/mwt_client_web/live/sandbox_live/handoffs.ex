defmodule MWTClientWeb.SandboxLive.Handoffs do
  @moduledoc """
  The handoffs page: work you reviewed in the VM and asked an agent to hand
  off, waiting to land on your branch, and what landed before.

  A handoff isn't where you review the work: that happened in the VM, in
  Zed, before you asked for it. Here you decide how it ends, and only so:
  land it (`Handoffs.accept/3`), as one commit with its changes, on a
  branch you choose, the task's base unless you choose another, or on a
  new `mwt/NAME` branch from it; send it back to its thread with a note;
  or close it without landing. Any branch takes it while its changes
  apply there without conflicts; a checked-out one needs no pending
  tracked work.

  So one handoff's page has two parts. On the right, kept in view, your
  decision: the three choices, each with what it needs and the button
  that does it, or, once decided, what was decided and the way back
  (Undo, Reopen, send back after landing). On the left, what you decide
  it from: where it comes from and where it is in the VM (Open in Zed),
  the agent's notes, what lands (its commits and files, the diff when you
  ask for it) and its history.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.SandboxLive.Components

  alias MWTClient.Git.FileDiff
  alias MWTClient.Sandbox.{Handoff, HandoffRecords, Handoffs}
  alias MWTClient.Search

  # Rows a page of the list shows: a screenful or two of handoffs to
  # decide on or look back at.
  @per_page 20

  @typedoc """
  Where you are in the list: which half (`filter`: `"open"`, those
  waiting to land, or `"closed"`), the words searched, the page, whether
  archived handoffs count, and then between which days (`from` and `to`,
  each a `YYYY-MM-DD` or empty, on this machine's clock, both included).
  """
  @type place :: %{
          filter: String.t(),
          term: String.t(),
          page: pos_integer(),
          archived?: boolean(),
          from: String.t(),
          to: String.t()
        }

  @doc "The list as it first shows: waiting to land, unsearched, the archived left out."
  @spec place() :: place()
  def place, do: %{filter: "open", term: "", page: 1, archived?: false, from: "", to: ""}

  @doc """
  The list searched as the search form says: its words, whether archived
  handoffs count and between which days. It starts again from its first
  page. A field the form doesn't send keeps what it was.
  """
  @spec searched(place(), map()) :: place()
  def searched(place, params) do
    %{
      place
      | term: params |> Map.get("term", place.term) |> to_string() |> String.slice(0, 200),
        archived?: Map.get(params, "archived", to_string(place.archived?)) == "true",
        from: day(Map.get(params, "from", place.from)),
        to: day(Map.get(params, "to", place.to)),
        page: 1
    }
  end

  defp day(text) do
    case Date.from_iso8601(to_string(text)) do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _} -> ""
    end
  end

  @doc """
  What `HandoffRecords.page/2` is asked for the list at `place`. Its days
  run from the start of `from` until the start of the day after `to`.
  """
  @spec query(place(), DateTime.t()) :: HandoffRecords.query()
  def query(place, now) do
    %{
      half: if(place.filter == "closed", do: :done, else: :waiting),
      terms: Search.terms(place.term),
      archived?: place.archived?,
      from: day_start(place.from, 0),
      to: day_start(place.to, 1),
      page: place.page,
      per_page: @per_page,
      now: now
    }
  end

  # The moment a day of this machine's calendar starts, `later` days after
  # `text`; nil for no day. A day whose midnight a clock change skips
  # starts at the hour after.
  defp day_start(text, later) do
    case Date.from_iso8601(text) do
      {:ok, date} ->
        date = Date.add(date, later)

        Enum.find_value([~T[00:00:00], ~T[01:00:00]], fn time ->
          case date |> NaiveDateTime.new!(time) |> NaiveDateTime.to_erl() |> local_to_utc() do
            [utc | _] -> utc |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
            [] -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp local_to_utc(local), do: :calendar.local_time_to_universal_time_dst(local)

  attr :place, :map, required: true, doc: "where you are in the list (`t:place/0`)"

  attr :listing, :map,
    required: true,
    doc: "the page of the list shown (`HandoffRecords.page/2`), nil while one is open"

  attr :view, :any, required: true, doc: "the handoff open, with what was worked out, or nil"
  attr :diff, :boolean, required: true, doc: "whether its diff is shown"
  attr :note_form, :any, required: true

  attr :decision, :string,
    default: "land",
    doc: "the decision shown for a handoff waiting for one: land, send_back or close"

  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <%= if @view do %>
      <.detail
        view={@view}
        filter={@place.filter}
        diff={@diff}
        note_form={@note_form}
        decision={@decision}
        vm={@vm}
        now={@now}
      />
    <% else %>
      <.handoff_list :if={@listing} place={@place} listing={@listing} now={@now} />
    <% end %>
    """
  end

  ## The list

  attr :place, :map, required: true
  attr :listing, :map, required: true
  attr :now, DateTime, required: true

  # Only the rows of the page shown get the words around the match.
  defp handoff_list(assigns) do
    %{place: place, listing: listing} = assigns
    terms = Search.terms(place.term)
    total = if place.filter == "closed", do: listing.done, else: listing.waiting

    assigns =
      assign(assigns,
        filter: place.filter,
        term: place.term,
        waiting: listing.waiting,
        done: listing.done,
        total: total,
        shown: Enum.map(listing.handoffs, &{&1, Handoff.snippet(&1, terms)}),
        page: listing.page,
        pages: listing.pages,
        per_page: @per_page,
        archive_after: HandoffRecords.archive_after_days()
      )

    ~H"""
    <.page_header id="handoffs-header" title="Handoffs">
      <:help>
        You review an agent's work in the VM, in Zed, and ask it to hand off once it's done: it commits, as you, catches up with the branch the task started from and runs mwt handoff. Its commits then wait here to land. Landing syncs what you reviewed as one commit: on the task's base, or any branch you choose where its changes apply without conflicts, or on a new mwt/ branch from it. Nothing is written into your repository until you land it. Every handoff is kept; one landed or closed more than {@archive_after} days ago is archived, and shows when you include the archived ones.
      </:help>
    </.page_header>

    <section id="handoffs" class="overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line-soft bg-deep/40 px-4 py-2.5">
        <.link
          patch={~p"/tools/sandbox/handoffs"}
          id="handoffs-filter-open"
          class={[
            "flex items-center gap-1.5 text-[13px] transition-colors",
            if(@filter != "closed",
              do: "font-semibold text-ink",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <.icon name="hero-arrow-down-on-square" class="size-4" /> {@waiting} Waiting to land
        </.link>
        <.link
          patch={~p"/tools/sandbox/handoffs?filter=closed"}
          id="handoffs-filter-closed"
          class={[
            "flex items-center gap-1.5 text-[13px] transition-colors",
            if(@filter == "closed",
              do: "font-semibold text-ink",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <.icon name="hero-check" class="size-4" /> {@done} Landed or closed
        </.link>
        <form
          id="handoff-search"
          phx-change="search_handoffs"
          phx-submit="search_handoffs"
          class="ml-auto flex flex-wrap items-center justify-end gap-2"
          autocomplete="off"
        >
          <label
            id="handoff-archived"
            title={"Handoffs landed or closed more than #{@archive_after} days ago"}
            class={[
              "flex cursor-pointer select-none items-center gap-1.5 rounded-md border px-2 py-1 text-[11px] transition-colors",
              if(@place.archived?,
                do: "border-accent/50 bg-accent-soft/40 text-accent-strong",
                else: "border-line text-muted hover:border-accent/40 hover:text-ink"
              )
            ]}
          >
            <input type="hidden" name="archived" value="false" />
            <input
              type="checkbox"
              name="archived"
              value="true"
              id="handoff-archived-toggle"
              checked={@place.archived?}
              class="size-3.5 accent-[var(--color-accent)]"
            /> Include archived
          </label>
          <div
            :if={@place.archived?}
            id="handoff-days"
            class="flex items-center gap-1.5 text-[11px] text-muted"
          >
            <span>From</span>
            <input
              type="date"
              name="from"
              id="handoff-from"
              value={@place.from}
              max={@place.to != "" && @place.to}
              class="rounded-md border border-line bg-panel px-1.5 py-1 text-[11px] text-ink outline-none transition-colors focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
            />
            <span>to</span>
            <input
              type="date"
              name="to"
              id="handoff-to"
              value={@place.to}
              min={@place.from != "" && @place.from}
              class="rounded-md border border-line bg-panel px-1.5 py-1 text-[11px] text-ink outline-none transition-colors focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
            />
          </div>
          <div class="relative w-full sm:w-64">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
            />
            <input
              type="text"
              name="term"
              id="handoff-search-term"
              value={@term}
              placeholder="Search every word in them"
              phx-debounce="120"
              class="w-full rounded-md border border-line bg-panel py-1.5 pl-7 pr-7 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
            />
            <button
              :if={@term != ""}
              type="button"
              id="handoff-search-clear"
              phx-click="clear_handoff_search"
              title="Clear search"
              class="absolute right-1.5 top-1/2 flex size-5 -translate-y-1/2 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
            >
              <.icon name="hero-x-mark-micro" class="size-3.5" />
            </button>
          </div>
        </form>
      </header>
      <ul id="handoff-list" class="divide-y divide-line-soft">
        <li :if={@shown == []}>
          <.empty id="handoffs-empty" icon="hero-arrow-down-on-square">
            <%= cond do %>
              <% @term != "" and @filter == "closed" -> %>
                No handoff landed or closed mentions “{@term}”.
              <% @term != "" -> %>
                No handoff waiting to land mentions “{@term}”.
              <% @filter == "closed" and @place.archived? -> %>
                Nothing landed or closed in these days.
              <% @filter == "closed" -> %>
                Nothing landed or closed in the last {@archive_after} days.
              <% true -> %>
                Nothing waiting to land. Review an agent's work in the VM, then ask it to hand off.
            <% end %>
          </.empty>
        </li>
        <li :for={{handoff, snippet} <- @shown} id={"handoff-row-#{handoff.id}"}>
          <.link
            patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
            class="group flex items-start gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
          >
            <.state_icon status={handoff.status} class="mt-0.5 size-4" />
            <div class="min-w-0 flex-1">
              <p class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class="truncate text-[13px] font-semibold text-ink group-hover:text-accent">
                  {handoff.title}
                </span>
                <span
                  :if={handoff.status == :sent_back}
                  class="rounded-full border border-warn/40 px-1.5 py-px text-[10px] font-medium text-warn-strong"
                >
                  Sent back
                </span>
                <span
                  :if={handoff.status == :withdrawn}
                  id={"handoff-withdrawn-#{handoff.id}"}
                  class="rounded-full border border-warn/40 px-1.5 py-px text-[10px] font-medium text-warn-strong"
                  title="Its agent took it back for more work: it lands once handed off again"
                >
                  Taken back
                </span>
                <span
                  :if={HandoffRecords.archived?(handoff, @now)}
                  id={"handoff-archived-#{handoff.id}"}
                  class="rounded-full border border-line px-1.5 py-px text-[10px] font-medium text-faint"
                  title={"Landed or closed more than #{@archive_after} days ago"}
                >
                  Archived
                </span>
              </p>
              <p class="mt-1 truncate text-[11px] text-faint">
                #{handoff.id} · {Handoffs.who(handoff)}{if handoff.thread,
                  do: " · " <> handoff.thread} · {handoff.project}
                <span class="font-mono">{handoff.source.branch}</span>
                <%= if handoff.status == :accepted do %>
                  → <span class="font-mono">{handoff.onto}</span>
                <% else %>
                  · based on <span class="font-mono">{Handoff.base_label(handoff)}</span>
                <% end %>
                · {verb(handoff)} {ago(handoff.updated_at || handoff.opened_at, @now)}
              </p>
              <.snippet :if={snippet} id={"handoff-snippet-#{handoff.id}"} parts={snippet} />
            </div>
            <div class="flex shrink-0 items-center gap-3 text-[11px]">
              <span
                :if={
                  (handoff.stats[:behind] || 0) > 0 and
                    handoff.status in [:open, :sent_back, :withdrawn]
                }
                id={"handoff-behind-#{handoff.id}"}
                class="flex items-center gap-1 text-warn-strong"
              >
                <.icon name="hero-clock-micro" class="size-3.5" /> Behind base
              </span>
              <span
                :if={
                  (handoff.stats[:conflicts] || 0) > 0 and
                    handoff.status in [:open, :sent_back, :withdrawn]
                }
                class="flex items-center gap-1 text-bad"
                title="Conflicts with its target branch as it is now"
              >
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /> conflicts
              </span>
              <span class="font-mono text-ok-strong">+{handoff.stats[:added] || 0}</span>
              <span class="font-mono text-bad">−{handoff.stats[:removed] || 0}</span>
              <span class="flex items-center gap-1 text-faint" title="Files changed">
                <.icon name="hero-document-micro" class="size-3.5" />{handoff.stats[:files] || 0}
              </span>
            </div>
          </.link>
        </li>
      </ul>
      <p
        :if={@filter == "closed" and not @place.archived?}
        id="handoffs-archived-hint"
        class="border-t border-line-soft px-4 py-2 text-[11px] text-faint"
      >
        Older ones are archived, not gone: include the archived to list and search them.
      </p>
      <.pages
        :if={@pages > 1}
        name="handoffs"
        label="Pages of handoffs"
        page={@page}
        pages={@pages}
        per_page={@per_page}
        total={@total}
        event="handoffs_page"
        class="border-t border-line-soft bg-deep/30 px-4 py-2"
      />
    </section>
    """
  end

  # The words around a search match in what the row doesn't show, the
  # match itself marked.
  attr :id, :string, required: true
  attr :parts, :any, required: true, doc: "`{before, match, after}`"

  defp snippet(%{parts: {before, match, rest}} = assigns) do
    assigns = assign(assigns, before: before, match: match, rest: rest)

    ~H"""
    <p id={@id} class="mt-1 truncate text-[11px] text-muted">
      {@before}<mark class="rounded-sm bg-warn-soft px-0.5 text-warn-strong">{@match}</mark>{@rest}
    </p>
    """
  end

  ## One handoff

  attr :view, :map, required: true
  attr :filter, :string, required: true, doc: "the half of the list it goes back to"
  attr :diff, :boolean, required: true
  attr :note_form, :any, required: true
  attr :decision, :string, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  # What you decide, on the right and kept in view; what you decide it
  # from, on the left.
  defp detail(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff, facts: assigns.view.facts)

    ~H"""
    <div id={"handoff-#{@handoff.id}"} class="space-y-5">
      <div>
        <.link
          patch={
            if(@filter == "closed",
              do: ~p"/tools/sandbox/handoffs?filter=closed",
              else: ~p"/tools/sandbox/handoffs"
            )
          }
          id="handoff-back"
          class="inline-flex items-center gap-1 text-[12px] text-muted transition-colors hover:text-ink"
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" /> Handoffs
        </.link>
        <h1 id="handoff-title" class="mt-2 text-xl font-semibold tracking-tight text-ink">
          {@handoff.title} <span class="font-normal text-faint">#{@handoff.id}</span>
        </h1>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-[13px] text-muted">
          <.state_pill status={@handoff.status} />
          <span>
            <span class="font-medium text-ink">{Handoffs.who(@handoff)}</span>
            handed off {count(@handoff.stats[:commits] || 0, "commit")} from
            <code class="rounded bg-deep px-1.5 py-0.5 font-mono text-[12px] text-ink">
              {@handoff.source.branch}
            </code>
            <%= if @handoff.status == :accepted do %>
              that landed on
              <code class="rounded bg-accent-soft/50 px-1.5 py-0.5 font-mono text-[12px] text-accent-strong">
                {@handoff.onto}
              </code>
            <% end %>
            <span class="text-faint">· {ago(@handoff.opened_at, @now)}</span>
          </span>
        </div>
        <p id="handoff-baseline" class="mt-1.5 text-[12px] text-muted">
          Based on <span class="font-mono">{Handoff.base_label(@handoff)}</span>
          <span :if={@handoff.base_commit} class="font-mono"> at {String.slice(
            @handoff.base_commit,
            0,
            7
          )}</span>
          <span
            :if={@facts && @facts.behind > 0 && @handoff.status in [:open, :sent_back, :withdrawn]}
            id="handoff-behind"
            class="ml-2 text-warn-strong"
          >
            Behind base · {count(@facts.behind, "commit")}
          </span>
        </p>
      </div>

      <p
        :if={@view.error}
        id="handoff-error"
        class="flex items-start gap-2 rounded-lg border border-bad/40 bg-bad-soft/30 px-3 py-2 text-xs text-bad"
      >
        <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
        {@view.error}
      </p>

      <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_21rem]">
        <.decision
          view={@view}
          note_form={@note_form}
          decision={@decision}
          now={@now}
        />
        <div id="handoff-information" class="min-w-0 space-y-4 lg:col-start-1 lg:row-start-1">
          <.details view={@view} vm={@vm} />
          <.description handoff={@handoff} now={@now} />
          <.what_lands handoff={@handoff} facts={@facts} diff={@view.diff} shown?={@diff} />
          <.timeline handoff={@handoff} now={@now} />
        </div>
      </div>
    </div>
    """
  end

  attr :handoff, :map, required: true
  attr :now, DateTime, required: true

  defp description(assigns) do
    ~H"""
    <section
      id="handoff-description"
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <.markdown_view :if={@handoff.body != ""} id="handoff-body" text={@handoff.body}>
        <:header>
          <span class="font-semibold text-ink">{Handoffs.who(@handoff)}'s notes</span>
          <span class="truncate text-faint">{ago(@handoff.opened_at, @now)}</span>
        </:header>
      </.markdown_view>
      <%= if @handoff.body == "" do %>
        <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2 text-[12px]">
          <span class="font-semibold text-ink">{Handoffs.who(@handoff)}'s notes</span>
          <span class="text-faint">{ago(@handoff.opened_at, @now)}</span>
        </header>
        <p class="px-4 py-3 text-[13px] italic text-faint">No notes given.</p>
      <% end %>
    </section>
    """
  end

  attr :handoff, :map, required: true
  attr :now, DateTime, required: true

  defp timeline(assigns) do
    ~H"""
    <section id="handoff-history">
      <p class="mb-2 text-[10px] font-semibold uppercase tracking-wide text-faint">History</p>
      <ol id="handoff-timeline" class="relative ml-4 space-y-3 border-l border-line-soft pl-5">
        <li
          :for={{event, i} <- Enum.with_index(@handoff.timeline)}
          id={"handoff-event-#{i}"}
          class="relative"
        >
          <span class={[
            "absolute -left-[1.95rem] flex size-6 items-center justify-center rounded-full border border-line bg-panel",
            event_tone(event.kind)
          ]}>
            <.icon name={event_icon(event.kind)} class="size-3.5" />
          </span>
          <p class="text-[12px] leading-6 text-muted">
            {event.text}
            <span class="text-faint">· {ago(event.at, @now)}</span>
          </p>
          <.markdown
            :if={event[:note] not in [nil, ""]}
            text={event.note}
            class="mt-1 rounded-lg border border-line-soft bg-deep/40 px-3 py-2 text-[12px] leading-5"
          />
          <p
            :if={event[:delivery]}
            id={"handoff-event-#{i}-delivery"}
            class={[
              "mt-1 flex items-start gap-1.5 text-[11px] leading-5",
              if(event.delivery.said?, do: "text-ok-strong", else: "text-faint")
            ]}
          >
            <.icon
              name={
                if(event.delivery.said?,
                  do: "hero-chat-bubble-left-right-micro",
                  else: "hero-chat-bubble-left-ellipsis-micro"
                )
              }
              class="mt-1 size-3.5 shrink-0"
            />
            <span>{delivery_words(event.delivery)}</span>
          </p>
        </li>
      </ol>
    </section>
    """
  end

  @doc "Whether a send back's note reached its thread, in words."
  def delivery_words(%{said?: true}), do: "The note went to its thread in Zed."

  def delivery_words(%{why: why}),
    do: "#{why} The agent reads the note when it runs mwt handoffs."

  defp event_icon(:opened), do: "hero-arrow-down-on-square-micro"
  defp event_icon(:updated), do: "hero-arrow-up-circle-micro"
  defp event_icon(:sent_back), do: "hero-arrow-uturn-left-micro"
  defp event_icon(:withdrawn), do: "hero-wrench-screwdriver-micro"
  defp event_icon(:caught_up), do: "hero-arrow-path-micro"
  defp event_icon(:accepted), do: "hero-check-micro"
  # Saved as a branch, which older MWTs offered.
  defp event_icon(:saved), do: "hero-bookmark-micro"
  defp event_icon(:closed), do: "hero-x-mark-micro"
  defp event_icon(_reopened), do: "hero-arrow-path-micro"

  defp event_tone(:accepted), do: "text-violet-strong"
  defp event_tone(:closed), do: "text-bad"
  defp event_tone(:sent_back), do: "text-warn-strong"
  defp event_tone(:withdrawn), do: "text-warn-strong"
  defp event_tone(_), do: "text-faint"

  attr :view, :map, required: true
  attr :vm, :any, required: true

  # Where it comes from and where it is in the VM, in one row.
  defp details(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff)

    ~H"""
    <dl
      id="handoff-details"
      class="grid gap-x-6 gap-y-3 rounded-xl border border-line bg-panel px-4 py-3 text-[12px] sm:grid-cols-2"
    >
      <div class="min-w-0">
        <dt class="text-[10px] font-semibold uppercase tracking-wide text-faint">Project</dt>
        <dd class="truncate text-ink" title={@handoff.repo}>{@handoff.project}</dd>
      </div>
      <div :if={@handoff.thread} class="min-w-0">
        <dt class="text-[10px] font-semibold uppercase tracking-wide text-faint">Thread</dt>
        <dd id="handoff-thread" class="truncate text-ink" title={Handoffs.who(@handoff)}>
          {@handoff.thread}
        </dd>
      </div>
      <div class="min-w-0">
        <dt class="text-[10px] font-semibold uppercase tracking-wide text-faint">
          Handed off from
        </dt>
        <dd class="truncate font-mono text-muted">
          {@handoff.source.branch} at {String.slice(@handoff.head, 0, 7)}
          <span class="font-sans text-faint">· rev {@handoff.revision}</span>
        </dd>
      </div>
      <.in_the_vm
        :if={@handoff.status in [:open, :sent_back, :withdrawn]}
        handoff={@handoff}
        worktree={@view.worktree}
        vm={@vm}
      />
    </dl>
    """
  end

  attr :handoff, :map, required: true

  attr :worktree, :any,
    required: true,
    doc:
      "where its branch is in the VM now, nil when in no worktree, `:unknown` when the VM can't say"

  attr :vm, :any, required: true

  # The way back to where the work is looked at: its worktree in the VM.
  defp in_the_vm(assigns) do
    ~H"""
    <div id="handoff-vm" class="min-w-0">
      <dt class="flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
        In the VM
        <.help id="handoff-vm-help" label="Where to look at it again">
          You reviewed this work in the VM, before you asked for the handoff. To look again, open its slot in Zed: its commits are there, and the thread that made them. What you land is the revision handed off, below, even if work went on there since.
        </.help>
      </dt>
      <dd>
        <%= cond do %>
          <% is_map(@worktree) -> %>
            <span class="flex items-center gap-2">
              <span id="handoff-worktree" class="truncate font-mono text-muted" title={@worktree.path}>
                {@worktree.slot || Path.basename(@worktree.path)}
              </span>
              <button
                type="button"
                id="handoff-open-zed"
                phx-click="open_handoff_worktree"
                disabled={@vm.status != :running}
                class="flex shrink-0 cursor-pointer items-center gap-1 rounded px-1.5 py-0.5 text-[11px] text-accent transition-colors hover:bg-accent-soft/40 disabled:cursor-not-allowed disabled:opacity-50"
              >
                <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Open in Zed
              </button>
            </span>
          <% @worktree == :unknown -> %>
            <span
              id="handoff-worktree"
              class="block truncate font-mono text-muted"
              title={@handoff.source.top}
            >
              {Path.basename(@handoff.source.top)}
            </span>
            <span class="text-[11px] text-faint">
              {if @vm.status != :running,
                do: "Start the VM to open it in Zed.",
                else: "MWT couldn't ask the VM where its branch is now."}
            </span>
          <% true -> %>
            <span id="handoff-worktree" class="text-[11px] leading-4 text-muted">
              In no worktree now: a thread in a free slot puts it back with <code class="font-mono">mwt worktree resume {@handoff.source.branch}</code>.
            </span>
        <% end %>
      </dd>
    </div>
    """
  end

  ## Your decision

  attr :view, :map, required: true
  attr :note_form, :any, required: true
  attr :decision, :string, required: true
  attr :now, DateTime, required: true

  # The three ways a handoff ends, and only those: land it (where and how),
  # send it back to its thread with a note, or close it without landing.
  # Once decided, what was decided, and the way back.
  defp decision(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff, accept: assigns.view.accept)

    ~H"""
    <aside
      id="handoff-decision"
      class="lg:sticky lg:top-4 lg:col-start-2 lg:row-start-1"
      aria-label="Your decision"
    >
      <div class={[
        "overflow-hidden rounded-xl border bg-panel shadow-lg shadow-black/5 dark:shadow-black/30",
        case @handoff.status do
          :accepted -> "border-violet/40"
          :closed -> "border-line"
          _ -> "border-accent/40"
        end
      ]}>
        <header class="border-b border-line-soft bg-deep/40 px-4 py-2.5">
          <p class="text-[10px] font-semibold uppercase tracking-wide text-faint">Your decision</p>
          <p id="handoff-decision-state" class="text-[13px] font-medium text-ink">
            {decision_state(@handoff)}
          </p>
        </header>

        <%= case @handoff.status do %>
          <% :accepted -> %>
            <div class="space-y-3 px-4 py-3">
              <p id="handoff-accepted" class="flex items-start gap-2 text-[12px] text-muted">
                <.icon name="hero-check-circle" class="size-4 shrink-0 text-violet-strong" />
                <span>
                  {upcase_first(Handoffs.accepted_words(@handoff.accepted))}{if @handoff.accepted.worktree,
                    do: ", at " <> home(@handoff.accepted.worktree)}, {ago(
                    @handoff.accepted.at,
                    @now
                  )}.
                </span>
              </p>
              <.button
                id="handoff-undo"
                class="w-full justify-center"
                phx-click="undo_handoff"
                phx-value-id={@handoff.id}
                data-confirm="Take it back out? Your branch goes back to where it was before."
              >
                <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Undo the landing
              </.button>
            </div>
            <.send_back handoff={@handoff} note_form={@note_form} after_landing />
          <% :closed -> %>
            <div class="space-y-3 px-4 py-3">
              <p class="text-[12px] text-muted">
                Closed without landing: nothing reached your repository.
              </p>
              <.button
                id="handoff-reopen"
                class="w-full justify-center"
                phx-click="reopen_handoff"
                phx-value-id={@handoff.id}
              >
                <.icon name="hero-arrow-path-micro" class="size-3.5" /> Reopen
              </.button>
            </div>
          <% _waiting -> %>
            <div
              id="handoff-choices"
              role="tablist"
              class="grid grid-cols-3 gap-1 border-b border-line-soft p-2"
            >
              <.choice
                value="land"
                label="Land"
                icon="hero-arrow-down-on-square-micro"
                chosen={@decision}
                tone="ok"
              />
              <.choice
                value="send_back"
                label="Send back"
                icon="hero-arrow-uturn-left-micro"
                chosen={@decision}
                tone="warn"
              />
              <.choice
                value="close"
                label="Close"
                icon="hero-x-mark-micro"
                chosen={@decision}
                tone="bad"
              />
            </div>
            <%= case @decision do %>
              <% "send_back" -> %>
                <.send_back handoff={@handoff} note_form={@note_form} />
              <% "close" -> %>
                <.close_it handoff={@handoff} />
              <% _land -> %>
                <.land view={@view} />
            <% end %>
        <% end %>
      </div>
    </aside>
    """
  end

  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :chosen, :string, required: true
  attr :tone, :string, required: true

  defp choice(assigns) do
    ~H"""
    <button
      type="button"
      id={"handoff-choose-#{@value}"}
      role="tab"
      aria-selected={to_string(@value == @chosen)}
      phx-click="handoff_decision"
      phx-value-choice={@value}
      class={[
        "flex cursor-pointer flex-col items-center gap-1 rounded-lg px-2 py-2 text-[12px] font-medium transition-colors",
        if(@value == @chosen,
          do:
            case @tone do
              "ok" -> "bg-ok-soft text-ok-strong ring-1 ring-ok/40"
              "warn" -> "bg-warn-soft text-warn-strong ring-1 ring-warn/40"
              _bad -> "bg-bad-soft text-bad ring-1 ring-bad/40"
            end,
          else: "text-muted hover:bg-hover hover:text-ink"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </button>
    """
  end

  defp decision_state(%Handoff{status: :accepted}), do: "Landed"
  defp decision_state(%Handoff{status: :closed}), do: "Closed without landing"

  defp decision_state(%Handoff{status: :withdrawn}),
    do: "None yet: its thread took it back for more work"

  defp decision_state(%Handoff{status: :sent_back}),
    do: "Sent back: waiting for its thread, or for you"

  defp decision_state(_handoff), do: "Waiting for you: land it, send it back, or close it"

  attr :view, :map, required: true

  # Where and how it lands, whether it can, and the button that ends the
  # handoff by landing it.
  defp land(assigns) do
    assigns =
      assign(assigns,
        handoff: assigns.view.handoff,
        accept: assigns.view.accept,
        hints: (assigns.view.facts && assigns.view.facts.hints) || []
      )

    ~H"""
    <%= if @handoff.status == :withdrawn do %>
      <div id="handoff-withdrawn" class="flex items-start gap-2.5 px-4 py-4 text-[12px] text-muted">
        <.icon name="hero-wrench-screwdriver" class="size-4 shrink-0 text-warn-strong" />
        <p>
          Its thread took it back for more work, so it can't land as it is. Its next handoff updates this one, ready to land.
        </p>
      </div>
    <% else %>
      <.form
        for={@accept.form}
        id="handoff-accept"
        phx-change="accept_change"
        phx-submit="accept_handoff"
        class="space-y-3 px-4 py-3"
      >
        <label class="flex flex-col gap-1">
          <span class="text-[11px] font-medium text-muted">Land on</span>
          <select
            id="handoff-onto"
            name={@accept.form[:onto].name}
            title="The branch it lands on, or the new branch starts from"
            class="w-full rounded-md border border-line bg-deep px-2 py-1.5 font-mono text-xs text-ink outline-none transition-colors focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          >
            <option
              :for={target <- @accept.branches}
              value={target.branch}
              selected={target.branch == @accept.onto}
            >
              {target.branch}{if target.branch == @handoff.base_branch,
                do: " · base"}{if target.worktree,
                do: " · checked out"}
            </option>
          </select>
        </label>
        <div class="flex flex-col items-start gap-1">
          <span class="text-[11px] font-medium text-muted">As</span>
          <.pills
            id="handoff-how"
            name={@accept.form[:how].name}
            options={[{"commit", "New commit"}, {"branch", "New branch"}]}
            checked={@accept.how}
          />
        </div>
        <div
          :if={match?({:ok, %{fast_forward?: true, commits: n}} when n > 1, @accept.preview)}
          class="flex flex-col items-start gap-1"
        >
          <span class="text-[11px] font-medium text-muted">Its commits</span>
          <.pills
            id="handoff-as"
            name={@accept.form[:as].name}
            options={[{"as_is", "As they are"}, {"one_commit", "As one"}]}
            checked={@accept.as}
          />
        </div>
        <label :if={@accept.how == "branch"} class="flex flex-col gap-1">
          <span class="text-[11px] font-medium text-muted">Branch name</span>
          <span class="flex items-stretch overflow-hidden rounded-md border border-line bg-deep transition-colors focus-within:border-accent/60 focus-within:ring-2 focus-within:ring-accent/15">
            <span
              id="handoff-branch-prefix"
              class="flex select-none items-center border-r border-line bg-panel px-2 font-mono text-xs text-faint"
            >
              {@accept.prefix}
            </span>
            <input
              type="text"
              id="handoff-new-branch"
              name={@accept.form[:name].name}
              value={@accept.name}
              autocomplete="off"
              spellcheck="false"
              phx-debounce="300"
              class="min-w-0 flex-1 bg-transparent px-2 py-1.5 font-mono text-xs text-ink outline-none placeholder:text-faint"
            />
          </span>
        </label>

        <.readiness preview={@accept.preview} handoff={@handoff} />

        <div :if={@hints != []} id="handoff-hints" class="text-[11px]">
          <p class="mb-1 font-medium text-muted">Runs on your machine once landed</p>
          <ul class="space-y-1">
            <li :for={hint <- @hints} class="flex items-start gap-1.5 leading-4 text-warn-strong">
              <.icon name="hero-light-bulb-micro" class="mt-px size-3.5 shrink-0" />
              <span>{hint}</span>
            </li>
          </ul>
        </div>

        <.button
          type="submit"
          id="handoff-accept-button"
          variant="primary"
          class="w-full justify-center"
          disabled={not ready?(@accept.preview)}
          phx-disable-with="Landing…"
        >
          <.icon name="hero-arrow-down-on-square-micro" class="size-3.5" />
          {land_label(@accept)}
        </.button>
        <p class="text-center text-[11px] leading-4 text-faint">
          Landing ends the handoff, and its slot is free for the next task. The VM's branches stay as they are; its next fetch brings what landed.
        </p>
      </.form>
    <% end %>
    """
  end

  defp land_label(%{how: "branch", prefix: prefix, name: name}), do: "Create #{prefix}#{name}"
  defp land_label(%{onto: onto}), do: "Land on #{onto}"

  attr :preview, :any, required: true
  attr :handoff, :map, required: true

  # Whether it can land where you chose, and what that makes: one commit
  # on that branch, or on a new one; or what stops it.
  defp readiness(assigns) do
    assigns = assign(assigns, tone: tone(assigns.preview))

    ~H"""
    <div
      id="handoff-preview"
      class={[
        "flex min-w-0 items-start gap-2.5 rounded-lg px-3 py-2.5",
        case @tone do
          :ok -> "bg-ok-soft/40"
          :bad -> "bg-bad-soft/30"
          _ -> "bg-warn-soft/30"
        end
      ]}
    >
      <.icon
        name={
          case @tone do
            :ok -> "hero-check-circle-micro"
            :bad -> "hero-exclamation-triangle-micro"
            _ -> "hero-pause-circle-micro"
          end
        }
        class={[
          "mt-0.5 size-4 shrink-0",
          case @tone do
            :ok -> "text-ok-strong"
            :bad -> "text-bad"
            _ -> "text-warn-strong"
          end
        ]}
      />
      <div class="min-w-0 text-[12px]">
        <%= case @preview do %>
          <% nil -> %>
            <p class="text-muted">Working out what landing would do…</p>
          <% {:error, words} -> %>
            <p class="font-semibold text-ink">It can't land there</p>
            <p class="text-muted">{words}</p>
          <% {:ok, %{conflicts: [_ | _] = files} = plan} -> %>
            <div id="handoff-conflicts">
              <p class="font-semibold text-ink">
                Its changes conflict with your <span class="font-mono">{plan.from}</span>
              </p>
              <p class="text-muted">The same lines changed there, in:</p>
              <ul class="mt-1 space-y-0.5">
                <li :for={file <- files} class="truncate font-mono text-[11px] text-bad">
                  {file}
                </li>
              </ul>
              <%= if own_branch?(@handoff, plan) do %>
                <p class="mt-1.5 text-muted">
                  Its thread resolves them: one click sends it back to catch up with {plan.from}, and it hands off again by itself once its checks pass.
                </p>
                <.catch_up_buttons handoff={@handoff} plan={plan} here={false} />
              <% else %>
                <p class="mt-1 text-muted">
                  Choose another branch, or
                  <button
                    type="button"
                    phx-click="handoff_decision"
                    phx-value-choice="send_back"
                    class="cursor-pointer text-accent hover:underline"
                  >send it back</button>
                  so its thread rebases onto {plan.from} and hands off again.
                </p>
              <% end %>
            </div>
          <% {:ok, %{up_to_date?: true} = plan} -> %>
            <p class="font-semibold text-ink">
              Your <span class="font-mono">{plan.from}</span> has all of it already
            </p>
            <p class="text-muted">
              There is nothing to land there: choose another branch, or close it.
            </p>
          <% {:ok, plan} -> %>
            <p id="handoff-merges" class="font-semibold text-ink">
              <%= if plan.new_branch? do %>
                Ready to create <span class="font-mono">{plan.branch}</span>
              <% else %>
                Ready to land on <span class="font-mono">{plan.branch}</span>
              <% end %>
            </p>
            <p :if={plan.as == :as_is} id="handoff-as-is" class="text-muted">
              {if plan.commits == 1,
                do: "Its commit, as it is: the one its checks ran on,",
                else: "Its #{plan.commits} commits, as they are: the ones its checks ran on,"} on top of <span class="font-mono">{plan.from}</span>{if plan.worktree,
                do: ", checked out at " <> home(plan.worktree)}, which hasn't moved since (a fast-forward).
              <%= if plan.new_branch? do %>
                Your existing branches and working files stay as they are.
              <% end %>
            </p>
            <p :if={plan.as == :one_commit} id="handoff-one-commit" class="text-muted">
              One commit, “{@handoff.title}”, with its changes, on top of <span class="font-mono">{plan.from}</span>{if plan.worktree,
                do: ", checked out at " <> home(plan.worktree)}.
              <%= if plan.new_branch? do %>
                Your existing branches and working files stay as they are.
              <% end %>
              <%= if plan.fast_forward? do %>
                The VM's branch keeps its own commits, which your branch then won't have.
              <% end %>
            </p>
            <div :if={plan.behind > 0} id="handoff-untested" class="mt-1">
              <p class="text-warn-strong">
                {plan.from} moved since its checks ran: it has {count(plan.behind, "commit")} this task wasn't built or tested with. Its changes apply cleanly on top, as one commit.
              </p>
              <.catch_up_buttons
                :if={own_branch?(@handoff, plan)}
                handoff={@handoff}
                plan={plan}
                here={true}
              />
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :handoff, :map, required: true
  attr :plan, :map, required: true
  attr :here, :boolean, required: true, doc: "whether MWT can catch it up itself: no conflicts"

  # The standard ways to bring it up to date with its own branch: MWT
  # replays its commits there itself, when they apply cleanly; or its
  # thread catches up, resolves and hands off again, which runs its checks.
  defp catch_up_buttons(assigns) do
    ~H"""
    <div id="handoff-catch-up" class="mt-2 flex flex-wrap items-center gap-1.5">
      <button
        :if={@here}
        type="button"
        id="handoff-catch-up-here"
        phx-click="catch_up_handoff"
        phx-value-id={@handoff.id}
        phx-disable-with="Catching up…"
        title={"MWT replays its commits onto #{@plan.from} in its own store, never in your repository: a new revision that lands as it is. Its checks ran before that."}
        class="inline-flex cursor-pointer items-center gap-1 rounded-md bg-accent px-2.5 py-1 text-[11px] font-semibold text-white transition-all hover:brightness-110"
      >
        <.icon name="hero-arrow-path-micro" class="size-3.5" /> Catch up here
      </button>
      <button
        type="button"
        id="handoff-ask-catch-up"
        phx-click="ask_catch_up_handoff"
        phx-value-id={@handoff.id}
        phx-disable-with="Sending…"
        title={"Sends it back with a note MWT writes: catch up with #{@plan.from}, resolve, run the checks and hand off again, without waiting for you."}
        class={[
          "inline-flex cursor-pointer items-center gap-1 rounded-md px-2.5 py-1 text-[11px] font-semibold transition-all",
          if(@here,
            do: "border border-line bg-panel text-ink hover:border-accent/50 hover:text-accent",
            else: "bg-accent text-white hover:brightness-110"
          )
        ]}
      >
        <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Ask its thread to catch up
      </button>
      <.help id="handoff-catch-up-help" label="About catching up">
        <%= if @here do %>
          Catch up here: MWT replays its commits onto {@plan.from} in its own store, never in your repository, keeping their authors and messages, as a new revision that lands as it is. Its checks ran on them before that. Ask its thread to catch up: its next handoff does the same in the VM and runs the checks, and it hands off again by itself.
        <% else %>
          Its thread runs mwt handoff, which rebases onto {@plan.from} and stops at the conflicts; it resolves them keeping what both sides meant, runs the checks and hands off again by itself: the note MWT sends says that is your ask.
        <% end %>
      </.help>
    </div>
    """
  end

  # Catching up is with the branch it is on, landing there.
  defp own_branch?(handoff, plan),
    do:
      is_binary(handoff.base_branch) and plan.branch == handoff.base_branch and
        not plan.new_branch?

  defp tone({:ok, %{up_to_date?: true}}), do: :wait
  defp tone({:ok, %{conflicts: [_ | _]}}), do: :bad
  defp tone({:ok, _}), do: :ok
  defp tone(_), do: :wait

  defp ready?({:ok, %{up_to_date?: true}}), do: false
  defp ready?({:ok, %{conflicts: []}}), do: true
  defp ready?(_), do: false

  attr :handoff, :map, required: true
  attr :note_form, :any, required: true

  attr :after_landing, :boolean,
    default: false,
    doc: "sent back for more work after it landed, as you tried it on your machine"

  defp send_back(assigns) do
    ~H"""
    <.form
      for={@note_form}
      id="handoff-send-back"
      phx-submit="send_back_handoff"
      class={["space-y-2 px-4 py-3", @after_landing && "border-t border-line-soft bg-deep/30"]}
    >
      <input type="hidden" name="handoff" value={@handoff.id} />
      <p class="flex items-center gap-1.5 text-[12px] text-muted">
        <%= if @after_landing do %>
          Found something on your machine? Send it back for more work.
        <% else %>
          What should its thread do next?
        <% end %>
        <.help id="handoff-send-back-help" label="About sending it back">
          <%= if @after_landing do %>
            What landed stays where it went (Undo takes it out). The thread reads your note with mwt handoffs and works on it, uncommitted for you to review in the VM; once you ask, its next handoff updates this one.
          <% else %>
            The handoff stays open. The thread reads your note with mwt handoffs and works on it, uncommitted for you to review in the VM; once you ask, its next handoff updates this one.
          <% end %>
        </.help>
      </p>
      <textarea
        name={@note_form[:note].name}
        id="handoff-note"
        rows={if @after_landing, do: "2", else: "5"}
        placeholder={"A note for #{if @handoff.thread, do: "the thread \"#{@handoff.thread}\"", else: "the agent"}: what to change, or to catch up again"}
        class={[input_classes(), "min-h-[3.25rem] text-xs"]}
      >{@note_form[:note].value}</textarea>
      <.button
        type="submit"
        id="handoff-send-back-button"
        variant={if @after_landing, do: "secondary", else: "primary"}
        class="w-full justify-center"
      >
        <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Send back to its thread
      </.button>
      <p :if={not @after_landing} class="text-center text-[11px] leading-4 text-faint">
        Nothing lands; its next handoff updates this one.
      </p>
    </.form>
    """
  end

  attr :handoff, :map, required: true

  defp close_it(assigns) do
    ~H"""
    <div id="handoff-close-panel" class="space-y-3 px-4 py-3">
      <p class="text-[12px] leading-5 text-muted">
        Drop it without landing: nothing reaches your repository. Its branch stays in the VM, and its slot is free for the next task. If it only came too soon, say so in its thread: it undoes its commits and keeps the work.
      </p>
      <.button
        id="handoff-close"
        type="button"
        variant="danger"
        class="w-full justify-center"
        phx-click="close_handoff"
        phx-value-id={@handoff.id}
        data-confirm="Close it without landing it?"
      >
        <.icon name="hero-x-mark-micro" class="size-3.5" /> Close without landing
      </.button>
      <p class="text-center text-[11px] leading-4 text-faint">Reopen brings it back.</p>
    </div>
    """
  end

  ## What lands: its commits and files, and the diff when asked for

  attr :handoff, :map, required: true
  attr :facts, :any, required: true
  attr :diff, :any, required: true
  attr :shown?, :boolean, required: true

  defp what_lands(assigns) do
    ~H"""
    <section id="handoff-what" class="overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-line-soft bg-deep/40 px-4 py-2">
        <p class="text-[12px] font-semibold text-ink">
          {if @handoff.status == :accepted, do: "What landed", else: "What lands"}
        </p>
        <p :if={@facts} class="text-[12px] text-muted">
          {count(length(@facts.commits), "commit")} · {count(length(@facts.files), "file")}
          <span class="ml-1 font-mono text-ok-strong">+{@facts.added}</span>
          <span class="font-mono text-bad">−{@facts.removed}</span>
        </p>
        <.link
          :if={@facts}
          patch={
            if @shown?,
              do: ~p"/tools/sandbox/handoffs?id=#{@handoff.id}",
              else: ~p"/tools/sandbox/handoffs?id=#{@handoff.id}&diff=1"
          }
          id="handoff-diff-toggle"
          class="ml-auto inline-flex items-center gap-1 text-[12px] text-muted transition-colors hover:text-ink"
        >
          <.icon
            name={if @shown?, do: "hero-eye-slash-micro", else: "hero-eye-micro"}
            class="size-3.5"
          />
          {if @shown?, do: "Hide the diff", else: "Show the diff"}
        </.link>
      </header>

      <p :if={is_nil(@facts)} class="px-4 py-3 text-[13px] text-faint">
        MWT couldn't read what it brings.
      </p>

      <%= if @facts do %>
        <ol id="handoff-commits" class="divide-y divide-line-soft">
          <li
            :for={commit <- @facts.commits}
            id={"handoff-commit-#{String.slice(commit.sha, 0, 10)}"}
            class="flex items-center gap-3 px-4 py-2"
          >
            <.icon name="hero-circle-stack-micro" class="size-3.5 shrink-0 text-faint" />
            <p class="min-w-0 flex-1 truncate text-[13px] text-ink">
              {commit.subject}
              <span class="text-[11px] text-faint">
                · {commit.author}{if commit.at,
                  do: " · " <> Calendar.strftime(commit.at, "%Y-%m-%d %H:%M")}
              </span>
            </p>
            <code class="shrink-0 rounded bg-deep px-1.5 py-0.5 font-mono text-[11px] text-muted">
              {String.slice(commit.sha, 0, 10)}
            </code>
          </li>
        </ol>
        <ul
          id="handoff-file-list"
          class="divide-y divide-line-soft/60 border-t border-line-soft bg-deep/20"
        >
          <li
            :for={file <- @facts.files}
            class="flex items-center gap-3 px-4 py-1.5 font-mono text-[11px]"
          >
            <.icon name="hero-document-micro" class="size-3.5 shrink-0 text-faint" />
            <span class="min-w-0 flex-1 truncate text-ink" title={file.path}>{file.path}</span>
            <%= if is_nil(file.added) do %>
              <span class="text-faint">binary</span>
            <% else %>
              <span class="text-ok-strong">+{file.added}</span>
              <span class="text-bad">−{file.removed}</span>
            <% end %>
          </li>
        </ul>
      <% end %>

      <.files :if={@shown?} diff={@diff} />
    </section>
    """
  end

  attr :diff, :any, required: true

  defp files(assigns) do
    ~H"""
    <div id="handoff-files" class="space-y-3 border-t border-line-soft bg-deep/20 p-3">
      <p :if={is_nil(@diff)} class="text-[13px] text-faint">The change couldn't be read.</p>
      <%= if @diff do %>
        <section
          :for={{file, i} <- Enum.with_index(@diff.files)}
          id={"handoff-file-#{i}"}
          class="overflow-hidden rounded-lg border border-line bg-panel"
        >
          <header class="flex items-center gap-3 border-b border-line-soft bg-deep/40 px-4 py-2">
            <span class="min-w-0 flex-1 truncate font-mono text-[12px] text-ink" title={file.path}>
              {file.path}
            </span>
            <span class="font-mono text-[11px] text-ok-strong">+{FileDiff.counts(file).added}</span>
            <span class="font-mono text-[11px] text-bad">−{FileDiff.counts(file).removed}</span>
          </header>
          <p :if={file.binary?} class="px-4 py-2 text-[12px] text-faint">A binary file.</p>
          <p :if={file.hunks == [] and not file.binary?} class="px-4 py-2 text-[12px] text-faint">
            Renamed, or its mode changed; no lines differ.
          </p>
          <div :if={file.hunks != []} class="overflow-x-auto font-mono text-[11px] leading-[1.5]">
            <table class="w-full border-collapse">
              <tbody :for={hunk <- file.hunks}>
                <tr class="bg-accent-soft/20 text-accent">
                  <td colspan="3" class="px-3 py-0.5">{hunk.header}</td>
                </tr>
                <tr :for={line <- hunk.lines} class={line_class(line.kind)}>
                  <td class="w-10 select-none border-r border-line-soft px-2 text-right text-faint">
                    {line.old_line}
                  </td>
                  <td class="w-10 select-none border-r border-line-soft px-2 text-right text-faint">
                    {line.new_line}
                  </td>
                  <td class="whitespace-pre px-3" phx-no-format>{sign(line.kind)}{line.text}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p
            :if={file.truncated?}
            class="border-t border-line-soft px-4 py-1.5 text-[11px] text-faint"
          >
            Cut short here.
          </p>
        </section>
        <p :if={@diff.cut?} id="handoff-diff-cut" class="text-[12px] text-faint">
          The change goes on past what is shown here.
        </p>
      <% end %>
    </div>
    """
  end

  defp line_class(:added), do: "bg-ok-soft/30 text-ink"
  defp line_class(:removed), do: "bg-bad-soft/30 text-ink"
  defp line_class(_), do: "text-ink/80"

  defp sign(:added), do: "+"
  defp sign(:removed), do: "−"
  defp sign(_), do: " "

  ## Small parts

  attr :status, :atom, required: true
  attr :class, :any, default: "size-4"

  defp state_icon(assigns) do
    ~H"""
    <.icon
      name={
        case @status do
          :accepted -> "hero-check-circle"
          :closed -> "hero-x-circle"
          :sent_back -> "hero-arrow-uturn-left"
          :withdrawn -> "hero-wrench-screwdriver"
          _waiting -> "hero-arrow-down-on-square"
        end
      }
      class={[
        @class,
        "shrink-0",
        case @status do
          :accepted -> "text-violet-strong"
          :closed -> "text-bad"
          :sent_back -> "text-warn-strong"
          :withdrawn -> "text-warn-strong"
          _waiting -> "text-ok-strong"
        end
      ]}
    />
    """
  end

  attr :status, :atom, required: true

  defp state_pill(assigns) do
    {label, classes} =
      case assigns.status do
        :open -> {"Waiting to land", "bg-ok-soft text-ok-strong"}
        :sent_back -> {"Sent back", "bg-warn-soft text-warn-strong"}
        :withdrawn -> {"Taken back", "bg-warn-soft text-warn-strong"}
        :accepted -> {"Landed", "bg-violet/15 text-violet-strong"}
        :closed -> {"Closed", "bg-bad-soft text-bad"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span
      id="handoff-state"
      class={[
        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[12px] font-medium",
        @classes
      ]}
    >
      <.state_icon status={@status} class="size-3.5 !text-current" /> {@label}
    </span>
    """
  end

  defp verb(%Handoff{status: :accepted}), do: "landed"
  defp verb(%Handoff{status: :closed}), do: "closed"
  defp verb(%Handoff{revision: 1}), do: "handed off"
  defp verb(_handoff), do: "updated"

  # A folder of yours, with your home folder as ~.
  defp home(nil), do: ""

  defp home(path) do
    home = System.user_home!()

    if String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(text), do: text

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"
end
