defmodule MWTClient.Sandbox.Made do
  @moduledoc """
  A value MWT made with a grant's real value, which the VM holds only as a
  placeholder (`MWTClient.Sandbox.CredentialEndpoint`): a JWT Google signed
  for it as a service account, kept as it came (`source: :fixed`); or the
  grant's ID token (`source: :id_token`), which stands for the one the
  grant's mint gives now, so a request carrying it gets a fresh one,
  whenever the tool asked for it.

  A grant's own value has one placeholder, made once. A made value has a
  placeholder of its own, made with it, and goes only where it was made
  for, which is narrower than where its grant goes:

    * **its hosts**, a subset of its grant's: a signed JWT goes only to the
      host its `aud` names;
    * **its carriers**, the headers MWT puts it in;
    * **until it expires**, its own expiry (a JWT's `exp`).

  It belongs to its grant: a request carrying its placeholder is a use of
  that grant, approved as any other, refused while the grant is off. It
  is kept in the server's memory only, as minted values are, so after MWT
  restarts the tool asks for it again. Expired, or no longer covered by
  its grant (`covered?/3`: the grant gone, no longer signing as its
  account or listing its host), a request carrying it is refused, saying
  so, rather than sent with a placeholder the service can't read.

  What `MWTClient.Sandbox.Policy` reads of it is the same struct with no
  value (`unvalued/1`): it decides from where a placeholder may go, never
  from the value behind it.
  """

  alias MWTClient.Sandbox.{Grant, Policy}

  @enforce_keys [:placeholder, :grant_id, :name, :hosts, :carriers, :until]
  defstruct [
    :placeholder,
    :grant_id,
    :name,
    :value,
    :account,
    :hosts,
    :carriers,
    :until,
    source: :fixed
  ]

  @typedoc """
  `name` says what it is in the log and on refusals ("BigQuery's JWT
  signed as …"); `account`, the service account it was signed as.
  """
  @type t :: %__MODULE__{
          placeholder: String.t(),
          grant_id: String.t(),
          name: String.t(),
          value: String.t() | nil,
          source: :fixed | :id_token,
          account: String.t() | nil,
          hosts: [String.t()],
          carriers: [String.t()],
          until: DateTime.t()
        }

  # A grant's made values kept at most: a tool signs again each time it
  # starts, and an old one is of no use once it expired.
  @kept_per_grant 64

  # A JWT's placeholder is the JWT with its signature replaced: `mwt` and
  # 43 base64url characters, never what an RS256 or ES256 signature is.
  @jwt_placeholder ~r/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.mwt[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/

  @doc """
  The placeholder for a JWT: its header and claims, which say nothing
  secret, so a client reading them locally works, with a random signature
  that marks it as MWT's. With `kept`, only those claims.
  """
  @spec jwt_placeholder(String.t(), [String.t()] | :all) :: String.t()
  def jwt_placeholder(jwt, kept \\ :all) do
    [header, claims | _signature] = String.split(jwt, ".")
    signature = "mwt" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Enum.join([header, kept_claims(claims, kept), signature], ".")
  end

  # The claims segment with only the `kept` claims, written again; as it
  # was when all are kept.
  defp kept_claims(claims, :all), do: claims

  defp kept_claims(claims, kept) do
    {:ok, decoded} = Base.url_decode64(claims, padding: false)

    decoded
    |> Jason.decode!()
    |> Map.take(kept)
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The JWT placeholders MWT writes found in `text`, made now or before, known
  or not.

      iex> placeholder = MWTClient.Sandbox.Made.jwt_placeholder("aGVhZA.Y2xhaW1z.c2ln")
      iex> MWTClient.Sandbox.Made.jwt_placeholders_in("Bearer " <> placeholder) == [placeholder]
      true
      iex> MWTClient.Sandbox.Made.jwt_placeholders_in("Bearer aGVhZA.Y2xhaW1z.c2ln")
      []
  """
  @spec jwt_placeholders_in(String.t()) :: [String.t()]
  def jwt_placeholders_in(text), do: @jwt_placeholder |> Regex.scan(text) |> List.flatten()

  @doc "A JWT's claims, read without checking its signature: `{:ok, map}` or `:error`."
  @spec claims(String.t()) :: {:ok, map()} | :error
  def claims(jwt) do
    with [_header, claims, _signature] <- String.split(jwt, "."),
         {:ok, decoded} <- Base.url_decode64(claims, padding: false),
         {:ok, %{} = claims} <- Jason.decode(decoded) do
      {:ok, claims}
    else
      _other -> :error
    end
  end

  @doc "The same, without its value: what decisions read."
  @spec unvalued(t()) :: t()
  def unvalued(%__MODULE__{} = made), do: %{made | value: nil}

  @doc """
  Whether `made` may still go anywhere at `now`: unexpired, and its grant
  (among `grants`) still covering it, signing as its account and listing
  each of its hosts.
  """
  @spec covered?(t(), [Grant.t()], DateTime.t()) :: boolean()
  def covered?(%__MODULE__{} = made, grants, now) do
    grant = Enum.find(grants, &(&1.id == made.grant_id and &1.kind == :token))

    DateTime.compare(made.until, now) == :gt and grant != nil and
      (is_nil(made.account) or made.account in grant.signs_as) and
      (made.source != :id_token or Grant.login_placeholder(grant) != nil) and
      Enum.all?(made.hosts, &Policy.host_listed?(&1, grant.hosts))
  end

  @doc """
  `kept`, the made values by placeholder, with `made` added: the expired
  dropped, and of its grant's others, the #{@kept_per_grant - 1} that
  expire last kept.
  """
  @spec put(%{String.t() => t()}, t(), DateTime.t()) :: %{String.t() => t()}
  def put(kept, %__MODULE__{} = made, now) do
    {own, others} =
      kept
      |> Map.values()
      |> Enum.filter(&(DateTime.compare(&1.until, now) == :gt))
      |> Enum.split_with(&(&1.grant_id == made.grant_id))

    own = [
      made
      | own |> Enum.sort_by(& &1.until, {:desc, DateTime}) |> Enum.take(@kept_per_grant - 1)
    ]

    Map.new(own ++ others, &{&1.placeholder, &1})
  end

  @doc "`kept` without `grant_id`'s made values: the grant was removed."
  @spec drop_grant(%{String.t() => t()}, String.t()) :: %{String.t() => t()}
  def drop_grant(kept, grant_id),
    do: Map.reject(kept, fn {_placeholder, made} -> made.grant_id == grant_id end)
end
