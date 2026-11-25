defmodule MWTClient.Sandbox.FormFields do
  @moduledoc """
  The fields of each thing you add, as its form, a preset and an agent's
  proposal name them (`mwt propose … --set FIELD=VALUE`): one list per
  thing, read by `MWTClient.Sandbox.Server.Grants.build_grant/3` and the
  resources' builders, so a preset or a proposal can set any field the
  form has, and nothing the form doesn't.

  The things:

    * `:credential` - a credential, a resource: what it is, the service it
      is for (`adapter`), how its value is made, how tools in the VM find
      its placeholder, and what its adapter takes (a GitHub App's ids, a
      Google login file or metadata server);
    * `:network` - a network, a resource: its destinations, the DNS
      server for their names, the interface they are reached through;
    * `:credential_grant` - a grant over a credential: where its value may
      go (`hosts`), in which headers, what it narrows by (`attributes`),
      the service accounts MWT signs JWTs as for it;
    * `:network_grant` - a grant over a network: all of it, or the
      destinations it lists, but the hosts it leaves out (`except`);
    * `:request_action` - a request MWT sends with a credential's value;
    * `:command_action` - a saved command on your machine.

  Some fields are yours alone (`yours/0`): the value, how a grant starts
  and how its uses are approved, whether it covers what MWT can't read,
  and whatever puts a real value within reach of your machine's scripts.
  An agent never sets them: a proposal naming one is refused. Which
  resource a grant or an action is over, and what kind it is, come from
  the command itself, not from a field.
  """

  @type thing ::
          :credential
          | :network
          | :credential_grant
          | :network_grant
          | :request_action
          | :command_action

  @fields %{
    credential: ~w(name purpose adapter source mint mint_per keep_minutes prefix env file_env
                   git app_id installation_id present_metadata present_project present_email
                   present_login present_id_header),
    network: ~w(name purpose destinations resolver anchor),
    credential_grant: ~w(name purpose hosts carriers signs_as attributes),
    network_grant: ~w(name purpose destinations except),
    request_action: ~w(name purpose method url headers body params schema),
    command_action: ~w(name purpose script dir params schema)
  }

  @yours ~w(value start state covers_unread confined with writes_dir)

  @doc """
  The fields `thing` has, as its form names them.

      iex> "app_id" in MWTClient.Sandbox.FormFields.of(:credential)
      true
      iex> "hosts" in MWTClient.Sandbox.FormFields.of(:credential)
      false
  """
  @spec of(thing()) :: [String.t()]
  def of(thing), do: Map.fetch!(@fields, thing)

  @doc "The fields only you set, on any thing."
  @spec yours() :: [String.t()]
  def yours, do: @yours

  @doc """
  `set`, fields an agent or a preset gives for `thing`, checked: `:ok`, or
  why not, naming the first field that is yours or that `thing` doesn't
  have.

      iex> alias MWTClient.Sandbox.FormFields
      iex> FormFields.check(:credential, %{"app_id" => "Iv23li", "installation_id" => "12"})
      :ok
      iex> FormFields.check(:credential, %{"value" => "ghp_x"})
      {:error, "value is yours to set, as you review it."}
      iex> FormFields.check(:network, %{"hosts" => "a.example"})
      {:error, "A network has no field hosts. Its fields: name, purpose, destinations, resolver, anchor."}
  """
  @spec check(thing(), map()) :: :ok | {:error, String.t()}
  def check(thing, set) when is_map(set) do
    fields = of(thing)

    Enum.find_value(Enum.sort(Map.keys(set)), :ok, fn field ->
      cond do
        field in @yours ->
          {:error, "#{field} is yours to set, as you review it."}

        field not in fields ->
          {:error,
           "#{String.capitalize(name(thing))} has no field #{field}. Its fields: " <>
             Enum.join(fields, ", ") <> "."}

        true ->
          nil
      end
    end)
  end

  @doc """
  What `thing` is called in a sentence.

      iex> MWTClient.Sandbox.FormFields.name(:credential_grant)
      "a grant over a credential"
  """
  @spec name(thing()) :: String.t()
  def name(:credential), do: "a credential"
  def name(:network), do: "a network"
  def name(:credential_grant), do: "a grant over a credential"
  def name(:network_grant), do: "a grant over a network"
  def name(:request_action), do: "a request action"
  def name(:command_action), do: "a saved command"
end
