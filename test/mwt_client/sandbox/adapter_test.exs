defmodule MWTClient.Sandbox.AdapterTest do
  @moduledoc """
  What MWT knows of each family of credentials, behind fixed extension
  points (`MWTClient.Sandbox.Adapter`): which one a credential has, how a
  mint's output is read, the hosts its own endpoints need.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Adapter
  alias MWTClient.Sandbox.Adapter.{Bearer, GitHub, Google}
  alias MWTClient.Sandbox.Grant

  doctest MWTClient.Sandbox.Adapter

  @now ~U[2026-11-24 12:00:00Z]

  test "a mint's output: the bare value, MWT's JSON, and gcloud's, by the Google adapter" do
    assert {:ok, %{value: "v", id_token: nil}, 600_000} = Bearer.read_mint("v", @now)

    assert {:ok, %{value: "v", id_token: "i"}, 1_740_000} =
             Bearer.read_mint(~s({"value": "v", "id_token": "i", "expires_in": 1800}), @now)

    gcloud =
      Jason.encode!(%{
        "credential" => %{
          "access_token" => "ya29.x",
          "id_token" => "eyJ.id",
          "token_expiry" => "2026-11-24T13:00:00Z"
        }
      })

    assert {:ok, %{value: "ya29.x", id_token: "eyJ.id"}, 3_540_000} =
             Google.read_mint(gcloud, @now)

    assert {:error, _} = Bearer.read_mint(~s({"nothing": 1}), @now)
  end

  test "the Google adapter implies its endpoints: the token endpoint for a login, IAM Credentials for signing" do
    login = %Grant{
      id: "g",
      name: "G",
      kind: :token,
      hosts: ["svc.example.com"],
      presents: %{login: %{refresh: "1//x", header: ""}}
    }

    assert Adapter.hosts(login) == ["svc.example.com", "oauth2.googleapis.com"]

    signs = %Grant{login | presents: %{}, signs_as: ["sa@p.iam.gserviceaccount.com"]}
    assert Adapter.hosts(signs) == ["svc.example.com", "iamcredentials.googleapis.com"]

    plain = %Grant{id: "h", name: "Hex", kind: :token, hosts: ["hex.pm"]}
    assert Adapter.hosts(plain) == ["hex.pm"]
  end

  describe "a GitHub App's installation token" do
    setup do
      %{username: username} = MWTClient.VaultHelpers.unlocked_identity("github-app")
      %{username: username}
    end

    test "is made from the key the mint prints, signed as the App, and goes where its grants say",
         %{username: username} do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      key_file = Path.join(System.tmp_dir!(), "mwt-app-#{System.unique_integer([:positive])}.pem")
      File.write!(key_file, pem)
      on_exit(fn -> File.rm(key_file) end)
      public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
      test = self()

      Req.Test.stub(GitHub, fn conn ->
        ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        [header, payload, signature] = String.split(jwt, ".")

        verified? =
          :public_key.verify(
            header <> "." <> payload,
            :sha256,
            Base.url_decode64!(signature, padding: false),
            public
          )

        send(
          test,
          {:traded, conn.request_path, verified?,
           Jason.decode!(Base.url_decode64!(payload, padding: false))}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          201,
          ~s({"token": "ghs_installation_0123456789", "expires_at": "2099-01-01T00:00:00Z"})
        )
      end)

      {:ok, grant} =
        MWTClient.Sandbox.create_grant(username, %{
          "kind" => "token",
          "preset" => "github-app",
          "name" => "GitHub App",
          "purpose" => "Read UME's repositories",
          "hosts" => "api.github.com",
          "env" => "GH_TOKEN",
          "prefix" => "ghs_",
          "source" => "minted",
          "mint" => "cat '#{key_file}'",
          "app_id" => "Iv23liTEST",
          "installation_id" => "4242"
        })

      assert grant.app == %{app_id: "Iv23liTEST", installation_id: "4242"}
      server = MWTClient.Vault.Store.whereis(MWTClient.Sandbox.Server, username)
      :ok = Req.Test.allow(GitHub, self(), server)
      {:ok, _} = MWTClient.Sandbox.turn_on(username, grant.id, 60, :all)

      request = %{
        host: "api.github.com",
        method: "GET",
        path: "/repos/o/r",
        headers: [{"authorization", "token " <> grant.placeholder}],
        body: ""
      }

      assert {:forward, replace, _} =
               MWTClient.Sandbox.Server.call(username, {:authorize, request})

      assert inspect(replace) =~ "ghs_installation_0123456789"
      refute inspect(replace) =~ "PRIVATE KEY"

      assert_received {:traded, "/app/installations/4242/access_tokens", true,
                       %{"iss" => "Iv23liTEST"}}
    end
  end

  test "the Google adapter signs a JWT as an account, for a URL, with the access token" do
    Req.Test.stub(Google, fn conn ->
      assert conn.request_path ==
               "/v1/projects/-/serviceAccounts/agent%40p.iam.gserviceaccount.com:signJwt"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ya29.real"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      claims = body |> Jason.decode!() |> Map.fetch!("payload") |> Jason.decode!()
      assert claims["aud"] == "https://pm.example.run.app/policies"
      assert claims["sub"] == "agent@p.iam.gserviceaccount.com"
      assert claims["exp"] - claims["iat"] == 3600
      Req.Test.json(conn, %{"keyId" => "k", "signedJwt" => "eyJ.signed"})
    end)

    assert {:ok, "eyJ.signed"} =
             Google.sign_jwt(
               "ya29.real",
               "agent@p.iam.gserviceaccount.com",
               "https://pm.example.run.app/policies",
               @now
             )

    Req.Test.stub(Google, &Plug.Conn.send_resp(&1, 403, "{}"))

    assert {:error, "Google answered 403 to signing as a@p.iam.gserviceaccount.com"} =
             Google.sign_jwt(
               "ya29.real",
               "a@p.iam.gserviceaccount.com",
               "https://x.example/",
               @now
             )
  end

  test "GitHub's adapter reads the repository a request names, and not a GraphQL query's" do
    assert %{"github.repository" => "o/r"} =
             GitHub.attributes(%{host: "api.github.com", path: "/repos/o/r/pulls/1"})

    assert %{"github.repository" => "o/r"} =
             GitHub.attributes(%{host: "github.com", path: "/o/r.git/info/refs"})

    assert %{"github.repository" => :unknown} =
             GitHub.attributes(%{host: "api.github.com", path: "/graphql"})

    assert %{} == GitHub.attributes(%{host: "example.com", path: "/repos/o/r"})
  end
end
