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
    server = MWTClient.Vault.Store.whereis(Sandbox.Server, username)
    :sys.replace_state(server, &%{&1 | vm: %{&1.vm | exists?: true}})
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    assert has_element?(view, "#nested-virt option[value=false][selected]")
    assert has_element?(view, "#timeline-recording option[value=false][selected]")
    assert has_element?(view, "#nested-virt-host", "This machine allows it.")
    refute has_element?(view, "#features-recreate-required")

    view |> form("#features-form", features: %{timeline_recording: "true"}) |> render_change()
    refute has_element?(view, "#features-recreate-required")
    refute Sandbox.snapshot(username).settings.timeline_recording

    view
    |> form("#features-form", features: %{nested_virt: "true", timeline_recording: "true"})
    |> render_change()

    assert has_element?(view, "#features-recreate-required", "requires recreation")
    assert has_element?(view, "#features-apply[data-confirm*='escapes']")
    refute Sandbox.snapshot(username).settings.nested_virt
    refute Sandbox.snapshot(username).settings.timeline_recording

    view
    |> form("#features-form", features: %{nested_virt: "true", timeline_recording: "true"})
    |> render_submit()

    assert has_element?(view, "#notices", "Recreate the VM")
    assert has_element?(view, "#nested-virt option[value=true][selected]")
    assert Sandbox.snapshot(username).settings.nested_virt
    assert Sandbox.snapshot(username).settings.timeline_recording

    view |> form("#features-form", features: %{nested_virt: "false"}) |> render_change()
    assert has_element?(view, "#features-recreate-required")
    refute has_element?(view, "#features-apply[data-confirm]")
    view |> form("#features-form", features: %{nested_virt: "false"}) |> render_submit()
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
    assert has_element?(view, "#nested-virt option[value=false]")
  end
end
