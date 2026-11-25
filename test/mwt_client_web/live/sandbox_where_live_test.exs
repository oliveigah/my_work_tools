defmodule MWTClientWeb.SandboxWhereLiveTest do
  @moduledoc """
  Every grant says its kind, by who builds what it lets through: open use
  (the agent) or a fixed call (MWT). Where something runs is said only of
  commands on your machine ("Runs on host"): a saved command, and Commands
  agents write. A request goes through a network, whoever built it.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn, "where-live")
  end

  defp github(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "Push to oliveigah/klife",
        "hosts" => "api.github.com, github.com",
        "env" => "GH_TOKEN",
        "prefix" => "ghp_",
        "value" => "ghp_real"
      })

    grant
  end

  defp waiting(username, kind) do
    Enum.find_value(1..100, fn _ ->
      case Enum.find(Sandbox.snapshot(username).waiting, &(&1.kind == kind)) do
        nil -> Process.sleep(10) && nil
        approval -> approval
      end
    end)
  end

  test "every grant says its kind; only a command on your machine says where it runs",
       %{conn: conn, username: username} do
    grant = github(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")
    view |> form("#grant-filters", %{status: "all"}) |> render_change()

    for {id, kind} <- [
          {grant.id, "Open use"},
          {"internet", "Open use"},
          {"agent-commands", "Open use"},
          {"mwt-read", "Fixed call"}
        ] do
      assert has_element?(view, "#grant-kind-#{id}", kind)
    end

    assert has_element?(view, "#grant-where-agent-commands", "Runs on host")

    for id <- [grant.id, "internet", "mwt-read"],
        do: refute(has_element?(view, "#grant-where-#{id}"))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")
    assert has_element?(view, "#detail-kind", "Open use")
    refute has_element?(view, "#detail-where")
    assert has_element?(view, "#grant-kind-use", "mwt exec")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/agent-commands")
    assert has_element?(view, "#detail-kind", "Open use")
    assert has_element?(view, "#detail-where", "Runs on host")
    assert has_element?(view, "#grant-always-asks")

    for id <- ~w(mwt-read internet) do
      {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{id}")
      refute has_element?(view, "#detail-where")
      assert has_element?(view, "#detail-kind")
      assert has_element?(view, "#grant-kind-use")
    end
  end

  test "a grant whose requests no network grant lets out says so, as an error",
       %{conn: conn, username: username} do
    grant = github(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")
    refute has_element?(view, "#grant-unreached")

    # The Internet's grant off: the agent's own requests can't leave, and
    # nor could a fixed call's.
    {:ok, _} = Sandbox.turn_off(username, "internet")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")
    assert has_element?(view, "#grant-unreached", "api.github.com, which Internet would let out")
  end

  test "a request an agent's tool sent waits on a card that says nothing of where it runs",
       %{conn: conn, username: username} do
    grant = github(username)
    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)

    request = %{
      host: "api.github.com",
      method: "GET",
      path: "/user",
      headers: [{"host", "api.github.com"}, {"authorization", "token #{grant.placeholder}"}],
      body: ""
    }

    task = Task.async(fn -> Server.call(username, {:authorize, request}, :infinity) end)
    approval = waiting(username, :request)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-#{approval.id}")
    refute has_element?(view, "#approval-where-#{approval.id}")

    :ok = Sandbox.decide(username, approval.id, :deny)
    Task.await(task)
  end

  test "a saved command's card says nothing of where it runs: the host is its resource",
       %{conn: conn, username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "say",
        "purpose" => "Says a word",
        "script" => ~s(echo "$WORD"),
        "params" => "WORD: word: what to say",
        "dir" => System.tmp_dir!()
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :ask)

    {:ok, approval} =
      Server.call(
        username,
        {:request_command,
         %{grant: "say", script: nil, values: %{"WORD" => "hello"}, reason: "try it"}}
      )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-#{approval.id}")
    refute has_element?(view, "#approval-where-#{approval.id}")
  end

  test "an ask for a grant over a credential says its kind, and nothing of where",
       %{conn: conn, username: username} do
    grant = github(username)

    asking =
      Task.async(fn ->
        {:ok, ask} =
          Server.call(username, {:request_access, %{grant: grant.id, reason: "push the fix"}})

        Server.call(username, {:await, ask.id, 5_000}, 6_000)
      end)

    ask = waiting(username, :activation)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-kind-badge-#{ask.id}", "Open use")
    refute has_element?(view, "#approval-where-#{ask.id}")

    :ok = Sandbox.decide(username, ask.id, :decline)
    Task.await(asking)
  end

  test "an ask for a fixed request says it is a fixed call; one for a saved command, where it runs",
       %{conn: conn, username: username} do
    github(username)

    {:ok, action} =
      Sandbox.create_grant(username, %{
        "kind" => "request",
        "preset" => "request_action",
        "credential" => "github",
        "name" => "pr view",
        "purpose" => "Shows a pull request",
        "method" => "GET",
        "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
        "headers" => "Authorization: Bearer {token}",
        "params" => "REPO: word: the repository\nPR: number: the pull request"
      })

    asking =
      Task.async(fn ->
        {:ok, ask} =
          Server.call(username, {:request_access, %{grant: action.id, reason: "read the PR"}})

        Server.call(username, {:await, ask.id, 5_000}, 6_000)
      end)

    ask = waiting(username, :activation)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-kind-badge-#{ask.id}", "Fixed call")
    refute has_element?(view, "#approval-where-#{ask.id}")

    :ok = Sandbox.decide(username, ask.id, :decline)
    Task.await(asking)

    {:ok, say} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "say",
        "purpose" => "Says a word",
        "script" => "echo hi",
        "dir" => System.tmp_dir!()
      })

    asking =
      Task.async(fn ->
        {:ok, ask} = Server.call(username, {:request_access, %{grant: say.id, reason: "say it"}})
        Server.call(username, {:await, ask.id, 5_000}, 6_000)
      end)

    ask = waiting(username, :activation)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-kind-badge-#{ask.id}", "Fixed call")
    assert has_element?(view, "#approval-where-#{ask.id}", "Runs on host")

    :ok = Sandbox.decide(username, ask.id, :decline)
    Task.await(asking)
  end
end
