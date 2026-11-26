defmodule MWTClient.Sandbox.EgressLeaksTest do
  @moduledoc """
  The real value through the proxy end to end, over TCP and TLS, the way
  the QA pass of 2026-11-16 went after it (its probes are named in each
  test): it goes only in a carrier, never comes back however the service
  quotes it, and is never let out when the VM holds it. Placeholders where
  their grant doesn't go are refused wherever MWT reads them.

  The upstream answers by the path it is asked for, and tells the test
  everything it received.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp

  @real "ghp_REAL_SECRET_VALUE_0123"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("leaks")
    upstream = start_upstream(self())
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options =
      [
        upstream: fn _host ->
          :ssl.connect(~c"127.0.0.1", upstream,
            verify: :verify_none,
            active: false,
            mode: :binary
          )
        end
      ] ++ MWTClient.SandboxProxy.client_waits()

    spawn_link(fn -> accept(listen, username, options) end)
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, proxy: port, ca: ca}
  end

  ## Harness

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive do: (:go -> Tcp.run(client, username, options)) end)
    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  defp start_upstream(test) do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen, test) end)
    port
  end

  defp serve(listen, test) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      got = read_quiet(socket, "")
      send(test, {:upstream_got, got})
      [_, path] = Regex.run(~r/\A[A-Z]+ ([^ ]+) /, got) || [nil, "/"]
      [_, auth] = Regex.run(~r/authorization: ([^\r]*)/i, got) || [nil, "none"]
      :ssl.send(socket, answer(path, auth))
      :ssl.close(socket)
    end)

    serve(listen, test)
  end

  # How the service quotes what it was sent, by the path asked for.
  defp answer("/echo-body" <> _, auth) do
    body = ~s({"message":"Bad credentials","seen":"#{auth}"})

    "HTTP/1.1 401 Unauthorized\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
  end

  defp answer("/early" <> _, auth) do
    "HTTP/1.1 103 Early Hints\r\nlink: </a.css>; rel=preload\r\n\r\n" <>
      "HTTP/1.1 200 OK\r\nx-echo: #{auth}\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
  end

  defp answer("/big" <> _, auth) do
    "HTTP/1.1 200 OK\r\nx-pad: #{String.duplicate("a", 70_000)}\r\nx-echo: #{auth}\r\n" <>
      "content-length: 2\r\nconnection: close\r\n\r\nok"
  end

  defp answer("/gzip" <> _, auth) do
    body = :zlib.gzip(~s({"seen":"#{auth}"}))

    "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end

  defp answer(_path, auth) do
    "HTTP/1.1 200 OK\r\nx-echo: #{auth}\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
  end

  # The head, then the body its Content-Length says, or until quiet; what
  # arrived when the proxy cut the connection short.
  defp read_quiet(socket, acc) do
    wanted =
      with [head, _body] <- :binary.split(acc, "\r\n\r\n"),
           [_, length] <- Regex.run(~r/content-length: ([0-9]+)/i, head) do
        byte_size(head) + 4 + String.to_integer(length)
      else
        _ -> nil
      end

    cond do
      wanted && byte_size(acc) >= wanted ->
        acc

      true ->
        case :ssl.recv(socket, 0, if(acc == "" or wanted, do: 5_000, else: 200)) do
          {:ok, data} -> read_quiet(socket, acc <> data)
          {:error, _quiet_or_closed} -> acc
        end
    end
  end

  # An answer on a TLS connection is read as a client reads it, up to its
  # end: MWT may keep the connection for the next request.
  defp read_all(socket, :ssl), do: MWTClient.SandboxProxy.read_answer(socket, :ssl)

  defp read_all(socket, mod, acc \\ "") do
    case mod.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, mod, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp connect(proxy, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    {socket, reply}
  end

  defp https(proxy, ca, host, request) do
    {socket, "HTTP/1.1 200" <> _} = connect(proxy, "140.82.112.3:443")

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: String.to_charlist(host),
        active: false,
        mode: :binary
      )

    # A list is sent a part at a time, with a pause between: what comes
    # after the first part arrives once MWT has decided on the request.
    for part <- List.wrap(request) do
      _ = :ssl.send(tls, part)
      if is_list(request), do: Process.sleep(300)
    end

    read_all(tls, :ssl)
  end

  defp token(username, attrs \\ %{}, uses \\ :all) do
    {:ok, grant} =
      Sandbox.create_grant(
        username,
        Map.merge(
          %{
            "kind" => "token",
            "preset" => "github",
            "name" => "GitHub",
            "purpose" => "The GitHub API",
            "hosts" => "api.github.com, github.com",
            "env" => "GH_TOKEN",
            "prefix" => "ghp_",
            "value" => @real
          },
          attrs
        )
      )

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, uses)
    grant
  end

  defp get(path, headers),
    do:
      "GET #{path} HTTP/1.1\r\nHost: api.github.com\r\n" <>
        Enum.map_join(headers, &(&1 <> "\r\n")) <> "\r\n"

  defp isolated(username) do
    case Sandbox.firewall(username).firewall.isolated do
      nil -> nil
      incident -> incident.rule
    end
  end

  defp summaries(username), do: Enum.map(Sandbox.events(username), & &1.summary)

  # The log is written by the sandbox as it goes: looked at until it shows.
  defp logged?(username, pattern) do
    Enum.any?(1..100, fn _ ->
      Enum.any?(summaries(username), &(&1 =~ pattern)) || (Process.sleep(20) && false)
    end)
  end

  ## The value comes back: never to the VM

  describe "an answer quoting the real value" do
    test "in its body is cut before any of it reaches the VM, and isolates (QA P1)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      response =
        https(
          proxy,
          ca,
          "api.github.com",
          get("/echo-body", ["Authorization: token #{grant.placeholder}"])
        )

      assert_receive {:upstream_got, got}
      assert got =~ "authorization: token #{@real}\r\n"
      # Asked for without content encoding, so a quote can be read.
      assert got =~ "accept-encoding: identity\r\n"

      assert response =~ "HTTP/1.1 401"
      refute response =~ @real
      refute response =~ "Bad credentials"
      assert isolated(username) == :real_value
      assert logged?(username, ~r/real value came back from api\.github\.com/)
      refute Enum.any?(summaries(username), &(&1 =~ @real))
    end

    test "in the head after a 103 Early Hints is replaced (QA M1)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      response =
        https(
          proxy,
          ca,
          "api.github.com",
          get("/early", ["Authorization: token #{grant.placeholder}"])
        )

      assert response =~ "HTTP/1.1 103 Early Hints"
      assert response =~ "x-echo: token #{grant.placeholder}\r\n"
      refute response =~ @real
    end

    test "in a head over 64 KiB is refused whole (QA M2)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      response =
        https(
          proxy,
          ca,
          "api.github.com",
          get("/big", ["Authorization: token #{grant.placeholder}"])
        )

      assert response =~ "HTTP/1.1 502"
      assert response =~ "mwt_unreadable_response"
      refute response =~ @real
    end

    test "in a gzip body, sent although MWT asked for none, is found and cut", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      https(
        proxy,
        ca,
        "api.github.com",
        get("/gzip", ["Authorization: token #{grant.placeholder}", "Accept-Encoding: gzip"])
      )

      assert_receive {:upstream_got, got}
      refute got =~ "accept-encoding: gzip"
      # Only decoded could it be seen there.
      assert isolated(username) == :real_value
    end

    test "as a Basic credential's base64 is found too", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)
      basic = "Basic " <> Base.encode64("x-access-token:" <> grant.placeholder)

      response =
        https(
          proxy,
          ca,
          "github.com",
          "GET /echo-body HTTP/1.1\r\nHost: github.com\r\nAuthorization: #{basic}\r\n\r\n"
        )

      assert_receive {:upstream_got, got}
      assert got =~ Base.encode64("x-access-token:" <> @real)
      refute response =~ Base.encode64("x-access-token:" <> @real)
      assert isolated(username) == :real_value
    end
  end

  ## The value goes only in a carrier

  describe "a placeholder outside its grant's carriers" do
    test "is refused, and nothing reaches the host (QA P2)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      for headers <- [
            ["X-GitHub-Api-Version: #{grant.placeholder}"],
            ["Authorization: token #{grant.placeholder}", "User-Agent: #{grant.placeholder}"]
          ] do
        response = https(proxy, ca, "api.github.com", get("/echo-body", headers))
        assert response =~ "HTTP/1.1 403", inspect(headers)
        assert response =~ "mwt_not_a_carrier"
        refute response =~ @real
      end

      refute_receive {:upstream_got, _}, 300
    end

    test "is swapped in a header the grant names as a carrier", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username, %{"carriers" => "X-Api-Key"})
      https(proxy, ca, "api.github.com", get("/", ["X-Api-Key: #{grant.placeholder}"]))
      assert_receive {:upstream_got, got}
      assert got =~ "x-api-key: #{@real}\r\n"
    end

    test "in a lowercase basic scheme is decoded and swapped (QA L11)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)
      basic = "basic " <> Base.encode64("x-access-token:" <> grant.placeholder)

      https(
        proxy,
        ca,
        "github.com",
        "GET /o/r.git/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: github.com\r\nAuthorization: #{basic}\r\n\r\n"
      )

      assert_receive {:upstream_got, got}
      [_, sent] = Regex.run(~r/authorization: basic ([^\r]*)/, got)
      assert Base.decode64!(sent) == "x-access-token:" <> @real
    end
  end

  describe "allow similar" do
    test "doesn't cover the same request with its credential in another header (QA P3)", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username, %{"carriers" => "Authorization, X-Api-Key"}, :ask)

      first =
        Task.async(fn ->
          https(
            proxy,
            ca,
            "api.github.com",
            get("/user", ["Authorization: token #{grant.placeholder}"])
          )
        end)

      [approval] = waiting(username, 1)
      assert {"Credential in", "authorization"} in approval.facts
      :ok = Sandbox.decide(username, approval.id, {:allow, :similar, 60})
      assert Task.await(first) =~ "HTTP/1.1 200"
      assert_receive {:upstream_got, _}

      # The same request again goes through under the allowance...
      assert https(
               proxy,
               ca,
               "api.github.com",
               get("/user", ["Authorization: token #{grant.placeholder}"])
             ) =~ "HTTP/1.1 200"

      assert_receive {:upstream_got, _}

      # ...but with the credential in another carrier it asks again.
      second =
        Task.async(fn ->
          https(proxy, ca, "api.github.com", get("/user", ["X-Api-Key: #{grant.placeholder}"]))
        end)

      [again] = waiting(username, 1)
      assert {"Credential in", "x-api-key"} in again.facts
      :ok = Sandbox.decide(username, again.id, :deny)
      assert Task.await(second) =~ "HTTP/1.1 403"
      refute_receive {:upstream_got, _}, 300
    end

    test "can't be stretched by a method override: it is refused", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)

      for header <- ["X-HTTP-Method-Override", "X-HTTP-Method", "X-Method-Override"] do
        response =
          https(
            proxy,
            ca,
            "api.github.com",
            "POST /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n#{header}: DELETE\r\nContent-Length: 0\r\n\r\n"
          )

        assert response =~ "HTTP/1.1 400", header
      end

      refute_receive {:upstream_got, _}, 300
    end
  end

  defp waiting(username, count) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        list when length(list) == count -> list
        _ -> Process.sleep(10) && nil
      end
    end)
  end

  ## A placeholder where its grant doesn't go, wherever MWT reads it

  describe "a placeholder to a host its grant doesn't list (QA L9)" do
    setup %{username: username} do
      # github.com only; api.github.com is another grant's, so MWT reads it.
      github = token(username, %{"hosts" => "github.com"})

      _other =
        token(username, %{
          "name" => "Other",
          "hosts" => "api.github.com",
          "value" => "other_real_value_0123456789"
        })

      %{github: github}
    end

    test "in the query is refused and logged", %{
      username: username,
      proxy: proxy,
      ca: ca,
      github: github
    } do
      response = https(proxy, ca, "api.github.com", get("/x?t=#{github.placeholder}", []))
      # Isolating closes every connection the proxy holds, this one too.
      refute response =~ "HTTP/1.1 200"
      refute_receive {:upstream_got, _}, 300
      assert logged?(username, ~r/GitHub placeholder sent to api\.github\.com · blocked/)
      assert isolated(username) == :credential_leak
    end

    test "in the start of the body is refused and logged", %{
      username: username,
      proxy: proxy,
      ca: ca,
      github: github
    } do
      # Only told, the firewall leaves the refusal to be read.
      :ok = Sandbox.firewall_set(username, {:action, :credential_leak, :alert})
      body = ~s({"note":"#{github.placeholder}"})

      response =
        https(
          proxy,
          ca,
          "api.github.com",
          "POST /x HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
        )

      assert response =~ "HTTP/1.1 403"
      assert response =~ "mwt_placeholder_blocked"
      refute_receive {:upstream_got, _}, 300
      assert logged?(username, ~r/GitHub placeholder sent to api\.github\.com · blocked/)
      assert isolated(username) == nil
    end

    test "past the first 64 KiB of the body is cut before it goes", %{
      username: username,
      proxy: proxy,
      ca: ca,
      github: github
    } do
      later = String.duplicate("a", 10_000) <> github.placeholder <> String.duplicate("b", 1_000)
      length = 70_000 + byte_size(later)

      https(proxy, ca, "api.github.com", [
        "POST /x HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: #{length}\r\n\r\n" <>
          String.duplicate("a", 70_000),
        later
      ])

      assert_receive {:upstream_got, got}, 5_000
      refute got =~ github.placeholder
      assert logged?(username, ~r/GitHub placeholder sent to api\.github\.com · blocked/)
      assert isolated(username) == :credential_leak
    end
  end

  ## The VM holds the real value: it never goes where MWT reads

  describe "a real value the VM sends" do
    test "in a header is refused, never described or logged", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      token(username)
      request = get("/user?x=#{@real}", ["Authorization: token #{@real}"])

      # Only told, the firewall leaves the refusal to be read...
      :ok = Sandbox.firewall_set(username, {:action, :real_value, :alert})
      response = https(proxy, ca, "api.github.com", request)
      assert response =~ "HTTP/1.1 403"
      assert response =~ "mwt_value_blocked"
      refute response =~ @real
      refute_receive {:upstream_got, _}, 300
      assert isolated(username) == nil

      # ...and by default it isolates.
      :ok = Sandbox.firewall_set(username, {:action, :real_value, :isolate})
      refute https(proxy, ca, "api.github.com", request) =~ "HTTP/1.1 200"
      refute_receive {:upstream_got, _}, 300
      assert isolated(username) == :real_value

      assert logged?(username, ~r/GitHub's real value in a request from the VM · blocked/)
      refute Enum.any?(Sandbox.events(username), &(inspect(&1) =~ @real))

      refute inspect(Sandbox.firewall(username), limit: :infinity, printable_limit: :infinity) =~
               @real
    end

    test "past the first 64 KiB of the body is cut before it goes", %{
      username: username,
      proxy: proxy,
      ca: ca
    } do
      grant = token(username)
      later = String.duplicate("a", 10_000) <> @real <> String.duplicate("b", 1_000)
      length = 70_000 + byte_size(later)

      https(proxy, ca, "api.github.com", [
        "POST /gists HTTP/1.1\r\nHost: api.github.com\r\n" <>
          "Authorization: token #{grant.placeholder}\r\nContent-Length: #{length}\r\n\r\n" <>
          String.duplicate("a", 70_000),
        later
      ])

      assert_receive {:upstream_got, got}, 5_000
      # The head carries the value MWT put in it; the body never does.
      [head, sent] = String.split(got, "\r\n\r\n", parts: 2)
      assert head =~ "authorization: token #{@real}"
      refute sent =~ @real
      assert isolated(username) == :real_value
    end
  end

  ## Tunnels

  defp local_server(username) do
    {:ok, server} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(server)

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Local #{port}",
        "purpose" => "A test server",
        "destinations" => "127.0.0.1:#{port}"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(server)
      heard(socket, test)
    end)

    port
  end

  defp heard(socket, test) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        send(test, {:server_got, data})
        heard(socket, test)

      {:error, reason} ->
        send(test, {:server_closed, reason})
    end
  end

  describe "a tunnel" do
    test "whose first byte is 0x16 is still looked through (QA L10)", %{
      username: username,
      proxy: proxy
    } do
      grant = token(username)
      port = local_server(username)

      {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{port}")

      :ok =
        :gen_tcp.send(
          socket,
          <<0x16>> <> "GET / HTTP/1.1\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
        )

      # A first byte of 0x16 has MWT wait up to 5 s for a TLS record whole.
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 10_000)
      assert_receive {:server_closed, _reason}, 10_000
      refute_received {:server_got, _}
      assert isolated(username) == :credential_leak
    end

    test "carrying a real value is cut before it goes, and isolates", %{
      username: username,
      proxy: proxy
    } do
      token(username)
      port = local_server(username)

      {socket, "HTTP/1.1 200" <> _} = connect(proxy, "127.0.0.1:#{port}")
      :ok = :gen_tcp.send(socket, "POST / HTTP/1.1\r\n\r\nstolen=#{@real}")

      # Plain HTTP is read: one MWT can't (no Host) is refused, nothing of it
      # ever connected, and its bytes are looked through all the same.
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      refute_received {:server_got, _}
      assert isolated(username) == :real_value
    end
  end
end
