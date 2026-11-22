defmodule MWTClient.Sandbox.HandoffSearchTest do
  @moduledoc "What a search of the handoffs finds in one, and the words it shows around it."
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Handoff
  alias MWTClient.Search

  defp handoff(fields \\ []) do
    struct!(
      %Handoff{
        id: 12,
        title: "Fix the login timeout",
        agent: "claude",
        thread: "Login thread",
        project: "my_app",
        repo: "/home/me/my_app",
        onto: "main",
        base_branch: "main",
        source: %{folder: "/work/my_app/.git", top: "/work/my_app.wt/slot-1", branch: "fix-login"},
        head: String.duplicate("a", 40),
        opened_at: ~U[2026-11-20 10:00:00Z],
        body: "Raised the session timeout.\n\nThe Redis pool now reconnects on its own.",
        timeline: [
          %{at: ~U[2026-11-20 10:00:00Z], kind: :opened, text: "claude handed it off"},
          %{
            at: ~U[2026-11-20 11:00:00Z],
            kind: :sent_back,
            text: "You sent it back",
            note: "Cover the expired cookie case too"
          }
        ]
      },
      fields
    )
  end

  defp matches?(handoff, words),
    do: Search.matches?(Handoff.search_text(handoff), Search.terms(words))

  test "a handoff holds the words its page shows of it, wherever they are" do
    handoff = handoff()

    for words <- [
          "#12",
          "login timeout",
          "CLAUDE",
          "login thread",
          "my_app",
          "fix-login",
          "main",
          "redis reconnects",
          "handed it off",
          "expired cookie"
        ] do
      assert matches?(handoff, words), words
    end
  end

  test "every word must be there, not only one of them" do
    handoff = handoff()

    assert matches?(handoff, "redis cookie")
    refute matches?(handoff, "redis postgres")
    refute matches?(handoff, "#13")
  end

  test "no words match every handoff" do
    assert matches?(handoff(), "")
    assert matches?(handoff(), "   ")
  end

  test "one from before agents or threads were kept matches on the rest" do
    handoff = handoff(agent: nil, thread: nil, timeline: [])

    assert matches?(handoff, "login")
    refute matches?(handoff, "cookie")
  end

  test "the words around a match are taken from its notes, then from its history's" do
    assert {"The ", "Redis", " pool now reconnects on its own."} =
             Handoff.snippet(handoff(), Search.terms("redis"))

    assert {"Cover the ", "expired", " cookie case too"} =
             Handoff.snippet(handoff(), Search.terms("expired"))
  end

  test "a match in what the list shows already has no words around it" do
    assert Handoff.snippet(handoff(), Search.terms("fix-login")) == nil
    assert Handoff.snippet(handoff(), Search.terms("")) == nil
  end
end
