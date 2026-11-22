defmodule MWTClient.Sandbox.Egress.Driver.Http1.Framing do
  @moduledoc """
  Where a message's body ends, read as its bytes stream (RFC 9112 6.3):
  after `Content-Length` bytes, after the last chunk of a chunked body and
  its trailers, or, for an answer that says neither, when the connection
  closes.

    * **A request** (`request/1`) that declares neither has no body. MWT
      judges a request by what it read, so it forwards that body and
      nothing past its end: bytes after it would be another request, which
      the host would carry out and MWT never judged.
    * **An answer** (`answer/3`) ends where its request and status say:
      at once for `HEAD`, `1xx`, `204` and `304`; else by its framing. One
      MWT can't frame (two lengths, a coding other than chunked) is read
      as running until the close, so it is passed on whole and its
      connection isn't kept (`MWTClient.Sandbox.Egress.Driver.Http1.Answer`).

  It only frames. The bytes it hands back are the body as the VM sent it,
  chunk framing included, for the host to read the same way, and each is
  handed back as it comes: an unfinished size line is kept only to be
  read once it is whole. Framing two parsers could read two ways is
  `:error`, as `MWTClient.Sandbox.Chunked` reads it: a size that isn't 1
  to 16 hex digits, a chunk not followed by CR LF, a size line or a
  trailer section longer than 8 KiB.

  For a request, the caller checks the head first (`MWTClient.Sandbox.Egress.Driver.Http1`'s
  `acceptable/5`): one numeric `Content-Length` or `Transfer-Encoding:
  chunked`, never both.
  """

  @size_line ~r/\A([0-9A-Fa-f]{1,16})(?:[ \t]*;[^\r\n]*)?\z/
  @line_limit 8 * 1024

  @typep phase :: :size | {:data, pos_integer()} | :crlf | :trailers
  @opaque t :: {:length, non_neg_integer()} | {:chunked, phase(), binary()} | :close

  @doc "The framing a request's headers declare."
  @spec request([{String.t(), String.t()}]) :: t()
  def request(headers) do
    case {List.keyfind(headers, "content-length", 0),
          List.keymember?(headers, "transfer-encoding", 0)} do
      {{_, length}, false} -> {:length, String.to_integer(length)}
      {nil, true} -> {:chunked, :size, ""}
      {nil, false} -> {:length, 0}
    end
  end

  @doc """
  The framing of the answer to a `method` request, from its `status` and
  headers (names in lower case).
  """
  @spec answer(String.t(), 100..599, [{String.t(), String.t()}]) :: t()
  def answer(method, status, headers) do
    codings = tokens(headers, "transfer-encoding")
    lengths = for({"content-length", value} <- headers, do: value) |> Enum.uniq()

    cond do
      method == "HEAD" or status in 100..199 or status in [204, 304] ->
        {:length, 0}

      codings == ["chunked"] ->
        {:chunked, :size, ""}

      codings != [] ->
        :close

      match?([_], lengths) and hd(lengths) =~ ~r/\A[0-9]{1,18}\z/ ->
        {:length, String.to_integer(hd(lengths))}

      true ->
        :close
    end
  end

  @doc "Whether the body runs until its connection closes: it says nothing of where it ends."
  @spec until_close?(t()) :: boolean()
  def until_close?(framing), do: framing == :close

  @doc """
  The body's next bytes: `{:more, data, framing}` when all of `data`
  belongs to the body and it goes on; `{:done, body, beyond}` once it
  ended, `body` being the start of `data` that belongs to it and `beyond`
  the rest; or `:error`.
  """
  @spec feed(t(), binary()) :: {:more, binary(), t()} | {:done, binary(), binary()} | :error
  def feed(:close, data), do: {:more, data, :close}

  def feed({:length, left}, data) when byte_size(data) < left,
    do: {:more, data, {:length, left - byte_size(data)}}

  def feed({:length, left}, data) do
    <<body::binary-size(^left), beyond::binary>> = data
    {:done, body, beyond}
  end

  def feed({:chunked, phase, pending}, data) do
    case chunked(phase, pending <> data, 0) do
      {:more, phase, pending} ->
        {:more, data, {:chunked, phase, pending}}

      # `pending` came in an earlier call: the end is counted in `data`.
      {:done, ends_at} ->
        at = ends_at - byte_size(pending)
        <<body::binary-size(^at), beyond::binary>> = data
        {:done, body, beyond}

      :error ->
        :error
    end
  end

  @doc "Whether the body has ended already, with nothing more to read for it."
  @spec done?(t()) :: boolean()
  def done?({:length, 0}), do: true
  def done?(_framing), do: false

  # Reads `buffer` from `at`: `{:more, phase, pending}`, the bytes of an
  # unfinished line kept to read with the next ones, or `{:done, ends_at}`.
  defp chunked(:size, buffer, at) do
    case :binary.match(buffer, "\r\n", scope: {at, byte_size(buffer) - at}) do
      {crlf, 2} ->
        case Regex.run(@size_line, binary_part(buffer, at, crlf - at)) do
          [_line, hex] ->
            case String.to_integer(hex, 16) do
              0 -> chunked(:trailers, buffer, crlf + 2)
              size -> chunked({:data, size}, buffer, crlf + 2)
            end

          nil ->
            :error
        end

      :nomatch ->
        rest(:size, buffer, at)
    end
  end

  defp chunked({:data, size}, buffer, at) do
    available = byte_size(buffer) - at

    if available < size,
      do: {:more, {:data, size - available}, ""},
      else: chunked(:crlf, buffer, at + size)
  end

  defp chunked(:crlf, buffer, at) do
    case binary_part(buffer, at, min(2, byte_size(buffer) - at)) do
      "\r\n" -> chunked(:size, buffer, at + 2)
      start when start in ["", "\r"] -> {:more, :crlf, start}
      _other -> :error
    end
  end

  # Trailer fields end with an empty line: CR LF at once when there are
  # none, CR LF CR LF after the last one.
  defp chunked(:trailers, buffer, at) do
    if binary_part(buffer, at, min(2, byte_size(buffer) - at)) == "\r\n" do
      {:done, at + 2}
    else
      case :binary.match(buffer, "\r\n\r\n", scope: {at, byte_size(buffer) - at}) do
        {found, 4} -> {:done, found + 4}
        :nomatch -> rest(:trailers, buffer, at)
      end
    end
  end

  defp tokens(headers, name) do
    for {^name, value} <- headers,
        token <- String.split(value, ","),
        token = token |> String.trim() |> String.downcase(),
        token != "",
        do: token
  end

  defp rest(phase, buffer, at) do
    pending = binary_part(buffer, at, byte_size(buffer) - at)
    if byte_size(pending) > @line_limit, do: :error, else: {:more, phase, pending}
  end
end
