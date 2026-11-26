defmodule MWTClient.Sandbox.Channel do
  @moduledoc """
  How agents in the VM ask MWT for access: a Unix socket that microsandbox
  joins to the VM's vsock port 5000 (`msb create --vsock`). The VM has no
  network route to MWT, so this is the only way in, and all it offers is
  reading the grants and the host's description, asking for a grant,
  asking to run a command on the host, working in projects: what a
  project is, a worktree of one's own, and handoffs
  (`MWTClient.Sandbox.Projects`, `MWTClient.Sandbox.Handoffs`), and MWT's
  own tools over MCP (`mwt mcp`, `serve_mcp/3`,
  `MWTClient.Sandbox.MwtTools`).

  Inside the VM, `/mnt/mwt/bin/mwt` (`priv/sandbox/mwt-cli`) speaks it with
  socat, one ask per connection:

    * the client sends one line of JSON: `{"command": "grants"}`,
      `{"command": "host"}`, `{"command": "why", "target": "HOST[:PORT]"}`
      (`MWTClient.Sandbox.Why`), `{"command": "ports"}` (with `"report"` from
      the VM's watcher, what listens in it), `{"command": "sync", "path": "..."}`
      (the shared folders' copies, `MWTClient.Sandbox.Server.ShareSync`),
      `{"command": "request", "grant": "...",
      "need": "...", "minutes": 60, "reason": "...", "agent": "...",
      "thread": "...", "thread_id": "...", "folder": "...", "wait": 60}`, `{"command": "run", "script": "...", "dir": "...",
      "timeout": 120, "reason": "...", "agent": "...", "thread": "...",
      "thread_id": "...", "folder": "...", "wait": 60}` or
      `{"command": "wait", "id": "...", "wait": 60}`;
    * MWT answers with the exit status the command should end with on the
      first line, then text for the agent, and closes.

  Exit statuses for grants: 0 the grant is on, 1 something is wrong with the
  ask, 2 still waiting for the user, 3 declined or given up. The command
  itself uses 4 when MWT doesn't answer: locked, or not running; MWT
  answers 4 too when its sandbox failed answering and started again.

  A command that ran answers `ran STATUS` on the first line, a note for the
  agent's stderr on the second (often empty), then the output. MWT's own
  outcomes for runs use statuses commands rarely use: 120 still waiting,
  121 it didn't run or its output didn't come back, 122 something is wrong
  with the ask, and the command itself uses 123 when MWT doesn't answer.
  Asks to run have ids starting with `run-`, so `mwt wait` knows which set
  of statuses applies.

  An ask waits for you as an activation approval (`MWTClient.Sandbox.Approval`)
  for 30 minutes; the agent waits at most `"wait"` seconds of it, then hears
  it is still pending and can come back with `mwt wait`. Any process in the
  VM can ask, which is accepted: all it can do is ask. The server keeps one
  waiting ask per grant and ten in all.

  One ask keeps its connection: `{"command": "attach", ...}`, from an
  `mwt-acp` in the VM, which `MWTClient.Sandbox.AgentThreads` serves for as
  long as it stays open.

  One listener per unlocked identity. Microsandbox opens the socket for each
  connection, so when MWT restarts, the channel works again without touching
  the VM.

  Any process in the VM can connect, as often as it likes, so what it can
  hold of MWT is bounded: 64 connections served at once (one more is closed
  unanswered, and `mwt` says MWT isn't answering), an ask's line within 10
  s, and an MCP message whole within 30 s, at most 8 of them read at once.
  """

  use GenServer

  require Logger

  alias MWTClient.Sandbox.{
    AgentThread,
    AgentThreads,
    Approval,
    Explain,
    Gate,
    Grant,
    GitTransport,
    Handoff,
    HandoffRecords,
    Handoffs,
    HostCommand,
    HostGit,
    Inbound,
    Instructions,
    Param,
    Policy,
    Projects,
    Routes,
    Server,
    Shares,
    Shown,
    Slots,
    Sockets,
    TaskBase,
    Why,
    Workspace,
    Zed
  }

  alias MWTClient.MCP.Protocol
  alias MWTClient.Sandbox.MwtTools
  alias MWTClient.Vault.Store

  @port 5000
  @line_limit 64 * 1024
  @mcp_limit 2_000_000
  @read_timeout 10_000
  # What the VM can hold of MWT through the channel: connections served at
  # once (an attached `mwt-acp` keeps one, an ask waiting for you another),
  # MCP messages being read at once (up to `@mcp_limit` each), and how long
  # one may take to arrive, whole.
  @max_connections 64
  @max_mcp_reading 8
  @mcp_read_ms 30_000
  @default_wait 60
  @max_wait 600

  @run_waiting 120
  @run_not_done 121
  @run_wrong 122
  @run_unreachable 123

  # The asks `answer/3` takes, each answered by a clause of `reply/3`;
  # `attach`, `mcp` and `git` are served apart (`serve/2`).
  @commands ~w(grants host why ports sync project worktree handoff handoffs call propose run
               request wait vm)
  # What acts on the user's behalf, refused while the VM is isolated.
  @acting ~w(request run call propose handoff)
  @isolated "MWT's firewall isolated this VM: nothing it sends leaves through MWT until the user releases it. The user has been told. Stop, and tell them what you were doing."

  @doc "The commands an ask may name, besides `attach`, `mcp` and `git`."
  @spec commands() :: [String.t()]
  def commands, do: @commands

  @doc "The vsock port agents connect to inside the VM."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc "The host socket of one identity's channel (`MWTClient.Sandbox.Sockets`)."
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(username), do: Sockets.path(username, "channel.sock")

  @doc "Starts the channel of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    Sockets.ensure!(username)
    path = socket_path(username)
    File.rm(path)

    case :gen_tcp.listen(0, [
           :binary,
           ifaddr: {:local, path},
           active: false,
           packet: :line,
           packet_size: @line_limit,
           # Line mode hands over a line longer than the driver's own buffer
           # cut at its size (9216 bytes by default), whatever `packet_size`
           # allows: a longer ask (a script, a handoff's notes) would read as
           # broken JSON. The cost: 64 KiB a connection while it is read.
           buffer: @line_limit + 1,
           backlog: 64
         ]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        acceptor = spawn_link(fn -> accept(socket, username, %{}) end)

        {:ok, %{username: username, path: path, socket: socket, acceptor: acceptor, reading: %{}}}

      {:error, reason} ->
        # The VM loses only its way to ask; everything else keeps working.
        Logger.warning("sandbox channel could not listen on #{path}: #{inspect(reason)}",
          system: :sandbox
        )

        {:ok, %{username: username, path: path, socket: nil, acceptor: nil, reading: %{}}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | reading: Map.delete(state.reading, ref)}}

  # A place to read one MCP message in, while fewer than `@max_mcp_reading`
  # are: given back by `{:mcp_read, ref}`, or when its reader ends.
  @impl true
  def handle_call(:mcp_reading, {pid, _tag}, state) do
    if map_size(state.reading) >= @max_mcp_reading do
      {:reply, :busy, state}
    else
      ref = Process.monitor(pid)
      {:reply, {:ok, ref}, %{state | reading: Map.put(state.reading, ref, pid)}}
    end
  end

  @impl true
  def handle_cast({:mcp_read, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | reading: Map.delete(state.reading, ref)}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    File.rm(state.path)
    :ok
  end

  # Each connection is served in a task of its own, at most
  # `@max_connections` at once: `open` holds the monitors of those that
  # run. One more is closed unanswered.
  defp accept(socket, username, open) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        open = ended(open)

        if map_size(open) >= @max_connections do
          :gen_tcp.close(client)
          accept(socket, username, open)
        else
          accept(socket, username, serve_in_task(client, username, open))
        end

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end

  defp serve_in_task(client, username, open) do
    case Task.Supervisor.start_child(MWTClient.Sandbox.TaskSupervisor, fn ->
           receive do
             {:go, client} -> serve(client, username)
           after
             5_000 -> :ok
           end
         end) do
      {:ok, pid} ->
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, {:go, client})
        Map.put(open, Process.monitor(pid), pid)

      {:error, _reason} ->
        :gen_tcp.close(client)
        open
    end
  end

  defp ended(open) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} -> ended(Map.delete(open, ref))
    after
      0 -> open
    end
  end

  @doc "How many connections the channel serves at once."
  @spec max_connections() :: pos_integer()
  def max_connections, do: @max_connections

  @doc false
  # One ask: a line of JSON in, an exit status and text out. An `mcp` ask is
  # followed by one MCP message, a line of its own (`serve_mcp/3`); an
  # `attach` keeps its connection, for `AgentThreads`.
  def serve(client, username) do
    ask =
      case :gen_tcp.recv(client, 0, @read_timeout) do
        {:ok, line} -> read(line)
        {:error, _reason} -> :none
      end

    case ask do
      %{"command" => "attach"} -> attach(client, username, ask)
      %{"command" => "mcp"} -> serve_mcp(client, ask, username)
      %{"command" => "git"} -> GitTransport.serve(client, username, ask)
      _other -> serve_ask(client, ask, username)
    end
  end

  # An `mwt-acp` keeping its connection: served by `AgentThreads` until it
  # ends, instead of one answer and close.
  defp attach(client, username, ask) do
    AgentThreads.attach(username, client, ask)
  catch
    :exit, _reason ->
      :gen_tcp.send(client, encode({4, unanswered(username)}))
  after
    :gen_tcp.close(client)
  end

  defp serve_ask(client, ask, username) do
    reply =
      try do
        case ask do
          :unreadable -> {1, "MWT couldn't read that ask. Use the mwt command."}
          :none -> {1, "MWT got no ask."}
          %{"command" => command} -> answer(command, ask, username)
        end
      catch
        :exit, _reason ->
          status = if run?(ask), do: @run_unreachable, else: 4
          {status, unanswered(username)}
      end

    :gen_tcp.send(client, encode(reply))
    :gen_tcp.close(client)
  end

  # Why MWT didn't answer an ask: locked, or the sandbox failed answering
  # it and started again, which keeps grants as they were but not what
  # the ask was waiting for. `UnlockState` lives as long as the unlock,
  # through the server's restarts.
  defp unanswered(username) do
    if Store.whereis(MWTClient.Sandbox.UnlockState, username),
      do:
        "MWT failed while answering this and started its sandbox again: nothing of this ask was kept. " <>
          "Ask again; if it fails again, tell the user.",
      else: "MWT is locked. Ask the user to unlock it."
  end

  @doc """
  Reads one line from the VM as an ask, or `:unreadable`.

  The line is the VM's, so nothing in it is taken on trust. An ask carries
  text, whole numbers and yes or no; anything else in it (a list, a map, a
  fraction) is dropped. Its text is made to show all it holds
  (`MWTClient.Sandbox.Shown`), since most of it ends on an approval. A
  script is the exception: it runs as it was sent or not at all, so it is
  left as it is here and checked in `MWTClient.Sandbox.HostCommand`. So are
  the `values` of a call, a map of texts checked against the action's
  parameters (`MWTClient.Sandbox.Param`); `params`, `headers` and what a
  proposed grant lists (`hosts`, `env`, `file_env`, `carriers`,
  `signs_as`, `destinations`) are lists of texts; a proposal's `set` and
  `fill`, maps of texts.
  """
  @lists ~w(params headers hosts env file_env carriers signs_as destinations)

  @spec read(binary()) :: map() | :unreadable
  def read(line) do
    case Jason.decode(line) do
      {:ok, %{"command" => command} = ask} when is_binary(command) ->
        Map.new(ask, fn
          {"script", value} when is_binary(value) -> {"script", value}
          {"values", %{} = values} -> {"values", texts(values)}
          {key, %{} = pairs} when key in ["set", "fill"] -> {key, shown(pairs)}
          {key, list} when key in @lists and is_list(list) -> {key, lines(list)}
          {key, value} when is_binary(value) -> {key, Shown.text(value)}
          {key, value} when is_integer(value) or is_boolean(value) -> {key, value}
          {key, _other} -> {key, nil}
        end)

      _other ->
        :unreadable
    end
  end

  # A call's values: the texts among them, as they were sent.
  defp texts(values) do
    for {name, value} <- Enum.take(values, 32), is_binary(name), is_binary(value), into: %{} do
      {name, value}
    end
  end

  # A proposal's FIELD=VALUE pairs: texts, as the user will read them.
  defp shown(pairs) do
    for {name, value} <- Enum.take(pairs, 32), is_binary(name), is_binary(value), into: %{} do
      {name, Shown.text(value)}
    end
  end

  defp lines(list),
    do: for(line <- Enum.take(list, 32), is_binary(line), do: Shown.text(line))

  @doc false
  # One MCP message from `mwt mcp`, the server agents in the VM run on
  # stdio: a line of JSON-RPC after the ask, up to 2 MB, answered by MWT's
  # own server (`MWTClient.MCP.Protocol`) as an agent in the VM
  # (`MWTClient.Sandbox.MwtTools`). Back: 0, then the response on a line,
  # or an empty line for a notification.
  def serve_mcp(client, ask, username) do
    :ok = :inet.setopts(client, packet: :raw)
    deadline = System.monotonic_time(:millisecond) + mcp_read_ms()

    reply =
      case read_mcp(client, username, deadline) do
        {:ok, line} ->
          "0\n" <> mcp_answer(line, ask, username) <> "\n"

        :too_big ->
          "0\n" <>
            Jason.encode!(Protocol.error(nil, -32600, "An MCP message is at most 2 MB.")) <> "\n"

        :too_slow ->
          "1\nMWT got no whole MCP message in time.\n"

        :busy ->
          "1\nMWT is reading #{@max_mcp_reading} MCP messages from this VM already. Try again.\n"

        :none ->
          "1\nMWT got no MCP message.\n"
      end

    :gen_tcp.send(client, reply)
    :gen_tcp.close(client)
  end

  # Only tests configure `config :mwt_client, MWTClient.Sandbox.Channel,
  # mcp_read_ms: …`, so a slow message gives up sooner.
  defp mcp_read_ms,
    do: Application.get_env(:mwt_client, __MODULE__, [])[:mcp_read_ms] || @mcp_read_ms

  # One message, read while the channel gives a place to read it in.
  defp read_mcp(client, username, deadline) do
    channel = Store.via(__MODULE__, username)

    case GenServer.call(channel, :mcp_reading) do
      {:ok, ref} ->
        try do
          read_message(client, [], 0, deadline)
        after
          GenServer.cast(channel, {:mcp_read, ref})
        end

      :busy ->
        :busy
    end
  catch
    :exit, _locked -> :none
  end

  defp read_message(client, acc, size, deadline) do
    case :gen_tcp.recv(client, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, chunk} ->
        size = size + byte_size(chunk)
        acc = [chunk | acc]

        cond do
          :binary.match(chunk, "\n") != :nomatch ->
            [line | _rest] = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.split("\n")
            {:ok, line}

          size > @mcp_limit ->
            :too_big

          true ->
            read_message(client, acc, size, deadline)
        end

      {:error, :timeout} ->
        if acc == [], do: :none, else: :too_slow

      {:error, _closed} ->
        if acc == [], do: :none, else: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp mcp_answer(line, ask, username) do
    claims =
      Map.new([:agent, :thread, :thread_id, :folder], fn key ->
        case ask[Atom.to_string(key)] do
          text when is_binary(text) and text != "" -> {key, text}
          _none -> {key, nil}
        end
      end)

    case Jason.decode(line) do
      {:ok, message} ->
        # A result enters the VM: no real value goes with it, in any
        # form. Shapes aren't looked for: your notes are yours.
        case Protocol.handle(message, MwtTools.caller(username, claims)) do
          :accepted -> ""
          response -> response |> Jason.encode!() |> Inbound.scrub(Gate.secrets(username))
        end

      {:error, _reason} ->
        Jason.encode!(Protocol.error(nil, -32700, "Invalid JSON."))
    end
  end

  # The output ends with a dot, so a shell reading it with `$(...)` keeps
  # its trailing newlines; the mwt command takes the dot off.
  defp encode({{:ran, status}, note, output}), do: "ran #{status}\n#{note}\n#{output}."
  defp encode({status, text}), do: "#{status}\n#{String.trim_trailing(text)}\n"

  # An answer `mwt` reads a line at a time (its `plan_value`): `key=value`,
  # each value on one line.
  defp key_lines(pairs) do
    Enum.map_join(pairs, "\n", fn {key, value} ->
      "#{key}=#{String.replace(value, ~r/[\r\n]+/, " ")}"
    end)
  end

  defp handed_words(handoff, how) do
    first =
      case how do
        :opened ->
          "Handed off as ##{handoff.id}: #{handoff.source.branch} based on #{Handoff.base_words(handoff)}."

        :updated ->
          "Updated handoff ##{handoff.id} (revision #{handoff.revision}): #{handoff.source.branch} based on #{Handoff.base_words(handoff)}."
      end

    Enum.join(
      [
        first,
        "#{count(handoff.stats[:commits] || 0, "commit")}, #{count(handoff.stats[:files] || 0, "file")} changed, at #{String.slice(handoff.head, 0, 12)}. It is caught up with #{Handoff.base_label(handoff)} as the user has it now.",
        "The user reviews this exact revision: work you do from here doesn't change it. They land it on its base or another branch they choose: as it is (a fast-forward, these same commits) when that branch hasn't moved, or as one commit.",
        "If they say it came too soon, undo its commits but keep the work, uncommitted for them to see: git reset $(git merge-base HEAD #{Handoff.base_in_vm(handoff)})",
        "More work stays uncommitted until they ask for the handoff again: mwt handoff then folds it into the handoff's commit, as a new revision.",
        "See what they decide with: mwt handoffs"
      ],
      "\n"
    )
  end

  defp handoff_words({handoff, facts}, where, look) do
    state =
      case handoff.status do
        :open -> "open, waiting for the user"
        :sent_back -> "sent back to you"
        :withdrawn -> "withdrawn: taken back for more work; mwt handoff again updates it"
        :accepted -> "landed: " <> Handoffs.accepted_words(handoff.accepted)
        :closed -> "closed by the user"
      end

    held = look && Enum.find(look.worktrees, &(&1.branch == handoff.source.branch))
    yours = if held && where == {:worktree, held.path}, do: " (this branch)", else: ""

    lines =
      [
        "##{handoff.id}  #{state}#{yours}",
        "  #{handoff.title}",
        "  #{handoff.source.branch}, compared with #{Handoff.base_words(handoff)}; revision #{handoff.revision}"
      ] ++
        place_lines(handoff, look, held) ++ fact_lines(handoff, facts) ++ note_lines(handoff)

    Enum.join(lines, "\n")
  end

  # Where an unfinished handoff's branch is now, so its thread finds it.
  defp place_lines(_handoff, nil, _held), do: []

  defp place_lines(%{status: status} = handoff, look, held)
       when status in [:open, :sent_back, :withdrawn] do
    case held do
      nil ->
        if Handoff.branch_deleted?(handoff),
          do: ["  " <> Handoffs.resume_words(handoff.source.branch)],
          else: [
            "  Its branch is in no worktree now. To continue it, ask the user to start a thread in a free slot, which runs: mwt worktree resume #{handoff.source.branch}"
          ]

      %{missing?: true} ->
        [
          "  Its worktree's folder is gone; the branch stays. To continue it, ask the user to start a thread in a free slot, which runs: mwt worktree resume #{handoff.source.branch}"
        ]

      %{path: path} ->
        case Slots.slot_at(look, path) do
          %{name: name} -> ["  In #{name}, #{path}."]
          nil -> ["  In #{path}."]
        end
    end
  end

  defp place_lines(_handoff, _look, _held), do: []

  defp fact_lines(_handoff, nil), do: []

  defp fact_lines(handoff, facts) do
    behind =
      if facts.behind > 0,
        do: [
          "  #{capitalized(Handoff.base_words(handoff))} has #{count(facts.behind, "commit")} this branch doesn't have."
        ],
        else: []

    conflicts =
      case facts.conflicts do
        [] when facts.behind > 0 ->
          [
            "  It applies cleanly to #{Handoff.base_words(handoff)}, but wasn't built or tested with those commits.",
            "  The user may land it as one commit anyway; a revision catches up with them first (mwt handoff does)."
          ]

        [] ->
          ["  It applies cleanly to #{Handoff.base_words(handoff)}."]

        files ->
          [
            "  It conflicts with #{Handoff.base_words(handoff)} in: " <>
              Enum.join(files, ", "),
            "  It lands only once caught up: the next mwt handoff rebases onto it and stops at the conflicts for you to resolve."
          ]
      end

    behind ++ conflicts
  end

  defp capitalized(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  # What the user said the last time they sent it back.
  defp note_lines(%{status: :sent_back, timeline: timeline}) do
    case timeline |> Enum.filter(&(&1.kind == :sent_back)) |> List.last() do
      %{note: note, catch_up: true} ->
        [
          "  Sent back to catch up: #{note}",
          "  It is the user's ask to hand off again: run mwt handoff until it hands off."
        ]

      %{note: note} when note not in [nil, ""] ->
        ["  The user's note: #{note}"]

      _ ->
        []
    end
  end

  defp note_lines(%{status: :withdrawn, timeline: timeline}) do
    case timeline |> Enum.filter(&(&1.kind == :withdrawn)) |> List.last() do
      %{note: note} when note not in [nil, ""] -> ["  Taken back for: #{note}"]
      _ -> []
    end
  end

  defp note_lines(_handoff), do: []

  # Who commits in the project, set by the mirror from the user's own
  # repository (`MWTClient.Sandbox.Mirror`), and what agents leave alone.
  defp identity_words(%{name: name, email: email}),
    do:
      "Commits here are the user's: #{Shown.text(name)} <#{Shown.text(email)}>, as in their repository on their machine, set by MWT. Don't change user.name or user.email, don't pass --author, and add no Co-Authored-By or \"Generated with\" lines."

  defp identity_words(nil),
    do:
      "Commits here are the user's, but their repository has no user.name and user.email on their machine, so MWT set none here. Tell the user before you commit, rather than set one."

  @review_words [
    "Leave your work uncommitted, so the user sees every change in Zed: never commit unless they say so. When it is done and tested, tell them it is ready for review and where, and wait.",
    "Hand off only when they ask (/handoff is that ask): write a title and notes, git add the new files that belong to the work, then mwt handoff --title \"…\" --body FILE. It fetches host-origin, commits the changes to files git has with the title (folding them into the handoff's commit for a new revision), catches up with the task's base by rebasing onto host-origin/BASE, runs the project's checks, if any, and sends that exact commit; when it stops, do what it says and run it again.",
    "If they say a handoff came too soon, undo its commits but keep the work, uncommitted for them to see: git reset $(git merge-base HEAD host-origin/BASE)",
    "host-origin is the user's repository on their machine, through MWT: git fetch host-origin brings their branches as host-origin/BRANCH. remote-origin is that repository's own remote, origin (GitHub, say), as their machine fetches it: remote-origin/BRANCH. There is no origin. A push to either is refused: work goes back by mwt handoff."
  ]

  defp branch_words(nil),
    do: "The user's branches are host-origin/BRANCH here (git fetch host-origin brings them)."

  defp branch_words(branches) do
    shown = Enum.take(branches, 30)
    more = if length(branches) > length(shown), do: ", …", else: ""

    "The user's branches, as host-origin/BRANCH (git fetch host-origin brings them): " <>
      Enum.map_join(shown, ", ", &("host-origin/" <> &1)) <> more <> "."
  end

  defp project_words(project, where, look, thread, branches) do
    clone = if look, do: look.mirror, else: "/work/#{project.name}"

    {:worktree, top} = where

    here = look && Slots.slot_at(look, top)

    place =
      case here do
        %{free?: true} = slot ->
          "You are in #{slot_label(slot)}, #{slot.path}, which is #{Slots.words(slot)}. Take it now, before anything else, even if the ask may change no code: mwt worktree new TASK --from BRANCH, with TASK named for what the user asked (fix-login-timeout, explain-handoff-sync; never task or wip) and BRANCH the branch they want the work based on: if they named none, ask them which first (their branches are host-origin/BRANCH here). Until then it shows as free, and the user may start another thread in it."

        %{branch: nil} = slot ->
          "You are in #{slot_label(slot)}, #{slot.path}: #{Slots.words(slot)}. It isn't free: if that work isn't your thread's, stop and tell the user."

        %{} = slot ->
          held_place(slot, Slots.holder(slot, thread))

        nil ->
          "You are in the worktree #{top}, which isn't a slot: no task starts here, and nothing is handed off from it. Read and run things here; to change code, ask the user to start a thread in a free slot (below) and give it the task there."
      end

    targets =
      "#{branch_words(branches)} Each task names the branch it is based on when it starts: mwt worktree new TASK --from BRANCH, the branch the user named, or the one they answer when you ask; it fetches host-origin first. mwt handoff rebases the task onto host-origin/BRANCH before it sends the work. The user lands a handoff on its base or another branch they choose, or on a new mwt/ branch: as it is (a fast-forward) when that branch hasn't moved since, or as one commit."

    checks =
      case project.checks do
        "" ->
          "No checks are set: mwt handoff runs none before it sends the work (the user sets them on MWT's Projects page)."

        command ->
          "Before it sends the work, mwt handoff runs the project's checks: #{command}"
      end

    Enum.join(
      [
        "Project #{project.name}: a clone of the user's repository, #{clone}, whose host-origin is that repository on their machine, through MWT.",
        place,
        targets,
        checks,
        "The clone's branches are the VM's: MWT never moves or resets one, and deletes a task's branch only once its handoff landed with nothing done on it since. Use refs/heads/TASK to base work on another VM task, or a commit ID for a snapshot."
      ] ++
        slot_lines(look, here) ++ [identity_words(HostGit.identity(project.path)) | @review_words],
      "\n"
    )
  end

  defp slot_label(%{name: "slot-0"}), do: "slot-0 (the clone itself)"
  defp slot_label(%{name: name}), do: name

  # Whether MWT can say something in this thread (`AgentThreads`): only a
  # thread open through mwt-acp, one of MWT's agents in Zed.
  @doc false
  def reach_words(%AgentThread{open?: true} = thread),
    do:
      "MWT can reach this thread (#{AgentThread.agent_name(thread)}): what MWT says to it, such as a handoff the user sends back with a note, arrives here as a message from MWT."

  def reach_words(_not_reachable),
    do:
      "MWT can't reach this thread: it wasn't started with Claude (MWT) or Codex (MWT) in Zed's agent panel. So a handoff the user sends back, and other news from MWT, won't arrive here by themselves. Tell the user once, early: to have that, they start a thread with Claude (MWT) or Codex (MWT) in Zed's agent panel, in the same folder, and give it the task there; a task this thread holds moves there with mwt worktree resume BRANCH. Until then, look at mwt handoffs yourself when the user mentions a handoff."

  # A slot on a task branch: yours, another thread's (read-only here), or
  # either, when MWT has no thread on record or the agent names none.
  defp held_place(slot, :yours),
    do:
      "You are in #{slot_label(slot)}, #{slot.path}, which your thread holds for its task #{slot.branch} until its handoff lands or is closed: yours to change, and to hand off from once the user asks. If the user asks for more: #{Slots.more_work_words(slot)}"

  defp held_place(slot, :another),
    do:
      "You are in #{slot_label(slot)}, #{slot.path}, which another thread holds for its task #{slot.branch}. Tell the user. #{Slots.read_only_words(slot)}"

  defp held_place(slot, _unknown),
    do:
      "You are in #{slot_label(slot)}, #{slot.path}, held by the task branch #{slot.branch} until its handoff lands or is closed. If #{slot.branch} is your thread's task, it is yours to change, and to hand off from once the user asks; if it isn't, another thread holds this slot: tell the user, and go on here only read-only (no edits, no git changes, no builds or tests, no mwt worktree or mwt handoff)."

  defp slot_lines(nil, _here), do: []

  defp slot_lines(look, here) do
    width = look.slots |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end)

    [
      "Worktree slots, each holding one task branch at a time (slot-0 is the clone itself; what git ignores stays between tasks):"
    ] ++
      Enum.map(look.slots, fn slot ->
        mark =
          cond do
            here && slot.path == here.path -> "  (here)"
            slot.free? -> "  (open: #{Zed.command(slot.path)})"
            true -> ""
          end

        "  #{String.pad_trailing(slot.name, width)}  #{Slots.words(slot)}#{mark}"
      end) ++
      [
        "Each thread works only in the slot it is in: never change, build or run things in another slot, not even by absolute path. In your slot: take it first with mwt worktree new TASK --from BRANCH, named for what the user asked, even for a question, from the branch they want it based on (ask them when they named none); it stays yours until its handoff lands or is closed. More work while its handoff is open goes into its next revision. Free it with mwt worktree free only when the user says its task is done or dropped. Continue a sent-back branch with mwt worktree resume BRANCH."
      ]
  end

  defp taken_words(slot, outcome, onto, where) do
    here? = where == {:worktree, slot.path}

    what =
      case outcome do
        :started ->
          "Started the task #{slot.branch} in #{slot.name}, #{slot.path}: a new branch from host-origin/#{onto}, the user's #{onto} as just fetched. What git ignores there (deps, _build, …) stays from the slot's last task."

        :resumed ->
          "Put the branch #{slot.branch}, as it was, in #{slot.name}, #{slot.path}. Its recorded base stays with it. mwt handoff fetches host-origin, catches up with that base and runs the checks before sending."

        :already ->
          "#{slot.branch} is in #{slot.name} already, #{slot.path}."

        :adopted ->
          "#{slot.branch} is in #{slot.name} already, #{slot.path}, and another thread held it: this thread holds it now. Carry on its task as the user asked; the other thread only reads there from now on."
      end

    go =
      if here?,
        do: ["You are in it: continue here. In Zed: #{Zed.command(slot.path)}"],
        else: [
          "It isn't the slot you are in: don't work in it from here. Ask the user to go on in a thread there. In Zed: #{Zed.command(slot.path)}",
          "or from MWT's Projects page."
        ]

    Enum.join([what | go], "\n")
  end

  defp freed_words(%{state: state} = slot) when state in [:absent, :missing],
    do: "#{slot.name} is free already: #{Slots.words(slot)}."

  defp freed_words(%{task?: false, branch: branch} = slot) when is_binary(branch),
    do:
      "#{slot.name} is free already: it is on #{branch}, which no task started, and a task can start in it with mwt worktree new TASK --from BRANCH."

  defp freed_words(%{branch: nil} = slot),
    do:
      "#{slot.name} is free already: a task can start in it with mwt worktree new TASK --from BRANCH."

  defp freed_words(slot) do
    after_words =
      case slot.handoff do
        %{status: status, id: id} when status in [:open, :sent_back, :withdrawn] ->
          " Its handoff ##{id} is #{Slots.status_word(status)}: if the user sends it back, continue it with mwt worktree resume #{slot.branch}."

        nil ->
          " It has no handoff."

        _done ->
          ""
      end

    "Freed #{slot.name}, #{slot.path}: it is on no branch now, and a task can start in it with mwt worktree new TASK --from BRANCH. The branch #{slot.branch} stays, with its commits." <>
      after_words
  end

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp run?(%{"command" => command}) when command in ["run", "call"], do: true
  defp run?(%{"command" => "wait", "id" => "run-" <> _}), do: true
  defp run?(_ask), do: false

  @doc """
  The answer to one ask, as `{exit_status, text}`. Public for the tests,
  which ask without a socket.

  While MWT's firewall holds the VM isolated, what acts (`@acting`) is
  refused before anything else; what only reads still answers, so the
  agent can tell the user what happened. It hears that the VM is isolated,
  never which rule fired.
  """
  @spec answer(String.t(), map(), String.t()) ::
          {non_neg_integer(), String.t()} | {{:ran, integer()}, String.t(), String.t()}
  def answer(command, ask, username) when command in @acting do
    if Server.call(username, :firewall_isolated?),
      do: {isolated_status(command), @isolated},
      else: reply(command, ask, username)
  end

  def answer(command, ask, username), do: reply(command, ask, username)

  defp isolated_status(command) when command in ["run", "call"], do: @run_not_done
  defp isolated_status(command) when command in ["request", "propose"], do: 3
  defp isolated_status(_handoff), do: 1

  defp reply("grants", _ask, username) do
    grants = Server.call(username, :agent_grants)
    {0, Instructions.grants(grants, DateTime.utc_now())}
  end

  defp reply("host", _ask, username), do: {0, Server.call(username, :host_text)}

  # The last decisions on this VM's requests, and one of them by id
  # (`MWTClient.Sandbox.Explain`): its own uses only, since it started.
  defp reply("why", %{"recent" => true}, username) do
    with %{} = view <- Gate.view(username),
         %{vm: vm, waiting: waiting} <- Server.call(username, :snapshot) do
      since = Map.get(vm, :started_at)
      events = MWTClient.Sandbox.events(username, %{since: since, limit: 500})
      _ = view
      {0, Explain.recent(events, waiting, view.grants, since)}
    else
      _ -> {4, "MWT is locked or closing. Ask the user to unlock it."}
    end
  end

  defp reply("why", %{"target" => "event-" <> _ = id}, username),
    do: explain_decision(username, MWTClient.Sandbox.event(username, id))

  defp reply("why", %{"target" => "approval-" <> _ = id}, username) do
    %{waiting: waiting, history: history} = Server.call(username, :snapshot)
    explain_decision(username, Enum.find(waiting ++ history, &(&1.id == id)))
  end

  # A request not made yet, decided as it would be now: sends nothing.
  defp reply("why", %{"target" => "http" <> _ = url} = ask, username) do
    case explain_world(username) do
      nil ->
        {4, "MWT is locked or closing. Ask the user to unlock it."}

      world ->
        case Explain.request(
               String.slice(url, 0, 2000),
               text_or_nil(ask["method"]),
               text_or_nil(ask["with"]),
               world
             ) do
          {:ok, answer} -> {0, answer}
          {:error, message} -> {1, message}
        end
    end
  end

  # Which grant covers a destination, and why the VM doesn't reach it now
  # (`MWTClient.Sandbox.Why`): read from the view the network path decides
  # from, without asking the server.
  defp reply("why", ask, username) do
    case Gate.view(username) do
      nil ->
        {4, "MWT is locked or closing. Ask the user to unlock it."}

      view ->
        world = %{
          snapshot:
            view.grants
            |> Policy.snapshot([], Map.get(view, :locks, %{}), Map.get(view, :limits, %{}))
            |> Map.put(:answered, Gate.answered_map(username)),
          firewall: view.firewall,
          isolated: Gate.isolated?(username, view),
          now: DateTime.utc_now(),
          route: &Routes.via/1
        }

        target = if is_binary(ask["target"]), do: String.slice(ask["target"], 0, 300), else: ""

        case Why.explain(target, world) do
          {:ok, answer} -> {0, answer}
          {:error, message} -> {1, message}
        end
    end
  end

  # From the VM's watcher (`mwt ports --watch`), what listens in it; asked
  # bare (`mwt ports`), where its servers open on this machine. Any process
  # in the VM can report: all a false report does is have MWT listen on more
  # of the VM's own address here (`MWTClient.Sandbox.Ports`).
  defp reply("ports", %{"report" => report}, username) when is_binary(report) do
    :ok = Server.call(username, {:ports_report, report})
    {0, "ok"}
  end

  defp reply("ports", _ask, username), do: {0, Server.call(username, :ports_text)}

  # The copies of the shared folders, brought up to date, and the
  # workspace's two halves: every one, or the one holding `path`. It waits
  # for the sync, however long it takes. The grant Shared folders: sync
  # decides what goes into the VM; Workspace: write to your machine, what
  # of from-vm comes out. With no path, a copy back it refuses leaves the
  # rest to sync, and says why.
  defp reply("sync", ask, username) do
    %{shares: shares, workspace: root} = Server.call(username, :projects)

    with {:ok, which, grants} <- sync_which(shares, root, ask["path"]),
         {:ok, which, notes} <- sync_allowed(username, which, grants, shares, root),
         {:ok, statuses} <- Server.call(username, {:sync_shares_wait, which}, :infinity) do
      sync_words(statuses, notes)
    else
      {:error, message} -> {1, message}
    end
  end

  defp reply("project", ask, username) do
    case Projects.place(username, ask["cwd"]) do
      {:ok, project, where, look} ->
        reach = reach_words(AgentThreads.get(username, ask["thread_id"]))
        branches = Projects.mirrored(username, project.name)

        {0, project_words(project, where, look, ask["thread_id"], branches) <> "\n" <> reach}

      {:error, reason} ->
        {1, Projects.explain(reason)}
    end
  end

  # A worktree slot: taken for a new task (`new`, also an ask without an
  # action, as older mwt commands send), for a branch to continue
  # (`resume`), or freed (`free`).
  defp reply("worktree", %{"action" => "free"} = ask, username) do
    case Projects.free_slot(username, ask["cwd"], ask["slot"], ask["thread_id"]) do
      {:ok, _project, slot} -> {0, freed_words(slot)}
      {:error, reason} -> {1, Projects.explain(reason)}
    end
  end

  defp reply("worktree", ask, username) do
    how = if ask["action"] == "resume", do: :resume, else: :new

    case Projects.take_slot(username, ask["cwd"], how, ask["name"],
           from: ask["from"] || ask["onto"],
           thread: ask["thread_id"]
         ) do
      {:ok, _project, slot, outcome, onto, where} ->
        reach = reach_words(AgentThreads.get(username, ask["thread_id"]))
        {0, taken_words(slot, outcome, onto, where) <> "\n" <> reach}

      {:error, reason} ->
        {1, Projects.explain(reason)}
    end
  end

  # A handoff, opened or updated from the folder the agent is in. Nothing is
  # written on your machine but MWT's own store, so nothing is asked.
  # What `mwt handoff` needs before it commits, catches up and runs the
  # checks in the VM, as `key=value` lines for the script to read.
  defp reply("handoff", %{"stage" => "prepare"} = ask, username) do
    case Handoffs.prepare(username, %{
           cwd: ask["cwd"],
           title: ask["title"],
           onto: ask["onto"],
           thread_id: ask["thread_id"]
         }) do
      {:ok, plan} ->
        landed =
          case plan.landed do
            nil -> []
            l -> [landed: l.commit, landed_from: l.from, landed_branch: l.branch]
          end

        amend = if plan.amend, do: [amend: plan.amend], else: []

        {0,
         key_lines(
           [onto: plan.onto, ref: plan.ref, title: plan.title, checks: plan.checks] ++
             landed ++ amend
         )}

      {:error, reason} ->
        {1, Handoffs.explain(reason)}
    end
  end

  # What `mwt handoff` asks you at a terminal: `key=value` lines, then,
  # for an open handoff, a line `--` and its notes as they are, for your
  # editor to start from.
  defp reply("handoff", %{"stage" => "branch"} = ask, username) do
    case Handoffs.about_branch(username, %{cwd: ask["cwd"]}) do
      {:ok, %{task?: true, open: nil}} ->
        {0, "task=yes"}

      {:ok, %{task?: true, open: handoff}} ->
        {0,
         key_lines(task: "yes", handoff: to_string(handoff.id), title: handoff.title) <>
           "\n--\n" <> (handoff.body || "")}

      {:ok, %{task?: false, base: base, from: from}} ->
        {0, key_lines(task: "no", onto: TaskBase.label(base), from: from || "")}

      {:error, reason} ->
        {1, Handoffs.explain(reason)}
    end
  end

  # You made the branch you are on a task, at a terminal, to hand it off.
  defp reply("handoff", %{"stage" => "task"} = ask, username) do
    case Handoffs.make_task(username, %{cwd: ask["cwd"], onto: ask["onto"]}) do
      {:ok, branch, base} ->
        {0,
         "Made #{branch} a task based on #{TaskBase.label(base)}: its handoff lands there unless you choose another branch."}

      {:error, reason} ->
        {1, Handoffs.explain(reason)}
    end
  end

  # The agent takes its open handoff back, to work on it again.
  defp reply("handoff", %{"stage" => "withdraw"} = ask, username) do
    case Handoffs.withdraw(username, %{
           cwd: ask["cwd"],
           reason: ask["reason"],
           agent: ask["agent"],
           thread: ask["thread"],
           thread_id: ask["thread_id"]
         }) do
      {:ok, handoff} ->
        {0,
         "Took handoff ##{handoff.id} back: the user can't land it until you hand off again. Continue working on #{handoff.source.branch}, and submit again once the user asks (mwt handoff): that updates ##{handoff.id}."}

      {:error, reason} ->
        {1, Handoffs.explain(reason)}
    end
  end

  defp reply("handoff", ask, username) do
    case Handoffs.open(username, %{
           cwd: ask["cwd"],
           head: ask["head"],
           title: ask["title"],
           body: ask["body"],
           agent: ask["agent"],
           thread: ask["thread"],
           thread_id: ask["thread_id"],
           onto: ask["onto"]
         }) do
      {:ok, handoff, how} -> {0, handed_words(handoff, how)}
      {:error, reason} -> {1, Handoffs.explain(reason)}
    end
  end

  defp reply("handoffs", ask, username) do
    case Handoffs.for_agent(username, ask["cwd"]) do
      {:ok, project, [], _where, _look} ->
        {0,
         "No handoff in #{project.name} waits for the user, and none landed or closed " <>
           "in the last #{HandoffRecords.archive_after_days()} days."}

      {:ok, _project, handoffs, where, look} ->
        {0, Enum.map_join(handoffs, "\n\n", &handoff_words(&1, where, look))}

      {:error, reason} ->
        {1, Projects.explain(reason)}
    end
  end

  # A fixed call, called by its id with a value for each parameter: MWT
  # builds its request or runs the user's own script, and the agent sends
  # no text.
  defp reply("call", ask, username) do
    request = %{
      grant: ask["grant"],
      script: nil,
      values: ask["values"] || %{},
      dir: nil,
      timeout: ask["timeout"],
      reason: ask["reason"],
      agent: ask["agent"],
      thread: ask["thread"],
      thread_id: ask["thread_id"],
      folder: ask["folder"]
    }

    case Server.call(username, {:call, request}) do
      {:ok, approval} ->
        await(username, approval.id, wait(ask))

      {:error, :no_script} ->
        {@run_wrong,
         ~s[#{ask["grant"]} is no fixed call: it takes the command you write. ] <>
           ~s[Run one with: mwt run --reason "..." -- COMMAND]}

      {:error, {:no_such_grant, _ids}} ->
        {@run_wrong,
         "No fixed call has the id #{ask["grant"]}. mwt grants lists them under their resource, " <>
           "with how to call each; the id is exact."}

      {:error, :no_command_grant} ->
        {@run_wrong,
         "No fixed call has the id #{ask["grant"]}. mwt grants lists them under their resource."}

      {:error, reason} ->
        {@run_wrong, run_refusal(reason)}
    end
  end

  # A grant an agent proposes: a credential or a network, a grant over
  # one, or a fixed call.
  # MWT saves it at once, off, for the user to review on its page; the
  # agent waits as for an ask for a grant, which accepting it answers.
  defp reply("propose", ask, username) do
    request = %{
      grant: ask["grant"],
      name: ask["name"],
      purpose: ask["for"],
      script: ask["script"],
      params: ask["params"] || [],
      dir: ask["dir"],
      method: ask["method"],
      url: ask["url"],
      headers: ask["headers"] || [],
      body: ask["data"],
      preset: ask["preset"],
      hosts: List.wrap(ask["hosts"]),
      env: List.wrap(ask["env"]),
      file_env: List.wrap(ask["file_env"]),
      carriers: List.wrap(ask["carriers"]),
      git: ask["git"] == true,
      mint: ask["mint"],
      keep_minutes: ask["keep_minutes"],
      signs_as: List.wrap(ask["signs_as"]),
      login_file: ask["login_file"] == true,
      id_token_header: ask["id_token_header"],
      metadata_project: ask["metadata_project"],
      metadata_account: ask["metadata_account"],
      destinations: List.wrap(ask["destinations"]),
      resolver: ask["resolver"],
      anchor: ask["via"],
      over: ask["over"],
      minutes: ask["minutes"],
      reason: ask["reason"],
      agent: ask["agent"],
      thread: ask["thread"],
      thread_id: ask["thread_id"],
      folder: ask["folder"]
    }

    with {:ok, set} <- pairs(ask["set"], "--set"),
         {:ok, fill} <- pairs(ask["fill"], "--fill"),
         {:ok, approval} <-
           Server.call(username, {:propose, Map.merge(request, %{set: set, fill: fill})}) do
      {status, text} = await(username, approval.id, wait(ask))
      {status, proposed_words(approval, status) <> text}
    else
      {:error, reason} -> {1, proposal_refusal(reason, ask)}
    end
  end

  defp reply("run", ask, username) do
    request = %{
      grant: ask["grant"],
      script: ask["script"],
      values: nil,
      dir: ask["dir"],
      timeout: ask["timeout"],
      reason: ask["reason"],
      agent: ask["agent"],
      thread: ask["thread"],
      thread_id: ask["thread_id"],
      folder: ask["folder"],
      suggest_save: ask["suggest_save"],
      save_for: ask["save_for"]
    }

    case Server.call(username, {:request_command, request}) do
      {:ok, approval} ->
        await(username, approval.id, wait(ask))

      {:error, reason} ->
        {@run_wrong, run_refusal(reason)}
    end
  end

  defp reply("request", ask, username) do
    request = %{
      grant: ask["grant"],
      need: ask["need"],
      minutes: ask["minutes"],
      reason: ask["reason"],
      agent: ask["agent"],
      thread: ask["thread"],
      thread_id: ask["thread_id"],
      folder: ask["folder"]
    }

    case Server.call(username, {:request_access, request}) do
      {:ok, approval} ->
        await(username, approval.id, wait(ask))

      {:already_on, grant} ->
        {0, "#{grant.name} is already on #{until(grant)}. #{uses(grant)}"}

      {:error, reason} ->
        {1, refusal(reason, ask)}
    end
  end

  defp reply("wait", %{"id" => id} = ask, username) when is_binary(id),
    do: await(username, id, wait(ask))

  # Which VM is asking, against the one MWT runs: an old VM, still running
  # after a recreate or a move, looks like this one from inside.
  defp reply("vm", ask, username) do
    %{name: name, status: status, record: record} = Server.call(username, :vm_record)
    mine = if is_binary(ask["id"]), do: String.trim(ask["id"]), else: ""

    cond do
      is_nil(record) ->
        {1, "MWT has no record of its VM yet. Ask the user to stop and start it once in MWT."}

      mine == "" ->
        {1,
         "This VM has no record of which it is: its boot script hasn't written one. " <>
           "MWT runs #{vm_words(name, record)}. Ask the user to stop and start the VM in MWT."}

      mine == record.id and status == :running ->
        {0, "This is the VM MWT runs: #{vm_words(name, record)}."}

      true ->
        {3,
         "This is NOT the VM MWT runs. This one is vm #{mine}; MWT runs #{vm_words(name, record)}" <>
           if(status == :running, do: ".", else: ", and it is #{status}.") <>
           " Work here isn't where the user's MWT looks: tell them to reconnect to the VM."}
    end
  end

  defp reply(_command, _ask, _username),
    do: {1, "MWT knows these commands: #{Enum.join(@commands ++ ["mcp"], ", ")}. Run mwt help."}

  # What to sync for `path`, and the grants that decide it.
  defp sync_which([], nil, _path),
    do: {:error, "The user shares no folder with the VM, so there is nothing to sync."}

  defp sync_which(_shares, root, path) when path in [nil, ""],
    do: {:ok, :all, if(root, do: [:share_sync, :workspace], else: [:share_sync])}

  defp sync_which(_shares, _root, path) when not is_binary(path),
    do: {:error, "mwt sync takes the path of a folder, as text."}

  defp sync_which(shares, root, path) do
    path = Path.expand(path, "/")
    to_vm = root && Workspace.to_vm(root)
    from_vm = root && Workspace.from_vm(root)

    cond do
      Workspace.within?(path, from_vm) ->
        {:ok, [from_vm], [:workspace]}

      Workspace.within?(path, to_vm) ->
        {:ok, [to_vm], [:share_sync]}

      Workspace.within?(path, root) ->
        {:ok, [to_vm, from_vm], [:share_sync, :workspace]}

      share = Enum.find(shares, &Shares.within?(path, &1.path)) ->
        {:ok, [share.path], [:share_sync]}

      true ->
        folders = Enum.map(shares, & &1.path) ++ List.wrap(root && "the workspace, #{root}")

        {:error,
         "#{path} isn't in a shared folder or the workspace. They are: " <>
           Enum.join(folders, ", ") <> ". Run mwt sync alone to sync them all."}
    end
  end

  # Each grant asked in turn. A copy back refused when everything was asked
  # for leaves the rest: the shared folders and to-vm, named one by one.
  defp sync_allowed(username, which, grants, shares, root) do
    Enum.reduce_while(grants, {:ok, which, []}, fn grant, {:ok, which, notes} ->
      case MwtTools.authorize(username, sync_use(grant, which, root)) do
        :ok ->
          {:cont, {:ok, which, notes}}

        {:error, message} when grant == :workspace and which == :all and root != nil ->
          rest = Enum.map(shares, & &1.path) ++ [Workspace.to_vm(root)]
          {:cont, {:ok, rest, notes ++ ["#{Workspace.from_vm(root)}: not copied. " <> message]}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  defp sync_use(:share_sync, which, _root),
    do: %{
      grant: :share_sync,
      tool: "mwt sync",
      title: if(which == :all, do: "your shared folders", else: hd(which)),
      args: %{"path" => if(which == :all, do: "all", else: hd(which))}
    }

  defp sync_use(:workspace, _which, root),
    do: %{
      grant: :workspace,
      tool: "mwt sync",
      title: "the workspace's from-vm",
      args: %{"path" => root && Workspace.from_vm(root)}
    }

  # A line per folder, and the notes; one that failed makes the status 1.
  @doc false
  def sync_words(statuses, notes) do
    lines =
      statuses
      |> Enum.sort()
      |> Enum.map(fn {path, status} -> "#{path}: " <> sync_line(status) end)

    failed? = notes != [] or Enum.any?(statuses, fn {_path, status} -> status.error != nil end)
    {if(failed?, do: 1, else: 0), Enum.join(lines ++ notes, "\n")}
  end

  defp sync_line(%{error: error}) when is_binary(error), do: "not synced. " <> error

  # The workspace's from-vm, copied onto the user's machine.
  defp sync_line(%{written: written, removed: removed, files: files}) do
    changes =
      case {written, removed} do
        {0, 0} -> "nothing had changed"
        {written, 0} -> "#{written} written"
        {0, removed} -> "#{removed} removed"
        {written, removed} -> "#{written} written, #{removed} removed"
      end

    "copied onto the user's machine, #{changes}; #{files} files there, read-only there."
  end

  defp sync_line(%{project?: true}),
    do: "a git repository, so a project (mwt project): nothing of it is copied."

  defp sync_line(status) do
    changes =
      case {status.sent, status.removed} do
        {0, 0} -> "nothing had changed"
        {sent, 0} -> "#{sent} sent"
        {0, removed} -> "#{removed} removed"
        {sent, removed} -> "#{sent} sent, #{removed} removed"
      end

    held =
      case Map.get(status, :held, []) do
        [] ->
          ""

        held ->
          " Held back from the VM, for the user to decide: " <>
            Enum.map_join(held, "; ", &"#{&1.path} (#{&1.why})") <> "."
      end

    "up to date, #{changes}; #{status.files} files, read-only here." <>
      held <> unread_words(Map.get(status, :unread, []))
  end

  # Files the user's machine wouldn't let MWT read: not here, tried again
  # at each sync. The agent hears which, since it may need them.
  defp unread_words([]), do: ""

  defp unread_words(unread) do
    shown = Enum.take(unread, 10)
    more = length(unread) - length(shown)

    " Not copied, since the user's machine doesn't let MWT read them (tell the user if you need them): " <>
      Enum.map_join(shown, "; ", &"#{&1.path} (#{&1.why})") <>
      if(more > 0, do: "; and #{more} more.", else: ".")
  end

  defp vm_words(name, record) do
    created =
      case record.created_at do
        nil ->
          "created before MWT kept records"

        at ->
          minutes = max(DateTime.diff(DateTime.utc_now(), at, :minute), 0)
          "created #{ago(minutes)} (#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC)"
      end

    image = if record.image, do: ", image #{record.image}", else: ""
    "#{name} (vm #{record.id}), #{created}#{image}"
  end

  defp ago(minutes) when minutes < 1, do: "just now"
  defp ago(minutes) when minutes < 60, do: "#{minutes} min ago"
  defp ago(minutes) when minutes < 48 * 60, do: "#{div(minutes, 60)} h ago"
  defp ago(minutes), do: "#{div(minutes, 1440)} days ago"

  defp await(username, id, seconds) do
    ms = seconds * 1_000

    case Server.call(username, {:await, id, ms}, ms + 5_000) do
      {:pending, %Approval{kind: :command} = approval} -> run_pending(id, approval)
      {:pending, _approval} -> pending(id)
      {:ok, %Approval{kind: :command} = approval, _grant} -> ran(approval)
      {:ok, %Approval{kind: :tool} = approval, _grant} -> tool_settled(approval)
      {:ok, %Approval{status: :allowed} = approval, grant} -> on(username, approval, grant)
      {:ok, approval, grant} -> settled(approval, grant)
      {:error, :not_found} -> not_found(id)
    end
  end

  defp not_found("run-" <> _ = id),
    do: {@run_not_done, "No run #{id} is known. MWT forgets asks when it restarts."}

  defp not_found(id), do: {1, "No ask #{id} is known. MWT forgets asks when it restarts."}

  defp run_pending(id, approval) do
    what =
      case approval do
        %Approval{status: :waiting, stage: :output} ->
          "It ran; the user is looking at its output before it comes back to you."

        %Approval{run: %{state: :running}} ->
          "The user approved it, and it is running on their machine."

        %Approval{} ->
          "Still waiting for the user to approve it."
      end

    {@run_waiting,
     """
     #{what} Keep working on what doesn't need it, then run: mwt wait #{id}
     """}
  end

  # The final answer to an ask to run: the command's own status and output,
  # or why there is none; with how to run it by name when it is a saved
  # command now.
  defp ran(%Approval{saved_as: id} = approval) when is_binary(id) do
    saved =
      "It is the user's saved command #{id} now: next time, call it by id with " <>
        ~s[mwt call #{id} --reason "..." and send no command (mwt grants shows its parameters).]

    case ran_once(approval) do
      {{:ran, _} = status, "", output} -> {status, "mwt: " <> saved, output}
      {{:ran, _} = status, note, output} -> {status, note <> " " <> saved, output}
      {status, text} -> {status, text <> " " <> saved}
    end
  end

  defp ran(approval), do: ran_once(approval)

  # A fixed request's answer: its body back, its status on stderr.
  defp ran_once(%Approval{
         status: :allowed,
         call: %{host: host},
         run: %{state: :done, error: nil} = run
       }) do
    note =
      [
        run[:status] && "HTTP #{run.status} from #{host}",
        run.timed_out && "it got no answer within its time limit",
        run.cut > 0 && "#{run.cut} bytes of the body were cut from its end"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("; ")

    {{:ran, ran_status(run)}, "mwt: " <> note <> ".", run.output}
  end

  defp ran_once(%Approval{call: %{}, run: %{state: :done, error: error}}) when is_binary(error),
    do: {@run_not_done, "MWT couldn't send it: #{error}"}

  # A typed result whose run failed: its status, and no output.
  defp ran_once(%Approval{
         status: :allowed,
         decision: decision,
         run: %{state: :done, error: nil, withheld: true} = run
       })
       when decision != :send_output do
    {{:ran, ran_status(run)},
     "mwt: ran on the user's machine and ended with #{exit_words(run)}; a typed result comes back only from a run that succeeds, so its output stays with the user.",
     ""}
  end

  # Its output came back, but not its status: something it started held
  # the output open after it ended, and MWT stopped reading
  # (`MWTClient.Sandbox.HostRun`). The output goes back; the status is one
  # of MWT's own, since no number of the command's can be told.
  defp ran_once(%Approval{status: :allowed, run: %{state: :done, error: nil, exit: nil} = run}) do
    {{:ran, @run_not_done},
     "mwt: it ran on the user's machine and its output came back, but its exit status is " <>
       "unknown: something it started kept its output open after it ended, so MWT stopped " <>
       "reading. Don't take it as having succeeded; check what it did.",
     String.replace(run.output, <<0>>, "")}
  end

  defp ran_once(%Approval{status: :allowed, run: %{state: :done, error: nil} = run}) do
    note =
      [
        run.stopped && "the user stopped it",
        run.timed_out && "it hit its time limit",
        run.cut > 0 && "#{run.cut} bytes of output were cut from the middle"
      ]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ""
        notes -> "mwt: ran on the user's machine; " <> Enum.join(notes, ", ") <> "."
      end

    {{:ran, run.exit}, note, String.replace(run.output, <<0>>, "")}
  end

  defp ran_once(%Approval{run: %{state: :done, error: error}}) when is_binary(error),
    do: {@run_not_done, "It couldn't start on the user's machine: #{error}"}

  defp ran_once(%Approval{status: :denied, decision: :keep_output, run: run}),
    do:
      {@run_not_done,
       "It ran (#{exit_words(run)}), but the user kept its output from you. Ask them about it if you need it."}

  defp ran_once(%Approval{status: :timed_out, stage: :output, run: run}),
    do:
      {@run_not_done,
       "It ran (#{exit_words(run)}), but the user didn't release its output in 30 minutes. Ask them about it if you need it."}

  # Refused by MWT, not by the user: what it was asked under no longer
  # holds (`MWTClient.Sandbox.Server.HostRuns.still/2`).
  defp ran_once(%Approval{status: :denied, decision: :grant_off, grant_id: id}),
    do:
      {@run_not_done,
       "It didn't run: #{id} no longer allowed it by the time it would have. It was turned " <>
         "off, ran out of time, was paused by its check or removed, or its grant no longer " <>
         "lists the host. mwt grants shows how it is now; if you still need it, ask for it " <>
         ~s[again: mwt request #{id} --reason "..."]}

  defp ran_once(%Approval{status: :denied, decision: :changed, grant_id: id}),
    do:
      {@run_not_done,
       "It didn't run: the user edited #{id} while this waited, so it would no longer have " <>
         "run what its card showed. mwt grants shows #{id} as it is now; call it again if it " <>
         "still does what you need."}

  defp ran_once(%Approval{status: :denied, decision: :isolated}),
    do: {@run_not_done, @isolated}

  defp ran_once(%Approval{status: :denied, decision: :locked}),
    do:
      {@run_not_done,
       "It didn't run: the user locked what it reaches (host commands, or a credential it runs " <>
         "with) while it waited. Asking won't change that: tell the user what you were doing."}

  defp ran_once(%Approval{status: :denied, decision: :simpler}),
    do:
      {@run_not_done,
       "The user declined it as more than they want to review. Send the smallest command " <>
         "that gets the raw data you need, one they can read at a glance, and filter, parse " <>
         "or transform its output here in the VM."}

  defp ran_once(%Approval{status: :denied}),
    do:
      {@run_not_done,
       "The user declined to run it. Don't ask again for the same thing unless they say so."}

  defp ran_once(%Approval{status: :timed_out}),
    do:
      {@run_not_done,
       "The user didn't answer in 30 minutes. Tell them what you need to run, then ask again."}

  # The status a run reports: the command's own, or, when it is unknown,
  # MWT's for "its output didn't come back as a status".
  defp ran_status(%{exit: exit}) when is_integer(exit), do: exit
  defp ran_status(_run), do: @run_not_done

  defp exit_words(%{exit: exit}) when is_integer(exit), do: "exit #{exit}"
  defp exit_words(_run), do: "its exit status unknown"

  defp pending(id) do
    {2,
     """
     Still waiting for the user (ask #{id}). Keep working on what doesn't need it, then run: mwt wait #{id}
     The ask stays for 30 minutes.
     """}
  end

  # A call of MWT's tools that waited for the user: made once they allowed it.
  defp tool_settled(%Approval{status: :allowed, applied: {:ok, text}}), do: {0, text}

  defp tool_settled(%Approval{status: :allowed, applied: {:error, text}}),
    do: {1, "The user allowed it, but it was not made: #{text}"}

  defp tool_settled(%Approval{status: :allowed}),
    do: {0, "The user allowed it, and MWT makes it as you sent it. Read the item to see it."}

  defp tool_settled(%Approval{status: :timed_out}),
    do: {3, "The user didn't answer in 30 minutes. Nothing changed."}

  defp tool_settled(%Approval{}),
    do:
      {3,
       "The user declined. Nothing changed. Don't ask again for the same thing unless they say so."}

  # What the agent does next with a grant just turned on reads /mnt/mwt
  # (`mwt exec` loads the grant's environment there): it hears it is on once
  # the VM's copy has it, or after a few seconds at worst.
  defp on(username, approval, grant) do
    try do
      Server.call(username, :inbox_copied, 10_000)
    catch
      :exit, _ -> :ok
    end

    settled(approval, grant)
  end

  defp settled(%Approval{status: :allowed} = approval, %Grant{} = grant) do
    saved =
      if approval.proposal,
        do:
          "The user reviewed it and accepted it as #{grant.id}, as they chose to: read it below.\n",
        else: ""

    {0,
     """
     #{saved}#{grant.name} is on #{until(grant)}. #{uses(grant)}
     #{Instructions.usage(grant)}
     """}
  end

  defp settled(%Approval{status: :allowed, resource: {kind, id}}, _grant),
    do:
      {0,
       """
       The user accepted the #{kind} #{id}: it is theirs now. A grant over it gives its uses: \
       the one you proposed over it waits for them, or propose one with mwt propose grant --over #{id} ....
       #{if kind == :credential, do: "A pasted value is theirs to paste: until they do, every use of it is refused (mwt_no_value).\n", else: ""}\
       """}

  defp settled(%Approval{status: :denied, decision: :grant_off}, _grant),
    do: {3, "The grant was removed while you waited."}

  defp settled(%Approval{status: :denied, decision: :isolated}, _grant),
    do: {3, @isolated}

  defp settled(%Approval{status: :denied, proposal: %{}}, _grant),
    do:
      {3,
       "The user declined it, and the proposal is removed. Don't propose it again unless they say so."}

  defp settled(%Approval{status: :denied}, _grant),
    do: {3, "The user declined. Don't ask again for the same thing unless they say so."}

  defp settled(%Approval{status: :timed_out}, _grant),
    do: {3, "The user didn't answer in 30 minutes. Tell them what you need, then ask again."}

  defp settled(%Approval{}, nil), do: {3, "The grant no longer exists."}

  defp until(%Grant{expires_at: nil}), do: "until turned off"

  defp until(%Grant{expires_at: at}),
    do: "until #{Calendar.strftime(at, "%H:%M")} UTC"

  defp uses(%Grant{kind: :command} = grant) do
    if Grant.auto_approved?(grant),
      do: "Every run goes through without asking while it stays on.",
      else: "Each run still waits for the user's approval."
  end

  defp uses(%Grant{} = grant) do
    if Enum.any?(grant.allowances, &(&1.pattern == :all)),
      do: "Every use goes through without asking.",
      else:
        "Each use still waits for the user's approval, so a request can hang for a few minutes: wait, don't retry in a loop."
  end

  defp refusal(:isolated, _ask), do: @isolated

  defp refusal(:firewall, _ask),
    do: "MWT's firewall refused this ask. The user has been told."

  defp refusal({:locked, resource}, _ask),
    do:
      MWTClient.Sandbox.Resource.locked_words(resource) <>
        " Asking for a grant over it changes nothing: don't work around it; tell the user what you were doing."

  defp refusal(:unknown_grant, ask) do
    """
    No grant is called "#{ask["grant"]}". Run mwt grants to see them. To ask for access none of them gives:
      mwt request --need "the access, and the service or host it is for" --reason "why"
    """
  end

  defp refusal(:no_reason, _ask),
    do: ~s[Say why: --reason "what you are about to do with it". The user reads it.]

  defp refusal(:bad_minutes, _ask), do: "--minutes is from 1 to 1440."

  defp refusal(:nothing_asked, _ask),
    do: ~s[Name a grant (mwt request GRANT --reason "...") or describe a need (--need "...").]

  defp refusal(:too_many, _ask),
    do: "Ten asks already wait for the user. Wait for their answers first (mwt wait ID)."

  # What the agent hears first of what it proposed: where it is, and that
  # nothing turns it on until the user accepts it.
  defp proposed_words(%Approval{resource: {kind, id}, proposal: proposal}, status) do
    saved =
      if Map.get(proposal || %{}, :updated),
        do: "Your proposal of the #{kind} #{id} is changed: still to review.",
        else: "Saved as the #{kind} #{id}, for the user to review on its page in MWT."

    if status == 2,
      do:
        saved <>
          " Nothing over it is accepted or turns on until they accept it; the answer below says when.\n",
      else: saved <> "\n"
  end

  defp proposed_words(%Approval{grant_id: id, proposal: proposal}, status) do
    saved =
      if Map.get(proposal || %{}, :updated),
        do: "Your proposal #{id} is changed: still off, still to review.",
        else: "Saved as #{id}, off, for the user to review on its page in MWT."

    if status == 2,
      do:
        saved <>
          " It turns on only once they accept it there; the answer below says when.\n",
      else: saved <> "\n"
  end

  # FIELD=VALUE pairs as the CLI sends them, an object of texts: none is
  # an empty one; anything else is refused, never read in part.
  defp pairs(nil, _option), do: {:ok, %{}}

  defp pairs(%{} = pairs, option) do
    if Enum.all?(pairs, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: {:ok, pairs},
      else: {:error, {:proposal, "#{option} takes NAME=VALUE pairs of text."}}
  end

  defp pairs(_other, option),
    do: {:error, {:proposal, "#{option} takes NAME=VALUE pairs of text."}}

  @propose_what "A new resource is mwt propose credential ... or mwt propose network ...; a grant over one, mwt propose grant --over RESOURCE ...; a fixed request over a credential, mwt propose CREDENTIAL ...; a saved command, run on the user's machine: mwt propose commands ..."

  defp proposal_refusal(:unknown_grant, ask),
    do: ~s[Nothing is called "#{ask["grant"]}". #{@propose_what} See mwt help propose.]

  defp proposal_refusal({:no_actions, name}, _ask),
    do:
      "#{name} takes no fixed calls: only a credential (fixed requests) and host commands (saved commands) do. #{@propose_what}"

  defp proposal_refusal(:token_split, _ask),
    do:
      "mwt propose token is gone: a credential and the grants over it are proposed apart. " <>
        "Propose the credential (mwt propose credential --name ... --for ... [--preset ID]), " <>
        "then a grant over it (mwt propose grant --over ITS_NAME --name ... --for ... --host ...); " <>
        "send both now: the user accepts the credential first. See mwt help propose."

  defp proposal_refusal(:no_over, _ask),
    do:
      "Say which resource the grant is over: --over CREDENTIAL_OR_NETWORK, by id or name (mwt grants lists them, mwt why names a host's)."

  defp proposal_refusal({:unknown_resource, name}, _ask),
    do:
      ~s[No credential or network is called "#{name}". Propose it first (mwt propose credential ... or mwt propose network ...), then the grant over it.]

  defp proposal_refusal({:no_grants, name}, _ask),
    do:
      "#{name} take no grant of this kind: propose a saved command instead, mwt propose commands --name ... --for ... -- 'SCRIPT'."

  defp proposal_refusal(:no_name, _ask),
    do: ~s[Name it: --name NAME, a few words that say what it does, like "gh repo view".]

  defp proposal_refusal(:no_purpose, _ask),
    do:
      ~s[Say what it does: --for "...", in words for any time it runs. The user and other agents read it to know when to call it. --reason stays why you need it.]

  defp proposal_refusal(:no_script, _ask),
    do: "Give the script after --, or on stdin. See: mwt help"

  defp proposal_refusal({:proposal, message}, _ask),
    do: "Not proposed: #{message} See mwt help for what mwt propose takes."

  defp proposal_refusal({:no_preset, id, thing}, _ask),
    do:
      "No preset for #{MWTClient.Sandbox.FormFields.name(thing)} is called #{id}. Leave out --preset and give its fields yourself, with its options or --set FIELD=VALUE."

  defp proposal_refusal(:too_many_proposals, _ask),
    do:
      "Twenty of your proposals already wait for the user to review them. Wait for them first, or propose a change to one by its name."

  defp proposal_refusal(:isolated, _ask), do: @isolated

  defp proposal_refusal(reason, ask), do: refusal(reason, ask)

  defp run_refusal({:values, %Grant{} = grant, problem}),
    do:
      Param.explain(problem) <>
        ~s[\nCall it as: #{Grant.signature(grant)} --reason "why now"]

  defp run_refusal({:credential_endpoint, host, entry}),
    do:
      "#{host} is a credential endpoint on the firewall's list (#{entry}): its answer would be a new credential in the VM, so MWT doesn't send there. Tell the user if you need it."

  defp run_refusal({:takes_no_values, _id}),
    do:
      ~s[A command you write takes no values: mwt run --reason "..." -- COMMAND. Values go to a fixed call: mwt call ID NAME=value.]

  defp run_refusal(:no_reason),
    do:
      ~s[Say why: --reason "what it does, and why it must run on the user's machine". The user reads it.]

  defp run_refusal(:no_script),
    do: "Give the command after --, or the script on stdin. See: mwt help"

  defp run_refusal(:script_too_long),
    do:
      "The script is over #{div(HostCommand.max_script(), 1024)} KiB, far more than the user can review. " <>
        "Send the smallest command that gets the raw data you need, and work on its output here in the VM."

  defp run_refusal({:hidden, what}),
    do:
      "The script has characters that don't show (#{Enum.join(what, ", ")}), so the user can't read what would run. Send it without them: write a control or invisible character as an escape, such as printf '\\033'."

  defp run_refusal(:no_save_for),
    do:
      ~s[--suggest-save needs --save-for "what it does", in words for any time it runs, not this one: they become the saved command's description. --reason stays why you need it now.]

  defp run_refusal(:bad_timeout),
    do: "--timeout is from 1 to #{elem(HostCommand.timeouts(), 1)} seconds."

  defp run_refusal({:name_a_grant, _ids}),
    do:
      ~s[Give the command after --: mwt run --reason "..." -- COMMAND. A saved command is called by id: mwt call ID --reason "..."]

  defp run_refusal({:no_such_grant, ids}),
    do:
      "No saved command by that id. The saved commands: #{Enum.join(ids, ", ")}. " <>
        ~s[A command you write takes no id: mwt run --reason "..." -- COMMAND, while Commands agents write is on. See: mwt grants]

  defp run_refusal({:grant_off, id}),
    do: ~s[#{id} is off. Ask for it with: mwt request #{id} --reason "..."]

  defp run_refusal({:fixed_script, id}),
    do:
      ~s[#{id} runs the user's own script: send no command. Call it with: mwt call #{id} --reason "..."]

  defp run_refusal(:isolated), do: @isolated

  defp run_refusal({:locked, resource, _grant}),
    do:
      MWTClient.Sandbox.Resource.locked_words(resource) <>
        " Tell the user what you were doing; asking won't change it."

  defp run_refusal(:firewall),
    do: "MWT's firewall refused this command. The user has been told; don't send it again."

  defp run_refusal(:too_many),
    do: "Ten commands already wait for the user. Wait for their answers first (mwt wait ID)."

  defp wait(ask) do
    case ask["wait"] do
      seconds when is_integer(seconds) and seconds >= 0 -> min(seconds, @max_wait)
      _ -> @default_wait
    end
  end

  # One decision of this VM's, explained, or why it can't be.
  defp explain_decision(username, decision) do
    case explain_world(username) do
      nil ->
        {4, "MWT is locked or closing. Ask the user to unlock it."}

      world ->
        case Explain.decision(decision, world) do
          {:ok, answer} -> {0, answer}
          {:error, message} -> {1, message}
        end
    end
  end

  # What an explanation reads: the view the network path decides from.
  defp explain_world(username) do
    case Gate.view(username) do
      nil ->
        nil

      view ->
        %{
          snapshot:
            Policy.snapshot(
              view.grants,
              Map.get(view, :made, []),
              Map.get(view, :locks, %{}),
              Map.get(view, :limits, %{})
            ),
          isolated: Gate.isolated?(username, view),
          now: DateTime.utc_now()
        }
    end
  end

  # A value the VM sent as text, or nil for anything else.
  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_other), do: nil
end
