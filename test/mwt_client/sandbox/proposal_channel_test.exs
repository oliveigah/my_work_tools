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
      assert %{kind: :command, parent_name: "Your machine", updated: false} = ask.proposal

      grant = proposed(context.username, ask.grant_id)

      assert %Grant{
               kind: :command,
               name: "repo view",
               purpose: "Shows a repository",
               script: ~s(echo "viewing $REPO_NAME"),
               params: [%{name: "REPO_NAME", shape: :word}],
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

      assert {:error, :every_run_asks} = Sandbox.set_start(context.username, grant.id, :on)

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
             "--host: List at least one host"},
            {["propose", "network", "--name", "x", "--for", "y", "--reason", "r"],
             "--destination: List at least one"},
            {[
               "propose",
               "token",
               "--name",
               "x",
               "--for",
               "y",
               "--reason",
               "r",
               "--preset",
               "nope"
             ], "No token preset is called nope"},
            {["propose", "token", "--name", "x", "--for", "y", "--reason", "r", "--", "echo a"],
             "takes no script"}
          ] do
        assert {output, 1} = mwt(context, args)
        assert output =~ says, inspect(args)
      end

      assert Sandbox.snapshot(context.username).waiting == []
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &Grant.proposed?/1)
    end
  end

  describe "a grant an agent proposes" do
    test "a token grant: saved off with no value; accepted, it needs one before it turns on",
         context do
      assert {output, 2} =
               mwt(context, [
                 "propose",
                 "token",
                 "--name",
                 "Stripe test",
                 "--for",
                 "Test charges through the Stripe API",
                 "--host",
                 "api.stripe.com",
                 "--env",
                 "STRIPE_API_KEY",
                 "--carrier",
                 "Authorization",
                 "--reason",
                 "The checkout tests call Stripe",
                 "--wait",
                 "0"
               ])

      assert output =~ "Saved as stripe-test, off, for the user to review"
      assert output =~ "mwt wait"

      grant = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "stripe-test"))

      assert %Grant{
               kind: :token,
               hosts: ["api.stripe.com"],
               env: ["STRIPE_API_KEY"],
               carriers: ["authorization"],
               source: :stored,
               state: :off,
               start: :off
             } = grant

      assert Grant.to_review?(grant)
      refute Sandbox.snapshot(context.username).values["stripe-test"]

      # grants.md says it waits for the user.
      {0, listed} = Channel.answer("grants", %{}, context.username)
      assert listed =~ "proposed by claude and not reviewed yet"

      # No value yet: accepting it can't turn it on.
      assert {:error, :no_value} =
               Sandbox.review(context.username, grant.id, {60, :ask}, grant.proposal.revision)

      :ok = Sandbox.set_value(context.username, grant.id, "sk_test_real")
      {:ok, on} = Sandbox.review(context.username, grant.id, {60, :ask}, grant.proposal.revision)
      assert on.state == :on
    end

    test "a token grant from a preset takes its fields, the agent's overriding them", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "token",
                 "--name",
                 "GitHub, read-only",
                 "--for",
                 "Reading issues of oliveigah/klife",
                 "--preset",
                 "github",
                 "--host",
                 "api.github.com",
                 "--reason",
                 "r",
                 "--wait",
                 "0"
               ])

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "github-read-only"))

      assert grant.hosts == ["api.github.com"]
      assert grant.env == ["GITHUB_TOKEN", "GH_TOKEN"]
      assert grant.git
      assert grant.preset == "github"
      assert grant.cli_tools == ["gh"]
      assert String.starts_with?(grant.placeholder, "ghp_")
    end

    test "a Google grant with a metadata server for client libraries", context do
      google = fn extra ->
        mwt(
          context,
          [
            "propose",
            "token",
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
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &(&1.id == "bigquery"))

      assert {_output, 2} =
               google.([
                 "--metadata-project",
                 "my-project",
                 "--metadata-account",
                 "sa@my-project.iam.gserviceaccount.com"
               ])

      grant = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "bigquery"))

      assert grant.presents == %{
               metadata: %{project: "my-project", email: "sa@my-project.iam.gserviceaccount.com"}
             }

      assert grant.hosts == ["*.googleapis.com"]
      assert Grant.to_review?(grant)
    end

    test "a grant that signs JWTs as a service account, its tokens kept a few minutes",
         context do
      propose = fn extra ->
        mwt(
          context,
          [
            "propose",
            "token",
            "--name",
            "Internal service",
            "--for",
            "The internal service behind IAP",
            "--host",
            "svc.example.com",
            "--mint",
            "gcloud auth print-access-token",
            "--keep-minutes",
            "4",
            "--sign-as",
            "svc@p.iam.gserviceaccount.com",
            "--reason",
            "r",
            "--wait",
            "0"
          ] ++ extra
        )
      end

      # Signing's host is the google adapter's own: implied, not listed.
      assert {_output, 2} = propose.([])

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "internal-service"))

      assert grant.signs_as == ["svc@p.iam.gserviceaccount.com"]
      assert grant.keep_minutes == 4

      # mwt grants says what MWT answers for it.
      {0, listed} = Channel.answer("grants", %{}, context.username)
      assert listed =~ "signJwt as svc@p.iam.gserviceaccount.com"

      # Proposed again before review, with a login file: it changes in place.
      assert {_output, 2} =
               propose.([
                 "--host",
                 "*.googleapis.com",
                 "--login-file",
                 "--id-token-header",
                 "X-Id-Token"
               ])

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "internal-service"))

      assert %{login: %{refresh: "1//mwt" <> _, header: "x-id-token"}} = grant.presents
      {0, listed} = Channel.answer("grants", %{}, context.username)
      assert listed =~ "GOOGLE_APPLICATION_CREDENTIALS names a Google login file"
    end

    test "a network grant, with its own DNS server and way out", context do
      assert {_output, 2} =
               mwt(context, [
                 "propose",
                 "network",
                 "--name",
                 "Staging database",
                 "--for",
                 "Postgres on the staging network",
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

      grant =
        Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == "staging-database"))

      assert %Grant{
               kind: :network,
               destinations: ["db.staging.corp:5432", "10.20.0.0/16:5432"],
               resolver: "10.8.0.1",
               anchor: "wg0",
               state: :off
             } = grant

      assert Grant.to_review?(grant)
      # An ask for it by id makes a card to review, never one that turns it on.
      assert {_output, 2} =
               mwt(context, ["request", grant.id, "--reason", "r", "--wait", "0"])

      ask = waiting(context.username, &(&1.kind == :activation and is_nil(&1.proposal)))
      assert ask.title == "Review Staging database"

      assert {:error, :bad_decision} =
               Sandbox.decide(context.username, ask.id, {:turn_on, 60, :ask})
    end

    test "at most twenty wait for review", context do
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
                 "network",
                 "--name",
                 "one more",
                 "--for",
                 "y",
                 "--destination",
                 "10.0.1.1:22",
                 "--reason",
                 "r"
               ])

      assert output =~ "Twenty of your proposals"
    end
  end
end
