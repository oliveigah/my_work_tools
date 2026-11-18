defmodule MWTClient.Sandbox.ChunkedTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Chunked

  doctest Chunked

  test "chunks are joined; extensions and trailers are skipped" do
    assert Chunked.decode("3\r\nabc\r\n2;name=value\r\nde\r\n0\r\nTrailer: x\r\n\r\n") ==
             {:whole, "abcde"}

    assert Chunked.decode("A\r\n0123456789\r\n0\r\n\r\n") == {:whole, "0123456789"}
    assert Chunked.decode("0003\r\nabc\r\n0\r\n\r\n") == {:whole, "abc"}
  end

  test "a body that stops early is cut, with what came" do
    assert Chunked.decode("") == {:cut, ""}
    assert Chunked.decode("3\r\nabc\r\n2") == {:cut, "abc"}
    assert Chunked.decode("3\r\nabc\r") == {:cut, "abc"}
    assert Chunked.decode("3\r\nab") == {:cut, "ab"}
  end

  test "framing two parsers could read two ways is an error, never a guess" do
    for body <- [
          "-3\r\nabc\r\n0\r\n\r\n",
          "+3\r\nabc\r\n0\r\n\r\n",
          "3\nabc\r\n0\r\n\r\n",
          "3\rx\r\nabc\r\n0\r\n\r\n",
          "3 junk\r\nabc\r\n0\r\n\r\n",
          "3\r\nabcd\r\n0\r\n\r\n",
          "\r\nabc\r\n0\r\n\r\n",
          String.duplicate("f", 17) <> "\r\nabc"
        ] do
      assert Chunked.decode(body) == :error, inspect(body)
    end
  end
end
