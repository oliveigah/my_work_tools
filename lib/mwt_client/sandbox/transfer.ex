defmodule MWTClient.Sandbox.Transfer do
  @moduledoc """
  The agent sandbox's section of an export (`MWTClient.Transfer.Participant`):
  what you set up for agents, so it moves to another machine or comes back
  from a backup.

  It holds:

    * your credentials (`MWTClient.Sandbox.Credential`): how each value is
      made and how tools find it, and their stored values only when you
      choose to export them (`for_file/2`); minted values never travel,
      since they come from logins on the machine that minted them;
    * your grants and their actions, as you defined them: scope, start
      setting, Always ask me, host lists; the built-in grants' settings
      (start, Always ask me, host lists), not their definitions, which are
      MWT's;
    * your presets (`sandbox/presets/*.json`);
    * what agents read of this machine: *This machine, for agents*, and the
      way of working.

  It leaves out what lasts a session (states, allowances, locks), grants
  an agent proposed and you haven't reviewed, the activity log, handoffs,
  the VM's disks and the CA.

  Importing (`merge/2`) keeps everything there: the same id with the same
  definition changes nothing, so importing twice is harmless; the same id
  with another definition comes in under a new id, to review, as a grant
  an agent proposed waits for you. `prepare/2` checks the data and changes
  nothing. Grants come in with their start settings. A credential that
  comes in gets placeholders made anew, so none can be one of yours; one
  already there with the same definition (placeholders aside) changes
  nothing.

  Stored values travel inside a function from the moment the file is read
  (`values`), as a value on its way to the vault does: a message is printed
  in full when a process crashes, and a function prints as its name.
  """

  @behaviour MWTClient.Transfer.Participant

  alias MWTClient.Sandbox.{Credential, Grant, Presets, Server}

  @impl true
  def key, do: "sandbox"

  @impl true
  def label, do: "Agent sandbox grants"

  @impl true
  def version, do: 1

  @impl true
  def export(username) do
    {:ok, Server.call(username, :transfer_export)}
  catch
    :exit, reason -> {:error, {:sandbox, reason}}
  end

  @doc """
  The section as it goes into a file: without stored values unless
  `values: true` (*Include stored credential values*). The whole section,
  values included, is what an import puts back should it fail.
  """
  @spec for_file(map(), keyword()) :: map()
  def for_file(data, opts) do
    if Keyword.get(opts, :values, false), do: data, else: %{data | values: %{}}
  end

  @impl true
  def prepare(1, %{} = data) do
    with {:ok, credentials} <- list(data, :credentials, &credential/1),
         {:ok, networks} <- list(data, :networks, &network/1),
         {:ok, grants} <- list(data, :grants, &grant/1),
         {:ok, internet_limits} <- limits(Map.get(data, :internet_limits)),
         {:ok, built_in} <- list(data, :built_in, &built_in/1),
         {:ok, presets} <- list(data, :presets, &preset/1) do
      values =
        for {id, value} <- Map.get(data, :values, %{}),
            id?(id) and is_binary(value),
            into: %{},
            do: {id, value}

      values = fn -> values end

      # Checks are gone: a grant of the file's that had some comes in
      # without, and the import names them.
      dropped_checks =
        for %{name: name} = saved <- List.wrap(Map.get(data, :grants)),
            is_binary(name),
            checks = List.wrap(Map.get(saved, :checks)),
            checks != [],
            do: {name, Enum.map(checks, &((is_map(&1) && Map.get(&1, :name)) || "a check"))}

      settings = Map.get(data, :settings, %{})

      {:ok,
       %{
         credentials: credentials,
         networks: networks,
         internet_limits: internet_limits,
         dropped_checks: dropped_checks,
         # Brought up to date together: a request action named the token
         # grant it was under, a saved command the token grants it ran
         # with (`Grant.upgrade_all/1`).
         grants: Grant.upgrade_all(grants),
         built_in: built_in,
         values: values,
         presets: presets,
         settings: %{
           host_notes: text(settings[:host_notes], 4_000),
           way_of_working: text(settings[:way_of_working], 20_000),
           confine_reads: folders(settings[:confine_reads])
         }
       }}
    else
      # The Internet's limits, which `limits/1` reads on their own.
      :error -> {:error, "The agent sandbox's internet_limits can't be read."}
      {:error, _message} = error -> error
    end
  end

  def prepare(_version, _data), do: {:error, "The agent sandbox's section can't be read."}

  @doc """
  What the section brings, in a line for the plan: how many grants,
  credentials and stored values, then what will run on this machine (the
  mints, the saved commands), the grants that start on, and the
  credentials that arrive without a value, so you see them before
  anything changes.
  """
  @impl true
  def describe(prepared) do
    values = prepared.values.()
    networks = length(Map.get(prepared, :networks, []))

    mints =
      for %Credential{source: {:minted, _command}} = c <- prepared.credentials, do: c.name

    commands =
      for %Grant{kind: :command, script: s} = g <- prepared.grants, is_binary(s), do: g.name

    starting =
      for %Grant{start: start} = g <- prepared.grants, start in [:on, :auto] do
        if start == :auto, do: "#{g.name} (auto-approving)", else: g.name
      end

    valueless =
      for %Credential{source: :stored, id: id} = c <- prepared.credentials,
          not Map.has_key?(values, id),
          do: c.name

    [
      "#{count(length(prepared.grants), "grant")}, " <>
        "#{count(length(prepared.credentials), "credential")}" <>
        if(networks > 0, do: ", #{count(networks, "network")}", else: "") <>
        if(map_size(values) > 0, do: ", #{count(map_size(values), "stored value")}", else: ""),
      listed("Runs on this machine: mints for", mints),
      listed("Saved commands, run on this machine when called:", commands),
      listed("Starts on:", starting),
      listed("Arrives without a value:", valueless)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
  end

  defp listed(_words, []), do: nil
  defp listed(words, names), do: "#{words} #{Enum.join(names, ", ")}"

  @impl true
  def merge(username, prepared), do: Server.call(username, {:transfer_import, :merge, prepared})

  @impl true
  def replace(username, prepared),
    do: Server.call(username, {:transfer_import, :replace, prepared})

  ## Reading a section

  defp list(data, key, fun) do
    data
    |> Map.get(key, [])
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, one} -> {:cont, {:ok, acc ++ [one]}}
        :error -> {:halt, {:error, "The agent sandbox's #{key} can't be read."}}
      end
    end)
  end

  defp credential(%{id: id, name: name} = saved) when is_binary(id) and is_binary(name) do
    if id?(id), do: {:ok, Credential.upgrade(saved)}, else: :error
  end

  defp credential(_other), do: :error

  # A network as `Network` holds it: its id as MWT gives ids, never the
  # Internet, which is MWT's.
  defp network(%{id: id, name: name} = saved) when is_binary(id) and is_binary(name) do
    network = MWTClient.Sandbox.Network.upgrade(saved)

    if id?(id) and not network.internet and is_list(network.destinations) and
         Enum.all?(network.destinations, &is_binary/1) and
         match?({:ok, _}, limits(Map.get(saved, :limits))),
       do: {:ok, network},
       else: :error
  end

  defp network(_other), do: :error

  defp grant(%{id: id, name: name, kind: kind} = saved)
       when is_binary(id) and is_binary(name) and kind in [:token, :network, :command, :request] do
    # A command grant without a script was Ask to run commands, MWT's
    # own, which no longer is: `Grant.upgrade_all/1` leaves it out.
    cond do
      not id?(id) -> :error
      not (is_nil(saved[:credential]) or id?(saved[:credential])) -> :error
      true -> {:ok, Map.delete(saved, :__struct__)}
    end
  end

  defp grant(_other), do: :error

  # Ids name files in the VM (`/mnt/mwt/grant-env/<id>.sh`, `tokens/<id>`)
  # and elements on MWT's pages: an export's must have the shape MWT gives
  # them, lowercase words joined by dashes, or the file is refused.
  defp id?(id),
    do:
      is_binary(id) and byte_size(id) <= 100 and
        Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, id)

  defp built_in(%{id: id} = saved) when is_binary(id) do
    rules = List.wrap(saved[:host_rules])

    # The hosts the Internet's grant leaves out, as entries; a file from
    # before them has none.
    except =
      case saved[:except] do
        nil ->
          {:ok, []}

        list when is_list(list) ->
          if Enum.all?(list, &is_binary/1),
            do: MWTClient.Sandbox.Network.except_entries(list),
            else: :error

        _other ->
          :error
      end

    case except do
      {:ok, except} ->
        if Enum.all?(rules, &host_rule?/1),
          do:
            {:ok,
             %{
               id: id,
               start: saved[:start],
               host_rules: rules,
               except: except
             }},
          else: :error

      _error ->
        :error
    end
  end

  defp built_in(_other), do: :error

  # A network's limits (`MWTClient.Sandbox.HostLimits`): none, or a
  # default and entries as MWT keeps them.
  defp limits(nil), do: {:ok, nil}

  defp limits(%{} = saved) do
    limits = MWTClient.Sandbox.HostLimits.upgrade(saved)

    if limits.default in [:reachable, :blocked] and is_list(limits.rules) and
         length(limits.rules) <= 500 and
         Enum.all?(limits.rules, fn
           %{host: host, blocked?: blocked?} ->
             is_binary(host) and byte_size(host) <= 255 and is_boolean(blocked?)

           _other ->
             false
         end),
       do: {:ok, limits},
       else: :error
  end

  defp limits(_other), do: :error

  defp preset(%{name: name, json: json}) when is_binary(name) and is_binary(json) do
    if Presets.file_name?(name), do: {:ok, %{name: name, json: json}}, else: :error
  end

  defp preset(_other), do: :error

  # A host list's entry as `Grant.host_rules` holds it.
  defp host_rule?(%{host: host, action: action}),
    do: is_binary(host) and byte_size(host) <= 255 and action in [:ask, :auto, :block]

  defp host_rule?(_other), do: false

  # Text within the length its form takes (`MWTClient.Sandbox.Settings`);
  # longer, or not text, it is `:invalid`, left out, and yours stays.
  defp text(value, most) when is_binary(value) do
    if String.length(value) <= most, do: value, else: :invalid
  end

  defp text(nil, _most), do: ""
  defp text(_other, _most), do: :invalid

  # The folders a confined command may read, as `Settings` takes them: whole
  # paths, from / or ~/, at most 50; nil for none (your login shell's PATH).
  # Anything else is `:invalid`, and yours stay as they are.
  defp folders(nil), do: nil

  defp folders(list) when is_list(list) and length(list) in 1..50 do
    if Enum.all?(list, &(is_binary(&1) and (&1 == "~" or String.starts_with?(&1, ["/", "~/"])))),
      do: list,
      else: :invalid
  end

  defp folders(_other), do: :invalid

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"
end
