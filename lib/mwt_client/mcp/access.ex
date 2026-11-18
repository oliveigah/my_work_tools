defmodule MWTClient.MCP.Access do
  @moduledoc """
  One persistent agent credential per local identity.

  Only a token hash is saved, as a document of the identity's encrypted
  `library.db` (`MWTClient.Storage.Documents`). The vault starts this
  process on unlock and stops it on lock, so the same token resumes
  working after unlocking or restarting MWT without retaining access to a
  locked identity.
  """
  use GenServer

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault.Store

  @registry MWTClient.MCP.Registry
  @document "mcp.access"
  # Where it was kept before library.db.
  @legacy_file "mcp_access.bin"

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Generates and durably saves a token, replacing the previous one."
  def issue(username), do: call(username, :issue)

  @doc "Permanently revokes this identity's token."
  def revoke(username), do: call(username, :revoke)

  def enabled?(username) do
    case Store.fetch(__MODULE__, username) do
      {:ok, %{enabled?: enabled?}} -> enabled?
      :error -> false
    end
  end

  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  def authorize(token) when is_binary(token) do
    case Registry.lookup(@registry, hash(token)) do
      [{pid, username}] ->
        if Store.whereis(__MODULE__, username) == pid and Store.open?(username),
          do: {:ok, username},
          else: :error

      [] ->
        :error
    end
  end

  def authorize(_token), do: :error

  defp call(username, request) do
    if Store.open?(username),
      do: GenServer.call(Store.via(__MODULE__, username), request),
      else: {:error, :locked}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)
    hash = restore(username, Keyword.fetch!(opts, :key))
    register(hash, username)
    :ok = Store.publish(__MODULE__, username, %{enabled?: hash != nil})
    {:ok, %{username: username, hash: hash}}
  end

  @impl true
  def handle_call(:issue, {caller, _tag}, state) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    hash = hash(token)

    case Documents.put(state.username, @document, %{version: 1, hash: hash}) do
      :ok ->
        {:reply, {:ok, token}, change(state, hash, caller)}

      {:error, error} ->
        log_storage_error(error)
        {:reply, {:error, :storage}, state}
    end
  end

  def handle_call(:revoke, {caller, _tag}, state) do
    case Documents.delete(state.username, @document) do
      :ok ->
        {:reply, :ok, change(state, nil, caller)}

      {:error, error} ->
        log_storage_error(error)
        {:reply, {:error, :storage}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister(state.hash)
    :ok
  end

  defp change(state, hash, caller) do
    unregister(state.hash)
    register(hash, state.username)
    :ok = Store.publish(__MODULE__, state.username, %{enabled?: hash != nil})

    Phoenix.PubSub.broadcast_from(
      MWTClient.PubSub,
      caller,
      topic(state.username),
      :mcp_access_changed
    )

    %{state | hash: hash}
  end

  defp register(nil, _username), do: :ok

  defp register(hash, username) do
    {:ok, _owner} = Registry.register(@registry, hash, username)
    :ok
  end

  defp unregister(nil), do: :ok
  defp unregister(hash), do: Registry.unregister(@registry, hash)

  # A credential that can't be read grants nothing, and is left as it is,
  # for recovery, until a new one replaces it.
  defp restore(username, key) do
    case Documents.load(username, @document, @legacy_file, key, :mcp) do
      {:ok, %{version: 1, hash: hash}} when is_binary(hash) and byte_size(hash) == 32 ->
        hash

      {:ok, _unreadable} ->
        Logger.warning("could not read the saved MCP credential", system: :mcp)
        nil

      :none ->
        nil
    end
  end

  defp log_storage_error(error) do
    Logger.error("could not persist MCP access: #{Exception.message(error)}", system: :mcp)
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
  defp topic(username), do: "mcp_access:" <> Accounts.id(username)
end
