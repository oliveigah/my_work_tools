defmodule MWTClientWeb.SandboxTerminalLiveTest do
  @moduledoc """
  The Overview's terminal, here over a folder standing in for the VM: a
  line typed runs where the last one ended, its output and how it ended
  show under its prompt, the Live Test lists the same runs, and Clear (or
  `clear`) empties the screen and nothing else.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.Guest

  @moduletag :tmp_dir

  setup %{conn: conn} do
    sign_in(conn, "terminal-live")
  end

  defp type(view, command) do
    view |> element("#terminal-form") |> render_submit(%{command: command})
    render_async(view)
  end

  test "with the VM stopped, its line says so and takes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#terminal-input[disabled]")
    assert has_element?(view, "#terminal-where", "Runs on VM")
  end

  test "a line runs where the last one ended, and shows under its prompt",
       %{conn: conn, username: username, tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "app"))
    MWTClient.StandIns.put_guest(username, Guest.local(dir))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")

    refute has_element?(view, "#terminal-input[disabled]")
    assert has_element?(view, "#terminal-form label", "vm:/work$")

    # Guest.local stands in for the VM: /work is the folder it runs in.
    type(view, "cd #{dir}/app && printf '\\033[32mgreen\\033[0m\\n'; exit 3")

    assert has_element?(
             view,
             "#terminal-screen [id^=terminal-output-] span.text-ok-strong",
             "green"
           )

    assert has_element?(view, "#terminal-screen", "exit 3")
    assert has_element?(view, "#terminal-form label", "vm:#{dir}/app$")

    type(view, "pwd")
    assert has_element?(view, "#terminal-screen [id^=terminal-output-]", "#{dir}/app")

    # Left and back: the terminal is where you left it.
    {:ok, again, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(again, "#terminal-form label", "vm:#{dir}/app$")

    # The Live Test lists the same runs.
    {:ok, live_test, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")
    assert has_element?(live_test, "#console-runs", "pwd")
  end

  test "Clear, or clear, empties the screen; the runs stay for ↑ and the Live Test",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")

    type(view, "echo first")
    assert has_element?(view, "#terminal-screen", "first")

    type(view, "clear")
    refute has_element?(view, "#terminal-screen [id^=terminal-run-]")
    assert has_element?(view, "#terminal[data-recall*=first]")

    type(view, "echo second")
    view |> element("#terminal-clear") |> render_click()
    refute has_element?(view, "#terminal-screen [id^=terminal-run-]")
  end
end
