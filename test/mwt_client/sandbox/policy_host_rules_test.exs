defmodule MWTClient.Sandbox.PolicyHostRulesTest do
  @moduledoc """
  A network grant's host list (`Grant.host_rules`), the Internet's
  included, checked over every combination of a small world: each entry
  and the hosts it covers, the grant's mode (asking each time or
  auto-approved), whether it always asks, and an allowance for uses like
  the one decided. Each test is a sentence that holds for all of them.
  """
  use MWTClient.PolicyCase, async: true

  @public {93, 184, 216, 34}
  @hosts ~w(api.example.com example.com deep.api.example.com other.test)
  @entries [
    [],
    [%{host: "example.com", action: :ask}],
    [%{host: "api.example.com", action: :block}],
    [%{host: "example.com", action: :block}, %{host: "api.example.com", action: :auto}],
    [%{host: "*.example.com", action: :auto}, %{host: "api.example.com", action: :ask}]
  ]

  defp internet(mode, rules, allowances) do
    %{
      Grant.internet()
      | state: :on,
        host_rules: rules,
        allowances: if(mode == :auto, do: [allowance(:all, nil)], else: []) ++ allowances
    }
  end

  defp lan(mode, ceiling, rules, allowances) do
    %Grant{
      id: "lan",
      name: "LAN",
      kind: :network,
      state: :on,
      destinations: ["10.0.0.0/8"],
      ceiling: ceiling,
      host_rules: rules,
      allowances: if(mode == :auto, do: [allowance(:all, nil)], else: []) ++ allowances
    }
  end

  defp request(host, under),
    do: %{host: host, method: "GET", path: "/v1", headers: [], body: "", under: under}

  # What the entry naming `host` most exactly says, said again plainly.
  defp entry_for(rules, host) do
    rules
    |> Enum.filter(fn %{host: entry} ->
      name = String.trim_leading(entry, "*.")
      host == name or String.ends_with?(host, "." <> name)
    end)
    |> Enum.max_by(&{String.trim_leading(&1.host, "*.") == host, byte_size(&1.host)}, fn ->
      nil
    end)
  end

  defp similar(host), do: Describe.request(request(host, nil)).pattern

  defp cases do
    for host <- @hosts,
        rules <- @entries,
        mode <- [:ask, :auto],
        similar? <- [false, true],
        do: %{host: host, rules: rules, mode: mode, similar?: similar?}
  end

  describe "a request the Internet's connection carried" do
    test "goes as the entry naming its host most exactly says, else as the Internet's mode" do
      for %{host: host, rules: rules, mode: mode, similar?: similar?} = one <- cases() do
        allowances = if similar?, do: [allowance(similar(host), @later)], else: []
        grant = internet(mode, rules, allowances)

        decided =
          Policy.decide(snapshot([grant]), {:network_request, request(host, "internet")}, @now)

        expected =
          case entry_for(rules, host) do
            %{action: :block} -> {:refuse, :host_blocked}
            # Only *Allow similar* covers it, never the Internet's every-use one.
            %{action: :ask} -> if similar?, do: :allow, else: :ask
            # The Internet lets through what it doesn't ask about without
            # a word to the server.
            %{action: :auto} -> :pass
            nil when mode == :auto -> :pass
            nil -> if similar?, do: :allow, else: :ask
          end

        assert kind(decided) == expected, inspect(one)
      end
    end

    test "names the entry on the card when one asked" do
      grant = internet(:auto, [%{host: "example.com", action: :ask}], [])

      assert {:ask, _grant, %{host_entry: "example.com"}} =
               Policy.decide(
                 snapshot([grant]),
                 {:network_request, request("api.example.com", "internet")},
                 @now
               )
    end

    test "is refused when the grant it went under is off" do
      grant = %{internet(:auto, [], []) | state: :off}

      assert {:refuse, {:grant_off, _}} =
               Policy.decide(
                 snapshot([grant]),
                 {:network_request, request("x.test", "internet")},
                 @now
               )
    end

    test "with names beside its host, is held by the strictest entry for any of them" do
      grant = internet(:auto, [%{host: "paste.test", action: :block}], [])
      plain = Map.put(request("allowed.test", "internet"), :names, ["paste.test"])

      assert {:refuse, {:host_blocked, _, "paste.test"}} =
               Policy.decide(snapshot([grant]), {:network_request, plain}, @now)
    end
  end

  describe "a request on another network grant" do
    test "Auto lets it through unless the grant always asks; Block refuses it" do
      for %{host: host, rules: rules, mode: mode, similar?: similar?} = one <- cases(),
          ceiling <- [:allow, :ask] do
        allowances = if similar?, do: [allowance(similar(host), @later)], else: []
        grant = lan(mode, ceiling, rules, allowances)
        decided = Policy.decide(snapshot([grant]), {:network_request, request(host, "lan")}, @now)

        expected =
          case {entry_for(rules, host), ceiling} do
            {%{action: :block}, _ceiling} -> {:refuse, :host_blocked}
            {_entry, :ask} -> :ask
            {%{action: :ask}, :allow} -> if similar?, do: :allow, else: :ask
            {%{action: :auto}, :allow} -> :allow
            {nil, :allow} -> if mode == :auto or similar?, do: :allow, else: :ask
          end

        assert kind(decided) == expected, inspect(Map.put(one, :ceiling, ceiling))
      end
    end
  end

  describe "a connection" do
    test "waits for its first bytes when a name answered for its address is asked about or blocked" do
      for rules <- @entries, mode <- [:ask, :auto] do
        grant = internet(mode, rules, [])

        snapshot =
          [grant]
          |> snapshot()
          |> Map.put(:answered, %{@public => ["api.example.com"]})

        decided = Policy.decide(snapshot, {:connection, @public, 443}, @now)

        expected =
          case entry_for(rules, "api.example.com") do
            %{action: action} when action in [:ask, :block] -> :ask
            _auto_or_none -> if mode == :auto, do: :allow, else: :ask
          end

        assert kind(decided) == expected, inspect({rules, mode})
      end
    end

    test "MWT can't read is held by the strictest entry for the name it asked for or any answered" do
      for rules <- @entries,
          mode <- [:ask, :auto],
          sni <- [nil, "other.test", "api.example.com"] do
        grant = internet(mode, rules, [])

        snapshot =
          [grant]
          |> snapshot()
          |> Map.put(:answered, %{@public => ["example.com"]})

        decided = Policy.decide(snapshot, {:unread, @public, 443, [sni]}, @now)

        actions =
          for name <- Enum.reject([sni, "example.com"], &is_nil/1),
              %{action: action} <- [entry_for(rules, name)],
              do: action

        expected =
          cond do
            :block in actions -> {:refuse, :host_blocked}
            :ask in actions -> :ask
            :auto in actions -> :allow
            mode == :auto -> :allow
            true -> :ask
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
                 snapshot([grant]),
                 {:request, Map.put(request("api.example.com", nil), :plain?, true)},
                 @now
               )
    end
  end
end
