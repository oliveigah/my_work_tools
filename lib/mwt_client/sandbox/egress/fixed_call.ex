defmodule MWTClient.Sandbox.Egress.FixedCall do
  @moduledoc """
  Sends a request MWT built from a fixed call (a request action) through
  the pipeline the VM's own HTTPS requests go through, so both are held
  by one set of checks: the address the host resolves to, the firewall,
  reading it, putting the values in only where they go, the answer looked
  through for a real value (the connection cut when one comes back), and
  the activity log's request line, labelled as the fixed call's.

  How: MWT opens a connection to itself on the loopback, a pair of
  sockets in this process's hands, and serves one end with
  `MWTClient.Sandbox.Egress.Tcp.run/3`, as the proxy serves the VM's. On
  the other end it speaks as the VM would: CONNECT to the host's address,
  TLS with the host's name, then one HTTP/1.1 request. The difference is
  the `:fixed` option, the call's mark (`t:mark/0`): its request is
  decided by the call, which covers its credential in it, and by the
  network's grants, as the agent's own request would be
  (`MWTClient.Sandbox.Policy.reach/3`,
  `MWTClient.Sandbox.Gate.fixed_destination/4`,
  `MWTClient.Sandbox.Server`'s `:authorize_fixed`), and the values it
  carries go in where the request holds their placeholders. The mark
  lives in MWT's memory: the VM's connections take the options of the
  config, and nothing the VM sends can carry one.

  The request carries placeholders made for this call alone, never a
  real value: those reach only the connection's process, in the mark, and
  go in on the way out. The answer comes back as a command's run reports
  (`MWTClient.Sandbox.SavedRequest.send/4` did before): `exit` 0 for 2xx,
  22 for any other, 124 at the time limit; the body's first 256 KiB.

  It resolves the host through the network's resolver, for this dial alone.
  The connection uses that network's destination scope and outbound interface.
  """

  alias MWTClient.Sandbox.Gate
  alias MWTClient.Sandbox.Egress.Tcp

  @keep 256 * 1024

  @typedoc """
  A fixed call's mark: the action's `grant_id` and `name`, its
  `definition` as the call was approved (`Approval.digest/1`), the
  `network` its host is on, and the `swaps` to make, each a placeholder
  of this call's, the real `value`, the `label` it is logged as and the
  headers it goes `within`.
  """
  @type mark :: %{
          grant_id: String.t(),
          name: String.t(),
          definition: String.t(),
          network: String.t(),
          swaps: [
            %{label: String.t(), placeholder: String.t(), value: String.t(), within: [String.t()]}
          ]
        }

  @typedoc "A request MWT built: what `MWTClient.Sandbox.SavedRequest.build/2` makes."
  @type built :: %{
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t() | nil
        }

  @doc """
  Sends `built` for `username`'s fixed call `mark`, within `timeout`
  seconds, and reports how it went.
  """
  @spec send(String.t(), built(), mark(), pos_integer()) :: map()
  def send(username, built, mark, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout * 1_000
    uri = URI.parse(built.url)
    port = uri.port || 443
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    ref = make_ref()
    fixed = Map.merge(mark, %{host: String.downcase(uri.host), notify: self(), ref: ref})

    result =
      with :ok <- https_port(port),
           {:ok, [ip | _], route} <- Gate.resolve_fixed(username, fixed, port),
           {:ok, client} <- pair(username, Map.merge(fixed, route)),
           :ok <- connect(client, ip, port, deadline),
           {:ok, tls} <- handshake(client, uri.host, deadline) do
        try do
          :ok = :ssl.send(tls, request(built, uri.host, path))
          read(tls, deadline)
        after
          :ssl.close(tls)
        end
      end

    report(result, ref)
  end

  defp https_port(443), do: :ok
  defp https_port(_port), do: {:error, "Fixed calls use HTTPS port 443."}

  # Two connected sockets on the loopback, this process holding one end;
  # the other served as the proxy serves the VM's, with the call's mark.
  # The one accepted is checked to be the one this process connected: on
  # a loopback port anything on this machine could reach for a moment.
  defp pair(username, fixed) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    try do
      {:ok, port} = :inet.port(listen)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, ours} = :inet.sockname(client)

      with {:ok, served} <- :gen_tcp.accept(listen, 2_000),
           {:ok, ^ours} <- :inet.peername(served) do
        options =
          Application.get_env(:mwt_client, MWTClient.Sandbox.Egress, []) ++
            stand_in(username) ++ [fixed: fixed]

        {:ok, pid} =
          Task.Supervisor.start_child(MWTClient.Sandbox.TaskSupervisor, fn ->
            receive do
              {:go, socket} -> Tcp.run(socket, username, options)
            after
              5_000 -> :ok
            end
          end)

        :ok = :gen_tcp.controlling_process(served, pid)
        send(pid, {:go, served})
        {:ok, client}
      else
        _other -> {:error, "MWT couldn't open a connection to itself"}
      end
    after
      :gen_tcp.close(listen)
    end
  end

  # Only tests configure `config :mwt_client, MWTClient.Sandbox.Egress.FixedCall,
  # upstream: {module, function}`: called with the username, it gives the
  # proxy's `:upstream` (the service a test stands in for), or nil.
  defp stand_in(username) do
    case Application.get_env(:mwt_client, __MODULE__, [])[:upstream] do
      {module, function} ->
        case apply(module, function, [username]) do
          nil -> []
          upstream -> [upstream: upstream]
        end

      nil ->
        []
    end
  end

  defp connect(client, ip, port, deadline) do
    authority = authority(ip, port)
    :ok = :gen_tcp.send(client, "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n")

    case read_head(client, "", deadline) do
      {:ok, "HTTP/1.1 200" <> _, _rest} -> :ok
      {:ok, _refused, _rest} -> {:error, :refused}
      {:error, _reason} = error -> error
    end
  end

  defp authority(ip, port) when tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]:#{port}"
  defp authority(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  defp read_head(socket, read, deadline) do
    case :binary.split(read, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] ->
        case :gen_tcp.recv(socket, 0, left(deadline)) do
          {:ok, more} -> read_head(socket, read <> more, deadline)
          {:error, :timeout} -> {:error, :timeout}
          {:error, _closed} -> {:error, :refused}
        end
    end
  end

  # TLS with the proxy, which ends it with a certificate of MWT's own
  # authority: this process speaks to its own proxy over the loopback, so
  # there is nothing to verify that the pair doesn't already prove.
  defp handshake(client, host, deadline) do
    case :ssl.connect(
           client,
           [
             verify: :verify_none,
             server_name_indication: String.to_charlist(host),
             alpn_advertised_protocols: ["http/1.1"],
             active: false,
             mode: :binary
           ],
           left(deadline)
         ) do
      {:ok, tls} -> {:ok, tls}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :refused}
    end
  end

  defp request(built, host, path) do
    skip = ["host", "content-length", "connection", "transfer-encoding"]
    body = built.body || ""

    headers =
      for {name, value} <- built.headers,
          String.downcase(name) not in skip,
          do: [name, ": ", value, "\r\n"]

    [
      "#{built.method} #{path} HTTP/1.1\r\n",
      "host: #{host}\r\n",
      headers,
      if(built.body, do: "content-length: #{byte_size(body)}\r\n", else: []),
      "connection: close\r\n\r\n",
      body
    ]
  end

  # The answer: its head, then its body by what the head says it is, kept
  # up to 256 KiB and counted beyond; until the connection closes when the
  # head says no length.
  defp read(tls, deadline), do: read(tls, deadline, "", nil)

  defp read(tls, deadline, read, nil) do
    case :binary.split(read, "\r\n\r\n") do
      [head, rest] ->
        read(tls, deadline, rest, parse_head(head))

      [_partial] ->
        case recv(tls, deadline) do
          {:ok, more} -> read(tls, deadline, read <> more, nil)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read(tls, deadline, body, head) do
    case complete(head, body) do
      {:done, whole, total} ->
        {:ok, head.status, whole, total, true}

      :more ->
        case recv(tls, deadline) do
          {:ok, more} ->
            body = body <> more

            if byte_size(body) > @keep + 64 * 1024 and not head.chunked?,
              do: {:ok, head.status, body, head.length || byte_size(body), false},
              else: read(tls, deadline, body, head)

          {:error, :closed} ->
            {whole, total} = as_far_as(head, body)
            {:ok, head.status, whole, total, head.length == nil and not head.chunked?}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp recv(tls, deadline) do
    case :ssl.recv(tls, 0, left(deadline)) do
      {:ok, data} -> {:ok, data}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _closed} -> {:error, :closed}
    end
  end

  defp parse_head(head) do
    [status_line | lines] = String.split(head, "\r\n")

    status =
      case String.split(status_line, " ", parts: 3) do
        [_version, code | _] -> String.to_integer(code)
        _other -> 0
      end

    headers =
      for line <- lines,
          [name, value] <- [String.split(line, ":", parts: 2)],
          do: {String.downcase(String.trim(name)), String.trim(value)}

    length =
      case List.keyfind(headers, "content-length", 0) do
        {_, value} -> String.to_integer(value)
        nil -> nil
      end

    chunked? =
      case List.keyfind(headers, "transfer-encoding", 0) do
        {_, value} -> String.contains?(String.downcase(value), "chunked")
        nil -> false
      end

    %{status: status, length: length, chunked?: chunked?}
  rescue
    ArgumentError -> %{status: 0, length: nil, chunked?: false}
  end

  defp complete(%{chunked?: true}, body) do
    case dechunk(body, []) do
      {:done, whole} -> {:done, whole, byte_size(whole)}
      :more -> :more
    end
  end

  defp complete(%{length: length}, body) when is_integer(length) and byte_size(body) >= length,
    do: {:done, binary_part(body, 0, length), length}

  defp complete(_head, _body), do: :more

  defp as_far_as(%{chunked?: true}, body) do
    whole = dechunk_partial(body, [])
    {whole, byte_size(whole)}
  end

  defp as_far_as(%{length: length}, body) when is_integer(length), do: {body, length}
  defp as_far_as(_head, body), do: {body, byte_size(body)}

  defp dechunk(data, acc) do
    with [size_line, rest] <- :binary.split(data, "\r\n"),
         {size, _ext} <- Integer.parse(size_line, 16) do
      cond do
        size == 0 ->
          {:done, IO.iodata_to_binary(Enum.reverse(acc))}

        byte_size(rest) >= size + 2 ->
          dechunk(binary_part(rest, size + 2, byte_size(rest) - size - 2), [
            binary_part(rest, 0, size) | acc
          ])

        true ->
          :more
      end
    else
      _incomplete -> :more
    end
  end

  defp dechunk_partial(data, acc) do
    with [size_line, rest] <- :binary.split(data, "\r\n"),
         {size, _ext} when size > 0 <- Integer.parse(size_line, 16) do
      take = min(size, byte_size(rest))
      chunk = binary_part(rest, 0, take)

      if byte_size(rest) >= size + 2,
        do:
          dechunk_partial(binary_part(rest, size + 2, byte_size(rest) - size - 2), [chunk | acc]),
        else: IO.iodata_to_binary(Enum.reverse([chunk | acc]))
    else
      _end -> IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # As a command's run reports, with the cut MWT made said in words.
  defp report(result, ref) do
    cut_label =
      receive do
        {:fixed_cut, ^ref, label} -> label
      after
        0 -> nil
      end

    case result do
      {:ok, _status, body, total, _whole?} when cut_label != nil ->
        failed(
          "MWT cut the answer: it held #{label_words(cut_label)}, as it does for the VM's own requests",
          kept(body),
          total
        )

      {:ok, status, body, total, _whole?} ->
        kept = kept(body)

        %{
          exit: if(status in 200..299, do: 0, else: 22),
          status: status,
          output: kept,
          bytes: total,
          cut: max(total - byte_size(kept), 0),
          timed_out: false,
          error: nil
        }

      {:error, :timeout} ->
        %{exit: 124, status: nil, output: "", bytes: 0, cut: 0, timed_out: true, error: nil}

      {:error, :refused} ->
        failed("MWT refused it on the way out: the activity log says why", "", 0)

      {:error, message} when is_binary(message) ->
        failed(message, "", 0)

      {:error, reason} ->
        failed("it couldn't be sent: #{inspect(reason)}", "", 0)
    end
  end

  defp failed(message, output, total),
    do: %{
      exit: nil,
      status: nil,
      output: output,
      bytes: total,
      cut: max(total - byte_size(output), 0),
      timed_out: false,
      error: message
    }

  defp kept(body) do
    kept = if byte_size(body) > @keep, do: binary_part(body, 0, @keep), else: body
    String.replace_invalid(kept, "�")
  end

  defp label_words({:value, name}), do: "#{name}'s real value"
  defp label_words(other), do: "a real value (#{inspect(other)})"
end
