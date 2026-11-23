defmodule MWTClient.Sandbox.UnlockState do
  @moduledoc """
  What the sandbox has in force since you unlocked MWT, kept apart from
  the sandbox's server (`MWTClient.Sandbox.Server`) so a restart of that
  server comes back to it: each grant as it is (on or off, the time left,
  its allowances), the firewall's windows, and what agents added with
  MWT's tools in the last hour.

  A start, opening MWT or unlocking it, puts every grant in its start
  setting. A restart of the server after it failed must not: the VM can
  make it fail, by finding a bug in how an ask is answered, and a start
  setting of *Enabled* would turn back on a grant you turned off, and the
  firewall would forget what it counted. So this process starts with the
  identity's stores, before the server, and stops with them at a lock,
  after it: what it holds is there across the server's restarts, and gone
  at the next unlock, which is a start again.

  The server hands it what it keeps after each message that changed it
  (`MWTClient.Sandbox.Server.Kept`). It holds no real value: grants carry
  none, they are kept apart in the server.
  """

  use GenServer

  alias MWTClient.Vault.Store

  @typedoc "What the server keeps here (`MWTClient.Sandbox.Server.Kept`)."
  @type kept :: %{
          grants: [MWTClient.Sandbox.Grant.t()],
          firewall_watch: map(),
          firewall_refused: non_neg_integer(),
          tool_creates: [{integer(), non_neg_integer()}]
        }

  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, nil, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  What the server kept since the unlock, or nil when it kept nothing yet:
  it is starting for the first time since the unlock.
  """
  @spec get(String.t()) :: kept() | nil
  def get(username) do
    case Store.whereis(__MODULE__, username) do
      nil -> nil
      pid -> GenServer.call(pid, :get)
    end
  end

  @doc """
  Keeps `kept` in place of what was there. Sent, not waited on: the
  server's own process puts it in this one's mailbox before it can fail,
  so a restart, which asks with `get/1`, finds it.
  """
  @spec put(String.t(), kept()) :: :ok
  def put(username, kept), do: GenServer.cast(Store.via(__MODULE__, username), {:put, kept})

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(:get, _from, kept), do: {:reply, kept, kept}

  @impl true
  def handle_cast({:put, kept}, _old), do: {:noreply, kept}
end
