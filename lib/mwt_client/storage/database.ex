defmodule MWTClient.Storage.Database do
  @moduledoc """
  One of an identity's databases, opened: its file checked under its key
  (or made, or set aside), its pool of connections started, and its
  migrations run.

  `MWTClient.Storage` starts one per database when an identity unlocks.
  What it starts is the database's Ecto repo, as a dynamic repo registered
  under the identity, so a lock that stops it closes every connection.

  The key is checked on one connection of its own before the pool starts,
  because a pool given a wrong key would retry for ever. So is the cipher:
  a build linked against stock SQLite by mistake would take the key and
  write plain text, and is refused. A file that the right key can't read
  ("not a database", "malformed") is broken, not locked: it is kept aside,
  as the `.bin` files are, and a new one is made. Any other failure (a
  second MWT holding the file, permissions, the disk) fails the unlock and
  touches nothing. The data key comes from the password the verifier just
  proved, so a wrong password never gets here.

  Each connection gets the same settings:

    * WAL, so reads go on while a write is being made;
    * no `auto_vacuum`: pages freed by deletes are reused by later writes,
      and compacting (`VACUUM`) gives the space back to the disk. With a
      cipher that reserves bytes in each page, as every authenticated one
      does, SQLite3 Multiple Ciphers 2.7.1 reported the file malformed
      while creating FTS5 tables under `auto_vacuum` (docs/storage.md);
    * an 8 MiB page cache, which is what bounds the memory a database
      takes, whatever its size;
    * transactions that take the write lock when they start, so two
      writers wait for each other instead of failing halfway;
    * `synchronous=FULL` for the library, where a save that returned must
      survive a power cut, and `NORMAL` for the journal, which may lose its
      last second but never its consistency;
    * a write-ahead log cut back to 64 MiB after each checkpoint;
    * for the library, `secure_delete`: what is deleted, a note or a
      version, is overwritten, not just left in a free page.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias MWTClient.Accounts
  alias MWTClient.Storage.JournalRepo
  alias MWTClient.Storage.LibraryRepo
  alias MWTClient.Vault.Store

  @type name :: :library | :journal

  @databases %{
    library: %{
      repo: LibraryRepo,
      file: "library.db",
      pool_size: 4,
      synchronous: :full,
      secure_delete: :on
    },
    journal: %{
      repo: JournalRepo,
      file: "journal.db",
      pool_size: 2,
      synchronous: :normal,
      secure_delete: :off
    }
  }

  # Each database's migrations, in order: {version, module}. A version,
  # once shipped, never changes; a change to the schema is a new one.
  @migrations %{
    library: [
      {1, MWTClient.Storage.Migrations.LibraryItems},
      {2, MWTClient.Storage.Migrations.LibraryHandoffs},
      {3, MWTClient.Storage.Migrations.FlashcardsUncertain}
    ],
    journal: [
      {1, MWTClient.Storage.Migrations.JournalHttpHistory},
      {2, MWTClient.Storage.Migrations.JournalEvents},
      {3, MWTClient.Storage.Migrations.JournalEventExchanges},
      {4, MWTClient.Storage.Migrations.JournalEventDetails}
    ]
  }

  # The test suite builds with `synchronous=OFF` for both (config/test.exs):
  # it opens databases by the thousand, and none of them outlives the run.
  @synchronous Application.compile_env(:mwt_client, [__MODULE__, :synchronous])

  @cache_kib 8192
  @busy_timeout_ms 5_000
  # What the write-ahead log is cut back to after a checkpoint: without it,
  # it stays the size of the largest transaction (an import, a mass delete)
  # until the identity locks.
  @journal_size_limit 64 * 1024 * 1024
  @ciphers ~w(chacha20 aes256cbc aes128cbc sqlcipher rc4 ascon128 aegis)

  @doc "The databases every identity has."
  @spec names() :: [name()]
  def names, do: [:library, :journal]

  @doc "How long a write waits for the disk, as the spec gives it: SQLite's `synchronous`."
  @spec synchronous(name()) :: :full | :normal
  def synchronous(name), do: Map.fetch!(@databases, name).synchronous

  @doc "The Ecto repo module of a database."
  @spec repo(name()) :: module()
  def repo(name), do: Map.fetch!(@databases, name).repo

  @doc "The file of a database, for one identity."
  @spec path(String.t(), name()) :: Path.t()
  def path(username, name), do: Accounts.store_path(username, Map.fetch!(@databases, name).file)

  @doc """
  The URI SQLite3 Multiple Ciphers opens a database with: its path, and the
  cipher settings from `vault.json`, checked so no setting can add another.
  """
  @spec uri(Path.t(), map()) :: String.t()
  def uri(path, %{"cipher" => cipher, "kdf_iter" => kdf_iter})
      when cipher in @ciphers and is_integer(kdf_iter) and kdf_iter > 0 do
    # In a URI filename SQLite decodes %HH and ends the path at ? or #.
    escaped =
      path
      |> String.replace("%", "%25")
      |> String.replace("?", "%3F")
      |> String.replace("#", "%23")

    "file:#{escaped}?cipher=#{cipher}&kdf_iter=#{kdf_iter}"
  end

  @doc """
  The `PRAGMA key` value for a 32-byte database key: its hex, quoted.

  Quoted here because exqlite puts its `:key` option into the statement as
  it is, and unquoted, hex that starts with a digit is not one token.
  """
  @spec secret(binary()) :: String.t()
  def secret(<<_::binary-32>> = key), do: "'" <> Base.encode16(key, case: :lower) <> "'"

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Opens one database for one identity: `:username`, `:name` (`t:name/0`),
  `:key` (its own 32-byte key) and `:storage` (the cipher settings).
  """
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    name = Keyword.fetch!(opts, :name)
    %{repo: repo} = database = Map.fetch!(@databases, name)
    path = path(username, name)
    storage = Keyword.fetch!(opts, :storage)
    uri = uri(path, storage)
    secret = secret(Keyword.fetch!(opts, :key))

    with :ok <- MWTClient.Files.mkdir_p(Path.dirname(path)),
         :ok <- prepare(path, uri, secret, storage["cipher"], username, name),
         {:ok, pid} <- repo.start_link(repo_options(database, uri, secret, username, name)) do
      migrate(repo, pid, name)
      {:ok, pid}
    end
  end

  defp repo_options(database, uri, secret, username, name) do
    [
      name: Store.via({__MODULE__, name}, username),
      database: uri,
      key: secret,
      journal_mode: :wal,
      synchronous: @synchronous || database.synchronous,
      secure_delete: database.secure_delete,
      journal_size_limit: @journal_size_limit,
      foreign_keys: :on,
      cache_size: -@cache_kib,
      busy_timeout: @busy_timeout_ms,
      default_transaction_mode: :immediate,
      pool_size: database.pool_size,
      log: false
    ]
  end

  @doc """
  Brings the schema of an identity's open database up to date with the
  code loaded now. It opened with the migrations the code had then: code
  loaded into a running MWT, as in development, may need one more before
  the database is opened again. Migrations already made are skipped.
  """
  @spec migrate(String.t(), name()) :: :ok
  def migrate(username, name) do
    pid =
      Store.whereis({__MODULE__, name}, username) ||
        raise "the vault for #{inspect(username)} is locked; sign in before migrating its #{name}"

    migrate(repo(name), pid, name)
    :ok
  end

  defp migrate(repo, pid, name) do
    Ecto.Migrator.run(repo, Map.fetch!(@migrations, name), :up,
      all: true,
      dynamic_repo: pid,
      log: false
    )
  end

  # A file the key opens is kept, and a new one made. One the right key
  # can't read is damaged: it is set aside and a new one made. Anything
  # else (another process holding it, permissions, the disk) fails the
  # unlock and leaves the file as it is, for the next one.
  defp prepare(path, uri, secret, cipher, username, name) do
    fresh? = not File.exists?(path)

    case check(uri, secret, cipher) do
      :ok ->
        :ok

      {:error, reason} when not fresh? and is_binary(reason) ->
        if damaged?(reason) do
          quarantine(path, reason, username, name)
          check(uri, secret, cipher)
        else
          {:error, {:storage, name, reason}}
        end

      {:error, reason} ->
        {:error, {:storage, name, reason}}
    end
  end

  # SQLITE_NOTADB and SQLITE_CORRUPT, as SQLite words them.
  defp damaged?(reason),
    do: reason =~ "file is not a database" or reason =~ "database disk image is malformed"

  defp check(uri, secret, cipher) do
    with {:ok, db} <- Sqlite3.open(uri, mode: [:readwrite, :create]) do
      try do
        with :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout = #{@busy_timeout_ms}"),
             :ok <- Sqlite3.execute(db, "PRAGMA key = #{secret}"),
             :ok <- encrypting(db, cipher),
             :ok <- check_synchronous(db),
             # The first statement that reads the file: a wrong key fails here.
             :ok <- Sqlite3.execute(db, "PRAGMA journal_mode = WAL") do
          Sqlite3.execute(db, "SELECT count(*) FROM sqlite_schema")
        end
      after
        Sqlite3.close(db)
      end
    end
  end

  # Making a new file WAL waits for the disk, as the pool's writes do: the
  # test suite, which waits for none (`@synchronous`), has this connection
  # not wait either.
  if @synchronous do
    defp check_synchronous(db), do: Sqlite3.execute(db, "PRAGMA synchronous = #{@synchronous}")
  else
    defp check_synchronous(_db), do: :ok
  end

  # Stock SQLite takes `PRAGMA key` and the URI's cipher without a word,
  # and writes plain text: linked against it by mistake (a package built
  # wrong, a stale build), MWT would. SQLite3 Multiple Ciphers answers
  # `PRAGMA cipher` with the one in use; anything else is refused.
  defp encrypting(db, cipher) do
    with {:ok, statement} <- Sqlite3.prepare(db, "PRAGMA cipher") do
      try do
        case Sqlite3.fetch_all(db, statement) do
          {:ok, [[^cipher]]} -> :ok
          other -> {:error, {:not_encrypted, other}}
        end
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  # Timestamped, so a second failure can't overwrite what the first kept.
  defp quarantine(path, reason, username, name) do
    corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

    for suffix <- ["", "-wal", "-shm"], File.exists?(path <> suffix) do
      File.rename(path <> suffix, corrupt <> suffix)
    end

    Logger.error(
      "#{name} database at #{path} could not be opened (#{inspect(reason)}); kept as #{corrupt}",
      user: username,
      system: :storage
    )
  end
end
