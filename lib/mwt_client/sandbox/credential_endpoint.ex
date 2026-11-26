defmodule MWTClient.Sandbox.CredentialEndpoint do
  @moduledoc """
  A credential endpoint MWT answers itself for a grant that takes it,
  instead of refusing it: what the endpoint makes stays with MWT, as a
  value made from the grant's (`MWTClient.Sandbox.Made`), and the VM gets
  a placeholder for it.

  Without this, a request carrying a grant's placeholder to a credential
  endpoint is refused (`MWTClient.Sandbox.Firewall.minting/3`): its answer
  would be a credential the VM holds. Answered here, the answer the VM
  gets holds only a placeholder, so nothing real enters it.

  Two there are. **Google's token endpoint**, for a grant with a login file
  (`Grant.login_file/1`): a client refreshing that login gets the grant's
  placeholder as its access token and, when the grant's mint gives one, a
  placeholder for an ID token (`refreshed/4`). And **IAM Credentials'
  `signJwt`**, for a grant that names the service accounts it may sign as
  (`Grant.signs_as`), below.

  The refresh, step by step:

    1. `recognize/2`: a `POST` to `oauth2.googleapis.com/token` for a grant
       with a login file. `MWTClient.Sandbox.Policy` finds the grant by the
       login's placeholder in the body, where a refresh carries it.
    2. `check/3`: a refresh grant (`grant_type=refresh_token`) of that very
       login, read whole. Nothing is sent anywhere: the login is the
       grant's mint, on your machine.
    3. `refreshed/4`, once the grant's value is at hand: `access_token` is
       the grant's own placeholder, swapped on the way out as always, with
       `expires_in` as long as MWT keeps the value; `id_token` is a
       placeholder made from the grant's (`MWTClient.Sandbox.Made`),
       standing for its current ID token, which MWT mints again when the
       one it keeps is too old. Its claims are the real token's `iss`,
       `aud`, `iat`, `exp`, `email` and `hd`, no more: a client reading
       them locally works, and nothing else of the login enters the VM.

  `signJwt`, for a grant that names the
  service accounts it may sign as (`Grant.signs_as`). A client of a service
  behind Identity-Aware Proxy loads default credentials, asks Google to sign
  claims it builds as a service account, and sends the JWT as its bearer.
  Step by step:

    1. `recognize/2`: a `POST` to
       `iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/ACCOUNT:signJwt`
       carrying the placeholder of a grant that signs. Any other credential
       endpoint, or this one for a grant that doesn't sign, is left to the
       firewall's rule.
    2. `check/3`, before anyone is asked: the account is one the grant
       names; the claims' `aud` is an `https` URL on a host the grant lists,
       since that host is the only place the signed JWT will go; no
       delegation, which would sign as an account the grant doesn't name.
    3. Once the grant's approval lets it through, MWT sends the same request
       itself (`call/1`), with the grant's real value: the very request the
       tool makes on your machine, with the same token.
    4. `answered/4` reads Google's answer. The signed JWT is kept, made from
       the grant, going only to the `aud` host, in `Authorization`, until
       its `exp`. The VM gets the JWT's header and claims, which it chose,
       and a placeholder where the signature goes, so a client that reads
       the claims locally still works.

  What signing as an account lets the VM do: authenticate as it, through
  MWT and the grant's approval, to every host the grant lists, Google's
  APIs included where the grant lists them. Naming the account is that
  trust decision; the JWT itself never enters the VM.

  Pure: requests and answers go in; what to send, what to keep and what the
  VM gets come out.
  """

  alias MWTClient.Sandbox.{Grant, Made, Policy}

  @sign_host "iamcredentials.googleapis.com"
  @token_host "oauth2.googleapis.com"
  # What an ID token's placeholder keeps of its claims: who issued it, for
  # whom and when, and the two a client reads of the person.
  @id_claims ~w(iss aud iat exp email hd)
  @sign_path ~r{\A/v1/projects/[^/?#]+/serviceAccounts/([^/?#:]+):signJwt\z}
  # Google keeps a self-signed JWT at most this long, and adds an hour
  # when the claims set no `exp`.
  @longest_seconds 12 * 3_600
  @default_seconds 3_600

  @typedoc """
  A request MWT answers: what was asked, checked (`check/3`); a JWT to sign
  with the grant it will belong to once `signer/2` found it.
  """
  @type ask ::
          %{
            required(:kind) => :sign_jwt,
            required(:account) => String.t(),
            required(:payload) => String.t(),
            required(:aud_host) => String.t(),
            optional(:grant_id) => String.t()
          }
          | %{kind: :refresh}

  @doc "The host that signs JWTs for service accounts."
  @spec sign_host() :: String.t()
  def sign_host, do: @sign_host

  @doc "The host of Google's token endpoint, where a login is refreshed."
  @spec token_host() :: String.t()
  def token_host, do: @token_host

  @doc """
  Whether `request` is one to Google's token endpoint, the only place a
  login's placeholder belongs.
  """
  @spec token_request?(map()) :: boolean()
  def token_request?(request),
    do: String.downcase(request.host || "") == @token_host and request.path == "/token"

  @doc """
  What credential endpoint MWT answers for `grant` in `request`, or nil:
  `{:sign_jwt, account}` for a request to sign as `account`, which may
  still fail `check/3`, when the grant signs as some account.

      iex> grant = %MWTClient.Sandbox.Grant{id: "g", name: "G", kind: :token, signs_as: ["sa@p.iam.gserviceaccount.com"]}
      iex> request = %{method: "POST", host: "iamcredentials.googleapis.com", path: "/v1/projects/-/serviceAccounts/sa%40p.iam.gserviceaccount.com:signJwt"}
      iex> MWTClient.Sandbox.CredentialEndpoint.recognize(grant, request)
      {:sign_jwt, "sa@p.iam.gserviceaccount.com"}
      iex> MWTClient.Sandbox.CredentialEndpoint.recognize(%{grant | signs_as: []}, request)
      nil
  """
  @spec recognize(Grant.t(), map()) :: {:sign_jwt, String.t()} | :refresh | nil
  def recognize(%Grant{kind: :token} = grant, %{method: "POST"} = request) do
    cond do
      token_request?(request) and Grant.login_placeholder(grant) != nil -> :refresh
      grant.signs_as != [] -> sign_jwt(request)
      true -> nil
    end
  end

  def recognize(_grant, _request), do: nil

  defp sign_jwt(request) do
    with @sign_host <- String.downcase(request.host),
         [_path, account] <- Regex.run(@sign_path, request.path) do
      {:sign_jwt, account |> URI.decode() |> String.downcase()}
    else
      _other -> nil
    end
  end

  @doc """
  Whether `grant` may have MWT answer the request, before anyone is asked:
  `{:ok, ask}`, or `{:error, code, message}` for the agent, saying what to
  change.
  """
  @spec check(Grant.t(), map(), {:sign_jwt, String.t()} | :refresh) ::
          {:ok, ask()} | {:error, String.t(), String.t()}
  def check(%Grant{} = grant, request, :refresh) do
    with {:ok, body} <- whole_body(request) do
      form = URI.decode_query(body)

      cond do
        form["grant_type"] != "refresh_token" ->
          {:error, "mwt_bad_request",
           "MWT answers only a refresh (grant_type=refresh_token) of #{grant.name}'s login."}

        # Its credential's login, or one it had before a merge.
        form["refresh_token"] not in [Grant.login_placeholder(grant) | grant.login_aliases || []] ->
          {:error, "mwt_bad_request",
           "The refresh is for another login than #{grant.name}'s: use its login file, #{Grant.login_file(grant)}."}

        true ->
          {:ok, %{kind: :refresh}}
      end
    end
  end

  def check(%Grant{} = grant, request, {:sign_jwt, account}) do
    with :ok <- signs_as(grant, account),
         {:ok, body} <- whole_body(request),
         {:ok, payload} <- payload(body),
         {:ok, host} <- audience(grant, payload) do
      {:ok, %{kind: :sign_jwt, account: account, payload: payload, aud_host: host}}
    end
  end

  @doc """
  The grant a JWT signed for `ask` belongs to: the first of `grants` (those
  over its credential that are on, the one that let the request through
  first) that signs as its account and lists its audience's host itself,
  so that MWT holds what it made (`MWTClient.Sandbox.Made.covered?/3`) for
  as long as that grant is on and unchanged. `{:ok, ask}` with its
  `grant_id`, or `{:error, code, message}` when no one grant does both,
  though between them they do.

      iex> pm = %MWTClient.Sandbox.Grant{id: "pm", name: "PM", kind: :token, hosts: ["*.googleapis.com"], signs_as: ["pm@p.iam.gserviceaccount.com"]}
      iex> box = %MWTClient.Sandbox.Grant{id: "box", name: "Box", kind: :token, hosts: ["box.example.com"], signs_as: ["box@p.iam.gserviceaccount.com"]}
      iex> ask = %{kind: :sign_jwt, account: "box@p.iam.gserviceaccount.com", payload: "{}", aud_host: "box.example.com"}
      iex> {:ok, %{grant_id: "box"}} = MWTClient.Sandbox.CredentialEndpoint.signer([pm, box], ask)
      iex> {:error, "mwt_not_a_signer", _} = MWTClient.Sandbox.CredentialEndpoint.signer([pm, box], %{ask | aud_host: "pm.example.com"})
  """
  @spec signer([Grant.t()], ask()) :: {:ok, ask()} | {:error, String.t(), String.t()}
  def signer(grants, %{kind: :sign_jwt, account: account, aud_host: host} = ask) do
    case Enum.find(grants, &(account in &1.signs_as and Policy.host_listed?(host, &1.hosts))) do
      %Grant{id: id} ->
        {:ok, Map.put(ask, :grant_id, id)}

      nil ->
        {:error, "mwt_not_a_signer",
         "No one grant over the credential both signs as #{account} and lists #{host}, so " <>
           "MWT would hold the JWT for none. Ask the user to add both to one grant."}
    end
  end

  defp signs_as(grant, account) do
    if account in grant.signs_as,
      do: :ok,
      else:
        {:error, "mwt_not_a_signer",
         "#{grant.name} may sign only as #{Enum.join(grant.signs_as, ", ")}, not #{account}. " <>
           "Ask the user to add the account to the grant."}
  end

  # The body, all of it: MWT reads at most the start of one before deciding,
  # and signs only what it read.
  defp whole_body(request) do
    body = request.body || ""

    case List.keyfind(request.headers, "content-length", 0) do
      {_name, length} ->
        case Integer.parse(length) do
          {n, ""} when n <= byte_size(body) -> {:ok, binary_part(body, 0, n)}
          _cut -> {:error, "mwt_bad_request", "MWT reads at most 64 KiB of a request it answers."}
        end

      nil ->
        {:error, "mwt_bad_request", "Send the request with a Content-Length."}
    end
  end

  defp payload(body) do
    case Jason.decode(body) do
      {:ok, %{"payload" => payload} = asked} when is_binary(payload) ->
        if Map.get(asked, "delegates", []) in [[], nil],
          do: {:ok, payload},
          else:
            {:error, "mwt_bad_request",
             "MWT signs only as the account named in the path: leave out delegates."}

      _other ->
        {:error, "mwt_bad_request", ~s(The request to sign is JSON with a "payload": the claims.)}
    end
  end

  # The signed JWT goes only to its audience's host, so that host must be
  # one the grant lists.
  defp audience(grant, payload) do
    with {:ok, %{"aud" => aud}} when is_binary(aud) <- Jason.decode(payload),
         %URI{scheme: "https", host: host} when is_binary(host) and host != "" <- URI.parse(aud) do
      host = String.downcase(host)

      if Policy.host_listed?(host, grant.hosts),
        do: {:ok, host},
        else:
          {:error, "mwt_placeholder_blocked",
           "The JWT's aud is on #{host}, which #{grant.name} doesn't list: the signed JWT would " <>
             "have nowhere to go. Ask the user to add the host to the grant."}
    else
      _other ->
        {:error, "mwt_bad_request",
         "The claims need an aud, the https URL of the service the JWT is for."}
    end
  end

  @doc """
  The request MWT sends itself, as a request action's call
  (`MWTClient.Sandbox.SavedRequest.send/4`), the grant's value where
  `{token}` is.
  """
  @spec call(ask()) :: map()
  def call(%{kind: :sign_jwt, account: account, payload: payload}) do
    %{
      method: "POST",
      url:
        "https://#{@sign_host}/v1/projects/-/serviceAccounts/" <>
          URI.encode(account, &URI.char_unreserved?/1) <> ":signJwt",
      host: @sign_host,
      headers: [{"authorization", "Bearer " <> MWTClient.Sandbox.SavedRequest.token_mark()}],
      body: Jason.encode!(%{payload: payload})
    }
  end

  @doc """
  The answer to a refresh of `grant`'s login: its placeholder as the access
  token, for `expires_in` seconds, and, when the grant's mint gave
  `id_token`, a placeholder for it, made from the grant, to keep: `{made
  | nil, json}`.
  """
  @spec refreshed(Grant.t(), String.t() | nil, pos_integer(), DateTime.t()) ::
          {Made.t() | nil, String.t()}
  def refreshed(%Grant{} = grant, id_token, expires_in, now) do
    made =
      with jwt when is_binary(jwt) <- id_token,
           {:ok, claims} <- Made.claims(jwt) do
        %Made{
          placeholder: Made.jwt_placeholder(jwt, @id_claims),
          grant_id: grant.id,
          name: "#{grant.name}'s ID token",
          source: :id_token,
          hosts: grant.hosts,
          carriers: Grant.id_token_carriers(grant),
          until: until(claims, now)
        }
      else
        _none -> nil
      end

    answer =
      %{access_token: grant.placeholder, expires_in: expires_in, token_type: "Bearer"}
      |> then(&if(made, do: Map.put(&1, :id_token, made.placeholder), else: &1))

    {made, Jason.encode!(answer)}
  end

  @doc """
  What came of the call (`result`, as `SavedRequest.send/4` reports it, or
  `{:error, message}` when the call never ran): `{:ok, made, json}`, the
  value to keep and the VM's answer, or `{:error, status, json}`, an answer
  saying why not. Google's own refusal goes to the VM as it came: it holds
  no credential.
  """
  @spec answered(Grant.t(), ask(), map() | {:error, String.t()}, DateTime.t()) ::
          {:ok, Made.t(), String.t()} | {:error, pos_integer(), String.t()}
  def answered(%Grant{} = grant, %{kind: :sign_jwt} = ask, %{status: 200, output: output}, now) do
    with {:ok, %{"signedJwt" => jwt} = answer} when is_binary(jwt) <- Jason.decode(output),
         {:ok, claims_map} <- Made.claims(jwt) do
      placeholder = Made.jwt_placeholder(jwt)

      made = %Made{
        placeholder: placeholder,
        grant_id: grant.id,
        name: "#{grant.name}'s JWT signed as #{ask.account} for #{ask.aud_host}",
        value: jwt,
        account: ask.account,
        hosts: [ask.aud_host],
        carriers: ["authorization"],
        until: until(claims_map, now)
      }

      {:ok, made, Jason.encode!(%{keyId: answer["keyId"], signedJwt: placeholder})}
    else
      _unreadable ->
        mwt_error(502, "mwt_unreadable_response", "Google's answer to signJwt couldn't be read.")
    end
  end

  # Only a refusal goes on as it came: any other answer could hold what
  # was signed.
  def answered(_grant, _ask, %{status: status, output: output}, _now)
      when is_integer(status) and status not in 200..299,
      do: {:error, status, output}

  def answered(_grant, _ask, %{status: status}, _now) when is_integer(status),
    do: mwt_error(502, "mwt_unreadable_response", "Google's answer to signJwt couldn't be read.")

  def answered(_grant, _ask, %{timed_out: true}, _now),
    do: mwt_error(504, "mwt_timeout", "Google didn't answer signJwt in time.")

  def answered(_grant, _ask, %{error: message}, _now) when is_binary(message),
    do: mwt_error(502, "mwt_upstream_failed", "Could not reach Google to sign: #{message}")

  def answered(_grant, _ask, {:error, message}, _now),
    do: mwt_error(502, "mwt_upstream_failed", "Could not sign: #{message}")

  # Until its own expiry, as Google keeps it: an hour when the claims set
  # none, never past 12 hours from now.
  defp until(claims, now) do
    longest = DateTime.add(now, @longest_seconds, :second)

    at =
      case claims["exp"] do
        exp when is_integer(exp) -> DateTime.from_unix!(exp)
        _none -> DateTime.add(now, @default_seconds, :second)
      end

    Enum.min([at, longest], DateTime)
  end

  defp mwt_error(status, code, message),
    do: {:error, status, Jason.encode!(%{code: code, error: message, by: "MWT agent sandbox"})}
end
