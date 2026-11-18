defmodule MWTClient.Places do
  @moduledoc """
  Where each tool was left, for one unlocked identity: the page it was on
  and what it had open, so switching to another tool and back finds it as
  it was.

  Switching tools ends the LiveView of the tool left, and the next visit
  mounts a new one. So a tool's page (`visit/3`) and its place (`keep/3`:
  tabs, selections, drafts not saved yet) are handed here as they change,
  and taken back (`recall/2`, `paths/1`) when the tool mounts again.

  Kept in memory only, in a process the vault starts on unlock and stops
  on lock (`MWTClient.Vault.Store`): what the tools were showing, drafts
  included, leaves memory with the key and never reaches disk. A place is
  a hint, not a record: a tool checks what it recalls against what still
  exists, and nothing here survives a restart.
  """
  use GenServer

  alias MWTClient.Vault.Store

  @typedoc "A tool's id, as in `MWTClient.Tools`."
  @type tool :: atom()

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc """
  Records the page `tool` is on: a path with its query, as the title bar
  links back to it.
  """
  @spec visit(String.t(), tool(), String.t()) :: :ok
  def visit(username, tool, path) when is_atom(tool) and is_binary(path),
    do: cast(username, {:visit, tool, path})

  @doc "Keeps `place` for `tool`, replacing what was kept for it before."
  @spec keep(String.t(), tool(), map()) :: :ok
  def keep(username, tool, place) when is_atom(tool) and is_map(place),
    do: cast(username, {:keep, tool, place})

  @doc "What was kept for `tool`, or an empty map."
  @spec recall(String.t(), tool()) :: map()
  def recall(username, tool) when is_atom(tool), do: call(username, {:recall, tool}, %{})

  @doc "The page each visited tool was last on, by tool id."
  @spec paths(String.t()) :: %{tool() => String.t()}
  def paths(username), do: call(username, :paths, %{})

  # A locked identity has no process: it then keeps and recalls nothing,
  # rather than failing the page that asked.
  defp cast(username, message), do: GenServer.cast(Store.via(__MODULE__, username), message)

  defp call(username, message, locked) do
    case Store.whereis(__MODULE__, username) do
      nil -> locked
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _gone -> locked
  end

  @impl true
  def init(_username), do: {:ok, %{}}

  @impl true
  def handle_cast({:visit, tool, path}, places),
    do: {:noreply, Map.update(places, tool, %{path: path}, &Map.put(&1, :path, path))}

  def handle_cast({:keep, tool, place}, places),
    do: {:noreply, Map.update(places, tool, %{place: place}, &Map.put(&1, :place, place))}

  @impl true
  def handle_call({:recall, tool}, _from, places),
    do: {:reply, get_in(places, [tool, :place]) || %{}, places}

  def handle_call(:paths, _from, places) do
    paths = for {tool, %{path: path}} <- places, into: %{}, do: {tool, path}
    {:reply, paths, places}
  end
end
