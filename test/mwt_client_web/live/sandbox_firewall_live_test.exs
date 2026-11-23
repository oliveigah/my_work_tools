defmodule MWTClientWeb.SandboxFirewallLiveTest do
  @moduledoc """
  The Firewall page: the VM isolated switch (the firewall's and yours),
  releasing, rules by group, lists, the banner.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  @moduletag :capture_log

  setup %{conn: conn} do
    sign_in(conn)
  end

  # Something that isolates the VM: a placeholder sent where its grant doesn't go.
  defp isolate(username) do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "value" => "ghp_real_value"
      })

    {:ok, grant} = Sandbox.turn_on(username, grant.id, 60, :all)

    {:deny, 403, _} =
      Server.call(
        username,
        {:authorize,
         %{
           host: "paste.example.net",
           method: "POST",
           path: "/",
           headers: [{"authorization", "token #{grant.placeholder}"}],
           body: ""
         }}
      )
  end

  test "the rules, their actions and the lists", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")

    assert has_element?(view, "#sandbox-nav-firewall[aria-current=page]")
    assert has_element?(view, "#firewall-isolated[aria-checked=false]")
    assert has_element?(view, "#firewall-group-credentials #firewall-rule-credential_leak")
    assert has_element?(view, "#firewall-action-credential_leak-isolate[aria-checked=true]")
    # An action a rule can't take is shown, not offered.
    assert has_element?(view, "#firewall-action-cpu_hog-block[aria-disabled=true]")
    refute has_element?(view, "#firewall-action-cpu_hog-block[role=radio]")
    refute has_element?(view, "#firewall-incidents")
    assert has_element?(view, "#firewall-findings-empty")

    # Every list has its tab, and its form on the page.
    for list <- MWTClient.Sandbox.Firewall.lists() do
      assert has_element?(view, "#firewall-list-tab-#{list}")
      assert has_element?(view, "#firewall-list-form-#{list}")
    end

    view |> element("#firewall-action-dns_bypass-alert") |> render_click()
    assert has_element?(view, "#firewall-action-dns_bypass-alert[aria-checked=true]")

    assert MWTClient.Sandbox.Firewall.action(Sandbox.firewall(username).firewall, :dns_bypass) ==
             :alert

    # A list that doesn't read keeps what you wrote and says which line.
    view
    |> form("#firewall-list-form-trusted", firewall_list: %{text: "ok.example\nnot a name"})
    |> render_submit()

    assert has_element?(view, "#firewall-list-error-trusted", "Line 2")
    assert has_element?(view, "#firewall-list-text-trusted", "not a name")

    view
    |> form("#firewall-list-form-trusted", firewall_list: %{text: "ok.example"})
    |> render_submit()

    refute has_element?(view, "#firewall-list-error-trusted")
    assert Sandbox.firewall(username).firewall.trusted == ["ok.example"]

    view |> element("#firewall-list-reset-trusted") |> render_click()
    assert "*.anthropic.com" in Sandbox.firewall(username).firewall.trusted

    view |> element("#firewall-enabled-false") |> render_click()
    assert has_element?(view, "#firewall-off")
  end

  test "isolated by the firewall: the banner on every page, the switch on, and releasing asks first",
       %{conn: conn, username: username} do
    isolate(username)

    {:ok, overview, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(overview, "#firewall-banner", "paste.example.net")
    assert has_element?(overview, "#sandbox-nav-isolated")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")
    refute has_element?(view, "#firewall-banner")
    assert has_element?(view, "#firewall-isolated[aria-checked=true]")
    assert has_element?(view, "#firewall-isolation-title", "Credential sent elsewhere")
    assert has_element?(view, "#firewall-incident-summary", "paste.example.net")
    assert has_element?(view, "#firewall-incident-events")
    assert has_element?(view, "#firewall-restorable", "GitHub")

    # Turning the switch off asks first, saying what the firewall saw.
    view |> element("#firewall-isolated") |> render_click()
    assert has_element?(view, "#firewall-release-dialog")
    assert has_element?(view, "#firewall-release-summary", "paste.example.net")
    assert has_element?(view, "#firewall-release-trust", "paste.example.net")
    assert Sandbox.firewall(username).firewall.isolated

    # Kept isolated.
    view |> element("#firewall-release-cancel") |> render_click()
    refute has_element?(view, "#firewall-release-dialog")
    assert has_element?(view, "#firewall-isolated[aria-checked=true]")
    assert Sandbox.firewall(username).firewall.isolated

    # Released, trusting the destination.
    view |> element("#firewall-isolated") |> render_click()
    view |> form("#firewall-release-form", release: %{trust: "true"}) |> render_submit()
    refute has_element?(view, "#firewall-release-dialog")
    assert has_element?(view, "#firewall-isolated[aria-checked=false]")
    refute has_element?(view, "#sandbox-nav-isolated")
    assert "paste.example.net" in Sandbox.firewall(username).firewall.trusted
    assert has_element?(view, "#firewall-incidents", "1 past isolation")
    assert %{state: :on} = Enum.find(Sandbox.snapshot(username).grants, &(&1.name == "GitHub"))
  end

  test "the switch isolates the VM, and releases your own isolation without asking",
       %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")

    view |> element("#firewall-isolated") |> render_click()
    assert has_element?(view, "#firewall-isolated[aria-checked=true]")
    assert has_element?(view, "#firewall-isolation-title", "VM isolated by you")
    refute has_element?(view, "#firewall-incident-summary")
    assert has_element?(view, "#sandbox-nav-isolated")
    assert %{by: :you} = Sandbox.firewall(username).firewall.isolated

    {:ok, overview, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(overview, "#firewall-banner", "You isolated the VM")

    view |> element("#firewall-isolated") |> render_click()
    refute has_element?(view, "#firewall-release-dialog")
    assert has_element?(view, "#firewall-isolated[aria-checked=false]")
    refute Sandbox.firewall(username).firewall.isolated
    assert has_element?(view, "#firewall-incidents", "by you")
  end

  test "releasing a large upload offers to trust the name it saw, not its domain",
       %{conn: conn, username: username} do
    model = "us-east5-aiplatform.googleapis.com"
    :cut = MWTClient.Sandbox.Gate.upload(username, model, 443, 5 * 1024 * 1024, 0)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/firewall")
    assert has_element?(view, "#firewall-findings", model)

    view |> element("#firewall-isolated") |> render_click()
    assert has_element?(view, "#firewall-release-trust", "Trust #{model} from now on")

    view |> form("#firewall-release-form", release: %{trust: "true"}) |> render_submit()
    trusted = Sandbox.firewall(username).firewall.trusted
    assert model in trusted
    refute "googleapis.com" in trusted
  end

  test "the activity page opens on the firewall's group", %{conn: conn, username: username} do
    isolate(username)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/activity?group=firewall")
    assert render(view) =~ "VM isolated"
  end
end
