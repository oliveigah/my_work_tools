defmodule MWTClient.Sandbox.AllowanceSettlesTest do
  @moduledoc """
  An allowance added while cards wait settles only what it would have let
  through, had it been there when they were asked: *Allow every use* and
  Auto-approve never a host its grant's host list asks about, nor an add
  of MWT's tools past the hour's limit. The card you decide goes by your
  decision.
  """
  use ExUnit.Case, async: true

  doctest MWTClient.Sandbox.Policy, only: [settles?: 3]

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server
  alias MWTClient.Vault.Store

  setup do
    MWTClient.VaultHelpers.unlocked_identity("allowance-settles")
  end

  defp request(host, path, grant_id) do
    %{
      host: host,
      port: 443,
      method: "GET",
      path: path,
      headers: [{"host", host}, {"user-agent", "curl"}],
      body: "",
      under: grant_id
    }
  end

  defp held(username, request),
    do: Task.async(fn -> Server.call(username, {:authorize_network, request}, :infinity) end)

  defp waiting_for(username, host) do
    Enum.find_value(1..300, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, &(&1.host == host)) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end) || flunk("nothing waited for #{host}")
  end

  defp still_waiting?(username, id),
    do: Enum.any?(Sandbox.snapshot(username).waiting, &(&1.id == id))

  defp corp(username) do
    {:ok, corp} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Corp",
        "purpose" => "The corp network",
        "destinations" => "*.corp.example:443"
      })

    {:ok, _} = Sandbox.turn_on(username, corp.id, 60, :ask)
    {:ok, _} = Sandbox.host_rule_set(username, corp.id, {:put, "admin.corp.example", :ask})
    corp
  end

  test "Allow every use on one card leaves the card a host list holds for asking",
       %{username: username} do
    corp = corp(username)
    wiki = held(username, request("wiki.corp.example", "/page", corp.id))
    admin = held(username, request("admin.corp.example", "/delete-everything", corp.id))

    wiki_card = waiting_for(username, "wiki.corp.example")
    admin_card = waiting_for(username, "admin.corp.example")
    assert admin_card.host_entry == "admin.corp.example"

    :ok = Sandbox.decide(username, wiki_card.id, {:allow, :all, 60})
    assert {:ok, _} = Task.await(wiki)

    # Still its own card, which only you decide.
    assert still_waiting?(username, admin_card.id)
    :ok = Sandbox.decide(username, admin_card.id, :deny)
    assert {:deny, 403, body} = Task.await(admin)
    assert body =~ "mwt_denied_by_user"
  end

  test "Auto-approve and Enabled, auto leave a waiting host-list Ask card", %{username: username} do
    {:ok, _} = Sandbox.host_rule_set(username, "internet", {:put, "example.com", :ask})
    {:ok, _} = Sandbox.set_mode(username, "internet", :ask)

    asking = held(username, request("example.com", "/held", "internet"))
    card = waiting_for(username, "example.com")
    assert card.host_entry == "example.com"

    {:ok, _} = Sandbox.set_mode(username, "internet", :all)
    assert still_waiting?(username, card.id)

    corp = corp(username)
    admin = held(username, request("admin.corp.example", "/", corp.id))
    admin_card = waiting_for(username, "admin.corp.example")
    {:ok, _} = Sandbox.set_start(username, corp.id, :auto)
    assert still_waiting?(username, admin_card.id)

    # Allow similar still settles it, as it would a new one.
    :ok = Sandbox.decide(username, card.id, {:allow, :similar, 60})
    assert {:ok, "internet"} = Task.await(asking)
    :ok = Sandbox.decide(username, admin_card.id, :allow_once)
    assert {:ok, _} = Task.await(admin)
  end

  test "the card you decide goes, whatever its allowance covers of others", %{username: username} do
    corp = corp(username)
    admin = held(username, request("admin.corp.example", "/", corp.id))
    card = waiting_for(username, "admin.corp.example")

    # Every use, chosen on the card itself (the page offers it only on
    # others): that one goes; the allowance covers the host no further.
    :ok = Sandbox.decide(username, card.id, {:allow, :all, 60})
    assert {:ok, _} = Task.await(admin)

    again = held(username, request("admin.corp.example", "/", corp.id))
    next = waiting_for(username, "admin.corp.example")
    refute next.id == card.id
    :ok = Sandbox.decide(username, next.id, :deny)
    Task.await(again)
  end

  test "an add past the hour's limit is settled by no allowance, only by you",
       %{username: username} do
    server = Store.whereis(Server, username)
    now = System.monotonic_time(:millisecond)
    :sys.replace_state(server, &%{&1 | tool_creates: List.duplicate({now, 10}, 200)})

    add = fn title ->
      use = %{
        grant: :create,
        tool: "create_note",
        kind: :note,
        title: title,
        bytes: 60,
        args: %{"title" => title, "body" => ""}
      }

      {:ask, id} = Server.call(username, {:tool, use})
      id
    end

    one = add.("One")
    two = add.("Two")
    card = Enum.find(Sandbox.snapshot(username).waiting, &(&1.id == one))
    assert is_nil(card.pattern)

    # Auto-approve again: they still ask.
    {:ok, _} = Sandbox.set_mode(username, "mwt-create", :ask)
    {:ok, _} = Sandbox.set_mode(username, "mwt-create", :all)
    assert still_waiting?(username, one) and still_waiting?(username, two)

    # Every use, on one of them: that one goes, the other still asks.
    :ok = Sandbox.decide(username, one, {:allow, :all, 60})
    refute still_waiting?(username, one)
    assert still_waiting?(username, two)
  end
end
