defmodule MWTClient.ProxyReadingBenchTest do
  @moduledoc """
  What reading a connection costs, against passing it through: the same
  client, the same HTTPS server, through the real proxy code
  (`MWTClient.Sandbox.Egress.Tcp`), its decisions, the activity log
  and its exchanges, one host read and one on the list of hosts MWT
  doesn't read. Read, MWT ends the client's TLS, reads and judges each
  request, starts TLS again with the server and checks its certificate,
  as it does for a real host (`Egress.Tcp.connect_tls/2`); passed through, it copies
  bytes.

  Excluded from the suite; run it with

      mix test test/bench/proxy_reading_bench_test.exs --only bench

  and size it with `BENCH_REQUESTS` (kept-connection requests, 2000) and
  `BENCH_CLIENTS` (concurrent clients, 32). `BENCH_VALUES` (3) is how many
  real values MWT holds, for hosts the requests don't go to: every answer
  it reads is looked through for them all, so `0` times reading with
  nothing to look for. The client and the server run
  in the same BEAM as MWT, so the CPU figures are the whole machine's; the
  difference between the two columns is what reading adds. Not counted:
  microsandbox and the relay between the VM and MWT, the same both ways,
  and the network to a real host, which a new connection pays for twice
  when read (once to MWT, once from MWT), once when passed through.

  It fails when reading is atrocious, not merely slower: the bounds are
  far from what it measures, so a regression of several times trips them.
  """
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp
  alias MWTClient.Sandbox.Egress.Driver.Http1.Answer

  @moduletag :bench
  @moduletag timeout: :infinity

  @requests String.to_integer(System.get_env("BENCH_REQUESTS", "2000"))
  @clients String.to_integer(System.get_env("BENCH_CLIENTS", "32"))
  @values String.to_integer(System.get_env("BENCH_VALUES", "3"))
  @new_connections 200
  @per_client 200
  @mib 1024 * 1024
  @download 64 * @mib
  @upload 32 * @mib
  @small 1024
  @read "read.bench.example"
  @passed "passed.bench.example"
  @public "93.184.216.34:443"

  setup_all do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("proxy-bench")
    # The large upload would set off the firewall's upload rule: it is
    # what MWT costs that is timed here, not what the firewall does.
    :ok = Sandbox.firewall_set(username, {:enabled, false})
    :ok = Sandbox.reading_set(username, {:put, @passed, false})

    for n <- 1..@values//1 do
      {:ok, _} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Bench #{n}",
          "purpose" => "A value to look for",
          "hosts" => "api#{n}.elsewhere.example",
          "env" => "BENCH_#{n}",
          "value" => "bench_real_value_#{n}_" <> Base.encode16(:crypto.strong_rand_bytes(16))
        })
    end

    server_ca = CA.new("Bench server CA")
    server = start_server(CA.leaf(server_ca, "*.bench.example"))
    roots = Path.join(System.tmp_dir!(), "bench-roots-#{System.unique_integer([:positive])}.pem")
    File.write!(roots, CA.pem(server_ca.cert))

    [{:Certificate, mwt_ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()

    # A read request's TLS with the server, as for a real host: verified
    # for its name against the roots, only the address here.
    options = [
      upstream: fn target ->
        Tcp.connect_tls(%{target | ip: {127, 0, 0, 1}, port: server}, roots)
      end,
      upstream_tcp: fn _target ->
        :gen_tcp.connect(~c"127.0.0.1", server, [:binary, active: false, nodelay: true])
      end
    ]

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        nodelay: true,
        ip: {127, 0, 0, 1},
        backlog: 1024
      ])

    {:ok, proxy} = :inet.port(listen)
    spawn(fn -> accept(listen, username, options) end)

    IO.puts("\n=== Reading a connection, against passing it through ===")
    IO.puts("#{System.schedulers_online()} schedulers; client, server and MWT in one BEAM")
    IO.puts("#{@values} real values held, looked for in every answer read\n")

    %{username: username, proxy: proxy, cacerts: [mwt_ca, server_ca.cert]}
  end

  # Until the listener closes, at the end of the run.
  defp accept(listen, username, options) do
    with {:ok, client} <- :gen_tcp.accept(listen) do
      pid = spawn(fn -> receive(do: (:go -> Tcp.run(client, username, options))) end)
      :gen_tcp.controlling_process(client, pid)
      send(pid, :go)
      accept(listen, username, options)
    end
  end

  ## The server

  # HTTPS, keep-alive: `/small` 1 KiB, `/big` the download, `/upload`
  # reads its body, `/stream` ten chunks 20 ms apart, each saying when it
  # was sent.
  defp start_server(leaf) do
    {:ok, listen} =
      :ssl.listen(
        0,
        CA.ssl_options(leaf) ++
          [active: false, mode: :binary, reuseaddr: true, nodelay: true, backlog: 1024]
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn(fn -> serve(listen) end)
    port
  end

  defp serve(listen) do
    with {:ok, socket} <- :ssl.transport_accept(listen) do
      spawn(fn ->
        with {:ok, socket} <- :ssl.handshake(socket, 10_000), do: answer(socket, "")
      end)

      serve(listen)
    end
  end

  defp answer(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [_method, path | _] = String.split(head, " ", parts: 3)

        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        with {:ok, rest} <- discard(socket, rest, length) do
          respond(socket, path)
          if head =~ ~r/connection: close/i, do: :ssl.close(socket), else: answer(socket, rest)
        end

      [_] ->
        with {:ok, data} <- :ssl.recv(socket, 0, 30_000), do: answer(socket, buffer <> data)
    end
  end

  defp discard(_socket, rest, length) when byte_size(rest) >= length,
    do: {:ok, binary_part(rest, length, byte_size(rest) - length)}

  # The body's `length` bytes read and dropped: what came after them.
  defp discard(socket, rest, length) do
    with {:ok, data} <- :ssl.recv(socket, 0, 30_000),
         do: discard(socket, data, length - byte_size(rest))
  end

  defp respond(socket, "/small"),
    do:
      :ssl.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-length: #{@small}\r\n\r\n",
        :binary.copy("a", @small)
      ])

  defp respond(socket, "/upload"),
    do: :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")

  defp respond(socket, "/big") do
    :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{@download}\r\n\r\n")
    piece = :crypto.strong_rand_bytes(256 * 1024)
    for _ <- 1..div(@download, byte_size(piece)), do: :ssl.send(socket, piece)
  end

  defp respond(socket, "/stream") do
    :ssl.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
    )

    for _ <- 1..10 do
      Process.sleep(20)
      data = "data: #{System.monotonic_time(:microsecond)}\n\n"
      :ssl.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
    end

    :ssl.send(socket, "0\r\n\r\n")
  end

  ## The client

  # TLS to `host` through the proxy, verifying whoever answers: MWT's
  # certificate when it reads, the server's own when it doesn't.
  defp open(%{proxy: proxy, cacerts: cacerts}, host) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false, nodelay: true])

    :ok = :gen_tcp.send(socket, "CONNECT #{@public} HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 10_000)

    {:ok, tls} =
      :ssl.connect(
        socket,
        [
          verify: :verify_peer,
          cacerts: cacerts,
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          alpn_advertised_protocols: ["http/1.1"],
          active: false,
          mode: :binary
        ],
        10_000
      )

    tls
  end

  defp get(tls, host, path, extra \\ ""),
    do: :ok = :ssl.send(tls, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\n#{extra}\r\n")

  # One answer, read to its end and dropped: its size.
  defp drain(tls, answer \\ Answer.new("GET"), size \\ 0) do
    {:ok, data} = :ssl.recv(tls, 0, 30_000)

    case Answer.feed(answer, data) do
      {:more, bytes, answer} -> drain(tls, answer, size + IO.iodata_length(bytes))
      {:done, bytes, _beyond, _keep?} -> size + IO.iodata_length(bytes)
    end
  end

  ## Measuring

  defp timed(fun) do
    {us, value} = :timer.tc(fun)
    {us, value}
  end

  # CPU time the BEAM spent, every scheduler, over `fun`.
  defp cpu(fun) do
    {cpu_before, _} = :erlang.statistics(:runtime)
    {us, value} = :timer.tc(fun)
    {cpu_after, _} = :erlang.statistics(:runtime)
    {us, cpu_after - cpu_before, value}
  end

  # The journal on disk, its log included: what the activity takes.
  defp journal_bytes(username) do
    :ok = MWTClient.Storage.Journal.flush(username)
    dir = MWTClient.Accounts.dir(username)

    for name <- ["journal.db", "journal.db-wal"], reduce: 0 do
      total ->
        case File.stat(Path.join(dir, name)) do
          {:ok, %{size: size}} -> total + size
          _none -> total
        end
    end
  end

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))

  defp spread(samples_us) do
    sorted = Enum.sort(samples_us)
    %{p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), p99: percentile(sorted, 0.99)}
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 2)

  defp row(label, read, passed) do
    IO.puts(
      String.pad_trailing(label, 44) <>
        String.pad_leading(read, 14) <> String.pad_leading(passed, 14)
    )
  end

  defp header(title) do
    IO.puts("\n" <> title)
    row("", "read", "passed")
  end

  # The sandbox server has logged what came: the activity and the
  # exchanges are behind the connections, never in front of them.
  defp settled(username) do
    server = MWTClient.Vault.Store.whereis(Sandbox.Server, username)
    {:message_queue_len, waiting} = Process.info(server, :message_queue_len)
    {us, _} = :timer.tc(fn -> :sys.get_state(server, :infinity) end)
    {waiting, us}
  end

  ## The scenarios

  test "what reading costs", context do
    # Warm both paths: certificates made, code loaded.
    for host <- [@read, @passed] do
      tls = open(context, host)
      get(tls, host, "/small")
      drain(tls)
      :ssl.close(tls)
    end

    results = %{}

    # 1. A connection a request, as a script calling curl does.
    header("A connection a request (#{@new_connections} in a row), ms")

    new =
      for host <- [@read, @passed], into: %{} do
        {_us, cpu_ms, samples} =
          cpu(fn ->
            for _ <- 1..@new_connections do
              {us, _} =
                timed(fn ->
                  tls = open(context, host)
                  get(tls, host, "/small", "Connection: close\r\n")
                  drain(tls)
                  :ssl.close(tls)
                end)

              us
            end
          end)

        {host, Map.put(spread(samples), :cpu, cpu_ms / @new_connections)}
      end

    for p <- [:p50, :p95, :p99], do: row("  #{p}", ms(new[@read][p]), ms(new[@passed][p]))

    row(
      "  CPU a request, all schedulers",
      "#{Float.round(new[@read].cpu, 2)}",
      "#{Float.round(new[@passed].cpu, 2)}"
    )

    results = Map.put(results, :new, new)

    # 2. Many requests on one connection, as npm, pip or a model API's
    # client does.
    header("One kept connection (#{@requests} requests in a row), ms")

    kept =
      for host <- [@read, @passed], into: %{} do
        {waiting_before, _} = settled(context.username)
        0 = waiting_before
        journal_before = journal_bytes(context.username)
        tls = open(context, host)

        {_us, cpu_ms, samples} =
          cpu(fn ->
            for _ <- 1..@requests do
              {us, _} = timed(fn -> get(tls, host, "/small") && drain(tls) end)
              us
            end
          end)

        :ssl.close(tls)
        _ = settled(context.username)
        written = journal_bytes(context.username) - journal_before

        {host,
         spread(samples)
         |> Map.put(:cpu, cpu_ms / @requests)
         |> Map.put(:log, written / @requests)}
      end

    for p <- [:p50, :p95, :p99], do: row("  #{p}", ms(kept[@read][p]), ms(kept[@passed][p]))

    row(
      "  log kept a request, bytes (1 KiB answers)",
      "#{round(kept[@read].log)}",
      "#{round(kept[@passed].log)}"
    )

    row(
      "  CPU a request, all schedulers",
      "#{Float.round(kept[@read].cpu, 3)}",
      "#{Float.round(kept[@passed].cpu, 3)}"
    )

    {waiting, drain_us} = settled(context.username)
    IO.puts("  the log behind it: #{waiting} messages waiting, caught up in #{ms(drain_us)} ms")
    results = Map.put(results, :kept, kept)

    # 3. Clients at once, each on a kept connection.
    header("#{@clients} clients at once, #{@per_client} requests each on a kept connection")

    together =
      for host <- [@read, @passed], into: %{} do
        {us, cpu_ms, samples} =
          cpu(fn ->
            1..@clients
            |> Task.async_stream(
              fn _ ->
                tls = open(context, host)

                samples =
                  for _ <- 1..@per_client do
                    {us, _} = timed(fn -> get(tls, host, "/small") && drain(tls) end)
                    us
                  end

                :ssl.close(tls)
                samples
              end,
              max_concurrency: @clients,
              timeout: :infinity
            )
            |> Enum.flat_map(fn {:ok, samples} -> samples end)
          end)

        total = @clients * @per_client
        {waiting, drain_us} = settled(context.username)

        {host,
         Map.merge(spread(samples), %{
           rate: total / (us / 1_000_000),
           cpu: cpu_ms / total,
           waiting: waiting,
           drain: drain_us
         })}
      end

    row(
      "  requests a second",
      "#{round(together[@read].rate)}",
      "#{round(together[@passed].rate)}"
    )

    for p <- [:p50, :p99], do: row("  #{p}, ms", ms(together[@read][p]), ms(together[@passed][p]))

    row(
      "  CPU a request, ms, all schedulers",
      "#{Float.round(together[@read].cpu, 3)}",
      "#{Float.round(together[@passed].cpu, 3)}"
    )

    row(
      "  the log behind it: messages, caught up in",
      "#{together[@read].waiting}, #{ms(together[@read].drain)} ms",
      "#{together[@passed].waiting}, #{ms(together[@passed].drain)} ms"
    )

    # The sandbox server writes the log, one process: how fast it takes
    # each request's line and exchange, the most read requests it keeps
    # up with, past which the log falls behind (and an approval waits
    # behind it).
    if together[@read].waiting > 0 do
      rate = together[@read].waiting / (together[@read].drain / 1_000_000)

      IO.puts(
        "  the log takes #{round(rate)} messages a second, two a read request: " <>
          "it keeps up with about #{round(rate / 2)} requests a second"
      )
    end

    results = Map.put(results, :together, together)

    # 4. Bytes: a download and an upload.
    header("Throughput, MB/s")

    bytes =
      for host <- [@read, @passed], into: %{} do
        tls = open(context, host)
        {down_us, size} = timed(fn -> get(tls, host, "/big") && drain(tls) end)
        ^size = @download + byte_size("HTTP/1.1 200 OK\r\ncontent-length: #{@download}\r\n\r\n")

        body = :binary.copy("u", @upload)

        {up_us, _} =
          timed(fn ->
            :ok =
              :ssl.send(tls, [
                "POST /upload HTTP/1.1\r\nHost: #{host}\r\ncontent-length: #{@upload}\r\n\r\n",
                body
              ])

            drain(tls)
          end)

        :ssl.close(tls)

        {host,
         %{
           down: @download / @mib / (down_us / 1_000_000),
           up: @upload / @mib / (up_us / 1_000_000)
         }}
      end

    row(
      "  download #{div(@download, @mib)} MiB",
      "#{round(bytes[@read].down)}",
      "#{round(bytes[@passed].down)}"
    )

    row(
      "  upload #{div(@upload, @mib)} MiB",
      "#{round(bytes[@read].up)}",
      "#{round(bytes[@passed].up)}"
    )

    results = Map.put(results, :bytes, bytes)

    # 5. A streamed answer, as a model's: what each chunk waits more.
    header("A streamed answer, 10 chunks 20 ms apart: delay a chunk, ms")

    stream =
      for host <- [@read, @passed], into: %{} do
        tls = open(context, host)
        get(tls, host, "/stream")
        delays = stream_delays(tls, [], "")
        :ssl.close(tls)
        {host, spread(delays)}
      end

    for p <- [:p50, :p99], do: row("  #{p}", ms(stream[@read][p]), ms(stream[@passed][p]))
    results = Map.put(results, :stream, stream)

    # 6. The first time MWT reads a host: its certificate is made.
    {leaf_us, _} =
      timed(fn ->
        for n <- 1..50,
            do: MWTClient.Sandbox.Gate.leaf(context.username, "host#{n}.first.example")
      end)

    {cached_us, _} =
      timed(fn ->
        for n <- 1..50,
            do: MWTClient.Sandbox.Gate.leaf(context.username, "host#{n}.first.example")
      end)

    IO.puts(
      "\nA host's first certificate: #{ms(leaf_us / 50)} ms; kept after: #{ms(cached_us / 50)} ms"
    )

    print_summary(results)

    # Bounds for what would make the VM unusable, far from what runs.
    assert kept[@read].p50 < 5_000, "a kept-connection request takes #{ms(kept[@read].p50)} ms"
    assert kept[@read].p99 < 50_000
    assert new[@read].p50 < 50_000, "a request on a new connection takes #{ms(new[@read].p50)} ms"
    # Agents make tens to hundreds of requests a second at their busiest
    # (a package install): a thousand is far above, and well below what
    # this measures.
    assert together[@read].rate > 1_000, "#{round(together[@read].rate)} requests a second"
    assert together[@read].p99 < 100_000
    assert bytes[@read].down > 50 and bytes[@read].up > 50
    assert stream[@read].p99 < 15_000, "a streamed chunk waits #{ms(stream[@read].p99)} ms more"

    assert together[@read].drain < 5_000_000,
           "the log took #{ms(together[@read].drain)} ms to catch up"

    assert leaf_us / 50 < 50_000
  end

  # Each chunk's delay from when the server sent it, until the answer ends.
  defp stream_delays(tls, delays, buffer) do
    {:ok, data} = :ssl.recv(tls, 0, 10_000)
    now = System.monotonic_time(:microsecond)
    buffer = buffer <> data

    delays =
      delays ++
        for [_, sent] <- Regex.scan(~r/data: (-?\d+)\n/, buffer_tail(buffer, data)),
            do: now - String.to_integer(sent)

    if String.ends_with?(buffer, "0\r\n\r\n"),
      do: delays,
      else: stream_delays(tls, delays, buffer)
  end

  # The bytes just come, with the line before them that a split could
  # have cut.
  defp buffer_tail(buffer, data) do
    before = byte_size(buffer) - byte_size(data)
    start = max(before - 40, 0)
    piece = binary_part(buffer, start, byte_size(buffer) - start)
    # Only lines that end in what just came, so none is counted twice.
    case :binary.split(binary_part(piece, 0, before - start), "\n", [:global]) |> List.last() do
      nil -> data
      partial -> partial <> data
    end
  end

  defp print_summary(results) do
    added_new = results.new[@read].p50 - results.new[@passed].p50
    added_kept = results.kept[@read].p50 - results.kept[@passed].p50

    IO.puts("""

    Reading adds, at the median: #{ms(added_kept)} ms a request on a kept connection, \
    #{ms(added_new)} ms on a new one (MWT's TLS with the client, and its own with the host).
    """)
  end
end
