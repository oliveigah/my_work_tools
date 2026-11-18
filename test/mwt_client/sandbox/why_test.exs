defmodule MWTClient.Sandbox.WhyTest do
  @moduledoc """
  Each answer of `mwt why HOST[:PORT]` (`MWTClient.Sandbox.Why`), from the
  rules alone, and once through the channel as the agent asks it.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Firewall, Grant, Policy, Why}

  doctest Why

  @now ~U[2026-11-17 12:00:00Z]

  defp internet(state \\ :on), do: %{Grant.internet() | state: state}

  defp lan(state, destinations),
    do: %Grant{
      id: "lan",
      name: "Office LAN",
      kind: :network,
      state: state,
      purpose: "The office",
      destinations: destinations
    }

  defp github(state),
    do: %Grant{
      id: "github",
      name: "GitHub",
      kind: :token,
      state: state,
      placeholder: "ghp_placeholder",
      hosts: ["api.github.com", "github.com"]
    }

  # Names resolve only as the test says; any other is a lookup MWT
  # shouldn't make.
  defp world(grants, opts \\ []) do
    test = self()

    resolve = fn name ->
      send(test, {:resolved, name})
      Map.get(Keyword.get(opts, :names, %{}), name, [])
    end

    snapshot =
      grants
      |> Policy.snapshot()
      |> Map.merge(%{own: [{192, 168, 1, 5}], resolve: resolve})

    %{
      snapshot: snapshot,
      firewall: Keyword.get(opts, :firewall, Firewall.new()),
      isolated: Keyword.get(opts, :isolated, false),
      now: @now
    }
  end

  defp answered(world, answered), do: put_in(world.snapshot[:answered], answered)

  defp why(target, world) do
    {:ok, text} = Why.explain(target, world)
    text
  end

  test "a private address under an off network grant says which, and how to ask" do
    text = why("10.1.2.3:5432", world([internet(), lan(:off, ["10.0.0.0/8:5432"])]))
    assert text =~ "10.1.2.3:5432: not reached now"

    assert text =~
             "Office LAN (network grant `lan`) covers 10.1.2.3 as 10.0.0.0/8:5432, and is off"

    assert text =~ ~s(mwt request lan --reason)

    on = why("10.1.2.3:5432", world([internet(), lan(:on, ["10.0.0.0/8:5432"])]))
    assert on =~ "10.1.2.3:5432: reached now"
    assert on =~ "and is on: each connection may wait for the user's approval"
  end

  test "a grant that lists another port says which ports it opens" do
    text = why("10.1.2.3:22", world([lan(:on, ["10.0.0.0/8:5432,6432"])]))
    assert text =~ "not reached now"
    assert text =~ "but not port 22: it opens 5432, 6432"
  end

  test "a private address no grant covers says to ask for access" do
    text = why("172.16.0.9:443", world([internet()]))
    assert text =~ "not reached now"
    assert text =~ "a private address"
    assert text =~ ~s(mwt request --need "172.16.0.9:443)
  end

  test "this machine or a reserved range opens only for an exact entry" do
    text = why("127.0.0.1:5433", world([lan(:on, ["127.0.0.0/8"])]))
    assert text =~ "not reached now"
    assert text =~ "only a network grant naming exactly this address opens it"

    exact = why("127.0.0.1:5433", world([lan(:on, ["127.0.0.1:5433"])]))
    assert exact =~ "reached now"
  end

  test "a public address follows the Internet grant" do
    assert why("93.184.216.34", world([internet()])) =~ "reached now"
    assert why("93.184.216.34", world([internet()])) =~ "No port given: port 443 is assumed"

    off = why("93.184.216.34:443", world([internet(:off)]))
    assert off =~ "not reached now"
    assert off =~ "the Internet grant opens it, and is off"
    assert off =~ "mwt request internet"
  end

  test "a token grant's host is reached, read by MWT; a request needs the grant on" do
    text = why("https://api.github.com/user", world([internet(:off), github(:off)]))
    assert text =~ "api.github.com:443: reached now"
    assert text =~ "GitHub (token grant `github`) lists it"
    assert text =~ "needs it on: ask for it with mwt request github"
    refute_received {:resolved, _}

    on = why("api.github.com", world([internet(:off), github(:on)]))
    assert on =~ "mwt exec github -- COMMAND"
  end

  test "a name no grant names is never looked up" do
    text = why("db.corp.example:5432", world([internet(), lan(:on, ["10.0.0.0/8"])]))
    assert text =~ "No grant names db.corp.example"
    refute_received {:resolved, _}
  end

  test "a name a network grant names is looked up, and judged by its address" do
    names = %{"db.internal" => [{10, 1, 2, 3}]}
    world = world([lan(:off, ["db.internal:5432"])], names: names)
    text = why("db.internal:5432", world)
    assert_received {:resolved, "db.internal"}
    assert text =~ "not reached now"
    assert text =~ "covers db.internal as db.internal:5432, and is off"

    gone = why("db.internal:5432", world([lan(:on, ["db.internal:5432"])]))
    assert gone =~ "lists db.internal, but it doesn't resolve here now"
  end

  # Step 17: with MWT's DNS in between, a name a network grant lists stands
  # for what MWT answered for it, and is never resolved here.
  test "a name under a network grant: what MWT answered, or why nothing was" do
    corp = lan(:off, ["*.corp.example:443"])

    off = why("git.corp.example", world([corp]) |> answered(%{}))
    refute_received {:resolved, _}
    assert off =~ "not reached now"
    assert off =~ "lists git.corp.example, and is off: MWT answers its names only while it is on"
    assert off =~ "mwt request lan"

    on = why("git.corp.example", world([%{corp | state: :on}]) |> answered(%{}))
    assert on =~ "is on, but MWT hasn't answered it yet: look it up now"

    answered =
      world([%{corp | state: :on}]) |> answered(%{{10, 4, 4, 4} => ["git.corp.example"]})

    reached = why("git.corp.example", answered)
    refute_received {:resolved, _}
    assert reached =~ "reached now"
    assert reached =~ "covers git.corp.example as *.corp.example:443, and is on"
  end

  test "a way out that isn't connected says so" do
    corp = %{lan(:on, ["10.0.0.0/8"]) | anchor: "wg0"}

    down = why("10.1.2.3:22", world([corp]) |> Map.put(:route, fn _ -> "eth0" end))
    assert down =~ "not reached now"
    assert down =~ "its network isn't connected: it goes only through the user's wg0"

    up = why("10.1.2.3:22", world([corp]) |> Map.put(:route, fn _ -> "wg0" end))
    assert up =~ "reached now"
  end

  test "the firewall: isolated says so first; a blocked service says not to work around it" do
    isolated = why("api.github.com", world([github(:on)], isolated: true))
    assert isolated =~ "not reached now"
    assert isolated =~ "MWT's firewall isolated this VM"

    blocked = why("pastebin.com:443", world([internet()]))
    assert blocked =~ "not reached now"
    assert blocked =~ "on the list of blocked services"
  end

  test "targets: a URL, an IPv6 address with a port, and what names nothing" do
    assert why("http://93.184.216.34/x", world([internet()])) =~ "93.184.216.34:80"
    assert why("[2606:2800:220:1:248:1893:25c8:1946]:8443", world([internet()])) =~ "]:8443"

    for bad <- ["", "a b", "host:99999", "host:x"] do
      assert {:error, "Name a host" <> _} = Why.explain(bad, world([]))
    end
  end

  test "an agent asks it over the channel" do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("why")

    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Office LAN",
        "purpose" => "The office",
        "destinations" => "10.0.0.0/8:5432"
      })

    assert {0, text} = Channel.answer("why", %{"target" => "10.9.9.9:5432"}, username)
    assert text =~ "Office LAN (network grant `office-lan`) covers 10.9.9.9"
    assert text =~ "mwt request office-lan"

    assert {1, _} = Channel.answer("why", %{"target" => 7}, username)
  end
end
