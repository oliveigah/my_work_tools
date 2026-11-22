defmodule MWTClient.SandboxLineDriver do
  @moduledoc """
  A driver for a made-up protocol, there only to show what adding one
  takes (`MWTClient.Sandbox.Egress.Driver`): plain text, one request a
  line, `TINY <operation> <resource>`, and one line back for each. Nothing
  outside this module knows it exists; a test hands it to the connection
  (`drivers:`).
  """

  @behaviour MWTClient.Sandbox.Egress.Driver

  alias MWTClient.Sandbox.Egress.{Driver, Request}

  @wait 5_000

  @impl true
  def alpn, do: []

  # Its own bytes, on TCP outside TLS. Fewer than its word: more to tell.
  @impl true
  def detect("TINY " <> _, %{transport: :tcp, tls?: false}), do: :yes

  def detect(data, %{transport: :tcp, tls?: false}) when byte_size(data) < 5,
    do: if(String.starts_with?("TINY ", data), do: :more, else: :no)

  def detect(_data, _ctx), do: :no

  @impl true
  def init(ctx),
    do: {[{:read, :vm, @wait}], %{ctx: ctx, buffer: "", request: nil, linked?: false}}

  # A whole line is a request, judged before it goes.
  @impl true
  def handle_data(:vm, data, line) do
    buffer = line.buffer <> data

    case :binary.split(buffer, "\n") do
      [text, rest] ->
        [_tiny, operation, resource] = String.split(text, " ", parts: 3)

        request = %Request{
          id: "tiny-" <> Integer.to_string(System.unique_integer([:positive])),
          driver: __MODULE__,
          name: Driver.host(line.ctx),
          port: line.ctx.port,
          under: line.ctx.under,
          operation: operation,
          resource: resource,
          data: text <> "\n"
        }

        {[{:judge, request}], %{line | buffer: rest, request: request}}

      [_partial] ->
        {[{:read, :vm, @wait}], %{line | buffer: buffer}}
    end
  end

  # Its answer, one line: the request ends, and the next may come.
  def handle_data(:host, data, line) do
    {[{:send, :vm, data}, {:done, line.request, nil}, {:read, :vm, @wait}],
     %{line | request: nil}}
  end

  @impl true
  def handle_verdict(_id, {:allow, _replace}, line) do
    connect = if line.linked?, do: [], else: [{:connect, %{alpn: []}}]

    {connect ++ [{:send, :host, line.request.data}, {:read, :host, @wait}],
     %{line | linked?: true}}
  end

  # A refusal in its own words.
  def handle_verdict(_id, {refused, _status, json}, line) when refused in [:deny, :reply] do
    %{"code" => code} = Jason.decode!(json)
    {[{:send, :vm, "REFUSED #{code}\n"}, {:done, line.request, nil}, :close], line}
  end

  @impl true
  def handle_closed(_side, _ended, line), do: {[:close], line}

  @impl true
  def handle_timeout(_side, line), do: {[:close], line}

  @impl true
  def handle_cut(_cut, line), do: {[{:send, :vm, "CUT\n"}, :close], line}

  @impl true
  def describe(request) do
    %{
      title: "TINY #{request.operation} #{request.name}:#{request.port} #{request.resource}",
      facts: [{"Resource", request.resource}],
      claims: [],
      pattern: "tiny #{request.operation} #{request.resource}"
    }
  end
end
