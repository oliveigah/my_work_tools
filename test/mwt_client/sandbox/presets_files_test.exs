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

  test "every shipped preset loads and builds a valid grant" do
    assert {presets, []} = Presets.load(Presets.own_dir())
    assert Enum.map(presets, & &1.id) == ~w(github-app github google-login google hex)

    for preset <- presets do
      # Each field filled as its shape takes: an installation's id is digits.
      fill =
        Map.new(
          preset.fill,
          &{&1.name, if(&1.name == "installation_id", do: "12345", else: "x1")}
        )

      attrs =
        preset.fields
        |> Map.merge(%{
          "kind" => Atom.to_string(preset.kind),
          "name" => preset.name,
          "value" => "real",
          "fill" => fill
        })

      assert {:ok, %Grant{} = grant, _value} = Grants.build_grant(attrs, [], preset: preset),
             "#{preset.id} doesn't build"

      assert grant.icon == preset.icon
      assert grant.preset == preset.id
    end
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

    assert {[%{id: "acme"}], errors} = Presets.load(dir)
    assert [{bad, "it isn't JSON" <> _}, {kind, "kind is one of" <> _}] = errors
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

      assert Enum.any?(Presets.presets(username), &(&1.id == "acme"))

      assert {:error, %{fill: "Fill in Organisation."}} =
               Sandbox.create_grant(username, %{
                 "kind" => "token",
                 "preset" => "acme",
                 "name" => "Acme",
                 "purpose" => "x",
                 "hosts" => "{org}.acme.test",
                 "value" => "v"
               })

      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "preset" => "acme",
          "name" => "Acme",
          "purpose" => "Acme for {org}",
          "hosts" => "{org}.acme.test",
          "value" => "real",
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
