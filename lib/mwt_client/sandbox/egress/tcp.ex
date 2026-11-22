defmodule MWTClient.Sandbox.Egress.Tcp do
  @moduledoc """
  The core for TCP: one connection the VM opened, from microsandbox's
  CONNECT to its close. The protocol inside is a driver's
  (`MWTClient.Sandbox.Egress.Driver`); everything a driver must not be
  trusted to do is here, the same for every protocol.

  Every call the VM makes through MWT is a TCP connection, since
  microsandbox carries no UDP but DNS (`MWTClient.Sandbox.Dns`). A core
  for UDP flows would sit beside this one and run the same drivers
  (`ctx.transport`); what is TCP's alone stays here: the CONNECT, who
  speaks first, TLS read from a stream and ended, the link's sockets.

    1. **The destination** is checked (`MWTClient.Sandbox.Gate`, from the
       view the sandbox published: the Internet, `refused`, `private` and
       network grants); the sandbox may hold it for your approval. With
       the Internet off and no grant opening the address, the connection
       may still reach a token grant's host, read: anything else closes.
    2. **The first bytes** are read: the client's, or, when it stays quiet
       a moment, the server's (SSH, SMTP, MySQL greet first). A TLS
       ClientHello names its host and the protocols it offers (`first/1`).
    3. **TLS is ended** with a certificate from MWT's own CA when MWT reads
       that host (`Gate.route/5`, `Gate.reading/3`): always a token grant's,
       for its value to go in; any other unless you set it as Not read.
       MWT offers the protocols its drivers speak. A client that refuses
       MWT's certificate is logged under the name, with why.
    4. **A driver is picked** (`Driver.pick/4`): by the protocol settled in
       TLS, or by the first bytes, decrypted. What none reads goes to
       `Driver.Raw`, as bytes. A network grant's connection MWT reads asks
       you request by request; one it doesn't, as a connection, after its
       first bytes, saying why.
    5. **The driver runs**, and this carries out what it asks for, in
       order: reads, sends, links, judgments, the log.

  What this keeps whatever the driver:

    * **One way out.** Every link goes to the address and port the
      destination check approved, through the grant's way out (`anchor`),
      never to a name resolved here. When the VM's TLS was ended, MWT starts
      TLS again to the host and verifies its certificate for the name the
      client asked for against this machine's roots
      (`MWTClient.Sandbox.Roots`): a request with a real value in it goes
      only to a server that proves it is that host.
    * **Looked through.** What a driver passes up as the VM's bytes is
      looked through for real values and misplaced placeholders
      (`MWTClient.Sandbox.Egress.Scanner`): for what is judged request by
      request, what the verdict says (every real value, the placeholders
      of grants that don't list the host); for bytes no driver reads, the
      firewall's list (`watch`), whatever their first byte says. Found, it
      never goes: the firewall hears of it, and the driver is told
      (`handle_cut/2`).
    * **Counted.** MWT's firewall (`MWTClient.Sandbox.Watch`) hears of
      each connection: its address and port with the destination check,
      the name it is for (`route`), and the bytes it carries, every 256 KiB
      sent up and once more at each request's end and at the close. The
      chunk that crosses a report waits for the answer, so a cut stops it
      before it goes.
    * **Judged.** Each request a driver reads is judged
      (`Gate.authorize/2`) in a process of its own, so a request waiting
      for you holds up only what its driver holds up. A verdict that lets
      it through says which values to put in and what to look for after;
      a request carrying a token grant's value holds its connection under
      that grant (`Gate.held_by/2`).
    * **Held.** A connection a grant let through closes as soon as the
      grant stops being live (`MWTClient.Sandbox.Server.Grants.close_ended/1`),
      and is looked at again when its time runs out (`{:grant_check, _,
      _}`). Each connection joins `MWTClient.Sandbox.Connections` under its
      identity, so isolating the VM closes them all at once.
    * **Deadlines.** The CONNECT is read whole within 10 seconds, and a
      driver waits for nothing without a deadline it set itself
      (`{:read, side, timeout}`): bytes that trickle can't hold a
      connection open. `MWTClient.Sandbox.Egress` caps how many are open.

  A side is read only when the driver asks (`{:read, _, _}`); what it
  asks to send goes in one write per side when it is done answering, so
  a request whose body the scanner stops never had its head go either.
  """

  require Logger

  alias MWTClient.Sandbox.{Destinations, Gate, Roots, Routes, Server}
  alias MWTClient.Sandbox.Egress.{Driver, Scanner}
  alias MWTClient.Sandbox.Egress.Driver.{Http1, Raw}

  @head_limit 64 * 1024
  # The whole of the CONNECT, however slowly it trickles.
  @connect_within 10_000
  # A ClientHello split over segments.
  @record_within 5_000
  # The driver's own buffer per socket. The default (a few KiB) costs a
  # tunnel about four times the CPU and a quarter of the speed.
  @buffer 262_144
  # How long the VM's client has to finish TLS with MWT's certificate.
  @handshake_within 10_000
  # microsandbox waits 10 seconds for the answer to a CONNECT.
  @answer_within 3_000
  # A client that speaks first does so at once; after this long MWT also
  # connects, in case the server speaks first.
  @client_first 100
  @server_first 1_400
  # A driver that wants more bytes to tell whether it reads a connection
  # gets this many, this long, at most.
  @detect_limit 16 * 1024
  @detect_within 1_000
  # A link to the host.
  @link_within 10_000
  @link_handshake_within 15_000

  @doc """
  Serves `client`, an accepted socket the caller owns.

  ## Options

    * `:drivers` - the drivers, in the order they are asked
      (`MWTClient.Sandbox.Egress.Driver.all/0` by default)
    * `:upstream` - `fn target -> {:ok, ssl_socket} | {:error, reason} end`,
      the link for a connection whose TLS MWT ended (`connect_tls/2` by
      default); tests point it elsewhere
    * `:upstream_tcp` - `fn target -> {:ok, tcp_socket} | {:error, reason} end`,
      the link for any other (`connect_tcp/1` by default)
    * `:answer_within` - how long, in milliseconds, the sandbox has to answer
      for a destination before the CONNECT is answered and the connection
      waits instead (3 seconds)
    * `:head_within` - how long, in milliseconds, the CONNECT (10 seconds)
      and a request's head (30 seconds, `Driver.Http1`) may take to arrive
      whole; tests make it short
    * `:body_within` - how long, in milliseconds, the start of a request's
      body may take to arrive (10 seconds, `Driver.Http1`)
  """
  def run(client, username, options \\ []) do
    started = System.monotonic_time(:millisecond)
    join(username)
    connect_by = within(Keyword.get(options, :head_within, @connect_within))

    with {:ok, head, rest} <- connect_head(client, "", connect_by),
         {:ok, host, port} <- connect_target(head),
         {:ok, ip} <- address(host),
         {:ok, reach} <- destination(client, username, ip, port, options),
         # A grant with a way out of its own keeps its connections on it.
         anchor = anchor(username, reach),
         target = %{ip: ip, port: port, anchor: anchor},
         {from_client, from_server, link} <- opening(client, rest, target, reach, options) do
      first = first(from_client)
      sni = with {:tls, hello} <- first, do: hello.name, else: (_ -> nil)
      under = if reach == :read_only, do: :read_only, else: elem(reach, 1)

      core = %{
        username: username,
        options: options,
        drivers: Keyword.get(options, :drivers, Driver.all()),
        target: Map.put(target, :name, sni),
        vm: client,
        vm_mod: :gen_tcp,
        link: nil,
        link_mod: :gen_tcp,
        driver: nil,
        state: nil,
        armed: %{vm: false, host: false},
        deadline: %{vm: nil, host: nil},
        out: %{vm: [], host: []},
        scanner: nil,
        scanners: %{},
        values: nil,
        meter: nil,
        up: 0,
        down: 0,
        judging: %{},
        judged?: false,
        cut?: false,
        ctx: %{
          transport: :tcp,
          name: sni,
          ip: ip,
          port: port,
          under: under,
          tls?: false,
          alpn: nil,
          first: :vm,
          linked?: false,
          why: nil,
          limit: Gate.body_limit(username),
          started: started,
          options: options
        }
      }

      case Gate.route(username, ip, port, sni, under) do
        # A token grant's host: read, for its value to go in.
        {:intercept, watch} ->
          discard(link)
          core |> watching(watch) |> intercept(from_client, :grant)

        {:tunnel, watch} ->
          core = watching(core, watch)

          case Gate.reading(username, under, first) do
            :read ->
              discard(link)
              intercept(core, from_client, :every_host)

            {:pass, why} ->
              case plain(core, from_client, from_server, why) do
                nil -> unread(core, reach, why, from_client, from_server, link)
                driver -> read_plain(core, driver, from_client, from_server, link)
              end
          end

        :refuse ->
          discard(link)
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

  ## The destination

  # Asks whether the VM may connect there (`MWTClient.Sandbox.Gate`):
  # `{:ok, {:open, grant_id}}`, `{:ok, :read_only}` (only a token grant's host, read by
  # MWT, while the Internet is off), or a refusal. An answer that comes at
  # once is passed on as it is: 200, or 403, which the VM sees as
  # "connection refused". A destination waiting for your approval takes
  # longer than microsandbox waits for a CONNECT, so then the 200 goes out
  # first and the open connection waits instead; a "no" closes it. A grant
  # that let it through holds it (`Gate.held_by/2`).
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

  # A network grant's that would ask you: asked once its first bytes say
  # whether MWT reads it (`asked/6`).
  defp reach(username, {:ask, grant}) do
    with :ok <- Gate.held_by(username, grant), do: {:ok, {:asking, grant}}
  end

  defp reach(_username, :read_only), do: {:ok, :read_only}
  defp reach(_username, {:deny, reason}), do: {:deny, reason}

  defp established(client),
    do: :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")

  defp anchor(_username, :read_only), do: nil
  defp anchor(username, {_open_or_asking, grant}), do: Gate.anchor(username, grant)

  ## The first bytes

  # Who speaks first, as `{from_client, from_server, link}`. Most clients
  # do, at once (a TLS ClientHello, an HTTP request), and their first bytes
  # decide between reading and passing through. When the client stays quiet
  # for a moment the server probably speaks first (SSH, SMTP, MySQL): MWT
  # connects and takes the first bytes from either side, instead of making
  # the server's greeting wait. `link` is the connection made on the way,
  # if any.
  #
  # A connection only a token grant's host may use is read or closed, never
  # passed through: MWT connects nowhere for it before the client spoke.
  defp opening(client, rest, _target, :read_only, _options) do
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

  # A network grant's connection that waits for you: nothing is connected to
  # before you decide, so a client that stays quiet (a server that greets
  # first: MySQL, SMTP) is asked about by its silence.
  defp opening(client, rest, _target, {:asking, _grant}, _options) do
    case rest do
      "" ->
        case :gen_tcp.recv(client, 0, @server_first) do
          {:ok, data} -> {complete_record(client, data), "", nil}
          {:error, :timeout} -> {"", "", nil}
          {:error, reason} -> {:error, reason}
        end

      rest ->
        {complete_record(client, rest), "", nil}
    end
  end

  defp opening(client, "", target, {:open, _grant}, options) do
    case :gen_tcp.recv(client, 0, @client_first) do
      {:ok, data} -> {complete_record(client, data), "", nil}
      {:error, :timeout} -> either(client, upstream_tcp(options).(target))
      {:error, reason} -> {:error, reason}
    end
  end

  defp opening(client, rest, _target, {:open, _grant}, _options),
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
      {tag, ^socket, _data_or_reason} when tag in [:tcp, :tcp_error, :ssl, :ssl_error] ->
        forget(socket)

      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
        forget(socket)
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

  ## What the first bytes are

  @typedoc "What a ClientHello says: the host it names, the protocols it offers (nil: none said)."
  @type hello :: %{name: String.t() | nil, alpn: [String.t()] | nil}

  @typedoc "A connection's first bytes, as `first/1` reads them."
  @type first :: {:tls, hello()} | :silent | :other

  @typedoc "Why MWT can't end the TLS a connection began with (`readable/2`)."
  @type unreadable :: :silent | :not_tls | :no_name | {:protocols, [String.t()]}

  @doc """
  What a connection's first bytes are: a TLS ClientHello (`{:tls, hello}`),
  nothing (`:silent`: the client waited for the server), or anything else.
  """
  @spec first(binary()) :: first()
  def first(""), do: :silent

  def first(<<0x16, _major, _minor, length::16, record::binary-size(length), _::binary>>) do
    with <<1, _hlen::24, _version::16, _random::binary-32, sid_len, _sid::binary-size(sid_len),
           cs_len::16, _cs::binary-size(cs_len), comp_len, _comp::binary-size(comp_len),
           ext_len::16, extensions::binary-size(ext_len), _::binary>> <- record do
      {:tls, extensions(extensions, %{name: nil, alpn: nil})}
    else
      _ -> :other
    end
  end

  def first(_data), do: :other

  @doc """
  The host a TLS ClientHello names, if the bytes are one and the name is a
  host name: letters, digits, dots, dashes and underscores, as names are on
  the wire (others travel as punycode). Any other bytes name nothing.
  """
  @spec sni(binary()) :: String.t() | nil
  def sni(data) do
    case first(data) do
      {:tls, hello} -> hello.name
      _other -> nil
    end
  end

  @doc """
  `:ok` when MWT can end the TLS a connection began with, for a driver to
  read inside, or why it can't: TLS naming a host (a bare address names
  nothing a certificate could be made for), offering no protocol or one a
  driver speaks (`MWTClient.Sandbox.Egress.Driver.alpn/1`). Bytes that
  aren't TLS, or silence, are for the drivers that read plain bytes
  (`Driver.pick/4`).
  """
  @spec readable(first(), [module()]) :: :ok | {:no, unreadable()}
  def readable(first, drivers \\ Driver.all())
  def readable(:silent, _drivers), do: {:no, :silent}
  def readable(:other, _drivers), do: {:no, :not_tls}
  def readable({:tls, %{name: nil}}, _drivers), do: {:no, :no_name}
  def readable({:tls, %{alpn: nil}}, _drivers), do: :ok

  def readable({:tls, %{alpn: alpn}}, drivers) do
    cond do
      Enum.any?(alpn, &(&1 in Driver.alpn(drivers))) -> :ok
      true -> {:no, {:protocols, alpn}}
    end
  end

  # The host name (`server_name`, 0) and the protocols (ALPN, 16). A name
  # is a host name as names are on the wire (others travel as punycode):
  # letters, digits, dots, dashes and underscores; any other names none.
  defp extensions(<<0::16, length::16, data::binary-size(length), rest::binary>>, hello),
    do: extensions(rest, %{hello | name: server_name(data)})

  defp extensions(<<16::16, length::16, data::binary-size(length), rest::binary>>, hello),
    do: extensions(rest, %{hello | alpn: protocols(data)})

  defp extensions(<<_type::16, length::16, _::binary-size(length), rest::binary>>, hello),
    do: extensions(rest, hello)

  defp extensions(_end, hello), do: hello

  defp server_name(<<_list::16, 0, length::16, name::binary-size(length), _::binary>>) do
    name = String.downcase(name)
    if name =~ ~r/\A[a-z0-9_]([a-z0-9_.-]{0,251}[a-z0-9_])?\z/, do: name
  end

  defp server_name(_other), do: nil

  defp protocols(<<length::16, list::binary-size(length)>>), do: protocol_list(list, [])
  defp protocols(_other), do: []

  defp protocol_list(<<length, protocol::binary-size(length), rest::binary>>, acc),
    do: protocol_list(rest, [protocol | acc])

  defp protocol_list(_end, acc), do: Enum.reverse(acc)

  ## Picking a driver

  # Ends the VM's TLS with MWT's certificate for the name, offering the
  # protocols the drivers speak, and picks the driver for what is inside:
  # a token grant's host is an HTTP API, so it is HTTP/1.1's whatever came
  # (what isn't HTTP is refused as such); otherwise the one speaking the
  # protocol settled, or the first bytes decide. Silence inside TLS is a
  # server that greets first (IMAP or SMTP over TLS): passed on decrypted.
  defp intercept(core, first, why) do
    %{vm: client, ctx: %{name: sni, port: port}} = core
    :ok = :gen_tcp.unrecv(client, first)

    offered =
      case Driver.alpn(core.drivers) do
        [] -> []
        protocols -> [alpn_preferred_protocols: protocols]
      end

    handshake =
      :ssl.handshake(
        client,
        Gate.leaf(core.username, sni) ++
          offered ++ [versions: [:"tlsv1.3", :"tlsv1.2"], active: false, mode: :binary],
        @handshake_within
      )

    case handshake do
      {:ok, tls} ->
        alpn =
          with {:ok, protocol} <- :ssl.negotiated_protocol(tls), do: protocol, else: (_ -> nil)

        core = %{
          core
          | vm: tls,
            vm_mod: :ssl,
            ctx: %{core.ctx | tls?: true, alpn: alpn, why: why}
        }

        cond do
          # A token grant's host is an HTTP API: HTTP/2 when the client
          # settled on it, HTTP/1.1 whatever else came.
          why == :grant ->
            start(core, Driver.for_alpn(alpn, core.drivers) || Http1, "", "")

          driver = Driver.for_alpn(alpn, core.drivers) ->
            start(core, driver, "", "")

          true ->
            case :ssl.recv(tls, 0, @server_first) do
              {:ok, data} ->
                case detect(core, data, within(@detect_within)) do
                  {Raw, data} ->
                    start(%{core | ctx: %{core.ctx | why: {:passed, :inside_tls}}}, Raw, data, "")

                  {driver, data} ->
                    start(core, driver, data, "")
                end

              {:error, :timeout} ->
                core = %{core | ctx: %{core.ctx | why: {:passed, :inside_tls}, first: :host}}
                start(core, Raw, "", "")

              {:error, _closed} ->
                :ssl.close(tls)
            end
        end

      {:error, reason} ->
        not_opened(core.username, sni, port, reason)
        :gen_tcp.close(client)
    end
  end

  # The driver for what came first inside TLS: `{driver, data}`, with more
  # bytes read while a driver asked for them, a little. What none reads
  # is passed on decrypted.
  defp detect(core, data, by) do
    case Driver.pick(data, core.ctx, core.drivers, false) do
      {:ok, driver} ->
        {driver, data}

      :more when byte_size(data) < @detect_limit ->
        case core.vm_mod.recv(core.vm, 0, left(by)) do
          {:ok, more} -> detect(core, data <> more, by)
          {:error, _} -> final(core, data)
        end

      _more_or_none ->
        final(core, data)
    end
  end

  defp final(core, data) do
    case Driver.pick(data, core.ctx, core.drivers, true) do
      {:ok, driver} -> {driver, data}
      :none -> {Raw, data}
    end
  end

  # A connection that isn't TLS, which a driver reads as it is: the
  # client's first bytes, or when it stayed quiet the server's. Only when
  # MWT would read the host (`Gate.reading/3` said it isn't TLS, not that
  # you set it as Not read).
  defp plain(core, from_client, from_server, why) when why in [:not_tls, :silent] do
    {data, first} = if from_client != "", do: {from_client, :vm}, else: {from_server, :host}
    ctx = %{core.ctx | first: first}

    case data != "" and Driver.pick(data, ctx, core.drivers, true) do
      {:ok, Raw} -> nil
      {:ok, driver} -> driver
      _none -> nil
    end
  end

  defp plain(_core, _from_client, _from_server, _why), do: nil

  defp read_plain(core, driver, from_client, from_server, link) do
    case link do
      {:ok, socket} ->
        core = %{core | link: socket, ctx: %{core.ctx | linked?: true, why: :every_host}}
        core = %{core | ctx: %{core.ctx | first: if(from_client == "", do: :host, else: :vm)}}
        start(core, driver, from_client, from_server)

      _none_or_failed ->
        start(%{core | ctx: %{core.ctx | why: :every_host}}, driver, from_client, "")
    end
  end

  # A connection MWT doesn't read: a network grant's that would ask you is
  # asked now, the name it asked for and why MWT can't read it on the card,
  # before anything is connected to; then its bytes go on as they are.
  defp unread(core, reach, why, from_client, from_server, link) do
    %{ip: ip, port: port, name: sni} = core.target

    with :ok <- asked(core.username, reach, ip, port, sni, why) do
      core = %{core | ctx: %{core.ctx | why: {:passed, why}}}

      case link do
        {:ok, socket} ->
          first = if from_client == "" and from_server != "", do: :host, else: :vm
          core = %{core | link: socket, ctx: %{core.ctx | linked?: true, first: first}}
          start(core, Raw, from_client, from_server)

        {:error, reason} ->
          Server.cast(
            core.username,
            {:log,
             %{
               outcome: :blocked,
               summary: "Could not connect: " <> Driver.unreachable(reason),
               host: sni || "#{:inet.ntoa(ip)}",
               port: port
             }}
          )

          :gen_tcp.close(core.vm)

        nil ->
          start(core, Raw, from_client, "")
      end
    else
      _denied ->
        discard(link)
        :gen_tcp.close(core.vm)
    end
  end

  # A network grant's that would ask you, or any whose host list asks
  # about or blocks a name it may be for (the Internet's included).
  defp asked(username, {open_or_asking, grant}, ip, port, sni, why) do
    seen = %{name: sni, why: Driver.why(why)}

    case Gate.unread(username, grant, ip, port, seen, open_or_asking == :asking) do
      {:ok, _grant} -> :ok
      denied -> denied
    end
  end

  defp asked(_username, :read_only, _ip, _port, _sni, _why), do: :ok

  # The VM's client gave up on TLS with MWT's certificate, so nothing went
  # out: logged by name, since the next try fails the same way and only
  # you can tell why (a client with a CA of its own, a pinned certificate,
  # a protocol MWT doesn't read).
  defp not_opened(username, sni, port, reason) do
    Server.cast(
      username,
      {:log,
       %{
         outcome: :read_failed,
         summary: "#{sni}: #{handshake_failure(reason)} · nothing went out",
         host: sni,
         port: port
       }}
    )
  end

  @doc """
  Why a client's TLS handshake with MWT failed, in a few words, from what
  `:ssl.handshake/3` answered.
  """
  @spec handshake_failure(term()) :: String.t()
  def handshake_failure({:tls_alert, {:unknown_ca, _}}),
    do:
      "the client doesn't trust MWT's certificate authority (a CA of its own, or a pinned certificate)"

  def handshake_failure({:tls_alert, {alert, _}})
      when alert in [:bad_certificate, :certificate_unknown, :unsupported_certificate],
      do: "the client refused MWT's certificate (a pinned certificate, or a CA of its own)"

  def handshake_failure({:tls_alert, {:no_application_protocol, _}}),
    do: "the client offered no protocol MWT reads"

  def handshake_failure({:tls_alert, {:protocol_version, _}}),
    do: "the client offered no TLS version MWT speaks (1.2 or 1.3)"

  def handshake_failure({:tls_alert, {alert, _}}),
    do: "the TLS handshake with MWT failed (#{String.replace(to_string(alert), "_", " ")})"

  def handshake_failure(:timeout), do: "the client didn't finish TLS with MWT in time"

  def handshake_failure(:closed),
    do: "the client closed the connection during TLS with MWT (a pinned certificate, often)"

  def handshake_failure(_other), do: "the TLS handshake with MWT failed"

  ## Running a driver

  # The driver takes the connection: what it asks for first, then the
  # first bytes from each side, as if they had just come.
  defp start(core, driver, from_vm, from_host) do
    if core.vm_mod == :gen_tcp, do: :inet.setopts(core.vm, buffer: @buffer)
    {actions, state} = driver.init(core.ctx)

    with {:cont, core} <- perform(%{core | driver: driver, state: state}, actions),
         {:cont, core} <- given(core, :vm, from_vm),
         {:cont, core} <- given(core, :host, from_host) do
      loop(core)
    else
      {:stop, core} -> stop(core)
    end
  end

  defp given(core, _side, ""), do: {:cont, core}
  defp given(%{link: nil} = core, :host, _data), do: {:cont, core}
  defp given(core, side, data), do: data_from(core, side, data)

  defp loop(core) do
    %{vm: vm, link: link, judging: judging} = core

    if waiting_for_nothing?(core) do
      Logger.debug("sandbox connection ended: its driver waits for nothing", system: :sandbox)
      stop(core)
    else
      receive do
        {tag, ^vm, data} when tag in [:tcp, :ssl] ->
          core |> unarmed(:vm) |> data_from(:vm, data) |> next()

        {tag, ^link, data} when tag in [:tcp, :ssl] ->
          core |> unarmed(:host) |> data_from(:host, data) |> next()

        {tag, ^vm} when tag in [:tcp_closed, :ssl_closed] ->
          core |> unarmed(:vm) |> ended(:vm, :closed) |> next()

        {tag, ^link} when tag in [:tcp_closed, :ssl_closed] ->
          core |> link_gone() |> ended(:host, :closed) |> next()

        {tag, ^vm, reason} when tag in [:tcp_error, :ssl_error] ->
          core |> unarmed(:vm) |> ended(:vm, {:error, reason}) |> next()

        {tag, ^link, reason} when tag in [:tcp_error, :ssl_error] ->
          core |> link_gone() |> ended(:host, {:error, reason}) |> next()

        {:verdict, ref, verdict} when is_map_key(judging, ref) ->
          core |> verdict(ref, verdict) |> next()

        # Its grant's time was up: it goes on only if the grant still is.
        {:grant_check, username, grant} ->
          case Gate.check(username, grant) do
            :ok -> loop(core)
            {:error, :grant_off} -> core |> cut(:grant_ended) |> next()
          end

        # From a link replaced or closed before.
        {tag, _socket, _data_or_reason} when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
          loop(core)

        {tag, _socket} when tag in [:tcp_closed, :ssl_closed] ->
          loop(core)
      after
        timeout(core) -> core |> timed_out() |> next()
      end
    end
  end

  defp next({:cont, core}), do: loop(core)
  defp next({:stop, core}), do: stop(core)

  defp waiting_for_nothing?(core),
    do: not core.armed.vm and not core.armed.host and core.judging == %{}

  defp data_from(core, side, data) do
    {actions, state} = core.driver.handle_data(side, data, core.state)
    perform(%{core | state: state}, actions)
  end

  defp ended(core, side, how) do
    {actions, state} = core.driver.handle_closed(side, how, core.state)
    perform(%{core | state: state}, actions)
  end

  defp timed_out(core) do
    now = System.monotonic_time(:millisecond)
    side = if core.deadline.vm && core.deadline.vm <= now, do: :vm, else: :host
    core = %{core | deadline: Map.put(core.deadline, side, nil)}
    {actions, state} = core.driver.handle_timeout(side, core.state)
    perform(%{core | state: state}, actions)
  end

  defp timeout(core) do
    case Enum.reject([core.deadline.vm, core.deadline.host], &is_nil/1) do
      [] -> :infinity
      deadlines -> max(Enum.min(deadlines) - System.monotonic_time(:millisecond), 0)
    end
  end

  # What a driver asked for, in order, then what it asked to send, one
  # write per side. Stopped short by a cut (`handle_cut/2`) or a link that
  # couldn't be made (`handle_closed/3`): what the driver says then is done
  # instead of the rest.
  defp perform(core, []), do: flush(core)

  defp perform(core, [action | rest]) do
    case act(core, action) do
      {:ok, core} ->
        perform(core, rest)

      {:stop, core} ->
        {:stop, core}

      {:cut, why, core} ->
        cut(core, why)

      {:failed, side, how, core} ->
        {actions, state} = core.driver.handle_closed(side, how, core.state)
        perform(%{core | state: state}, actions)
    end
  end

  defp act(core, {:send, :vm, bytes}) do
    {:ok,
     %{
       core
       | out: %{core.out | vm: [core.out.vm, bytes]},
         down: core.down + IO.iodata_length(bytes)
     }}
  end

  defp act(%{cut?: true} = core, {tag, :host, _bytes}) when tag in [:send, :write, :frame],
    do: {:ok, core}

  defp act(%{cut?: true} = core, {:send, :host, _bytes, _stream}), do: {:ok, core}

  defp act(core, {:send, :host, bytes}) do
    data = IO.iodata_to_binary(bytes)

    case scanned(core, data) do
      {:ok, core} -> up(core, data)
      {:found, label} -> {:cut, {:found, found(core, label)}, core}
    end
  end

  # The VM's text of one stream (a request's body, a WebSocket's messages,
  # an HTTP/2 stream), looked through as a stream of its own: what goes
  # between two of its sends (frame headers, other streams) can't hide a
  # value split across them. With the list its request's verdict gave, or
  # the connection's.
  defp act(core, {:send, :host, bytes, stream}) do
    data = IO.iodata_to_binary(bytes)

    scanner =
      Map.get_lazy(core.scanners, stream, fn ->
        Scanner.new(core.scanner && core.scanner.secrets)
      end)

    case Scanner.feed(scanner, data) do
      {:ok, _data, scanner} ->
        up(%{core | scanners: Map.put(core.scanners, stream, scanner)}, data)

      {:found, label} ->
        {:cut, {:found, found(core, label)}, core}
    end
  end

  defp act(core, {:write, :host, bytes}), do: up(core, bytes)
  defp act(core, {:frame, :host, bytes}), do: up(core, bytes)

  # The VM's bytes a driver refused: never sent, only looked through for
  # real values, so the firewall hears of one as it would had they gone.
  # A placeholder in them is no leak: it went nowhere.
  defp act(core, {:look, bytes}) do
    case MWTClient.Sandbox.Secrets.find(core.values, IO.iodata_to_binary(bytes)) do
      nil -> {:ok, core}
      label -> {:cut, {:found, found(core, label)}, core}
    end
  end

  defp act(core, {:read, side, timeout}), do: {:ok, arm(core, side, timeout)}

  defp act(core, {:connect, %{alpn: alpn}}) do
    core = close_link(core)

    case courier(core, alpn) do
      {:ok, socket, mod} -> {:ok, %{core | link: socket, link_mod: mod}}
      {:error, reason} -> {:failed, :host, {:unreachable, reason}, core}
    end
  end

  defp act(core, {:judge, request}) do
    parent = self()
    ref = make_ref()
    username = core.username

    pid =
      spawn_link(fn ->
        verdict =
          try do
            Gate.authorize(username, request)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:verdict, ref, verdict})
      end)

    {:ok, %{core | judging: Map.put(core.judging, ref, {pid, request}), judged?: true}}
  end

  # The exchange goes to the sandbox, which keeps it with the request's
  # events; the firewall hears what went up since its last report, and
  # may stop the connection there.
  defp act(core, {:done, request, exchange}) do
    if exchange, do: Server.cast(core.username, {:exchange, request.id, exchange})
    core = %{core | scanners: Map.delete(core.scanners, request.id)}

    case report(core) do
      {:ok, core} -> {:ok, core}
      {:cut, core} -> {:stop, core}
    end
  end

  # What is queued for the VM goes first: hearing of it, the firewall may
  # isolate the VM and close every connection at once, and what the driver
  # said before it (a head with the value put back as its placeholder) was
  # meant to arrive. The firewall hears of it either way.
  defp act(core, {:found, label, how}) do
    flushed = flush_vm(core)
    _cut = gate_found(core.username, label, core.ctx.name, how)

    case flushed do
      {:ok, core} -> {:ok, core}
      {:error, reason, core} -> {:failed, :vm, {:error, reason}, unarmed(core, :vm)}
    end
  end

  defp act(core, {:log, attrs}) do
    Server.cast(core.username, {:log, attrs})
    {:ok, core}
  end

  defp act(core, {:close, :host}) do
    case flush_host(core) do
      {:ok, core} -> {:ok, close_link(core)}
      {:error, _reason, core} -> {:ok, close_link(core)}
    end
  end

  defp act(core, :close), do: {:stop, core}

  # What the driver passes up, counted, and stopped when the firewall says
  # so: the chunk that crosses a report waits for the answer.
  defp up(core, bytes) do
    up = core.up + IO.iodata_length(bytes)

    case metered(core, up) do
      {:ok, core} ->
        {:ok, %{core | up: up, out: %{core.out | host: [core.out.host, bytes]}}}

      {:cut, core} ->
        {:cut, if(Gate.isolated?(core.username), do: :isolated, else: :firewall), core}
    end
  end

  # Nothing of what it was sending goes; the driver says what happens
  # instead, and nothing more of it goes up.
  defp cut(core, why) do
    core = %{core | out: %{core.out | host: []}, cut?: true}
    {actions, state} = core.driver.handle_cut(why, core.state)
    perform(%{core | state: state}, actions)
  end

  defp verdict(core, ref, verdict) do
    {{_pid, request}, judging} = Map.pop(core.judging, ref)
    core = %{core | judging: judging}

    case verdict do
      {:exit, _reason} ->
        {:stop, core}

      {:forward, replace, scan} ->
        case Gate.held_by(core.username, Map.get(scan, :grant)) do
          :ok ->
            scanner = Scanner.new(scan.out)

            core = %{
              core
              | scanner: scanner,
                scanners: Map.put(core.scanners, request.id, scanner)
            }

            told(core, request, {:allow, replace})

          {:error, :grant_off} ->
            json =
              Jason.encode!(%{
                code: "mwt_grant_off",
                error: "The grant turned off before this request went out.",
                by: "MWT agent sandbox"
              })

            told(core, request, {:deny, 403, json})
        end

      {:deny, status, json} ->
        told(core, request, {:deny, status, json})

      {:answer, status, json} ->
        told(core, request, {:reply, status, json})
    end
  end

  defp told(core, request, verdict) do
    {actions, state} = core.driver.handle_verdict(request.id, verdict, core.state)
    perform(%{core | state: state}, actions)
  end

  ## Sockets

  # A side read once more: active for one message, with a deadline unless
  # `:infinity`.
  defp arm(%{link: nil} = core, :host, _timeout), do: core

  defp arm(core, side, timeout) do
    unless core.armed[side] do
      case side do
        :vm -> active(core.vm, core.vm_mod)
        :host -> active(core.link, core.link_mod)
      end
    end

    deadline = if timeout == :infinity, do: nil, else: within(timeout)

    %{
      core
      | armed: Map.put(core.armed, side, true),
        deadline: Map.put(core.deadline, side, deadline)
    }
  end

  defp unarmed(core, side),
    do: %{
      core
      | armed: Map.put(core.armed, side, false),
        deadline: Map.put(core.deadline, side, nil)
    }

  defp active(socket, :gen_tcp), do: :inet.setopts(socket, active: :once)
  defp active(socket, :ssl), do: :ssl.setopts(socket, active: :once)

  # The link closed or failed under the core: gone, with what was to go
  # on it.
  defp link_gone(core) do
    core.link_mod.close(core.link)
    forget(core.link)
    %{unarmed(core, :host) | link: nil, out: %{core.out | host: []}}
  end

  defp close_link(%{link: nil} = core), do: core
  defp close_link(core), do: link_gone(core)

  # One write per side, the host's first.
  defp flush(core) do
    with {:host, {:ok, core}} <- {:host, flush_host(core)},
         {:vm, {:ok, core}} <- {:vm, flush_vm(core)} do
      {:cont, core}
    else
      {:host, {:error, reason, core}} ->
        core |> link_gone() |> ended(:host, {:send_failed, reason})

      {:vm, {:error, reason, core}} ->
        ended(unarmed(core, :vm), :vm, {:error, reason})
    end
  end

  defp flush_host(%{out: %{host: []}} = core), do: {:ok, core}
  defp flush_host(%{link: nil} = core), do: {:ok, %{core | out: %{core.out | host: []}}}

  defp flush_host(core) do
    out = core.out.host
    core = %{core | out: %{core.out | host: []}}

    case core.link_mod.send(core.link, out) do
      :ok -> {:ok, core}
      {:error, reason} -> {:error, reason, core}
    end
  end

  defp flush_vm(%{out: %{vm: []}} = core), do: {:ok, core}

  defp flush_vm(core) do
    out = core.out.vm
    core = %{core | out: %{core.out | vm: []}}

    case core.vm_mod.send(core.vm, out) do
      :ok -> {:ok, core}
      {:error, reason} -> {:error, reason, core}
    end
  end

  defp stop(core) do
    _ = flush_host(core)
    _ = flush_vm(core)
    if core.link, do: core.link_mod.close(core.link)
    core.vm_mod.close(core.vm)
    for {_ref, {pid, _request}} <- core.judging, do: Process.exit(pid, :kill)
    # What went up since the last report still counts.
    _ = report(core)
    :ok
  end

  ## The one way out

  # A link to the target: TLS when MWT ended the VM's, offering `alpn`.
  defp courier(core, alpn) do
    target = Map.put(core.target, :alpn, alpn)

    if core.ctx.tls? do
      with {:ok, socket} <- Keyword.get(core.options, :upstream, &connect_tls/1).(target),
           do: {:ok, socket, :ssl}
    else
      with {:ok, socket} <- upstream_tcp(core.options).(target), do: {:ok, socket, :gen_tcp}
    end
  end

  defp upstream_tcp(options), do: Keyword.get(options, :upstream_tcp, &connect_tcp/1)

  @doc """
  A TCP connection to `target` (`%{ip, port, anchor}`): the address and port
  the destination check approved, never a name resolved here (a name
  resolved again could lead elsewhere, a private address included), through
  the grant's way out, bound to its interface where the system allows
  (`MWTClient.Sandbox.Routes`). Passive and binary.
  """
  @spec connect_tcp(map()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_tcp(%{ip: ip, port: port} = target) do
    :gen_tcp.connect(
      ip,
      port,
      [:binary, active: false, nodelay: true, buffer: @buffer] ++
        Routes.options(Map.get(target, :anchor)),
      @link_within
    )
  end

  @doc """
  A TLS connection to `target` (`connect_tcp/1`), its certificate verified
  for the target's `name` against `roots` (this machine's, `Roots.file/0`),
  offering its `alpn` (none when it is empty). The address is the VM's
  choice, so the certificate is what makes it the host.
  """
  @spec connect_tls(map(), Path.t()) :: {:ok, :ssl.sslsocket()} | {:error, term()}
  def connect_tls(%{name: name} = target, roots \\ Roots.file()) when is_binary(name) do
    alpn = Map.get(target, :alpn, ["http/1.1"])

    with {:ok, tcp} <- connect_tcp(target) do
      options =
        [
          verify: :verify_peer,
          cacertfile: roots,
          server_name_indication: String.to_charlist(name),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          depth: 10,
          active: false,
          mode: :binary
        ] ++ if(alpn == [], do: [], else: [alpn_advertised_protocols: alpn])

      case :ssl.connect(tcp, options, @link_handshake_within) do
        {:ok, tls} ->
          {:ok, tls}

        {:error, reason} ->
          :gen_tcp.close(tcp)
          {:error, reason}
      end
    end
  end

  ## Looking through, and counting

  # The firewall's watch on the connection (`Gate.route/5`), made ready:
  # when the next report is due, and what bytes no driver judges must not
  # carry. Nil while the firewall is off.
  defp watching(core, nil), do: core

  defp watching(core, watch) do
    %{
      core
      | meter: %{
          destination: watch.destination,
          every: watch.report_every,
          next: watch.report_every,
          sent: {0, 0}
        },
        scanner: Scanner.new(Map.get(watch, :secrets)),
        values: Map.get(watch, :values)
    }
  end

  defp scanned(%{scanner: nil} = core, _data), do: {:ok, core}

  defp scanned(core, data) do
    case Scanner.feed(core.scanner, data) do
      {:ok, _data, scanner} -> {:ok, %{core | scanner: scanner}}
      {:found, label} -> {:found, label}
    end
  end

  # Tells the sandbox what was found where it doesn't belong: in a request
  # MWT judged, or in bytes none reads. It never went, whatever the
  # firewall does next.
  defp found(core, label) do
    if core.judged? do
      gate_found(core.username, label, core.ctx.name, :request)
    else
      destination = if core.meter, do: core.meter.destination, else: core.target.name
      gate_found(core.username, label, "#{destination}:#{core.ctx.port}", :plaintext)
    end

    label
  end

  defp gate_found(username, label, destination, how) do
    Gate.found(username, label, destination, how)
  catch
    :exit, _not_answering -> :cut
  end

  # `up` bytes sent once the next goes: reported when that crosses the
  # next report.
  defp metered(%{meter: %{every: every, next: next}} = core, up)
       when is_integer(every) and up >= next do
    case report(%{core | up: up}) do
      {:ok, core} -> {:ok, %{core | meter: %{core.meter | next: up + every}}}
      {:cut, core} -> {:cut, core}
    end
  end

  defp metered(core, _up), do: {:ok, core}

  # Tells the sandbox what went up and came back since the last report.
  defp report(%{meter: %{every: every} = meter} = core) when is_integer(every) do
    {sent_up, sent_down} = meter.sent

    if core.up > sent_up or core.down > sent_down do
      case Gate.upload(
             core.username,
             meter.destination,
             core.ctx.port,
             core.up - sent_up,
             core.down - sent_down
           ) do
        :ok -> {:ok, %{core | meter: %{meter | sent: {core.up, core.down}}}}
        :cut -> {:cut, core}
      end
    else
      {:ok, core}
    end
  catch
    :exit, _not_answering -> {:cut, core}
  end

  defp report(core), do: {:ok, core}

  ## Parsing

  # The time by which something must have arrived, and how long is left
  # of it.
  defp within(ms), do: System.monotonic_time(:millisecond) + ms
  defp left(by), do: max(by - System.monotonic_time(:millisecond), 0)

  # microsandbox's CONNECT, whole by `by`.
  defp connect_head(socket, acc, by) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] when byte_size(head) <= @head_limit ->
        {:ok, head, rest}

      [_partial] when byte_size(acc) <= @head_limit ->
        # A head that ends its lines with line feeds alone never ends for
        # this reader: said at once, instead of waiting for more.
        with :nomatch <- :binary.match(acc, "\n\n"),
             {:ok, data} <- :gen_tcp.recv(socket, 0, left(by)) do
          connect_head(socket, acc <> data, by)
        else
          {:error, reason} -> {:error, reason}
          {_at, _length} -> {:error, :bad_request}
        end

      _too_large ->
        {:error, :head_too_large}
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
end
