defmodule MWTClient.Sandbox.EgressDriverTest do
  @moduledoc """
  A protocol MWT reads through a driver of its own
  (`MWTClient.SandboxLineDriver`, a made-up one), with nothing else
  changed: picked by its first bytes, each request judged as its driver
  describes it (a card under the network grant, *Allow similar* by its
  pattern), refused in its own words, and its bytes looked through by the
  core like any other's.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.Sandbox.Egress.Driver.{Http1, Raw}
  alias MWTClient.SandboxLineDriver

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("line-driver")
    service = line_service()
    %{username: username, service: service, proxy: proxy(username)}
  end

  defp proxy(username) do
    options =
      [
        drivers: [SandboxLineDriver, Http1, Raw]
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

  # A service of that protocol: each line answered `OK` and the line.
  defp line_service do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, packet: :line])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve(listen, test) end)
    port
  end

  defp serve(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn(fn -> answer(socket, test) end)
    serve(listen, test)
  end

  defp answer(socket, test) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000) do
      send(test, {:service_got, line})
      :gen_tcp.send(socket, "OK " <> line)
      answer(socket, test)
    end
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

  defp connect(proxy, service) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false, packet: :line])

    :ok = :gen_tcp.send(socket, "CONNECT 127.0.0.1:#{service} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    {:ok, "\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
    socket
  end

  defp waiting(username) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  test "each request is a card its driver describes, and Allow similar goes by its pattern", %{
    username: username,
    service: service,
    proxy: proxy
  } do
    grant = network_grant(username, service, :ask)
    socket = connect(proxy, service)

    :ok = :gen_tcp.send(socket, "TINY GET /users\n")
    approval = waiting(username)
    assert approval.title == "TINY GET 127.0.0.1:#{service} /users"
    assert {"Resource", "/users"} in approval.facts
    assert {"Through", "Corp"} in approval.facts
    refute_received {:service_got, _}

    :ok = Sandbox.decide(username, approval.id, {:allow, :similar, 60})
    assert {:ok, "OK TINY GET /users\n"} = :gen_tcp.recv(socket, 0, 5_000)

    # The same again goes without asking, on the same link.
    :ok = :gen_tcp.send(socket, "TINY GET /users\n")
    assert {:ok, "OK TINY GET /users\n"} = :gen_tcp.recv(socket, 0, 5_000)
    assert Sandbox.snapshot(username).waiting == []

    # Another isn't similar: asked, and refused in the protocol's words.
    :ok = :gen_tcp.send(socket, "TINY DELETE /users\n")
    :ok = Sandbox.decide(username, waiting(username).id, :deny)
    assert {:ok, "REFUSED mwt_denied_by_user\n"} = :gen_tcp.recv(socket, 0, 5_000)
    refute_received {:service_got, "TINY DELETE" <> _}

    read = Enum.filter(Sandbox.events(username), &(&1.outcome == :read))
    assert length(read) == 2
    assert Enum.all?(read, &(&1.method == "GET" and &1.path == "/users"))
    assert Enum.all?(read, &(&1.grant_id == grant.id))
  end

  @tag :capture_log
  test "a placeholder in what it sends never goes: the core looks through every driver's bytes",
       %{username: username, service: service, proxy: proxy} do
    {:ok, token} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_real_value_0123456789"
      })

    network_grant(username, service, :all)
    socket = connect(proxy, service)

    :ok = :gen_tcp.send(socket, "TINY GET /x?token=#{token.placeholder}\n")
    assert {:ok, "CUT\n"} = :gen_tcp.recv(socket, 0, 5_000)
    refute_receive {:service_got, _}, 200
  end

  test "bytes no driver claims go on as they are, as before", %{
    username: username,
    service: service,
    proxy: proxy
  } do
    network_grant(username, service, :all)
    socket = connect(proxy, service)

    :ok = :gen_tcp.send(socket, "HELLO there\n")
    assert {:ok, "OK HELLO there\n"} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    assert Enum.find_value(1..300, fn _ ->
             Enum.find(Sandbox.events(username), &(&1.outcome == :tunnel)) ||
               (Process.sleep(10) && nil)
           end).summary == "Not read: it isn't TLS"
  end
end
