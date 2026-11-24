defmodule MWTClient.Sandbox.DnsTest do
  # The resolver is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Dns, Gate}

  doctest Dns

  # A question for `name`, as a resolver library builds it.
  defp question(name, type \\ 1, id \\ 0x1234) do
    labels =
      for label <- String.split(name, "."), into: <<>>, do: <<byte_size(label), label::binary>>

    <<id::16, 0x0100::16, 1::16, 0::48, labels::binary, 0, type::16, 1::16>>
  end

  # Stands in for this machine's resolver: answers each question with the
  # question itself and `tail`, over UDP, and tells the test what it got.
  defp fake_resolver(tail, flags \\ 0x8180) do
    {udp, tcp, port} = resolver_sockets()
    test = self()

    spawn_link(fn -> serve_udp(udp, tail, flags, test) end)
    spawn_link(fn -> serve_tcp(tcp, tail, test) end)

    saved = Application.get_env(:mwt_client, Dns)
    Application.put_env(:mwt_client, Dns, resolver: {{127, 0, 0, 1}, port})

    on_exit(fn ->
      if saved,
        do: Application.put_env(:mwt_client, Dns, saved),
        else: Application.delete_env(:mwt_client, Dns)
    end)
  end

  # A UDP and a TCP socket on one port, as a resolver has. The UDP port is
  # any free one; the same number for TCP may be taken by another socket
  # (a connection's own port, in a full run), so then another is tried.
  defp resolver_sockets(tries \\ 20) do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(udp)

    case :gen_tcp.listen(port, [
           :binary,
           active: false,
           ip: {127, 0, 0, 1},
           packet: 2,
           reuseaddr: true
         ]) do
      {:ok, tcp} ->
        {udp, tcp, port}

      {:error, :eaddrinuse} when tries > 1 ->
        :gen_udp.close(udp)
        resolver_sockets(tries - 1)
    end
  end

  defp serve_udp(socket, tail, flags, test) do
    {:ok, {address, port, <<id::16, _flags::16, rest::binary>> = asked}} =
      :gen_udp.recv(socket, 0)

    send(test, {:resolver_udp, asked})
    :gen_udp.send(socket, address, port, <<id::16, flags::16, rest::binary, tail::binary>>)
    serve_udp(socket, tail, flags, test)
  end

  defp serve_tcp(listen, tail, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, <<id::16, _flags::16, rest::binary>> = asked} = :gen_tcp.recv(socket, 0, 5_000)
    send(test, {:resolver_tcp, asked})
    :gen_tcp.send(socket, <<id::16, 0x8180::16, rest::binary, tail::binary, "whole">>)
    :gen_tcp.close(socket)
    serve_tcp(listen, tail, test)
  end

  # What the relay does for each question the VM asks.
  defp ask(username, message) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Dns.path(username)}, 0, [:binary, active: false, packet: 2])

    :ok = :gen_tcp.send(socket, message)
    answer = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    answer
  end

  defp blocked(username) do
    _ = :sys.get_state(MWTClient.Vault.Store.whereis(Sandbox.Server, username))
    for %{outcome: :blocked} = event <- Sandbox.events(username), do: {event.host, event.summary}
  end

  defp lookups(username) do
    _ = :sys.get_state(MWTClient.Vault.Store.whereis(Sandbox.Server, username))
    for %{outcome: :lookup} = event <- Sandbox.events(username), do: {event.host, event.summary}
  end

  setup do
    MWTClient.VaultHelpers.unlocked_identity("dns")
  end

  test "what a message asks for is read; anything else is not a question" do
    assert Dns.question(question("api.GitHub.com", 28)) == {:ok, "api.github.com", "AAAA"}
    assert Dns.question(question("example.com", 999)) == {:ok, "example.com", "type 999"}
    assert Dns.question(<<1, 2, 3>>) == :error
    assert Dns.question(<<0::16, 0::16, 2::16, 0::48, 0, 1::16, 1::16>>) == :error
    # A label that says it is longer than the message.
    assert Dns.question(<<0::16, 0::16, 1::16, 0::48, 50, "short">>) == :error
  end

  test "a question goes to this machine's resolver and its answer comes back unchanged", %{
    username: username
  } do
    fake_resolver("the answer")
    asked = question("example.com")

    assert {:ok, answer} = ask(username, asked)
    assert_received {:resolver_udp, ^asked}
    <<_id::16, _flags::16, rest::binary>> = asked
    assert answer == <<0x1234::16, 0x8180::16, rest::binary, "the answer">>
  end

  @tag :capture_log
  test "a name the firewall refuses is answered REFUSED here, and never asked of the resolver",
       %{username: username} do
    fake_resolver("x")

    # Blocked, not isolating: DNS over HTTPS around MWT.
    asked = question("dns.google")
    assert {:ok, <<0x1234::16, 0x8185::16, 1::16, 0::48, _::binary>>} = ask(username, asked)
    refute_received {:resolver_udp, _}

    # One name shaped to carry data is refused here, but doesn't isolate;
    # the third such name under the domain in 10 minutes does, and every
    # name is refused after.
    long = fn i -> String.duplicate("a", 60) <> "#{i}.example.com" end
    assert {:ok, <<_::16, 0x8185::16, _::binary>>} = ask(username, question(long.(1)))
    refute_received {:resolver_udp, _}
    assert is_nil(Sandbox.firewall(username).firewall.isolated)

    assert {:ok, <<_::16, 0x8185::16, _::binary>>} = ask(username, question(long.(2)))
    assert {:ok, <<_::16, 0x8185::16, _::binary>>} = ask(username, question(long.(3)))
    assert {:ok, <<_::16, 0x8185::16, _::binary>>} = ask(username, question("example.com"))
    refute_received {:resolver_udp, _}
    assert %{rule: :dns_tunnel} = Sandbox.firewall(username).firewall.isolated
  end

  test "every name is in the activity log, once in a while", %{username: username} do
    fake_resolver("x")

    assert {:ok, _} = ask(username, question("one.example.com"))
    assert {:ok, _} = ask(username, question("one.example.com"))
    assert {:ok, _} = ask(username, question("one.example.com", 28))
    assert {:ok, _} = ask(username, question("two.example.com"))

    assert Enum.sort(lookups(username)) == [
             {"one.example.com", "Looked up (A)"},
             {"one.example.com", "Looked up (AAAA)"},
             {"two.example.com", "Looked up (A)"}
           ]
  end

  test "an answer cut short over UDP is asked again over TCP", %{username: username} do
    # 0x8380: the same answer flags with TC set.
    fake_resolver("part", 0x8380)
    asked = question("big.example.com", 16)

    assert {:ok, answer} = ask(username, asked)
    assert_received {:resolver_udp, ^asked}
    assert_received {:resolver_tcp, ^asked}
    assert String.ends_with?(answer, "partwhole")
  end

  test "bytes that aren't a question get no answer and reach no resolver", %{username: username} do
    fake_resolver("x")

    assert {:error, :closed} = ask(username, "not a dns message at all")
    refute_received {:resolver_udp, _}
    assert lookups(username) == []
  end

  # QA L12: the sandbox's server is on no lookup's way. Suspended, as a
  # long call or a slow save would leave it, names are still answered.
  test "a lookup is answered while the sandbox's server is busy", %{username: username} do
    fake_resolver("the answer")
    server = MWTClient.Vault.Store.whereis(Sandbox.Server, username)
    :sys.suspend(server)

    try do
      {us, answer} = :timer.tc(fn -> ask(username, question("example.com")) end)
      assert {:ok, <<0x1234::16, 0x8180::16, _::binary>>} = answer
      assert us < 1_000_000
    after
      :sys.resume(server)
    end
  end

  # QA L5: only a standard query of one name goes on. An UPDATE with its
  # records, a NOTIFY or a zone transfer would reach the host's resolver,
  # which may be the LAN's.
  describe "what the resolver is sent" do
    # A message with `flags`, one entry in its first section, and `sections`
    # after it: the counts of the next three, then their bytes.
    defp message(name, type, flags, counts, sections) do
      labels =
        for label <- String.split(name, "."), into: <<>>, do: <<byte_size(label), label::binary>>

      <<0x4242::16, flags::16, 1::16, counts::binary, labels::binary, 0, type::16, 1::16,
        sections::binary>>
    end

    test "an UPDATE with its records is answered NOTIMP here, and reaches no resolver", %{
      username: username
    } do
      fake_resolver("x")
      text = "exfiltrated-secret-data-in-an-update-record"

      record =
        <<3, "www", 7, "example", 3, "com", 0, 16::16, 1::16, 300::32, byte_size(text) + 1::16,
          byte_size(text), text::binary>>

      # Opcode 5 (UPDATE): one zone, one record to add.
      update = message("example.com", 6, 0x2800, <<0::16, 1::16, 0::16>>, record)

      assert {:ok, <<0x4242::16, 1::1, 5::4, _::7, 4::4, _::binary>>} = ask(username, update)
      refute_received {:resolver_udp, _}

      # NOTIFY (4) and the other operations alike.
      notify = message("example.com", 6, 0x2000, <<0::48>>, "")
      assert {:ok, <<0x4242::16, 1::1, 4::4, _::7, 4::4, _::binary>>} = ask(username, notify)
      refute_received {:resolver_udp, _}
    end

    test "a zone transfer is refused", %{username: username} do
      fake_resolver("x")

      for type <- [252, 251] do
        asked = message("corp.internal", type, 0x0100, <<0::48>>, "")
        assert {:ok, <<0x4242::16, 0x8185::16, _::binary>>} = ask(username, asked)
      end

      refute_received {:resolver_udp, _}
    end

    test "a query carrying records of its own is refused", %{username: username} do
      fake_resolver("x")
      record = <<0, 16::16, 1::16, 0::32, 5::16, 4, "data">>

      for counts <- [<<1::16, 0::16, 0::16>>, <<0::16, 1::16, 0::16>>, <<0::16, 0::16, 1::16>>] do
        asked = message("example.com", 1, 0x0100, counts, record)
        assert {:ok, <<0x4242::16, 0x8185::16, _::binary>>} = ask(username, asked)
      end

      refute_received {:resolver_udp, _}
    end

    test "EDNS goes on without its options, and nothing after the question does", %{
      username: username
    } do
      fake_resolver("x")
      bare = message("example.com", 1, 0x0100, <<0::48>>, "")

      # Bytes after the question, counted nowhere.
      assert {:ok, _} = ask(username, bare <> "trailing data")
      assert_received {:resolver_udp, ^bare}

      # An OPT record with an option (padding here) carrying data.
      option = <<12::16, 9::16, "some data">>
      opt = <<0, 41::16, 1232::16, 0x8000::32, byte_size(option)::16, option::binary>>
      with_opt = message("example.com", 1, 0x0100, <<0::32, 1::16>>, opt)

      plain_opt =
        message(
          "example.com",
          1,
          0x0100,
          <<0::32, 1::16>>,
          <<0, 41::16, 1232::16, 0x8000::32, 0::16>>
        )

      assert {:ok, _} = ask(username, with_opt)
      assert_received {:resolver_udp, ^plain_opt}

      # Any other additional record is refused.
      other =
        message("example.com", 1, 0x0100, <<0::32, 1::16>>, <<0, 16::16, 1::16, 0::32, 0::16>>)

      assert {:ok, <<0x4242::16, 0x8185::16, _::binary>>} = ask(username, other)
      refute_received {:resolver_udp, _}
    end
  end

  # Step 17: a name a network grant lists is answered only while the grant
  # is on, by its own resolver when it names one, and the addresses
  # answered are what the grant opens.
  describe "a name a network grant lists" do
    # The labels of `name`, as a message writes them.
    defp labels(name),
      do:
        for(label <- String.split(name, "."), into: <<>>, do: <<byte_size(label), label::binary>>) <>
          <<0>>

    # An answer to `asked`: its name a CNAME of edge.corp.example (written
    # through a pointer to the question), that name's A record (through a
    # pointer to the CNAME's data), and an unrelated name's A record.
    defp corp_answer(<<id::16, _flags::16, _counts::64, rest::binary>>, ttl) do
      question_size = byte_size(rest)
      target = labels("edge.corp.example")
      target_at = 12 + question_size + 12

      cname = <<0xC00C::16, 5::16, 1::16, ttl::32, byte_size(target)::16, target::binary>>
      a = <<0xC000 + target_at::16, 1::16, 1::16, ttl + 100::32, 4::16, 10, 4, 4, 4>>
      other = <<labels("other.example")::binary, 1::16, 1::16, ttl::32, 4::16, 10, 6, 6, 6>>

      <<id::16, 0x8180::16, 1::16, 3::16, 0::32, rest::binary, cname::binary, a::binary,
        other::binary>>
    end

    # A grant's own resolver: answers every question as `corp_answer/2`
    # does, and tells the test what it got.
    defp corp_resolver(ttl) do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(udp)
      test = self()

      serve = fn serve ->
        {:ok, {address, from, asked}} = :gen_udp.recv(udp, 0)
        send(test, {:corp_resolver, asked})
        :gen_udp.send(udp, address, from, corp_answer(asked, ttl))
        serve.(serve)
      end

      spawn_link(fn -> serve.(serve) end)
      "127.0.0.1:#{port}"
    end

    defp corp_grant(username, attrs) do
      {:ok, grant} =
        Sandbox.create_grant(
          username,
          Map.merge(
            %{
              "kind" => "network",
              "name" => "Corp",
              "purpose" => "The company's network",
              "destinations" => "*.corp.example:443"
            },
            attrs
          )
        )

      grant
    end

    test "the addresses of an answer: through its CNAMEs, and its shortest TTL" do
      asked = question("git.corp.example")

      assert Dns.addresses(corp_answer(asked, 30), "Git.Corp.Example.") ==
               {[{10, 4, 4, 4}], 30}

      assert Dns.addresses(corp_answer(asked, 30), "elsewhere.example") == {[], 0}
      assert Dns.addresses("not an answer", "git.corp.example") == {[], 0}

      # A pointer to itself is not followed forever.
      looping = <<0::16, 0x8180::16, 1::16, 1::16, 0::32, 0xC00C::16, 1::16, 1::16>>
      assert Dns.addresses(looping, "git.corp.example") == {[], 0}
    end

    test "off, it is refused here, the Internet on or not; on, its resolver answers it and MWT keeps the addresses",
         %{username: username} do
      fake_resolver("the machine's answer")
      resolver = corp_resolver(5)
      _grant = corp_grant(username, %{"resolver" => resolver})
      asked = question("git.corp.example")

      assert {:ok, <<0x1234::16, 0x8185::16, _::binary>>} = ask(username, asked)
      refute_received {:corp_resolver, _}
      refute_received {:resolver_udp, _}

      # A new grant starts off: a name of its network still isn't sent to
      # the Internet's resolver.
      assert {"git.corp.example", "Not looked up (A): Corp is off"} in blocked(username)

      {:ok, _} = Sandbox.turn_on(username, "corp", :until_off, :all)
      assert {:ok, answer} = ask(username, asked)
      assert answer == corp_answer(asked, 5)
      assert_received {:corp_resolver, ^asked}
      refute_received {:resolver_udp, _}

      # Kept for the name asked, at least a minute, whatever the TTL said;
      # the unrelated record in the answer opens nothing.
      assert Gate.answered_for(username, {10, 4, 4, 4}) == %{
               {10, 4, 4, 4} => ["git.corp.example"]
             }

      assert Gate.answered_for(username, {10, 6, 6, 6}) == %{}

      # A name no grant lists still goes to this machine's resolver.
      assert {:ok, _} = ask(username, question("example.com"))
      assert_received {:resolver_udp, _}
    end

    test "with a way out that isn't connected, its names are refused", %{username: username} do
      fake_resolver("x")
      resolver = corp_resolver(300)
      _grant = corp_grant(username, %{"resolver" => resolver, "anchor" => "mwt-none0"})
      {:ok, _} = Sandbox.turn_on(username, "corp", :until_off, :all)

      assert {:ok, <<_::16, 0x8185::16, _::binary>>} = ask(username, question("git.corp.example"))
      refute_received {:corp_resolver, _}

      assert {"git.corp.example", "Not looked up (A): Corp's network isn't connected (mwt-none0)"} in blocked(
               username
             )
    end

    test "a connection opens only to an address answered, and TLS only with a name answered there",
         %{username: username} do
      resolver = corp_resolver(300)
      _grant = corp_grant(username, %{"resolver" => resolver})
      ip = {10, 4, 4, 4}

      # On, but nothing answered yet: the address is the LAN's, not the grant's.
      {:ok, _} = Sandbox.turn_on(username, "corp", :until_off, :all)
      assert {:deny, _} = Gate.destination(username, ip, 443)

      assert {:ok, _} = ask(username, question("git.corp.example"))
      assert {:ok, "corp"} = Gate.destination(username, ip, 443)
      assert {:deny, _} = Gate.destination(username, ip, 22)

      assert {:tunnel, _} = Gate.route(username, ip, 443, "git.corp.example", "corp")
      assert :refuse = Gate.route(username, ip, 443, "admin.elsewhere.example", "corp")
      assert :refuse = Gate.route(username, ip, 443, "wiki.corp.example", "corp")
    end
  end
end
