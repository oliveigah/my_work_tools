defmodule MWTClient.MCP.DiscoveryTest do
  # What an agent in the VM learns of MWT's tools from the server alone,
  # through the messages `mwt mcp` carries (`MWTClient.Sandbox.Channel`).
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.MCP.{Protocol, Schema}
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.ToolCallers

  setup do
    %{username: username} = unlocked_identity()
    %{caller: ToolCallers.allowed(username), username: username}
  end

  test "initializes and lists the tools: none deletes, reviews or reads HTTP requests", %{
    caller: caller
  } do
    initialized =
      rpc(caller, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test-agent", "version" => "1"}
      })["result"]

    assert initialized["protocolVersion"] == "2025-11-25"
    assert initialized["capabilities"]["tools"] == %{"listChanged" => false}
    assert initialized["instructions"] =~ "mwt-read (list/get)"

    names = Enum.map(rpc(caller, "tools/list")["result"]["tools"], & &1["name"])
    assert "create_note" in names and "update_diagram" in names
    assert "create_http_request" in names and "import_http_request" in names
    assert "create_flashcards" in names and "list_flashcard_tags" in names

    for name <- ~w(get_http_request list_http_requests update_http_request review_flashcard
                   delete_flashcard) do
      refute name in names
    end

    assert length(names) == 15
  end

  test "a notification never runs a tool; protocol and tool errors keep their forms", %{
    caller: caller,
    username: username
  } do
    create = %{
      "name" => "create_note",
      "arguments" => %{"title" => "Ignored", "body" => "Ignored"}
    }

    assert Protocol.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, caller) ==
             :accepted

    assert Protocol.handle(
             %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => create},
             caller
           ) ==
             :accepted

    assert rpc(caller, "unknown")["error"]["code"] == -32601
    assert rpc(caller, "tools/call", %{"name" => "get_http_request"})["error"]["code"] == -32602

    answer = rpc(caller, "tools/call", put_in(create, ["arguments", "body"], 123))
    assert answer["result"]["isError"]
    refute Map.has_key?(answer, "error")
    assert Notes.list(username) == []
  end

  test "creates, updates, reads and paginates using only the advertised examples and contracts",
       %{caller: caller} do
    tools = rpc(caller, "tools/list")["result"]["tools"]

    for tool <- tools, example <- tool["inputSchema"]["examples"] do
      assert :ok = Schema.validate(example, tool["inputSchema"])
    end

    for tool <- tools do
      assert is_binary(tool["title"])

      for {_name, property} <- tool["inputSchema"]["properties"] do
        assert is_binary(property["description"])
      end
    end

    families = [
      {"create_note", "get_note", "update_note", "list_notes"},
      {"create_diagram", "get_diagram", "update_diagram", "list_diagrams"}
    ]

    for {create, get, update, list} <- families do
      creation = find_tool(tools, create)

      for example <- creation["inputSchema"]["examples"] do
        saved = call(caller, creation, example)
        read = call(caller, find_tool(tools, get), %{"id" => saved["id"]})
        assert read == saved
        assert saved["url"] =~ saved["path"]

        updating = find_tool(tools, update)

        assert updating["annotations"] == %{
                 "readOnlyHint" => false,
                 "destructiveHint" => true,
                 "idempotentHint" => true,
                 "openWorldHint" => false
               }

        for update_example <- updating["inputSchema"]["examples"] do
          args = Map.put(update_example, "id", saved["id"])
          updated = call(caller, updating, args)
          assert updated["id"] == saved["id"]
          assert updated["created_at"] == saved["created_at"]
          assert call(caller, find_tool(tools, get), %{"id" => saved["id"]}) == updated
          assert call(caller, updating, args) == updated
        end
      end

      listing = find_tool(tools, list)
      first = call(caller, listing, %{"limit" => 1})
      ids = collect_pages(caller, listing, first, [])
      assert length(ids) == first["total"]
      assert Enum.uniq(ids) == ids
      assert call(caller, listing, %{"offset" => first["total"]})["items"] == []
    end

    # HTTP samples are only added: no tool reads them back.
    for create <- ["create_http_request", "import_http_request"] do
      creation = find_tool(tools, create)

      for example <- creation["inputSchema"]["examples"] do
        saved = call(caller, creation, example)
        assert saved["url"] =~ saved["path"]
        assert saved["sent"] == false
        assert saved["request_url"] =~ "https://api.example.test/"
        assert is_map(saved["headers"])
        refute Map.has_key?(saved, "response")
      end
    end
  end

  test "writes, finds, reads and updates flash cards using only the advertised examples and contracts",
       %{caller: caller} do
    tools = rpc(caller, "tools/list")["result"]["tools"]
    creating = find_tool(tools, "create_flashcards")
    reading = find_tool(tools, "get_flashcard")
    updating = find_tool(tools, "update_flashcard")
    listing = find_tool(tools, "list_flashcards")

    for example <- creating["inputSchema"]["examples"] do
      saved = call(caller, creating, example)
      assert saved["created"] == length(example["cards"])
      assert saved["existing"] == 0
      assert saved["url"] =~ saved["path"]

      for card <- saved["cards"] do
        assert card["status"] == "created"
        assert card["url"] =~ card["path"]
        assert call(caller, reading, %{"id" => card["id"]}) == Map.delete(card, "status")
      end

      # Asking again writes nothing new.
      again = call(caller, creating, example)
      assert {again["created"], again["existing"]} == {0, length(example["cards"])}
      assert Enum.map(again["cards"], & &1["id"]) == Enum.map(saved["cards"], & &1["id"])

      card = hd(saved["cards"])

      assert updating["annotations"] == %{
               "readOnlyHint" => false,
               "destructiveHint" => true,
               "idempotentHint" => true,
               "openWorldHint" => false
             }

      for update_example <- updating["inputSchema"]["examples"] do
        args = Map.put(update_example, "id", card["id"])
        updated = call(caller, updating, args)
        assert updated["id"] == card["id"]
        assert updated["created_at"] == card["created_at"]
        assert call(caller, reading, %{"id" => card["id"]}) == updated
        assert call(caller, updating, args) == updated
      end
    end

    first = call(caller, listing, %{"limit" => 1})
    ids = collect_pages(caller, listing, first, [])
    assert length(ids) == first["total"]
    assert Enum.uniq(ids) == ids

    for example <- listing["inputSchema"]["examples"] do
      assert is_list(call(caller, listing, example)["items"])
    end

    tags = call(caller, find_tool(tools, "list_flashcard_tags"), %{})["tags"]

    assert %{"name" => "mwt_client", "cards" => 3} =
             Enum.find(tags, &(&1["name"] == "mwt_client"))
  end

  test "discovers guides and validates every JSON example obtained through resources/read", %{
    caller: caller
  } do
    initialized =
      rpc(caller, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "discovery-only-agent", "version" => "1"}
      })["result"]

    assert initialized["capabilities"]["resources"] == %{
             "subscribe" => false,
             "listChanged" => false
           }

    assert initialized["instructions"] =~ "resources/read"
    resources = rpc(caller, "resources/list")["result"]["resources"]

    assert Enum.map(resources, & &1["uri"]) == [
             "mwt://guides/notes",
             "mwt://guides/diagrams",
             "mwt://guides/http",
             "mwt://guides/flashcards"
           ]

    tools = rpc(caller, "tools/list")["result"]["tools"]

    for resource <- resources do
      assert [%{"uri" => uri, "mimeType" => "text/markdown", "text" => text}] =
               rpc(caller, "resources/read", %{"uri" => resource["uri"]})["result"]["contents"]

      assert uri == resource["uri"]

      examples = Regex.scan(~r/### (\w+)\s+```json\n(.*?)\n```/s, text)
      assert length(examples) >= 2

      for [_, name, json] <- examples do
        assert :ok = Schema.validate(Jason.decode!(json), find_tool(tools, name)["inputSchema"])
      end
    end

    assert rpc(caller, "resources/templates/list")["result"] == %{"resourceTemplates" => []}
  end

  test "guides accept only published URIs", %{caller: caller} do
    for uri <- ["mwt://guides/missing", "file:///etc/passwd", "mwt://guides/../notes"] do
      assert rpc(caller, "resources/read", %{"uri" => uri})["error"]["code"] == -32002
    end

    assert rpc(caller, "resources/read", %{})["error"]["code"] == -32602
    assert rpc(caller, "resources/read", %{"uri" => 123})["error"]["code"] == -32602
    assert rpc(caller, "resources/list", %{"cursor" => "invalid"})["error"]["code"] == -32602
  end

  test "diagram schema rejects missing coordinates and row endpoints before saving", %{
    caller: caller,
    username: username
  } do
    tool = find_tool(rpc(caller, "tools/list")["result"]["tools"], "create_diagram")
    example = hd(tool["inputSchema"]["examples"])
    [shape, api, arrow] = example["elements"]

    cases = [
      {[Map.delete(shape, "width")], "arguments.elements[0].width is required"},
      {[Map.put(shape, "height", 0)], "arguments.elements[0].height must be greater than 0"},
      {[shape, api, Map.delete(arrow, "y2")], "arguments.elements[2].y2 is required"},
      {[Map.put(arrow, "startRow", "id") |> Map.delete("start")],
       "arguments.elements[0].start is required"},
      {[Map.put(arrow, "startRow", "id") |> Map.put("start", nil)],
       "arguments.elements[0].start must have type"}
    ]

    for {elements, message} <- cases do
      args = Map.put(example, "elements", elements)
      assert {:error, reason} = Schema.validate(args, tool["inputSchema"])
      assert reason =~ message
      result = rpc(caller, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ message
    end

    assert Diagrams.list(username) == []
  end

  test "attachment errors identify the offending field and missing target", %{caller: caller} do
    tool = find_tool(rpc(caller, "tools/list")["result"]["tools"], "create_diagram")
    example = List.last(tool["inputSchema"]["examples"])
    [customers, orders, arrow] = example["elements"]

    for {changes, field, target} <- [
          {%{"end" => "missing_table"}, "end", "missing_table"},
          {%{"endRow" => "missing_row"}, "endRow", "missing_row"}
        ] do
      args = Map.put(example, "elements", [customers, orders, Map.merge(arrow, changes)])
      result = rpc(caller, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "arguments.elements[2].#{field}"
      assert hd(result["content"])["text"] =~ target
    end
  end

  defp collect_pages(caller, tool, page, ids) do
    ids = ids ++ Enum.map(page["items"], & &1["id"])

    if page["next_offset"] == nil do
      ids
    else
      next = call(caller, tool, %{"limit" => 1, "offset" => page["next_offset"]})
      collect_pages(caller, tool, next, ids)
    end
  end

  defp call(caller, tool, args) do
    result = rpc(caller, "tools/call", %{"name" => tool["name"], "arguments" => args})["result"]
    assert result["isError"] == false, inspect(result)
    data = result["structuredContent"]
    assert :ok = Schema.validate(data, tool["outputSchema"])
    assert Jason.decode!(hd(result["content"])["text"]) == data
    data
  end

  defp find_tool(tools, name), do: Enum.find(tools, &(&1["name"] == name))

  # One message and its answer, as JSON on the way, as the channel sends it.
  defp rpc(caller, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    |> Protocol.handle(caller)
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
