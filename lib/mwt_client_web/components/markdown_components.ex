defmodule MWTClientWeb.MarkdownComponents do
  @moduledoc """
  Markdown on a page, for any app: rendered (`markdown/1`), or rendered with
  a tab to read the text as it was written (`markdown_view/1`).

  Rendering goes through `MWTClient.Markdown`, which keeps raw HTML out, so
  text from anywhere (an agent, an import) is fit to show. The look comes
  from the `.markdown` rules in `app.css`.
  """
  use Phoenix.Component

  import MWTClientWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  `text`, rendered.

  ## Examples

      <.markdown id="note-preview" text={@note.body} />
  """
  attr :id, :string, default: nil
  attr :text, :string, required: true
  attr :class, :any, default: nil

  def markdown(assigns) do
    ~H"""
    <article id={@id} class={["markdown", @class]}>
      {Phoenix.HTML.raw(MWTClient.Markdown.to_html(@text))}
    </article>
    """
  end

  @doc """
  `text` in a panel with two tabs: Markdown (rendered, the default) and Raw
  (the text as written). Switching happens in the browser and stays across
  updates of the page. The `header` slot fills the left of the tab row.

  ## Examples

      <.markdown_view id="handoff-body" text={@handoff.body}>
        <:header>Written by the agent</:header>
      </.markdown_view>
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :class, :any, default: nil
  attr :body_class, :any, default: "px-4 py-3"
  slot :header

  def markdown_view(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <div class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-1.5 text-[12px]">
        <div class="flex min-w-0 flex-1 items-center gap-2">{render_slot(@header)}</div>
        <div
          role="tablist"
          aria-label="How to show it"
          class="flex shrink-0 items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
        >
          <button
            type="button"
            role="tab"
            id={"#{@id}-tab-rendered"}
            aria-selected="true"
            aria-controls={"#{@id}-rendered"}
            phx-click={show(@id, "rendered")}
            class={tab_class()}
          >
            <.icon name="hero-eye-micro" class="size-3.5" /> Markdown
          </button>
          <button
            type="button"
            role="tab"
            id={"#{@id}-tab-raw"}
            aria-selected="false"
            aria-controls={"#{@id}-raw"}
            phx-click={show(@id, "raw")}
            class={tab_class()}
          >
            <.icon name="hero-code-bracket-micro" class="size-3.5" /> Raw
          </button>
        </div>
      </div>
      <div id={"#{@id}-rendered"} role="tabpanel" class={@body_class}>
        <.markdown text={@text} class="text-[13px] leading-6" />
      </div>
      <%!-- White space is kept, so the text sits tight against its tags. --%>
      <pre
        id={"#{@id}-raw"}
        role="tabpanel"
        class={[
          "hidden whitespace-pre-wrap break-words font-mono text-[12px] leading-5 text-ink",
          @body_class
        ]}
        phx-no-format
      >{@text}</pre>
    </div>
    """
  end

  defp tab_class,
    do:
      "flex h-5 cursor-pointer items-center gap-1 rounded px-1.5 text-[11px] text-faint transition-colors hover:text-ink aria-selected:bg-active aria-selected:text-ink"

  defp show(id, which) do
    other = if which == "raw", do: "rendered", else: "raw"

    JS.show(to: "##{id}-#{which}")
    |> JS.hide(to: "##{id}-#{other}")
    |> JS.set_attribute({"aria-selected", "true"}, to: "##{id}-tab-#{which}")
    |> JS.set_attribute({"aria-selected", "false"}, to: "##{id}-tab-#{other}")
  end
end
