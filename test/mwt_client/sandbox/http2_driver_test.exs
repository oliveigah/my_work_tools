defmodule MWTClient.Sandbox.Http2DriverTest do
  @moduledoc """
  MWT's HTTP/2 driver on its own, frames in and actions out: a gRPC call
  read and judged, its head written again for the host as text, its
  answer's trailers passed back, a request for another host refused, and a
  value put in going as bytes the core doesn't look through. A head is
  read as strictly as HTTP/1.1's; what MWT holds is bounded by the windows
  it gave, both ways, and by the header list it announced; an answer
  quoting the value is found compressed too, and what could start the
  value waits 50 ms at most.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver.Http2
  alias MWTClient.Sandbox.Egress.Driver.Http2.Frame

  @ctx %{
    transport: :tcp,
    name: "example.com",
    ip: {93, 184, 216, 34},
    port: 443,
    under: "internet",
    tls?: true,
    alpn: "h2",
    first: :vm,
    linked?: false,
    why: :every_host,
    limit: 65_536,
    started: 0,
    options: []
  }

  defp frame(type, flags, stream, payload),
    do: IO.iodata_to_binary(Frame.encode(type, flags, stream, payload))

  defp block(headers) do
    {block, _table} = HPAX.encode(:no_store, headers, HPAX.new(4096))
    IO.iodata_to_binary(block)
  end

  # The frames in what the actions send to `side`, as `{type, flags, stream, payload}`.
  defp sent(actions, side) do
    bytes =
      actions
      |> Enum.flat_map(fn
        {:send, ^side, bytes} -> [bytes]
        {:send, ^side, bytes, _stream} -> [bytes]
        {:frame, ^side, bytes} -> [bytes]
        {:write, ^side, bytes} -> [bytes]
        _other -> []
      end)
      |> IO.iodata_to_binary()
      |> String.replace_prefix(Frame.preface(), "")

    {:ok, frames, ""} = Frame.split(bytes, 1_000_000)

    Enum.map(frames, fn {type, flags, stream, payload, _size} ->
      {type, flags, stream, payload}
    end)
  end

  defp headers_of(frames, stream) do
    for {:headers, _flags, ^stream, block} <- frames do
      {:ok, headers, _table} = HPAX.decode(block, HPAX.new(4096))
      headers
    end
  end

  defp opened(headers, data \\ nil) do
    {_actions, h2} = Http2.init(@ctx)
    ends? = is_nil(data)

    vm =
      Frame.preface() <>
        frame(:settings, 0, 0, "") <>
        frame(:headers, Frame.flags(ends?, true), 1, block(headers)) <>
        if(data, do: frame(:data, Frame.flags(true, false), 1, data), else: "")

    Http2.handle_data(:vm, vm, h2)
  end

  @grpc [
    {":method", "POST"},
    {":scheme", "https"},
    {":authority", "example.com"},
    {":path", "/pkg.Service/Call"},
    {"content-type", "application/grpc"},
    {"te", "trailers"}
  ]

  test "a gRPC call is judged, sent as text on MWT's own stream, and its trailers come back" do
    message = <<0, 0, 0, 0, 2, 8, 1>>
    {actions, h2} = opened(@grpc, message)

    assert {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))
    assert request.operation == "POST" and request.resource == "/pkg.Service/Call"

    assert %{title: "gRPC pkg.Service/Call on example.com", pattern: pattern} =
             Http2.describe(request)

    assert pattern == "gRPC example.com/pkg.Service/Call"

    {actions, h2} = Http2.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, h2)
    assert {:connect, %{alpn: ["h2"]}} in actions

    # The head is the VM's text, on the request's own stream; the body too.
    up = sent(actions, :host)
    [head] = headers_of(up, 1)
    assert {":authority", "example.com"} in head and {"te", "trailers"} in head
    assert {:data, flags, 1, ^message} = List.keyfind(up, :data, 0)
    assert Frame.end_stream?(flags)

    texts = for {:send, :host, bytes, stream} <- actions, do: {IO.iodata_to_binary(bytes), stream}
    assert Enum.all?(texts, fn {_bytes, stream} -> stream == request.id end)
    assert Enum.any?(texts, fn {bytes, _} -> bytes =~ "/pkg.Service/Call" end)

    answer =
      frame(:settings, 0, 0, "") <>
        frame(
          :headers,
          Frame.flags(false, true),
          1,
          block([{":status", "200"}, {"content-type", "application/grpc"}])
        ) <>
        frame(:data, 0, 1, <<0, 0, 0, 0, 0>>) <>
        frame(:headers, Frame.flags(true, true), 1, block([{"grpc-status", "0"}]))

    {actions, _h2} = Http2.handle_data(:host, answer, h2)
    down = sent(actions, :vm)
    assert [[{":status", "200"} | _], [{"grpc-status", "0"}]] = headers_of(down, 1)
    assert {:headers, flags, 1, _} = List.last(Enum.filter(down, &(elem(&1, 0) == :headers)))
    assert Frame.end_stream?(flags)

    assert {:done, ^request, %{response: %{status: 200}}} =
             Enum.find(actions, &match?({:done, _, _}, &1))
  end

  test "TLS MWT can't make with the host is logged as a read that failed, and says what to do" do
    {actions, h2} = opened(@grpc, <<0, 0, 0, 0, 0>>)
    {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))
    {_actions, h2} = Http2.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, h2)

    {actions, _h2} =
      Http2.handle_closed(:host, {:unreachable, {:tls_alert, {:unknown_ca, ~c"unknown ca"}}}, h2)

    # Its line is the one Don't read is offered on, as HTTP/1.1's is.
    assert {:log, %{outcome: :read_failed, host: "example.com", port: 443}} =
             Enum.find(actions, &match?({:log, _}, &1))

    [answer] = headers_of(sent(actions, :vm), 1)
    assert {"grpc-status", "14"} in answer
    {_, message} = List.keyfind(answer, "grpc-message", 0)
    assert URI.decode(message) =~ "a CA this machine doesn't trust"
    assert URI.decode(message) =~ "Don't read"
  end

  test "a request for another host than the connection's is refused on its stream" do
    headers = List.keyreplace(@grpc, ":authority", 0, {":authority", "elsewhere.test"})
    {actions, _h2} = opened(headers)
    refute Enum.any?(actions, &match?({:judge, _}, &1))

    [answer] = headers_of(sent(actions, :vm), 1)
    assert {"grpc-status", "7"} in answer
    assert {_, message} = List.keyfind(answer, "grpc-message", 0)
    assert message =~ "elsewhere.test does not match example.com"
  end

  test "a head HTTP/2 forbids, or a method override, isn't passed on" do
    for extra <- [{"connection", "keep-alive"}, {"x-http-method-override", "DELETE"}] do
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":authority", "example.com"},
        {":path", "/"},
        extra
      ]

      {actions, _h2} = opened(headers)
      refute Enum.any?(actions, &match?({:judge, _}, &1))
      assert [[{":status", "400"} | _]] = headers_of(sent(actions, :vm), 1)
    end
  end

  test "a head with a value put in goes as bytes the core doesn't look through" do
    headers = [
      {":method", "GET"},
      {":scheme", "https"},
      {":authority", "example.com"},
      {":path", "/me"},
      {"authorization", "Bearer mwt_placeholder_0123456789"}
    ]

    {actions, h2} = opened(headers)
    {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))

    replace = %{
      request: [
        %{
          label: "g",
          from: "mwt_placeholder_0123456789",
          to: "real_0123456789",
          within: ["authorization"]
        }
      ],
      answer: [%{label: "g", from: ["real_0123456789"], to: "mwt_placeholder_0123456789"}]
    }

    {actions, h2} = Http2.handle_verdict(request.id, {:allow, replace}, h2)
    writes = for {:write, :host, bytes} <- actions, do: IO.iodata_to_binary(bytes)
    assert Enum.any?(writes, &(&1 =~ "real_0123456789"))

    refute Enum.any?(actions, fn
             {:send, :host, bytes, _stream} -> IO.iodata_to_binary(bytes) =~ "real_0123456789"
             _other -> false
           end)

    # Back in the answer's headers, it is the placeholder again.
    answer =
      frame(
        :headers,
        Frame.flags(true, true),
        1,
        block([{":status", "200"}, {"x-echo", "real_0123456789"}])
      )

    {actions, _h2} = Http2.handle_data(:host, answer, h2)
    [[{":status", "200"}, {"x-echo", echoed}]] = headers_of(sent(actions, :vm), 1)
    assert echoed == "mwt_placeholder_0123456789"
  end

  ## A head read as strictly as HTTP/1.1's

  @get [
    {":method", "GET"},
    {":scheme", "https"},
    {":authority", "example.com"},
    {":path", "/"}
  ]

  defp status_of(actions) do
    case headers_of(sent(actions, :vm), 1) do
      [[{":status", status} | _] | _] -> status
      _none -> nil
    end
  end

  test "a host named twice, or apart from :authority, or a field with CR, LF or NUL, is refused" do
    for extra <- [
          [{"host", "example.com"}, {"host", "evil.example"}],
          [{"host", "evil.example"}],
          [{"x-note", "a\r\nauthorization: Bearer injected"}],
          [{"x-nul", "a\0b"}],
          [{"x name", "a"}]
        ] do
      {actions, _h2} = opened(@get ++ extra)
      refute Enum.any?(actions, &match?({:judge, _}, &1)), inspect(extra)
      assert status_of(actions) == "400", inspect(extra)
    end

    # One host saying what :authority says is the same request, and goes
    # with :authority alone.
    {actions, h2} = opened(@get ++ [{"host", "example.com"}])
    {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))
    {actions, _h2} = Http2.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, h2)
    [head] = headers_of(sent(actions, :host), 1)
    refute List.keymember?(head, "host", 0)
  end

  test "a body its content-length doesn't match is refused, before or after it went" do
    post = List.keyreplace(@grpc, ":method", 0, {":method", "POST"})

    # Longer than it says: what follows could be read as another request.
    {actions, _h2} =
      opened(post ++ [{"content-length", "0"}], "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n")

    refute Enum.any?(actions, &match?({:judge, _}, &1))
    assert [[{":status", "200"}, _, {"grpc-status", "7"} | _]] = headers_of(sent(actions, :vm), 1)

    # Shorter than it says.
    {actions, _h2} = opened(post ++ [{"content-length", "10"}], "12345")
    refute Enum.any?(actions, &match?({:judge, _}, &1))

    # As it says.
    {actions, _h2} = opened(post ++ [{"content-length", "5"}], "12345")
    assert Enum.any?(actions, &match?({:judge, _}, &1))

    # Its start went up already: the rest past the length doesn't, and
    # the stream is reset both ways.
    {_actions, h2} = Http2.init(@ctx)

    vm =
      Frame.preface() <>
        frame(:settings, 0, 0, "") <>
        frame(:headers, Frame.flags(false, true), 1, block(post ++ [{"content-length", "70000"}])) <>
        String.duplicate(frame(:data, 0, 1, :binary.copy("a", 14_000)), 5)

    {actions, h2} = Http2.handle_data(:vm, vm, h2)
    {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))
    {_actions, h2} = Http2.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, h2)
    {actions, _h2} = Http2.handle_data(:vm, frame(:data, 0, 1, "more"), h2)
    refute Enum.any?(sent(actions, :host), &match?({:data, _, 1, _}, &1))
    assert {:rst_stream, 0, 1, <<8::32>>} in sent(actions, :host)
    assert {:rst_stream, 0, 1, <<1::32>>} in sent(actions, :vm)
  end

  ## Bounds

  test "MWT announces the header list it takes, and refuses a block that decodes past it" do
    {actions, _h2} = Http2.init(@ctx)
    [{:settings, 0, 0, settings}] = Enum.filter(sent(actions, :vm), &(elem(&1, 0) == :settings))
    assert {:ok, pairs} = Frame.settings(settings)
    assert {6, 65_536} in pairs

    # A few bytes that stand, through HPACK's table, for a field of 4 KB
    # sent many times: 19 KB on the wire, 57 MB decoded.
    {pseudo, table} = HPAX.encode(:no_store, @get, HPAX.new(4096))
    {literal, _} = HPAX.encode(:store, [{"x-a", String.duplicate("v", 4_000)}], table)
    block = IO.iodata_to_binary([pseudo, literal]) <> :binary.copy(<<0xBE>>, 15_000)

    frames =
      for {header, part} <- Frame.header_frames(1, block, true, 16_384),
          into: "",
          do: header <> part

    {_actions, h2} = Http2.init(@ctx)

    {actions, _h2} =
      Http2.handle_data(:vm, Frame.preface() <> frame(:settings, 0, 0, "") <> frames, h2)

    refute Enum.any?(actions, &match?({:judge, _}, &1))
    assert status_of(actions) == "431"
  end

  defp post_frames(id, ended?) do
    headers = List.keyreplace(@grpc, ":path", 0, {":path", "/upload/#{id}"})
    frame(:headers, Frame.flags(ended?, true), id, block(headers))
  end

  defp goaway_code(actions) do
    for {:goaway, _f, 0, <<_::32, code::32>>} <- sent(actions, :vm), do: code
  end

  test "a VM sending past the windows MWT gave it ends the connection (FLOW_CONTROL_ERROR)" do
    chunk = frame(:data, 0, 1, :binary.copy("z", 16_384))

    # Past its stream's window (1 MiB) while it waits for its verdict.
    {_actions, h2} = Http2.init(@ctx)

    {_actions, h2} =
      Http2.handle_data(
        :vm,
        Frame.preface() <> frame(:settings, 0, 0, "") <> post_frames(1, false),
        h2
      )

    {actions, _h2} = Http2.handle_data(:vm, :binary.copy(chunk, 65), h2)
    assert goaway_code(actions) == [3]
    assert :close in actions

    # Within the window, it is held.
    {_actions, h2} = Http2.init(@ctx)

    {_actions, h2} =
      Http2.handle_data(
        :vm,
        Frame.preface() <> frame(:settings, 0, 0, "") <> post_frames(1, false),
        h2
      )

    {actions, _h2} = Http2.handle_data(:vm, :binary.copy(chunk, 64), h2)
    assert goaway_code(actions) == []
  end

  defp credit(frames, stream),
    do:
      for(
        {:window_update, _f, ^stream, <<_::1, n::31>>} <- frames,
        reduce: 0,
        do: (acc -> acc + n)
      )

  test "what a stream held goes back to the connection's window when the VM resets it" do
    {_init, h2} = Http2.init(@ctx)
    data = :binary.copy("x", 16_000)

    vm =
      Frame.preface() <>
        frame(:settings, 0, 0, "") <>
        post_frames(1, false) <>
        frame(:data, 0, 1, data) <> frame(:data, 0, 1, data) <> frame(:data, 0, 1, data)

    {actions, h2} = Http2.handle_data(:vm, vm, h2)
    refute Enum.any?(actions, &match?({:judge, _}, &1))
    assert credit(sent(actions, :vm), 0) == 0

    # The client gives up on the call (a gRPC deadline): RST_STREAM CANCEL.
    {actions, _h2} = Http2.handle_data(:vm, frame(:rst_stream, 0, 1, <<8::32>>), h2)
    assert credit(sent(actions, :vm), 0) == 48_000
  end

  test "a VM that doesn't read leaves MWT holding no more of the host's answers than its window" do
    {_init, h2} = Http2.init(@ctx)
    streams = for n <- 0..2, do: 2 * n + 1

    # The VM gives the host no window at all.
    get = fn id ->
      frame(
        :headers,
        Frame.flags(true, true),
        id,
        block(List.keyreplace(@get, ":path", 0, {":path", "/#{id}"}))
      )
    end

    vm =
      Frame.preface() <>
        frame(:settings, 0, 0, Frame.settings_payload([{4, 0}])) <> Enum.map_join(streams, get)

    {actions, h2} = Http2.handle_data(:vm, vm, h2)

    h2 =
      for {:judge, request} <- actions, reduce: h2 do
        h2 ->
          {_actions, h2} =
            Http2.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, h2)

          h2
      end

    chunk = :binary.copy("y", 16_384)

    answer = fn up, count ->
      frame(:headers, Frame.flags(false, true), up, block([{":status", "200"}])) <>
        String.duplicate(frame(:data, 0, up, chunk), count)
    end

    # Two streams fill the 2 MiB MWT gave the host's connection...
    {actions, h2} =
      Http2.handle_data(:host, frame(:settings, 0, 0, "") <> answer.(1, 64) <> answer.(3, 64), h2)

    refute {:close, :host} in actions
    refute Enum.any?(sent(actions, :vm), &match?({:data, _, _, _}, &1))

    # ...and a host sending past it is cut off rather than held.
    {actions, _h2} = Http2.handle_data(:host, answer.(5, 1), h2)
    assert {:close, :host} in actions
  end

  ## The answer to a stream with a value in it

  @auth [{"authorization", "Bearer mwt_placeholder_0123456789"}]
  @replace %{
    request: [
      %{
        label: "g",
        from: "mwt_placeholder_0123456789",
        to: "real_0123456789",
        within: ["authorization"]
      }
    ],
    answer: [%{label: "g", from: ["real_0123456789"], to: "mwt_placeholder_0123456789"}]
  }

  defp valued(headers) do
    {actions, h2} = opened(headers ++ @auth)
    {:judge, request} = Enum.find(actions, &match?({:judge, _}, &1))
    Http2.handle_verdict(request.id, {:allow, @replace}, h2)
  end

  defp data_to_vm(actions),
    do: for({:data, _f, 1, payload} <- sent(actions, :vm), into: "", do: payload)

  test "a gzip answer quoting the value is found and cut; one MWT can't decode is refused" do
    body = :zlib.gzip(~s({"message":"Bad credentials","seen":"Bearer real_0123456789"}))
    {_actions, h2} = valued(@get)

    answer =
      frame(:settings, 0, 0, "") <>
        frame(
          :headers,
          Frame.flags(false, true),
          1,
          block([{":status", "401"}, {"content-encoding", "gzip"}])
        ) <>
        frame(:data, Frame.flags(true, false), 1, body)

    {actions, _h2} = Http2.handle_data(:host, answer, h2)
    assert {:found, "g", :echo} in actions
    refute data_to_vm(actions) == body

    for encoding <- [{"content-encoding", "br"}, {"grpc-encoding", "gzip"}] do
      {_actions, h2} = valued(@get)
      head = frame(:headers, Frame.flags(false, true), 1, block([{":status", "200"}, encoding]))
      {actions, _h2} = Http2.handle_data(:host, frame(:settings, 0, 0, "") <> head, h2)
      assert status_of(actions) == "502", inspect(encoding)
      assert data_to_vm(actions) =~ "mwt_unreadable_response"
    end
  end

  test "its request asks for no compression, gRPC's own included" do
    {actions, _h2} = valued(@grpc ++ [{"grpc-accept-encoding", "gzip,deflate"}])
    writes = for {:write, :host, bytes} <- actions, into: "", do: IO.iodata_to_binary(bytes)

    {:ok, frames, ""} =
      Frame.split(writes |> String.replace_prefix(Frame.preface(), ""), 1_000_000)

    [head] =
      for {:headers, _f, 1, block, _size} <- frames,
          do: elem(HPAX.decode(block, HPAX.new(4096)), 1)

    refute List.keymember?(head, "grpc-accept-encoding", 0)
    assert {"accept-encoding", "identity"} in head
  end

  test "what could start the value waits 50 ms at most, and goes before the trailers" do
    {_actions, h2} = valued(@grpc)
    # The first streamed message happens to end in "re".
    message = <<0, 0, 0, 0, 7, "one: re">>

    answer =
      frame(:settings, 0, 0, "") <>
        frame(
          :headers,
          Frame.flags(false, true),
          1,
          block([{":status", "200"}, {"content-type", "application/grpc"}])
        ) <>
        frame(:data, 0, 1, message)

    {actions, h2} = Http2.handle_data(:host, answer, h2)
    assert data_to_vm(actions) == binary_part(message, 0, 10)
    assert {:read, :host, 50} in actions

    # The host pauses: the held bytes go.
    {actions, h2} = Http2.handle_timeout(:host, h2)
    assert data_to_vm(actions) == "re"

    # A message ending so, then the trailers at once: it goes whole before them.
    {actions, _h2} =
      Http2.handle_data(
        :host,
        frame(:data, 0, 1, <<0, 0, 0, 0, 3, "two">> <> "r") <>
          frame(:headers, Frame.flags(true, true), 1, block([{"grpc-status", "0"}])),
        h2
      )

    assert data_to_vm(actions) == <<0, 0, 0, 0, 3, "two", "r">>
    assert [_trailers] = headers_of(sent(actions, :vm), 1)
  end
end
