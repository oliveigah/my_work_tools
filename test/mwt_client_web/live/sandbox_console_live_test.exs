defmodule MWTClientWeb.SandboxConsoleLiveTest do
  @moduledoc """
  The console on the Grants page: a command run in the VM, here a folder
  standing in for it, with what it printed, its exit status and the run
  in the activity log; the runs kept in its history, paged, searched and
  run again; an HTTP request as the command that sends it; a real value
  refused before anything runs.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Guest

  @moduletag :tmp_dir

  # A run is a real shell, which a loaded run can make take more than the
  # second `render_async/1` waits by default.
  @run_within 10_000

  setup %{conn: conn} do
    sign_in(conn, "console-live")
  end

  test "with the VM stopped, nothing runs; what runs, runs on the VM", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")
    assert has_element?(view, "#console-vm-stopped")
    assert has_element?(view, "#console-run[disabled]")
    assert has_element?(view, "#console-where", "Runs on VM")
  end

  test "a command runs as the VM: its output and errors, its exit status, and a line in the log",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")
    refute has_element?(view, "#console-vm-stopped")

    view
    |> form("#console-form", console: %{command: "echo hello; echo oops >&2; exit 2"})
    |> render_submit()

    render_async(view, @run_within)
    assert has_element?(view, "#console-runs [id^=console-output-text-]", "hello")
    assert has_element?(view, "#console-runs [id^=console-output-text-]", "oops")
    assert has_element?(view, "#console-runs", "exit 2")

    assert Enum.any?(
             Sandbox.events(username, %{limit: 20}),
             &(&1.summary =~ "You ran in the VM: echo hello")
           )
  end

  test "an HTTP request runs as the curl command it shows, speaking as a credential",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))

    {:ok, _credential} =
      Sandbox.create_resource(username, :credential, %{
        "name" => "GitHub",
        "purpose" => "gh",
        "source" => "stored",
        "value" => "ghp_real-value-0123456789"
      })

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console&with=github")
    assert has_element?(view, "#console-with option[value=github][selected]")

    view
    |> form("#console-form", console: %{mode: "http"})
    |> render_change()

    view
    |> form("#console-form",
      console: %{mode: "http", method: "GET", url: "https://api.github.com/user", with: "github"}
    )
    |> render_change()

    assert has_element?(
             view,
             "#console-preview",
             ~s{curl -sS -i -X GET -H "Authorization: Bearer $(cat /mnt/mwt/tokens/github)"}
           )

    refute render(view) =~ "ghp_real-value"
  end

  test "a command holding a real value of yours is refused before it reaches the VM",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))

    {:ok, _credential} =
      Sandbox.create_resource(username, :credential, %{
        "name" => "Stripe",
        "purpose" => "p",
        "source" => "stored",
        "value" => "sk_live_real-value-0123456789"
      })

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")

    view
    |> form("#console-form", console: %{command: "echo sk_live_real-value-0123456789 > leak"})
    |> render_submit()

    render_async(view, @run_within)
    assert has_element?(view, "#console-error", "holds the real value of Stripe")
    refute File.exists?(Path.join(dir, "leak"))
    # Refused before it ran, it isn't a run.
    assert Sandbox.console_runs(username) == []
  end

  test "the runs stay in the history after the page closes: ten a page, searched, opened and run again",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))

    for n <- 1..11 do
      {:ok, _run} = Sandbox.console(username, "echo run-#{n}", nil)
    end

    [newest_first | _] = runs = Sandbox.console_runs(username)
    first = List.last(runs)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")
    assert has_element?(view, "#console-history-count", "11 runs")
    assert has_element?(view, "#console-pages-shown", "1–10 of 11")
    assert has_element?(view, "#console-run-#{newest_first.id}", "echo run-11")
    refute has_element?(view, "#console-run-#{first.id}")

    view |> element("#console-page-2") |> render_click()
    assert has_element?(view, "#console-run-#{first.id}", "echo run-1")
    refute has_element?(view, "#console-run-#{newest_first.id}")

    # Opened: what it printed, kept with it.
    view |> element("#console-open-#{first.id}") |> render_click()
    assert has_element?(view, "#console-output-text-#{first.id}", "run-1")

    view |> form("#console-search", %{term: "run-7"}) |> render_change()
    assert has_element?(view, "#console-runs code", "echo run-7")
    refute has_element?(view, "#console-pages")

    # Run again: as it ran, a new run, the newest, opened.
    [seventh] = Enum.filter(Sandbox.console_runs(username), &(&1.command == "echo run-7"))
    view |> element("#console-again-#{seventh.id}") |> render_click()
    render_async(view, @run_within)

    assert [%{command: "echo run-7", id: newest} | _] = Sandbox.console_runs(username)
    assert newest > seventh.id
    assert has_element?(view, "#console-output-text-#{newest}", "run-7")
    assert has_element?(view, "#console-history-count", "12 runs")

    view |> element("#console-clear") |> render_click()
    assert has_element?(view, "#console-no-runs")
    assert Sandbox.console_runs(username) == []
  end

  test "a run stopped from MWT is kept as stopped, and logged so",
       %{conn: conn, username: username, tmp_dir: dir} do
    MWTClient.StandIns.put_guest(username, Guest.local(dir))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants?tab=console")

    view |> form("#console-form", console: %{command: "sleep 2"}) |> render_submit()
    assert has_element?(view, "#console-running")
    view |> element("#console-stop") |> render_click()

    assert [%{command: "sleep 2", stopped: true, id: id}] = Sandbox.console_runs(username)
    assert has_element?(view, "#console-run-#{id}", "stopped")
    assert has_element?(view, "#console-output-#{id}", "Stopped from MWT")

    assert Enum.any?(
             Sandbox.events(username, %{limit: 20}),
             &(&1.summary =~ "sleep 2 (stopped from MWT)")
           )
  end
end
