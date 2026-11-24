defmodule MWTClient.Sandbox.NoticesTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Approval, Grant, Handoff, Notices}

  @now ~U[2026-11-13 12:00:00Z]
  @grant %Grant{id: "github", name: "GitHub", kind: :token}

  defp approval(attrs) do
    struct!(
      Approval,
      Map.merge(
        %{
          id: "ask-1",
          title: "Turn on GitHub",
          requested_at: @now,
          deadline: DateTime.add(@now, 30 * 60)
        },
        attrs
      )
    )
  end

  test "an ask for a grant names the agent and the grant, and quotes its reason" do
    ask = approval(%{kind: :activation, agent: "claude", minutes: 30, reason: "push the fix"})

    assert Notices.approval(ask, @grant, @now) == %{
             summary: "Claude asks to turn on GitHub",
             body: "For 30 min\nReason: “push the fix”\nGives up in 30 min unless you decide.",
             kind: "sandbox.approvals",
             open: "/tools/sandbox/approvals?focus=ask-1"
           }
  end

  test "an ask from a thread says which, with your home folder as ~" do
    home = System.user_home!()

    ask =
      approval(%{
        kind: :activation,
        agent: "claude",
        minutes: 30,
        reason: "push the fix",
        thread: %{title: "Fix the push flow", id: "f4cb1da2-43", folder: home <> "/projects/mwt"}
      })

    assert Notices.approval(ask, @grant, @now).body ==
             "From “Fix the push flow” in ~/projects/mwt\nFor 30 min\nReason: “push the fix”\nGives up in 30 min unless you decide."

    untitled = %{ask | thread: %{title: nil, id: "f4cb1da2-43", folder: nil}}
    assert Notices.approval(untitled, @grant, @now).body =~ ~r/^From thread f4cb1da2\n/
  end

  test "an ask no grant meets says what it needs" do
    ask =
      approval(%{
        kind: :activation,
        agent: "An agent",
        need: "Postgres on 10.0.0.5",
        reason: "migrate"
      })

    notice = Notices.approval(ask, nil, @now)
    assert notice.summary == "An agent asks for access you haven't set up"
    assert notice.body =~ "Postgres on 10.0.0.5\nReason: “migrate”"
  end

  test "a held request and a connection say which grant, and what" do
    request =
      approval(%{
        id: "approval-9",
        kind: :request,
        title: "Push to oliveigah/klife",
        deadline: DateTime.add(@now, 179)
      })

    assert %{summary: "An agent wants to use GitHub", body: body, open: open} =
             Notices.approval(request, @grant, @now)

    assert body == "Push to oliveigah/klife\nGives up in 3 min unless you decide."
    assert open == "/tools/sandbox/approvals?focus=approval-9"

    connection =
      approval(%{kind: :connection, pattern: "10.0.0.5:5432", deadline: DateTime.add(@now, 45)})

    vpn = %Grant{id: "vpn", name: "Office VPN", kind: :network}

    assert %{summary: "An agent wants to connect through Office VPN", body: body} =
             Notices.approval(connection, vpn, @now)

    assert body == "10.0.0.5:5432\nGives up in 45 s unless you decide."
  end

  test "a command shows its first line; its output, how it ended" do
    run =
      approval(%{
        id: "run-1",
        kind: :command,
        agent: "codex",
        script: "mix test\nmix format",
        reason: "check it on the host"
      })

    assert %{summary: "Codex asks to run a command it wrote, on this machine", body: body} =
             Notices.approval(run, nil, @now)

    assert body =~ "mix test (+1 lines)\nReason: “check it on the host”"

    # Your own script says whose it is, and not its text.
    saved = %{run | script_from: :grant, grant_id: "tests"}
    grant = %MWTClient.Sandbox.Grant{id: "tests", name: "Run the tests", kind: :command}

    assert %{summary: "Codex calls your action Run the tests", body: body} =
             Notices.approval(saved, grant, @now)

    refute body =~ "mix test"
    assert body =~ "Reason: “check it on the host”"

    output = %{run | stage: :output, run: %{exit: 1, timed_out: false, stopped: false}}

    assert %{summary: "A command's output waits for you", body: body} =
             Notices.approval(output, nil, @now)

    assert body =~ "mix test (+1 lines)\nExit 1"
  end

  test "a handoff says who handed what off, onto which branch, and its size" do
    at = ~U[2026-11-14 10:00:00Z]

    handoff = %Handoff{
      id: 7,
      title: "Fix the login",
      agent: "claude",
      thread: "Login thread",
      project: "app",
      repo: "/home/ana/app",
      onto: "main",
      source: %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "fix"},
      head: "abc",
      opened_at: at,
      updated_at: at,
      stats: %{commits: 2, files: 1, added: 10, removed: 3},
      timeline: [%{at: at, kind: :opened, text: "claude handed it off"}]
    }

    assert Notices.handoff(handoff) == %{
             kind: "sandbox.handoffs",
             summary: "Claude handed off #7: Fix the login",
             body: "From Login thread\napp: fix, based on main\n2 commits, 1 file (+10 −3)",
             open: "/tools/sandbox/handoffs?id=7"
           }

    later = %{
      handoff
      | timeline: handoff.timeline ++ [%{at: at, kind: :updated, text: "updated"}],
        thread: nil,
        agent: nil
    }

    assert %{summary: "An agent updated #7: Fix the login", body: "app: fix" <> _} =
             Notices.handoff(later)
  end
end
