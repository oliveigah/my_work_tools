defmodule MWTClient.Sandbox.ExplainTest do
  @moduledoc """
  `mwt why` on whole requests (`MWTClient.Sandbox.Explain`): how one would
  be decided now, sending nothing; the last decisions on the VM's own
  requests; one of them by id. Each from a list of what may be shown: no
  value, no placeholder, no body, nothing of the firewall's workings.
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Approval, Channel, Credential, Event, Explain}

  doctest MWTClient.Sandbox.Overlaps

  @google "gcloud auth print-access-token"

  defp google(id, hosts, state) do
    grant = %Grant{
      id: id,
      name: id,
      kind: :token,
      preset: "google",
      source: {:minted, @google},
      placeholder: "ya29.mwt_" <> id,
      hosts: hosts
    }

    case state do
      :auto -> %{grant | state: :on, allowances: [allowance(:all, nil)]}
      :ask -> %{grant | state: :on}
      :off -> Grant.put_down(grant)
    end
  end

  defp internet, do: %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

  defp world(grants, opts \\ []) do
    {grants, _} = Credential.migrate(grants, [])

    %{
      snapshot: snapshot(grants) |> Map.put(:locks, Keyword.get(opts, :locks, %{})),
      isolated: Keyword.get(opts, :isolated, false),
      now: @now
    }
  end

  describe "a request not made yet" do
    test "names each grant's say over each resource, the most permissive giving" do
      world =
        world([
          google("google-all", ["*.googleapis.com"], :auto),
          google("cloud-storage", ["storage.googleapis.com"], :off),
          internet()
        ])

      explain = fn world ->
        {:ok, text} =
          Explain.request(
            "https://storage.googleapis.com/upload/b/o?x=1",
            "post",
            "google-all",
            world
          )

        text
      end

      text = explain.(world)

      assert text =~
               "POST https://storage.googleapis.com/upload/b/o?x=1, carrying the credential google-all"

      assert text =~ "The credential google-all:"
      assert text =~ "google-all (google-all): yes, on, auto-approved"
      assert text =~ "cloud-storage (cloud-storage): nothing, off"
      assert text =~ "The network internet:"
      assert text =~ "Internet (network, internet): yes"
      # Off, it has no say: the one on gives it.
      assert text =~ "Decision: goes through, with google-all's value."
      refute text =~ "ya29.mwt"

      # None on over the credential: refused, naming each one to ask for.
      off =
        world([
          google("google-all", ["*.googleapis.com"], :off),
          google("cloud-storage", ["storage.googleapis.com"], :off),
          internet()
        ])

      text = explain.(off)
      assert text =~ "Decision: refused"
      assert text =~ "mwt request google-all"
      assert text =~ "mwt request cloud-storage"
    end

    test "names the network's grant too: the credential's alone doesn't send it" do
      world = world([google("google-all", ["*.googleapis.com"], :auto), Grant.internet()])

      {:ok, text} =
        Explain.request("https://bigquery.googleapis.com/q", nil, "google-all", world)

      assert text =~ "google-all (google-all): yes, on, auto-approved"
      assert text =~ "Internet (network, internet): nothing, off"
      assert text =~ "Decision: refused: Internet (internet) would give it, and is off."
      assert text =~ "mwt request internet"
    end

    test "goes through with no credential where the Internet lets it" do
      {:ok, text} = Explain.request("https://pypi.org/simple/", nil, nil, world([internet()]))
      assert text =~ "GET https://pypi.org/simple/, carrying no credential"
      assert text =~ "Decision: goes through."
    end

    test "says a lock is the user's to lift, and asking won't" do
      world =
        world([google("google-all", ["*.googleapis.com"], :auto), internet()],
          locks: %{{:credential, "google-all"} => %{you: @now}}
        )

      {:ok, text} = Explain.request("https://bigquery.googleapis.com/q", nil, "google-all", world)
      assert text =~ "locked by the user"
      assert text =~ "only they can unlock it"
    end

    test "names a credential that doesn't exist, and a target that isn't a URL" do
      world = world([internet()])
      assert {:error, message} = Explain.request("https://x.example/", nil, "nope", world)
      assert message =~ "No credential nope"
      assert {:error, _} = Explain.request("ftp://x.example/", nil, nil, world)
    end

    test "shows the path made safe, never a control character" do
      {:ok, text} = Explain.request("https://x.example/a%1Bb", nil, nil, world([internet()]))
      refute text =~ <<27>>
    end
  end

  describe "overlaps" do
    test "only grants over the same network overlap, a name and a range maybe" do
      lan = %Grant{
        id: "lan",
        name: "LAN",
        kind: :network,
        destinations: ["10.0.0.0/8", "db.corp.example:5432"]
      }

      part = fn id, destinations ->
        %Grant{
          id: id,
          name: id,
          kind: :network,
          network: "lan",
          scope: destinations,
          destinations: destinations
        }
      end

      lab = part.("lan-lab", ["10.20.0.0/16"])
      wiki = part.("lan-wiki", ["wiki.corp.example:443"])

      # Another network, and a credential, are other resources: a use that
      # goes through both needs each.
      vpn = %Grant{id: "vpn", name: "VPN", kind: :network, destinations: ["10.20.0.0/16"]}

      token = %Grant{
        id: "dl",
        name: "Datalake",
        kind: :token,
        credential: "dl",
        hosts: ["internal.corp.example"]
      }

      assert [%{grant: %{id: "lan-lab"}, may?: false}, %{grant: %{id: "lan-wiki"}, may?: true}] =
               MWTClient.Sandbox.Overlaps.of(lan, [lan, lab, vpn, wiki, token])

      assert MWTClient.Sandbox.Overlaps.of(token, [lan, lab, vpn, wiki, token]) == []
    end
  end

  describe "the last decisions" do
    test "lists what was refused, denied or waits, newest first, since the VM started" do
      grants = [google("cloud-storage", ["storage.googleapis.com"], :ask)]

      events = [
        %Event{
          id: "event-2",
          at: @later,
          outcome: :refused,
          host: "storage.googleapis.com",
          method: "POST",
          path: "/upload",
          grant_id: "cloud-storage",
          summary: "x"
        },
        %Event{
          id: "event-1",
          at: @earlier,
          outcome: :refused,
          host: "old.example",
          method: "GET",
          path: "/",
          summary: "x"
        },
        %Event{
          id: "event-3",
          at: @later,
          outcome: :firewall,
          host: "paste.example",
          summary: "rule saw it"
        },
        %Event{id: "event-4", at: @later, outcome: :read, host: "pypi.org", summary: "read"}
      ]

      waiting = [
        %Approval{
          id: "approval-1",
          kind: :request,
          title: "GET h/",
          grant_id: "cloud-storage",
          requested_at: @now,
          deadline: @later
        }
      ]

      text = Explain.recent(events, waiting, grants, @now)
      assert text =~ "event-2"
      assert text =~ "refused  POST storage.googleapis.com/upload  · cloud-storage"
      assert text =~ "approval-1"
      assert text =~ "waiting  GET h/  · asks cloud-storage"
      refute text =~ "event-1"
      refute text =~ "paste.example"
      refute text =~ "rule saw it"
      refute text =~ "event-4"
      [_header, first | _] = String.split(text, "\n")
      assert first =~ "event-2"
    end

    test "says when there is nothing" do
      assert Explain.recent([], [], []) =~ "Nothing refused"
    end
  end

  describe "through the agent channel" do
    setup do
      %{username: username} = MWTClient.VaultHelpers.unlocked_identity("explain")
      %{username: username}
    end

    test "mwt why URL decides a request without sending it, and mwt why --recent lists what was refused",
         %{username: username} do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "name" => "GitHub",
          "purpose" => "Read klife",
          "hosts" => "api.github.com",
          "env" => "GH_TOKEN",
          "value" => "ghp_real_value_0123456789"
        })

      assert {0, text} =
               Channel.answer(
                 "why",
                 %{"target" => "https://api.github.com/user", "with" => grant.credential},
                 username
               )

      assert text =~ "GitHub (github): nothing, off"
      assert text =~ "Decision: refused"
      refute text =~ grant.placeholder
      refute text =~ "ghp_real_value"

      # A request the proxy refused shows among the last decisions.
      request = %{
        host: "api.github.com",
        method: "GET",
        path: "/user",
        headers: [{"authorization", "token " <> grant.placeholder}],
        body: ""
      }

      assert text =~ "Dry run"
      assert {:deny, 403, body} = Sandbox.Server.call(username, {:authorize, request})
      # The refusal names its decision, for mwt why to give back as made.
      assert %{"decision" => "event-" <> _ = id, "why" => "mwt why " <> id} = Jason.decode!(body)

      assert {0, text} = Channel.answer("why", %{"recent" => true}, username)
      assert text =~ "refused  GET api.github.com/user  · GitHub"
      assert text =~ id

      # Turned on since, the decision given back is still the one made then.
      {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
      assert {0, text} = Channel.answer("why", %{"target" => id}, username)
      assert text =~ "As decided then"
      assert text =~ "GitHub (github): nothing, off"
      assert text =~ "Decision: refused"
      refute text =~ "Dry run"
      refute text =~ grant.placeholder
    end
  end
end
