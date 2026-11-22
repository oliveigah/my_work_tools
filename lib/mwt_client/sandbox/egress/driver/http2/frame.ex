defmodule MWTClient.Sandbox.Egress.Driver.Http2.Frame do
  @moduledoc """
  HTTP/2 frames (RFC 9113 §4): read whole out of a stream of bytes, and
  written. Pure. Only the frame layer: what a frame means is
  `MWTClient.Sandbox.Egress.Driver.Http2`'s.

  A frame read is `{type, flags, stream, payload, size}`, `type` by its
  name (`:data`, `:headers`, …; a type RFC 9113 doesn't name is
  `{:unknown, number}`, which a peer ignores). Padding (`PADDED`) and the
  priority fields of `HEADERS` (`PRIORITY`) are taken off as frames are
  read, so a payload is what the frame carries; `size` is its payload as
  it came, padding included, which is what flow control counts.
  """

  import Bitwise

  @types %{
    0 => :data,
    1 => :headers,
    2 => :priority,
    3 => :rst_stream,
    4 => :settings,
    5 => :push_promise,
    6 => :ping,
    7 => :goaway,
    8 => :window_update,
    9 => :continuation
  }
  @numbers Map.new(@types, fn {number, name} -> {name, number} end)

  @end_stream 0x1
  @ack 0x1
  @end_headers 0x4
  @padded 0x8
  @priority 0x20

  @typedoc "A frame read: its type, flags, stream, payload (padding taken off), and size as it came."
  @type t :: {atom() | {:unknown, byte()}, byte(), non_neg_integer(), binary(), non_neg_integer()}

  @doc "What a client sends first, before its first frame."
  @spec preface() :: binary()
  def preface, do: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  @doc """
  The whole frames at the start of `buffer`, no larger than `most` bytes of
  payload each: `{:ok, frames, rest}`, or `{:error, reason}` for a frame
  too large or whose padding says more than it holds.
  """
  @spec split(binary(), pos_integer()) :: {:ok, [t()], binary()} | {:error, atom()}
  def split(buffer, most), do: split(buffer, most, [])

  defp split(<<length::24, _type, _flags, _r::1, _stream::31, _::binary>>, most, _acc)
       when length > most,
       do: {:error, :frame_size_error}

  defp split(
         <<length::24, type, flags, _r::1, stream::31, payload::binary-size(length),
           rest::binary>>,
         most,
         acc
       ) do
    type = Map.get(@types, type, {:unknown, type})

    case unpad(type, flags, payload) do
      {:ok, unpadded} -> split(rest, most, [{type, flags, stream, unpadded, length} | acc])
      :error -> {:error, :protocol_error}
    end
  end

  defp split(rest, _most, acc), do: {:ok, Enum.reverse(acc), rest}

  defp unpad(type, flags, payload) when type in [:data, :headers, :push_promise] do
    with {:ok, payload} <- strip_padding(flags, payload) do
      strip_priority(type, flags, payload)
    end
  end

  defp unpad(_type, _flags, payload), do: {:ok, payload}

  defp strip_padding(flags, <<padding, rest::binary>>) when (flags &&& @padded) != 0 do
    if padding <= byte_size(rest),
      do: {:ok, binary_part(rest, 0, byte_size(rest) - padding)},
      else: :error
  end

  defp strip_padding(flags, _payload) when (flags &&& @padded) != 0, do: :error
  defp strip_padding(_flags, payload), do: {:ok, payload}

  defp strip_priority(:headers, flags, <<_dependency::40, rest::binary>>)
       when (flags &&& @priority) != 0,
       do: {:ok, rest}

  defp strip_priority(:headers, flags, _payload) when (flags &&& @priority) != 0, do: :error
  defp strip_priority(_type, _flags, payload), do: {:ok, payload}

  @doc "A frame's bytes: its 9-byte header and its payload, unpadded."
  @spec encode(atom(), byte(), non_neg_integer(), iodata()) :: iodata()
  def encode(type, flags, stream, payload),
    do: [header(type, flags, stream, IO.iodata_length(payload)), payload]

  @doc "A frame's 9-byte header alone, for a payload of `length` bytes sent apart."
  @spec header(atom(), byte(), non_neg_integer(), non_neg_integer()) :: binary()
  def header(type, flags, stream, length),
    do: <<length::24, Map.fetch!(@numbers, type), flags, 0::1, stream::31>>

  @doc "Whether a frame's flags say its stream ends with it."
  @spec end_stream?(byte()) :: boolean()
  def end_stream?(flags), do: (flags &&& @end_stream) != 0

  @doc "Whether a header block's frame is its last (`END_HEADERS`)."
  @spec end_headers?(byte()) :: boolean()
  def end_headers?(flags), do: (flags &&& @end_headers) != 0

  @doc "Whether a `SETTINGS` or `PING` frame answers one (`ACK`)."
  @spec ack?(byte()) :: boolean()
  def ack?(flags), do: (flags &&& @ack) != 0

  @doc "The flags for a frame that ends its stream, or not, and ends its header block, or not."
  @spec flags(boolean(), boolean()) :: byte()
  def flags(end_stream?, end_headers?),
    do: if(end_stream?, do: @end_stream, else: 0) ||| if(end_headers?, do: @end_headers, else: 0)

  @doc "`SETTINGS` as `{id, value}` pairs, or `:error` for a payload not made of them."
  @spec settings(binary()) :: {:ok, [{non_neg_integer(), non_neg_integer()}]} | :error
  def settings(payload) when rem(byte_size(payload), 6) == 0,
    do: {:ok, for(<<id::16, value::32 <- payload>>, do: {id, value})}

  def settings(_payload), do: :error

  @doc "A `SETTINGS` frame's payload."
  @spec settings_payload([{non_neg_integer(), non_neg_integer()}]) :: binary()
  def settings_payload(pairs), do: for({id, value} <- pairs, into: "", do: <<id::16, value::32>>)

  @doc """
  A header block split into a `HEADERS` frame and as many `CONTINUATION`
  frames as `most` (the peer's largest frame) needs, as `{header, part}`
  pairs, so the parts can go apart from the framing.
  """
  @spec header_frames(non_neg_integer(), binary(), boolean(), pos_integer()) :: [
          {binary(), binary()}
        ]
  def header_frames(stream, block, end_stream?, most) do
    parts = chunks(block, most)
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, index} ->
      type = if index == 0, do: :headers, else: :continuation
      flags = flags(index == 0 and end_stream?, index == last)
      {header(type, flags, stream, byte_size(part)), part}
    end)
  end

  @doc "`data` in pieces of at most `most` bytes, at least one (empty for no data)."
  @spec chunks(binary(), pos_integer()) :: [binary()]
  def chunks(data, most) when byte_size(data) <= most, do: [data]

  def chunks(data, most) do
    <<part::binary-size(most), rest::binary>> = data
    [part | chunks(rest, most)]
  end
end
