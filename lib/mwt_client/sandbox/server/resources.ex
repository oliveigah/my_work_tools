defmodule MWTClient.Sandbox.Server.Resources do
  @moduledoc """
  The resources in the sandbox server's state, added, edited and removed
  on their own (`MWTClient.Sandbox.Resource`): credentials
  (`state.credentials`) and networks (`state.networks`). Your machine and
  MWT's tools are built in, as is the Internet.

  A resource holds what it is: a credential where its value comes from
  and how tools in the VM find its placeholder; a network its addresses,
  DNS server, interface and the hosts it blocks
  (`MWTClient.Sandbox.HostLimits`). Grants over it give uses of it. Every
  grant over a resource holds a copy of its fields
  (`MWTClient.Sandbox.Credential.attach/2`,
  `MWTClient.Sandbox.Network.attach/2`), taken again at each change.

  Removing a resource removes the grants over it, and a credential's
  value with it.
  """

  alias MWTClient.Sandbox.{Credential, Grant, HostLimits, Network}
  alias MWTClient.Sandbox.Server.{Grants, State}

  @doc """
  A credential from its form's fields, with its value when it was pasted:
  added under an id of its own, made from its name. `{:ok, state,
  credential}` or `{:error, errors}` by field.
  """
  def create_credential(state, attrs) do
    credentials = Map.get(state, :credentials, [])

    with {:ok, built, value} <- build_credential(attrs, [], false) do
      id = free_id(slug(built.name), Enum.map(credentials, & &1.id))
      credential = %{built | id: id}

      state =
        state
        |> Map.put(:credentials, credentials ++ [credential])
        |> Map.update!(:values, &if(value, do: Map.put(&1, id, value), else: &1))
        |> State.log(%{outcome: :grant, summary: "#{credential.name} added, a credential"})
        |> State.write_inbox()
        |> State.changed()

      {:ok, state, credential}
    end
  end

  @doc """
  A credential changed from its form: its name, words, how its value is
  made and how tools find it. Its id and placeholders stay, so tools that
  hold them go on working; a new value pasted replaces the old. What was
  minted the old way goes.
  """
  def update_credential(state, id, attrs) do
    credentials = Map.get(state, :credentials, [])

    with %Credential{} = before <- Enum.find(credentials, &(&1.id == id)) || {:error, :not_found},
         {:ok, built, value} <- build_credential(attrs, [placeholder: before.placeholder], true) do
      credential = %{
        before
        | name: built.name,
          purpose: built.purpose,
          source: built.source,
          mint_per: built.mint_per,
          keep_minutes: built.keep_minutes,
          env: built.env,
          file_env: built.file_env,
          git: built.git,
          presents: keep_login(built.presents, before.presents),
          app: built.app || before.app
      }

      credentials = Enum.map(credentials, &if(&1.id == id, do: credential, else: &1))

      state =
        state
        |> Map.put(:credentials, credentials)
        |> Map.update!(:values, &if(value, do: Map.put(&1, id, value), else: &1))
        |> State.change(:grants, &Credential.attach_all(&1.grants, credentials))
        |> then(&if(made_same?(before, credential), do: &1, else: Grants.forget_values(&1, id)))
        |> State.log(%{outcome: :grant, summary: "#{credential.name} edited, a credential"})
        |> State.write_inbox()
        |> State.changed()

      {:ok, state, credential}
    end
  end

  # A credential's form, read as a token grant's is (`Grants.build_grant/3`),
  # its scope left out: the credential is what it presents and how its
  # value is made.
  defp build_credential(attrs, keep, editing?) do
    attrs = Map.merge(attrs, %{"kind" => "token", "hosts" => "credential.invalid"})

    case Grants.build_grant(attrs, [], editing: editing?, preset: nil) do
      {:ok, grant, value} ->
        grant = %{grant | placeholder: keep[:placeholder] || grant.placeholder}
        {:ok, %{Credential.of_grant(grant) | preset: blank(attrs["preset"])}, value}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp made_same?(before, now),
    do:
      {before.source, before.mint_per, before.keep_minutes, before.app} ==
        {now.source, now.mint_per, now.keep_minutes, now.app}

  # A login file's refresh placeholder never changes while the file stays.
  defp keep_login(%{login: login} = presents, %{login: %{refresh: refresh}}),
    do: %{presents | login: %{login | refresh: refresh}}

  defp keep_login(presents, _before), do: presents

  @doc """
  A network from its form's fields: its name, words, destinations, DNS
  server and interface, every host reachable. `{:ok, state, network}` or
  `{:error, errors}` by field.
  """
  def create_network(state, attrs) do
    networks = Map.get(state, :networks, [])

    with {:ok, built} <- build_network(attrs) do
      network = %{built | id: free_id(slug(built.name), Enum.map(networks, & &1.id))}

      state =
        state
        |> Map.put(:networks, networks ++ [network])
        |> State.log(%{outcome: :grant, summary: "#{network.name} added, a network"})
        |> State.write_inbox()
        |> State.changed()

      {:ok, state, network}
    end
  end

  @doc """
  A network changed from its form; the Internet's are MWT's. Every grant
  over it takes its fields again.
  """
  def update_network(state, id, attrs) do
    networks = Map.get(state, :networks, [])

    case Enum.find(networks, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      %Network{internet: true} ->
        {:error, :built_in}

      before ->
        with {:ok, built} <- build_network(attrs) do
          network = %{
            before
            | name: built.name,
              purpose: built.purpose,
              destinations: built.destinations,
              resolver: built.resolver,
              anchor: built.anchor
          }

          {:ok, put_network(state, network, "#{network.name} edited, a network"), network}
        end
    end
  end

  # A network's form, read as a network grant's is.
  defp build_network(attrs) do
    attrs = Map.merge(attrs, %{"kind" => "network"})

    case Grants.build_grant(attrs, [], editing: true, preset: nil) do
      {:ok, grant, _value} ->
        {:ok, %{Network.of_grant(grant) | preset: blank(attrs["preset"])}}

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc """
  A change to a network's limits (`MWTClient.Sandbox.HostLimits`):
  `{:default, :reachable | :blocked}`, `{:put, host, blocked?}` or
  `{:remove, host}`. `{:ok, state, network}` or `{:error, message}`.
  """
  def set_limits(state, id, change) do
    case Enum.find(Map.get(state, :networks, []), &(&1.id == id)) do
      nil ->
        {:error, "No such network."}

      network ->
        with {:ok, limits, words} <- limits_change(network.limits, change) do
          network = %{network | limits: limits}
          {:ok, put_network(state, network, "#{network.name}: #{words}"), network}
        end
    end
  end

  defp limits_change(limits, {:default, default}) when default in [:reachable, :blocked],
    do:
      {:ok, HostLimits.set_default(limits, default),
       "hosts on neither list now #{default_words(default)}"}

  defp limits_change(limits, {:put, host, blocked?})
       when is_binary(host) and is_boolean(blocked?) do
    with {:ok, limits} <- HostLimits.put(limits, host, blocked?) do
      {:ok, limits, "#{String.trim(host)} #{if(blocked?, do: "blocked", else: "reachable")}"}
    end
  end

  defp limits_change(limits, {:remove, host}) when is_binary(host),
    do: {:ok, HostLimits.remove(limits, host), "#{String.trim(host)} taken off its list"}

  defp limits_change(_limits, _change), do: {:error, "That isn't a change to a network's hosts."}

  defp default_words(:reachable), do: "reachable"
  defp default_words(:blocked), do: "blocked"

  defp put_network(state, network, summary) do
    networks =
      Enum.map(Map.get(state, :networks, []), &if(&1.id == network.id, do: network, else: &1))

    state
    |> Map.put(:networks, networks)
    |> State.change(:grants, &Network.attach_all(&1.grants, networks))
    |> State.log(%{outcome: :grant, summary: summary})
    |> State.write_inbox()
    |> State.changed()
  end

  @doc """
  Removes a credential or a network, with every grant over it; a
  credential's value and what was minted from it go too. Built-in
  resources stay: `{:error, :built_in}`.
  """
  def delete(state, {:credential, id} = resource) do
    case Enum.find(Map.get(state, :credentials, []), &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      credential ->
        state =
          state
          |> drop_grants(resource)
          |> Map.update!(:credentials, &Enum.reject(&1, fn c -> c.id == id end))
          |> Map.update!(:values, fn values ->
            Map.reject(values, fn
              {{^id, _part}, _} -> true
              {key, _} -> key == id
            end)
          end)
          |> Grants.forget_values(id)
          |> State.log(%{outcome: :grant, summary: "#{credential.name} removed, a credential"})
          |> State.write_inbox()
          |> State.changed()

        {:ok, state}
    end
  end

  def delete(state, {:network, id} = resource) do
    case Enum.find(Map.get(state, :networks, []), &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      %Network{internet: true} ->
        {:error, :built_in}

      network ->
        state =
          state
          |> drop_grants(resource)
          |> Map.update!(:networks, &Enum.reject(&1, fn n -> n.id == id end))
          |> State.log(%{outcome: :grant, summary: "#{network.name} removed, a network"})
          |> State.write_inbox()
          |> State.changed()

        {:ok, state}
    end
  end

  def delete(_state, _built_in), do: {:error, :built_in}

  defp drop_grants(state, resource) do
    state.grants
    |> Enum.filter(&(Grant.resource(&1) == resource))
    |> Enum.reduce(state, &Grants.delete(&2, &1, "#{&1.name} removed, with its resource"))
  end

  defp blank(value) when is_binary(value) and value != "", do: value
  defp blank(_value), do: nil

  defp slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "resource"
      slug -> String.slice(slug, 0, 40)
    end
  end

  defp free_id(id, taken) do
    if id in taken,
      do: Enum.find_value(2..10_000, &("#{id}-#{&1}" not in taken && "#{id}-#{&1}")),
      else: id
  end
end
