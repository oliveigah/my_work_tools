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
    5. **The answer**, read back: for a request with a value in it,
       `Response` puts the placeholder back in every head and cuts the
       answer before a value in its body goes; for a kept one, `Answer`
       reads only where it ends.

  A kept link the host closed just as a request went on it took none of
  it, or did nothing it can't do twice: the request goes again on a new
  one, once, as any HTTP client does (`retryable?/2`).

  What MWT answers itself (a refusal, a request it can't read) is HTTP,
  with MWT's JSON (`code`, `error`, `by`), and closes the connection.
  """

  @behaviour MWTClient.Sandbox.Egress.Driver

  alias MWTClient.Sandbox.{Describe, Exchange, Placeholder, Secrets}
  alias MWTClient.Sandbox.Egress.{Driver, Request}
  alias MWTClient.Sandbox.Egress.Driver.Http1.{Answer, Framing, Response}

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
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @overrides ~w(x-http-method-override x-http-method x-method-override)
  @field_value ~r/\A[\t\x20-\x7e\x80-\xff]*\z/

  # `phase`: reading a `:head`, the start of its `:body`, `:judging` it, or
  # its `:answer`. `linked?` while a link to the host is open, kept from
  # the request before or this one's; `pending`, what the VM sent past the
  # body's end. For the request in flight: what the log keeps (`record`),
  # how its `answer` is read, whether its link is kept (`keep?`), went on
  # the kept one (`reused?`), and its bytes, to send again (`resend`) when
  # the host turns out to have closed that one (`retry?` when that's safe
  # after it took them); `fresh?` until anything moved since it went.
  defstruct [
    :ctx,
    :by,
    :head,
    :framing,
    :request,
    :record,
    :answer,
    :resend,
    phase: :head,
    buffer: "",
    body: "",
    pending: "",
    linked?: false,
    keep?: false,
    reused?: false,
    retry?: false,
    retrying?: false,
    fresh?: false
  ]

  @impl true
  def alpn, do: ["http/1.1"]

  @doc """
  A request's first bytes: a method's name and a space, or bytes too few to
  tell yet. On TCP, inside TLS MWT ended only: plain HTTP isn't read yet,
  since nothing proves which host is there.
  """
  @impl true
  def detect(data, %{transport: :tcp, tls?: true}),
    do: if(data =~ ~r/\A[A-Z]{1,20}( |\z)/, do: :yes, else: :no)

  def detect(_data, _ctx), do: :no

  @impl true
  def init(ctx), do: awaiting_head(%__MODULE__{ctx: ctx, linked?: ctx.linked?}, "")

  @doc """
  The request as the sandbox's server reads it: `host`, `port`, `method`,
  `path`, `headers`, the start of its `body`, the grant it went `under`,
  and its `exchange`.
  """
  @spec message(Request.t()) :: map()
  def message(%Request{data: data} = request) do
    %{
      host: request.name,
      port: request.port,
      method: request.operation,
      path: request.resource,
      headers: data.headers,
      body: data.body,
      under: request.under,
      exchange: request.id
    }
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
  def handle_data(:vm, data, %{phase: :body} = http), do: body(http, data)

  # Asked for before the request was whole: the next one's start, kept.
  def handle_data(:vm, data, %{phase: :judging} = http),
    do: {[], %{http | pending: http.pending <> data}}

  # Past the body's end, a kept request's bytes are the next request's,
  # kept for it; anyone else's go nowhere. A VM sending more than a head's
  # worth ahead waits for the answer to end.
  def handle_data(:vm, data, %{phase: :answer} = http) do
    case body_bytes(http.framing, data) do
      {:ok, data, framing, beyond} ->
        pending = if http.keep?, do: http.pending <> beyond, else: ""
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

  def handle_data(:host, data, %{phase: :answer, answer: nil} = http) do
    {vm, http} = to_vm(%{http | fresh?: false}, data)
    {vm ++ [{:read, :host, @idle}], http}
  end

  def handle_data(:host, data, %{phase: :answer, answer: %Answer{} = answer} = http) do
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

  def handle_data(:host, data, %{phase: :answer} = http),
    do: http.answer |> Response.feed(data) |> answered(%{http | fresh?: false})

  # On a kept link between requests, bytes nothing asked for end it.
  def handle_data(:host, _data, http), do: {[{:close, :host}], %{http | linked?: false}}

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
    %{name: name, port: port} = http.ctx

    with {:ok, method, target, version, headers} <- parse_request(head),
         :ok <- acceptable(method, target, headers, name, port) do
      # One Host, and it is the name the connection was encrypted for.
      headers = List.keyreplace(headers, "host", 0, {"host", authority(name, port)})
      {continue, headers} = continue_if_expected(headers)
      by = within(Keyword.get(http.ctx.options, :body_within, @body_within))

      head = %{
        method: method,
        target: target,
        version: version,
        headers: headers,
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
            error: "Host #{host} does not match #{authority(name, port)}.",
            by: "MWT agent sandbox"
          })
        )

      {:refuse, status, code, message} ->
        refuse(http, status, code, message)

      {:error, :bad_request} ->
        unreadable_request(http)
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

  defp judge(%{head: %{upgrade?: true}} = http, body, _framing, beyond),
    do: judging(http, body <> beyond, :open, "")

  defp judge(http, body, framing, beyond), do: judging(http, body, framing, beyond)

  defp judging(http, body, framing, beyond) do
    %{method: method, target: target, version: version, headers: headers} = http.head

    request = %Request{
      id: Exchange.new_id(),
      driver: __MODULE__,
      name: http.ctx.name,
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

    {[{:judge, request}],
     %{
       http
       | phase: :judging,
         request: request,
         record: record,
         framing: framing,
         pending: beyond,
         body: ""
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
    keep? = replace.request == [] and keeps?(data.version, headers)
    head = head(method, path, data.version, headers, echo != nil, keep?)
    reuse? = keep? and http.linked?

    answer =
      case echo do
        {secrets, placeholders} -> Response.new(method, secrets, placeholders)
        nil -> if keep?, do: Answer.new(method)
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
        fresh?: true
    }

    {connect ++
       [{:write, :host, head}] ++
       body ++ [{:read, :host, waiting(answer)}, {:read, :vm, :infinity}], http}
  end

  # The forms the values put in go by, each to come back as its
  # placeholder: those the core named, and the one MWT wrote into a
  # carrier when that isn't the value as it is (a Basic credential's
  # base64). Nil with nothing put in.
  defp echo(%{answer: []}, _headers), do: nil

  defp echo(replace, headers) do
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
  # `Connection` header, HTTP/1.1's own keep-alive.
  defp head(method, path, version, headers, echo?, keep?) do
    upgrade? = Enum.any?(headers, fn {name, _} -> name == "upgrade" end)

    headers =
      headers
      |> Enum.reject(fn {name, _} ->
        name in ["proxy-connection", "keep-alive"] or (name == "connection" and not upgrade?) or
          (name == "accept-encoding" and echo?)
      end)
      |> then(&if(echo?, do: &1 ++ [{"accept-encoding", "identity"}], else: &1))
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

  # The same bytes on a new link, the kept one having closed under them.
  defp again(http) do
    answer = if http.answer, do: Answer.new(http.request.operation)

    {[{:connect, %{alpn: alpn()}}, {:write, :host, http.resend}, {:read, :host, @idle}],
     %{http | reused?: false, retrying?: true, answer: answer}}
  end

  # The host closed a kept request's link before its answer ended. Before
  # any of it came, on a link kept from the request before, the host most
  # likely closed it as the request went: sent again on a new one when
  # that can't do it twice. Otherwise the VM gets MWT's 502 when nothing of
  # the answer reached it, or the answer as far as it came.
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

  defp answered({:done, bytes}, http) do
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
            "MWT could not read #{authority(http.ctx.name, http.ctx.port)}'s answer, " <>
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

  # TLS with the host failed as MWT started it again: a certificate this
  # machine's roots don't vouch for (an internal CA, one expired), or a host
  # that wants a client certificate. It fails for being read, as a client
  # refusing MWT's does, so its line is `read_failed`: the host can be set
  # as Not read, and then the VM's client judges it.
  defp host_refused(http, reason) do
    %{name: name, port: port} = http.ctx
    words = Driver.unreachable(reason)

    failed =
      {:log,
       %{
         outcome: :read_failed,
         summary:
           "#{name}: MWT's TLS with the host failed (#{words}), checking it against " <>
             "this machine's roots · nothing went out",
         host: name,
         port: port
       }}

    {answer, http} =
      answer_self(
        http,
        502,
        Jason.encode!(%{
          code: "mwt_upstream_tls",
          error:
            "MWT could not make TLS with #{authority(name, port)}: #{words}. " <>
              "Tell the user: if this host's certificate is one they trust, they can have MWT pass " <>
              "it through unread (Don't read, on its line in MWT's activity log).",
          by: "MWT agent sandbox"
        })
      )

    {[failed | answer], http}
  end

  defp could_not_reach(http, reason) do
    answer_self(
      http,
      502,
      Jason.encode!(%{
        error:
          "Could not reach #{authority(http.ctx.name, http.ctx.port)}: " <>
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
          "#{authority(http.ctx.name, http.ctx.port)} closed the connection without answering: " <>
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

  # Before there is a request to log.
  defp respond(http, status, json), do: {[{:send, :vm, answer(status, json)}, :close], http}

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
      host: http.ctx.name,
      port: http.ctx.port
    }
  end

  # The request in flight ends, logged with what came back, and so does
  # the connection.
  defp close(%{request: nil} = http, _note), do: {[:close], http}

  defp close(http, note) do
    {[{:done, http.request, exchange(http, Exchange.response(http.record.sent, note))}, :close],
     http}
  end

  ## The log

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
      method in ["TRACE", "CONNECT"] ->
        {:refuse, 405, "mwt_method_refused", "MWT does not pass on #{method} requests."}

      # MWT would judge, and an allowance match, the method it reads while
      # the host carries out another.
      Enum.any?(headers, fn {name, _} -> name in @overrides end) ->
        {:refuse, 400, "mwt_bad_request",
         "A request says its method once: MWT doesn't pass on a method override."}

      not (String.starts_with?(target, "/") or (method == "OPTIONS" and target == "*")) ->
        {:refuse, 400, "mwt_bad_request", "The request target must be a path."}

      # What HTTP allows in a target, and what an approval can show as it is.
      not (target =~ ~r/\A[\x21-\x7e]+\z/) ->
        {:refuse, 400, "mwt_bad_request",
         "The request target must be visible ASCII: percent-encode anything else."}

      length(hosts) != 1 ->
        {:refuse, 400, "mwt_bad_request", "A request needs exactly one Host header."}

      hd(hosts) not in [sni, "#{sni}:#{port}"] ->
        {:misdirected, hd(hosts)}

      length(lengths) > 1 or (lengths != [] and encodings != []) ->
        {:refuse, 400, "mwt_bad_request",
         "A request says how long its body is once: Content-Length or Transfer-Encoding."}

      lengths != [] and not (hd(lengths) =~ ~r/\A[0-9]+\z/) ->
        {:refuse, 400, "mwt_bad_request", "Content-Length must be a number."}

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
         true <- method =~ @token,
         {:ok, headers} <- parse_headers(lines, []) do
      {:ok, method, target, version, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp parse_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_headers([line | rest], acc) do
    with [name, value] <- String.split(line, ":", parts: 2),
         true <- name =~ @token,
         true <- value =~ @field_value do
      value = String.replace(value, ~r/\A[ \t]+|[ \t]+\z/, "")
      parse_headers(rest, [{String.downcase(name), value} | acc])
    else
      _ -> :error
    end
  end

  # The time by which something must have arrived, and how long is left
  # of it.
  defp within(ms), do: System.monotonic_time(:millisecond) + ms
  defp left(by), do: max(by - System.monotonic_time(:millisecond), 0)
end
