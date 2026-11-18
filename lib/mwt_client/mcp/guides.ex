defmodule MWTClient.MCP.Guides do
  @moduledoc "Built-in agent guides available without repository or filesystem access."

  alias MWTClient.MCP.Catalogue

  @guides [
    {"notes", "Notes and search",
     "Markdown creation and updates, finding existing notes and following paginated results."},
    {"diagrams", "Native diagram layout",
     "Creating and updating diagrams, shape sizing, table geometry, row attachments and native examples."},
    {"http", "HTTP request samples",
     "Literal JSON/form bodies, headers, curl imports and the distinction between samples and sent history."},
    {"flashcards", "Flash cards from a thread",
     "Choosing what is worth remembering from a thread, writing questions that make the user recall it, tags and duplicates."}
  ]

  def list do
    for {slug, title, description} <- @guides do
      %{
        "uri" => "mwt://guides/#{slug}",
        "name" => "#{slug}-guide",
        "title" => title,
        "description" => description,
        "mimeType" => "text/markdown"
      }
    end
  end

  def read(uri) do
    if Enum.any?(list(), &(&1["uri"] == uri)) do
      {:ok, %{"uri" => uri, "mimeType" => "text/markdown", "text" => body(uri)}}
    else
      :error
    end
  end

  defp body("mwt://guides/notes") do
    """
    # Notes, search and pagination

    MWT is a local encrypted toolbox. All tools operate only on the identity
    associated with the Bearer token, while that identity is unlocked. You do
    not need repository access. Tools create, update, list and read notes and
    diagrams; they do not delete or mark notes complete. HTTP requests are
    append-only through MCP. Every create call generates a new ID, so blindly
    repeating a successful call creates a duplicate.

    create_note takes title and Markdown body strings. Code fences, Unicode,
    task lists and empty bodies are supported. Returned url opens the note in
    MWT. Use get_note with its string id to read the complete saved content.

    ## Updating an existing note

    Use list_notes/get_note to find and read the note, then call update_note
    with its id and title, body, or both. Omitted fields stay unchanged. body
    replaces the complete Markdown source; pass an empty string to clear it.
    The ID, creation time and completion state are preserved. Missing IDs
    return isError=true and never create a note. Repeating the same update
    leaves the note unchanged, including its updated_at timestamp.

    ## Search

    list_notes searches titles and Markdown bodies; list_diagrams searches
    titles and all canvas text, including table cells and arrow labels. These
    searches are case-insensitive, normalize whitespace and require every
    query word to match somewhere in the item. Accents are not stripped.

    list_http_requests instead matches one normalized substring across the
    description, URL, tags, headers and body. Omit query or pass an empty
    string to list all items. List results are summaries, not complete bodies.

    ## Pagination

    All list tools take query, limit (1–100, default 20) and offset (default 0).
    Results contain items, total and next_offset. Keep query and limit fixed,
    then pass next_offset as offset until it is null. An offset past the end
    returns an empty items array. Results are newest first; concurrent edits
    can move entries between pages, so paginate while the collection is stable.

    ## Errors and readback

    A tool result with isError=true explains an invalid argument or missing
    item. Correct the input before retrying. Successful create/update/get results
    include structuredContent plus equivalent JSON text. Use list/get to
    inspect existing items and read back important creations and updates.

    ## Example arguments
    """ <> examples("create_note") <> examples("update_note") <> examples("list_notes")
  end

  defp body("mwt://guides/diagrams") do
    """
    # Native MWT diagrams

    create_diagram takes a title and an elements array. These are editable
    native shapes and arrows, not Mermaid source or raster images. Each call
    creates another diagram. Use list_diagrams/get_diagram to inspect an
    existing layout and follow returned url to open it in MWT.

    ## Updating an existing diagram

    Call update_diagram with an existing id and title, elements, or both.
    Omitted fields stay unchanged. elements replaces the entire canvas rather
    than patching individual shapes: read get_diagram first, edit its elements
    and include every shape, arrow and attachment you want to keep. Pass an
    empty array to clear the canvas. Updates use the same layout validation
    as creation and invalid input leaves the saved diagram unchanged.
    The ID and creation time are preserved. Missing IDs return isError=true
    without creating anything. Repeating the same update changes nothing.

    ## Coordinates and layout

    x runs right and y runs down, in canvas units. rectangle, ellipse, diamond,
    text and table require x, y, positive width and positive height. arrows
    require x1, y1, x2 and y2, even when endpoints are attached to elements.
    Every element needs an id unique within its diagram, using 1–64 ASCII
    letters, digits, underscores or hyphens.

    Start simple shapes around 220 × 80, put connected shapes about 380 units
    apart horizontally or 180 vertically, and leave extra room for arrow
    labels. Use short labels and explicit newlines. The editor grows shapes to
    fit wrapped labels, fits free text, and recalculates table columns/heights.
    These are starting dimensions rather than fixed text measurements.

    Styles: color=ink/accent/ok/warn/bad/violet, fill=none/tint,
    stroke=solid/dashed, size=s/m/l. Defaults: ink, none, solid, m.
    Arrow head=end/both/none; default end. Use head=none for plain lifelines.

    ## Attachments

    start/end reference existing non-arrow element IDs in the same diagram.
    Omit an attachment or pass null for a free endpoint. Arrow coordinates
    remain required; the editor resolves attached endpoints after layout.

    Tables contain rows with id, type and name strings. Row IDs must be unique
    within their table. type is the left column and name the right column;
    row text is single-line. startRow/endRow reference a row on the table
    named by start/end. Referencing a nonexistent element/row is rejected
    rather than silently detaching the arrow.

    An attached end floats by default: it aims at the element's center from
    the next point along the arrow and stops at the outline, so two arrows
    between the same pair of elements overlap. startAnchor/endAnchor pin an
    end to one spot of the outline instead, as fractions of the element's
    box: {"x": 0.5, "y": 0} is the middle of the top edge, {"x": 0, "y": 0.75}
    three quarters down the left edge. On a table row only the side counts:
    x < 0.5 is the row's left edge, otherwise its right. An anchor requires
    its start/end.

    points lists the canvas points an arrow bends at, in order from start to
    end; a floating end heads for the nearest bend. Bend one of two opposite
    arrows (A to B and B to A) out of the other's way, or pin them to
    different spots. An element can be joined to itself when both ends are
    pinned or on different rows: pin both ends and add bends that run round
    the outside, e.g. start {"x": 0.25, "y": 0} and end {"x": 0.75, "y": 0}
    with points 40 units above each.

    ## Table sizing and row anchors

    | size | font | header height | row height |
    | --- | ---: | ---: | ---: |
    | s | 12 | 31 | 24 |
    | m | 14 | 36 | 28 |
    | l | 17 | 44 | 34 |

    height = header height + number of rows × row height.
    For zero-based row index i, its center is:
    y + header height + (i + 0.5) × row height.
    Horizontal anchors lie on the table's left or right edge, facing the other
    endpoint. A medium table with two rows has height 92; row centers are
    y+50 and y+78. Try width 260–320 and split 100 for short fields. The editor
    adjusts width and split to fit actual cells, so avoid treating them as
    permanent font measurements.

    ## Complete example arguments
    """ <> examples("create_diagram") <> examples("update_diagram")
  end

  defp body("mwt://guides/http") do
    """
    # HTTP request samples

    create_http_request saves a sample without sending any network request.
    import_http_request parses a curl command without executing curl or a
    shell. HTTP requests are append-only through MCP: each call creates a
    new item. Existing samples and sent history cannot be updated or deleted.
    To revise a request, save a new sample with the desired fields. Repeating
    a successful create/import call creates another sample. The user can open
    the returned MWT url and manually send it in HTTP Client.

    url in the creation arguments is the absolute http:// or https:// API
    destination. In results, request_url is that API destination, while url
    opens the saved item in MWT. IDs are positive integers, unlike note and
    diagram IDs, which are strings.

    ## Method, body and headers

    Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS. Default GET.
    body is always literal text: serialize a JSON object yourself, or provide
    URL-encoded form text such as sku=A123&quantity=1. JSON syntax is not
    validated, allowing intentionally malformed samples for testing.

    body_type defaults to text. none discards the body; text, json and form
    preserve its literal text and supply Content-Type text/plain,
    application/json or application/x-www-form-urlencoded respectively.
    An explicit Content-Type is preserved. An empty body stores no payload.

    Input headers are name/value objects. Repeat a name for multiple values.
    Result headers are lowercase names mapped to arrays of values. Optional
    description and tags make a sample easier to find.

    ## Finding and inspecting

    list_http_requests includes unsent samples and existing request history.
    sent=false means an unsent sample; sent=true means a recorded send attempt,
    including one that failed. get_http_request returns the stored request,
    never response payloads, and never sends it. Search is a case-insensitive
    normalized substring across description, URL, tags, headers and body.
    Follow next_offset until null, keeping query and limit fixed.

    ## Example arguments
    """ <> examples("create_http_request") <> examples("import_http_request")
  end

  defp body("mwt://guides/flashcards") do
    """
    # Flash cards

    MWT keeps flash cards the user studies in remember sessions. They vote
    on each card (forgot, hard, good, easy), and a card they forget comes
    back sooner than one they know. A session picks cards by tags, mixed and
    matched, and by when they were written, for example "the cards about
    mwt_client and grants" or "everything from the last 7 days". You write
    the cards; reviewing them is the user's alone. They also correct cards as
    they review them, and remove the ones not worth remembering; removing
    and deleting are not available through MCP.

    ## What is worth a card

    A card the user didn't need costs them more than it gives: it comes
    back in every session, and enough of them bury the few that matter.
    Worth a card is what the user will need in their own head in a month,
    and the code can't show them:

    - a decision, with the fact about their world it rests on ("one
      customer's nightly sync makes 50k calls from a single IP"). A reason
      that would fit any project ("best practice", "cleaner") is no reason;
    - a rule agreed on, or what the work revealed that changed the plan;
    - above all what is costly if wrong: what others rely on (an API, a
      format, a promise to users), data that is kept, how it behaves in
      production or when something fails, who carries the work or the risk.

    Never: what the code, its docs or git log say plainly; names, flags and
    signatures; steps taken once; status or a summary of the thread.

    ## Writing cards from a thread

    When asked to turn a thread or task into flash cards:

    1. Pick what passes the test above. A long thread gives a few cards,
       rarely more than five, never one per message.
    2. Write one idea per card. The front is a question that makes the user
       recall it: ask why, what or how, not yes or no, and name the thing
       asked about so the card makes sense on its own months later.
       "Why does each agent task run in a worktree slot?" works;
       "Slots?" and "Did we choose slots?" don't. A concrete case makes
       them work it out: "A payment arrives after its seat hold expired:
       what happens, and why that way?"
    3. The back answers in one to three sentences and gives the reason. A
       short code block or command is fine when it is the answer. Don't
       paste long code, logs or the whole discussion. When the choice was
       yours, not the user's, say so: they shouldn't recall it as theirs.
    4. Call list_flashcard_tags and reuse names already in use. Give
       every card the project (the repository name, as the user calls it)
       and a topic, in that order. Pass tags shared by every card once,
       at the top level of create_flashcards.
    5. Set source to where the cards come from, with the date:
       "Thread: worktree slots design, 2026-11-14". The user sees it under
       the answer.
    6. Send the cards in one create_flashcards call, then tell the user how
       many were created, and give them the returned url.

    ## Cards nobody asked for

    Rarely, and only when the task ends (the user asks for its handoff or
    says it is done): one to three, each of a decision the user made
    themselves, settled, and costly if wrong. Then say so in one line, with
    the url. Most tasks have none: write none and say nothing.

    ## Duplicates, removed cards and edits

    A card whose front and back match an existing card, ignoring case and
    spacing, is not saved again; it comes back with status=existing. So a
    repeated call is safe, but a reworded card is a new card: check
    list_flashcards with the project's tag before writing cards about a
    thread you may have covered already, and fix an existing card with
    update_flashcard rather than writing another.

    A card that comes back with status=removed matches one the user removed
    from the deck as not worth remembering. It is not added again. Take it as
    their judgement of what matters: don't write the same idea in other
    words. Updates keep how well the
    user remembers the card. tags in an update replaces the whole list.

    ## Tags

    Tags are labels, matched without regard to case; a card written with
    a tag already in use takes the spelling in use. Up to 10 per card,
    each up to 60 characters. The user picks sessions by combining them,
    so a tag is worth its name only if it gathers cards: prefer one more
    card under an existing tag to a new tag for one card.
    list_flashcard_tags returns them with how many cards hold each and how
    many are due.

    ## Finding cards

    list_flashcards searches front, back, tags and source, matching every
    query word. tags keeps cards holding any of them, or every one with
    match=all; days keeps cards written in the last that many days. Cards
    the user removed are left out; get_flashcard still reads one, with its
    removed_at. Results are summaries, newest first;
    get_flashcard returns the back too. Follow next_offset until null,
    keeping the other arguments fixed.

    ## Example arguments
    """ <> examples("create_flashcards") <> examples("update_flashcard")
  end

  defp examples(name) do
    tool = Enum.find(Catalogue.list(), &(&1["name"] == name))

    Enum.map_join(tool["inputSchema"]["examples"], "\n", fn example ->
      "\n### #{name}\n\n```json\n#{Jason.encode!(example, pretty: true)}\n```\n"
    end)
  end
end
