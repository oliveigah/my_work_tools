defmodule MWTClientWeb.SandboxHandoffsLiveLandingTest do
  # The Handoffs page landing what you saw: never over a file of yours git
  # doesn't track, and never a revision that came after the one shown.
  # Apart from sandbox_handoffs_live_blocked_test.exs so the two run side
  # by side.
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MWTClientWeb.HandoffsLiveHelpers

  alias MWTClient.Sandbox.{Channel, HandoffRecords}

  setup {MWTClientWeb.HandoffsLiveHelpers, :project}

  test "a file git doesn't track where it would write stops it, named, as pending work does", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    File.write!(Path.join(repo, ".gitignore"), ".env\n")
    git(repo, ["add", ".gitignore"])
    git(repo, ["commit", "-q", "-m", "ignore .env"])
    File.write!(Path.join(repo, ".env"), "API_KEY=only-here\n")

    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, ".env"), "API_KEY=from-the-vm\n")
        git(tree, ["add", "-f", ".env"])
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")

    assert has_element?(
             view,
             "#handoff-preview",
             "files git doesn't track, ignored ones included, where it would write: .env"
           )

    assert has_element?(view, "#handoff-accept-button[disabled]")

    # A new branch writes nothing in your checkout.
    view |> form("#handoff-accept", accept: %{how: "branch"}) |> render_change()
    refute has_element?(view, "#handoff-accept-button[disabled]")
    assert File.read!(Path.join(repo, ".env")) == "API_KEY=only-here\n"
  end

  test "one handed off again since the page showed it doesn't land in its place", %{
    conn: conn,
    username: username,
    repo: repo,
    vm: vm
  } do
    handoff =
      hand_off(username, vm, "fix", "Fix it", fn tree ->
        File.write!(Path.join(tree, "b.txt"), "from the vm\n")
      end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/handoffs?id=#{handoff.id}")
    assert has_element?(view, "#handoff-accept-head[value='#{handoff.head}']")
    before = git(repo, ["rev-parse", "master"])

    # Its thread hands off again while the page shows the first revision.
    tree = Path.join(vm, "app.wt/slot-1")
    File.write!(Path.join(tree, "c.txt"), "more\n")
    git(tree, ["add", "c.txt"])
    git(tree, ["commit", "-q", "-m", "more"])

    {0, _} =
      Channel.answer(
        "handoff",
        %{"cwd" => tree, "title" => "Fix it", "agent" => "claude"},
        username
      )

    view |> form("#handoff-accept") |> render_submit(%{accept: %{head: handoff.head}})
    assert has_element?(view, "#notices", "Nothing landed")
    assert has_element?(view, "#notices", "revision 2 waits now, and nothing landed")
    assert git(repo, ["rev-parse", "master"]) == before

    # The page shows revision 2 now; that one lands.
    {:ok, revised} = HandoffRecords.get(username, handoff.id)
    assert has_element?(view, "#handoff-accept-head[value='#{revised.head}']")
    view |> form("#handoff-accept") |> render_submit()
    assert has_element?(view, "#handoff-decision-state", "Landed")
    assert git(repo, ["rev-parse", "master"]) == revised.head <> "\n"
  end
end
