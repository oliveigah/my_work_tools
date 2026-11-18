defmodule MWTClient.Storage.DocumentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.Storage
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault

  setup do
    unlocked_identity()
  end

  test "a document is kept whole, in place of what was, until deleted", %{username: username} do
    assert Documents.get(username, "test.doc") == :none

    :ok = Documents.put(username, "test.doc", %{n: 1, secret: "the plan"})
    :ok = Documents.put(username, "test.doc", %{n: 2, secret: "the plan"})

    assert Documents.get(username, "test.doc") == {:ok, %{n: 2, secret: "the plan"}}
    refute on_disk(username) =~ "the plan"

    :ok = Documents.delete(username, "test.doc")
    :ok = Documents.delete(username, "test.doc")
    assert Documents.get(username, "test.doc") == :none
  end

  test "a file from before library.db is brought in once, then retired", %{
    username: username,
    key: key
  } do
    path = seal(username, key, "test.bin", %{from: :file})

    assert Documents.load(username, "test.doc", "test.bin", key, :test) == {:ok, %{from: :file}}
    assert Documents.get(username, "test.doc") == {:ok, %{from: :file}}
    refute File.exists?(path)
    assert File.exists?(Path.join([Accounts.dir(username), "legacy", "test.bin"]))

    :ok = Documents.put(username, "test.doc", %{from: :document})

    assert Documents.load(username, "test.doc", "test.bin", key, :test) ==
             {:ok, %{from: :document}}
  end

  test "a file put back beside a document is the newer, and replaces it", %{
    username: username,
    key: key
  } do
    :ok = Documents.put(username, "test.doc", %{from: :document})
    seal(username, key, "test.bin", %{from: :file})

    assert Documents.load(username, "test.doc", "test.bin", key, :test) == {:ok, %{from: :file}}
    assert Documents.get(username, "test.doc") == {:ok, %{from: :file}}
  end

  test "a file that won't decrypt is set aside, and the document stays", %{
    username: username,
    key: key
  } do
    :ok = Documents.put(username, "test.doc", %{from: :document})
    path = Accounts.store_path(username, "test.bin")
    File.write!(path, "damaged")

    capture_log(fn ->
      assert Documents.load(username, "test.doc", "test.bin", key, :test) ==
               {:ok, %{from: :document}}
    end)

    assert [_corrupt] = Path.wildcard(path <> ".*.corrupt")
  end

  test "a write the database refuses comes back as an error, changing nothing", %{
    username: username
  } do
    :ok = Documents.put(username, "test.doc", :kept)

    Storage.run(username, :library, fn repo ->
      repo.query!(
        "CREATE TRIGGER refuse BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT, 'disk full'); END"
      )
    end)

    assert {:error, %Exqlite.Error{}} = Documents.put(username, "test.doc", :lost)
    assert Documents.get(username, "test.doc") == {:ok, :kept}
  end

  test "agent threads kept in agent_threads.bin come in at unlock", %{
    username: username,
    key: key
  } do
    thread = %MWTClient.Sandbox.AgentThread{id: "thread-1", title: "Revisit storage"}
    :ok = MWTClient.Vault.Store.close(username)
    seal(username, key, "agent_threads.bin", %{threads: [thread]})

    :ok = MWTClient.Vault.Store.open(username, key)

    assert %{id: "thread-1", title: "Revisit storage"} =
             MWTClient.Sandbox.AgentThreads.get(username, "thread-1")
  end

  defp seal(username, key, file, term) do
    path = Accounts.store_path(username, file)
    File.write!(path, Vault.seal(key, term))
    path
  end
end
