defmodule MWTClient.Sandbox.NetworkTest do
  @moduledoc """
  Networks as resources of their own (`MWTClient.Sandbox.Network`): the
  grants over one network, each over all of it or part of it, the most
  permissive that is on giving; a lock on the network for all of them; the
  network kept as MWT starts again and carried by an export.
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Gate, Network}

  doctest Network

  @db {10, 1, 2, 3}

  defp lan(state, mode) do
    grant = %Grant{
      id: "lan",
      name: "LAN",
      kind: :network,
      destinations: ["10.0.0.0/8:443", "*.corp.example:443"]
    }

    case {state, mode} do
      {:on, :auto} -> %{grant | state: :on, allowances: [allowance(:all, nil)]}
      {:on, :ask} -> %{grant | state: :on}
      {:off, _mode} -> Grant.put_down(grant)
    end
  end

  # A grant over the database's host alone, auto-approving.
  defp db(network) do
    %Grant{
      id: "lan-db",
      name: "LAN: db",
      kind: :network,
      network: network,
      scope: ["db.corp.example:443"],
      destinations: ["db.corp.example:443"],
      state: :on,
      allowances: [allowance(:all, nil)]
    }
  end

  defp world(grants) do
    {grants, _networks} = Network.migrate(grants, [])
    grants |> snapshot() |> Map.put(:answered, %{@db => ["db.corp.example"]})
  end

  defp request(host),
    do: %{host: host, method: "GET", path: "/", headers: [], body: "", under: nil}

  describe "grants over one network" do
    test "a grant over part of it that auto-approves gives its hosts where the network's asks" do
      snapshot = world([lan(:on, :ask), db("lan")])

      assert {:allow, %Grant{id: "lan-db"}, _, _} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("db.corp.example") | under: "lan"}},
                 @now
               )

      assert {:ask, %Grant{id: "lan"}, _about} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("wiki.corp.example") | under: "lan"}},
                 @now
               )
    end

    test "with the network's grant off, the part's grant gives its hosts alone, and nothing the rest" do
      snapshot = world([lan(:off, :ask), db("lan")])

      # The database's address opens under the grant over it, by the name
      # MWT's DNS answered for it.
      assert {:allow, %Grant{id: "lan-db"}, _, _} =
               Policy.decide(snapshot, {:connection, @db, 443}, @now)

      under = "lan-db"

      assert {:allow, %Grant{id: "lan-db"}, _, _} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("db.corp.example") | under: under}},
                 @now
               )

      # Refused, naming the grant that would give it.
      assert {:refuse, {:grant_off, %Grant{id: "lan"}}} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("wiki.corp.example") | under: under}},
                 @now
               )
    end

    test "a part's grant that is off has no say: the network's gives its hosts too" do
      off = Grant.put_down(db("lan"))
      snapshot = world([lan(:on, :auto), off])

      assert {:allow, %Grant{id: "lan"}, _, _} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("db.corp.example") | under: "lan"}},
                 @now
               )

      assert {:allow, %Grant{id: "lan"}, _, _} =
               Policy.decide(
                 snapshot,
                 {:network_request, %{request("wiki.corp.example") | under: "lan"}},
                 @now
               )
    end

    test "every grant over a network is the network's to lock" do
      {grants, [network]} = Network.migrate([lan(:on, :auto), db("lan")], [])
      assert network.id == "lan"
      assert Enum.all?(grants, &(Grant.resource(&1) == {:network, "lan"}))
    end
  end

  describe "through the server" do
    setup do
      %{username: username} = MWTClient.VaultHelpers.unlocked_identity("networks")
      %{username: username}
    end

    test "a network grant makes its network; the network's lock holds its every grant", %{
      username: username
    } do
      {:ok, lan} =
        Sandbox.create_grant(username, %{
          "kind" => "network",
          "name" => "LAN",
          "purpose" => "The office network",
          "destinations" => "10.0.0.0/8"
        })

      assert %{networks: networks} = Sandbox.snapshot(username)

      assert %Network{id: "lan", destinations: ["10.0.0.0/8"]} =
               Enum.find(networks, &(&1.id == lan.id))

      {:ok, _} = Sandbox.turn_on(username, lan.id, 60, :all)
      assert {:ok, _} = Gate.destination(username, @db, 443)

      :ok = Sandbox.lock(username, {:network, lan.id})
      assert {:deny, words} = Gate.destination(username, @db, 443)
      assert words =~ "locked"

      # Edited, the network follows its grant over all of it.
      {:ok, _} =
        Sandbox.update_grant(username, lan.id, %{
          "name" => "LAN",
          "purpose" => "The office network",
          "destinations" => "10.0.0.0/8\n192.168.0.0/16"
        })

      assert %Network{destinations: ["10.0.0.0/8", "192.168.0.0/16"]} =
               Enum.find(Sandbox.snapshot(username).networks, &(&1.id == lan.id))

      # A resource of its own, the network stays when its last grant goes,
      # and goes only when removed itself; the Internet never does.
      :ok = Sandbox.unlock(username, {:network, lan.id})
      :ok = Sandbox.delete_grant(username, lan.id)
      assert Enum.any?(Sandbox.snapshot(username).networks, &(&1.id == lan.id))

      :ok = Sandbox.delete_resource(username, {:network, lan.id})
      assert [%Network{id: "internet"}] = Sandbox.snapshot(username).networks
      assert {:error, :built_in} = Sandbox.delete_resource(username, {:network, "internet"})
    end
  end
end
