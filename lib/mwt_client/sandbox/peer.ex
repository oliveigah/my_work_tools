defmodule MWTClient.Sandbox.Peer do
  @moduledoc """
  Who may connect to the sockets the VM's bubble reaches MWT by
  (`proxy.sock`, `dns.sock`, `channel.sock`, `MWTClient.Sandbox.Sockets`):
  a process of that bubble, and nothing else on this machine.

  Their folder is yours only, so no other account gets in. This is about
  other programs running as you: to MWT, any of them would be the VM, with
  its network, your credentials put in where its grants let them, and its
  agent channel. The kernel says which process connected (`SO_PEERCRED`,
  as it was at `connect`), and MWT lets it in only when that process
  descends from the bubble's `bwrap` (`MWTClient.Sandbox.Bubble`): the
  relay, msb and the VM's own process are its children, and an orphan in
  there is adopted by the bubble's first process, never by one outside.

  The bubble's process id comes from `bubble.pid`, in MWT's own folder
  beside the sockets, with the time that process started: an id is given
  again once its process ended, and the time tells the bubble from
  whatever has its number now. A bubble whose file has no time (started by
  an MWT before this check) is let in by nothing until it starts again.

  It stops a program that connects to a socket, not one written against
  MWT: you own the bubble's namespaces, so a program running as you can
  join them and go through the relay from in there. A user of MWT's own
  would close that (`docs/architecture.md`).

  A refused connection is closed unanswered and said in the activity log,
  at most once a minute for each socket.

  Tests count their own BEAM as a bubble too (`:roots`, given by
  `MWTClient.StandIns`), since their stand-ins connect from it.
  """

  alias MWTClient.Files
  alias MWTClient.Sandbox.{Server, Shown, Sockets}

  # SOL_SOCKET and SO_PEERCRED on Linux, and its struct ucred: pid, uid, gid.
  @sol_socket 1
  @so_peercred 17

  # How many parents to walk up before giving up: a bubble is a few deep.
  @max_depth 64

  @said_every 60_000

  @typedoc "When this socket's last refusal was said (monotonic milliseconds), or nil."
  @type said_at :: integer() | nil

  @doc """
  Lets `client` in when the process at its other end is in `username`'s
  bubble. Otherwise closes it, says so in the activity log unless that was
  said for this socket in the last minute (`said_at`, as this returned it
  last), and returns false. `socket_name` names the socket in what is
  said: "proxy", "DNS" or "agent channel".
  """
  @spec admit(:gen_tcp.socket(), String.t(), String.t(), said_at()) :: {boolean(), said_at()}
  def admit(client, username, socket_name, said_at) do
    pid =
      case peer(client) do
        {:ok, pid} -> pid
        :error -> nil
      end

    if pid && inside?(username, pid) do
      {true, said_at}
    else
      :gen_tcp.close(client)
      {false, say_refused(username, socket_name, pid, said_at)}
    end
  end

  @doc "The id of the process at the other end of a Unix socket, as the kernel says."
  @spec peer(:gen_tcp.socket()) :: {:ok, pos_integer()} | :error
  def peer(client) do
    case :inet.getopts(client, [{:raw, @sol_socket, @so_peercred, 12}]) do
      {:ok, [{:raw, _, _, <<pid::32-native, _uid::32-native, _gid::32-native>>}]} when pid > 0 ->
        {:ok, pid}

      _ ->
        :error
    end
  end

  @doc "Whether process `pid` is in `username`'s bubble, or one of its tests' roots."
  @spec inside?(String.t(), pos_integer()) :: boolean()
  def inside?(username, pid) do
    case roots(username) do
      [] -> false
      roots -> descends?(pid, roots, @max_depth)
    end
  end

  @doc """
  What `/proc` says of process `pid`: its parent's id, and when it started
  (in clock ticks since boot, as the kernel writes it).
  """
  @spec process(pos_integer()) ::
          {:ok, %{parent: non_neg_integer(), started: String.t()}} | :error
  def process(pid) do
    # The name, in parentheses, may hold anything, ") " included; every
    # field after it is a number or a letter. The state comes first, then
    # the parent; the start time is the stat file's 22nd field.
    with {:ok, text} <- Files.read("/proc/#{pid}/stat"),
         {at, 2} <- text |> :binary.matches(") ") |> List.last(),
         fields = text |> binary_part(at + 2, byte_size(text) - at - 2) |> String.split(" "),
         [_state, parent | _] <- fields,
         {parent, ""} <- Integer.parse(parent),
         started when is_binary(started) <- Enum.at(fields, 19) do
      {:ok, %{parent: parent, started: started}}
    else
      _ -> :error
    end
  end

  defp roots(username) do
    tests =
      case Application.get_env(:mwt_client, __MODULE__, [])[:roots] do
        nil -> []
        roots -> roots.(username)
      end

    List.wrap(bubble(username)) ++ tests
  end

  # The bubble's first process, when the one `bubble.pid` names is still it.
  defp bubble(username) do
    with {:ok, text} <- Files.read(Sockets.host_path(username, "bubble.pid")),
         [pid, started] <- String.split(text),
         {pid, ""} <- Integer.parse(pid),
         {:ok, %{started: ^started}} <- process(pid) do
      pid
    else
      _ -> nil
    end
  end

  defp descends?(pid, roots, depth) do
    cond do
      pid in roots -> true
      pid <= 1 or depth == 0 -> false
      true -> parent_descends?(process(pid), roots, depth)
    end
  end

  defp parent_descends?({:ok, %{parent: parent}}, roots, depth),
    do: descends?(parent, roots, depth - 1)

  defp parent_descends?(:error, _roots, _depth), do: false

  defp say_refused(username, socket_name, pid, said_at) do
    now = System.monotonic_time(:millisecond)

    if said_at && now - said_at < @said_every do
      said_at
    else
      Server.cast(
        username,
        {:log,
         %{
           outcome: :blocked,
           summary:
             "A program outside the VM connected to the VM's #{socket_name}, and was refused: " <>
               who(pid)
         }}
      )

      now
    end
  end

  # The name the program gave itself, which it chose: written out as the
  # VM's own text is.
  defp who(nil), do: "the kernel didn't say which"

  defp who(pid) do
    case Files.read("/proc/#{pid}/comm") do
      {:ok, name} -> "#{Shown.text(String.trim_trailing(name, "\n"))} (process #{pid})"
      {:error, _} -> "process #{pid}, already ended"
    end
  end
end
