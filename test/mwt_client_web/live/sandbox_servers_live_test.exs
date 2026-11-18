defmodule MWTClientWeb.SandboxServersLiveTest do
  # Not async: forwarding is turned on, with a fake tunnel, through the
  # application env.
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.FakeTunnel
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Forwarder, Ports, Server}
  alias MWTClient.Sandbox.Server.State
  alias MWTClient.Vault.Store
  alias MWTClientWeb.SandboxLive.Servers

  setup %{conn: conn} do
    agent = FakeTunnel.agent()

    for {module, value} <- [
          {Forwarder, [enabled: true, tunnel: FakeTunnel]},
          {FakeTunnel, [test: self(), agent: agent]}
        ] do
      Application.put_env(:mwt_client, module, value)
      on_exit(fn -> Application.delete_env(:mwt_client, module) end)
    end

    sign_in(conn)
  end

  test "the overview lists the VM's servers, with a link to each one open here", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    assert has_element?(view, "#overview-servers #servers-status", "The VM isn't running.")

    server = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(server, fn state ->
      State.change(state, :vm, &%{&1.vm | exists?: true, status: :running})
    end)

    report =
      FakeTunnel.report([
        {"127.0.0.1", 4101, "beam.smp", "/work/app.wt/slot-1"},
        {"0.0.0.0", 22, "sshd"}
      ])

    assert {0, "ok"} = Channel.answer("ports", %{"report" => report}, username)
    assert_receive {:tunnel, :forward, address, 4101, _target}

    # The page follows the server's changes; render until it shows them.
    assert Enum.find_value(1..100, fn _ ->
             has_element?(view, "#server-open-4101") || (Process.sleep(10) && nil)
           end)

    assert address == Ports.address(MWTClient.Accounts.id(username))
    assert has_element?(view, "#servers-address", address)
    assert has_element?(view, "#servers-range", "4100–4199")
    assert has_element?(view, "#server-open-4101[href='http://#{address}:4101'][target=_blank]")
    assert has_element?(view, "#server-4101", "slot-1 of app")

    # Ports outside the range stay in the VM, and aren't listed.
    refute has_element?(view, "#server-22")
  end

  test "a server is killed from the overview: what holds its port in the VM gets SIGTERM", %{
    conn: conn,
    username: username
  } do
    test = self()

    # The VM's side stands in: what would run there, and what it prints.
    MWTClient.StandIns.put_guest(username, %{
      exec: fn words ->
        send(test, {:exec, words})
        {:ok, "812\n"}
      end
    })

    server = GenServer.whereis(Store.via(Server, username))

    :sys.replace_state(server, fn state ->
      State.change(state, :vm, &%{&1.vm | exists?: true, status: :running})
    end)

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox")
    report = FakeTunnel.report([{"127.0.0.1", 4102, "node", "/work/app.wt/slot-2"}])
    assert {0, "ok"} = Channel.answer("ports", %{"report" => report}, username)

    assert Enum.find_value(1..100, fn _ ->
             has_element?(view, "#server-kill-4102") || (Process.sleep(10) && nil)
           end)

    view |> element("#server-kill-4102") |> render_click()

    # The port is looked up again in the VM, not taken from the report.
    assert_receive {:exec, ["sh", "-c", script, "mwt-stop-server", "4102"]}
    assert script =~ "ss -ltnpH"
    assert script =~ "kill $pids"
    assert has_element?(view, "#notices", "Killed the server on port 4102")

    assert Enum.find_value(1..100, fn _ ->
             Enum.find(Sandbox.events(username), &(&1.summary =~ "port 4102")) ||
               (Process.sleep(10) && nil)
           end).outcome == :vm
  end

  test "killing a server says why it stays: gone already, or not one of the listed ports", %{
    username: username
  } do
    MWTClient.StandIns.put_guest(username, %{exec: fn _words -> {:ok, "\n"} end})

    assert {:error, :not_listening} = Sandbox.stop_server(username, 4102)
    assert {:error, :out_of_range} = Sandbox.stop_server(username, 22)
  end

  test "a slot shows the servers running in it, and only those" do
    ports = %{
      address: "127.77.1.2",
      status: :on,
      ports: [
        %{port: 4110, process: "beam.smp", cwd: "/work/app.wt/slot-1", status: :forwarded},
        %{port: 4111, process: "x", cwd: "/work/app.wt/slot-1/a", status: {:skipped, "Taken"}},
        %{port: 4120, process: "beam.smp", cwd: "/work/app.wt/slot-2", status: :forwarded}
      ]
    }

    html = render_component(&Servers.slot_list/1, ports: ports, project: "app", slot: "slot-1")
    document = LazyHTML.from_fragment(html)

    assert [link] =
             document |> LazyHTML.query("#slot-server-slot-1-4110 a") |> Enum.to_list()

    assert LazyHTML.attribute(link, "href") == ["http://127.77.1.2:4110"]
    assert document |> LazyHTML.query("#slot-server-slot-1-4111") |> Enum.count() == 1
    assert document |> LazyHTML.query("#slot-server-slot-1-4120") |> Enum.count() == 0

    assert render_component(&Servers.slot_list/1, ports: ports, project: "app", slot: "slot-3") ==
             ""
  end
end
