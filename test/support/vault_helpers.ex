defmodule MWTClient.VaultHelpers do
  @moduledoc """
  Sets up an unlocked identity for tests that need somewhere to persist.
  """

  alias MWTClient.Accounts
  alias MWTClient.Vault.Store

  @doc """
  Unlocks a unique identity and cleans up only its stores and directory on
  exit, once the sandbox's work for it has ended (`await_sandbox_tasks/1`).

  Cleanups run newest first: a folder the identity's sandbox writes into
  is removed after the identity closes when its cleanup is registered
  before this is called.
  """
  def unlocked_identity(username \\ "tester", password \\ "correct horse") do
    username = unique_username(username)
    directory = Accounts.dir(username)

    ExUnit.Callbacks.on_exit(fn ->
      server = Store.whereis(MWTClient.Sandbox.Server, username)
      Store.close(username)
      if server, do: await_sandbox_tasks(server)
      MWTClient.TestFolders.remove!(directory)
    end)

    {:ok, profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(profile.username, key)

    %{username: profile.username, password: password, key: key}
  end

  @doc """
  Waits for the tasks a sandbox server started to end, as long as 5 s.

  The sandbox runs its work (a share sync, a handoff's git) in tasks under
  `MWTClient.Sandbox.TaskSupervisor`, not under the identity: closing it
  doesn't stop them, and one still copying into a test's folder would race
  that folder's removal. One still running after 5 s fails the test.
  """
  def await_sandbox_tasks(server) do
    tasks =
      for pid <- Task.Supervisor.children(MWTClient.Sandbox.TaskSupervisor),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          server in Keyword.get(dictionary, :"$callers", []),
          do: {pid, Process.monitor(pid)}

    for {pid, ref} <- tasks do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          raise "a sandbox task still ran 5 s after its identity closed: " <>
                  inspect(Process.info(pid, :current_stacktrace))
      end
    end

    :ok
  end

  @doc """
  The process `store` runs in for `username` once its supervisor has
  started it again after `old` ended, waited for as long as 5 s.

  A test that saw `old` end can't learn that from one `:sys.get_state/1`
  of the supervisor: `old`'s exit reaches the supervisor from `old`, apart
  from what the test sends it, in no set order, and under a busy run after
  it. So it asks the supervisor again, each answer saying it handled what
  had reached it, until the store is a new process. Still `old`, or none,
  after 5 s fails the test.
  """
  def restarted(store, username, old) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_restart(store, username, old, deadline)
  end

  defp await_restart(store, username, old, deadline) do
    _ = :sys.get_state(Store.supervisor(username))

    case Store.whereis(store, username) do
      pid when is_pid(pid) and pid != old ->
        pid

      _not_yet ->
        if System.monotonic_time(:millisecond) < deadline,
          do: await_restart(store, username, old, deadline),
          else:
            raise(
              "#{inspect(store)} wasn't started again 5 s after #{inspect(old)} ended: " <>
                "registered #{inspect(Store.whereis(store, username))}, its supervisor's children " <>
                inspect(DynamicSupervisor.which_children(Store.supervisor(username)))
            )
    end
  end

  @doc "Unlocks an extra identity alongside the current one."
  def also_unlock(username, password \\ "correct horse") do
    unlocked_identity(username, password).username
  end

  @doc """
  What anyone who can read the folder sees of one of an identity's
  databases (`:library` or `:journal`): the file and its write-ahead log,
  as they are now.
  """
  def on_disk(username, name \\ :library) do
    path = MWTClient.Storage.Database.path(username, name)

    # Right after a lock, SQLite may be closing the last connection, which
    # removes the log (`lock_settled/2`): one gone meanwhile holds nothing.
    for suffix <- ["", "-wal"], into: "" do
      case File.read(path <> suffix) do
        {:ok, bytes} -> bytes
        {:error, :enoent} -> ""
      end
    end
  end

  @doc """
  Runs `fun` with only the identity's databases open, while it is locked:
  as a test edits what an earlier MWT, or a crash, left saved.
  """
  def with_storage(username, key, fun) do
    supervisor = Store.supervisor(username)

    {:ok, pid} =
      DynamicSupervisor.start_child(supervisor, {MWTClient.Storage, username: username, key: key})

    try do
      fun.()
    after
      DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc """
  Locks the identity and leaves its database files as they will stay, for a
  test that reads or changes them next.

  Locking stops the connections without closing them one by one: SQLite
  closes each a moment later, and the last to close checkpoints what the
  write-ahead log holds into the file, or, when two close at once, leaves
  the log behind. Opened again on their own, the databases are checkpointed
  whole: whatever closes later finds nothing to write.
  """
  def lock_settled(username, key) do
    :ok = Store.close(username)

    with_storage(username, key, fn ->
      for name <- MWTClient.Storage.Database.names() do
        MWTClient.Storage.run(username, name, & &1.query!("PRAGMA wal_checkpoint(TRUNCATE)"))
      end
    end)

    :ok
  end

  @doc "Returns a username that cannot collide with another test's identity."
  def unique_username(prefix) do
    prefix <> "-#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc "Removes all application data. Only use in synchronous tests that need global state reset."
  def reset_data_dir!, do: File.rm_rf!(Accounts.root())
end
