defmodule MWTClient.Sandbox.EgressHttp2Test do
  @moduledoc """
  HTTP/2, read: offered only to a client that offers no HTTP/1.1 (gRPC's),
  each stream a request of its own, judged, logged and sent on MWT's own
  connection to the host; a value put in only in its carriers, and back to
  the VM as its placeholder; flow control kept on both connections.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxH2Host

  @public "93.184.216.34:443"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("http2")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    {_pid, host} = SandboxH2Host.start()
    %{username: username, ca: ca, proxy: proxy(username, host)}
  end

  defp proxy(username, host) do
    test = self()

    options = [
      upstream: fn target ->
        send(test, {:read_target, target})

        :ssl.connect(~c"127.0.0.1", host,
          verify: :verify_none,
          active: false,
          mode: :binary,
          alpn_advertised_protocols: target.alpn
        )
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

  defp tls(proxy, ca, alpn) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{@public} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    :ssl.connect(
      socket,
      [
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: ~c"example.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        alpn_advertised_protocols: alpn,
        active: false,
        mode: :binary
      ],
      5_000
    )
  end

  # An HTTP/2 client through the proxy, as a gRPC client is: offering only h2.
  defp client(proxy, ca) do
    {:ok, tls} = tls(proxy, ca, ["h2"])
    assert {:ok, "h2"} = :ssl.negotiated_protocol(tls)
    {:ok, conn} = Mint.HTTP2.initiate(:https, tls, "example.com", 443, mode: :passive)
    ready(conn)
  end

  # MWT's settings and its connection window read, as a client reads them
  # before it sends much.
  defp ready(conn) do
    if Mint.HTTP2.get_window_size(conn, :connection) > 65_535 do
      conn
    else
      {:ok, conn, []} = Mint.HTTP2.recv(conn, 0, 5_000)
      ready(conn)
    end
  end

  defp request(conn, method, path, headers \\ [], body \\ nil) do
    {:ok, conn, ref} = Mint.HTTP2.request(conn, method, path, headers, body)
    {conn, ref}
  end

  # Everything that came for `ref` until it is done.
  defp response(conn, ref, acc \\ %{status: nil, headers: [], body: ""}) do
    case Mint.HTTP2.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        {acc, done?} =
          Enum.reduce(responses, {acc, false}, fn
            {:status, ^ref, status}, {acc, done?} ->
              {%{acc | status: status}, done?}

            {:headers, ^ref, headers}, {acc, done?} ->
              {%{acc | headers: acc.headers ++ headers}, done?}

            {:data, ^ref, data}, {acc, done?} ->
              {%{acc | body: acc.body <> data}, done?}

            {:done, ^ref}, {acc, _done?} ->
              {acc, true}

            {:error, ^ref, reason}, {acc, _done?} ->
              {Map.put(acc, :error, reason), true}

            _other, state ->
              state
          end)

        if done?, do: {conn, acc}, else: response(conn, ref, acc)

      {:error, conn, reason, _responses} ->
        {conn, Map.put(acc, :error, reason)}
    end
  end

  defp event(username, fun) do
    Enum.find_value(1..300, fn _ ->
      Enum.find(Sandbox.events(username), fun) || (Process.sleep(10) && nil)
    end)
  end

  defp waiting(username, count) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        waiting when length(waiting) == count -> waiting
        _other -> Process.sleep(10) && nil
      end
    end)
  end

  test "a client offering only HTTP/2 is read: each request goes on, logged", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    conn = client(proxy, ca)
    {conn, ref} = request(conn, "GET", "/hello")
    {_conn, answer} = response(conn, ref)
    assert %{status: 200, body: "hello"} = answer

    assert_receive {:read_target, %{name: "example.com", alpn: ["h2"]}}

    assert %{outcome: :read, host: "example.com", method: "GET", path: "/hello", exchange_id: id} =
             event(username, &(&1.outcome == :read))

    assert is_binary(id)
  end

  # A host that never took up HTTP/2 and ignores ALPN, as many do: it
  # picks no protocol and answers whatever comes as HTTP/1.1 would.
  defp ignoring_alpn do
    leaf = CA.leaf(CA.new("example.com's CA"), "example.com")

    {:ok, listen} =
      :ssl.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}] ++ CA.ssl_options(leaf))

    {:ok, {_ip, port}} = :ssl.sockname(listen)

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket)

      # MWT closes the link once it sees no protocol was picked, before
      # its first bytes; a link kept would get this.
      with {:ok, _preface} <- :ssl.recv(socket, 0),
           do: :ssl.send(socket, "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n")

      Process.sleep(:infinity)
    end)

    port
  end

  test "a host that doesn't speak HTTP/2 fails the client's requests, saying so", %{
    username: username,
    ca: ca
  } do
    # One refuses the client's offer in TLS; one takes none of it, and
    # answers HTTP/2's first bytes as HTTP/1.1.
    {_pid, refusing} = SandboxH2Host.start("example.com", http_2?: false)

    for host <- [refusing, ignoring_alpn()] do
      conn = client(proxy(username, host), ca)
      {conn, ref} = request(conn, "GET", "/hello")
      {_conn, answer} = response(conn, ref)

      assert answer.status == 502
      assert answer.body =~ "doesn't speak HTTP/2, and the client offered nothing else"
    end
  end

  test "a client offering HTTP/1.1 too speaks HTTP/1.1 to MWT", %{ca: ca, proxy: proxy} do
    {:ok, tls} = tls(proxy, ca, ["h2", "http/1.1"])
    assert {:ok, "http/1.1"} = :ssl.negotiated_protocol(tls)
  end

  test "a stream held for you holds up only itself", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.set_mode(username, "internet", :ask)
    conn = client(proxy, ca)
    {conn, first} = request(conn, "GET", "/first")
    {conn, second} = request(conn, "GET", "/second")

    [one, two] = waiting(username, 2) |> Enum.sort_by(& &1.path)
    assert {one.path, two.path} == {"/first", "/second"}

    # The second, allowed first, goes first, on a stream id of MWT's own.
    :ok = Sandbox.decide(username, two.id, :allow_once)
    {conn, answer} = response(conn, second)
    assert answer.body == "/second"

    :ok = Sandbox.decide(username, one.id, :allow_once)
    {_conn, answer} = response(conn, first)
    assert answer.body == "/first"
  end

  test "a value goes in only in its carrier, and comes back as its placeholder", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Example",
        "purpose" => "The example API",
        "hosts" => "example.com",
        "env" => "EXAMPLE_TOKEN",
        "value" => "real_value_0123456789"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    auth = [{"authorization", "Bearer " <> grant.placeholder}]

    conn = client(proxy, ca)
    {conn, ref} = request(conn, "GET", "/auth", auth)
    {conn, answer} = response(conn, ref)
    assert answer.status == 200
    # The host got the real value; the VM sees its placeholder.
    assert {"x-auth", "Bearer " <> grant.placeholder} in answer.headers
    refute inspect(answer) =~ "real_value_0123456789"

    # A body quoting it is cut before the value goes.
    {conn, ref} = request(conn, "GET", "/echo-auth", auth)
    {_conn, answer} = response(conn, ref)
    refute answer.body =~ "real_value_0123456789"
  end

  test "a host the Internet blocks refuses a gRPC call in gRPC's words", %{
    username: username,
    ca: ca,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.limits_set(username, "internet", {:put, "example.com", true})
    conn = client(proxy, ca)

    {conn, ref} =
      request(
        conn,
        "POST",
        "/pkg.Service/Method",
        [{"content-type", "application/grpc"}],
        <<0, 0, 0, 0, 0>>
      )

    {_conn, answer} = response(conn, ref)
    assert answer.status == 200
    assert {"grpc-status", "7"} in answer.headers
    assert {_, message} = List.keyfind(answer.headers, "grpc-message", 0)
    assert message =~ "example.com is blocked on internet (example.com)"
  end

  test "flow control holds both ways: a large upload and a large answer", %{
    ca: ca,
    proxy: proxy
  } do
    conn = client(proxy, ca)
    body = String.duplicate("b", 300 * 1024)
    {conn, ref} = request(conn, "POST", "/size", [], body)
    {conn, answer} = response(conn, ref)
    assert answer.body == "#{300 * 1024}"

    {conn, ref} = request(conn, "GET", "/big")
    {_conn, answer} = response(conn, ref)
    assert byte_size(answer.body) == 2 * 1024 * 1024
  end
end
