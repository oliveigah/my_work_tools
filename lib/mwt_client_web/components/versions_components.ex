defmodule MWTClientWeb.VersionsComponents do
  @moduledoc """
  The versions of a note, a diagram or a flash card, as their pages show
  them: a button that opens them, and a panel listing each earlier version
  with who replaced it and when. Choosing one shows what restoring it would
  change, and *Restore* makes it current (`MWTClient.Versions`).

  The page owns the events: `show_versions`, `hide_versions`,
  `select_version` and `restore_version`, the last two with a `version`
  value.
  """
  use Phoenix.Component

  import MWTClientWeb.CoreComponents, only: [icon: 1]

  alias MWTClient.Versions
  alias MWTClient.Versions.Diff

  @doc "The button that opens the versions of the item open."
  attr :id, :string, required: true
  attr :open, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil

  def versions_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={if @open, do: "hide_versions", else: "show_versions"}
      disabled={@disabled}
      title="Versions"
      aria-pressed={to_string(@open)}
      class={[
        "flex cursor-pointer items-center gap-1 rounded px-1.5 text-[11px] transition-colors disabled:cursor-default disabled:opacity-40",
        if(@open, do: "bg-active text-ink", else: "text-faint hover:text-ink"),
        @class
      ]}
    >
      <.icon name="hero-clock-micro" class="size-3.5" />
      <span class="hidden lg:inline">Versions</span>
    </button>
    """
  end

  @doc """
  The panel of versions. `current` is the item's content now, in the
  fields a version keeps; `kind` says how to show what differs.
  """
  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:note, :diagram, :card]
  attr :versions, :list, required: true
  attr :selected, :integer, default: nil, doc: "the number of the version chosen"
  attr :current, :map, required: true

  def versions_panel(assigns) do
    assigns =
      assign(assigns, :chosen, Enum.find(assigns.versions, &(&1.version == assigns.selected)))

    ~H"""
    <aside
      id={@id}
      class="flex w-80 shrink-0 flex-col border-l border-line-soft bg-panel"
      aria-label="Versions"
    >
      <div class="flex h-9 shrink-0 items-center justify-between border-b border-line-soft pl-3 pr-1.5">
        <span class="text-[12px] font-medium text-ink">Versions</span>
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click="hide_versions"
          title="Close"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>

      <div
        :if={@versions == []}
        id={"#{@id}-empty"}
        class="p-4 text-[12px] leading-relaxed text-muted"
      >
        No earlier versions yet. One is kept before every change an agent makes, before a
        restore, and every 10 minutes while you edit.
      </div>

      <ol :if={@versions != []} id={"#{@id}-list"} class="min-h-0 flex-1 overflow-y-auto py-1">
        <li :for={version <- @versions}>
          <button
            type="button"
            id={"#{@id}-#{version.version}"}
            phx-click="select_version"
            phx-value-version={version.version}
            aria-current={to_string(version.version == @selected)}
            class={[
              "flex w-full cursor-pointer flex-col items-start gap-0.5 px-3 py-1.5 text-left transition-colors",
              if(version.version == @selected, do: "bg-active", else: "hover:bg-hover")
            ]}
          >
            <span class="flex items-center gap-1.5 text-[12px] text-ink">
              <.icon
                :if={Versions.agent?(version.replaced_by)}
                name="hero-sparkles-micro"
                class="size-3.5 text-accent"
              />
              {replaced_words(version)}
            </span>
            <span class="text-[11px] text-faint">
              {when_label(version.replaced_at)} · saved {when_label(version.saved_at)}
            </span>
          </button>

          <div
            :if={version.version == @selected and @chosen}
            id={"#{@id}-#{version.version}-preview"}
            class="border-y border-line-soft bg-deep px-3 py-2"
          >
            <p class="mb-1.5 text-[11px] text-muted">Restoring it changes this:</p>
            <.difference kind={@kind} from={@current} to={@chosen.content} id={"#{@id}-diff"} />
            <button
              type="button"
              id={"#{@id}-restore"}
              phx-click="restore_version"
              phx-value-version={version.version}
              class="mt-2 flex cursor-pointer items-center gap-1 rounded-md border border-line px-2 py-1 text-[11px] text-ink transition-colors hover:border-accent/60 hover:text-accent"
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Restore this version
            </button>
          </div>
        </li>
      </ol>
    </aside>
    """
  end

  @doc """
  What changes from `from` to `to`, two contents of the same kind of item.
  Used here, and on the cards of changes agents ask to make.
  """
  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:note, :diagram, :card]
  attr :from, :map, required: true
  attr :to, :map, required: true

  def difference(%{kind: :note} = assigns) do
    assigns =
      assign(assigns,
        title: title_change(assigns.from, assigns.to),
        lines: Diff.around_changes(Diff.lines(assigns.from[:body] || "", assigns.to[:body] || ""))
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-1.5">
      <.title_change :if={@title} change={@title} />
      <.text_lines lines={@lines} />
    </div>
    """
  end

  def difference(%{kind: :diagram} = assigns) do
    assigns =
      assign(assigns,
        title: title_change(assigns.from, assigns.to),
        elements:
          Diff.elements_words(
            Diff.elements(assigns.from[:elements] || [], assigns.to[:elements] || [])
          )
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-1.5 text-[12px]">
      <.title_change :if={@title} change={@title} />
      <p :if={@elements} class="text-ink">{@elements}</p>
      <p :if={!@title and !@elements} class="text-muted">Nothing differs.</p>
    </div>
    """
  end

  def difference(%{kind: :card} = assigns) do
    assigns =
      assign(assigns,
        changes:
          Diff.fields(assigns.from, assigns.to, [:front, :back, :tags, :source, :uncertain])
      )

    ~H"""
    <dl id={@id} class="flex flex-col gap-1.5 text-[12px]">
      <div :for={{field, old, new} <- @changes}>
        <dt class="text-[11px] text-faint">{field_label(field)}</dt>
        <dd class="whitespace-pre-wrap break-words text-bad line-through decoration-bad/40">
          {field_text(old)}
        </dd>
        <dd class="whitespace-pre-wrap break-words text-ok">{field_text(new)}</dd>
      </div>
      <p :if={@changes == []} class="text-muted">Nothing differs.</p>
    </dl>
    """
  end

  attr :change, :any, required: true

  defp title_change(assigns) do
    ~H"""
    <p class="text-[12px]">
      <span class="text-faint">Title</span>
      <span class="text-bad line-through decoration-bad/40">{elem(@change, 0)}</span>
      <span class="text-faint">→</span>
      <span class="text-ok">{elem(@change, 1)}</span>
    </p>
    """
  end

  attr :lines, :list, required: true

  defp text_lines(assigns) do
    ~H"""
    <div class="max-h-80 overflow-auto rounded border border-line-soft bg-app font-mono text-[11px] leading-snug">
      <%= for line <- @lines do %>
        <%= case line do %>
          <% {:skip, count} -> %>
            <div class="px-2 py-0.5 text-faint">⋯ {count} unchanged</div>
          <% {:del, text} -> %>
            <div class="whitespace-pre-wrap break-words bg-bad/10 px-2 text-bad">- {text}</div>
          <% {:ins, text} -> %>
            <div class="whitespace-pre-wrap break-words bg-ok/10 px-2 text-ok">+ {text}</div>
          <% {:eq, text} -> %>
            <div class="whitespace-pre-wrap break-words px-2 text-muted">{"  "}{text}</div>
        <% end %>
      <% end %>
      <div :if={Enum.all?(@lines, &match?({:eq, _}, &1))} class="px-2 py-0.5 text-faint">
        The text is the same.
      </div>
    </div>
    """
  end

  defp title_change(from, to) do
    if from[:title] != to[:title], do: {from[:title], to[:title]}
  end

  defp replaced_words(%{how: :restore}), do: "Before you restored an earlier one"
  defp replaced_words(%{replaced_by: :you}), do: "Before your edits"

  defp replaced_words(%{replaced_by: by}) do
    "Before " <> lower_first(Versions.who(by)) <> " changed it"
  end

  # "An agent…" reads "an agent…" mid-sentence; an agent's own name stays.
  defp lower_first("An " <> rest), do: "an " <> rest
  defp lower_first(text), do: text

  defp field_label(:front), do: "Front"
  defp field_label(:back), do: "Back"
  defp field_label(:tags), do: "Tags"
  defp field_label(:source), do: "Source"
  defp field_label(:uncertain), do: "Uncertain"

  defp field_text(nil), do: "—"
  defp field_text([]), do: "—"
  defp field_text(list) when is_list(list), do: Enum.join(list, ", ")
  defp field_text(text), do: text

  # Today's by the time, older ones by the day, on this machine's clock.
  defp when_label(%DateTime{} = at) do
    local =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()

    today = NaiveDateTime.to_date(NaiveDateTime.local_now())

    cond do
      NaiveDateTime.to_date(local) == today -> Calendar.strftime(local, "%H:%M")
      local.year == today.year -> Calendar.strftime(local, "%b %-d, %H:%M")
      true -> Calendar.strftime(local, "%b %-d, %Y")
    end
  end
end
