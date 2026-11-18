defmodule MWTClient.Sandbox.RoutesTest do
  @moduledoc """
  The interface this machine routes an address through
  (`MWTClient.Sandbox.Routes`), which a network grant's way out is checked
  against, and the form's checks of a private network's fields.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Routes

  doctest Routes

  test "loopback is routed through an interface of its own, read from the system" do
    assert is_binary(Routes.via({127, 0, 0, 1}))
    # Kept a moment: asked again, the same.
    assert Routes.via({127, 0, 0, 1}) == Routes.via({127, 0, 0, 1})
  end

  test "a connection is bound to its way out only where the system can bind one" do
    assert Routes.options(nil) == []

    case :os.type() do
      {:unix, :linux} -> assert Routes.options("wg0") == [bind_to_device: "wg0"]
      _other -> assert Routes.options("wg0") == []
    end
  end

  test "a network grant's DNS server and way out are checked as the form takes them" do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("routes")

    base = %{
      "kind" => "network",
      "name" => "Corp",
      "purpose" => "The company's network",
      "destinations" => "*.corp.example:443\n10.0.0.0/8"
    }

    assert {:error, %{resolver: _}} =
             Sandbox.create_grant(username, Map.put(base, "resolver", "dns.corp.example"))

    assert {:error, %{anchor: _}} =
             Sandbox.create_grant(username, Map.put(base, "anchor", "wg0; rm -rf /"))

    assert {:ok, grant} =
             Sandbox.create_grant(
               username,
               Map.merge(base, %{"resolver" => " 10.8.0.1:5353 ", "anchor" => "wg0"})
             )

    assert {grant.resolver, grant.anchor} == {"10.8.0.1:5353", "wg0"}
    assert grant.destinations == ["*.corp.example:443", "10.0.0.0/8"]
  end
end
