defmodule MWTClient.Sandbox.FramingTest do
  @moduledoc """
  Where a request's body ends, however its bytes are split as they arrive:
  each body is fed whole, and split at every byte, and must come back the
  same, with what follows it apart.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver.Http1.Framing

  # Feeds `pieces` in order: the body handed back, and all that came after
  # it, or `:error`; `{:more, body}` when the body hasn't ended.
  defp framed(headers, pieces), do: framed(Framing.request(headers), pieces, "")

  defp framed(_framing, [], body), do: {:more, body}

  defp framed(framing, [piece | rest], body) do
    case Framing.feed(framing, piece) do
      {:more, data, framing} -> framed(framing, rest, body <> data)
      {:done, data, beyond} -> {:done, body <> data, Enum.join([beyond | rest])}
      :error -> :error
    end
  end

  # Every way of splitting `bytes` in two.
  defp splits(bytes) do
    for at <- 0..byte_size(bytes) do
      <<first::binary-size(^at), second::binary>> = bytes
      [first, second]
    end
  end

  # One byte at a time, too.
  defp bytewise(bytes), do: for(<<byte <- bytes>>, do: <<byte>>)

  @chunked [{"transfer-encoding", "chunked"}]

  test "a chunked body ends after its last chunk and its trailers, however it is split" do
    bodies = [
      "5\r\nhello\r\n0\r\n\r\n",
      "5;ext=\"x\"\r\nhello\r\n0\r\n\r\n",
      "5\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\nOther: y\r\n\r\n",
      "0\r\n\r\n",
      "A\r\n0123456789\r\n0\r\n\r\n"
    ]

    for body <- bodies, next <- ["", "GET /next HTTP/1.1\r\n\r\n"] do
      bytes = body <> next

      for pieces <- [[bytes], bytewise(bytes) | splits(bytes)] do
        assert framed(@chunked, pieces) == {:done, body, next}, inspect({body, pieces})
      end
    end
  end

  test "a chunked body that hasn't ended asks for more, its bytes handed back as they come" do
    for bytes <- ["5\r\nhel", "5\r\nhello\r\n", "5\r\nhello\r\n0\r\nTrailer: x\r\n", "", "5"] do
      for pieces <- [[bytes], bytewise(bytes)] do
        assert framed(@chunked, pieces) == {:more, bytes}
      end
    end
  end

  test "chunked framing two parsers could read two ways is an error" do
    for bytes <- [
          "-5\r\nhello\r\n0\r\n\r\n",
          "+5\r\nhello\r\n0\r\n\r\n",
          "5\r\nhelloXX0\r\n\r\n",
          "5\nhello\r\n0\r\n\r\n",
          "12345678901234567\r\n",
          "zz\r\n",
          String.duplicate("a", 9 * 1024)
        ] do
      assert framed(@chunked, [bytes]) == :error, inspect(bytes)
    end
  end

  test "a Content-Length body ends after that many bytes; none declared, it has none" do
    for pieces <- [["hello", "GET /"], bytewise("helloGET /"), ["hel", "loGET /"]] do
      assert framed([{"content-length", "5"}], pieces) == {:done, "hello", "GET /"}
    end

    assert framed([{"content-length", "5"}], ["hel"]) == {:more, "hel"}
    assert framed([], ["GET /next"]) == {:done, "", "GET /next"}
    assert Framing.done?(Framing.request([]))
    assert Framing.done?(Framing.request([{"content-length", "0"}]))
    refute Framing.done?(Framing.request([{"content-length", "1"}]))
    refute Framing.done?(Framing.request(@chunked))
  end
end
