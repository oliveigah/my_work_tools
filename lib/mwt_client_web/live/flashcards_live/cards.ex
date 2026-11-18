defmodule MWTClientWeb.FlashcardsLive.Cards do
  @moduledoc """
  The Cards view: the cards the page's filter picks, searchable, on the
  left, and the card open on the right, written beside how it will look.

  A card leaves the deck in two steps: removed, as not worth remembering
  (from here or from a session), it waits under Removed, where it can be
  put back or deleted for good.

  A new card keeps the tags and the source of the one added before it, so
  writing several about one thing means typing them once.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.FlashcardsLive.Components

  alias MWTClient.Flashcards.Card
  alias MWTClientWeb.FlashcardsLive.Filter

  attr :entries, :list, required: true
  attr :hidden, :integer, required: true
  attr :count, :integer, required: true
  attr :removed_count, :integer, required: true
  attr :bin?, :boolean, required: true, doc: "whether the removed cards are listed"
  attr :filter, :map, required: true
  attr :tags, :list, required: true
  attr :current_id, :string, default: nil
  attr :now, :any, required: true

  def list(assigns) do
    ~H"""
    <aside
      id="card-list-panel"
      class="flex w-[var(--card-list-width,21rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">
          {if @bin?, do: "Removed", else: "Cards"}
        </span>
        <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">{@count}</span>
        <div class="flex-1"></div>
        <.link
          :if={!@bin?}
          id="new-card"
          patch={~p"/tools/flashcards/cards"}
          title="New card"
          class="flex size-6 items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-accent"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </.link>
      </div>

      <div class="flex shrink-0 flex-col gap-1.5 border-b border-line-soft p-2">
        <form
          id="card-search"
          phx-change="search"
          phx-submit="search"
          autocomplete="off"
          class="relative"
        >
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="query"
            value={@filter.query}
            placeholder="Search questions and answers"
            phx-debounce="120"
            class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-2 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
        </form>
        <Filter.compact filter={@filter} tags={@tags} />
      </div>

      <div
        id="card-list"
        data-keep-scroll
        role="listbox"
        aria-label="Cards"
        class="min-h-0 flex-1 overflow-y-auto px-1.5 py-2"
      >
        <p :if={@entries == []} class="px-2 py-6 text-center text-xs text-faint">
          <%= cond do %>
            <% @bin? -> %>
              No removed card{if filtered?(@filter), do: " matches"}.
            <% filtered?(@filter) -> %>
              No card matches.
            <% true -> %>
              No cards yet. Write the first one on the right.
          <% end %>
        </p>

        <.link
          :for={entry <- @entries}
          id={"card-row-#{entry.id}"}
          patch={~p"/tools/flashcards/cards?id=#{entry.id}"}
          role="option"
          aria-selected={to_string(entry.id == @current_id)}
          class={[
            "mb-0.5 block rounded-md px-2.5 py-2 transition-colors",
            if(entry.id == @current_id,
              do: "bg-active shadow-[inset_2px_0_0_0_var(--color-accent)]",
              else: "hover:bg-hover"
            ),
            @bin? && "opacity-75"
          ]}
        >
          <span class="line-clamp-2 text-xs leading-snug text-ink">
            {Card.plain_front(entry.front)}
          </span>
          <span class="mt-1.5 flex items-center gap-1.5">
            <span class="flex min-w-0 flex-1 gap-1 overflow-hidden">
              <.tag_chip :for={tag <- Enum.take(entry.tags, 2)} name={tag} />
              <span :if={length(entry.tags) > 2} class="text-[10px] text-faint">
                +{length(entry.tags) - 2}
              </span>
            </span>
            <.strength box={entry.box} reviews={entry.reviews} />
            <.due :if={entry.reviews > 0 and !@bin?} due_at={entry.due_at} now={@now} />
          </span>
        </.link>

        <.load_more id="card-more" list="card-list" hidden={@hidden} />
      </div>

      <button
        :if={@bin? or @removed_count > 0}
        type="button"
        id="toggle-removed"
        phx-click="toggle_removed"
        class="flex shrink-0 cursor-pointer items-center gap-2 border-t border-line-soft px-3 py-2 text-left text-xs text-muted transition-colors hover:bg-hover hover:text-ink"
      >
        <%= if @bin? do %>
          <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Back to the deck
        <% else %>
          <.icon name="hero-archive-box-micro" class="size-3.5" /> Removed as not important
          <span class="ml-auto font-mono text-[10px] text-faint">{@removed_count}</span>
        <% end %>
      </button>
    </aside>
    """
  end

  attr :form, :any, required: true
  attr :form_key, :integer, required: true
  attr :card, :any, required: true, doc: "the card open, nil for a new one"
  attr :tags, :list, required: true
  attr :now, :any, required: true
  attr :versions?, :boolean, default: false

  def editor(assigns) do
    assigns =
      assign(assigns,
        front: assigns.form[:front].value || "",
        back: assigns.form[:back].value || "",
        removed?: assigns.card != nil and Card.removed?(assigns.card)
      )

    ~H"""
    <section id="card-editor" data-keep-scroll class="min-w-0 flex-1 overflow-y-auto bg-app">
      <div class="mx-auto w-full max-w-5xl px-6 py-6">
        <div
          :if={@removed?}
          id="card-removed"
          class="mb-5 flex flex-wrap items-center gap-3 rounded-xl border border-line bg-panel px-4 py-3"
        >
          <.icon name="hero-archive-box-x-mark" class="size-5 text-faint" />
          <p class="min-w-0 flex-1 text-[13px] text-muted">
            Removed from the deck as not important, {Calendar.strftime(@card.removed_at, "%b %-d")}.
            Sessions don't ask it, and an agent writing it again is told so.
          </p>
          <.button id="restore-card" phx-click="restore_card" phx-value-id={@card.id}>
            <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> Put back in the deck
          </.button>
          <.button
            id="delete-card"
            variant="danger"
            phx-click="delete_card"
            phx-value-id={@card.id}
            data-confirm="Delete this card for good? It can't be put back."
          >
            <.icon name="hero-trash-micro" class="size-4" /> Delete for good
          </.button>
        </div>

        <div class="mb-5 flex flex-wrap items-center gap-3">
          <div class="min-w-0 flex-1">
            <h1 class="text-base font-semibold text-ink">
              {if @card, do: "Edit card", else: "New card"}
            </h1>
            <p
              id="card-stats"
              class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted"
            >
              <%= if @card do %>
                <.strength id="card-strength" box={@card.box} reviews={@card.reviews} />
                <%= if @card.reviews == 0 do %>
                  <span>Not answered yet</span>
                <% else %>
                  <span>
                    Answered {times(@card.reviews)}, {if @card.lapses == 0,
                      do: "never forgotten",
                      else: "forgotten #{times(@card.lapses)}"}
                  </span>
                  <span :if={!@removed?}>
                    · <.due due_at={@card.due_at} now={@now} class="text-xs" />
                  </span>
                <% end %>
                · <span>written {Calendar.strftime(@card.created_at, "%b %-d, %Y")}</span>
              <% else %>
                One idea per card: a question that makes you recall it, and its answer.
              <% end %>
            </p>
          </div>
          <.versions_button :if={@card} id="card-versions-button" open={@versions?} class="h-7" />
          <.button
            :if={@card && !@removed?}
            id="remove-card"
            phx-click="remove_card"
            phx-value-id={@card.id}
            title="Not worth remembering: take it out of the deck"
          >
            <.icon name="hero-archive-box-x-mark-micro" class="size-4" /> Not important
          </.button>
        </div>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,0.9fr)]">
          <.form
            for={@form}
            id={"card-form-#{@form_key}"}
            phx-change="edit_change"
            phx-submit="save_card"
            autocomplete="off"
            class="flex flex-col gap-4"
          >
            <%!-- Named after the form, so a new form's fields are new
                  elements: the question takes the focus. --%>
            <.card_fields
              form={@form}
              id={"card-#{@form_key}"}
              tags={@tags}
              focus={is_nil(@card)}
            />

            <div class="flex items-center gap-2 pt-1">
              <.button type="submit" id={"save-card-#{@form_key}"} variant="primary" class="px-4">
                <%= if @card do %>
                  <.icon name="hero-check-micro" class="size-4" /> Save card
                <% else %>
                  <.icon name="hero-plus-micro" class="size-4" /> Add card
                <% end %>
              </.button>
              <.button
                :if={@card}
                id="cancel-edit"
                variant="ghost"
                patch={~p"/tools/flashcards/cards"}
              >
                New card
              </.button>
              <span :if={!@card} class="text-[11px] text-faint">
                The form stays open for the next one.
              </span>
            </div>
          </.form>

          <div id="card-preview" class="flex flex-col gap-3 lg:pt-5">
            <.face
              id="preview-front"
              label="Question"
              text={@front}
              empty="The question shows here."
              class="text-center text-[15px]"
            />
            <.face
              id="preview-back"
              label="Answer"
              text={@back}
              empty="The answer shows here."
              class="text-[13px]"
              accent
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :text, :string, required: true
  attr :empty, :string, required: true
  attr :class, :any, default: nil
  attr :accent, :boolean, default: false

  # A side of the card as a session shows it.
  defp face(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex min-h-32 flex-col rounded-xl border bg-panel p-4 shadow-sm",
        if(@accent, do: "border-accent/30", else: "border-line")
      ]}
    >
      <span class="text-[10px] font-semibold uppercase tracking-wider text-faint">{@label}</span>
      <div class="flex flex-1 items-center justify-center py-3">
        <%= if String.trim(@text) == "" do %>
          <span class="text-xs text-faint">{@empty}</span>
        <% else %>
          <.markdown text={@text} class={["w-full", @class]} />
        <% end %>
      </div>
    </div>
    """
  end

  defp filtered?(filter), do: filter.query != "" or filter.tags != [] or filter.days != nil

  defp times(0), do: "never"
  defp times(1), do: "once"
  defp times(2), do: "twice"
  defp times(n), do: "#{n} times"
end
