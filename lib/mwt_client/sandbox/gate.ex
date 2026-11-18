defmodule MWTClient.Sandbox.Gate do
  @moduledoc """
  The network path's side of the sandbox: what the proxy
  (`MWTClient.Sandbox.Egress.Connection`) and DNS (`MWTClient.Sandbox.Dns`)
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
    Destinations,
    Firewall,
    Grant,
    Placeholder,
    Policy,
    Routes,
    Secrets,
    Server,
    Watch
  }

  alias MWTClient.Sandbox.Server.{State, Values}

  @table __MODULE__
  @max_leaves 64
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
      State.held(state)
    }

    if Map.get(state, :gate) == inputs do
      state
    else
      version = (Map.get(state, :gate_version) || 0) + 1
      forms = Values.value_forms(state)
      placeholders = placeholders(state.grants)

      view = %{
        version: version,
        grants: state.grants,
        # The grants a gating check holds off.
        failing: elem(inputs, 5),
        firewall: Map.get(state, :firewall) || Firewall.new(),
        forms: forms,
        secrets: Secrets.new(forms),
        placeholders: placeholders,
        tunnel_secrets:
          Secrets.new(for({name, p} <- placeholders, do: {{:placeholder, name}, [p]}) ++ forms),
        ca: state.ca
      }

      :ets.insert(@table, {{state.username, :view}, view})
      state |> Map.put(:gate, inputs) |> Map.put(:gate_version, version)
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
         %Grant{} = grant <- Enum.find(view.grants, &(&1.id == id)),
         false <- Map.has_key?(Map.get(view, :failing, %{}), id) do
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
         false <- Map.has_key?(Map.get(view, :failing, %{}), id),
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
  Whether a name may be looked up: `:ok`, `:refuse`, or `{:refuse,
  :internet_off}` for a name no grant lists while the Internet is off.
  A name a network grant lists is `{:covered, grant}` while one that
  lists it is on (asked of its resolver, and what is answered kept,
  `answered/4`), and `{:refuse, {:grant_off, grant}}` otherwise, the
  Internet on or not. A name carrying a real value is never passed on,
  nor logged.
  """
  def lookup(username, name) do
    view = view(username)
    covering = covering(view, name)

    cond do
      isolated?(username, view) ->
        refused(username)
        :refuse

      grant = value_in_name(view, name) ->
        _verdict = Watch.observe(username, {:value, grant, nil, :lookup})
        :refuse

      # A name a network grant covers is answered only while one that
      # covers it is on, the Internet on or not; by its resolver, when it
      # names one, and what it answers is kept.
      covering != [] ->
        case Enum.find(covering, &live?(username, &1.id)) do
          nil ->
            {:refuse, {:grant_off, hd(covering)}}

          grant ->
            case Watch.observe(username, {:lookup, name, view.placeholders}) do
              :pass -> {:covered, grant}
              _refused -> :refuse
            end
        end

      not internet?(view) and not listed_name?(view.grants, name) ->
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
  Whether the VM may connect to `ip` and `port`: `{:ok, grant_id}`, the
  grant it goes under; `:read_only` while the Internet is off and no
  grant opens this public address, when only a host a token grant lists
  may be reached, read by MWT (`route/5`); or `{:deny, why}`. One that
  waits for you is held by the server, as long as you take.
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
          |> Policy.snapshot(Map.get(view, :failing, %{}))
          |> Map.merge(facts(username, view.grants, ip)),
          {:connection, ip, port},
          State.now()
        )

      class =
        case decision do
          {:allow, %Grant{internet: true}, _allowance, _about} -> :public
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

  defp connect(username, decision, ip, port) do
    case decision do
      {:allow, %Grant{internet: true} = grant, _allowance, _about} ->
        {:ok, grant.id}

      {:allow, grant, _allowance, _about} ->
        Server.cast(username, {:used, grant.id})
        {:ok, grant.id}

      {:refuse, :internet_off} ->
        :read_only

      {:refuse, reason} ->
        summary =
          if reason == :reserved,
            do: "This machine or a reserved address · always refused",
            else: "Private address with no network grant on"

        log(username, %{
          outcome: :blocked,
          summary: summary,
          host: "#{:inet.ntoa(ip)}",
          port: port
        })

        {:deny, summary}

      {:ask, _grant, _about} ->
        Server.call(username, {:destination, ip, port}, :infinity)
    end
  end

  @doc """
  What becomes of a connection once its first bytes named a host (`sni`)
  or didn't: `:intercept` (read by MWT), `{:tunnel, watch}` (passed
  through, watched by the firewall as `watch` says), or `:refuse`.
  `under` is the grant the connection went under (`destination/3`), or
  `:read_only` for one only a token grant's host may use. One a network
  grant opened by a name it lists goes on, when it is TLS, only with a
  name MWT answered for that address and the grant covers: an address
  shared by many names (a load balancer, an ingress) opens for the
  grant's names only.
  """
  def route(username, ip, port, sni, under \\ nil) do
    read_only? = under == :read_only
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

      sni && Policy.reads?(view.grants, sni) ->
        :intercept

      read_only? ->
        log(username, %{
          outcome: :blocked,
          summary: "The Internet is off · not passed through",
          host: destination,
          port: port
        })

        :refuse

      grant = name_mismatch(username, view, under, ip, port, sni) ->
        log(username, %{
          outcome: :blocked,
          summary:
            "#{sni} isn't a name MWT answered for this address under #{grant.name} · refused",
          host: destination,
          port: port
        })

        :refuse

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
        secrets: view.tunnel_secrets
      }
    end
  end

  @doc "A tunnel's bytes since its last report: `:ok` to go on, `:cut` to close it. It waits for the answer, never cut for a slow one."
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
  Whether a request MWT read may go out, and with what: `{:forward,
  headers, scan}` or `{:deny, status, body}`, as
  `MWTClient.Sandbox.Server` answers `{:authorize, request}`. Decided
  here unless it needs a real value or you: then the server answers, as
  long as you take.
  """
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
          port: 443
        })

        _verdict = Watch.observe(username, {:value, grant, request.host, :request})
        Values.value_blocked()

      true ->
        decision =
          Policy.decide(
            Policy.snapshot(view.grants, Map.get(view, :failing, %{})),
            {:request, request},
            State.now()
          )

        case decision do
          :pass ->
            log(username, %{
              outcome: :tunnel,
              summary: "Read by MWT, no credential in it",
              host: request.host,
              port: 443,
              method: request.method,
              path: request.path,
              exchange_id: Map.get(request, :exchange)
            })

            {:forward, request.headers, scan(view, request.host)}

          {:refuse, reason} ->
            {event, observation, answer} = Values.refusal(reason, request)
            if event, do: log(username, event)
            if observation, do: Watch.observe(username, observation)
            answer

          _allow_or_ask ->
            # The server checks credential endpoints before it fetches a
            # value (`MWTClient.Sandbox.Firewall.minting/3`).
            Server.call(username, {:authorize, request}, :infinity)
        end
    end
  end

  # What a request to `host` with no value in it is looked through for, in
  # what the VM sends after its head: every real value, and the
  # placeholder of every grant that doesn't list the host.
  defp scan(view, host) do
    elsewhere =
      for %Grant{kind: :token, placeholder: placeholder} = grant <- view.grants,
          is_binary(placeholder),
          not Policy.host_listed?(host, grant.hosts),
          do: {{:placeholder, grant.name}, [placeholder]}

    %{out: Secrets.new(view.forms ++ elsewhere), echo: nil, placeholder: nil, grant: nil}
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
      %Grant{kind: :network, internet: false, destinations: destinations} ->
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

  # A name some grant lists, on or off: a token grant's host (unless only
  # its subgrants use it: MWT sends those itself), or a host name among a
  # network grant's destinations.
  defp listed_name?(grants, name) do
    name = name |> String.downcase() |> String.trim_trailing(".")

    Enum.any?(grants, fn
      %Grant{kind: :token, reach: :subgrants} ->
        false

      %Grant{kind: :token, hosts: hosts} ->
        Policy.host_listed?(name, hosts)

      %Grant{kind: :network, destinations: destinations} ->
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
end
