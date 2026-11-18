defmodule MWTClientWeb.FlashcardsLive.Settings do
  @moduledoc """
  The Settings view: how sessions run, and how cards come back, laid out so
  why a card shows up when it does is never a guess.
  """
  use MWTClientWeb, :html

  import MWTClientWeb.FlashcardsLive.Components

  alias MWTClient.Flashcards.Schedule
  alias MWTClient.Flashcards.Settings

  attr :settings, :any, required: true
  attr :form, :any, required: true

  def page(assigns) do
    assigns = assign(assigns, waits: Schedule.waits(), max_size: Settings.max_size())

    ~H"""
    <div id="flashcard-settings" class="mx-auto w-full max-w-2xl px-6 py-8">
      <h1 class="text-lg font-semibold text-ink">Settings</h1>
      <p class="mt-0.5 text-[13px] text-muted">
        How remember sessions run. Changes are kept as you make them.
      </p>

      <div class="mt-5 divide-y divide-line-soft rounded-xl border border-line bg-panel shadow-sm">
        <.form
          for={@form}
          id="settings-form"
          phx-change="settings_change"
          phx-submit="settings_change"
          class="flex items-center gap-4 px-5 py-4"
        >
          <div class="min-w-0 flex-1">
            <label for="settings-size" class="text-[13px] font-medium text-ink">Cards per session</label>
            <p class="mt-0.5 text-xs text-muted">
              How many cards a session asks, unless you start it with another number.
            </p>
          </div>
          <input
            type="number"
            id="settings-size"
            name={@form[:session_size].name}
            value={@form[:session_size].value}
            min="1"
            max={@max_size}
            phx-debounce="300"
            class="w-20 rounded-md border border-line bg-deep px-2 py-1.5 text-center text-[13px] text-ink outline-none transition-colors focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
        </.form>

        <div class="flex items-center gap-4 px-5 py-4">
          <div class="min-w-0 flex-1">
            <p class="text-[13px] font-medium text-ink">Bring forgotten cards back</p>
            <p class="mt-0.5 text-xs text-muted">
              A card you forget is asked again at the end of the session, until you remember it.
            </p>
          </div>
          <.switch
            id="settings-repeat"
            on={@settings.repeat_forgotten}
            label="Bring forgotten cards back"
            phx-click="toggle_setting"
            phx-value-kind="repeat_forgotten"
            phx-value-on={to_string(!@settings.repeat_forgotten)}
          />
        </div>

        <div class="flex items-center gap-4 px-5 py-4">
          <div class="min-w-0 flex-1">
            <p class="text-[13px] font-medium text-ink">Fill sessions with cards not due yet</p>
            <p class="mt-0.5 text-xs text-muted">
              When fewer cards are due than a session asks, add the ones coming due soonest.
              Off, a session asks only the cards due, so it can be short, or empty.
            </p>
          </div>
          <.switch
            id="settings-fill"
            on={@settings.fill}
            label="Fill sessions with cards not due yet"
            phx-click="toggle_setting"
            phx-value-kind="fill"
            phx-value-on={to_string(!@settings.fill)}
          />
        </div>
      </div>

      <h2 class="mb-2.5 mt-8 text-[11px] font-semibold uppercase tracking-wider text-faint">
        How cards come back
      </h2>
      <div id="schedule-explainer" class="rounded-xl border border-line bg-panel p-5 shadow-sm">
        <p class="text-[13px] leading-relaxed text-muted">
          Each card sits in one of six boxes. The higher its box, the longer it waits before a session asks it again.
          Your vote moves it:
        </p>
        <ul class="mt-3 grid gap-1.5 text-[13px] sm:grid-cols-2">
          <li class="flex items-center gap-2">
            <span class="size-2 rounded-full bg-bad"></span>
            <span class="font-medium text-ink">Forgot</span>
            <span class="text-muted">back to box 1</span>
          </li>
          <li class="flex items-center gap-2">
            <span class="size-2 rounded-full bg-warn"></span>
            <span class="font-medium text-ink">Hard</span>
            <span class="text-muted">stays in its box</span>
          </li>
          <li class="flex items-center gap-2">
            <span class="size-2 rounded-full bg-ok"></span>
            <span class="font-medium text-ink">Good</span>
            <span class="text-muted">up one box</span>
          </li>
          <li class="flex items-center gap-2">
            <span class="size-2 rounded-full bg-accent"></span>
            <span class="font-medium text-ink">Easy</span>
            <span class="text-muted">up two boxes</span>
          </li>
        </ul>

        <div class="mt-5 grid grid-cols-6 gap-1.5">
          <div
            :for={{box, days} <- @waits}
            id={"schedule-box-#{box}"}
            class="flex flex-col items-center gap-1.5 rounded-lg border border-line-soft bg-deep/50 px-1 py-2.5"
          >
            <.strength box={box} reviews={1} />
            <span class="text-[11px] font-medium text-ink">Box {box}</span>
            <span class="text-center text-[10.5px] leading-tight text-muted">{wait_label(days)}</span>
          </div>
        </div>
        <p class="mt-4 text-xs text-faint">
          New cards are due as soon as they are written. A session asks the due cards first, the least known first,
          and in a shuffled order.
        </p>
      </div>
    </div>
    """
  end
end
