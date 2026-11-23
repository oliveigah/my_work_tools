defmodule MWTClient.Sandbox.EgressHeldRequestTest do
  @moduledoc """
  A request held for your approval whose client gives up meanwhile (its
  own timeout, then a retry on a new connection, which joins the card):
  the request goes once, for the client still waiting, when you allow it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxProxy

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("held-request")
    test = self()
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, host} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, host_port}} = :ssl.sockname(host)
    spawn_link(fn -> serve(host, test) end)

    options = [
      upstream: fn _target ->
        :ssl.connect(~c"127.0.0.1", host_port, verify: :verify_none, active: false, mode: :binary)
      end
    ]

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, username, options, test) end)
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, proxy: port, ca: ca}
  end

  defp accept(listen, username, options, test) do
    {:ok, client} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive do: (:go -> Tcp.run(client, username, options)) end)
    send(test, {:connection, pid})
    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options, test)
  end

  # The host tells the test of each request it gets, and creates it.
  defp serve(listen, test) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      {:ok, got} = :ssl.recv(socket, 0, 5_000)
      send(test, {:host_got, got})

      :ssl.send(
        socket,
        "HTTP/1.1 201 Created\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
      )

      :ssl.close(socket)
    end)

    serve(listen, test)
  end

  defp open(proxy, ca) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
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

    tls
  end

  # The card waiting, once `ready?` says it is as the test wants it.
  defp card(username, ready?) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [card] -> if ready?.(card), do: card, else: Process.sleep(10) && nil
        _none -> Process.sleep(10) && nil
      end
    end)
  end

  test "a client that gave up while its request waited doesn't have it sent; its retry does, once",
       %{username: username, proxy: proxy, ca: ca} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_REAL_SECRET_VALUE_0123"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :ask)
    body = ~s({"title":"one issue"})

    request =
      "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
        "Authorization: token #{grant.placeholder}\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
        body

    # The client sends it, waits for the card, then gives up and closes:
    # its connection ends at once, though nobody decided yet.
    first = open(proxy, ca)
    assert_receive {:connection, gone}
    ref = Process.monitor(gone)
    :ok = :ssl.send(first, request)
    assert %{retries: 0} = card(username, fn _ -> true end)
    :ok = :ssl.close(first)
    assert_receive {:DOWN, ^ref, :process, ^gone, _reason}

    # Its retry, the very same request on a new connection, joins the card.
    retry =
      Task.async(fn ->
        tls = open(proxy, ca)
        :ok = :ssl.send(tls, request)
        SandboxProxy.read_answer(tls, :ssl, "POST")
      end)

    joined = card(username, &(&1.retries == 1))
    :ok = Sandbox.decide(username, joined.id, :allow_once)

    assert Task.await(retry) =~ "HTTP/1.1 201 Created"
    assert_receive {:host_got, "POST /repos/o/r/issues" <> _}
    refute_receive {:host_got, _}, 500
  end
end
