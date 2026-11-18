defmodule MWTClient.HttpClient.ResourcesTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.HttpClient.HistoryMetadata
  alias MWTClient.HttpClient.Resources
  alias MWTClient.Storage
  alias MWTClient.Vault
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "stores and searches history entries", %{username: username} do
    request = Req.new(url: "https://example.test/health")
    response = %Req.Response{status: 204, body: "healthy"}
    metadata = HistoryMetadata.new(%{description: "Health check", tags: ["system", "health"]})

    identifier = Resources.record(username, metadata, request, response)

    assert {:ok, {^identifier, stored, ^request, ^response}} = Resources.get(username, identifier)
    assert %HistoryMetadata{description: "Health check", tags: ["system", "health"]} = stored
    assert stored.search_text =~ "https://example.test/health"
    assert [{^identifier, ^stored, ^request, ^response}] = Resources.all(username)

    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "HEALTH")
    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "system")
    assert [{^identifier, ^stored, _, _}] = Resources.search(username, "healthy")
    assert Resources.search(username, "missing") == []

    assert [summary] = Resources.summaries(username)

    assert {^identifier, "Health check", ["system", "health"], _at, 0, :get,
            %URI{host: "example.test", path: "/health"}, 204} = summary

    assert Resources.summaries(username, "HEALTH") == [summary]
    assert Resources.summaries(username, "missing") == []

    assert {:ok, {^identifier, ^stored, ^request, {:response, 204, %{}, response_size}}} =
             Resources.outline(username, identifier)

    assert response_size == byte_size(response.body)
  end

  test "clears stored history", %{username: username} do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: "https://example.test"),
      %Req.Response{status: 200}
    )

    assert :ok = Resources.clear(username)
    assert Resources.all(username) == []
  end

  test "summarizes failed requests with the client error status", %{username: username} do
    identifier =
      Resources.record(
        username,
        HistoryMetadata.new(%{}),
        Req.new(url: "https://example.test/slow"),
        Req.TransportError.exception(reason: :timeout)
      )

    assert [
             {^identifier, nil, [], _at, 0, :get, %URI{path: "/slow"}, 599}
           ] = Resources.summaries(username)
  end

  test "rewrites the whole history, numbering the entries afresh", %{username: username} do
    old = record(username, "https://example.test/old")

    entries =
      for path <- ["/first", "/second"] do
        request = Req.new(url: "https://example.test" <> path)
        response = %Req.Response{status: 201, body: "created"}
        metadata = HistoryMetadata.with_search_text(HistoryMetadata.new(%{}), request, response)
        {metadata, request, response}
      end

    :ok =
      Resources.rewrite(username, fn current ->
        # Given oldest first and without identifiers.
        assert [{%HistoryMetadata{}, %Req.Request{url: %URI{path: "/old"}}, _}] = current
        entries
      end)

    assert [
             {second, _, %Req.Request{url: %URI{path: "/second"}}, _},
             {first, _, %Req.Request{url: %URI{path: "/first"}}, _}
           ] = Resources.all(username)

    assert old < first and first < second
    assert Resources.get(username, old) == :error
    assert {:ok, {^second, _, _, {:response, 201, _, 7}}} = Resources.outline(username, second)
    assert [{^first, _, _, _}] = Resources.search(username, "/first")
    assert record(username, "https://example.test/next") > second
  end

  test "a rewrite keeps a request recorded while it runs", %{username: username} do
    record(username, "https://example.test/before")

    :ok =
      Resources.rewrite(username, fn current ->
        record(username, "https://example.test/meanwhile")
        current
      end)

    assert [_, _] = Resources.all(username)
    assert [_] = Resources.search(username, "meanwhile")
  end

  test "deletes one entry and keeps the rest", %{username: username} do
    kept = record(username, "https://example.test/one")
    dropped = record(username, "https://example.test/two")

    assert :ok = Resources.delete(username, dropped)
    assert Resources.delete(username, dropped) == :error
    assert Resources.get(username, dropped) == :error
    assert Resources.outline(username, dropped) == :error
    assert {:ok, _entry} = Resources.get(username, kept)
  end

  test "survives a lock and unlock, restoring the counter", %{
    username: username,
    password: password
  } do
    first = record(username, "https://example.test/one")
    last = record(username, "https://example.test/two")

    :ok = Store.close(username)
    refute Store.open?(username)

    {:ok, _profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(username, key)

    assert {:ok, {^first, _, _, _}} = Resources.get(username, first)
    assert {:ok, {^last, _, _, _}} = Resources.get(username, last)
    assert {:ok, {^last, _, _, {:response, 200, _, _}}} = Resources.outline(username, last)
    assert record(username, "https://example.test/three") > last
  end

  test "a recorded entry, and a tag edit, are written by the time they return", %{
    username: username
  } do
    id = record(username, "https://api.example.test/health")
    {:ok, _entry} = MWTClient.HttpClient.Core.add_tag(username, id, "smoke")

    # Read on another connection: committed, not waiting on a later flush.
    tags =
      Task.async(fn ->
        Storage.run(username, :journal, fn repo ->
          repo.query!("SELECT tags FROM http_requests WHERE id = ?", [id]).rows
        end)
      end)

    assert Task.await(tags) == [[~s(["smoke"])]]
  end

  test "the history on disk is encrypted", %{username: username} do
    record(username, "https://api.example.test/health")
    :ok = Resources.clear(username)
    record(username, "https://api.example.test/health")
    blob = on_disk(username, :journal)
    :ok = Store.close(username)

    assert byte_size(blob) > 0
    refute String.contains?(blob, "api.example.test")
    refute String.contains?(blob, "Elixir.Req.Request")
    refute String.contains?(on_disk(username, :journal), "api.example.test")
  end

  test "another identity cannot read this one's history", %{username: username} do
    record(username, "https://api.example.test/health")
    other = also_unlock("someone-else")

    assert Resources.all(other) == []
    assert Resources.search(other, "health") == []
  end

  test "reading a locked vault raises rather than falling through", %{username: username} do
    :ok = Store.close(username)

    assert_raise RuntimeError, ~r/locked/, fn -> Resources.all(username) end
  end

  test "a history kept in http_history.bin comes in at unlock, under its ids, searched afresh",
       %{username: username, key: key} do
    request = Req.new(url: "https://api.example.test/orders")
    response = %Req.Response{status: 201, body: ~s({"id":"ord_1"})}
    metadata = HistoryMetadata.new(%{tags: ["kept"]})

    # What an earlier build kept: the inspected structs, steps and all.
    old = HistoryMetadata.normalize_search_text(inspect({request, response}))
    assert old =~ "%req.request{"

    sample =
      {41, %{metadata | search_text: ""}, Req.new(url: "https://api.example.test/draft"), nil}

    :ok = Store.close(username)

    path = Accounts.store_path(username, "http_history.bin")

    File.write!(
      path,
      Vault.seal(key, [{40, %{metadata | search_text: old}, request, response}, sample])
    )

    :ok = Store.open(username, key)

    assert {:ok, {40, %HistoryMetadata{tags: ["kept"]}, ^request, ^response}} =
             Resources.get(username, 40)

    assert {:ok, {41, _metadata, _request, nil}} = Resources.get(username, 41)
    assert Resources.summaries(username, "retry") == []
    assert [{40, _, _, _, _, _, _, 201}] = Resources.summaries(username, ~s("id":"ord_1"))
    assert record(username, "https://api.example.test/next") > 41
    refute File.exists?(path)
    assert File.exists?(Path.join([Accounts.dir(username), "legacy", "http_history.bin"]))
  end

  defp record(username, url) do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: url),
      %Req.Response{status: 200}
    )
  end
end
