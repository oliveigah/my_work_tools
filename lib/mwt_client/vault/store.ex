defmodule MWTClient.Vault.Store do
  @moduledoc """
  The runtime home of an unlocked identity.

  Opening a vault starts one process per store, each holding the derived key
  and an ETS table it owns. Closing terminates them, so the key and the
  decrypted data leave memory together.

  Every lookup is keyed by username, so a LiveView left over from an earlier
  session addresses a process that no longer exists rather than silently
  reading whoever signed in next.

  The stores live under a `PartitionSupervisor` of `DynamicSupervisor`s,
  one identity always in the same partition: a supervisor starts its
  children one at a time, and opening the databases takes a while, so one
  identity unlocking or locking never waits for another's.
  """

  alias MWTClient.Accounts

  @registry MWTClient.Vault.Registry
  @supervisor MWTClient.Vault.Supervisors
  # Started in reverse and closed in order, so the keyring comes up first and
  # goes down last, and the databases (`MWTClient.Storage`) come up before
  # the stores that use them and go down after.
  @stores [
    MWTClient.Places,
    MWTClient.Sandbox.Channel,
    MWTClient.Sandbox.AgentThreads,
    MWTClient.Sandbox.Dns,
    MWTClient.Sandbox.Egress,
    MWTClient.Sandbox.Monitor,
    MWTClient.Sandbox.Watch,
    MWTClient.Sandbox.Server,
    # Started before the server and stopped after it: what it holds
    # outlives the server's restarts, not a lock.
    MWTClient.Sandbox.UnlockState,
    MWTClient.MCP.Access,
    MWTClient.Flashcards.Library,
    MWTClient.Notes.Library,
    MWTClient.Diagrams.Library,
    MWTClient.HttpClient.Resources,
    MWTClient.HttpClient.Requests,
    MWTClient.Storage,
    MWTClient.Vault.Keyring
  ]

  @doc false
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :supervisor}
  end

  @doc "Starts the registry and the supervisors the per-identity stores live under."
  def start_link do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: @registry},
        {PartitionSupervisor, child_spec: DynamicSupervisor, name: @supervisor}
      ],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end

  @doc """
  Brings an identity's stores up with the key that decrypts them. One that
  can't start (its databases held by another MWT, a disk that refuses)
  stops the unlock: what started is closed again, and the reason returned.
  """
  @spec open(String.t(), MWTClient.Vault.key()) :: :ok | {:error, term()}
  def open(username, key) do
    @stores
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn store, :ok ->
      case DynamicSupervisor.start_child(
             supervisor(username),
             {store, username: username, key: key}
           ) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, {:already_started, _pid}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {store, reason}}}
      end
    end)
    |> case do
      :ok ->
        :ok

      error ->
        close(username)
        error
    end
  end

  @doc "Tears an identity's stores down, taking the key and the plaintext with them."
  @spec close(String.t()) :: :ok
  def close(username) do
    Enum.each(@stores, fn store ->
      case whereis(store, username) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(supervisor(username), pid)
      end
    end)
  end

  @doc """
  The supervisor an identity's stores live under, for a caller that starts
  one of them alone or waits for it to have restarted one.
  """
  @spec supervisor(String.t()) :: GenServer.name()
  def supervisor(username),
    do: {:via, PartitionSupervisor, {@supervisor, Accounts.id(username)}}

  @doc "Whether this identity is currently unlocked."
  @spec open?(String.t()) :: boolean()
  def open?(username), do: Enum.all?(@stores, &(whereis(&1, username) != nil))

  @doc "The registered name of one store for one identity."
  def via(store, username), do: {:via, Registry, {@registry, key(store, username)}}

  @doc "The pid of one store, or nil when the identity is locked."
  def whereis(store, username) do
    case Registry.lookup(@registry, key(store, username)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  The handles a store published for itself, for lock free reads.

  The liveness check matters: the registry clears its entries from a monitor,
  so without it a just closed vault would hand back a handle to a destroyed
  ETS table.
  """
  @spec fetch(module(), String.t()) :: {:ok, term()} | :error
  def fetch(store, username) do
    case Registry.lookup(@registry, key(store, username)) do
      [{_pid, nil}] -> :error
      [{pid, value}] -> if Process.alive?(pid), do: {:ok, value}, else: :error
      [] -> :error
    end
  end

  @doc "Called by a store process as it shuts down, before its table dies."
  def release(store, username) do
    Registry.unregister(@registry, key(store, username))
  end

  @doc "Called by a store process to publish its table and counter."
  def publish(store, username, value) do
    {_new, _old} = Registry.update_value(@registry, key(store, username), fn _ -> value end)
    :ok
  end

  defp key(store, username), do: {store, Accounts.id(username)}
end
