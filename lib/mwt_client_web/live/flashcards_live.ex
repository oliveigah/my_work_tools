defmodule MWTClientWeb.FlashcardsLive do
  @moduledoc """
  The flash cards tool, in three views:

    * **Remember** - pick what to go over by mixing and matching tags
      (`MWTClientWeb.FlashcardsLive.Filter`), how recently the cards were
      written and how many, then a session: one card at a time, its answer
      shown on a flip, and a vote that decides when it comes back
      (`MWTClient.Flashcards.Schedule`). Once the answer shows, the card can
      be corrected, or removed from the deck as not important;
    * **Cards** - the cards the same filter picks, found by their words, and
      written or changed beside how they will look; the removed ones apart;
    * **Settings** - how sessions run.

  One filter serves both views, so what Remember would ask is what Cards
  lists. A session lives in this page (`MWTClient.Flashcards.Session`), but
  every vote, correction and removal is kept as it is made, so leaving loses
  nothing. Cards are written from outside this page too, by agents through
  MCP, so it follows `MWTClient.Flashcards.Library.subscribe/1` and redraws
  what others change.
  """
  use MWTClientWeb, :live_view

  @behaviour MWTClientWeb.Hooks.Places

  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library
  alias MWTClient.Flashcards.Schedule
  alias MWTClient.Flashcards.Session
  alias MWTClient.Places
  alias MWTClient.Tools
  alias MWTClientWeb.FlashcardsLive.Cards
  alias MWTClientWeb.FlashcardsLive.Components
  alias MWTClientWeb.FlashcardsLive.Remember
  alias MWTClientWeb.FlashcardsLive.Settings

  @views [
    {:remember, "Remember", "hero-academic-cap-micro"},
    {:cards, "Cards", "hero-rectangle-stack-micro"},
    {:settings, "Settings", "hero-adjustments-horizontal-micro"}
  ]

  # Tags the picker's cloud shows before it is asked for more.
  @cloud_size 24
  # Cards Remember shows of those the filter picks.
  @matching 5

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Library.subscribe(username)
    settings = Library.settings(username)

    # Back where it was left (`MWTClientWeb.Hooks.Places`): the view and
    # card open come back by the address; the rest from here.
    place = Places.recall(username, :flashcards)
    session = place[:session] && fresh_session(username, place.session)

    {:ok,
     socket
     |> assign(:page_title, "Flashcards")
     |> assign(:tool, Tools.fetch!(:flashcards))
     |> assign(:username, username)
     |> assign(:settings, settings)
     |> assign(:settings_form, settings_form(settings))
     |> assign(:filter, Map.get(place, :filter, %{tags: [], match: :any, days: nil, query: ""}))
     |> assign(:tag_query, Map.get(place, :tag_query, ""))
     |> assign(:more_tags?, false)
     |> assign(:size, settings.session_size)
     |> assign(:session, session)
     |> assign(:session_scope, session && place[:session_scope])
     |> assign(:edit_form, edit_form(session, place[:edit]))
     |> assign(:just_removed, nil)
     |> assign(:bin?, Map.get(place, :bin?, false))
     |> assign(:limit, Map.get(place, :limit, page_size()))
     |> assign(:card, nil)
     |> assign(:versions, nil)
     |> assign(:form_key, 0)
     |> assign(:sticky, Map.get(place, :sticky, %{"tags" => [], "source" => ""}))
     |> assign(:draft, place[:draft])
     |> assign_card_form(%{})
     |> refresh()}
  end

  @impl MWTClientWeb.Hooks.Places
  def place(socket) do
    %{card: card, card_form: card_form, edit_form: edit_form, draft: draft} = socket.assigns
    asked = socket.assigns.session && socket.assigns.session.current

    socket.assigns
    |> Map.take([:session, :session_scope, :filter, :tag_query, :bin?, :limit, :sticky])
    |> Map.merge(%{
      edit: edit_form && asked && %{for: asked.id, params: edit_form.params},
      # The card form as it was written in, until a draft taken back is shown.
      draft: draft || %{for: card && card.id, params: card_form.params}
    })
  end

  # A session left part way, with each card as it is now: one deleted or
  # removed meanwhile is skipped, as it would have been on the page.
  defp fresh_session(username, %Session{} = session) do
    session =
      [session.current | session.queue]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(session, fn %Card{id: id}, session ->
        case Library.get(username, id) do
          {:ok, %Card{removed_at: nil} = card} -> Session.refresh(session, card)
          _gone -> Session.drop(session, id)
        end
      end)

    if Session.done?(session) and Session.handled(session) == 0, do: nil, else: session
  end

  # A correction left half written, while the card it was for is still the
  # one asked.
  defp edit_form(%Session{current: %Card{id: id}}, %{for: id, params: params}),
    do: card_form(params, :edit)

  defp edit_form(_session, _edit), do: nil

  # The card form left half written comes back once, over the card it was
  # written for, or as the new card it was.
  defp restore_draft(%{assigns: %{draft: %{for: id, params: params}, card: card}} = socket) do
    socket = assign(socket, :draft, nil)
    if id == (card && card.id), do: assign_card_form(socket, params), else: socket
  end

  defp restore_draft(socket), do: socket

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :now, DateTime.utc_now())

    case {socket.assigns.live_action, params} do
      {:cards, %{"id" => id}} ->
        case Library.get(socket.assigns.username, id) do
          {:ok, card} ->
            {:noreply,
             socket
             |> open_card(card)
             |> restore_draft()
             |> assign(:bin?, Card.removed?(card))
             |> assign_list()}

          :error ->
            {:noreply,
             socket |> new_card() |> assign_list() |> put_flash(:error, "Card not found")}
        end

      {:cards, _params} ->
        socket = if socket.assigns.card, do: new_card(socket), else: socket
        {:noreply, socket |> restore_draft() |> assign_list()}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :views, @views)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tool={@tool}
      notices={@notices}
      update={@update}
      sandbox_waiting={@sandbox_waiting}
      notifications={@notifications}
      places={@places}
    >
      <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
        <nav
          id="flashcard-views"
          aria-label="Flashcards"
          class="flex h-9 shrink-0 items-stretch gap-0.5 border-b border-line-soft bg-panel px-2"
        >
          <.link
            :for={{view, label, icon} <- @views}
            id={"view-#{view}"}
            patch={view_path(view)}
            aria-current={@live_action == view && "page"}
            class={[
              "-mb-px flex items-center gap-1.5 border-b-2 px-3 text-[12.5px] transition-colors",
              if(@live_action == view,
                do: "border-accent font-medium text-ink",
                else: "border-transparent text-muted hover:text-ink"
              )
            ]}
          >
            <.icon
              name={icon}
              class={["size-3.5", if(@live_action == view, do: "text-accent", else: "text-faint")]}
            />
            {label}
            <span
              :if={view == :remember and @live_action != :remember and under_way?(@session)}
              id="session-waiting"
              title="A session is under way"
              class="size-1.5 animate-pulse rounded-full bg-accent"
            ></span>
          </.link>
          <div class="flex-1"></div>
          <span id="flashcard-totals" class="flex items-center gap-1.5 pr-1 text-[11px] text-faint">
            <span>{@totals.cards} {if @totals.cards == 1, do: "card", else: "cards"}</span>
            <span :if={@totals.due > 0} class="flex items-center gap-1 text-warn">
              · <span class="size-1.5 rounded-full bg-warn"></span> {@totals.due} due
            </span>
          </span>
        </nav>

        <%= case @live_action do %>
          <% :remember -> %>
            <div class="min-h-0 flex-1 overflow-y-auto bg-app">
              <%= cond do %>
                <% under_way?(@session) -> %>
                  <Remember.session
                    session={@session}
                    scope_label={scope_label(@session_scope)}
                    preview={Schedule.preview(@session.current)}
                    edit_form={@edit_form}
                    tags={@tags}
                    just_removed={@just_removed}
                  />
                <% @session -> %>
                  <Remember.summary session={@session} scope_label={scope_label(@session_scope)} />
                <% true -> %>
                  <Remember.start
                    filter={@filter}
                    picker={@picker}
                    count={@count}
                    size={@size}
                    fill={@settings.fill}
                    totals={@totals}
                    matching={@matching}
                    now={@now}
                  />
              <% end %>
            </div>
          <% :cards -> %>
            <div class="flex min-h-0 flex-1 overflow-hidden">
              <Cards.list
                entries={@entries}
                hidden={@hidden}
                count={@listed}
                removed_count={@removed_count}
                bin?={@bin?}
                filter={@filter}
                tags={@tags}
                current_id={@card && @card.id}
                now={@now}
              />
              <.resizer
                id="card-list-resizer"
                panel="card-list-panel"
                variable="--card-list-width"
                storage_key="mwt:card-list-width"
                axis="x"
                min="220"
                max="560"
              />
              <Cards.editor
                form={@card_form}
                form_key={@form_key}
                card={@card}
                tags={@tags}
                now={@now}
                versions?={@versions != nil}
              />
              <.versions_panel
                :if={@versions && @card}
                id="card-versions"
                kind={:card}
                versions={@versions.list}
                selected={@versions.selected}
                current={Map.take(@card, [:front, :back, :tags, :source])}
              />
            </div>
          <% :settings -> %>
            <div class="min-h-0 flex-1 overflow-y-auto bg-app">
              <Settings.page settings={@settings} form={@settings_form} />
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  ## The filter

  @impl true
  def handle_event("toggle_tag", %{"name" => name}, socket) do
    tags = socket.assigns.filter.tags

    tags =
      if Enum.any?(tags, &same_tag?(&1, name)),
        do: Enum.reject(tags, &same_tag?(&1, name)),
        else: tags ++ [name]

    {:noreply, socket |> assign(:tag_query, "") |> put_filter(tags: tags)}
  end

  def handle_event("clear_tags", _params, socket), do: {:noreply, put_filter(socket, tags: [])}

  def handle_event("set_match", %{"match" => match}, socket) do
    {:noreply, put_filter(socket, match: if(match == "all", do: :all, else: :any))}
  end

  def handle_event("set_days", %{"days" => days}, socket) do
    days =
      case Integer.parse(String.trim(to_string(days))) do
        {days, ""} when days > 0 -> min(days, 3650)
        _other -> nil
      end

    {:noreply, put_filter(socket, days: days)}
  end

  def handle_event("tag_search", %{"tag_query" => query}, socket) do
    {:noreply, socket |> assign(:tag_query, query) |> refresh()}
  end

  # Enter in the tag search picks the first tag it found.
  def handle_event("pick_tag", %{"tag_query" => query}, socket) do
    socket = socket |> assign(:tag_query, query) |> refresh()

    case socket.assigns.picker.cloud do
      [first | _rest] ->
        tags = socket.assigns.filter.tags ++ [first.name]
        {:noreply, socket |> assign(:tag_query, "") |> put_filter(tags: tags)}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("more_tags", _params, socket) do
    {:noreply, socket |> update(:more_tags?, &(!&1)) |> refresh()}
  end

  def handle_event("filter_add_tag", %{"tag" => name}, socket) when name != "" do
    tags = socket.assigns.filter.tags

    if Enum.any?(tags, &same_tag?(&1, name)),
      do: {:noreply, socket},
      else: {:noreply, put_filter(socket, tags: tags ++ [name])}
  end

  def handle_event("filter_add_tag", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, put_filter(socket, query: query)}
  end

  ## Remember

  def handle_event("set_size", %{"size" => size}, socket) do
    size = MWTClient.Flashcards.Settings.size(size, socket.assigns.settings.session_size)
    {:noreply, assign(socket, :size, size)}
  end

  def handle_event("start", params, socket) do
    size =
      MWTClient.Flashcards.Settings.size(Map.get(params, "size"), socket.assigns.size)

    {:noreply, start(assign(socket, :size, size), scope(socket.assigns.filter), size)}
  end

  def handle_event("flip", _params, socket), do: {:noreply, flip(socket)}

  def handle_event("vote", %{"grade" => grade}, socket) do
    case Schedule.grade(grade) do
      {:ok, grade} -> {:noreply, vote(socket, grade)}
      :error -> {:noreply, socket}
    end
  end

  # Space or Enter shows the answer; once it shows, 1 to 4 vote, E edits the
  # card and X removes it. Keys held down, and those pressed with a
  # modifier, are someone else's shortcut. While the card is being edited,
  # the page doesn't listen: what is typed goes to the form.
  def handle_event("session_key", %{"key" => key} = params, socket) do
    session = socket.assigns.session

    cond do
      params["repeat"] || params["ctrlKey"] || params["metaKey"] || params["altKey"] ->
        {:noreply, socket}

      not under_way?(session) or socket.assigns.edit_form != nil ->
        {:noreply, socket}

      key in [" ", "Enter"] and not session.flipped? ->
        {:noreply, flip(socket)}

      not session.flipped? ->
        {:noreply, socket}

      Map.has_key?(Remember.keys(), key) ->
        {:noreply, vote(socket, Map.fetch!(Remember.keys(), key))}

      key in ["e", "E"] ->
        {:noreply, edit_current(socket)}

      key in ["x", "X"] ->
        {:noreply, remove_current(socket)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("edit_card", _params, socket), do: {:noreply, edit_current(socket)}

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, :edit_form, nil)}

  def handle_event("save_edit", %{"edit" => params}, socket) do
    %{username: username, session: session} = socket.assigns

    case session && session.current && Library.update(username, session.current.id, attrs(params)) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(session: Session.refresh(session, card), edit_form: nil)
         |> refresh()
         |> put_notice(:success, "Card corrected")}

      {:error, errors} ->
        {:noreply, assign(socket, :edit_form, card_form(params, :edit, errors))}

      _gone ->
        {:noreply, assign(socket, :edit_form, nil)}
    end
  end

  def handle_event("remove_card", %{"id" => id}, socket) do
    case Library.remove(socket.assigns.username, id) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:card, card)
         |> refresh()
         |> put_notice(:info, "Removed from the deck",
           body: "It waits under Removed, where you can put it back."
         )}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_card", _params, socket), do: {:noreply, remove_current(socket)}

  def handle_event("restore_card", %{"id" => id}, socket) do
    %{username: username, session: session} = socket.assigns

    case Library.restore(username, id) do
      {:ok, card} ->
        socket =
          socket
          |> assign(:session, session && Session.unremove(session, id))
          |> update(:just_removed, &if(match?({^id, _front}, &1), do: nil, else: &1))
          |> update(:card, &if(&1 && &1.id == id, do: card, else: &1))
          |> refresh()

        {:noreply, put_notice(socket, :success, "Put back in the deck")}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("end_session", _params, socket) do
    session = socket.assigns.session
    socket = assign(socket, edit_form: nil, just_removed: nil)

    if session && Session.handled(session) > 0 do
      {:noreply, assign(socket, :session, Session.stop(session))}
    else
      {:noreply, socket |> assign(:session, nil) |> refresh()}
    end
  end

  def handle_event("again", _params, socket) do
    {:noreply, start(socket, socket.assigns.session_scope, socket.assigns.size)}
  end

  def handle_event("close_summary", _params, socket) do
    {:noreply, socket |> assign(:session, nil) |> refresh()}
  end

  ## Cards

  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + page_size())) |> assign_list()}
  end

  def handle_event("toggle_removed", _params, socket) do
    {:noreply,
     socket
     |> assign(bin?: !socket.assigns.bin?, limit: page_size())
     |> push_patch(to: ~p"/tools/flashcards/cards")
     |> assign_list()}
  end

  # Both card forms send their changes here: the Cards editor's as `card`,
  # a session's correction as `edit`.
  def handle_event("edit_change", %{"card" => params}, socket) do
    {:noreply, assign_card_form(socket, params)}
  end

  def handle_event("edit_change", %{"edit" => params}, socket) do
    {:noreply, assign(socket, :edit_form, card_form(params, :edit))}
  end

  def handle_event("add_tag", %{"form" => form, "name" => name}, socket) do
    {:noreply, update_tags(socket, form, &add_tags(&1, name, socket.assigns.tags))}
  end

  def handle_event("remove_tag", %{"form" => form, "last" => _last}, socket) do
    {:noreply, update_tags(socket, form, &Enum.drop(&1, -1))}
  end

  def handle_event("remove_tag", %{"form" => form, "name" => name}, socket) do
    {:noreply, update_tags(socket, form, &Enum.reject(&1, fn tag -> tag == name end))}
  end

  def handle_event("save_card", %{"card" => params}, socket) do
    %{username: username, card: card} = socket.assigns
    attrs = attrs(params)

    if card do
      case Library.update(username, card.id, attrs) do
        {:ok, card} ->
          {:noreply, socket |> open_card(card) |> refresh() |> put_notice(:success, "Card saved")}

        {:error, errors} ->
          {:noreply, assign_card_form(socket, params, errors)}

        :error ->
          {:noreply,
           socket
           |> push_patch(to: ~p"/tools/flashcards/cards")
           |> put_flash(:error, "That card is gone")}
      end
    else
      case Library.create(username, [attrs]) do
        {:ok, [{:created, created}]} ->
          sticky = %{"tags" => created.tags, "source" => created.source || ""}

          {:noreply,
           socket
           |> assign(:sticky, sticky)
           |> update(:form_key, &(&1 + 1))
           |> assign_card_form(sticky)
           |> refresh()
           |> put_notice(:success, "Card added")}

        {:ok, [{:existing, existing}]} ->
          {:noreply,
           socket
           |> push_patch(to: ~p"/tools/flashcards/cards?id=#{existing.id}")
           |> put_notice(:info, "That card is already here")}

        {:ok, [{:removed, removed}]} ->
          {:noreply,
           socket
           |> push_patch(to: ~p"/tools/flashcards/cards?id=#{removed.id}")
           |> put_notice(:info, "That card was removed as not important",
             body: "Put it back in the deck to keep it."
           )}

        {:error, [{0, errors}]} ->
          {:noreply, assign_card_form(socket, params, errors)}
      end
    end
  end

  def handle_event("show_versions", _params, socket) do
    {:noreply, socket |> assign(:versions, %{list: [], selected: nil}) |> load_versions()}
  end

  def handle_event("hide_versions", _params, socket) do
    {:noreply, assign(socket, :versions, nil)}
  end

  def handle_event("select_version", %{"version" => number}, socket) do
    selected = String.to_integer(number)
    selected = if socket.assigns.versions.selected == selected, do: nil, else: selected
    {:noreply, update(socket, :versions, &%{&1 | selected: selected})}
  end

  def handle_event("restore_version", %{"version" => number}, socket) do
    %{username: username, card: card} = socket.assigns

    case card && Library.restore_version(username, card.id, String.to_integer(number)) do
      {:ok, card} ->
        {:noreply,
         socket
         |> open_card(card)
         |> assign(:versions, %{list: [], selected: nil})
         |> load_versions()
         |> refresh()
         |> put_notice(:success, "Restored", body: "What it replaced is the newest version now.")}

      _gone ->
        {:noreply, socket |> load_versions() |> put_flash(:error, "That version is gone")}
    end
  end

  def handle_event("delete_card", %{"id" => id}, socket) do
    _deleted = Library.delete(socket.assigns.username, id)

    {:noreply,
     socket
     |> push_patch(to: ~p"/tools/flashcards/cards")
     |> refresh()
     |> put_notice(:info, "Card deleted")}
  end

  ## Settings

  def handle_event("settings_change", %{"settings" => params}, socket) do
    {:ok, settings} = Library.put_settings(socket.assigns.username, params)
    {:noreply, assign_settings(socket, settings)}
  end

  def handle_event("toggle_setting", %{"kind" => kind, "on" => on}, socket)
      when kind in ~w(repeat_forgotten fill) do
    {:ok, settings} = Library.put_settings(socket.assigns.username, %{kind => on})
    {:noreply, socket |> assign_settings(settings) |> refresh()}
  end

  ## Changes made elsewhere

  # A card written, changed or deleted by an agent, or in another window.
  # A session under way asks the newest version of each card, and skips a
  # card deleted; the card open is redrawn unless it was deleted. A form
  # being written in is left as it is.
  @impl true
  def handle_info({:flashcards_changed, :settings}, socket) do
    {:noreply, socket |> assign_settings(Library.settings(socket.assigns.username)) |> refresh()}
  end

  def handle_info({:flashcards_changed, what}, socket) do
    %{username: username, session: session, card: card} = socket.assigns

    found = if is_binary(what), do: Library.get(username, what), else: :error

    socket =
      case {session, found} do
        {nil, _found} ->
          socket

        {session, {:ok, %Card{removed_at: nil} = changed}} ->
          assign(socket, :session, Session.refresh(session, changed))

        {session, _gone} when is_binary(what) ->
          assign(socket, :session, Session.drop(session, what))

        _all ->
          socket
      end

    # Every card it had left gone before one was dealt with: nothing to sum up.
    socket =
      case socket.assigns.session do
        %Session{} = session ->
          if Session.done?(session) and Session.handled(session) == 0,
            do: assign(socket, session: nil, edit_form: nil),
            else: socket

        nil ->
          socket
      end

    socket =
      cond do
        is_nil(card) or what not in [:all, card.id] ->
          socket

        match?({:ok, _card}, Library.get(username, card.id)) ->
          {:ok, fresh} = Library.get(username, card.id)
          assign(socket, :card, fresh)

        true ->
          socket |> new_card() |> push_patch(to: ~p"/tools/flashcards/cards")
      end

    {:noreply, refresh(socket)}
  end

  ## Helpers

  defp under_way?(nil), do: false
  defp under_way?(session), do: not Session.done?(session)

  defp view_path(:remember), do: ~p"/tools/flashcards"
  defp view_path(:cards), do: ~p"/tools/flashcards/cards"
  defp view_path(:settings), do: ~p"/tools/flashcards/settings"

  defp same_tag?(one, other), do: String.downcase(one) == String.downcase(other)

  defp scope(filter), do: Map.take(filter, [:tags, :match, :days])

  defp put_filter(socket, changes) do
    socket
    |> assign(:filter, Map.merge(socket.assigns.filter, Map.new(changes)))
    |> assign(:limit, page_size())
    |> refresh()
  end

  defp start(socket, scope, size) do
    socket = assign(socket, edit_form: nil, just_removed: nil)

    case Library.pick(socket.assigns.username, scope, size) do
      [] ->
        socket
        |> assign(:session, nil)
        |> refresh()
        |> put_notice(:info, "No card is due there",
          body: "Turn on filling sessions in Settings to go over cards not due yet."
        )

      cards ->
        session = Session.new(cards, repeat?: socket.assigns.settings.repeat_forgotten)

        socket
        |> assign(session: session, session_scope: scope)
        |> push_patch(to: ~p"/tools/flashcards")
    end
  end

  defp flip(socket) do
    case socket.assigns.session do
      nil -> socket
      session -> assign(socket, :session, Session.flip(session))
    end
  end

  # A vote counts only once the answer shows, and for the card it was cast on.
  defp vote(socket, grade) do
    session = socket.assigns.session

    if answer_showing?(socket) do
      socket = assign(socket, :just_removed, nil)

      case Library.review(socket.assigns.username, session.current.id, grade) do
        {:ok, card} ->
          socket |> assign(:session, Session.answer(session, grade, card)) |> refresh()

        :error ->
          socket |> assign(:session, Session.drop(session, session.current.id)) |> refresh()
      end
    else
      socket
    end
  end

  defp edit_current(socket) do
    if answer_showing?(socket) do
      assign(socket, :edit_form, card_form(card_params(socket.assigns.session.current), :edit))
    else
      socket
    end
  end

  defp remove_current(socket) do
    session = socket.assigns.session

    if answer_showing?(socket) do
      %Card{id: id, front: front} = session.current
      _removed = Library.remove(socket.assigns.username, id)

      socket
      |> assign(session: Session.remove(session), just_removed: {id, front}, edit_form: nil)
      |> refresh()
    else
      socket
    end
  end

  defp answer_showing?(socket) do
    session = socket.assigns.session
    under_way?(session) and session.flipped? and socket.assigns.edit_form == nil
  end

  defp assign_settings(socket, settings) do
    assign(socket, settings: settings, settings_form: settings_form(settings))
  end

  defp settings_form(settings) do
    to_form(%{"session_size" => "#{settings.session_size}"}, as: :settings)
  end

  defp open_card(socket, %Card{} = card) do
    previous = socket.assigns.card

    if previous && previous.id == card.id do
      socket = socket |> assign(:card, card) |> assign_card_form(card_params(card))
      if previous.version != card.version, do: load_versions(socket), else: socket
    else
      socket
      |> assign(:card, card)
      |> update(:form_key, &(&1 + 1))
      |> assign_card_form(card_params(card))
      |> then(
        &if(&1.assigns.versions,
          do: &1 |> assign(:versions, %{list: [], selected: nil}) |> load_versions(),
          else: &1
        )
      )
    end
  end

  # The versions of the card open, keeping the one chosen while it is there.
  defp load_versions(%{assigns: %{versions: nil}} = socket), do: socket
  defp load_versions(%{assigns: %{card: nil}} = socket), do: assign(socket, :versions, nil)

  defp load_versions(socket) do
    %{username: username, card: card, versions: versions} = socket.assigns
    list = Library.versions(username, card.id)
    selected = if Enum.any?(list, &(&1.version == versions.selected)), do: versions.selected
    assign(socket, :versions, %{list: list, selected: selected})
  end

  defp new_card(socket) do
    socket
    |> assign(:versions, nil)
    |> assign(:card, nil)
    |> update(:form_key, &(&1 + 1))
    |> assign_card_form(socket.assigns.sticky)
  end

  defp card_params(%Card{} = card) do
    %{
      "front" => card.front,
      "back" => card.back,
      "tags" => card.tags,
      "source" => card.source || ""
    }
  end

  defp assign_card_form(socket, params, errors \\ []) do
    assign(socket, :card_form, card_form(params, :card, errors))
  end

  defp card_form(params, as, errors \\ []) do
    params =
      %{"front" => "", "back" => "", "tags" => [], "source" => "", "new_tag" => ""}
      |> Map.merge(params)
      |> Map.update!("tags", &Components.chosen/1)

    errors = for {field, message} <- errors, do: {field, {message, []}}
    to_form(params, as: as, errors: errors)
  end

  # What a card form holds, as a card is written with: a tag typed and not
  # yet added counts.
  defp attrs(params) do
    tags = Components.chosen(Map.get(params, "tags", []))
    typed = Components.chosen(Map.get(params, "new_tag", ""))

    %{
      front: Map.get(params, "front", ""),
      back: Map.get(params, "back", ""),
      tags: tags ++ typed,
      source: Map.get(params, "source", "")
    }
  end

  defp update_tags(socket, "card", fun) do
    params = socket.assigns.card_form.params
    assign_card_form(socket, %{params | "tags" => fun.(params["tags"]), "new_tag" => ""})
  end

  defp update_tags(%{assigns: %{edit_form: %{params: params}}} = socket, "edit", fun) do
    form = card_form(%{params | "tags" => fun.(params["tags"]), "new_tag" => ""}, :edit)
    assign(socket, :edit_form, form)
  end

  defp update_tags(socket, _form, _fun), do: socket

  # Tags typed, split at commas, in the spelling the deck already uses, and
  # only those not there yet.
  defp add_tags(tags, typed, deck) do
    spellings = Map.new(deck, &{String.downcase(&1.name), &1.name})

    typed
    |> Components.chosen()
    |> Enum.map(&Map.get(spellings, String.downcase(&1), &1))
    |> Enum.reduce(tags, fn tag, tags ->
      if Enum.any?(tags, &same_tag?(&1, tag)), do: tags, else: tags ++ [tag]
    end)
  end

  # What every view shows: the totals, the tags, and what the filter picks,
  # and what the view open needs besides.
  defp refresh(socket) do
    %{username: username, filter: filter} = socket.assigns
    scope = scope(filter)

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:totals, Library.count(username, %{}))
    |> assign(:tags, Library.tags(username))
    |> assign(:count, Library.count(username, scope))
    |> assign(:removed_count, Library.count(username, Map.put(scope, :removed, true)).cards)
    |> assign(:matching, username |> Library.list(scope) |> Enum.take(@matching))
    |> assign_picker()
    |> then(&if(&1.assigns[:live_action] == :cards, do: assign_list(&1), else: &1))
  end

  # The tags the picker offers: any of the deck's in the days picked, or,
  # with every tag required, those found together with the ones picked, so
  # each count says how many cards would be left with it added.
  defp assign_picker(socket) do
    %{username: username, filter: filter, tag_query: query, more_tags?: more?} = socket.assigns
    in_days = Library.tags(username, %{days: filter.days})

    offered =
      if filter.match == :all and filter.tags != [],
        do: Library.tags(username, scope(filter)),
        else: in_days

    picked = MapSet.new(filter.tags, &String.downcase/1)
    offered = Enum.reject(offered, &MapSet.member?(picked, String.downcase(&1.name)))

    found =
      case query |> String.trim() |> String.downcase() do
        "" -> offered
        words -> Enum.filter(offered, &String.contains?(String.downcase(&1.name), words))
      end

    shown = if more? or query != "", do: found, else: Enum.take(found, @cloud_size)

    assign(socket, :picker, %{
      counts: Map.new(in_days, &{String.downcase(&1.name), &1.cards}),
      cloud: shown,
      hidden: length(found) - length(shown),
      total: length(offered),
      tag_query: query,
      more?: more?
    })
  end

  defp assign_list(socket) do
    %{username: username, filter: filter, limit: limit, bin?: bin?} = socket.assigns
    cards = Library.list(username, Map.put(filter, :removed, bin?))

    assign(socket,
      entries: Enum.take(cards, limit),
      hidden: max(length(cards) - limit, 0),
      listed: length(cards)
    )
  end

  defp scope_label(nil), do: ""

  defp scope_label(%{tags: tags, match: match, days: days}) do
    what =
      case tags do
        [] -> "All cards"
        [tag] -> tag
        tags -> Enum.join(tags, if(match == :all, do: " + ", else: " or "))
      end

    case days do
      nil -> what
      1 -> what <> " · added today"
      days -> what <> " · added in the last #{days} days"
    end
  end
end
