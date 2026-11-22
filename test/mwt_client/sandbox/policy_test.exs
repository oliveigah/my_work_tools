defmodule MWTClient.Sandbox.PolicyTest do
  @moduledoc """
  The rules of `MWTClient.Sandbox.Policy`, checked for every combination of
  a small world (`MWTClient.PolicyCase`): each state a grant can be in,
  each set of allowances on it, each host and address, each way a
  placeholder travels. A test here is a sentence that must hold for all of
  them, so a failure prints the one combination that breaks it. Requests
  have policy_requests_test.exs and policy_requests_in_time_test.exs, so
  the three run side by side.
  """
  use MWTClient.PolicyCase, async: true

  doctest MWTClient.Sandbox.Placeholder
  doctest MWTClient.Sandbox.Allowance

  ## Connections

  @public [{93, 184, 216, 34}, {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]
  @private [{10, 1, 2, 3}, {172, 16, 9, 9}, {100, 64, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 5}]
  # Loopback, link-local (cloud metadata), unspecified, an address of this
  # machine in a private range, and loopback written as IPv4-in-IPv6.
  @reserved [
    {127, 0, 0, 1},
    {169, 254, 169, 254},
    {0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {192, 168, 1, 5},
    {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
  ]
  @ports [443, 5432]
  @destinations [
    [],
    ["10.0.0.0/8"],
    ["10.1.2.3"],
    ["10.1.2.3:5432"],
    ["127.0.0.1:5432"],
    ["127.0.0.0/8"],
    ["0.0.0.0/0", "::/0"],
    ["192.168.0.0/16"],
    ["192.168.1.5"],
    ["169.254.169.254:443"],
    ["db.internal:5432"],
    ["localhost"],
    ["fd00::/8"],
    ["not a destination"]
  ]

  defp network_grant(state, expires_at, destinations, allowances) do
    %Grant{
      id: "lan",
      name: "LAN",
      kind: :network,
      state: state,
      expires_at: expires_at,
      destinations: destinations,
      allowances: allowances
    }
  end

  defp connection_cases(addresses) do
    for ip <- addresses,
        port <- @ports,
        {state, expires_at, on?} <- @states,
        destinations <- @destinations,
        allowances <-
          subsets([
            allowance(:all, nil),
            allowance("#{:inet.ntoa(ip)}:#{port}", @later),
            allowance("#{:inet.ntoa(ip)}:#{port}", @earlier)
          ]) do
      %{
        ip: ip,
        port: port,
        on?: on?,
        grant: network_grant(state, expires_at, destinations, allowances)
      }
    end
  end

  defp decide_connection(one, more \\ []) do
    Policy.decide(snapshot([one.grant | more]), {:connection, one.ip, one.port}, @now)
  end

  # The entries that name `ip` exactly, with a port that fits: said here as
  # text, apart from the parser.
  defp names_exactly?(destinations, ip, port) do
    address = "#{:inet.ntoa(ip)}"

    Enum.any?(destinations, fn entry ->
      entry == address or entry == "#{address}:#{port}"
    end)
  end

  describe "a connection" do
    test "to a public address goes under the Internet while it is on, whatever the others" do
      internet = %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

      for one <- connection_cases(@public) do
        assert {:allow, %Grant{internet: true}, _allowance, about} =
                 decide_connection(one, [internet])

        assert about.pattern == "#{:inet.ntoa(one.ip)}:#{one.port}"
      end
    end

    test "an address in this machine's own networks is never public, whatever its range" do
      internet = %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

      # The LAN's IPv6 prefix, which gives neighbours global addresses, and a
      # network a VPN routes, numbered from public space.
      networks = [{{0x2A02, 0x8108, 1, 2, 0, 0, 0, 0}, 64}, {{203, 0, 113, 0}, 24}]
      snapshot = [internet] |> snapshot() |> Map.put(:networks, networks)

      for ip <- [{0x2A02, 0x8108, 1, 2, 0, 0, 0, 1}, {203, 0, 113, 7}] do
        assert {:refuse, reason} = Policy.decide(snapshot, {:connection, ip, 443}, @now)
        refute reason == :internet_off
      end

      assert {:allow, %Grant{internet: true}, _allowance, _about} =
               Policy.decide(snapshot, {:connection, {93, 184, 215, 14}, 443}, @now)
    end

    test "to a public address with the Internet off opens only for a network grant listing it" do
      internet = Grant.internet()

      for one <- connection_cases(@public) do
        case decide_connection(one, [internet]) do
          {:refuse, reason} ->
            assert reason == :internet_off

          answer ->
            assert kind(answer) in [:allow, :ask]
            assert one.on?, inspect(one)
            assert one.grant.destinations != []
        end
      end

      opens = fn destinations ->
        one = %{ip: hd(@public), port: 443, grant: network_grant(:on, nil, destinations, [])}
        kind(decide_connection(one, [internet]))
      end

      assert opens.(["0.0.0.0/0"]) == :ask
      assert opens.(["93.184.216.0/24:443"]) == :ask
      assert opens.(["93.184.216.0/24:22"]) == {:refuse, :internet_off}
      assert opens.([]) == {:refuse, :internet_off}
      # No Internet grant at all is the Internet off.
      assert decide_connection(%{
               ip: hd(@public),
               port: 443,
               grant: network_grant(:off, nil, [], [])
             }) ==
               {:refuse, :internet_off}
    end

    test "the Internet never opens a private or reserved address, and never asks" do
      internet = %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

      for ip <- @private ++ @reserved, port <- @ports do
        assert {:refuse, reason} =
                 Policy.decide(snapshot([internet]), {:connection, ip, port}, @now)

        assert reason in [:private, :reserved]
      end

      bare = %{internet | allowances: []}

      assert {:allow, %Grant{internet: true}, _allowance, _about} =
               Policy.decide(snapshot([bare]), {:connection, hd(@public), 443}, @now)

      # Off by the clock, it lets nothing through.
      over = %{internet | expires_at: @earlier}

      assert {:refuse, :internet_off} =
               Policy.decide(snapshot([over]), {:connection, hd(@public), 443}, @now)
    end

    test "to this machine or a reserved range opens only for an entry naming that very address" do
      for one <- connection_cases(@reserved) do
        opened? = kind(decide_connection(one)) in [:allow, :ask]
        named? = one.on? and names_exactly?(one.grant.destinations, one.ip, one.port)

        assert opened? == named?,
               "#{:inet.ntoa(one.ip)}:#{one.port} with #{inspect(one.grant.destinations)}, on: #{one.on?}"

        unless opened?, do: assert(decide_connection(one) == {:refuse, :reserved})
      end
    end

    test "to a private range opens only while a network grant listing it is on" do
      for one <- connection_cases(@private) do
        case decide_connection(one) do
          {:refuse, reason} ->
            assert reason == :private

          answer ->
            assert kind(answer) in [:allow, :ask]
            assert one.on?, inspect(one)
            assert one.grant.destinations != []
        end
      end

      # The ranges and names of the world do open what they cover.
      opens = fn destinations, ip, port ->
        one = %{ip: ip, port: port, grant: network_grant(:on, nil, destinations, [])}
        kind(decide_connection(one))
      end

      assert opens.(["10.0.0.0/8"], {10, 1, 2, 3}, 443) == :ask
      assert opens.(["10.1.2.3:5432"], {10, 1, 2, 3}, 5432) == :ask
      assert opens.(["10.1.2.3:5432"], {10, 1, 2, 3}, 443) == {:refuse, :private}
      assert opens.(["db.internal:5432"], {10, 1, 2, 3}, 5432) == :ask
      assert opens.(["fd00::/8"], {0xFD00, 0, 0, 0, 0, 0, 0, 5}, 22) == :ask
      assert opens.(["192.168.0.0/16"], {172, 16, 9, 9}, 443) == {:refuse, :private}
    end

    test "is allowed only by an allowance for that address and port, in time" do
      for one <- connection_cases(@private ++ @reserved) do
        case decide_connection(one) do
          {:allow, grant, allowance, about} ->
            assert grant == one.grant
            assert about.pattern == "#{:inet.ntoa(one.ip)}:#{one.port}"
            assert covered?([allowance], about.pattern, @now)

          {:ask, _grant, about} ->
            refute covered?(one.grant.allowances, about.pattern, @now)

          _refused ->
            :ok
        end
      end
    end

    test "is never opened by a grant that isn't a network grant" do
      others =
        for kind <- [:token, :command, :mwt] do
          %Grant{
            id: "#{kind}",
            name: "#{kind}",
            kind: kind,
            state: :on,
            hosts: ["10.1.2.3"],
            destinations: ["0.0.0.0/0", "10.1.2.3", "127.0.0.1"],
            allowances: [allowance(:all, nil)]
          }
        end

      for ip <- @private ++ @reserved, port <- @ports do
        answer = Policy.decide(snapshot(others), {:connection, ip, port}, @now)
        assert match?({:refuse, _}, answer), "#{:inet.ntoa(ip)}:#{port}"
      end
    end
  end

  # Step 17: a name a network grant lists opens only the addresses MWT's
  # DNS answered for it; a grant with a way out of its own opens nothing
  # while this machine doesn't route the address through it.
  describe "a private network" do
    defp corp(attrs \\ []) do
      struct!(
        %Grant{
          id: "corp",
          name: "Corp",
          kind: :network,
          state: :on,
          destinations: ["*.corp.example:443", "db.corp.example:5432"],
          allowances: [allowance(:all, nil)]
        },
        attrs
      )
    end

    defp decide_at(grant, ip, port, facts) do
      [grant]
      |> snapshot(resolve: fn _ -> flunk("a name is never resolved at connect time") end)
      |> Map.merge(facts)
      |> Policy.decide({:connection, ip, port}, @now)
    end

    test "a name opens only an address answered for a name it covers, on a port it lists" do
      ip = {10, 9, 8, 7}

      assert {:refuse, :private} = decide_at(corp(), ip, 443, %{answered: %{}})

      assert {:allow, %{id: "corp"}, _, %{listed_as: "*.corp.example:443"}} =
               decide_at(corp(), ip, 443, %{answered: %{ip => ["git.corp.example"]}})

      # `*.` covers the name itself too, as a token grant's hosts do; a name
      # merely ending the same way isn't under it.
      assert {:allow, _, _, _} =
               decide_at(corp(), ip, 443, %{answered: %{ip => ["corp.example"]}})

      for name <- ["evilcorp.example", "corp.example.evil"] do
        assert {:refuse, :private} = decide_at(corp(), ip, 443, %{answered: %{ip => [name]}})
      end

      assert {:refuse, :private} =
               decide_at(corp(), ip, 5432, %{answered: %{ip => ["git.corp.example"]}})

      assert {:allow, _, _, %{listed_as: "db.corp.example:5432"}} =
               decide_at(corp(), ip, 5432, %{answered: %{ip => ["db.corp.example"]}})

      # This machine and reserved ranges: never by a name, whatever was answered.
      assert {:refuse, :reserved} =
               decide_at(corp(), {127, 0, 0, 1}, 443, %{
                 answered: %{{127, 0, 0, 1} => ["git.corp.example"]}
               })
    end

    test "a name answered while the grant is off still opens nothing" do
      ip = {10, 9, 8, 7}
      facts = %{answered: %{ip => ["git.corp.example"]}}
      assert {:refuse, :private} = decide_at(corp(state: :off), ip, 443, facts)
    end

    test "a way out of its own: open only while the address is routed through it" do
      ip = {10, 9, 8, 7}
      answered = %{ip => ["git.corp.example"]}
      grant = corp(anchor: "wg0")

      assert {:allow, %{id: "corp"}, _, _} =
               decide_at(grant, ip, 443, %{answered: answered, via: "wg0"})

      for via <- ["eth0", nil] do
        assert {:refuse, {:network_down, %{id: "corp"}}} =
                 decide_at(grant, ip, 443, %{answered: answered, via: via})
      end

      # With no route known, an anchored grant opens nothing either.
      assert {:refuse, {:network_down, _}} = decide_at(grant, ip, 443, %{answered: answered})

      # Another grant that opens it without an anchor still does.
      lan = %Grant{
        id: "lan",
        name: "LAN",
        kind: :network,
        state: :on,
        destinations: ["10.0.0.0/8"],
        allowances: [allowance(:all, nil)]
      }

      assert {:allow, %{id: "lan"}, _, _} =
               [grant, lan]
               |> snapshot()
               |> Map.merge(%{answered: answered, via: "eth0"})
               |> Policy.decide({:connection, ip, 443}, @now)
    end

    test "of grants that open it, the one naming it most exactly goes first, in any order" do
      ip = {10, 9, 8, 7}
      answered = %{answered: %{ip => ["dev.corp.example"]}}

      grant = fn id, destinations, allowances ->
        %Grant{
          id: id,
          name: id,
          kind: :network,
          state: :on,
          destinations: destinations,
          allowances: allowances
        }
      end

      exact = grant.("exact", ["dev.corp.example:443"], [allowance(:all, nil)])
      wild = grant.("wild", ["*.corp.example:443"], [])
      wilder = grant.("wilder", ["*.example:443"], [])
      range = grant.("range", ["10.0.0.0/8"], [])
      address = grant.("address", ["10.9.8.7"], [])

      decide = fn grants ->
        grants |> snapshot() |> Map.merge(answered) |> Policy.decide({:connection, ip, 443}, @now)
      end

      for grants <- [[wild, exact, range], [range, exact, wild], [exact, wild, range]] do
        assert {:allow, %{id: "exact"}, _, %{listed_as: "dev.corp.example:443"}} = decide.(grants)
      end

      for grants <- [[wilder, wild, range], [range, wild, wilder]] do
        assert {:ask, %{id: "wild"}, _} = decide.(grants)
      end

      assert {:ask, %{id: "range"}, _} = decide.([range])
      assert {:ask, %{id: "address"}, _} = decide.([range, address])

      # On a tie, the one that would ask: an allowance never decides which.
      allowed = %{wild | id: "allowed", allowances: [allowance(:all, nil)]}

      for grants <- [[allowed, wild], [wild, allowed]] do
        assert {:ask, %{id: "wild"}, _} = decide.(grants)
      end
    end

    test "a request through a network grant is that grant's to allow, like any use of it" do
      request = %{
        host: "git.corp.example",
        method: "GET",
        path: "/api/v4/projects",
        headers: [],
        body: "",
        under: "corp"
      }

      decide = fn grant -> Policy.decide(snapshot([grant]), {:network_request, request}, @now) end

      assert {:allow, %{id: "corp"}, _, %{pattern: "GET git.corp.example/api/v4/projects"}} =
               decide.(corp())

      assert {:ask, %{id: "corp"}, %{title: "GET git.corp.example/api/v4/projects"}} =
               decide.(corp(allowances: []))

      similar = allowance("GET git.corp.example/api/v4/projects", nil)
      assert {:allow, _, ^similar, _} = decide.(corp(allowances: [similar]))
      assert {:refuse, {:grant_off, _}} = decide.(corp(state: :off))

      # The Internet's, or none: nothing for a network grant to say.
      assert :pass =
               Policy.decide(
                 snapshot([corp()]),
                 {:network_request, %{request | under: "internet"}},
                 @now
               )
    end
  end

  ## Commands

  defp command_grant(state, expires_at, script, allowances) do
    %Grant{
      id: "deploy",
      name: "Deploy",
      kind: :command,
      state: state,
      expires_at: expires_at,
      script: script,
      dir: script && "/srv/app",
      allowances: allowances
    }
  end

  defp command_cases do
    for {state, expires_at, on?} <- @states,
        script <- [nil, "make deploy"],
        allowances <- [[], [allowance(:all, nil)], [allowance("run abc", @later)]],
        named <- [nil, "", "deploy", "DEPLOY", " Deploy ", "nope", "github", 42, %{"a" => 1}],
        sent <- [nil, "", "   ", "rm -rf ~", 42] do
      %{
        grant: command_grant(state, expires_at, script, allowances),
        on?: on?,
        ask: %{grant: named, script: sent, reason: "because"}
      }
    end
  end

  describe "a command" do
    test "is never let through unasked, whatever allowances its grant carries" do
      for one <- command_cases() do
        answer = Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now)
        # The compiler works this one out by itself: the clause for commands
        # has no way to answer anything else.
        assert elem(answer, 0) in [:ask, :refuse], inspect(one)
      end
    end

    test "is asked about only when the agent names a command grant, by its exact id, that is on by the clock" do
      for one <- command_cases() do
        answer = Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now)

        # Its id, not its name: "DEPLOY" and "Deploy" name nothing.
        named? = is_binary(one.ask.grant) and String.trim(one.ask.grant) == "deploy"

        if kind(answer) == :ask do
          assert named? and one.on?, inspect(one)
        end

        if named? and not one.on?, do: assert(kind(answer) == {:refuse, :grant_off})
      end
    end

    test "of a grant with your own script never takes text from the agent" do
      for one <- command_cases(), one.grant.script != nil do
        case Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now) do
          {:ask, _grant, about} ->
            assert about == %{script: "make deploy", dir: "/srv/app"}
            refute is_binary(one.ask.script) and String.trim(one.ask.script) != ""

          {:refuse, _reason} ->
            :ok
        end
      end
    end

    test "runs nowhere when no command grant exists, whatever else does" do
      others = [
        token_grant(:on, nil, ["api.example.com"], [allowance(:all, nil)]),
        network_grant(:on, nil, ["0.0.0.0/0"], [allowance(:all, nil)]),
        %Grant{id: "mwt-read", name: "MWT: read", kind: :mwt, tools: :read, state: :on}
      ]

      for one <- command_cases() do
        assert Policy.decide(snapshot(others), {:command, one.ask}, @now) ==
                 {:refuse, :no_command_grant}
      end
    end
  end

  describe "a ceiling" do
    # Every request case, at each ceiling.
    defp ceiling_cases do
      for one <- Enum.take_every(request_cases(), 3), ceiling <- [:ask, :allow] do
        {%{one | grant: %{one.grant | ceiling: ceiling}}, ceiling}
      end
    end

    defp decide_with(one),
      do:
        Policy.decide(
          snapshot([one.grant, other_token_grant()]),
          {:request, one.request},
          @now
        )

    test "always asks never allows a request, whatever its allowances" do
      for {one, :ask} <- ceiling_cases() do
        answer = decide_with(one)
        refute kind(answer) == :allow, inspect(one)

        # Refusals stay what they were; what was let through or asked
        # about asks.
        expected =
          case kind(decide_request(%{one | grant: %{one.grant | ceiling: :allow}})) do
            :allow -> :ask
            other -> other
          end

        assert kind(answer) == expected, inspect(one)
      end
    end

    test "allowing, it answers as the rules for requests say" do
      for {one, :allow} <- ceiling_cases() do
        assert decide_with(one) == decide_request(one)
      end
    end

    test "connections and MWT's tools follow it too" do
      ip = {10, 1, 2, 3}
      lan = network_grant(:on, nil, ["10.0.0.0/8"], [allowance(:all, nil)])

      assert {:allow, _, _, _} =
               Policy.decide(snapshot([lan]), {:connection, ip, 443}, @now)

      assert {:ask, _, _} =
               Policy.decide(snapshot([%{lan | ceiling: :ask}]), {:connection, ip, 443}, @now)

      tools = %Grant{
        id: "mwt-create",
        name: "MWT: create",
        kind: :mwt,
        tools: :create,
        state: :on,
        allowances: [allowance(:all, nil)]
      }

      use = %{grant: :create, tool: "create_note", kind: :note, over_limit: false}

      assert {:allow, _, _, _} = Policy.decide(snapshot([tools]), {:tool, use}, @now)

      assert {:ask, _, _} =
               Policy.decide(snapshot([%{tools | ceiling: :ask}]), {:tool, use}, @now)

      # Past the hour's limit, adding asks whatever the allowances say.
      assert {:ask, _, _} =
               Policy.decide(snapshot([tools]), {:tool, %{use | over_limit: true}}, @now)
    end

    test "which ceilings a grant takes, and what always asks takes away" do
      token = token_grant(:on, nil, ["api.example.com"], [allowance(:all, nil)])
      assert Grant.ceilings(token) == [:ask, :allow]
      assert Grant.auto_approvable?(token)
      assert Grant.auto_approved?(token, @now)

      asks = %{token | ceiling: :ask}
      refute Grant.auto_approvable?(asks)
      refute Grant.auto_approved?(asks, @now)
      assert Grant.starts(asks) == [:off, :on]

      assert Grant.ceilings(Grant.internet()) == [:allow]
      assert Grant.ceiling(%{Grant.internet() | ceiling: :ask}) == :allow
      assert Grant.ceilings(Grant.ask_to_run()) == [:ask]
      assert Grant.ceiling(%{Grant.ask_to_run() | ceiling: :allow}) == :ask
    end

    test "a grant saved with YOLO's ceiling, or none, now takes allowances; one that YOLO couldn't open asks" do
      fields = %{id: "g", name: "G", kind: :token}

      assert Grant.upgrade(Map.put(fields, :ceiling, :yolo)).ceiling == :allow
      assert Grant.upgrade(fields).ceiling == :allow
      assert Grant.upgrade(Map.put(fields, :ceiling, :auto)).ceiling == :ask
      assert Grant.upgrade(Map.put(fields, :ceiling, :ask)).ceiling == :ask
    end
  end

  describe "a grant to review" do
    test "is never on, starts only disabled, and no use goes through it" do
      proposal = %{agent: "Claude", thread: nil, reason: "r", minutes: 60, at: @now}

      grant = %{
        token_grant(:off, nil, ["api.example.com"], [])
        | proposal: Map.put(proposal, :reviewed_at, nil)
      }

      assert Grant.proposed?(grant)
      assert Grant.to_review?(grant)
      assert Grant.starts(grant) == [:off]

      request = request("api.example.com", {"GET", "/repos/a/b"}, :bearer)

      assert {:refuse, {:grant_off, _}} =
               Policy.decide(snapshot([grant]), {:request, request}, @now)

      reviewed = %{grant | proposal: Map.put(proposal, :reviewed_at, @now)}
      assert Grant.proposed?(reviewed)
      refute Grant.to_review?(reviewed)
      assert Grant.starts(reviewed) == [:off, :on, :auto]
    end
  end

  describe "a request with the Internet off" do
    test "with no placeholder, it reaches a token grant's host only while a grant listing it is on" do
      for {state, expires_at, on?} <- @states, hosts <- @listed, host <- @hosts do
        grant = token_grant(state, expires_at, hosts, [])
        request = request(host, {"GET", "/repos/a/b"}, :none)
        listed? = host_listed?(host, hosts)

        read_only =
          Policy.decide(snapshot([grant]), {:request, Map.put(request, :under, :read_only)}, @now)

        under_internet =
          Policy.decide(snapshot([grant]), {:request, Map.put(request, :under, "internet")}, @now)

        cond do
          listed? and on? -> assert read_only == :pass
          listed? -> assert read_only == {:refuse, {:grant_off, grant}}
          true -> assert read_only == {:refuse, :internet_off}
        end

        # The Internet on, the host is the Internet's: no grant needed.
        assert under_internet == :pass
      end
    end

    test "a check holding the grant off says so, and another grant listing the host opens it" do
      grant = token_grant(:on, nil, ["api.example.com"], [])
      request = Map.put(request("api.example.com", {"GET", "/x"}, :none), :under, :read_only)

      failing = Map.put(snapshot([grant]), :failing, %{"github" => "the VPN is down"})

      assert {:refuse, {:check_failing, ^grant, "the VPN is down"}} =
               Policy.decide(failing, {:request, request}, @now)

      # Hex lists *.example.com and is on.
      assert :pass =
               Policy.decide(
                 %{failing | grants: [grant, other_token_grant()]},
                 {:request, request},
                 @now
               )
    end
  end

  describe "a grant only its subgrants use" do
    test "its placeholder opens nothing; sent elsewhere it is still a leak" do
      grant = %{
        token_grant(:on, nil, ["api.example.com"], [allowance(:all, nil)])
        | reach: :subgrants
      }

      request = request("api.example.com", {"GET", "/repos/a/b"}, :bearer)

      assert {:refuse, {:subgrants_only, ^grant}} =
               Policy.decide(snapshot([grant]), {:request, request}, @now)

      elsewhere = request("evil.test", {"GET", "/x"}, :bearer)

      assert {:refuse, {:wrong_host, _}} =
               Policy.decide(snapshot([grant]), {:request, elsewhere}, @now)
    end

    test "its hosts aren't read, and it has nothing to turn on" do
      grant = %{token_grant(:off, nil, ["api.example.com"], []) | reach: :subgrants}
      refute Policy.reads?([grant], "api.example.com")
      assert Policy.reads?([%{grant | reach: :vm}], "api.example.com")
      assert Grant.starts(grant) == [:off]
    end
  end

  describe "which hosts are read" do
    test "every host a token grant lists, on or off, and no other" do
      for {state, expires_at, _on?} <- @states, hosts <- @listed, host <- @hosts do
        grants = [
          token_grant(state, expires_at, hosts, []),
          network_grant(:on, nil, ["evil.test"], [])
        ]

        assert Policy.reads?(grants, host) == host_listed?(host, hosts)
      end

      refute Policy.reads?([token_grant(:on, nil, ["api.example.com"], [])], nil)
    end
  end
end
