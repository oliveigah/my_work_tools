defmodule MWTClientWeb.FlashcardsLive.Components do
  @moduledoc """
  The small pieces the flash cards views share: a tag label, the fields a
  card is written in, how well a card is known, when it is due, and the
  words for the waits between boxes.
  """
  use MWTClientWeb, :html

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Schedule

  @doc "One tag, as a small label."
  attr :name, :string, required: true
  attr :class, :any, default: nil

  def tag_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex max-w-40 items-center gap-1 truncate rounded-full border border-line-soft bg-deep px-2 py-0.5 text-[10.5px] leading-4 text-muted",
      @class
    ]}>
      <span class="size-1.5 shrink-0 rounded-full bg-accent/70"></span>
      <span class="truncate">{@name}</span>
    </span>
    """
  end

  @doc """
  The fields a card is written in: question, answer, tags and, unless
  `compact`, source. Used by the Cards editor and by a session, to correct
  a card as it is asked.

  Tags are chips, each with its ×, kept in the form as `FORM[tags][]`.
  Enter or a comma in the tag field sends what is typed as `add_tag`, and
  Backspace in it, empty, sends `remove_tag` for the last chip; both carry
  `form`, the form's name, so one handler serves every form. With Enter
  and nothing typed, the form is submitted. Whatever is typed and not yet
  added is sent as `FORM[new_tag]` and kept on save.
  """
  attr :form, :any, required: true
  attr :id, :string, required: true, doc: "prefix of the fields' ids, unique per form shown"
  attr :tags, :list, required: true, doc: "every tag in the deck, for suggestions"
  attr :compact, :boolean, default: false
  attr :focus, :boolean, default: false, doc: "puts the cursor in the question once shown"

  def card_fields(assigns) do
    chosen = chosen(assigns.form[:tags].value)

    assigns =
      assign(assigns,
        chosen: chosen,
        chosen_keys: Enum.map(chosen, &String.downcase/1),
        name: assigns.form.name
      )

    ~H"""
    <.input
      field={@form[:front]}
      id={"#{@id}-front"}
      type="textarea"
      label="Question"
      rows={if @compact, do: "2", else: "3"}
      maxlength={Card.max_front()}
      phx-debounce="250"
      phx-mounted={@focus && JS.focus()}
      placeholder="Why do concurrent agents use separate Git worktrees?"
    />
    <.input
      field={@form[:back]}
      id={"#{@id}-back"}
      type="textarea"
      label="Answer"
      rows={if @compact, do: "5", else: "7"}
      maxlength={Card.max_back()}
      phx-debounce="250"
      placeholder="Each checkout has its own branch, files and index, so concurrent changes stay independent. Markdown works here."
    />
    <div>
      <label
        for={"#{@id}-tag-input"}
        class="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted"
      >
        Tags
      </label>
      <div
        id={"#{@id}-tags"}
        class={[
          "flex min-h-9 flex-wrap items-center gap-1.5 rounded-md border bg-deep px-2 py-1.5 transition-colors focus-within:border-accent/60 focus-within:ring-2 focus-within:ring-accent/15",
          if(@form[:tags].errors != [], do: "border-bad/70", else: "border-line")
        ]}
      >
        <span
          :for={tag <- @chosen}
          class="inline-flex items-center gap-1 rounded-full border border-accent/40 bg-accent-soft py-0.5 pl-2 pr-1 text-xs text-accent-strong"
        >
          <input type="hidden" name={"#{@name}[tags][]"} value={tag} />
          {tag}
          <button
            type="button"
            phx-click="remove_tag"
            phx-value-form={@name}
            phx-value-name={tag}
            title={"Remove #{tag}"}
            class="flex size-4 cursor-pointer items-center justify-center rounded-full text-accent/70 transition-colors hover:bg-accent/20 hover:text-accent-strong"
          >
            <.icon name="hero-x-mark-micro" class="size-3" />
          </button>
        </span>
        <input
          type="text"
          id={"#{@id}-tag-input"}
          name={"#{@name}[new_tag]"}
          value={@form[:new_tag].value}
          list={"#{@id}-tag-options"}
          data-form={@name}
          phx-hook=".TagInput"
          maxlength={Card.max_tag()}
          autocomplete="off"
          placeholder={if @chosen == [], do: "mwt_client, agent sandbox…", else: "Add a tag"}
          class="min-w-28 flex-1 bg-transparent py-0.5 text-[13px] text-ink outline-none placeholder:text-faint"
        />
        <datalist id={"#{@id}-tag-options"}>
          <option
            :for={tag <- @tags}
            :if={String.downcase(tag.name) not in @chosen_keys}
            value={tag.name}
          >
          </option>
        </datalist>
      </div>
      <p :for={{message, _opts} <- @form[:tags].errors} class="mt-1 text-xs text-bad">{message}</p>
      <div
        :if={Enum.any?(@tags, &(String.downcase(&1.name) not in @chosen_keys))}
        id={"#{@id}-tag-suggestions"}
        class="mt-1.5 flex flex-wrap items-center gap-1"
      >
        <span class="mr-0.5 text-[11px] text-faint">Enter or comma adds a tag. In use:</span>
        <button
          :for={
            tag <- @tags |> Enum.reject(&(String.downcase(&1.name) in @chosen_keys)) |> Enum.take(8)
          }
          type="button"
          phx-click="add_tag"
          phx-value-form={@name}
          phx-value-name={tag.name}
          class="cursor-pointer rounded-full border border-dashed border-line px-2 py-0.5 text-[11px] text-muted transition-colors hover:border-accent/60 hover:text-accent"
        >
          + {tag.name}
        </button>
      </div>
    </div>
    <.input
      :if={!@compact}
      field={@form[:source]}
      id={"#{@id}-source"}
      label="Source"
      maxlength={Card.max_source()}
      phx-debounce="250"
      placeholder="Thread: concurrent development workflow"
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TagInput">
      export default {
        mounted() {
          this.el.addEventListener("keydown", event => {
            const typed = this.el.value.trim()
            if ((event.key === "Enter" || event.key === ",") && typed !== "") {
              event.preventDefault()
              this.pushEvent("add_tag", {form: this.el.dataset.form, name: typed})
              this.el.value = ""
            } else if (event.key === "Backspace" && this.el.value === "") {
              this.pushEvent("remove_tag", {form: this.el.dataset.form, last: true})
            }
          })
        }
      }
    </script>
    """
  end

  @doc "The tags a card form holds, as a list, however they came in."
  def chosen(value) when is_list(value), do: Enum.reject(value, &(&1 == ""))

  def chosen(value) when is_binary(value) do
    case Card.tags(value) do
      {:ok, tags} -> tags
      {:error, _message} -> []
    end
  end

  def chosen(_value), do: []

  @doc "A key, as the page shows it."
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class="mx-0.5 rounded border border-line bg-deep px-1 py-px font-mono text-[10px] font-normal text-muted">
      {render_slot(@inner_block)}
    </kbd>
    """
  end

  @doc """
  How well a card is known: one bar per box, filled up to the card's. A card
  never answered shows "New".
  """
  attr :id, :string, default: nil
  attr :box, :integer, required: true
  attr :reviews, :integer, required: true
  attr :class, :any, default: nil

  def strength(assigns) do
    assigns = assign(assigns, top: Schedule.top())

    ~H"""
    <span
      id={@id}
      class={["inline-flex items-center gap-[3px]", @class]}
      title={strength_title(@box, @reviews)}
      aria-label={strength_title(@box, @reviews)}
    >
      <%= if @reviews == 0 do %>
        <span class="rounded-full bg-accent-soft px-1.5 py-px text-[10px] font-medium text-accent-strong">
          New
        </span>
      <% else %>
        <span
          :for={bar <- 1..@top}
          class={[
            "h-2.5 w-[4px] rounded-full transition-colors",
            if(bar <= @box, do: level_color(@box), else: "bg-line")
          ]}
        ></span>
      <% end %>
    </span>
    """
  end

  @doc "When a card is due, read against `now`."
  attr :due_at, :any, required: true
  attr :now, :any, required: true
  attr :class, :any, default: nil

  def due(assigns) do
    ~H"""
    <span class={[
      "shrink-0 font-mono text-[10px]",
      if(DateTime.compare(@due_at, @now) == :gt, do: "text-faint", else: "text-warn"),
      @class
    ]}>
      {due_label(@due_at, @now)}
    </span>
    """
  end

  @doc "The title a strength meter carries."
  def strength_title(_box, 0), do: "New: not answered yet"
  def strength_title(box, _reviews), do: "Box #{box} of #{Schedule.top()}"

  @doc "The colour of the bars of a card in `box`."
  def level_color(box) when box <= 1, do: "bg-bad"
  def level_color(box) when box <= 3, do: "bg-warn"
  def level_color(_box), do: "bg-ok"

  @doc """
  When something due at `due_at` is due, in words, against `now`: in days
  on this machine's calendar, so a card due tomorrow morning is due
  "tomorrow", however few hours away that is.
  """
  def due_label(due_at, now) do
    days = Date.diff(local_date(due_at), local_date(now))

    cond do
      DateTime.compare(due_at, now) != :gt -> "due"
      days <= 0 -> "later today"
      days == 1 -> "tomorrow"
      true -> "in " <> days_label(days)
    end
  end

  defp local_date(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
    |> NaiveDateTime.to_date()
  end

  @doc "A wait of `days` as the vote buttons say it."
  def wait_label(0), do: "next session"
  def wait_label(1), do: "tomorrow"
  def wait_label(days), do: "in " <> days_label(days)

  @doc "A number of days, in weeks once it is a whole number of them."
  def days_label(1), do: "1 day"
  def days_label(7), do: "1 week"
  def days_label(days) when rem(days, 7) == 0, do: "#{div(days, 7)} weeks"
  def days_label(days), do: "#{days} days"
end
