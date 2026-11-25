defmodule MWTClient.Preferences do
  @moduledoc """
  App wide settings that are readable before anyone signs in.

  This file is deliberately *not* encrypted: the theme has to be known before
  the first paint, and the login form needs a username to prefill. Nothing
  secret belongs here.
  """

  use GenServer

  @defaults %{
    "theme" => "system",
    "last_username" => nil
  }

  @doc "Starts the preferences owner."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Every stored preference, defaults included."
  @spec all() :: map()
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Reads one preference."
  @spec get(String.t()) :: term()
  def get(key), do: Map.get(all(), key)

  @doc "Writes one preference and persists it."
  @spec put(String.t(), term()) :: :ok
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc "Removes one preference from the file; it reads as its default again."
  @spec delete(String.t()) :: :ok
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @doc "The file backing the preferences."
  @spec path() :: Path.t()
  def path, do: Path.join(MWTClient.Accounts.root(), "preferences.json")

  @impl true
  def init(:ok), do: {:ok, %{}}

  # Read through rather than cached: the file is tiny, reads are rare, and it
  # keeps the server from going stale against the disk.
  @impl true
  def handle_call(:all, _from, state), do: {:reply, read(path()), state}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    path = path()
    :ok = MWTClient.Files.mkdir_p(Path.dirname(path))
    :ok = write(path, Map.put(read(path), key, value))
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    path = path()

    values = read(path)
    if Map.has_key?(values, key), do: :ok = write(path, Map.delete(values, key))

    {:reply, :ok, state}
  end

  # Read on every page's first render: with `MWTClient.Files`, past
  # Erlang's one file server, so a busy one never holds a page.
  defp read(path) do
    with {:ok, body} <- MWTClient.Files.read(path),
         {:ok, values} when is_map(values) <- Jason.decode(body) do
      Map.merge(@defaults, values)
    else
      _unreadable -> @defaults
    end
  end

  defp write(path, values) do
    MWTClient.Files.write(path, Jason.encode!(values, pretty: true))
  end
end
