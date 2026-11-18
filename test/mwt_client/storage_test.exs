defmodule MWTClient.StorageTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias Exqlite.Sqlite3
  alias MWTClient.Accounts
  alias MWTClient.Storage
  alias MWTClient.Storage.Database
  alias MWTClient.Vault
  alias MWTClient.Vault.Store

  @marker "storage-test-marker"

  defp put_marker(username, name) do
    Storage.run(username, name, fn repo ->
      repo.query!("CREATE TABLE IF NOT EXISTS t (x TEXT)")
      repo.query!("INSERT INTO t VALUES (?)", [@marker])
    end)
  end

  defp markers(username, name) do
    Storage.run(username, name, fn repo -> repo.query!("SELECT x FROM t").rows end)
  end

  defp vault_json(username), do: username |> Accounts.dir() |> Path.join("vault.json")

  defp read_vault(username), do: username |> vault_json() |> File.read!() |> Jason.decode!()

  test "unlocking opens a library and a journal that hold data no one can read on disk" do
    %{username: username} = unlocked_identity()

    for name <- Database.names() do
      put_marker(username, name)
      assert markers(username, name) == [[@marker]]

      disk = on_disk(username, name)
      assert byte_size(disk) > 0
      refute String.contains?(disk, @marker)
      refute String.starts_with?(disk, "SQLite format 3")
    end
  end

  test "locking closes the databases, and the next unlock finds the data again" do
    %{username: username, key: key} = unlocked_identity()
    put_marker(username, :library)

    :ok = Store.close(username)

    assert_raise RuntimeError, ~r/locked/, fn -> markers(username, :library) end

    :ok = Store.open(username, key)
    assert markers(username, :library) == [[@marker]]
  end

  test "the databases take the settings the spec gives them" do
    %{username: username} = unlocked_identity()

    pragma = fn name, pragma ->
      Storage.run(username, name, fn repo -> repo.query!("PRAGMA #{pragma}").rows end)
    end

    for name <- Database.names() do
      assert pragma.(name, "journal_mode") == [["wal"]]
      # 0 is NONE, which a VACUUM, as compacting runs, keeps.
      assert pragma.(name, "auto_vacuum") == [[0]]
      put_marker(username, name)
      Storage.run(username, name, fn repo -> repo.query!("VACUUM") end)
      assert pragma.(name, "auto_vacuum") == [[0]]
      assert pragma.(name, "cache_size") == [[-8192]]
    end

    # FULL and NORMAL, as the app runs them. The suite builds with OFF, 0,
    # for both (config/test.exs).
    assert Database.synchronous(:library) == :full
    assert Database.synchronous(:journal) == :normal
    assert pragma.(:library, "synchronous") == [[0]]
    assert pragma.(:journal, "synchronous") == [[0]]
  end

  test "reads from other processes see what was written" do
    %{username: username} = unlocked_identity()
    put_marker(username, :journal)

    reads =
      1..8
      |> Task.async_stream(fn _ -> markers(username, :journal) end)
      |> Enum.map(fn {:ok, rows} -> rows end)

    assert reads == List.duplicate([[@marker]], 8)
  end

  test "a new identity's vault.json holds its data key sealed, never in the clear" do
    %{username: username, key: key} = unlocked_identity()
    meta = read_vault(username)

    assert %{"data_key" => sealed, "storage" => %{"cipher" => "chacha20", "kdf_iter" => 1}} = meta
    assert {:ok, data_key, _storage} = Accounts.data_key(username, key)
    assert byte_size(data_key) == 32
    assert Vault.open(key, Base.decode64!(sealed)) == {:ok, data_key}
    refute File.read!(vault_json(username)) =~ Base.encode64(data_key)
    refute File.read!(vault_json(username)) =~ Base.encode16(data_key, case: :lower)
  end

  test "an identity from before gets a data key at its first unlock and keeps the rest" do
    username = unique_username("before")
    on_exit(fn -> File.rm_rf!(Accounts.dir(username)) end)
    {:ok, _profile, key} = Accounts.sign_in(username, "correct horse")

    before = Map.drop(read_vault(username), ["data_key", "storage"])
    File.write!(vault_json(username), Jason.encode!(before))

    assert {:ok, data_key, _storage} = Accounts.data_key(username, key)
    assert Map.take(read_vault(username), Map.keys(before)) == before

    # The way back to a build from before: its vault.json, kept.
    kept = username |> Accounts.store_path("legacy/vault.json") |> File.read!() |> Jason.decode!()
    assert kept == before
    assert {:ok, ^data_key, _storage} = Accounts.data_key(username, key)
    assert {:ok, _profile, ^key} = Accounts.sign_in(username, "correct horse")
  end

  test "a data key is never replaced, even beside settings gone missing" do
    %{username: username, key: key} = unlocked_identity()
    {:ok, data_key, storage} = Accounts.data_key(username, key)
    File.write!(vault_json(username), Jason.encode!(Map.delete(read_vault(username), "storage")))

    assert {:ok, ^data_key, ^storage} = Accounts.data_key(username, key)
  end

  test "no data key is made beside databases made with one since lost" do
    %{username: username, key: key} = unlocked_identity()
    :ok = lock_settled(username, key)
    library = File.read!(Database.path(username, :library))
    File.write!(vault_json(username), Jason.encode!(Map.delete(read_vault(username), "data_key")))

    assert Accounts.data_key(username, key) == {:error, :data_key_missing}
    assert Accounts.sign_in(username, "correct horse") == {:error, :data_key_missing}
    refute Map.has_key?(read_vault(username), "data_key")
    assert File.read!(Database.path(username, :library)) == library
  end

  test "a data key the password's key can't open is refused, not replaced" do
    %{username: username, key: key} = unlocked_identity()
    other = Vault.derive("another", Vault.salt())
    foreign = Base.encode64(Vault.seal(other, :crypto.strong_rand_bytes(32)))

    File.write!(
      vault_json(username),
      Jason.encode!(%{read_vault(username) | "data_key" => foreign})
    )

    assert Accounts.data_key(username, key) == {:error, :unreadable_vault}
    assert read_vault(username)["data_key"] == foreign
  end

  test "two first unlocks at once agree on one data key" do
    username = unique_username("race")
    on_exit(fn -> File.rm_rf!(Accounts.dir(username)) end)
    {:ok, _profile, key} = Accounts.sign_in(username, "correct horse")
    File.write!(vault_json(username), Jason.encode!(Map.delete(read_vault(username), "data_key")))

    keys =
      1..4
      |> Task.async_stream(fn _ -> Accounts.data_key(username, key) end)
      |> Enum.map(fn {:ok, {:ok, data_key, _storage}} -> data_key end)
      |> Enum.uniq()

    assert [_one] = keys
  end

  test "each database has a key of its own" do
    %{username: username, key: key} = unlocked_identity()
    put_marker(username, :library)
    {:ok, data_key, storage} = Accounts.data_key(username, key)

    readable? = fn name, key_of ->
      uri = Database.uri(Database.path(username, name), storage)
      {:ok, db} = Sqlite3.open(uri, mode: [:readonly])

      :ok =
        Sqlite3.execute(
          db,
          "PRAGMA key = #{Database.secret(Storage.database_key(data_key, key_of))}"
        )

      result = Sqlite3.execute(db, "SELECT count(*) FROM sqlite_schema")
      Sqlite3.close(db)
      result == :ok
    end

    assert readable?.(:library, :library)
    refute readable?.(:library, :journal)
    refute readable?.(:journal, :library)
  end

  # exqlite puts its `:key` option into the statement unquoted, where hex
  # that starts with a digit is not one token.
  test "a key whose hex starts with a digit or a letter works the same" do
    for first <- [0x0A, 0xA0] do
      key = <<first, :crypto.strong_rand_bytes(31)::binary>>
      dir = Path.join(System.tmp_dir!(), "mwt-storage-key-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(dir)
      uri = Database.uri(Path.join(dir, "k.db"), %{"cipher" => "chacha20", "kdf_iter" => 1})

      {:ok, db} = Sqlite3.open(uri, mode: [:readwrite, :create])
      assert :ok = Sqlite3.execute(db, "PRAGMA key = #{Database.secret(key)}")
      assert :ok = Sqlite3.execute(db, "CREATE TABLE t (x)")
      Sqlite3.close(db)

      {:ok, db} = Sqlite3.open(uri, mode: [:readonly])
      wrong = <<first, :crypto.strong_rand_bytes(31)::binary>>
      :ok = Sqlite3.execute(db, "PRAGMA key = #{Database.secret(wrong)}")
      assert {:error, _} = Sqlite3.execute(db, "SELECT count(*) FROM sqlite_schema")
      Sqlite3.close(db)
    end
  end

  test "a file the key can't open is kept aside, and a new one is made" do
    %{username: username, key: key} = unlocked_identity()
    path = Database.path(username, :library)
    :ok = lock_settled(username, key)
    File.write!(path, :crypto.strong_rand_bytes(8192))

    ExUnit.CaptureLog.capture_log(fn -> :ok = Store.open(username, key) end)

    put_marker(username, :library)
    assert markers(username, :library) == [[@marker]]

    assert [_kept] =
             username
             |> Accounts.dir()
             |> File.ls!()
             |> Enum.filter(&(&1 =~ ~r/^library\.db\.\d+\.corrupt$/))
  end

  test "a path holding characters a URI gives meaning to still opens" do
    dir = Path.join(System.tmp_dir!(), "mwt storage #{System.unique_integer([:positive])} 50%?#x")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    path = Path.join(dir, "u.db")

    {:ok, db} =
      Sqlite3.open(Database.uri(path, %{"cipher" => "chacha20", "kdf_iter" => 1}),
        mode: [:readwrite, :create]
      )

    :ok = Sqlite3.execute(db, "PRAGMA key = #{Database.secret(:crypto.strong_rand_bytes(32))}")
    :ok = Sqlite3.execute(db, "CREATE TABLE t (x)")
    Sqlite3.close(db)

    assert File.exists?(path)
  end

  test "cipher settings that would add to the URI are refused" do
    assert_raise FunctionClauseError, fn ->
      Database.uri("/x.db", %{"cipher" => "chacha20&kdf_iter=1&key=x", "kdf_iter" => 1})
    end

    assert_raise FunctionClauseError, fn ->
      Database.uri("/x.db", %{"cipher" => "chacha20", "kdf_iter" => "1&x=y"})
    end
  end
end
