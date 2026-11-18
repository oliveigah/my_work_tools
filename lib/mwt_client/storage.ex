defmodule MWTClient.Storage do
  @moduledoc """
  An unlocked identity's databases, encrypted page by page (docs/storage.md):

    * `:library` (`library.db`) - what you make;
    * `:journal` (`journal.db`) - what happens, agent activity written
      in batches by `MWTClient.Storage.Journal`.

  `MWTClient.Vault.Store` starts this for each identity it unlocks, before
  the stores that use it, and stops it after them. It opens the identity's
  data key with the password's key (`MWTClient.Accounts.data_key/2`), gives
  each database a key of its own derived from it, and opens each one
  (`MWTClient.Storage.Database`). Locking stops it, which closes every
  connection, and SQLite's page cache, the only plaintext it holds, with
  them.

  Read and write through `run/3`, from any process: reads run beside a
  write, and writes wait for each other.
  """

  use Supervisor

  alias MWTClient.Accounts
  alias MWTClient.Storage.Database
  alias MWTClient.Storage.Janitor
  alias MWTClient.Storage.Journal
  alias MWTClient.Vault.Store

  @doc "Opens an identity's databases: `:username` and `:key`, its password's key."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    Supervisor.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc """
  Runs `fun` with the repo of one of `username`'s databases, as Ecto's
  dynamic repo of the calling process, and returns what it returns.

      Storage.run(username, :library, fn repo -> repo.all(query) end)

  Raises when the identity is locked.
  """
  @spec run(String.t(), Database.name(), (module() -> result)) :: result when result: term()
  def run(username, name, fun) when is_function(fun, 1) do
    repo = Database.repo(name)

    pid =
      Store.whereis({Database, name}, username) ||
        raise "the vault for #{inspect(username)} is locked; sign in before reading its #{name}"

    previous = repo.put_dynamic_repo(pid)

    try do
      fun.(repo)
    after
      repo.put_dynamic_repo(previous)
    end
  end

  @doc """
  Runs `fun` with the repo of one of `username`'s databases inside a
  transaction, as `run/3` does, and returns what `fun` returns. The
  transaction takes the write lock when it starts, so what `fun` reads is
  still so when it writes. Inside another, it is part of that one.

  Raises when `fun` does, having rolled back.
  """
  @spec transaction(String.t(), Database.name(), (module() -> result)) :: result
        when result: term()
  def transaction(username, name, fun) when is_function(fun, 1) do
    run(username, name, fn repo ->
      {:ok, result} = repo.transaction(fn -> fun.(repo) end, timeout: :infinity)
      result
    end)
  end

  @doc """
  The key of one database, derived from the identity's data key, so no two
  databases share one.
  """
  @spec database_key(binary(), Database.name()) :: binary()
  def database_key(data_key, name) do
    :crypto.mac(:hmac, :sha256, data_key, "mwt:storage:#{name}:v1")
  end

  @impl true
  def init(opts) do
    username = Keyword.fetch!(opts, :username)

    case Accounts.data_key(username, Keyword.fetch!(opts, :key)) do
      {:ok, data_key, storage} ->
        databases =
          for name <- Database.names() do
            {Database,
             username: username, name: name, key: database_key(data_key, name), storage: storage}
          end

        # Started after the databases, and so stopped before them: the
        # journal's writer writes what waits as the identity locks. One
        # that fails restarts what came after it: a database restarts the
        # writer and the janitor too.
        Supervisor.init(
          databases ++ [{Journal, username: username}, {Janitor, username: username}],
          strategy: :rest_for_one
        )

      {:error, reason} ->
        raise "the data key of #{inspect(username)} could not be opened: #{inspect(reason)}"
    end
  end
end
