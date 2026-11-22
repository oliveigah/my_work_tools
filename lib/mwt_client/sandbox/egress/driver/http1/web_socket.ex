defmodule MWTClient.Sandbox.Egress.Driver.Http1.WebSocket do
  @moduledoc """
  The frames of a WebSocket (RFC 6455) on a connection MWT reads, once its
  handshake switched it (`MWTClient.Sandbox.Egress.Driver.Http1`): each
  side's messages read for the log, and the VM's frames written again so
  that what MWT looks through going up is their text. Pure: bytes go in
  (`feed/2`), what to send comes out.

  **The VM's frames.** A client masks every frame it sends with four bytes
  of its choosing, so on the wire its text is scrambled, and MWT's look
  for real values and placeholders (`MWTClient.Sandbox.Egress.Tcp`) would
  find nothing in it. So each frame goes up again with its payload as it
  is, masked with four zero bytes: RFC 6455 lets a client pick any mask,
  and a zero one leaves the payload as it is. The header goes as the
  driver's own framing (`{:frame, header}`), the payload as the VM's text
  (`{:payload, text}`), so the core looks through a message's text as one
  stream, a value split across two frames included. MWT also takes the
  client's extensions offer out of the handshake (`Http1`), so no message
  comes compressed past reading.

  **The host's frames** go to the VM as they came: they are only read.

  **What the log keeps** of each side (`log/1`): its messages, one a line,
  text as it is, the rest in words (`[binary, 12 bytes]`, `[close 1000
  going away]`; pings and pongs aren't kept), up to the body limit.

  Bytes that stop being frames this reads (an extension's bits set, an
  opcode RFC 6455 doesn't define, a VM frame left unmasked) end the
  reading: `feed/2` says `{:broken, ...}` once, and the caller passes the
  rest on as bytes, looked through as any are.
  """

  alias MWTClient.Sandbox.Exchange

  @control [8, 9, 10]
  @opcodes [0, 1, 2 | @control]

  @derive {Inspect, only: [:side, :total, :cut?]}
  defstruct [
    :side,
    :limit,
    frame: nil,
    buffer: "",
    message: nil,
    control: "",
    kept: [],
    kept_size: 0,
    total: 0,
    cut?: false
  ]

  @opaque t :: %__MODULE__{}

  @typedoc """
  What to send up for the VM's frames, in order: a frame's header, MWT's
  own (`:frame`), and its payload unmasked, the VM's text (`:payload`).
  The host's side gives none: its bytes go to the VM as they came.
  """
  @type part :: {:frame, binary()} | {:payload, binary()}

  @doc "A reader of `side`'s frames: the VM's (`:vm`, masked) or the host's; the log keeps `limit` bytes of its messages."
  @spec new(:vm | :host, non_neg_integer()) :: t()
  def new(side, limit) when side in [:vm, :host], do: %__MODULE__{side: side, limit: limit}

  @doc """
  The next bytes: `{:ok, parts, reader}`, or `{:broken, parts, rest,
  reader}` once they stop being frames this reads, `rest` being the bytes
  from there on, not read.
  """
  @spec feed(t(), binary()) :: {:ok, [part()], t()} | {:broken, [part()], binary(), t()}
  def feed(%__MODULE__{} = reader, data), do: step(%{reader | buffer: reader.buffer <> data}, [])

  @doc "What the log keeps of this side: its messages, one a line, up to the limit."
  @spec log(t()) :: Exchange.body()
  def log(%__MODULE__{} = reader) do
    %{
      data: IO.iodata_to_binary(reader.kept),
      bytes: reader.total,
      cut?: reader.cut?,
      note: "WebSocket messages, one a line"
    }
  end

  ## Frames

  defp step(%__MODULE__{frame: nil, buffer: buffer} = reader, out) do
    case header(buffer) do
      :more ->
        {:ok, Enum.reverse(out), reader}

      {:ok, fin, 0, opcode, masked?, length, key, rest}
      when opcode in @opcodes and masked? == (reader.side == :vm) and
             (opcode not in @control or (fin == 1 and length <= 125)) ->
        frame = %{fin: fin, opcode: opcode, left: length, key: key, offset: 0}
        out = if reader.side == :vm, do: [{:frame, written(fin, opcode, length)} | out], else: out
        payload(%{began(reader, frame) | frame: frame, buffer: rest}, out)

      _not_a_frame_read_here ->
        {:broken, Enum.reverse(out), buffer, %{reader | buffer: ""}}
    end
  end

  defp step(reader, out), do: payload(reader, out)

  defp payload(%__MODULE__{frame: frame, buffer: buffer} = reader, out) do
    take = min(frame.left, byte_size(buffer))
    <<chunk::binary-size(take), rest::binary>> = buffer
    text = if frame.key, do: unmask(chunk, frame.key, frame.offset), else: chunk
    out = if reader.side == :vm and take > 0, do: [{:payload, text} | out], else: out
    reader = keep(reader, frame, text)
    frame = %{frame | left: frame.left - take, offset: frame.offset + take}

    if frame.left == 0 do
      step(%{ended(reader, frame) | frame: nil, buffer: rest}, out)
    else
      {:ok, Enum.reverse(out), %{reader | frame: frame, buffer: rest}}
    end
  end

  defp header(<<fin::1, rsv::3, opcode::4, mask::1, length::7, rest::binary>>) do
    with {:ok, length, rest} <- extended(length, rest),
         {:ok, key, rest} <- key(mask, rest),
         do: {:ok, fin, rsv, opcode, mask == 1, length, key, rest}
  end

  defp header(_short), do: :more

  defp extended(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp extended(127, <<0::1, length::63, rest::binary>>), do: {:ok, length, rest}
  defp extended(length, rest) when length < 126, do: {:ok, length, rest}
  defp extended(127, <<1::1, _::bitstring>>), do: :error
  defp extended(_length, _short), do: :more

  defp key(1, <<key::binary-size(4), rest::binary>>), do: {:ok, key, rest}
  defp key(1, _short), do: :more
  defp key(0, rest), do: {:ok, nil, rest}

  # The header MWT writes for a VM frame: the same, masked with zeros.
  defp written(fin, opcode, length) do
    size =
      cond do
        length < 126 -> <<1::1, length::7>>
        length < 65_536 -> <<1::1, 126::7, length::16>>
        true -> <<1::1, 127::7, length::64>>
      end

    <<fin::1, 0::3, opcode::4>> <> size <> <<0, 0, 0, 0>>
  end

  defp unmask("", _key, _offset), do: ""

  defp unmask(chunk, key, offset) do
    shift = rem(offset, 4)
    <<head::binary-size(shift), tail::binary>> = key
    rotated = tail <> head
    stream = :binary.copy(rotated, div(byte_size(chunk), 4) + 1)
    :crypto.exor(chunk, binary_part(stream, 0, byte_size(chunk)))
  end

  ## Messages, for the log

  # A text or binary frame begins a message, a continuation goes on with
  # the one begun (or, with none, is counted as bytes); a control frame
  # comes between, apart.
  defp began(reader, %{opcode: opcode}) when opcode in @control, do: %{reader | control: ""}

  defp began(reader, %{opcode: 0}),
    do: %{reader | message: reader.message || %{opcode: 2, size: 0}}

  defp began(reader, %{opcode: opcode}), do: %{reader | message: %{opcode: opcode, size: 0}}

  # A data frame's text joins its message; a control frame's is kept whole
  # (at most 125 bytes) until it ends.
  defp keep(reader, %{opcode: opcode}, text) when opcode in @control,
    do: %{reader | control: reader.control <> text}

  defp keep(%{message: message} = reader, _frame, text) do
    reader = %{reader | message: %{message | size: message.size + byte_size(text)}}
    if message.opcode == 1, do: kept(reader, text), else: reader
  end

  defp ended(reader, %{opcode: 8}) do
    words =
      case reader.control do
        <<code::16, reason::binary>> -> String.trim("close #{code} #{reason}")
        _none -> "close"
      end

    %{kept(reader, "[#{words}]\n") | control: ""}
  end

  defp ended(reader, %{opcode: opcode}) when opcode in @control, do: %{reader | control: ""}

  defp ended(reader, %{fin: 1}) do
    case reader.message do
      %{opcode: 1} -> %{kept(reader, "\n") | message: nil}
      %{size: size} -> %{kept(reader, "[binary, #{size} bytes]\n") | message: nil}
      nil -> reader
    end
  end

  defp ended(reader, _not_last), do: reader

  defp kept(reader, text) do
    room = reader.limit - reader.kept_size
    total = reader.total + byte_size(text)

    cond do
      room <= 0 ->
        %{reader | total: total, cut?: reader.cut? or text != ""}

      byte_size(text) <= room ->
        %{
          reader
          | kept: [reader.kept, text],
            kept_size: reader.kept_size + byte_size(text),
            total: total
        }

      true ->
        %{
          reader
          | kept: [reader.kept, binary_part(text, 0, room)],
            kept_size: reader.limit,
            total: total,
            cut?: true
        }
    end
  end
end
