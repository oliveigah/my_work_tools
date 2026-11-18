defmodule MWTClient.Sandbox.EgressResponseTest do
  @moduledoc """
  The answer to a request MWT put a real value in, read as HTTP on its way
  back (`Egress.Response`), without sockets: every head scrubbed, a body
  quoting the value cut before any byte of it goes, however it is framed or
  encoded, and what can't be read refused.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Response
  alias MWTClient.Sandbox.Secrets

  @value "ghp_REAL_SECRET_VALUE_0123"
  @placeholder "ghp_mwtPLACEHOLDER0123456789"
  @basic Base.encode64("x-access-token:" <> @value)

  defp response(method \\ "GET") do
    echo = Secrets.new([{{:value, "GitHub"}, Secrets.forms(@value) ++ [@basic]}], 8)
    Response.new(method, echo, @placeholder)
  end

  # Feeds `chunks` in turn: everything that would reach the VM, and how it
  # ended (`:more` when the answer isn't over yet).
  defp run(response, chunks) do
    Enum.reduce_while(chunks, {[], response}, fn chunk, {out, response} ->
      case Response.feed(response, chunk) do
        {:more, bytes, response} -> {:cont, {[out, bytes], response}}
        {:done, bytes} -> {:halt, {[out, bytes], :done}}
        {:cut, reason, bytes} -> {:halt, {[out, bytes], {:cut, reason}}}
        {:refuse, message} -> {:halt, {out, {:refuse, message}}}
      end
    end)
    |> then(fn
      {out, %Response{}} -> {IO.iodata_to_binary(out), :more}
      {out, ending} -> {IO.iodata_to_binary(out), ending}
    end)
  end

  # Every way of cutting `data` in two.
  defp splits(data) do
    for at <- 1..(byte_size(data) - 1),
        do: [binary_part(data, 0, at), binary_part(data, at, byte_size(data) - at)]
  end

  defp head(lines),
    do: "HTTP/1.1 200 OK\r\n" <> Enum.map_join(lines, "", &(&1 <> "\r\n")) <> "\r\n"

  # A chunked body, decoded: what a client makes of MWT's chunks.
  defp dechunk(data, acc \\ "") do
    [line, rest] = :binary.split(data, "\r\n")
    size = String.to_integer(line, 16)

    if size == 0 do
      {acc, rest}
    else
      <<chunk::binary-size(size), "\r\n", more::binary>> = rest
      dechunk(more, acc <> chunk)
    end
  end

  describe "heads" do
    test "the value is replaced in every head, 1xx included (QA M1)" do
      answer =
        "HTTP/1.1 103 Early Hints\r\nlink: </a.css>; rel=preload\r\nx-early: token #{@value}\r\n\r\n" <>
          head(["x-echo: token #{@value}", "content-length: 2", "connection: close"]) <> "ok"

      for chunks <- [[answer] | splits(answer)] do
        {out, :done} = run(response(), chunks)
        refute out =~ @value
        assert out =~ "x-early: token #{@placeholder}"
        assert out =~ "x-echo: token #{@placeholder}"
        assert String.ends_with?(out, "\r\n\r\nok")
      end
    end

    test "a Basic credential's base64 is replaced too" do
      {out, :done} =
        run(response(), [head(["x-echo: Basic #{@basic}", "content-length: 0"])])

      refute out =~ @basic
      assert out =~ "x-echo: Basic #{@placeholder}"
    end

    test "a head over 64 KiB is refused, not passed on (QA M2)" do
      big = head(["x-pad: " <> String.duplicate("a", 70_000), "x-echo: #{@value}"])
      assert {"", {:refuse, message}} = run(response(), [big])
      assert message =~ "64 KiB"

      # Without its end yet: refused once it is too long to be one.
      assert {"", {:refuse, _}} =
               run(response(), ["HTTP/1.1 200 OK\r\nx: " <> String.duplicate("a", 70_000)])
    end

    test "after a head went, one that can't be read cuts the answer" do
      early = "HTTP/1.1 103 Early Hints\r\nlink: x\r\n\r\n"
      {out, {:cut, :unreadable}} = run(response(), [early <> "not a status line\r\n\r\n"])
      assert out == early
    end

    test "a status line or header MWT can't read is refused" do
      for broken <- [
            "HTTP/2 200\r\n\r\n",
            "HTTP/1.1 200 OK\r\nno colon\r\n\r\n",
            "HTTP/1.1 200 OK\r\nx-a: 1\r\n folded\r\n\r\n"
          ] do
        assert {"", {:refuse, _}} = run(response(), [broken]), inspect(broken)
      end
    end
  end

  describe "bodies" do
    test "a body quoting the value is cut before any byte of it goes, split anywhere (QA P1)" do
      body = ~s({"message":"Bad credentials","seen":"token #{@value}"})
      answer = head(["content-length: #{byte_size(body)}", "connection: close"]) <> body

      for chunks <- [[answer] | splits(answer)] do
        {out, ending} = run(response(), chunks)
        assert ending == {:cut, {:found, {:value, "GitHub"}}}, inspect(chunks)
        refute out =~ "token g", "the start of the value went: #{inspect(chunks)}"
      end
    end

    test "a body without the value comes through as it was, length and all" do
      body = String.duplicate("x", 10_000)
      answer = head(["content-length: #{byte_size(body)}"]) <> body
      assert {^answer, :done} = run(response(), [answer])

      # Bytes after the body aren't part of the answer: one request, one answer.
      assert {^answer, :done} = run(response(), [answer <> "HTTP/1.1 200 OK\r\n\r\nmore"])
    end

    test "a chunked body is written out again, a value split by its framing still found" do
      payload = ~s({"seen":"token #{@value}"})
      {left, right} = String.split_at(payload, 15)

      answer =
        head(["transfer-encoding: chunked"]) <>
          Integer.to_string(byte_size(left), 16) <>
          "\r\n" <>
          left <>
          "\r\n" <>
          Integer.to_string(byte_size(right), 16) <> "\r\n" <> right <> "\r\n0\r\n\r\n"

      for chunks <- [[answer] | splits(answer)] do
        {out, ending} = run(response(), chunks)
        assert ending == {:cut, {:found, {:value, "GitHub"}}}, inspect(chunks)
        refute out =~ "token g"
      end
    end

    test "a chunked body without the value decodes to what was sent; trailers are scrubbed" do
      answer =
        head(["transfer-encoding: chunked"]) <>
          "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nx-trailer: #{@value}\r\n\r\n"

      for chunks <- [[answer] | splits(answer)] do
        {out, :done} = run(response(), chunks)
        [_head, body] = String.split(out, "\r\n\r\n", parts: 2)
        assert {"hello world", trailers} = dechunk(body)
        assert trailers == "x-trailer: #{@placeholder}\r\n\r\n"
      end
    end

    test "chunked framing that doesn't parse cuts the answer" do
      {_out, {:cut, :unreadable}} =
        run(response(), [head(["transfer-encoding: chunked"]) <> "zz\r\n"])

      {_out, {:cut, :unreadable}} =
        run(response(), [head(["transfer-encoding: chunked"]) <> "2\r\nabXY"])
    end

    test "gzip and deflate are decoded for the look, and passed on as they came" do
      body = ~s({"seen":"token #{@value}"})

      for {encoding, packed} <- [{"gzip", :zlib.gzip(body)}, {"deflate", :zlib.compress(body)}] do
        answer =
          head(["content-encoding: #{encoding}", "content-length: #{byte_size(packed)}"]) <>
            packed

        {_out, ending} = run(response(), [answer])
        assert ending == {:cut, {:found, {:value, "GitHub"}}}, encoding
      end

      clean = :zlib.gzip(String.duplicate("nothing to see ", 1_000))
      answer = head(["content-encoding: gzip", "content-length: #{byte_size(clean)}"]) <> clean
      assert {^answer, :done} = run(response(), splits(answer) |> Enum.at(100))
    end

    test "an encoding MWT can't decode is refused before anything goes" do
      for encoding <- ["br", "zstd", "gzip, br"] do
        answer = head(["content-encoding: #{encoding}", "content-length: 3"]) <> "abc"
        assert {"", {:refuse, _}} = run(response(), [answer]), encoding
      end
    end

    test "a transfer coding besides chunked, or two lengths, is refused before anything goes" do
      assert {"", {:refuse, _}} = run(response(), [head(["transfer-encoding: gzip, chunked"])])

      assert {"", {:refuse, _}} =
               run(response(), [head(["content-length: 2", "content-length: 3"])])
    end

    test "a body MWT can't read after a 1xx went cuts the answer" do
      early = "HTTP/1.1 103 Early Hints\r\nlink: x\r\n\r\n"
      answer = early <> head(["content-encoding: br", "content-length: 3"]) <> "abc"
      assert {^early, {:cut, :unreadable}} = run(response(), [answer])
    end

    test "a body read up to the close lets what was held go at the end" do
      answer = head(["connection: close"]) <> "the end: ghp_RE"
      {out, :more} = run(response(), [answer])
      refute out =~ "ghp_RE"

      {:more, _, response} = Response.feed(response(), answer)
      assert {:done, held} = Response.finish(response)
      assert IO.iodata_to_binary(held) == "ghp_RE"
    end

    test "what is held goes when the stream pauses, and the rest is still looked for" do
      {:more, out, response} =
        Response.feed(response(), head(["connection: close"]) <> "x ghp_RE")

      refute IO.iodata_to_binary(out) =~ "ghp_RE"
      assert Response.held?(response)

      {held, response} = Response.release(response)
      assert IO.iodata_to_binary(held) == "ghp_RE"
      refute Response.held?(response)

      rest = binary_part(@value, 6, byte_size(@value) - 6)
      assert {:cut, {:found, {:value, "GitHub"}}, _} = Response.feed(response, rest)
    end

    test "a HEAD answer, a 204 and a 304 have no body" do
      assert {_, :done} = run(response("HEAD"), [head(["content-length: 100"])])
      assert {_, :done} = run(response(), ["HTTP/1.1 204 No Content\r\n\r\n"])

      assert {_, :done} =
               run(response(), ["HTTP/1.1 304 Not Modified\r\ncontent-length: 9\r\n\r\n"])
    end

    test "after 101 Switching Protocols the bytes are still looked through" do
      answer = "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n"
      {out, :more} = run(response(), [answer <> "frame one"])
      # The last "e" could start the Basic credential's base64: held, it goes
      # on the next bytes or a pause.
      assert out == answer <> "frame on"

      {_out, {:cut, {:found, _}}} = run(response(), [answer <> "echo " <> @value])
    end

    test "an answer that ends inside its head is refused; one that never began, closed" do
      {:more, [], cut_short} = Response.feed(response(), "HTTP/1.1 200 OK\r\nx-a")
      assert {:refuse, _} = Response.finish(cut_short)
      assert {:done, []} = Response.finish(response())
    end
  end
end
