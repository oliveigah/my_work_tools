defmodule MWTClient.Sandbox.Egress.Driver do
  @moduledoc """
  What a protocol implements for MWT to read it, whatever transport
  carries it, and how a call's first bytes pick the driver that reads it.

  A driver exists so that what the VM does outside it is seen and decided
  request by request, the finest grain there is: it breaks a call into the
  requests it carries (an HTTP request, a database query), and each is
  judged on its own (let through, held for you on a card, refused) and
  kept in the log with what came back. A call no driver reads can only be
  decided whole, by where it goes (`Driver.Raw`). Putting a credential
  into a request is one use of that reading, the HTTP driver's today, not
  what a driver is for: a protocol with no value to carry is read for its
  requests alone.

  ## Calls, and the cores that carry them

  A call is what the VM sends to one destination over one transport: a
  TCP connection, or a UDP flow (the datagrams between one of the VM's
  ports and one destination, until neither side sends for a while). A
  core carries each call, in a process of its own, and runs a driver on
  it:

    * `MWTClient.Sandbox.Egress.Tcp` carries the VM's TCP connections:
      every one, as microsandbox hands them to MWT (an HTTP CONNECT each);
    * UDP has no core yet. microsandbox carries no UDP but DNS, which MWT
      answers itself (`MWTClient.Sandbox.Dns`). A core for it would sit
      beside `Tcp` (`Egress.Udp`) and run these same drivers;
      `ctx.transport` tells a driver which transport it is on.

  A driver holds none of what a core does. It is pure: what happens on
  the call comes in as a callback (bytes, a verdict, a side that ended, a
  deadline), and the driver answers with actions for the core to carry
  out. So whatever a driver does, the core keeps these, for every
  protocol at once:

    * nothing goes anywhere but the address and port the destination check
      approved: a driver says `{:connect, _}`, never where;
    * every byte a driver passes up as the VM's (`{:send, :host, _}`) is
      looked through for real values and misplaced placeholders before it
      goes, and counted for the firewall, which may stop it;
    * a grant that ends, or the VM isolated, ends the call;
    * a value goes into a request only as the core says
      (`handle_verdict/3`'s replacements), after the judge let it through.

  A driver keeps the rest: where its messages start and end, which of them
  are requests to judge (`{:judge, request}` before any byte of one goes
  up), what each one is (`MWTClient.Sandbox.Egress.Request`, and its card,
  `describe/1`), its answers, and what the log keeps of both
  (`{:done, _, _}`).

  ## A first draft

  This interface was written for two drivers, HTTP/1.1 and bytes passed
  through, on one transport, TCP. It isn't settled. When a protocol
  doesn't fit, change the interface rather than bend the driver around
  it, and propose the change with the driver: what the protocol needs,
  which callback, action or `ctx` field changes, and what that means for
  the drivers there are (`all/0`) and for `Tcp`. Keep the core's
  guarantees above whole: they are what MWT promises, whatever reads the
  bytes. Where it is known not to fit yet:

    * **Multiplexed protocols** (HTTP/2, gRPC, Kafka with several requests
      in flight) send each stream's text with `{:send, :host, bytes,
      stream}`, looked through with that stream's own list, and their
      framing with `{:frame, :host, bytes}`.
    * **Switching** mid-call (HTTP's Upgrade, STARTTLS in SMTP, IMAP or
      Postgres): a driver can't hand its call to another, nor ask the core
      to start TLS on it. HTTP/1.1 passes an upgraded connection on
      itself.
    * **Refusals** come as an HTTP status and MWT's JSON (`verdict/0`),
      which a driver for another protocol decodes.
    * **Values** go into HTTP/1.1 requests only: the judge finds a token
      grant's placeholders in an HTTP request (`MWTClient.Sandbox.Policy`),
      and `Tcp` reads a token grant's host with `Driver.Http1`, whatever
      its first bytes. A placeholder in another driver's request is a
      string out of place, which the core's look stops.
    * **What the log keeps** of a request (`{:done, _, exchange}`) is an
      HTTP exchange or nothing (`MWTClient.Sandbox.Exchange`).
    * **Datagrams**: each action says what it would mean on UDP, but no
      core has carried one yet.

  ## A call's life

    1. The core picks the driver (below) and calls `init/1`.
    2. It gives the driver the bytes it already read while picking: the
       VM's, then the host's, each through `handle_data/3`, as if they had
       just come.
    3. From then on, each event is one callback: bytes from a side the
       driver asked to read (`handle_data/3`), a verdict
       (`handle_verdict/3`), a side that ended (`handle_closed/3`), a
       deadline that passed (`handle_timeout/2`), or something the core
       stopped (`handle_cut/2`). They come one at a time, in the call's
       process, in the order they happen.
    4. Each callback answers `{actions, state}`. The core carries the
       actions out in order. What they send is written once the list is
       done, one write per side, the host's first, so a list the core
       cuts halfway sends nothing up.
    5. The call ends when the driver says `:close`, or when it waits for
       nothing: no side read and no verdict to come. The core closes both
       sides, drops the verdicts still to come, and reports the last bytes
       to the firewall.

  A raise in a callback ends the call at once, with no line in the log.
  The bytes are the VM's, so a driver answers what it can't make sense of
  in its protocol's own terms instead.

  ## Replacing

  A real value goes into a request only where the core says, and comes
  back to the VM as its placeholder. The core decides which value (the
  grant, its value, fetched or minted); the driver does the work in its
  protocol. An allowing verdict carries `replace`:

    * `request` - each `%{label, from, to, within}`: put `to` (the real
      value) wherever `from` (its placeholder) is, inside `within` only
      (for HTTP/1.1, the headers it travels in: a grant's carriers). Bytes
      the driver writes with a value in them go up as `{:write, :host, _}`,
      which the core counts but doesn't look through for values;
    * `answer` - each `%{label, from, to}`: wherever the answer holds one of
      `from` (the forms the value goes by), it must reach the VM as `to`
      (its placeholder), along with any form the driver itself wrote the
      value in (Basic's base64). Where it can't replace (inside a body
      whose length is said), the driver cuts the answer before the value
      goes, and says so (`{:found, label, :echo}`);
    * `values` - every value MWT holds (`MWTClient.Sandbox.Secrets`, nil
      for none), whatever the request carried: none may reach the VM in
      the answer. The driver looks through every answer it reads for them,
      holding back what could start one, and cuts the answer before one
      goes, the same way (`{:found, label, :echo}`). Absent, nothing more
      is looked for.

  ## Picking a driver

  After the destination check, the core reads the first bytes. TLS naming
  a host MWT reads is ended with MWT's certificate, offering the protocols
  the drivers speak (`alpn/0`); then:

    1. a protocol settled in that handshake picks the driver that speaks
       it;
    2. otherwise each driver's `detect/2`, in order, is shown the first
       bytes (decrypted, if TLS was ended): the first `:yes` takes the
       call, and `:more` makes the core wait for more bytes, a little;
    3. `MWTClient.Sandbox.Egress.Driver.Raw` says yes to anything, last:
       what no driver reads goes on as bytes.

  A server that speaks first leaves the client's first bytes empty; then
  `detect/2` is shown the server's (`ctx.first` is `:host`).
  """

  alias MWTClient.Sandbox.Describe
  alias MWTClient.Sandbox.Egress.Driver.{Http1, Http2, Raw}
  alias MWTClient.Sandbox.Egress.Request

  # What a protocol a driver offers (`alpn/1`) is called, for words.
  @protocol_names %{"h2" => "HTTP/2", "http/1.1" => "HTTP/1.1"}

  # HTTP/1.1 before HTTP/2: inside TLS MWT ends, it picks the first of
  # these a client offers, so only a client offering no HTTP/1.1 speaks
  # HTTP/2 to it (`Driver.Http2`).
  @drivers [Http1, Http2, Raw]

  @typedoc "One end of a call: the VM's client, or the host MWT connected to for it."
  @type side :: :vm | :host

  @typedoc """
  Why a call isn't read, for `ctx.why`'s `{:passed, reason}`, in words in
  `why/1`. Either you set it so (`:listed`: a host you set as Not read;
  `:off`: MWT reads only token grants' hosts), or MWT can't read it:

    * `:silent` - the client said nothing; the server speaks first;
    * `:not_tls` - plain bytes no driver reads;
    * `:no_name` - TLS to an address, naming no host for a certificate;
    * `{:protocols, names}` - TLS offering only protocols no driver speaks;
    * `:inside_tls` - TLS MWT ended, with nothing inside a driver reads.

  A new core adds the reasons it gives here, with their words.
  """
  @type passed ::
          :listed
          | :off
          | :silent
          | :not_tls
          | :no_name
          | {:protocols, [String.t()]}
          | :inside_tls

  @typedoc """
  What the core knows of the call a driver runs on, the same for the
  whole call:

    * `transport` - what carries it: `:tcp` (`Egress.Tcp`), or `:udp` once a
      core carries UDP. A driver for a protocol of one transport says `:no`
      to the other in `detect/2`;
    * `name` - the host the client named (TLS's SNI), or nil;
    * `ip`, `port` - where it goes, as the destination check approved;
    * `under` - the grant it went under;
    * `tls?` - whether MWT ended the VM's TLS. If so, the link to the host
      is TLS too, started again by MWT and verified for `name`, and the
      bytes the driver sees both ways are decrypted;
    * `alpn` - the protocol settled with the VM's client in that handshake,
      or nil;
    * `first` - who spoke first: `:vm`, or `:host` when the client waited
      for the server's greeting;
    * `linked?` - whether a link to the host is open already: the core made
      one while waiting to see who speaks first;
    * `why` - why MWT reads it: `:grant` (a token grant's host, for its
      value to go in), `:every_host`, or `{:passed, reason}` when it
      doesn't (`Driver.Raw`, `passed/0`);
    * `limit` - how much of each body the log keeps, in bytes (0: heads
      only);
    * `started` - when the call came, in monotonic milliseconds;
    * `options` - the core's options (`Tcp.run/3`), for the deadlines tests
      shorten.
  """
  @type ctx :: %{
          transport: :tcp | :udp,
          name: String.t() | nil,
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          under: String.t() | nil,
          tls?: boolean(),
          alpn: String.t() | nil,
          first: side(),
          linked?: boolean(),
          why: :grant | :every_host | {:passed, passed()},
          limit: non_neg_integer(),
          started: integer(),
          options: keyword()
        }

  @typedoc "A value to put into a request, where the core says (`Replacing`)."
  @type replacement :: %{label: term(), from: binary(), to: binary(), within: term()}

  @typedoc "A value that must reach the VM as its placeholder, whatever form it came in."
  @type back :: %{label: term(), from: [binary()], to: binary()}

  @typedoc """
  The judge's word on a request: let through, with what to replace in it
  and in its answer; refused, with MWT's answer (an HTTP status, which
  also says what kind of refusal, and MWT's JSON: `code`, `error`, `by`),
  which the driver writes in its own protocol's words; or answered by MWT
  itself (a credential endpoint), the same way.
  """
  @type verdict ::
          {:allow,
           %{
             required(:request) => [replacement()],
             required(:answer) => [back()],
             optional(:values) => MWTClient.Sandbox.Secrets.t() | nil
           }}
          | {:deny, 100..599, binary()}
          | {:reply, 100..599, binary()}

  @typedoc """
  What a driver asks the core to do. The core carries a list out in
  order, and what it sends goes in one write per side once the list is
  done (or before a `{:close, :host}` or `:close` in it):

    * `{:send, :vm, bytes}` - to the VM's client, counted;
    * `{:send, :host, bytes}` - to the host, as the VM's bytes: looked
      through first, across sends, so a value split over two is found
      too, and counted for the firewall. A value or a misplaced placeholder
      in them stops them, and everything else queued for the host, and
      `handle_cut/2` comes instead of the rest of the list;
    * `{:send, :host, bytes, stream}` - to the host, the VM's text of one
      stream of the call (`stream`, a term of the driver's: the request's
      `id` for its body, its WebSocket messages, its HTTP/2 stream): looked
      through as `{:send, :host, _}` is, but as a stream of its own, so
      what goes between two of its sends (frame headers, other streams)
      can't hide a value split across them; with the list its request's
      verdict gave, when `stream` is a judged request's `id`, or else the
      call's. Counted;
    * `{:frame, :host, bytes}` - to the host, framing the driver wrote
      itself, holding none of the VM's text: frame and message headers,
      lengths, stream ids, its own settings and pings. Counted, not looked
      through. A driver that frames the VM's text sends the text with
      `{:send, :host, _, stream}` and only the framing this way;
    * `{:look, bytes}` - the VM's bytes the driver refused, sending none of
      them: looked through for real values, so the firewall hears of one in
      a request MWT refused (one it couldn't read) as it would had it gone
      (a placeholder in them went nowhere: no leak). Found, what follows in
      the list is dropped and `handle_cut/2` comes instead;
    * `{:write, :host, bytes}` - to the host, bytes the driver wrote with a
      value the core had it put in (`Replacing`): counted, not looked
      through for values, since they are meant to hold one. Nothing else
      goes this way;
    * `{:read, side, timeout}` - one delivery from that side
      (`handle_data/3`), or `handle_timeout/2` after `timeout`
      milliseconds of nothing (`:infinity` for no deadline). Asked again
      while it is waiting, only the deadline changes. Ignored for the
      host while no link is open. A side is read only when asked: that is
      the backpressure;
    * `{:connect, %{alpn: protocols}}` - a link to the call's destination,
      replacing the one open (what was queued for that one is dropped, so
      connect first). TLS when MWT ended the VM's (`ctx.tls?`), offering
      `protocols` (`[]` for none). If it can't be made, the rest of the
      list is dropped and `handle_closed(:host, {:unreachable, reason}, _)`
      comes instead;
    * `{:judge, request}` - judge it (`MWTClient.Sandbox.Gate.authorize/2`),
      in a process of its own; the verdict comes to `handle_verdict/3`,
      by the request's id. Several may wait at once;
    * `{:done, request, exchange}` - the request ended (answered, refused or
      cut): the log keeps `exchange` with it (`MWTClient.Sandbox.Exchange`,
      or nil to keep nothing), and the firewall hears what the call
      carried since its last report. When the firewall says stop there,
      the call ends at once, with no callback: the request is over;
    * `{:found, label, :echo}` - a real value came back in an answer, and
      the driver cut it there: what is queued for the VM goes first (the
      answer up to the cut, the value put back as its placeholder), then the
      firewall hears of it, and may isolate the VM, closing every call;
    * `{:log, attrs}` - a line in the activity log
      (`MWTClient.Sandbox.Event`: `outcome`, `summary`, `host`, `port`,
      and for a call passed on `up`, `down` and `ms`);
    * `{:close, :host}` - what is queued for the host goes, then the link
      closes; the VM's side stays;
    * `:close` - the call ends: what is queued goes, both sides close, and
      nothing after it in the list is done.

  On UDP, once a core carries it, each send would be one datagram, and
  each read one datagram back.
  """
  @type action ::
          {:send, side(), iodata()}
          | {:send, :host, iodata(), term()}
          | {:frame, :host, iodata()}
          | {:look, iodata()}
          | {:write, :host, iodata()}
          | {:read, side(), timeout()}
          | {:connect, %{alpn: [String.t()]}}
          | {:judge, Request.t()}
          | {:done, Request.t(), map() | nil}
          | {:found, term(), :echo}
          | {:log, map()}
          | {:close, :host}
          | :close

  @typedoc """
  Why the core stopped what the driver passed up (`handle_cut/2`): a real
  value or a misplaced placeholder in it (`{:found, label}`), the
  firewall's count (`:firewall`), the VM isolated, or the grant the call
  went under ended.
  """
  @type cut :: {:found, term()} | :firewall | :isolated | :grant_ended

  @typedoc """
  How a side ended (`handle_closed/3`): closed, failed, couldn't be
  reached (`{:unreachable, reason}`, the host only), or closed under bytes
  the core was writing to it (`{:send_failed, reason}`, the host only).
  """
  @type ended :: :closed | {:error, term()} | {:unreachable, term()} | {:send_failed, term()}

  @typedoc "The driver's own, from `init/1` on: the core only hands it back."
  @type state :: term()

  @typedoc "What every callback but `alpn/0`, `detect/2` and `describe/1` answers."
  @type result :: {[action()], state()}

  @doc """
  The protocols it speaks inside TLS, by their ALPN names (`["http/1.1"]`,
  `["h2"]`), or `[]` for a protocol TLS doesn't name (Postgres, bytes
  passed on).

  Asked of every driver each time MWT ends a client's TLS (`alpn/1`): MWT
  offers the client all of them, and picks the first, in the drivers'
  order, that the client offers too; the one settled on picks its driver,
  without `detect/2`. So a protocol a driver lists after another driver's
  is spoken only by a client that offers none before it: HTTP/2
  (`Driver.Http2`) only by one offering no HTTP/1.1. List only what the
  driver reads whole. The same list every time.
  """
  @callback alpn() :: [String.t()]

  @doc """
  Whether it reads a call that began with `data`: `:yes` takes it, `:no`
  leaves it to the next driver, `:more` asks to see more bytes first.

  `data` is what came first from the side that spoke first (`ctx.first`):
  the VM's client, usually; the host's when the client waited (SSH, SMTP
  and MySQL servers greet first). It is decrypted when MWT ended the
  call's TLS (`ctx.tls?`), and may stop anywhere: one TCP segment of a
  longer message, or one datagram.

  Asked in the drivers' order (`all/0`), only when no protocol was settled
  in TLS (`alpn/0`) and the call isn't a token grant's host (read with
  `Driver.Http1`, for its value to go in):

    * inside TLS MWT ended, with up to 16 KiB and one second more for
      drivers that answer `:more`;
    * on plain bytes, once, with what came first, and only for a host MWT
      would read: not one you set as Not read.

  A driver asked before the one that says `:yes` holds the pick while it
  answers `:more`; once no more bytes will come, `:more` counts as `:no`
  (`pick/4`).

  Look at `ctx.transport` and `ctx.tls?`, not only the bytes: HTTP/1.1 is
  read only inside TLS MWT ended, where the certificate proves which host
  is there. Keep it cheap and pure, and never raise: it runs on the VM's
  bytes, for every call that reaches it.
  """
  @callback detect(data :: binary(), ctx()) :: :yes | :no | :more

  @doc """
  The call is now the driver's: the state it starts with, and what it asks
  for before any byte comes.

  `ctx` is what the core knows of the call (`ctx/0`). It doesn't change, so
  keep what you need of it in the state. Right after this, the core gives
  the driver the bytes it read while picking, through `handle_data/3`,
  whether or not the driver asked to read them: the VM's, then, when
  `ctx.linked?`, the host's. So `init/1` asks for what comes next:

    * a protocol where the client asks and the server answers waits for
      the VM: `{:read, :vm, timeout}` (`Driver.Http1`);
    * a protocol whose server speaks first, or bytes passed on, connects
      and reads both sides: `{:connect, %{alpn: []}}`, `{:read, :vm, _}`
      and `{:read, :host, _}` (`Driver.Raw`). With `ctx.linked?`, the link
      is open already, and connecting again would replace it.
  """
  @callback init(ctx()) :: result()

  @doc """
  Bytes from `side`: the VM's client's (`:vm`), or the host's (`:host`),
  decrypted when MWT ended TLS (`ctx.tls?`).

  A side is read only when the driver asked (`{:read, side, timeout}`),
  and each ask brings one delivery: ask again for more. That is the
  backpressure: a driver waiting for a verdict leaves the VM unread, and
  the VM's client waits. The only bytes a driver gets without asking are
  the first ones, right after `init/1`.

  On TCP, `data` is whatever the socket had: a message may come in pieces,
  or several in one, so keep what isn't whole in the state. On UDP, it
  would be one datagram, whole.

  The VM's bytes are requests: nothing of one goes up before it is judged.
  Once a request is whole enough to say what it is, answer
  `{:judge, request}`, keep its bytes, and wait for `handle_verdict/3`.
  Meanwhile the driver may go on reading the VM (the rest of a body, to
  send once it is let through), but it sends none of it.

  The host's bytes are answers: before they go to the VM
  (`{:send, :vm, _}`), each form of a value the verdict named becomes its
  placeholder (`Replacing`). Once an answer is over, `{:done, request,
  exchange}`.
  """
  @callback handle_data(side(), data :: binary(), state()) :: result()

  @doc """
  The judge's word on the request that `{:judge, request}` asked about, by
  its `id`.

  It comes once for each request judged, in the call's process, after any
  time at all: a request may wait minutes for you, and meanwhile every read
  the driver asked for goes on. If the call ends first, it never comes.

    * `{:allow, replace}` - send it. Put each of `replace.request` in
      (`Replacing`); connect if no link is open (`{:connect, _}`, first in
      the list); send it, with `{:write, :host, _}` for bytes holding a
      value and `{:send, :host, _}` for the rest; and read the answer
      (`{:read, :host, timeout}`). Keep `replace.answer` for that answer.
      A grant that turned off while you decided turns an allow into a
      deny before it gets here;
    * `{:deny, status, json}` - don't send it. Tell the VM, in the
      protocol's words, from MWT's JSON (`code` for programs, `error` for
      people, `by`), and `{:done, request, exchange}`;
    * `{:reply, status, json}` - MWT answers the request itself (a
      credential endpoint): the same, as the request's answer.

  On a deny or a reply, nothing of the request goes up.
  """
  @callback handle_verdict(id :: String.t(), verdict(), state()) :: result()

  @doc """
  `side` ended (`ended/0`):

    * `:closed` - the VM's client, or the host, closed;
    * `{:error, reason}` - its socket failed, or a write to the VM did;
    * `{:unreachable, reason}` - the host only: `{:connect, _}` failed (the
      address refused, TLS to it failed, its certificate isn't for the
      name). The rest of that action list was dropped, and this came
      instead. `unreachable/1` says why in words;
    * `{:send_failed, reason}` - the host only: a write to it failed, and
      what it carried is lost.

  The core notices a side closing only while it reads that side, so a
  driver that wants to hear the VM leave keeps `{:read, :vm, _}` asked.
  Once the host ended, its link is gone: `{:connect, _}` makes another.
  Once the VM ended, nothing more comes from it, and what is left is to
  finish (the log's line, `{:done, _, _}`) and `:close`.

  On UDP no side closes: a flow would end when the driver's own deadline
  says so (`handle_timeout/2`).
  """
  @callback handle_closed(side(), ended(), state()) :: result()

  @doc """
  A deadline passed: `{:read, side, timeout}` asked for bytes from `side`
  within `timeout` milliseconds, and none came.

  The side is still read, with no deadline now: bytes that come later reach
  `handle_data/3`, unless the driver closes. Each `{:read, side, timeout}`
  sets the side's deadline again, so a driver that wants a deadline from
  the last byte asks again after each. This is how a driver bounds what it
  waits for: a head that trickles in, an answer that never comes, a call
  idle for too long, the end of a UDP flow.
  """
  @callback handle_timeout(side(), state()) :: result()

  @doc """
  The core stopped what the driver passed up, and why (`cut/0`):

    * `{:found, label}` - a `{:send, :host, _}` held a real value, or a
      placeholder its grant doesn't send to this host. It didn't go, and
      neither did anything else queued for the host in that action list.
      MWT's firewall has been told;
    * `:firewall` - the firewall's count of the call's bytes said stop;
    * `:isolated` - MWT's firewall isolated the VM;
    * `:grant_ended` - the grant the call went under ended.

  From now on, nothing more of the call goes to the host: sends and writes
  to it are dropped. What is left is the VM's: tell it in the protocol's
  words, where a request still waits for its answer (HTTP/1.1 answers 403,
  with MWT's JSON), finish its log, and `:close`.
  """
  @callback handle_cut(cut(), state()) :: result()

  @doc """
  The card for one of its requests (`MWTClient.Sandbox.Describe`), shown
  when it waits for you:

    * `title` - the request, in a line;
    * `facts` - `{label, value}` pairs, worked out from its bytes;
    * `claims` - text the VM wrote (a title, a message), kept apart so it
      never reads as a fact;
    * `pattern` - what *Allow similar* lets through from then on: a string
      naming what requests like it share (`"tiny GET /users"`), or nil when
      the driver can't tell what the request does; its card then offers no
      *Allow similar*.

  The judge calls it outside the call's process, on the VM's bytes: it
  must describe what it can't make sense of rather than raise.
  """
  @callback describe(Request.t()) :: MWTClient.Sandbox.Describe.t()

  @doc "The drivers MWT reads with, in the order they are asked."
  @spec all() :: [module()]
  def all, do: @drivers

  @doc "The protocols MWT offers inside TLS it ends: every driver's, in order."
  @spec alpn([module()]) :: [String.t()]
  def alpn(drivers \\ @drivers), do: drivers |> Enum.flat_map(& &1.alpn()) |> Enum.uniq()

  @doc "The driver that speaks `protocol`, settled in a TLS handshake, or nil."
  @spec for_alpn(String.t() | nil, [module()]) :: module() | nil
  def for_alpn(nil, _drivers), do: nil
  def for_alpn(protocol, drivers), do: Enum.find(drivers, &(protocol in &1.alpn()))

  @doc """
  The driver for a call that began with `data`: `{:ok, driver}`, or
  `:more` while a driver asked before the one that would take it wants
  more bytes to tell. `final?` once no more will come: then `:more` is a
  no. `Raw` takes anything, so a list ending with it always picks one.
  """
  @spec pick(binary(), ctx(), [module()], boolean()) :: {:ok, module()} | :more | :none
  def pick(data, ctx, drivers \\ @drivers, final? \\ false) do
    Enum.reduce_while(drivers, :none, fn driver, seen ->
      case driver.detect(data, ctx) do
        :yes when seen == :more -> {:halt, :more}
        :yes -> {:halt, {:ok, driver}}
        :more when final? -> {:cont, seen}
        :more -> {:cont, :more}
        :no -> {:cont, seen}
      end
    end)
  end

  @doc "Why MWT didn't read a call (`passed/0`), in a few words for the log."
  @spec why(passed()) :: String.t()
  def why(:listed), do: "you set it as Not read (What MWT reads, Activity log)"
  def why(:off), do: "it is on neither list, and those aren't read (What MWT reads, Activity log)"
  def why(:silent), do: "the server speaks first"
  def why(:not_tls), do: "it isn't TLS"
  def why(:no_name), do: "TLS to an address, naming no host"
  def why(:inside_tls), do: "not HTTP inside its TLS · passed on decrypted, looked through"

  # The names are the VM's bytes: only visible ASCII is written out.
  def why({:protocols, alpn}) do
    names =
      Enum.map(alpn, &if(&1 =~ ~r/\A[\x21-\x7e]{1,40}\z/, do: &1, else: "a protocol unnamed"))

    "the client offered #{Enum.join(names, ", ")}, which MWT doesn't read"
  end

  @doc """
  The host a call goes to, for a request's `name` and the log: the name
  its client asked for, or, naming none, its address.
  """
  @spec host(ctx()) :: String.t()
  def host(%{name: name, ip: ip}), do: name || "#{:inet.ntoa(ip)}"

  @doc """
  Why a link to the host failed (`{:unreachable, reason}`), in a few
  words, for the log and for MWT's answers.
  """
  @spec unreachable(term()) :: String.t()
  def unreachable({:tls_alert, {:unknown_ca, _}}),
    do: "its certificate is from a CA this machine doesn't trust"

  def unreachable({:tls_alert, {:certificate_expired, _}}), do: "its certificate has expired"

  def unreachable({:tls_alert, {:certificate_required, _}}),
    do: "it wants a client certificate, which MWT has none of"

  def unreachable({:tls_alert, {alert, description}}) do
    if to_string(description) =~ "hostname_check_failed",
      do: "its certificate is for another name",
      else: "its TLS failed (#{String.replace(to_string(alert), "_", " ")})"
  end

  def unreachable({:protocol, offered}) do
    names = Enum.map_join(offered, " or ", &Map.get(@protocol_names, &1, &1))
    "it doesn't speak #{names}, and the client offered nothing else"
  end

  def unreachable({:options, _} = reason), do: inspect(reason)

  def unreachable(reason) when is_atom(reason) do
    case :inet.format_error(reason) do
      ~c"unknown POSIX error" -> to_string(reason)
      text -> to_string(text)
    end
  end

  def unreachable(reason), do: inspect(reason)

  @doc """
  TLS with the host failed as MWT started it again
  (`{:unreachable, {:tls_alert, _}}`): a certificate this machine's roots
  don't vouch for (an internal CA, one expired), or a host that wants a
  client certificate. It fails for being read, as a client refusing MWT's
  certificate does, so its line is `read_failed`: the host can be set as
  Not read, and then the VM's client judges it. The line for the log, and
  MWT's answer (JSON) for each request that was to go.
  """
  @spec tls_refused(ctx(), term()) :: {map(), String.t()}
  def tls_refused(%{name: name, port: port}, reason) do
    words = unreachable(reason)

    line = %{
      outcome: :read_failed,
      summary:
        "#{name}: MWT's TLS with the host failed (#{words}), checking it against " <>
          "this machine's roots · nothing went out",
      host: name,
      port: port
    }

    answer =
      Jason.encode!(%{
        code: "mwt_upstream_tls",
        error:
          "MWT could not make TLS with #{Describe.authority(%{host: name, port: port})}: " <>
            "#{words}. Tell the user: if this host's certificate is one they trust, they can " <>
            "have MWT pass it through unread (Don't read, on its line in MWT's activity log).",
        by: "MWT agent sandbox"
      })

    {line, answer}
  end
end
