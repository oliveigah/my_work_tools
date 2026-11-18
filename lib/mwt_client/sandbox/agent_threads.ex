defmodule MWTClient.Sandbox.AgentThreads do
  @moduledoc """
  MWT's link to the agent threads you run in Zed ("Agent threads" in
  `docs/agent_sandbox.md`). It sees each thread of an MWT agent (its agent,
  folder, title, and whether it is working) and can say something in an
  open one: it shows in the thread as a message, and the agent acts on it.
  It knows nothing of handoffs or grants; they use it.

  Zed starts `mwt-acp` (`native/mwt_acp`) in the VM for the agents
  **Claude (MWT)** and **Codex (MWT)**, in place of their ACP adapter.
  Each `mwt-acp` keeps one connection on the agent channel
  (`MWTClient.Sandbox.Channel`): it attaches
  (`{"command": "attach", "agent": "claude-acp", "pid": …}`), then one JSON
  message per line, both ways. Up: `opened` (thread, folder, title,
  working), `closed`, `working`, `idle`, `title`, and `said` or `failed`
  for what MWT said. Down: `say` (id, thread, text). That loop runs in the
  channel's task for the connection (`attach/3`); this process holds the
  threads.

  A thread is open while an attached `mwt-acp` has it: from Zed opening it
  until Zed closes it (archiving it does) or that `mwt-acp` goes, with its
  connection. `say/4` is delivered at once or refused: into the turn that
  runs, or starting one, as the agent takes it; nothing waits for a thread
  that isn't open.

  One process per unlocked identity, started by `MWTClient.Vault.Store`.
  The record of every thread seen (`MWTClient.Sandbox.AgentThread`) is
  the `agent_threads` document of the identity's encrypted `library.db`
  (`MWTClient.Storage.Documents`), written a moment after a change; the
  links are live only. Pages hear
  `{:agent_threads_changed, id}` on the sandbox's topic.

  What the VM opens is bounded: 64 open threads per `mwt-acp` and 128 in
  all (an `opened` past them is dropped, and MWT can't say anything in
  that thread), and the record keeps the 500 last active, the oldest
  closed going as soon as a new one comes.
  """

  use GenServer

  require Logger

  alias MWTClient.Storage.Documents
  alias MWTClient.Sandbox.{AgentThread, Server, Shown}
  alias MWTClient.Vault.Store

  @document "agent_threads"
  # Where the record was kept before library.db.
  @legacy_file "agent_threads.bin"
  @say_timeout 10_000
  @flush_after 2_000
  @keep_threads 500
  # The VM opens threads as it likes: at most this many are open through
  # one `mwt-acp`, and in all. An `opened` past them is dropped.
  @max_open_per_link 64
  @max_open 128
  @keep_said 20
  @longest_text 200

  @type error :: :closed | :unknown | :vm_not_running | :timeout | {:failed, String.t()}

  @doc "Starts the threads of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Every thread seen, the last active first."
  @spec list(String.t()) :: [AgentThread.t()]
  def list(username), do: call(username, :list)

  @doc "One thread, or nil when MWT never saw it."
  @spec get(String.t(), String.t() | nil) :: AgentThread.t() | nil
  def get(_username, nil), do: nil
  def get(username, id), do: call(username, {:get, id})

  @doc """
  Says `text` in the thread `id`, for `:from` (who says it, shown with the
  text: `MWT (handoff #21 sent back): …`).

  `:ok` once the thread's `mwt-acp` gave it to the agent. Otherwise:
  `:closed` (seen, now closed), `:unknown` (never seen through `mwt-acp`:
  Zed's own agents, an agent in a terminal), `:vm_not_running`, `:timeout`
  (no word back in 10 s), or `{:failed, why}` as the agent refused it.
  """
  @spec say(String.t(), String.t() | nil, String.t(), keyword()) :: :ok | {:error, error()}
  def say(username, id, text, opts) do
    from = Keyword.fetch!(opts, :from)

    result =
      if is_binary(id) and id != "",
        do: call(username, {:say, id, "MWT (#{from}): #{text}", from}, @say_timeout + 5_000),
        else: {:error, {:not_open, :unknown}}

    # Not open here: the VM may be why.
    case result do
      {:error, {:not_open, reason}} ->
        if vm_running?(username), do: {:error, reason}, else: {:error, :vm_not_running}

      result ->
        result
    end
  end

  @doc "What an error of `say/4` means, for you."
  @spec explain(error()) :: String.t()
  def explain(:closed), do: "Its thread isn't open in Zed."
  def explain(:unknown), do: "Its thread isn't one MWT can reach (not started with an MWT agent)."
  def explain(:vm_not_running), do: "The VM isn't running."
  def explain(:timeout), do: "Its thread didn't answer in time."
  def explain({:failed, why}), do: "The agent refused it: #{why}."

  @doc "How many threads may be open through one `mwt-acp`, and in all."
  @spec max_open() :: {pos_integer(), pos_integer()}
  def max_open, do: {@max_open_per_link, @max_open}

  @doc """
  Serves one `mwt-acp` connection, in the calling process, until it ends:
  the channel hands it over after reading the attach line (`ask`).
  """
  @spec attach(String.t(), port(), map()) :: :ok
  def attach(username, socket, ask) do
    server = Store.whereis(__MODULE__, username) || exit(:locked)
    agent = if is_binary(ask["agent"]), do: String.slice(ask["agent"], 0, 60)
    ref = Process.monitor(server)
    :ok = GenServer.call(server, {:attach, self(), agent, ask["pid"]})
    :ok = :inet.setopts(socket, active: :once)
    link(socket, server, ref)
  end

  defp link(socket, server, ref) do
    receive do
      {:tcp, ^socket, line} ->
        case event(line) do
          nil -> :ok
          event -> GenServer.cast(server, {:event, self(), event})
        end

        :ok = :inet.setopts(socket, active: :once)
        link(socket, server, ref)

      {:say, id, thread, text} ->
        message = Jason.encode!(%{type: "say", id: id, thread: thread, text: text})
        _ = :gen_tcp.send(socket, message <> "\n")
        link(socket, server, ref)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :gen_tcp.close(socket)
        :ok
    end
  end

  # A line from `mwt-acp`, the VM's word: only known events, with their
  # fields checked; text to be shown made safe to show.
  defp event(line) do
    with {:ok, %{"type" => type} = message} when is_binary(type) <- Jason.decode(line) do
      thread = id(message["thread"])

      case type do
        "opened" when thread != nil ->
          %{
            type: :opened,
            thread: thread,
            folder: text(message["folder"], 4096),
            title: text(message["title"], @longest_text),
            working?: message["working"] == true
          }

        "title" when thread != nil ->
          %{type: :title, thread: thread, title: text(message["title"], @longest_text)}

        kind when kind in ["closed", "working", "idle"] and thread != nil ->
          %{type: String.to_existing_atom(kind), thread: thread}

        "said" ->
          if id = id(message["id"]), do: %{type: :said, id: id}

        "failed" ->
          if id = id(message["id"]),
            do: %{type: :failed, id: id, why: text(message["why"], @longest_text) || "no reason"}

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp id(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9._:-]{1,128}\z/, do: value
  end

  defp id(_value), do: nil

  defp text(value, longest) when is_binary(value),
    do: value |> Shown.text() |> String.slice(0, longest)

  defp text(_value, _longest), do: nil

  defp vm_running?(username) do
    Server.call(username, :vm_record).status == :running
  catch
    :exit, _ -> false
  end

  defp call(username, request, timeout \\ 5_000),
    do: GenServer.call(Store.via(__MODULE__, username), request, timeout)

  # -- the process ------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    username = Keyword.fetch!(opts, :username)

    {:ok,
     %{
       username: username,
       threads: restore(username, Keyword.fetch!(opts, :key)),
       links: %{},
       open: %{},
       pending: %{},
       next: 0,
       flush: nil
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    threads = state.threads |> Map.values() |> Enum.sort_by(&last_active/1, :desc)
    {:reply, threads, state}
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state.threads, id), state}

  def handle_call({:attach, link, agent, os_pid}, _from, state) do
    ref = Process.monitor(link)
    links = Map.put(state.links, link, %{agent: agent, os_pid: os_pid, ref: ref})
    {:reply, :ok, %{state | links: links}}
  end

  def handle_call({:say, id, text, from_label}, from, state) do
    case Map.fetch(state.open, id) do
      {:ok, link} ->
        say_id = "say-#{state.next + 1}"
        send(link, {:say, say_id, id, text})
        timer = Process.send_after(self(), {:say_timeout, say_id}, @say_timeout)
        pending = %{from: from, thread: id, label: from_label, text: text, timer: timer}

        {:noreply,
         %{state | next: state.next + 1, pending: Map.put(state.pending, say_id, pending)}}

      :error ->
        reason = if Map.has_key?(state.threads, id), do: :closed, else: :unknown
        {:reply, {:error, {:not_open, reason}}, state}
    end
  end

  @impl true
  def handle_cast({:event, link, event}, state) do
    if Map.has_key?(state.links, link),
      do: {:noreply, apply_event(state, link, event)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, link, _reason}, %{links: links} = state)
      when is_map_key(links, link) do
    gone = for {id, ^link} <- state.open, do: id
    state = %{state | links: Map.delete(state.links, link)}
    {:noreply, Enum.reduce(gone, state, &close(&2, &1))}
  end

  def handle_info({:say_timeout, say_id}, state),
    do: {:noreply, settle(state, say_id, {:error, :timeout})}

  def handle_info(:flush, state), do: {:noreply, flushed(%{state | flush: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = persist(state)
    :ok
  end

  defp apply_event(state, link, %{type: :opened} = event) do
    if Map.has_key?(state.open, event.thread) or room?(state, link),
      do: open(state, link, event),
      else: state
  end

  defp apply_event(state, link, %{type: :closed, thread: id}) do
    if state.open[id] == link, do: close(state, id), else: state
  end

  defp apply_event(state, link, %{type: type, thread: id}) when type in [:working, :idle] do
    case state.open[id] == link && state.threads[id] do
      %AgentThread{} = thread ->
        changed(state, %{thread | working?: type == :working, last_active_at: now()})

      _ ->
        state
    end
  end

  defp apply_event(state, link, %{type: :title, thread: id, title: title}) do
    case state.open[id] == link && state.threads[id] do
      %AgentThread{} = thread when is_binary(title) -> changed(state, %{thread | title: title})
      _ -> state
    end
  end

  defp apply_event(state, _link, %{type: :said, id: say_id}), do: settle(state, say_id, :ok)

  defp apply_event(state, _link, %{type: :failed, id: say_id, why: "closed"}),
    do: settle(state, say_id, {:error, :closed})

  defp apply_event(state, _link, %{type: :failed, id: say_id, why: why}),
    do: settle(state, say_id, {:error, {:failed, why}})

  # Whether one more thread may open through `link`.
  defp room?(state, link) do
    map_size(state.open) < @max_open and
      Enum.count(state.open, fn {_id, other} -> other == link end) < @max_open_per_link
  end

  defp open(state, link, event) do
    now = now()
    agent = state.links[link].agent

    thread =
      case Map.get(state.threads, event.thread) do
        %AgentThread{open?: true} = thread -> thread
        nil -> %AgentThread{id: event.thread, opened_at: now}
        thread -> %{thread | opened_at: now}
      end

    thread = %{
      thread
      | agent: agent || thread.agent,
        folder: event.folder || thread.folder,
        title: event.title || thread.title,
        open?: true,
        working?: event.working?,
        last_active_at: now
    }

    state
    |> put_in([:open, event.thread], link)
    |> changed(thread)
  end

  defp close(state, id) do
    state = %{state | open: Map.delete(state.open, id)}

    # What was said in it and not yet answered can't be any more.
    state =
      state.pending
      |> Enum.filter(fn {_say_id, pending} -> pending.thread == id end)
      |> Enum.reduce(state, fn {say_id, _}, state -> settle(state, say_id, {:error, :closed}) end)

    case state.threads[id] do
      %AgentThread{} = thread ->
        changed(state, %{thread | open?: false, working?: false, last_active_at: now()})

      nil ->
        state
    end
  end

  defp settle(state, say_id, result) do
    case Map.pop(state.pending, say_id) do
      {nil, _pending} ->
        state

      {pending, rest} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, result)
        state = %{state | pending: rest}

        case {result, state.threads[pending.thread]} do
          {:ok, %AgentThread{} = thread} ->
            said = %{at: now(), from: pending.label, text: pending.text}
            changed(state, %{thread | said: Enum.take(thread.said ++ [said], -@keep_said)})

          _ ->
            state
        end
    end
  end

  defp changed(state, %AgentThread{} = thread) do
    Phoenix.PubSub.broadcast(
      MWTClient.PubSub,
      Server.topic(state.username),
      {:agent_threads_changed, thread.id}
    )

    # A new thread takes the place of the oldest closed one once the record
    # is full, so the VM can't grow it between two writes.
    state =
      if Map.has_key?(state.threads, thread.id) or map_size(state.threads) < @keep_threads,
        do: state,
        else: %{state | threads: pruned(state, @keep_threads - 1)}

    state = %{state | threads: Map.put(state.threads, thread.id, thread)}

    if state.flush,
      do: state,
      else: %{state | flush: Process.send_after(self(), :flush, @flush_after)}
  end

  defp flushed(state) do
    if state.flush, do: Process.cancel_timer(state.flush)
    state = %{state | flush: nil, threads: pruned(state, @keep_threads)}
    :ok = persist(state)
    state
  end

  # The oldest closed threads go once there are more than `keep`.
  defp pruned(state, keep) do
    if map_size(state.threads) <= keep do
      state.threads
    else
      {open, closed} = state.threads |> Map.values() |> Enum.split_with(& &1.open?)

      keep =
        closed |> Enum.sort_by(&last_active/1, :desc) |> Enum.take(max(keep - length(open), 0))

      Map.new(open ++ keep, &{&1.id, &1})
    end
  end

  defp last_active(%AgentThread{last_active_at: nil}), do: 0
  defp last_active(%AgentThread{last_active_at: at}), do: DateTime.to_unix(at, :microsecond)

  defp persist(state) do
    record = Enum.map(Map.values(state.threads), &%{&1 | open?: false, working?: false})

    case Documents.put(state.username, @document, %{threads: record}) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.error("could not write the agent threads: #{Exception.message(error)}",
          user: state.username,
          system: :sandbox
        )

        :ok
    end
  end

  # A record that can't be read starts the list empty: it is facts about
  # threads, kept for you, never needed to run. The next write replaces it.
  defp restore(username, key) do
    case Documents.load(username, @document, @legacy_file, key, :sandbox) do
      {:ok, %{threads: threads}} when is_list(threads) ->
        Map.new(threads, fn thread ->
          thread = struct(AgentThread, Map.from_struct(thread))
          {thread.id, %{thread | open?: false, working?: false}}
        end)

      _none_or_unreadable ->
        %{}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
