defmodule MWTClientWeb.FlashcardsLive.Filter do
  @moduledoc """
  Picking cards by their tags, mixed and matched: the tags picked, whether a
  card needs any of them or all, and how recently it was written.

  One filter serves the whole page, so the cards a session would ask are the
  cards the Cards view lists. Remember shows it whole (`picker/1`), to choose
  among many tags; the Cards list shows it compact (`compact/1`).

  The events it sends, handled by `MWTClientWeb.FlashcardsLive`:
  `toggle_tag` (`name`), `clear_tags`, `set_match` (`match`), `set_days`
  (`days`, empty for any time), `tag_search` and `pick_tag` (`tag_query`,
  the first tag found), `more_tags`, and `filter_add_tag` (`tag`).
  """
  use MWTClientWeb, :html

  @doc "The days the picker offers with one click."
  def day_presets, do: [{nil, "Any time"}, {1, "Today"}, {7, "7 days"}, {30, "30 days"}]

  @doc """
  The whole picker: the tags picked, a search over the rest, and the rest
  as a cloud, the tags on most cards first. With `match: :all`, the cloud
  holds only tags found together with every tag picked, and its counts say
  how many cards would be left with each one added.
  """
  attr :filter, :map, required: true, doc: "`tags`, `match`, `days`"
  attr :counts, :map, required: true, doc: "cards per picked tag, by name"
  attr :cloud, :list, required: true, doc: "the tags to offer, as shown"
  attr :hidden, :integer, required: true, doc: "tags the cloud leaves out until asked"
  attr :total, :integer, required: true, doc: "tags offered, searched or not"
  attr :tag_query, :string, required: true
  attr :more?, :boolean, required: true

  def picker(assigns) do
    ~H"""
    <div id="tag-picker" class="space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-[11px] font-medium uppercase tracking-wide text-muted">Tags</span>
        <div class="flex-1"></div>
        <.match_toggle
          id="tag-match"
          match={@filter.match}
          enabled={length(@filter.tags) > 1}
        />
      </div>

      <div id="picked-tags" class="flex min-h-8 flex-wrap items-center gap-1.5">
        <%= if @filter.tags == [] do %>
          <span class="inline-flex items-center gap-1.5 rounded-full border border-dashed border-line px-2.5 py-1 text-xs text-muted">
            <.icon name="hero-squares-2x2-micro" class="size-3.5" />
            Every card. Pick tags below to narrow it.
          </span>
        <% else %>
          <button
            :for={tag <- @filter.tags}
            type="button"
            id={"picked-tag-#{tag_id(tag)}"}
            phx-click="toggle_tag"
            phx-value-name={tag}
            title={"Stop picking #{tag}"}
            class="group inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-accent/60 bg-accent-soft py-1 pl-2.5 pr-1.5 text-xs text-accent-strong transition-colors hover:border-accent"
          >
            {tag}
            <span class="font-mono text-[10px] opacity-70">{Map.get(@counts, String.downcase(tag), 0)}</span>
            <.icon
              name="hero-x-mark-micro"
              class="size-3.5 opacity-60 transition-opacity group-hover:opacity-100"
            />
          </button>
          <span :if={length(@filter.tags) > 1} class="px-1 text-[11px] text-faint">
            {if @filter.match == :all, do: "cards with every one", else: "cards with any of them"}
          </span>
          <button
            type="button"
            id="clear-tags"
            phx-click="clear_tags"
            class="cursor-pointer px-1 text-[11px] text-faint underline-offset-2 transition-colors hover:text-ink hover:underline"
          >
            Clear
          </button>
        <% end %>
      </div>

      <form
        id="tag-search"
        phx-change="tag_search"
        phx-submit="pick_tag"
        autocomplete="off"
        class="relative"
      >
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-faint"
        />
        <input
          type="text"
          name="tag_query"
          id="tag-search-input"
          value={@tag_query}
          placeholder={"Find a tag among #{@total}… Enter picks the first"}
          phx-debounce="100"
          class="w-full rounded-md border border-line bg-deep py-1.5 pl-8 pr-2 text-[13px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
        />
      </form>

      <div id="tag-cloud" class="flex flex-wrap gap-1.5">
        <button
          :for={tag <- @cloud}
          type="button"
          id={"tag-#{tag_id(tag.name)}"}
          phx-click="toggle_tag"
          phx-value-name={tag.name}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-line bg-deep px-2.5 py-1 text-xs text-muted transition-all hover:-translate-y-px hover:border-accent/50 hover:text-ink"
        >
          {tag.name}
          <span class="font-mono text-[10px] text-faint">{tag.cards}</span>
        </button>
        <p :if={@cloud == [] and @tag_query != ""} class="py-1 text-xs text-faint">
          No tag matches “{@tag_query}”.
        </p>
        <p
          :if={@cloud == [] and @tag_query == "" and @filter.tags != []}
          class="py-1 text-xs text-faint"
        >
          <%= if @filter.match == :all do %>
            No other tag is on the cards with every tag picked.
          <% else %>
            Every tag is picked.
          <% end %>
        </p>
        <button
          :if={@hidden > 0 or @more?}
          type="button"
          id="more-tags"
          phx-click="more_tags"
          class="cursor-pointer px-1.5 py-1 text-xs text-accent transition-colors hover:text-accent-strong"
        >
          {if @more?, do: "Show fewer", else: "#{@hidden} more…"}
        </button>
      </div>
    </div>
    """
  end

  @doc "The days a session or a list looks back, as one-click presets and a number."
  attr :days, :any, required: true

  def days(assigns) do
    assigns = assign(assigns, presets: day_presets())

    ~H"""
    <div id="filter-days" class="flex flex-wrap items-center gap-2">
      <span class="text-[13px] text-muted">Added</span>
      <div class="flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5">
        <button
          :for={{days, label} <- @presets}
          type="button"
          id={"days-#{days || "any"}"}
          phx-click="set_days"
          phx-value-days={days || ""}
          aria-pressed={to_string(@days == days)}
          class={[
            "cursor-pointer rounded px-2 py-0.5 text-xs transition-colors",
            if(@days == days, do: "bg-active text-ink", else: "text-faint hover:text-ink")
          ]}
        >
          {label}
        </button>
      </div>
      <form
        id="days-form"
        phx-change="set_days"
        phx-submit="set_days"
        class="flex items-center gap-1.5"
      >
        <span class="text-[13px] text-muted">or the last</span>
        <input
          type="number"
          name="days"
          id="days-input"
          value={@days}
          min="1"
          max="3650"
          placeholder="N"
          phx-debounce="300"
          class="w-16 rounded-md border border-line bg-deep px-2 py-0.5 text-center text-[13px] text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60"
        />
        <span class="text-[13px] text-muted">days</span>
      </form>
    </div>
    """
  end

  @doc """
  The filter in a narrow column: the tags picked as chips, a menu to pick
  one more, Any or All once two are picked, and the days, when set.
  """
  attr :filter, :map, required: true
  attr :tags, :list, required: true, doc: "every tag in the deck"

  def compact(assigns) do
    picked = MapSet.new(assigns.filter.tags, &String.downcase/1)

    assigns =
      assign(
        assigns,
        :offered,
        Enum.reject(assigns.tags, &MapSet.member?(picked, String.downcase(&1.name)))
      )

    ~H"""
    <div id="card-filter-tags" class="flex flex-wrap items-center gap-1">
      <button
        :for={tag <- @filter.tags}
        type="button"
        phx-click="toggle_tag"
        phx-value-name={tag}
        title={"Stop picking #{tag}"}
        class="inline-flex cursor-pointer items-center gap-1 rounded-full border border-accent/60 bg-accent-soft py-0.5 pl-2 pr-1 text-[11px] text-accent-strong"
      >
        {tag} <.icon name="hero-x-mark-micro" class="size-3" />
      </button>
      <span
        :if={@filter.days}
        class="inline-flex items-center gap-1 rounded-full border border-line bg-deep py-0.5 pl-2 pr-1 text-[11px] text-muted"
      >
        {if @filter.days == 1, do: "Today", else: "Last #{@filter.days} days"}
        <button
          type="button"
          phx-click="set_days"
          phx-value-days=""
          title="Any time"
          class="flex cursor-pointer items-center rounded-full hover:text-ink"
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </button>
      </span>
      <%!-- A new menu for each tag picked, so it shows its prompt again. --%>
      <form
        :if={@offered != []}
        id={"card-filter-add-#{length(@filter.tags)}"}
        phx-change="filter_add_tag"
      >
        <select
          name="tag"
          aria-label="Pick a tag"
          class="cursor-pointer rounded-full border border-dashed border-line bg-transparent py-0.5 pl-2 pr-1 text-[11px] text-muted outline-none transition-colors hover:border-accent/60 hover:text-ink"
        >
          <option value="">+ Tag</option>
          <option :for={tag <- @offered} value={tag.name}>{tag.name} ({tag.cards})</option>
        </select>
      </form>
      <.match_toggle
        :if={length(@filter.tags) > 1}
        id="card-filter-match"
        match={@filter.match}
        enabled
        small
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :match, :atom, required: true
  attr :enabled, :boolean, required: true
  attr :small, :boolean, default: false

  defp match_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label="Cards with"
      title={!@enabled && "Pick two tags or more to choose"}
      class={[
        "flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5",
        !@enabled && "opacity-50"
      ]}
    >
      <button
        :for={{match, label} <- [any: "Any tag", all: "All tags"]}
        type="button"
        id={"#{@id}-#{match}"}
        role="radio"
        aria-checked={to_string(@match == match)}
        phx-click="set_match"
        phx-value-match={match}
        disabled={!@enabled}
        class={[
          "cursor-pointer rounded px-2 transition-colors disabled:cursor-default",
          if(@small, do: "py-0 text-[10.5px]", else: "py-0.5 text-xs"),
          if(@match == match, do: "bg-active text-ink", else: "text-faint hover:text-ink")
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc "A DOM id for a tag, which may hold spaces and any letter."
  def tag_id(name) do
    :crypto.hash(:sha256, String.downcase(name))
    |> binary_part(0, 6)
    |> Base.url_encode64(padding: false)
  end
end
