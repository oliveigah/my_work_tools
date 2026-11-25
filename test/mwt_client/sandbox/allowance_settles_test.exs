defmodule MWTClient.Sandbox.AllowanceSettlesTest do
  @moduledoc """
  An allowance added while cards wait settles only what it would have let
  through, had it been there when they were asked: *Allow every use* and
  Auto-approve every card of its grant, *Allow similar* only those like
  the one decided, none a grant that always asks nor an add of MWT's
  tools past the hour's limit. The card you decide goes by your decision.
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
    corp
  end

  test "Allow every use on one card settles the others its grant asked about",
       %{username: username} do
    corp = corp(username)
    wiki = held(username, request("wiki.corp.example", "/page", corp.id))
    admin = held(username, request("admin.corp.example", "/delete-everything", corp.id))

    wiki_card = waiting_for(username, "wiki.corp.example")
    admin_card = waiting_for(username, "admin.corp.example")
    assert admin_card.grant_id == corp.id

    :ok = Sandbox.decide(username, wiki_card.id, {:allow, :all, 60})
    # Each answer says what decided it: you, on the card you decided; the
    # allowance your choice there made, on the card it settled.
    wiki_card_id = wiki_card.id
    assert {:ok, _, %{by: :you, card: ^wiki_card_id}} = Task.await(wiki)

    assert {:ok, _, %{by: :allowance, card: ^wiki_card_id, allowance: %{origin: %{kind: :card}}}} =
             Task.await(admin)

    refute still_waiting?(username, admin_card.id)
  end

  test "Allow similar settles only the cards like the one decided", %{username: username} do
    corp = corp(username)
    first = held(username, request("wiki.corp.example", "/page", corp.id))
    card = waiting_for(username, "wiki.corp.example")
    admin = held(username, request("admin.corp.example", "/delete-everything", corp.id))
    admin_card = waiting_for(username, "admin.corp.example")

    :ok = Sandbox.decide(username, card.id, {:allow, :similar, 60})
    assert {:ok, _, %{by: :you}} = Task.await(first)
    assert still_waiting?(username, admin_card.id)

    :ok = Sandbox.decide(username, admin_card.id, :deny)
    assert {:deny, 403, body} = Task.await(admin)
    assert body =~ "mwt_denied_by_user"
  end

  test "Auto-approve settles what its grant asked about", %{username: username} do
    corp = corp(username)
    admin = held(username, request("admin.corp.example", "/", corp.id))
    card = waiting_for(username, "admin.corp.example")

    {:ok, _} = Sandbox.set_mode(username, corp.id, :all)
    assert {:ok, _, %{by: :allowance, allowance: %{origin: %{kind: :auto}}}} = Task.await(admin)
    refute still_waiting?(username, card.id)
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
