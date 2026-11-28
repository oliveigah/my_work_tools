defmodule MWTClientWeb.SandboxLiveCommandsTest do
  @moduledoc "Host commands on the sandbox's pages: their cards, running, output, settings."
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup %{conn: conn} do
    sign_in(conn)
  end

  # An agent asking to run `script`, a command it wrote, which needs no
  # grant, and waiting up to 10 s for the answer. `commands` is the id the
  # agent's commands had when they went through a grant, still taken.
  defp ask(username, script, attrs \\ %{}) do
    ask =
      Map.merge(
        %{
          grant: "commands",
          script: script,
          reason: "check the cluster",
          agent: "claude",
          dir: "/root"
        },
        attrs
      )

    {:ok, approval} = Server.call(username, {:request_command, ask})
    task = Task.async(fn -> Server.call(username, {:await, approval.id, 10_000}, 11_000) end)
    {approval, task}
  end

  defp until(fun) do
    Enum.find_value(1..300, fn _ -> fun.() || (Process.sleep(10) && nil) end) ||
      flunk("it never happened")
  end

  test "a command's card shows the script in full, the facts, hints and the reason; it runs from there",
       %{conn: conn, username: username} do
    {approval, task} = ask(username, "sudo kubectl get pods\necho done")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    # Text the agent wrote: an ad-hoc command, with the caution it deserves.
    assert has_element?(view, "#approval-#{approval.id}[data-command=ad-hoc]")
    assert has_element?(view, "#approval-kind-#{approval.id}", "Written by the agent")
    assert has_element?(view, "#approval-caution-#{approval.id}", "Written by the agent, not you")
    refute has_element?(view, "#approval-trust-#{approval.id}")
    assert has_element?(view, "#command-script-text-#{approval.id}", "sudo kubectl get pods")
    assert has_element?(view, "#command-script-text-#{approval.id}", "echo done")
    assert has_element?(view, "#copy-script-#{approval.id}")
    assert has_element?(view, "#approval-facts-#{approval.id}", "Your home folder")
    assert has_element?(view, "#approval-hints-#{approval.id}", "Asks for root with sudo")
    assert has_element?(view, "#approval-claims-#{approval.id}", "check the cluster")
    # No allowance is offered for a command.
    refute has_element?(view, "#allow-similar-#{approval.id}")
    refute has_element?(view, "#allow-all-#{approval.id}")
    assert has_element?(view, "#command-output-#{approval.id}-send[checked]")

    view
    |> form("#command-form-#{approval.id}", run: %{output: "send"})
    |> render_submit()

    # sudo fails without a terminal; what matters is that it ran and answered.
    assert {:ok, %{status: :allowed, run: %{state: :done, exit: exit}}, nil} =
             Task.await(task, 11_000)

    assert is_integer(exit)

    # The page catches up on its own once the run ends.
    until(fn -> has_element?(view, "#decided-#{approval.id}") end)
    assert has_element?(view, "#decided-#{approval.id}", "Ran")
    view |> element("#decided-toggle-#{approval.id}") |> render_click()
    assert has_element?(view, "#kept-approval-#{approval.id} #command-output-#{approval.id}")
    refute has_element?(view, "#kept-approval-#{approval.id} #command-form-#{approval.id}")
    assert [%{id: id, run: run}] = Sandbox.approval_history(username)
    assert id == approval.id
    refute Map.has_key?(run, :output)
    refute Map.has_key?(Sandbox.approval_card(username, id).run, :output)
  end

  test "the overview counts a waiting command, and leaves deciding to the approvals page", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "uname -a")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")

    assert has_element?(view, "#stat-waiting[href='/tools/sandbox/approvals']", "1")
    refute has_element?(view, "#approval-#{approval.id}")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    view |> element("#decline-ask-#{approval.id}") |> render_click()

    assert {:ok, %{status: :denied, decision: :decline, run: nil}, nil} =
             Task.await(task)
  end

  test "output shown first waits on its own card, to send or keep", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "echo the-output; exit 2")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    view
    |> form("#command-form-#{approval.id}", run: %{output: "review"})
    |> render_submit()

    until(fn ->
      Enum.find(Sandbox.snapshot(username).waiting, &(&1.stage == :output))
    end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#approval-#{approval.id}", "its output waits for you")
    assert has_element?(view, "#command-output-text-#{approval.id}", "the-output")
    assert has_element?(view, "#output-exit-#{approval.id}", "exit 2")

    view |> element("#send-output-#{approval.id}") |> render_click()

    assert {:ok, %{status: :allowed, decision: :send_output, run: %{output: "the-output\n"}}, nil} =
             Task.await(task, 11_000)

    assert has_element?(view, "#decided-#{approval.id}", "you sent the output")
  end

  test "a running command shows above the queue and can be stopped", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "sleep 30")
    :ok = Sandbox.decide(username, approval.id, {:run, :send})
    until(fn -> Sandbox.snapshot(username).running != [] end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")
    assert has_element?(view, "#running-#{approval.id}", "sleep 30")
    view |> element("#stop-command-#{approval.id}") |> render_click()

    assert {:ok, %{run: %{state: :done, stopped: true}}, nil} =
             Task.await(task, 11_000)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    refute has_element?(view, "#running-commands")
  end

  test "settings show this machine as agents see it, with your notes", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/settings?tab=host")
    assert has_element?(view, "#settings-tab-runtime[aria-current=page]")
    assert has_element?(view, "#settings-host")
    assert has_element?(view, "#host-tools", "not checked yet")
    assert has_element?(view, "#host-text", "# The user's machine")

    view
    |> form("#host-notes-form", host: %{notes: "Kubernetes contexts: staging, prod"})
    |> render_submit()

    assert has_element?(view, "#host-text", "Kubernetes contexts: staging, prod")
    assert Sandbox.snapshot(username).settings.host_notes == "Kubernetes contexts: staging, prod"

    view
    |> form("#host-notes-form", host: %{notes: String.duplicate("x", 4_001)})
    |> render_submit()

    assert has_element?(view, "#host-notes-error", "4,000")
  end

  test "a command an agent wrote is saved from its card, which still waits", %{
    conn: conn,
    username: username
  } do
    {approval, task} = ask(username, "kubectl get pods -n web -o json")
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    view |> element("#save-command-#{approval.id}") |> render_click()

    # The form comes filled in from the card.
    assert has_element?(view, "#saving-from", "From what claude asked to run")
    assert has_element?(view, "#grant-script", "kubectl get pods -n web -o json")

    assert has_element?(
             view,
             "#add-grant-form input[name='grant[name]'][value='kubectl get pods']"
           )

    assert has_element?(view, "#add-grant-form input[name='grant[dir]'][value='#{approval.dir}']")

    # What it's for starts empty: the agent's reason is about this run.
    refute has_element?(
             view,
             "#add-grant-form textarea[name='grant[purpose]']",
             "check the cluster"
           )

    assert has_element?(view, "#purpose-hint", "for any time it runs")

    view
    |> form("#add-grant-form", grant: %{name: "Web pods", purpose: "Lists the web pods"})
    |> render_submit()

    assert has_element?(view, "#notices", "Saved as Web pods, on for 1 h")
    assert has_element?(view, "#approval-saved-#{approval.id}", "Saved as web-pods")
    refute has_element?(view, "#save-command-#{approval.id}")

    # On for the hour the agent is at it, asking each time.
    assert %{kind: :command, script: "kubectl get pods -n web -o json", state: :on, minutes: 60} =
             web_pods = Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "web-pods"))

    assert web_pods.allowances == []

    # Saving decided nothing: the card still waits to run or not.
    assert has_element?(view, "#run-command-#{approval.id}")
    view |> element("#decline-ask-#{approval.id}") |> render_click()
    assert {:ok, %{status: :denied, saved_as: "web-pods"}, _grant} = Task.await(task)
  end

  test "the agent's suggestion to save leads the card, under its name", %{
    conn: conn,
    username: username
  } do
    {approval, task} =
      ask(username, "gh auth status", %{
        suggest_save: "gh status",
        save_for: "Says which GitHub accounts gh is logged in to"
      })

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    assert has_element?(view, "#approval-suggest-save-#{approval.id}", "gh status")

    assert has_element?(
             view,
             "#approval-save-for-#{approval.id}",
             "Says which GitHub accounts gh is logged in to"
           )

    refute has_element?(view, "#save-command-#{approval.id}")

    view |> element("#save-command-#{approval.id}-suggested") |> render_click()
    assert has_element?(view, "#add-grant-form input[name='grant[name]'][value='gh status']")

    # Its description is the agent's words for the saved command, not its reason.
    assert has_element?(
             view,
             "#add-grant-form textarea[name='grant[purpose]']",
             "Says which GitHub accounts gh is logged in to"
           )

    assert has_element?(view, "#purpose-hint", "The agent's suggestion")

    view |> element("#decline-ask-#{approval.id}") |> render_click()
    Task.await(task)
  end

  test "a long command can be declined with a request for a simpler one", %{
    conn: conn,
    username: username
  } do
    {approval, task} =
      ask(username, "for p in a b c d e f; do\n  echo $p\n  date\ndone\nls\nwc -l x")

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    assert has_element?(
             view,
             "#approval-hints-#{approval.id}",
             "Long for a command you check by eye"
           )

    view |> element("#simpler-#{approval.id}") |> render_click()

    assert {:ok, %{status: :denied, decision: :simpler, run: nil}, nil} =
             Task.await(task)

    until(fn -> has_element?(view, "#decided-#{approval.id}") end)
    assert has_element?(view, "#decided-#{approval.id}", "asked for a simpler one")
  end

  test "a saved command's card names it, and offers neither saving nor a simpler one", %{
    conn: conn,
    username: username
  } do
    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "Pods",
        "purpose" => "List pods",
        "script" => "kubectl get pods",
        "dir" => System.tmp_dir!()
      })

    {:ok, _} = Sandbox.turn_on(username, "pods", 60, :ask)

    {:ok, approval} =
      Server.call(
        username,
        {:request_command, %{grant: "pods", script: "", reason: "look", agent: "claude"}}
      )

    task = Task.async(fn -> Server.call(username, {:await, approval.id, 10_000}, 11_000) end)
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    # Your own script: named, with what it's for, and calmer.
    assert has_element?(view, "#approval-#{approval.id}[data-command=saved]")
    assert has_element?(view, "#approval-kind-#{approval.id}", "Saved command")
    assert has_element?(view, "#approval-#{approval.id} h3", "Pods")
    assert has_element?(view, "#approval-purpose-#{approval.id}", "List pods")
    assert has_element?(view, "#approval-trust-#{approval.id}", "The agent sent no text")
    refute has_element?(view, "#approval-caution-#{approval.id}")
    # The script is there, folded: it is yours.
    assert has_element?(view, "#approval-script-#{approval.id}:not([open])")
    assert has_element?(view, "#command-script-text-#{approval.id}", "kubectl get pods")
    assert has_element?(view, "#run-command-#{approval.id}", "Run Pods")
    refute has_element?(view, "#save-command-#{approval.id}")
    refute has_element?(view, "#simpler-#{approval.id}")

    view |> element("#decline-ask-#{approval.id}") |> render_click()
    Task.await(task)
  end

  test "asked to turn on, a saved command can auto-approve; an agent's own command needs no grant",
       %{conn: conn, username: username} do
    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "Pods",
        "purpose" => "List pods",
        "script" => "kubectl get pods",
        "dir" => System.tmp_dir!()
      })

    {:ok, _} = Sandbox.turn_off(username, "pods")

    {:ok, saved} =
      Server.call(
        username,
        {:request_access, %{grant: "pods", minutes: 60, reason: "r", agent: "claude"}}
      )

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/approvals")

    assert has_element?(view, "#activation-uses-#{saved.id}-all")
    refute Enum.any?(Sandbox.snapshot(username).grants, &(&1.id == "commands"))

    view
    |> form("#activation-form-#{saved.id}", ask: %{minutes: "60", uses: "all"})
    |> render_submit()

    assert %{state: :on, allowances: [%{pattern: :all}]} =
             Enum.find(Sandbox.snapshot(username).grants, &(&1.id == "pods"))
  end
end
