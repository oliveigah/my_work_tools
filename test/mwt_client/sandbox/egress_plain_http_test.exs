defmodule MWTClient.Sandbox.EgressPlainHttpTest do
  @moduledoc """
  Plain HTTP, read: each request judged and logged as one inside TLS is,
  its host the one its `Host` names, which only the client vouches for.
  So no placeholder goes in one, its card says the address it goes to, an
  allowance for it covers that address only, and a host list holds it by
  the strictest of its name and those MWT's DNS answered for the address.
  What else comes as plain bytes goes on as before.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Gate
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.SandboxProxy

  @address "93.184.216.34"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("plain-http")
    host = start_host()
    %{username: username, proxy: proxy(username, host)}
  end

  defp proxy(username, host) do
    test = self()

    options = [
      upstream_tcp: fn target ->
        send(test, {:upstream, target})
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

  # Plain HTTP, each request answered with its path; anything else echoed.
  defp start_host do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve(listen, test) end)
    port
  end

  defp serve(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)

    spawn(fn ->
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, "GET " <> _ = data} ->
          send(test, {:host_got, data})
          [_, path | _] = String.split(data, " ")

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(path)}\r\n\r\n#{path}"
          )

        {:ok, data} ->
          send(test, {:host_got, data})
          :gen_tcp.send(socket, "echo:" <> data)

        _other ->
          :ok
      end

      _ = :gen_tcp.recv(socket, 0, 2_000)
      :gen_tcp.close(socket)
    end)

    serve(listen, test)
  end

  defp connect(proxy) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT #{@address}:80 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    socket
  end

  defp get(proxy, path, headers \\ [{"host", "example.com"}]) do
    socket = connect(proxy)
    head = Enum.map_join(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\n#{head}\r\n")
    SandboxProxy.read_answer(socket, :gen_tcp)
  end

  defp event(username, fun) do
    Enum.find_value(1..300, fn _ ->
      Enum.find(Sandbox.events(username), fun) || (Process.sleep(10) && nil)
    end)
  end

  defp waiting(username) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        [approval] -> approval
        [] -> Process.sleep(10) && nil
      end
    end)
  end

  test "a plain HTTP request is read: it goes on, logged under the host it names", %{
    username: username,
    proxy: proxy
  } do
    assert get(proxy, "/readme") =~ "/readme"
    assert_receive {:host_got, "GET /readme HTTP/1.1\r\nhost: example.com\r\n" <> _}
    assert_receive {:upstream, %{ip: {93, 184, 216, 34}, port: 80}}

    assert %{outcome: :read, host: "example.com", path: "/readme", exchange_id: id} =
             event(username, &(&1.outcome == :read))

    assert is_binary(id)
  end

  test "a placeholder never goes over plain HTTP, even to a host its grant lists", %{
    username: username,
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

    answer =
      get(proxy, "/me", [
        {"host", "example.com"},
        {"authorization", "Bearer " <> grant.placeholder}
      ])

    assert answer =~ "HTTP/1.1 403"
    assert answer =~ "mwt_plain_http"
    assert answer =~ "https://example.com"
    refute_received {:host_got, _}
  end

  test "its card says the address, and an allowance for it covers that address only", %{
    username: username,
    proxy: proxy
  } do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :ask})
    answer = Task.async(fn -> get(proxy, "/held") end)

    approval = waiting(username)
    assert approval.title =~ "http://example.com/held"
    assert approval.pattern =~ "via #{@address}"

    assert Enum.any?(approval.facts, fn {label, value} ->
             label == "Plain HTTP" and value =~ "to #{@address}: nothing proves it is example.com"
           end)

    :ok = Sandbox.decide(username, approval.id, :allow_once)
    assert Task.await(answer) =~ "/held"
  end

  test "a host list holds it by the strictest of its Host and the names answered for its address",
       %{username: username, proxy: proxy} do
    # The VM looked up paste.test, then claims another name to its address.
    :ok = Gate.answered(username, "paste.test", [{93, 184, 216, 34}], 60)
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "paste.test", :block})

    answer = get(proxy, "/out", [{"host", "harmless.test"}])
    assert answer =~ "HTTP/1.1 403"
    assert answer =~ "mwt_host_blocked"
    refute_received {:host_got, _}
  end

  # An address shared by many names (an ingress) serves each by its Host.
  test "under a network grant opened by a name, only that name's Host goes on", %{
    username: username,
    proxy: proxy
  } do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "The app",
        "purpose" => "The office's app",
        "destinations" => "app.corp.test:80"
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    # MWT's DNS answered the grant's name with the ingress's address.
    :ok = Gate.answered(username, "app.corp.test", [{10, 20, 30, 40}], 60)

    get = fn host ->
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 10.20.30.40:80 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
      :ok = :gen_tcp.send(socket, "GET /admin HTTP/1.1\r\nhost: #{host}\r\n\r\n")
      SandboxProxy.read_answer(socket, :gen_tcp)
    end

    answer = get.("admin.corp.test")
    assert answer =~ "HTTP/1.1 403"
    assert answer =~ "mwt_name_not_granted"
    refute_received {:host_got, _}

    assert event(username, &(&1.summary =~ "admin.corp.test isn't a name MWT answered"))

    assert get.("app.corp.test") =~ "HTTP/1.1 200"
    assert_received {:host_got, "GET /admin" <> _}
  end

  test "a Host that names another port, or no host, is refused as unreadable", %{proxy: proxy} do
    assert get(proxy, "/", [{"host", "example.com:8080"}]) =~ "HTTP/1.1 400"
    assert get(proxy, "/", []) =~ "HTTP/1.1 400"
    refute_received {:host_got, _}
  end

  test "what isn't HTTP as plain bytes goes on as before", %{username: username, proxy: proxy} do
    socket = connect(proxy)
    :ok = :gen_tcp.send(socket, "NICK agent\r\n")
    assert {:ok, "echo:NICK agent\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
    # A tunnel's line comes as it closes.
    :gen_tcp.close(socket)

    assert %{outcome: :tunnel, summary: "Not read: it isn't TLS" <> _} =
             event(username, &(&1.outcome == :tunnel))
  end

  test "reading only token grants' hosts leaves plain HTTP unread", %{
    username: username,
    proxy: proxy
  } do
    :ok = Sandbox.reading_set(username, {:default, :token_hosts})
    socket = connect(proxy)
    :ok = :gen_tcp.send(socket, "GET /x HTTP/1.1\r\nhost: example.com\r\n\r\n")
    assert {:ok, "HTTP/1.1 200 OK" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    assert %{summary: "Passed through"} = event(username, &(&1.outcome == :tunnel))
    refute Enum.any?(Sandbox.events(username), &(&1.outcome == :read))
  end
end
