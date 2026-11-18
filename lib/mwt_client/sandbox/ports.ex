defmodule MWTClient.Sandbox.Ports do
  @moduledoc """
  Which of the VM's ports show up on your machine, and where.

  Each identity's VM has a fixed address here, `127.77.X.Y` (`address/1`).
  Linux sends all of `127.0.0.0/8` to loopback, so it needs no setup, and a
  port keeps its number there without colliding with this machine's own:
  your `localhost:4000` stays yours.

  Only ports 4100 to 4199 (`range/0`) open here: agents are told to run
  what you'll try on one of them. Everything else that listens in the
  VM, such as language servers, test runs and the tools agents start, stays
  there and isn't shown. The range sits above Phoenix's 4000 and Erlang's
  4369, and far below the ports Linux hands out at random (32768 up), and
  needs no root here.

  The VM says what listens in it (`mwt ports --watch`, started by its boot
  script, sends a report over the agent channel when it changes). `parse/1`
  reads a report: `ss -ltnpH` lines, then a `cwd PID FOLDER` line for each
  process holding a port, so a server can be told apart by the worktree slot
  it runs in (`slot/1`). `plan/1` decides what to forward: each port in the
  range, to the same port on the address, connecting inside the VM to
  loopback when the server listens there or on every address.

  A report is the VM's word, so nothing in it is taken on trust: ports must
  be numbers in range, process names and folders are shown as text only,
  and at most `max_listeners/0` lines are read. The watcher reports only the
  range, and `plan/1` leaves out anything else. All a false report can do
  is have MWT listen on the range of the VM's own address here, and connect,
  in the VM, to ports nothing listens on.

  `MWTClient.Sandbox.Forwarder` keeps the forwards in step; this module only
  decides.
  """

  @range 4100..4199
  @max_listeners 512

  @type listener :: %{
          port: 1..65_535,
          binds: [String.t()],
          process: String.t() | nil,
          pid: pos_integer() | nil,
          cwd: String.t() | nil
        }

  @type entry :: %{
          port: 1..65_535,
          process: String.t() | nil,
          cwd: String.t() | nil,
          target: String.t(),
          status: :forwarded | :pending | {:skipped, String.t()}
        }

  @doc """
  The ports that open on this machine. `mwt ports --watch` in the VM
  (`priv/sandbox/mwt-cli`) and the agents' instructions say the same.
  """
  @spec range() :: Range.t()
  def range, do: @range

  @doc "The range as words: `4100 to 4199`."
  @spec range_text() :: String.t()
  def range_text, do: "#{@range.first} to #{@range.last}"

  @doc "How many lines of a report are read at most."
  @spec max_listeners() :: pos_integer()
  def max_listeners, do: @max_listeners

  @doc """
  The VM's address on this machine, derived from the identity's id: the
  same on every start, and different for each identity's VM.

      iex> MWTClient.Sandbox.Ports.address("abc") == MWTClient.Sandbox.Ports.address("abc")
      true

      iex> String.starts_with?(MWTClient.Sandbox.Ports.address("abc"), "127.77.")
      true
  """
  @spec address(String.t()) :: String.t()
  def address(identity_id) do
    <<x, y, _rest::binary>> = :crypto.hash(:sha256, "mwt-sandbox-address:" <> identity_id)
    "127.77.#{x}.#{rem(y, 254) + 1}"
  end

  @doc "`http://ADDRESS:PORT`."
  @spec url(String.t(), 1..65_535) :: String.t()
  def url(address, port), do: "http://#{address}:#{port}"

  @doc """
  The TCP listeners in a report, one per port, sorted by port, with every
  address the port listens on, the first process holding it, and the folder
  that process runs in when the report says.
  """
  @spec parse(String.t()) :: [listener()]
  def parse(report) do
    lines = report |> String.split("\n", trim: true) |> Enum.take(@max_listeners)

    cwds =
      for line <- lines,
          ["cwd", pid_text, folder] <- [String.split(line, " ", parts: 3)],
          {pid, ""} <- [Integer.parse(pid_text)],
          into: %{},
          do: {pid, String.slice(folder, 0, 4096)}

    lines
    |> Enum.flat_map(&parse_line/1)
    |> Enum.group_by(& &1.port)
    |> Enum.map(fn {port, found} ->
      pid = Enum.find_value(found, & &1.pid)

      %{
        port: port,
        binds: found |> Enum.map(& &1.bind) |> Enum.uniq(),
        process: Enum.find_value(found, & &1.process),
        pid: pid,
        cwd: pid && Map.get(cwds, pid)
      }
    end)
    |> Enum.sort_by(& &1.port)
  end

  defp parse_line(line) do
    with ["LISTEN", _recv, _send, local | rest] <- String.split(line),
         {bind, port} <- split_address(local) do
      users = Enum.join(rest, " ")
      [%{port: port, bind: bind, process: process(users), pid: pid(users)}]
    else
      _ -> []
    end
  end

  # `127.0.0.1:4000`, `[::1]:4000`, `*:4000`, `127.0.0.53%lo:53`.
  defp split_address(local) do
    with [port_text, host] <- local |> String.reverse() |> String.split(":", parts: 2),
         {port, ""} when port in 1..65_535 <- port_text |> String.reverse() |> Integer.parse() do
      host =
        host
        |> String.reverse()
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.replace(~r/%.*$/, "")
        |> String.replace_prefix("::ffff:", "")

      {host, port}
    else
      _ -> nil
    end
  end

  # users:(("beam.smp",pid=123,fd=20)): a process name is at most 15 bytes
  # in Linux, so a longer one is cut there.
  defp process(text) do
    case Regex.run(~r/users:\(\("([^"]+)"/, text) do
      [_, name] -> String.slice(name, 0, 64)
      nil -> nil
    end
  end

  defp pid(text) do
    case Regex.run(~r/users:\(\("[^"]*",pid=(\d+)/, text) do
      [_, pid] -> String.to_integer(pid)
      nil -> nil
    end
  end

  @doc """
  What to forward: each listener in `range/0`, to `target` inside the VM.
  The rest stay in the VM and are left out.
  """
  @spec plan([listener()]) :: [entry()]
  def plan(listeners) do
    for listener <- listeners, listener.port in @range do
      %{
        port: listener.port,
        process: listener.process,
        cwd: listener.cwd,
        target: target(listener.binds),
        status: :pending
      }
    end
  end

  # Loopback when the server listens there or everywhere (`*` is IPv6 with
  # IPv4 too); `::1` for a server only on IPv6; otherwise the one address it
  # listens on, such as another of the VM's loopback addresses.
  defp target(binds) do
    cond do
      Enum.any?(binds, &(&1 in ["0.0.0.0", "*", "127.0.0.1"])) -> "127.0.0.1"
      Enum.any?(binds, &(&1 in ["::", "::1"])) -> "::1"
      true -> hd(binds)
    end
  end

  @doc """
  The words that stop what listens on `port`, one of `range/0`, in the VM:
  each process holding the port gets SIGTERM, as `kill` sends it. What
  holds the port is looked up again there, so a report that has gone stale
  can't have another process stopped. It prints the process ids it
  signalled (`stopped/1`), nothing when nothing listens there any more.
  """
  @spec stop_words(1..65_535) :: [String.t()]
  def stop_words(port) when port in @range do
    script = """
    pids=$(ss -ltnpH "( sport = :$1 )" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
    [ -z "$pids" ] || kill $pids
    echo $pids
    """

    ["sh", "-c", script, "mwt-stop-server", Integer.to_string(port)]
  end

  @doc ~S"""
  The process ids `stop_words/1` says it signalled.

      iex> MWTClient.Sandbox.Ports.stopped("812 815\n")
      [812, 815]

      iex> MWTClient.Sandbox.Ports.stopped("\n")
      []
  """
  @spec stopped(String.t()) :: [pos_integer()]
  def stopped(output) do
    for word <- String.split(output), {pid, ""} <- [Integer.parse(word)], pid > 0, do: pid
  end

  @doc """
  The project and worktree slot a server runs in, from its folder:
  `/work/NAME.wt/slot-N`, or a folder inside it.

      iex> MWTClient.Sandbox.Ports.slot("/work/app.wt/slot-2/assets")
      {"app", "slot-2"}

      iex> MWTClient.Sandbox.Ports.slot("/work/app")
      nil
  """
  @spec slot(String.t() | nil) :: {String.t(), String.t()} | nil
  def slot(nil), do: nil

  def slot(cwd) do
    case Regex.run(~r{\A/work/([^/]+)\.wt/(slot-\d+)(?:/|\z)}, cwd) do
      [_, project, slot] -> {project, slot}
      nil -> nil
    end
  end
end
