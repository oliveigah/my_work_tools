defmodule MWTClient.Sandbox.EgressNetworkTest do
  @moduledoc """
  A network grant's connections, read when MWT can: each request a card of
  its own under the grant, as a token grant's requests are, with *Allow
  similar*; one MWT can't read asked about as a connection after its first
  bytes, with the name it asked for and why, before anything is connected
  to.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxProxy

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("network-read")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, ca: ca}
  end

  # A proxy whose read requests go to `service`, a TLS server here.
  defp proxy(username, service) do
    test = self()

    options = [
      upstream: fn target ->
        send(test, {:read_target, target})
        :ssl.connect(~c"127.0.0.1", service, verify: :verify_none, active: false, mode: :binary)
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

  # An HTTPS service, answering each request on a connection with its path.
  defp https_service do
    test = self()
    leaf = CA.leaf(CA.new(), "svc.corp.example")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve_https(listen, test) end)
    port
  end

  defp serve_https(listen, test) do
    {:ok, socket} = :ssl.transport_accept(listen)
    spawn(fn -> with {:ok, socket} <- :ssl.handshake(socket), do: answer(socket, test, "") end)
    serve_https(listen, test)
  end

  defp answer(socket, test, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [_, path | _] = String.split(head, " ")
        send(test, {:service_got, head})
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(path)}\r\n\r\n#{path}")
        answer(socket, test, rest)

      [_] ->
        with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: answer(socket, test, buffer <> data)
    end
  end

  # A plain TCP service: it greets first when `greets?`, then echoes.
  defp tcp_service(greets?) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      send(test, :service_connected)
      if greets?, do: :gen_tcp.send(socket, "220 hello\r\n")

      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000) do
        :gen_tcp.send(socket, "pong:" <> data)
      end

      :gen_tcp.close(socket)
    end)

    port
  end

  defp network_grant(username, port, uses) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Corp",
        "purpose" => "The corp network",
        "destinations" => "127.0.0.1:#{port}"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  defp connect(proxy, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{target} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    socket
  end

  defp tls(proxy, port, ca) do
    {:ok, tls} = tls_connect(proxy, port, ca)
    tls
  end

  defp tls_connect(proxy, port, ca) do
    :ssl.connect(
      connect(proxy, "127.0.0.1:#{port}"),
      verify: :verify_peer,
      cacerts: [ca],
      server_name_indication: ~c"svc.corp.example",
      alpn_advertised_protocols: ["http/1.1"],
      active: false,
      mode: :binary
    )
  end

  defp waiting(username) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  defp get(path), do: "GET #{path} HTTP/1.1\r\nHost: svc.corp.example\r\n\r\n"

  describe "a service MWT reads" do
    test "each request is a card of its own, in full; no card for the connection", %{
      username: username,
      ca: ca
    } do
      service = https_service()
      grant = network_grant(username, service, :ask)
      tls = tls(proxy(username, service), service, ca)

      # The connection opened without a card.
      assert Sandbox.snapshot(username).waiting == []

      :ok = :ssl.send(tls, get("/api/v4/projects"))
      approval = waiting(username)
      assert approval.kind == :request
      assert approval.grant_id == grant.id
      # A port other than 443 is part of the host it names.
      assert approval.title == "GET svc.corp.example:#{service}/api/v4/projects"
      assert {"Through", "Corp"} in approval.facts
      refute_received {:service_got, _}

      :ok = Sandbox.decide(username, approval.id, :allow_once)
      assert SandboxProxy.read_answer(tls, :ssl) =~ "/api/v4/projects"
      assert_receive {:service_got, "GET /api/v4/projects " <> _}

      # The next, on the same connection, asks again; allowing similar
      # lets the same endpoint through from then on.
      :ok = :ssl.send(tls, get("/api/v4/projects?page=2"))
      approval = waiting(username)
      :ok = Sandbox.decide(username, approval.id, {:allow, :similar, 60})
      assert SandboxProxy.read_answer(tls, :ssl) =~ "200 OK"

      :ok = :ssl.send(tls, get("/api/v4/projects?page=3"))
      assert SandboxProxy.read_answer(tls, :ssl) =~ "200 OK"
      assert Sandbox.snapshot(username).waiting == []

      # Each one in the log, read, under the grant.
      read = Enum.filter(Sandbox.events(username), &(&1.outcome == :read))
      assert length(read) == 3
      assert Enum.all?(read, &(&1.grant_id == grant.id))
    end

    test "a request you deny is answered so, and never reaches the service", %{
      username: username,
      ca: ca
    } do
      service = https_service()
      network_grant(username, service, :ask)
      tls = tls(proxy(username, service), service, ca)

      :ok = :ssl.send(tls, get("/admin/delete-everything"))
      :ok = Sandbox.decide(username, waiting(username).id, :deny)

      response = SandboxProxy.read_answer(tls, :ssl)
      assert response =~ "HTTP/1.1 403"
      assert response =~ "mwt_denied_by_user"
      refute_received {:service_got, _}
    end

    test "with every use allowed, requests go without a card, read and logged", %{
      username: username,
      ca: ca
    } do
      service = https_service()
      grant = network_grant(username, service, :all)
      tls = tls(proxy(username, service), service, ca)

      :ok = :ssl.send(tls, get("/health"))
      assert SandboxProxy.read_answer(tls, :ssl) =~ "/health"
      assert Sandbox.snapshot(username).waiting == []

      assert Enum.any?(
               Sandbox.events(username),
               &(&1.outcome == :read and &1.grant_id == grant.id and &1.path == "/health")
             )
    end
  end

  describe "a connection MWT can't read" do
    test "is asked about after its first bytes, saying why, before anything is reached", %{
      username: username
    } do
      service = tcp_service(false)
      network_grant(username, service, :ask)
      socket = connect(proxy(username, https_service()), "127.0.0.1:#{service}")
      :ok = :gen_tcp.send(socket, "ping")

      approval = waiting(username)
      assert approval.kind == :connection
      assert {"Not read", "it isn't TLS"} in approval.facts
      refute_received :service_connected

      :ok = Sandbox.decide(username, approval.id, :allow_once)
      assert {:ok, "pong:ping"} = :gen_tcp.recv(socket, 0, 5_000)
    end

    test "a service that greets first is asked about by the client's silence, unreached", %{
      username: username
    } do
      service = tcp_service(true)
      network_grant(username, service, :ask)
      socket = connect(proxy(username, https_service()), "127.0.0.1:#{service}")

      approval = waiting(username)
      assert {"Not read", "the server speaks first"} in approval.facts
      refute_received :service_connected

      :ok = Sandbox.decide(username, approval.id, :allow_once)
      assert {:ok, "220 hello\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
    end

    test "a host on your list is asked about as a connection, with the name it asked for", %{
      username: username,
      ca: ca
    } do
      service = https_service()
      network_grant(username, service, :ask)
      :ok = Sandbox.reading_set(username, {:put, "svc.corp.example", false})
      proxy = proxy(username, service)

      client = Task.async(fn -> tls_connect(proxy, service, ca) end)
      approval = waiting(username)
      assert approval.title == "Connect to svc.corp.example (127.0.0.1:#{service})"
      assert {"Name asked for", "svc.corp.example"} in approval.facts

      assert {"Not read", "you set it as Not read (What MWT reads, Activity log)"} in approval.facts

      :ok = Sandbox.decide(username, approval.id, :deny)
      assert {:error, _closed} = Task.await(client)
      refute_received {:read_target, _}
    end
  end
end
