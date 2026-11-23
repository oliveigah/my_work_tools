defmodule MWTClient.Sandbox.Egress.Driver.Http2 do
  @moduledoc """
  The driver for HTTP/2 (RFC 9113) inside TLS MWT ended, offered only to a
  client that offers no HTTP/1.1 (gRPC's, mostly; `Driver.alpn/1` lists
  HTTP/1.1 first, and MWT picks by its own order). A client that speaks
  either is read over HTTP/1.1 (`Driver.Http1`), request by request all
  the same: offering it HTTP/2 would add nothing seen or decided, only this
  driver's risk.

  MWT is the server of the VM's connection and the client of its own to the
  host: two HTTP/2 connections, each with its own settings, header
  compression and flow control. Each of the VM's streams is a request of its
  own:

    1. **Its head**: a header block (`HEADERS` and any `CONTINUATION`, at
       most 64 KiB, and at most 64 KiB decoded, as MWT announces in
       `SETTINGS_MAX_HEADER_LIST_SIZE`), read as strictly as an HTTP/1.1
       head (`acceptable/2`, `MWTClient.Sandbox.Egress.RequestHead`):
       `:method`, `:scheme` `https`, a `:path` that is a path, its
       `:authority` (or one `host`, never both saying different things) the
       name the connection was encrypted for, fields HTTP allows (no CR, LF
       or NUL), no header HTTP/2 forbids, and a `content-length` its DATA
       then matches.
    2. **The start of its body**, until its stream ends, 64 KiB came, or half
       a second passed, so a streaming request (gRPC's) is judged on what
       came. What follows is held, within the window MWT gave the stream,
       until the verdict. A peer that sends past the windows MWT gave it
       ends the connection (`FLOW_CONTROL_ERROR`), so what MWT holds for a
       connection is bounded by them, both ways.
    3. **Judged** (`{:judge, request}`) as an HTTP request is
       (`Driver.Http1.message/1`): the same card, *Allow similar*, a token
       grant's value in its carriers. A stream waiting for you holds up only
       itself.
    4. **Sent** on MWT's own connection, on a stream id of MWT's, its headers
       written again without Huffman coding and with nothing indexed, so what
       MWT looks through is their text: header block and body as the
       request's own stream (`{:send, :host, _, id}`), each frame's header as
       MWT's framing (`{:frame, :host, _}`). A header block with a value MWT
       put in goes as `{:write, :host, _}`.
    5. **Its answer** goes to the VM decoded and written again, trailers
       (gRPC's `grpc-status`) too. For a stream with a value in it, each form
       of the value becomes its placeholder in the answer's headers, and its
       body is looked through for them (`MWTClient.Sandbox.Egress.AnswerBody`,
       gzip and deflate decoded for the look, any other encoding refused):
       one found cuts the connection before it goes. Bytes that could start
       one wait 50 ms at most for what follows.

  What MWT answers itself (a refusal) is an answer on the stream: MWT's
  JSON, or for gRPC an answer of trailers only, `grpc-status` 7
  (`PERMISSION_DENIED`), MWT's error as `grpc-message`.

  Not done: server push (MWT asks the host for none), a host that answers
  MWT's `h2` with HTTP/1.1 only (its streams fail), priorities (dropped), and
  extended CONNECT (WebSockets over HTTP/2, refused).
  """

  @behaviour MWTClient.Sandbox.Egress.Driver

  alias MWTClient.Sandbox.{Describe, Exchange, Secrets}
  alias MWTClient.Sandbox.Egress.{AnswerBody, Driver, Request, RequestHead}
  alias MWTClient.Sandbox.Egress.Driver.Http1
  alias MWTClient.Sandbox.Egress.Driver.Http1.Response
  alias MWTClient.Sandbox.Egress.Driver.Http2.Frame

  @block_limit 64 * 1024
  @body_peek 64 * 1024
  @judge_within 500
  @idle 300_000
  @preface_within 10_000
  # What MWT lets each peer send it before it takes some in: a stream's
  # window, and the connection's. MWT gives window back only for what went
  # on, so the connection's is the most it holds of one peer's bytes for
  # the other: a VM that stops reading, or a stream held for you. The VM
  # opens up to 512 connections, so that is up to 1 GiB each way at most;
  # a larger window would let one connection go faster on a far host, and
  # let a VM make MWT hold more.
  @stream_window 1024 * 1024
  @connection_window 2 * 1024 * 1024
  # The most a header block may hold decoded (RFC 9113's field section
  # size, each field's name and value and 32), announced to both peers: as
  # an HTTP/1.1 head's 64 KiB, since HPACK lets a few bytes on the wire
  # stand for a field sent before, many times over.
  @header_list 64 * 1024
  # How long bytes that could start a real value wait for what follows
  # before they go anyway (`Response`'s, the same).
  @hold 50
  @max_streams 100
  @frame_size 16_384
  @default_window 65_535
  @forbidden ~w(connection keep-alive proxy-connection transfer-encoding upgrade)

  # Errors RFC 9113 §7 names.
  @no_error 0
  @protocol_error 1
  @internal_error 2
  @flow_control_error 3
  @refused_stream 7
  @cancel 8
  @compression_error 9

  defstruct [
    :ctx,
    :by,
    phase: :preface,
    vm: "",
    host: "",
    block: nil,
    streams: %{},
    by_up: %{},
    by_request: %{},
    last_vm: 0,
    next_up: 1,
    linked?: false,
    leaving?: false,
    vm_hpack: nil,
    to_vm_hpack: nil,
    host_hpack: nil,
    to_host_hpack: nil,
    vm_window: @default_window,
    vm_initial: @default_window,
    vm_frame: @frame_size,
    host_window: @default_window,
    host_initial: @default_window,
    host_frame: @frame_size,
    # What each peer may still send MWT on the connection, by the windows
    # MWT gave it (`vm_window` and `host_window` are MWT's own to send).
    vm_may_send: @connection_window,
    host_may_send: @connection_window
  ]

  @impl true
  def alpn, do: ["h2"]

  @doc """
  Inside TLS MWT ended, a client speaking HTTP/2 without naming it: its
  preface, or the start of it. Never plain bytes: HTTP/2 without TLS (h2c)
  isn't read.
  """
  @impl true
  def detect(data, %{transport: :tcp, tls?: true}) do
    preface = Frame.preface()

    cond do
      String.starts_with?(data, preface) -> :yes
      data != "" and String.starts_with?(preface, data) -> :more
      true -> :no
    end
  end

  def detect(_data, _ctx), do: :no

  @impl true
  def init(ctx) do
    h2 = %__MODULE__{
      ctx: ctx,
      by: within(@preface_within),
      vm_hpack: HPAX.new(4096),
      to_vm_hpack: HPAX.new(4096),
      host_hpack: HPAX.new(4096),
      to_host_hpack: HPAX.new(4096)
    }

    # MWT's settings as the VM's server, and a connection window as large
    # as its streams'.
    settings =
      Frame.settings_payload([{3, @max_streams}, {4, @stream_window}, {6, @header_list}])

    {[
       {:send, :vm, Frame.encode(:settings, 0, 0, settings)},
       {:send, :vm, window_update(0, @connection_window - @default_window)},
       {:read, :vm, @preface_within}
     ], h2}
  end

  @doc "The request as the sandbox's server reads it: as an HTTP/1.1 one, saying whether MWT holds its whole body."
  @spec message(Request.t()) :: map()
  def message(%Request{data: data} = request),
    do: request |> Http1.message() |> Map.put(:body_whole?, data.whole?)

  @impl true
  def describe(request), do: Describe.request(message(request))

  ## The VM's bytes

  @impl true
  def handle_data(:vm, data, %{phase: :preface} = h2) do
    buffer = h2.vm <> data
    preface = Frame.preface()

    cond do
      String.starts_with?(buffer, preface) ->
        rest = binary_part(buffer, 24, byte_size(buffer) - 24)
        handle_data(:vm, rest, %{h2 | phase: :open, vm: "", by: nil})

      String.starts_with?(preface, buffer) ->
        {[{:read, :vm, left(h2.by)}], %{h2 | vm: buffer}}

      true ->
        {[:close], h2}
    end
  end

  def handle_data(:vm, data, h2) do
    case Frame.split(h2.vm <> data, @frame_size) do
      {:ok, frames, rest} ->
        {actions, h2} = each(frames, %{h2 | vm: rest}, &vm_frame/2)
        settle(actions, h2)

      {:error, _reason} ->
        leave(h2, @protocol_error)
    end
  end

  ## The host's bytes

  def handle_data(:host, data, h2) do
    case Frame.split(h2.host <> data, @frame_size) do
      {:ok, frames, rest} ->
        {actions, h2} = each(frames, %{h2 | host: rest}, &host_frame/2)
        settle(actions ++ [{:read, :host, host_wait(h2)}], h2)

      {:error, _reason} ->
        host_broke(h2, "The host's HTTP/2 framing broke.")
    end
  end

  ## Verdicts

  @impl true
  def handle_verdict(request_id, verdict, h2) do
    with id when is_integer(id) <- Map.get(h2.by_request, request_id),
         %{phase: :judging} = stream <- Map.get(h2.streams, id) do
      {actions, h2} =
        case verdict do
          {:allow, replace} -> send_upstream(h2, stream, replace)
          {:deny, status, json} -> answer_self(h2, stream, status, json)
          {:reply, status, json} -> answer_self(h2, stream, status, json)
        end

      settle(actions, h2)
    else
      _gone -> {[], h2}
    end
  end

  ## Ends

  @impl true
  def handle_closed(:vm, _ended, h2), do: close_all(h2, nil)

  # TLS with the host failed as MWT started it again (`Driver.tls_refused/2`).
  def handle_closed(:host, {:unreachable, {:tls_alert, _} = reason}, h2) do
    {line, json} = Driver.tls_refused(h2.ctx, reason)
    {actions, h2} = lost(%{h2 | linked?: false}, line.summary, json)
    {[{:log, line} | actions], h2}
  end

  def handle_closed(:host, {:unreachable, reason}, h2) do
    words = Driver.unreachable(reason)
    host_lost(%{h2 | linked?: false}, "Could not reach #{authority(h2)}: #{words}")
  end

  def handle_closed(:host, _ended, h2),
    do: host_lost(%{h2 | linked?: false}, "#{authority(h2)} closed the connection.")

  @impl true
  def handle_timeout(:vm, %{phase: :preface} = h2), do: {[:close], h2}

  def handle_timeout(:vm, h2) do
    now = now()
    due = for {_id, %{phase: :body, by: by} = stream} <- h2.streams, by <= now, do: stream

    if due == [] do
      if busy?(h2), do: settle([], h2), else: leave(h2, @no_error)
    else
      {actions, h2} = each(due, h2, fn stream, h2 -> judge(h2, stream) end)
      settle(actions, h2)
    end
  end

  # The host paused: what a stream holds back as the possible start of a
  # value goes, since what would complete it hasn't come.
  def handle_timeout(:host, h2) do
    case holding(h2) do
      [] ->
        if busy?(h2), do: settle([], h2), else: {[], h2}

      held ->
        {actions, h2} = each(held, h2, fn stream, h2 -> released(h2, stream) end)
        settle(actions ++ [{:read, :host, @idle}], h2)
    end
  end

  @impl true
  def handle_cut({:found, _label}, h2) do
    json =
      Jason.encode!(%{
        code: "mwt_value_blocked",
        error:
          "This request holds a real credential, which nothing in the VM should have. " <>
            "It did not go out. The user has been told.",
        by: "MWT agent sandbox"
      })

    refuse_all(h2, 403, json)
  end

  def handle_cut(:isolated, h2) do
    {:deny, status, json} = MWTClient.Sandbox.Server.Values.isolated()
    refuse_all(h2, status, json)
  end

  def handle_cut(:grant_ended, h2),
    do: close_all(h2, "Closed by MWT: the grant that let it through ended.")

  def handle_cut(_firewall, h2), do: close_all(h2, "Cut by MWT's firewall.")

  ## Frames from the VM

  # A header block goes on until it ends, and nothing comes between.
  defp vm_frame({:continuation, flags, id, part, _size}, %{block: {:vm, id, first, acc}} = h2) do
    block = [acc, part]

    cond do
      IO.iodata_length(block) > @block_limit ->
        leave(h2, @protocol_error)

      Frame.end_headers?(flags) ->
        vm_block(%{h2 | block: nil}, id, first, IO.iodata_to_binary(block))

      true ->
        {[], %{h2 | block: {:vm, id, first, block}}}
    end
  end

  defp vm_frame(_frame, %{block: {:vm, _, _, _}} = h2), do: leave(h2, @protocol_error)

  defp vm_frame({:settings, flags, 0, payload, _size}, h2) do
    cond do
      Frame.ack?(flags) ->
        {[], h2}

      true ->
        case Frame.settings(payload) do
          {:ok, pairs} ->
            h2 = Enum.reduce(pairs, h2, &vm_setting/2)
            {flushed, h2} = flush_all_vm(h2)
            {[{:send, :vm, Frame.encode(:settings, 1, 0, "")} | flushed], h2}

          :error ->
            leave(h2, @protocol_error)
        end
    end
  end

  defp vm_frame({:ping, flags, 0, payload, _size}, h2) do
    if Frame.ack?(flags),
      do: {[], h2},
      else: {[{:send, :vm, Frame.encode(:ping, 1, 0, payload)}], h2}
  end

  defp vm_frame({:window_update, _flags, 0, <<_::1, increment::31>>, _size}, h2) do
    h2 = %{h2 | vm_window: h2.vm_window + increment}
    if h2.vm_window > 2_147_483_647, do: leave(h2, @flow_control_error), else: flush_all_vm(h2)
  end

  defp vm_frame({:window_update, _flags, id, <<_::1, increment::31>>, _size}, h2) do
    case Map.get(h2.streams, id) do
      nil -> {[], h2}
      stream -> flush_vm(h2, %{stream | vm_window: stream.vm_window + increment})
    end
  end

  defp vm_frame({:headers, flags, id, block, _size}, h2) do
    cond do
      byte_size(block) > @block_limit -> leave(h2, @protocol_error)
      Frame.end_headers?(flags) -> vm_block(h2, id, flags, block)
      true -> {[], %{h2 | block: {:vm, id, flags, block}}}
    end
  end

  # The VM sends no more than the windows MWT gave it: one that does would
  # have MWT hold whatever it sends while a stream waits for you or for
  # the host.
  defp vm_frame({:data, _flags, _id, _payload, size}, h2) when size > h2.vm_may_send,
    do: leave(h2, @flow_control_error)

  defp vm_frame({:data, flags, id, payload, size}, h2) do
    h2 = %{h2 | vm_may_send: h2.vm_may_send - size}

    case Map.get(h2.streams, id) do
      %{vm_ended?: false, vm_may_send: room} when size > room ->
        leave(h2, @flow_control_error)

      %{vm_ended?: false} = stream ->
        stream = %{stream | vm_may_send: stream.vm_may_send - size}
        vm_data(h2, stream, payload, size, Frame.end_stream?(flags))

      _gone_or_ended ->
        # Data for a stream that is gone still took from the connection's
        # window: given back.
        {credit, h2} = give_vm(h2, size)
        {credit ++ rst_unless_known(h2, id), h2}
    end
  end

  defp vm_frame({:rst_stream, _flags, id, <<code::32>>, _size}, h2) do
    case Map.get(h2.streams, id) do
      nil ->
        {[], h2}

      stream ->
        reset = if stream.up, do: [{:frame, :host, rst(stream.up, code)}], else: []
        {done, h2} = finish(h2, stream, "The client reset the stream.")
        {reset ++ done, h2}
    end
  end

  defp vm_frame({:goaway, _flags, 0, _payload, _size}, h2), do: {[], %{h2 | leaving?: true}}
  defp vm_frame({:push_promise, _flags, _id, _payload, _size}, h2), do: leave(h2, @protocol_error)
  defp vm_frame(_priority_or_unknown, h2), do: {[], h2}

  defp vm_setting({1, size}, h2), do: %{h2 | to_vm_hpack: HPAX.resize(h2.to_vm_hpack, size)}

  defp vm_setting({4, initial}, h2) do
    delta = initial - h2.vm_initial
    streams = Map.new(h2.streams, fn {id, s} -> {id, %{s | vm_window: s.vm_window + delta}} end)
    %{h2 | vm_initial: initial, streams: streams}
  end

  defp vm_setting({5, size}, h2) when size in 16_384..16_777_215, do: %{h2 | vm_frame: size}
  defp vm_setting(_other, h2), do: h2

  # A header block: a new stream's head, or its trailers.
  defp vm_block(h2, id, flags, block) do
    case HPAX.decode(block, h2.vm_hpack) do
      {:ok, headers, table} ->
        h2 = %{h2 | vm_hpack: table}
        ended? = Frame.end_stream?(flags)

        case Map.get(h2.streams, id) do
          nil -> opened(h2, id, headers, ended?)
          stream -> vm_trailers(h2, stream, headers, ended?)
        end

      {:error, _reason} ->
        leave(h2, @compression_error)
    end
  end

  defp opened(h2, id, headers, ended?) do
    cond do
      rem(id, 2) == 0 or id <= h2.last_vm ->
        leave(h2, @protocol_error)

      map_size(h2.streams) >= @max_streams or h2.leaving? ->
        {[{:send, :vm, rst(id, @refused_stream)}], %{h2 | last_vm: id}}

      true ->
        h2 = %{h2 | last_vm: id}

        case acceptable(headers, h2.ctx) do
          {:ok, head} ->
            stream = %{
              id: id,
              up: nil,
              phase: :body,
              head: head,
              request: nil,
              record: nil,
              held: [],
              held_size: 0,
              more: [],
              vm_ended?: ended?,
              trailers: nil,
              out: [],
              up_window: h2.host_initial,
              to_vm: [],
              vm_window: h2.vm_initial,
              vm_may_send: @stream_window,
              host_may_send: @stream_window,
              declared: head.declared,
              body_size: 0,
              answer: nil,
              host_ended?: false,
              echo: nil,
              skip: 0,
              ended_up?: false,
              by: within(@judge_within)
            }

            h2 = put(h2, stream)

            cond do
              not ended? -> {[], h2}
              mismatched?(stream) -> mismatched(h2, stream)
              true -> judge(h2, stream)
            end

          {:refuse, status, code, message} ->
            json = Jason.encode!(%{code: code, error: message, by: "MWT agent sandbox"})
            {answer, h2} = respond(h2, id, status, json, grpc?(headers))
            reset = if ended?, do: [], else: [{:send, :vm, rst(id, @no_error)}]
            {answer ++ reset, h2}
        end
    end
  end

  # Trailers end the stream: held with its body until the verdict, sent
  # after it once it went.
  defp vm_trailers(h2, stream, headers, true) do
    stream = %{stream | trailers: regular(headers), vm_ended?: true}

    cond do
      section_size(headers) > @header_list ->
        refuse_stream(h2, stream, 431, "The request's trailers are over 64 KiB.")

      not Enum.all?(stream.trailers, fn {name, value} -> field?(name, value) end) ->
        refuse_stream(h2, stream, 400, fields_refused())

      mismatched?(stream) ->
        mismatched(h2, stream)

      stream.phase == :body ->
        judge(h2, stream)

      stream.phase == :sent ->
        flush_up(h2, stream)

      true ->
        {[], put(h2, stream)}
    end
  end

  defp vm_trailers(h2, _stream, _headers, false), do: leave(h2, @protocol_error)

  defp vm_data(h2, stream, payload, size, ended?) do
    stream = %{stream | vm_ended?: ended?, body_size: stream.body_size + byte_size(payload)}
    padding = size - byte_size(payload)

    cond do
      # A body longer or shorter than its content-length is one two
      # parsers could read two ways (a host turning it into HTTP/1.1 would
      # read its end as another request): refused, with what came of it
      # given back to the windows.
      mismatched?(stream) ->
        stream =
          if stream.phase == :sent,
            do: %{stream | out: stream.out ++ [payload]},
            else: %{
              stream
              | held: [stream.held, payload],
                held_size: stream.held_size + byte_size(payload)
            }

        {credit, h2} = give_vm(h2, padding)
        {own, stream} = give_vm_stream(stream, padding)
        {actions, h2} = mismatched(h2, stream)
        {credit ++ own ++ actions, h2}

      stream.phase == :sent ->
        stream = %{stream | out: stream.out ++ [payload]}
        flush_up(h2, stream, padding)

      true ->
        stream = %{
          stream
          | held: [stream.held, payload],
            held_size: stream.held_size + byte_size(payload)
        }

        # Padding is given back at once; the rest once it goes up.
        {credit, h2} = give_vm(h2, padding)
        {own, stream} = give_vm_stream(stream, padding)

        if stream.phase == :body and (ended? or stream.held_size >= @body_peek) do
          {actions, h2} = judge(h2, stream)
          {credit ++ own ++ actions, h2}
        else
          {credit ++ own, put(h2, stream)}
        end
    end
  end

  # A body that went past its content-length, or ended short of it.
  defp mismatched?(%{declared: nil}), do: false

  defp mismatched?(%{declared: declared, body_size: size, vm_ended?: ended?}),
    do: size > declared or (ended? and size != declared)

  defp mismatched(h2, stream) do
    refuse_stream(
      h2,
      stream,
      400,
      "The request's content-length says #{stream.declared} bytes, and its DATA carried " <>
        "#{if stream.body_size > stream.declared, do: "more", else: stream.body_size}."
    )
  end

  # A stream MWT refuses once it began, with why: MWT's answer on it while
  # nothing of it went up; reset both ways after, since the host has its
  # start. What it held is given back to the VM's window.
  defp refuse_stream(h2, stream, status, message) do
    json = Jason.encode!(%{code: "mwt_bad_request", error: message, by: "MWT agent sandbox"})

    cond do
      stream.phase == :sent ->
        {done, h2} = finish(h2, stream, "Refused by MWT: " <> message)

        {[
           {:frame, :host, rst(stream.up, @cancel)},
           {:send, :vm, rst(stream.id, @protocol_error)} | done
         ], h2}

      stream.request ->
        answer_self(h2, stream, status, json)

      true ->
        {credit, h2} = give_vm(h2, unsent(stream))
        {answer, h2} = respond(h2, stream.id, status, json, grpc?(stream.head.headers))
        reset = if stream.vm_ended?, do: [], else: [{:send, :vm, rst(stream.id, @no_error)}]
        {answer ++ reset ++ credit, drop(h2, stream)}
    end
  end

  ## Judging

  defp judge(h2, stream) do
    held = IO.iodata_to_binary(stream.held)
    peek = binary_part(held, 0, min(byte_size(held), @body_peek))
    %{method: method, path: path, headers: headers} = stream.head

    request = %Request{
      id: Exchange.new_id(),
      driver: __MODULE__,
      name: h2.ctx.name,
      ip: h2.ctx.ip,
      port: h2.ctx.port,
      under: h2.ctx.under,
      operation: method,
      resource: path,
      data: %{
        version: "HTTP/2",
        headers: headers,
        body: peek,
        whole?: stream.vm_ended? and byte_size(held) <= @body_peek
      }
    }

    record = %{sent_up: message(request), more: []}
    stream = %{stream | phase: :judging, request: request, record: record, held: [held], by: nil}

    {[{:judge, request}],
     put(%{h2 | by_request: Map.put(h2.by_request, request.id, stream.id)}, stream)}
  end

  ## Sending it

  # On MWT's connection, opened first if none is: the head written again,
  # with the values the verdict says put in, then what was held.
  defp send_upstream(h2, stream, replace) do
    {link, h2} = link(h2)
    %{method: method, path: path, headers: headers} = stream.head
    headers = Http1.replace(headers, replace.request)
    echo = echo(Http1.echo(replace, headers))

    # With a value in it, its answer is asked for unencoded, so a value it
    # quotes can be read; gRPC's own compression of each message too.
    headers =
      if echo,
        do:
          headers
          |> Enum.reject(fn {name, _} -> name == "grpc-accept-encoding" end)
          |> List.keystore("accept-encoding", 0, {"accept-encoding", "identity"}),
        else: headers

    pseudo = [
      {":method", method},
      {":scheme", "https"},
      {":authority", authority(h2)},
      {":path", path}
    ]

    {block, table} = HPAX.encode(:no_store, pseudo ++ headers, h2.to_host_hpack)
    block = IO.iodata_to_binary(block)
    up = h2.next_up
    held = IO.iodata_to_binary(stream.held)
    alone? = held == "" and is_nil(stream.trailers) and stream.vm_ended?

    head =
      for {header, part} <- Frame.header_frames(up, block, alone?, h2.host_frame) do
        if replace.request != [],
          do: [{:write, :host, [header, part]}],
          else: [{:frame, :host, header}, {:send, :host, part, stream.request.id}]
      end

    stream = %{
      stream
      | phase: :sent,
        up: up,
        held: [],
        held_size: 0,
        out: if(held == "", do: [], else: [held]),
        echo: echo,
        skip: byte_size(stream.record.sent_up.body),
        ended_up?: alone?,
        up_window: h2.host_initial,
        host_may_send: @stream_window
    }

    h2 = %{
      h2
      | to_host_hpack: table,
        next_up: up + 2,
        by_up: Map.put(h2.by_up, up, stream.id)
    }

    {more, h2} = flush_up(put(h2, stream), stream, 0)
    {link ++ List.flatten(head) ++ more, h2}
  end

  defp link(%{linked?: true} = h2), do: {[], h2}

  defp link(h2) do
    settings =
      Frame.settings_payload([
        {2, 0},
        {3, @max_streams},
        {4, @stream_window},
        {6, @header_list}
      ])

    {[
       {:connect, %{alpn: ["h2"]}},
       {:frame, :host, Frame.preface()},
       {:frame, :host, Frame.encode(:settings, 0, 0, settings)},
       {:frame, :host, window_update(0, @connection_window - @default_window)},
       {:read, :host, @idle}
     ],
     %{
       h2
       | linked?: true,
         host: "",
         host_hpack: HPAX.new(4096),
         to_host_hpack: HPAX.new(4096),
         host_window: @default_window,
         host_initial: @default_window,
         host_frame: @frame_size,
         host_may_send: @connection_window,
         next_up: 1,
         by_up: %{}
     }}
  end

  # What a stream holds for the host, sent as far as the host's windows
  # let it, the VM given back what went (and `extra`, padding it sent).
  defp flush_up(h2, stream, extra \\ 0) do
    {frames, stream, h2, sent} = data_up(h2, stream, [], 0)

    {trailers, stream, h2} =
      if stream.out == [] and stream.trailers != nil do
        {block, table} = HPAX.encode(:no_store, stream.trailers, h2.to_host_hpack)

        parts =
          for {header, part} <-
                Frame.header_frames(stream.up, IO.iodata_to_binary(block), true, h2.host_frame),
              do: [{:frame, :host, header}, {:send, :host, part, stream.request.id}]

        {List.flatten(parts), %{stream | trailers: :sent, ended_up?: true},
         %{h2 | to_host_hpack: table}}
      else
        {[], stream, h2}
      end

    {credit, h2} = give_vm(h2, sent + extra)
    {own, stream} = give_vm_stream(stream, sent + extra)
    {frames ++ trailers ++ credit ++ own, put(h2, stream)}
  end

  defp data_up(h2, %{out: []} = stream, acc, sent), do: {Enum.reverse(acc), stream, h2, sent}

  # An empty piece is the VM ending its stream with no data: an empty
  # frame says so, unless more follows.
  defp data_up(h2, %{out: ["" | rest]} = stream, acc, sent) do
    if rest == [] and stream.vm_ended? and is_nil(stream.trailers) and not stream.ended_up? do
      header = Frame.header(:data, Frame.flags(true, false), stream.up, 0)
      data_up(h2, %{stream | out: [], ended_up?: true}, [{:frame, :host, header} | acc], sent)
    else
      data_up(h2, %{stream | out: rest}, acc, sent)
    end
  end

  defp data_up(h2, %{out: [chunk | rest]} = stream, acc, sent) do
    room = Enum.min([h2.host_window, stream.up_window, h2.host_frame])

    if room <= 0 do
      {Enum.reverse(acc), stream, h2, sent}
    else
      take = min(room, byte_size(chunk))
      <<part::binary-size(take), left::binary>> = chunk
      out = if left == "", do: rest, else: [left | rest]
      last? = out == [] and stream.vm_ended? and is_nil(stream.trailers)
      header = Frame.header(:data, Frame.flags(last?, false), stream.up, take)

      stream =
        logged(
          %{stream | out: out, up_window: stream.up_window - take, ended_up?: last?},
          part,
          h2.ctx.limit
        )

      h2 = %{h2 | host_window: h2.host_window - take}
      acc = [{:send, :host, part, stream.request.id}, {:frame, :host, header} | acc]
      data_up(h2, stream, acc, sent + take)
    end
  end

  # What of the body went up joins the log, past the start the card read
  # (`skip`), up to the limit.
  defp logged(%{skip: skip} = stream, part, limit) when skip > 0 do
    skipped = min(skip, byte_size(part))
    rest = binary_part(part, skipped, byte_size(part) - skipped)
    stream = %{stream | skip: skip - skipped}
    if rest == "", do: stream, else: logged(stream, rest, limit)
  end

  defp logged(stream, part, limit), do: %{stream | record: kept_more(stream.record, part, limit)}

  defp flush_all_up(h2) do
    h2.streams
    |> Map.values()
    |> Enum.filter(&(&1.phase == :sent and &1.out != []))
    |> Enum.sort_by(& &1.id)
    |> each(h2, fn stream, h2 -> flush_up(h2, Map.fetch!(h2.streams, stream.id)) end)
  end

  ## Frames from the host

  defp host_frame({:continuation, flags, id, part, _size}, %{block: {:host, id, first, acc}} = h2) do
    block = [acc, part]

    cond do
      IO.iodata_length(block) > @block_limit ->
        host_broke(h2, "The host's header block is too large.")

      Frame.end_headers?(flags) ->
        host_block(%{h2 | block: nil}, id, first, IO.iodata_to_binary(block))

      true ->
        {[], %{h2 | block: {:host, id, first, block}}}
    end
  end

  defp host_frame(_frame, %{block: {:host, _, _, _}} = h2),
    do: host_broke(h2, "The host broke HTTP/2's header blocks.")

  defp host_frame({:settings, flags, 0, payload, _size}, h2) do
    if Frame.ack?(flags) do
      {[], h2}
    else
      case Frame.settings(payload) do
        {:ok, pairs} ->
          h2 = Enum.reduce(pairs, h2, &host_setting/2)
          {flushed, h2} = flush_all_up(h2)
          {[{:frame, :host, Frame.encode(:settings, 1, 0, "")} | flushed], h2}

        :error ->
          host_broke(h2, "The host's SETTINGS are malformed.")
      end
    end
  end

  defp host_frame({:ping, flags, 0, payload, _size}, h2) do
    if Frame.ack?(flags),
      do: {[], h2},
      else: {[{:frame, :host, Frame.encode(:ping, 1, 0, payload)}], h2}
  end

  defp host_frame({:window_update, _flags, 0, <<_::1, increment::31>>, _size}, h2),
    do: flush_all_up(%{h2 | host_window: h2.host_window + increment})

  defp host_frame({:window_update, _flags, up, <<_::1, increment::31>>, _size}, h2) do
    case stream_up(h2, up) do
      nil -> {[], h2}
      stream -> flush_up(h2, %{stream | up_window: stream.up_window + increment})
    end
  end

  defp host_frame({:headers, flags, up, block, _size}, h2) do
    cond do
      byte_size(block) > @block_limit -> host_broke(h2, "The host's header block is too large.")
      Frame.end_headers?(flags) -> host_block(h2, up, flags, block)
      true -> {[], %{h2 | block: {:host, up, flags, block}}}
    end
  end

  # The host sends no more than the windows MWT gave it, or MWT would hold
  # whatever it sends for a VM that doesn't read.
  defp host_frame({:data, _flags, _up, _payload, size}, h2) when size > h2.host_may_send,
    do: host_broke(h2, "The host sent past the window MWT gave it.")

  defp host_frame({:data, flags, up, payload, size}, h2) do
    h2 = %{h2 | host_may_send: h2.host_may_send - size}

    case stream_up(h2, up) do
      nil ->
        give_host(h2, size)

      %{host_may_send: room} when size > room ->
        host_broke(h2, "The host sent past the window MWT gave it.")

      stream ->
        stream = %{stream | host_may_send: stream.host_may_send - size}
        padding = size - byte_size(payload)
        {give, h2} = give_host(h2, padding)
        {own, stream} = give_host_stream(stream, padding)
        {actions, h2} = answer_data(h2, stream, payload, Frame.end_stream?(flags))
        {give ++ own ++ actions, h2}
    end
  end

  defp host_frame({:rst_stream, _flags, up, <<code::32>>, _size}, h2) do
    case stream_up(h2, up) do
      nil ->
        {[], h2}

      stream ->
        {done, h2} = finish(h2, stream, "The host reset the stream.")
        {[{:send, :vm, rst(stream.id, code)} | done], h2}
    end
  end

  # The host is leaving: streams it won't take are refused to the VM, which
  # may send them again; the VM is told to open another connection.
  defp host_frame({:goaway, _flags, 0, <<_::1, last::31, _code::32, _::binary>>, _size}, h2) do
    {refused, kept} = h2.streams |> Map.values() |> Enum.split_with(&(&1.up && &1.up > last))

    {actions, h2} =
      each(refused, h2, fn stream, h2 ->
        {done, h2} = finish(h2, stream, "The host refused it, leaving.")
        {[{:send, :vm, rst(stream.id, @refused_stream)} | done], h2}
      end)

    last_vm = kept |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end)
    away = Frame.encode(:goaway, 0, 0, <<0::1, last_vm::31, @no_error::32>>)
    {actions ++ [{:send, :vm, away}], %{h2 | leaving?: true}}
  end

  defp host_frame({:push_promise, _flags, _up, _payload, _size}, h2),
    do: host_broke(h2, "The host pushed, which MWT asked it not to.")

  defp host_frame(_priority_or_unknown, h2), do: {[], h2}

  defp host_setting({1, size}, h2), do: %{h2 | to_host_hpack: HPAX.resize(h2.to_host_hpack, size)}

  defp host_setting({4, initial}, h2) do
    delta = initial - h2.host_initial

    streams =
      Map.new(h2.streams, fn {id, s} -> {id, %{s | up_window: s.up_window + delta}} end)

    %{h2 | host_initial: initial, streams: streams}
  end

  defp host_setting({5, size}, h2) when size in 16_384..16_777_215, do: %{h2 | host_frame: size}
  defp host_setting(_other, h2), do: h2

  defp host_block(h2, up, flags, block) do
    case HPAX.decode(block, h2.host_hpack) do
      {:ok, headers, table} ->
        h2 = %{h2 | host_hpack: table}

        case stream_up(h2, up) do
          nil ->
            {[], h2}

          stream ->
            if section_size(headers) > @header_list,
              do: unreadable_answer(h2, stream, "Its head is over 64 KiB."),
              else: answer_head(h2, stream, headers, Frame.end_stream?(flags))
        end

      {:error, _reason} ->
        host_broke(h2, "The host's header compression broke.")
    end
  end

  ## The answer

  # Its head, or its trailers: to the VM written again, each form of a
  # value that went in as its placeholder.
  defp answer_head(h2, stream, headers, ended?) do
    case readable(stream, headers) do
      {:ok, stream} -> answer_head_read(h2, stream, headers, ended?)
      {:error, message} -> unreadable_answer(h2, stream, message)
    end
  end

  # A stream with a value in it has its answer's body looked through for
  # the value: its final head says how the body comes, and one MWT can't
  # decode is refused rather than passed on unread. gRPC's compression of
  # each message, which MWT asked for none of, is one.
  defp readable(%{echo: nil} = stream, _headers), do: {:ok, stream}
  defp readable(%{echo: %{body: %AnswerBody{}}} = stream, _headers), do: {:ok, stream}

  defp readable(%{echo: echo} = stream, headers) do
    status = with {_, status} <- List.keyfind(headers, ":status", 0), do: status
    compressed = for {"grpc-encoding", value} <- headers, value != "identity", do: value

    cond do
      is_nil(status) or status =~ ~r/\A1[0-9]{2}\z/ ->
        {:ok, stream}

      compressed != [] ->
        {:error,
         "Its gRPC messages are compressed (#{hd(compressed)}), which MWT asked for none of."}

      true ->
        case AnswerBody.encoding(headers) do
          {:ok, encoding} ->
            {:ok, %{stream | echo: %{echo | body: AnswerBody.new(echo.secrets, encoding)}}}

          :error ->
            {:error, Response.unreadable_encoding()}
        end
    end
  end

  defp answer_head_read(h2, stream, headers, ended?) do
    # Bytes held back as the possible start of a value go before a head
    # that follows them (gRPC's trailers): nothing more of the body comes.
    {held, stream} = release_held(stream)
    stream = queue_data(stream, held, h2.ctx.limit)
    headers = Enum.map(headers, fn {name, value} -> {name, back(stream.echo, value)} end)
    {block, table} = HPAX.encode(:no_store, headers, h2.to_vm_hpack)
    h2 = %{h2 | to_vm_hpack: table}
    frames = Frame.header_frames(stream.id, IO.iodata_to_binary(block), ended?, h2.vm_frame)
    item = {:frames, Enum.map(frames, fn {header, part} -> [header, part] end)}

    answer =
      case stream.answer do
        nil ->
          status = headers |> List.keyfind(":status", 0, {":status", "0"}) |> elem(1)

          %{
            status: String.to_integer(if(status =~ ~r/\A\d{3}\z/, do: status, else: "0")),
            headers: regular(headers),
            kept: [],
            kept_size: 0,
            seen: 0
          }

        answer ->
          %{answer | headers: answer.headers ++ regular(headers)}
      end

    stream = %{stream | to_vm: stream.to_vm ++ [item], answer: answer, host_ended?: ended?}
    flush_vm(h2, stream)
  end

  defp answer_data(h2, stream, payload, ended?) do
    case looked(stream, payload, ended?) do
      # Even empty, a piece is queued: the DATA frame ending the stream.
      {:ok, out, stream} ->
        stream = %{
          stream
          | to_vm: stream.to_vm ++ [{:data, out}],
            host_ended?: ended?,
            answer: kept_answer(stream.answer, out, h2.ctx.limit)
        }

        flush_vm(h2, stream)

      :unreadable ->
        unreadable_answer(h2, stream, "Its body didn't decode.", byte_size(payload))

      {:found, label} ->
        # What came before it goes; then the connection ends, as an HTTP/1.1
        # answer that quoted the value does.
        {flushed, h2} = flush_vm(h2, stream)
        stream = Map.get(h2.streams, stream.id, stream)

        {done, h2} =
          finish(h2, stream, "Cut by MWT: the answer quoted the real credential.")

        away = Frame.encode(:goaway, 0, 0, <<0::1, h2.last_vm::31, @cancel::32>>)

        {flushed ++
           [{:send, :vm, rst(stream.id, @cancel)}, {:found, label, :echo}] ++
           done ++ [{:send, :vm, away}, :close], h2}
    end
  end

  # A stream with a value in it has its answer's body looked through for
  # the value, holding back what could start one until what follows comes.
  defp looked(%{echo: nil} = stream, payload, _ended?), do: {:ok, payload, stream}

  defp looked(%{echo: echo} = stream, payload, ended?) do
    body = echo.body || AnswerBody.new(echo.secrets, nil)

    case AnswerBody.feed(body, payload) do
      {:ok, out, body} ->
        {released, body} = if ended?, do: AnswerBody.release(body), else: {"", body}
        {:ok, out <> released, %{stream | echo: %{echo | body: body}}}

      found_or_unreadable ->
        found_or_unreadable
    end
  end

  # The answer's bytes for the VM, queued behind what waits, and kept for
  # the log.
  defp queue_data(stream, "", _limit), do: stream

  defp queue_data(stream, bytes, limit),
    do: %{
      stream
      | to_vm: stream.to_vm ++ [{:data, bytes}],
        answer: kept_answer(stream.answer, bytes, limit)
    }

  # What a stream holds back as the possible start of a value, let go.
  defp release_held(%{echo: %{body: %AnswerBody{} = body} = echo} = stream) do
    {held, body} = AnswerBody.release(body)
    {held, %{stream | echo: %{echo | body: body}}}
  end

  defp release_held(stream), do: {"", stream}

  defp released(h2, stream) do
    {held, stream} = release_held(stream)
    flush_vm(h2, queue_data(stream, held, h2.ctx.limit))
  end

  # The streams holding bytes back, waiting for what follows.
  defp holding(h2) do
    for {_id, %{echo: %{body: %AnswerBody{} = body}} = stream} <- h2.streams,
        AnswerBody.held?(body),
        do: stream
  end

  # How long the host is read for: a pause holding bytes back lets them go
  # after `@hold`; otherwise the idle time.
  defp host_wait(h2), do: if(holding(h2) == [], do: @idle, else: @hold)

  # An answer MWT can't read for the value that went in: MWT's 502 while
  # nothing of it reached the VM, the stream cut after; the host stops
  # sending it, and what it sent of it is given back to its window.
  defp unreadable_answer(h2, stream, message, taken \\ 0) do
    line = %{
      outcome: :blocked,
      summary: "An answer MWT could not read, not passed on",
      host: h2.ctx.name,
      port: h2.ctx.port
    }

    stop = if stream.up && h2.linked?, do: [{:frame, :host, rst(stream.up, @cancel)}], else: []
    {credit, h2} = give_host(h2, taken)

    if is_nil(stream.answer) do
      json =
        Jason.encode!(%{
          code: "mwt_unreadable_response",
          error:
            "MWT could not read #{authority(h2)}'s answer, so it did not pass it on: #{message}",
          by: "MWT agent sandbox"
        })

      {answer, h2} = answer_self(h2, stream, 502, json)
      {stop ++ credit ++ [{:log, line} | answer], h2}
    else
      {done, h2} = finish(h2, stream, "Cut by MWT: it could not read the rest of the answer.")
      {stop ++ credit ++ [{:send, :vm, rst(stream.id, @cancel)}, {:log, line} | done], h2}
    end
  end

  # What waits for the VM, sent as far as its windows let it, the host
  # given back what went.
  defp flush_vm(h2, stream) do
    {sends, stream, h2, sent} = to_vm(h2, stream, [], 0)

    {credit, h2} = if stream.up, do: give_host(h2, sent), else: {[], h2}
    {own, stream} = give_host_stream(stream, sent)
    credit = credit ++ own
    h2 = put(h2, stream)

    if stream.to_vm == [] and stream.host_ended? do
      {done, h2} = finish(h2, stream, nil)
      {sends ++ credit ++ done, h2}
    else
      {sends ++ credit, h2}
    end
  end

  defp to_vm(h2, %{to_vm: []} = stream, acc, sent), do: {Enum.reverse(acc), stream, h2, sent}

  defp to_vm(h2, %{to_vm: [{:frames, frames} | rest]} = stream, acc, sent),
    do: to_vm(h2, %{stream | to_vm: rest}, [{:send, :vm, frames} | acc], sent)

  defp to_vm(h2, %{to_vm: [{:data, data} | rest]} = stream, acc, sent) do
    room = Enum.min([h2.vm_window, stream.vm_window, h2.vm_frame])
    last? = rest == [] and stream.host_ended?

    cond do
      data == "" and last? ->
        frame = Frame.encode(:data, Frame.flags(true, false), stream.id, "")
        to_vm(h2, %{stream | to_vm: rest}, [{:send, :vm, frame} | acc], sent)

      data == "" ->
        to_vm(h2, %{stream | to_vm: rest}, acc, sent)

      room <= 0 ->
        {Enum.reverse(acc), stream, h2, sent}

      true ->
        take = min(room, byte_size(data))
        <<part::binary-size(take), left::binary>> = data
        queue = if left == "", do: rest, else: [{:data, left} | rest]
        ends? = left == "" and last?
        frame = Frame.encode(:data, Frame.flags(ends?, false), stream.id, part)

        stream = %{stream | to_vm: queue, vm_window: stream.vm_window - take}
        h2 = %{h2 | vm_window: h2.vm_window - take}
        to_vm(h2, stream, [{:send, :vm, frame} | acc], sent + take)
    end
  end

  defp flush_all_vm(h2) do
    h2.streams
    |> Map.values()
    |> Enum.filter(&(&1.to_vm != []))
    |> Enum.sort_by(& &1.id)
    |> each(h2, fn stream, h2 -> flush_vm(h2, Map.fetch!(h2.streams, stream.id)) end)
  end

  ## What MWT answers itself

  # Before anything of it went up: MWT's answer on the stream, logged with
  # it; what the VM sent of it is given back to its window.
  defp answer_self(h2, stream, status, json) do
    # What the VM sent of it that never goes is given back to its window.
    {credit, h2} = give_vm(h2, unsent(stream))
    reset = if stream.vm_ended?, do: [], else: [{:send, :vm, rst(stream.id, @no_error)}]
    {answer, h2} = respond(h2, stream.id, status, json, grpc?(stream.head.headers))
    exchange = exchange(stream, Exchange.mwt_answer(status, json), h2.ctx.limit)

    h2 = drop(h2, stream)
    {answer ++ reset ++ credit ++ [{:done, stream.request, exchange}], h2}
  end

  # An answer of MWT's own: its JSON, or for gRPC trailers only, saying
  # why as gRPC does (`grpc-status`, `grpc-message`).
  defp respond(h2, id, status, json, grpc?) do
    headers =
      if grpc? do
        error =
          with {:ok, %{"error" => error}} <- Jason.decode(json), do: error, else: (_ -> json)

        [
          {":status", "200"},
          {"content-type", "application/grpc"},
          {"grpc-status", if(status in 400..499, do: "7", else: "14")},
          {"grpc-message", grpc_message(error)}
        ]
      else
        [
          {":status", "#{status}"},
          {"content-type", "application/json"},
          {"content-length", "#{byte_size(json)}"}
        ]
      end

    {block, table} = HPAX.encode(:no_store, headers, h2.to_vm_hpack)
    block = IO.iodata_to_binary(block)

    head =
      for {header, part} <- Frame.header_frames(id, block, grpc?, h2.vm_frame), do: [header, part]

    h2 = %{h2 | to_vm_hpack: table}

    if grpc?,
      do: {[{:send, :vm, head}], h2},
      else:
        {[
           {:send, :vm, head},
           {:send, :vm, Frame.encode(:data, Frame.flags(true, false), id, json)}
         ], h2}
  end

  # gRPC's message: percent-encoded outside visible ASCII and `%`.
  defp grpc_message(text) do
    for <<byte <- text>>, into: "" do
      if byte in 0x20..0x7E and byte != ?%, do: <<byte>>, else: "%" <> Base.encode16(<<byte>>)
    end
  end

  defp refuse_all(h2, status, json) do
    {actions, h2} =
      h2.streams
      |> Map.values()
      |> each(h2, fn stream, h2 ->
        if is_nil(stream.answer) and stream.request,
          do: answer_self(h2, stream, status, json),
          else: finish(h2, stream, "Cut by MWT.")
      end)

    {actions ++
       [{:send, :vm, Frame.encode(:goaway, 0, 0, <<0::1, h2.last_vm::31, @cancel::32>>)}, :close],
     h2}
  end

  # The link to the host is gone: streams that went on it end, an answer
  # of MWT's for those that had none yet.
  defp host_lost(h2, message),
    do: lost(h2, message, Jason.encode!(%{error: message, by: "MWT agent sandbox"}))

  # Each stream sent to the host: one with no answer yet gets `json`, one
  # whose answer had begun is reset, its exchange ending with `note`.
  defp lost(h2, note, json) do
    {actions, h2} =
      h2.streams
      |> Map.values()
      |> Enum.filter(&(&1.phase == :sent))
      |> each(h2, fn stream, h2 ->
        if is_nil(stream.answer) do
          answer_self(h2, stream, 502, json)
        else
          {done, h2} = finish(h2, stream, note)
          {[{:send, :vm, rst(stream.id, @cancel)} | done], h2}
        end
      end)

    settle(actions, %{h2 | by_up: %{}})
  end

  defp host_broke(h2, message) do
    {actions, h2} = host_lost(%{h2 | linked?: false}, message)
    {[{:close, :host} | actions], h2}
  end

  ## Streams ending

  defp finish(h2, stream, note) do
    response =
      case stream.answer do
        nil ->
          nil

        answer ->
          Exchange.answer(
            answer.status,
            answer.headers,
            IO.iodata_to_binary(answer.kept),
            answer.seen,
            h2.ctx.limit,
            note
          )
      end

    done =
      if stream.request,
        do: [{:done, stream.request, exchange(stream, response, h2.ctx.limit)}],
        else: []

    # What it took of the windows and never passed on goes back to them:
    # a stream the VM reset while it waited for you, or one the host cut,
    # must not leave the connection with less room for the rest.
    {credit, h2} = give_vm(h2, unsent(stream))

    {host_credit, h2} =
      if stream.up && h2.linked? && Map.get(h2.by_up, stream.up) == stream.id,
        do: give_host(h2, queued(stream)),
        else: {[], h2}

    {done ++ credit ++ host_credit, drop(h2, stream)}
  end

  # The VM's bytes a stream holds that never went up.
  defp unsent(stream), do: IO.iodata_length(stream.held) + IO.iodata_length(stream.out)

  # The host's bytes a stream holds that never went to the VM.
  defp queued(stream),
    do: for({:data, data} <- stream.to_vm, reduce: 0, do: (size -> size + byte_size(data)))

  defp drop(h2, stream) do
    %{
      h2
      | streams: Map.delete(h2.streams, stream.id),
        by_up: if(stream.up, do: Map.delete(h2.by_up, stream.up), else: h2.by_up),
        by_request:
          if(stream.request,
            do: Map.delete(h2.by_request, stream.request.id),
            else: h2.by_request
          )
    }
  end

  defp close_all(h2, note) do
    {actions, h2} =
      h2.streams |> Map.values() |> each(h2, fn stream, h2 -> finish(h2, stream, note) end)

    {actions ++ [:close], h2}
  end

  # The VM is told the connection is over, with why: an error of its own
  # making, or nothing more to do.
  defp leave(h2, code) do
    away = Frame.encode(:goaway, 0, 0, <<0::1, h2.last_vm::31, code::32>>)
    {actions, h2} = close_all(h2, nil)
    {[{:send, :vm, away} | actions], h2}
  end

  ## Reading a head

  # As strictly as an HTTP/1.1 head (`RequestHead`, the rules both share):
  # one of each pseudo-header a request needs, before every other; fields
  # HTTP allows; a path; one name for its host, the one the connection was
  # encrypted for; one content-length at most; nothing HTTP/2 forbids, and
  # no method override.
  defp acceptable(headers, %{name: name, port: port}) do
    {pseudo, rest} = Enum.split_while(headers, fn {key, _} -> String.starts_with?(key, ":") end)
    regular = regular(rest)
    names = Enum.map(pseudo, &elem(&1, 0))
    get = fn key -> with {_, value} <- List.keyfind(pseudo, key, 0), do: value end
    authority = get.(":authority")
    hosts = for {"host", value} <- regular, do: value
    host = authority || List.first(hosts)
    method = get.(":method")
    path = get.(":path")

    cond do
      section_size(headers) > @header_list ->
        {:refuse, 431, "mwt_bad_request", "The request's head is over 64 KiB."}

      Enum.any?(rest, fn {key, _} -> String.starts_with?(key, ":") end) or
        names -- Enum.uniq(names) != [] or
          Enum.any?(names, &(&1 not in [":method", ":scheme", ":authority", ":path"])) ->
        {:refuse, 400, "mwt_bad_request", "MWT could not read this as one HTTP/2 request."}

      is_nil(method) or not RequestHead.token?(method) or get.(":scheme") != "https" or
          is_nil(path) ->
        {:refuse, 400, "mwt_bad_request", "MWT could not read this as one HTTP/2 request."}

      not Enum.all?(regular, fn {key, value} -> field?(key, value) end) ->
        {:refuse, 400, "mwt_bad_request", fields_refused()}

      refusal = RequestHead.refusal(method, path, regular) ->
        refusal

      # One name for its host, as HTTP/1.1 has one Host: a front end that
      # goes by `host` would take it elsewhere than `:authority` says.
      length(hosts) > 1 or
          (authority != nil and hosts != [] and
             String.downcase(hd(hosts)) != String.downcase(authority)) ->
        {:refuse, 400, "mwt_bad_request",
         "A request names its host once: :authority, or one Host header saying the same."}

      is_nil(host) or RequestHead.misdirected?(host, name, port) ->
        {:refuse, 421, "mwt_misdirected",
         "#{host} does not match #{Describe.authority(%{host: name, port: port})}."}

      Enum.any?(regular, fn {key, value} ->
        key in @forbidden or (key == "te" and value != "trailers")
      end) ->
        {:refuse, 400, "mwt_bad_request", "HTTP/2 forbids this request's headers."}

      true ->
        declared = for {"content-length", value} <- regular, do: String.to_integer(value)

        {:ok,
         %{
           method: method,
           path: path,
           headers: regular |> Enum.reject(&match?({"host", _}, &1)) |> trimmed(),
           declared: List.first(declared)
         }}
    end
  end

  # A field as HTTP/1.1 reads one: a token's name, in lower case as HTTP/2
  # writes names, and a value of visible bytes, spaces and tabs. A CR, LF
  # or NUL in one splits it in two for a parser that reads it as HTTP/1.1
  # (a host's front end, a card showing it), but not for MWT.
  defp field?(name, value),
    do:
      RequestHead.token?(name) and name == String.downcase(name) and
        RequestHead.field_value?(value)

  defp fields_refused,
    do:
      "A field's name must be a token in lower case, and its value visible bytes, spaces " <>
        "and tabs: no CR, LF or NUL."

  defp trimmed(headers), do: for({name, value} <- headers, do: {name, RequestHead.trimmed(value)})

  # A header block's size as RFC 9113 counts it (`SETTINGS_MAX_HEADER_LIST_SIZE`).
  defp section_size(headers),
    do:
      Enum.reduce(headers, 0, fn {name, value}, size ->
        size + byte_size(name) + byte_size(value) + 32
      end)

  defp regular(headers),
    do: Enum.reject(headers, fn {key, _} -> String.starts_with?(key, ":") end)

  defp grpc?(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, type} -> String.starts_with?(type, "application/grpc")
      nil -> false
    end
  end

  ## Values, back as their placeholders

  # The forms a value that went in goes by, each to come back as its
  # placeholder (`Http1.echo/2`).
  defp echo(nil), do: nil

  # Its body is looked through once its final head says how it comes
  # (`readable/2`).
  defp echo({secrets, placeholders}),
    do: %{body: nil, secrets: secrets, placeholders: placeholders}

  defp back(nil, value), do: value

  defp back(%{secrets: secrets, placeholders: placeholders}, value),
    do: Secrets.replace_each(secrets, value, &Map.fetch!(placeholders, &1))

  ## The log

  defp exchange(stream, response, limit) do
    vm = stream.record.sent_up
    request = %{vm | body: IO.iodata_to_binary([vm.body | stream.record.more])}
    %{request: Exchange.request(request, limit), response: response}
  end

  # The body the VM sends after what MWT read before deciding, kept for the
  # log up to the limit.
  defp kept_more(record, nil, _limit), do: record

  defp kept_more(record, data, limit) do
    held = byte_size(record.sent_up.body) + IO.iodata_length(record.more)
    room = limit - held

    cond do
      room <= 0 or data == "" -> record
      byte_size(data) <= room -> %{record | more: [record.more, data]}
      true -> %{record | more: [record.more, binary_part(data, 0, room)]}
    end
  end

  defp kept_answer(nil, _data, _limit), do: nil

  defp kept_answer(answer, data, limit) do
    room = limit - answer.kept_size
    kept = if room > 0, do: binary_part(data, 0, min(room, byte_size(data))), else: ""

    %{
      answer
      | kept: [answer.kept, kept],
        kept_size: answer.kept_size + byte_size(kept),
        seen: answer.seen + byte_size(data)
    }
  end

  ## Helpers

  # Each item's actions, in order, the state passed along.
  defp each(items, h2, fun) do
    Enum.reduce(items, {[], h2}, fn item, {acc, h2} ->
      {actions, h2} = fun.(item, h2)
      {[acc, actions], h2}
    end)
    |> then(fn {acc, h2} -> {List.flatten(acc), h2} end)
  end

  # What every answer ends with: the VM read again, by the earliest stream
  # still to judge or, with none, after the idle time.
  defp settle(actions, h2) do
    if :close in actions do
      {actions, h2}
    else
      deadline =
        h2.streams
        |> Map.values()
        |> Enum.flat_map(fn %{phase: phase, by: by} ->
          if phase == :body and by, do: [by], else: []
        end)
        |> Enum.min(fn -> nil end)

      wait = if deadline, do: max(deadline - now(), 0), else: @idle
      done? = h2.leaving? and h2.streams == %{}
      {actions ++ if(done?, do: [:close], else: [{:read, :vm, wait}]), h2}
    end
  end

  defp busy?(h2), do: h2.streams != %{}

  defp put(h2, stream), do: %{h2 | streams: Map.put(h2.streams, stream.id, stream)}

  defp stream_up(h2, up) do
    with id when is_integer(id) <- Map.get(h2.by_up, up), do: Map.get(h2.streams, id)
  end

  defp rst_unless_known(h2, id),
    do: if(id > h2.last_vm, do: [], else: [{:send, :vm, rst(id, @internal_error)}])

  defp rst(id, code), do: Frame.encode(:rst_stream, 0, id, <<code::32>>)

  # Window given back to the VM, on the connection and on a stream it
  # still sends on: what it may send MWT again.
  defp give_vm(h2, amount) when amount > 0,
    do: {[{:send, :vm, window_update(0, amount)}], %{h2 | vm_may_send: h2.vm_may_send + amount}}

  defp give_vm(h2, _none), do: {[], h2}

  defp give_vm_stream(%{vm_ended?: false} = stream, amount) when amount > 0,
    do:
      {[{:send, :vm, window_update(stream.id, amount)}],
       %{stream | vm_may_send: stream.vm_may_send + amount}}

  defp give_vm_stream(stream, _none), do: {[], stream}

  # The same for the host, on MWT's own connection to it.
  defp give_host(h2, amount) when amount > 0,
    do:
      {[{:frame, :host, window_update(0, amount)}],
       %{h2 | host_may_send: h2.host_may_send + amount}}

  defp give_host(h2, _none), do: {[], h2}

  defp give_host_stream(%{host_ended?: false, up: up} = stream, amount)
       when is_integer(up) and amount > 0,
       do:
         {[{:frame, :host, window_update(up, amount)}],
          %{stream | host_may_send: stream.host_may_send + amount}}

  defp give_host_stream(stream, _none), do: {[], stream}

  defp window_update(id, increment) when increment > 0,
    do: Frame.encode(:window_update, 0, id, <<0::1, increment::31>>)

  defp window_update(_id, _none), do: []

  defp authority(h2), do: Describe.authority(%{host: h2.ctx.name, port: h2.ctx.port})

  defp now, do: System.monotonic_time(:millisecond)
  defp within(ms), do: now() + ms
  defp left(by), do: max(by - now(), 0)
end
