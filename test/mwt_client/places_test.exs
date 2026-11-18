defmodule MWTClient.PlacesTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Places
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "keeps each tool's page and place apart", %{username: username} do
    assert Places.paths(username) == %{}
    assert Places.recall(username, :notes) == %{}

    :ok = Places.visit(username, :sandbox, "/tools/sandbox/grants")
    :ok = Places.keep(username, :notes, %{id: "n1", mode: "preview"})
    :ok = Places.visit(username, :notes, "/tools/notes")
    :ok = Places.keep(username, :notes, %{id: "n2", mode: "split"})

    assert Places.paths(username) == %{sandbox: "/tools/sandbox/grants", notes: "/tools/notes"}
    assert Places.recall(username, :notes) == %{id: "n2", mode: "split"}
    assert Places.recall(username, :sandbox) == %{}
  end

  test "another identity's places stay its own", %{username: username} do
    other = also_unlock("other")
    :ok = Places.visit(username, :notes, "/tools/notes")
    :ok = Places.keep(username, :notes, %{id: "mine"})

    assert Places.paths(other) == %{}
    assert Places.recall(other, :notes) == %{}
  end

  test "locking drops them, and a locked identity keeps nothing", %{username: username} do
    :ok = Places.keep(username, :http, %{tabs: [%{url: "https://example.test", token: "t"}]})
    assert %{tabs: [_]} = Places.recall(username, :http)

    :ok = Store.close(username)

    assert :ok = Places.keep(username, :http, %{tabs: []})
    assert :ok = Places.visit(username, :http, "/tools/http")
    assert Places.recall(username, :http) == %{}
    assert Places.paths(username) == %{}
  end
end
