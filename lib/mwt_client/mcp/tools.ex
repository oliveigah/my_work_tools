defmodule MWTClient.MCP.Tools do
  @moduledoc """
  Agent tools backed by MWT's existing encrypted libraries.

  An agent on this machine calls them through `/mcp` with the identity's
  token; an agent in the VM through `mwt mcp`, where each call first goes
  through its caller's `gate`, the grant for what it does
  (`access/1`, `MWTClient.Sandbox.MwtTools`). For a change, the gate is
  shown what would change before anything does. HTTP requests are closed
  to reading from the VM (`open_to_vm?/1`): the user's history holds the
  credentials they sent, so agents there only add samples, and don't even
  see the tools that read them.
  """

  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Diagrams.Library, as: Diagrams
  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Library, as: Flashcards
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note
  alias MWTClient.HttpClient.{Curl, HistoryMetadata, Resources, Translation, Utils}
  alias MWTClient.MCP.{Caller, Catalogue, Schema}

  @reads ~w(list_notes get_note list_diagrams get_diagram list_http_requests get_http_request
            list_flashcards get_flashcard list_flashcard_tags)
  @creates ~w(create_note create_diagram create_http_request import_http_request create_flashcards)
  @changes ~w(update_note update_diagram update_flashcard)

  # What an agent writes a card with, by argument.
  @card_fields [{"front", :front}, {"back", :back}, {"tags", :tags}, {"source", :source}]

  # Closed to agents in the VM: they add HTTP samples, never read any.
  @closed_to_vm ~w(list_http_requests get_http_request)

  @doc "The fixed tool catalogue, including the schemas agents use to construct calls."
  def list, do: Catalogue.list()

  @doc "The tools `caller` may use: for an agent in the VM, those open to it."
  def list(%Caller{from: :vm}), do: Enum.filter(list(), &open_to_vm?(&1["name"]))
  def list(%Caller{}), do: list()

  @doc "Whether agents in the VM may use a tool: every one but those reading HTTP requests."
  @spec open_to_vm?(String.t()) :: boolean()
  def open_to_vm?(name), do: name not in @closed_to_vm

  @doc "What a tool does: `:read`, `:create` (adds, changes nothing) or `:change`."
  @spec access(String.t()) :: :read | :create | :change | nil
  def access(name) when name in @reads, do: :read
  def access(name) when name in @creates, do: :create
  def access(name) when name in @changes, do: :change
  def access(_name), do: nil

  @doc "Calls a tool as an agent on this machine would, through `/mcp`."
  def call(name, arguments, username, base_url) when is_binary(username),
    do: call(name, arguments, Caller.local(username, base_url))

  @doc """
  Validates arguments before calling a library, as `caller`
  (`MWTClient.MCP.Caller`): who a change is by, and for an agent in the
  VM, what its grants allow.
  """
  def call(name, arguments, %Caller{} = caller) do
    with tool when not is_nil(tool) <- Enum.find(list(), &(&1["name"] == name)),
         :ok <- Schema.validate(arguments, tool["inputSchema"]) do
      gated(name, arguments, caller)
    else
      nil -> {:error, :unknown_tool}
      {:error, message} -> {:ok, failure(message)}
    end
  end

  defp gated(name, args, %Caller{gate: nil} = caller), do: run(name, args, caller)

  defp gated(name, _args, %Caller{from: :vm}) when name in @closed_to_vm do
    {:ok,
     failure(
       "#{name} isn't open to agents in the VM: from here, HTTP requests are only added " <>
         "(create_http_request, import_http_request, when the user asks for a sample), never read."
     )}
  end

  defp gated(name, args, %Caller{gate: gate} = caller) do
    case access(name) do
      :read ->
        name |> read_use(args) |> gate.() |> then_run(name, args, caller)

      :create ->
        name
        |> create_use(args)
        |> Map.merge(%{args: args, apply: fn -> run(name, args, caller) end})
        |> gate.()
        |> then_run(name, args, caller)

      :change ->
        case preview(name, args, caller.username) do
          {:change, use} ->
            use
            |> Map.merge(%{args: args, apply: fn -> run(name, args, caller) end})
            |> gate.()
            |> then_run(name, args, caller)

          # Nothing would change, or it is based on an older version: the
          # library answers that as it does for anyone, with nothing to ask.
          :same ->
            run(name, args, caller)

          :error ->
            {:ok, failure("Item not found in this identity.")}

          {:error, message} ->
            {:ok, failure(message)}
        end

      # A tool no grant covers is closed to the VM.
      nil ->
        {:ok, failure("#{name} isn't open to agents in the VM.")}
    end
  end

  defp then_run(:ok, name, args, caller), do: run(name, args, caller)
  defp then_run({:error, message}, _name, _args, _caller), do: {:ok, failure(message)}

  # A validated call, made, and its answer as MCP gives it.
  defp run(name, args, caller) do
    case execute(name, args, caller) do
      {:ok, data} ->
        data = with_urls(data, caller.base_url)

        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(data)}],
           "structuredContent" => data,
           "isError" => false
         }}

      {:error, message} ->
        {:ok, failure(message)}

      :error ->
        {:ok, failure("Item not found in this identity.")}
    end
  end

  defp failure(message),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp read_use(name, _args), do: %{grant: :read, tool: name}

  defp create_use(name, args) do
    {kind, title} =
      case name do
        "create_note" -> {:note, args["title"]}
        "create_diagram" -> {:diagram, args["title"]}
        "create_http_request" -> {:http, args["description"] || args["url"]}
        "import_http_request" -> {:http, args["description"]}
        "create_flashcards" -> {:cards, "#{length(args["cards"])} of them"}
      end

    %{grant: :create, tool: name, kind: kind, title: title, bytes: byte_size(Jason.encode!(args))}
  end

  # What a change would do, worked out as its library would, so the gate
  # can show it before anything changes.
  defp preview("update_note", args, username) do
    with {:ok, note} <- Notes.get(username, args["id"]) do
      updated = Note.update(note, update_attrs(args, [{"title", :title}, {"body", :body}]))
      from = %{title: note.title, body: note.body}
      to = %{title: updated.title, body: updated.body}
      change_use("update_note", :note, note, note.title, args, {from, to})
    end
  end

  defp preview("update_diagram", args, username) do
    with :ok <- validate_updated_elements(args),
         {:ok, diagram} <- Diagrams.get(username, args["id"]) do
      attrs = update_attrs(args, [{"title", :title}, {"elements", :elements}])
      updated = Diagram.update(diagram, attrs)
      from = %{title: diagram.title, elements: diagram.elements}
      to = %{title: updated.title, elements: updated.elements}
      change_use("update_diagram", :diagram, diagram, diagram.title, args, {from, to})
    end
  end

  defp preview("update_flashcard", args, username) do
    with {:ok, attrs} <- card_attrs(update_attrs(args, @card_fields)),
         {:ok, card} <- Flashcards.get(username, args["id"]) do
      updated = Card.update(card, attrs)
      updated = if args["resolved"], do: Card.resolve(updated, DateTime.utc_now()), else: updated
      from = card_shown(card)
      to = card_shown(updated)
      change_use("update_flashcard", :card, card, card.front, args, {from, to})
    end
  end

  # What a change to a card shows: what it says, and the mark it carries.
  defp card_shown(card) do
    uncertain =
      case card do
        %Card{uncertain_at: nil} -> nil
        %Card{uncertain_note: nil} -> "Marked uncertain"
        %Card{uncertain_note: note} -> "Marked uncertain: " <> note
      end

    card |> Map.take([:front, :back, :tags, :source]) |> Map.put(:uncertain, uncertain)
  end

  defp card_attrs(attrs) do
    case Card.validate(attrs) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, [{field, message} | _more]} -> {:error, "arguments.#{field} #{message}."}
    end
  end

  defp change_use(_tool, _kind, _item, _title, _args, {same, same}), do: :same

  defp change_use(_tool, _kind, item, _title, %{"version" => version}, _change)
       when version != item.version,
       do: :same

  defp change_use(tool, kind, item, title, _args, {from, to}) do
    {:change,
     %{grant: :change, tool: tool, kind: kind, id: item.id, title: title, from: from, to: to}}
  end

  defp execute("create_note", args, %Caller{username: username}) do
    with {:ok, note} <-
           Notes.save(username, Note.new_id(), %{title: args["title"], body: args["body"]}) do
      {:ok, note_data(note)}
    end
  end

  defp execute("get_note", args, %Caller{username: username}) do
    with {:ok, note} <- Notes.get(username, args["id"]), do: {:ok, note_data(note)}
  end

  defp execute("update_note", args, caller) do
    attrs = update_attrs(args, [{"title", :title}, {"body", :body}])

    caller.username
    |> Notes.update(args["id"], attrs, change_opts(args, caller))
    |> changed("note", "get_note", &note_data/1)
  end

  defp execute("list_notes", args, %Caller{username: username}) do
    items = Notes.list(username, Map.get(args, "query", ""))

    {:ok,
     page(items, args, fn note ->
       %{
         id: note.id,
         title: note.title,
         excerpt: note.excerpt,
         done: note.done_at != nil,
         updated_at: note.updated_at
       }
     end)}
  end

  defp execute("create_diagram", args, %Caller{username: username}) do
    with :ok <- validate_elements(args["elements"]),
         {:ok, diagram} <-
           Diagrams.save(username, Diagram.new_id(), %{
             title: args["title"],
             elements: args["elements"]
           }) do
      {:ok, diagram_data(diagram)}
    end
  end

  defp execute("get_diagram", args, %Caller{username: username}) do
    with {:ok, diagram} <- Diagrams.get(username, args["id"]), do: {:ok, diagram_data(diagram)}
  end

  defp execute("update_diagram", args, caller) do
    attrs = update_attrs(args, [{"title", :title}, {"elements", :elements}])

    with :ok <- validate_updated_elements(args) do
      caller.username
      |> Diagrams.update(args["id"], attrs, change_opts(args, caller))
      |> changed("diagram", "get_diagram", &diagram_data/1)
    end
  end

  defp execute("list_diagrams", args, %Caller{username: username}) do
    {:ok,
     page(Diagrams.list(username, Map.get(args, "query", "")), args, fn diagram ->
       %{
         id: diagram.id,
         title: diagram.title,
         element_count: diagram.count,
         updated_at: diagram.updated_at
       }
     end)}
  end

  defp execute("create_http_request", args, %Caller{username: username}) do
    headers =
      for row <- Map.get(args, "headers", []), do: Utils.new_row(row["name"], row["value"])

    request =
      Utils.new_request(%{
        url: args["url"],
        method: Map.get(args, "method", "GET"),
        headers: headers,
        body: Map.get(args, "body", ""),
        body_type: Map.get(args, "body_type", "text")
      })

    save_request(username, request, args)
  end

  defp execute("import_http_request", args, %Caller{username: username}) do
    case Curl.from_curl(args["curl"]) do
      {:ok, attrs} -> save_request(username, Utils.new_request(attrs), args)
      {:error, reason} -> {:error, "Could not parse curl: #{reason}"}
    end
  end

  defp execute("list_http_requests", args, %Caller{username: username}) do
    {:ok,
     page(Resources.summaries(username, Map.get(args, "query", "")), args, fn
       {id, description, tags, at, _duration, method, url, status} ->
         %{
           id: id,
           description: description,
           tags: tags,
           saved_at: at,
           method: method |> to_string() |> String.upcase(),
           request_url: URI.to_string(url),
           sent: status != 0
         }
     end)}
  end

  defp execute("get_http_request", args, %Caller{username: username}) do
    with {:ok, entry} <- Resources.get(username, args["id"]), do: {:ok, request_data(entry)}
  end

  defp execute("create_flashcards", args, %Caller{username: username}) do
    shared = Map.get(args, "tags", [])

    cards =
      for card <- args["cards"] do
        %{
          front: card["front"],
          back: card["back"],
          tags: shared ++ Map.get(card, "tags", []),
          source: Map.get(card, "source", args["source"])
        }
      end

    case Flashcards.create(username, cards) do
      {:ok, results} ->
        {:ok,
         %{
           created: Enum.count(results, &match?({:created, _card}, &1)),
           existing: Enum.count(results, &match?({:existing, _card}, &1)),
           removed: Enum.count(results, &match?({:removed, _card}, &1)),
           cards:
             for({status, card} <- results, do: Map.put(flashcard_data(card), :status, status)),
           path: "/tools/flashcards/cards"
         }}

      {:error, [{index, [{field, message} | _more]} | _others]} ->
        {:error, "arguments.cards[#{index}].#{field} #{message}."}
    end
  end

  defp execute("update_flashcard", args, caller) do
    attrs = update_attrs(args, @card_fields)
    change = if args["resolved"], do: &Flashcards.resolve/4, else: &Flashcards.update/4

    case change.(caller.username, args["id"], attrs, change_opts(args, caller)) do
      {:error, [{field, message} | _more]} -> {:error, "arguments.#{field} #{message}."}
      result -> changed(result, "flash card", "get_flashcard", &flashcard_data/1)
    end
  end

  defp execute("get_flashcard", args, %Caller{username: username}) do
    with {:ok, card} <- Flashcards.get(username, args["id"]), do: {:ok, flashcard_data(card)}
  end

  defp execute("list_flashcards", args, %Caller{username: username}) do
    scope = %{
      query: Map.get(args, "query", ""),
      tags: Map.get(args, "tags", []),
      match: if(args["match"] == "all", do: :all, else: :any),
      days: args["days"]
    }

    scope =
      if is_boolean(args["uncertain"]),
        do: Map.put(scope, :uncertain, args["uncertain"]),
        else: scope

    {:ok,
     page(Flashcards.list(username, scope), args, fn card ->
       card
       |> Map.take([
         :id,
         :front,
         :tags,
         :source,
         :box,
         :due_at,
         :reviews,
         :created_at,
         :updated_at
       ])
       |> Map.put(:uncertain, uncertain_data(card))
     end)}
  end

  defp execute("list_flashcard_tags", _args, %Caller{username: username}) do
    {:ok, %{tags: Flashcards.tags(username)}}
  end

  defp save_request(username, request, args) do
    url = URI.parse(Utils.full_url(request))

    if url.scheme in ["http", "https"] and is_binary(url.host) and url.host != "" and
         request.method in Utils.methods() do
      metadata =
        HistoryMetadata.new(%{description: args["description"], tags: Map.get(args, "tags", [])})

      request = Translation.to_req(request)
      id = Resources.record(username, metadata, request, nil)
      {:ok, request_data({id, metadata, request, nil})}
    else
      {:error, "Use an absolute http:// or https:// URL and a supported HTTP method."}
    end
  end

  # Who changes it, and the version the change was based on.
  defp change_opts(args, caller), do: [by: Caller.by(caller), version: args["version"]]

  defp changed({:ok, item}, _noun, _get, data), do: {:ok, data.(item)}
  defp changed(:error, _noun, _get, _data), do: :error

  defp changed({:stale, item}, noun, get, _data) do
    {:error,
     "This #{noun} changed since you read it: it is version #{item.version} now, and your change " <>
       "was based on another. Nothing was changed. Read it again with #{get} and make your change on what it holds now."}
  end

  defp update_attrs(args, fields) do
    for {key, field} <- fields, Map.has_key?(args, key), into: %{}, do: {field, args[key]}
  end

  defp validate_updated_elements(%{"elements" => elements}), do: validate_elements(elements)
  defp validate_updated_elements(_args), do: :ok

  defp note_data(note) do
    %{
      id: note.id,
      title: note.title,
      body: note.body,
      done: note.done_at != nil,
      version: note.version,
      created_at: note.created_at,
      updated_at: note.updated_at,
      path: "/tools/notes?id=#{note.id}"
    }
  end

  defp flashcard_data(%Card{} = card) do
    card
    |> Map.take([
      :id,
      :front,
      :back,
      :tags,
      :source,
      :box,
      :due_at,
      :reviews,
      :lapses,
      :removed_at,
      :version,
      :created_at,
      :updated_at
    ])
    |> Map.put(:uncertain, uncertain_data(card))
    |> Map.put(:path, "/tools/flashcards/cards?id=#{card.id}")
  end

  defp uncertain_data(%{uncertain_at: nil}), do: nil
  defp uncertain_data(card), do: %{note: card.uncertain_note, marked_at: card.uncertain_at}

  # Every saved item names its page, and so does every card of a batch.
  defp with_urls(data, base_url) do
    data = if data[:path], do: Map.put(data, :url, base_url <> data.path), else: data

    case data do
      %{cards: cards} when is_list(cards) ->
        %{data | cards: Enum.map(cards, &with_urls(&1, base_url))}

      data ->
        data
    end
  end

  defp diagram_data(diagram) do
    %{
      id: diagram.id,
      title: diagram.title,
      elements: diagram.elements,
      version: diagram.version,
      created_at: diagram.created_at,
      updated_at: diagram.updated_at,
      path: "/tools/diagrams?id=#{diagram.id}"
    }
  end

  defp request_data({id, metadata, request, response}) do
    %{
      id: id,
      description: metadata.description,
      tags: metadata.tags,
      method: request.method |> to_string() |> String.upcase(),
      request_url: URI.to_string(request.url),
      headers: request.headers,
      body: request.body || "",
      sent: response != nil,
      saved_at: metadata.completed_at,
      path: "/tools/http?id=#{id}"
    }
  end

  defp page(items, args, fun) do
    offset = Map.get(args, "offset", 0)
    limit = Map.get(args, "limit", 20)
    total = length(items)

    %{
      items: items |> Enum.slice(offset, limit) |> Enum.map(fun),
      total: total,
      next_offset: if(offset + limit < total, do: offset + limit, else: nil)
    }
  end

  # The canvas sanitizer is forgiving for interactive editing. Agent input is
  # checked before saving so duplicates and broken arrows cannot silently vanish.
  defp validate_elements(elements) do
    ids = Enum.map(elements, & &1["id"])
    targets = Map.new(elements, &{&1["id"], &1})

    error =
      elements
      |> Enum.with_index()
      |> Enum.find_value(fn {element, index} ->
        path = "arguments.elements[#{index}]"
        fields = if element["type"] == "arrow", do: ~w(x1 y1 x2 y2), else: ~w(x y width height)

        cond do
          not Diagram.id?(element["id"]) ->
            "#{path}.id must use 1–64 ASCII letters, digits, underscores or hyphens."

          Enum.any?(fields, &(not Map.has_key?(element, &1))) ->
            "#{path} (#{element["id"]}) requires #{Enum.join(fields, ", ")}."

          element["type"] != "arrow" and (element["width"] <= 0 or element["height"] <= 0) ->
            "#{path} (#{element["id"]}) requires positive width and height."

          element["type"] == "table" and invalid_rows?(Map.get(element, "rows", [])) ->
            "#{path}.rows requires valid row IDs unique within table #{inspect(element["id"])}."

          element["type"] == "arrow" ->
            validate_attachments(element, targets, path)

          true ->
            nil
        end
      end)

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        counts = Enum.frequencies(ids)
        duplicate = Enum.find(ids, &(counts[&1] > 1))

        {:error,
         "arguments.elements contains duplicate ID #{inspect(duplicate)}; use a unique ID for every element."}

      error ->
        {:error, error}

      problem = group_error(elements) ->
        {:error, problem}

      true ->
        :ok
    end
  end

  # The premises of groups the editor builds on (see `Diagram`), which the
  # canvas sanitizer would otherwise restore by changing what was written.
  defp group_error(elements) do
    members =
      for {element, index} <- Enum.with_index(elements),
          group <- Map.get(element, "groups", []),
          reduce: %{} do
        members -> Map.update(members, group, [index], &[index | &1])
      end
      |> Map.new(fn {group, indexes} -> {group, Enum.reverse(indexes)} end)

    repeated_group(elements) || nesting_error(elements) || size_error(elements, members) ||
      split_error(elements, members)
  end

  defp repeated_group(elements) do
    elements
    |> Enum.with_index()
    |> Enum.find_value(fn {element, index} ->
      groups = Map.get(element, "groups", [])

      if repeated = Enum.find(groups, &(Enum.count(groups, fn other -> other == &1 end) > 1)) do
        "#{element_path(elements, index)}.groups lists #{inspect(repeated)} twice; list each group once, outermost first."
      end
    end)
  end

  defp nesting_error(elements) do
    elements
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {element, index}, seen ->
      groups = Map.get(element, "groups", [])

      groups
      |> Enum.with_index()
      |> Enum.reduce_while(seen, fn {group, position}, seen ->
        before = Enum.take(groups, position)

        case Map.fetch(seen, group) do
          {:ok, {^before, _first}} ->
            {:cont, seen}

          {:ok, {other, first}} ->
            {:halt,
             {:error,
              "#{element_path(elements, index)}.groups lists #{inspect(group)} inside #{inspect(before)}, " <>
                "but #{element_path(elements, first)} lists it inside #{inspect(other)}; every member of a group " <>
                "lists the same groups before it, outermost first."}}

          :error ->
            {:cont, Map.put(seen, group, {before, index})}
        end
      end)
      |> case do
        {:error, message} -> {:halt, message}
        seen -> {:cont, seen}
      end
    end)
    |> case do
      message when is_binary(message) -> message
      _seen -> nil
    end
  end

  defp size_error(elements, members) do
    Enum.find_value(members, fn
      {group, [index]} ->
        "group #{inspect(group)} has one member, #{element_path(elements, index)}; a group needs two or more."

      _group ->
        nil
    end)
  end

  defp split_error(elements, members) do
    Enum.find_value(members, fn {group, indexes} ->
      {first, last} = {List.first(indexes), List.last(indexes)}

      if length(indexes) != last - first + 1 do
        inside = MapSet.new(indexes)
        apart = Enum.find(first..last, &(not MapSet.member?(inside, &1)))

        "group #{inspect(group)} is split by #{element_path(elements, apart)}, which lies between its members " <>
          "in drawing order; list a group's members next to each other."
      end
    end)
  end

  defp element_path(elements, index),
    do: "arguments.elements[#{index}] (#{Enum.at(elements, index)["id"]})"

  defp invalid_rows?(rows) do
    Enum.any?(rows, &(not Diagram.id?(&1["id"]))) or
      length(rows) != length(Enum.uniq_by(rows, & &1["id"]))
  end

  defp validate_attachments(arrow, targets, path) do
    Enum.find_value([{"start", "startRow"}, {"end", "endRow"}], fn {endpoint, row_key} ->
      id = arrow[endpoint]
      row = arrow[row_key]
      anchor_key = endpoint <> "Anchor"
      target = targets[id]

      cond do
        id != nil and (target == nil or target["type"] == "arrow") ->
          "#{path}.#{endpoint} names #{inspect(id)}, which must be an existing non-arrow element ID in this diagram."

        row != nil and
            (target == nil or not Enum.any?(Map.get(target, "rows", []), &(&1["id"] == row))) ->
          "#{path}.#{row_key} names #{inspect(row)}, which must be a row ID on the table referenced by #{endpoint}=#{inspect(id)}."

        arrow[anchor_key] != nil and id == nil ->
          "#{path}.#{anchor_key} pins an end that is not attached; set #{endpoint} to the element it is on."

        true ->
          nil
      end
    end)
  end
end
