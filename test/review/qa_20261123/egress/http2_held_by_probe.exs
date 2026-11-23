defmodule MWTClient.QaProbes.Egress.Http2HeldByTest do
  @moduledoc """
  QA probe: an HTTP/2 connection whose streams carry a token grant's value
  joins `MWTClient.Sandbox.Connections` under that grant once per stream,
  each join with a timer for the grant's end. Does it grow with every call?
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxH2Host

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("qa-h2-held")
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    {_pid, host} = SandboxH2Host.start()

    options = [
      upstream: fn target ->
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
    test = self()
    spawn_link(fn -> accept(listen, username, options, test) end)
    %{username: username, ca: ca, proxy: port}
  end

  defp accept(listen, username, options, test) do
    {:ok, client} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive(do: (:go -> Tcp.run(client, username, options))) end)
    send(test, {:core, pid})
    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options, test)
  end

  defp client(proxy, ca) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 93.184.216.34:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(
        socket,
        [
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"example.com",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          alpn_advertised_protocols: ["h2"],
          active: false,
          mode: :binary
        ],
        5_000
      )

    {:ok, conn} = Mint.HTTP2.initiate(:https, tls, "example.com", 443, mode: :passive)
    conn
  end

  defp done(conn, ref) do
    case Mint.HTTP2.recv(conn, 0, 5_000) do
      {:ok, conn, responses} ->
        if Enum.any?(responses, &match?({:done, ^ref}, &1)), do: conn, else: done(conn, ref)

      {:error, _conn, reason, _} ->
        flunk("stream failed: #{inspect(reason)}")
    end
  end

  test "each call with a value joins the grant's connections again, with a timer of its own", %{
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
    assert_receive {:core, core}

    conn =
      Enum.reduce(1..200, conn, fn _, conn ->
        {:ok, conn, ref} = Mint.HTTP2.request(conn, "GET", "/auth", auth, nil)
        done(conn, ref)
      end)

    _ = conn
    entries = Registry.lookup(MWTClient.Sandbox.Connections, {username, grant.id})
    mine = Enum.count(entries, fn {pid, _} -> pid == core end)
    {:messages, _} = Process.info(core, :messages)
    timers = length(:erlang.process_info(core, :dictionary) |> elem(1))

    IO.puts(
      "\n[probe] one HTTP/2 connection, 200 calls carrying the value: " <>
        "#{mine} registrations under the grant (dict #{timers})"
    )

    assert mine >= 200
  end
end
