defmodule MWTClient.Sandbox.Server.Grants do
  @moduledoc """
  The grants in the sandbox server's state: building one from a form and
  saying what is wrong with it, turning one on, adding an allowance, and
  turning off the ones whose time ran out.

  Runs in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{
    Allowance,
    Approval,
    CredentialEndpoint,
    Destinations,
    Dns,
    Grant,
    HostCommand,
    Param,
    Policy,
    Presets,
    SavedRequest,
    Shown
  }

  alias MWTClient.Sandbox.Server.{Approvals, Firewall, HostRuns, State}

  @doc """
  Adds an allowance to an on grant, and lets through every use waiting on
  it that the allowance covers. A grant that always asks
  (`Grant.ceiling/1`) takes none.
  """
  def allow(state, grant, pattern, duration) do
    if Grant.ceiling(grant) == :ask,
      do: state,
      else: add_allowance(state, grant, pattern, duration)
  end

  defp add_allowance(state, grant, pattern, duration) do
    allowance = %Allowance{
      id: "allowance-" <> State.unique(),
      pattern: pattern,
      until:
        if(duration == :grant, do: nil, else: DateTime.add(State.now(), duration * 60, :second))
    }

    if allowance.until,
      do: State.timer({:expire_allowance, grant.id, allowance.id}, allowance.until)

    state =
      state.approvals
      |> Enum.filter(fn other ->
        other.status == :waiting and other.grant_id == grant.id and Approval.use?(other) and
          Allowance.covers?(allowance, other.pattern)
      end)
      |> Enum.reduce(state, fn other, acc ->
        how = if pattern == :all, do: "every use", else: "similar"

        acc
        |> Approvals.settle(
          other,
          :allowed,
          {:allow, if(pattern == :all, do: :all, else: :similar), duration}
        )
        |> Approvals.answer_waiters(other, :allow)
        |> State.log(
          Approvals.event_for(
            other,
            :allowed,
            "you allowed #{how} #{State.duration_words(duration)}"
          )
        )
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

    state
    |> State.change(:grants, fn _ -> grants end)
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
  Removes a grant and its subgrants, with their values and what waited on
  them; `summary` is what the log says.
  """
  def delete(state, %Grant{id: id} = grant, summary) do
    gone = [id | state.grants |> Grant.subgrants(grant) |> Enum.map(& &1.id)]

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
      |> Approvals.settle_waiting(id, :grant_off, [:activation, :request, :connection])
      |> Map.update!(:values, fn values ->
        Map.reject(values, fn {key, _} -> key == id or match?({^id, _part}, key) end)
      end)
      |> Map.update!(:minted, fn minted ->
        Map.reject(minted, fn {key, _} -> key == id or match?({^id, _host}, key) end)
      end)
      |> Map.update(:id_tokens, %{}, fn id_tokens ->
        Map.reject(id_tokens, fn {key, _} -> key == id or match?({^id, _host}, key) end)
      end)
      |> Map.update(:made, %{}, &MWTClient.Sandbox.Made.drop_grant(&1, id))
    end)
    |> State.change(:grants, &Enum.reject(&1.grants, fn g -> g.id in gone end))
    # Gone from the state, so the grant as it was goes with the event.
    |> State.log(%{outcome: :grant, summary: summary, details: Grant.details(grant)})
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  Turns a grant on for `minutes` (or `:until_off`); `:all` also lets every
  use through for as long as it stays on.
  """
  def turn_on(state, nil, _minutes, _uses, _why), do: state

  # Only for its subgrants: nothing of it to turn on.
  def turn_on(state, %Grant{kind: :token, reach: :subgrants}, _minutes, _uses, _why), do: state

  def turn_on(state, grant, minutes, uses, why) do
    # Ask to run commands always asks, and a file has no uses to approve.
    uses = if Grant.auto_approvable?(grant), do: uses, else: :ask

    grant = %{grant | state: :on, expires_at: expires_at(minutes), minutes: minutes}
    State.schedule_expiry(grant)

    state =
      state
      |> State.replace_grant(grant)
      |> State.log(%{
        outcome: :grant,
        summary:
          "#{grant.name} turned on #{State.duration_words(minutes)}" <>
            if(uses == :all, do: ", auto-approve", else: "") <> why,
        grant_id: grant.id
      })
      |> State.write_inbox()
      |> State.changed()
      # Its checks run as it turns on; until a gating one passes, it is
      # paused (`MWTClient.Sandbox.Server.Checks`).
      |> MWTClient.Sandbox.Server.Checks.run(grant, :enable)

    if uses == :all, do: allow(state, grant, :all, :grant), else: state
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
    if Grant.auto_approved?(grant, State.now()) do
      state
    else
      state
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: auto-approve while on",
        grant_id: grant.id
      })
      |> allow(grant, :all, :grant)
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
  disabled, or enabled until turned off, every use asking (`:on`) or going
  through (`:auto`). Nothing a session left carries over: no time left, no
  allowance.
  """
  def start(grants), do: Enum.map(grants, &started/1)

  defp started(%Grant{} = grant) do
    grant = %{grant | state: :off, expires_at: nil, allowances: []}

    case start_of(grant) do
      :off -> grant
      :on -> %{grant | state: :on, minutes: :until_off}
      :auto -> %{grant | state: :on, minutes: :until_off, allowances: [always()]}
    end
  end

  # A setting saved before the grant could no longer take it counts as the
  # nearest one it can.
  defp start_of(%Grant{start: start} = grant) do
    cond do
      start in Grant.starts(grant) -> start
      start == :auto -> :on
      true -> :off
    end
  end

  defp always, do: %Allowance{id: "allowance-" <> State.unique(), pattern: :all, until: nil}

  @doc """
  Sets the state a grant is in when MWT starts, and puts it in that state
  now: what waited on a grant that goes off is refused, and a saved
  command's runs that waited go once it is enabled and auto-approved.
  """
  def set_start(state, %Grant{} = grant, start) do
    words = %{
      off: "disabled",
      on: "enabled, every use asking",
      auto: "enabled, every use auto-approved"
    }

    state =
      if start == :off and grant.state == :on,
        do: Approvals.settle_waiting(state, grant.id, :grant_off),
        else: state

    updated = started(%{grant | start: start})

    state =
      state
      |> State.replace_grant(updated)
      |> then(
        &if(start == :off,
          do: &1,
          else: MWTClient.Sandbox.Server.Checks.run(&1, updated, :enable)
        )
      )
      |> State.log(%{
        outcome: :grant,
        summary: "#{grant.name}: #{words[start]}, from now and each time MWT starts",
        grant_id: grant.id
      })
      |> then(fn state ->
        # Enabled now: that answers the agents waiting for it. Disabled
        # answers nobody.
        if start == :off,
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
        state.approvals
        |> Enum.filter(&(&1.status == :waiting and &1.grant_id == grant.id and Approval.use?(&1)))
        |> Enum.reduce(state, fn other, acc ->
          acc
          |> Approvals.settle(other, :allowed, {:allow, :all, :grant})
          |> Approvals.answer_waiters(other, :allow)
          |> State.log(Approvals.event_for(other, :allowed, "enabled on startup, auto-approved"))
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
  Sets the most automation a grant accepts (`Grant.ceiling/1`). Lowered to
  `:ask`, every allowance it holds ends, Auto-approve included, and a start
  of *Enabled, auto* becomes *Enabled, ask*.
  """
  def set_ceiling(state, %Grant{} = grant, ceiling) do
    updated = %{grant | ceiling: ceiling}

    updated =
      if Grant.ceiling(updated) == :ask,
        do: %{
          updated
          | allowances: [],
            start: if(grant.start == :auto, do: :on, else: grant.start)
        },
        else: updated

    words = %{
      ask: "always asks: no allowance covers a use",
      allow: "no longer always asks"
    }

    state
    |> State.replace_grant(updated)
    |> State.log(%{
      outcome: :grant,
      summary: "#{grant.name} #{words[Grant.ceiling(updated)]}",
      grant_id: grant.id
    })
    |> State.write_inbox()
    |> State.changed()
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
          if grant.state == :on and updated.state == :off,
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
  The grants with Ask to run commands, the escape hatch, in them, as MWT
  makes it: every identity has it, built in and off. The one an identity
  already has (once called Any command, or one you added before it was
  built in) keeps its state and is given MWT's id, name and words.
  """
  def with_built_in(grants),
    do: grants |> put_built_in() |> put_mwt_tools() |> put_internet() |> adopt()

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

  # A saved command is a subgrant of Ask to run commands: those saved
  # before subgrants are moved under it. A subgrant whose grant is gone
  # goes with it.
  defp adopt(grants) do
    %Grant{id: built_in} = Enum.find(grants, &Grant.ask_to_run?/1)
    ids = MapSet.new(grants, & &1.id)

    grants
    |> Enum.map(fn grant ->
      if Grant.saved_command?(grant) and is_nil(grant.parent),
        do: %{grant | parent: built_in},
        else: grant
    end)
    |> Enum.filter(&(is_nil(&1.parent) or MapSet.member?(ids, &1.parent)))
  end

  defp put_built_in(grants) do
    built_in = Grant.ask_to_run()

    case Enum.find_index(grants, &Grant.ask_to_run?/1) do
      nil ->
        id =
          if Enum.any?(grants, &(&1.id == built_in.id)),
            do: grant_id(built_in.name, grants),
            else: built_in.id

        grants ++ [%{built_in | id: id}]

      index ->
        List.update_at(grants, index, fn grant ->
          others = List.delete_at(grants, index)
          id = if Enum.any?(others, &(&1.id == built_in.id)), do: grant.id, else: built_in.id
          %{grant | id: id, name: built_in.name, purpose: built_in.purpose, preset: nil}
        end)
    end
  end

  @doc """
  An agent's ask, with Ask to run commands' id for the one that grant had
  before (`Grant.former_ask_to_run_id/0`), unless a grant has that id now: an
  agent that read it before the rename goes on working, and hears the new
  one.
  """
  def former_id(grants, %{grant: id} = ask) when is_binary(id) do
    with true <- id == Grant.former_ask_to_run_id(),
         false <- Enum.any?(grants, &(&1.id == id)),
         %Grant{id: built_in} <- Enum.find(grants, &Grant.ask_to_run?/1) do
      %{ask | grant: built_in}
    else
      _same -> ask
    end
  end

  def former_id(_grants, ask), do: ask

  @doc """
  A grant from a form's fields, with its real value when the form carried one, or the errors by field.

  `proposal: true` builds what an agent proposes (`MWTClient.Sandbox.Proposal`):
  a token grant needs no value yet, you paste it as you review it.
  """
  def build_grant(attrs, existing, opts \\ []) do
    kind = Enum.find(Grant.kinds(), &(Atom.to_string(&1) == attrs["kind"]))
    editing? = Keyword.get(opts, :editing, false)
    valueless? = editing? or Keyword.get(opts, :proposal, false)

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

      {destinations, destination_error} = destinations(attrs["destinations"], kind)

      script = if(kind == :command, do: command_script(attrs["script"]))
      # A saved command: your own script, which agents call by id. It is a
      # subgrant of Ask to run commands.
      saved? = kind == :command and (script != nil or attrs["preset"] == "saved_command")

      # A request subgrant: a request MWT sends with a token grant's value.
      parent =
        cond do
          saved? -> Enum.find(existing, &Grant.ask_to_run?/1)
          kind == :request -> Enum.find(existing, &(&1.id == attrs["parent"]))
          true -> nil
        end

      {params, param_error} =
        case (saved? or kind == :request) && Param.parse(attrs["params"]) do
          false -> {[], nil}
          {:ok, params} -> {params, if(saved?, do: unused_error(params, script))}
          {:error, message} -> {[], message}
        end

      start = Enum.find([:on, :auto], :off, &(Atom.to_string(&1) == attrs["start"]))
      only_subgrants? = kind == :token and attrs["reach"] == "subgrants"

      grant = %Grant{
        id: grant_id(name, existing),
        name: name,
        kind: kind,
        preset: preset,
        purpose: purpose,
        placeholder: if(kind == :token, do: placeholder(attrs["prefix"])),
        presents: if(kind == :token and not only_subgrants?, do: presents(attrs), else: %{}),
        resolver:
          if(kind == :network, do: blank_to_nil(String.trim(State.to_text(attrs["resolver"])))),
        anchor:
          if(kind == :network, do: blank_to_nil(String.trim(State.to_text(attrs["anchor"])))),
        reach: if(only_subgrants?, do: :subgrants, else: :vm),
        env: if(kind == :token and not only_subgrants?, do: list(attrs["env"]), else: []),
        file_env:
          if(kind == :token and not only_subgrants?, do: list(attrs["file_env"]), else: []),
        git: kind == :token and not only_subgrants? and attrs["git"] in ["true", "on"],
        hosts:
          if(kind == :token, do: Enum.map(list(attrs["hosts"]), &String.downcase/1), else: []),
        carriers:
          if(kind == :token,
            do: attrs["carriers"] |> list() |> Enum.map(&String.downcase/1) |> Enum.uniq(),
            else: []
          ),
        destinations: destinations,
        script: script,
        dir: if(kind == :command, do: command_dir(attrs["dir"])),
        parent: parent && parent.id,
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
          if(kind == :token and not only_subgrants?,
            do: attrs["signs_as"] |> list() |> Enum.map(&String.downcase/1) |> Enum.uniq(),
            else: []
          )
      }

      errors = grant_errors(grant, attrs, destination_error, saved?, existing, valueless?)

      errors =
        if kind == :request and param_error == nil,
          do: Map.merge(SavedRequest.errors(Map.from_struct(grant), params, parent), errors),
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
                  cli_tools: found.tools,
                  checks:
                    for(
                      {attrs, n} <- Enum.with_index(found.checks, 1),
                      {:ok, check} <- [MWTClient.Sandbox.Check.new(stringed(attrs), "check-#{n}")],
                      do: check
                    )
              },
              else: grant

          {:ok, started(grant),
           if(minted? or valueless? or kind in [:network, :command, :request],
             do: nil,
             else: blank_to_nil(State.opened(attrs["value"]))
           )}

        errors ->
          {:error, errors}
      end
    end
  end

  # A login file's refresh placeholder never changes while the file stays:
  # a tool that read it keeps working.
  defp kept_login(%{login: login} = presents, %{login: %{refresh: refresh}}),
    do: %{presents | login: %{login | refresh: refresh}}

  defp kept_login(presents, _before), do: presents

  # A parameter named like a variable a grant it runs with sets.
  defp with_clash(%Grant{with: []}, _existing), do: nil

  defp with_clash(grant, existing) do
    variables =
      for %Grant{kind: :token} = other <- existing,
          other.id in grant.with,
          variable <- other.env ++ other.file_env,
          do: variable

    Enum.find_value(grant.params, &(&1.name in variables and &1.name))
  end

  defp stringed(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc """
  Adds the subgrants a preset carries under `grant`, each checked as its
  form would be; one that doesn't pass is left out, and the log says so.
  """
  def add_preset_subgrants(state, grant, preset, fill \\ %{})

  def add_preset_subgrants(state, _grant, nil, _fill), do: state

  def add_preset_subgrants(state, grant, preset, fill) do
    Enum.reduce(preset.subgrants, state, fn attrs, state ->
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
          "parent" => grant.id,
          "preset" => if(kind == "request", do: "request_subgrant", else: "saved_command")
        })

      case build_grant(attrs, state.grants, preset: nil) do
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
              "#{attrs["name"]}, a subgrant #{preset.name} carries, was left out: " <>
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

  # A request subgrant's body: JSON, or nil for none.
  defp request_body(text) do
    case text |> State.to_text() |> String.replace("\r\n", "\n") |> String.trim() do
      "" -> nil
      body -> body
    end
  end

  @doc """
  A grant changed from its form: what you can change of it, checked as when
  it was added. It keeps its id, so agents still find it, its placeholder
  and value, its kind and the grant it sits under, its host list, and its
  state: on or off, for as long, asking or not, and the state it starts
  in, which its page changes. Ask to run commands and MWT's tools are built in, and
  can't be changed.
  """
  def edit_grant(%Grant{} = grant, attrs, grants) do
    if Grant.built_in?(grant) do
      {:error, :built_in}
    else
      attrs =
        Map.merge(attrs, %{
          "kind" => Atom.to_string(grant.kind),
          "preset" => edit_preset(grant),
          "parent" => grant.parent,
          "start" => Atom.to_string(grant.start),
          "prefix" => "",
          "source" => if(match?({:minted, _}, grant.source), do: "minted", else: "stored"),
          "mint_per" => Map.get(attrs, "mint_per", Atom.to_string(grant.mint_per))
        })

      case build_grant(attrs, List.delete(grants, grant), editing: true, preset: nil) do
        {:ok, built, _value} ->
          {:ok,
           %{
             built
             | id: grant.id,
               preset: grant.preset,
               placeholder: grant.placeholder,
               presents: kept_login(built.presents, grant.presents),
               parent: grant.parent,
               start: grant.start,
               ceiling: grant.ceiling,
               icon: grant.icon,
               request_headers: grant.request_headers,
               cli_tools: grant.cli_tools,
               checks: grant.checks,
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
  defp edit_preset(%Grant{kind: :request}), do: "request_subgrant"
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

    any_command =
      Enum.find(existing, &(&1.kind == :command and is_nil(&1.script) and &1.id != grant.id))

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
      # MWT sends the grant's value there itself to sign, and a value goes
      # only where its grant lists.
      {:signs_as,
       grant.signs_as != [] and
         not Policy.host_listed?(CredentialEndpoint.sign_host(), grant.hosts),
       "Signing sends the grant's value to #{CredentialEndpoint.sign_host()}: list it among the hosts, or *.googleapis.com."},
      {:present_id_header,
       Map.has_key?(grant.presents, :login) and grant.presents.login.header != "" and
         (not Regex.match?(@header, grant.presents.login.header) or
            grant.presents.login.header in @framing),
       "A header's name: letters, digits and dashes, like X-Id-Token. Empty sends it as the grant's own value goes."},
      # MWT answers the refresh there, and the VM's request goes there.
      {:present_login,
       Map.has_key?(grant.presents, :login) and
         not Policy.host_listed?(CredentialEndpoint.token_host(), grant.hosts),
       "The login file is refreshed at #{CredentialEndpoint.token_host()}: list it among the hosts, or *.googleapis.com."},
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
      {:name, grant.kind == :command and not saved? and any_command != nil,
       "#{any_command && any_command.name} is built in and takes any command. " <>
         "Turn it on when a task needs it, or add a subgrant."},
      {:script, saved? and is_nil(grant.script),
       "Write the script agents may run. To let them write their own, turn on Ask to run commands."},
      {:script,
       grant.kind == :command and byte_size(grant.script || "") > HostCommand.max_script(),
       "The script is over #{div(HostCommand.max_script(), 1024)} KiB."},
      {:script, grant.kind == :command and Shown.hidden(grant.script || "") != [],
       "The script has characters that don't show " <>
         "(#{Enum.join(Shown.hidden(grant.script || ""), ", ")}). Paste it without them."},
      {:dir, grant.kind == :command and grant.script != nil and is_nil(grant.dir),
       "Say which folder your script runs in."},
      {:with, grant.with != [] and not grant.confined,
       "Only a confined command runs with a grant's real value: tick Runs confined."},
      {:with,
       Enum.any?(
         grant.with,
         &(not Enum.any?(existing, fn other -> other.id == &1 and other.kind == :token end))
       ),
       "Name token grants by their id: " <>
         Enum.join(
           Enum.reject(grant.with, fn id ->
             Enum.any?(existing, &(&1.id == id and &1.kind == :token))
           end),
           ", "
         ) <> " isn't one."},
      {:with,
       Enum.any?(existing, &(&1.id in grant.with and &1.kind == :token and &1.mint_per == :host)),
       "A grant minted per host can't be named here: a script has no single host to mint it for."},
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

  defp destinations(text, kind) do
    entries = list(text)

    cond do
      kind != :network ->
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
      failing = State.held(state)

      for grant <- state.grants,
          not Map.has_key?(failing, grant.id),
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
          |> State.replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
          |> State.log(%{
            outcome: :grant,
            summary: "#{grant.name} turned off: its time ran out",
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
