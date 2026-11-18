defmodule MWTClient.MCP.Protocol do
  @moduledoc "The JSON-RPC methods for MWT's stateless MCP server."

  alias MWTClient.MCP.{Caller, Guides, Tools}

  @versions ~w(2025-11-25 2025-06-18 2025-03-26)

  def versions, do: @versions

  @doc "Answers one message from an agent on this machine, through `/mcp`."
  def handle(message, username, base_url),
    do: handle(message, Caller.local(username, base_url))

  @doc """
  Answers one JSON-RPC message from `caller` (`MWTClient.MCP.Caller`): a
  response, or `:accepted` for a notification.
  """
  def handle(message, %Caller{} = caller) do
    case message do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method}
      when (is_binary(id) or is_integer(id)) and is_binary(method) ->
        params = Map.get(message, "params", %{})

        if is_map(params),
          do: dispatch(id, method, params, caller),
          else: error(id, -32602, "Params must be an object.")

      %{"jsonrpc" => "2.0", "method" => method}
      when is_binary(method) and not is_map_key(message, "id") ->
        if is_map(Map.get(message, "params", %{})),
          do: :accepted,
          else: error(nil, -32600, "Invalid notification.")

      _invalid ->
        error(nil, -32600, "Invalid JSON-RPC request. Send one request per POST.")
    end
  end

  def error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp dispatch(id, "initialize", params, caller) do
    case params do
      %{
        "protocolVersion" => version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => name, "version" => client_version}
      }
      when is_binary(version) and is_map(capabilities) and is_binary(name) and
             is_binary(client_version) ->
        result(id, %{
          "protocolVersion" => if(version in @versions, do: version, else: hd(@versions)),
          "capabilities" => %{
            "tools" => %{"listChanged" => false},
            "resources" => %{"subscribe" => false, "listChanged" => false}
          },
          "serverInfo" => %{
            "name" => "mwt",
            "version" => Application.spec(:mwt_client, :vsn) |> to_string()
          },
          "instructions" =>
            where(caller) <>
              """
              Create native diagrams, Markdown notes, or HTTP request samples; samples are saved without sending requests.
              Save flash cards the user studies in remember sessions: the few decisions from a thread worth recalling in a
              month, one question and answer per card (read mwt://guides/flashcards first).
              Make notes, diagrams and cards when the user asks; unasked, only the rare cards that guide allows. An item the
              user didn't need costs them more than it gives.
              Use list/get tools to find and inspect existing work. update_note, update_diagram and update_flashcard edit
              existing items by ID and the version get returned; supply only the fields you want to change. A change based on
              an older version is refused: read the item again. Body/elements replace their complete saved content.
              Each create/import call creates a new item; repeating a successful call creates a duplicate, except
              create_flashcards, which skips cards equal to one already saved.
              HTTP requests are append-only through MCP: save a new sample instead of updating an existing request.
              Deletion, completing notes, reviewing flash cards and HTTP execution are not available through MCP.
              Returned url opens the saved item in MWT; request_url is an API destination.

              Tool schemas include field descriptions, defaults, examples and response contracts. No repository access
              is needed. Built-in guides are available through resources/list and resources/read:
              mwt://guides/notes, mwt://guides/diagrams, mwt://guides/http and mwt://guides/flashcards. Read the diagram
              guide for table sizing and row anchors. All list tools use query, limit (default 20) and offset (default 0); keep query and limit
              fixed and follow next_offset until null. Note/diagram search matches every word; HTTP search matches a substring.

              """ <> access(caller)
        })

      _invalid ->
        error(id, -32602, "initialize requires protocolVersion, capabilities and clientInfo.")
    end
  end

  defp dispatch(id, "ping", _params, _caller), do: result(id, %{})

  defp dispatch(id, "tools/list", params, caller) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"tools" => Tools.list(caller)}),
      else: error(id, -32602, "Invalid tools cursor.")
  end

  defp dispatch(id, "resources/list", params, _caller) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"resources" => Guides.list()}),
      else: error(id, -32602, "Invalid resources cursor.")
  end

  defp dispatch(id, "resources/templates/list", params, _caller) do
    if Map.get(params, "cursor") in [nil, ""],
      do: result(id, %{"resourceTemplates" => []}),
      else: error(id, -32602, "Invalid resource templates cursor.")
  end

  defp dispatch(id, "resources/read", %{"uri" => uri}, _caller)
       when is_binary(uri) do
    case Guides.read(uri) do
      {:ok, content} ->
        result(id, %{"contents" => [content]})

      :error ->
        error(id, -32002, "Unknown MWT guide. Use resources/list to find available guide URIs.")
    end
  end

  defp dispatch(id, "resources/read", _params, _caller),
    do: error(id, -32602, "resources/read requires a string uri from resources/list.")

  defp dispatch(id, "tools/call", %{"name" => name} = params, caller)
       when is_binary(name) do
    case Tools.call(name, Map.get(params, "arguments", %{}), caller) do
      {:ok, output} -> result(id, output)
      {:error, :unknown_tool} -> error(id, -32602, "Unknown MWT tool.")
    end
  rescue
    ArgumentError -> error(id, -32603, "The tool could not process this input.")
    RuntimeError -> error(id, -32000, "The vault is unavailable. Unlock MWT and reconnect.")
  catch
    :exit, _reason -> error(id, -32000, "The vault is unavailable. Unlock MWT and reconnect.")
  end

  defp dispatch(id, "tools/call", _params, _caller),
    do: error(id, -32602, "tools/call requires a tool name.")

  defp dispatch(id, _method, _params, _caller),
    do: error(id, -32601, "Method not found.")

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp where(%Caller{from: :local}) do
    """
    MWT is a local encrypted developer toolbox. Tools operate only on the identity that issued your token.
    """
  end

  defp where(%Caller{from: :vm}) do
    """
    MWT is the user's encrypted developer toolbox, on their machine; you reach it from MWT's agent sandbox VM
    through `mwt mcp`, with no token. You read its notes, diagrams and flash cards, the user's own included.
    HTTP requests are closed to reading from here: save a sample (create_http_request, import_http_request)
    only when the user asks for one; you can't read any, theirs or yours.
    """
  end

  defp access(%Caller{from: :local}) do
    """
    Tokens persist across restarts. Access requires the vault to be unlocked; use the same token again after unlocking.
    """
  end

  defp access(%Caller{from: :vm}) do
    """
    Three grants decide each call: mwt-read (list/get), mwt-create (create/import) and mwt-change (update).
    A call whose grant is off says so: ask with `mwt request GRANT --reason "..."`. A change may wait for the
    user's approval; they see it as a diff.
    Every change keeps the version it replaced, so the user can restore it.
    """
  end
end
