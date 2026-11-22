defmodule MWTClientWeb.SandboxSettingsSizeTest do
  @moduledoc """
  The size and timing form: what it suggests for this machine, the most it
  takes, and that nothing is kept before Save.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Resources

  setup %{conn: conn} do
    host = Resources.host()

    conn
    |> sign_in()
    |> Map.merge(%{suggested: Resources.suggested(host), most: Resources.most(host)})
  end

  test "a new VM starts with what MWT suggests for this machine", %{
    username: username,
    suggested: suggested
  } do
    settings = Sandbox.snapshot(username).settings
    assert %{cpus: settings.cpus, memory_gib: settings.memory_gib} == suggested
  end

  test "every setting says what it is and when a change applies", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    for field <- MWTClientWeb.SandboxLive.Settings.vm_fields() do
      assert has_element?(view, "#vm_#{field}-help")
    end

    assert has_element?(view, "#vm_cpus-help", "A change applies when the VM is recreated.")
    assert has_element?(view, "#vm_home_gib-help", "A change applies when the VM next starts.")
    assert has_element?(view, "#vm_hold_seconds-help", "A change applies to the next request.")
    assert has_element?(view, "#vm_log_body_kib-help", "A change applies to the next request.")
  end

  test "how much of each body the log keeps: 64 KiB at first, 0 to 1024", %{
    conn: conn,
    username: username
  } do
    assert Sandbox.snapshot(username).settings.log_body_kib == 64
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    assert has_element?(view, "#vm_log_body_kib[value='64']")

    assert {:error, %{log_body_kib: _}} =
             Sandbox.update_settings(username, %{"log_body_kib" => "2048"})

    assert {:ok, %{log_body_kib: 0}} = Sandbox.update_settings(username, %{"log_body_kib" => "0"})
    assert MWTClient.Sandbox.Gate.body_limit(username) == 0
  end

  test "Use suggested fills the form, and only Save keeps it", %{
    conn: conn,
    username: username,
    suggested: suggested
  } do
    {:ok, _} = Sandbox.update_settings(username, %{"cpus" => "1", "memory_gib" => "1"})
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")

    assert has_element?(view, "#vm-form-state", "Saved")
    assert has_element?(view, "#vm-save[disabled]")

    view |> element("#vm-use-suggested") |> render_click()
    assert has_element?(view, "#vm_cpus[value='#{suggested.cpus}']")
    assert has_element?(view, "#vm_memory_gib[value='#{suggested.memory_gib}']")
    assert has_element?(view, "#vm-on-suggestion")
    assert has_element?(view, "#vm-form-state", "Unsaved changes")
    assert Sandbox.snapshot(username).settings.cpus == 1

    view |> form("#vm-form") |> render_submit()
    settings = Sandbox.snapshot(username).settings
    assert {settings.cpus, settings.memory_gib} == {suggested.cpus, suggested.memory_gib}
    assert has_element?(view, "#vm-form-state", "Saved")
  end

  test "Discard puts the saved values back", %{conn: conn, username: username} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    view |> form("#vm-form", vm: %{disk_gib: "99"}) |> render_change()
    assert has_element?(view, "#vm-form-state", "Unsaved changes")

    view |> element("#vm-reset") |> render_click()
    disk = Sandbox.snapshot(username).settings.disk_gib
    assert has_element?(view, "#vm_disk_gib[value='#{disk}']")
    assert has_element?(view, "#vm-form-state", "Saved")
  end

  test "the meters follow what you type, and warn past the suggestion", %{
    conn: conn,
    suggested: suggested,
    most: most
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    host = Resources.host()

    view |> form("#vm-form", vm: %{cpus: "1"}) |> render_change()
    assert has_element?(view, "#vm-cpus-share-left", "#{host.cores - 1}")
    refute has_element?(view, "#vm-cpus-share-over")

    if most.cpus > suggested.cpus do
      view |> form("#vm-form", vm: %{cpus: "#{most.cpus}"}) |> render_change()
      assert has_element?(view, "#vm-cpus-share-over")
    end
  end

  test "more than this machine can give is refused", %{
    conn: conn,
    username: username,
    most: most
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings")
    before = Sandbox.snapshot(username).settings

    view
    |> form("#vm-form", vm: %{memory_gib: "#{most.memory_gib + 1}"})
    |> render_submit()

    assert has_element?(
             view,
             "#vm_memory_gib-error",
             "Enter a whole number from 1 to #{most.memory_gib}."
           )

    assert Sandbox.snapshot(username).settings.memory_gib == before.memory_gib
  end
end
