defmodule MWTClient.Sandbox.GateTest do
  @moduledoc """
  The network path decides from the view the server published
  (`MWTClient.Sandbox.Gate`), so a busy server stops none of it (QA L12);
  and the Internet is a grant like the others: off, the VM reaches only
  what other grants list, and turning it off closes what it let through.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.Sandbox.{Gate, Grant, Server}
  alias MWTClient.SandboxProxy
  alias MWTClient.Vault.Store

  @public {140, 82, 112, 3}

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("gate")
    %{username: username}
  end

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_REAL_VALUE_THROUGH_THE_GATE_0123456789"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
    grant
  end

  defp request(host, headers \\ []) do
    %{host: host, method: "GET", path: "/user", headers: [{"host", host} | headers], body: ""}
  end

  defp server(username), do: Store.whereis(Server, username)

  defp suspended(username, fun) do
    pid = server(username)
    :sys.suspend(pid)

    try do
      fun.()
    after
      :sys.resume(pid)
    end
  end

  describe "with the sandbox's server busy (QA L12)" do
    test "connections, routes, tunnels' reports and plain requests are decided at once", %{
      username: username
    } do
      _grant = github(username)

      suspended(username, fn ->
        {us, decided} =
          :timer.tc(fn ->
            [
              Gate.destination(username, @public, 443),
              Gate.route(username, @public, 443, "example.com"),
              Gate.route(username, @public, 443, "api.github.com"),
              Gate.upload(username, "example.com", 443, 1024, 512),
              Gate.lookup(username, "example.com"),
              Gate.authorize(username, request("api.github.com"))
            ]
          end)

        assert [
                 {:ok, "internet"},
                 {:tunnel, %{}},
                 {:intercept, %{}},
                 :ok,
                 :ok,
                 {:forward, _headers, %{grant: nil}}
               ] = decided

        assert us < 1_000_000
      end)
    end

    test "a request with a placeholder waits for it, and goes once it answers", %{
      username: username
    } do
      grant = github(username)
      held = request("api.github.com", [{"authorization", "Bearer #{grant.placeholder}"}])
      pid = server(username)
      :sys.suspend(pid)
      task = Task.async(fn -> Gate.authorize(username, held) end)
      refute Task.yield(task, 200)
      :sys.resume(pid)

      assert {:forward, %{request: [%{to: "ghp_REAL" <> _, within: ["authorization"]}]},
              %{grant: "github"}} = Task.await(task)
    end
  end

  describe "a turn-off, as the network path sees it" do
    test "is in the view once the call returns", %{username: username} do
      grant = github(username)
      assert Gate.live?(username, grant.id)
      {:ok, _} = Sandbox.turn_off(username, grant.id)
      refute Gate.live?(username, grant.id)
      # Joining what it let through after that closes at once.
      assert {:error, :grant_off} = Gate.held_by(username, grant.id)
    end

    test "a locked identity leaves nothing to decide from: everything is refused", %{
      username: username
    } do
      Store.close(username)
      assert Gate.view(username) == nil
      assert {:deny, _} = Gate.destination(username, @public, 443)
      assert :refuse = Gate.lookup(username, "example.com")
    end
  end

  ## The Internet, a grant

  describe "the Internet" do
    test "is built in, on and auto-approved as MWT starts, and asks only when set to", %{
      username: username
    } do
      internet = Enum.find(Sandbox.snapshot(username).grants, &Grant.internet?/1)
      assert %Grant{id: "internet", kind: :network, state: :on, start: :auto} = internet
      assert Grant.built_in?(internet)
      assert Grant.auto_approved?(internet)
      assert Grant.starts(internet) == [:off, :on, :auto]
      assert Grant.default_uses(internet) == :all

      # Asking each time is a mode like any grant's.
      {:ok, _} = Sandbox.turn_off(username, "internet")
      {:ok, internet} = Sandbox.turn_on(username, "internet", 30, :ask)
      refute Grant.auto_approved?(internet)
      {:ok, internet} = Sandbox.set_mode(username, "internet", :all)
      assert Grant.auto_approved?(internet)
      {:ok, internet} = Sandbox.set_mode(username, "internet", :ask)
      refute Grant.auto_approved?(internet)
    end

    test "off, a public address opens only for a network grant listing it", %{
      username: username
    } do
      {:ok, _} = Sandbox.turn_off(username, "internet")
      assert :read_only = Gate.destination(username, @public, 443)

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "network",
          "name" => "GitHub's range",
          "purpose" => "A public range",
          "destinations" => "140.82.112.0/20:443"
        })

      {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
      assert {:ok, id} = Gate.destination(username, @public, 443)
      assert id == grant.id
      assert :read_only = Gate.destination(username, @public, 22)
    end

    test "off, DNS answers only the names grants list; a network grant's only while it is on", %{
      username: username
    } do
      _grant = github(username)

      {:ok, network} =
        Sandbox.create_grant(username, %{
          "kind" => "network",
          "name" => "Git server",
          "purpose" => "The office's git",
          "destinations" => "git.corp.internal:443"
        })

      {:ok, _} = Sandbox.turn_off(username, "internet")
      assert {:refuse, :internet_off} = Gate.lookup(username, "example.com")
      assert :ok = Gate.lookup(username, "api.github.com")
      assert :ok = Gate.lookup(username, "GitHub.com.")
      assert network.state == :off

      assert {:refuse, {:grant_off, %{id: "git-server"}}} =
               Gate.lookup(username, "git.corp.internal")

      # The Internet on doesn't answer it either: its grant does.
      {:ok, _} = Sandbox.turn_on(username, "internet", :until_off, :all)
      assert :ok = Gate.lookup(username, "example.com")

      assert {:refuse, {:grant_off, %{id: "git-server"}}} =
               Gate.lookup(username, "Git.Corp.Internal.")

      {:ok, _} = Sandbox.turn_on(username, "git-server", :until_off, :all)
      assert {:covered, %{id: "git-server"}} = Gate.lookup(username, "git.corp.internal")
    end

    test "off, a token grant's host is still reached, read by MWT; nothing else is", %{
      username: username
    } do
      grant = github(username)
      {:ok, _} = Sandbox.turn_off(username, "internet")
      # MWT's DNS answered the name with the address the proxy is asked for.
      :ok = Gate.answered(username, "api.github.com", [{140, 82, 112, 3}], 300)
      net = SandboxProxy.start(username)

      response =
        SandboxProxy.https(
          net,
          "api.github.com",
          "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: Bearer #{grant.placeholder}\r\n\r\n"
        )

      assert response =~ "HTTP/1.1 200"
      assert response =~ "ghp_REAL_VALUE_THROUGH_THE_GATE"

      # A name no token grant lists: the connection closes, unread.
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", net.proxy, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

      assert {:error, _closed} =
               :ssl.connect(socket,
                 verify: :verify_none,
                 server_name_indication: ~c"example.com",
                 active: false
               )

      # Nor do plain bytes go anywhere.
      {:ok, plain} = :gen_tcp.connect(~c"127.0.0.1", net.proxy, [:binary, active: false])
      :ok = :gen_tcp.send(plain, "CONNECT 140.82.112.3:22 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(plain, 0, 5_000)
      :ok = :gen_tcp.send(plain, "SSH-2.0-OpenSSH_9.6\r\n")
      assert {:error, :closed} = :gen_tcp.recv(plain, 0, 5_000)

      _ = :sys.get_state(server(username))

      assert Enum.any?(
               Sandbox.events(username),
               &(&1.summary == "The Internet is off · not passed through")
             )
    end

    test "turned off, it closes the connections it let through", %{username: username} do
      _grant = github(username)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)

      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        pid = spawn(fn -> receive(do: (:go -> Tcp.run(client, username, []))) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        Process.sleep(:infinity)
      end)

      [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

      # Read by MWT, waiting for its request: held under the Internet.
      {:ok, tls} =
        :ssl.connect(socket,
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"api.github.com",
          active: false,
          mode: :binary
        )

      assert [{held, _}] = Registry.lookup(MWTClient.Sandbox.Connections, {username, "internet"})
      ref = Process.monitor(held)

      {:ok, _} = Sandbox.turn_off(username, "internet")
      assert {:error, _closed} = :ssl.recv(tls, 0, 2_000)
      # The connection it held is gone. (The registry forgets it a moment
      # after, on its own: reading it at once raced under load.)
      assert_receive {:DOWN, ^ref, :process, ^held, _reason}
    end
  end

  # A DNS answer: one question for `name`, one A record pointing to `ip`.
  defp a_answer(name, {a, b, c, d}) do
    q =
      for label <- String.split(name, "."), into: <<>>, do: <<byte_size(label), label::binary>>

    question = <<q::binary, 0, 1::16, 1::16>>
    rr = <<q::binary, 0, 1::16, 1::16, 60::32, 4::16, a, b, c, d>>
    <<0x1234::16, 0x8180::16, 1::16, 1::16, 0::32, question::binary, rr::binary>>
  end

  describe "what MWT reads" do
    test "every Internet connection it can; on your list, unreadable or switched off, why not", %{
      username: username
    } do
      named = {:tls, %{name: "example.com", alpn: ["h2", "http/1.1"]}}

      assert :read = Gate.reading(username, "internet", named)
      assert :read = Gate.reading(username, "internet", {:tls, %{name: "example.com", alpn: nil}})

      assert :read =
               Gate.reading(username, "internet", {:tls, %{name: "x.example", alpn: ["h2"]}})

      assert {:pass, {:protocols, ["imap"]}} =
               Gate.reading(username, "internet", {:tls, %{name: "x.example", alpn: ["imap"]}})

      assert {:pass, :no_name} =
               Gate.reading(username, "internet", {:tls, %{name: nil, alpn: nil}})

      assert {:pass, :silent} = Gate.reading(username, "internet", Tcp.first(""))
      assert {:pass, :not_tls} = Gate.reading(username, "internet", Tcp.first("SSH-2.0-x\r\n"))

      :ok = Sandbox.reading_set(username, {:put, "example.com", false})
      assert {:pass, :listed} = Gate.reading(username, "internet", named)

      :ok = Sandbox.reading_set(username, {:default, :token_hosts})

      assert {:pass, :off} =
               Gate.reading(username, "internet", {:tls, %{name: "other.example", alpn: nil}})
    end

    test "a network grant's connections are read the same way", %{username: username} do
      assert :read =
               Gate.reading(username, "corp", {:tls, %{name: "git.corp.example", alpn: nil}})

      assert {:pass, :not_tls} =
               Gate.reading(username, "corp", Tcp.first("SSH-2.0-OpenSSH_9.6\r\n"))
    end
  end

  describe "a name a host list holds is known by its addresses" do
    test "its answer is kept, and a connection to them is held by its entry whatever it names",
         %{username: username} do
      ip = {160, 1, 2, 9}
      {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "paste.example", :block})

      :ok = Gate.remember_listed(username, "paste.example", a_answer("paste.example", ip))
      assert ["paste.example"] = Map.get(Gate.answered_for(username, ip), ip)

      # Unread, claiming another name: blocked all the same.
      assert {:deny, words} =
               Gate.unread(username, "internet", ip, 443, %{name: "harmless.example"}, false)

      assert words =~ "blocked on Internet (paste.example)"

      # A name no entry asks about or blocks is not kept.
      other = {160, 1, 2, 10}

      :ok =
        Gate.remember_listed(username, "harmless.example", a_answer("harmless.example", other))

      assert Map.get(Gate.answered_for(username, other), other) in [nil, []]
    end
  end

  describe "with the Internet off, a token grant's host is reached only where MWT's DNS said" do
    test "its answer is kept; a connection naming it elsewhere is refused", %{username: username} do
      _grant = github(username)
      {:ok, _} = Sandbox.turn_off(username, "internet")
      ip = {160, 1, 2, 20}

      assert :refuse = Gate.route(username, ip, 443, "api.github.com", :read_only)

      :ok = Gate.remember_read(username, "api.github.com", a_answer("api.github.com", ip))
      assert ["api.github.com"] = Map.get(Gate.answered_for(username, ip), ip)
      assert {:intercept, _watch} = Gate.route(username, ip, 443, "api.github.com", :read_only)

      # A name no token grant reads is not kept.
      other = {160, 1, 2, 21}
      :ok = Gate.remember_read(username, "example.com", a_answer("example.com", other))
      assert Map.get(Gate.answered_for(username, other), other) in [nil, []]
    end
  end

  describe "a trusted name is spared only at an address MWT resolved for it" do
    test "a trusted SNI to an address MWT never answered for it is refused", %{
      username: username
    } do
      assert :refuse = Gate.route(username, @public, 443, "api.anthropic.com")
    end

    test "once MWT has resolved it, a connection to that address tunnels", %{username: username} do
      ip = {160, 1, 2, 3}

      :ok =
        Gate.remember_trusted(username, "api.anthropic.com", a_answer("api.anthropic.com", ip))

      assert {:tunnel, watch} = Gate.route(username, ip, 443, "api.anthropic.com")
      # Trusted: not counted for uploads.
      assert is_nil(watch) or is_nil(watch.report_every)
      # The same answer doesn't vouch for a different address.
      assert :refuse = Gate.route(username, @public, 443, "api.anthropic.com")
    end

    test "a name no trusted entry covers is untouched by the match", %{username: username} do
      assert {:tunnel, _} = Gate.route(username, @public, 443, "example.com")
    end
  end
end
