defmodule MWTClient.Sandbox.Http2DriverTest do
  @moduledoc """
  MWT's HTTP/2 driver on its own, frames in and actions out: a gRPC call
  read and judged, its head written again for the host as text, its
  answer's trailers passed back, a request for another host refused, and a
  value put in going as bytes the core doesn't look through.
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
end
