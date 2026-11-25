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
    test "to a public address goes under the grant on that names it more exactly, else the Internet" do
      internet = internet_on()

      for one <- connection_cases(@public) do
        alone = decide_connection(one)

        case decide_connection(one, [internet]) do
          # A grant on that opens it names it more exactly than the
          # Internet's, and answers as it would alone.
          answer when elem(alone, 0) in [:allow, :ask] ->
            assert answer == alone, inspect(one)

          # Off, or not opening it, a grant has no say.
          answer ->
            assert {:allow, %Grant{internet: true}, _allowance, about} = answer
            assert about.pattern == "#{:inet.ntoa(one.ip)}:#{one.port}"
        end
      end

      off = %{
        ip: hd(@public),
        port: 443,
        grant: network_grant(:off, nil, ["93.184.216.0/24"], [])
      }

      assert {:allow, %Grant{internet: true}, _allowance, _about} =
               decide_connection(off, [internet])
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

    test "to a public address with the Internet's grant off opens only for a network grant listing it" do
      internet = Grant.internet()

      for one <- connection_cases(@public) do
        case decide_connection(one, [internet]) do
          # Refused, naming the grant to turn on: the one naming it most
          # exactly, the Internet's when no other does.
          {:refuse, {:grant_off, grant}} ->
            assert grant in [one.grant, internet]
            assert Grant.state_at(grant, @now) == :off

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
      assert opens.(["93.184.216.0/24:22"]) == {:refuse, :grant_off}
      assert opens.([]) == {:refuse, :grant_off}

      # Off, the Internet's grant has no say: another grant that opens a
      # public address opens it.
      listed = %{
        ip: hd(@public),
        port: 443,
        grant: network_grant(:on, nil, ["93.184.216.0/24"], [])
      }

      assert {:ask, %Grant{id: "lan"}, _about} = decide_connection(listed, [internet])

      # With no Internet grant at all, a public address is the Internet's,
      # off.
      assert decide_connection(%{
               ip: hd(@public),
               port: 443,
               grant: network_grant(:off, nil, [], [])
             }) ==
               {:refuse, :internet_off}
    end

    test "the Internet never opens a private or reserved address, and asks only once it is read" do
      internet = %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

      for ip <- @private ++ @reserved, port <- @ports do
        assert {:refuse, reason} =
                 Policy.decide(snapshot([internet]), {:connection, ip, port}, @now)

        assert reason in [:private, :reserved]
      end

      assert {:allow, %Grant{internet: true}, _allowance, _about} =
               Policy.decide(snapshot([internet]), {:connection, hd(@public), 443}, @now)

      # Set to ask each time, a connection waits for its first bytes, as a
      # network grant's does: an address alone is nothing to ask about.
      bare = %{internet | allowances: []}

      assert {:ask, %Grant{internet: true}, _about} =
               Policy.decide(snapshot([bare]), {:connection, hd(@public), 443}, @now)

      # Off by the clock, it lets nothing through.
      over = %{internet | expires_at: @earlier}

      assert {:refuse, {:grant_off, %Grant{internet: true}}} =
               Policy.decide(snapshot([over]), {:connection, hd(@public), 443}, @now)
    end

    test "to this machine or a reserved range opens only for an entry naming that very address" do
      for one <- connection_cases(@reserved) do
        opened? = kind(decide_connection(one)) in [:allow, :ask]
        named? = one.on? and names_exactly?(one.grant.destinations, one.ip, one.port)

        assert opened? == named?,
               "#{:inet.ntoa(one.ip)}:#{one.port} with #{inspect(one.grant.destinations)}, on: #{one.on?}"

        refused =
          if Grant.state_at(one.grant, @now) == :off and
               names_exactly?(one.grant.destinations, one.ip, one.port),
             do: {:refuse, {:grant_off, one.grant}},
             else: {:refuse, :reserved}

        unless opened?, do: assert(decide_connection(one) == refused)
      end
    end

    test "to a private range opens only while a network grant listing it is on" do
      for one <- connection_cases(@private) do
        case decide_connection(one) do
          {:refuse, {:grant_off, grant}} ->
            assert grant == one.grant
            assert Grant.state_at(grant, @now) == :off
            assert grant.destinations != []

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
      assert {:refuse, {:grant_off, %{id: "corp"}}} = decide_at(corp(state: :off), ip, 443, facts)
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

      # On a tie, the one that lets it through: grants only give.
      allowed = %{wild | id: "allowed", allowances: [allowance(:all, nil)]}

      for grants <- [[allowed, wild], [wild, allowed]] do
        assert {:allow, %{id: "allowed"}, _, _} = decide.(grants)
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

  defp command_grant(state, expires_at, allowances) do
    %Grant{
      id: "deploy",
      name: "Deploy",
      kind: :command,
      state: state,
      expires_at: expires_at,
      script: "make deploy",
      dir: "/srv/app",
      allowances: allowances
    }
  end

  # What names the agent's own command: no id, Commands agents write's, or
  # one Ask to run commands had.
  @own_ids ["", "agent-commands", "commands", "any-command"]

  # Commands agents write, built in, on: an agent may ask.
  defp written(state \\ :on, allowances \\ []),
    do: %{Grant.agent_commands() | state: state, allowances: allowances}

  defp command_cases do
    for {state, expires_at, on?} <- @states,
        allowances <- [
          [],
          [allowance(:all, nil)],
          [allowance("run deploy", @later)],
          [allowance("run deploy", @earlier)],
          [allowance("run abc", @later)]
        ],
        named <-
          [nil, "", "deploy", "DEPLOY", " Deploy ", "nope", "agent-commands", "commands"] ++
            ["any-command", 42, %{}],
        sent <- [nil, "", "   ", "rm -rf ~", 42] do
      %{
        grant: command_grant(state, expires_at, allowances),
        on?: on?,
        ask: %{grant: named, script: sent, reason: "because"},
        named: if(is_binary(named), do: String.trim(named), else: ""),
        sent?: is_binary(sent) and String.trim(sent) != ""
      }
    end
  end

  describe "a command" do
    test "gets the one answer the rules give, in every combination" do
      for one <- command_cases() do
        expected =
          cond do
            # The agent's own: Commands agents write lets it ask, and you
            # approve each one.
            one.named in @own_ids and one.sent? -> :ask
            one.named in @own_ids -> {:refuse, :name_a_grant}
            # A saved command by its exact id: a name is not enough.
            one.named != "deploy" -> {:refuse, :no_such_grant}
            one.sent? -> {:refuse, :fixed_script}
            not one.on? -> {:refuse, :grant_off}
            covered?(one.grant.allowances, "run deploy", @now) -> :allow
            true -> :ask
          end

        answer = Policy.decide(snapshot([one.grant, written()]), {:command, one.ask}, @now)
        assert kind(answer) == expected, inspect(one)
      end
    end

    test "the agent writes is asked about, with nothing of a grant's, whatever grants allow" do
      # Commands agents write's allowances, had it any, let nothing through.
      every = [allowance(:all, nil)]

      for one <- command_cases(), one.named in @own_ids, one.sent? do
        assert Policy.decide(
                 snapshot([one.grant, written(:on, every)]),
                 {:command, one.ask},
                 @now
               ) ==
                 {:ask, nil, %{script: nil, dir: nil, pattern: nil}}
      end
    end

    test "the agent writes can't even ask while Commands agents write is off, or missing" do
      run = {:command, %{grant: nil, script: "ls"}}

      for grants <- [[written(:off)], []] do
        assert {:refuse, {:grant_off, %Grant{id: "agent-commands"}}} =
                 Policy.decide(snapshot(grants), run, @now)
      end
    end

    test "saved never takes text from the agent: its card shows your script" do
      for one <- command_cases(), one.named == "deploy" do
        case Policy.decide(snapshot([one.grant]), {:command, one.ask}, @now) do
          {:ask, _grant, about} ->
            assert Map.take(about, [:script, :dir, :pattern]) ==
                     %{script: "make deploy", dir: "/srv/app", pattern: "run deploy"}

            refute one.sent?

          {:allow, _grant, _allowance, about} ->
            assert about.script == "make deploy"
            refute one.sent?

          {:refuse, _reason} ->
            :ok
        end
      end
    end

    test "saved is given by no grant of another type" do
      others = [
        token_grant(:on, nil, ["api.example.com"], [allowance(:all, nil)]),
        network_grant(:on, nil, ["0.0.0.0/0"], [allowance(:all, nil)]),
        %Grant{id: "mwt-read", name: "MWT: read", kind: :mwt, tools: :read, state: :on}
      ]

      for one <- command_cases() do
        answer = Policy.decide(snapshot(others), {:command, one.ask}, @now)

        # The agent's own needs Commands agents write, which isn't there.
        if one.named in @own_ids and one.sent?,
          do: assert({:refuse, {:grant_off, %Grant{id: "agent-commands"}}} = answer),
          else: assert(match?({:refuse, _}, answer), inspect(one))
      end
    end

    test "is refused at once while host commands are locked, the agent's own included" do
      deploy = command_grant(:on, nil, [allowance(:all, nil)])
      locked = Map.put(snapshot([deploy, written()]), :locks, %{machine: %{you: @now}})

      assert {:refuse, {:locked, :machine, %Grant{id: "agent-commands"}}} =
               Policy.decide(locked, {:command, %{grant: nil, script: "ls"}}, @now)

      assert {:refuse, {:locked, :machine, %Grant{id: "deploy"}}} =
               Policy.decide(locked, {:command, %{grant: "deploy", script: nil}}, @now)
    end

    test "saved covers the credentials it runs with: no grant over them has a say, a lock does" do
      deploy = %{command_grant(:on, nil, [allowance(:all, nil)]) | with: ["github"]}
      run = {:command, %{grant: "deploy", script: nil}}
      decide = fn grants -> Policy.decide(snapshot([deploy | grants]), run, @now) end

      # With no grant over the credential, or one off or asking: the saved
      # command's own say.
      for token <- [
            [],
            [token_grant(:off, nil, ["api.example.com"], [])],
            [token_grant(:on, nil, ["api.example.com"], [])]
          ] do
        assert {:allow, %Grant{id: "deploy"}, _, _} = decide.(token)
      end

      assert {:ask, %Grant{id: "deploy"}, _} =
               Policy.decide(snapshot([%{deploy | allowances: []}]), run, @now)

      # Its credential locked, refused.
      locked = Map.put(snapshot([deploy]), :locks, %{{:credential, "github"} => %{you: @now}})

      assert {:refuse, {:locked, {:credential, "github"}, %Grant{id: "deploy"}}} =
               Policy.decide(locked, run, @now)
    end
  end

  describe "a grant saved when it could always ask" do
    test "keeps asking as Ask does, its ceiling gone: nothing it had goes through unasked" do
      fields = %{id: "g", name: "G", kind: :token, state: :on, allowances: []}

      for ceiling <- [:ask, :auto, :yolo, :allow] do
        grant = Grant.upgrade(Map.put(fields, :ceiling, ceiling))
        refute Map.has_key?(grant, :ceiling)
        refute Grant.auto_approved?(grant, @now)
        assert Grant.starts(grant) == [:off, :on, :auto]
      end
    end
  end

  describe "a grant to review" do
    test "is never on, starts only off, and no use goes through it" do
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

  describe "a request with no placeholder" do
    test "goes by its network alone: a token grant listing its host gives nothing" do
      for {state, expires_at, _on?} <- @states, hosts <- @listed, host <- @hosts do
        grant = token_grant(state, expires_at, hosts, [allowance(:all, nil)])
        request = request(host, {"GET", "/repos/a/b"}, :none)
        decide = fn grants -> Policy.decide(snapshot(grants), {:request, request}, @now) end

        assert decide.([grant]) == {:refuse, {:outside, "internet"}}
        assert decide.([grant, Grant.internet()]) == {:refuse, {:grant_off, Grant.internet()}}
        assert decide.([grant, internet_on()]) == :pass
      end
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
