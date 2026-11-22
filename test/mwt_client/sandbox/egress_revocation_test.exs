defmodule MWTClient.Sandbox.EgressRevocationTest do
  @moduledoc """
  A grant that stops, by your switch, its time running out, or being
  removed, stops what it let through at once: the connections still open
  close (QA M5), an upgraded session (a WebSocket) included.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.Sandbox.Server

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("revoke")
    %{username: username}
  end

  ## A proxy as microsandbox reaches it, and the servers behind it

  defp proxy(username, options \\ []) do
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

  # A TCP server on this machine that tells the test what it receives, and
  # when the connection ends.
  defp tcp_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      relay_to(test, socket, :gen_tcp)
    end)

    port
  end

  defp relay_to(test, socket, mod) do
    case mod.recv(socket, 0, 10_000) do
      {:ok, data} ->
        send(test, {:server_got, data})
        relay_to(test, socket, mod)

      {:error, reason} ->
        send(test, {:server_closed, reason})
    end
  end

  defp network_grant(username, port, minutes \\ 60) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Local #{port}",
        "purpose" => "A test server",
        "destinations" => "127.0.0.1:#{port}"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, minutes, :all)
    grant
  end

  defp tunnel(proxy, port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 127.0.0.1:#{port} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.send(socket, "before")
    assert_receive {:server_got, "before"}, 5_000
    socket
  end

  # After the change, nothing more reaches the server, and both ends close.
  defp assert_cut(socket) do
    assert_receive {:server_closed, _reason}, 2_000
    _ = :gen_tcp.send(socket, "after")
    refute_receive {:server_got, "after"}, 200
    assert {:error, _closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  defp server(username), do: MWTClient.Vault.Store.whereis(Server, username)

  ## Network grants

  test "turning a network grant off closes the connections it let through", %{
    username: username
  } do
    port = tcp_server()
    grant = network_grant(username, port)
    socket = tunnel(proxy(username), port)

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    assert_cut(socket)
  end

  test "a network grant's time running out closes them too", %{username: username} do
    port = tcp_server()
    grant = network_grant(username, port, 5)
    socket = tunnel(proxy(username), port)

    # Its time ran out a second ago; its timer comes now.
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    :sys.replace_state(server(username), fn state ->
      grants =
        Enum.map(state.grants, fn
          %{id: id} = g when id == grant.id -> %{g | expires_at: past}
          other -> other
        end)

      %{state | grants: grants}
    end)

    send(server(username), {:expire_grant, grant.id, past})
    assert_cut(socket)
  end

  # QA L12: the connection looks at its grant itself when the time is up,
  # so a server too busy to take its timer doesn't keep it open.
  test "a grant's time running out closes them while the sandbox's server is busy", %{
    username: username
  } do
    port = tcp_server()
    grant = network_grant(username, port, 5)
    soon = DateTime.add(DateTime.utc_now(), 1, :second)

    :sys.replace_state(server(username), fn state ->
      grants =
        Enum.map(state.grants, fn
          %{id: id} = g when id == grant.id -> %{g | expires_at: soon}
          other -> other
        end)

      %{state | grants: grants}
    end)

    # The next message publishes the grant as it is now.
    _ = Sandbox.snapshot(username)
    socket = tunnel(proxy(username), port)
    :sys.suspend(server(username))

    try do
      assert_receive {:server_closed, _reason}, 3_000
      assert {:error, _closed} = :gen_tcp.recv(socket, 0, 1_000)
    after
      :sys.resume(server(username))
    end
  end

  test "removing a network grant closes them", %{username: username} do
    port = tcp_server()
    grant = network_grant(username, port)
    socket = tunnel(proxy(username), port)

    :ok = Sandbox.delete_grant(username, grant.id)
    assert_cut(socket)
  end

  test "a connection to another grant stays open", %{username: username} do
    first = tcp_server()
    other = tcp_server()
    grant = network_grant(username, first)
    _ = network_grant(username, other)
    net = proxy(username)

    cut = tunnel(net, first)
    {:ok, kept} = :gen_tcp.connect(~c"127.0.0.1", net, [:binary, active: false])
    :ok = :gen_tcp.send(kept, "CONNECT 127.0.0.1:#{other} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(kept, 0, 5_000)

    {:ok, _} = Sandbox.turn_off(username, grant.id)
    assert_cut(cut)

    :ok = :gen_tcp.send(kept, "still")
    assert_receive {:server_got, "still"}, 2_000
  end

  ## Token grants: an upgraded session

  # An upstream that switches protocols, then tells the test what comes and
  # sends it back.
  defp websocket_upstream do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket)
      {:ok, head} = :ssl.recv(socket, 0, 5_000)
      send(test, {:upstream_head, head})

      :ssl.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n\r\n"
      )

      relay_to(test, socket, :ssl)
    end)

    fn _host ->
      :ssl.connect(~c"127.0.0.1", port, verify: :verify_none, active: false, mode: :binary)
    end
  end

  test "turning a token grant off cuts the upgraded session it let through", %{
    username: username
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_REAL_VALUE_FOR_A_SOCKET_0123456789"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
    net = proxy(username, upstream: websocket_upstream())
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", net, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: ~c"api.github.com",
        active: false,
        mode: :binary
      )

    :ok =
      :ssl.send(
        tls,
        "GET /socket HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: Bearer #{grant.placeholder}\r\n" <>
          "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
      )

    assert_receive {:upstream_head, _head}, 5_000
    assert {:ok, "HTTP/1.1 101" <> _} = :ssl.recv(tls, 0, 5_000)
    :ok = :ssl.send(tls, "frame one")
    assert_receive {:server_got, "frame one"}, 5_000

    {:ok, _} = Sandbox.turn_off(username, grant.id)

    assert_receive {:server_closed, _reason}, 2_000
    _ = :ssl.send(tls, "frame two")
    refute_receive {:server_got, "frame two"}, 200
    assert {:error, _closed} = :ssl.recv(tls, 0, 2_000)
  end
end
