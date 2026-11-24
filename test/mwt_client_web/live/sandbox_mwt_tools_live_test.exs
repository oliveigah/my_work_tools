defmodule MWTClientWeb.SandboxMwtToolsLiveTest do
  @moduledoc "MWT's own tools for agents in the VM on the sandbox's pages: their grants, and a change's card."
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.MCP.Tools
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Notes.Note
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.MwtTools

  setup %{conn: conn} do
    sign_in(conn)
  end

  defp until(fun) do
    Enum.find_value(1..300, fn _ -> fun.() || (Process.sleep(10) && nil) end) ||
      flunk("it never happened")
  end

  test "a change an agent in the VM asks for shows as a diff, and allowing it makes it",
       %{conn: conn, username: username} do
    {:ok, note} = Notes.save(username, Note.new_id(), %{title: "Plan", body: "keep\nmine"})
    caller = MwtTools.caller(username, %{agent: "claude", thread: "Tidy the plan"})
    args = %{"id" => note.id, "version" => 1, "body" => "keep\ntheirs"}
    task = Task.async(fn -> Tools.call("update_note", args, caller) end)

    approval = until(fn -> List.first(Sandbox.snapshot(username).waiting) end)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    card = "#approval-#{approval.id}"
    assert has_element?(view, card, "Change note “Plan”")
    assert has_element?(view, card, "claude")
    assert has_element?(view, "#approval-words-#{approval.id}", "1 line in, 1 out")
    assert has_element?(view, "#approval-diff-#{approval.id}", "- mine")
    assert has_element?(view, "#approval-diff-#{approval.id}", "+ theirs")
    assert has_element?(view, "#allow-similar-#{approval.id}", "Changes to this note")

    view |> element("#allow-once-#{approval.id}") |> render_click()

    assert {:ok, %{"isError" => false}} = Task.await(task)
    assert {:ok, %{body: "keep\ntheirs"}} = Notes.get(username, note.id)
    assert has_element?(view, "#decided-#{approval.id}", "Change note “Plan”")
  end

  test "MWT's three grants are built in: shown as such, with no edit or remove",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=all")
    # MWT's own tools, all on one page of the catalog.
    view |> form("#grant-type", type: "mwt") |> render_change()

    for id <- ~w(mwt-read mwt-create mwt-change) do
      assert has_element?(view, "#grant-card-#{id}", "Built in")
    end

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/mwt-change")
    assert has_element?(view, "#grant-mwt-tools", "update_*")
    refute has_element?(view, "#edit-grant")
    refute has_element?(view, "#grant-danger")
  end

  test "the Internet is built in, says what it reaches, and asks each time only when set to",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=all")
    assert has_element?(view, "#grant-card-internet", "Built in")
    assert has_element?(view, "#grant-card-internet", "Every public address")
    assert has_element?(view, "#grant-mode-internet--ask")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/internet")
    assert has_element?(view, "#grant-internet", "Every public address on the internet")
    assert has_element?(view, "#grant-internet-off", "api.anthropic.com:443")
    assert has_element?(view, "#detail-mode-internet--ask")
    refute has_element?(view, "#edit-grant")
    refute has_element?(view, "#grant-danger")
  end
end
