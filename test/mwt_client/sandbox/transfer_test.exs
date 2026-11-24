defmodule MWTClient.Sandbox.TransferTest do
  @moduledoc """
  The agent sandbox's section of an export (`MWTClient.Sandbox.Transfer`):
  credentials, networks and the hosts each blocks, grants and their
  actions, the built-in grants' settings, your presets; stored values only
  when you choose. Importing merges without losing anything, twice
  changing nothing, or replaces.
  """
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Grant, HostLimits}
  alias MWTClient.Transfer

  setup do
    identity = unlocked_identity("sandbox-export")
    path = Path.join(Accounts.dir(identity.username), "exports/sandbox.mwtexport")
    File.mkdir_p!(Path.dirname(path))
    Map.put(identity, :path, path)
  end

  defp setup_grants(username) do
    {:ok, datalake} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Datalake",
        "purpose" => "The datalake in prod",
        "hosts" => "internal.example.com",
        "env" => "DATALAKE_TOKEN",
        "value" => "real-datalake-0123456789",
        "start" => "on"
      })

    {:ok, google} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "BigQuery",
        "purpose" => "BigQuery as me",
        "hosts" => "bigquery.googleapis.com",
        "file_env" => "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "source" => "minted",
        "mint" => "gcloud auth print-access-token"
      })

    {:ok, storage} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Cloud Storage",
        "purpose" => "Storage as me",
        "hosts" => "storage.googleapis.com",
        "credential" => google.credential,
        "start" => "off"
      })

    {:ok, _} = Sandbox.limits_set(username, "internet", {:put, "paste.example", true})

    {:ok, _} =
      Sandbox.update_settings(username, %{
        "confine_reads" => "~/.local/share/mise\n/opt/tools"
      })

    {datalake, google, storage}
  end

  defp section(plan), do: Enum.find(plan.sections, &(&1.label == "Agent sandbox grants"))

  defp own(username), do: Enum.reject(Sandbox.snapshot(username).grants, &Grant.built_in?/1)

  defp internet(username), do: Enum.find(Sandbox.snapshot(username).networks, & &1.internet)

  test "an export carries the grants and credentials, and stored values only when asked", %{
    username: username,
    password: password,
    path: path
  } do
    setup_grants(username)

    :ok = Transfer.export(username, path)
    {:ok, plan} = Transfer.read(username, path)
    # What will run here and what starts on shows before anything changes.
    assert section(plan).summary ==
             "3 grants, 2 credentials. Runs on this machine: mints for BigQuery. " <>
               "Starts on: Datalake. Arrives without a value: Datalake"

    :ok = Transfer.export(username, path, values: true)
    {:ok, plan} = Transfer.read(username, path)
    assert section(plan).summary =~ "3 grants, 2 credentials, 1 stored value. Runs on"
    refute section(plan).summary =~ "without a value"

    # Into another identity: the grants with their start settings, the
    # credentials, the value, the host the Internet blocks.
    other = also_unlock("sandbox-import", password)
    {:ok, plan} = Transfer.read(other, path, password: password)
    :ok = Transfer.import(other, plan, :merge)

    grants = own(other)

    assert Enum.map(grants, & &1.name) |> Enum.sort() ==
             ["BigQuery", "Cloud Storage", "Datalake"]

    assert Enum.find(grants, &(&1.name == "Datalake")).state == :on
    assert Enum.find(grants, &(&1.name == "Cloud Storage")).state == :off
    assert Enum.find(grants, &(&1.name == "BigQuery")).state == :off
    snapshot = Sandbox.snapshot(other)
    assert length(snapshot.credentials) == 2
    assert snapshot.values["datalake"]

    # The Internet's limits: the host it blocks, and no grant over it.
    assert HostLimits.blocked?(internet(other).limits, "paste.example")
    refute HostLimits.blocked?(internet(other).limits, "example.com")

    # The folders confined commands may read, as paths, your home as ~.
    assert snapshot.settings.confine_reads ==
             [Path.expand("~/.local/share/mise"), "/opt/tools"]

    # Twice changes nothing.
    :ok = Transfer.import(other, plan, :merge)
    assert length(own(other)) == 3
    assert length(Sandbox.snapshot(other).credentials) == 2
    assert length(internet(other).limits.rules) == 1
  end

  test "a grant whose id another definition holds comes in beside it, to review", %{
    username: username,
    password: password,
    path: path
  } do
    setup_grants(username)
    :ok = Transfer.export(username, path)

    other = also_unlock("sandbox-clash", password)

    {:ok, _} =
      Sandbox.create_grant(other, %{
        "kind" => "token",
        "name" => "Datalake",
        "purpose" => "Another datalake",
        "hosts" => "elsewhere.example.com",
        "env" => "DATALAKE_TOKEN",
        "value" => "theirs-0123456789"
      })

    {:ok, plan} = Transfer.read(other, path, password: password)
    :ok = Transfer.import(other, plan, :merge)

    datalakes = Enum.filter(own(other), &(&1.name == "Datalake"))
    assert length(datalakes) == 2
    imported = Enum.find(datalakes, &(&1.id != "datalake"))
    assert Grant.to_review?(imported) and imported.state == :off
    # Theirs is untouched, value and all.
    assert Sandbox.snapshot(other).values["datalake"]
  end

  test "an id that isn't one MWT would give is refused: ids name files in the VM" do
    grant = %{id: "../../etc/x", name: "X", kind: :token}

    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{grants: [grant], credentials: []})

    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [],
               credentials: [%{id: "a b", name: "A"}]
             })

    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [Map.merge(grant, %{id: "x", credential: "../y"})],
               credentials: []
             })

    assert {:ok, %{grants: [%{id: "github-app-ume"}]}} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [%{grant | id: "github-app-ume"}],
               credentials: []
             })

    # A host list's entry, or a network's limits, that isn't one is
    # refused, not crashed on.
    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [],
               credentials: [],
               built_in: [%{id: "internet", host_rules: ["paste.example"]}]
             })

    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [],
               credentials: [],
               internet_limits: %{default: :maybe, rules: []}
             })

    assert {:error, _} =
             MWTClient.Sandbox.Transfer.prepare(1, %{
               grants: [],
               credentials: [],
               networks: [
                 %{id: "lan", name: "LAN", destinations: [], limits: %{rules: [%{host: 1}]}}
               ]
             })
  end

  test "stored values never print: they travel sealed from the moment the file is read" do
    {:ok, prepared} =
      MWTClient.Sandbox.Transfer.prepare(1, %{
        grants: [],
        credentials: [%{id: "dl", name: "Datalake", source: :stored}],
        values: %{"dl" => "real-datalake-0123456789"}
      })

    refute inspect(prepared) =~ "real-datalake"
    assert prepared.values.() == %{"dl" => "real-datalake-0123456789"}
  end

  test "a credential that comes in gets placeholders of its own, never one of yours", %{
    username: username,
    password: password,
    path: path
  } do
    {datalake, _google, _storage} = setup_grants(username)
    :ok = Transfer.export(username, path)

    # Into the same identity, its datalake made differently: the file's
    # comes in beside it, with a new placeholder.
    {:ok, _} =
      Sandbox.update_grant(username, datalake.id, %{
        "name" => "Datalake",
        "purpose" => "The datalake in prod",
        "hosts" => "internal.example.com",
        "env" => "DATALAKE_TOKEN, DL_TOKEN"
      })

    {:ok, plan} = Transfer.read(username, path, password: password)
    :ok = Transfer.import(username, plan, :merge)

    placeholders = Enum.map(Sandbox.snapshot(username).credentials, & &1.placeholder)
    assert length(placeholders) == length(Enum.uniq(placeholders))

    imported = Enum.find(Sandbox.snapshot(username).credentials, &(&1.id == "datalake-imported"))
    assert imported && imported.placeholder != datalake.placeholder
  end

  test "a file of before resources: its grants come in as each mediating one resource" do
    {:ok, prepared} =
      MWTClient.Sandbox.Transfer.prepare(1, %{
        credentials: [],
        grants: [
          # Ask to run commands: a command an agent writes needs no grant.
          %{id: "commands", name: "Ask to run commands", kind: :command},
          # A token grant only its actions used: its actions stay, over
          # its credential.
          %{id: "gh", name: "GitHub", kind: :token, reach: :actions, credential: "github"},
          %{id: "gh-view", name: "View", kind: :request, parent: "gh"},
          %{id: "gcp", name: "GCP", kind: :token, credential: "google"},
          %{id: "bq", name: "bq", kind: :command, script: "bq ls", with: ["gcp"]}
        ]
      })

    assert [
             %Grant{id: "gh-view", credential: "github"},
             %Grant{id: "gcp", credential: "google", machine: true},
             %Grant{id: "bq", with: ["google"]}
           ] = prepared.grants
  end

  test "a network comes with the hosts it blocks", %{username: username, password: password} do
    {:ok, lan} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "LAN",
        "purpose" => "The office",
        "destinations" => "*.lan.example:443"
      })

    {:ok, _} = Sandbox.limits_set(username, lan.id, {:put, "admin.lan.example", true})

    {:ok, data} = MWTClient.Sandbox.Transfer.export(username)
    {:ok, prepared} = MWTClient.Sandbox.Transfer.prepare(1, data)

    other = also_unlock("sandbox-networks", password)
    :ok = Sandbox.Server.call(other, {:transfer_import, :merge, prepared})

    network = Enum.find(Sandbox.snapshot(other).networks, &(&1.id == lan.id))
    assert HostLimits.blocked?(network.limits, "admin.lan.example")
    refute HostLimits.blocked?(network.limits, "wiki.lan.example")
  end

  test "a file of before networks: its host list comes in once as the hosts the Internet blocks",
       %{username: username} do
    {:ok, prepared} =
      MWTClient.Sandbox.Transfer.prepare(1, %{
        grants: [],
        credentials: [],
        built_in: [%{id: "internet", host_rules: [%{host: "paste.example", action: :block}]}]
      })

    for _twice <- 1..2,
        do: :ok = Sandbox.Server.call(username, {:transfer_import, :merge, prepared})

    # A grant of the file's that had checks comes in without, named.
    {:ok, checked} =
      MWTClient.Sandbox.Transfer.prepare(1, %{
        credentials: [],
        grants: [
          %{
            id: "lan",
            name: "LAN",
            kind: :network,
            destinations: ["10.0.0.0/8"],
            checks: [%{id: "c", name: "the VPN is up", script: "true"}]
          }
        ]
      })

    :ok = Sandbox.Server.call(username, {:transfer_import, :merge, checked})

    assert Enum.any?(
             Sandbox.events(username),
             &(&1.summary =~ "Checks removed, which no longer run: LAN: the VPN is up")
           )

    assert [%{host: "paste.example", blocked?: true}] = internet(username).limits.rules
    refute Enum.any?(Sandbox.snapshot(username).grants, &(&1.scope == ["*.paste.example"]))
  end

  test "a network whose id you have for another comes in beside yours, its grant to review with it",
       %{username: username} do
    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "LAN",
        "purpose" => "The office",
        "destinations" => "10.0.0.0/8"
      })

    {:ok, prepared} =
      MWTClient.Sandbox.Transfer.prepare(1, %{
        credentials: [],
        networks: [%{id: "lan", name: "LAN", destinations: ["10.9.0.0/16"]}],
        grants: [
          %{
            id: "lan",
            name: "LAN",
            kind: :network,
            purpose: "The lab",
            network: "lan",
            destinations: ["10.9.0.0/16"]
          }
        ]
      })

    :ok = Sandbox.Server.call(username, {:transfer_import, :merge, prepared})
    snapshot = Sandbox.snapshot(username)

    assert %{destinations: ["10.0.0.0/8"]} = Enum.find(snapshot.networks, &(&1.id == "lan"))

    assert %{destinations: ["10.9.0.0/16"]} =
             Enum.find(snapshot.networks, &(&1.id == "lan-imported"))

    imported = Enum.find(snapshot.grants, &(&1.id == "lan-imported"))
    assert Grant.to_review?(imported)
    assert imported.network == "lan-imported" and imported.destinations == ["10.9.0.0/16"]
  end

  test "replacing puts the file's grants in place of yours", %{
    username: username,
    password: password,
    path: path
  } do
    setup_grants(username)
    :ok = Transfer.export(username, path)

    other = also_unlock("sandbox-replace", password)

    {:ok, _} =
      Sandbox.create_grant(other, %{
        "kind" => "network",
        "name" => "LAN",
        "purpose" => "Theirs",
        "destinations" => "10.0.0.0/8"
      })

    {:ok, plan} = Transfer.read(other, path, password: password)
    :ok = Transfer.import(other, plan, :replace)

    assert Enum.map(own(other), & &1.name) |> Enum.sort() == [
             "BigQuery",
             "Cloud Storage",
             "Datalake"
           ]

    assert HostLimits.blocked?(internet(other).limits, "paste.example")
  end
end
