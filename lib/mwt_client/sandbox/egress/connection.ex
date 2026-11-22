defmodule MWTClient.Sandbox.Egress.Connection do
  @moduledoc """
  One connection the VM opened, from microsandbox's CONNECT to its close.

    1. The destination is checked (`MWTClient.Sandbox.Gate`, from the view
       the sandbox published: the Internet, `refused`, `private` and network
       grants); the sandbox may hold it for your approval. With the Internet
       off and no grant opening the address, the connection may still reach
       a token grant's host, read: anything else closes.
    2. The first bytes are peeked. A TLS ClientHello names its host (SNI).
    3. A host some credential grant lists is **read**: MWT finishes TLS with
       a certificate from its own CA, offering HTTP/1.1 only, reads the
       request, and decides whether it may go out and with what: the
       sandbox's server is asked only when it needs a real value or you.
       Everything else is **tunnelled** as bytes, unread.

  Read requests go out one per connection (`connection: close`), so every
  request is judged on its own and turning a grant off takes effect on the
  next one. A connection a grant let through (a tunnel to an address a
  network grant opened, a request carrying a token grant's value, and the
  session it upgrades to) is held under that grant, and closes as soon as
  the grant stops being live (`MWTClient.Sandbox.Server.Grants.close_ended/1`).

  Every head is read against a deadline, not an idle time per read: the
  CONNECT within 10 seconds, a read request's head within 30, and the start
  of its body within 10, so bytes that trickle can't hold a connection
  open. `MWTClient.Sandbox.Egress` caps how many are open at once. The upstream connection is MWT's own: it resolves the host and
  verifies its certificate, and the address the VM asked for is ignored, so
  a forged lookup in the VM cannot redirect a credential.

  The answer to a request MWT put a real value in is read back as HTTP
  (`MWTClient.Sandbox.Egress.Response`): the value is replaced with the
  placeholder in every head, and an answer carrying it in its body is cut
  before any of it reaches the VM. What the VM sends after the head is
  looked through for every grant's real value as it goes
  (`MWTClient.Sandbox.Egress.Scanner`): found, the connection is cut.

  MWT's firewall (`MWTClient.Sandbox.Watch`) hears of each one:
  its address and port with the destination check, the name it is for
  (`route`), and, for a tunnel, the bytes it carries as they flow. A tunnel
  reports every 256 KiB it sends, and once more at its end; the chunk that
  crosses a report waits for the answer, so a cut stops it before it goes.
  Every chunk a tunnel sends up is looked through for a placeholder or a
  real value first, whatever its first byte says: in TLS only the
  handshake is readable, and encrypted bytes can't match one by chance.
  Each connection joins `MWTClient.Sandbox.Connections` under its
  identity, so isolating the VM closes them all at once.
  """

  require Logger

  alias MWTClient.Sandbox.{Destinations, Exchange, Gate, Roots, Routes, Server}

  alias MWTClient.Sandbox.Egress.{Response, Scanner}

  @head_limit 64 * 1024
  @body_peek 64 * 1024
  @idle 60_000
  # The whole of a head, however slowly it trickles: the CONNECT msb sends
  # at once, and a read request's head. A byte a minute must not keep a
  # connection, and what MWT holds for it, forever.
  @connect_within 10_000
  @head_within 30_000
  # The start of a request's body that is read before deciding, and a
  # ClientHello split over segments.
  @body_within 10_000
  @record_within 5_000
  # The driver's own buffer per socket. The default (a few KiB) costs a
  # tunnel about four times the CPU and a quarter of the speed.
  @buffer 262_144
  # microsandbox waits 10 seconds for the answer to a CONNECT.
  @answer_within 3_000
  # A client that speaks first does so at once; after this long MWT also
  # connects, in case the server speaks first.
  @client_first 100
  @server_first 1_400
  # How long bytes that could start a real value wait for what follows
  # before they go anyway.
  @hold 50
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @overrides ~w(x-http-method-override x-http-method x-method-override)
  @field_value ~r/\A[\t\x20-\x7e\x80-\xff]*\z/

  @doc """
  Serves `client`, an accepted socket the caller owns.

  ## Options

    * `:upstream` - `fn host -> {:ok, ssl_socket} | {:error, reason} end`, the
      connection a read request is sent on; tests point it elsewhere
    * `:answer_within` - how long, in milliseconds, the sandbox has to answer
      for a destination before the CONNECT is answered and the tunnel waits
      instead (3 seconds)
    * `:head_within` - how long, in milliseconds, the CONNECT (10 seconds)
      and a read request's head (30 seconds) may take to arrive whole;
      tests make it short
  """
  def run(client, username, options \\ []) do
    started = System.monotonic_time(:millisecond)
    join(username)
    connect_by = within(Keyword.get(options, :head_within, @connect_within))

    with {:ok, head, rest} <- read_head(client, :gen_tcp, "", connect_by),
         {:ok, host, port} <- connect_target(head),
         {:ok, ip} <- address(host),
         {:ok, reach} <- destination(client, username, ip, port, options),
         # A grant with a way out of its own keeps its connections on it.
         anchor = anchor(username, reach),
         {from_client, from_server, upstream} <- opening(client, rest, {ip, port, anchor}, reach) do
      sni = sni(from_client)
      under = if reach == :read_only, do: :read_only, else: elem(reach, 1)

      case Gate.route(username, ip, port, sni, under) do
        :intercept ->
          discard(upstream)
          intercept(client, from_client, sni, username, options)

        {:tunnel, watch} ->
          watch = watching(watch, username, port)

          tunnel(
            client,
            from_client,
            from_server,
            upstream,
            {ip, port, sni, anchor},
            username,
            started,
            watch
          )

        :refuse ->
          discard(upstream)
          :gen_tcp.close(client)
      end
    else
      {:deny, _reason} ->
        :gen_tcp.send(client, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(client)

      _error ->
        :gen_tcp.close(client)
    end
  rescue
    error ->
      Logger.debug("sandbox connection ended: #{Exception.message(error)}", system: :sandbox)
      :gen_tcp.close(client)
  catch
    :exit, reason ->
      Logger.debug("sandbox connection ended: #{inspect(reason)}", system: :sandbox)
      :gen_tcp.close(client)
  end

  # Joins the connections isolating the VM closes. An MWT started before
  # the registry, with this code loaded since, has none to join.
  defp join(username) do
    Registry.register(MWTClient.Sandbox.Connections, username, nil)
  rescue
    ArgumentError -> :ok
  end

  # Asks whether the VM may connect there (`MWTClient.Sandbox.Gate`):
  # `{:ok, {:open, grant_id}}`, `{:ok, :read_only}` (only a token grant's host, read by
  # MWT, while the Internet is off), or a refusal. An answer that comes at
  # once is passed on as it is: 200, or 403, which the VM sees as
  # "connection refused". A destination waiting for your approval takes
  # longer than microsandbox waits for a CONNECT, so then the 200 goes out
  # first and the open tunnel waits instead; a "no" closes it. A grant that
  # let it through holds it (`Gate.held_by/2`).
  defp destination(client, username, ip, port, options) do
    parent = self()
    ref = make_ref()

    spawn_link(fn -> send(parent, {ref, Gate.destination(username, ip, port)}) end)

    receive do
      {^ref, answer} ->
        case reach(username, answer) do
          {:ok, reach} -> with :ok <- established(client), do: {:ok, reach}
          {:error, :grant_off} -> {:deny, :grant_off}
          denied -> denied
        end
    after
      Keyword.get(options, :answer_within, @answer_within) ->
        with :ok <- established(client) do
          receive do
            {^ref, answer} ->
              case reach(username, answer) do
                {:ok, reach} -> {:ok, reach}
                _denied -> {:error, :denied}
              end
          end
        end
    end
  end

  defp reach(username, {:ok, grant}) do
    with :ok <- Gate.held_by(username, grant), do: {:ok, {:open, grant}}
  end

  defp reach(_username, :read_only), do: {:ok, :read_only}
  defp reach(_username, {:deny, reason}), do: {:deny, reason}

  defp established(client),
    do: :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")

  ## The first bytes

  # Who speaks first, as `{from_client, from_server, upstream}`. Most clients
  # do, at once (a TLS ClientHello, an HTTP request), and their first bytes
  # decide between reading and tunnelling. When the client stays quiet for a
  # moment the server probably speaks first (SSH, SMTP, MySQL): MWT connects
  # and takes the first bytes from either side, instead of making the server's
  # greeting wait. `upstream` is the connection made on the way, if any.
  #
  # A connection only a token grant's host may use is read or closed, never
  # passed through: MWT connects nowhere for it before the client spoke.
  defp anchor(_username, :read_only), do: nil
  defp anchor(username, {:open, grant}), do: Gate.anchor(username, grant)

  defp opening(client, rest, _target, :read_only) do
    case rest do
      "" ->
        case :gen_tcp.recv(client, 0, @server_first) do
          {:ok, data} -> {complete_record(client, data), "", nil}
          {:error, reason} -> {:error, reason}
        end

      rest ->
        {complete_record(client, rest), "", nil}
    end
  end

  defp opening(client, "", {ip, port, anchor}, {:open, _grant}) do
    case :gen_tcp.recv(client, 0, @client_first) do
      {:ok, data} -> {complete_record(client, data), "", nil}
      {:error, :timeout} -> either(client, connect(ip, port, anchor))
      {:error, reason} -> {:error, reason}
    end
  end

  defp opening(client, rest, _target, {:open, _grant}),
    do: {complete_record(client, rest), "", nil}

  defp either(_client, {:error, _reason} = failed), do: {"", "", failed}

  defp either(client, {:ok, upstream}) do
    :inet.setopts(client, active: :once)
    :inet.setopts(upstream, active: :once)

    receive do
      {:tcp, ^client, data} -> {complete_record(client, data), "", {:ok, upstream}}
      {:tcp, ^upstream, data} -> {"", data, {:ok, upstream}}
      {tag, ^client} when tag in [:tcp_closed, :tcp_error] -> {:error, :closed}
      {:tcp_error, ^client, reason} -> {:error, reason}
      {:tcp_closed, ^upstream} -> {"", "", {:error, :closed}}
      {:tcp_error, ^upstream, reason} -> {"", "", {:error, reason}}
    after
      @server_first -> {"", "", {:ok, upstream}}
    end
  end

  # A connection made while waiting for the first bytes, not needed after
  # all: closed, and whatever it already delivered dropped.
  defp discard({:ok, upstream}) do
    :gen_tcp.close(upstream)
    forget(upstream)
  end

  defp discard(_none), do: :ok

  defp forget(socket) do
    receive do
      {:tcp, ^socket, _data} -> forget(socket)
      {:tcp_closed, ^socket} -> forget(socket)
      {:tcp_error, ^socket, _reason} -> forget(socket)
    after
      0 -> :ok
    end
  end

  # A ClientHello can span TCP segments (post-quantum key shares make it
  # large), so read until the TLS record is whole.
  defp complete_record(client, data), do: complete_record(client, data, within(@record_within))

  defp complete_record(client, <<0x16, _major, _minor, length::16, _::binary>> = data, by)
       when byte_size(data) < length + 5 do
    case :gen_tcp.recv(client, 0, left(by)) do
      {:ok, more} -> complete_record(client, data <> more, by)
      {:error, _} -> data
    end
  end

  defp complete_record(_client, data, _by), do: data

  ## Tunnels

  defp connect(ip, port, anchor) do
    :gen_tcp.connect(
      ip,
      port,
      [:binary, active: false, nodelay: true, buffer: @buffer] ++ Routes.options(anchor),
      10_000
    )
  end

  defp tunnel(
         client,
         from_client,
         from_server,
         upstream,
         {ip, port, sni, anchor},
         username,
         started,
         watch
       ) do
    case upstream || connect(ip, port, anchor) do
      {:ok, upstream} ->
        :inet.setopts(client, buffer: @buffer)

        {up, down} =
          case watched(watch, from_client, byte_size(from_client), byte_size(from_server)) do
            {:ok, watch} ->
              if from_client != "", do: :ok = :gen_tcp.send(upstream, from_client)
              if from_server != "", do: :ok = :gen_tcp.send(client, from_server)

              splice(
                client,
                :gen_tcp,
                upstream,
                :gen_tcp,
                byte_size(from_client),
                byte_size(from_server),
                watch
              )

            {:cut, _watch} ->
              finish(client, :gen_tcp, upstream, :gen_tcp, 0, 0, nil)
          end

        Server.cast(
          username,
          {:log,
           %{
             outcome: :tunnel,
             summary: "Passed through",
             host: sni || "#{:inet.ntoa(ip)}",
             port: port,
             up: up,
             down: down,
             ms: System.monotonic_time(:millisecond) - started
           }}
        )

      {:error, reason} ->
        Server.cast(
          username,
          {:log,
           %{
             outcome: :blocked,
             summary: "Could not connect: #{:inet.format_error(reason)}",
             host: sni || "#{:inet.ntoa(ip)}",
             port: port
           }}
        )

        :gen_tcp.close(client)
    end
  end

  ## Read requests

  defp intercept(client, first, sni, username, options) do
    :ok = :gen_tcp.unrecv(client, first)
    certificate = Gate.leaf(username, sni)

    {:ok, tls} =
      :ssl.handshake(
        client,
        certificate ++
          [
            alpn_preferred_protocols: ["http/1.1"],
            versions: [:"tlsv1.3", :"tlsv1.2"],
            active: false,
            mode: :binary
          ],
        10_000
      )

    head_by = within(Keyword.get(options, :head_within, @head_within))

    with {:ok, head, rest} <- read_head(tls, :ssl, "", head_by),
         {:ok, method, target, version, headers} <- parse_request(head),
         :ok <- acceptable(method, target, headers, sni) do
      # One Host, and it is the name the connection was encrypted for.
      headers = List.keyreplace(headers, "host", 0, {"host", sni})
      {headers, rest} = continue_if_expected(tls, headers, rest)
      body = read_body_prefix(tls, headers, rest)

      request = %{
        host: sni,
        method: method,
        path: target,
        headers: headers,
        body: body,
        exchange: Exchange.new_id()
      }

      # What the VM sent, kept for the log before a real value goes in.
      record = %{
        username: username,
        id: request.exchange,
        request: Exchange.request(request),
        sent: Exchange.capture()
      }

      case Gate.authorize(username, request) do
        {:forward, headers, scan} ->
          request = %{request | method: method, path: target, headers: headers}

          case Gate.held_by(username, Map.get(scan, :grant)) do
            :ok ->
              send_upstream(tls, request, version, scan, record, options)

            {:error, :grant_off} ->
              json =
                Jason.encode!(%{
                  code: "mwt_grant_off",
                  error: "The grant turned off before this request went out.",
                  by: "MWT agent sandbox"
                })

              respond(tls, 403, json)
              recorded(record, Exchange.mwt_answer(403, json))
          end

        {:deny, status, json} ->
          respond(tls, status, json)
          recorded(record, Exchange.mwt_answer(status, json))

        # A credential endpoint MWT answered itself, with placeholders
        # (`MWTClient.Sandbox.CredentialEndpoint`): nothing went out from
        # the VM.
        {:answer, status, json} ->
          respond(tls, status, json)
          recorded(record, Exchange.mwt_answer(status, json))
      end
    else
      {:misdirected, host} ->
        respond(
          tls,
          421,
          Jason.encode!(%{error: "Host #{host} does not match #{sni}.", by: "MWT agent sandbox"})
        )

      {:refuse, status, code, message} ->
        respond(
          tls,
          status,
          Jason.encode!(%{code: code, error: message, by: "MWT agent sandbox"})
        )

      {:error, :bad_request} ->
        respond(
          tls,
          400,
          Jason.encode!(%{
            code: "mwt_bad_request",
            error: "MWT could not read this as one HTTP/1.1 request.",
            by: "MWT agent sandbox"
          })
        )

      {:error, :head_too_large} ->
        respond(
          tls,
          431,
          Jason.encode!(%{
            code: "mwt_bad_request",
            error: "The request's head is over #{div(@head_limit, 1024)} KiB.",
            by: "MWT agent sandbox"
          })
        )

      _closed ->
        :ssl.close(tls)
    end
  end

  # `scan` says what to look for: `out`, every real value, in what the VM
  # sends after the head; `echo`, the forms of the value put in this request,
  # in the answer, where `placeholder` replaces it in heads.
  defp send_upstream(tls, request, version, scan, record, options) do
    out = Scanner.new(scan.out)
    username = record.username

    case Scanner.feed(out, request.body) do
      {:found, label} ->
        found(username, label, request.host, :request)
        respond(tls, 403, Jason.encode!(blocked()))

      {:ok, _body, out} ->
        connect = Keyword.get(options, :upstream, &upstream/1)

        case connect.(request.host) do
          {:ok, upstream} ->
            :ok = :ssl.send(upstream, [head(request, version, scan.echo), request.body])

            response =
              if scan.echo, do: Response.new(request.method, scan.echo, scan.placeholders)

            relay(tls, upstream, response, out, Map.put(record, :host, request.host))

          {:error, reason} ->
            json =
              Jason.encode!(%{
                error: "Could not reach #{request.host}: #{inspect(reason)}",
                by: "MWT agent sandbox"
              })

            respond(tls, 502, json)
            recorded(record, Exchange.mwt_answer(502, json))
        end
    end
  end

  # The head MWT writes itself: one request per connection, and with a real
  # value in it, an answer asked for without content encoding, so a value
  # it quotes can be read.
  defp head(request, version, echo) do
    upgrade? = Enum.any?(request.headers, fn {name, _} -> name == "upgrade" end)

    headers =
      request.headers
      |> Enum.reject(fn {name, _} ->
        name in ["proxy-connection", "keep-alive"] or (name == "connection" and not upgrade?) or
          (name == "accept-encoding" and echo != nil)
      end)
      |> then(&if(echo, do: &1 ++ [{"accept-encoding", "identity"}], else: &1))
      |> then(&if(upgrade?, do: &1, else: &1 ++ [{"connection", "close"}]))

    [
      request.method,
      " ",
      request.path,
      " ",
      version,
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]
  end

  defp blocked do
    %{
      code: "mwt_value_blocked",
      error:
        "This request holds a real credential, which nothing in the VM should have. " <>
          "It did not go out. The user has been told.",
      by: "MWT agent sandbox"
    }
  end

  defp upstream(host) do
    charlist = String.to_charlist(host)

    :ssl.connect(
      charlist,
      443,
      [
        nodelay: true,
        verify: :verify_peer,
        cacertfile: Roots.file(),
        server_name_indication: charlist,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        alpn_advertised_protocols: ["http/1.1"],
        depth: 10,
        active: false,
        mode: :binary
      ],
      15_000
    )
  end

  defp respond(tls, status, json) do
    reason = Plug.Conn.Status.reason_phrase(status)

    :ssl.send(tls, [
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n",
      json
    ])

    :ssl.close(tls)
  end

  # MWT judges a request by what it read, and the host must act on the same
  # thing. So a request two parsers could read two ways does not go out: its
  # target is a path, it has one Host (the name it was encrypted for, or it
  # could look like GitHub to MWT while going elsewhere), and one way of
  # saying how long its body is. TRACE has the host send the request back,
  # real value included.
  defp acceptable(method, target, headers, sni) do
    hosts = for {"host", value} <- headers, do: String.downcase(value)
    lengths = for {"content-length", value} <- headers, do: value
    encodings = for {"transfer-encoding", value} <- headers, do: String.downcase(value)

    cond do
      method in ["TRACE", "CONNECT"] ->
        {:refuse, 405, "mwt_method_refused", "MWT does not pass on #{method} requests."}

      # MWT would judge, and an allowance match, the method it reads while
      # the host carries out another.
      Enum.any?(headers, fn {name, _} -> name in @overrides end) ->
        {:refuse, 400, "mwt_bad_request",
         "A request says its method once: MWT doesn't pass on a method override."}

      not (String.starts_with?(target, "/") or (method == "OPTIONS" and target == "*")) ->
        {:refuse, 400, "mwt_bad_request", "The request target must be a path."}

      # What HTTP allows in a target, and what an approval can show as it is.
      not (target =~ ~r/\A[\x21-\x7e]+\z/) ->
        {:refuse, 400, "mwt_bad_request",
         "The request target must be visible ASCII: percent-encode anything else."}

      length(hosts) != 1 ->
        {:refuse, 400, "mwt_bad_request", "A request needs exactly one Host header."}

      hd(hosts) not in [sni, sni <> ":443"] ->
        {:misdirected, hd(hosts)}

      length(lengths) > 1 or (lengths != [] and encodings != []) ->
        {:refuse, 400, "mwt_bad_request",
         "A request says how long its body is once: Content-Length or Transfer-Encoding."}

      lengths != [] and not (hd(lengths) =~ ~r/\A[0-9]+\z/) ->
        {:refuse, 400, "mwt_bad_request", "Content-Length must be a number."}

      encodings not in [[], ["chunked"]] ->
        {:refuse, 400, "mwt_bad_request", "The only Transfer-Encoding passed on is chunked."}

      true ->
        :ok
    end
  end

  # Answers 100 Continue ourselves, so the start of the body arrives before
  # the decision; the upstream then never sees the expectation.
  defp continue_if_expected(tls, headers, rest) do
    case List.keyfind(headers, "expect", 0) do
      {_, value} ->
        if String.downcase(value) == "100-continue" do
          :ssl.send(tls, "HTTP/1.1 100 Continue\r\n\r\n")
          {List.keydelete(headers, "expect", 0), rest}
        else
          {headers, rest}
        end

      nil ->
        {headers, rest}
    end
  end

  defp read_body_prefix(tls, headers, rest) do
    wanted =
      case List.keyfind(headers, "content-length", 0) do
        {_, length} ->
          case Integer.parse(length) do
            {n, _} -> min(n, @body_peek)
            :error -> 0
          end

        nil ->
          if List.keymember?(headers, "transfer-encoding", 0), do: :chunked, else: 0
      end

    by = within(@body_within)

    if wanted == :chunked,
      do: read_chunked(tls, rest, by),
      else: read_at_least(tls, rest, wanted, by)
  end

  # A chunked body is read until its last chunk or the peek limit, whichever
  # comes first: a small one ends long before the limit.
  defp read_chunked(tls, acc, by) do
    if byte_size(acc) >= @body_peek or chunked_whole?(acc) do
      acc
    else
      case :ssl.recv(tls, 0, min(2_000, left(by))) do
        {:ok, data} -> read_chunked(tls, acc <> data, by)
        {:error, _timeout_or_closed} -> acc
      end
    end
  end

  @doc "Whether these bytes hold a chunked body up to and including its last chunk."
  @spec chunked_whole?(binary()) :: boolean()
  def chunked_whole?(data) do
    with [line, rest] <- :binary.split(data, "\r\n"),
         {size, _extension} <- line |> String.trim() |> Integer.parse(16) do
      cond do
        size == 0 and String.starts_with?(rest, "\r\n") ->
          true

        size == 0 ->
          String.contains?(rest, "\r\n\r\n")

        true ->
          case rest do
            <<_chunk::binary-size(size), "\r\n", more::binary>> -> chunked_whole?(more)
            _short -> false
          end
      end
    else
      # Not a chunk header: nothing to wait for; the host will refuse it.
      :error -> true
      [_no_line_yet] -> false
    end
  end

  defp read_at_least(_tls, acc, wanted, _by) when byte_size(acc) >= wanted, do: acc

  defp read_at_least(tls, acc, wanted, by) do
    case :ssl.recv(tls, 0, min(2_000, left(by))) do
      {:ok, data} -> read_at_least(tls, acc <> data, wanted, by)
      {:error, _timeout_or_closed} -> acc
    end
  end

  ## Moving bytes

  # A tunnel: copies both ways until either side closes, what goes up shown
  # to the firewall's watch first.
  defp splice(a, a_mod, b, b_mod, up, down, watch) do
    set_active(a, a_mod)
    set_active(b, b_mod)
    loop(a, a_mod, b, b_mod, up, down, watch)
  end

  defp loop(a, a_mod, b, b_mod, up, down, watch) do
    receive do
      {tag, ^a, data} when tag in [:tcp, :ssl] ->
        case watched(watch, data, up + byte_size(data), down) do
          {:ok, watch} ->
            b_mod.send(b, data)
            set_active(a, a_mod)
            loop(a, a_mod, b, b_mod, up + byte_size(data), down, watch)

          {:cut, _watch} ->
            finish(a, a_mod, b, b_mod, up, down, nil)
        end

      {tag, ^b, data} when tag in [:tcp, :ssl] ->
        a_mod.send(a, data)
        set_active(b, b_mod)
        loop(a, a_mod, b, b_mod, up, down + byte_size(data), watch)

      {tag, _socket} when tag in [:tcp_closed, :ssl_closed] ->
        finish(a, a_mod, b, b_mod, up, down, watch)

      {tag, _socket, _reason} when tag in [:tcp_error, :ssl_error] ->
        finish(a, a_mod, b, b_mod, up, down, watch)

      # Its grant's time was up: it goes on only if the grant still is.
      {:grant_check, username, grant} ->
        case Gate.check(username, grant) do
          :ok -> loop(a, a_mod, b, b_mod, up, down, watch)
          {:error, :grant_off} -> finish(a, a_mod, b, b_mod, up, down, watch)
        end
    after
      @idle * 5 -> finish(a, a_mod, b, b_mod, up, down, watch)
    end
  end

  defp finish(a, a_mod, b, b_mod, up, down, watch) do
    a_mod.close(a)
    b_mod.close(b)
    # What the tunnel sent since its last report still counts.
    report(watch, up, down)
    {up, down}
  end

  # A read request, sent: what the VM sends after it goes up looked through
  # for real values (`out`); the answer comes back through `response`, or as
  # it is when MWT put no value in the request. `record` keeps what went to
  # the VM, for the log, until the connection ends.
  defp relay(tls, upstream, response, out, record) do
    :ssl.setopts(tls, active: :once)
    :ssl.setopts(upstream, active: :once)
    relaying(tls, upstream, response, out, record)
  end

  defp relaying(tls, upstream, response, out, record) do
    waiting = if response && Response.held?(response), do: @hold, else: @idle * 5

    receive do
      {:ssl, ^tls, data} ->
        case Scanner.feed(out, data) do
          {:ok, data, out} ->
            :ssl.send(upstream, data)
            :ssl.setopts(tls, active: :once)
            relaying(tls, upstream, response, out, record)

          {:found, label} ->
            found(record.username, label, record.host, :request)

            close(
              tls,
              upstream,
              record,
              "Cut by MWT: the VM sent a real credential after the head."
            )
        end

      {:ssl, ^upstream, data} when is_nil(response) ->
        record = to_vm(tls, data, record)
        :ssl.setopts(upstream, active: :once)
        relaying(tls, upstream, response, out, record)

      {:ssl, ^upstream, data} ->
        response
        |> Response.feed(data)
        |> answered(tls, upstream, out, record)

      {:ssl_closed, ^upstream} when response != nil ->
        response
        |> Response.finish()
        |> answered(tls, upstream, out, record)

      {tag, _socket} when tag in [:ssl_closed, :tcp_closed] ->
        close(tls, upstream, record)

      {tag, _socket, _reason} when tag in [:ssl_error, :tcp_error] ->
        close(tls, upstream, record, "The connection failed before the answer ended.")

      # Its grant's time was up: it goes on only if the grant still is.
      {:grant_check, username, grant} ->
        case Gate.check(username, grant) do
          :ok ->
            relaying(tls, upstream, response, out, record)

          {:error, :grant_off} ->
            close(tls, upstream, record, "Closed by MWT: the grant that let it through ended.")
        end
    after
      waiting ->
        if response && Response.held?(response) do
          {bytes, response} = Response.release(response)
          record = to_vm(tls, bytes, record)
          relaying(tls, upstream, response, out, record)
        else
          close(
            tls,
            upstream,
            record,
            "Closed by MWT: nothing came for #{div(@idle * 5, 1000)} s."
          )
        end
    end
  end

  defp answered({:more, bytes, response}, tls, upstream, out, record) do
    record = to_vm(tls, bytes, record)
    :ssl.setopts(upstream, active: :once)
    relaying(tls, upstream, response, out, record)
  end

  defp answered({:done, bytes}, tls, upstream, _out, record) do
    record = to_vm(tls, bytes, record)
    close(tls, upstream, record)
  end

  # The sandbox hears of it before the VM sees the answer end.
  defp answered({:cut, reason, bytes}, tls, upstream, _out, record) do
    :ssl.close(upstream)
    record = to_vm(tls, bytes, record)

    note =
      case reason do
        {:found, label} ->
          found(record.username, label, record.host, :echo)
          "Cut by MWT: the answer quoted the real credential."

        :unreadable ->
          unreadable(record.username, record.host)
          "Cut by MWT: it could not read the rest of the answer."
      end

    close(tls, upstream, record, note)
  end

  defp answered({:refuse, message}, tls, upstream, _out, record) do
    :ssl.close(upstream)
    unreadable(record.username, record.host)

    json =
      Jason.encode!(%{
        code: "mwt_unreadable_response",
        error: "MWT could not read #{record.host}'s answer, so it did not pass it on: #{message}",
        by: "MWT agent sandbox"
      })

    respond(tls, 502, json)
    recorded(record, Exchange.mwt_answer(502, json))
  end

  # Bytes for the VM: sent, and kept for the log.
  defp to_vm(tls, bytes, record) do
    if IO.iodata_length(bytes) > 0, do: :ssl.send(tls, bytes)
    %{record | sent: Exchange.capture(record.sent, bytes)}
  end

  defp close(tls, upstream) do
    :ssl.close(upstream)
    :ssl.close(tls)
  end

  defp close(tls, upstream, record, note \\ nil) do
    close(tls, upstream)
    recorded(record, Exchange.response(record.sent, note))
  end

  # The exchange goes to the sandbox, which keeps it with the request's
  # events.
  defp recorded(record, response) do
    Server.cast(
      record.username,
      {:exchange, record.id, %{request: record.request, response: response}}
    )
  end

  # Tells the sandbox what was found where it doesn't belong: `how` it was
  # going (`:request`, `:plaintext`), or that it came back (`:echo`). It
  # never went on, whatever the firewall does next.
  defp found(username, label, destination, how) do
    Gate.found(username, label, destination, how)
  catch
    :exit, _not_answering -> :cut
  end

  defp unreadable(username, host) do
    Server.cast(
      username,
      {:log,
       %{
         outcome: :blocked,
         summary: "An answer MWT could not read, not passed on",
         host: host,
         port: 443
       }}
    )
  end

  ## The firewall's watch on a tunnel

  # What the sandbox asked of this tunnel (`route`), made ready: when the
  # next report is due, and what to look for in plain text.
  defp watching(nil, _username, _port), do: nil

  defp watching(watch, username, port) do
    %{
      username: username,
      destination: watch.destination,
      port: port,
      every: watch.report_every,
      next: watch.report_every,
      sent: {0, 0},
      scanner: Scanner.new(Map.get(watch, :secrets))
    }
  end

  # `data`, about to go up, with `up` bytes sent once it has: `{:ok, watch}`
  # to send it, `{:cut, watch}` to close the tunnel instead.
  defp watched(nil, _data, _up, _down), do: {:ok, nil}

  defp watched(watch, data, up, down) do
    with {:ok, watch} <- scanned(watch, data) do
      if watch.every && up >= watch.next do
        case report(watch, up, down) do
          :ok -> {:ok, %{watch | next: up + watch.every, sent: {up, down}}}
          :cut -> {:cut, watch}
        end
      else
        {:ok, watch}
      end
    end
  end

  defp scanned(watch, data) do
    case Scanner.feed(watch.scanner, data) do
      {:ok, _data, scanner} ->
        {:ok, %{watch | scanner: scanner}}

      {:found, label} ->
        _cut = found(watch.username, label, "#{watch.destination}:#{watch.port}", :plaintext)
        {:cut, watch}
    end
  end

  # Tells the sandbox what went up and came back since the last report.
  defp report(nil, _up, _down), do: :ok
  defp report(%{every: nil}, _up, _down), do: :ok

  defp report(watch, up, down) do
    {sent_up, sent_down} = watch.sent

    if up > sent_up or down > sent_down do
      Gate.upload(watch.username, watch.destination, watch.port, up - sent_up, down - sent_down)
    else
      :ok
    end
  catch
    :exit, _not_answering -> :cut
  end

  defp set_active(socket, :gen_tcp), do: :inet.setopts(socket, active: :once)
  defp set_active(socket, :ssl), do: :ssl.setopts(socket, active: :once)

  ## Parsing

  # The time by which something must have arrived, and how long is left
  # of it.
  defp within(ms), do: System.monotonic_time(:millisecond) + ms
  defp left(by), do: max(by - System.monotonic_time(:millisecond), 0)

  # A head, whole by `by` (`within/1`), or `{:error, :timeout}`.
  defp read_head(socket, mod, acc, by) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _rest] when byte_size(head) > @head_limit ->
        {:error, :head_too_large}

      [head, rest] ->
        {:ok, head, rest}

      [_] when byte_size(acc) > @head_limit ->
        {:error, :head_too_large}

      [_] ->
        # A head that ends its lines with line feeds alone never ends for
        # this reader: said at once, instead of waiting for more.
        if :binary.match(acc, "\n\n") != :nomatch do
          {:error, :bad_request}
        else
          case mod.recv(socket, 0, left(by)) do
            {:ok, data} -> read_head(socket, mod, acc <> data, by)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp connect_target(head) do
    with [line | _] <- String.split(head, "\r\n"),
         ["CONNECT", target, _version] <- String.split(line, " "),
         [port | reversed] <- target |> String.split(":") |> Enum.reverse(),
         {port, ""} <- Integer.parse(port) do
      {:ok, reversed |> Enum.reverse() |> Enum.join(":"), port}
    else
      _ -> {:error, :not_connect}
    end
  end

  defp address(host) do
    case Destinations.parse_ip(host) do
      {:ok, ip} ->
        {:ok, ip}

      :error ->
        case Destinations.resolve(host) do
          [ip | _] -> {:ok, ip}
          [] -> {:error, :unresolved}
        end
    end
  end

  # Strict on purpose: a line that isn't `name: value`, a name with a space in
  # it, a folded header or a stray CR or LF is where two parsers disagree. A
  # value is what HTTP says one is: visible bytes, spaces and tabs, with the
  # spaces and tabs around it dropped and nothing else.
  defp parse_request(head) do
    [line | lines] = String.split(head, "\r\n")

    with [method, target, version] when version in ["HTTP/1.1", "HTTP/1.0"] <-
           String.split(line, " "),
         true <- method =~ @token,
         {:ok, headers} <- parse_headers(lines, []) do
      {:ok, method, target, version, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp parse_headers([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_headers([line | rest], acc) do
    with [name, value] <- String.split(line, ":", parts: 2),
         true <- name =~ @token,
         true <- value =~ @field_value do
      value = String.replace(value, ~r/\A[ \t]+|[ \t]+\z/, "")
      parse_headers(rest, [{String.downcase(name), value} | acc])
    else
      _ -> :error
    end
  end

  ## The ClientHello

  @doc """
  The host a TLS ClientHello names, if the bytes are one and the name is a
  host name: letters, digits, dots, dashes and underscores, as names are on
  the wire (others travel as punycode). Any other bytes name nothing, and
  the connection is passed through unread under its address.
  """
  @spec sni(binary()) :: String.t() | nil
  def sni(<<0x16, _major, _minor, length::16, record::binary-size(length), _::binary>>) do
    with <<1, _hlen::24, _version::16, _random::binary-32, sid_len, _sid::binary-size(sid_len),
           cs_len::16, _cs::binary-size(cs_len), comp_len, _comp::binary-size(comp_len),
           ext_len::16, extensions::binary-size(ext_len), _::binary>> <- record do
      server_name(extensions)
    else
      _ -> nil
    end
  end

  def sni(_data), do: nil

  defp server_name(<<0::16, length::16, data::binary-size(length), _rest::binary>>) do
    case data do
      <<_list::16, 0, name_length::16, name::binary-size(name_length), _::binary>> ->
        name = String.downcase(name)
        if name =~ ~r/\A[a-z0-9_]([a-z0-9_.-]{0,251}[a-z0-9_])?\z/, do: name

      _ ->
        nil
    end
  end

  defp server_name(<<_type::16, length::16, _::binary-size(length), rest::binary>>),
    do: server_name(rest)

  defp server_name(_), do: nil
end
