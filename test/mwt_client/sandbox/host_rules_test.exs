defmodule MWTClient.Sandbox.HostRulesTest do
  @moduledoc """
  A list of entries naming hosts, shared by what MWT reads and a network's
  host limits: which entry speaks for a host, and what an entry can
  be.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.HostRules

  test "the entry naming a host most exactly speaks for it" do
    rules = [
      %{host: "example.com", action: :block},
      %{host: "*.api.example.com", action: :ask},
      %{host: "v1.api.example.com", action: :auto}
    ]

    assert %{action: :ask} = HostRules.rule(rules, "api.example.com")
    assert %{action: :ask} = HostRules.rule(rules, "v2.api.example.com")
    assert %{action: :auto} = HostRules.rule(rules, "v1.api.example.com")
    assert %{action: :block} = HostRules.rule(rules, "www.example.com")
    assert %{action: :block} = HostRules.rule(rules, "Example.COM.")
    assert HostRules.rule(rules, "notexample.com") == nil
    assert HostRules.rule(rules, "example.com.evil.test") == nil
    assert HostRules.rule(rules, nil) == nil
  end

  test "an entry is a host name, taken from a URL when given one; never an address" do
    assert HostRules.entry(" https://API.Example.com:8443/v1?x=1 ") == {:ok, "api.example.com"}
    assert HostRules.entry("*.example.com") == {:ok, "*.example.com"}
    assert {:error, "10.0.0.5 is an address" <> _} = HostRules.entry("10.0.0.5")
    assert {:error, _} = HostRules.entry("")
    assert {:error, _} = HostRules.entry("not a host")
  end

  test "putting one replaces the entry of the same name, up to a limit; removing takes it off" do
    {:ok, rules} = HostRules.put([], %{host: "Example.com", action: :ask}, 2)
    {:ok, rules} = HostRules.put(rules, %{host: "example.com", action: :block}, 2)
    assert rules == [%{host: "example.com", action: :block}]

    # With or without its star, it covers the same names: one entry.
    {:ok, rules} = HostRules.put(rules, %{host: "*.example.com", action: :ask}, 2)
    assert rules == [%{host: "*.example.com", action: :ask}]

    {:ok, rules} = HostRules.put(rules, %{host: "b.test", action: :ask}, 2)
    assert {:error, "At most 2 hosts."} = HostRules.put(rules, %{host: "c.test", action: :ask}, 2)

    assert HostRules.remove(rules, " EXAMPLE.com ") == [%{host: "b.test", action: :ask}]
    assert HostRules.remove(rules, "*.b.test") == [%{host: "*.example.com", action: :ask}]
  end
end
