defmodule MWTClient.Sandbox.Adapter do
  @moduledoc """
  What MWT knows of one family of credentials, behind fixed extension
  points the core calls. The core owns the flow: the locks, the rule, the
  cards, when to mint and what is kept, swapping placeholders, what the VM
  gets, the firewall. An adapter supplies what only the family knows:

    * `read_mint/2` - reading what a mint command prints: the value, a
      value that comes with it (an ID token), and how long it lasts;
    * `implied_hosts/1` - the hosts its own endpoints need, which a grant
      over it needn't list: they are plumbing, not access;
    * `env/1` - variables `mwt exec` sets beside the credential's own
      (a project a client library looks for);
    * `attributes/1` - what its requests name that a grant may narrow by
      (`MWTClient.Sandbox.Attributes`), read only from a URL or a
      documented field, never from what a query means;
    * `sign_jwt/4`, optional - a JWT signed as one of the accounts a grant
      names, with the credential's real value, for a request action that
      sends one (`{signed_jwt}`, `MWTClient.Sandbox.SavedRequest`).

  Adapters ship with MWT, never as plugins you install: they run in the
  process that holds every real value. Your presets stay data, on top of
  any of them (`MWTClient.Sandbox.Presets`).
  """

  alias MWTClient.Sandbox.{Credential, Grant}

  @typedoc "What a mint printed, read: the values and how many milliseconds they stay fresh."
  @type minted :: {:ok, %{value: String.t(), id_token: String.t() | nil}, non_neg_integer()}

  @callback id() :: atom()
  @callback name() :: String.t()
  @callback read_mint(output :: String.t(), now :: DateTime.t()) ::
              minted() | {:error, String.t()}
  @callback implied_hosts(Credential.t() | Grant.t()) :: [String.t()]
  @callback env(Credential.t() | Grant.t()) :: [{String.t(), String.t()}]
  @callback attributes(request :: map()) :: map()
  @callback sign_jwt(value :: String.t(), account :: String.t(), aud :: String.t(), DateTime.t()) ::
              {:ok, String.t()} | {:error, String.t()}
  @optional_callbacks sign_jwt: 4

  @adapters [
    MWTClient.Sandbox.Adapter.Bearer,
    MWTClient.Sandbox.Adapter.GitHub,
    MWTClient.Sandbox.Adapter.Google,
    MWTClient.Sandbox.Adapter.Hex
  ]

  @doc "Every adapter MWT ships."
  @spec all() :: [module()]
  def all, do: @adapters

  @doc """
  The adapter whose id is `id`, given as an atom or as its text, as a form
  or a preset names it; `:error` for none.

      iex> MWTClient.Sandbox.Adapter.find("github")
      {:ok, MWTClient.Sandbox.Adapter.GitHub}
      iex> MWTClient.Sandbox.Adapter.find("nope")
      :error
  """
  @spec find(atom() | String.t() | nil) :: {:ok, module()} | :error
  def find(id) do
    case Enum.find(@adapters, &(Atom.to_string(&1.id()) == to_string(id))) do
      nil -> :error
      adapter -> {:ok, adapter}
    end
  end

  @doc """
  The adapter for a credential, or a token grant over it: the one it
  names (`Credential.adapter`), else the one its preset or its fields say
  (GitHub's with an App; Google's when it signs, presents a login file or
  a metadata server, or comes from a Google preset; GitHub's or Hex's from
  theirs), else `bearer`. Only what was saved before credentials named
  their adapter, or is still being built, goes by what it says.

      iex> alias MWTClient.Sandbox.{Adapter, Grant}
      iex> Adapter.of(%Grant{id: "g", name: "G", kind: :token, preset: "github"})
      MWTClient.Sandbox.Adapter.GitHub
      iex> Adapter.of(%Grant{id: "g", name: "G", kind: :token, signs_as: ["sa@p.iam.gserviceaccount.com"]})
      MWTClient.Sandbox.Adapter.Google
      iex> Adapter.of(%Grant{id: "g", name: "G", kind: :token})
      MWTClient.Sandbox.Adapter.Bearer
  """
  @spec of(Credential.t() | Grant.t()) :: module()
  def of(%{adapter: id}) when is_atom(id) and not is_nil(id),
    do: Enum.find(@adapters, MWTClient.Sandbox.Adapter.Bearer, &(&1.id() == id))

  def of(%{} = credential) do
    preset = credential |> Map.get(:preset) |> to_string()
    presents = Map.get(credential, :presents) || %{}

    cond do
      Map.get(credential, :app) != nil ->
        MWTClient.Sandbox.Adapter.GitHub

      String.starts_with?(preset, "google") or Map.get(credential, :signs_as, []) != [] or
        Map.has_key?(presents, :login) or Map.has_key?(presents, :metadata) ->
        MWTClient.Sandbox.Adapter.Google

      String.starts_with?(preset, "github") ->
        MWTClient.Sandbox.Adapter.GitHub

      String.starts_with?(preset, "hex") ->
        MWTClient.Sandbox.Adapter.Hex

      true ->
        MWTClient.Sandbox.Adapter.Bearer
    end
  end

  @doc """
  What a mint printed, made into the credential's value by its adapter:
  read as it is (`read_mint/2`), or, for an adapter that makes its value
  from what the mint printed (a GitHub App's key), exchanged.
  """
  @spec made(module(), Credential.t() | Grant.t(), String.t(), DateTime.t()) ::
          minted() | {:error, String.t()}
  def made(adapter, credential, output, now) do
    if Map.get(credential, :app) != nil and function_exported?(adapter, :exchange, 3),
      do: adapter.exchange(output, credential, now),
      else: adapter.read_mint(output, now)
  end

  @doc """
  What every adapter reads of a request that a grant may narrow by,
  together.
  """
  @spec attributes(map()) :: map()
  def attributes(request),
    do: Enum.reduce(@adapters, %{}, &Map.merge(&2, &1.attributes(request)))

  @doc """
  The hosts a token grant's value may go: the ones it lists, and those its
  credential's adapter implies for its own endpoints.
  """
  @spec hosts(Grant.t()) :: [String.t()]
  def hosts(%Grant{kind: :token} = grant),
    do: Enum.uniq(grant.hosts ++ of(grant).implied_hosts(grant))

  def hosts(%Grant{} = grant), do: grant.hosts
end
