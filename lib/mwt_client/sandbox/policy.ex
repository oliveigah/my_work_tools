defmodule MWTClient.Sandbox.Policy do
  @moduledoc """
  What MWT answers to one use the VM makes of a grant: a connection to an
  address, a request carrying a placeholder, a command for this machine.

  `decide/3` is pure. Its answer depends on the grants, the use and the
  clock it is given, and on nothing else: it holds nobody, logs nothing and never
  sees a real value. `MWTClient.Sandbox.Server` asks it and acts on the
  answer, so the rules are checked on their own, for every combination
  (`test/mwt_client/sandbox/policy_test.exs`).

  | Answer                              | The server then                                    |
  | ----------------------------------- | -------------------------------------------------- |
  | `:pass`                             | lets it through: no grant has a say                |
  | `{:allow, grant, allowance, about}` | lets it through, with the real value for a request |
  | `{:ask, grant, about}`              | holds it for you                                   |
  | `{:refuse, reason}`                 | refuses it, and says why                           |

  The rules, in the order they are tried:

    * **A connection** to a public address is the Internet's
      (`Grant.internet/0`) while it is on; with it off, a network grant that
      is on and lists the address opens it, and nothing else does
      (`{:refuse, :internet_off}`: a token grant's host may still be read,
      by name, `MWTClient.Sandbox.Gate`). One to this machine or a
      reserved range needs a network grant that is on and names that exact
      address; one to a private range needs a network grant that is on and
      lists it. The Internet opens neither. A name a network grant lists
      covers only the addresses MWT's DNS answered for it
      (`snapshot.answered`); a grant with a way out of its own
      (`Grant.anchor`) opens nothing while this machine doesn't route the
      address through it (`snapshot.via`): `{:refuse, {:network_down,
      grant}}`. Of two grants that open it, the one whose entry says it
      most exactly goes first: an exact address or name, then the longest
      name under a wildcard, then the narrowest range, an entry naming
      ports before one that doesn't; on a tie, the one that would ask.
      Then an allowance for that address and port lets it through, or it
      asks; the Internet never asks, its every use allowed while it is on.
    * **A request on a connection a network grant opened**
      (`{:network_request, request}`, its `under` the grant) is that
      grant's to allow, as its connections are: an allowance for requests
      like it (`MWTClient.Sandbox.Describe`), or every use, lets it
      through, or it asks. A placeholder in it is then the token grant's,
      by the rules below.
    * **A request** with no placeholder in its headers passes, but on a
      connection only a token grant's host may use (`under: :read_only`,
      the Internet off) only while a grant listing that host is on: with
      the Internet off, a host reached because a grant lists it is reached
      for that grant. A
      placeholder to a host its grant doesn't list is refused, in a header,
      the target or the start of the body; so is a request with two grants'
      placeholders in its headers. With one, every header carrying
      it must be one of the grant's carriers (`Grant.carriers/1`), and the
      grant must be on; then an allowance for uses like it, through the
      same carrier, lets it through, or it asks. A value made from a
      grant's (`snapshot.made`, `MWTClient.Sandbox.Made`) is that grant's
      use, with hosts and carriers of its own, narrower than the grant's;
      one MWT no longer holds, or whose grant no longer covers it, is
      refused, `{:made_stale, made}`, rather than sent as it is.
    * **A call of a request subgrant** needs that subgrant, named by its
      exact id, on by its own switch, under a token grant that lists the
      host it sends to. It asks unless an allowance for every use covers
      it (*Auto-approve*, or enabled on startup with *Enabled, auto*).
    * **A command** needs a command grant, named by its exact id, that is on.
      One with a script of yours takes no text from the agent. It always
      asks: no allowance covers a command.
    * **A grant a gating check holds off** (`snapshot.failing`,
      `MWTClient.Sandbox.Check`) refuses every use `{:check_failing,
      grant, why}`; a network grant paused opens nothing.
    * **A call of MWT's tools** from the VM needs the built-in grant for
      what it does (reading, creating or changing) to be on. Then an
      allowance lets it through (*Enabled, auto*, *Auto-approve*, or for a
      change, changes to the same item), or it asks. Adding past the hour's
      limit asks whatever the allowances say (`MWTClient.Sandbox.MwtTools`).

  A grant whose ceiling is `:ask` (`Grant.ceiling/1`) asks for every use,
  whatever allowance it holds. Refusals stay refusals.
  """

  alias MWTClient.Sandbox.{
    Allowance,
    CredentialEndpoint,
    Describe,
    Destinations,
    Grant,
    Made,
    MwtTools,
    Placeholder,
    SavedRequest
  }

  @typedoc """
  What a decision reads: the grants, this machine's own addresses and
  networks, and how a host name in a network grant resolves here.
  """
  @type snapshot :: %{
          required(:grants) => [Grant.t()],
          required(:own) => [Destinations.ip()],
          optional(:networks) => [{Destinations.ip(), non_neg_integer()}],
          required(:resolve) => (String.t() -> [Destinations.ip()]),
          optional(:failing) => %{String.t() => String.t()},
          optional(:made) => [Made.t()],
          optional(:answered) => %{Destinations.ip() => [String.t()]},
          optional(:via) => String.t() | nil
        }

  @type use ::
          {:connection, Destinations.ip(), :inet.port_number()}
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
          | {:subgrants_only, Grant.t()}
          | {:check_failing, Grant.t(), String.t()}
          | {:network_down, Grant.t()}
          | :no_command_grant
          | {:name_a_grant, [String.t()]}
          | {:no_such_grant, [String.t()]}
          | {:fixed_script, Grant.t()}
          | :no_mwt_grant

  @type answer ::
          :pass
          | {:allow, Grant.t(), Allowance.t(), map()}
          | {:ask, Grant.t(), map()}
          | {:refuse, refusal()}

  @doc """
  The snapshot of these grants on this machine, as it is now, with the
  grants a gating check holds off, each with why
  (`MWTClient.Sandbox.Check.failing/3`), and the values made from them
  (`MWTClient.Sandbox.Made`), without their values.
  """
  @spec snapshot([Grant.t()], %{String.t() => String.t()}, [Made.t()]) :: snapshot()
  def snapshot(grants, failing \\ %{}, made \\ []) do
    %{
      grants: grants,
      made: Enum.map(made, &Made.unvalued/1),
      own: Destinations.host_addresses(),
      networks: MWTClient.Sandbox.Routes.networks(),
      resolve: &Destinations.resolve/1,
      failing: failing
    }
  end

  @doc """
  Decides one use at `now`.

  `about` is what an approval shows and what an allowance is matched on. For
  a connection: `pattern` (`address:port`) and `listed_as`, the grant's entry
  that covers it. For a request: `MWTClient.Sandbox.Describe.request/1`. For
  a command: the grant's `script` and `dir`, both nil when the agent sends
  the text.
  """
  @spec decide(snapshot(), use(), DateTime.t()) :: answer()
  def decide(%{grants: grants} = snapshot, {:connection, ip, port}, now) do
    class = Destinations.classify(ip, snapshot.own, Map.get(snapshot, :networks, []))
    pattern = "#{:inet.ntoa(ip)}:#{port}"
    internet = Enum.find(grants, &Grant.internet?/1)

    answered = Map.get(snapshot, :answered)

    # The network grants on that open it; one with a way out of its own
    # (`Grant.anchor`) only while this machine routes the address through
    # it.
    candidates =
      if (class == :public and internet) && live?(snapshot, internet, now) do
        [{internet, %{source: "Every public address"}}]
      else
        for %Grant{kind: :network, internet: false} = grant <- grants,
            live?(snapshot, grant, now),
            specs =
              Enum.filter(specs(grant), &opens?(&1, class, ip, port, snapshot.resolve, answered)),
            specs != [],
            do: {grant, Enum.max_by(specs, &exactness(&1, ip))}
      end
      |> Enum.sort_by(
        fn {grant, spec} ->
          {exactness(spec, ip), asks?(grant, pattern, now)}
        end,
        :desc
      )

    opening = Enum.find(candidates, fn {grant, _spec} -> way_out?(grant, snapshot) end)

    case {opening, class} do
      {nil, _class} when candidates != [] ->
        {:refuse, {:network_down, candidates |> hd() |> elem(0)}}

      {nil, :public} ->
        {:refuse, :internet_off}

      {nil, :refused} ->
        {:refuse, :reserved}

      {nil, :private} ->
        {:refuse, :private}

      {{grant, spec}, _class} ->
        allow_or_ask(grant, now, %{pattern: pattern, listed_as: spec.source})
    end
  end

  def decide(%{grants: grants} = snapshot, {:request, request}, now) do
    tokens = for %Grant{kind: :token, placeholder: p} = grant <- grants, is_binary(p), do: grant
    made = Map.get(snapshot, :made, [])
    carried = Enum.filter(tokens, &Placeholder.in?(request.headers, &1.placeholder))
    made_carried = Enum.filter(made, &Placeholder.in?(request.headers, &1.placeholder))

    # Only a header gets a value, but a placeholder anywhere in what MWT
    # read is a string moved where its grant doesn't go (QA L9).
    moved? = fn placeholder, hosts, in_headers? ->
      not host_listed?(request.host, hosts) and
        (in_headers? or String.contains?(request.path, placeholder) or
           String.contains?(request.body || "", placeholder))
    end

    elsewhere = Enum.find(tokens, &moved?.(&1.placeholder, &1.hosts, &1 in carried))
    made_elsewhere = Enum.find(made, &moved?.(&1.placeholder, &1.hosts, &1 in made_carried))

    # A login's placeholder belongs only in the body of a refresh at
    # Google's token endpoint, which MWT answers
    # (`MWTClient.Sandbox.CredentialEndpoint`): there it makes the request
    # its grant's; anywhere else it is moved where it doesn't go.
    refresh? = CredentialEndpoint.token_request?(request)
    # A form body carries it percent-encoded (`1%2F%2F…`).
    body = request.body || ""
    bodies = [body, form_decoded(body)]

    logins =
      for %Grant{} = grant <- tokens,
          login = Grant.login_placeholder(grant),
          is_binary(login),
          do: {grant, login}

    in_body? = fn login -> Enum.any?(bodies, &String.contains?(&1, login)) end
    login_carried = for {grant, login} <- logins, refresh?, in_body?.(login), do: grant

    login_moved =
      Enum.find_value(logins, fn {grant, login} ->
        if Placeholder.in?(request.headers, login) or String.contains?(request.path, login) or
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

    cond do
      elsewhere ->
        {:refuse, {:wrong_host, elsewhere}}

      login_moved ->
        {:refuse, {:wrong_host, login_moved}}

      made_elsewhere ->
        {:refuse, {:made_elsewhere, made_elsewhere}}

      stale ->
        {:refuse, {:made_stale, if(stale == :unknown, do: nil, else: stale)}}

      owners == [] ->
        if Map.get(request, :under) == :read_only,
          do: listing_live(snapshot, grants, request.host, now),
          else: :pass

      match?([_, _ | _], owners) ->
        {:refuse, :multiple_grants}

      true ->
        [grant] = owners
        carriers = Grant.carriers(grant)

        # Each placeholder only in the headers its value goes in: the
        # grant's own in its carriers, a made one in its own.
        outside =
          if(grant in carried,
            do: [{Placeholder.outside(request.headers, grant.placeholder, carriers), carriers}],
            else: []
          ) ++
            for(
              m <- made_carried,
              do: {Placeholder.outside(request.headers, m.placeholder, m.carriers), m.carriers}
            )

        cond do
          # One kept from before: its value is only MWT's to send.
          Grant.subgrants_only?(grant) ->
            {:refuse, {:subgrants_only, grant}}

          (wrong = Enum.find(outside, fn {headers, _carriers} -> headers != [] end)) != nil ->
            {headers, carriers} = wrong
            {:refuse, {:not_a_carrier, grant, headers, carriers}}

          why = failing(snapshot, grant) ->
            {:refuse, {:check_failing, grant, why}}

          not Grant.on?(grant, now) ->
            {:refuse, {:grant_off, grant}}

          true ->
            carrier =
              Placeholder.carrier(request.headers, grant.placeholder, carriers) ||
                Enum.find_value(
                  made_carried,
                  &Placeholder.carrier(request.headers, &1.placeholder, &1.carriers)
                )

            about = Describe.request(request)
            # A refresh carries the login in its body, not in a header.
            about = if carrier, do: Describe.carried_in(about, carrier), else: about
            allow_or_ask(grant, now, about)
        end
    end
  end

  def decide(%{grants: grants} = snapshot, {:network_request, request}, now) do
    case Enum.find(grants, &(&1.id == Map.get(request, :under) and &1.kind == :network)) do
      %Grant{internet: false} = grant ->
        cond do
          why = failing(snapshot, grant) -> {:refuse, {:check_failing, grant, why}}
          not Grant.on?(grant, now) -> {:refuse, {:grant_off, grant}}
          true -> allow_or_ask(grant, now, about(request))
        end

      # The Internet's, or a token grant's host with the Internet off.
      _not_a_network_grant ->
        :pass
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

      grant ->
        parent = Enum.find(grants, &(&1.id == grant.parent and &1.kind == :token))

        cond do
          is_nil(parent) ->
            {:refuse, {:no_such_grant, ids}}

          why = failing(snapshot, grant) || failing(snapshot, parent) ->
            {:refuse, {:check_failing, grant, why}}

          not Grant.on?(grant, now) ->
            {:refuse, {:grant_off, grant}}

          not host_listed?(SavedRequest.host(grant), parent.hosts) ->
            {:refuse, {:wrong_host, parent}}

          true ->
            {:ask, grant, %{parent: parent}}
        end
    end
  end

  def decide(%{grants: grants} = snapshot, {:command, ask}, now) do
    commands = Enum.filter(grants, &(&1.kind == :command))
    ids = Enum.map(commands, & &1.id)
    wanted = ask |> Map.get(:grant) |> text() |> String.trim()

    # By its exact id: a name is not enough to run something.
    grant = Enum.find(commands, &(&1.id == wanted))

    cond do
      commands == [] ->
        {:refuse, :no_command_grant}

      wanted == "" ->
        {:refuse, {:name_a_grant, ids}}

      is_nil(grant) ->
        {:refuse, {:no_such_grant, ids}}

      why = failing(snapshot, grant) ->
        {:refuse, {:check_failing, grant, why}}

      not Grant.on?(grant, now) ->
        {:refuse, {:grant_off, grant}}

      is_nil(grant.script) ->
        {:ask, grant, %{script: nil, dir: nil}}

      ask |> Map.get(:script) |> text() |> String.trim() != "" ->
        {:refuse, {:fixed_script, grant}}

      true ->
        {:ask, grant, %{script: grant.script, dir: grant.dir}}
    end
  end

  def decide(%{grants: grants} = snapshot, {:tool, use}, now) do
    case Enum.find(grants, &(&1.kind == :mwt and &1.tools == use.grant)) do
      nil ->
        {:refuse, :no_mwt_grant}

      grant ->
        about = MwtTools.about(use)

        cond do
          why = failing(snapshot, grant) ->
            {:refuse, {:check_failing, grant, why}}

          not Grant.on?(grant, now) ->
            {:refuse, {:grant_off, grant}}

          Map.get(use, :over_limit, false) ->
            {:ask, grant, about}

          true ->
            allow_or_ask(grant, now, about)
        end
    end
  end

  # With the Internet off, a request with no placeholder goes to a token
  # grant's host only while a grant listing it is on and no check holds it
  # off; otherwise the first one listing it says why.
  defp listing_live(snapshot, grants, host, now) do
    listing =
      Enum.filter(
        grants,
        &(&1.kind == :token and not Grant.subgrants_only?(&1) and host_listed?(host, &1.hosts))
      )

    cond do
      Enum.any?(listing, &live?(snapshot, &1, now)) ->
        :pass

      listing == [] ->
        {:refuse, :internet_off}

      grant = Enum.find(listing, &failing(snapshot, &1)) ->
        {:refuse, {:check_failing, grant, failing(snapshot, grant)}}

      true ->
        {:refuse, {:grant_off, hd(listing)}}
    end
  end

  @doc """
  Whether connections to `host` are read instead of tunnelled: some token
  grant the VM wields lists it, on or off. An off grant's host is still
  read, so its placeholder is refused with a reason instead of going out
  as it is. A grant only its subgrants use is not counted: less of the
  VM's traffic is read.
  """
  @spec reads?([Grant.t()], String.t() | nil) :: boolean()
  def reads?(grants, host),
    do:
      Enum.any?(
        grants,
        &(&1.kind == :token and not Grant.subgrants_only?(&1) and host_listed?(host, &1.hosts))
      )

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

  # A form body decoded, or as it is when it isn't one: what the VM sent
  # needn't be well formed.
  defp form_decoded(body) do
    URI.decode_www_form(body)
  rescue
    ArgumentError -> body
  end

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

  # Whether the grant would ask for a use: it always does, or no
  # allowance of its covers it.
  defp asks?(grant, pattern, now) do
    Grant.ceiling(grant) == :ask or
      (not (grant.internet and grant.state == :on) and
         not Enum.any?(grant.allowances, &Allowance.covers?(&1, pattern, now)))
  end

  # A grant that always asks asks, whatever allowance it was left with.
  # A request's card: its driver's, made with it, for a protocol other
  # than HTTP (`MWTClient.Sandbox.Gate.authorize/2`); an HTTP request's
  # is worked out from it.
  defp about(%{about: about}), do: about
  defp about(request), do: Describe.request(request)

  defp allow_or_ask(grant, now, about) do
    allowance =
      Grant.ceiling(grant) != :ask &&
        Enum.find(grant.allowances, &Allowance.covers?(&1, about.pattern, now))

    cond do
      Grant.ceiling(grant) == :ask ->
        {:ask, grant, about}

      allowance ->
        {:allow, grant, allowance, about}

      # The Internet on asks nothing, its allowance or not (a state saved
      # by hand, a mode set before it was its own).
      grant.internet and grant.state == :on ->
        {:allow, grant, %Allowance{id: "internet", pattern: :all, until: nil}, about}

      true ->
        {:ask, grant, about}
    end
  end

  # Why a gating check holds the grant off, or nil (`MWTClient.Sandbox.Check`).
  defp failing(snapshot, %Grant{id: id}), do: snapshot |> Map.get(:failing, %{}) |> Map.get(id)

  # Lets uses through: on, by the clock, and no check holds it off.
  defp live?(snapshot, grant, now),
    do: is_nil(failing(snapshot, grant)) and Grant.on?(grant, now)

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""
end
