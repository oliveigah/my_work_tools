defmodule MWTClient.Sandbox.Server.Transfers do
  @moduledoc """
  The agent sandbox's section of an export, in the server's state
  (`MWTClient.Sandbox.Transfer` reads and checks it): what it holds, made
  from the state; and an import, merged into it or replacing it.
  """

  alias MWTClient.Sandbox.{Credential, Grant, Network, Presets}
  alias MWTClient.Sandbox.Server.{Grants, State}

  @doc """
  The section: your credentials and networks, with the hosts each network
  blocks (the Internet's too), grants (proposals you haven't reviewed left
  out), the stored values of your credentials, the built-in grants'
  settings, your presets and what agents read of this machine. Nothing of
  a session: grants are as they start, and no lock comes along.
  """
  def export(state) do
    {built_in, own} = Enum.split_with(state.grants, &Grant.built_in?/1)
    own = Enum.reject(own, &Grant.to_review?/1)
    credentials = Map.get(state, :credentials, [])
    internet = Enum.find(Map.get(state, :networks, []), & &1.internet)

    # Your networks, the Internet aside: it is MWT's, but for the hosts
    # it blocks.
    networks = for n <- Map.get(state, :networks, []), not n.internet, do: n

    %{
      credentials: Enum.map(credentials, &(&1 |> Map.from_struct() |> Map.put(:locked, nil))),
      networks:
        Enum.map(
          networks,
          &(&1 |> Map.from_struct() |> Map.update!(:limits, fn l -> Map.from_struct(l) end))
        ),
      internet_limits: internet && Map.from_struct(internet.limits),
      grants: Enum.map(own, &definition/1),
      values: stored_values(credentials, state.values),
      built_in:
        Enum.map(built_in, fn g ->
          %{id: g.id, start: g.start, ceiling: g.ceiling, host_rules: g.host_rules}
        end),
      presets: presets(state.username),
      settings: %{
        host_notes: state.settings.host_notes,
        way_of_working: state.settings.way_of_working,
        # Where your tools live, as paths: what they hold stays here. Your
        # home is written `~`, so they fit another machine's.
        confine_reads:
          case Map.get(state.settings, :confine_reads) do
            nil -> nil
            folders -> Enum.map(folders, &home_relative/1)
          end
      }
    }
  end

  defp home_relative(folder) do
    home = System.user_home!()

    cond do
      folder == home -> "~"
      String.starts_with?(folder, home <> "/") -> "~" <> String.replace_prefix(folder, home, "")
      true -> folder
    end
  end

  defp stored_values(credentials, values) do
    for %Credential{id: id, source: :stored} <- credentials,
        value = Map.get(values, id),
        is_binary(value),
        into: %{},
        do: {id, value}
  end

  # A grant as you defined it: nothing of the session it was in, off; it
  # starts as its start setting says once imported.
  defp definition(%Grant{} = grant) do
    grant
    |> Grant.put_down()
    |> Map.merge(%{last_used_at: nil, uses: 0, minutes: nil})
    |> Map.from_struct()
  end

  defp presets(username) do
    dir = Presets.dir(username)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            Presets.file_name?(name),
            {:ok, json} <- [File.read(Path.join(dir, name))],
            do: %{name: name, json: json}

      {:error, _} ->
        []
    end
  end

  @doc """
  An import (`MWTClient.Sandbox.Transfer.prepare/2`) into the state.

  `:merge` keeps everything there: what has the same id and the same
  definition changes nothing; what has the same id and another definition
  comes in under a new id, to review, as an agent's proposal waits for you;
  the rest comes in with its start setting. A stored value goes in only for
  a credential that comes in. The built-in grants take the section's start
  settings and Always ask me, and the entries of their host lists they
  lack. *This machine, for agents* and the way of working are taken only
  where yours are empty.

  `:replace` puts the section in place of your credentials and grants (the
  built-in grants' settings too), placeholders as they are, as an import in
  replace mode does, and as a failed import puts back what was there. The
  section's presets are written in either mode; yours it lacks stay.
  """
  def import(state, mode, prepared) do
    # Networks first: one whose id you have with another definition comes
    # in under a new id, and the grants over it follow.
    {state, moved} = import_networks(state, Map.get(prepared, :networks, []), mode)

    prepared = %{
      prepared
      | grants:
          Enum.map(prepared.grants, fn
            %Grant{kind: :network, network: id} = g when is_binary(id) ->
              %{g | network: Map.get(moved, id, id)}

            g ->
              g
          end)
    }

    state
    |> import_grants(mode, prepared)
    |> import_internet_limits(Map.get(prepared, :internet_limits), mode)
    |> import_built_in(prepared.built_in, mode)
    |> import_presets(prepared.presets, mode)
    |> import_settings(prepared.settings, mode)
    |> then(fn state ->
      # Every network grant over its network, one from a file of before
      # networks given one and its host list made grants over its hosts,
      # the Internet's settings' included.
      {grants, networks} = Network.migrate(state.grants, Map.get(state, :networks, []))

      state
      |> Map.put(:networks, networks)
      |> State.change(:grants, fn _ -> grants end)
      |> State.change(
        :grants,
        &Credential.attach_all(&1.grants, Map.get(&1, :credentials, []))
      )
    end)
    |> State.log(%{
      outcome: :grant,
      summary:
        "Grants imported (#{if mode == :merge, do: "merged", else: "replacing yours"}): " <>
          "#{length(prepared.grants)} grants, #{length(prepared.credentials)} credentials" <>
          dropped_words(Map.get(prepared, :dropped_checks, []))
    })
    |> State.write_inbox()
    |> State.changed()
  end

  defp dropped_words([]), do: ""

  defp dropped_words(dropped),
    do:
      ". Checks removed, which no longer run: " <>
        Enum.map_join(dropped, "; ", fn {grant, checks} ->
          "#{grant}: #{Enum.join(checks, ", ")}"
        end)

  # Merging keeps yours: a network of the file's that is yours already
  # (the same id, destinations, DNS server and interface) changes nothing;
  # one whose id you have for another network comes in beside it under a
  # new id, so its grants, to review, show what the file meant. Replacing
  # puts the file's in place of yours, the Internet staying MWT's. Returns
  # the state and the new ids, by the file's.
  # The hosts the Internet blocks: the file's in place of yours, or, to
  # merge, the entries you lack, yours staying where both name a host.
  defp import_internet_limits(state, nil, _mode), do: state

  defp import_internet_limits(state, limits, mode) do
    Map.update(state, :networks, [], fn networks ->
      Enum.map(networks, fn
        %Network{internet: true} = internet ->
          merged =
            case mode do
              :replace ->
                limits

              :merge ->
                mine = MapSet.new(internet.limits.rules, &String.trim_leading(&1.host, "*."))

                %{
                  internet.limits
                  | rules:
                      internet.limits.rules ++
                        Enum.reject(
                          limits.rules,
                          &MapSet.member?(mine, String.trim_leading(&1.host, "*."))
                        )
                }
            end

          %{internet | limits: merged}

        network ->
          network
      end)
    end)
  end

  defp import_networks(state, networks, :merge) do
    Enum.reduce(networks, {state, %{}}, fn network, {state, moved} ->
      mine = Map.get(state, :networks, [])

      case Enum.find(mine, &(&1.id == network.id)) do
        nil ->
          {Map.put(state, :networks, mine ++ [network]), moved}

        same
        when same.destinations == network.destinations and same.resolver == network.resolver and
               same.anchor == network.anchor ->
          {state, moved}

        _other ->
          id = free_id(network.id, Enum.map(mine, & &1.id) ++ Enum.map(state.grants, & &1.id))

          {Map.put(state, :networks, mine ++ [%{network | id: id}]),
           Map.put(moved, network.id, id)}
      end
    end)
  end

  defp import_networks(state, networks, :replace) do
    internet = Enum.filter(Map.get(state, :networks, []), & &1.internet)
    {Map.put(state, :networks, internet ++ Enum.reject(networks, & &1.internet)), %{}}
  end

  defp import_grants(state, :replace, prepared) do
    {built_in, _own} = Enum.split_with(state.grants, &Grant.built_in?/1)

    state
    |> Map.put(:credentials, prepared.credentials)
    |> Map.put(:values, prepared.values.())
    |> State.change(:grants, fn _ -> built_in ++ Grants.start(prepared.grants) end)
  end

  defp import_grants(state, :merge, prepared) do
    credentials = Map.get(state, :credentials, [])
    theirs = prepared.values.()

    # Credentials first: one whose id is taken by another definition comes
    # in under a new id, and the grants over it follow.
    {credentials, renamed, values} =
      Enum.reduce(prepared.credentials, {credentials, %{}, state.values}, fn c,
                                                                             {acc, renamed,
                                                                              values} ->
        case Enum.find(acc, &(&1.id == c.id)) do
          nil ->
            {acc ++ [fresh(c)], renamed, put_value(values, c.id, theirs[c.id])}

          same ->
            if same_credential?(same, c) do
              {acc, renamed, values}
            else
              id = free_id(c.id, Enum.map(acc, & &1.id))

              {acc ++ [fresh(%{c | id: id})], Map.put(renamed, c.id, id),
               put_value(values, id, theirs[c.id])}
            end
        end
      end)

    {grants, _} =
      Enum.reduce(prepared.grants, {state.grants, %{}}, fn g, {acc, moved} ->
        g = %{
          g
          | credential: g.credential && Map.get(renamed, g.credential, g.credential),
            with: Enum.map(g.with, &Map.get(renamed, &1, &1))
        }

        case Enum.find(acc, &(&1.id == g.id)) do
          nil ->
            {acc ++ Grants.start([g]), moved}

          same ->
            if Grant.definition(same) == Grant.definition(g) and same_scope?(same, g) do
              {acc, moved}
            else
              id = free_id(g.id, Enum.map(acc, & &1.id))

              proposal = %{
                agent: "An import",
                thread: nil,
                reason: "Imported from an export, where #{g.name} differs from yours.",
                minutes: 60,
                at: State.now(),
                reviewed_at: nil,
                revision: nil
              }

              to_review = %{
                Grant.put_down(g)
                | id: id,
                  start: :off,
                  proposal: proposal
              }

              {acc ++ [to_review], Map.put(moved, g.id, id)}
            end
        end
      end)

    state
    |> Map.put(:credentials, credentials)
    |> Map.put(:values, values)
    |> State.change(:grants, fn _ -> grants end)
  end

  defp put_value(values, _id, nil), do: values
  defp put_value(values, id, value), do: Map.put_new(values, id, value)

  # The same definition, placeholders aside: those are made anew for what
  # comes in (`fresh/1`).
  defp same_credential?(a, b), do: definition_of(a) == definition_of(b)

  defp definition_of(%Credential{} = c) do
    c
    |> Map.from_struct()
    |> Map.take(Credential.copied() ++ [:name])
    |> Map.drop([:placeholder, :aliases, :login_aliases])
    |> Map.update(:presents, nil, &without_refresh/1)
  end

  defp without_refresh(%{login: %{} = login} = presents),
    do: %{presents | login: Map.delete(login, :refresh)}

  defp without_refresh(presents), do: presents

  # A credential coming in, with placeholders made anew in the shape of
  # its own (`ghp_…`), and none of the old ones it answered to: a
  # placeholder from a file could be one of yours.
  defp fresh(%Credential{} = c) do
    presents =
      case c.presents do
        %{login: %{refresh: _}} = presents ->
          put_in(presents, [:login, :refresh], Grant.new_login_placeholder())

        presents ->
          presents
      end

    %{
      c
      | placeholder: c.placeholder && Grants.fresh_placeholder(c.placeholder),
        aliases: [],
        login_aliases: [],
        presents: presents
    }
  end

  defp same_scope?(a, b),
    do:
      Map.take(a, [:name, :kind, :hosts, :carriers, :destinations, :credential, :signs_as, :reach]) ==
        Map.take(b, [
          :name,
          :kind,
          :hosts,
          :carriers,
          :destinations,
          :credential,
          :signs_as,
          :reach
        ])

  defp free_id(id, taken) do
    Stream.iterate(2, &(&1 + 1))
    |> Stream.map(&"#{id}-imported#{if &1 == 2, do: "", else: "-#{&1}"}")
    |> Enum.find(&(&1 not in taken))
  end

  defp import_built_in(state, built_in, mode) do
    State.change(state, :grants, fn state ->
      Enum.map(state.grants, fn grant ->
        case Grant.built_in?(grant) && Enum.find(built_in, &(&1.id == grant.id)) do
          nil ->
            grant

          false ->
            grant

          settings ->
            rules =
              case mode do
                :replace ->
                  settings.host_rules

                :merge ->
                  # A host you have a grant over already stays as yours.
                  known =
                    for %Grant{kind: :network, scope: [entry]} = g <- state.grants,
                        Network.part?(g),
                        Network.id_of(g) == Network.id_of(grant),
                        into: MapSet.new(grant.host_rules, & &1.host),
                        do: String.trim_leading(entry, "*.")

                  grant.host_rules ++
                    Enum.reject(
                      settings.host_rules,
                      &MapSet.member?(known, String.trim_leading(&1.host, "*."))
                    )
              end

            start =
              if settings.start in Grant.starts(grant), do: settings.start, else: grant.start

            ceiling =
              if settings.ceiling in [:ask, :allow], do: settings.ceiling, else: grant.ceiling

            %{grant | start: start, ceiling: ceiling, host_rules: rules}
        end
      end)
    end)
  end

  defp import_presets(state, presets, mode) do
    dir = Presets.dir(state.username)
    File.mkdir_p!(dir)

    for %{name: name, json: json} <- presets, Presets.file_name?(name) do
      path = Path.join(dir, name)
      if mode == :replace or not File.exists?(path), do: File.write!(path, json)
    end

    state
  end

  # What the section checked as invalid (`:invalid`) leaves yours as it is,
  # in either mode.
  defp import_settings(state, settings, mode) do
    take = fn
      mine, :invalid -> mine
      mine, theirs -> if mode == :replace or mine in [nil, ""], do: theirs, else: mine
    end

    reads =
      case settings[:confine_reads] do
        folders when is_list(folders) -> folders |> Enum.map(&Path.expand/1) |> Enum.uniq()
        other -> other
      end

    %{
      state
      | settings:
          Map.merge(state.settings, %{
            host_notes: take.(state.settings.host_notes, settings.host_notes),
            way_of_working: take.(state.settings.way_of_working, settings.way_of_working),
            confine_reads: take.(Map.get(state.settings, :confine_reads), reads)
          })
    }
  end
end
