defmodule MWTClient.Sandbox.Egress.Driver.Http1 do
  @moduledoc """
  The driver for HTTP/1.1 (`MWTClient.Sandbox.Egress.Driver`): each request
  read, judged before any byte of it goes up, sent, and its answer read
  back, for the log and for the value that went in.

    1. **The head**, whole within 30 seconds however slowly it trickles,
       read strictly: a request two parsers could read two ways doesn't go
       out (`acceptable/5`). Its Host is the name the connection was
       encrypted for.
    2. **The start of its body**, all of it or its first 64 KiB, within 10
       seconds (`Expect: 100-continue` is answered here, so it comes), and
       framed (`Framing`): what the VM sent past the body's end is the next
       request's start, never part of this one.
    3. **Judged** (`{:judge, request}`), the card made from what was read.
    4. **Sent**: MWT writes the head itself, the values the verdict says put
       in (`Placeholder.swap/4`, in the grant's carriers only). A request
       with nothing put in it shares the link kept from the request before
       (HTTP/1.1's keep-alive), and the VM's connection waits for its next
       request; one with a value goes alone, on a new link, with
       `Connection: close`, and the VM's connection ends with it.
    5. **The answer**, read back: `Response` looks through every answer
       for every value MWT holds, whatever the request carried, and cuts
       it before one goes (asking the host only for encodings MWT
       decodes); for a request with a value in it, it also puts the
       placeholder back in every head. A kept request's answer is read to
       where it ends, so its link carries the next. With no value to look
       for, `Answer` reads only where it ends; a WebSocket's bytes are
       looked through as they stream.

  A kept link the host closed just as a request went on it took none of
  it, or did nothing it can't do twice: the request goes again on a new
  one, once, as any HTTP client does (`retryable?/2`).

  What MWT answers itself (a refusal, a request it can't read) is HTTP,
  with MWT's JSON (`code`, `error`, `by`), and closes the connection.
  """

  @behaviour MWTClient.Sandbox.Egress.Driver

  alias MWTClient.Sandbox.{Describe, Exchange, Placeholder, Secrets}
  alias MWTClient.Sandbox.Egress.{Driver, Request, RequestHead, Scanner}
  alias MWTClient.Sandbox.Egress.Driver.Http1.{Answer, Framing, Response, WebSocket}

  @head_limit 64 * 1024
  @body_peek 64 * 1024
  @idle 300_000
  @head_within 30_000
  @body_within 10_000
  # How long bytes that could start a real value wait for what follows
  # before they go anyway.
  @hold 50
  # The value put in a request is looked for in its answer down to this
  # many bytes: that value only, so a shorter one than anywhere else.
  @echo_shortest 8

  # `phase`: reading a `:head`, the start of its `:body`, `:judging` it, or
  # its `:answer`. `linked?` while a link to the host is open, kept from
  # the request before or this one's; `pending`, what the VM sent past the
  # body's end. For the request in flight: what the log keeps (`record`),
  # how its `answer` is read, whether its link is kept (`keep?`), went on
  # the kept one (`reused?`), and its bytes, to send again (`resend`) when
  # the host turns out to have closed that one (`retry?` when that's safe
  # after it took them); `reusable?`, with nothing put in it, its link may
  # carry the next request once its answer is read to its end (a switch
  # the host declines included); `look`, what of an answer no `Response`
  # reads is looked through with (`down/2`); `fresh?` until anything moved
  # since it went; `ws`,
  # a WebSocket whose messages MWT reads: its answer's head until it
  # switched, then each side's frames (`WebSocket`); `read`, the request's
  # bytes until it is judged, looked through should MWT refuse it; `later`,
  # what the VM sent while it was judged, framed once it goes; `upgrade`,
  # for a request that asked to switch protocols (`Upgrade`), the host's
  # answer's head as read so far, until it says whether it switched
  # (`watch_switch/3`).
  defstruct [
    :ctx,
    :upgrade,
    :by,
    :head,
    :framing,
    :request,
    :record,
    :answer,
    :resend,
    :ws,
    :look,
    phase: :head,
    buffer: "",
    read: "",
    body: "",
    pending: "",
    later: "",
    linked?: false,
    keep?: false,
    reused?: false,
    retry?: false,
    retrying?: false,
    reusable?: false,
    fresh?: false
  ]

  @impl true
  def alpn, do: ["http/1.1"]

  @doc """
  A request's first bytes, on TCP. Inside TLS MWT ended, a method's name
  and a space, or bytes too few to tell yet. As plain bytes, from the
  client, its whole request line (`GET /path HTTP/1.1`), so a plain
  protocol that happens to begin with a word in capitals (IRC's `NICK
  name`) isn't taken for HTTP. Read as plain bytes, nothing proves which
  host is there: the request names its host itself (`Host`), and no real
  value goes in it (`Request.plain?`).
  """
  @impl true
  # HTTP/2's preface begins as a request would (`PRI * HTTP/2.0`): it is
  # `Driver.Http2`'s.
  def detect("PRI " <> _rest, %{transport: :tcp, tls?: true}), do: :no

  # Empty lines before a request are claimed, so the request is refused
  # (`400`) rather than passed on unread: servers skip them (RFC 9112
  # 2.2), and a request a host reads that MWT took for bytes would go
  # unjudged, past a host list and a network grant's ask.
  def detect(data, %{transport: :tcp, tls?: true}) do
    case past_empty_lines(data) do
      empty when empty in ["", "\r"] -> :more
      rest -> if rest =~ ~r/\A[A-Z]{1,20}( |\z)/, do: :yes, else: :no
    end
  end

  def detect(data, %{transport: :tcp, tls?: false, first: :vm}) do
    rest = past_empty_lines(data)

    cond do
      rest =~ ~r/\A[A-Z]{1,20} [\x21-\x7e]+ HTTP\/1\.[01]\r\n/ -> :yes
      byte_size(data) < 8192 and rest =~ ~r/\A(\r|[A-Z]{1,20}( [^\r\n]*)?)?\z/ -> :more
      true -> :no
    end
  end

  def detect(_data, _ctx), do: :no

  defp past_empty_lines("\r\n" <> rest), do: past_empty_lines(rest)
  defp past_empty_lines(data), do: data

  @impl true
  def init(ctx), do: awaiting_head(%__MODULE__{ctx: ctx, linked?: ctx.linked?}, "")

  @doc """
  The request as the sandbox's server reads it: `host`, `port`, `method`,
  `path`, `headers`, the start of its `body`, the grant it went `under`,
  and its `exchange`.
  """
  @spec message(Request.t()) :: map()
  def message(%Request{data: data} = request) do
    message = %{
      host: request.name,
      port: request.port,
      method: request.operation,
      path: request.resource,
      headers: data.headers,
      body: data.body,
      under: request.under,
      exchange: request.id
    }

    # Over plain HTTP, the address it goes to beside the name it claims:
    # its card says both, and no value goes in it.
    if request.plain?,
      do: Map.merge(message, %{plain?: true, ip: "#{:inet.ntoa(request.ip)}"}),
      else: message
  end

  @impl true
  def describe(request), do: Describe.request(message(request))

  @doc """
  `headers` with each value the core said put in (an allowing verdict's
  `request` replacements) where its placeholder is, inside the headers it
  travels in only, a `Basic` credential's base64 included
  (`MWTClient.Sandbox.Placeholder.swap/4`): what replacing is for HTTP/1.1.
  """
  @spec replace([{String.t(), String.t()}], [Driver.replacement()]) :: [{String.t(), String.t()}]
  def replace(headers, replacements) do
    Enum.reduce(replacements, headers, fn swap, headers ->
      Placeholder.swap(headers, swap.from, swap.to, swap.within)
    end)
  end

  ## The VM's bytes

  @impl true
  def handle_data(:vm, data, %{phase: :head} = http), do: head(http, http.buffer <> data)

  def handle_data(:vm, data, %{phase: :body} = http),
    do: body(%{http | read: http.read <> data}, data)

  # Read while it is judged, so a client that gives up (a timeout while
  # you decide) ends the request before it goes: one decision sends it
  # once, for the client still there. What comes meanwhile (the rest of
  # its body, the next request) is kept as it came, framed once it goes;
  # past a head's worth the VM waits, and a close behind those bytes goes
  # unseen until they are read.
  def handle_data(:vm, data, %{phase: :judging} = http) do
    later = http.later <> data
    more = if byte_size(later) <= @head_limit, do: [{:read, :vm, :infinity}], else: []
    {more, %{http | later: later}}
  end

  # A WebSocket's frames from the VM: written again, their text looked
  # through as the request's own stream (`WebSocket`). Bytes that stop
  # being frames go on as bytes from there.
  def handle_data(
        :vm,
        data,
        %{phase: :answer, ws: %{vm_raw?: false, switched?: true} = ws} = http
      ) do
    reads = [{:read, :vm, :infinity}, {:read, :host, @idle}]

    case WebSocket.feed(ws.vm, data) do
      {:ok, parts, reader} ->
        {frames_up(parts, http.request.id) ++ reads,
         %{http | ws: %{ws | vm: reader}, fresh?: false}}

      {:broken, parts, rest, reader} ->
        rest = if rest != "", do: [{:send, :host, rest}], else: []

        {frames_up(parts, http.request.id) ++ rest ++ reads,
         %{http | ws: %{ws | vm: reader, vm_raw?: true}, fresh?: false}}
    end
  end

  # Past the body's end, a kept request's bytes are the next request's,
  # kept for it, and so are those after a request asking to switch
  # protocols until its answer says whether the host did (`watch_switch/3`);
  # anyone else's go nowhere. A VM sending more than a head's worth ahead
  # waits for the answer to end.
  def handle_data(:vm, data, %{phase: :answer} = http) do
    case body_bytes(http.framing, data) do
      {:ok, data, framing, beyond} ->
        pending = if http.keep? or http.upgrade, do: http.pending <> beyond, else: ""
        up = if data != "", do: [{:send, :host, data}], else: []
        more = if byte_size(pending) <= @head_limit, do: [{:read, :vm, :infinity}], else: []

        http = %{
          http
          | framing: framing,
            pending: pending,
            record: kept_more(http.record, framing, data),
            fresh?: false
        }

        {up ++ more ++ [{:read, :host, waiting(http.answer)}], http}

      :error ->
        close(http, "Cut by MWT: it could not read where the body ends.")
    end
  end

  ## The host's bytes

  def handle_data(:host, data, %{phase: :answer, upgrade: %{} = upgrade} = http),
    do: watch_switch(%{http | upgrade: nil}, upgrade.head <> data, data)

  def handle_data(:host, data, http), do: host_data(data, http)

  # A request that asked to switch protocols: the VM's bytes past its body
  # wait until the head of the host's answer says whether it switched
  # (`101`), which HTTP leaves to the host. Switched, they go on, as
  # another protocol's, unread (a WebSocket's, as its frames); not, the
  # request was an ordinary one, and its connection carries the next
  # request, judged as any is, when its answer was read to its end. Before,
  # MWT passed on whatever the VM sent after such a request, switched or
  # not: requests no card showed and the log didn't keep.
  defp watch_switch(http, buffer, data) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] when byte_size(head) <= @head_limit ->
        case Response.read_head(head) do
          {:ok, 101, _headers} -> switched(http, data)
          {:ok, status, _headers} when status in 100..199 -> watch_switch(http, rest, data)
          _final -> declined(http, data)
        end

      [_partial] when byte_size(buffer) <= @head_limit ->
        host_data(data, %{http | upgrade: %{head: buffer}})

      _unreadable ->
        declined(http, data)
    end
  end

  defp switched(http, data) do
    held = http.pending
    # An answer read only for its end has none now: it is another protocol.
    # One looked through goes on being, as bytes (`Response`'s `:raw`).
    answer = if match?(%Answer{}, http.answer), do: nil, else: http.answer
    {down, http} = host_data(data, %{http | answer: answer, framing: :open, pending: ""})

    if held == "" do
      {down, http}
    else
      {up, http} = handle_data(:vm, held, http)
      {down ++ up, http}
    end
  end

  defp declined(http, data),
    do: host_data(data, %{http | keep?: http.reusable? and http.answer != nil})

  # A WebSocket's answer: its head, to the VM as it is once looked through
  # whole (`look`); switched (`101`), its frames are read from then on;
  # any other answer goes on as one MWT doesn't read the end of. What
  # follows the head is looked through as it streams (`down/2`).
  defp host_data(data, %{phase: :answer, ws: %{switched?: false} = ws} = http) do
    buffer = ws.head <> data

    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        case Secrets.find(http.look && http.look.secrets, head) do
          nil ->
            {vm, http} = to_vm(%{http | fresh?: false}, [head, "\r\n\r\n"])

            case Response.read_head(head) do
              {:ok, 101, _headers} ->
                {more, http} =
                  websocket_down(%{http | ws: %{ws | switched?: true, head: ""}}, rest)

                {vm ++ more, http}

              _other ->
                {more, http} = down(%{http | ws: nil}, rest)
                {vm ++ more, http}
            end

          label ->
            answered({:cut, {:found, label}, []}, %{http | fresh?: false})
        end

      [_partial] when byte_size(buffer) > @head_limit ->
        down(%{http | ws: nil, fresh?: false}, buffer)

      [_partial] ->
        {[{:read, :host, @idle}], %{http | ws: %{ws | head: buffer}}}
    end
  end

  defp host_data(data, %{phase: :answer, ws: %{switched?: true}} = http),
    do: websocket_down(%{http | fresh?: false}, data)

  defp host_data(data, %{phase: :answer, answer: nil} = http),
    do: down(%{http | fresh?: false}, data)

  defp host_data(data, %{phase: :answer, answer: %Answer{} = answer} = http) do
    case Answer.feed(answer, data) do
      {:more, bytes, answer} ->
        {vm, http} = to_vm(%{http | answer: answer, fresh?: false}, bytes)
        {vm ++ [{:read, :host, @idle}], http}

      # Bytes after the answer's end are none the VM asked for: the link
      # that sent them isn't kept.
      {:done, bytes, beyond, keep?} ->
        {vm, http} = to_vm(http, bytes)
        {next, http} = next_request(http, keep? and beyond == "")
        {vm ++ next, http}
    end
  end

  defp host_data(data, %{phase: :answer} = http),
    do: http.answer |> Response.feed(data) |> answered(%{http | fresh?: false})

  # On a kept link between requests, bytes nothing asked for end it.
  defp host_data(_data, http), do: {[{:close, :host}], %{http | linked?: false}}

  ## Verdicts

  @impl true
  def handle_verdict(id, verdict, %{phase: :judging, request: %{id: id}} = http) do
    case verdict do
      {:allow, replace} -> send_upstream(http, replace)
      {:deny, status, json} -> answer_self(http, status, json)
      {:reply, status, json} -> answer_self(http, status, json)
    end
  end

  def handle_verdict(_id, _verdict, http), do: {[], http}

  ## Ends

  @impl true
  def handle_closed(:host, {:unreachable, reason}, %{phase: :answer} = http) do
    cond do
      http.retrying? -> unreachable_now(http, reason)
      match?({:tls_alert, _}, reason) -> host_refused(http, reason)
      true -> could_not_reach(http, reason)
    end
  end

  # The kept link turned out closed as the bytes went: it took none of
  # them, so they go on a new one.
  def handle_closed(:host, {:send_failed, _reason}, %{phase: :answer, reused?: true} = http),
    do: again(%{http | retry?: false})

  def handle_closed(:host, {:send_failed, reason}, %{phase: :answer} = http),
    do: could_not_reach(http, reason)

  def handle_closed(:host, _ended, %{phase: :answer, answer: %Answer{}} = http),
    do: ended_early(http)

  # A kept request's answer, looked through: as one read for its end.
  def handle_closed(:host, _ended, %{phase: :answer, answer: %Response{}, keep?: true} = http),
    do: ended_early(http)

  def handle_closed(:host, :closed, %{phase: :answer, answer: %Response{} = response} = http),
    do: response |> Response.finish() |> answered(http)

  def handle_closed(:host, :closed, %{phase: :answer} = http), do: close(http, nil)

  def handle_closed(:host, _failed, %{phase: :answer} = http),
    do: close(http, "The connection failed before the answer ended.")

  # The link kept between requests closed: the next one gets a new one.
  def handle_closed(:host, _ended, http), do: {[], %{http | linked?: false}}

  def handle_closed(:vm, _ended, %{phase: phase} = http) when phase in [:judging, :answer],
    do: close(http, nil)

  def handle_closed(:vm, _ended, http), do: {[:close], http}

  @impl true
  def handle_timeout(:vm, %{phase: :body} = http) do
    refuse(
      http,
      408,
      "mwt_bad_request",
      "The request's body didn't arrive within #{div(@body_within, 1000)} s. MWT reads " <>
        "a body, up to #{div(@body_peek, 1024)} KiB of it, before it decides on the request."
    )
  end

  def handle_timeout(:host, %{phase: :answer, answer: %Response{} = response} = http) do
    if Response.held?(response) do
      {bytes, response} = Response.release(response)
      {vm, http} = to_vm(%{http | answer: response}, bytes)
      {vm ++ [{:read, :host, waiting(response)}], http}
    else
      idle(http)
    end
  end

  # Bytes `down/2` held back go: the stream paused, so they weren't a
  # value's start, or what follows will be looked through with them.
  def handle_timeout(:host, %{phase: :answer, look: %Scanner{held: held} = look} = http)
      when held != "" do
    {held, look} = Scanner.release(look)
    {vm, http} = to_vm(%{http | look: look}, held)
    {vm ++ [{:read, :host, @idle}], http}
  end

  def handle_timeout(:host, %{phase: :answer} = http), do: idle(http)

  # A head that didn't come whole in time, or anything else: the end.
  def handle_timeout(_side, http), do: {[:close], http}

  @impl true
  def handle_cut({:found, _label}, %{phase: :answer, fresh?: true} = http) do
    answer_self(
      http,
      403,
      Jason.encode!(%{
        code: "mwt_value_blocked",
        error:
          "This request holds a real credential, which nothing in the VM should have. " <>
            "It did not go out. The user has been told.",
        by: "MWT agent sandbox"
      })
    )
  end

  def handle_cut({:found, _label}, %{phase: :answer} = http),
    do: close(http, "Cut by MWT: the VM sent a real credential after the head.")

  # Isolated, the VM is told so, as for any request; otherwise the
  # connection only closes, as a tunnel's does.
  def handle_cut(:isolated, %{phase: :answer, fresh?: true} = http) do
    {:deny, status, json} = MWTClient.Sandbox.Server.Values.isolated()
    answer_self(http, status, json)
  end

  def handle_cut(:grant_ended, %{phase: phase} = http) when phase in [:judging, :answer],
    do: close(http, "Closed by MWT: the grant that let it through ended.")

  def handle_cut(_cut, %{phase: phase} = http) when phase in [:judging, :answer],
    do: close(http, "Cut by MWT's firewall.")

  def handle_cut(_cut, http), do: {[:close], http}

  ## Reading a request

  defp awaiting_head(http, data) do
    by = within(Keyword.get(http.ctx.options, :head_within, @head_within))
    head(%{http | phase: :head, buffer: "", by: by}, data)
  end

  # A head, whole by its deadline. One that ends its lines with line feeds
  # alone never ends for this reader: said at once, instead of waiting for
  # more.
  defp head(http, buffer) do
    http = %{http | read: buffer}

    case :binary.split(buffer, "\r\n\r\n") do
      [head, _rest] when byte_size(head) > @head_limit ->
        too_large(http)

      [head, rest] ->
        headed(%{http | buffer: ""}, head, rest)

      [_partial] when byte_size(buffer) > @head_limit ->
        too_large(http)

      [_partial] ->
        if :binary.match(buffer, "\n\n") != :nomatch,
          do: unreadable_request(http),
          else: {[{:read, :vm, left(http.by)}], %{http | buffer: buffer}}
    end
  end

  defp headed(http, head, rest) do
    %{port: port, tls?: tls?} = http.ctx

    with {:ok, method, target, version, headers} <- parse_request(head),
         {:ok, name} <- request_name(headers, http.ctx),
         :ok <- acceptable(method, target, headers, name, port) do
      # One Host, and it is the name the connection was encrypted for. As
      # plain bytes, it is the client's own word, kept as it wrote it.
      headers =
        if tls?,
          do: List.keyreplace(headers, "host", 0, {"host", authority(name, port)}),
          else: headers

      {continue, headers} = continue_if_expected(headers)
      by = within(Keyword.get(http.ctx.options, :body_within, @body_within))

      head = %{
        method: method,
        target: target,
        version: version,
        headers: headers,
        name: name,
        upgrade?: List.keymember?(headers, "upgrade", 0)
      }

      {actions, http} =
        body(%{http | phase: :body, head: head, framing: Framing.request(headers), by: by}, rest)

      {continue ++ actions, http}
    else
      {:misdirected, host} ->
        respond(
          http,
          421,
          Jason.encode!(%{
            error: "Host #{host} does not match #{authority(http.ctx.name, port)}.",
            by: "MWT agent sandbox"
          })
        )

      {:refuse, status, code, message} ->
        refuse(http, status, code, message)

      {:error, :bad_request} ->
        unreadable_request(http)
    end
  end

  # The host a request is for: inside TLS, the name the connection was
  # encrypted for; as plain bytes, the one its Host names, a host name or
  # an address, on the port it connected to. Several Hosts, or none, are
  # `acceptable/5`'s to refuse.
  defp request_name(_headers, %{tls?: true, name: name}), do: {:ok, name}

  defp request_name(headers, %{port: port}) do
    case for {"host", value} <- headers, do: String.downcase(value) do
      [host] ->
        {name, given} =
          case Regex.run(~r/\A(.+?)(?::(\d{1,5}))?\z/, host) do
            [_, name, port] -> {name, port}
            [_, name] -> {name, nil}
            nil -> {host, nil}
          end

        cond do
          given && given != "#{port}" ->
            {:refuse, 400, "mwt_bad_request",
             "The request's Host names port #{given}, but it connected to #{port}."}

          name =~ ~r/\A[a-z0-9_]([a-z0-9_.-]{0,251}[a-z0-9_])?\z/ ->
            {:ok, name}

          true ->
            {:refuse, 400, "mwt_bad_request",
             "The request's Host must be a host name or an IPv4 address."}
        end

      _none_or_several ->
        {:ok, nil}
    end
  end

  # The start of the body, read before deciding: all of it, or its first
  # 64 KiB when it is longer, by the deadline (10 seconds), or the request
  # is refused. A card is made from what was read, so it never says "no
  # body" for one that hadn't come yet. Also how the rest is framed
  # (`Framing`): `:done` when it has all come, `:open` after an `Upgrade`,
  # whose bytes, once the host switches, belong to the new protocol. What
  # follows the body's end isn't part of this request: it doesn't go with
  # it, and is the start of the next one.
  defp body(http, data) do
    case Framing.feed(http.framing, data) do
      {:done, body, beyond} ->
        judge(http, http.body <> body, :done, beyond)

      {:more, more, framing} ->
        body = http.body <> more

        if byte_size(body) >= @body_peek,
          do: judge(http, body, framing, ""),
          else: {[{:read, :vm, left(http.by)}], %{http | body: body, framing: framing}}

      :error ->
        refuse(
          http,
          400,
          "mwt_bad_request",
          "MWT could not read where the request's chunked body ends."
        )
    end
  end

  defp judge(http, body, framing, beyond), do: judging(http, body, framing, beyond)

  defp judging(http, body, framing, beyond) do
    %{method: method, target: target, version: version, headers: headers} = http.head

    request = %Request{
      id: Exchange.new_id(),
      driver: __MODULE__,
      name: http.head.name,
      ip: http.ctx.ip,
      plain?: not http.ctx.tls?,
      port: http.ctx.port,
      under: http.ctx.under,
      operation: method,
      resource: target,
      data: %{version: version, headers: headers, body: body}
    }

    # What the VM sent, kept for the log before a value goes in (`sent_up`,
    # with what of its body follows, `more`), and what went back to it.
    record = %{
      sent_up: message(request),
      more: [],
      sent: Exchange.capture(http.ctx.limit)
    }

    {[{:judge, request}, {:read, :vm, :infinity}],
     %{
       http
       | phase: :judging,
         request: request,
         record: record,
         framing: framing,
         pending: beyond,
         later: "",
         body: "",
         read: ""
     }}
  end

  ## Sending it

  # With the values the verdict says put in, and what of them to look for
  # in the answer. A request with nothing put in it that may share a link
  # (`keeps?/2`) goes on the one kept from the request before, and its
  # answer is read to know where it ends (`Answer`), so the VM's
  # connection can carry the next.
  defp send_upstream(http, replace) do
    %Request{operation: method, resource: path, data: data} = http.request

    headers = replace(data.headers, replace.request)
    echo = echo(replace, headers)
    # Every value MWT holds, which the answer mustn't carry to the VM
    # whatever this request carried (`Driver`'s `values`).
    values = Map.get(replace, :values)
    # A WebSocket MWT reads the messages of, one with no value in it: its
    # extensions offer goes, so no message comes compressed.
    websocket? = echo == nil and websocket?(headers)

    headers =
      if websocket?,
        do: Enum.reject(headers, fn {name, _} -> name == "sec-websocket-extensions" end),
        else: headers

    keep? = replace.request == [] and keeps?(data.version, headers)
    upgrade? = List.keymember?(headers, "upgrade", 0)
    encodings = if(echo, do: :identity, else: if(values, do: :readable, else: :as_sent))
    head = head(method, path, data.version, headers, encodings, keep?)
    reuse? = keep? and http.linked?

    # A switch the host may decline: its answer is read to where it ends,
    # so a declined one's connection carries the next request.
    reusable? = replace.request == [] and (keep? or (upgrade? and not websocket?))

    # Looked through (`Response`) when there is anything to look for: the
    # values put in, and every value MWT holds. With nothing to look for,
    # read only for where it ends (`Answer`), or not at all.
    answer =
      cond do
        websocket? -> nil
        echo != nil -> Response.new(method, elem(echo, 0), elem(echo, 1), values)
        values != nil -> Response.new(method, nil, %{}, values)
        reusable? -> Answer.new(method)
        true -> nil
      end

    connect = if reuse?, do: [], else: [{:connect, %{alpn: alpn()}}]
    body = if data.body != "", do: [{:send, :host, data.body}], else: []

    http = %{
      http
      | phase: :answer,
        answer: answer,
        keep?: keep?,
        reused?: reuse?,
        linked?: true,
        resend: if(keep?, do: [head, data.body]),
        retry?: keep? and retryable?(method, http.framing),
        retrying?: false,
        reusable?: reusable?,
        # An answer no `Response` reads (a WebSocket's) is looked through
        # as bytes: a server's frames aren't masked, so a value in one
        # message is in them as it is. One split across frames (a message
        # in fragments) isn't seen.
        look: if(answer == nil and values != nil, do: Scanner.new(values, hold: true)),
        fresh?: true,
        upgrade: if(upgrade?, do: %{head: ""}),
        ws:
          if(websocket?,
            do: %{
              switched?: false,
              head: "",
              vm: WebSocket.new(:vm, http.ctx.limit),
              host: WebSocket.new(:host, http.ctx.limit),
              vm_raw?: false,
              host_raw?: false
            }
          )
    }

    actions =
      connect ++
        [{:write, :host, head}] ++
        body ++ [{:read, :host, waiting(answer)}, {:read, :vm, :infinity}]

    sent_later(actions, http)
  end

  # What the VM sent while the request was judged goes on behind it, as
  # if it came now: the rest of its body, or the next request, kept. It
  # goes in the same write as the head, so the request is still fresh.
  defp sent_later(actions, %{later: ""} = http), do: {actions, http}

  defp sent_later(actions, http) do
    {more, http} = handle_data(:vm, http.later, %{http | later: ""})
    {actions ++ more, %{http | fresh?: true}}
  end

  @doc """
  The forms the values a verdict put in go by, each to come back to the VM
  as its placeholder, as `{secrets, placeholders}` (`placeholders` by
  label): those the core named (`replace.answer`), and the one MWT wrote
  into a carrier of `headers` when that isn't the value as it is (a Basic
  credential's base64). Nil with nothing put in. `Driver.Http2` reads its
  answers the same way.
  """
  @spec echo(%{request: [Driver.replacement()], answer: [Driver.back()]}, [
          {String.t(), String.t()}
        ]) ::
          {Secrets.t(), %{term() => String.t()}} | nil
  def echo(%{answer: []}, _headers), do: nil

  def echo(replace, headers) do
    written =
      for swap <- replace.request,
          {name, header} <- headers,
          name in swap.within,
          not String.contains?(header, swap.to),
          String.contains?(Placeholder.decoded(header) || "", swap.to),
          [_scheme, encoded] <- [String.split(header, " ", parts: 2)],
          do: {swap.label, String.trim(encoded)}

    entries =
      for back <- replace.answer,
          do:
            {back.label,
             back.from ++ for({label, form} <- written, label == back.label, do: form)}

    case Secrets.new(entries, @echo_shortest) do
      nil -> nil
      secrets -> {secrets, Map.new(replace.answer, &{&1.label, &1.to})}
    end
  end

  defp websocket?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "upgrade" and String.downcase(value) =~ "websocket"
    end)
  end

  # A WebSocket's VM frames as actions: MWT's headers, the VM's text as the
  # request's own stream.
  defp frames_up(parts, stream) do
    Enum.map(parts, fn
      {:frame, header} -> {:frame, :host, header}
      {:payload, text} -> {:send, :host, text, stream}
    end)
  end

  # A WebSocket's bytes from the host: to the VM as `down/2` lets them,
  # their messages read for the log until they stop being frames.
  defp websocket_down(%{ws: ws} = http, data) do
    ws =
      if ws.host_raw?,
        do: ws,
        else:
          (case WebSocket.feed(ws.host, data) do
             {:ok, _parts, reader} -> %{ws | host: reader}
             {:broken, _parts, _rest, reader} -> %{ws | host: reader, host_raw?: true}
           end)

    down(%{http | ws: ws}, data)
  end

  # An answer's bytes no `Response` reads, to the VM as they came but for
  # those that could start a value (`look`), held until what follows
  # comes or the stream pauses (`handle_timeout/2`). A value cuts it
  # there, as `Response` does.
  defp down(http, data) do
    case Scanner.feed(http.look || Scanner.new(nil), data) do
      {:ok, out, look} ->
        {vm, http} = to_vm(%{http | look: http.look && look}, out)
        wait = if http.look && Scanner.held?(look), do: @hold, else: @idle
        {vm ++ [{:read, :host, wait}], http}

      {:found, label} ->
        answered({:cut, {:found, label}, []}, http)
    end
  end

  # A request that may share a link with the next: from a client that
  # keeps its own (HTTP/1.1, no `Connection: close`), switching to no
  # other protocol. Its answer then needs reading only for where it ends.
  defp keeps?(version, headers) do
    version == "HTTP/1.1" and
      not Enum.any?(headers, fn {name, value} ->
        name == "upgrade" or (name == "connection" and close?(value))
      end)
  end

  defp close?(value),
    do:
      value |> String.downcase() |> String.split(",") |> Enum.any?(&(String.trim(&1) == "close"))

  # Sent again on a new link, should the kept one turn out closed before
  # any of the answer came: only a request doing it twice can't change
  # (RFC 9110's idempotent methods) and whose whole body MWT holds.
  defp retryable?(method, framing),
    do: method in ~w(GET HEAD OPTIONS PUT DELETE) and framing == :done

  # The head MWT writes itself: with a value in it, alone on its link
  # (`Connection: close`) and asking for an answer without content
  # encoding, so a value it quotes can be read; kept (`keep?`), with no
  # `Connection` header, HTTP/1.1's own keep-alive. `encodings`: what
  # the answer may come encoded in, `:identity` for a value put in,
  # `:readable` while there are values to look for (`readable/1`), else
  # `:as_sent`.
  defp head(method, path, version, headers, encodings, keep?) do
    upgrade? = Enum.any?(headers, fn {name, _} -> name == "upgrade" end)

    headers =
      headers
      |> Enum.reject(fn {name, _} ->
        name in ["proxy-connection", "keep-alive"] or (name == "connection" and not upgrade?)
      end)
      |> accept_encoding(encodings)
      |> then(&if(upgrade? or keep?, do: &1, else: &1 ++ [{"connection", "close"}]))

    [
      method,
      " ",
      path,
      " ",
      version,
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]
  end

  # The answer's encodings MWT asks for (`head/6`).
  defp accept_encoding(headers, :as_sent), do: headers

  defp accept_encoding(headers, :identity),
    do: List.keydelete(headers, "accept-encoding", 0) ++ [{"accept-encoding", "identity"}]

  defp accept_encoding(headers, :readable) do
    case for({"accept-encoding", value} <- headers, do: value) do
      [] ->
        headers

      values ->
        List.keydelete(headers, "accept-encoding", 0) ++ [{"accept-encoding", readable(values)}]
    end
  end

  @doc """
  What the client accepts of the encodings MWT decodes to look through an
  answer (`AnswerBody`): gzip and deflate, in the client's own order and
  weights; `identity` when it accepts neither. A host sending another
  anyway is refused (`Response`): MWT can't look through it, and a
  client that offered `br` or `zstd` takes gzip as well.

      iex> MWTClient.Sandbox.Egress.Driver.Http1.readable(["br, gzip;q=0.9", "zstd, deflate, *"])
      "gzip;q=0.9, deflate"
      iex> MWTClient.Sandbox.Egress.Driver.Http1.readable(["br"])
      "identity"
  """
  @spec readable([String.t()]) :: String.t()
  def readable(values) do
    kept =
      for value <- values,
          token <- String.split(value, ","),
          token = String.trim(token),
          coding =
            token |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase(),
          coding in ["gzip", "x-gzip", "deflate", "identity"],
          do: token

    if kept == [], do: "identity", else: Enum.join(kept, ", ")
  end

  # The same bytes on a new link, the kept one having closed under them.
  defp again(http) do
    answer =
      case http.answer do
        %Response{} = response -> Response.restart(response)
        %Answer{} -> Answer.new(http.request.operation)
        nil -> nil
      end

    {[{:connect, %{alpn: alpn()}}, {:write, :host, http.resend}, {:read, :host, @idle}],
     %{http | reused?: false, retrying?: true, answer: answer}}
  end

  # The host closed a kept request's link before its answer ended. Before
  # any of it came, on a link kept from the request before, the host most
  # likely closed it as the request went: sent again on a new one when
  # that can't do it twice. Otherwise the VM gets MWT's 502 when nothing of
  # the answer reached it, or the answer as far as it came.
  defp ended_early(%{answer: %Response{} = response} = http) do
    cond do
      not Response.started?(response) and http.reused? and http.retry? ->
        again(%{http | retry?: false})

      not Response.started?(response) ->
        unreachable_now(http, :closed)

      # Its link is gone: the answer ends here, and so does the VM's
      # connection, as for one read only for its end.
      true ->
        response |> Response.finish() |> answered(%{http | keep?: false})
    end
  end

  defp ended_early(%{answer: answer} = http) do
    cond do
      not Answer.started?(answer) and http.reused? and http.retry? ->
        again(%{http | retry?: false})

      not Answer.started?(answer) ->
        unreachable_now(http, :closed)

      true ->
        {how, held} = Answer.finish(answer)
        {vm, http} = to_vm(http, held)

        note = if how == :cut, do: "The host closed the connection before the answer ended."
        {closing, http} = close(http, note)
        {vm ++ closing, http}
    end
  end

  # A kept request's answer went to the VM whole: its exchange goes to the
  # log, and the VM's connection waits for its next request, on the same
  # link when the host keeps it. One whose answer came before its body was
  # all sent can't tell its body from the next request: it ends.
  defp next_request(http, keep_link?) do
    done = {:done, http.request, exchange(http, Exchange.response(http.record.sent, nil))}

    if http.framing == :done do
      link = if keep_link?, do: [{:read, :host, :infinity}], else: [{:close, :host}]

      {actions, http} =
        awaiting_head(
          %{
            http
            | request: nil,
              record: nil,
              answer: nil,
              resend: nil,
              keep?: false,
              reused?: false,
              retry?: false,
              retrying?: false,
              fresh?: false,
              linked?: keep_link?,
              pending: ""
          },
          http.pending
        )

      {[done | link] ++ actions, http}
    else
      {[done, :close], http}
    end
  end

  ## Answers

  defp answered({:more, bytes, response}, http) do
    {vm, http} = to_vm(%{http | answer: response}, bytes)
    {vm ++ [{:read, :host, waiting(response)}], http}
  end

  # Whole: a kept request's connection waits for the next, on the same
  # link when the host keeps it; any other ends.
  defp answered({:done, bytes, beyond, keep?}, %{keep?: true} = http) do
    {vm, http} = to_vm(http, bytes)
    {next, http} = next_request(http, keep? and beyond == "")
    {vm ++ next, http}
  end

  defp answered({:done, bytes, _beyond, _keep?}, http) do
    {vm, http} = to_vm(http, bytes)
    {closing, http} = close(http, nil)
    {vm ++ closing, http}
  end

  # The sandbox hears of it before the VM sees the answer end.
  defp answered({:cut, reason, bytes}, http) do
    {vm, http} = to_vm(http, bytes)

    {said, note} =
      case reason do
        {:found, label} ->
          {{:found, label, :echo}, "Cut by MWT: the answer quoted the real credential."}

        :unreadable ->
          {{:log, unreadable_answer(http)},
           "Cut by MWT: it could not read the rest of the answer."}
      end

    {closing, http} = close(http, note)
    {[{:close, :host} | vm] ++ [said | closing], http}
  end

  defp answered({:refuse, message}, http) do
    {answer, http} =
      answer_self(
        http,
        502,
        Jason.encode!(%{
          code: "mwt_unreadable_response",
          error:
            "MWT could not read #{authority(name(http), http.ctx.port)}'s answer, " <>
              "so it did not pass it on: #{message}",
          by: "MWT agent sandbox"
        })
      )

    {[{:close, :host}, {:log, unreadable_answer(http)} | answer], http}
  end

  defp waiting(%Response{} = response), do: if(Response.held?(response), do: @hold, else: @idle)
  defp waiting(_answer_or_none), do: @idle

  defp idle(http), do: close(http, "Closed by MWT: nothing came for #{div(@idle, 1000)} s.")

  # Bytes for the VM: sent, and kept for the log.
  defp to_vm(http, bytes) do
    if IO.iodata_length(bytes) > 0 do
      record = %{http.record | sent: Exchange.capture(http.record.sent, bytes)}
      {[{:send, :vm, bytes}], %{http | record: record}}
    else
      {[], http}
    end
  end

  ## What MWT answers itself

  # TLS with the host failed as MWT started it again (`Driver.tls_refused/2`).
  defp host_refused(http, reason) do
    {line, json} = Driver.tls_refused(http.ctx, reason)
    {answer, http} = answer_self(http, 502, json)
    {[{:log, line} | answer], http}
  end

  defp could_not_reach(http, reason) do
    answer_self(
      http,
      502,
      Jason.encode!(%{
        error:
          "Could not reach #{authority(name(http), http.ctx.port)}: " <>
            Driver.unreachable(reason),
        by: "MWT agent sandbox"
      })
    )
  end

  defp unreachable_now(http, reason) do
    answer_self(
      http,
      502,
      Jason.encode!(%{
        error:
          "#{authority(name(http), http.ctx.port)} closed the connection without answering: " <>
            Driver.unreachable(reason),
        by: "MWT agent sandbox"
      })
    )
  end

  # MWT's answer to the request in flight, logged with it; the connection
  # ends.
  defp answer_self(http, status, json) do
    {[
       {:send, :vm, answer(status, json)},
       {:done, http.request, exchange(http, Exchange.mwt_answer(status, json))},
       :close
     ], http}
  end

  defp too_large(http) do
    refuse(
      http,
      431,
      "mwt_bad_request",
      "The request's head is over #{div(@head_limit, 1024)} KiB."
    )
  end

  defp unreadable_request(http),
    do: refuse(http, 400, "mwt_bad_request", "MWT could not read this as one HTTP/1.1 request.")

  defp refuse(http, status, code, message),
    do:
      respond(http, status, Jason.encode!(%{code: code, error: message, by: "MWT agent sandbox"}))

  # Before there is a request to log. What the VM sent of it is looked
  # through first, as it would have been going up.
  defp respond(http, status, json) do
    look = if http.read != "", do: [{:look, http.read}], else: []
    {look ++ [{:send, :vm, answer(status, json)}, :close], %{http | read: ""}}
  end

  defp answer(status, json) do
    [
      "HTTP/1.1 #{status} #{Plug.Conn.Status.reason_phrase(status)}\r\n" <>
        "content-type: application/json\r\ncontent-length: #{byte_size(json)}\r\n" <>
        "connection: close\r\n\r\n",
      json
    ]
  end

  defp unreadable_answer(http) do
    %{
      outcome: :blocked,
      summary: "An answer MWT could not read, not passed on",
      host: name(http),
      port: http.ctx.port
    }
  end

  # The host of the request in flight, as it named it; the connection's
  # name between requests.
  defp name(%{request: %Request{name: name}}), do: name
  defp name(http), do: http.ctx.name

  # The request in flight ends, logged with what came back, and so does
  # the connection.
  defp close(%{request: nil} = http, _note), do: {[:close], http}

  defp close(http, note) do
    {[{:done, http.request, exchange(http, Exchange.response(http.record.sent, note))}, :close],
     http}
  end

  ## The log

  # A WebSocket's: its handshake, and each side's messages as its body.
  defp exchange(%{ws: %{switched?: true} = ws} = http, response) do
    %{request: request, response: response} = exchange(%{http | ws: nil}, response)

    %{
      request: %{request | body: WebSocket.log(ws.vm)},
      response: response && %{response | body: WebSocket.log(ws.host)}
    }
  end

  defp exchange(http, response) do
    vm = http.record.sent_up
    request = %{vm | body: IO.iodata_to_binary([vm.body | http.record.more])}
    %{request: Exchange.request(request, http.ctx.limit), response: response}
  end

  # The body the VM sends after what MWT read before deciding, kept for the
  # log up to the limit; never what follows an Upgrade, which is another
  # protocol's.
  defp kept_more(record, :open, _data), do: record

  defp kept_more(record, _framing, data) do
    held = byte_size(record.sent_up.body) + IO.iodata_length(record.more)
    room = record.sent.limit - held

    cond do
      room <= 0 or data == "" -> record
      byte_size(data) <= room -> %{record | more: [record.more, data]}
      true -> %{record | more: [record.more, binary_part(data, 0, room)]}
    end
  end

  ## Parsing

  # What of the VM's next bytes belongs to the request's body, as framed:
  # `{:ok, bytes, framing, beyond}`, `beyond` being what came after the
  # body's end, or `:error`.
  defp body_bytes(:open, data), do: {:ok, data, :open, ""}
  defp body_bytes(:done, data), do: {:ok, "", :done, data}

  defp body_bytes(framing, data) do
    case Framing.feed(framing, data) do
      {:more, data, framing} -> {:ok, data, framing, ""}
      {:done, data, beyond} -> {:ok, data, :done, beyond}
      :error -> :error
    end
  end

  # The name a request's Host says, with the port when it isn't HTTPS's own.
  defp authority(name, port), do: Describe.authority(%{host: name, port: port})

  # MWT judges a request by what it read, and the host must act on the same
  # thing. So a request two parsers could read two ways does not go out: its
  # target is a path, it has one Host (the name it was encrypted for, or it
  # could look like GitHub to MWT while going elsewhere), and one way of
  # saying how long its body is. TRACE has the host send the request back,
  # real value included.
  defp acceptable(method, target, headers, sni, port) do
    hosts = for {"host", value} <- headers, do: String.downcase(value)
    lengths = for {"content-length", value} <- headers, do: value
    encodings = for {"transfer-encoding", value} <- headers, do: String.downcase(value)

    cond do
      refusal = RequestHead.refusal(method, target, headers) ->
        refusal

      length(hosts) != 1 ->
        {:refuse, 400, "mwt_bad_request", "A request needs exactly one Host header."}

      RequestHead.misdirected?(hd(hosts), sni, port) ->
        {:misdirected, hd(hosts)}

      lengths != [] and encodings != [] ->
        {:refuse, 400, "mwt_bad_request",
         "A request says how long its body is once: Content-Length or Transfer-Encoding."}

      encodings not in [[], ["chunked"]] ->
        {:refuse, 400, "mwt_bad_request", "The only Transfer-Encoding passed on is chunked."}

      true ->
        :ok
    end
  end

  # Answers 100 Continue itself, so the start of the body arrives before
  # the decision; the host then never sees the expectation.
  defp continue_if_expected(headers) do
    case List.keyfind(headers, "expect", 0) do
      {_, value} ->
        if String.downcase(value) == "100-continue",
          do:
            {[{:send, :vm, "HTTP/1.1 100 Continue\r\n\r\n"}],
             List.keydelete(headers, "expect", 0)},
          else: {[], headers}

      nil ->
        {[], headers}
    end
  end

  # Strict on purpose: a line that isn't `name: value`, a name with a space in
  # it, a folded header or a stray CR or LF is where two parsers disagree. A
  # value is what HTTP says one is: visible bytes, spaces and tabs, with the
  # spaces and tabs around it dropped and nothing else.
  defp parse_request(head) do
    [line | lines] = String.split(head, "\r\n")

    with [method, target, version] when version in ["HTTP/1.1", "HTTP/1.0"] <-
           String.split(line, " "),
         true <- RequestHead.token?(method),
         {:ok, headers} <- parse_headers(lines, []) do
      {:ok, method, target, version, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp parse_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_headers([line | rest], acc) do
    with [name, value] <- String.split(line, ":", parts: 2),
         true <- RequestHead.token?(name),
         true <- RequestHead.field_value?(value) do
      parse_headers(rest, [{String.downcase(name), RequestHead.trimmed(value)} | acc])
    else
      _ -> :error
    end
  end

  # The time by which something must have arrived, and how long is left
  # of it.
  defp within(ms), do: System.monotonic_time(:millisecond) + ms
  defp left(by), do: max(by - System.monotonic_time(:millisecond), 0)
end
