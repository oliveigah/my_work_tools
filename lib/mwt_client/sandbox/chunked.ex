defmodule MWTClient.Sandbox.Chunked do
  @moduledoc """
  Reads a chunked HTTP body (`Transfer-Encoding: chunked`, RFC 9112 7.1) as
  the host it goes to reads it, so what an approval shows is what the host
  acts on.

  Each chunk is a size in hex, an optional extension after `;`, CR LF, that
  many bytes, CR LF; a size of zero ends the body. Extensions mean nothing
  to the data and are skipped, as HTTP says: text in one is never read as
  the body. MWT holds only the start of a body, so a body may stop mid-way;
  that is `{:cut, data}`, with the data up to there. Framing two parsers
  could read two ways (a negative or signed size, a bare CR or LF, a chunk
  not followed by CR LF, a size longer than 16 digits) is `:error`: MWT
  shows the bytes as they came instead of guessing what the host makes of
  them.
  """

  @size_line ~r/\A([0-9A-Fa-f]{1,16})(?:[ \t]*;[^\r\n]*)?\z/
  @size_start ~r/\A[0-9A-Fa-f]{0,16}(?:[ \t]*(?:;[^\r\n]*)?)?\z/

  @doc """
  The data of a chunked body: `{:whole, data}` up to its last chunk,
  `{:cut, data}` when the bytes stop before it, or `:error` when its
  framing isn't one MWT reads the way a host would.

      iex> MWTClient.Sandbox.Chunked.decode("4;x=\\"9 lies\\"\\r\\nWiki\\r\\n0\\r\\n\\r\\n")
      {:whole, "Wiki"}

      iex> MWTClient.Sandbox.Chunked.decode("4\\r\\nWi")
      {:cut, "Wi"}

      iex> MWTClient.Sandbox.Chunked.decode("-4\\r\\nWiki\\r\\n0\\r\\n\\r\\n")
      :error
  """
  @spec decode(binary()) :: {:whole, binary()} | {:cut, binary()} | :error
  def decode(body), do: chunks(body, [])

  defp chunks(data, acc) do
    case :binary.split(data, "\r\n") do
      [line, rest] ->
        case Regex.run(@size_line, line) do
          [_line, hex] -> chunk(String.to_integer(hex, 16), rest, acc)
          nil -> :error
        end

      # The bytes stop inside a size line: cut, if it could still be one.
      [partial] ->
        if Regex.match?(@size_start, partial), do: {:cut, done(acc)}, else: :error
    end
  end

  defp chunk(0, _trailers, acc), do: {:whole, done(acc)}

  defp chunk(size, rest, acc) do
    case rest do
      <<data::binary-size(^size), "\r\n", rest::binary>> ->
        chunks(rest, [data | acc])

      <<_data::binary-size(^size), _not_crlf::binary-size(2), _rest::binary>> ->
        :error

      <<data::binary-size(^size), _part_of_crlf::binary>> ->
        {:cut, done([data | acc])}

      partial ->
        {:cut, done([partial | acc])}
    end
  end

  defp done(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
