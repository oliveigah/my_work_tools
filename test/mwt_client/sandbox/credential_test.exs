defmodule MWTClient.Sandbox.CredentialTest do
  @moduledoc """
  Credentials (`MWTClient.Sandbox.Credential`): where a real value comes
  from, shared by every grant over it. Each grant says where the value may
  go and how a use is approved; the most permissive that is on and covers
  the use counts (`MWTClient.Sandbox.Policy`).
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Credential
  alias MWTClient.Sandbox.Server

  doctest MWTClient.Sandbox.Credential
  doctest MWTClient.Sandbox.Grant

  @google "gcloud config config-helper --force-auth-refresh --format=json"

  defp google(id, hosts, extra \\ %{}) do
    struct(
      %Grant{
        id: id,
        name: id,
        kind: :token,
        preset: "google-login",
        source: {:minted, @google},
        placeholder: "ya29.mwt_" <> id,
        hosts: hosts
      },
      extra
    )
  end

  describe "migrating grants saved before credentials" do
    test "merges the grants minted the same way into one credential, keeping their placeholders" do
      grants = [
        google("bigquery", ["bigquery.googleapis.com"], %{
          file_env: ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"]
        }),
        google("storage", ["storage.googleapis.com"]),
        google("pm", ["pm.example.run.app"], %{
          presents: %{login: %{refresh: "1//mwt_pm", header: "x-user-assertion"}}
        }),
        # Kept 4 minutes: apart, or every other would be minted as often.
        google("research", ["research.example.app"], %{keep_minutes: 4}),
        %Grant{
          id: "github",
          name: "GitHub",
          kind: :token,
          placeholder: "ghp_mwt1",
          hosts: ["github.com"]
        }
      ]

      {grants, credentials} = Credential.migrate(grants, [])

      assert [google, research, github] = credentials
      assert google.id == "bigquery" and google.name == "Google login, with ID token"
      assert google.aliases == ["ya29.mwt_storage", "ya29.mwt_pm"]
      assert google.login_aliases == []
      assert google.file_env == ["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"]
      assert google.keep_minutes == nil
      assert research.id == "research" and research.keep_minutes == 4
      assert github.id == "github" and github.aliases == []

      by_id = Map.new(grants, &{&1.id, &1})
      assert Enum.all?(["bigquery", "storage", "pm"], &(by_id[&1].credential == "bigquery"))
      # Each grant over it holds its placeholder now, the one minted once.
      assert Enum.all?(
               ["bigquery", "storage", "pm"],
               &(by_id[&1].placeholder == "ya29.mwt_bigquery")
             )

      assert by_id["github"].credential == "github"
    end

    test "sends the ID token in each grant's carriers when their logins named different headers" do
      grants = [
        google("bigquery", ["bigquery.googleapis.com"], %{
          presents: %{login: %{refresh: "1//mwt_bq", header: "authorization"}}
        }),
        google("pm", ["pm.example.run.app"], %{
          presents: %{login: %{refresh: "1//mwt_pm", header: "x-user-assertion"}}
        })
      ]

      {grants, [credential]} = Credential.migrate(grants, [])
      assert credential.presents.login.header == ""
      assert credential.login_aliases == ["1//mwt_pm"]
      pm = Enum.find(grants, &(&1.id == "pm"))
      assert "x-user-assertion" in Grant.carriers(pm)
    end

    test "leaves stored values apart: two can't be told the same without reading them" do
      grants = [
        %Grant{id: "a", name: "A", kind: :token, placeholder: "p_a", hosts: ["a.example"]},
        %Grant{id: "b", name: "B", kind: :token, placeholder: "p_b", hosts: ["a.example"]}
      ]

      {_grants, credentials} = Credential.migrate(grants, [])
      assert Enum.map(credentials, & &1.id) == ["a", "b"]
    end

    test "changes nothing the second time" do
      grants = [
        google("bigquery", ["bigquery.googleapis.com"]),
        google("storage", ["storage.googleapis.com"])
      ]

      {grants, credentials} = Credential.migrate(grants, [])
      assert Credential.migrate(grants, credentials) == {grants, credentials}
    end
  end

  describe "a request carrying a credential's placeholder" do
    setup do
      {grants, _} =
        Credential.migrate(
          [
            google("bigquery", ["bigquery.googleapis.com"], %{
              state: :on,
              allowances: [allowance(:all, nil)]
            }),
            google("storage", ["storage.googleapis.com"], %{state: :on})
          ],
          []
        )

      %{grants: grants}
    end

    defp request(host, placeholder \\ "ya29.mwt_bigquery") do
      %{
        host: host,
        method: "GET",
        path: "/",
        headers: [{"authorization", "Bearer " <> placeholder}],
        body: ""
      }
    end

    test "is decided by the grants over it that list its host", %{grants: grants} do
      assert {:allow, %{id: "bigquery"}, _, _} =
               Policy.decide(
                 snapshot([internet_on() | grants]),
                 {:request, request("bigquery.googleapis.com")},
                 @now
               )

      assert {:ask, %{id: "storage"}, _} =
               Policy.decide(
                 snapshot([internet_on() | grants]),
                 {:request, request("storage.googleapis.com")},
                 @now
               )

      assert {:refuse, {:wrong_host, _}} =
               Policy.decide(
                 snapshot([internet_on() | grants]),
                 {:request, request("example.com")},
                 @now
               )
    end

    test "is given by another grant listing its host where one over it is off",
         %{grants: grants} do
      wide = %{Enum.find(grants, &(&1.id == "bigquery")) | hosts: ["*.googleapis.com"]}
      storage = Grant.put_down(Enum.find(grants, &(&1.id == "storage")))
      decide = &Policy.decide(snapshot([internet_on() | &1]), {:request, &2}, @now)

      # Off, it has no say: the wide one gives it.
      assert {:allow, %{id: "bigquery"}, _, _} =
               decide.([wide, storage], request("storage.googleapis.com"))

      # With none on, refused, naming one to turn on.
      assert {:refuse, {:grant_off, %{id: "bigquery"}}} =
               decide.([Grant.put_down(wide), storage], request("storage.googleapis.com"))
    end

    test "answers to a placeholder it had before a merge", %{grants: grants} do
      assert {:ask, %{id: "storage"}, _} =
               Policy.decide(
                 snapshot([internet_on() | grants]),
                 {:request, request("storage.googleapis.com", "ya29.mwt_storage")},
                 @now
               )
    end
  end

  describe "through the sandbox" do
    setup do
      %{username: username} = MWTClient.VaultHelpers.unlocked_identity("credentials")
      %{username: username}
    end

    test "a grant over a credential you have shares its placeholder and its value",
         %{username: username} do
      {:ok, first} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Datalake, dev",
          "purpose" => "The datalake in dev",
          "hosts" => "dev.example.com",
          "env" => "DATALAKE_TOKEN",
          "value" => "real-datalake-0123456789"
        })

      {:ok, second} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "Datalake, prod",
          "purpose" => "The datalake in prod",
          "hosts" => "prod.example.com",
          "credential" => first.credential
        })

      assert second.credential == first.id and second.placeholder == first.placeholder
      assert [%Credential{id: id}] = Sandbox.snapshot(username).credentials
      assert id == first.id

      {:ok, _} = Sandbox.turn_on(username, second.id, 60, :all)

      request = %{
        host: "prod.example.com",
        method: "GET",
        path: "/rows",
        headers: [{"authorization", "Bearer " <> second.placeholder}],
        body: ""
      }

      assert {:forward, replace, _} = Server.call(username, {:authorize, request})
      assert inspect(replace) =~ "real-datalake-0123456789"

      # The first is still off: dev isn't reached through the second.
      assert {:deny, 403, _} =
               Server.call(username, {:authorize, %{request | host: "dev.example.com"}})

      # A resource of its own, the credential stays when its last grant
      # goes, and goes, value and all, only when removed itself.
      :ok = Sandbox.delete_grant(username, first.id)
      :ok = Sandbox.delete_grant(username, second.id)
      assert [%Credential{id: ^id}] = Sandbox.snapshot(username).credentials
      :ok = Sandbox.delete_resource(username, {:credential, id})
      assert [] = Sandbox.snapshot(username).credentials
    end
  end
end
