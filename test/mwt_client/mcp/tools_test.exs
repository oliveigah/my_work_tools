defmodule MWTClient.MCP.ToolsTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers
  import MWTClient.ToolCallers, only: [allowed: 1]
  alias MWTClient.MCP.Tools
  alias MWTClient.HttpClient.{Resources, Transfer, Translation}
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "saves, finds and reads Markdown notes only in the authorized identity", %{
    username: username
  } do
    other = also_unlock("other")

    note =
      call(
        "create_note",
        %{"title" => "Launch idea", "body" => "# Ship\nAdd an MCP interface"},
        username
      )

    assert note["body"] == "# Ship\nAdd an MCP interface"
    assert note["url"] == "http://127.0.0.1:12995/tools/notes?id=#{note["id"]}"
    assert {:ok, stored} = Notes.get(username, note["id"])
    assert stored.title == "Launch idea"
    assert call("get_note", %{"id" => note["id"]}, username) == note
    assert [%{"id" => id}] = call("list_notes", %{"query" => "MCP launch"}, username)["items"]
    assert id == note["id"]
    assert call("list_notes", %{}, other)["items"] == []
    assert tool_error?("get_note", %{"id" => note["id"]}, other)
  end

  test "creates native editable diagrams with attached arrows and typed table rows", %{
    username: username
  } do
    table = %{
      "id" => "users",
      "type" => "table",
      "text" => "Users",
      "x" => 40,
      "y" => 40,
      "width" => 240,
      "height" => 120,
      "rows" => [%{"id" => "user_id", "type" => "uuid", "name" => "id"}]
    }

    shape = %{
      "id" => "api",
      "type" => "rectangle",
      "text" => "API",
      "x" => 400,
      "y" => 40,
      "width" => 180,
      "height" => 80
    }

    arrow = %{
      "id" => "relation",
      "type" => "arrow",
      "x1" => 280,
      "y1" => 80,
      "x2" => 400,
      "y2" => 80,
      "start" => "users",
      "startRow" => "user_id",
      "end" => "api"
    }

    diagram =
      call(
        "create_diagram",
        %{"title" => "Architecture", "elements" => [table, shape, arrow]},
        username
      )

    assert {:ok, stored} = Diagrams.get(username, diagram["id"])
    assert length(stored.elements) == 3
    assert List.last(stored.elements)["startRow"] == "user_id"
    assert call("get_diagram", %{"id" => diagram["id"]}, username) == diagram
    assert length(call("list_diagrams", %{"query" => "uuid API"}, username)["items"]) == 1
  end

  test "keeps arrows pinned to spots of an outline and bent round others", %{
    username: username
  } do
    shape = %{
      "id" => "state",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 200,
      "height" => 80
    }

    loop = %{
      "id" => "retry",
      "type" => "arrow",
      "text" => "retry",
      "x1" => 50,
      "y1" => -6,
      "x2" => 150,
      "y2" => -6,
      "start" => "state",
      "startAnchor" => %{"x" => 0.25, "y" => 0},
      "end" => "state",
      "endAnchor" => %{"x" => 0.75, "y" => 0},
      "points" => [%{"x" => 50, "y" => -40}, %{"x" => 150, "y" => -40}]
    }

    diagram =
      call("create_diagram", %{"title" => "Loop", "elements" => [shape, loop]}, username)

    assert %{
             "startAnchor" => %{"x" => 0.25, "y" => +0.0},
             "endAnchor" => %{"x" => 0.75, "y" => +0.0},
             "points" => [%{"x" => 50, "y" => -40}, %{"x" => 150, "y" => -40}]
           } = List.last(diagram["elements"])

    assert call("get_diagram", %{"id" => diagram["id"]}, username) == diagram

    for broken <- [
          Map.delete(loop, "start"),
          Map.put(loop, "endAnchor", %{"x" => 2, "y" => 0}),
          Map.put(loop, "points", [%{"x" => 1}])
        ] do
      assert tool_error?(
               "create_diagram",
               %{"title" => "Broken", "elements" => [shape, broken]},
               username
             )
    end
  end

  test "rejects diagrams that would lose elements or attachments", %{username: username} do
    shape = %{
      "id" => "a",
      "type" => "rectangle",
      "x" => 0,
      "y" => 0,
      "width" => 100,
      "height" => 60
    }

    arrow = %{
      "id" => "arrow",
      "type" => "arrow",
      "x1" => 0,
      "y1" => 0,
      "x2" => 100,
      "y2" => 60,
      "end" => "missing"
    }

    for elements <- [
          [shape, shape],
          [arrow],
          [Map.delete(shape, "width")],
          [Map.put(shape, "id", "a\n")],
          [Map.put(shape, "width", 0)],
          [Map.put(shape, "type", "mermaid")]
        ] do
      assert tool_error?(
               "create_diagram",
               %{"title" => "Invalid", "elements" => elements},
               username
             )
    end

    assert Diagrams.list(username) == []
  end

  test "keeps groups as written, and rejects the ones the editor could not keep", %{
    username: username
  } do
    box = fn id, groups ->
      %{
        "id" => id,
        "type" => "rectangle",
        "x" => 0,
        "y" => 0,
        "width" => 100,
        "height" => 60,
        "groups" => groups
      }
    end

    elements = [box.("a", ["legend", "key"]), box.("b", ["legend", "key"]), box.("c", ["legend"])]
    diagram = call("create_diagram", %{"title" => "Legend", "elements" => elements}, username)

    assert Enum.map(diagram["elements"], & &1["groups"]) == [
             ["legend", "key"],
             ["legend", "key"],
             ["legend"]
           ]

    for {broken, message} <- [
          {[box.("a", ["g", "g"]), box.("b", ["g"])], ~s(lists "g" twice)},
          {[box.("a", ["g", "h"]), box.("b", ["h"])], ~s(lists "h" inside [])},
          {[box.("a", ["g"]), box.("b", [])], ~s(group "g" has one member)},
          {[box.("a", ["g"]), box.("b", []), box.("c", ["g"])], ~s(group "g" is split by)},
          {[box.("a", ["bad id!"]), box.("b", ["bad id!"])], "invalid format"}
        ] do
      {:ok, result} =
        Tools.call(
          "create_diagram",
          %{"title" => "Broken", "elements" => broken},
          allowed(username)
        )

      assert result["isError"]
      assert hd(result["content"])["text"] =~ message
    end
  end

  test "stores HTTP samples without a response, and keeps them through encryption and export", %{
    username: username,
    key: key
  } do
    args = %{
      "url" => "http://127.0.0.1:1/orders",
      "method" => "POST",
      "description" => "Order sample",
      "tags" => ["orders"],
      "headers" => [
        %{"name" => "Content-Type", "value" => "application/json"},
        %{"name" => "X-Demo", "value" => "sample"}
      ],
      "body" => ~s({"sku":"A"})
    }

    sample = call("create_http_request", args, username)
    refute sample["sent"]
    assert {:ok, entry = {_id, _metadata, request, nil}} = Resources.get(username, sample["id"])
    assert request.body == args["body"]
    assert request.method == :post
    assert Translation.request_from_history(entry).response == nil
    {:ok, outline} = Resources.outline(username, sample["id"])
    assert Translation.request_outline_from_history(outline).response == nil

    # A sample, never sent.
    id = sample["id"]

    assert [{^id, "Order sample", ["orders"], _at, _took, _method, _url, 0}] =
             Resources.summaries(username, "Order sample")

    {:ok, section} = Transfer.export(username)
    assert {:ok, [_entry]} = Transfer.prepare(1, section)

    :ok = Store.close(username)

    refute on_disk(username, :journal) =~ "Order sample"

    :ok = Store.open(username, key)
    assert {:ok, {^id, _metadata, reopened, nil}} = Resources.get(username, id)
    assert reopened.body == args["body"]
  end

  test "imports curl by parsing it, preserving method, headers and body", %{username: username} do
    sample =
      call(
        "import_http_request",
        %{
          "curl" => "curl -X POST https://example.test/notes -H 'X-Demo: sample' -d 'hello'",
          "description" => "Curl sample"
        },
        username
      )

    assert sample["method"] == "POST"
    assert sample["headers"]["x-demo"] == ["sample"]
    assert sample["body"] == "hello"
    refute sample["sent"]
    assert tool_error?("import_http_request", %{"curl" => "echo nope"}, username)
    assert tool_error?("create_http_request", %{"url" => "file:///etc/passwd"}, username)
  end

  test "validates sizes, types and unknown fields before writing, and paginates lists", %{
    username: username
  } do
    assert tool_error?(
             "create_note",
             %{"title" => "Too large", "body" => String.duplicate("x", 100_001)},
             username
           )

    assert tool_error?(
             "create_note",
             %{"title" => "Spoof", "body" => "Text", "username" => "other"},
             username
           )

    assert Notes.list(username) == []

    for title <- ["First", "Second", "Third"],
        do: call("create_note", %{"title" => title, "body" => ""}, username)

    first = call("list_notes", %{"limit" => 2}, username)
    assert length(first["items"]) == 2
    assert first["total"] == 3
    assert first["next_offset"] == 2
    last = call("list_notes", %{"offset" => 2, "limit" => 2}, username)
    assert length(last["items"]) == 1
    assert last["next_offset"] == nil
    assert tool_error?("list_notes", %{"limit" => 0}, username)
  end

  test "writes flash cards with shared tags and source, once, only in the authorized identity",
       %{
         username: username
       } do
    other = also_unlock("other")

    args = %{
      "tags" => ["mwt_client"],
      "source" => "Thread: slots, 2026-11-14",
      "cards" => [
        %{
          "front" => "Why slots?",
          "back" => "Warm builds.",
          "tags" => ["worktrees", "MWT_CLIENT"]
        },
        %{
          "front" => "Who lands a handoff?",
          "back" => "The user.",
          "source" => "Thread: handoffs"
        }
      ]
    }

    saved = call("create_flashcards", args, username)
    assert {saved["created"], saved["existing"]} == {2, 0}
    assert saved["url"] == "http://127.0.0.1:12995/tools/flashcards/cards"

    [slots, handoff] = saved["cards"]
    assert slots["tags"] == ["mwt_client", "worktrees"]
    assert slots["source"] == "Thread: slots, 2026-11-14"
    assert handoff["source"] == "Thread: handoffs"
    assert slots["url"] == "http://127.0.0.1:12995/tools/flashcards/cards?id=#{slots["id"]}"
    assert {slots["box"], slots["reviews"], slots["lapses"]} == {0, 0, 0}

    again = call("create_flashcards", args, username)
    assert {again["created"], again["existing"]} == {0, 2}
    assert Enum.map(again["cards"], & &1["status"]) == ["existing", "existing"]

    assert [%{"id" => id}] = call("list_flashcards", %{"query" => "warm"}, username)["items"]
    assert id == slots["id"]
    assert call("list_flashcards", %{"tags" => ["worktrees"]}, username)["total"] == 1
    assert call("list_flashcards", %{"days" => 1}, username)["total"] == 2

    assert call("list_flashcard_tags", %{}, username)["tags"] == [
             %{"name" => "mwt_client", "cards" => 2, "due" => 2, "uncertain" => 0},
             %{"name" => "worktrees", "cards" => 1, "due" => 1, "uncertain" => 0}
           ]

    updated =
      call(
        "update_flashcard",
        %{"id" => id, "version" => 1, "back" => "Builds start warm."},
        username
      )

    assert updated["back"] == "Builds start warm."
    assert updated["tags"] == slots["tags"]

    assert call(
             "list_flashcards",
             %{"tags" => ["mwt_client", "worktrees"], "match" => "all"},
             username
           )[
             "total"
           ] == 1

    # A card the user removed is left out, and not written again.
    {:ok, _removed} = MWTClient.Flashcards.Library.remove(username, handoff["id"])
    assert call("list_flashcards", %{}, username)["total"] == 1
    assert call("get_flashcard", %{"id" => handoff["id"]}, username)["removed_at"]

    again = call("create_flashcards", %{"cards" => [Enum.at(args["cards"], 1)]}, username)
    assert {again["created"], again["existing"], again["removed"]} == {0, 0, 1}
    assert [%{"status" => "removed", "id" => removed_id}] = again["cards"]
    assert removed_id == handoff["id"]

    assert call("list_flashcards", %{}, other)["items"] == []
    assert call("list_flashcard_tags", %{}, other)["tags"] == []
    assert tool_error?("get_flashcard", %{"id" => id}, other)

    assert tool_error?(
             "update_flashcard",
             %{"id" => id, "version" => 1, "back" => "Mine now"},
             other
           )
  end

  test "lists the cards the user marked uncertain, and resolves them, corrected or as they were",
       %{username: username} do
    alias MWTClient.Flashcards.Library, as: Flashcards

    saved =
      call(
        "create_flashcards",
        %{
          "tags" => ["mwt_client"],
          "cards" => [
            %{"front" => "When do shares sync?", "back" => "Every 3 seconds."},
            %{"front" => "Who lands a handoff?", "back" => "The user."},
            %{"front" => "Why slots?", "back" => "Warm builds."}
          ]
        },
        username
      )

    [stale, right, sure] = saved["cards"]
    assert sure["uncertain"] == nil
    {:ok, _marked} = Flashcards.mark_uncertain(username, stale["id"], "Since on-demand sync?")
    {:ok, _marked} = Flashcards.mark_uncertain(username, right["id"], nil)

    listed = call("list_flashcards", %{"uncertain" => true}, username)
    assert listed["total"] == 2

    assert %{"note" => "Since on-demand sync?", "marked_at" => "20" <> _} =
             Enum.find(listed["items"], &(&1["id"] == stale["id"]))["uncertain"]

    assert [%{"id" => id}] = call("list_flashcards", %{"uncertain" => false}, username)["items"]
    assert id == sure["id"]
    assert call("list_flashcards", %{}, username)["total"] == 3
    assert call("get_flashcard", %{"id" => right["id"]}, username)["uncertain"]["note"] == nil

    # Their due counts leave out what sessions don't ask.
    assert [%{"name" => "mwt_client", "cards" => 3, "due" => 1, "uncertain" => 2}] =
             call("list_flashcard_tags", %{}, username)["tags"]

    args = %{"id" => stale["id"], "version" => 1, "back" => "On demand.", "resolved" => true}
    corrected = call("update_flashcard", args, username)

    assert {corrected["back"], corrected["uncertain"], corrected["version"]} ==
             {"On demand.", nil, 2}

    assert call("update_flashcard", args, username) == corrected

    resolved =
      call(
        "update_flashcard",
        %{"id" => right["id"], "version" => 1, "resolved" => true},
        username
      )

    assert {resolved["back"], resolved["uncertain"], resolved["version"]} == {"The user.", nil, 1}
    assert call("list_flashcards", %{"uncertain" => true}, username)["total"] == 0

    # Only the user marks a card, and resolving is all an agent does to a mark.
    assert tool_error?(
             "update_flashcard",
             %{"id" => sure["id"], "version" => 1, "resolved" => false},
             username
           )

    assert tool_error?(
             "update_flashcard",
             %{"id" => sure["id"], "version" => 1, "uncertain" => "Doubt"},
             username
           )
  end

  test "a check of uncertain cards takes only the context the user names", %{username: username} do
    alias MWTClient.Flashcards.Library, as: Flashcards

    saved =
      call(
        "create_flashcards",
        %{
          "cards" => [
            %{"front" => "Egress?", "back" => "A.", "tags" => ["mwt_client", "egress"]},
            %{"front" => "Grants?", "back" => "B.", "tags" => ["mwt_client", "grants"]},
            %{"front" => "Klife egress?", "back" => "C.", "tags" => ["klife", "egress"]},
            %{"front" => "Sure egress?", "back" => "D.", "tags" => ["mwt_client", "egress"]}
          ]
        },
        username
      )

    [egress, grants, klife, _sure] = saved["cards"]

    for card <- [egress, grants, klife],
        do: {:ok, _marked} = Flashcards.mark_uncertain(username, card["id"], nil)

    tags = call("list_flashcard_tags", %{}, username)["tags"]
    assert %{"cards" => 3, "uncertain" => 2} = Enum.find(tags, &(&1["name"] == "egress"))

    scoped =
      call(
        "list_flashcards",
        %{"uncertain" => true, "tags" => ["mwt_client", "egress"], "match" => "all"},
        username
      )

    assert Enum.map(scoped["items"], & &1["id"]) == [egress["id"]]

    worded = call("list_flashcards", %{"uncertain" => true, "query" => "klife"}, username)
    assert Enum.map(worded["items"], & &1["id"]) == [klife["id"]]
  end

  test "flash card errors name the card and field to correct, and save nothing", %{
    username: username
  } do
    {:ok, result} =
      Tools.call(
        "create_flashcards",
        %{
          "cards" => [
            %{"front" => "Fine?", "back" => "Fine."},
            %{"front" => "   ", "back" => "Blank question."}
          ]
        },
        allowed(username)
      )

    assert result["isError"]
    assert hd(result["content"])["text"] == "arguments.cards[1].front can't be blank."

    # Fine apart, too many once the shared tags join the card's own.
    shared = Enum.map(1..6, &"shared#{&1}")
    own = Enum.map(1..5, &"own#{&1}")

    {:ok, result} =
      Tools.call(
        "create_flashcards",
        %{"tags" => shared, "cards" => [%{"front" => "Q", "back" => "A", "tags" => own}]},
        allowed(username)
      )

    assert hd(result["content"])["text"] =~ "arguments.cards[0].tags use at most 10"
    assert call("list_flashcards", %{}, username)["total"] == 0

    assert tool_error?("create_flashcards", %{"cards" => []}, username)
    assert tool_error?("update_flashcard", %{"id" => "missing"}, username)
  end

  defp call(name, args, username) do
    {:ok, result} = Tools.call(name, args, allowed(username))
    refute result["isError"], inspect(result)
    Jason.decode!(Jason.encode!(result["structuredContent"]))
  end

  defp tool_error?(name, args, username) do
    {:ok, result} = Tools.call(name, args, allowed(username))
    result["isError"]
  end
end
