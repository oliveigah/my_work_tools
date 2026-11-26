defmodule MWTClient.Sandbox.Server.Grants do
  @moduledoc """
  The grants in the sandbox server's state: building one from a form and
  saying what is wrong with it, turning one on, adding an allowance, and
  turning off the ones whose time ran out.

  Runs in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.Decision

  alias MWTClient.Sandbox.{
    Allowance,
    Approval,
    Credential,
    Destinations,
    Dns,
    Grant,
    HostCommand,
    Network,
    Param,
    Policy,
    Presets,
    SavedRequest,
    Shown
  }

  alias MWTClient.Sandbox.Server.{Approvals, Firewall, HostRuns, State}

  @doc """
  Adds an allowance to an on grant, and lets through every use waiting on
  it that the allowance covers.
  """
  # Commands agents write takes none: every run waits for you
  # (`Grant.always_asks?/1`).
  def allow(state, grant, pattern, duration, origin \\ %{kind: :you})

  def allow(state, %Grant{kind: :agent_commands}, _pattern, _duration, _origin), do: state

  def allow(state, grant, pattern, duration, origin) do
    allowance = %Allowance{
      id: "allowance-" <> State.unique(),
      pattern: pattern,
      origin: Map.put_new(origin, :at, State.now()),
      until:
        if(duration == :grant, do: nil, else: DateTime.add(State.now(), duration * 60, :second))
    }

    if allowance.until,
      do: State.timer({:expire_allowance, grant.id, allowance.id}, allowance.until)

    # Only what it would have let through, asked now: never a use a host
    # list holds for asking, nor an add past the hour's limit. A card that
    # answers for several grants settles once every one of them would let
    # its use through.
    now = State.now()

    state =
      state.approvals
      |> Enum.filter(fn other ->
        other.status == :waiting and grant.id in Approval.grant_ids(other) and
          Policy.settles?(other, allowance, now) and
          Enum.all?(Approval.grant_ids(other) -- [grant.id], fn id ->
            case Enum.find(state.grants, &(&1.id == id)) do
              %Grant{} = g ->
                Enum.any?(g.allowances, &Policy.settles?(other, &1, now))

              nil ->
                true
            end
          end)
      end)
      |> Enum.reduce(state, fn other, acc ->
        how = if pattern == :all, do: "every use", else: "similar"

        acc
        |> Approvals.settle(
          other,
          :allowed,
          {:allow, if(pattern == :all, do: :all, else: :similar), duration}
        )
        |> State.log(
          Approvals.event_for(
            other,
            :allowed,
            "you allowed #{how} #{State.duration_words(duration)}",
            Decision.allowance(grant, allowance)
          )
        )
        |> Approvals.answer_waiters(other, :allow)
      end)

    grant = Enum.find(state.grants, &(&1.id == grant.id))
    state = State.replace_grant(state, %{grant | allowances: grant.allowances ++ [allowance]})

    # Runs of a saved command waiting for you go now, as the next would.
    state.approvals
    |> Enum.filter(&(&1.status == :waiting and &1.kind == :command and &1.grant_id == grant.id))
    |> Enum.reduce(state, &HostRuns.auto_approve(&2, &1))
    |> State.changed()
  end

  @doc """
  Saves a grant an agent proposed (`MWTClient.Sandbox.Server.Approvals.proposal/2`):
  off, to review. One that replaces an earlier proposal of the same name
  keeps its id, and that one's place in the list.
  """
  def save_proposed(state, %Grant{} = grant, previous) do
    {grants, words} =
      case previous do
        nil ->
          {state.grants ++ [grant], "proposed by #{grant.proposal.agent}"}

        %Grant{id: id} ->
          {Enum.map(state.grants, &if(&1.id == id, do: grant, else: &1)),
           "proposal changed by #{grant.proposal.agent}"}
      end

    grant =
      if grant.kind == :token,
        do: %{grant | credential: grant.credential || grant.id},
        else: grant

    state
    |> State.change(:grants, fn _ ->
      Enum.map(grants, &if(&1.id == grant.id, do: grant, else: &1))
    end)
    |> put_credential_of(grant)
    |> put_network_of(grant)
    |> State.log(%{
      outcome: :grant,
      summary: "#{grant.name} #{words} · to review",
      grant_id: grant.id,
      details: if(previous, do: Grant.changes(previous, grant), else: [])
    })
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  You accepted a grant an agent proposed: reviewed, yours from now on, to
  turn on, edit and remove as any other.
  """
  def review(state, %Grant{proposal: %{} = proposal} = grant) do
    reviewed = %{grant | proposal: %{proposal | reviewed_at: State.now()}}

    state
    |> State.replace_grant(reviewed)
    |> State.log(%{
      outcome: :grant,
      summary: "#{grant.name} accepted by you",
      grant_id: grant.id
    })
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  Removes a grant, with what waited on it and what was made from it;
  `summary` is what the log says. Its resource stays: a resource goes only
  when you remove it (`MWTClient.Sandbox.Server.Resources.delete/2`).
  """
  def delete(state, %Grant{id: id} = grant, summary) do
    gone = [id]

    # One still to review: the agent waiting on it hears you declined it.
    state =
      if Grant.to_review?(grant),
        do:
          state.approvals
          |> Enum.filter(
            &(&1.status == :waiting and &1.kind == :activation and &1.grant_id == id)
          )
          |> Enum.reduce(state, &Approvals.decide(&2, &1, :decline)),
        else: state

    gone
    |> Enum.reduce(state, fn id, state ->
      state
      |> Approvals.settle_waiting(id, :grant_off, [
        :activation,
        :request,
        :connection,
        :tool,
        :command
      ])
      |> Map.update(:made, %{}, &MWTClient.Sandbox.Made.drop_grant(&1, id))
    end)
    |> State.change(:grants, &Enum.reject(&1.grants, fn g -> g.id in gone end))
    # Gone from the state, so the grant as it was goes with the event.
    |> State.log(%{outcome: :grant, summary: summary, details: Grant.details(grant)})
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  A grant from its form, over the resource it names, as you add one and as
  an agent proposes one: over a credential you have (`"credential"`), its
  value and how it is made are the credential's, and only its own scope
  comes from the form; over a network you have (`"network"`), all of it or
  the destinations the form lists; else a new one, as the form says.
  `{:ok, grant, value}`, the value pasted for a new credential, or
  `{:error, errors}` by field. Nothing is saved.
  """
  def build_new(state, attrs, preset, opts \\ []) do
    credentials = Map.get(state, :credentials, [])

    over =
      if attrs["kind"] == "token",
        do: Enum.find(credentials, &(&1.id == attrs["credential"]))

    attrs = if over, do: credential_attrs(attrs, over), else: attrs

    case build_grant(
           attrs,
           state.grants,
           [preset: preset, valueless: over != nil, credentials: credentials] ++ opts
         ) do
      {:ok, grant, value} ->
        grant =
          cond do
            over -> Credential.attach(grant, over)
            grant.kind == :token -> %{grant | credential: grant.id}
            true -> grant
          end

        {:ok, over_network(state, grant, attrs), if(over, do: nil, else: value)}

      {:error, errors} ->
        {:error, errors}
    end
  end

  # One over a network you already have: over all of it, or over the hosts
  # its form lists (`scope`).
  defp over_network(state, %Grant{kind: :network} = grant, %{"network" => id})
       when is_binary(id) and id != "" do
    case Enum.find(Map.get(state, :networks, []), &(&1.id == id)) do
      nil ->
        grant

      network ->
        scope = if attrs_part?(grant, network), do: grant.destinations

        Network.attach(%{grant | network: network.id, scope: scope, internet: false}, network)
    end
  end

  defp over_network(_state, grant, _attrs), do: grant

  # A grant whose form lists destinations other than its network's is over
  # those alone.
  defp attrs_part?(grant, network),
    do: grant.destinations != [] and grant.destinations != network.destinations

  # A form for a grant over an existing credential: how its value is made
  # is the credential's, so the form's own fields for it give way.
  defp credential_attrs(attrs, %Credential{} = credential) do
    minted =
      case credential.source do
        {:minted, command} -> %{"source" => "minted", "mint" => command}
        :stored -> %{"source" => "stored"}
      end

    Map.merge(attrs, minted)
  end

  @doc """
  Keeps a token grant's credential in step with it: what the grant says of
  how its value is made and shown (`Credential.copied/0`) is its
  credential's, and every grant over that credential gets it too
  (`Credential.attach_all/2`). One with no credential yet gets one of its
  own, under its id. Name, words, lock and earlier placeholders stay the
  credential's.
  """
  def put_credential_of(state, %Grant{kind: :token} = grant) do
    id = Grant.credential_id(grant)
    credentials = Map.get(state, :credentials, [])

    credential =
      case Enum.find(credentials, &(&1.id == id)) do
        nil ->
          %{Credential.of_grant(grant) | id: id}

        existing ->
          fields =
            Map.take(Map.from_struct(grant), Credential.copied() -- [:aliases, :login_aliases])

          struct(existing, fields)
      end

    credentials =
      if Enum.any?(credentials, &(&1.id == id)),
        do: Enum.map(credentials, &if(&1.id == id, do: credential, else: &1)),
        else: credentials ++ [credential]

    state
    |> Map.put(:credentials, credentials)
    |> State.change(:grants, &Credential.attach_all(&1.grants, credentials))
  end

  # A request action takes its credential's fields as it is added or
  # edited, as the grants over that credential do: how its value is made.
  def put_credential_of(state, %Grant{kind: :request}) do
    credentials = Map.get(state, :credentials, [])
    State.change(state, :grants, &Credential.attach_all(&1.grants, credentials))
  end

  def put_credential_of(state, _grant), do: state

  @doc """
  The network a network grant just added or edited is over, made or
  brought up to date (`MWTClient.Sandbox.Network`): one over all of it
  says what the network is (its destinations, DNS server and interface);
  one over part of it keeps its destinations as its scope. The Internet is
  MWT's: no grant changes it. Every grant over the network takes its
  fields again.
  """
  def put_network_of(state, %Grant{kind: :network} = grant) do
    id = Network.id_of(grant)
    networks = Map.get(state, :networks, [])
    existing = Enum.find(networks, &(&1.id == id))

    network =
      cond do
        Network.part?(grant) and existing ->
          existing

        Network.part?(grant) ->
          %{Network.of_grant(grant) | id: id, destinations: grant.destinations}

        existing && existing.internet ->
          existing

        existing ->
          %{
            existing
            | destinations: grant.destinations,
              resolver: grant.resolver,
              anchor: grant.anchor
          }

        true ->
          %{Network.of_grant(grant) | id: id}
      end

    networks =
      if existing,
        do: Enum.map(networks, &if(&1.id == id, do: network, else: &1)),
        else: networks ++ [network]

    # One over part of the network takes what its form lists as its scope.
    state =
      if Network.part?(grant),
        do: State.replace_grant(state, %{grant | scope: grant.destinations, network: id}),
        else: State.replace_grant(state, %{grant | network: id})

    state
    |> Map.put(:networks, networks)
    |> State.change(:grants, &Network.attach_all(&1.grants, networks))
  end

  def put_network_of(state, _grant), do: state

  @doc """
  Drops what MWT minted for a grant (each host's too), the ID tokens its
  mint printed, and the values made from them (`MWTClient.Sandbox.Made`):
  as it is removed, or once how its value is made changed
  (`Grant.how_made/1`), so the next use mints again. A stored value stays:
  it is yours, replaced only on its page. A mint still running when this
  runs keeps its result: it ends within 30 seconds.
  """
  def forget_values(state, id) do
    state
    |> Map.update!(:minted, fn minted ->
      Map.reject(minted, fn {key, _} -> key == id or match?({^id, _host}, key) end)
    end)
    |> Map.update(:id_tokens, %{}, fn id_tokens ->
      Map.reject(id_tokens, fn {key, _} -> key == id or match?({^id, _host}, key) end)
    end)
    |> Map.update(:made, %{}, &MWTClient.Sandbox.Made.drop_grant(&1, id))
  end

  @doc """
  What an edit from its form changes beyond the grant itself (`edit_grant/3`
  makes `updated` from `before`): how its value is made changed, what was
  minted and made from the old one goes (`forget_values/2`); what a run or
  a call of it carries out changed (`Grant.definition/1`), the cards still
  waiting on it are refused (`:changed`), since they say what the old one
  did.
  """
  def edited(state, %Grant{id: id} = before, %Grant{} = updated) do
    state =
      if Grant.how_made(before) != Grant.how_made(updated),
        do: forget_values(state, Grant.credential_id(updated)),
        else: state

    if Grant.definition(before) != Grant.definition(updated),
      do: Approvals.settle_waiting(state, id, :changed, [:command]),
      else: state
  end

  @doc """
  Why `grant` can't turn on now, or nil: proposed and not accepted yet
  (`:to_review`); over a resource an agent proposed that you haven't
  accepted (`:resource_to_review`); over a credential whose value you
  haven't pasted (`:no_value`), so every use would be refused.
  """
  @spec turn_on_refusal(map(), Grant.t()) :: nil | :to_review | :resource_to_review | :no_value
  def turn_on_refusal(state, %Grant{} = grant) do
    resource = Grant.resource(grant)
    credentials = Map.get(state, :credentials, [])

    cond do
      Grant.to_review?(grant) ->
        :to_review

      MWTClient.Sandbox.Resource.to_review?(resource, credentials, Map.get(state, :networks, [])) ->
        :resource_to_review

      grant.kind in [:token, :request] and stored?(credentials, grant) and
          not Map.has_key?(state.values, Grant.credential_id(grant)) ->
        :no_value

      true ->
        nil
    end
  end

  defp stored?(credentials, grant) do
    case Enum.find(credentials, &(&1.id == Grant.credential_id(grant))) do
      %Credential{source: :stored} -> true
      %Credential{} -> false
      nil -> grant.source == :stored
    end
  end

  @doc """
  Turns a grant on for `minutes` (or `:until_off`); `:all` also lets every
  use through for as long as it stays on.
  """
  def turn_on(state, grant, minutes, uses, why, decision \\ nil)

  def turn_on(state, nil, _minutes, _uses, _why, _decision), do: state

  def turn_on(state, grant, minutes, uses, why, decision) do
    uses = if Grant.always_asks?(grant), do: :ask, else: uses
    grant = %{grant | state: :on, expires_at: expires_at(minutes), minutes: minutes}
    State.schedule_expiry(grant)

    state =
      state
      |> State.replace_grant(grant)
      |> State.log(%{
        decision: decision,
        outcome: :grant,
        summary:
          "#{grant.name} turned on #{State.duration_words(minutes)}" <>
            if(uses == :all, do: ", auto-approve", else: "") <> why,
        grant_id: grant.id
      })
      |> State.write_inbox()
      |> State.changed()

    if uses == :all, do: allow(state, grant, :all, :grant, %{kind: :auto}), else: state
  end

  @doc """
  Gives a grant that is on a new duration, counted from now: `minutes`, or
  `:until_off`. It stays on, its approval mode as it was.
  """
  def set_duration(state, %Grant{} = grant, minutes) do
    grant = %{grant | expires_at: expires_at(minutes), minutes: minutes}
    State.schedule_expiry(grant)

    state
    |> State.replace_grant(grant)
    |> State.log(%{
      outcome: :grant,
      summary: "#{grant.name} now on #{State.duration_words(minutes)}",
      grant_id: grant.id
    })
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  Changes how the uses of a grant that is on are approved: `:all`
  auto-approves every use while it stays on, `:ask` makes each wait for
  you again. It stays on, for as long as it was.
  """
  def set_mode(state, %Grant{} = grant, :all) do
    if Grant.auto_approved?(grant, State.now()) or Grant.always_asks?(grant) do
      state
    else
      state
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: auto-approve while on",
        grant_id: grant.id
      })
      |> allow(grant, :all, :grant, %{kind: :auto})
      |> State.write_inbox()
    end
  end

  def set_mode(state, %Grant{} = grant, :ask) do
    if Enum.any?(grant.allowances, &(&1.pattern == :all)) do
      state
      |> State.replace_grant(%{
        grant
        | allowances: Enum.reject(grant.allowances, &(&1.pattern == :all))
      })
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: asks each time",
        grant_id: grant.id
      })
      |> State.write_inbox()
      |> State.changed()
    else
      state
    end
  end

  @doc """
  Puts every grant in the state its `start` setting names, as MWT starts:
  off, or on until turned off, every use asking (`:on`) or going through
  (`:auto`). Nothing a session left carries over: no time left, no
  allowance.
  """
  def start(grants), do: Enum.map(grants, &started/1)

  defp started(%Grant{} = grant) do
    case start_of(grant) do
      :off -> Grant.put_down(grant)
      :on -> %{Grant.put_down(grant) | state: :on, minutes: :until_off}
      :auto -> %{Grant.put_down(grant) | state: :on, minutes: :until_off, allowances: [always()]}
    end
  end

  # A setting saved before the grant could no longer take it counts as the
  # nearest one it can.
  defp start_of(%Grant{start: start} = grant) do
    cond do
      start in Grant.starts(grant) -> start
      start == :auto and :on in Grant.starts(grant) -> :on
      true -> :off
    end
  end

  @doc "Whether a start setting leaves the grant on as MWT starts."
  def starts_on?(start), do: start in [:on, :auto]

  defp always,
    do: %Allowance{
      id: "allowance-" <> State.unique(),
      pattern: :all,
      until: nil,
      origin: %{kind: :start, at: State.now()}
    }

  @doc """
  Sets the state a grant is in when MWT starts, and puts it in that state
  now: what waited on a grant that goes off is refused, and a saved
  command's runs that waited go once it is enabled and auto-approved.
  """
  def set_start(state, %Grant{} = grant, start) do
    words = %{
      off: "off",
      on: "enabled, every use asking",
      auto: "enabled, every use auto-approved"
    }

    state =
      if not starts_on?(start) and grant.state == :on,
        do: Approvals.settle_waiting(state, grant.id, :grant_off),
        else: state

    updated = started(%{grant | start: start})

    state =
      state
      |> State.replace_grant(updated)
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: #{words[start]}, from now and each time MWT starts",
        grant_id: grant.id
      })
      |> then(fn state ->
        # Enabled now: that answers the agents waiting for it. Off or
        # disabled answers nobody.
        if not starts_on?(start),
          do: state,
          else:
            Approvals.settle_activations(
              state,
              grant.id,
              :until_off,
              if(start == :auto, do: :all, else: :ask)
            )
      end)

    state =
      if start == :auto do
        # Enabled, auto is the every-use allowance (`started/1`): it settles
        # what that allowance would, no more (`Policy.settles?/3`).
        every = Enum.find(updated.allowances, &(&1.pattern == :all))
        now = State.now()

        state.approvals
        |> Enum.filter(
          &(&1.status == :waiting and &1.grant_id == grant.id and every != nil and
              Policy.settles?(&1, every, now))
        )
        |> Enum.reduce(state, fn other, acc ->
          acc
          |> Approvals.settle(other, :allowed, {:allow, :all, :grant})
          |> State.log(
            Approvals.event_for(
              other,
              :allowed,
              "enabled on startup, auto-approved",
              Decision.allowance(updated, every)
            )
          )
          |> Approvals.answer_waiters(other, :allow)
        end)
        |> then(fn state ->
          state.approvals
          |> Enum.filter(
            &(&1.status == :waiting and &1.kind == :command and &1.grant_id == grant.id)
          )
          |> Enum.reduce(state, &HostRuns.auto_approve(&2, &1))
        end)
      else
        state
      end

    state |> State.write_inbox() |> State.changed()
  end

  @doc """
  The hosts a network grant leaves out, set (`Grant.except`), and a line
  in the log saying which. Uses waiting for you are left as they are: a
  card asked under it is still yours to decide.
  """
  def set_except(state, %Grant{kind: :network} = grant, entries) do
    summary =
      case entries do
        [] -> "#{grant.name} leaves out no host"
        _some -> "#{grant.name} leaves out #{Enum.join(entries, ", ")}"
      end

    state
    |> State.replace_grant(%{grant | except: entries})
    |> State.log(%{outcome: :grant, summary: summary, grant_id: grant.id})
  end

  defp expires_at(:until_off), do: nil
  defp expires_at(minutes), do: DateTime.add(State.now(), minutes * 60, :second)

  @doc """
  Applies `fun` to the grant with this id and answers the caller with the result; turning it off this way denies what waited on it.
  """
  def with_grant(state, id, fun) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        {updated, summary} = fun.(grant)

        state =
          if grant.state == :on and updated.state != :on,
            do: Approvals.settle_waiting(state, id, :grant_off),
            else: state

        state = State.replace_grant(state, updated)

        state =
          if summary,
            do: State.log(state, %{outcome: :grant, summary: summary, grant_id: id}),
            else: state

        {:reply, {:ok, updated}, state |> State.write_inbox() |> State.changed()}
    end
  end

  @doc """
  The grants with the built-in ones in them, as MWT makes them: MWT's
  tools, the Internet's, and Commands agents write. Those an identity already has keep how they
  are, with MWT's names and words.
  """
  def with_built_in(grants),
    do: grants |> put_mwt_tools() |> put_internet() |> put_agent_commands()

  # Commands agents write: every identity has one, on as it starts. One an
  # identity has keeps how it is; its name and words are MWT's.
  defp put_agent_commands(grants) do
    built_in = Grant.agent_commands()

    case Enum.find_index(grants, &Grant.agent_commands?/1) do
      nil ->
        id =
          if Enum.any?(grants, &(&1.id == built_in.id)),
            do: grant_id(built_in.name, grants),
            else: built_in.id

        grants ++ [started(%{built_in | id: id})]

      index ->
        List.update_at(
          grants,
          index,
          &%{&1 | name: built_in.name, purpose: built_in.purpose, allowances: []}
        )
    end
  end

  # The Internet: every identity has one, always on as it starts. One an
  # identity has keeps how it is; its name and words are MWT's.
  defp put_internet(grants) do
    built_in = Grant.internet()

    case Enum.find_index(grants, &Grant.internet?/1) do
      nil ->
        id =
          if Enum.any?(grants, &(&1.id == built_in.id)),
            do: grant_id(built_in.name, grants),
            else: built_in.id

        grants ++ [started(%{built_in | id: id})]

      index ->
        List.update_at(
          grants,
          index,
          &%{&1 | name: built_in.name, purpose: built_in.purpose, destinations: [], preset: nil}
        )
    end
  end

  # MWT's own tools: three grants, one for each of what they open. One an
  # identity has keeps how it is; MWT's id, name and words are its own.
  defp put_mwt_tools(grants) do
    Enum.reduce(Grant.mwt_tools(), grants, fn built_in, grants ->
      case Enum.find_index(grants, &(&1.kind == :mwt and &1.tools == built_in.tools)) do
        nil ->
          id =
            if Enum.any?(grants, &(&1.id == built_in.id)),
              do: grant_id(built_in.name, grants),
              else: built_in.id

          # New to this identity, it is in the state it starts in.
          grants ++ [started(%{built_in | id: id})]

        index ->
          List.update_at(grants, index, &%{&1 | name: built_in.name, purpose: built_in.purpose})
      end
    end)
  end

  @doc """
  A grant from a form's fields, with its real value when the form carried one, or the errors by field.

  `proposal: true` builds what an agent proposes (`MWTClient.Sandbox.Proposal`):
  a token grant needs no value yet, you paste it as you review it.
  """
  def build_grant(attrs, existing, opts \\ []) do
    kind = Enum.find(Grant.kinds(), &(Atom.to_string(&1) == attrs["kind"]))
    editing? = Keyword.get(opts, :editing, false)

    valueless? =
      editing? or Keyword.get(opts, :proposal, false) or Keyword.get(opts, :valueless, false)

    # The preset that filled the form, when one did: given by the server,
    # which knows yours too, or one of MWT's own.
    found =
      Keyword.get_lazy(opts, :preset, fn ->
        case Presets.find(attrs["preset"] || "") do
          {:ok, preset} -> preset
          :error -> nil
        end
      end)

    found = if is_binary(found[:id]), do: found, else: nil
    preset = found && found.id

    {attrs, fill_error} =
      case found && Presets.fill(attrs, found.fill) do
        {:ok, filled} -> {filled, nil}
        {:error, message} -> {attrs, message}
        nil -> {attrs, nil}
      end

    if is_nil(kind) do
      {:error, %{kind: "Pick what kind of access this is."}}
    else
      name = String.trim(attrs["name"] || "")
      purpose = String.trim(attrs["purpose"] || "")
      minted? = kind == :token and attrs["source"] == "minted"

      # Over a network you have, none listed is all of it.
      over_network? = kind == :network and attrs["network"] not in [nil, ""]

      {destinations, destination_error} =
        destinations(attrs["destinations"], kind, over_network?)

      # The hosts a network grant leaves out of what it covers, for
      # another grant to cover on its own terms.
      {except, except_error} =
        case kind == :network && Network.except_entries(attrs["except"]) do
          {:ok, entries} -> {entries, nil}
          {:error, message} -> {[], message}
          false -> {[], nil}
        end

      script = if(kind == :command, do: command_script(attrs["script"]))
      # A saved command: your own script, which agents call by id.
      saved? = kind == :command

      # A request action: a request MWT sends with a credential's value.
      credential =
        if kind == :request,
          do: Enum.find(Keyword.get(opts, :credentials, []), &(&1.id == attrs["credential"]))

      # The call's parameters: its JSON Schema, as the form writes it, or
      # `NAME: shape: what it is` lines, as agents' --param do; never both.
      {params, param_error} =
        case (saved? or kind == :request) && call_params(attrs) do
          false -> {[], nil}
          {:ok, params} -> {params, if(saved?, do: unused_error(params, script))}
          {:error, message} -> {[], message}
        end

      start = Enum.find([:on, :auto, :off], :off, &(Atom.to_string(&1) == attrs["start"]))

      grant = %Grant{
        id: grant_id(name, existing),
        name: name,
        kind: kind,
        preset: preset,
        purpose: purpose,
        placeholder: if(kind == :token, do: placeholder(attrs["prefix"])),
        presents: if(kind == :token, do: presents(attrs), else: %{}),
        resolver:
          if(kind == :network, do: blank_to_nil(String.trim(State.to_text(attrs["resolver"])))),
        anchor:
          if(kind == :network, do: blank_to_nil(String.trim(State.to_text(attrs["anchor"])))),
        env: if(kind == :token, do: list(attrs["env"]), else: []),
        file_env: if(kind == :token, do: list(attrs["file_env"]), else: []),
        git: kind == :token and attrs["git"] in ["true", "on"],
        hosts:
          if(kind == :token, do: Enum.map(list(attrs["hosts"]), &String.downcase/1), else: []),
        carriers:
          if(kind == :token,
            do: attrs["carriers"] |> list() |> Enum.map(&String.downcase/1) |> Enum.uniq(),
            else: []
          ),
        destinations: destinations,
        except: except,
        script: script,
        dir: if(kind == :command, do: command_dir(attrs["dir"])),
        credential: credential && credential.id,
        params: params,
        confined: saved? and attrs["confined"] in ["true", "on"],
        with: if(saved?, do: list(attrs["with"]), else: []),
        writes_dir: saved? and attrs["writes_dir"] in ["true", "on"],
        method: if(kind == :request, do: attrs["method"] |> State.to_text() |> String.upcase()),
        url: if(kind == :request, do: attrs["url"] |> State.to_text() |> String.trim()),
        headers:
          if(kind == :request,
            do: SavedRequest.headers(State.to_text(attrs["headers"])),
            else: []
          ),
        body: if(kind == :request, do: request_body(attrs["body"])),
        start: start,
        state: :off,
        source: if(minted?, do: {:minted, String.trim(attrs["mint"] || "")}, else: :stored),
        mint_per:
          if(minted? and attrs["mint_per"] in ["host", "true", "on"], do: :host, else: :grant),
        keep_minutes: if(minted?, do: keep_minutes(attrs["keep_minutes"])),
        signs_as:
          if(kind in [:token, :request],
            do: attrs["signs_as"] |> list() |> Enum.map(&String.downcase/1) |> Enum.uniq(),
            else: []
          ),
        covers_unread: attrs["covers_unread"] not in ["false", false],
        # A GitHub App's installation token, made by the github adapter from
        # the key the mint prints (`MWTClient.Sandbox.Adapter.GitHub`).
        app:
          if(
            kind == :token and
              (text_given?(attrs["app_id"]) or text_given?(attrs["installation_id"])),
            do: %{
              app_id: String.trim(attrs["app_id"] || ""),
              installation_id: String.trim(attrs["installation_id"] || "")
            }
          ),
        # The service its credential is for (`MWTClient.Sandbox.Adapter`):
        # what the form or preset chose; none chosen, the one its fields
        # say, once its credential is made (`Credential.of_grant/1`).
        adapter:
          if(kind == :token,
            do:
              case MWTClient.Sandbox.Adapter.find(
                     blank_to_nil(String.trim(State.to_text(attrs["adapter"])))
                   ) do
                {:ok, adapter} -> adapter.id()
                :error -> nil
              end
          )
      }

      # Narrowed beyond its hosts (`MWTClient.Sandbox.Attributes`): a token
      # grant only.
      {grant, attribute_error} =
        case kind == :token && MWTClient.Sandbox.Attributes.parse(attrs["attributes"]) do
          {:ok, attributes} -> {%{grant | attributes: attributes}, nil}
          {:error, message} -> {grant, message}
          _other -> {grant, nil}
        end

      errors = grant_errors(grant, attrs, destination_error, saved?, existing, valueless?)
      errors = if attribute_error, do: Map.put(errors, :attributes, attribute_error), else: errors
      errors = if except_error, do: Map.put(errors, :except, except_error), else: errors

      errors = Map.merge(adapter_errors(grant, attrs), errors)

      errors =
        if kind == :request and param_error == nil,
          do:
            Map.merge(
              SavedRequest.errors(
                Map.from_struct(grant),
                params,
                credential && Credential.attach(grant, credential)
              ),
              errors
            ),
          else: errors

      errors = if param_error, do: Map.put(errors, :params, param_error), else: errors
      errors = if fill_error, do: Map.put(errors, :fill, fill_error), else: errors

      errors =
        if start in Grant.starts(grant),
          do: errors,
          else:
            Map.put(
              errors,
              :start,
              "Nothing auto-approves this one, so it can't start enabled and auto-approved."
            )

      case errors do
        errors when errors == %{} ->
          # What the preset gave beyond the form, copied: nothing looks at
          # the preset again.
          grant =
            if found,
              do: %{
                grant
                | icon: found.icon,
                  request_headers: found.request_headers,
                  cli_tools: found.tools
              },
              else: grant

          {:ok, started(grant),
           if(kind == :token and not minted?,
             do: blank_to_nil(State.opened(attrs["value"]))
           )}

        errors ->
          {:error, errors}
      end
    end
  end

  defp text_given?(value), do: is_binary(value) and String.trim(value) != ""

  # What a token grant's credential holds for its adapter, checked: an
  # adapter MWT has, when one is named, and a GitHub App only on a GitHub
  # credential whose value is minted, with both of its ids.
  defp adapter_errors(%Grant{kind: :token} = grant, attrs) do
    named = String.trim(State.to_text(attrs["adapter"]))

    adapter_error =
      if named != "" and is_nil(grant.adapter),
        do: %{
          adapter:
            "No adapter is called #{named}: " <>
              Enum.map_join(MWTClient.Sandbox.Adapter.all(), ", ", &Atom.to_string(&1.id())) <>
              "."
        },
        else: %{}

    app_error =
      case grant.app do
        nil ->
          nil

        %{app_id: app_id, installation_id: installation} ->
          cond do
            (grant.adapter || :github) != :github ->
              "A GitHub App's ids go on a GitHub credential."

            not match?({:minted, _}, grant.source) ->
              "A GitHub App's token is minted: give the command that prints its private key."

            not Regex.match?(~r/\A[A-Za-z0-9.]{1,64}\z/, app_id) or
                not Regex.match?(~r/\A\d{1,18}\z/, installation) ->
              "A GitHub App's id is letters and digits (Iv23li… or 123456), its installation's id digits."

            true ->
              nil
          end
      end

    if app_error, do: Map.put(adapter_error, :app, app_error), else: adapter_error
  end

  defp adapter_errors(%Grant{}, _attrs), do: %{}

  # A login file's refresh placeholder never changes while the file stays:
  # a tool that read it keeps working.
  defp kept_login(%{login: login} = presents, %{login: %{refresh: refresh}}),
    do: %{presents | login: %{login | refresh: refresh}}

  defp kept_login(presents, _before), do: presents

  # A parameter named like a variable a credential it runs with sets.
  defp with_clash(%Grant{with: []}, _existing), do: nil

  defp with_clash(grant, existing) do
    variables =
      for %Grant{kind: :token} = other <- existing,
          Grant.credential_id(other) in grant.with,
          variable <- other.env ++ other.file_env,
          do: variable

    Enum.find_value(grant.params, &(&1.name in variables and &1.name))
  end

  # Whether a token grant is over the credential `id`: one a saved command
  # may run with.
  defp credential_named?(existing, id),
    do: Enum.any?(existing, &(&1.kind == :token and Grant.credential_id(&1) == id))

  defp stringed(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc """
  Adds the actions a preset carries beside `grant`, over its resource,
  each checked as its form would be; one that doesn't pass is left out,
  and the log says so.
  """
  def add_preset_actions(state, grant, preset, fill \\ %{})

  def add_preset_actions(state, _grant, nil, _fill), do: state

  def add_preset_actions(state, grant, preset, fill) do
    Enum.reduce(preset.actions, state, fn attrs, state ->
      kind = if grant.kind == :token, do: "request", else: "command"

      attrs =
        attrs
        |> stringed()
        |> Map.new(fn {key, value} -> {key, preset_field(value)} end)
        |> Map.put_new("headers", grant.request_headers || SavedRequest.default_headers(nil))
        |> Map.put("fill", fill || %{})
        |> Presets.fill(preset.fill)
        |> case do
          {:ok, filled} -> filled
          {:error, _missing} -> attrs |> stringed() |> Map.delete("fill")
        end
        |> Map.merge(%{
          "kind" => kind,
          "credential" => Grant.credential_id(grant),
          "preset" => if(kind == "request", do: "request_action", else: "saved_command")
        })

      case build_grant(attrs, state.grants,
             preset: nil,
             credentials: Map.get(state, :credentials, [])
           ) do
        {:ok, sub, _value} ->
          state
          |> State.change(:grants, &(&1.grants ++ [sub]))
          |> State.log(%{
            outcome: :grant,
            summary: "#{sub.name} added, from #{preset.name}",
            grant_id: sub.id
          })

        {:error, errors} ->
          State.log(state, %{
            outcome: :grant,
            summary:
              "#{attrs["name"]}, an action #{preset.name} carries, was left out: " <>
                (errors |> Map.values() |> Enum.join(" ")),
            grant_id: grant.id
          })
      end
    end)
  end

  defp preset_field(value) when is_binary(value), do: value
  defp preset_field(value) when is_list(value), do: Enum.map_join(value, "\n", &to_string/1)
  defp preset_field(value), do: to_string(value)

  # Every parameter is read by the script, so a value reaches a tool only
  # where the script shows it go.
  defp unused_error(_params, nil), do: nil

  defp unused_error(params, script) do
    case Param.unused(params, script) do
      [] ->
        nil

      unused ->
        names = Enum.map_join(unused, ", ", & &1.name)
        first = hd(unused).name
        "The script doesn't read #{names}. Use it as \"$#{first}\", or take it off the list."
    end
  end

  # A request action's body: JSON, or nil for none.
  defp request_body(text) do
    case text |> State.to_text() |> String.replace("\r\n", "\n") |> String.trim() do
      "" -> nil
      body -> body
    end
  end

  @doc """
  A grant changed from its form: what you can change of it, checked as when
  it was added. It keeps its id, so agents still find it, its placeholder
  and value, its kind and the resource it is over, and its state: on or
  off, for as long, asking or not, and the state it starts in, which its
  page changes. The Internet's grant and MWT's tools are built in, and
  can't be changed.
  """
  def edit_grant(%Grant{} = grant, attrs, grants, credentials \\ []) do
    # A token grant over a credential: how its value is made and how tools
    # find it are the credential's, edited on its page; the grant's form
    # says only where it may go.
    over =
      if grant.kind == :token,
        do: Enum.find(credentials, &(&1.id == Grant.credential_id(grant)))

    if Grant.built_in?(grant) do
      {:error, :built_in}
    else
      attrs =
        Map.merge(attrs, %{
          "kind" => Atom.to_string(grant.kind),
          "preset" => edit_preset(grant),
          "credential" => grant.credential,
          "start" => Atom.to_string(grant.start),
          "prefix" => "",
          "source" => if(match?({:minted, _}, grant.source), do: "minted", else: "stored"),
          "mint_per" => Map.get(attrs, "mint_per", Atom.to_string(grant.mint_per))
        })

      attrs = if over, do: credential_attrs(attrs, over), else: attrs

      case build_grant(attrs, List.delete(grants, grant),
             editing: true,
             preset: nil,
             credentials: credentials
           ) do
        {:ok, built, _value} ->
          built = if over, do: Credential.attach(built, over), else: built

          {:ok,
           %{
             built
             | id: grant.id,
               preset: grant.preset,
               placeholder: grant.placeholder,
               presents: kept_login(built.presents, grant.presents),
               credential: grant.credential,
               network: grant.network,
               scope: grant.scope,
               aliases: grant.aliases,
               login_aliases: grant.login_aliases,
               app: built.app || grant.app,
               adapter: built.adapter || grant.adapter,
               start: grant.start,
               icon: grant.icon,
               request_headers: grant.request_headers,
               cli_tools: grant.cli_tools,
               host_rules: grant.host_rules,
               proposal: grant.proposal,
               state: grant.state,
               expires_at: grant.expires_at,
               minutes: grant.minutes,
               allowances: grant.allowances,
               uses: grant.uses,
               last_used_at: grant.last_used_at
           }}

        {:error, errors} ->
          {:error, errors}
      end
    end
  end

  defp edit_preset(%Grant{kind: :command}), do: "saved_command"
  defp edit_preset(%Grant{kind: :request}), do: "request_action"
  defp edit_preset(%Grant{preset: nil, kind: kind}), do: Atom.to_string(kind)
  defp edit_preset(%Grant{preset: preset}), do: to_string(preset)

  # A command grant's own script: nil when agents write the text.
  defp command_script(text) do
    case text |> State.to_text() |> String.replace("\r\n", "\n") |> String.trim() do
      "" -> nil
      script -> script
    end
  end

  # The folder a script of yours runs in, as a real path; your home folder
  # when you named none.
  defp command_dir(text) do
    case text |> State.to_text() |> String.trim() do
      "" -> nil
      dir -> Path.expand(dir)
    end
  end

  @variable ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @host ~r/^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/
  @prefix ~r/^[A-Za-z0-9_.\-]{0,24}$/
  @header ~r/^[a-z0-9][a-z0-9-]*$/
  @account ~r/\A[^\s@\/]+@[^\s@\/]+\.[^\s@\/]+\z/
  # A network interface's name: at most 15 bytes, as Linux keeps it.
  @interface ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}\z/
  # Headers that say how a request is framed or routed, never a credential.
  @framing ~w(host content-length transfer-encoding connection upgrade expect te trailer
              keep-alive proxy-connection content-encoding)

  defp grant_errors(%Grant{} = grant, attrs, destination_error, saved?, existing, valueless?) do
    token? = grant.kind == :token
    variables = grant.env ++ grant.file_env

    [
      {:name, grant.name == "", "Give it a name you'll recognise on an approval."},
      {:purpose, grant.purpose == "",
       "Say what it's for. Agents in the VM read this to find the grant they need."},
      {:hosts, token? and grant.hosts == [], "List at least one host the value may go to."},
      {:hosts, token? and not Enum.all?(grant.hosts, &Regex.match?(@host, &1)),
       "Hosts are names like api.example.com, or *.example.com for its subdomains."},
      {:resolver, grant.resolver != nil and Dns.resolver_address(grant.resolver) == :error,
       "The DNS server is an IP address, with a port if it isn't 53: 10.8.0.1, 10.8.0.1:5353."},
      {:anchor, grant.anchor != nil and not Regex.match?(@interface, grant.anchor),
       "The way out is a network interface's name, as ip link shows it: wg0, tun0, utun4."},
      {:carriers, token? and not Enum.all?(grant.carriers, &Regex.match?(@header, &1)),
       "Header names are letters, digits and dashes, like Authorization or X-Api-Key."},
      {:carriers, token? and Enum.any?(grant.carriers, &(&1 in @framing)),
       "#{Enum.find(grant.carriers, &(&1 in @framing))} says how a request is sent; " <>
         "a credential can't travel in it."},
      {:env, token? and not Enum.all?(variables, &Regex.match?(@variable, &1)),
       "Variable names are letters, digits and underscores, not starting with a digit."},
      {:prefix, token? and not Regex.match?(@prefix, String.trim(attrs["prefix"] || "")),
       "Up to 24 letters, digits, dots, dashes or underscores."},
      {:keep_minutes,
       match?({:minted, _}, grant.source) and is_nil(grant.keep_minutes) and
         String.trim(State.to_text(attrs["keep_minutes"])) != "",
       "A whole number of minutes, from 1 to 1440, or empty to keep it as the mint says."},
      {:signs_as, not Enum.all?(grant.signs_as, &Regex.match?(@account, &1)),
       "Name each service account by its email: name@project.iam.gserviceaccount.com."},
      # Signing's host, and the token endpoint a login file is refreshed
      # at, are the google adapter's own: implied, not listed
      # (`MWTClient.Sandbox.Adapter.Google.implied_hosts/1`).
      {:present_id_header,
       Map.has_key?(grant.presents, :login) and grant.presents.login.header != "" and
         (not Regex.match?(@header, grant.presents.login.header) or
            grant.presents.login.header in @framing),
       "A header's name: letters, digits and dashes, like X-Id-Token. Empty sends it as the grant's own value goes."},
      {:present_project,
       Map.has_key?(grant.presents, :metadata) and
         not Regex.match?(~r/\A[a-z][a-z0-9-]{4,62}\z/, grant.presents.metadata.project),
       "Name the project as the cloud does: lowercase letters, digits and dashes."},
      {:present_email,
       Map.has_key?(grant.presents, :metadata) and
         not Regex.match?(~r/\A([^\s@]+@[^\s@]+)?\z/, grant.presents.metadata.email),
       "The account is an email, or empty for the default one."},
      {:destinations, grant.kind == :network and destination_error != nil, destination_error},
      {:mint, match?({:minted, ""}, grant.source),
       "Enter the command that prints a short-lived token."},
      {:script, saved? and is_nil(grant.script),
       "Write the script agents may run. They can always ask to run one of their own, which you approve each time."},
      {:script,
       grant.kind == :command and byte_size(grant.script || "") > HostCommand.max_script(),
       "The script is over #{div(HostCommand.max_script(), 1024)} KiB."},
      {:script, grant.kind == :command and Shown.hidden(grant.script || "") != [],
       "The script has characters that don't show " <>
         "(#{Enum.join(Shown.hidden(grant.script || ""), ", ")}). Paste it without them."},
      {:dir, grant.kind == :command and grant.script != nil and is_nil(grant.dir),
       "Say which folder your script runs in."},
      {:with, grant.with != [] and not grant.confined,
       "Only a confined command runs with a credential's real value: tick Runs confined."},
      {:with, Enum.any?(grant.with, &(not credential_named?(existing, &1))),
       "Name credentials by their id: " <>
         Enum.join(Enum.reject(grant.with, &credential_named?(existing, &1)), ", ") <>
         " isn't one a token grant is over."},
      {:with,
       Enum.any?(
         existing,
         &(&1.kind == :token and Grant.credential_id(&1) in grant.with and &1.mint_per == :host)
       ),
       "A credential minted per host can't be named here: a script has no single host to mint it for."},
      {:with, with_clash(grant, existing) != nil,
       "#{with_clash(grant, existing)} is both a parameter and a variable of a grant it runs with. Rename the parameter."},
      {:dir, grant.kind == :command and grant.dir != nil and not File.dir?(grant.dir),
       "That folder does not exist on this machine."},
      {:value,
       not valueless? and grant.kind == :token and grant.source == :stored and
         blank_to_nil(State.opened(attrs["value"])) == nil,
       "Paste the value. It is kept in your vault, never in the VM."}
    ]
    |> Enum.filter(fn {_field, failed?, _message} -> failed? end)
    |> Enum.reverse()
    |> Map.new(fn {field, _failed?, message} -> {field, message} end)
  end

  defp call_params(attrs) do
    schema = String.trim(State.to_text(attrs["schema"]))
    lines = String.trim(State.to_text(attrs["params"]))

    cond do
      schema != "" and lines != "" ->
        {:error, "Give the parameters once: as a schema, or as NAME: shape: what it is lines."}

      schema != "" ->
        MWTClient.Sandbox.ParamSchema.parse(schema)

      true ->
        Param.parse(lines)
    end
  end

  defp destinations(text, kind, over_network?) do
    entries = list(text)

    cond do
      kind != :network ->
        {[], nil}

      entries == [] and over_network? ->
        {[], nil}

      entries == [] ->
        {[], "List at least one host, address or range."}

      true ->
        case Destinations.parse_all(entries) do
          {:ok, _specs} -> {entries, nil}
          {:error, message} -> {entries, message}
        end
    end
  end

  # How long a minted value is kept at most, in minutes: nil when the field
  # is empty or isn't a number from 1 to 1440 (a day), which the form then
  # says.
  defp keep_minutes(text) do
    case Integer.parse(String.trim(State.to_text(text))) do
      {minutes, ""} when minutes in 1..1440 -> minutes
      _none -> nil
    end
  end

  # The presentations a token grant asks for, from its form. A login file's
  # refresh token is a placeholder made here, once: editing keeps it
  # (`edit_grant/3`).
  defp presents(attrs) do
    metadata =
      if attrs["present_metadata"] in ["true", "on"],
        do: %{
          metadata: %{
            project: attrs |> Map.get("present_project") |> State.to_text() |> String.trim(),
            email: attrs |> Map.get("present_email") |> State.to_text() |> String.trim()
          }
        },
        else: %{}

    login =
      if attrs["present_login"] in ["true", "on"],
        do: %{
          login: %{
            refresh: Grant.new_login_placeholder(),
            header:
              attrs
              |> Map.get("present_id_header")
              |> State.to_text()
              |> String.trim()
              |> String.downcase()
          }
        },
        else: %{}

    Map.merge(metadata, login)
  end

  @doc """
  A new placeholder in the shape of `like`, an existing one: the same
  prefix (`ghp_`, `ya29.mwt`), new random characters.
  """
  def fresh_placeholder(like) when is_binary(like),
    do: placeholder(String.slice(like, 0, max(String.length(like) - 40, 0)))

  # Placeholders look like the real thing where a client checks the format
  # (`ghp_` for GitHub), and are long and random, so finding one in a header
  # is unambiguous.
  defp placeholder(prefix) do
    prefix = String.trim(prefix || "")
    prefix = if prefix == "", do: "mwt_", else: prefix
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    bytes = :crypto.strong_rand_bytes(40)
    prefix <> for(<<byte <- bytes>>, into: "", do: <<Enum.at(alphabet, rem(byte, 62))>>)
  end

  defp list(nil), do: []

  defp list(value) do
    value
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp grant_id(name, existing) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "grant"
        slug -> slug
      end

    if Enum.any?(existing, &(&1.id == base)), do: base <> "-" <> State.unique(), else: base
  end

  @connections MWTClient.Sandbox.Connections

  @doc """
  The ids of the grants that let uses through now: on by the clock. None
  while the firewall holds the VM isolated.
  """
  def live(state) do
    if Firewall.isolated?(state) do
      MapSet.new()
    else
      now = State.now()
      locks = Map.get(state, :locks, %{})

      for grant <- state.grants,
          not Map.has_key?(locks, Grant.resource(grant)),
          Grant.on?(grant, now),
          into: MapSet.new(),
          do: grant.id
    end
  end

  @doc """
  Closes what each grant that stopped being live since the last message
  let through: the connections the proxy holds under it
  (`MWTClient.Sandbox.Connections`, keyed by `{username, grant_id}`), a
  tunnel or an upgraded session alike. Turned off, out of time, removed,
  it stops at once (QA M5). Runs after every message the
  server takes, before its answer goes.
  """
  def close_ended(state) do
    live = live(state)

    for id <- MapSet.difference(Map.get(state, :live, MapSet.new()), live),
        {pid, _} <- connections(state.username, id),
        do: Process.exit(pid, :kill)

    Map.put(state, :live, live)
  end

  @doc """
  Closes every connection held under a grant that isn't live: as the
  server starts, when connections from before it may still be open.
  """
  def close_unlive(state) do
    live = live(state)

    pattern = [{{{state.username, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

    for {id, pid} <- select(pattern), not MapSet.member?(live, id), do: Process.exit(pid, :kill)

    Map.put(state, :live, live)
  end

  defp connections(username, id) do
    Registry.lookup(@connections, {username, id})
  rescue
    ArgumentError -> []
  end

  defp select(pattern) do
    Registry.select(@connections, pattern)
  rescue
    ArgumentError -> []
  end

  @doc """
  Turns off every grant whose time ran out and drops every allowance past
  its end, by the clock.
  """
  def sweep(state) do
    at = DateTime.utc_now()

    Enum.reduce(state.grants, state, fn grant, state ->
      ended = Enum.filter(grant.allowances, &Allowance.ended?(&1, at))

      cond do
        grant.state == :on and not Grant.on?(grant, at) ->
          state
          |> Approvals.settle_waiting(grant.id, :grant_off)
          |> State.replace_grant(Grant.put_down(grant))
          |> State.log(%{
            outcome: :grant,
            summary: "#{grant.name} off: its time ran out",
            grant_id: grant.id
          })
          |> State.write_inbox()
          |> State.changed()

        ended != [] ->
          state
          |> State.replace_grant(%{grant | allowances: grant.allowances -- ended})
          |> State.changed()

        true ->
          state
      end
    end)
  end
end
