defmodule MWTClient.Sandbox.DestinationsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Destinations

  doctest Destinations

  test "classifies refused, private and public addresses" do
    own = [{192, 168, 15, 97}]

    assert Destinations.classify({127, 0, 0, 1}, own) == :refused
    assert Destinations.classify({169, 254, 169, 254}, own) == :refused
    assert Destinations.classify({0, 0, 0, 0, 0, 0, 0, 1}, own) == :refused
    assert Destinations.classify({192, 168, 15, 97}, own) == :refused
    assert Destinations.classify({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, own) == :refused
    assert Destinations.classify({192, 168, 15, 1}, own) == :private
    assert Destinations.classify({10, 20, 4, 12}, own) == :private
    assert Destinations.classify({100, 64, 1, 1}, own) == :private
    assert Destinations.classify({0xFD00, 0, 0, 0, 0, 0, 0, 5}, own) == :private
    assert Destinations.classify({140, 82, 112, 3}, own) == :public
  end

  # QA L6: an IPv6 address that carries an IPv4 one inside reaches that
  # address on a host that translates it, and a few ranges the probe found
  # public route to private hosts or answer as cloud metadata.
  test "judges an address by the IPv4 one it carries, and by the ranges that route inward" do
    own = [{192, 168, 15, 97}]
    class = &Destinations.classify(elem(Destinations.parse_ip(&1), 1), own)

    # NAT64, well-known prefix: the IPv4 inside decides.
    assert class.("64:ff9b::7f00:1") == :refused
    assert class.("64:ff9b::a9fe:a9fe") == :refused
    assert class.("64:ff9b::c0a8:0101") == :private
    assert class.("64:ff9b::a00:1") == :private
    assert class.("64:ff9b::8c52:7003") == :public
    # NAT64, a local prefix of the network's own: where it goes is theirs.
    assert class.("64:ff9b:1::8c52:7003") == :private
    # IPv4-compatible, SIIT and 6to4 carry one too.
    assert class.("::127.0.0.1") == :refused
    assert class.("::0.0.0.5") == :refused
    assert class.("::ffff:0:127.0.0.1") == :refused
    assert class.("2002:7f00:1::") == :refused
    assert class.("2002:c0a8:0f61::1") == :refused
    assert class.("2002:8c52:7003::1") == :public
    # Fake-IP pools of local proxies (Clash, sing-box) map these anywhere.
    assert class.("198.18.0.1") == :private
    assert class.("198.19.255.254") == :private
    assert class.("fec0::1") == :private
    # Cloud metadata outside 169.254.0.0/16.
    assert class.("192.0.0.192") == :refused
    assert class.("100.100.100.200") == :refused
    assert class.("fd00:ec2::254") == :refused
    # Multicast and the reserved block route nowhere a VM should go.
    assert class.("224.0.0.1") == :refused
    assert class.("240.0.0.1") == :refused
    assert class.("255.255.255.255") == :refused
    assert class.("ff02::1") == :refused
    # Ordinary addresses stay as they were.
    assert class.("140.82.112.3") == :public
    assert class.("2606:4700::6810:84e5") == :public
    assert class.("100.64.1.1") == :private
  end

  test "parses ranges, addresses and names with ports" do
    assert {:ok, %{match: {:cidr, {10, 20, 0, 0}, 16}, ports: [443, 5432]}} =
             Destinations.parse("10.20.0.0/16:443,5432 # office")

    assert {:ok, %{match: {:cidr, {127, 0, 0, 1}, 32}, ports: [5433]}} =
             Destinations.parse("127.0.0.1:5433")

    assert {:ok, %{match: {:host, "git.corp.internal"}, ports: :any}} =
             Destinations.parse("git.corp.internal")

    assert {:ok, %{match: {:cidr, {0xFD00, 0, 0, 0, 0, 0, 0, 5}, 128}, ports: [22]}} =
             Destinations.parse("[fd00::5]:22")

    assert {:error, _} = Destinations.parse("10.20.0.0/40")
    assert {:error, _} = Destinations.parse("host:99999")
    assert {:error, _} = Destinations.parse("not a host!")
  end

  test "matches addresses, ranges, resolved names and ports" do
    {:ok, range} = Destinations.parse("10.20.0.0/16:5432")
    assert Destinations.matches?(range, {10, 20, 4, 12}, 5432)
    refute Destinations.matches?(range, {10, 20, 4, 12}, 22)
    refute Destinations.matches?(range, {10, 21, 0, 1}, 5432)

    {:ok, name} = Destinations.parse("db.internal")
    resolve = fn "db.internal" -> [{10, 9, 8, 7}] end
    assert Destinations.matches?(name, {10, 9, 8, 7}, 5432, resolve)
    refute Destinations.matches?(name, {10, 9, 8, 6}, 5432, resolve)

    {:ok, exact} = Destinations.parse("127.0.0.1:5433")
    assert Destinations.exact?(exact, {127, 0, 0, 1})
    refute Destinations.exact?(range, {10, 20, 4, 12})
  end

  test "a name, or every name under one, matches by what MWT answered, never resolved" do
    assert {:ok, %{match: {:names, "corp.example"}, ports: [443]}} =
             Destinations.parse("*.Corp.Example:443")

    assert {:error, _} = Destinations.parse("*.:443")
    assert {:error, _} = Destinations.parse("a.*.corp.example")

    {:ok, names} = Destinations.parse("*.corp.example:443")
    {:ok, name} = Destinations.parse("db.corp.example")
    never = fn name -> flunk("#{name} resolved") end
    ip = {10, 9, 8, 7}
    mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A09, 0x0807}
    answered = %{ip => ["git.corp.example", "db.corp.example"]}

    assert Destinations.matches?(names, ip, 443, never, answered)
    assert Destinations.matches?(names, mapped, 443, never, answered)
    refute Destinations.matches?(names, ip, 22, never, answered)
    refute Destinations.matches?(names, {10, 9, 8, 6}, 443, never, answered)
    refute Destinations.matches?(names, ip, 443, never, %{ip => ["evilcorp.example"]})
    assert Destinations.matches?(name, ip, 5432, never, answered)
    refute Destinations.matches?(name, ip, 5432, never, %{ip => ["git.corp.example"]})

    # Without answers (no DNS in between), an exact name resolves as before;
    # every name under one matches nothing.
    refute Destinations.matches?(names, ip, 443, never, nil)
    assert Destinations.matches?(name, ip, 443, fn "db.corp.example" -> [ip] end, nil)
  end
end
