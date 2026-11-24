defmodule MWTClient.Sandbox.Adapter.GitHub do
  @moduledoc """
  GitHub's tokens: personal, fine-grained, a GitHub App's installation token
  (`MWTClient.Sandbox.Adapter`). What its requests name: the repository,
  from the REST API's `/repos/OWNER/NAME/…` and git's `/OWNER/NAME(.git)/…`.
  A GraphQL query names it in its variables or its text, which isn't read
  as a repository: unknown, which counts against the use.

  A GitHub App's installation token (`ghs_…`, an hour, no person's) is made
  here (`exchange/3`): the credential's mint prints the App's private key,
  on your machine, from where you keep it; MWT signs a JWT as the App with
  it (RS256, ten minutes) and trades it at
  `POST api.github.com/app/installations/ID/access_tokens` for an
  installation token, kept until a minute before it expires. The key is
  held only while it signs, and never logged.
  """

  @behaviour MWTClient.Sandbox.Adapter

  alias MWTClient.Sandbox.Adapter.Bearer

  @impl true
  def id, do: :github

  @impl true
  def name, do: "GitHub"

  @impl true
  def read_mint(output, now), do: Bearer.read_mint(output, now)

  @doc """
  What a credential with a GitHub App (`Credential.app`) makes of the key
  its mint printed: an installation token, or why not.
  """
  @spec exchange(String.t(), map(), DateTime.t()) ::
          MWTClient.Sandbox.Adapter.minted() | {:error, String.t()}
  def exchange(pem, %{app: %{app_id: app_id, installation_id: installation}}, now) do
    with {:ok, key} <- private_key(pem),
         jwt = app_jwt(key, app_id, now),
         {:ok, %{"token" => token} = answer} <- trade(jwt, installation) do
      seconds =
        with expiry when is_binary(expiry) <- answer["expires_at"],
             {:ok, at, _offset} <- DateTime.from_iso8601(expiry),
             do: DateTime.diff(at, now)

      {:ok, %{value: token, id_token: nil}, Bearer.fresh(seconds)}
    else
      {:ok, _other} -> {:error, "GitHub's answer held no installation token"}
      {:error, message} -> {:error, message}
    end
  end

  defp private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, "the command printed no private key (a PEM block)"}
    end
  rescue
    _ -> {:error, "the command printed a key MWT can't read"}
  end

  # A JWT as the App: issued a minute ago, for clock drift, good for nine
  # minutes more, as GitHub allows at most ten.
  defp app_jwt(key, app_id, now) do
    iat = DateTime.to_unix(now) - 60
    header = encode(%{"alg" => "RS256", "typ" => "JWT"})
    payload = encode(%{"iat" => iat, "exp" => iat + 540, "iss" => app_id})
    signing = header <> "." <> payload
    signing <> "." <> Base.url_encode64(:public_key.sign(signing, :sha256, key), padding: false)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp trade(jwt, installation) do
    options =
      [
        url: "https://api.github.com/app/installations/#{installation}/access_tokens",
        headers: [
          {"authorization", "Bearer " <> jwt},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"}
        ],
        retry: false,
        receive_timeout: 20_000
      ] ++ test_options()

    case Req.post(options) do
      {:ok, %Req.Response{status: status, body: %{} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitHub answered #{status} to the App's token request"}

      {:error, exception} ->
        {:error, "GitHub couldn't be reached: #{Exception.message(exception)}"}
    end
  end

  defp test_options do
    case Application.get_env(:mwt_client, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end

  @impl true
  def implied_hosts(_credential), do: []

  @impl true
  def env(_credential), do: []

  @impl true
  def attributes(request) do
    host = request |> Map.get(:host, "") |> to_string() |> String.downcase()
    path = request |> Map.get(:path, "") |> to_string() |> String.split("?", parts: 2) |> hd()

    repository =
      cond do
        host == "api.github.com" and String.ends_with?(path, "/graphql") ->
          :unknown

        host == "api.github.com" ->
          case String.split(path, "/", trim: true) do
            ["repos", owner, name | _] -> "#{owner}/#{name}"
            _ -> nil
          end

        host in ["github.com", "uploads.github.com"] ->
          case String.split(path, "/", trim: true) do
            [owner, name | _] -> "#{owner}/#{String.trim_trailing(name, ".git")}"
            _ -> nil
          end

        true ->
          nil
      end

    if repository, do: %{"github.repository" => repository}, else: %{}
  end
end
