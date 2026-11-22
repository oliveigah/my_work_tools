defmodule MWTClient.Sandbox.ReadingTest do
  @moduledoc """
  Which hosts the proxy reads: a default for any host, and hosts you opted
  in or out, the one naming a host most exactly deciding.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Reading

  test "with no rule, every host is read, or none, as the default says" do
    reading = Reading.new()
    assert Reading.read?(reading, "example.com")
    refute Reading.read?(Reading.set_default(reading, :token_hosts), "example.com")
    assert Reading.read?(reading, nil)
  end

  test "a host opted in or out, and every name under it; the most exact entry decides" do
    {:ok, reading} = Reading.put(Reading.new(), "Example.com", false)
    {:ok, reading} = Reading.put(reading, "api.example.com", true)
    {:ok, reading} = Reading.put(reading, "*.cdn.example.com", false)

    refute Reading.read?(reading, "example.com")
    refute Reading.read?(reading, "www.example.com")
    assert Reading.read?(reading, "api.example.com")
    assert Reading.read?(reading, "v2.api.example.com")
    refute Reading.read?(reading, "img.cdn.example.com")
    assert Reading.read?(reading, "example.org")

    # With only token grants' hosts read, an opted-in host still is.
    reading = Reading.set_default(reading, :token_hosts)
    assert Reading.read?(reading, "api.example.com")
    refute Reading.read?(reading, "example.org")

    assert %{host: "api.example.com", read?: true} = Reading.rule(reading, "v2.api.example.com")
    assert Reading.rule(reading, "example.org") == nil
  end

  test "an entry again replaces its rule; taken off, the host follows the default" do
    {:ok, reading} = Reading.put(Reading.new(), "pinned.example", false)
    {:ok, reading} = Reading.put(reading, "pinned.example", true)
    assert reading.rules == [%{host: "pinned.example", read?: true}]

    reading = Reading.remove(reading, "Pinned.Example")
    assert reading.rules == []
  end

  test "an entry is a host name; a URL is taken for its host, an address refused" do
    assert {:ok, "api.example.com"} = Reading.entry("https://API.example.com:8443/v1?x=1")
    assert {:ok, "*.example.com"} = Reading.entry(" *.example.com. ")
    assert {:error, "10.0.0.5 is an address" <> _} = Reading.entry("10.0.0.5")
    assert {:error, _} = Reading.entry("not a host")
    assert {:error, _} = Reading.entry("")
  end

  test "a saved one keeps what it held; none saved is a new one" do
    {:ok, reading} = Reading.put(Reading.new(), "pinned.example", false)
    assert Reading.upgrade(Map.from_struct(reading)) == reading
    assert Reading.upgrade(nil) == Reading.new()
  end
end
