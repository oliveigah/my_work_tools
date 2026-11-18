defmodule MWTClientWeb.FlashcardsLiveTest do
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Flashcards.Library
  alias MWTClientWeb.FlashcardsLive.Filter

  setup %{conn: conn} do
    sign_in(conn)
  end

  describe "with no cards" do
    test "invites writing one or connecting an agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")

      assert has_element?(view, "#remember-empty")
      assert has_element?(view, "#empty-write[href='/tools/flashcards/cards']")
      assert has_element?(view, "#empty-agents[href='/agents']")
      refute has_element?(view, "#session-setup")
    end

    test "the tool is in the picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools")
      assert has_element?(view, "#tool-flashcards[href='/tools/flashcards']")
    end
  end

  describe "remember" do
    setup %{conn: conn, username: username} do
      {:ok, created} =
        Library.create(username, [
          %{
            front: "Why slots?",
            back: "Warm builds.",
            tags: ["mwt_client", "worktrees"],
            source: "Thread: slots"
          },
          %{front: "Who lands a handoff?", back: "The user.", tags: ["mwt_client", "handoffs"]},
          %{front: "How to read a list item?", back: "`Enum.at/2`", tags: ["elixir"]}
        ])

      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")
      %{view: view, cards: Enum.map(created, &elem(&1, 1))}
    end

    test "mixes and matches tags to pick the cards", %{view: view} do
      assert has_element?(view, "#session-count", "3 cards")
      assert has_element?(view, "#flashcard-totals", "3 due")
      refute has_element?(view, "#quick-starts")

      view |> element(tag("mwt_client")) |> render_click()
      assert has_element?(view, "#picked-tag-#{Filter.tag_id("mwt_client")}", "2")
      assert has_element?(view, "#session-count", "2 cards")
      refute has_element?(view, tag("mwt_client"))

      # Any of the tags...
      view |> element(tag("elixir")) |> render_click()
      assert has_element?(view, "#session-count", "3 cards")

      # ...or all of them: then only tags found with every one are offered.
      view |> element("#tag-match-all") |> render_click()
      assert has_element?(view, "#session-count", "No card has these tags")
      view |> element("#picked-tag-#{Filter.tag_id("elixir")}") |> render_click()
      view |> element(tag("handoffs")) |> render_click()
      assert has_element?(view, "#session-count", "1 card")
      refute has_element?(view, tag("elixir"))
      refute has_element?(view, tag("worktrees"))

      view |> element("#clear-tags") |> render_click()
      assert has_element?(view, "#session-count", "3 cards")

      # A search narrows the tags offered, and Enter picks the first.
      view |> form("#tag-search", tag_query: "ELIX") |> render_change()
      assert has_element?(view, tag("elixir"))
      refute has_element?(view, tag("handoffs"))
      view |> form("#tag-search", tag_query: "elix") |> render_submit()
      assert has_element?(view, "#picked-tag-#{Filter.tag_id("elixir")}")
      assert has_element?(view, "#session-count", "1 card")

      view |> element("#days-7") |> render_click()
      assert has_element?(view, "#days-7[aria-pressed=true]")
      assert has_element?(view, "#session-count", "1 card")
    end

    test "shows the cards picked, and opens them in Cards", %{view: view, cards: [slots | _]} do
      view |> element(tag("worktrees")) |> render_click()

      assert has_element?(view, "#matching-#{slots.id}", "Why slots?")
      refute has_element?(view, "#matching-cards", "list item")

      view |> element("#open-in-cards") |> render_click()
      assert_patch(view, ~p"/tools/flashcards/cards")
      assert has_element?(view, "#card-row-#{slots.id}")
      assert has_element?(view, "#card-filter-tags", "worktrees")
      refute has_element?(view, "#card-list", "list item")
    end

    test "asks each card, shows its answer, and keeps each vote", %{
      view: view,
      username: username,
      cards: cards
    } do
      view |> element(tag("mwt_client")) |> render_click()
      view |> element("#start-session") |> render_click()

      assert has_element?(view, "#remember-session")
      assert has_element?(view, "#session-scope", "mwt_client")
      assert has_element?(view, "#session-progress", "1 / 2")
      refute has_element?(view, "#votes")

      first = asked(view, cards)
      view |> element("#flip") |> render_click()
      assert has_element?(view, "#session-card[class*=rotate-y-180]")
      assert has_element?(view, "#card-back-text", first.back)
      assert has_element?(view, "#vote-good", "tomorrow")

      # Forgotten, it comes back at the end of the session.
      view |> element("#vote-forgot") |> render_click()
      assert has_element?(view, "#session-progress", "2 / 3")
      assert {:ok, %{box: 1, lapses: 1}} = Library.get(username, first.id)

      second = asked(view, cards)
      refute second.id == first.id

      # The keyboard: a vote before the answer shows does nothing.
      render_keydown(view, "session_key", %{"key" => "3"})
      assert has_element?(view, "#session-progress", "2 / 3")
      render_keydown(view, "session_key", %{"key" => " "})
      assert has_element?(view, "#votes")
      render_keydown(view, "session_key", %{"key" => "4"})
      assert {:ok, %{box: 3}} = Library.get(username, second.id)

      assert asked(view, cards).id == first.id
      render_keydown(view, "session_key", %{"key" => "Enter"})
      render_keydown(view, "session_key", %{"key" => "3"})

      assert has_element?(view, "#remember-summary")
      assert has_element?(view, "#summary-score", "1 of 2")
      assert has_element?(view, "#tally-forgot", "1")
      assert has_element?(view, "#summary-forgotten", first.front)
      assert {:ok, %{box: 2, reviews: 2}} = Library.get(username, first.id)

      view |> element("#session-close") |> render_click()
      assert has_element?(view, "#session-setup")
      assert has_element?(view, "#flashcard-totals", "1 due")
    end

    test "corrects the card asked, its tags too, keeping how well it is known", %{
      view: view,
      username: username,
      cards: [_slots, _handoff, elixir]
    } do
      {:ok, _reviewed} = Library.review(username, elixir.id, :hard)
      view |> element(tag("elixir")) |> render_click()
      view |> element("#start-session") |> render_click()

      # Only once the answer shows.
      render_keydown(view, "session_key", %{"key" => "e"})
      refute has_element?(view, "#session-edit-form")

      view |> element("#flip") |> render_click()
      view |> element("#edit-card") |> render_click()
      assert has_element?(view, "#session-edit-form")
      assert has_element?(view, "#session-edit-front", "How to read a list item?")
      refute has_element?(view, "#votes")

      # While it is edited, keys are typing, not votes.
      render_keydown(view, "session_key", %{"key" => "1"})
      assert {:ok, %{reviews: 1}} = Library.get(username, elixir.id)

      render_hook(view, "add_tag", %{"form" => "edit", "name" => "Lists, enum"})
      view |> element("#session-edit-tags button[phx-value-name=elixir]") |> render_click()

      view
      |> form("#session-edit-form", edit: %{back: "`Enum.at(list, i)`: no access syntax."})
      |> render_submit()

      assert {:ok, card} = Library.get(username, elixir.id)
      assert card.back == "`Enum.at(list, i)`: no access syntax."
      assert card.tags == ["Lists", "enum"]
      assert {card.box, card.reviews} == {1, 1}

      refute has_element?(view, "#session-edit-form")
      assert has_element?(view, "#card-back-text", "no access syntax")
      assert has_element?(view, "#votes")

      # Escape gives up an edit.
      view |> element("#edit-card") |> render_click()
      render_keydown(element(view, "#edit-escape"), %{"key" => "Escape"})
      refute has_element?(view, "#session-edit-form")
    end

    test "a correction that leaves the card blank says so", %{view: view, username: username} do
      view |> element("#start-session") |> render_click()
      view |> element("#flip") |> render_click()
      render_keydown(view, "session_key", %{"key" => "E"})

      html = view |> form("#session-edit-form", edit: %{front: " "}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#session-edit-form")
      assert length(Library.list(username)) == 3
    end

    test "removes a card not worth remembering, with a way back", %{
      view: view,
      username: username,
      cards: cards
    } do
      view |> element(tag("mwt_client")) |> render_click()
      view |> element("#start-session") |> render_click()

      first = asked(view, cards)
      view |> element("#flip") |> render_click()
      view |> element("#remove-card") |> render_click()

      assert {:ok, %{removed_at: %DateTime{}}} = Library.get(username, first.id)
      assert has_element?(view, "#removed-notice", first.front)
      assert has_element?(view, "#session-progress", "2 / 2")

      view |> element("#undo-remove") |> render_click()
      assert {:ok, %{removed_at: nil}} = Library.get(username, first.id)
      refute has_element?(view, "#removed-notice")

      # X does the same.
      second = asked(view, cards)
      render_keydown(view, "session_key", %{"key" => " "})
      render_keydown(view, "session_key", %{"key" => "x"})

      assert has_element?(view, "#remember-summary")
      assert has_element?(view, "#summary-removed", second.front)
      assert {:ok, %{removed_at: %DateTime{}}} = Library.get(username, second.id)

      view |> element("#restore-#{second.id}") |> render_click()
      assert {:ok, %{removed_at: nil}} = Library.get(username, second.id)
      refute has_element?(view, "#summary-removed")
    end

    test "ending a session part way says what was left", %{view: view} do
      view |> form("#session-size-form", size: "3") |> render_change()
      view |> element("#start-session") |> render_click()
      view |> element("#flip") |> render_click()
      view |> element("#vote-good") |> render_click()
      view |> element("#end-session") |> render_click()

      assert has_element?(view, "#summary-score", "1 of 1")
      assert has_element?(view, "#summary-score", "2 left for next time")

      # Ended before any answer, there is nothing to sum up.
      view |> element("#session-again") |> render_click()
      view |> element("#end-session") |> render_click()
      assert has_element?(view, "#session-setup")
    end

    test "with filling off, a pick with nothing due starts no session", %{
      view: view,
      username: username,
      cards: cards
    } do
      {:ok, _settings} = Library.put_settings(username, %{fill: false})
      for card <- cards, do: {:ok, _card} = Library.review(username, card.id, :easy)

      view |> element("#days-any") |> render_click()
      assert has_element?(view, "#session-count", "none due now")
      assert has_element?(view, "#start-session[disabled]")
    end

    test "a card changed while it waits is asked as it is now", %{
      view: view,
      username: username,
      cards: [_slots, _handoff, elixir]
    } do
      view |> element(tag("elixir")) |> render_click()
      view |> element("#start-session") |> render_click()

      Task.async(fn ->
        Library.update(username, elixir.id, %{front: "Read item i of a list?"})
      end)
      |> Task.await()

      assert has_element?(view, "#card-front-text", "Read item i of a list?")

      Task.async(fn -> Library.delete(username, elixir.id) end) |> Task.await()
      render(view)
      refute has_element?(view, "#remember-session")
      refute has_element?(view, "#remember-summary")
      assert has_element?(view, "#session-setup")
    end
  end

  describe "coming back to the tool" do
    setup %{username: username} do
      {:ok, created} =
        Library.create(username, [
          %{front: "Why slots?", back: "Warm builds.", tags: ["mwt_client"]},
          %{front: "Who lands a handoff?", back: "The user.", tags: ["mwt_client"]},
          %{front: "How to read a list item?", back: "`Enum.at/2`", tags: ["elixir"]}
        ])

      %{cards: Enum.map(created, &elem(&1, 1))}
    end

    test "finds a session part way where it was left", %{conn: conn, cards: cards} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")
      view |> element(tag("mwt_client")) |> render_click()
      view |> element("#start-session") |> render_click()
      view |> element("#flip") |> render_click()
      view |> element("#vote-good") |> render_click()
      second = asked(view, cards)

      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")

      assert has_element?(view, "#remember-session")
      assert has_element?(view, "#session-scope", "mwt_client")
      assert has_element?(view, "#session-progress", "2 / 2")
      assert asked(view, cards).id == second.id
    end

    test "a card deleted meanwhile is skipped", %{conn: conn, username: username, cards: cards} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")
      view |> element(tag("mwt_client")) |> render_click()
      view |> element("#start-session") |> render_click()
      first = asked(view, cards)

      :ok = Library.delete(username, first.id)
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")

      assert has_element?(view, "#remember-session")
      refute asked(view, cards).id == first.id
    end

    test "a card half written comes back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      view
      |> form("[id^=card-form]", card: %{front: "Half a question", back: ""})
      |> render_change()

      # Through another view of the tool, then away and back.
      view |> element("#view-remember") |> render_click()
      {:ok, _remember, _html} = live(conn, ~p"/tools/flashcards")
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      assert view |> element("#card-editor textarea[name='card[front]']") |> render() =~
               "Half a question"
    end
  end

  describe "cards" do
    setup %{conn: conn, username: username} do
      {:ok, [{:created, card}]} =
        Library.create(username, [
          %{
            front: "Why slots?",
            back: "Warm builds.",
            tags: ["mwt_client"],
            source: "Thread: slots"
          }
        ])

      %{card: card, conn: conn}
    end

    test "adds cards, keeping tags and source for the next one", %{
      conn: conn,
      username: username
    } do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      assert has_element?(view, "#card-editor h1", "New card")

      view
      |> element("#card-editor [id$=-tag-suggestions] button", "mwt_client")
      |> render_click()

      render_hook(view, "add_tag", %{"form" => "card", "name" => "MWT_CLIENT, handoffs"})
      assert has_element?(view, "#card-editor [id$=-tags] input[value=handoffs]")

      view
      |> form("[id^=card-form]",
        card: %{
          front: "Who lands a **handoff**?",
          back: "The user.",
          source: "Thread: handoffs",
          new_tag: "review"
        }
      )
      |> render_change()

      assert has_element?(view, "#preview-front strong", "handoff")

      view |> form("[id^=card-form]") |> render_submit()

      assert [
               %{
                 front: "Who lands a **handoff**?",
                 tags: ["mwt_client", "handoffs", "review"],
                 source: "Thread: handoffs"
               },
               _old
             ] = Library.list(username)

      assert has_element?(view, "[id^=card-row-]", "Who lands a handoff?")
      assert has_element?(view, "#card-editor [id$=-tags] input[value=review]")
      assert has_element?(view, "input[name='card[source]'][value='Thread: handoffs']")
    end

    test "says what is missing, and adds nothing", %{conn: conn, username: username} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      html = view |> form("[id^=card-form]", card: %{front: "  ", back: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert length(Library.list(username)) == 1
    end

    test "adding a card already here opens it, and one removed says so", %{
      conn: conn,
      username: username,
      card: card
    } do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      view
      |> form("[id^=card-form]", card: %{front: "why slots?", back: "warm builds."})
      |> render_submit()

      assert_patch(view, ~p"/tools/flashcards/cards?id=#{card.id}")
      assert has_element?(view, "#card-editor h1", "Edit card")

      {:ok, _removed} = Library.remove(username, card.id)
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      view
      |> form("[id^=card-form]", card: %{front: "Why slots?", back: "Warm builds."})
      |> render_submit()

      assert_patch(view, ~p"/tools/flashcards/cards?id=#{card.id}")
      assert has_element?(view, "#card-removed")
    end

    test "edits a card from its link and keeps its progress", %{
      conn: conn,
      username: username,
      card: card
    } do
      {:ok, _card} = Library.review(username, card.id, :good)
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards?id=#{card.id}")

      assert has_element?(view, "#card-row-#{card.id}[aria-selected=true]")
      assert has_element?(view, "#card-stats", "Answered once")
      assert has_element?(view, "textarea[name='card[back]']", "Warm builds.")

      render_hook(view, "add_tag", %{"form" => "card", "name" => "slots"})
      render_hook(view, "remove_tag", %{"form" => "card", "name" => "mwt_client"})

      view
      |> form("[id^=card-form]", card: %{back: "Builds start warm."})
      |> render_submit()

      assert {:ok, %{back: "Builds start warm.", tags: ["slots"], box: 2}} =
               Library.get(username, card.id)

      # Backspace in the empty tag field takes the last tag off.
      render_hook(view, "remove_tag", %{"form" => "card", "last" => true})
      refute has_element?(view, "[id$=-tags] input[value=slots]")
    end

    test "finds cards by their words and tags", %{conn: conn, username: username} do
      {:ok, _created} =
        Library.create(username, [
          %{front: "Enum.at?", back: "Index.", tags: ["elixir"]},
          %{front: "Both?", back: "Yes.", tags: ["elixir", "mwt_client"]}
        ])

      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")
      assert list_has?(view, "Enum.at?")

      view |> form("#card-filter-add-0", tag: "mwt_client") |> render_change()
      refute list_has?(view, "Enum.at?")
      assert list_has?(view, "Why slots?")
      assert list_has?(view, "Both?")

      view |> form("#card-filter-add-1", tag: "elixir") |> render_change()
      assert list_has?(view, "Enum.at?")
      view |> element("#card-filter-match-all") |> render_click()
      assert list_has?(view, "Both?")
      refute list_has?(view, "Enum.at?")
      refute list_has?(view, "Why slots?")

      view |> element("#card-filter-tags button", "mwt_client") |> render_click()
      view |> form("#card-search", query: "index") |> render_change()
      assert list_has?(view, "Enum.at?")
      refute list_has?(view, "Both?")
    end

    test "removes a card from the deck, puts it back, and deletes it for good", %{
      conn: conn,
      username: username,
      card: card
    } do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards?id=#{card.id}")

      view |> element("#remove-card") |> render_click()
      assert has_element?(view, "#card-removed")
      refute has_element?(view, "#remove-card")
      assert has_element?(view, "#toggle-removed", "1")

      view |> element("#restore-card") |> render_click()
      assert {:ok, %{removed_at: nil}} = Library.get(username, card.id)
      refute has_element?(view, "#card-removed")

      view |> element("#remove-card") |> render_click()
      view |> element("#toggle-removed") |> render_click()
      assert has_element?(view, "#card-row-#{card.id}")

      view |> element("#card-row-#{card.id}") |> render_click()
      view |> element("#delete-card") |> render_click()
      assert_patch(view, ~p"/tools/flashcards/cards")
      assert Library.get(username, card.id) == :error
    end

    test "a card an agent writes shows up", %{conn: conn, username: username} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards")

      Task.async(fn -> Library.create(username, [%{front: "From an agent?", back: "Yes."}]) end)
      |> Task.await()

      assert list_has?(view, "From an agent?")
      assert has_element?(view, "#flashcard-totals", "2 cards")
    end

    test "an unknown card says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/cards?id=missing")
      assert has_element?(view, "#card-editor h1", "New card")
      assert render(view) =~ "Card not found"
    end
  end

  describe "settings" do
    test "keeps the session size and switches as they change", %{
      conn: conn,
      username: username
    } do
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards/settings")

      assert has_element?(view, "#settings-repeat[aria-checked=true]")
      assert has_element?(view, "#schedule-box-6", "in 5 weeks")

      view |> form("#settings-form", settings: %{session_size: "25"}) |> render_change()
      view |> element("#settings-repeat") |> render_click()
      view |> element("#settings-fill") |> render_click()

      assert %{session_size: 25, repeat_forgotten: false, fill: false} =
               Library.settings(username)

      assert has_element?(view, "#settings-repeat[aria-checked=false]")

      # A new session starts at that size.
      {:ok, _created} = Library.create(username, [%{front: "Q", back: "A"}])
      {:ok, view, _html} = live(conn, ~p"/tools/flashcards")
      assert has_element?(view, "#session-size[value='25']")
    end
  end

  defp tag(name), do: "#tag-#{Filter.tag_id(name)}"

  defp list_has?(view, text), do: has_element?(view, "#card-list [id^=card-row-]", text)

  # The card the session asks now, among `cards`.
  defp asked(view, cards) do
    text = view |> element("#card-front-text") |> render()
    Enum.find(cards, &(text =~ &1.front))
  end
end
