defmodule MWTClient.Sandbox.Egress.Driver.Raw do
  @moduledoc """
  The driver for what no other reads: the call's bytes go on as they come,
  both ways, until either side closes or neither sends for five minutes.
  It is asked last and takes anything (`MWTClient.Sandbox.Egress.Driver`).
  Each delivery goes on as one send, so on TCP it is a stream passed on,
  and on UDP it would be each datagram, one for one.

  It judges nothing: the call was judged as a whole before it came here
  (the destination check, and for a network grant that asks, a card for
  the connection). The core still looks through and counts every byte
  it sends up, as for any driver, so a placeholder or a real value in it
  is caught whatever the protocol. When MWT ended the VM's TLS and found
  no protocol it reads inside, the link to the host is TLS MWT started
  again, so what goes up is decrypted and looked through all the same.

  Its call is one line in the log, at its end: why it wasn't read, and how
  many bytes went each way.
  """

  @behaviour MWTClient.Sandbox.Egress.Driver

  alias MWTClient.Sandbox.EventDetails
  alias MWTClient.Sandbox.Egress.Driver

  @idle 300_000

  defstruct [:ctx, up: 0, down: 0]

  @impl true
  def alpn, do: []

  @impl true
  def detect(_data, _ctx), do: :yes

  @impl true
  def init(ctx) do
    connect = if ctx.linked?, do: [], else: [{:connect, %{alpn: []}}]
    {connect ++ [{:read, :vm, @idle}, {:read, :host, @idle}], %__MODULE__{ctx: ctx}}
  end

  # Either side's bytes keep both waiting: five minutes of nothing at all
  # ends it.
  @impl true
  def handle_data(:vm, data, raw) do
    {[{:send, :host, data}, {:read, :vm, @idle}, {:read, :host, @idle}],
     %{raw | up: raw.up + byte_size(data)}}
  end

  def handle_data(:host, data, raw) do
    {[{:send, :vm, data}, {:read, :host, @idle}, {:read, :vm, @idle}],
     %{raw | down: raw.down + byte_size(data)}}
  end

  @impl true
  def handle_verdict(_id, _verdict, raw), do: {[], raw}

  @impl true
  def handle_closed(:host, {:unreachable, reason}, raw) do
    {[
       {:log,
        %{
          outcome: :blocked,
          summary: "Could not connect: " <> Driver.unreachable(reason),
          host: Driver.host(raw.ctx),
          port: raw.ctx.port
        }},
       :close
     ], raw}
  end

  def handle_closed(_side, _ended, raw), do: finish(raw)

  @impl true
  def handle_timeout(_side, raw), do: finish(raw)

  @impl true
  def handle_cut(_cut, raw), do: finish(raw)

  @impl true
  def describe(request) do
    %{title: "#{request.operation} #{request.name}", facts: [], claims: [], pattern: nil}
  end

  defp finish(raw) do
    {[
       {:log,
        %{
          outcome: :tunnel,
          summary: summary(raw.ctx.why),
          host: Driver.host(raw.ctx),
          port: raw.ctx.port,
          up: raw.up,
          down: raw.down,
          ms: System.monotonic_time(:millisecond) - raw.ctx.started,
          details: details(raw.ctx)
        }},
       :close
     ], raw}
  end

  # The connection as MWT saw it: where it went, what it offered, why it
  # wasn't read.
  defp details(ctx) do
    [
      EventDetails.section("The connection", [
        {"Address", "#{:inet.ntoa(ctx.ip)}:#{ctx.port}"},
        {"Name it asked for", ctx.name},
        {"Transport", ctx.transport |> to_string() |> String.upcase()},
        {"TLS", if(ctx.tls?, do: "yes", else: "no")},
        {"Protocol offered", ctx.alpn},
        {"Under the grant",
         is_binary(ctx.under) && {:link, ctx.under, "/tools/sandbox/grants/#{ctx.under}"}},
        {"Why not read", why_words(ctx.why)}
      ])
    ]
  end

  defp why_words({:passed, reason}), do: Driver.why(reason)
  defp why_words(_read), do: nil

  # Why MWT didn't read it (`MWTClient.Sandbox.Gate.reading/3`): with
  # reading only token grants' hosts, it is passed through as it always
  # was.
  defp summary({:passed, :off}), do: "Passed through"
  defp summary({:passed, reason}), do: "Not read: " <> Driver.why(reason)
end
