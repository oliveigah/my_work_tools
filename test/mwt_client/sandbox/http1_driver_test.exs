defmodule MWTClient.Sandbox.Http1DriverTest do
  @moduledoc """
  The HTTP/1.1 driver alone, with no socket: bytes in, actions out
  (`MWTClient.Sandbox.Egress.Driver`). Nothing goes up before its
  verdict; the values the verdict names go in where it says, and come
  back to the VM as their placeholders; a kept link carries the next
  request.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver.Http1
  alias MWTClient.Sandbox.Egress.Request

  @ctx %{
    transport: :tcp,
    name: "api.example.com",
    ip: {93, 184, 216, 34},
    port: 443,
    under: "internet",
    tls?: true,
    alpn: "http/1.1",
    first: :vm,
    linked?: false,
    why: :every_host,
    limit: 65_536,
    started: 0,
    options: []
  }

  defp start do
    {[{:read, :vm, _}], http} = Http1.init(@ctx)
    http
  end

  defp sent(actions, side),
    do:
      for(
        {tag, ^side, bytes} <- actions,
        tag in [:send, :write],
        into: "",
        do: IO.iodata_to_binary(bytes)
      )

  test "a request is judged before any of it goes, read as the server reads it" do
    {actions, http} =
      Http1.handle_data(
        :vm,
        "POST /repos HTTP/1.1\r\nHost: api.example.com\r\ncontent-length: 2\r\n\r\n{}",
        start()
      )

    # The VM is still read while it is judged: a client that gives up
    # ends the request before it goes.
    assert [{:judge, %Request{} = request}, {:read, :vm, :infinity}] = actions

    assert %{operation: "POST", resource: "/repos", name: "api.example.com", under: "internet"} =
             request

    assert request.data.body == "{}"

    assert %{method: "POST", path: "/repos", body: "{}", host: "api.example.com"} =
             Http1.message(request)

    assert sent(actions, :host) == ""
    assert http.phase == :judging
  end

  test "the verdict's values go in where it says, and come back as their placeholders" do
    head = "GET /user HTTP/1.1\r\nHost: api.example.com\r\nauthorization: token mwt_ph\r\n\r\n"
    {[{:judge, request}, {:read, :vm, :infinity}], http} = Http1.handle_data(:vm, head, start())

    replace = %{
      request: [
        %{
          label: {:value, "GitHub"},
          from: "mwt_ph",
          to: "ghp_REAL_value",
          within: ["authorization"]
        }
      ],
      answer: [%{label: {:value, "GitHub"}, from: ["ghp_REAL_value"], to: "mwt_ph"}]
    }

    {actions, http} = Http1.handle_verdict(request.id, {:allow, replace}, http)

    # Alone on a link of its own, the value in its carrier, asking for an
    # answer it can read.
    assert {:connect, %{alpn: ["http/1.1"]}} = hd(actions)
    up = sent(actions, :host)
    assert up =~ "authorization: token ghp_REAL_value\r\n"
    assert up =~ "connection: close\r\n"
    assert up =~ "accept-encoding: identity\r\n"
    refute up =~ "mwt_ph"

    # The service quotes it in a head: the VM gets the placeholder.
    answer = "HTTP/1.1 200 OK\r\nx-echo: ghp_REAL_value\r\ncontent-length: 2\r\n\r\nok"
    {actions, _http} = Http1.handle_data(:host, answer, http)
    down = sent(actions, :vm)
    assert down =~ "x-echo: mwt_ph\r\n"
    refute down =~ "ghp_REAL_value"

    assert {:done, ^request, %{request: _, response: _}} =
             Enum.find(actions, &match?({:done, _, _}, &1))

    assert :close in actions
  end

  test "a request with nothing put in keeps its link for the next" do
    get = "GET /a HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
    {[{:judge, first}, {:read, :vm, :infinity}], http} = Http1.handle_data(:vm, get, start())
    {actions, http} = Http1.handle_verdict(first.id, {:allow, %{request: [], answer: []}}, http)
    assert [{:connect, _} | _] = actions
    refute sent(actions, :host) =~ "connection: close"

    {actions, http} =
      Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", http)

    assert {:done, ^first, _exchange} = Enum.find(actions, &match?({:done, _, _}, &1))
    refute :close in actions

    # The next goes on the same link: no new one.
    {[{:judge, second}, {:read, :vm, :infinity}], http} = Http1.handle_data(:vm, get, http)
    {actions, _http} = Http1.handle_verdict(second.id, {:allow, %{request: [], answer: []}}, http)
    refute Enum.any?(actions, &match?({:connect, _}, &1))
    assert sent(actions, :host) =~ "GET /a HTTP/1.1\r\n"
  end

  # Before, whatever the VM sent after a request with an Upgrade went up
  # unread, whether the host switched or not: requests no card showed.
  describe "a request asking to switch protocols" do
    @upgrade "GET /h HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: x\r\nConnection: keep-alive\r\n\r\n"
    @behind "DELETE /x HTTP/1.1\r\nHost: api.example.com\r\n\r\n"

    test "declined, what the VM sent after it is the next request, judged as any" do
      {[{:judge, request}, {:read, :vm, :infinity}], http} =
        Http1.handle_data(:vm, @upgrade, start())

      {actions, http} =
        Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)

      assert sent(actions, :host) =~ "GET /h HTTP/1.1\r\n"

      {actions, http} = Http1.handle_data(:vm, @behind, http)
      assert sent(actions, :host) == ""
      refute Enum.any?(actions, &match?({:judge, _}, &1))

      {actions, _http} =
        Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok", http)

      assert sent(actions, :vm) =~ "HTTP/1.1 200 OK"
      assert sent(actions, :host) == ""
      assert {:done, ^request, _exchange} = Enum.find(actions, &match?({:done, _, _}, &1))

      assert {:judge, %Request{operation: "DELETE"}} =
               Enum.find(actions, &match?({:judge, _}, &1))
    end

    test "switched, what the VM sends goes on as the new protocol's, after the 101" do
      {[{:judge, request}, {:read, :vm, :infinity}], http} =
        Http1.handle_data(:vm, @upgrade, start())

      {_actions, http} =
        Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)

      {actions, http} = Http1.handle_data(:vm, "early", http)
      assert sent(actions, :host) == ""

      {actions, http} =
        Http1.handle_data(:host, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: x\r\n\r\nhi", http)

      assert sent(actions, :vm) =~ "101 Switching Protocols\r\nUpgrade: x\r\n\r\nhi"
      assert sent(actions, :host) == "early"

      {actions, _http} = Http1.handle_data(:vm, "more", http)
      assert sent(actions, :host) == "more"
    end

    test "what the VM sent while it was judged waits for the answer too" do
      {[{:judge, request}, {:read, :vm, :infinity}], http} =
        Http1.handle_data(:vm, @upgrade, start())

      {_actions, http} = Http1.handle_data(:vm, @behind, http)

      {actions, http} =
        Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)

      assert sent(actions, :host) =~ "GET /h HTTP/1.1\r\n"
      refute sent(actions, :host) =~ "DELETE"

      {actions, _http} =
        Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok", http)

      assert sent(actions, :host) == ""

      assert {:judge, %Request{operation: "DELETE"}} =
               Enum.find(actions, &match?({:judge, _}, &1))
    end

    test "an informational answer first is not the switch" do
      {[{:judge, request}, {:read, :vm, :infinity}], http} =
        Http1.handle_data(:vm, @upgrade, start())

      {_actions, http} =
        Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)

      {_actions, http} = Http1.handle_data(:vm, @behind, http)

      {actions, http} = Http1.handle_data(:host, "HTTP/1.1 103 Early Hints\r\n\r\n", http)
      assert sent(actions, :host) == ""

      {actions, _http} =
        Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", http)

      assert sent(actions, :host) == ""

      assert {:judge, %Request{operation: "DELETE"}} =
               Enum.find(actions, &match?({:judge, _}, &1))
    end
  end

  test "a refusal is MWT's own HTTP answer, logged with the request" do
    {[{:judge, request}, {:read, :vm, :infinity}], http} =
      Http1.handle_data(:vm, "GET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n", start())

    json = ~s({"code":"mwt_denied_by_user","by":"MWT agent sandbox"})
    {actions, _http} = Http1.handle_verdict(request.id, {:deny, 403, json}, http)
    assert sent(actions, :vm) =~ "HTTP/1.1 403 Forbidden\r\n"
    assert sent(actions, :host) == ""

    assert {:done, ^request, %{response: %{status: 403}}} =
             Enum.find(actions, &match?({:done, _, _}, &1))
  end

  test "it reads TCP: inside TLS MWT ended by a method, as plain bytes by a whole request line" do
    assert Http1.detect("GET / HTTP/1.1\r\n", @ctx) == :yes
    assert Http1.detect("GET / HTTP/1.1\r\n", %{@ctx | transport: :udp}) == :no
    assert Http1.detect(<<0, 1, 2>>, @ctx) == :no

    plain = %{@ctx | tls?: false, first: :vm}
    assert Http1.detect("GET / HTTP/1.1\r\nhost: example.com\r\n", plain) == :yes
    assert Http1.detect("GET / HT", plain) == :more
    # A plain protocol that begins with a word in capitals isn't HTTP.
    assert Http1.detect("NICK agent\r\nUSER agent 0 * :agent\r\n", plain) == :no
    # A server that greets first.
    assert Http1.detect("HELO there\r\n", %{plain | first: :host}) == :no
  end

  test "a request after empty lines is claimed, and refused, never passed on unread" do
    # Servers skip empty lines before a request (RFC 9112 2.2): taken for
    # bytes, it would reach the host unjudged.
    assert Http1.detect("\r\nGET / HTTP/1.1\r\n", @ctx) == :yes
    assert Http1.detect("\r\n\r", @ctx) == :more
    plain = %{@ctx | tls?: false, first: :vm}
    assert Http1.detect("\r\n\r\nGET / HTTP/1.1\r\nhost: example.com\r\n", plain) == :yes

    {actions, _http} =
      Http1.handle_data(:vm, "\r\nGET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n", start())

    refute Enum.any?(actions, &match?({:judge, _}, &1))
    assert sent(actions, :vm) =~ "HTTP/1.1 400 Bad Request\r\n"
    assert sent(actions, :host) == ""
  end

  test "a client that closes while its request is judged ends it: nothing goes" do
    post = "POST /repos HTTP/1.1\r\nHost: api.example.com\r\ncontent-length: 2\r\n\r\n{}"
    {[{:judge, request}, {:read, :vm, :infinity}], http} = Http1.handle_data(:vm, post, start())

    # The call ends there, and its verdict never comes (`Driver`).
    {actions, _http} = Http1.handle_closed(:vm, :closed, http)
    assert {:done, ^request, _exchange} = Enum.find(actions, &match?({:done, _, _}, &1))
    assert :close in actions
    assert sent(actions, :host) == ""
  end

  test "what the VM sends while its request is judged goes behind it, framed, once allowed" do
    head = "POST /upload HTTP/1.1\r\nHost: api.example.com\r\ncontent-length: 100000\r\n\r\n"
    start = :binary.copy("a", 70_000)

    {[{:judge, request}, {:read, :vm, :infinity}], http} =
      Http1.handle_data(:vm, head <> start, start())

    # The rest of the body and the next request come while it waits: kept,
    # nothing sent, the VM read again.
    next = "GET /next HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
    {actions, http} = Http1.handle_data(:vm, :binary.copy("b", 30_000) <> next, http)
    assert actions == [{:read, :vm, :infinity}]

    {actions, http} = Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)
    up = sent(actions, :host)
    [_head, body] = String.split(up, "\r\n\r\n", parts: 2)
    assert body == start <> :binary.copy("b", 30_000)

    # Its answer ends it; the next request is read from what was kept.
    {actions, _http} =
      Http1.handle_data(:host, "HTTP/1.1 201 Created\r\ncontent-length: 0\r\n\r\n", http)

    assert [{:judge, second}] = for({:judge, _} = judge <- actions, do: judge)
    assert second.resource == "/next"
  end

  test "past a head's worth sent while it is judged, the VM waits" do
    head = "POST /upload HTTP/1.1\r\nHost: api.example.com\r\ncontent-length: 1000000\r\n\r\n"

    {[{:judge, _request}, _read], http} =
      Http1.handle_data(:vm, head <> :binary.copy("a", 70_000), start())

    {actions, _http} = Http1.handle_data(:vm, :binary.copy("b", 70_000), http)
    assert actions == []
  end
end
