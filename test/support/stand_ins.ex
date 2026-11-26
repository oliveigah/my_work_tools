defmodule MWTClient.StandIns do
  @moduledoc """
  What a test puts in place of the VM and of Zed, for its own identity.

  `config/test.exs` points the sandbox's stand-ins here
  (`MWTClient.Sandbox.Projects`' `:guest`, `MWTClient.Sandbox.Zed`'s
  `:open`), and each test registers its own under the username it signed
  in with: tests that each have an identity of their own run at the same
  time, and none sees another's.

  An identity with no stand-in reaches its VM as it would outside tests,
  and finds it stopped; Zed never opens, whatever the identity.
  `test_helper.exs` makes the table before any test runs.

  The workspace (`MWTClient.Sandbox.Workspace`) goes in a home folder of
  the identity's own, inside the test data folder, and opening it opens
  nothing.
  """

  alias MWTClient.Accounts

  @table __MODULE__

  @doc "Makes the table, owned by the process that runs the suite."
  def start do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ok
  end

  @doc """
  Puts `guest` (a `MWTClient.Sandbox.Guest`, or a map with an `:exec`
  function) in place of `username`'s VM until the test ends.
  """
  def put_guest(username, guest), do: put(:guest, username, guest)

  @doc "Takes `username`'s stand-in away: from now on its VM isn't running."
  def remove_guest(username) do
    :ets.delete(@table, {:guest, Accounts.id(username)})
    :ok
  end

  @doc """
  Calls `fun` with the address Zed would open for `username`, instead of
  doing nothing, until the test ends. It returns what `Zed.open/3` does.
  """
  def on_zed(username, fun) when is_function(fun, 1), do: put(:zed, username, fun)

  @doc false
  # Projects' `:guest`: the stand-in for this identity's VM, or nil.
  def guest(username), do: lookup(:guest, username)

  @doc """
  Makes `pids` the processes whose own and descendants' connections to
  `username`'s sockets count as its bubble's (`MWTClient.Sandbox.Peer`),
  until the test ends; `[]` leaves only the bubble `bubble.pid` names.
  """
  def put_peer_roots(username, pids), do: put(:peer_roots, username, pids)

  @doc false
  # Peer's `:roots`: by default the suite's own BEAM, where stand-ins for
  # the relay and msb connect from.
  def peer_roots(username),
    do: lookup(:peer_roots, username) || [List.to_integer(:os.getpid())]

  @doc """
  The home folder `username`'s workspace goes in: one of its own, inside
  the test data folder, made when first asked for.
  """
  def workspace_home(username) do
    home = Path.join([Accounts.root(), "homes", Accounts.id(username)])
    File.mkdir_p!(home)
    home
  end

  @doc false
  # The workspace's `:open`: nothing opens.
  def open_folder(_root), do: :ok

  @doc false
  # Zed's `:open`.
  def open_zed(username, address) do
    case lookup(:zed, username) do
      nil -> :ok
      fun -> fun.(address)
    end
  end

  defp put(kind, username, value) do
    key = {kind, Accounts.id(username)}
    :ets.insert(@table, {key, value})
    ExUnit.Callbacks.on_exit(fn -> :ets.delete(@table, key) end)
    :ok
  end

  defp lookup(kind, username) do
    case :ets.lookup(@table, {kind, Accounts.id(username)}) do
      [{_key, value}] -> value
      [] -> nil
    end
  end
end
