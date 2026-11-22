defmodule MWTClientWeb.FlashcardsLive.Remember do
  @moduledoc """
  The Remember view: choosing what a session asks, by mixing and matching
  tags, the session itself, one card at a time, flipped to its answer,
  corrected if it needs it, and voted on, removed or marked uncertain, and
  what it came to.

  A card marked uncertain waits for a check against the code, by an agent
  the user asks; the view says how many wait, and the words to ask with,
  naming the tags picked, since sessions leave them out until then.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.FlashcardsLive.Components

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Session
  alias MWTClientWeb.FlashcardsLive.Filter

  # Each vote: its grade, its label, the key that casts it, and its colours.
  @votes [
    {:forgot, "Forgot", "1", "border-bad/40 text-bad hover:border-bad hover:bg-bad-soft/60"},
    {:hard, "Hard", "2", "border-warn/40 text-warn hover:border-warn hover:bg-warn-soft/60"},
    {:good, "Good", "3", "border-ok/40 text-ok hover:border-ok hover:bg-ok-soft/60"},
    {:easy, "Easy", "4",
     "border-accent/40 text-accent hover:border-accent hover:bg-accent-soft/60"}
  ]

  @doc "The grades and the keys that cast them."
  def keys, do: Map.new(@votes, fn {grade, _label, key, _class} -> {key, grade} end)

  @doc """
  What the user asks an agent with, to check the cards marked uncertain:
  those holding `tags`, any one or, with `:all`, every one, or every card
  with none.
  """
  @spec check_prompt([String.t()], :any | :all) :: String.t()
  def check_prompt([], _match), do: "Check my uncertain flash cards in MWT against the code."

  def check_prompt(tags, match) do
    {init, [last]} = Enum.split(tags, -1)

    joined =
      if init == [],
        do: last,
        else: "#{Enum.join(init, ", ")} #{if match == :all, do: "and", else: "or"} #{last}"

    "Check my uncertain flash cards in MWT tagged #{joined} against the code."
  end

  ## Choosing what to go over

  attr :filter, :map, required: true
  attr :picker, :map, required: true, doc: "what `Filter.picker/1` takes besides the filter"
  attr :count, :map, required: true
  attr :size, :integer, required: true
  attr :fill, :boolean, required: true, doc: "whether sessions are filled with cards not due yet"
  attr :totals, :map, required: true, doc: "the deck's counts, as `Library.count/2` gives them"
  attr :matching, :list, required: true, doc: "the first cards the filter picks"
  attr :now, :any, required: true

  def start(assigns) do
    assigns =
      assign(assigns,
        asks: session_size(assigns.count, assigns.size, assigns.fill),
        check_prompt: check_prompt(assigns.filter.tags, assigns.filter.match),
        narrowed?: assigns.filter.tags != [] or assigns.filter.days != nil
      )

    ~H"""
    <div id="remember-start" class="mx-auto w-full max-w-3xl px-6 py-8">
      <%= if @totals.cards == 0 do %>
        <.empty />
      <% else %>
        <div class="mb-5">
          <h1 class="text-lg font-semibold text-ink">Remember</h1>
          <p class="mt-0.5 text-[13px] text-muted">
            Mix and match tags to pick what to go over. Cards you forget come back sooner than the ones you know.
          </p>
        </div>

        <section
          id="session-setup"
          class="overflow-hidden rounded-xl border border-line bg-panel shadow-sm"
        >
          <div class="space-y-4 p-5">
            <Filter.picker filter={@filter} {@picker} />

            <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 border-t border-line-soft pt-4">
              <Filter.days days={@filter.days} />
              <form
                id="session-size-form"
                phx-change="set_size"
                phx-submit="start"
                class="flex items-center gap-2"
              >
                <label for="session-size" class="text-[13px] text-muted">Cards</label>
                <input
                  type="number"
                  id="session-size"
                  name="size"
                  value={@size}
                  min="1"
                  max="100"
                  phx-debounce="250"
                  class="w-16 rounded-md border border-line bg-deep px-2 py-1 text-center text-[13px] text-ink outline-none transition-colors focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
                />
              </form>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-3 border-t border-line-soft bg-deep/40 px-5 py-3">
            <p id="session-count" class="flex-1 text-xs text-muted">
              <%= cond do %>
                <% @count.cards == 0 -> %>
                  No card has these tags{if @filter.days, do: " in those days"}.
                <% @count.cards == @count.uncertain -> %>
                  <span class="text-ink">{plural(@count.cards, "card")}</span>
                  · all marked uncertain: sessions ask them once they are resolved.
                <% @asks == 0 -> %>
                  <span class="text-ink">{plural(@count.cards, "card")}</span>
                  · none due now. Sessions ask only due cards: see Settings.
                <% true -> %>
                  <span class="text-ink">{plural(@count.cards, "card")}</span>
                  · <span class={@count.due > 0 && "text-warn"}>{@count.due} due now</span>
                  · the session asks {plural(@asks, "card")}
              <% end %>
              <span :if={@count.uncertain > 0 and @count.cards > @count.uncertain}>
                · {@count.uncertain} uncertain left out
              </span>
            </p>
            <.button
              id="start-session"
              variant="primary"
              phx-click="start"
              disabled={@asks == 0}
              class="px-4"
            >
              <.icon name="hero-play-micro" class="size-4" /> Start session
            </.button>
          </div>
        </section>

        <section
          :if={@totals.uncertain > 0}
          id="uncertain-waiting"
          class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border border-warn/30 bg-warn-soft/30 px-4 py-3"
        >
          <.icon name="hero-question-mark-circle" class="size-5 shrink-0 text-warn" />
          <div class="min-w-0 flex-1">
            <p class="text-[13px] text-ink">
              {plural(@totals.uncertain, "card")} marked uncertain {if @totals.uncertain == 1,
                do: "waits",
                else: "wait"} to be checked<span :if={@narrowed?}>, {@count.uncertain} in this pick</span>
            </p>
            <p class="mt-0.5 text-xs text-muted">
              Sessions leave them out until they are resolved. Ask an agent connected to MWT:
              <span class="italic text-ink">“{@check_prompt}”</span>
            </p>
          </div>
          <.button id="see-uncertain" phx-click="show_listing" phx-value-listing="uncertain">
            See them <.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.button>
        </section>

        <section :if={@count.cards > 0} id="matching-cards" class="mt-6">
          <div class="mb-2 flex items-center gap-2">
            <h2 class="text-[11px] font-semibold uppercase tracking-wider text-faint">
              In this pick
            </h2>
            <span class="font-mono text-[10px] text-faint">{@count.cards}</span>
            <div class="flex-1"></div>
            <.link
              id="open-in-cards"
              patch={~p"/tools/flashcards/cards"}
              class="flex items-center gap-1 text-xs text-accent transition-colors hover:text-accent-strong"
            >
              {if @count.cards > length(@matching), do: "See all in Cards", else: "Open in Cards"}
              <.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </div>
          <ul class="divide-y divide-line-soft overflow-hidden rounded-lg border border-line-soft bg-panel">
            <li :for={card <- @matching} id={"matching-#{card.id}"}>
              <.link
                patch={~p"/tools/flashcards/cards?id=#{card.id}"}
                class="flex items-center gap-3 px-3.5 py-2 transition-colors hover:bg-hover"
              >
                <span class="min-w-0 flex-1 truncate text-[13px] text-ink">
                  {Card.plain_front(card.front)}
                </span>
                <span class="hidden shrink-0 gap-1 sm:flex">
                  <.tag_chip :for={tag <- Enum.take(card.tags, 3)} name={tag} />
                </span>
                <.uncertain_badge :if={Card.uncertain?(card)} note={card.uncertain_note} />
                <.strength box={card.box} reviews={card.reviews} />
                <.due :if={card.reviews > 0} due_at={card.due_at} now={@now} class="w-16 text-right" />
              </.link>
            </li>
          </ul>
        </section>
      <% end %>
    </div>
    """
  end

  defp empty(assigns) do
    ~H"""
    <div id="remember-empty" class="flex flex-col items-center px-6 py-16 text-center">
      <div class="relative mb-6 h-24 w-32">
        <span class="absolute inset-x-3 top-0 h-20 -rotate-6 rounded-xl border border-line bg-panel shadow-sm"></span>
        <span class="absolute inset-x-3 top-1 flex h-20 rotate-3 items-center justify-center rounded-xl border border-accent/40 bg-panel shadow-md">
          <.icon name="hero-light-bulb" class="size-7 text-accent" />
        </span>
      </div>
      <h1 class="text-base font-semibold text-ink">Nothing to remember yet</h1>
      <p class="mt-1.5 max-w-md text-[13px] leading-relaxed text-muted">
        Write a card about something you want to keep, or ask an agent connected to MWT to turn a thread into cards:
      </p>
      <p class="mt-3 max-w-md rounded-lg border border-line-soft bg-deep px-3.5 py-2 text-[13px] italic text-ink">
        “Add flash cards to MWT with the key decisions of this thread.”
      </p>
      <div class="mt-6 flex items-center gap-2">
        <.button id="empty-write" variant="primary" patch={~p"/tools/flashcards/cards"}>
          <.icon name="hero-plus-micro" class="size-4" /> Write a card
        </.button>
        <.button id="empty-agents" navigate={~p"/agents"}>
          <.icon name="hero-command-line-micro" class="size-4" /> Connect an agent
        </.button>
      </div>
    </div>
    """
  end

  ## A session

  attr :session, :any, required: true
  attr :scope_label, :string, required: true
  attr :preview, :map, required: true, doc: "the days each vote would wait"
  attr :edit_form, :any, required: true, doc: "the card being corrected, nil while it isn't"

  attr :uncertain_form, :any,
    required: true,
    doc: "what is doubted about the card asked, being written; nil while it isn't"

  attr :tags, :list, required: true

  attr :set_aside, :any,
    required: true,
    doc: "`{:removed | :uncertain, id, front}` of the card just set aside so, or nil"

  def session(assigns) do
    assigns =
      assign(assigns,
        card: assigns.session.current,
        handled: Session.handled(assigns.session),
        left: Session.left(assigns.session),
        votes: @votes
      )

    ~H"""
    <div
      id="remember-session"
      phx-window-keydown={is_nil(@edit_form) && is_nil(@uncertain_form) && "session_key"}
      phx-hook=".SessionKeys"
      class="mx-auto flex w-full max-w-2xl flex-col px-6 py-6"
    >
      <%!-- Space shows the answer, so it must not also scroll the page. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionKeys">
        export default {
          mounted() {
            this.onKey = event => {
              const typing = event.target.closest?.("input, textarea, select, button, [contenteditable]")
              if (event.key === " " && !typing) event.preventDefault()
            }
            window.addEventListener("keydown", this.onKey)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          }
        }
      </script>
      <span
        :if={@edit_form}
        id="edit-escape"
        phx-window-keydown="cancel_edit"
        phx-key="Escape"
        class="hidden"
      ></span>
      <span
        :if={@uncertain_form}
        id="doubt-escape"
        phx-window-keydown="cancel_doubt"
        phx-key="Escape"
        class="hidden"
      ></span>

      <div class="mb-2 flex items-center gap-3">
        <span id="session-scope" class="flex min-w-0 flex-1 items-center gap-1.5 text-xs text-muted">
          <.icon name="hero-rectangle-stack-micro" class="size-3.5 shrink-0 text-faint" />
          <span class="truncate">{@scope_label}</span>
        </span>
        <span id="session-progress" class="font-mono text-[11px] text-faint">
          {@handled + 1} / {@handled + @left}
        </span>
        <.button id="end-session" variant="ghost" phx-click="end_session" class="px-2 py-1 text-xs">
          End session
        </.button>
      </div>
      <div class="mb-4 h-1 overflow-hidden rounded-full bg-deep">
        <div
          class="h-full rounded-full bg-accent transition-[width] duration-500 ease-out"
          style={"width: #{progress(@handled, @left)}%"}
        >
        </div>
      </div>

      <.set_aside_notice :if={@set_aside} set_aside={@set_aside} />

      <%!-- Each card asked is a new element, so moving on never plays the
            flip backwards with the next card's answer on show. --%>
      <div
        id={"session-card-#{@handled}"}
        class="animate-card-in perspective-distant motion-reduce:animate-none"
      >
        <div
          id="session-card"
          class={[
            "grid transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)] transform-3d motion-reduce:transition-none",
            @session.flipped? && "rotate-y-180"
          ]}
        >
          <section
            id="card-front"
            aria-hidden={to_string(@session.flipped?)}
            class="col-start-1 row-start-1 flex min-h-72 flex-col rounded-2xl border border-line bg-panel p-7 shadow-xl backface-hidden"
          >
            <.card_top card={@card} label="Question" />
            <div class="flex flex-1 items-center justify-center py-6">
              <.markdown
                id="card-front-text"
                text={@card.front}
                class="w-full text-center text-[17px] leading-relaxed"
              />
            </div>
            <p class="text-center text-[11px] text-faint">
              Recall the answer, then press
              <.kbd>Space</.kbd>
              to check it
            </p>
          </section>

          <section
            id="card-back"
            aria-hidden={to_string(!@session.flipped?)}
            class={[
              "col-start-1 row-start-1 flex min-h-72 rotate-y-180 flex-col rounded-2xl border bg-panel p-7 shadow-xl backface-hidden",
              if(@edit_form, do: "border-accent/60", else: "border-accent/30")
            ]}
          >
            <%= if @edit_form do %>
              <.form
                for={@edit_form}
                id="session-edit-form"
                phx-change="edit_change"
                phx-submit="save_edit"
                autocomplete="off"
                class="flex flex-col gap-3"
              >
                <div class="flex items-center gap-2">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-accent">
                    Correcting this card
                  </span>
                  <div class="flex-1"></div>
                  <span class="text-[11px] text-faint">
                    How well you know it is kept
                  </span>
                </div>
                <.card_fields form={@edit_form} id="session-edit" tags={@tags} compact />
                <div class="flex items-center gap-2 pt-1">
                  <.button type="submit" id="save-edit" variant="primary" class="px-4">
                    <.icon name="hero-check-micro" class="size-4" /> Save
                  </.button>
                  <.button type="button" id="cancel-edit" variant="ghost" phx-click="cancel_edit">
                    Cancel
                  </.button>
                  <span class="text-[11px] text-faint"><.kbd>Esc</.kbd>
                  cancels</span>
                </div>
              </.form>
            <% else %>
              <.card_top card={@card} label="Answer" />
              <p class="mt-3 line-clamp-2 text-[13px] text-muted">{Card.plain_front(@card)}</p>
              <div class="my-4 h-px bg-line-soft"></div>
              <.markdown id="card-back-text" text={@card.back} class="flex-1 text-[15px]" />
              <%!-- Across the foot of the card, apart from the answer, as it
                    acts on the whole card: question, answer and tags. --%>
              <div class="-mx-7 -mb-7 mt-6 flex items-center gap-3 rounded-b-2xl border-t border-line-soft bg-deep/40 px-7 py-2.5">
                <p
                  id="card-source"
                  class="flex min-w-0 flex-1 items-center gap-1.5 text-[11px] text-faint"
                >
                  <%= if @card.source do %>
                    <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3.5 shrink-0" />
                    <span class="truncate">{@card.source}</span>
                  <% end %>
                </p>
                <button
                  type="button"
                  id="edit-card"
                  phx-click="edit_card"
                  title="Correct this card: its question, its answer or its tags"
                  class="flex shrink-0 cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-2.5 py-1 text-xs text-muted transition-colors hover:border-accent/60 hover:text-accent"
                >
                  <.icon name="hero-pencil-square-micro" class="size-3.5" /> Edit card
                  <.kbd>E</.kbd>
                </button>
              </div>
            <% end %>
          </section>
        </div>
      </div>

      <div class="mt-6 min-h-16">
        <%= cond do %>
          <% @edit_form -> %>
          <% @uncertain_form -> %>
            <.doubt_form form={@uncertain_form} />
          <% @session.flipped? -> %>
            <div id="votes" class="flex animate-card-in items-stretch gap-2">
              <div class="grid flex-1 grid-cols-4 gap-2">
                <button
                  :for={{grade, label, key, class} <- @votes}
                  type="button"
                  id={"vote-#{grade}"}
                  phx-click="vote"
                  phx-value-grade={grade}
                  class={[
                    "flex cursor-pointer flex-col items-center gap-0.5 rounded-xl border bg-panel px-2 py-2.5 transition-all active:scale-[0.97]",
                    class
                  ]}
                >
                  <span class="flex items-center gap-1.5 text-[13px] font-semibold">
                    {label}
                    <.kbd>{key}</.kbd>
                  </span>
                  <span class="text-[11px] text-muted">{wait_label(@preview[grade])}</span>
                </button>
              </div>
              <div class="w-px bg-line-soft"></div>
              <%!-- Instead of a vote, stacked so the votes keep their width:
                    each sets the card aside, out of what sessions ask. --%>
              <div class="flex w-40 shrink-0 flex-col gap-1.5">
                <button
                  type="button"
                  id="doubt-card"
                  phx-click="doubt_card"
                  title="You doubt the answer: set the card aside for an agent to check against the code"
                  class="flex flex-1 cursor-pointer items-center gap-1.5 rounded-lg border border-dashed border-line bg-transparent px-2.5 text-muted transition-all hover:border-warn/60 hover:bg-warn-soft/30 hover:text-warn active:scale-[0.97]"
                >
                  <.icon name="hero-question-mark-circle-micro" class="size-3.5 shrink-0" />
                  <span class="flex-1 whitespace-nowrap text-left text-xs font-semibold">Unsure</span>
                  <.kbd>U</.kbd>
                </button>
                <button
                  type="button"
                  id="remove-card"
                  phx-click="remove_card"
                  title="Not worth remembering: take it out of the deck"
                  class="flex flex-1 cursor-pointer items-center gap-1.5 rounded-lg border border-dashed border-line bg-transparent px-2.5 text-muted transition-all hover:border-bad/60 hover:bg-bad-soft/30 hover:text-bad active:scale-[0.97]"
                >
                  <.icon name="hero-archive-box-x-mark-micro" class="size-3.5 shrink-0" />
                  <span class="flex-1 whitespace-nowrap text-left text-xs font-semibold">
                    Not important
                  </span>
                  <.kbd>X</.kbd>
                </button>
              </div>
            </div>
          <% true -> %>
            <div class="flex justify-center">
              <button
                type="button"
                id="flip"
                phx-click="flip"
                class="flex cursor-pointer items-center gap-2 rounded-xl border border-line bg-panel px-6 py-3 text-[13px] font-medium text-ink shadow-sm transition-all hover:-translate-y-px hover:border-accent/60 hover:shadow-md active:translate-y-0"
              >
                <.icon name="hero-arrow-path-rounded-square" class="size-4 text-accent" /> Show answer
                <.kbd>Space</.kbd>
              </button>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :set_aside, :any, required: true, doc: "`{:removed | :uncertain, id, front}`"

  # What was done to the card just left, with its undo.
  defp set_aside_notice(%{set_aside: {kind, id, front}} = assigns) do
    assigns = assign(assigns, kind: kind, id: id, front: Card.plain_front(front))

    ~H"""
    <div
      id={"#{@kind}-notice"}
      class="mb-4 flex animate-card-in items-center gap-2 rounded-lg border border-line-soft bg-panel px-3 py-2 text-xs text-muted"
    >
      <%= if @kind == :removed do %>
        <.icon name="hero-archive-box-x-mark-micro" class="size-4 shrink-0 text-faint" />
        <span class="min-w-0 flex-1 truncate">Removed “{@front}” from the deck.</span>
      <% else %>
        <.icon name="hero-question-mark-circle-micro" class="size-4 shrink-0 text-warn" />
        <span class="min-w-0 flex-1 truncate">
          Marked “{@front}” uncertain, for an agent to check.
        </span>
      <% end %>
      <button
        type="button"
        id={if @kind == :removed, do: "undo-remove", else: "undo-uncertain"}
        phx-click={if @kind == :removed, do: "restore_card", else: "unmark_uncertain"}
        phx-value-id={@id}
        class="cursor-pointer font-medium text-accent transition-colors hover:text-accent-strong"
      >
        Undo
      </button>
    </div>
    """
  end

  attr :form, :any, required: true

  # What the user doubts about the card asked, written in a line before it
  # is set aside. Nothing written is fine: the mark alone says it.
  defp doubt_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="doubt-form"
      phx-change="doubt_change"
      phx-submit="save_doubt"
      autocomplete="off"
      class="animate-card-in rounded-xl border border-warn/40 bg-panel p-3.5 shadow-sm"
    >
      <.input
        field={@form[:note]}
        id="doubt-note"
        label="What are you unsure about? Optional"
        maxlength={Card.max_uncertain_note()}
        phx-mounted={JS.focus()}
        placeholder="Is this still true since shares sync on demand?"
      />
      <div class="mt-2.5 flex flex-wrap items-center gap-2">
        <.button type="submit" id="save-doubt" variant="primary" class="px-4">
          <.icon name="hero-question-mark-circle-micro" class="size-4" /> Mark uncertain
        </.button>
        <.button type="button" id="cancel-doubt" variant="ghost" phx-click="cancel_doubt">
          Cancel
        </.button>
        <span class="text-[11px] text-faint">
          <.kbd>Enter</.kbd>
          marks it and moves on ·
          <.kbd>Esc</.kbd>
          cancels.
          Sessions leave it out until it is checked.
        </span>
      </div>
    </.form>
    """
  end

  attr :card, :any, required: true
  attr :label, :string, required: true

  defp card_top(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-faint">{@label}</span>
      <div class="flex min-w-0 flex-1 flex-wrap justify-end gap-1">
        <.tag_chip :for={tag <- @card.tags} name={tag} />
      </div>
      <.strength box={@card.box} reviews={@card.reviews} class="ml-1" />
    </div>
    """
  end

  ## What the session came to

  attr :session, :any, required: true
  attr :scope_label, :string, required: true

  def summary(assigns) do
    tally = Session.tally(assigns.session)
    asked = Enum.sum(Map.values(tally))

    assigns =
      assign(assigns,
        tally: tally,
        asked: asked,
        remembered: asked - tally.forgot,
        forgotten: Session.forgotten(assigns.session),
        removed: Session.removed(assigns.session),
        uncertain: Session.uncertain(assigns.session),
        skipped: assigns.session.skipped,
        votes: @votes
      )

    ~H"""
    <div id="remember-summary" class="mx-auto w-full max-w-xl px-6 py-10">
      <div class="animate-card-in rounded-2xl border border-line bg-panel p-7 text-center shadow-xl">
        <span class={[
          "mx-auto mb-4 flex size-12 items-center justify-center rounded-full",
          if(@tally.forgot == 0, do: "bg-ok-soft text-ok", else: "bg-accent-soft text-accent")
        ]}>
          <.icon
            name={if @tally.forgot == 0, do: "hero-trophy", else: "hero-check-badge"}
            class="size-6"
          />
        </span>
        <h1 class="text-base font-semibold text-ink">
          {if @skipped > 0, do: "Session ended", else: "Session done"}
        </h1>
        <p id="summary-score" class="mt-1 text-[13px] text-muted">
          <%= if @asked == 0 do %>
            No card was answered.
          <% else %>
            You remembered <span class="font-semibold text-ink">{@remembered} of {@asked}</span>
            {if @asked == 1, do: "card", else: "cards"}
          <% end %>
          <span :if={@skipped > 0}>· {@skipped} left for next time</span>
        </p>
        <p class="mt-0.5 text-[11px] text-faint">{@scope_label}</p>

        <div :if={@asked > 0} id="summary-tally" class="mt-5 grid grid-cols-4 gap-2">
          <div
            :for={{grade, label, _key, class} <- @votes}
            id={"tally-#{grade}"}
            class={["rounded-lg border bg-deep/40 px-2 py-2", class]}
          >
            <div class="text-lg font-semibold">{@tally[grade]}</div>
            <div class="text-[11px] text-muted">{label}</div>
          </div>
        </div>

        <.summary_list :if={@forgotten != []} id="summary-forgotten" cards={@forgotten}>
          Forgotten: these come back first next time
        </.summary_list>

        <.summary_list
          :if={@uncertain != []}
          id="summary-uncertain"
          cards={@uncertain}
          undo={{"unmark_uncertain", "Not uncertain", "unmark"}}
        >
          Marked uncertain: ask an agent to check them
        </.summary_list>

        <.summary_list
          :if={@removed != []}
          id="summary-removed"
          cards={@removed}
          undo={{"restore_card", "Put back", "restore"}}
        >
          Removed from the deck as not important
        </.summary_list>

        <div class="mt-7 flex justify-center gap-2">
          <.button id="session-again" variant="primary" phx-click="again">
            <.icon name="hero-arrow-path-micro" class="size-4" /> Another round
          </.button>
          <.button id="session-close" phx-click="close_summary">Done</.button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :cards, :list, required: true, doc: "`{id, front}`"

  attr :undo, :any,
    default: nil,
    doc: "`{event, label, id prefix}` of a button undoing what was done to each card, or nil"

  slot :inner_block, required: true

  defp summary_list(assigns) do
    ~H"""
    <div id={@id} class="mt-6 text-left">
      <h2 class="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-faint">
        {render_slot(@inner_block)}
      </h2>
      <ul class="divide-y divide-line-soft rounded-lg border border-line-soft">
        <li :for={{id, front} <- @cards} class="flex items-center">
          <.link
            patch={~p"/tools/flashcards/cards?id=#{id}"}
            class="block min-w-0 flex-1 truncate px-3 py-2 text-[13px] text-ink transition-colors hover:bg-hover"
          >
            {Card.plain_front(front)}
          </.link>
          <button
            :if={@undo}
            type="button"
            id={"#{elem(@undo, 2)}-#{id}"}
            phx-click={elem(@undo, 0)}
            phx-value-id={id}
            class="shrink-0 cursor-pointer px-3 py-2 text-xs text-accent transition-colors hover:text-accent-strong"
          >
            {elem(@undo, 1)}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # The cards marked uncertain are never asked, nor counted due.
  defp session_size(count, size, true), do: min(size, count.cards - count.uncertain)
  defp session_size(count, size, false), do: min(size, count.due)

  defp progress(handled, left) when handled + left == 0, do: 100
  defp progress(handled, left), do: round(handled * 100 / (handled + left))

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
