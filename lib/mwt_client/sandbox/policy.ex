defmodule MWTClient.Sandbox.Policy do
  @moduledoc """
  What MWT answers to one use the VM makes: a connection to an address, a
  request, a call of an action, a saved command, a call of MWT's tools.

  `decide/3` is pure. Its answer depends on the grants, the resources'
  limits, the use and the clock it is given, and on nothing else: it holds
  nobody, logs nothing and never sees a real value.
  `MWTClient.Sandbox.Server` asks it and acts on the answer, so the rules
  are checked on their own, for every combination
  (`test/mwt_client/sandbox/policy_test.exs`).

  | Answer                              | The server then                                    |
  | ----------------------------------- | -------------------------------------------------- |
  | `:pass`                             | lets it through: the Internet's grant auto-approves |
  | `{:allow, grant, allowance, about}` | lets it through, with the real value for a request |
  | `{:ask, grant, about}`              | holds it for you                                   |
  | `{:refuse, reason}`                 | refuses it, and says why                           |

  **The rule.** Every grant mediates one resource
  (`MWTClient.Sandbox.Grant.resource/1`). A use goes through one or more
  resources, and each needs a grant over it that is on and covers the use;
  a grant that is off has no say, so with none on, nothing goes. Within
  one resource the most permissive grant counts (`most_permissive/1`):
  grants only give. Across resources the use goes unasked only if each
  lets it through unasked; if any asks, one card names each grant that
  asks (`all_of/1`). A locked resource, or a host its network blocks
  (`MWTClient.Sandbox.HostLimits`), refuses whatever the grants say. A
  network grant covers its part of the network but the hosts it leaves
  out (`Grant.except`), which another grant may cover on its own terms;
  none does, `{:excepted, grant, entry}`.

    * **A connection** goes through its network. The network grants that
      are on and open the address (the Internet's covering every public
      one; another's listing it, a name covering only the addresses MWT's
      DNS answered for it, `snapshot.answered`) are its candidates, the
      one naming it most exactly first, then the one that lets it through;
      one with a way out of its own (`Grant.anchor`) only while this
      machine routes the address through it (`snapshot.via`). None,
      refused: `:internet_off` for a public address, `:private`,
      `:reserved` (one to this machine or a reserved range needs a grant
      naming that exact address), `{:network_down, grant}`, or
      `{:grant_off, grant}` when a grant that is off would open it. A
      network whose limits may block one of the names the address has is
      held until its first bytes say which host it is for (`{:ask, …}`).
    * **A connection MWT can't read** (`{:unread, ip, port, names}`): its
      network, by the names it may be for (the one it asked for, those MWT's
      DNS answered): a blocked one refuses; then the grant that opened it
      and every grant over part of the network naming one of them.
    * **A request with no credential** (`{:network_request, request}`, or
      `{:request, request}` carrying no placeholder): its network, by its
      host (`network_say/3`): blocked, refused; then every grant over that
      network covering the host, one over all of it or one over part of it
      naming it. None on, refused (`{:outside, _}`, or `{:grant_off, _}`
      naming one that would). The Internet's grant auto-approving passes it
      without a word.
    * **A request carrying a credential's placeholder** (`{:request, _}`):
      the credential and the network. The credential by the grants over it
      that list the host and match its attributes, where its value can go
      in this request: only in a grant's carriers, never over plain HTTP,
      never to a host no grant over it lists (a credential only fixed calls
      are over has none: its placeholder goes nowhere), never in a request
      whose path its host may read as another (`{:ambiguous_path, _}`),
      never two credentials at once. A placeholder is looked for as sent
      and percent-decoded. A value made from a grant's (`snapshot.made`,
      `MWTClient.Sandbox.Made`) is that grant's use, with hosts and
      carriers of its own; one MWT no longer holds is refused,
      `{:made_stale, made}`.
    * **A call of a request action** (`{:call, _}`): the action, for the
      credential in its request (no token grant over it has a say), and the
      network of its host as for the agent's own request (`reach/3`): its
      request goes out as the agent's would.
    * **A saved command** (`{:command, _}`, by its exact id): the saved
      command alone, over host commands and the credentials it runs with
      (`Grant.with`); a lock on any of them refuses. A command the agent
      writes (no id, or one Ask to run commands had) is open use of host
      commands: Commands agents write (`Grant.agent_commands/0`) has to be
      on, and then it asks you, always; refused while host commands are
      locked.
    * **A call of MWT's tools** (`{:tool, _}`): MWT's tools, or your machine
      for git and the shared folders, by the built-in grant for what it
      does. Adding past the hour's limit asks whatever the allowances say
      (`MWTClient.Sandbox.MwtTools`).

  An allowance added while cards wait settles those it would have let
  through had it been there when they were asked, and no others
  (`settles?/3`): the same rules, for a use asked before.
  """

  alias MWTClient.Sandbox.{
    Adapter,
    Allowance,
    Approval,
    Attributes,
    CredentialEndpoint,
    Describe,
    Destinations,
    Grant,
    HostLimits,
    Made,
    MwtTools,
    Network,
    Placeholder,
    Resource,
    SavedRequest
  }

  @typedoc """
  What a decision reads: the grants, the networks' limits by network id,
  the locked resources, this machine's own addresses and networks, and how
  a host name in a network grant resolves here.
  """
  @type snapshot :: %{
          required(:grants) => [Grant.t()],
          required(:own) => [Destinations.ip()],
          optional(:networks) => [{Destinations.ip(), non_neg_integer()}],
          required(:resolve) => (String.t() -> [Destinations.ip()]),
          optional(:made) => [Made.t()],
          optional(:answered) => %{Destinations.ip() => [String.t()]},
          optional(:via) => String.t() | nil,
          optional(:locks) => map(),
          optional(:limits) => %{String.t() => HostLimits.t()}
        }

  @type use ::
          {:connection, Destinations.ip(), :inet.port_number()}
          | {:unread, Destinations.ip(), :inet.port_number(), [String.t()]}
          | {:request, Describe.request()}
          | {:network_request, Describe.request()}
          | {:command, map()}
          | {:call, map()}
          | {:tool, map()}

  @type refusal ::
          :reserved
          | :private
          | :internet_off
          | :multiple_grants
          | {:wrong_host, Grant.t()}
          | {:made_elsewhere, Made.t()}
          | {:made_stale, Made.t() | nil}
          | {:not_a_carrier, Grant.t(), [String.t()], [String.t()]}
          | {:grant_off, Grant.t()}
          | {:network_down, Grant.t()}
          | {:host_blocked, String.t(), String.t() | :default}
          | {:outside, Grant.t() | String.t()}
          | {:excepted, Grant.t(), String.t()}
          | {:plain_http, Grant.t()}
          | {:ambiguous_path, Grant.t()}
          | {:name_a_grant, [String.t()]}
          | {:no_such_grant, [String.t()]}
          | {:fixed_script, Grant.t()}
          | :no_mwt_grant
          | {:locked, Resource.id(), Grant.t() | nil}
          | {:uncovered, Grant.t()}

  @type answer ::
          :pass
          | {:allow, Grant.t(), Allowance.t(), map()}
          | {:ask, Grant.t() | nil, map()}
          | {:refuse, refusal()}

  @doc """
  The snapshot of these grants on this machine, as it is now, with the
  values made from them (`MWTClient.Sandbox.Made`), without their values,
  the locks, and each network's limits by its id.
  """
  @spec snapshot([Grant.t()], [Made.t()], map(), %{String.t() => HostLimits.t()}) :: snapshot()
  def snapshot(grants, made \\ [], locks \\ %{}, limits \\ %{}) do
    %{
      grants: grants,
      made: Enum.map(made, &Made.unvalued/1),
      own: Destinations.host_addresses(),
      networks: MWTClient.Sandbox.Routes.networks(),
      resolve: &Destinations.resolve/1,
      locks: locks,
      limits: limits
    }
  end

  # Whether `resource` is locked: refused whatever the grants say.
  defp locked?(snapshot, resource), do: Map.has_key?(Map.get(snapshot, :locks, %{}), resource)

  defp locked_refusal(snapshot, grants) do
    Enum.find_value(grants, fn grant ->
      resource = Grant.resource(grant)
      if locked?(snapshot, resource), do: {:refuse, {:locked, resource, grant}}
    end)
  end

  defp limits(snapshot, network),
    do: snapshot |> Map.get(:limits, %{}) |> Map.get(network) || %HostLimits{}

  @doc """
  Decides one use at `now`.

  `about` is what an approval shows and what an allowance is matched on. For
  a connection: `pattern` (`address:port`) and `listed_as`, the grant's entry
  that covers it. For a request: `MWTClient.Sandbox.Describe.request/1`. For
  a command: the grant's `script` and `dir`, both nil when the agent sends
  the text.
  """
  @spec decide(snapshot(), use(), DateTime.t()) :: answer()
  def decide(snapshot, {:connection, ip, port}, now) do
    with {:ok, grant, about} <- opening(snapshot, ip, port, now),
         nil <- locked_refusal(snapshot, [grant]) do
      limits = limits(snapshot, Network.id_of(grant))

      # A network that may block one of the names this address has holds
      # the connection until its first bytes say which host it is for
      # (`{:unread, _, _, _}`, or each request it carries): an address
      # shared by many names opens for the others.
      answered = answered_names(snapshot, ip)

      # So does a grant that leaves out one of them (`Grant.except`).
      if (HostLimits.any?(limits) and HostLimits.any_blocked?(limits, answered)) or
           Network.excepted(grant, answered) != nil do
        {:ask, grant, about}
      else
        allow_or_ask(grant, now, about)
      end
    end
  end

  def decide(snapshot, {:unread, ip, port, names}, now) do
    with {:ok, grant, about} <- opening(snapshot, ip, port, now),
         nil <- locked_refusal(snapshot, [grant]) do
      network = Network.id_of(grant)
      # The name it asked for proves nothing on a connection MWT can't read:
      # each name MWT's DNS answered for its address counts too.
      asked = for name <- names, is_binary(name), do: String.downcase(name)
      names = Enum.uniq(asked ++ answered_names(snapshot, ip))

      case blocked(limits(snapshot, network), names) do
        nil ->
          parts =
            for g <- parts(snapshot.grants, network),
                g.id != grant.id,
                Grant.on?(g, now),
                Enum.any?(names, &names?(g, &1)),
                do: g

          # A grant leaving out one of the names it may be for has no say:
          # MWT can't tell which of them it is for.
          case Enum.split_with([grant | parts], &is_nil(Network.excepted(&1, names))) do
            {[], [first | _]} ->
              {:refuse, {:excepted, first, Network.excepted(first, names)}}

            {covering, _left_out} ->
              most_permissive(Enum.map(covering, &allow_or_ask(&1, now, about)))
          end

        entry ->
          {:refuse, {:host_blocked, network, entry}}
      end
    end
  end

  def decide(%{grants: grants} = snapshot, {:request, request}, now) do
    tokens = for %Grant{kind: :token, placeholder: p} = grant <- grants, is_binary(p), do: grant
    made = Map.get(snapshot, :made, [])

    # Every grant that knows a credential's placeholder: open use of it
    # and the fixed calls over it (`Credential.attach/2`). Only open use
    # lists hosts its value goes to in the agent's own requests: a fixed
    # call covers its credential in the request MWT builds, never in one
    # the agent sends. So the placeholder
    # of a credential only fixed calls are over goes nowhere: carried
    # anywhere, it is moved where its credential doesn't go, refused and
    # the firewall told, as any other.
    known =
      tokens ++
        for %Grant{kind: :request, placeholder: p} = grant <- grants, is_binary(p), do: grant

    # A placeholder is its credential's, shared by every grant over it
    # (`MWTClient.Sandbox.Credential`): carried, it makes the request a use
    # of each of them, and it goes where any of them lists.
    carried =
      Enum.filter(tokens, fn grant ->
        Enum.any?(Grant.placeholders(grant), &Placeholder.in?(request.headers, &1))
      end)

    made_carried = Enum.filter(made, &Placeholder.in?(request.headers, &1.placeholder))
    hosts_of = credential_hosts(tokens)

    # The path and the body as sent, and as the host may read them once it
    # decodes them: percent-encoded (`mwt%5Fghp…`), or a form's `+`. A
    # placeholder is looked for in each.
    body = request.body || ""

    texts =
      Enum.uniq([request.path, Describe.percent_decoded(request.path), body, form_decoded(body)])

    anywhere? = fn placeholder -> Enum.any?(texts, &String.contains?(&1, placeholder)) end

    # Only a header gets a value, but a placeholder anywhere in what MWT
    # read is a string moved where its grant doesn't go (QA L9).
    moved? = fn placeholder, hosts ->
      not host_listed?(request.host, hosts) and
        (Placeholder.in?(request.headers, placeholder) or anywhere?.(placeholder))
    end

    elsewhere =
      Enum.find(known, fn grant ->
        hosts = Map.get(hosts_of, Grant.credential_id(grant), [])
        Enum.any?(Grant.placeholders(grant), &moved?.(&1, hosts))
      end)

    made_elsewhere = Enum.find(made, &moved?.(&1.placeholder, &1.hosts))

    # A login's placeholder belongs only in the body of a refresh at
    # Google's token endpoint, which MWT answers
    # (`MWTClient.Sandbox.CredentialEndpoint`): there it makes the request
    # its grant's; anywhere else it is moved where it doesn't go.
    refresh? = CredentialEndpoint.token_request?(request)
    # A form body carries it percent-encoded (`1%2F%2F…`).
    bodies = Enum.uniq([body, form_decoded(body)])
    paths = Enum.uniq([request.path, Describe.percent_decoded(request.path)])

    logins =
      for %Grant{} = grant <- tokens,
          login <- [Grant.login_placeholder(grant) | grant.login_aliases || []],
          is_binary(login),
          do: {grant, login}

    in_body? = fn login -> Enum.any?(bodies, &String.contains?(&1, login)) end
    login_carried = for {grant, login} <- logins, refresh?, in_body?.(login), do: grant

    login_moved =
      Enum.find_value(logins, fn {grant, login} ->
        if Placeholder.in?(request.headers, login) or
             Enum.any?(paths, &String.contains?(&1, login)) or
             (not refresh? and in_body?.(login)),
           do: grant
      end)

    # A JWT placeholder MWT wrote and no longer holds (expired, or from
    # before MWT started), or one its grant no longer covers: sent as it
    # is, the service would only say no, and not why.
    stale =
      Enum.find(made_carried, &(not Made.covered?(&1, grants, now))) ||
        if unknown_made?(request.headers, made), do: :unknown

    owners =
      Enum.uniq_by(
        carried ++ for(m <- made_carried, g <- tokens, g.id == m.grant_id, do: g) ++ login_carried,
        & &1.id
      )

    # Every grant over the credentials the request carries: one credential
    # may have several, each with its own hosts and approval.
    over =
      owners
      |> Enum.map(&Grant.credential_id/1)
      |> Enum.uniq()

    # Over plain HTTP nothing proves which host gets the request, so no
    # placeholder goes, wherever it is in it.
    plain =
      Map.get(request, :plain?, false) &&
        (Enum.find(owners, & &1) ||
           Enum.find(known, &Enum.any?(Grant.placeholders(&1), anywhere?)))

    cond do
      plain ->
        {:refuse, {:plain_http, plain}}

      elsewhere ->
        {:refuse, {:wrong_host, elsewhere}}

      login_moved ->
        {:refuse, {:wrong_host, login_moved}}

      made_elsewhere ->
        {:refuse, {:made_elsewhere, made_elsewhere}}

      stale ->
        {:refuse, {:made_stale, if(stale == :unknown, do: nil, else: stale)}}

      owners == [] ->
        # No credential: its network alone.
        network_say(snapshot, request, now)

      # A value goes in only where MWT reads the path as the host will.
      # MWT matches a grant's attributes (`github.repository` is the two
      # segments after `/repos/`) and its allowances on the path as sent;
      # a host normalising `/repos/o/r/../../x/y` acts on `/repos/x/y`.
      # So a path with a `.` or `..` segment, or a backslash, as sent or
      # percent-encoded (`Describe.ambiguous_path?/1`), carries no value:
      # refused before it goes in. Tools send paths normalised (curl does
      # unless `--path-as-is`); one that doesn't is told to.
      Describe.ambiguous_path?(request.path) ->
        {:refuse, {:ambiguous_path, hd(owners)}}

      match?([_, _ | _], over) ->
        {:refuse, :multiple_grants}

      refused = locked_refusal(snapshot, Enum.take(owners, 1)) ->
        refused

      # A login's refresh, which MWT answers itself (`CredentialEndpoint`):
      # nothing real leaves, and the VM gets placeholders only. No use of a
      # grant, so no card: answered while a grant over the credential is on.
      refresh? and login_carried != [] ->
        [credential_id] = over
        grants_over = Enum.filter(tokens, &(Grant.credential_id(&1) == credential_id))

        case Enum.find(grants_over, &Grant.on?(&1, now)) do
          %Grant{} = grant ->
            {:allow, grant,
             %Allowance{id: "login-refresh", pattern: :all, until: nil, origin: %{kind: :mwt}},
             Describe.request(request)}

          nil ->
            {:refuse, {:grant_off, hd(grants_over)}}
        end

      # A request carrying a credential goes through two resources: the
      # credential, to a host a grant over it lists, and the network the
      # host is on. Each gives it by its own grants; it goes unasked only
      # if both do.

      true ->
        [credential_id] = over
        grants_over = Enum.filter(tokens, &(Grant.credential_id(&1) == credential_id))

        case credential_say(request, grants_over, carried, made_carried, now) do
          {:refuse, _why} = refused ->
            refused

          say ->
            # Both read the use as one: the same card, the same pattern for
            # their allowances.
            described = Map.put(request, :about, elem(say, tuple_size(say) - 1))
            all_of([say, network_say(snapshot, described, now)])
        end
    end
  end

  def decide(snapshot, {:network_request, request}, now) do
    case under(snapshot.grants, request) do
      %Grant{} -> network_say(snapshot, request, now)
      # Under no network grant: nothing to decide here.
      nil -> :pass
    end
  end

  def decide(%{grants: grants} = snapshot, {:call, ask}, now) do
    requests = Enum.filter(grants, &(&1.kind == :request))
    ids = Enum.map(requests, & &1.id)
    wanted = ask |> Map.get(:grant) |> text() |> String.trim()

    # By its exact id: a name is not enough to send something.
    case Enum.find(requests, &(&1.id == wanted)) do
      nil ->
        {:refuse, {:no_such_grant, ids}}

      action ->
        host = SavedRequest.host(action)
        about = %{pattern: "call " <> action.id, title: action.name, facts: [], claims: []}
        network = network_of_host(snapshot, host)

        cond do
          refused = locked_refusal(snapshot, [action]) ->
            refused

          not Grant.on?(action, now) ->
            all_of([{:refuse, {:grant_off, action}}, reach(snapshot, network, host, about, now)])

          true ->
            all_of([allow_or_ask(action, now, about), reach(snapshot, network, host, about, now)])
        end
    end
  end

  def decide(%{grants: grants} = snapshot, {:command, ask}, now) do
    commands = Enum.filter(grants, &(&1.kind == :command))
    ids = Enum.map(commands, & &1.id)
    wanted = ask |> Map.get(:grant) |> text() |> String.trim()
    script = ask |> Map.get(:script) |> text() |> String.trim()

    # By its exact id: a name is not enough to run something.
    grant = Enum.find(commands, &(&1.id == wanted))

    cond do
      # The agent's own: Commands agents write lets it ask, and nothing
      # lets it through unasked (`Grant.always_asks?/1`), so it asks with
      # no grant that an allowance could be added to. Missing from the
      # grants, it counts as off.
      is_nil(grant) and
          (wanted == "" or wanted in [Grant.agent_commands().id | Grant.former_command_ids()]) ->
        written = Enum.find(grants, Grant.agent_commands(), &Grant.agent_commands?/1)

        cond do
          locked?(snapshot, :machine) -> {:refuse, {:locked, :machine, written}}
          script == "" -> {:refuse, {:name_a_grant, ids}}
          not Grant.on?(written, now) -> {:refuse, {:grant_off, written}}
          true -> {:ask, nil, %{script: nil, dir: nil, pattern: nil}}
        end

      is_nil(grant) ->
        {:refuse, {:no_such_grant, ids}}

      script != "" ->
        {:refuse, {:fixed_script, grant}}

      refused = locked_refusal(snapshot, [grant]) ->
        refused

      true ->
        about = %{script: grant.script, dir: grant.dir, pattern: "run " <> grant.id}

        machine_say =
          if Grant.on?(grant, now),
            do: allow_or_ask(grant, now, about),
            else: {:refuse, {:grant_off, grant}}

        case Enum.find(grant.with, &locked?(snapshot, {:credential, &1})) do
          nil -> machine_say
          locked -> {:refuse, {:locked, {:credential, locked}, grant}}
        end
    end
  end

  def decide(%{grants: grants} = snapshot, {:tool, use}, now) do
    case Enum.find(grants, &(&1.kind == :mwt and &1.tools == use.grant)) do
      nil ->
        {:refuse, :no_mwt_grant}

      grant ->
        about = MwtTools.about(use)

        cond do
          refused = locked_refusal(snapshot, [grant]) ->
            refused

          not Grant.on?(grant, now) ->
            {:refuse, {:grant_off, grant}}

          # Like no other: nothing is similar to it, and no allowance
          # settles its card (`settles?/3`).
          Map.get(use, :over_limit, false) ->
            {:ask, grant, %{about | pattern: nil}}

          true ->
            allow_or_ask(grant, now, about)
        end
    end
  end

  # The hosts each credential's value may go to: every host any grant over
  # it lists.
  defp credential_hosts(tokens) do
    tokens
    |> Enum.group_by(&Grant.credential_id/1)
    |> Map.new(fn {id, grants} -> {id, Enum.flat_map(grants, &Adapter.hosts/1)} end)
  end

  # The credential's say about the request: the most permissive of the
  # grants over it that are on and cover its host (and its attributes),
  # where its value can go in this request. None on, refused: by one that
  # would cover it (off, which an agent may ask for), or as uncovered.
  defp credential_say(request, grants_over, carried, made_carried, now) do
    listing =
      case Enum.filter(grants_over, &host_listed?(request.host, Adapter.hosts(&1))) do
        # A value made from a grant goes where it was made for, which its
        # grant may name only by a wildcard: its grant decides.
        [] -> grants_over
        listing -> listing
      end

    # Narrowed by attributes (`MWTClient.Sandbox.Attributes`): a grant
    # covers the use only where each it names matches. What MWT couldn't
    # read counts against the use.
    attrs = Attributes.of(request)

    covering =
      Enum.filter(listing, fn grant ->
        case Attributes.matches?(grant.attributes || %{}, attrs) do
          true -> true
          false -> false
          # What MWT couldn't read counts against the use: a grant that
          # would let it through unasked doesn't cover it, one that asks
          # does (unless *Covers requests MWT can't read* is off).
          :unknown -> grant.covers_unread != false and not Grant.auto_approved?(grant, now)
        end
      end)

    on = Enum.filter(covering, &Grant.on?(&1, now))

    case Enum.split_with(on, &is_nil(cannot_go(request, &1, carried, made_carried))) do
      {[_ | _] = going, _cannot} ->
        going
        |> Enum.map(&grant_say(request, &1, carried, made_carried, now))
        |> most_permissive()

      # Each on grant covering it refuses where the value can't go at all:
      # a header that isn't one of its carriers.
      {[], [first | _]} ->
        cannot_go(request, first, carried, made_carried)

      {[], []} when covering != [] ->
        {:refuse, {:grant_off, hd(covering)}}

      {[], []} ->
        {:refuse, {:uncovered, hd(listing)}}
    end
  end

  # Why the grant's value can't go in this request at all, or nil.
  defp cannot_go(request, grant, carried, made_carried) do
    carriers = Grant.carriers(grant)

    # Each placeholder only in the headers its value goes in: the grant's
    # own (or one its credential had before a merge) in its carriers, a
    # made one in its own.
    outside =
      if(grant in carried,
        do:
          for(
            placeholder <- Grant.placeholders(grant),
            do: {Placeholder.outside(request.headers, placeholder, carriers), carriers}
          ),
        else: []
      ) ++
        for(
          m <- made_carried,
          do: {Placeholder.outside(request.headers, m.placeholder, m.carriers), m.carriers}
        )

    cond do
      (wrong = Enum.find(outside, fn {headers, _carriers} -> headers != [] end)) != nil ->
        {headers, carriers} = wrong
        {:refuse, {:not_a_carrier, grant, headers, carriers}}

      true ->
        nil
    end
  end

  # One grant over the credential the request carries, on: yes or ask
  # (`allow_or_ask/3`), about the request as the carrier it went in says.
  defp grant_say(request, grant, _carried, made_carried, now) do
    carriers = Grant.carriers(grant)

    carrier =
      Enum.find_value(
        Grant.placeholders(grant),
        &Placeholder.carrier(request.headers, &1, carriers)
      ) ||
        Enum.find_value(
          made_carried,
          &Placeholder.carrier(request.headers, &1.placeholder, &1.carriers)
        )

    about = Describe.request(request)
    # A refresh carries the login in its body, not in a header.
    about = if carrier, do: Describe.carried_in(about, carrier), else: about
    allow_or_ask(grant, now, about)
  end

  # The network's say about a request (`request.host`, and over plain HTTP
  # the names beside it, `request.names`): the network its connection went
  # under (`request.under`), or the one its host is on.
  defp network_say(snapshot, request, now) do
    network =
      case under(snapshot.grants, request) do
        %Grant{} = grant -> Network.id_of(grant)
        nil -> network_of_host(snapshot, request.host)
      end

    network_say(snapshot, network, request, now)
  end

  # A network's say about a request to a host on it: locked or blocked,
  # refused; then the most permissive of the grants over it that are on
  # and cover the host, one over all of it or one over part of it naming
  # it, but for one that leaves the host out (`Grant.except`). The
  # Internet's grant auto-approving passes it without a word: a request
  # there costs nothing more than its log line.
  defp network_say(snapshot, network, request, now) do
    names = [request.host | Map.get(request, :names, [])]
    names = for name <- names, is_binary(name), do: String.downcase(name)
    over = for %Grant{kind: :network} = g <- snapshot.grants, Network.id_of(g) == network, do: g

    named =
      Enum.filter(over, &(Network.part?(&1) and Enum.any?(names, fn n -> names?(&1, n) end)))

    {covering, left_out} =
      Enum.split_with(
        named ++ Enum.reject(over, &Network.part?/1),
        &is_nil(Network.excepted(&1, names))
      )

    about = about(request)

    cond do
      refused = network_limits(snapshot, network, names, List.first(covering)) ->
        refused

      (on = Enum.filter(covering, &Grant.on?(&1, now))) != [] ->
        on
        |> Enum.map(fn
          %Grant{internet: true} = g ->
            if Grant.auto_approved?(g, now), do: :pass, else: allow_or_ask(g, now, about)

          g ->
            allow_or_ask(g, now, about)
        end)
        |> most_permissive()

      covering != [] ->
        {:refuse, {:grant_off, hd(covering)}}

      left_out != [] ->
        first = Enum.find(left_out, hd(left_out), &Grant.on?(&1, now))
        {:refuse, {:excepted, first, Network.excepted(first, names)}}

      true ->
        {:refuse, {:outside, under(snapshot.grants, request) || network}}
    end
  end

  @doc """
  Whether a request to `host` may leave on its network as the agent's own
  would, credential aside: locked or blocked, refused; then the network's
  grants that cover the host, the most permissive (`network_say/4`). A
  fixed call's request goes out this way too: the action covers its
  credential in it, the network's grants decide where it goes, as they
  do for the agent's own requests.
  """
  @spec reach(snapshot(), String.t() | nil, DateTime.t(), :inet.port_number() | nil) :: answer()
  def reach(snapshot, host, now, port \\ nil) do
    reach(snapshot, network_of_host(snapshot, host), host, %{pattern: nil}, now, port)
  end

  defp reach(snapshot, network, host, about, now, port \\ 443) do
    snapshot =
      if port,
        do: %{snapshot | grants: fixed_grants(snapshot, network, host, port)},
        else: snapshot

    network_say(snapshot, network, %{host: host, under: nil, about: about}, now)
  end

  @doc "Grants over a fixed call's network whose scope includes its host and port."
  def fixed_grants(snapshot, network, host, port) do
    name = String.downcase(host || "")

    for %Grant{kind: :network} = grant <- snapshot.grants,
        Network.id_of(grant) == network,
        grant.internet or Enum.any?(specs(grant), &named_port?(&1, name, port)),
        do: grant
  end

  defp named_port?(%{match: {kind, pattern}, ports: ports}, name, port)
       when kind in [:host, :names],
       do: (ports == :any or port in ports) and Destinations.name_covers?(kind, pattern, name)

  defp named_port?(_spec, _name, _port), do: false

  @doc "Selects the network grant for a fixed call's resolved address and outbound route."
  def fixed_opening(snapshot, network, host, ip, port, now) do
    class = Destinations.classify(ip, snapshot.own, Map.get(snapshot, :networks, []))
    grants = fixed_grants(snapshot, network, host, port)

    cond do
      class == :refused ->
        {:refuse, :reserved}

      network == "internet" and class != :public ->
        {:refuse, :private}

      network_of_host(snapshot, host) != network ->
        {:refuse, {:outside, network}}

      refused = network_limits(snapshot, network, [host], List.first(grants)) ->
        refused

      true ->
        covering = Enum.reject(grants, &Network.excepted(&1, [host]))
        answered = %{Destinations.unmap(ip) => [host]}
        snapshot |> Map.merge(%{grants: covering, answered: answered}) |> opening(ip, port, now)
    end
  end

  @doc "Whether the socket's fixed-call route still matches its grant."
  def fixed_route_current?(snapshot, request, fixed, now) do
    network_of_host(snapshot, fixed.host) == fixed.network and
      Enum.any?(fixed_grants(snapshot, fixed.network, fixed.host, 443), fn grant ->
        grant.id == request.under and Grant.on?(grant, now) and
          is_nil(Network.excepted(grant, [fixed.host])) and
          grant.anchor == fixed.anchor and grant.resolver == fixed.resolver
      end)
  end

  # What refuses a use of `network` whatever its grants say, or nil: the
  # network locked, or one of `names` on its list of blocked hosts.
  defp network_limits(snapshot, network, names, grant) do
    cond do
      locked?(snapshot, {:network, network}) ->
        {:refuse, {:locked, {:network, network}, grant}}

      entry = blocked(limits(snapshot, network), names) ->
        {:refuse, {:host_blocked, network, entry}}

      true ->
        nil
    end
  end

  # The network grant a request's connection went under, or nil.
  defp under(grants, request) do
    case Map.get(request, :under) do
      under when is_binary(under) -> Enum.find(grants, &(&1.id == under and &1.kind == :network))
      _none -> nil
    end
  end

  @doc """
  The network a host is on, for a use that went under no connection (a
  call MWT sends): one a network grant other than the Internet's names
  it in, else the Internet.
  """
  @spec network_of_host(snapshot(), String.t() | nil) :: String.t()
  def network_of_host(snapshot, host) do
    name = String.downcase(host || "")

    Enum.find_value(snapshot.grants, "internet", fn
      %Grant{kind: :network, internet: false} = g -> names?(g, name) && Network.id_of(g)
      _other -> nil
    end)
  end

  # The entry of `limits` that blocks one of `names`, or `:default` when
  # the default blocks one no entry names; nil when none is blocked. A use
  # with no name at all goes by the default.
  defp blocked(limits, []), do: if(limits.default == :blocked, do: :default)

  defp blocked(limits, names) do
    Enum.find_value(names, fn name ->
      if HostLimits.blocked?(limits, name) do
        case HostLimits.rule(limits, name) do
          %{host: entry} -> entry
          nil -> :default
        end
      end
    end)
  end

  @doc """
  The most permissive of one resource's grants' says about a use: grants
  only give, so the first that lets it through counts (`:pass` before an
  allowance), else the first that asks. Nil when none has a say.

      iex> alias MWTClient.Sandbox.{Allowance, Grant, Policy}
      iex> a = %Grant{id: "a", name: "A", kind: :network}
      iex> b = %Grant{id: "b", name: "B", kind: :network}
      iex> about = %{pattern: "x"}
      iex> every = %Allowance{id: "e", pattern: :all}
      iex> {:allow, %Grant{id: "b"}, _, _} = Policy.most_permissive([{:ask, a, about}, {:allow, b, every, about}])
      iex> {:ask, %Grant{id: "a"}, _} = Policy.most_permissive([{:ask, a, about}, {:ask, b, about}])
      iex> Policy.most_permissive([])
      nil
  """
  @spec most_permissive([answer()]) :: answer() | nil
  def most_permissive(says) do
    Enum.find(says, &(&1 == :pass)) ||
      Enum.find(says, &match?({:allow, _, _, _}, &1)) ||
      Enum.find(says, &match?({:ask, _, _}, &1)) ||
      List.first(says)
  end

  @doc """
  The answer for a use that goes through several resources, from each
  one's say: a refusal wins over an ask, an ask over a yes. Nil stands for
  a resource with no say; `:pass` for a yes nobody needs to hear of (the
  Internet letting through what it doesn't ask about).

  An ask names every grant that asked (`about.asking`), the first being
  the card's own, and those that let it through (`about.through`); a yes,
  every grant that let it through beside the one answering
  (`about.through`). The one answering is the first that holds a
  credential (a token grant's yes carries its value), else the first.
  `about.credential` is the token grant whose value the use carries,
  asking or not: once the card is allowed, its value goes in.

      iex> alias MWTClient.Sandbox.{Allowance, Grant, Policy}
      iex> token = %Grant{id: "t", name: "T", kind: :token}
      iex> net = %Grant{id: "n", name: "N", kind: :network}
      iex> about = %{title: "GET h/", pattern: "GET h/", facts: [], claims: []}
      iex> {:ask, grant, about} = Policy.all_of([{:ask, net, about}, {:ask, token, about}])
      iex> {grant.id, about.asking}
      {"t", ["t", "n"]}
      iex> every = %Allowance{id: "a", pattern: :all}
      iex> {:ask, grant, about} = Policy.all_of([{:allow, token, every, about}, {:ask, net, about}])
      iex> {grant.id, about.asking, about.through}
      {"n", ["n"], ["t"]}
      iex> Policy.all_of([{:allow, token, every, about}, {:refuse, :private}])
      {:refuse, :private}
      iex> Policy.all_of([:pass, nil])
      :pass
  """
  @spec all_of([answer() | nil]) :: answer()
  def all_of(says) do
    says = Enum.reject(says, &is_nil/1)
    refusal = Enum.find(says, &match?({:refuse, _}, &1))
    asks = for {:ask, grant, about} <- says, do: {grant, about}
    allows = for {:allow, grant, allowance, about} <- says, do: {grant, allowance, about}

    cond do
      refusal ->
        refusal

      asks != [] ->
        [{grant, about} | _] = Enum.sort_by(asks, fn {grant, _} -> grant.kind != :token end)
        others = for {g, _} <- asks, g.id != grant.id, do: g.id
        through = for {g, _, _} <- allows, do: g.id

        credential =
          Enum.find_value(asks, fn {g, _} -> g.kind == :token && g.id end) ||
            Enum.find_value(allows, fn {g, _, _} -> g.kind == :token && g.id end)

        about =
          about
          |> Map.put(:asking, [grant.id | others])
          |> Map.put(:through, through)
          |> Map.put(:credential, credential)

        {:ask, grant, about}

      allows != [] ->
        [{grant, allowance, about} | _] =
          Enum.sort_by(allows, fn {grant, _, _} -> grant.kind != :token end)

        through = for {g, _, _} <- allows, g.id != grant.id, do: g.id
        {:allow, grant, allowance, Map.put(about, :through, through)}

      true ->
        :pass
    end
  end

  @doc """
  Whether connections to `host` are read instead of tunnelled: some token
  grant lists it, on or off. An off grant's host is still read, so its
  placeholder is refused with a reason instead of going out as it is.
  """
  @spec reads?([Grant.t()], String.t() | nil) :: boolean()
  def reads?(grants, host),
    do:
      Enum.any?(
        grants,
        &(&1.kind == :token and host_listed?(host, Adapter.hosts(&1)))
      )

  @doc """
  The placeholders that don't belong in what goes to `host`, by name: each
  credential's (`MWTClient.Sandbox.Credential`), its earlier ones
  included, when no grant over it lists the host. What the VM sends after
  a request's head is looked through for them.
  """
  @spec placeholders_elsewhere([Grant.t()], String.t() | nil) :: [
          {{:placeholder, String.t()}, [String.t()]}
        ]
  def placeholders_elsewhere(grants, host) do
    for {_id, [first | _] = over} <-
          grants
          |> Enum.filter(&(&1.kind == :token and is_binary(&1.placeholder)))
          |> Enum.group_by(&Grant.credential_id/1),
        not Enum.any?(over, &host_listed?(host, Adapter.hosts(&1))),
        do: {{:placeholder, first.name}, Grant.placeholders(first)}
  end

  @doc """
  Whether `host` is on a token grant's list. `*.example.com` covers
  `example.com` and every name under it; any other entry covers itself.
  """
  @spec host_listed?(String.t() | nil, [String.t()]) :: boolean()
  def host_listed?(host, hosts) do
    host = String.downcase(host || "")

    Enum.any?(hosts, fn
      "*." <> suffix -> host == suffix or String.ends_with?(host, "." <> suffix)
      exact -> host == String.downcase(exact)
    end)
  end

  # A body as a form decodes it (`+` a space, then each `%XX`), however
  # well formed: what the VM sent needn't be, and a host may decode the
  # pairs it can and keep the rest.
  defp form_decoded(body), do: body |> String.replace("+", " ") |> Describe.percent_decoded()

  # Whether a header carries a JWT placeholder MWT wrote that isn't among
  # the made values it holds.
  defp unknown_made?(headers, made) do
    known = MapSet.new(made, & &1.placeholder)

    Enum.any?(headers, fn {_name, value} ->
      value
      |> Made.jwt_placeholders_in()
      |> Enum.any?(&(not MapSet.member?(known, &1)))
    end)
  end

  # A grant with no way out of its own goes wherever this machine routes;
  # one with an anchor only through it (`snapshot.via`, the interface this
  # machine routes the address through now).
  defp way_out?(%Grant{anchor: nil}, _snapshot), do: true
  defp way_out?(%Grant{anchor: anchor}, snapshot), do: Map.get(snapshot, :via) == anchor

  # A reserved address opens only for an entry that names it exactly; a
  # private or public one for any entry that covers it.
  defp opens?(spec, class, ip, port, resolve, answered) do
    Destinations.matches?(spec, ip, port, resolve, answered) and
      (class in [:private, :public] or Destinations.exact?(spec, ip))
  end

  # How exactly an entry names `ip`, as `{rank, length, ports?}`, more
  # being more exact: an address or a name alone (3), a name under a
  # wildcard by how long it is (2), a range by its prefix (1); one listing
  # ports before one taking any.
  defp exactness(%{match: match, ports: ports} = spec, ip) do
    {rank, length} =
      case match do
        {:host, name} -> {3, byte_size(name)}
        {:names, suffix} -> {2, byte_size(suffix)}
        {:cidr, _net, bits} -> if Destinations.exact?(spec, ip), do: {3, bits}, else: {1, bits}
      end

    {rank, length, ports != :any}
  end

  defp exactness(_internet, _ip), do: {0, 0, false}

  # A request's card: its driver's, made with it, for a protocol other
  # than HTTP (`MWTClient.Sandbox.Gate.authorize/2`); an HTTP request's
  # is worked out from it.
  defp about(%{about: about}), do: about
  defp about(request), do: Describe.request(request)

  # Yes or ask, by the grant's allowances.
  defp allow_or_ask(grant, now, about) do
    allowance = Enum.find(grant.allowances, &Allowance.covers?(&1, about.pattern, now))

    if allowance, do: {:allow, grant, allowance, about}, else: {:ask, grant, about}
  end

  # Whether the grant would ask for a use: no allowance of its covers it.
  defp asks?(grant, pattern, now),
    do: not Enum.any?(grant.allowances, &Allowance.covers?(&1, pattern, now))

  @doc """
  Whether `allowance`, added now, lets through the use `approval` holds:
  as it would have, had it been there when the use was asked. A use its
  grant's host list asks about takes only an allowance for uses like it
  (`host_ask/4`), never *Allow every use*; an add of MWT's tools past the
  hour's limit takes none, and its card has no pattern (`decide/3`). Any
  other use takes an allowance that covers its pattern, every use
  included, as `allow_or_ask/3` does for a new one.

  The card itself, the one you decided, is settled by your decision, not
  by this.

      iex> alias MWTClient.Sandbox.{Allowance, Approval, Policy}
      iex> now = ~U[2026-11-23 12:00:00Z]
      iex> every = %Allowance{id: "a", pattern: :all, until: nil}
      iex> card = %Approval{id: "c", kind: :request, title: "GET /", pattern: "GET h/",
      ...>   requested_at: now, deadline: now}
      iex> Policy.settles?(card, every, now)
      true
      iex> Policy.settles?(%{card | host_entry: "h"}, every, now)
      false
      iex> Policy.settles?(%{card | host_entry: "h"}, %{every | pattern: "GET h/"}, now)
      true
      iex> Policy.settles?(%{card | kind: :tool, pattern: nil}, every, now)
      false
  """
  @spec settles?(Approval.t(), Allowance.t(), DateTime.t()) :: boolean()
  def settles?(%Approval{} = approval, %Allowance{} = allowance, now) do
    cond do
      not Approval.use?(approval) -> false
      not Allowance.covers?(allowance, approval.pattern, now) -> false
      is_binary(approval.host_entry) -> allowance.pattern != :all
      # Every call of MWT's tools has a pattern but one past the hour's
      # limit; a request MWT couldn't describe has none too, and every use
      # covers that one.
      approval.kind == :tool and is_nil(approval.pattern) -> false
      true -> true
    end
  end

  # The grants over part of `network`.
  defp parts(grants, network) do
    for %Grant{kind: :network} = g <- grants,
        Network.part?(g),
        Network.id_of(g) == network,
        do: g
  end

  defp names?(grant, name) do
    Enum.any?(specs(grant), fn
      %{match: {kind, pattern}} when kind in [:host, :names] ->
        Destinations.name_covers?(kind, pattern, name)

      _range ->
        false
    end)
  end

  @doc """
  Whether MWT keeps what its DNS answered for `name`, so a connection to
  one of its addresses is judged by the name: a grant over part of a
  network that is on names it, or a network's limits take something away
  (`MWTClient.Sandbox.Gate.remember_listed/3`).
  """
  @spec remembers?([Grant.t()], %{String.t() => HostLimits.t()}, String.t(), DateTime.t()) ::
          boolean()
  def remembers?(grants, limits, name, now) do
    name = String.downcase(name)

    Enum.any?(Map.values(limits), &HostLimits.any?/1) or
      Enum.any?(grants, fn g ->
        g.kind == :network and Network.part?(g) and Grant.on?(g, now) and names?(g, name)
      end)
  end

  # The network grant on that opens `ip` and `port`, the one naming it
  # most exactly first, then the one letting it through, with what its
  # card says (`about`), or why none does.
  defp opening(%{grants: grants} = snapshot, ip, port, now) do
    class = Destinations.classify(ip, snapshot.own, Map.get(snapshot, :networks, []))
    pattern = "#{:inet.ntoa(ip)}:#{port}"
    answered = Map.get(snapshot, :answered)

    # Every network grant that would open it, on or off.
    opens =
      for %Grant{kind: :network} = grant <- grants,
          spec <- [opening_spec(grant, class, ip, port, snapshot.resolve, answered)],
          spec != nil,
          do: {grant, spec}

    candidates =
      opens
      |> Enum.filter(fn {grant, _spec} -> Grant.on?(grant, now) end)
      |> Enum.sort_by(
        fn {grant, spec} -> {exactness(spec, ip), not asks?(grant, pattern, now)} end,
        :desc
      )

    opening = Enum.find(candidates, fn {grant, _spec} -> way_out?(grant, snapshot) end)

    case {opening, class} do
      {{grant, spec}, _class} ->
        {:ok, grant, %{pattern: pattern, listed_as: spec.source}}

      {nil, _class} when candidates != [] ->
        {:refuse, {:network_down, candidates |> hd() |> elem(0)}}

      {nil, _class} when opens != [] ->
        {:refuse, {:grant_off, opens |> Enum.max_by(&exactness(elem(&1, 1), ip)) |> elem(0)}}

      {nil, :public} ->
        {:refuse, :internet_off}

      {nil, :refused} ->
        {:refuse, :reserved}

      {nil, :private} ->
        {:refuse, :private}
    end
  end

  # The entry of `grant` that opens the address, or nil: the Internet's
  # covers every public address.
  defp opening_spec(%Grant{internet: true}, class, _ip, _port, _resolve, _answered),
    do: if(class == :public, do: %{source: "Every public address"})

  defp opening_spec(grant, class, ip, port, resolve, answered) do
    case Enum.filter(specs(grant), &opens?(&1, class, ip, port, resolve, answered)) do
      [] -> nil
      specs -> Enum.max_by(specs, &exactness(&1, ip))
    end
  end

  # The names MWT's DNS answered for `ip`, as far as the snapshot knows.
  defp answered_names(snapshot, ip) do
    case Map.get(snapshot, :answered) do
      %{} = answered -> Map.get(answered, Destinations.unmap(ip), [])
      nil -> []
    end
  end

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""
end
