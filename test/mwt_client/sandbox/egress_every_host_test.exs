defmodule MWTClient.Sandbox.EgressEveryHostTest do
  @moduledoc """
  MWT reads every connection to the Internet it can, not only a token
  grant's hosts: a host no grant lists is read, its requests logged with
  what they carried; one on your list, a client offering only HTTP/2, or
  reading switched off, is passed through as bytes, saying why; what
  isn't HTTP inside TLS goes on decrypted, looked through.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp

  @public "93.184.216.34:443"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("every-host")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()

    # The host's own server, with a certificate of its own CA: a client
    # that trusts only that CA can tell it from MWT.
    host_ca = CA.new("example.com's CA")
    host = start_host(host_ca, "example.com")
    proxy = proxy(username, host)
    %{username: username, ca: ca, host_ca: host_ca.cert, proxy: proxy}
  end

  # A proxy whose read requests and tunnels both go to `host`, here.
  defp proxy(username, host) do
    test = self()

    options = [
      upstream: fn target ->
        send(test, {:read_target, target})
        :ssl.connect(~c"127.0.0.1", host, verify: :verify_none, active: false, mode: :binary)
      end,
      upstream_tcp: fn target ->
        send(test, {:tunnel_target, target})
        :gen_tcp.connect(~c"127.0.0.1", host, [:binary, active: false])
      end
    ]

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

  # The host: over TLS, a request is answered with its path; any other
  # first bytes are echoed back as `echo:` and what came. Silent for 200
  # ms, it greets first, as an IMAP server does.
  defp start_host(ca, name) do
    test = self()
    leaf = CA.leaf(ca, name)

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen, test) end)
    port
  end

  defp serve(listen, test) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      with {:ok, socket} <- :ssl.handshake(socket, 5_000) do
        case :ssl.recv(socket, 0, 200) do
          {:ok, "GET " <> _ = data} ->
            [_, path | _] = String.split(data, " ")
            send(test, {:host_got, data})

            :ssl.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(path)}\r\n\r\n#{path}"
            )

          {:ok, data} ->
            send(test, {:host_got, data})
            :ssl.send(socket, "echo:" <> data)

          {:error, :timeout} ->
            :ssl.send(socket, "* OK greeting\r\n")
        end

        _ = :ssl.recv(socket, 0, 2_000)
        :ssl.close(socket)
      end
    end)

    serve(listen, test)
  end

  defp connect(proxy, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{target} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    socket
  end

  # TLS to example.com through the proxy, trusting only `cacerts`.
  defp tls(proxy, cacerts, alpn) do
    socket = connect(proxy, @public)

    :ssl.connect(
      socket,
      [
        verify: :verify_peer,
        cacerts: cacerts,
        server_name_indication: ~c"example.com",
        active: false,
        mode: :binary
      ] ++ if(alpn, do: [alpn_advertised_protocols: alpn], else: []),
      5_000
    )
  end

  defp event(username, fun) do
    Enum.find_value(1..300, fn _ ->
      Enum.find(Sandbox.events(username), fun) || (Process.sleep(10) && nil)
    end)
  end

  test "a host no grant lists is read: its request goes on, logged with what it carried", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    # The client gets MWT's certificate, not the host's.
    {:ok, tls} = tls(proxy, [ca], ["h2", "http/1.1"])
    :ok = :ssl.send(tls, "GET /readme HTTP/1.1\r\nHost: example.com\r\n\r\n")
    assert MWTClient.SandboxProxy.read_answer(tls, :ssl) =~ "200 OK"

    assert_receive {:read_target, %{ip: {93, 184, 216, 34}, port: 443, name: "example.com"}}
    assert_receive {:host_got, "GET /readme HTTP/1.1\r\n" <> _}

    assert %{outcome: :read, host: "example.com", path: "/readme", exchange_id: id} =
             event(username, &(&1.outcome == :read))

    assert is_binary(id)
  end

  test "a host on your list is passed through as bytes, the host's own TLS end to end", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    :ok = Sandbox.reading_set(username, {:put, "example.com", false})

    # Only the host's own CA is trusted, and the handshake still holds.
    {:ok, tls} = tls(proxy, [host_ca], ["http/1.1"])
    :ok = :ssl.send(tls, "GET /readme HTTP/1.1\r\nHost: example.com\r\n\r\n")
    assert MWTClient.SandboxProxy.read_answer(tls, :ssl) =~ "/readme"
    :ssl.close(tls)

    # The address, not the name: a client slower than `@client_first` (a
    # loaded machine) has MWT connect before its ClientHello names the host.
    assert_receive {:tunnel_target, %{ip: {93, 184, 216, 34}, port: 443}}
    refute_received {:read_target, _}

    assert %{
             outcome: :tunnel,
             summary: "Not read: you set it as Not read (What MWT reads, Proxy activity)"
           } =
             event(username, &(&1.outcome == :tunnel))
  end

  test "a client offering only HTTP/2 is passed through, saying why", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    # The host doesn't speak HTTP/2 here, so the handshake is all there is.
    _ = tls(proxy, [host_ca], ["h2"])
    # The address, not the name, as above.
    assert_receive {:tunnel_target, %{ip: {93, 184, 216, 34}, port: 443}}

    assert %{summary: "Not read: the client offered only HTTP/2, which MWT doesn't read yet"} =
             event(username, &(&1.outcome == :tunnel))
  end

  test "reading only token grants' hosts passes the rest through, as before", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    :ok = Sandbox.reading_set(username, {:default, :token_hosts})
    {:ok, tls} = tls(proxy, [host_ca], ["http/1.1"])
    :ssl.close(tls)

    assert %{summary: "Passed through"} = event(username, &(&1.outcome == :tunnel))
    refute_received {:read_target, _}

    # A host opted in is read even so.
    :ok = Sandbox.reading_set(username, {:put, "example.com", true})
    assert {:error, _refused} = tls(proxy, [host_ca], ["http/1.1"])

    :ok = Sandbox.reading_set(username, {:default, :every_host})
    assert Sandbox.reading(username).default == :every_host
  end

  test "what isn't HTTP inside TLS goes on decrypted, and is looked through", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    # A client asking for no protocol, speaking something else.
    {:ok, tls} = tls(proxy, [ca], nil)
    :ok = :ssl.send(tls, <<0, 1, "binary protocol">>)
    assert {:ok, "echo:" <> <<0, 1, "binary protocol">>} = :ssl.recv(tls, 0, 5_000)

    # To the host over TLS MWT started again, offering it no protocol.
    assert_receive {:read_target, %{name: "example.com", alpn: []}}

    assert %{summary: "Not read: not HTTP inside its TLS" <> _} =
             event(username, &(&1.outcome == :tunnel))
  end

  @tag :capture_log
  test "a placeholder in what goes on decrypted is caught, as in any tunnel", %{
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

    {:ok, tls} = tls(proxy, [ca], nil)
    :ok = :ssl.send(tls, <<0, 1>> <> grant.placeholder)
    refute_receive {:host_got, _}, 500
    assert %{rule: :credential_leak} = Sandbox.firewall(username).firewall.isolated
  end

  test "a host whose certificate this machine doesn't vouch for is not read, saying how to pass it",
       %{username: username, ca: ca} do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options = [
      upstream: fn _target ->
        {:error, {:tls_alert, {:unknown_ca, ~c"TLS client: generated CLIENT ALERT: Unknown CA"}}}
      end
    ]

    spawn_link(fn -> accept(listen, username, options) end)

    {:ok, tls} = tls(port, [ca], ["http/1.1"])
    :ok = :ssl.send(tls, "GET /readme HTTP/1.1\r\nHost: example.com\r\n\r\n")
    response = MWTClient.SandboxProxy.read_answer(tls, :ssl)
    assert response =~ "HTTP/1.1 502"
    assert response =~ "mwt_upstream_tls"
    assert response =~ "a CA this machine doesn't trust"

    assert %{outcome: :read_failed, host: "example.com", summary: summary} =
             event(username, &(&1.outcome == :read_failed))

    assert summary =~ "a CA this machine doesn't trust"
  end

  test "a server that greets first inside TLS is heard", %{ca: ca, proxy: proxy} do
    {:ok, tls} = tls(proxy, [ca], nil)
    assert {:ok, "* OK greeting\r\n"} = :ssl.recv(tls, 0, 5_000)
  end

  test "a client refusing MWT's certificate is logged as not read, and you can list the host", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    # A client with a CA of its own, as a pinned one, refuses MWT's.
    {:error, _refused} = tls(proxy, [host_ca], ["http/1.1"])

    assert %{outcome: :read_failed, host: "example.com"} =
             event(username, &(&1.outcome == :read_failed))

    refute_received {:read_target, _}

    :ok = Sandbox.reading_set(username, {:put, "example.com", false})
    assert Sandbox.reading(username).rules == [%{host: "example.com", read?: false}]

    # The next one goes through unread, and the client is happy.
    assert {:ok, _tls} = tls(proxy, [host_ca], ["http/1.1"])
  end
end
