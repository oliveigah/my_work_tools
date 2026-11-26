defmodule MWTClient.Sandbox.ExchangeTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Exchange

  defp sent(chunks), do: Enum.reduce(chunks, Exchange.capture(), &Exchange.capture(&2, &1))

  test "the request is kept as the VM sent it, its body as MWT read it" do
    request =
      Exchange.request(%{
        method: "POST",
        host: "api.github.com",
        path: "/repos/o/r/pulls",
        headers: [{"content-type", "application/json"}, {"content-length", "13"}],
        body: ~s({"title":"x"})
      })

    assert request.body == %{data: ~s({"title":"x"}), bytes: 13, cut?: false, note: nil}

    chunked =
      Exchange.request(%{
        method: "POST",
        host: "h",
        path: "/",
        headers: [{"transfer-encoding", "chunked"}],
        body: "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
      })

    assert chunked.body.data == "hello world"
    refute chunked.body.cut?
  end

  test "the response is read from what reached the VM, early hints and framing aside" do
    response =
      sent([
        "HTTP/1.1 103 Early Hints\r\nlink: </a.css>\r\n\r\n",
        "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\n",
        "transfer-encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n",
        "3\r\n:1}\r\n0\r\n\r\n"
      ])
      |> Exchange.response(nil)

    assert response.status == 201
    assert response.reason == "Created"
    assert {"content-type", "application/json"} in response.headers
    assert response.body.data == ~s({"a":1})
    refute response.body.cut?
    assert Exchange.readable(response.body, response.headers) == "{\n  \"a\": 1\n}"
  end

  test "gzip is undone, at most the limit of it, however small it came" do
    big = String.duplicate("a", Exchange.body_limit() * 4)
    gzipped = :zlib.gzip(big)

    response =
      sent([
        "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: #{byte_size(gzipped)}\r\n\r\n",
        gzipped
      ])
      |> Exchange.response(nil)

    assert byte_size(response.body.data) <= Exchange.body_limit() + 64 * 1024
    assert String.starts_with?(big, response.body.data)
    assert response.body.cut?

    small = sent(["HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\n\r\n", :zlib.gzip("hi")])
    assert Exchange.response(small, nil).body == %{data: "hi", bytes: 2, cut?: false, note: nil}
  end

  test "a long answer keeps its start, says it was cut and how long it said it was" do
    total = Exchange.body_limit() * 3
    head = "HTTP/1.1 200 OK\r\ncontent-length: #{total}\r\n\r\n"
    response = sent([head, :binary.copy("x", total)]) |> Exchange.response("closed early")

    assert byte_size(response.body.data) == Exchange.body_limit()
    assert response.body.cut?
    assert response.body.bytes == total
    assert response.note == "closed early"
  end

  test "an encoding MWT doesn't decode is not kept; bytes that aren't text are kept as bytes" do
    response =
      sent(["HTTP/1.1 200 OK\r\ncontent-encoding: br\r\ncontent-length: 3\r\n\r\n", <<1, 2, 3>>])
      |> Exchange.response(nil)

    assert response.body.data == nil
    assert response.body.note =~ "br-encoded"

    bytes = sent(["HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n", <<0xFF, 0xFE>>])
    response = Exchange.response(bytes, nil)
    assert Exchange.readable(response.body, response.headers) == :binary

    assert %{"response" => %{"body_base64" => "//4="}} =
             Exchange.to_json(%{request: request(), response: response})

    # Valid UTF-8 that is mostly control characters is bytes too.
    controls = %{data: <<0, 1, 2, 3>>, bytes: 4, cut?: false, note: nil}
    assert Exchange.readable(controls, []) == :binary
    assert Exchange.readable(%{controls | data: "a\tb\r\nc"}, []) == "a\tb\r\nc"
  end

  test "nothing sent is no response; what isn't HTTP says so" do
    assert Exchange.response(Exchange.capture(), nil) == nil

    assert %{status: nil, body: %{note: "Not readable as HTTP"}} =
             Exchange.response(sent(["garbage\r\n\r\n"]), nil)
  end

  test "MWT's own answer stands as the response" do
    answer = Exchange.mwt_answer(403, ~s({"code":"mwt_grant_off"}))
    assert answer.by_mwt?
    assert answer.reason == "Forbidden"

    assert %{"response" => %{"answered_by" => "MWT", "body" => %{"code" => "mwt_grant_off"}}} =
             Exchange.to_json(%{request: request(), response: answer})
  end

  test "redact passes every text through, the path, header values and both bodies" do
    exchange = %{
      request: %{request() | path: "/?t=SECRET", headers: [{"x", "SECRET"}]},
      response: Exchange.mwt_answer(200, "SECRET")
    }

    redacted = Exchange.redact(exchange, &String.replace(&1, "SECRET", "[gone]"))
    refute inspect(redacted) =~ "SECRET"
    assert redacted.request.path == "/?t=[gone]"
  end

  test "as JSON: a URL, headers as an object, a whole JSON body as JSON" do
    json =
      Exchange.to_json(%{
        request: %{
          request()
          | headers: [{"accept", "a"}, {"accept", "b"}, {"content-type", "application/json"}],
            body: %{data: ~s({"x":1}), bytes: 7, cut?: false, note: nil}
        },
        response: nil
      })

    assert json["request"]["url"] == "https://api.github.com/user"
    assert json["request"]["headers"]["accept"] == ["a", "b"]
    assert json["request"]["body"] == %{"x" => 1}
    assert json["response"] == nil
  end

  test "with nothing back, a note says why, kept through redact and in the JSON" do
    assert Exchange.new(request(), nil, nil) == %{request: request(), response: nil}

    exchange = Exchange.new(request(), nil, "Closed by MWT: nothing came for 300 s.")
    redacted = Exchange.redact(exchange, & &1)
    assert redacted.note == "Closed by MWT: nothing came for 300 s."
    assert Exchange.to_json(redacted)["note"] == "Closed by MWT: nothing came for 300 s."

    # A response says its own.
    answer = Exchange.mwt_answer(502, "{}")
    assert Exchange.new(request(), answer, "unused") == %{request: request(), response: answer}
  end

  defp request do
    Exchange.request(%{
      method: "GET",
      host: "api.github.com",
      path: "/user",
      headers: [],
      body: ""
    })
  end
end
