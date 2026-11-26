defmodule MWTClient.Sandbox.EgressWebSocketTest do
  @moduledoc """
  A WebSocket on a connection MWT reads: its handshake judged as any
  request, then each side's messages kept in the log. The VM's frames go
  up masked with zeros, so what MWT looks through is their text, a value
  split across two frames included; the client's extensions offer is
  taken out, so no message comes compressed.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Driver.Http1.WebSocket
  alias MWTClient.Sandbox.Egress.Tcp

  @public "93.184.216.34:443"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("websocket")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, ca: ca, proxy: proxy(username, start_host())}
  end

  defp proxy(username, host) do
    options =
      [
        upstream: fn _target ->
          :ssl.connect(~c"127.0.0.1", host, verify: :verify_none, active: false, mode: :binary)
        end
      ] ++ MWTClient.SandboxProxy.client_waits()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, username, options) end)
    port
  end

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive(do: (:go -> Tcp.run(client, username, options))) end)
    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  # A WebSocket server: switches, then tells the test each byte that came
  # and answers each text frame with an unmasked one, "echo: " and its text.
  defp start_host do
    test = self()
    leaf = CA.leaf(CA.new(), "example.com")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket, 5_000)
      {:ok, head} = :ssl.recv(socket, 0, 5_000)
      send(test, {:host_head, head})

      :ssl.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
          "sec-websocket-accept: x\r\n\r\n"
      )

      relay(socket, test, "")
    end)

    port
  end

  defp relay(socket, test, seen) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} ->
        send(test, {:host_got, data})
        seen = seen <> data

        case seen do
          <<_::4, 1::4, 1::1, length::7, _key::binary-size(4), payload::binary-size(length),
            rest::binary>> ->
            :ssl.send(socket, <<0x81, byte_size("echo: " <> payload)>> <> "echo: " <> payload)
            relay(socket, test, rest)

          _more ->
            relay(socket, test, seen)
        end

      {:error, _closed} ->
        send(test, :host_closed)
    end
  end

  defp upgraded(proxy, ca) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{@public} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(
        socket,
        [
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"example.com",
          active: false,
          mode: :binary
        ],
        5_000
      )

    :ok =
      :ssl.send(
        tls,
        "GET /socket HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" <>
          "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n"
      )

    {:ok, "HTTP/1.1 101" <> _} = :ssl.recv(tls, 0, 5_000)
    tls
  end

  # A client frame, masked with a random key as a client's are.
  defp frame(fin, opcode, payload) do
    key = :crypto.strong_rand_bytes(4)
    stream = :binary.copy(key, div(byte_size(payload), 4) + 1)
    masked = :crypto.exor(payload, binary_part(stream, 0, byte_size(payload)))

    size =
      if byte_size(payload) < 126,
        do: <<1::1, byte_size(payload)::7>>,
        else: <<1::1, 126::7, byte_size(payload)::16>>

    <<fin::1, 0::3, opcode::4>> <> size <> key <> masked
  end

  defp exchange_of(username) do
    Enum.find_value(1..300, fn _ ->
      with %{id: id} <- Enum.find(Sandbox.events(username), &(&1.path == "/socket")),
           %{exchange: %{} = exchange} <- Sandbox.event(username, id) do
        exchange
      else
        _ -> Process.sleep(10) && nil
      end
    end)
  end

  defp host_bytes(acc \\ "") do
    receive do
      {:host_got, data} -> host_bytes(acc <> data)
    after
      300 -> acc
    end
  end

  test "each side's messages are kept, and the VM's frames go up as their text", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    tls = upgraded(proxy, ca)
    assert_receive {:host_head, head}
    refute head =~ ~r/sec-websocket-extensions/i
    assert head =~ ~r/upgrade: websocket/i

    :ok = :ssl.send(tls, frame(1, 1, "hello"))
    assert {:ok, <<0x81, 11, "echo: hello">>} = :ssl.recv(tls, 0, 5_000)

    # Masked with zeros: the text itself is on the wire.
    assert host_bytes() == <<0x81, 0x85, 0, 0, 0, 0, "hello">>

    :ok = :ssl.send(tls, frame(1, 8, <<1000::16, "bye">>))
    :ssl.close(tls)

    exchange = exchange_of(username)
    assert exchange.request.body.data == "hello\n[close 1000 bye]\n"
    assert exchange.response.body.data == "echo: hello\n"
    assert exchange.response.status == 101
  end

  @tag :capture_log
  test "a placeholder split across two frames of a message is found, and never goes", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_real_value_0123456789"
      })

    tls = upgraded(proxy, ca)
    half = div(byte_size(grant.placeholder), 2)
    <<first::binary-size(half), second::binary>> = grant.placeholder

    # Each half alone is nothing; with a frame header between them on the
    # wire, only a look at the message's text sees the whole.
    :ok = :ssl.send(tls, frame(0, 1, "token=" <> first))
    :ok = :ssl.send(tls, frame(1, 0, second))

    seen = host_bytes()
    refute seen =~ second
    assert %{rule: :credential_leak} = Sandbox.firewall(username).firewall.isolated
  end

  @tag :capture_log
  test "a host's message holding a value MWT holds is cut before any of it goes, and isolates", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    # The host's answer to the VM's text is "echo: " and the text: a value
    # MWT holds that the VM never sent whole.
    held = "echo: stand-in-secret-0123"

    {:ok, _grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Stripe",
        "purpose" => "Refunds",
        "hosts" => "api.stripe.com",
        "env" => "STRIPE_KEY",
        "value" => held
      })

    tls = upgraded(proxy, ca)
    :ok = :ssl.send(tls, frame(1, 1, "hello"))
    assert {:ok, <<0x81, 11, "echo: hello">>} = :ssl.recv(tls, 0, 5_000)

    :ok = :ssl.send(tls, frame(1, 1, "stand-in-secret-0123"))
    assert {:error, :closed} = :ssl.recv(tls, 0, 5_000)
    assert %{rule: :real_value} = Sandbox.firewall(username).firewall.isolated
  end

  describe "the reader" do
    test "unmasks the VM's frames whatever the offset a piece starts at, and writes zeros" do
      payload = String.duplicate("abcdefghij", 30)
      bytes = frame(1, 2, payload)

      # Fed a byte at a time, the payload comes out whole and in order.
      {parts, reader} =
        for <<byte <- bytes>>, reduce: {[], WebSocket.new(:vm, 1024)} do
          {parts, reader} ->
            {:ok, more, reader} = WebSocket.feed(reader, <<byte>>)
            {parts ++ more, reader}
        end

      assert [{:frame, <<0x82, 0xFE, 300::16, 0, 0, 0, 0>>} | payloads] = parts
      assert payloads |> Enum.map(fn {:payload, text} -> text end) |> Enum.join() == payload
      assert WebSocket.log(reader).data == "[binary, 300 bytes]\n"
    end

    test "says broken for bytes that aren't frames it reads, and keeps only up to the limit" do
      # An extension's bit set: RSV1.
      assert {:broken, [], <<0xC1, 0x80, 0, 0, 0, 0>>, _reader} =
               WebSocket.feed(WebSocket.new(:vm, 64), <<0xC1, 0x80, 0, 0, 0, 0>>)

      # A VM frame left unmasked.
      assert {:broken, [], _rest, _reader} =
               WebSocket.feed(WebSocket.new(:vm, 64), <<0x81, 2, "hi">>)

      {:ok, [], reader} = WebSocket.feed(WebSocket.new(:host, 4), <<0x81, 6, "abcdef">>)
      assert %{data: "abcd", bytes: 7, cut?: true} = WebSocket.log(reader)
    end
  end
end
