defmodule MWTClientWeb.Plugs.LoopbackHostTest do
  # Changes the application-wide host validation setting.
  use MWTClientWeb.ConnCase, async: false

  alias MWTClient.Accounts
  alias MWTClient.VaultHelpers
  alias MWTClientWeb.Plugs.LoopbackHost

  setup do
    VaultHelpers.reset_data_dir!()
    on_exit(&VaultHelpers.reset_data_dir!/0)
    :ok
  end

  for host <- ~w(127.0.0.1 localhost) do
    test "#{host} is served", %{conn: conn} do
      conn = %{conn | host: unquote(host)}

      assert conn |> get(~p"/") |> html_response(200)
    end
  end

  test "a rebound host is refused", %{conn: conn} do
    conn = %{conn | host: "attacker.test"}

    assert conn |> get(~p"/") |> response(403)
  end

  test "sign in cannot be driven from a rebound host", %{conn: conn} do
    conn = %{conn | host: "attacker.test"}

    assert conn
           |> post(~p"/login", %{"user" => %{"username" => "victim", "password" => "guess"}})
           |> response(403)

    refute Accounts.exists?("victim")
  end

  describe "another 127.x.y.z address, as an MWT in the agent sandbox's VM opens at" do
    setup do
      on_exit(fn -> Application.delete_env(:mwt_client, :any_loopback_address) end)
    end

    test "is refused unless asked for, then served", %{conn: conn} do
      conn = %{conn | host: "127.77.12.34"}
      assert conn |> get(~p"/") |> response(403)

      Application.put_env(:mwt_client, :any_loopback_address, true)
      assert conn |> get(~p"/") |> html_response(200)
    end

    test "a name is never taken for one" do
      Application.put_env(:mwt_client, :any_loopback_address, true)

      for host <- ~w(127.77.12.34.attacker.test 127.77.12 10.0.0.1) do
        refute LoopbackHost.origin?(URI.parse("http://#{host}:4000"), 4000), host
      end
    end

    test "opens sockets only from its own port, over plain HTTP" do
      refute LoopbackHost.origin?(URI.parse("http://127.77.12.34:4000"), 4000)

      Application.put_env(:mwt_client, :any_loopback_address, true)
      assert LoopbackHost.origin?(URI.parse("http://127.77.12.34:4000"), 4000)
      assert LoopbackHost.origin?(URI.parse("http://localhost:4000"), 4000)
      assert LoopbackHost.origin?(URI.parse("http://[::1]:4000"), 4000)
      refute LoopbackHost.origin?(URI.parse("http://127.77.12.34:4001"), 4000)
      refute LoopbackHost.origin?(URI.parse("https://127.77.12.34:4000"), 4000)
    end
  end

  test "the rule is lifted when the endpoint is bound publicly", %{conn: conn} do
    Application.put_env(:mwt_client, :require_loopback_host, false)
    on_exit(fn -> Application.put_env(:mwt_client, :require_loopback_host, true) end)

    conn = %{conn | host: "mwt.example.com"}

    assert conn |> get(~p"/") |> html_response(200)
  end
end
