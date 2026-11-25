defmodule MWTClient.Sandbox.PolicyHostRulesTest do
  @moduledoc """
  A network's host limits (`MWTClient.Sandbox.HostLimits`) and grants over
  single hosts of it (`MWTClient.Sandbox.Network`), the Internet's
  included: what a host list's entries became, Block and Ask a blocked
  host, Auto a grant over the host. A blocked host is refused whatever the
  grants say; otherwise the most permissive grant that is on and covers
  the host counts. Checked over every combination of a small world: each
  host list and the hosts it covers, the network grant's mode (asking each
  time or auto-approved), whether it always asks, and an allowance for uses
  like the one decided. Each test is a sentence that holds for all of them.
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox.{HostLimits, Network}

  doctest HostLimits

  @public {93, 184, 216, 34}
  @hosts ~w(api.example.com example.com deep.api.example.com other.test)
  @entries [
    [],
    [%{host: "example.com", action: :ask}],
    [%{host: "api.example.com", action: :block}],
    [%{host: "example.com", action: :block}, %{host: "api.example.com", action: :auto}],
    [%{host: "*.example.com", action: :auto}, %{host: "api.example.com", action: :ask}]
  ]

  # The grants and their networks' limits, a host list's entries moved off
  # its grant as MWT does as it starts.
  defp world(grants) do
    {grants, networks} = Network.migrate(grants, [])
    grants |> snapshot() |> Map.put(:limits, Map.new(networks, &{&1.id, &1.limits}))
  end

  defp internet(mode, rules, allowances) do
    %{
      Grant.internet()
      | state: :on,
        host_rules: rules,
        allowances: if(mode == :auto, do: [allowance(:all, nil)], else: []) ++ allowances
    }
  end

  defp lan(mode, rules, allowances) do
    %Grant{
      id: "lan",
      name: "LAN",
      kind: :network,
      state: :on,
      destinations: ["10.0.0.0/8"],
      host_rules: rules,
      allowances: if(mode == :auto, do: [allowance(:all, nil)], else: []) ++ allowances
    }
  end

  defp request(host, under),
    do: %{host: host, method: "GET", path: "/v1", headers: [], body: "", under: under}

  # What the entries covering `host` said, said again plainly: each covers
  # its name and every name under it.
  defp actions_for(rules, host) do
    for %{host: entry, action: action} <- rules,
        name = String.trim_leading(entry, "*."),
        host == name or String.ends_with?(host, "." <> name),
        do: action
  end

  # Whether a host is blocked: an entry that blocked or asked covers it,
  # nothing that waited for you going unasked.
  defp blocked?(actions), do: :block in actions or :ask in actions

  defp similar(host), do: Describe.request(request(host, nil)).pattern

  defp cases do
    for host <- @hosts,
        rules <- @entries,
        mode <- [:ask, :auto],
        similar? <- [false, true],
        do: %{host: host, rules: rules, mode: mode, similar?: similar?}
  end

  describe "a request the Internet's connection carried" do
    test "is refused for a blocked host, else goes as the most permissive grant covering it" do
      for %{host: host, rules: rules, mode: mode, similar?: similar?} = one <- cases() do
        allowances = if similar?, do: [allowance(similar(host), @later)], else: []

        decided =
          Policy.decide(
            world([internet(mode, rules, allowances)]),
            {:network_request, request(host, "internet")},
            @now
          )

        actions = actions_for(rules, host)

        expected =
          cond do
            blocked?(actions) -> {:refuse, :host_blocked}
            # The Internet lets through what it doesn't ask about without
            # a word to the server.
            mode == :auto -> :pass
            # A grant over the host that auto-approves gives what the
            # Internet's would ask about.
            :auto in actions or similar? -> :allow
            true -> :ask
          end

        assert kind(decided) == expected, inspect(one)
      end
    end

    test "names the grant over the host that let it through where the Internet's asks" do
      grant = internet(:ask, [%{host: "example.com", action: :auto}], [])

      assert {:allow, %Grant{id: "internet-example-com"}, _allowance, _about} =
               Policy.decide(
                 world([grant]),
                 {:network_request, request("api.example.com", "internet")},
                 @now
               )

      assert {:ask, %Grant{id: "internet"}, _about} =
               Policy.decide(
                 world([grant]),
                 {:network_request, request("other.test", "internet")},
                 @now
               )
    end

    test "is refused when the grant it went under is off" do
      grant = %{internet(:auto, [], []) | state: :off}

      assert {:refuse, {:grant_off, _}} =
               Policy.decide(
                 world([grant]),
                 {:network_request, request("x.test", "internet")},
                 @now
               )
    end

    test "with names beside its host, is refused when any of them is blocked" do
      grant = internet(:auto, [%{host: "paste.test", action: :block}], [])
      plain = Map.put(request("allowed.test", "internet"), :names, ["paste.test"])

      assert {:refuse, {:host_blocked, "internet", "paste.test"}} =
               Policy.decide(world([grant]), {:network_request, plain}, @now)
    end

    test "on a network blocked by default, reaches only the hosts its Reachable list names" do
      {:ok, limits} = HostLimits.put(%HostLimits{default: :blocked}, "api.example.com", false)
      snapshot = Map.put(snapshot([internet(:auto, [], [])]), :limits, %{"internet" => limits})
      decide = &Policy.decide(snapshot, {:network_request, request(&1, "internet")}, @now)

      assert :pass = decide.("deep.api.example.com")
      assert {:refuse, {:host_blocked, "internet", :default}} = decide.("example.com")
      assert {:refuse, {:host_blocked, "internet", :default}} = decide.("other.test")
    end
  end

  describe "a request on another network" do
    test "is refused for a blocked host, else goes as the most permissive grant covering it" do
      for %{host: host, rules: rules, mode: mode, similar?: similar?} = one <- cases() do
        allowances = if similar?, do: [allowance(similar(host), @later)], else: []

        decided =
          Policy.decide(
            world([lan(mode, rules, allowances)]),
            {:network_request, request(host, "lan")},
            @now
          )

        actions = actions_for(rules, host)

        expected =
          cond do
            blocked?(actions) -> {:refuse, :host_blocked}
            # The grant over the host auto-approves, whatever the
            # network's grant would ask.
            :auto in actions -> :allow
            mode == :auto or similar? -> :allow
            true -> :ask
          end

        assert kind(decided) == expected, inspect(one)
      end
    end
  end

  describe "a connection" do
    test "waits for its first bytes when a name answered for its address may be blocked" do
      for rules <- @entries, mode <- [:ask, :auto] do
        snapshot =
          [internet(mode, rules, [])]
          |> world()
          |> Map.put(:answered, %{@public => ["api.example.com"]})

        decided = Policy.decide(snapshot, {:connection, @public, 443}, @now)
        actions = actions_for(rules, "api.example.com")

        expected =
          cond do
            blocked?(actions) -> :ask
            # The grant over the host names it more exactly.
            :auto in actions -> :allow
            mode == :ask -> :ask
            true -> :allow
          end

        assert kind(decided) == expected, inspect({rules, mode})
      end
    end

    test "MWT can't read is refused when the name it asked for or any answered is blocked" do
      for rules <- @entries,
          mode <- [:ask, :auto],
          sni <- [nil, "other.test", "api.example.com"] do
        snapshot =
          [internet(mode, rules, [])]
          |> world()
          |> Map.put(:answered, %{@public => ["example.com"]})

        decided = Policy.decide(snapshot, {:unread, @public, 443, [sni]}, @now)

        actions =
          for name <- Enum.reject([sni, "example.com"], &is_nil/1),
              action <- actions_for(rules, name),
              do: action

        expected =
          cond do
            Enum.any?([sni, "example.com"], &(&1 && blocked?(actions_for(rules, &1)))) ->
              {:refuse, :host_blocked}

            :auto in actions or mode == :auto ->
              :allow

            true ->
              :ask
          end

        assert kind(decided) == expected, inspect({rules, mode, sni})
      end
    end
  end

  describe "a placeholder over plain HTTP" do
    test "is refused wherever it is in the request, the host listed or not" do
      grant = %Grant{
        id: "github",
        name: "GitHub",
        kind: :token,
        state: :on,
        placeholder: @placeholder,
        hosts: ["api.example.com"],
        allowances: [allowance(:all, nil)]
      }

      for request <- [
            request("api.example.com", nil)
            |> Map.put(:headers, [{"authorization", "Bearer " <> @placeholder}]),
            Map.put(request("api.example.com", nil), :body, "token=" <> @placeholder),
            Map.put(request("evil.test", nil), :path, "/?t=" <> @placeholder)
          ] do
        plain = Map.put(request, :plain?, true)

        assert {:refuse, {:plain_http, %Grant{id: "github"}}} =
                 Policy.decide(snapshot([grant]), {:request, plain}, @now)
      end

      # One with none goes as any request does.
      assert :pass =
               Policy.decide(
                 snapshot([grant, internet_on()]),
                 {:request, Map.put(request("api.example.com", nil), :plain?, true)},
                 @now
               )
    end
  end
end
