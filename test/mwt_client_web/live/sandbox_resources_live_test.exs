defmodule MWTClientWeb.SandboxResourcesLiveTest do
  @moduledoc """
  Resources on the Grants page: added and edited on their own from the
  Resources tab, each with a page of its own that lists the grants over
  it, adds one, locks it, and removes it with them.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox

  setup %{conn: conn} do
    sign_in(conn, "resources-live")
  end

  test "a credential is added on its own, edited, given a grant from its page, and removed with it",
       %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=resources")
    assert has_element?(view, "#resources-credentials-empty")

    view |> element("#add-credential") |> render_click()
    assert has_element?(view, "#resource-dialog", "Add a credential")

    # A pasted value is needed.
    view
    |> form("#resource-form", resource: %{name: "GitHub personal", purpose: "gh, as me"})
    |> render_submit()

    assert has_element?(view, "#resource-error-value")

    view
    |> form("#resource-form",
      resource: %{
        name: "GitHub personal",
        purpose: "gh, as me",
        value: "ghp_real-value",
        env: "GH_TOKEN"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/tools/sandbox/resources/credential/github-personal")
    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/credential/github-personal")
    assert has_element?(page, "#resource-name", "GitHub personal")
    assert has_element?(page, "#credential-source", "Stored in your vault")
    assert has_element?(page, "#resource-grants-empty")
    refute render(page) =~ "ghp_real-value"

    assert [%{id: "github-personal", env: ["GH_TOKEN"]}] = Sandbox.snapshot(username).credentials
    assert %{"github-personal" => true} = Sandbox.snapshot(username).credential_values

    # Edited: its id and placeholder stay.
    [before] = Sandbox.snapshot(username).credentials
    page |> element("#edit-resource") |> render_click()

    page
    |> form("#resource-form", resource: %{name: "GitHub (me)", purpose: "gh, as me"})
    |> render_submit()

    assert [%{id: "github-personal", name: "GitHub (me)", placeholder: placeholder}] =
             Sandbox.snapshot(username).credentials

    assert placeholder == before.placeholder

    # A grant over it, from its page: the credential comes chosen.
    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/credential/github-personal")
    page |> element("#add-grant-over") |> render_click()
    assert has_element?(page, "#add-grant-title", "Add a grant over GitHub (me)")
    assert has_element?(page, "#grant-credential option[value=github-personal][selected]")

    page
    |> form("#add-grant-form",
      grant: %{name: "GitHub API", purpose: "The API", hosts: "api.github.com"}
    )
    |> render_submit()

    assert %{credential: "github-personal", state: :off} =
             Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "github-api"))

    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/credential/github-personal")
    assert has_element?(page, "#resource-grants #resource-row-github-api")

    # Removed, with every grant over it and its value.
    page |> element("#delete-resource") |> render_click()
    assert has_element?(page, "#sandbox-confirm", "1 grant")
    page |> element("#sandbox-confirm-accept") |> render_click()
    assert_patch(page, ~p"/tools/sandbox/grants?tab=resources")

    snapshot = Sandbox.snapshot(username)
    assert snapshot.credentials == []
    refute Enum.any?(snapshot.grants, &(&1.id == "github-api"))
  end

  test "a network is added on its own; grants over all of it or some hosts; locked from its page",
       %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=resources")
    view |> element("#add-network") |> render_click()

    view
    |> form("#resource-form",
      resource: %{
        name: "Prod VPN",
        purpose: "Production, through the VPN",
        destinations: "10.20.0.0/16\ndb.prod.corp:5432",
        anchor: "wg0"
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/tools/sandbox/resources/network/prod-vpn")

    assert %{destinations: ["10.20.0.0/16", "db.prod.corp:5432"], anchor: "wg0"} =
             Enum.find(Sandbox.snapshot(username).networks, &(&1.id == "prod-vpn"))

    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/network/prod-vpn")
    assert has_element?(page, "#network-destinations", "db.prod.corp:5432")
    assert has_element?(page, "#resource-limits")

    # Over part of it: the hosts its form lists.
    page |> element("#add-grant-over") |> render_click()

    page
    |> form("#add-grant-form",
      grant: %{name: "Prod database", purpose: "Read prod", destinations: "db.prod.corp:5432"}
    )
    |> render_submit()

    # Over all of it: none listed.
    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/network/prod-vpn")
    page |> element("#add-grant-over") |> render_click()

    page
    |> form("#add-grant-form",
      grant: %{name: "All of prod", purpose: "Everything", destinations: ""}
    )
    |> render_submit()

    grants = Sandbox.snapshot(username).grants

    assert %{network: "prod-vpn", scope: ["db.prod.corp:5432"], anchor: "wg0"} =
             Enum.find(grants, &(&1.id == "prod-database"))

    assert %{network: "prod-vpn", scope: nil, destinations: ["10.20.0.0/16", "db.prod.corp:5432"]} =
             Enum.find(grants, &(&1.id == "all-of-prod"))

    # Locked from its page: the On now tab says so, and links to it.
    {:ok, page, _html} = live(conn, ~p"/tools/sandbox/resources/network/prod-vpn")
    assert has_element?(page, "#lock-network-prod-vpn-open", "Open")
    page |> element("#lock-network-prod-vpn") |> render_click()
    assert has_element?(page, "#lock-network-prod-vpn-locked", "Locked")
    assert Map.has_key?(Sandbox.snapshot(username).locks, {:network, "prod-vpn"})

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants")

    assert has_element?(
             view,
             "#grants-locked a[href='/tools/sandbox/resources/network/prod-vpn']",
             "Prod VPN"
           )
  end

  test "a grant's page and row name the resource it is over, as a link", %{
    conn: conn,
    username: username
  } do
    {:ok, network} =
      Sandbox.create_resource(username, :network, %{
        "name" => "Office LAN",
        "purpose" => "The office",
        "destinations" => "192.168.10.0/24"
      })

    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "network",
        "name" => "Office printers",
        "purpose" => "Print",
        "network" => network.id,
        "destinations" => "192.168.10.50"
      })

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/office-printers")

    assert has_element?(
             view,
             "#grant-crumbs #grant-resource[href='/tools/sandbox/resources/network/office-lan']",
             "Office LAN"
           )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=all")
    view |> form("#grant-search", term: "printers") |> render_change()

    assert has_element?(
             view,
             "#grant-card-office-printers #grant-over-office-printers",
             "Office LAN"
           )
  end
end
