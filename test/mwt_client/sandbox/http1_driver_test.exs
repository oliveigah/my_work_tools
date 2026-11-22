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

    assert [{:judge, %Request{} = request}] = actions

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
    {[{:judge, request}], http} = Http1.handle_data(:vm, head, start())

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
    {[{:judge, first}], http} = Http1.handle_data(:vm, get, start())
    {actions, http} = Http1.handle_verdict(first.id, {:allow, %{request: [], answer: []}}, http)
    assert [{:connect, _} | _] = actions
    refute sent(actions, :host) =~ "connection: close"

    {actions, http} =
      Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", http)

    assert {:done, ^first, _exchange} = Enum.find(actions, &match?({:done, _, _}, &1))
    refute :close in actions

    # The next goes on the same link: no new one.
    {[{:judge, second}], http} = Http1.handle_data(:vm, get, http)
    {actions, _http} = Http1.handle_verdict(second.id, {:allow, %{request: [], answer: []}}, http)
    refute Enum.any?(actions, &match?({:connect, _}, &1))
    assert sent(actions, :host) =~ "GET /a HTTP/1.1\r\n"
  end

  test "a refusal is MWT's own HTTP answer, logged with the request" do
    {[{:judge, request}], http} =
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
end
