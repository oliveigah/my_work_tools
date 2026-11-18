defmodule MWTClient.MCP.AccessTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers
  import ExUnit.CaptureLog
  alias MWTClient.Accounts
  alias MWTClient.MCP.Access
  alias MWTClient.Storage
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault
  alias MWTClient.Vault.Store

  setup do
    unlocked_identity()
  end

  test "tokens belong to one identity and rotation and revocation survive reopening", %{
    username: username,
    key: key
  } do
    other = also_unlock("other")
    {:ok, token} = Access.issue(username)
    {:ok, other_token} = Access.issue(other)
    assert {:ok, ^username} = Access.authorize(token)
    assert {:ok, ^other} = Access.authorize(other_token)
    assert Access.enabled?(username)
    assert Access.authorize("made up") == :error
    assert Access.authorize(nil) == :error

    {:ok, rotated} = Access.issue(username)
    refute token == rotated
    assert Access.authorize(token) == :error
    assert {:ok, ^username} = Access.authorize(rotated)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    assert Access.authorize(token) == :error
    assert {:ok, ^username} = Access.authorize(rotated)
    :ok = Access.revoke(username)
    :ok = Store.close(username)
    :ok = Store.open(username, key)
    refute Access.enabled?(username)
    assert Access.authorize(rotated) == :error
    assert {:ok, ^other} = Access.authorize(other_token)
  end

  test "locking pauses access and the saved token resumes in a fresh process", %{
    username: username,
    key: key
  } do
    {:ok, token} = Access.issue(username)
    owner = Store.whereis(Access, username)
    monitor = Process.monitor(owner)
    :ok = Store.close(username)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert Access.authorize(token) == :error
    assert Access.issue(username) == {:error, :locked}
    assert Registry.lookup(MWTClient.MCP.Registry, :crypto.hash(:sha256, token)) == []
    :ok = Store.open(username, key)
    refute Store.whereis(Access, username) == owner
    assert {:ok, ^username} = Access.authorize(token)
    assert Access.enabled?(username)
  end

  test "only the token hash is saved, encrypted before generation returns", %{
    username: username
  } do
    {:ok, token} = Access.issue(username)
    hash = :crypto.hash(:sha256, token)

    assert Documents.get(username, "mcp.access") == {:ok, %{version: 1, hash: hash}}
    refute on_disk(username) =~ token
    refute on_disk(username) =~ hash
  end

  test "a failed rotation keeps the existing credential working", %{username: username, key: key} do
    {:ok, token} = Access.issue(username)

    refusing_writes(username, fn ->
      capture_log(fn -> assert Access.issue(username) == {:error, :storage} end)
      assert {:ok, ^username} = Access.authorize(token)
    end)

    :ok = Store.close(username)
    :ok = Store.open(username, key)
    assert {:ok, ^username} = Access.authorize(token)
  end

  test "a failed revocation leaves the token active and reports the failure", %{
    username: username
  } do
    {:ok, token} = Access.issue(username)

    refusing_writes(username, fn ->
      capture_log(fn -> assert Access.revoke(username) == {:error, :storage} end)
      assert {:ok, ^username} = Access.authorize(token)
      assert Access.enabled?(username)
    end)
  end

  test "unreadable credentials grant no access and are kept for recovery", %{
    username: username,
    key: key
  } do
    {:ok, token} = Access.issue(username)
    :ok = Store.close(username)

    with_storage(username, key, fn ->
      :ok = Documents.put(username, "mcp.access", "damaged credential")
    end)

    capture_log(fn -> :ok = Store.open(username, key) end)
    assert Access.authorize(token) == :error
    refute Access.enabled?(username)
    assert Documents.get(username, "mcp.access") == {:ok, "damaged credential"}
  end

  test "a credential kept in mcp_access.bin before library.db still works, and the file retires",
       %{username: username, key: key} do
    token = "kept-from-before"
    :ok = Store.close(username)
    path = Accounts.store_path(username, "mcp_access.bin")
    File.write!(path, Vault.seal(key, %{version: 1, hash: :crypto.hash(:sha256, token)}))

    :ok = Store.open(username, key)

    assert {:ok, ^username} = Access.authorize(token)
    refute File.exists?(path)
    assert File.exists?(Path.join([Accounts.dir(username), "legacy", "mcp_access.bin"]))
  end

  # The database refuses every write of a document while `fun` runs, as a
  # full disk would.
  defp refusing_writes(username, fun) do
    triggers =
      for event <- ~w(INSERT UPDATE DELETE) do
        name = "refuse_#{String.downcase(event)}"

        Storage.run(username, :library, fn repo ->
          repo.query!(
            "CREATE TRIGGER #{name} BEFORE #{event} ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END"
          )
        end)

        name
      end

    try do
      fun.()
    after
      for name <- triggers,
          do: Storage.run(username, :library, & &1.query!("DROP TRIGGER #{name}"))
    end
  end
end
