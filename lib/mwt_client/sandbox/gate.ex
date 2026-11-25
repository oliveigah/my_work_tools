defmodule MWTClient.Sandbox.Gate do
  @moduledoc """
  The network path's side of the sandbox: what the proxy
  (`MWTClient.Sandbox.Egress.Tcp`) and DNS (`MWTClient.Sandbox.Dns`)
  decide, in their own processes, without waiting on
  `MWTClient.Sandbox.Server` (QA L12).

  The server publishes a **view** of what those decisions read
  (`publish/1`): the grants, the firewall's settings and its
  isolation, what scanners look for, and the CA. It does so after every
  message that changed any of them, before its answer goes, so a call
  that turned a grant off returns once every new decision sees it off.
  Only the server writes it; everything else reads.

  Decided here, from the view: every lookup, every connection
  (`destination/3`), whether a connection is read or tunnelled
  (`route/5`), a tunnel's bytes (`upload/5`), leaf certificates, and every
  request MWT reads that needs neither you nor a real value
  (`authorize/2`). What the firewall counts goes to
  `MWTClient.Sandbox.Watch`, which does nothing else. What waits for you,
  and what puts a real value in a request, goes to the server: those
  calls are the only ones the network path makes to it, and they wait as
  long as you do. Logging is a cast.

  A connection a grant let through joins `MWTClient.Sandbox.Connections`
  under that grant (`held_by/2`), then reads the view again: the server
  closes what a grant let through after publishing that it stopped, so
  either it sees the connection or the connection sees the grant off. It
  also looks again when the grant's time runs out (`ends_at/2`), whether or
  not the server is busy then.

  A name a network grant lists is answered only while the grant is on
  (`lookup/2`), and the addresses MWT answered for it are kept here
  (`answered/4`): a connection goes under that grant only to one of them
  (`MWTClient.Sandbox.Policy`), and, when it is TLS, only with a name
  answered for that address (`route/5`). Kept beside the view, written by
  DNS and read by connections, never through the server.

  The view lives in one table, owned by this module's process (started
  with the application), so it outlives a restart of the server's. With no
  view (the identity locked, its server starting) everything is refused.
  """

  use GenServer

  alias MWTClient.Sandbox.{
    CertificateAuthority,
    Decision,
    Destinations,
    EventDetails,
    Firewall,
    Grant,
    HostLimits,
    Made,
    Placeholder,
    Policy,
    Reading,
    Routes,
    Secrets,
    Server,
    Watch
  }

  alias MWTClient.Sandbox.Egress.{Request, Tcp}
  alias MWTClient.Sandbox.Egress.Driver.{Http1, Http2}
  alias MWTClient.Sandbox.Server.{State, Values}

  @table __MODULE__
  # Every host MWT reads has its own certificate: enough for an agent's
  # day of hosts, each of 1 KiB or so.
  @max_leaves 1024
  @leaf_kept_seconds 7 * 24 * 3_600
  # A tunnel reports its bytes to the firewall every this many sent.
  @report_every 256 * 1024
  # How long an answer MWT gave for a covered name is held, in seconds,
  # whatever its TTL; and how many names one address keeps.
  @answer_least 60
  @answer_most 600
  # A trusted name's answer is kept this long (seconds), so a connection
  # claiming it is still matched after the VM's own DNS cache would hold it.
  @trusted_hold 3_600
  @names_per_address 64

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(Routes.table(), [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  ## The view

  @doc """
  Publishes the view of the server's `state` when what decisions read
  changed since the last one, and returns the state with what it was
  made from. Runs in the server's process only.
  """
  def publish(state) do
    inputs = {
      state.grants,
      Map.get(state, :firewall),
      state.values,
      for({id, {value, _at}} <- state.minted || %{}, do: {id, value}),
      state.ca,
      Map.get(state, :made, %{}),
      Map.get(state, :id_tokens, %{}),
      settings_body_kib(state),
      Map.get(state, :reading),
      Map.get(state, :locks, %{}),
      Map.new(Map.get(state, :networks, []), &{&1.id, &1.limits})
    }

    if Map.get(state, :gate) == inputs do
      state
    else
      version = (Map.get(state, :gate_version) || 0) + 1
      forms = Values.value_forms(state)
      made = state |> Map.get(:made, %{}) |> Map.values() |> Enum.map(&Made.unvalued/1)
      placeholders = placeholders(state.grants) ++ for(m <- made, do: {m.name, m.placeholder})

      view = %{
        version: version,
        grants: state.grants,
        # What you locked (`Grant.resource/1`): refused whatever the grants say.
        locks: elem(inputs, 9),
        # Each network's hosts it blocks, by network id
        # (`MWTClient.Sandbox.HostLimits`).
        limits: elem(inputs, 10),
        # The values made from the grants, without them.
        made: made,
        firewall: Map.get(state, :firewall) || Firewall.new(),
        forms: forms,
        secrets: Secrets.new(forms),
        placeholders: placeholders,
        tunnel_secrets:
          Secrets.new(for({name, p} <- placeholders, do: {{:placeholder, name}, [p]}) ++ forms),
        ca: state.ca,
        # How much of each body the log keeps (`MWTClient.Sandbox.Exchange`).
        body_limit: settings_body_kib(state) * 1024,
        # Which hosts the proxy reads (`MWTClient.Sandbox.Reading`).
        reading: Map.get(state, :reading) || MWTClient.Sandbox.Reading.new()
      }

      :ets.insert(@table, {{state.username, :view}, view})
      state |> Map.put(:gate, inputs) |> Map.put(:gate_version, version)
    end
  end

  defp settings_body_kib(state) do
    case Map.get(state, :settings) do
      %{log_body_kib: kib} when is_integer(kib) -> kib
      _none -> div(MWTClient.Sandbox.Exchange.body_limit(), 1024)
    end
  end

  @doc """
  How much of each body the log keeps for `username`, in bytes: your
  setting, or `Exchange.body_limit/0` with no view.
  """
  @spec body_limit(String.t()) :: non_neg_integer()
  def body_limit(username) do
    case view(username) do
      %{body_limit: limit} -> limit
      _none -> MWTClient.Sandbox.Exchange.body_limit()
    end
  end

  @doc "Forgets everything of `username`'s: their sandbox is gone, and so is what it allowed."
  def forget(username) do
    :ets.match_delete(@table, {{username, :_}, :_})
    :ets.match_delete(@table, {{username, :leaf, :_}, :_})
    :ets.match_delete(@table, {{username, :answered, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The view `username`'s server published last, or nil."
  def view(username) do
    case :ets.lookup(@table, {username, :view}) do
      [{_key, view}] -> view
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Every token grant's real value at hand, as the view last published has
  them (`MWTClient.Sandbox.Secrets`), or nil: what must not enter the VM.
  """
  def secrets(username) do
    case view(username) do
      %{secrets: secrets} -> secrets
      _none -> nil
    end
  end

  ## Names a network grant covers, and the addresses MWT answered

  @doc """
  Keeps the addresses MWT answered for a covered `name`, for `seconds`
  (an answer's TTL, held between 60 and 600): a connection to one of them
  goes under a grant that names it (`MWTClient.Sandbox.Destinations`).
  """
  def answered(username, name, addresses, seconds, most \\ @answer_most) do
    now = System.monotonic_time(:millisecond)
    until = now + min(max(seconds, @answer_least), most) * 1000
    name = name |> String.downcase() |> String.trim_trailing(".")

    for ip <- addresses do
      key = {username, :answered, Destinations.unmap(ip)}

      # Those gone stale go, and an address answered for many names (a
      # wildcard record) keeps the latest few.
      names =
        case :ets.lookup(@table, key) do
          [{_key, names}] -> Enum.reject(names, fn {n, at} -> n == name or at <= now end)
          [] -> []
        end

      :ets.insert(@table, {key, Enum.take([{name, until} | names], @names_per_address)})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Records a trusted name's answer, held longer than an ordinary one
  (#{div(@trusted_hold, 60)} minutes), so a TLS connection claiming that
  name is spared only when it goes to an address MWT resolved for it
  (`route/5`). A no-op for a name no trusted entry covers, or an answer
  with no address.
  """
  def remember_trusted(username, name, answer) do
    with %{firewall: firewall} <- view(username),
         true <- Firewall.trusted?(firewall, name),
         {[_ | _] = addresses, seconds} <- MWTClient.Sandbox.Dns.addresses(answer, name) do
      answered(username, name, addresses, seconds, @trusted_hold)
    end

    :ok
  end

  @doc """
  Records the answer for a name a grant over part of a network names (one
  over a host of the Internet), or any name while a network's limits take
  something away, so a connection to one of its addresses is judged by
  its names even when it names another host, or none (`Policy`'s
  `{:unread, _, _, _}`, a plain HTTP request's names). A no-op for any
  other name, or an answer with no address.
  """
  def remember_listed(username, name, answer) do
    with %{grants: grants} = view <- view(username),
         true <- Policy.remembers?(grants, Map.get(view, :limits, %{}), name, State.now()),
         {[_ | _] = addresses, seconds} <- MWTClient.Sandbox.Dns.addresses(answer, name) do
      answered(username, name, addresses, seconds)
    end

    :ok
  end

  # Whether MWT answered `name` for `ip` and still holds it.
  defp answered_name?(username, ip, name) do
    names = Map.get(answered_for(username, ip), Destinations.unmap(ip), [])
    String.downcase(name) in names
  end

  @doc "Every address MWT answered and still holds, with its names: for `mwt why`."
  def answered_map(username) do
    now = System.monotonic_time(:millisecond)

    for {{_, :answered, ip}, names} <- :ets.match_object(@table, {{username, :answered, :_}, :_}),
        fresh = for({name, until} <- names, until > now, do: name),
        fresh != [],
        into: %{},
        do: {ip, fresh}
  rescue
    ArgumentError -> %{}
  end

  @doc """
  What a decision on a connection to `ip` reads besides the view: the
  names MWT answered for it, and, when a network grant has a way out of
  its own (`Grant.anchor`), the interface this machine routes it through
  now (`MWTClient.Sandbox.Routes`).
  """
  def facts(username, grants, ip) do
    facts = %{answered: answered_for(username, ip)}

    if Enum.any?(grants, &(&1.kind == :network and &1.anchor != nil)),
      do: Map.put(facts, :via, Routes.via(ip)),
      else: facts
  end

  @doc "The interface a connection under the grant with `id` must leave through, or nil."
  def anchor(_username, nil), do: nil

  def anchor(username, id) do
    with %{} = view <- view(username),
         %Grant{anchor: anchor} <- Enum.find(view.grants, &(&1.id == id)) do
      anchor
    else
      _none -> nil
    end
  end

  @doc """
  What MWT answered and still holds for `ip`, as `%{ip => names}`: what
  `MWTClient.Sandbox.Policy` matches a name a network grant lists by.
  """
  def answered_for(username, ip) do
    ip = Destinations.unmap(ip)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, {username, :answered, ip}) do
      [{_key, names}] ->
        case for({name, until} <- names, until > now, do: name) do
          [] -> %{}
          fresh -> %{ip => fresh}
        end

      [] ->
        %{}
    end
  rescue
    ArgumentError -> %{}
  end

  ## Isolation

  @doc """
  Marks the VM isolated at once, ahead of the server's own record of it:
  the firewall's watch, or the server, on a finding that isolates.
  """
  def trip(username, finding), do: :ets.insert(@table, {{username, :tripped}, finding})

  @doc "Clears the mark: the server released the VM."
  def untrip(username) do
    :ets.delete(@table, {username, :tripped})
    count_refused_from_zero(username)
  rescue
    ArgumentError -> true
  end

  @doc "Starts counting what is refused while isolated again, from zero."
  def count_refused_from_zero(username) do
    :ets.insert(@table, {{username, :refused}, 0})
  rescue
    ArgumentError -> true
  end

  @doc "Whether the VM is isolated, by the view or the mark."
  def isolated?(username, view \\ nil) do
    view = view || view(username)

    is_nil(view) or Firewall.isolated?(view.firewall) or
      :ets.member(@table, {username, :tripped})
  rescue
    ArgumentError -> true
  end

  @doc "Counts one more thing refused while the VM is isolated."
  def refused(username) do
    :ets.update_counter(@table, {username, :refused}, 1, {{username, :refused}, 0})
  rescue
    ArgumentError -> 0
  end

  @doc "How many things were refused while the VM is isolated."
  def refused_count(username) do
    case :ets.lookup(@table, {username, :refused}) do
      [{_key, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  ## Grants that hold connections

  @doc """
  Whether the grant with `id` lets uses through now: on by the clock, and
  the VM not isolated.
  """
  def live?(username, id) do
    with %{} = view <- view(username),
         false <- isolated?(username, view),
         %Grant{} = grant <- Enum.find(view.grants, &(&1.id == id)) do
      Grant.on?(grant, DateTime.utc_now())
    else
      _ -> false
    end
  end

  @doc """
  When the grant with `id` stops being live by the clock, as far as the
  view says now: `:never` while it is on until turned off, the moment
  otherwise, `:now` when it isn't live.
  """
  def ends_at(username, id) do
    now = DateTime.utc_now()

    with %{} = view <- view(username),
         false <- isolated?(username, view),
         %Grant{} = grant <- Enum.find(view.grants, &(&1.id == id)),
         true <- Grant.on?(grant, now) do
      grant.expires_at || :never
    else
      _ -> :now
    end
  end

  @doc """
  Joins what the grant with `id` let through, and reads the view again:
  `:ok` while it still lets this connection, `{:error, :grant_off}` once
  it doesn't. A grant with an end in sight sends the caller
  `{:grant_check, username, id}` then (`check/2`). `nil` is no grant.
  """
  def held_by(_username, nil), do: :ok

  def held_by(username, id) do
    try do
      Registry.register(MWTClient.Sandbox.Connections, {username, id}, nil)
    rescue
      ArgumentError -> :ok
    end

    check(username, id)
  end

  @doc """
  Looks at the grant again, and sets the next look for when its time runs
  out: `:ok`, or `{:error, :grant_off}` to close.
  """
  def check(username, id) do
    case ends_at(username, id) do
      :now ->
        {:error, :grant_off}

      :never ->
        :ok

      %DateTime{} = at ->
        ms = max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0) + 50
        Process.send_after(self(), {:grant_check, username, id}, ms)
        :ok
    end
  end

  ## Lookups

  @doc """
  Whether a name may be looked up: `:ok`, `:refuse`, `{:refuse,
  :internet_off}` for a name of the Internet no grant that is on gives,
  `{:refuse, {:host_blocked, network, entry}}` for one the Internet
  blocks, or `{:refuse, {:excepted, grant, entry}}` for one a grant
  leaves out and no other grant that is on names. A name a network grant other than the Internet's lists is
  `{:covered, grant}` while one that lists it is on (asked of its
  resolver, and what is answered kept, `answered/4`), and `{:refuse,
  {:grant_off, grant}}` otherwise. A name carrying a real value is never
  passed on, nor logged.
  """
  def lookup(username, name) do
    view = view(username)
    lower = name |> String.downcase() |> String.trim_trailing(".")

    # A grant that leaves the name out (`Grant.except`) doesn't cover it.
    {covering, left_out} =
      view
      |> covering(name)
      |> Enum.split_with(&is_nil(MWTClient.Sandbox.Network.excepted(&1, [lower])))

    internet_out =
      case view && Enum.find(view.grants, &Grant.internet?/1) do
        %Grant{} = internet ->
          entry = MWTClient.Sandbox.Network.excepted(internet, [lower])
          if entry && Grant.on?(internet, State.now()), do: {internet, entry}

        nil ->
          nil
      end

    cond do
      isolated?(username, view) ->
        refused(username)
        :refuse

      grant = value_in_name(view, name) ->
        _verdict = Watch.observe(username, {:value, grant, nil, :lookup})
        :refuse

      # A name a network grant covers is answered only while one that
      # covers it is on; by its resolver, when it names one, and what it
      # answers is kept. One only grants that are off cover isn't sent to
      # the Internet's resolver either: it is a name of their network, and
      # the refusal names the grant to ask for.
      covering != [] ->
        case Enum.find(covering, &live?(username, &1.id)) do
          nil ->
            {:refuse, {:grant_off, hd(covering)}}

          live ->
            case Watch.observe(username, {:lookup, name, view.placeholders}) do
              :pass -> {:covered, live}
              _refused -> :refuse
            end
        end

      # Left out by every grant of its network that names it.
      left_out != [] ->
        grant = hd(left_out)
        {:refuse, {:excepted, grant, MWTClient.Sandbox.Network.excepted(grant, [lower])}}

      # A host the Internet blocks: never looked up.
      HostLimits.blocked?(internet_limits(view), name) and
          HostLimits.rule(internet_limits(view), name) != nil ->
        {:refuse, {:host_blocked, "internet", HostLimits.rule(internet_limits(view), name).host}}

      # One the Internet's grant leaves out, which no grant over part of
      # the Internet that is on names: never looked up either.
      internet_out != nil and not internet_part_names?(view.grants, name) ->
        {internet, entry} = internet_out
        {:refuse, {:excepted, internet, entry}}

      not internet?(view) and not internet_part_names?(view.grants, name) ->
        {:refuse, :internet_off}

      true ->
        case Watch.observe(username, {:lookup, name, view.placeholders}) do
          :pass -> :ok
          _refused -> :refuse
        end
    end
  end

  ## Connections

  @doc """
  The grant that lets a lookup of `name` through on the Internet, as
  `lookup/2` says `:ok`: the Internet's grant while it is on, else one over
  part of the Internet that names it; nil when neither is there. For the
  activity log's line (`MWTClient.Sandbox.Decision`).
  """
  @spec opened_by(String.t(), String.t()) :: Grant.t() | nil
  def opened_by(username, name) do
    grants = view(username).grants
    lower = name |> String.downcase() |> String.trim_trailing(".")
    now = State.now()

    Enum.find(grants, &(Grant.internet?(&1) and Grant.on?(&1, now))) ||
      Enum.find(grants, fn g ->
        g.kind == :network and MWTClient.Sandbox.Network.part?(g) and
          MWTClient.Sandbox.Network.id_of(g) == "internet" and Grant.on?(g, now) and
          Policy.remembers?([g], %{}, lower, now)
      end)
  end

  @doc """
  Whether the VM may connect to `ip` and `port`: `{:ok, grant_id}`, the
  grant it goes under; `{:ask, grant_id}`, a network grant's that would
  ask you, asked only once the connection's first bytes say whether MWT
  can read it (`ask_connection/4`): read, each request is asked instead;
  or `{:deny, why}`. The Internet's are asked the same way, once its
  first bytes came: set to ask, or for an address whose names include a
  host its network may block.
  """
  def destination(username, ip, port) do
    view = view(username)

    if isolated?(username, view) do
      refused(username)
      {:deny, "Refused by MWT's firewall"}
    else
      decision =
        Policy.decide(
          view.grants
          |> Policy.snapshot([], Map.get(view, :locks, %{}), Map.get(view, :limits, %{}))
          |> Map.merge(facts(username, view.grants, ip)),
          {:connection, ip, port},
          State.now()
        )

      class =
        case decision do
          {:allow, %Grant{internet: true}, _allowance, _about} -> :public
          {:ask, %Grant{internet: true}, _about} -> :public
          {:refuse, :internet_off} -> :public
          {:refuse, _reason} -> :refused
          _granted -> :granted
        end

      case Watch.observe(username, {:connect, "#{:inet.ntoa(ip)}", port, class}) do
        :pass -> connect(username, decision, ip, port)
        _refused -> {:deny, "Refused by MWT's firewall"}
      end
    end
  end

  @doc """
  Whether a request MWT built from a fixed call may connect to `ip` and
  `port` (`MWTClient.Sandbox.Egress.FixedCall`): `{:ok, grant_id}`, under
  the fixed call, or `{:deny, why}`. Which network grant lets its host's
  request out, as it would the agent's own, was decided with the call by
  name (`Policy.reach/3`), and is again as it is authorized; here, every
  check of the address stands, as for the VM's own connections:
  isolated, refused; this machine or a reserved address, refused; a host
  on the Internet at an address that isn't public (a name moved onto your
  network), refused. The firewall hears of it as of any connection.
  """
  def fixed_destination(username, ip, port, fixed) do
    view = view(username)
    shown = "#{:inet.ntoa(ip)}"
    class = Destinations.classify(ip, Destinations.host_addresses(), Routes.networks())

    blocked = fn summary ->
      log(username, %{
        outcome: :blocked,
        summary: "#{fixed.host} at #{shown} · fixed call #{fixed.name} · #{summary}",
        host: fixed.host,
        port: port,
        grant_id: fixed.grant_id
      })

      {:deny, summary}
    end

    cond do
      isolated?(username, view) ->
        refused(username)
        {:deny, "Refused by MWT's firewall"}

      class == :refused ->
        blocked.("this machine or a reserved address, always refused")

      fixed.network == "internet" and class != :public ->
        blocked.("an address on your network, which a host on the Internet never goes to")

      true ->
        watched = if class == :public, do: :public, else: :granted

        case Watch.observe(username, {:connect, shown, port, watched}) do
          :pass -> {:ok, fixed.grant_id}
          _refused -> {:deny, "Refused by MWT's firewall"}
        end
    end
  end

  defp connect(username, decision, ip, port) do
    case decision do
      {:allow, %Grant{internet: true} = grant, _allowance, _about} ->
        {:ok, grant.id}

      {:allow, grant, _allowance, _about} ->
        Server.cast(username, {:used, grant.id})
        {:ok, grant.id}

      {:refuse, {:grant_off, grant}} ->
        log(username, %{
          outcome: :blocked,
          summary: "#{:inet.ntoa(ip)}:#{port} · #{grant.name} would open it, and is off",
          host: "#{:inet.ntoa(ip)}",
          port: port,
          grant_id: grant.id
        })

        {:deny, "#{grant.name} would open it, and is off: ask for it to be turned on"}

      {:refuse, {:locked, resource, grant}} ->
        log(username, %{
          outcome: :blocked,
          summary: "#{:inet.ntoa(ip)}:#{port} · locked by you",
          host: "#{:inet.ntoa(ip)}",
          port: port,
          grant_id: grant.id
        })

        {:deny, MWTClient.Sandbox.Resource.locked_words(resource)}

      {:refuse, reason} ->
        summary =
          case reason do
            :reserved -> "This machine or a reserved address · always refused"
            :internet_off -> "Public address with no grant on over the Internet"
            _private -> "Private address with no network grant on"
          end

        log(username, %{
          outcome: :blocked,
          summary: summary,
          host: "#{:inet.ntoa(ip)}",
          port: port
        })

        {:deny, summary}

      # Asked once the first bytes say whether MWT reads it, the Internet's
      # too: an address alone is nothing to decide on.
      {:ask, grant, _about} ->
        {:ask, grant.id}
    end
  end

  @doc """
  Whether a connection MWT can't read goes on: one a network grant would
  ask you about (`destination/3` said `{:ask, grant_id}`), or one under a
  grant whose host list asks about or blocks a name it may be for. What it
  saw (`seen`: the name it asked for, why MWT can't read it) decides with
  the names MWT's DNS answered for the address (`Policy`'s `{:unread, _,
  _, _}`), and goes on the card when you are asked. `{:ok, grant_id}` or
  `{:deny, why}`, as long as you take.

  `under` is the grant it went under. One the destination check let
  through, whose grant has no entry that asks or blocks, goes on without
  another look.
  """
  def unread(username, under, ip, port, seen, asking?) do
    view = view(username)
    grant = Enum.find(view.grants, &(&1.id == under))

    cond do
      is_nil(grant) ->
        {:ok, under}

      not asking? and not judged_by_name?(view, grant) ->
        {:ok, under}

      true ->
        snapshot =
          view.grants
          |> Policy.snapshot([], Map.get(view, :locks, %{}), Map.get(view, :limits, %{}))
          |> Map.merge(facts(username, view.grants, ip))
          |> Map.put(:answered, answered_for(username, ip))

        case Policy.decide(snapshot, {:unread, ip, port, [seen[:name]]}, State.now()) do
          {:allow, %Grant{} = grant, _allowance, _about} ->
            if not grant.internet, do: Server.cast(username, {:used, grant.id})
            {:ok, grant.id}

          {:refuse, {:host_blocked, network, entry}} ->
            summary = blocked_words(network, entry, seen[:name] || "#{:inet.ntoa(ip)}")

            log(username, %{
              outcome: :blocked,
              summary: summary,
              host: seen[:name] || "#{:inet.ntoa(ip)}",
              port: port,
              grant_id: grant.id
            })

            {:deny, summary}

          {:refuse, {:excepted, by, entry}} ->
            summary = excepted_words(by, entry, seen[:name] || "#{:inet.ntoa(ip)}")

            log(username, %{
              outcome: :blocked,
              summary: summary,
              host: seen[:name] || "#{:inet.ntoa(ip)}",
              port: port,
              grant_id: by.id
            })

            {:deny, summary}

          {:refuse, _reason} ->
            {:deny, "Refused"}

          {:ask, _grant, _about} ->
            Server.call(username, {:destination, ip, port, seen}, :infinity)
        end
    end
  end

  @doc """
  Why a use of a host its network blocks was refused, in words for the log:
  by the entry naming it, or by the network's default.
  """
  @spec blocked_words(String.t(), String.t() | :default, String.t()) :: String.t()
  def blocked_words(network, :default, host),
    do: "#{host} isn't among the hosts #{network} reaches · blocked by you"

  def blocked_words(network, entry, host),
    do: "#{host} is blocked on #{network} (#{entry}) · blocked by you"

  @doc """
  Why a use of a host a network grant leaves out (`Grant.except`), and no
  other grant covers, was refused, in words for the log.
  """
  @spec excepted_words(Grant.t(), String.t(), String.t()) :: String.t()
  def excepted_words(grant, entry, host),
    do: "#{host} · #{grant.name} leaves out #{entry}, and no other grant on covers it"

  @doc """
  What becomes of a connection once its first bytes named a host (`sni`)
  or didn't: `{:intercept, watch}` (read by MWT), `{:tunnel, watch}`
  (passed through), or `:refuse`. `watch` is what the firewall hears of
  what goes up (`upload/5`), nil while it is off: for a tunnel, every
  byte, looked through for placeholders and real values too; for a read
  connection, its requests, which MWT looks through itself, and what to
  look for should what is inside its TLS not be HTTP. A tunnel may still
  be read, as MWT reads every host it can (`reading/3`).
  `under` is the grant the connection went under (`destination/3`). One a network
  grant opened by a name it lists goes on, when it is TLS, only with a
  name MWT answered for that address and the grant covers, read or not:
  an address shared by many names (a load balancer, an ingress) opens for
  the grant's names only.
  """
  def route(username, ip, port, sni, under \\ nil, fixed \\ nil) do
    view = view(username)
    destination = sni || "#{:inet.ntoa(ip)}"

    cond do
      isolated?(username, view) ->
        refused(username)
        :refuse

      sni && Firewall.trusted?(view.firewall, sni) && not answered_name?(username, ip, sni) ->
        log(username, %{
          outcome: :blocked,
          summary: "#{sni} to #{:inet.ntoa(ip)}, an address MWT didn't resolve for it · refused",
          host: destination,
          port: port
        })

        :refuse

      sni && observe(username, {:host, sni, port}) != :pass ->
        :refuse

      observe(username, {:upload, destination, port, 0, 0}) != :pass ->
        :refuse

      # A fixed call's request is read, always: its values go in there.
      fixed != nil ->
        {:intercept, tunnel_watch(view, ip, destination)}

      grant = name_mismatch(username, view, under, ip, port, sni) ->
        log(username, %{
          outcome: :blocked,
          summary:
            "#{sni} isn't a name MWT answered for this address under #{grant.name} · refused",
          host: destination,
          port: port
        })

        :refuse

      sni && Policy.reads?(view.grants, sni) ->
        {:intercept, tunnel_watch(view, ip, destination)}

      true ->
        {:tunnel, tunnel_watch(view, ip, destination)}
    end
  end

  # The network grant `id` when it opened `ip` by a name it lists and `sni`
  # isn't one MWT answered for that address and the grant covers; nil when
  # the name fits, there is none, or an address the grant lists opened it.
  defp name_mismatch(_username, _view, _id, _ip, _port, nil), do: nil

  defp name_mismatch(username, view, id, ip, port, sni) when is_binary(id) do
    case Enum.find(view.grants, &(&1.id == id)) do
      %Grant{kind: :network, internet: false} = grant ->
        sni = String.downcase(sni)
        names = Map.get(answered_for(username, ip), Destinations.unmap(ip), [])
        answered = if sni in names, do: %{Destinations.unmap(ip) => [sni]}, else: %{}

        fits? =
          Enum.any?(grant.destinations, fn text ->
            case Destinations.parse(text) do
              {:ok, spec} -> Destinations.matches?(spec, ip, port, fn _ -> [] end, answered)
              {:error, _} -> false
            end
          end)

        if fits?, do: nil, else: grant

      _other ->
        nil
    end
  end

  defp name_mismatch(_username, _view, _under, _ip, _port, _sni), do: nil

  # What a tunnel reports as its bytes flow: its uploads to a public
  # address, unless the firewall is off or trusts the destination (a private
  # one you opened with a network grant isn't counted); and the placeholders
  # and real values it must not carry.
  defp tunnel_watch(view, ip, destination) do
    if view.firewall.enabled do
      counted? =
        Destinations.classify(ip, [], Routes.networks()) == :public and
          not Firewall.trusted?(view.firewall, destination)

      %{
        destination: destination,
        report_every: if(counted?, do: @report_every),
        secrets: view.tunnel_secrets,
        # Real values alone: what a request MWT refused is looked through
        # for (`{:look, _}`), its placeholders being no leak.
        values: view.secrets
      }
    end
  end

  @doc """
  Whether MWT reads a connection `route/5` let pass (`{:tunnel, watch}`),
  from how it began (`MWTClient.Sandbox.Egress.Tcp.first/1`): `:read`,
  or `{:pass, why}`, `why` for the log.

  MWT reads every connection it can (`Tcp.readable/2`), the
  Internet's and a network grant's, as you set it in What MWT reads, on
  the activity log (`MWTClient.Sandbox.Reading`): a host you opted out is passed
  through (`:listed`), and with only token grants' hosts read, every host
  you didn't opt in (`:off`). A network grant's
  connection it doesn't read is asked about as a connection
  (`ask_connection/4`); one it reads, request by request (`authorize/2`).
  """
  @spec reading(String.t(), String.t() | nil, Tcp.first()) ::
          :read | {:pass, :off | :listed | Tcp.unreadable()}
  def reading(username, _under, first) do
    reading = Map.get(view(username), :reading) || Reading.new()
    name = with {:tls, %{name: name}} <- first, do: name, else: (_ -> nil)

    cond do
      Reading.read?(reading, name) ->
        with {:no, why} <- Tcp.readable(first), do: {:pass, why}, else: (:ok -> :read)

      Reading.rule(reading, name) ->
        {:pass, :listed}

      true ->
        {:pass, :off}
    end
  end

  @doc "A tunnel's or a read connection's bytes since its last report: `:ok` to go on, `:cut` to close it. It waits for the answer, never cut for a slow one."
  def upload(username, destination, port, up, down) do
    case Watch.observe(username, {:upload, destination, port, up, down}, :infinity) do
      :pass -> :ok
      _refused -> :cut
    end
  end

  @doc """
  What was found where it doesn't belong, and cut: a placeholder in a
  tunnel or past the start of a read request's body, or a real value
  going out (`:plaintext`, `:request`) or coming back (`:echo`). It never
  went, whatever the rule says. Logged, and shown to the firewall.
  """
  def found(username, {:placeholder, grant}, destination, :plaintext) do
    _verdict = Watch.observe(username, {:leak, grant, destination, :plaintext})
    :cut
  end

  def found(username, {:placeholder, grant}, host, :request) do
    log(username, %{
      outcome: :violation,
      summary: "#{grant} placeholder sent to #{host} · blocked",
      host: host,
      port: 443
    })

    _verdict = Watch.observe(username, {:leak, grant, host, :request})
    :cut
  end

  def found(username, {:value, grant}, destination, how)
      when how in [:plaintext, :request, :echo] do
    summary =
      case how do
        :echo -> "#{grant}'s real value came back from #{destination} · cut before the VM got it"
        _out -> "#{grant}'s real value in what the VM sent to #{destination} · cut"
      end

    log(username, %{outcome: :blocked, summary: summary, host: destination})
    _verdict = Watch.observe(username, {:value, grant, destination, how})
    :cut
  end

  ## Certificates

  @doc """
  The TLS options for a certificate for `host`, from MWT's CA: one per
  name on it, kept while it is young (a leaf lasts 30 days and MWT can
  run longer), at most #{@max_leaves} per identity. A grant host such as
  `*.googleapis.com` covers every name one label below it with a single
  wildcard certificate.
  """
  def leaf(username, host) do
    view = view(username)
    name = leaf_name(view.grants, host)
    now = System.system_time(:second)

    case :ets.lookup(@table, {username, :leaf, name}) do
      [{_key, {options, made}}] when now - made < @leaf_kept_seconds ->
        options

      _none_or_old ->
        options = view.ca |> CertificateAuthority.leaf(name) |> CertificateAuthority.ssl_options()

        if :ets.update_counter(@table, {username, :leaves}, 1, {{username, :leaves}, 0}) >
             @max_leaves do
          :ets.match_delete(@table, {{username, :leaf, :_}, :_})
          :ets.insert(@table, {{username, :leaves}, 1})
        end

        :ets.insert(@table, {{username, :leaf, name}, {options, now}})
        options
    end
  end

  @doc "How many certificates are kept for `username`."
  def leaves(username),
    do: :ets.select_count(@table, [{{{username, :leaf, :_}, :_}, [], [true]}])

  defp leaf_name(grants, host) do
    host = String.downcase(host)

    Enum.find_value(grants, host, fn
      %Grant{kind: :token, hosts: hosts} ->
        Enum.find(hosts, fn
          "*." <> suffix ->
            String.ends_with?(host, "." <> suffix) and
              not String.contains?(String.trim_trailing(host, "." <> suffix), ".")

          _exact ->
            false
        end)

      _other ->
        nil
    end)
  end

  ## Requests MWT reads

  @doc """
  Whether a request a driver read (`MWTClient.Sandbox.Egress.Request`)
  may go out, and with what: `{:forward, replace, scan}`, what to replace
  in it and in its answer (`MWTClient.Sandbox.Server.Values.replace/1`)
  and what to look for in what the VM sends after it (`scan.out`), with
  the grant whose value went in, if any (`scan.grant`); `{:deny, status,
  body}`; or `{:answer, status, body}` for a credential endpoint MWT
  answered itself (`MWTClient.Sandbox.CredentialEndpoint`), as
  `MWTClient.Sandbox.Server` answers `{:authorize, request}`. Decided
  here unless it needs a real value or you: then the server answers, as
  long as you take.

  An HTTP/1.1 request is judged as the server reads one
  (`Egress.Driver.Http1.message/1`), a token grant's placeholder in it
  included: a value goes only into HTTP, in the headers a grant names.
  A request of another protocol carries no value MWT can put in: the
  network grant it went under decides it (its card from its driver,
  `describe/1`), and whatever the VM sends after it must carry no
  placeholder and no real value.
  """
  def authorize(username, %Request{driver: Http1, plain?: true} = request) do
    # Over plain HTTP the name is the client's word: the network's limits
    # and its grants over part of it judge it by that and the names MWT's
    # DNS answered for the address it goes to. A network grant opened by a name it lists goes on
    # only for a name MWT answered for that address and the grant covers,
    # as its TLS connections do by the name in their ClientHello (`route/5`):
    # a shared address (an ingress) serves other names by their Host.
    names = Map.get(answered_for(username, request.ip), Destinations.unmap(request.ip), [])
    message = request |> Http1.message() |> Map.put(:names, names)
    view = view(username)

    case name_mismatch(username, view, request.under, request.ip, request.port, request.name) do
      nil ->
        authorize(username, message)

      grant ->
        {event, nil, answer} = Values.refusal({:name_not_granted, grant}, message)
        log(username, event)
        answer
    end
  end

  def authorize(username, %Request{driver: Http1} = request),
    do: authorize(username, Http1.message(request))

  def authorize(username, %Request{driver: Http2} = request),
    do: authorize(username, Http2.message(request))

  def authorize(username, %Request{} = request) do
    view = view(username)

    message = %{
      host: request.name,
      port: request.port,
      under: request.under,
      method: request.operation,
      path: request.resource || "",
      headers: [],
      body: "",
      exchange: request.id,
      about: request.driver.describe(request)
    }

    if isolated?(username, view) do
      refused(username)
      Values.isolated()
    else
      with {:ok, through, decision} <- through(username, view, message) do
        log(username, %{
          decision: decision,
          outcome: :read,
          summary: "Read by MWT, nothing put in it",
          host: request.name,
          port: request.port,
          grant_id: through,
          method: request.operation,
          path: request.resource,
          exchange_id: request.id,
          details: about_details(message.about)
        })

        {:forward, Values.replace([]), %{out: view.tunnel_secrets, grant: nil}}
      end
    end
  end

  def authorize(username, request) do
    view = view(username)

    cond do
      isolated?(username, view) ->
        refused(username)
        Values.isolated()

      grant = carried(view, request) ->
        log(username, %{
          outcome: :blocked,
          summary: "#{grant}'s real value in a request from the VM · blocked",
          host: request.host,
          port: Map.get(request, :port, 443)
        })

        _verdict = Watch.observe(username, {:value, grant, request.host, :request})
        Values.value_blocked()

      true ->
        decided(username, view, request)
    end
  end

  # A request on a connection a network grant opened is that grant's to
  # allow first (`Policy`'s `{:network_request, _}`), as its connections
  # are: allowed, asked or refused. Only then is a placeholder in it the
  # token grant's, by its own rules: each grant decides by its own
  # approval mode. `{:ok, grant_id, decision}`: the grant it went through,
  # if any, and what let it (`MWTClient.Sandbox.Decision`).
  @doc """
  As `authorize/2`, for a request on a connection MWT opened itself for a
  fixed call (`MWTClient.Sandbox.Egress.FixedCall`), `fixed` its mark: the
  sandbox's server decides by the fixed call, and puts in the values MWT
  fetched for it. The mark comes from the connection's options, which
  nothing in the VM sets. With none, it is `authorize/2`.
  """
  def authorize(username, request, nil), do: authorize(username, request)

  def authorize(username, %Request{driver: Http1} = request, fixed),
    do: Server.call(username, {:authorize_fixed, Http1.message(request), fixed}, :infinity)

  def authorize(_username, %Request{}, _fixed),
    do: Values.deny(400, "mwt_fixed_call", "A fixed call speaks HTTP/1.1 only.", nil)

  # An HTTP/2 stream is an HTTP request like any: the same judge, the same
  # carriers for a value.
  defp through(username, view, request) do
    snapshot =
      Policy.snapshot(
        view.grants,
        Map.get(view, :made, []),
        Map.get(view, :locks, %{}),
        Map.get(view, :limits, %{})
      )

    now = State.now()
    decision = Policy.decide(snapshot, {:network_request, request}, now)

    case decision do
      :pass ->
        {:ok, nil, Decision.passed(view.grants, now)}

      {:allow, grant, allowance, _about} ->
        Server.cast(username, {:used, grant.id})
        {:ok, grant.id, Decision.allowance(grant, allowance)}

      {:refuse, reason} ->
        world = %{snapshot: snapshot, isolated: false, now: now}
        {event, observation, answer} = Values.kept_refusal(reason, request, world)
        if event, do: log(username, event)
        if observation, do: Watch.observe(username, observation)
        answer

      {:ask, _grant, _about} ->
        Server.call(username, {:authorize_network, request}, :infinity)
    end
  end

  # One decision for the request, by the resources it goes through: the
  # network its connection went under and the credential whose placeholder
  # it carries, each given by its grants (`Policy.all_of/1`).
  # What needs no value and no one is decided here; the rest goes to the
  # server, which asks once for all the grants that ask.
  defp decided(username, view, request) do
    snapshot =
      Policy.snapshot(
        view.grants,
        Map.get(view, :made, []),
        Map.get(view, :locks, %{}),
        Map.get(view, :limits, %{})
      )

    now = State.now()
    decision = Policy.decide(snapshot, {:request, request}, now)

    case decision do
      {:allow, %Grant{kind: :network} = grant, allowance, about} ->
        for id <- [grant.id | Map.get(about, :through, [])],
            do: Server.cast(username, {:used, id})

        forward_unvalued(username, view, request, grant.id, Decision.allowance(grant, allowance))

      :pass ->
        forward_unvalued(username, view, request, nil, Decision.passed(view.grants, now))

      {:refuse, reason} ->
        world = %{snapshot: snapshot, isolated: false, now: now}
        {event, observation, answer} = Values.kept_refusal(reason, request, world)
        if event, do: log(username, event)
        if observation, do: Watch.observe(username, observation)
        answer

      _allow_or_ask ->
        # The server checks credential endpoints before it fetches a
        # value (`MWTClient.Sandbox.Firewall.minting/3`).
        Server.call(username, {:authorize, request}, :infinity)
    end
  end

  # A request let through with nothing put in it.
  defp forward_unvalued(username, view, request, through, decision) do
    log(username, %{
      decision: decision,
      outcome: :read,
      summary: "Read by MWT, no credential in it",
      host: request.host,
      port: Map.get(request, :port, 443),
      grant_id: through,
      method: request.method,
      path: request.path,
      exchange_id: Map.get(request, :exchange)
    })

    # Over plain HTTP no placeholder goes, whatever the host: it is looked
    # for in what follows the head as one going elsewhere.
    host = if Map.get(request, :plain?), do: nil, else: request.host
    {:forward, Values.replace([]), scan(view, host)}
  end

  # What a request to `host` with no value in it is looked through for, in
  # what the VM sends after its head: every real value, and the
  # placeholder of every grant that doesn't list the host.
  defp scan(view, host) do
    elsewhere = Policy.placeholders_elsewhere(view.grants, host)

    made_elsewhere =
      for made <- Map.get(view, :made, []),
          not Policy.host_listed?(host, made.hosts),
          do: {{:placeholder, made.name}, [made.placeholder]}

    %{out: Secrets.new(view.forms ++ elsewhere ++ made_elsewhere), grant: nil}
  end

  defp carried(view, request) do
    case view.secrets do
      nil ->
        nil

      secrets ->
        texts =
          [request.path, request.body] ++
            Enum.map(request.headers, fn {_name, value} -> value end)

        Enum.find_value(texts, fn text ->
          case Secrets.find(secrets, text || "") ||
                 Secrets.find(secrets, Placeholder.decoded(text || "") || "") do
            {:value, name} -> name
            nil -> nil
          end
        end)
    end
  end

  ## What the view says

  # The Internet's limits, as the view has them.
  defp internet_limits(view),
    do: view |> Map.get(:limits, %{}) |> Map.get("internet") || %HostLimits{}

  # Whether a connection under `grant` is judged by the name it is for: a
  # grant over part of its network, one leaving hosts out, or limits on
  # it.
  defp judged_by_name?(view, grant) do
    network = MWTClient.Sandbox.Network.id_of(grant)
    limits = view |> Map.get(:limits, %{}) |> Map.get(network)

    (limits != nil and HostLimits.any?(limits)) or
      Enum.any?(
        view.grants,
        &(&1.kind == :network and
            (MWTClient.Sandbox.Network.part?(&1) or &1.except != []) and
            MWTClient.Sandbox.Network.id_of(&1) == network)
      )
  end

  # Whether a grant over part of the Internet that is on names `name`.
  defp internet_part_names?(grants, name) do
    name = name |> String.downcase() |> String.trim_trailing(".")

    Enum.any?(grants, fn g ->
      g.kind == :network and MWTClient.Sandbox.Network.part?(g) and
        MWTClient.Sandbox.Network.id_of(g) == "internet" and Grant.on?(g, State.now()) and
        Policy.remembers?([g], %{}, name, State.now())
    end)
  end

  defp internet?(view) do
    case Enum.find(view.grants, &Grant.internet?/1) do
      nil -> false
      grant -> Grant.on?(grant, DateTime.utc_now())
    end
  end

  # The network grants whose names cover `name`.
  defp covering(nil, _name), do: []

  defp covering(view, name) do
    name = name |> String.downcase() |> String.trim_trailing(".")

    Enum.filter(view.grants, fn
      # Names of the Internet resolve as this machine's do, whatever a
      # grant over a host of it says.
      %Grant{kind: :network, internet: false, network: network, destinations: destinations}
      when network != "internet" ->
        Enum.any?(destinations, fn text ->
          case Destinations.parse(text) do
            {:ok, %{match: {kind, pattern}}} when kind in [:host, :names] ->
              Destinations.name_covers?(kind, pattern, name)

            _other ->
              false
          end
        end)

      _other ->
        false
    end)
  end

  # The grant whose real value a looked-up name carries, or nil. Names are
  # read in lower case, and a label holds 63 characters, so the value's
  # last 40 (or all of a shorter one) are looked for.
  defp value_in_name(view, name) do
    name = String.downcase(name)

    Enum.find_value(view.forms, fn {{:value, grant}, [value | _]} ->
      tail = value |> String.slice(-40, 40) |> String.downcase()
      if byte_size(tail) >= Secrets.shortest() and String.contains?(name, tail), do: grant
    end)
  end

  defp placeholders(grants) do
    for %Grant{kind: :token, placeholder: placeholder} = grant <- grants,
        is_binary(placeholder),
        do: {grant.name, placeholder}
  end

  defp observe(username, observation), do: Watch.observe(username, observation)

  defp log(username, attrs), do: Server.cast(username, {:log, attrs})

  # What MWT made of a request of another protocol than HTTP, from its
  # driver (`MWTClient.Sandbox.Describe`): what it worked out, and apart,
  # the words the request carried, as claims.
  defp about_details(about) do
    [
      EventDetails.section("What MWT read of it", [{"Request", about.title} | about.facts]),
      EventDetails.agent("In the request's own words", about.claims)
    ]
  end
end
