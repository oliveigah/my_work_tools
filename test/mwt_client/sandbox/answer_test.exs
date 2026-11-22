defmodule MWTClient.Sandbox.AnswerTest do
  @moduledoc """
  Where an answer MWT passes on ends, and whether its connection may carry
  the next request, however its bytes are split as they arrive: every
  byte passed on unchanged, nothing past the answer's end taken as its.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver.Http1.Answer

  # Feeds `pieces` in order: `{:done, passed, beyond, keep?}`, with all
  # that came after the answer's end; or `{:more, passed, answer}`.
  defp read(method, pieces), do: read(Answer.new(method), pieces, "")

  defp read(answer, [], passed), do: {:more, passed, answer}

  defp read(answer, [piece | rest], passed) do
    case Answer.feed(answer, piece) do
      {:more, bytes, answer} ->
        read(answer, rest, passed <> IO.iodata_to_binary(bytes))

      {:done, bytes, beyond, keep?} ->
        {:done, passed <> IO.iodata_to_binary(bytes), Enum.join([beyond | rest]), keep?}
    end
  end

  defp ways(bytes) do
    splits =
      for at <- 0..byte_size(bytes) do
        <<first::binary-size(^at), second::binary>> = bytes
        [first, second]
      end

    [[bytes], for(<<byte <- bytes>>, do: <<byte>>) | splits]
  end

  @next "HTTP/1.1 200 OK\r\n"

  test "an answer ends where its framing says, and its connection is kept" do
    answers = [
      {"GET", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"},
      {"GET", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"},
      {"GET",
       "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-T: 1\r\n\r\n"},
      {"GET", "HTTP/1.1 204 No Content\r\n\r\n"},
      {"GET", "HTTP/1.1 304 Not Modified\r\nContent-Length: 50\r\n\r\n"},
      {"HEAD", "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n"},
      {"GET",
       "HTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"},
      {"GET", "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nConnection: keep-alive\r\n\r\nok"}
    ]

    for {method, bytes} <- answers, pieces <- ways(bytes <> @next) do
      assert read(method, pieces) == {:done, bytes, @next, true}, inspect({method, pieces})
    end
  end

  test "an answer that closes its connection, or is HTTP/1.0, isn't kept" do
    for bytes <- [
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: Upgrade, Close\r\n\r\nok",
          "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"
        ] do
      assert read("GET", [bytes]) == {:done, bytes, "", false}
    end
  end

  test "an answer that says nothing of its end runs until the close, unkept" do
    for head <- [
          "HTTP/1.1 200 OK\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n",
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
          "not a head\r\n\r\n"
        ] do
      bytes = head <> "and all that follows"
      assert {:more, ^bytes, answer} = read("GET", [bytes])
      assert Answer.finish(answer) == {:ended, []}
    end

    # A head over 64 KiB is passed on as it is.
    big = "HTTP/1.1 200 OK\r\nX-Pad: " <> String.duplicate("a", 70_000)
    assert {:more, ^big, answer} = read("GET", [big])
    assert Answer.finish(answer) == {:ended, []}
  end

  test "upstream closing before the answer ended is a cut; before any byte, nothing came" do
    assert {:more, "", answer} = read("GET", [])
    refute Answer.started?(answer)
    assert Answer.finish(answer) == {:ended, ""}

    assert {:more, "", answer} = read("GET", ["HTTP/1.1 200"])
    assert Answer.started?(answer)
    assert Answer.finish(answer) == {:cut, "HTTP/1.1 200"}

    assert {:more, _passed, answer} =
             read("GET", ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel"])

    assert {:cut, []} = Answer.finish(answer)
  end
end
