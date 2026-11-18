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
      grant}}`. Then an allowance for that address and port lets it
      through, or it asks; the Internet never asks, its every use allowed
      while it is on.
    * **A request** with no placeholder in its headers passes. A
      placeholder to a host its grant doesn't list is refused, in a header,
      the target or the start of the body; so is a request with two grants'
      placeholders in its headers. With one, every header carrying
      it must be one of the grant's carriers (`Grant.carriers/1`), and the
      grant must be on; then an allowance for uses like it, through the
      same carrier, lets it through, or it asks.
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
    Describe,
    Destinations,
    Grant,
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
          optional(:answered) => %{Destinations.ip() => [String.t()]},
          optional(:via) => String.t() | nil
        }

  @type use ::
          {:connection, Destinations.ip(), :inet.port_number()}
          | {:request, Describe.request()}
          | {:command, map()}
          | {:call, map()}
          | {:tool, map()}

  @type refusal ::
          :reserved
          | :private
          | :internet_off
          | :multiple_grants
          | {:wrong_host, Grant.t()}
          | {:not_a_carrier, Grant.t(), [String.t()]}
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
  (`MWTClient.Sandbox.Check.failing/3`).
  """
  @spec snapshot([Grant.t()], %{String.t() => String.t()}) :: snapshot()
  def snapshot(grants, failing \\ %{}) do
    %{
      grants: grants,
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
            spec =
              Enum.find(specs(grant), &opens?(&1, class, ip, port, snapshot.resolve, answered)),
            spec != nil,
            do: {grant, spec}
      end

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
    carried = Enum.filter(tokens, &Placeholder.in?(request.headers, &1.placeholder))

    # Only a header gets a value, but a placeholder anywhere in what MWT
    # read is a string moved where its grant doesn't go (QA L9).
    elsewhere =
      Enum.find(tokens, fn grant ->
        not host_listed?(request.host, grant.hosts) and
          (grant in carried or String.contains?(request.path, grant.placeholder) or
             String.contains?(request.body || "", grant.placeholder))
      end)

    case {carried, elsewhere} do
      {_, %Grant{} = elsewhere} ->
        {:refuse, {:wrong_host, elsewhere}}

      {[], nil} ->
        :pass

      {[_, _ | _], nil} ->
        {:refuse, :multiple_grants}

      {[grant], nil} ->
        carriers = Grant.carriers(grant)

        cond do
          # One kept from before: its value is only MWT's to send.
          Grant.subgrants_only?(grant) ->
            {:refuse, {:subgrants_only, grant}}

          (outside = Placeholder.outside(request.headers, grant.placeholder, carriers)) != [] ->
            {:refuse, {:not_a_carrier, grant, outside}}

          why = failing(snapshot, grant) ->
            {:refuse, {:check_failing, grant, why}}

          not Grant.on?(grant, now) ->
            {:refuse, {:grant_off, grant}}

          true ->
            carrier = Placeholder.carrier(request.headers, grant.placeholder, carriers)
            about = request |> Describe.request() |> Describe.carried_in(carrier)
            allow_or_ask(grant, now, about)
        end
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

  # A grant that always asks asks, whatever allowance it was left with.
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
