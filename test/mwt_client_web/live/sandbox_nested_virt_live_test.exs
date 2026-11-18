defmodule MWTClientWeb.SandboxNestedVirtLiveTest do
  # Not async: one test points MWT at a machine that doesn't allow nesting,
  # through the application env.
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.NestedVirtHelpers
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.NestedVirt

  setup %{conn: conn} do
    sign_in(conn)
  end

  test "VMs inside the VM: off until turned on, after a warning", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    assert has_element?(view, "#nested-virt-false[aria-checked=true]")
    assert has_element?(view, "#nested-virt-host", "This machine allows it.")
    # Switching on asks first; switching back off doesn't.
    assert has_element?(view, "#nested-virt-true[data-confirm*='escapes']")

    view |> element("#nested-virt-true") |> render_click()

    assert has_element?(view, "#notices", "VMs inside the VM turned on")
    assert has_element?(view, "#nested-virt-true[aria-checked=true]")
    assert Sandbox.snapshot(username).settings.nested_virt

    refute has_element?(view, "#nested-virt-false[data-confirm]")
    view |> element("#nested-virt-false") |> render_click()
    refute Sandbox.snapshot(username).settings.nested_virt
  end

  test "where this machine doesn't allow it, there is no On, only how to allow it", %{
    conn: conn,
    username: username
  } do
    root = Path.join(System.tmp_dir!(), "nested-virt-live-#{System.unique_integer([:positive])}")
    saved = Application.get_env(:mwt_client, NestedVirt)

    on_exit(fn ->
      Application.put_env(:mwt_client, NestedVirt, saved)
      File.rm_rf!(root)
    end)

    Application.put_env(:mwt_client, NestedVirt, root: NestedVirtHelpers.fake_host!(root, :off))

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    refute has_element?(view, "#nested-virt")
    assert has_element?(view, "#nested-virt-host", "loaded without nesting")
    assert has_element?(view, "#nested-virt-enable", "options kvm_amd nested=1")

    # A VM that has it on can still turn it off.
    assert {:ok, _} = Sandbox.update_settings(username, %{"nested_virt" => "true"})
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    assert has_element?(view, "#nested-virt-false")
  end
end
