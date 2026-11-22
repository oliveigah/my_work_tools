defmodule MWTClient.Sandbox.EgressReadTest do
  @moduledoc """
  Where a request MWT reads goes, and what it skips no more: the address,
  port and way out the destination check approved (the threat model
  review's finding 4), a client refusing MWT's certificate logged, the
  firewall counting what it sends, and, with the Internet off, a token
  grant's host reached only for that grant.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp

  @mib 1024 * 1024

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("egress-read")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, ca: ca}
  end

  # A proxy whose read requests go to `upstream`, a TLS server here, and
  # which tells the test the target each one was sent to.
  defp proxy(username, upstream, options \\ []) do
    test = self()

    options =
      options ++
        [
          upstream: fn target ->
            send(test, {:target, target})

            :ssl.connect(~c"127.0.0.1", upstream,
              verify: :verify_none,
              active: false,
              mode: :binary
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

  # A TLS server that reads a request whole, body and all, tells the test
  # its head and how much body came, and answers `ok`. With `linger`, it
  # first waits that long for anything after the body, and tells the test
  # what came (`{:upstream_after, bytes}`).
  defp upstream(linger \\ nil) do
    test = self()
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen, test, linger) end)
    port
  end

  defp serve(listen, test, linger) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      with {:ok, socket} <- :ssl.handshake(socket),
           {:ok, head, body} <- read_request(socket, "") do
        send(test, {:upstream_got, head, body})
        if linger, do: send(test, {:upstream_after, after_body(socket, linger, "")})

        :ssl.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
        )

        :ssl.close(socket)
      end
    end)

    serve(listen, test, linger)
  end

  defp after_body(socket, linger, acc) do
    case :ssl.recv(socket, 0, linger) do
      {:ok, data} -> after_body(socket, linger, acc <> data)
      {:error, _timeout_or_closed} -> acc
    end
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        wanted =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        {:ok, head,
         if(head =~ ~r/transfer-encoding: chunked/i,
           do: chunked(socket, body),
           else: read_body(socket, body, wanted)
         )}

      [_] ->
        with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: read_request(socket, acc <> data)
    end
  end

  defp read_body(_socket, body, wanted) when byte_size(body) >= wanted,
    do: binary_part(body, 0, wanted)

  defp read_body(socket, body, wanted) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> read_body(socket, body <> data, wanted)
      {:error, _closed} -> body
    end
  end

  # A chunked body, framed and all, up to its last chunk.
  defp chunked(socket, body) do
    if String.ends_with?(body, "0\r\n\r\n") do
      body
    else
      case :ssl.recv(socket, 0, 5_000) do
        {:ok, data} -> chunked(socket, body <> data)
        {:error, _closed} -> body
      end
    end
  end

  # An answer, read as a client reads it: up to its end, the connection
  # left open when MWT keeps it.
  defp read_all(socket), do: MWTClient.SandboxProxy.read_answer(socket, :ssl)

  defp connect(proxy, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    {socket, reply}
  end

  defp tls(proxy, target, host, cacerts) do
    {socket, "HTTP/1.1 200" <> _} = connect(proxy, target)

    :ssl.connect(socket,
      verify: :verify_peer,
      cacerts: cacerts,
      server_name_indication: String.to_charlist(host),
      alpn_advertised_protocols: ["http/1.1"],
      active: false,
      mode: :binary
    )
  end

  defp https(proxy, target, ca, host, request) do
    {:ok, tls} = tls(proxy, target, host, [ca])
    :ok = :ssl.send(tls, request)
    read_all(tls)
  end

  defp github(username, uses \\ :all) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_real_value"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  defp event(username, fun) do
    Enum.find_value(1..200, fn _ ->
      Enum.find(Sandbox.events(username), fun) || (Process.sleep(10) && nil)
    end)
  end

  test "a read request goes to the address and port the VM asked for, under its TLS name", %{
    username: username,
    ca: ca
  } do
    _grant = github(username)
    proxy = proxy(username, upstream())

    response =
      https(
        proxy,
        "140.82.112.3:8443",
        ca,
        "api.github.com",
        "GET /meta HTTP/1.1\r\nHost: api.github.com:8443\r\n\r\n"
      )

    assert response =~ "HTTP/1.1 200 OK"

    # Where the doorman said, not the name resolved here, nor port 443.
    assert_receive {:target, %{ip: {140, 82, 112, 3}, port: 8443, name: "api.github.com"}}

    # The Host keeps its port, as the client wrote it.
    assert_receive {:upstream_got, head, ""}
    assert head <> "\r\n" =~ "\r\nhost: api.github.com:8443\r\n"

    # Logged as read, not as a tunnel, on its own port.
    assert %{outcome: :read, port: 8443} = event(username, &(&1.path == "/meta"))
  end

  test "a Host naming another port than the connection's is misdirected", %{
    username: username,
    ca: ca
  } do
    _grant = github(username)
    proxy = proxy(username, upstream())

    response =
      https(
        proxy,
        "140.82.112.3:8443",
        ca,
        "api.github.com",
        "GET /meta HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n"
      )

    assert response =~ "HTTP/1.1 421"
    refute_receive {:target, _}, 100

    # On 443, the name alone and with its port are the same Host.
    for host <- ["api.github.com", "api.github.com:443"] do
      response =
        https(
          proxy,
          "140.82.112.3:443",
          ca,
          "api.github.com",
          "GET /meta HTTP/1.1\r\nHost: #{host}\r\n\r\n"
        )

      assert response =~ "HTTP/1.1 200 OK"
    end
  end

  test "a client that refuses MWT's certificate is logged by name, and nothing goes out", %{
    username: username
  } do
    _grant = github(username)
    proxy = proxy(username, upstream())
    other = CA.new("Someone else's CA")

    assert {:error, _refused} = tls(proxy, "140.82.112.3:443", "api.github.com", [other.cert])

    assert %{outcome: :read_failed, host: "api.github.com", port: 443} =
             event = event(username, &(&1.summary =~ "MWT's certificate"))

    assert event.summary =~ "doesn't trust MWT's certificate authority"
    assert event.summary =~ "nothing went out"
    refute_receive {:target, _}, 100
  end

  test "the reasons a client's handshake fails, in words" do
    assert Tcp.handshake_failure({:tls_alert, {:unknown_ca, ~c"x"}}) =~
             "doesn't trust MWT's certificate authority"

    assert Tcp.handshake_failure({:tls_alert, {:bad_certificate, ~c"x"}}) =~
             "refused MWT's certificate"

    assert Tcp.handshake_failure({:tls_alert, {:no_application_protocol, ~c"x"}}) =~
             "no protocol MWT reads"

    assert Tcp.handshake_failure(:closed) =~ "closed the connection"
    assert Tcp.handshake_failure({:tls_alert, {:decode_error, ~c"x"}}) =~ "decode error"
  end

  test "with the Internet off, a token grant's host is reached only while that grant is on", %{
    username: username,
    ca: ca
  } do
    grant = github(username)
    {:ok, _} = Sandbox.turn_off(username, "internet")
    {:ok, _} = Sandbox.turn_off(username, grant.id)
    proxy = proxy(username, upstream())
    request = "GET /meta HTTP/1.1\r\nHost: api.github.com\r\n\r\n"

    response = https(proxy, "140.82.112.3:443", ca, "api.github.com", request)
    assert response =~ "HTTP/1.1 403"
    assert response =~ "mwt_grant_off"
    assert response =~ "mwt request #{grant.id}"
    refute_receive {:target, _}, 100

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    assert https(proxy, "140.82.112.3:443", ca, "api.github.com", request) =~ "HTTP/1.1 200 OK"
    assert_receive {:target, _}

    # With the Internet on, it isn't the grant's: a request with no
    # placeholder needs no grant then.
    {:ok, _} = Sandbox.turn_off(username, grant.id)
    {:ok, _} = Sandbox.turn_on(username, "internet", 60, :all)
    assert https(proxy, "140.82.112.3:443", ca, "api.github.com", request) =~ "HTTP/1.1 200 OK"
  end

  @tag :capture_log
  test "what read requests send counts toward the firewall's upload rule", %{
    username: username,
    ca: ca
  } do
    _grant = github(username)
    proxy = proxy(username, upstream())

    # Under the rule's 4 MiB: it goes, whole.
    body = String.duplicate("a", 3 * @mib)

    response =
      https(
        proxy,
        "140.82.112.3:443",
        ca,
        "api.github.com",
        "POST /gists HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
          body
      )

    assert response =~ "HTTP/1.1 200 OK"
    assert_receive {:upstream_got, _head, ^body}

    # The next 3 MiB to the same destination cross it: cut before all of
    # it goes, and the VM is isolated.
    {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])

    :ssl.send(
      tls,
      "POST /gists HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
        body
    )

    _ = read_all(tls)
    refute_receive {:upstream_got, _head, ^body}, 500
    assert %{rule: :large_upload} = Sandbox.firewall(username).firewall.isolated
  end

  defp waiting(username) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  describe "the body before the card (finding 3)" do
    test "a card waits for a body sent after a pause, and shows it", %{
      username: username,
      ca: ca
    } do
      grant = github(username, :ask)
      proxy = proxy(username, upstream())
      body = ~s({"title":"sent late"})
      {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])

      :ok =
        :ssl.send(
          tls,
          "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\nContent-Length: #{byte_size(body)}\r\n\r\n"
        )

      # The client waits for its body to be asked for, hears nothing, and
      # nothing is shown to you yet.
      assert {:error, :timeout} = :ssl.recv(tls, 0, 300)
      assert Sandbox.snapshot(username).waiting == []

      :ok = :ssl.send(tls, body)
      approval = waiting(username)
      assert approval.request.body == body
      refute Enum.any?(approval.facts, fn {name, _} -> name == "Body" end)

      :ok = Sandbox.decide(username, approval.id, :allow_once)
      assert read_all(tls) =~ "HTTP/1.1 200 OK"
      assert_receive {:upstream_got, _head, ^body}
    end

    test "a body that doesn't come in time is refused, and no card is made", %{
      username: username,
      ca: ca
    } do
      grant = github(username, :ask)
      proxy = proxy(username, upstream(), body_within: 200)
      {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])

      :ok =
        :ssl.send(
          tls,
          "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\nContent-Length: 10\r\n\r\nabc"
        )

      response = read_all(tls)
      assert response =~ "HTTP/1.1 408"
      assert response =~ "body didn't arrive"
      assert Sandbox.snapshot(username).waiting == []
      refute_receive {:target, _}, 100
    end

    test "nothing the VM sends past the body's declared end goes", %{
      username: username,
      ca: ca
    } do
      grant = github(username)
      proxy = proxy(username, upstream(300))
      next = "DELETE /repos/o/r HTTP/1.1\r\nHost: api.github.com\r\n\r\n"
      chunked = "5\r\nhello\r\n0\r\n\r\n"

      for {framing, body} <- [
            {"Content-Length: 5", "hello"},
            {"Transfer-Encoding: chunked", chunked}
          ] do
        {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])

        head =
          "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\n#{framing}\r\n\r\n"

        # In one piece with the body, and again after it.
        :ok = :ssl.send(tls, head <> body <> next)
        :ok = :ssl.send(tls, next)

        assert_receive {:upstream_got, got, ^body}, 2_000
        assert got =~ "authorization: token ghp_real_value"
        assert_receive {:upstream_after, ""}, 2_000
        assert read_all(tls) =~ "HTTP/1.1 200 OK"
      end
    end

    test "a request MWT couldn't describe offers nothing similar", %{
      username: username,
      ca: ca
    } do
      grant = github(username, :ask)
      proxy = proxy(username, upstream())
      body = "this isn't a GraphQL document"
      {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])

      :ok =
        :ssl.send(
          tls,
          "POST /graphql HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
        )

      approval = waiting(username)
      assert approval.title =~ "GraphQL unknown"
      assert approval.pattern == nil

      assert {:error, :bad_decision} =
               Sandbox.decide(username, approval.id, {:allow, :similar, 60})

      # Every use, or this one, still can be allowed.
      :ok = Sandbox.decide(username, approval.id, :allow_once)
      assert read_all(tls) =~ "HTTP/1.1 200 OK"
    end
  end

  # A TLS server here that answers each request on a connection in turn,
  # telling the test which connection each came on and its head. On a
  # connection that already answered one, `/drop` closes it without
  # answering, as a host does with an idle connection just as a request
  # comes; `/close`, or a request saying `Connection: close`, is answered
  # with `Connection: close`, and closed.
  defp keeping_upstream do
    test = self()
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> keep_serving(listen, test) end)
    port
  end

  defp keep_serving(listen, test) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      with {:ok, socket} <- :ssl.handshake(socket),
           do: answer_each(socket, test, make_ref(), 1, "")
    end)

    keep_serving(listen, test)
  end

  defp answer_each(socket, test, connection, nth, buffer) do
    with {:ok, head, body, rest} <- one_request(socket, buffer) do
      [_method, path | _] = String.split(head, " ")
      send(test, {:kept_upstream, connection, head, body})

      cond do
        path == "/drop" and nth > 1 ->
          :ssl.close(socket)

        path == "/close" or head =~ ~r/\r\nconnection: close/i ->
          :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
          :ssl.close(socket)

        true ->
          :ssl.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(path)}\r\n\r\n#{path}"
          )

          answer_each(socket, test, connection, nth + 1, rest)
      end
    end
  end

  # One request and what came after it, read by its framing.
  defp one_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        case Regex.run(~r/content-length: (\d+)/i, head) do
          [_, n] -> sized(socket, head, rest, String.to_integer(n))
          nil -> {:ok, head, "", rest}
        end

      [_partial] ->
        with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: one_request(socket, buffer <> data)
    end
  end

  defp sized(_socket, head, rest, n) when byte_size(rest) >= n,
    do: {:ok, head, binary_part(rest, 0, n), binary_part(rest, n, byte_size(rest) - n)}

  defp sized(socket, head, rest, n) do
    with {:ok, data} <- :ssl.recv(socket, 0, 5_000), do: sized(socket, head, rest <> data, n)
  end

  defp get(path, extra \\ ""),
    do: "GET #{path} HTTP/1.1\r\nHost: api.github.com\r\n#{extra}\r\n"

  defp closed?(tls), do: :ssl.recv(tls, 0, 1_000) in [{:error, :closed}, {:error, :einval}]

  describe "connections kept for the next request (step 3)" do
    setup %{username: username, ca: ca} do
      grant = github(username)
      proxy = proxy(username, keeping_upstream())
      {:ok, tls} = tls(proxy, "140.82.112.3:443", "api.github.com", [ca])
      %{grant: grant, tls: tls}
    end

    test "requests with nothing to judge alone share one connection to the host", %{
      username: username,
      tls: tls
    } do
      for path <- ["/a", "/b", "/c"] do
        :ok = :ssl.send(tls, get(path))
        assert read_all(tls) =~ "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n#{path}"
      end

      # One connection made for the three, each request as the VM sent it,
      # with HTTP/1.1's own keep-alive.
      assert_receive {:target, _}
      refute_received {:target, _}
      assert_receive {:kept_upstream, connection, a, ""}
      assert_receive {:kept_upstream, ^connection, _b, ""}
      assert_receive {:kept_upstream, ^connection, _c, ""}
      refute a =~ ~r/connection:/i

      # Each one logged as read, with its own exchange.
      events = Enum.filter(Sandbox.events(username), &(&1.outcome == :read))
      assert length(events) == 3
      assert events |> Enum.map(& &1.exchange_id) |> Enum.uniq() |> length() == 3
    end

    test "requests sent back to back are answered in order", %{tls: tls} do
      :ok = :ssl.send(tls, get("/a") <> get("/b"))
      assert read_all(tls) =~ "\r\n\r\n/a"
      assert read_all(tls) =~ "\r\n\r\n/b"
      assert_receive {:kept_upstream, connection, _a, ""}
      assert_receive {:kept_upstream, ^connection, _b, ""}
    end

    test "a request with a real value goes alone on a new connection, and ends the VM's", %{
      grant: grant,
      tls: tls
    } do
      :ok = :ssl.send(tls, get("/a"))
      assert read_all(tls) =~ "/a"
      assert_receive {:kept_upstream, first, _a, ""}

      :ok = :ssl.send(tls, get("/user", "Authorization: token #{grant.placeholder}\r\n"))
      assert read_all(tls) =~ "HTTP/1.1 200 OK"
      assert_receive {:kept_upstream, other, head, ""}
      assert other != first
      assert head =~ "authorization: token ghp_real_value"
      assert head =~ "connection: close"
      assert closed?(tls)
    end

    test "the host closing its end, saying so or not, has the next request go on a new one", %{
      tls: tls
    } do
      :ok = :ssl.send(tls, get("/close"))
      assert read_all(tls) =~ "connection: close"
      assert_receive {:kept_upstream, first, _close, ""}

      :ok = :ssl.send(tls, get("/a"))
      assert read_all(tls) =~ "/a"
      assert_receive {:kept_upstream, second, _a, ""}
      assert second != first
    end

    test "a kept connection the host closed as a request went: sent again, once, when that can't do it twice",
         %{tls: tls} do
      :ok = :ssl.send(tls, get("/a"))
      assert read_all(tls) =~ "/a"

      # Dropped on the kept connection, answered on a new one.
      :ok = :ssl.send(tls, get("/drop"))
      assert read_all(tls) =~ "\r\n\r\n/drop"
      assert_receive {:kept_upstream, first, _a, ""}
      assert_receive {:kept_upstream, ^first, _dropped, ""}
      assert_receive {:kept_upstream, retried, _drop, ""}
      assert retried != first

      # A POST could have been carried out: not sent again, said instead.
      :ok =
        :ssl.send(
          tls,
          "POST /drop HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: 1\r\n\r\nx"
        )

      response = read_all(tls)
      assert response =~ "HTTP/1.1 502"
      assert response =~ "closed the connection without answering"
      assert_receive {:kept_upstream, ^retried, _post, "x"}
      refute_receive {:kept_upstream, _, "POST" <> _, _}, 200
    end

    test "a client that says Connection: close gets its answer, and the connection ends", %{
      tls: tls
    } do
      :ok = :ssl.send(tls, get("/a", "Connection: close\r\n"))
      assert read_all(tls) =~ "HTTP/1.1 200 OK"
      assert_receive {:kept_upstream, _connection, head, ""}
      assert head =~ "connection: close"
      assert closed?(tls)
    end

    @tag :capture_log
    test "the firewall counts what all of a connection's requests send", %{
      username: username,
      tls: tls
    } do
      body = String.duplicate("a", 3 * @mib)

      post =
        "POST /gists HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n"

      :ok = :ssl.send(tls, post <> body)
      assert read_all(tls) =~ "HTTP/1.1 200 OK"

      :ok = :ssl.send(tls, post <> body)
      _ = read_all(tls)
      assert %{rule: :large_upload} = Sandbox.firewall(username).firewall.isolated
    end
  end

  describe "how much of each body the log keeps" do
    # The exchange of the request to `path`, once its connection ended.
    defp exchange_of(username, path) do
      Enum.find_value(1..300, fn _ ->
        with %{id: id} <- Enum.find(Sandbox.events(username), &(&1.path == path)),
             %{exchange: %{} = exchange} <- Sandbox.event(username, id) do
          exchange
        else
          _ -> Process.sleep(10) && nil
        end
      end)
    end

    defp post(proxy, ca, path, body) do
      https(
        proxy,
        "140.82.112.3:443",
        ca,
        "api.github.com",
        "POST #{path} HTTP/1.1\r\nHost: api.github.com\r\nConnection: close\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      )
    end

    test "is your setting: a body past it is cut, saying how long it was", %{
      username: username,
      ca: ca
    } do
      _grant = github(username)
      {:ok, _} = Sandbox.update_settings(username, %{"log_body_kib" => "1"})
      proxy = proxy(username, upstream())

      assert post(proxy, ca, "/small", String.duplicate("a", 3_000)) =~ "200 OK"
      exchange = exchange_of(username, "/small")
      assert byte_size(exchange.request.body.data) == 1024
      assert exchange.request.body.cut?
      assert exchange.request.body.bytes == 3_000
    end

    test "past what MWT read before deciding, what the VM sent after is kept too", %{
      username: username,
      ca: ca
    } do
      _grant = github(username)
      {:ok, _} = Sandbox.update_settings(username, %{"log_body_kib" => "256"})
      proxy = proxy(username, upstream())

      body =
        :crypto.strong_rand_bytes(100 * 1024) |> Base.encode64() |> binary_part(0, 100 * 1024)

      assert post(proxy, ca, "/large", body) =~ "200 OK"
      exchange = exchange_of(username, "/large")
      assert exchange.request.body.data == body
      refute exchange.request.body.cut?
    end

    test "at 0, only the heads", %{username: username, ca: ca} do
      _grant = github(username)
      {:ok, _} = Sandbox.update_settings(username, %{"log_body_kib" => "0"})
      proxy = proxy(username, upstream())

      assert post(proxy, ca, "/heads", "some text") =~ "200 OK"
      exchange = exchange_of(username, "/heads")
      assert exchange.request.body.data == ""
      assert exchange.request.body.cut?
      assert exchange.response.status == 200
      assert exchange.response.body.data == ""
    end
  end

  describe "the courier" do
    # A TLS server here with a certificate for `name` from its own CA, and
    # a roots file holding that CA.
    defp server(name) do
      ca = CA.new("Link test CA")
      leaf = CA.leaf(ca, name)

      {:ok, listen} =
        :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

      {:ok, {_, port}} = :ssl.sockname(listen)

      spawn_link(fn -> handshakes(listen) end)

      roots = Path.join(System.tmp_dir!(), "courier-#{System.unique_integer([:positive])}.pem")
      File.write!(roots, CA.pem(ca.cert))
      on_exit(fn -> File.rm(roots) end)
      {port, roots}
    end

    # Each connection's handshake, in the process that accepted it, which
    # owns it for as long as the test runs.
    defp handshakes(listen) do
      {:ok, socket} = :ssl.transport_accept(listen)
      _ = :ssl.handshake(socket, 5_000)
      handshakes(listen)
    end

    test "connects to the target's address and port, and trusts it only under its name" do
      {port, roots} = server("api.example.test")
      target = %{ip: {127, 0, 0, 1}, port: port, anchor: nil}

      assert {:ok, tls} =
               Tcp.connect_tls(Map.put(target, :name, "api.example.test"), roots)

      :ssl.close(tls)

      # The same server, asked for another name: its certificate doesn't
      # make it that host.
      assert {:error, {:tls_alert, _}} =
               Tcp.connect_tls(Map.put(target, :name, "other.example.test"), roots)
    end

    test "trusts only the roots it is given" do
      {port, _roots} = server("api.example.test")
      target = %{ip: {127, 0, 0, 1}, port: port, anchor: nil, name: "api.example.test"}

      assert {:error, {:tls_alert, {:unknown_ca, _}}} = Tcp.connect_tls(target)
    end
  end
end
