defmodule MWTClientWeb.HttpClientLiveAppWideTest do
  # Not async: these change what the whole app shares (Req's default
  # options, Req.Test's shared mode, the layout preference) or wait for every
  # request the app runs.
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.HttpClient.Requests
  alias MWTClient.HttpClient.Resources

  setup {MWTClientWeb.HttpClientLiveHelpers, :with_history}

  test "an infinite request exposes a cancel button and can be cancelled", %{
    view: view,
    username: username
  } do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, {:infinite_request_started, self()})

      receive do
        :unexpected_finish -> Plug.Conn.send_resp(conn, 200, "too late")
      end
    end)

    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
    end)

    view
    |> element("#request-form")
    |> render_change(%{
      "request" => %{
        "url" => "https://api.example.test/stream",
        "timeout_ms" => "infinity"
      }
    })

    view |> element("#request-form") |> render_submit(%{})
    assert_receive {:infinite_request_started, _request_process}
    assert has_element?(view, "#cancel-request")

    view |> element("#cancel-request") |> render_click()

    refute has_element?(view, "#cancel-request")
    assert has_element?(view, "#send-request")
    assert length(Resources.all(username)) == 2
  end

  test "a running request shows how long it has waited and cancels with Escape", %{view: view} do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, :slow_request_started)

      receive do
        :unexpected_finish -> Plug.Conn.send_resp(conn, 200, "too late")
      end
    end)

    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
    end)

    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"url" => "https://api.example.test/slow"}})

    view |> element("#request-form") |> render_submit(%{})
    assert_receive :slow_request_started

    assert has_element?(view, "#response-waiting [data-started-at]")
    assert has_element?(view, "#cancel-request-waiting")
    assert view |> element("#response-waiting") |> render() =~ "api.example.test"

    view |> element("#response-waiting") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#response-waiting")
    assert has_element?(view, "#response-cancelled")
    assert has_element?(view, "#send-request")
  end

  test "the response sits below or beside the request, and the choice is kept", %{
    view: view,
    conn: conn
  } do
    assert has_element?(view, "#request-workspace[data-layout=vertical]")
    assert has_element?(view, "#request-resizer[data-axis=y][data-panel=request-editor]")

    view |> element("#toggle-layout") |> render_click()

    assert has_element?(view, "#request-workspace[data-layout=horizontal]")
    assert has_element?(view, "#request-resizer-x[data-axis=x][data-panel=request-pane]")
    refute has_element?(view, "#request-resizer")

    {:ok, reopened, _html} = live(conn, ~p"/tools/http")
    assert has_element?(reopened, "#request-workspace[data-layout=horizontal]")

    reopened |> element("#toggle-layout") |> render_click()
    assert has_element?(reopened, "#request-workspace[data-layout=vertical]")
  end

  test "sending records the description and tags of the tab", %{view: view, username: username} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
    end)

    view |> element("#request-description") |> render_change(%{"description" => "Nightly smoke"})

    # typed into the tag box but never submitted with Enter
    view |> element("#request-tag") |> render_change(%{"tag" => "smoke"})
    refute has_element?(view, "[phx-click=remove_tag][phx-value-tag=smoke]")

    view
    |> element("#request-form")
    |> render_change(%{"request" => %{"url" => "https://api.example.test/ping"}})

    view |> element("#request-form") |> render_submit(%{})
    await_requests(view, username)

    assert [{_id, metadata, _request, _response} | _older] = Resources.all(username)
    assert metadata.description == "Nightly smoke"
    assert metadata.tags == ["smoke"]
  end

  defp await_requests(view, username) do
    for pid <- Task.Supervisor.children(MWTClient.HttpClient.TaskSupervisor) do
      reference = Process.monitor(pid)
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 2_000
    end

    assert Requests.running(username) == []
    _ = :sys.get_state(view.pid)

    view
  end
end
