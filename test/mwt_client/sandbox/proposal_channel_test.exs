defmodule MWTClient.Sandbox.ProposalChannelTest do
  @moduledoc """
  What an agent proposes through the `mwt` command in the VM: an action
  over a resource, or a grant, waiting for your review.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Grant}

  describe "an action an agent proposes" do
    defp propose(context, extra \\ []) do
      mwt(
        context,
        [
          "propose",
          "machine",
          "--name",
          "repo view",
          "--for",
          "Shows a repository",
          "--param",
          "REPO_NAME:word:the repository, as owner/name",
          "--reason",
          "I look at several"
        ] ++ extra ++ ["--", ~s(echo "viewing $REPO_NAME")]
      )
    end

    defp proposed(username, id),
      do: Enum.find(Sandbox.snapshot(username).grants, &(&1.id == id))

    test "is saved at once, off and to review; accepting it on its page answers with its id",
         context do
      # Nothing has to be on: it is a saved command, over your machine.
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      assert ask.title == "Review repo view"
      assert %{kind: :command, parent_name: "Host commands", updated: false} = ask.proposal

      grant = proposed(context.username, ask.grant_id)

      assert %Grant{
               kind: :command,
               name: "repo view",
               purpose: "Shows a repository",
               script: ~s(echo "viewing $REPO_NAME"),
               params: [%{name: "REPO_NAME", schema: %{"format" => "word"}}],
               state: :off,
               start: :off,
               proposal: %{agent: "claude", reason: "I look at several", reviewed_at: nil}
             } = grant

      assert Grant.resource(grant) == :machine
      assert Grant.to_review?(grant)
      # Confined, as one you add starts.
      assert grant.confined
      assert grant.proposal.thread.title == "Ship the release"

      # Nothing turns it on before you accept it: not its switch, not the card.
      assert {:error, :to_review} = Sandbox.turn_on(context.username, grant.id, 60)

      assert {:error, :bad_decision} =
               Sandbox.decide(context.username, ask.id, {:turn_on, 60, :ask})

      assert {:error, :to_review} = Sandbox.set_start(context.username, grant.id, :on)

      # The agent is told where it is and that it waits.
      assert Sandbox.snapshot(context.username).waiting |> Enum.any?(&(&1.id == ask.id))

      {:ok, accepted} =
        Sandbox.review(context.username, grant.id, {60, :ask}, grant.proposal.revision)

      refute Grant.to_review?(accepted)
      assert Grant.proposed?(accepted)
      assert accepted.state == :on

      assert {output, 0} = Task.await(asking)
      assert output =~ "Saved as repo-view, off, for the user to review"
      assert output =~ "accepted it as repo-view"
      assert output =~ ~s(mwt call repo-view REPO_NAME=… --reason "why now")

      # On for the time it asked, each call asking.
      called =
        Task.async(fn ->
          mwt(context, ["call", "repo-view", "REPO_NAME=oliveigah/klife", "--reason", "r"],
            stderr: false
          )
        end)

      approval = command(context.username)
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {"viewing oliveigah/klife\n", 0} = Task.await(called)

      # Accepted, it is the user's: reviewing again is refused.
      assert {:error, :reviewed} =
               Sandbox.review(context.username, grant.id, :keep_off, grant.proposal.revision)
    end

    # The agent may propose again under the same name, changing what you
    # are reading: accepting names the revision the page showed.
    test "accepting takes it as the page showed it, never as the agent changed it since",
         context do
      revise = fn script ->
        mwt(context, [
          "propose",
          "machine",
          "--name",
          "repo view",
          "--for",
          "Shows a repository",
          "--param",
          "REPO_NAME:word:the repository, as owner/name",
          "--reason",
          "r",
          "--wait",
          "0",
          "--",
          script
        ])
      end

      {_said, 2} = revise.(~s(echo "viewing $REPO_NAME"))
      shown = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.name == "repo view"))

      {_said, 2} = revise.(~s(gh repo delete "$REPO_NAME" --yes))
      changed = proposed(context.username, shown.id)
      assert changed.script =~ "delete"
      assert changed.proposal.revision != shown.proposal.revision

      assert {:error, :changed} =
               Sandbox.review(context.username, shown.id, {60, :ask}, shown.proposal.revision)

      assert Grant.to_review?(proposed(context.username, shown.id))

      assert {:ok, _accepted} =
               Sandbox.review(context.username, shown.id, :keep_off, changed.proposal.revision)
    end

    test "one in a shared folder is saved to run there", context do
      shared = Path.join(context.project, "docs")
      File.mkdir_p!(shared)
      {:ok, share} = Sandbox.add_share(context.username, shared)

      assert {_output, 2} = propose(context, ["--wait", "0", "--dir", shared])
      ask = waiting(context.username, &(&1.kind == :activation))
      assert proposed(context.username, ask.grant_id).dir == share.path
    end

    test "proposed again under its name before review, it changes in place", context do
      assert {_output, 2} = propose(context, ["--wait", "0"])
      ask = waiting(context.username, &(&1.kind == :activation))
      first = proposed(context.username, ask.grant_id)

      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "machine",
                 "--name",
                 "Repo View",
                 "--for",
                 "Shows a repository, as JSON",
                 "--reason",
                 "again",
                 "--wait",
                 "0",
                 "--",
                 "gh repo view --json name"
               ])

      assert output =~ "Your proposal repo-view is changed"
      changed = proposed(context.username, first.id)
      assert changed.script == "gh repo view --json name"
      assert changed.purpose == "Shows a repository, as JSON"
      assert Enum.count(Sandbox.snapshot(context.username).grants, &Grant.to_review?/1) == 1

      # One ask waits for it, asked twice.
      assert [%{retries: 1}] =
               Enum.filter(Sandbox.snapshot(context.username).waiting, &(&1.grant_id == first.id))
    end

    test "accepted and kept off, it waits for its switch; its ask is answered when it turns on",
         context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))

      revision = proposed(context.username, ask.grant_id).proposal.revision
      {:ok, accepted} = Sandbox.review(context.username, ask.grant_id, :keep_off, revision)
      assert accepted.state == :off
      refute Grant.to_review?(accepted)
      assert Grant.starts(accepted) == [:off, :on, :auto]

      {:ok, _} = Sandbox.turn_on(context.username, accepted.id, 60)
      assert {output, 0} = Task.await(asking)
      assert output =~ "accepted it as repo-view"
    end

    test "declined, the agent hears so and the proposal is removed", context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      :ok = Sandbox.decide(context.username, ask.id, :decline)
      assert {output, 3} = Task.await(asking)
      assert output =~ "declined it, and the proposal is removed"
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &Grant.action?/1)
    end

    test "removed from its page before review, the agent hears it was declined", context do
      asking = Task.async(fn -> propose(context) end)
      ask = waiting(context.username, &(&1.kind == :activation))
      :ok = Sandbox.delete_grant(context.username, ask.grant_id)
      assert {output, 3} = Task.await(asking)
      assert output =~ "declined"
    end

    test "is refused before it waits when it is no function the user could read", context do
      for {args, says} <- [
            {["propose", "machine", "--for", "x", "--reason", "r", "--", "echo a"], "Name it"},
            {["propose", "machine", "--name", "x", "--reason", "r", "--", "echo a"],
             "Say what it does"},
            {["propose", "machine", "--name", "x", "--for", "y", "--", "echo a"], "Say why"},
            {["propose", "machine", "--name", "x", "--for", "y", "--reason", "r"],
             "Give the script"},
            {[
               "propose",
               "machine",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--param",
               "WORD:word:a word",
               "--",
               "echo fixed"
             ], "doesn't read WORD"},
            {[
               "propose",
               "machine",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--param",
               "LD_PRELOAD:text:a library",
               "--",
               ~s(echo "$LD_PRELOAD")
             ], "already means something"},
            {["propose", "nope", "--name", "x", "--for", "y", "--reason", "r", "--", "echo a"],
             ~s[Nothing is called "nope"]},
            {[
               "propose",
               "machine",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--",
               "echo",
               "$A"
             ], "one argument in single quotes"},
            {["propose", "token", "--name", "x", "--for", "y", "--reason", "r"],
             "mwt propose token is gone"},
            {["propose", "network", "--name", "x", "--for", "y", "--reason", "r"],
             "--destination: List at least one"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--host", "api.example.com"], "--host isn't for a credential"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--set", "value=sk_live"], "value is yours to set"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--set", "hosts=a.example"], "A credential has no field hosts"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--set", "adapter"], "--set takes NAME=VALUE"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--preset", "nope"], "No preset for a credential is called nope"},
            # A grant preset doesn't start a credential.
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--preset", "github-everything"],
             "No preset for a credential is called github-everything"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--set", "adapter=gitlab"], "No adapter is called gitlab"},
            {["propose", "credential", "--name", "x", "--for", "y", "--reason", "r"] ++
               ["--set", "app_id=Iv23li"], "A GitHub App's token is minted"},
            {["propose", "grant", "--name", "x", "--for", "y", "--reason", "r"],
             "Say which resource the grant is over"},
            {["propose", "grant", "--over", "nope", "--name", "x", "--for", "y", "--reason", "r"],
             ~s[No credential or network is called "nope"]},
            {[
               "propose",
               "credential",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--",
               "echo a"
             ], "takes no script"}
          ] do
        assert {output, 1} = mwt(context, args)
        assert output =~ says, inspect(args)
      end

      snapshot = Sandbox.snapshot(context.username)
      assert snapshot.waiting == []
      refute Enum.any?(snapshot.grants, &Grant.proposed?/1)
      assert snapshot.credentials == []
    end
  end

  describe "a resource and grants over it, proposed apart" do
    defp credential(username, id),
      do: Enum.find(Sandbox.snapshot(username).credentials, &(&1.id == id))

    defp grant(username, id),
      do: Enum.find(Sandbox.snapshot(username).grants, &(&1.id == id))

    test "a credential with no value, then a grant over it: each accepted in turn",
         context do
      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "credential",
                 "--name",
                 "Stripe test",
                 "--for",
                 "A Stripe test key",
                 "--env",
                 "STRIPE_API_KEY",
                 "--reason",
                 "The checkout tests call Stripe",
                 "--wait",
                 "0"
               ])

      assert output =~ "Saved as the credential stripe-test, for the user to review"

      assert %{env: ["STRIPE_API_KEY"], source: :stored, adapter: :bearer, proposal: proposal} =
               stripe = credential(context.username, "stripe-test")

      assert %{agent: "claude", reviewed_at: nil} = proposal
      assert Sandbox.snapshot(context.username).grants |> Enum.filter(&Grant.proposed?/1) == []
      ask = waiting(context.username, &(&1.resource == {:credential, "stripe-test"}))
      assert ask.title == "Review Stripe test"

      # A grant over it, proposed before it is accepted.
      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "grant",
                 "--over",
                 "Stripe test",
                 "--name",
                 "Stripe API",
                 "--for",
                 "Test charges through the Stripe API",
                 "--host",
                 "api.stripe.com",
                 "--carrier",
                 "Authorization",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      assert output =~ "Saved as stripe-api, off, for the user to review"

      assert %Grant{
               kind: :token,
               credential: "stripe-test",
               hosts: ["api.stripe.com"],
               env: ["STRIPE_API_KEY"],
               carriers: ["authorization"],
               state: :off
             } = over = grant(context.username, "stripe-api")

      assert Grant.to_review?(over)

      # The resource first.
      assert {:error, :resource_to_review} =
               Sandbox.review(context.username, over.id, :keep_off, over.proposal.revision)

      assert {:error, :changed} =
               Sandbox.review_resource(context.username, {:credential, "stripe-test"}, "old")

      assert {:ok, %{proposal: %{reviewed_at: %DateTime{}}}} =
               Sandbox.review_resource(
                 context.username,
                 {:credential, "stripe-test"},
                 stripe.proposal.revision
               )

      assert {said, 0} = mwt(context, ["wait", ask.id])
      assert said =~ "accepted the credential stripe-test"
      assert said =~ "mwt_no_value"

      # Accepted with no value: the grant over it can't turn on yet.
      assert {:error, :no_value} =
               Sandbox.review(context.username, over.id, {60, :ask}, over.proposal.revision)

      {:ok, _off} = Sandbox.review(context.username, over.id, :keep_off, over.proposal.revision)
      assert {:error, :no_value} = Sandbox.turn_on(context.username, over.id, 60)
      :ok = Sandbox.set_credential_value(context.username, "stripe-test", "sk_test_real")
      assert {:ok, %{state: :on}} = Sandbox.turn_on(context.username, over.id, 60)
    end

    test "a GitHub App from its preset, a field overridden, and a grant on one repository",
         context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "credential",
                 "--name",
                 "GitHub App",
                 "--for",
                 "My App's installation token",
                 "--preset",
                 "github-app",
                 "--fill",
                 "app_id=Iv23liABCD",
                 "--fill",
                 "installation_id=12345678",
                 "--fill",
                 "key_command=cat ~/.config/app.pem",
                 "--set",
                 "env=GH_TOKEN",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      assert %{
               adapter: :github,
               app: %{app_id: "Iv23liABCD", installation_id: "12345678"},
               source: {:minted, "cat ~/.config/app.pem"},
               env: ["GH_TOKEN"],
               git: true,
               preset: "github-app",
               cli_tools: ["gh"]
             } = app = credential(context.username, "github-app")

      assert String.starts_with?(app.placeholder, "ghs_")

      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "grant",
                 "--over",
                 "github-app",
                 "--name",
                 "klife only",
                 "--for",
                 "gh and git on oliveigah/klife",
                 "--preset",
                 "github-repository",
                 "--fill",
                 "repository=oliveigah/klife",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      assert %Grant{
               credential: "github-app",
               hosts: ["api.github.com", "github.com", "uploads.github.com"],
               attributes: %{"github.repository" => ["oliveigah/klife"]},
               app: %{app_id: "Iv23liABCD"}
             } = grant(context.username, "klife-only")
    end

    test "the same App from no preset at all, every field set", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "credential",
                 "--name",
                 "Bare App",
                 "--for",
                 "An App by hand",
                 "--set",
                 "adapter=github",
                 "--set",
                 "app_id=123456",
                 "--set",
                 "installation_id=42",
                 "--mint",
                 "pass show github/app-key",
                 "--env",
                 "GH_TOKEN",
                 "--git",
                 "--set",
                 "prefix=ghs_",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      assert %{
               adapter: :github,
               app: %{app_id: "123456", installation_id: "42"},
               source: {:minted, "pass show github/app-key"},
               git: true,
               preset: nil
             } = credential(context.username, "bare-app")
    end

    test "a Google credential with a metadata server, and a grant that signs as an account",
         context do
      google = fn extra ->
        mwt(
          context,
          [
            "propose",
            "credential",
            "--name",
            "BigQuery",
            "--for",
            "Queries from Python",
            "--preset",
            "google",
            "--reason",
            "r",
            "--wait",
            "0"
          ] ++ extra
        )
      end

      # The server needs a project: an account alone is refused, naming the
      # option it lacks, and nothing is saved.
      assert {output, 1} = google.(["--metadata-account", "sa@p.iam.gserviceaccount.com"])
      assert output =~ "--metadata-project: Name the project"
      refute credential(context.username, "bigquery")

      assert {_output, 2} =
               google.([
                 "--metadata-project",
                 "my-project",
                 "--metadata-account",
                 "sa@my-project.iam.gserviceaccount.com",
                 "--keep-minutes",
                 "4"
               ])

      assert %{
               adapter: :google,
               keep_minutes: 4,
               presents: %{
                 metadata: %{
                   project: "my-project",
                   email: "sa@my-project.iam.gserviceaccount.com"
                 }
               }
             } = credential(context.username, "bigquery")

      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "grant",
                 "--over",
                 "BigQuery",
                 "--name",
                 "Internal service",
                 "--for",
                 "The internal service behind IAP",
                 "--preset",
                 "google-apis",
                 "--host",
                 "svc.example.com",
                 "--sign-as",
                 "svc@p.iam.gserviceaccount.com",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      # The option replaces the preset's hosts, as a field the form has.
      assert %Grant{hosts: ["svc.example.com"], signs_as: ["svc@p.iam.gserviceaccount.com"]} =
               grant(context.username, "internal-service")

      {0, listed} = Channel.answer("grants", %{}, context.username)
      assert listed =~ "signJwt as svc@p.iam.gserviceaccount.com"
    end

    test "a network, and a grant over part of it", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "network",
                 "--name",
                 "Staging",
                 "--for",
                 "The staging network",
                 "--destination",
                 "db.staging.corp:5432",
                 "--destination",
                 "10.20.0.0/16:5432",
                 "--resolver",
                 "10.8.0.1",
                 "--via",
                 "wg0",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      network = Enum.find(Sandbox.snapshot(context.username).networks, &(&1.id == "staging"))

      assert %{
               destinations: ["db.staging.corp:5432", "10.20.0.0/16:5432"],
               resolver: "10.8.0.1",
               anchor: "wg0",
               proposal: %{reviewed_at: nil}
             } = network

      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "grant",
                 "--over",
                 "staging",
                 "--name",
                 "Staging database",
                 "--for",
                 "Postgres on staging",
                 "--destination",
                 "db.staging.corp:5432",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      over = grant(context.username, "staging-database")
      assert %Grant{kind: :network, network: "staging", scope: ["db.staging.corp:5432"]} = over

      # An ask for it by id makes a card to review, never one that turns it on.
      assert {_output, 2} = mwt(context, ["request", over.id, "--reason", "r", "--wait", "0"])

      ask =
        waiting(
          context.username,
          &(&1.kind == :activation and &1.grant_id == over.id and is_nil(&1.proposal))
        )

      assert {:error, :bad_decision} =
               Sandbox.decide(context.username, ask.id, {:turn_on, 60, :ask})
    end

    test "declining a proposed credential removes it and what was proposed over it", context do
      {_output, 2} =
        mwt(context, [
          "propose",
          "credential",
          "--name",
          "Hex key",
          "--for",
          "Publishing",
          "--preset",
          "hex",
          "--reason",
          "r",
          "--wait",
          "0"
        ])

      asking =
        Task.async(fn ->
          mwt(context, [
            "propose",
            "grant",
            "--over",
            "Hex key",
            "--name",
            "Hex packages",
            "--for",
            "hex.pm",
            "--preset",
            "hex-packages",
            "--reason",
            "r"
          ])
        end)

      grant_ask = waiting(context.username, &(&1.grant_id == "hex-packages"))
      ask = waiting(context.username, &(&1.resource == {:credential, "hex-key"}))
      :ok = Sandbox.decide(context.username, ask.id, :decline)

      refute credential(context.username, "hex-key")
      refute grant(context.username, "hex-packages")
      assert {output, 3} = Task.await(asking)
      assert output =~ "declined"
      refute Enum.any?(Sandbox.snapshot(context.username).waiting, &(&1.id == grant_ask.id))
    end

    test "at most twenty wait for review, resources and grants together", context do
      for n <- 1..20 do
        assert {_output, 2} =
                 mwt(context, [
                   "propose",
                   "network",
                   "--name",
                   "net #{n}",
                   "--for",
                   "y",
                   "--destination",
                   "10.0.0.#{n}:22",
                   "--reason",
                   "r",
                   "--wait",
                   "0"
                 ])
      end

      assert {output, 1} =
               mwt(context, [
                 "propose",
                 "credential",
                 "--name",
                 "one more",
                 "--for",
                 "y",
                 "--reason",
                 "r"
               ])

      assert output =~ "Twenty of your proposals"
    end
  end
end
