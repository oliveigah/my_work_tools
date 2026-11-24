defmodule MWTClient.Sandbox.Adapter.Google do
  @moduledoc """
  Google's credentials (`MWTClient.Sandbox.Adapter`): an access token, a
  login file whose refresh MWT answers, the ID token a login mint prints,
  `signJwt` for the accounts its grants name, a metadata server.

    * A mint may print what `gcloud config config-helper --format=json`
      prints (`credential.access_token`, `credential.id_token`,
      `credential.token_expiry`), read as it is, or MWT's own JSON.
    * Its endpoints are plumbing, implied for every grant over a credential
      that needs them: Google's token endpoint for a login file
      (`oauth2.googleapis.com`), IAM Credentials for signing
      (`iamcredentials.googleapis.com`). A grant over it needn't list them.
    * `mwt exec` sets `GOOGLE_CLOUD_PROJECT` to the project its metadata
      server reports, when it has one: google-auth warns without one, and
      some clients need it.
  """

  @behaviour MWTClient.Sandbox.Adapter

  alias MWTClient.Sandbox.Adapter.Bearer
  alias MWTClient.Sandbox.CredentialEndpoint

  @impl true
  def id, do: :google

  @impl true
  def name, do: "Google"

  @impl true
  def read_mint("{" <> _ = output, now) do
    case Jason.decode(output) do
      {:ok, %{"credential" => %{"access_token" => value} = credential}}
      when is_binary(value) and value != "" ->
        seconds =
          with expiry when is_binary(expiry) <- credential["token_expiry"],
               {:ok, at, _offset} <- DateTime.from_iso8601(expiry),
               do: DateTime.diff(at, now)

        id_token =
          if is_binary(credential["id_token"]) and credential["id_token"] != "",
            do: credential["id_token"]

        {:ok, %{value: value, id_token: id_token}, Bearer.fresh(seconds)}

      _other ->
        Bearer.read_mint(output, now)
    end
  end

  def read_mint(output, now), do: Bearer.read_mint(output, now)

  @impl true
  def implied_hosts(credential) do
    presents = Map.get(credential, :presents) || %{}

    if(Map.has_key?(presents, :login), do: [CredentialEndpoint.token_host()], else: []) ++
      if Map.get(credential, :signs_as, []) != [], do: [CredentialEndpoint.sign_host()], else: []
  end

  @impl true
  def env(credential) do
    case get_in(Map.get(credential, :presents) || %{}, [:metadata, :project]) do
      project when is_binary(project) and project != "" -> [{"GOOGLE_CLOUD_PROJECT", project}]
      _none -> []
    end
  end

  @impl true
  def attributes(_request), do: %{}

  @doc """
  A JWT signed as `account` by IAM Credentials' `signJwt`, with `value`, the
  credential's access token: issued now, for `aud` (the URL a request
  action sends to), good for an hour, the longest Google signs for. The
  account must let the credential's identity sign as it
  (`roles/iam.serviceAccountTokenCreator`): Google decides, and its refusal
  comes back as it is.
  """
  @impl true
  def sign_jwt(value, account, aud, now) do
    iat = DateTime.to_unix(now)

    payload =
      Jason.encode!(%{
        "iss" => account,
        "sub" => account,
        "aud" => aud,
        "iat" => iat,
        "exp" => iat + 3600
      })

    options =
      [
        url:
          "https://#{CredentialEndpoint.sign_host()}/v1/projects/-/serviceAccounts/" <>
            URI.encode(account, &URI.char_unreserved?/1) <> ":signJwt",
        headers: [{"authorization", "Bearer " <> value}],
        json: %{"payload" => payload},
        retry: false,
        receive_timeout: 20_000
      ] ++ test_options()

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: %{"signedJwt" => jwt}}}
      when status in 200..299 and is_binary(jwt) ->
        {:ok, jwt}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Google answered #{status} to signing as #{account}"}

      {:error, exception} ->
        {:error,
         "Google couldn't be reached to sign as #{account}: #{Exception.message(exception)}"}
    end
  end

  # Only tests configure `config :mwt_client, MWTClient.Sandbox.Adapter.Google,
  # plug: …`, which answers instead of Google.
  defp test_options do
    case Application.get_env(:mwt_client, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
