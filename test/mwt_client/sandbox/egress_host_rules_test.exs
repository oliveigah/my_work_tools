defmodule MWTClient.Sandbox.EgressHostRulesTest do
  @moduledoc """
  A network grant's host list, the Internet's included: a host set to Ask
  has each request MWT reads held on a card of its own, and a connection
  MWT can't read asked about as one; Block refuses each; Auto lets each
  through while the grant itself asks each time. Hosts no entry names go
  as the grant's mode says.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxProxy

  @public "93.184.216.34:443"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("host-rules")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    host_ca = CA.new("example.com's CA")
    host = start_host(host_ca, "example.com")
    %{username: username, ca: ca, host_ca: host_ca.cert, proxy: proxy(username, host)}
  end

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

  # Over TLS, each request is answered with its path.
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
      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, data} <- :ssl.recv(socket, 0, 2_000) do
        send(test, {:host_got, data})
        [_, path | _] = String.split(data, " ")
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(path)}\r\n\r\n#{path}")
        _ = :ssl.recv(socket, 0, 2_000)
        :ssl.close(socket)
      end
    end)

    serve(listen, test)
  end

  defp tls(proxy, cacerts, alpn) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{@public} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    :ssl.connect(
      socket,
      [
        verify: :verify_peer,
        cacerts: cacerts,
        server_name_indication: ~c"example.com",
        active: false,
        mode: :binary,
        alpn_advertised_protocols: alpn
      ],
      5_000
    )
  end

  # TLS offering no protocol: what it carries decides how MWT reads it.
  defp bare_tls(proxy, ca) do
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

    tls
  end

  defp get(tls, path) do
    :ok = :ssl.send(tls, "GET #{path} HTTP/1.1\r\nHost: example.com\r\n\r\n")
    SandboxProxy.read_answer(tls, :ssl)
  end

  defp waiting(username) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  defp event(username, fun) do
    Enum.find_value(1..300, fn _ ->
      Enum.find(Sandbox.events(username), fun) || (Process.sleep(10) && nil)
    end)
  end

  test "a host set to Ask holds each request on a card, while the rest go as before", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "*.example.com", :ask})

    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    answer = Task.async(fn -> get(tls, "/held") end)

    approval = waiting(username)
    assert approval.kind == :request
    assert approval.grant_id == "internet"
    assert approval.host_entry == "*.example.com"
    assert {"Asks you", "*.example.com is set to Ask on Internet"} in approval.facts
    refute_received {:host_got, _}

    :ok = Sandbox.decide(username, approval.id, :allow_once)
    assert Task.await(answer) =~ "/held"
    assert_receive {:host_got, "GET /held " <> _}
  end

  test "Auto-approve on the grant doesn't cover a host set to Ask; Allow similar does", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    # The Internet starts auto-approved; the entry asks all the same.
    assert MWTClient.Sandbox.Grant.auto_approved?(
             Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "internet"))
           )

    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :ask})

    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    first = Task.async(fn -> get(tls, "/repeat") end)
    :ok = Sandbox.decide(username, waiting(username).id, {:allow, :similar, 60})
    assert Task.await(first) =~ "/repeat"

    # The same endpoint again goes without a card.
    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    assert get(tls, "/repeat") =~ "/repeat"
    assert Sandbox.snapshot(username).waiting == []
  end

  test "a blocked host refuses each request, saying so, and the host never hears of it", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :block})

    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    answer = get(tls, "/out")
    assert answer =~ "HTTP/1.1 403"
    assert answer =~ "mwt_host_blocked"
    refute_received {:host_got, _}

    assert %{outcome: :blocked, summary: "example.com is blocked on Internet (example.com)" <> _} =
             event(username, &(&1.outcome == :blocked))
  end

  test "Auto lets a host through while the Internet asks each time", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.set_mode(username, "internet", :ask)
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :auto})

    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    assert get(tls, "/free") =~ "/free"
    assert Sandbox.snapshot(username).waiting == []

    # Taken off, it asks as the Internet now does.
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:remove, "example.com"})
    {:ok, tls} = tls(proxy, [ca], ["http/1.1"])
    answer = Task.async(fn -> get(tls, "/asked") end)
    approval = waiting(username)
    assert approval.host_entry == nil
    :ok = Sandbox.decide(username, approval.id, :deny)
    assert Task.await(answer) =~ "HTTP/1.1 403"
  end

  test "a connection MWT can't read is asked about as one when its host is set to Ask", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :ask})

    # Offering only a protocol no driver speaks, it isn't read: the
    # connection is the card.
    handshake = Task.async(fn -> tls(proxy, [host_ca], ["imap"]) end)
    approval = waiting(username)
    assert approval.kind == :connection
    assert approval.title =~ "Connect to example.com"
    assert {"Asks you", "example.com is set to Ask on Internet"} in approval.facts
    refute_received {:tunnel_target, _}

    :ok = Sandbox.decide(username, approval.id, :allow_once)
    _ = Task.await(handshake)
    assert_receive {:tunnel_target, %{port: 443}}
  end

  test "a connection MWT can't read to a blocked host closes, logged", %{
    username: username,
    host_ca: host_ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :block})
    assert {:error, _closed} = tls(proxy, [host_ca], ["imap"])
    refute_received {:tunnel_target, _}

    assert %{outcome: :blocked, host: "example.com"} =
             event(username, &(&1.outcome == :blocked))
  end

  test "TLS carrying no HTTP to a blocked host closes, and nothing reaches it", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :block})

    # A database or a queue over TLS: MWT ends the TLS, reads no HTTP in it,
    # and holds the connection as one it can't read.
    tls = bare_tls(proxy, ca)
    :ok = :ssl.send(tls, "*1\r\n$4\r\nPING\r\n")
    assert {:error, _closed} = :ssl.recv(tls, 0, 5_000)
    refute_received {:read_target, _}
    refute_received {:host_got, _}

    assert %{outcome: :blocked, host: "example.com"} =
             event(username, &(&1.outcome == :blocked))
  end

  test "a request after an empty line is refused, never passed on as bytes", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :block})

    # Servers skip the empty line (RFC 9112 2.2) and serve what follows.
    tls = bare_tls(proxy, ca)
    :ok = :ssl.send(tls, "\r\nGET /blocked HTTP/1.1\r\nHost: example.com\r\n\r\n")
    assert SandboxProxy.read_answer(tls, :ssl) =~ "HTTP/1.1 400"
    refute_received {:read_target, _}
    refute_received {:host_got, _}
  end

  test "a network grant's form keeps its host list when saved", %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Corp",
        "purpose" => "The corp network",
        "destinations" => "*.corp.example:443"
      })

    {:ok, _} = Sandbox.host_rule_set(username, grant.id, {:put, "prod.corp.example", :ask})

    {:ok, edited} =
      Sandbox.update_grant(username, grant.id, %{
        "name" => "Corp VPN",
        "purpose" => "The corp network",
        "destinations" => "*.corp.example:443"
      })

    assert edited.name == "Corp VPN"
    assert edited.host_rules == [%{host: "prod.corp.example", action: :ask}]
  end

  test "only a network grant has a host list, and an entry is a host name", %{
    username: username
  } do
    assert {:error, "Only a network grant has a host list."} =
             Sandbox.host_rule_set(username, "commands", {:put, "example.com", :ask})

    assert {:error, "10.0.0.5 is an address" <> _} =
             Sandbox.host_rule_set(username, "internet", {:put, "10.0.0.5", :block})

    assert {:error, _} =
             Sandbox.host_rule_set(username, "internet", {:put, "example.com", :maybe})

    {:ok, grant} =
      Sandbox.host_rule_set(username, "internet", {:put, "https://API.Example.com/v1", :ask})

    assert grant.host_rules == [%{host: "api.example.com", action: :ask}]

    {:ok, grant} = Sandbox.host_rule_set(username, "internet", {:put, "api.example.com", :block})
    assert grant.host_rules == [%{host: "api.example.com", action: :block}]

    assert MWTClient.Sandbox.Instructions.usage(grant) =~
             "api.example.com: blocked, every request there refused"
  end
end
