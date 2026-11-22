defmodule MWTClient.Sandbox.Dns do
  @moduledoc """
  The DNS forwarder: every name the VM looks up goes through here.

  microsandbox is told `--dns-nameserver 127.0.0.1:5353`, a port that exists
  only in its bubble, where the relay passes each question to this socket
  (`dns.sock`), framed as DNS over TCP is: two bytes of length, then the
  message. The bubble has no other network, so a question the VM aims at
  another resolver gets no answer.

  Only a standard query of one name goes on (`query/1`), rebuilt from what
  was read: its header, its question, and EDNS's OPT record without its
  options; nothing after them. Any other operation (UPDATE, NOTIFY) is
  answered NOTIMP here, and a zone transfer or a query carrying records of
  its own REFUSED: the host's resolver may be the LAN's, and they would
  reach it unread.

  Each query is passed to this machine's own resolver (the first
  `nameserver` of `/etc/resolv.conf`, so VPN names keep working) and its
  answer returned unchanged. A name a network grant lists is answered
  only while that grant is on, by the grant's own resolver when it names
  one (`Grant.resolver`, reached through its way out, `Grant.anchor`),
  and the addresses in the answer are kept for it
  (`MWTClient.Sandbox.Gate.answered/4`, `addresses/2`): only those open
  under the grant. So are the addresses of a name a grant's host list asks
  about or blocks (`Gate.remember_listed/3`), for a connection to them to be
  held by that entry whatever name it gives. An answer cut short over UDP is asked again
  over TCP. The name and type are read for the activity log, where a name is
  logged again only after `@quiet` seconds. A message it can't read is
  dropped.

  Before it is passed on, each name is decided here, with
  `MWTClient.Sandbox.Gate`, never waiting on the sandbox's server, and
  shown to MWT's firewall (`MWTClient.Sandbox.Watch`). A name it refuses,
  every name while the VM is isolated, and, while the Internet is off,
  every name no grant lists, is answered REFUSED and never leaves this
  machine; so is every name when the sandbox has no view published.

  One listener per unlocked identity. When it is not listening, the VM
  resolves nothing.
  """

  use GenServer

  require Logger

  alias MWTClient.Sandbox.{Gate, Grant, Routes, Server, Sockets}
  alias MWTClient.Vault.Store

  @answer_within 5_000
  @idle 60_000
  @quiet 600
  @seen_limit 20_000
  @types %{
    1 => "A",
    28 => "AAAA",
    5 => "CNAME",
    15 => "MX",
    16 => "TXT",
    33 => "SRV",
    12 => "PTR",
    2 => "NS",
    6 => "SOA",
    65 => "HTTPS",
    64 => "SVCB"
  }

  @doc "Starts the forwarder of one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :username)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The Unix socket one identity's forwarder listens on (`MWTClient.Sandbox.Sockets`)."
  @spec path(String.t()) :: Path.t()
  def path(username), do: Sockets.path(username, "dns.sock")

  @doc """
  The name and type a DNS message asks for, or `:error` when it isn't a
  question this can read.

      iex> question = <<0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, "example", 3, "com", 0, 0, 1, 0, 1>>
      iex> MWTClient.Sandbox.Dns.question(question)
      {:ok, "example.com", "A"}
  """
  @spec question(binary()) :: {:ok, String.t(), String.t()} | :error
  def question(<<_id::16, _flags::16, 1::16, _counts::48, rest::binary>>) do
    with {:ok, labels, <<type::16, _class::16, _::binary>>} <- labels(rest, []) do
      {:ok, labels |> Enum.join(".") |> String.downcase(), type_name(type)}
    end
  end

  def question(_message), do: :error

  # IXFR, AXFR, MAILB, MAILA: zone transfers and their kin.
  @transfers [251, 252, 253, 254]
  # Of a query's flags, those passed on: RD, AD and CD.
  @query_flags 0x130

  @doc """
  What may be passed on of a message: `{:ok, name, type, query}` for a
  standard query (opcode 0) of one name in class IN, with at most EDNS's
  OPT record after it, where `query` is the message MWT rebuilt from what
  it read; `{:refuse, rcode}` for anything else it can read, NOTIMP (4) for
  another operation and REFUSED (5) for a zone transfer or a query carrying
  records; `:error` for what it can't.

      iex> query = <<0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, "example", 3, "com", 0, 0, 1, 0, 1>>
      iex> {:ok, "example.com", "A", ^query} = MWTClient.Sandbox.Dns.query(query <> "after")
      iex> update = <<0x12, 0x34, 0x28, 0, 0, 1, 0, 0, 0, 1, 0, 0, 7, "example", 3, "com", 0, 0, 6, 0, 1>>
      iex> MWTClient.Sandbox.Dns.query(update)
      {:refuse, 4}
  """
  @spec query(binary()) :: {:ok, String.t(), String.t(), binary()} | {:refuse, 4 | 5} | :error
  def query(
        <<id::16, 0::1, 0::4, flags::11, 1::16, ancount::16, nscount::16, arcount::16,
          rest::binary>>
      ) do
    with {:ok, labels, <<type::16, class::16, after_question::binary>>} <- labels(rest, []) do
      question = binary_part(rest, 0, byte_size(rest) - byte_size(after_question))
      name = labels |> Enum.join(".") |> String.downcase()

      cond do
        type in @transfers or class != 1 or ancount != 0 or nscount != 0 or arcount > 1 ->
          {:refuse, 5}

        arcount == 0 ->
          {:ok, name, type_name(type), header(id, flags, 0) <> question}

        true ->
          case after_question do
            <<0, 41::16, size::16, extended::32, length::16, _options::binary-size(length),
              _::binary>> ->
              opt = <<0, 41::16, size::16, extended::32, 0::16>>
              {:ok, name, type_name(type), header(id, flags, 1) <> question <> opt}

            _other ->
              {:refuse, 5}
          end
      end
    end
  end

  def query(<<_id::16, 0::1, _opcode::4, _flags::11, 1::16, _counts::48, rest::binary>>) do
    case labels(rest, []) do
      {:ok, _labels, <<_type::16, _class::16, _::binary>>} -> {:refuse, 4}
      _unreadable -> :error
    end
  end

  def query(_message), do: :error

  defp header(id, flags, additional),
    do:
      <<id::16, 0::1, 0::4, Bitwise.band(flags, @query_flags)::11, 1::16, 0::32, additional::16>>

  defp type_name(type), do: Map.get(@types, type, "type #{type}")

  defp labels(<<0, rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp labels(<<size, label::binary-size(size), rest::binary>>, acc)
       when size in 1..63 and length(acc) < 128 do
    # Visible ASCII, as names are on the wire: the name goes into the log.
    if label =~ ~r/\A[\x21-\x7e]+\z/, do: labels(rest, [label | acc]), else: :error
  end

  defp labels(_other, _acc), do: :error

  @doc """
  The address questions are passed to: this machine's own resolver. Tests
  set `config :mwt_client, MWTClient.Sandbox.Dns, resolver: {address, port}`.
  """
  @spec resolver() :: {:inet.ip_address(), :inet.port_number()}
  def resolver do
    case Application.get_env(:mwt_client, __MODULE__, [])[:resolver] do
      nil -> system_resolver()
      resolver -> resolver
    end
  end

  defp system_resolver do
    with {:ok, text} <- File.read("/etc/resolv.conf"),
         [address | _] <-
           for(
             line <- String.split(text, "\n"),
             ["nameserver", address] <- [String.split(line)],
             {:ok, ip} <- [:inet.parse_address(String.to_charlist(address))],
             do: ip
           ) do
      {address, 53}
    else
      _ -> {{127, 0, 0, 53}, 53}
    end
  end

  @impl true
  def init(username) do
    Process.flag(:trap_exit, true)
    Sockets.ensure!(username)
    path = path(username)
    File.rm(path)
    seen = :ets.new(:seen, [:set, :public])

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, backlog: 256]) do
      {:ok, socket} ->
        File.chmod(path, 0o600)
        acceptor = spawn_link(fn -> accept(socket, username, seen) end)
        {:ok, %{username: username, path: path, socket: socket, acceptor: acceptor}}

      {:error, reason} ->
        Logger.warning("sandbox DNS could not listen on #{path}: #{inspect(reason)}",
          system: :sandbox
        )

        {:ok, %{username: username, path: path, socket: nil, acceptor: nil}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    File.rm(state.path)
    :ok
  end

  defp accept(socket, username, seen) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(MWTClient.Sandbox.TaskSupervisor, fn ->
            receive do
              :go -> serve(client, username, seen)
            after
              5_000 -> :ok
            end
          end)

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(socket, username, seen)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        exit(reason)
    end
  end

  # One connection carries one question (from UDP in the VM) or several
  # (from TCP there).
  defp serve(client, username, seen) do
    with {:ok, <<size::16>>} <- :gen_tcp.recv(client, 2, @idle),
         {:ok, message} <- :gen_tcp.recv(client, size, @answer_within),
         {:ok, answer} <- answer(message, username, seen),
         :ok <- :gen_tcp.send(client, [<<byte_size(answer)::16>>, answer]) do
      serve(client, username, seen)
    else
      _closed_unreadable_or_unanswered -> :gen_tcp.close(client)
    end
  end

  defp answer(message, username, seen) do
    case query(message) do
      {:ok, name, type, query} ->
        screened(username, query, name, type, seen, fn way ->
          with :ok <- note(username, seen, name, type), do: forward(query, way)
        end)

      {:refuse, 5} ->
        {:ok, refused(message)}

      {:refuse, rcode} ->
        {:ok, not_answered(message, rcode)}

      :error ->
        :error
    end
  end

  # The answer to a message that isn't a query: its id and operation, and
  # `rcode`, with no sections.
  defp not_answered(<<id::16, _qr::1, opcode::4, _::11, _::binary>>, rcode),
    do: <<id::16, 1::1, opcode::4, 0::7, rcode::4, 0::64>>

  # The firewall first: a name it lets through is passed on, any other is
  # answered REFUSED here.
  defp screened(username, message, name, type, seen, pass_on) do
    case Gate.lookup(username, name) do
      :ok ->
        with {:ok, answer} <- pass_on.(resolver()) do
          Gate.remember_trusted(username, name, answer)
          Gate.remember_listed(username, name, answer)
          {:ok, answer}
        end

      {:covered, grant} ->
        case way(grant) do
          {:ok, way} ->
            with {:ok, answer} <- pass_on.(way) do
              case addresses(answer, name) do
                {[], _seconds} -> :ok
                {addresses, seconds} -> Gate.answered(username, name, addresses, seconds)
              end

              {:ok, answer}
            end

          {:error, why} ->
            note(username, seen, name, type, "Not looked up (#{type}): #{grant.name}'s #{why}")
            {:ok, refused(message)}
        end

      :refuse ->
        {:ok, refused(message)}

      {:refuse, {:grant_off, grant}} ->
        note(username, seen, name, type, "Not looked up (#{type}): #{grant.name} is off")
        {:ok, refused(message)}

      {:refuse, :internet_off} ->
        note(username, seen, name, type, "Not looked up (#{type}): the Internet is off")
        {:ok, refused(message)}
    end
  catch
    :exit, _not_answering -> {:ok, refused(message)}
  end

  @doc """
  The answer REFUSED to a question: its id and question, nothing else.

      iex> question = <<0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, "example", 3, "com", 0, 0, 1, 0, 1>>
      iex> <<0x12, 0x34, 0x81, 0x85, 0, 1, 0, 0, 0, 0, 0, 0, rest::binary>> = MWTClient.Sandbox.Dns.refused(question)
      iex> rest
      <<7, "example", 3, "com", 0, 0, 1, 0, 1>>
  """
  @spec refused(binary()) :: binary()
  def refused(
        <<id::16, _qr::1, opcode::4, _aa::1, _tc::1, rd::1, _rest::8, 1::16, _counts::48,
          rest::binary>>
      ) do
    <<id::16, 1::1, opcode::4, 0::1, 0::1, rd::1, 1::1, 0::3, 5::4, 1::16, 0::16, 0::16, 0::16,
      binary_part(rest, 0, question_size(rest, 0))::binary>>
  end

  defp question_size(rest, at) do
    case rest do
      <<_::binary-size(at), 0, _::binary>> -> at + 5
      <<_::binary-size(at), size, _::binary>> -> question_size(rest, at + 1 + size)
    end
  end

  defp note(username, seen, name, type, summary \\ nil) do
    now = System.monotonic_time(:second)

    {outcome, key} =
      if summary, do: {:blocked, {name, type, summary}}, else: {:lookup, {name, type}}

    case :ets.lookup(seen, key) do
      [{_key, at}] when now - at < @quiet ->
        :ok

      _new_or_old ->
        # The names are the VM's to make up: the table starts over before it
        # grows without end, at the cost of logging some names twice.
        if :ets.info(seen, :size) >= @seen_limit, do: :ets.delete_all_objects(seen)
        :ets.insert(seen, {key, now})

        Server.cast(
          username,
          {:log, %{outcome: outcome, summary: summary || "Looked up (#{type})", host: name}}
        )
    end
  end

  # Where a covered name is asked: the grant's resolver, through its way
  # out when it has one, or this machine's.
  defp way(%Grant{resolver: nil}), do: {:ok, resolver()}

  defp way(%Grant{resolver: text, anchor: anchor}) do
    case resolver_address(text) do
      {:ok, {ip, port} = address} ->
        cond do
          anchor == nil -> {:ok, address}
          Routes.via(ip) == anchor -> {:ok, {ip, port, anchor}}
          true -> {:error, "network isn't connected (#{anchor})"}
        end

      :error ->
        {:error, "resolver #{text} isn't an address"}
    end
  end

  @doc """
  A grant's resolver, `address` or `address:port` (`[v6]:port`), as
  `{ip, port}`.

      iex> MWTClient.Sandbox.Dns.resolver_address("10.8.0.1")
      {:ok, {{10, 8, 0, 1}, 53}}
      iex> MWTClient.Sandbox.Dns.resolver_address("[fd00::53]:5353")
      {:ok, {{0xFD00, 0, 0, 0, 0, 0, 0, 0x53}, 5353}}
      iex> MWTClient.Sandbox.Dns.resolver_address("dns.corp.example")
      :error
  """
  @spec resolver_address(String.t()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | :error
  def resolver_address(text) do
    {host, port} =
      case Regex.run(~r/\A\[([^\]]+)\](?::(\d+))?\z|\A([^:]+)(?::(\d+))?\z/, String.trim(text)) do
        [_, v6] -> {v6, "53"}
        [_, v6, port] when v6 != "" -> {v6, port}
        [_, "", "", v4] -> {v4, "53"}
        [_, "", "", v4, port] -> {v4, port}
        _ -> {nil, nil}
      end

    with true <- is_binary(host),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(host)),
         {port, ""} when port in 1..65_535 <- Integer.parse(port) do
      {:ok, {ip, port}}
    else
      _ -> :error
    end
  end

  @doc """
  The addresses an answer gives for `name`, its A and AAAA records reached
  through its CNAMEs, and how long they may be kept: their shortest TTL,
  in seconds. `{[], 0}` for an answer with none, or one that can't be read.
  """
  @spec addresses(binary(), String.t()) :: {[:inet.ip_address()], non_neg_integer()}
  def addresses(
        <<_id::16, _flags::16, qd::16, an::16, _ns::16, _ar::16, _::binary>> = answer,
        name
      ) do
    with {:ok, at} <- skip_questions(answer, 12, qd),
         {:ok, records} <- records(answer, at, an, []) do
      wanted = chain(records, MapSet.new([normal(name)]), 8)

      found =
        for {owner, type, ttl, data} <- records,
            type in [1, 28],
            MapSet.member?(wanted, owner),
            ip = address(type, data),
            ip != nil,
            do: {ip, ttl}

      # A CNAME on the way holds no longer than its own TTL.
      chained = for {owner, 5, ttl, _target} <- records, MapSet.member?(wanted, owner), do: ttl

      case found do
        [] ->
          {[], 0}

        found ->
          {found |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
           Enum.min(Enum.map(found, &elem(&1, 1)) ++ chained)}
      end
    else
      _ -> {[], 0}
    end
  end

  def addresses(_answer, _name), do: {[], 0}

  defp normal(name), do: name |> String.downcase() |> String.trim_trailing(".")

  # The names the question's name leads to through CNAMEs, a few hops at most.
  defp chain(_records, names, 0), do: names

  defp chain(records, names, hops) do
    more =
      for {owner, 5, _ttl, {:name, target}} <- records,
          MapSet.member?(names, owner),
          into: names,
          do: target

    if MapSet.equal?(more, names), do: names, else: chain(records, more, hops - 1)
  end

  defp address(1, <<a, b, c, d>>), do: {a, b, c, d}

  defp address(28, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

  defp address(_type, _data), do: nil

  defp skip_questions(_message, at, 0), do: {:ok, at}

  defp skip_questions(message, at, n) do
    with {:ok, _name, at} <- read_name(message, at, 0),
         true <- byte_size(message) >= at + 4 do
      skip_questions(message, at + 4, n - 1)
    else
      _ -> :error
    end
  end

  defp records(_message, _at, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp records(message, at, n, acc) do
    with {:ok, owner, at} <- read_name(message, at, 0),
         <<_::binary-size(at), type::16, _class::16, ttl::32, size::16, data::binary-size(size),
           _::binary>> <- message do
      data =
        if type == 5 do
          case read_name(message, at + 10, 0) do
            {:ok, target, _} -> {:name, target}
            :error -> nil
          end
        else
          data
        end

      records(message, at + 10 + size, n - 1, [{owner, type, ttl, data} | acc])
    else
      _ -> :error
    end
  end

  # A name at `at`, its labels joined, following compression pointers (a
  # few at most): `{:ok, name, where it ends}`.
  defp read_name(message, at, jumps, labels \\ [], ends \\ nil)

  defp read_name(_message, _at, jumps, _labels, _ends) when jumps > 16, do: :error

  defp read_name(message, at, jumps, labels, ends) do
    case message do
      <<_::binary-size(at), 0, _::binary>> ->
        name = labels |> Enum.reverse() |> Enum.join(".") |> String.downcase()
        {:ok, name, ends || at + 1}

      <<_::binary-size(at), 3::2, pointer::14, _::binary>> ->
        read_name(message, pointer, jumps + 1, labels, ends || at + 2)

      <<_::binary-size(at), 0::2, size::6, label::binary-size(size), _::binary>> ->
        read_name(message, at + 1 + size, jumps, [label | labels], ends)

      _ ->
        :error
    end
  end

  defp forward(message, way) do
    {address, port, options} =
      case way do
        {address, port} -> {address, port, []}
        {address, port, anchor} -> {address, port, Routes.options(anchor)}
      end

    family = if tuple_size(address) == 8, do: :inet6, else: :inet

    with {:ok, socket} <- :gen_udp.open(0, [:binary, family, active: false] ++ options) do
      answer =
        with :ok <- :gen_udp.send(socket, address, port, message),
             {:ok, {_from, _port, answer}} <- :gen_udp.recv(socket, 0, @answer_within) do
          {:ok, answer}
        end

      :gen_udp.close(socket)

      case answer do
        # Cut short (TC): the whole answer needs TCP.
        {:ok, <<_id::16, _::6, 1::1, _::9, _::binary>>} ->
          over_tcp(address, port, family, options, message)

        other ->
          other
      end
    end
  end

  defp over_tcp(address, port, family, options, message) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             address,
             port,
             [:binary, family, active: false, packet: 2] ++ options,
             @answer_within
           ) do
      answer =
        with :ok <- :gen_tcp.send(socket, message) do
          :gen_tcp.recv(socket, 0, @answer_within)
        end

      :gen_tcp.close(socket)
      answer
    end
  end
end
