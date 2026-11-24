defmodule MWTClient.Sandbox.EventDetailsTest do
  @moduledoc """
  What an event of the activity log says when opened: one shape, its
  premises held where details are made (`EventDetails.new/1`), and what
  each kind's builder writes.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MWTClient.Sandbox.{Approval, EventDetails, Grant}

  describe "new/1" do
    test "keeps only what has something to say, as showable text" do
      details =
        EventDetails.new([
          EventDetails.section("The ask", [
            {"Why", "fix the build\u202E"},
            {"Exit", 0},
            {"Nothing", nil},
            {"Empty", ""},
            {"No", false},
            {"Items", {:list, ["a", "", "b"]}},
            {"Same", {:change, "x", "x"}},
            {"Changed", {:change, nil, "on"}},
            {"Here", {:link, "GitHub", "/tools/sandbox/grants/github"}},
            {"Away", {:link, "evil", "https://evil.example"}}
          ]),
          EventDetails.section("Empty", [{"Nothing", nil}]),
          nil
        ])

      assert [%{title: "The ask", by: :mwt, rows: rows}] = details

      assert rows == [
               {"Why", {:text, "fix the build\\u{202E}"}},
               {"Exit", {:text, "0"}},
               {"Items", {:list, ["a", "b"]}},
               {"Changed", {:change, nil, "on"}},
               {"Here", {:link, "GitHub", "/tools/sandbox/grants/github"}},
               {"Away", {:text, "evil"}}
             ]
    end

    test "takes at most 16 KiB, a value cut saying how much it lost" do
      script = String.duplicate("echo hi\n", 5_000)

      # Past the budget, the rest goes: the second section has nothing left.
      assert [%{title: "Command", rows: [{"Script", {:code, kept}}]}] =
               EventDetails.new([
                 EventDetails.section("Command", [{"Script", {:code, script}}]),
                 EventDetails.section("After", [{"Exit", 0}])
               ])

      assert byte_size(kept) < 16_500
      assert kept =~ ~r/… \d+ more bytes not kept\z/
    end

    test "the agent's words stay apart" do
      assert [%{by: :agent}] = EventDetails.new([EventDetails.agent("Its words", [{"Why", "x"}])])
    end
  end

  test "changes/2 has a row per setting that reads differently, nil for none" do
    before = [{"Name", "GitHub"}, {"Hosts", {:list, ["api.github.com"]}}, {"Script", nil}]
    now = [{"Name", "GitHub"}, {"Hosts", {:list, ["api.github.com", "github.com"]}}]

    assert %{title: "What changed", rows: rows} = EventDetails.changes(before, now)
    assert rows == [{"Hosts", {:change, "api.github.com", "api.github.com, github.com"}}]
    assert EventDetails.changes(before, before) == nil
  end

  test "a builder that fails describes its failure, and says so in MWT's log" do
    log =
      capture_log(fn ->
        assert [%{title: "Not described", rows: [{"Why", {:text, why}}]}] =
                 EventDetails.safely("a test", fn -> raise "no such key" end)

        assert why =~ "no such key"
      end)

    assert log =~ "could not describe a test"
  end

  test "the word filter looks in the details, lowercased" do
    details =
      EventDetails.new([
        EventDetails.section("Command", [{"Script", {:code, "kubectl GET pods"}}])
      ])

    assert EventDetails.search_text(details) =~ "kubectl get pods"
  end

  describe "builders" do
    test "an approval: the ask, the command and how it ran, and the agent's words apart" do
      now = DateTime.utc_now()

      approval = %Approval{
        id: "ask-1",
        kind: :command,
        title: "kubectl get pods",
        script: "kubectl get pods -n prod",
        dir: "/home/me/infra",
        timeout: 60,
        agent: "Claude",
        thread: %{title: "Check the deploy", id: "t1", folder: "/work/infra"},
        reason: "to see whether the rollout finished",
        requested_at: DateTime.add(now, -30, :second),
        deadline: now,
        facts: [{"Runs as", "you"}],
        run: %{
          state: :done,
          output_to: :send,
          started_at: DateTime.add(now, -5, :second),
          finished_at: now,
          exit: 0,
          output: :redacted,
          bytes: 412,
          cut: 0,
          stopped: false,
          timed_out: false,
          error: nil
        }
      }

      details = Approval.details(approval, "you ran it")
      titles = Enum.map(details, & &1.title)

      assert titles == [
               "The ask",
               "Command",
               "How it ran",
               "What MWT worked out",
               "In the agent's words"
             ]

      rows = fn title -> details |> Enum.find(&(&1.title == title)) |> Map.fetch!(:rows) end
      assert {"Script", {:code, "kubectl get pods -n prod"}} in rows.("Command")
      assert {"Exit", {:text, "0"}} in rows.("How it ran")
      assert {"Output", {:text, "412 bytes"}} in rows.("How it ran")
      assert {"Decided", {:text, "you ran it"}} in rows.("The ask")

      assert %{by: :agent, rows: agent} =
               Enum.find(details, &(&1.title == "In the agent's words"))

      assert {"Why", {:text, "to see whether the rollout finished"}} in agent
      # What it printed is never in them.
      refute inspect(details) =~ "redacted"
    end

    test "a decided proposal, which keeps few of its keys, is still described" do
      approval = %Approval{
        id: "ask-2",
        kind: :activation,
        title: "Propose repo-view",
        requested_at: DateTime.utc_now(),
        deadline: DateTime.utc_now(),
        proposal: %{kind: :command, parent_name: "Ask to run commands", updated: false}
      }

      assert Enum.any?(Approval.details(approval, "declined"), &(&1.title == "Action proposed"))
    end

    test "a grant: as it is, never its value; an edit, before and after" do
      grant = %Grant{
        id: "github",
        name: "GitHub",
        kind: :token,
        purpose: "The GitHub API",
        hosts: ["api.github.com"],
        env: ["GH_TOKEN"],
        state: :on
      }

      [%{title: "The grant, then", rows: rows}] = Grant.details(grant)
      assert {"Grant", {:link, "GitHub", "/tools/sandbox/grants/github"}} in rows
      assert {"Hosts", {:list, ["api.github.com"]}} in rows
      assert {"State", {:text, "on, until turned off"}} in rows

      edited = %{grant | hosts: ["api.github.com", "uploads.github.com"], ceiling: :ask}

      assert [%{title: "What changed", rows: changed}] = Grant.changes(grant, edited)

      assert {"Hosts", {:change, "api.github.com", "api.github.com, uploads.github.com"}} in changed
      assert {"Always ask me", {:change, nil, "on"}} in changed
      assert Grant.changes(grant, grant) == []
    end

    test "a network grant's host list, each entry with what it does" do
      grant = %Grant{id: "internet", name: "Internet", kind: :network, internet: true}
      listed = %{grant | host_rules: [%{host: "example.com", action: :block}]}

      assert [%{rows: changed}] = Grant.changes(grant, listed)
      assert {"Host list", {:change, nil, "example.com: Block"}} in changed
    end
  end
end
