defmodule MWTClientWeb.UIComponents do
  @moduledoc """
  Small controls every app's pages share: a switch, and the "?" that holds
  an explanation a page doesn't need to show all the time.
  """
  use Phoenix.Component

  import MWTClientWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  A switch: on is to the right, and green, or red with `tone={:bad}` for a
  switch whose on is an alarm.
  """
  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :ok, values: [:ok, :bad]

  attr :rest, :global,
    include: ~w(phx-click phx-value-id phx-value-minutes phx-value-kind phx-value-on disabled)

  def switch(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      role="switch"
      aria-checked={to_string(@on)}
      aria-label={@label}
      title={@label}
      class={[
        "relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full border transition-colors duration-200",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        cond do
          not @on -> "border-line bg-deep hover:border-muted"
          @tone == :bad -> "border-bad/70 bg-bad"
          true -> "border-ok/60 bg-ok/80"
        end
      ]}
      {@rest}
    >
      <span class={[
        "inline-block size-3.5 rounded-full shadow-sm transition-transform duration-200",
        if(@on, do: "translate-x-[1.05rem] bg-white", else: "translate-x-0.5 bg-muted")
      ]}></span>
    </button>
    """
  end

  @doc """
  A small "?" that shows its text while hovered or focused, for the
  explanations a screen doesn't need to show all the time.

  The text is positioned fixed by a hook, so cards that clip their content
  don't clip it. Its position and open state are set in the browser and kept
  across patches; its words still follow the server.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "More about this"
  attr :class, :any, default: nil

  attr :tip_class, :any,
    default: "w-max max-w-80",
    doc: "the text's width, for one that holds a list"

  slot :inner_block, required: true

  def help(assigns) do
    ~H"""
    <span id={@id} phx-hook=".Help" class={["inline-flex shrink-0 align-middle", @class]}>
      <button
        type="button"
        aria-label={@label}
        aria-describedby={"#{@id}-tip"}
        data-help-trigger
        class="inline-flex size-4 cursor-help items-center justify-center rounded-full text-faint transition-colors hover:text-accent focus-visible:text-accent focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
      >
        <.icon name="hero-question-mark-circle-micro" class="size-3.5" />
      </button>
      <span
        id={"#{@id}-tip"}
        role="tooltip"
        data-help-tip
        phx-mounted={JS.ignore_attributes(["style", "data-open"])}
        class={[
          "pointer-events-none invisible fixed left-0 top-0 z-[70] translate-y-0.5 rounded-lg border border-line bg-panel px-3 py-2 text-left text-[11px] font-normal normal-case leading-[1.125rem] tracking-normal text-ink opacity-0 shadow-xl shadow-black/15 transition-[opacity,translate] duration-150 data-open:visible data-open:translate-y-0 data-open:opacity-100 dark:shadow-black/50",
          @tip_class
        ]}
      >
        {render_slot(@inner_block)}
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Help">
      export default {
        mounted() {
          this.trigger = this.el.querySelector("[data-help-trigger]")
          this.tip = this.el.querySelector("[data-help-tip]")
          this.show = () => this.open()
          this.hide = () => this.close()
          this.toggle = (event) => {
            event.preventDefault()
            this.tip.hasAttribute("data-open") ? this.close() : this.open()
          }
          this.onKey = (event) => { if (event.key === "Escape") this.close() }
          this.el.addEventListener("mouseenter", this.show)
          this.el.addEventListener("mouseleave", this.hide)
          this.trigger.addEventListener("focus", this.show)
          this.trigger.addEventListener("blur", this.hide)
          this.trigger.addEventListener("click", this.toggle)
          this.trigger.addEventListener("keydown", this.onKey)
        },
        destroyed() {
          this.close()
        },
        open() {
          const gap = 8
          const box = this.trigger.getBoundingClientRect()
          this.tip.setAttribute("data-open", "")
          const tip = this.tip.getBoundingClientRect()
          // Below when it fits, else above when it fits there; fitting
          // neither, on the side with more room.
          const roomBelow = window.innerHeight - box.bottom
          const below = roomBelow >= tip.height + gap ||
            (box.top < tip.height + gap && roomBelow >= box.top)
          const top = below ? box.bottom + gap : box.top - tip.height - gap
          const left = Math.min(
            Math.max(gap, box.left + box.width / 2 - tip.width / 2),
            window.innerWidth - tip.width - gap
          )
          this.tip.style.top = `${Math.max(gap, top)}px`
          this.tip.style.left = `${left}px`
          window.addEventListener("scroll", this.hide, {capture: true, passive: true})
          window.addEventListener("resize", this.hide, {passive: true})
        },
        close() {
          this.tip?.removeAttribute("data-open")
          window.removeEventListener("scroll", this.hide, {capture: true})
          window.removeEventListener("resize", this.hide)
        },
      }
    </script>
    """
  end
end
