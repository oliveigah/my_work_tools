defmodule MWTClient.Sandbox.AgentThreadsTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{AgentThread, AgentThreads, Channel, Server}
  alias MWTClient.Vault.Store

  setup do
    MWTClient.VaultHelpers.unlocked_identity("agent-threads")
  end

  # Plays an `mwt-acp`: a connection to the identity's channel, attached.
  defp attach(context, agent \\ "claude-acp") do
    path = Channel.socket_path(context.username)

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])

    send_line(socket, %{command: "attach", agent: agent, pid: 4242, version: "0.1.0"})
    socket
  end

  defp send_line(socket, message), do: :ok = :gen_tcp.send(socket, Jason.encode!(message) <> "\n")

  defp receive_line(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    Jason.decode!(line)
  end

  defp open_thread(socket, context, id, extra \\ %{}) do
    send_line(
      socket,
      Map.merge(
        %{type: "opened", thread: id, folder: "/work/x", title: nil, working: false},
        extra
      )
    )

    eventually(fn ->
      match?(%AgentThread{open?: true}, AgentThreads.get(context.username, id))
    end)
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("it never happened")
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end

  defp vm(context, status) do
    server = Store.whereis(Server, context.username)
    :sys.replace_state(server, &%{&1 | vm: %{&1.vm | status: status}})
  end

  test "a thread opened through mwt-acp is listed, and follows what it does", context do
    :ok = MWTClient.Sandbox.subscribe(context.username)
    socket = attach(context)
    open_thread(socket, context, "s-1", %{folder: "/work/mwt.wt/slot-3", title: "Fix it"})
    assert_receive {:agent_threads_changed, "s-1"}

    assert [%AgentThread{id: "s-1", agent: "claude-acp", open?: true, working?: false} = thread] =
             AgentThreads.list(context.username)

    assert thread.folder == "/work/mwt.wt/slot-3" and thread.title == "Fix it"
    assert AgentThread.state_words(thread) == "open, idle"

    send_line(socket, %{type: "working", thread: "s-1"})
    eventually(fn -> AgentThreads.get(context.username, "s-1").working? end)
    send_line(socket, %{type: "title", thread: "s-1", title: "Fix the login"})
    send_line(socket, %{type: "idle", thread: "s-1"})
    eventually(fn -> not AgentThreads.get(context.username, "s-1").working? end)
    assert AgentThreads.get(context.username, "s-1").title == "Fix the login"

    send_line(socket, %{type: "closed", thread: "s-1"})
    eventually(fn -> not AgentThreads.get(context.username, "s-1").open? end)
    assert AgentThread.state_words(AgentThreads.get(context.username, "s-1")) == "closed"
  end

  test "say gives the text to the thread's mwt-acp and returns once it said it", context do
    socket = attach(context)
    open_thread(socket, context, "s-1")

    task =
      Task.async(fn ->
        AgentThreads.say(context.username, "s-1", "look at the note",
          from: "handoff #21 sent back"
        )
      end)

    assert %{"type" => "say", "id" => say_id, "thread" => "s-1", "text" => text} =
             receive_line(socket)

    assert text == "MWT (handoff #21 sent back): look at the note"
    send_line(socket, %{type: "said", id: say_id})
    assert Task.await(task) == :ok

    assert [%{from: "handoff #21 sent back", text: ^text}] =
             AgentThreads.get(context.username, "s-1").said
  end

  test "say passes on why mwt-acp couldn't", context do
    socket = attach(context)
    open_thread(socket, context, "s-1")

    for {why, expected} <- [
          {"closed", {:error, :closed}},
          {"the agent broke", {:error, {:failed, "the agent broke"}}}
        ] do
      task = Task.async(fn -> AgentThreads.say(context.username, "s-1", "hi", from: "test") end)
      %{"id" => say_id} = receive_line(socket)
      send_line(socket, %{type: "failed", id: say_id, why: why})
      assert Task.await(task) == expected
    end

    assert AgentThreads.get(context.username, "s-1").said == []
  end

  test "say refuses a thread that isn't open, and says why", context do
    vm(context, :running)

    assert AgentThreads.say(context.username, "never-seen", "hi", from: "test") ==
             {:error, :unknown}

    assert AgentThreads.say(context.username, nil, "hi", from: "test") == {:error, :unknown}

    socket = attach(context)
    open_thread(socket, context, "s-1")
    send_line(socket, %{type: "closed", thread: "s-1"})
    eventually(fn -> not AgentThreads.get(context.username, "s-1").open? end)
    assert AgentThreads.say(context.username, "s-1", "hi", from: "test") == {:error, :closed}

    vm(context, :stopped)

    assert AgentThreads.say(context.username, "s-1", "hi", from: "test") ==
             {:error, :vm_not_running}

    assert AgentThreads.explain(:closed) =~ "isn't open in Zed"
  end

  test "a connection that ends closes its threads, and what was being said in them", context do
    vm(context, :running)
    socket = attach(context)
    open_thread(socket, context, "s-1", %{working: true})
    task = Task.async(fn -> AgentThreads.say(context.username, "s-1", "hi", from: "test") end)
    %{"type" => "say"} = receive_line(socket)

    :gen_tcp.close(socket)
    assert Task.await(task) == {:error, :closed}
    thread = AgentThreads.get(context.username, "s-1")
    refute thread.open? or thread.working?
  end

  test "mwt project and mwt worktree new say whether MWT can reach the thread", context do
    assert Channel.reach_words(nil) =~ "MWT can't reach this thread"
    assert Channel.reach_words(nil) =~ "Claude (MWT) or Codex (MWT)"
    assert Channel.reach_words(nil) =~ "mwt worktree resume BRANCH"

    socket = attach(context, "codex-acp")
    open_thread(socket, context, "s-1")
    reachable = Channel.reach_words(AgentThreads.get(context.username, "s-1"))
    assert reachable =~ "MWT can reach this thread (Codex (MWT))"

    send_line(socket, %{type: "closed", thread: "s-1"})
    eventually(fn -> not AgentThreads.get(context.username, "s-1").open? end)
    assert Channel.reach_words(AgentThreads.get(context.username, "s-1")) =~ "MWT can't reach"
  end

  test "lines that aren't events are ignored", context do
    socket = attach(context)

    for line <- [
          "not json",
          ~s({"type": "opened", "thread": "has spaces"}),
          ~s({"type": "opened", "thread": 7}),
          ~s({"type": "launch", "thread": "s-1"}),
          ~s(["opened"])
        ] do
      :ok = :gen_tcp.send(socket, line <> "\n")
    end

    open_thread(socket, context, "s-2", %{title: "a" <> <<0x202E::utf8>> <> "b"})
    assert [%AgentThread{id: "s-2", title: "a\\u{202E}b"}] = AgentThreads.list(context.username)
  end

  test "the record outlives a restart, with every thread closed", context do
    socket = attach(context)
    open_thread(socket, context, "s-1", %{title: "Kept"})

    pid = Store.whereis(AgentThreads, context.username)
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    eventually(fn ->
      case Store.whereis(AgentThreads, context.username) do
        nil -> false
        new -> new != pid and AgentThreads.get(context.username, "s-1") != nil
      end
    end)

    assert %AgentThread{title: "Kept", open?: false} = AgentThreads.get(context.username, "s-1")
  end

  # The VM opens threads as it likes: what MWT keeps of them is bounded.
  test "one mwt-acp opens only so many threads, and all of them only so many more", context do
    {per_link, total} = AgentThreads.max_open()
    first = attach(context)
    for i <- 1..(per_link + 20), do: send_line(first, %{type: "opened", thread: "a-#{i}"})
    open_thread(first, context, "a-#{per_link}")
    # Its own events go in order: once the last is in, so is the one past it.
    send_line(first, %{type: "title", thread: "a-1", title: "last"})
    eventually(fn -> AgentThreads.get(context.username, "a-1").title == "last" end)
    assert length(AgentThreads.list(context.username)) == per_link
    assert AgentThreads.get(context.username, "a-#{per_link + 1}") == nil

    # A thread already open stays open when it says so again.
    open_thread(first, context, "a-1")

    # Then all of them: a third opens one while there is room, a second
    # fills the rest.
    second = attach(context)
    third = attach(context)
    open_thread(third, context, "c-0")
    for i <- 1..(total - per_link - 1), do: send_line(second, %{type: "opened", thread: "b-#{i}"})
    open_thread(second, context, "b-#{total - per_link - 1}")
    send_line(third, %{type: "opened", thread: "c-1"})
    send_line(third, %{type: "title", thread: "c-0", title: "after c-1"})
    eventually(fn -> AgentThreads.get(context.username, "c-0").title == "after c-1" end)
    assert AgentThreads.get(context.username, "c-1") == nil
    assert Enum.count(AgentThreads.list(context.username), & &1.open?) == total

    # A place freed is a place for another.
    send_line(first, %{type: "closed", thread: "a-1"})
    eventually(fn -> not AgentThreads.get(context.username, "a-1").open? end)
    open_thread(third, context, "c-2")
  end

  test "threads opened and closed without end never hold more than the record keeps",
       context do
    socket = attach(context)

    for i <- 1..700 do
      send_line(socket, %{type: "opened", thread: "t-#{i}", folder: String.duplicate("f", 4000)})
      send_line(socket, %{type: "closed", thread: "t-#{i}"})
    end

    open_thread(socket, context, "last")
    state = :sys.get_state(Store.whereis(AgentThreads, context.username))
    assert map_size(state.threads) == 500
    assert %AgentThread{open?: true} = state.threads["last"]
    assert Map.has_key?(state.threads, "t-700")
    refute Map.has_key?(state.threads, "t-1")
  end

  # The real shell (native/mwt_acp), when built, against this channel, with
  # a small ACP agent in Python standing in for Claude's adapter.
  @shell Enum.find(
           [
             Path.expand("../../../priv/microsandbox/bin/mwt-acp", __DIR__),
             Path.expand("../../../native/mwt_acp/target/release/mwt-acp", __DIR__),
             Path.expand("../../../native/mwt_acp/target/debug/mwt-acp", __DIR__)
           ],
           &File.exists?/1
         )

  @fake_agent """
  import json, sys
  def out(m):
      sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
  for line in sys.stdin:
      m = json.loads(line)
      method, id = m.get("method"), m.get("id")
      if method == "initialize":
          out({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": 1}})
      elif method == "session/new":
          out({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "e2e-1"}})
      elif method == "session/prompt":
          text = m["params"]["prompt"][0]["text"]
          out({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "e2e-1",
               "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "echo: " + text}}}})
          out({"jsonrpc": "2.0", "id": id, "result": {"stopReason": "end_turn"}})
  """

  if @shell do
    test "the real mwt-acp opens a thread here and delivers what is said in it", context do
      agent = Path.join(System.tmp_dir!(), "fake-acp-#{System.unique_integer([:positive])}.py")
      File.write!(agent, @fake_agent)
      on_exit(fn -> File.rm(agent) end)

      port =
        Port.open({:spawn_executable, @shell}, [
          :binary,
          {:line, 65_536},
          :exit_status,
          args: ["claude-acp"],
          env: [
            {~c"MWT_CHANNEL", ~c"UNIX-CONNECT:#{Channel.socket_path(context.username)}"},
            {~c"MWT_ACP_COMMAND", String.to_charlist(Jason.encode!(["python3", agent]))}
          ]
        ])

      zed = fn message -> Port.command(port, Jason.encode!(message) <> "\n") end
      zed.(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{protocolVersion: 1}})

      zed.(%{
        jsonrpc: "2.0",
        id: 2,
        method: "session/new",
        params: %{cwd: "/work/e2e", mcpServers: []}
      })

      eventually(
        fn -> match?(%AgentThread{open?: true}, AgentThreads.get(context.username, "e2e-1")) end,
        300
      )

      assert AgentThreads.get(context.username, "e2e-1").folder == "/work/e2e"

      assert AgentThreads.say(context.username, "e2e-1", "hello", from: "test") == :ok
      assert_receive {^port, {:data, {:eol, line}}} when is_binary(line), 2_000
      lines = collect(port, [line])
      assert Enum.any?(lines, &(&1 =~ ~s("user_message_chunk") and &1 =~ "MWT (test): hello"))
      assert Enum.any?(lines, &(&1 =~ "echo: MWT (test): hello"))

      Port.close(port)
      eventually(fn -> not AgentThreads.get(context.username, "e2e-1").open? end, 300)
    end
  end

  defp collect(port, lines) do
    receive do
      {^port, {:data, {:eol, line}}} -> collect(port, [line | lines])
    after
      500 -> Enum.reverse(lines)
    end
  end
end
