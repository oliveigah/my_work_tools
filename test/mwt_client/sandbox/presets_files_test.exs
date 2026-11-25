defmodule MWTClient.Sandbox.PresetsFilesTest do
  @moduledoc """
  Presets as files (`MWTClient.Sandbox.Presets`): MWT's own load and build
  valid grants; yours load from the identity's folder; a bad file is
  refused with its path and why; what a preset gives is copied onto the
  grant, so removing the file changes nothing.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Grant, Presets}
  alias MWTClient.Sandbox.Server.Grants

  doctest Presets

  test "every shipped preset loads; credential presets make credentials, grant presets grants" do
    assert {presets, []} = Presets.load(Presets.own_dir())

    assert Enum.map(presets, &{&1.id, &1.makes}) == [
             {"github-app", :credential},
             {"github-everything", :grant},
             {"github-repository", :grant},
             {"github", :credential},
             {"google-apis", :grant},
             {"google-login", :credential},
             {"google", :credential},
             {"hex-packages", :grant},
             {"hex", :credential}
           ]

    for preset <- presets do
      # Each field filled as its shape takes: an installation's id is digits.
      fill =
        Map.new(preset.fill, fn
          %{name: "installation_id"} -> {"installation_id", "12345"}
          %{name: "repository"} -> {"repository", "o/r"}
          %{name: name} -> {name, "x1"}
        end)

      # A credential is built as a token grant with no scope of its own
      # (`Server.Resources`); a grant over one, with no value of its own.
      attrs =
        preset.fields
        |> Map.merge(%{"kind" => "token", "name" => preset.name, "fill" => fill})
        |> Map.merge(
          if(preset.makes == :credential,
            do: %{"hosts" => "credential.invalid", "value" => "real"},
            else: %{}
          )
        )

      assert {:ok, %Grant{} = grant, _value} =
               Grants.build_grant(attrs, [], preset: preset, valueless: preset.makes == :grant),
             "#{preset.id} doesn't build"

      assert grant.icon == preset.icon

      if preset.makes == :credential do
        assert grant.adapter == String.to_existing_atom(preset.fields["adapter"])
      else
        assert preset.over != [] and grant.hosts != []
      end
    end

    assert %{app: %{app_id: "Iv1", installation_id: "42"}, adapter: :github} =
             Presets.find("github-app")
             |> elem(1)
             |> then(
               &Grants.build_grant(
                 Map.merge(&1.fields, %{
                   "kind" => "token",
                   "name" => "App",
                   "hosts" => "credential.invalid",
                   "fill" => %{
                     "app_id" => "Iv1",
                     "installation_id" => "42",
                     "key_command" => "cat key.pem"
                   }
                 }),
                 [],
                 preset: &1
               )
             )
             |> elem(1)
  end

  @tag :tmp_dir
  test "a bad file is refused with its path and the reason", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "good.json"),
      ~s({"id": "acme", "kind": "token", "name": "Acme", "grant": {}})
    )

    File.write!(Path.join(dir, "bad.json"), "{not json")

    File.write!(
      Path.join(dir, "kind.json"),
      ~s({"id": "x", "kind": "rocket", "name": "X", "grant": {}})
    )

    assert {[%{id: "acme", makes: :credential}, %{id: "acme-grant", makes: :grant}], errors} =
             Presets.load(dir)

    assert [{bad, "it isn't JSON" <> _}, {kind, "makes is one of" <> _}] = errors
    assert String.ends_with?(bad, "bad.json") and String.ends_with?(kind, "kind.json")
  end

  describe "through the sandbox" do
    setup do
      MWTClient.VaultHelpers.unlocked_identity("presets")
    end

    test "a preset of yours fills, carries actions, and removing it changes nothing",
         %{username: username} do
      dir = Presets.dir(username)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "acme.json"),
        Jason.encode!(%{
          "id" => "acme",
          "kind" => "token",
          "name" => "Acme",
          "icon" => "hero-bolt",
          "fill" => [%{"name" => "org", "label" => "Organisation", "example" => "mine"}],
          "grant" => %{
            "purpose" => "Acme for {org}",
            "hosts" => "{org}.acme.test",
            "source" => "stored"
          },
          "request_headers" => "X-Key: {token}",
          "tools" => ["acme"],
          "actions" => [
            %{
              "name" => "whoami",
              "purpose" => "Who the key is",
              "method" => "GET",
              "url" => "https://{org}.acme.test/me"
            }
          ]
        })
      )

      # Written before presets said what they make: a credential preset and
      # a grant preset over it.
      assert [%{makes: :credential}] = Enum.filter(Presets.presets(username), &(&1.id == "acme"))
      assert [%{id: "acme-grant", over: ["acme"]}] = Presets.over(%{preset: "acme"}, username)

      {:ok, credential} =
        Sandbox.create_resource(username, :credential, %{
          "preset" => "acme",
          "name" => "Acme",
          "purpose" => "Acme for {org}",
          "source" => "stored",
          "value" => "real",
          "fill" => %{"org" => "mine"}
        })

      assert %{purpose: "Acme for mine", icon: "hero-bolt", request_headers: "X-Key: {token}"} =
               credential

      assert credential.cli_tools == ["acme"]

      assert {:error, %{fill: "Fill in Organisation."}} =
               Sandbox.create_grant(username, %{
                 "kind" => "token",
                 "preset" => "acme-grant",
                 "credential" => credential.id,
                 "name" => "Acme",
                 "purpose" => "x",
                 "hosts" => "{org}.acme.test"
               })

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "preset" => "acme-grant",
          "credential" => credential.id,
          "name" => "Acme API",
          "purpose" => "Acme for {org}",
          "hosts" => "{org}.acme.test",
          "fill" => %{"org" => "mine"}
        })

      assert %{hosts: ["mine.acme.test"], purpose: "Acme for mine", icon: "hero-bolt"} = grant
      assert %{request_headers: "X-Key: {token}", cli_tools: ["acme"]} = grant

      assert [
               %{
                 kind: :request,
                 url: "https://mine.acme.test/me",
                 headers: [{"X-Key", "{token}"}]
               }
             ] =
               Enum.filter(
                 Sandbox.snapshot(username).grants,
                 &(&1.kind == :request and &1.credential == grant.credential)
               )

      File.rm_rf!(dir)

      assert %{icon: "hero-bolt", hosts: ["mine.acme.test"]} =
               Enum.find(Sandbox.snapshot(username).grants, &(&1.id == grant.id))
    end
  end
end
