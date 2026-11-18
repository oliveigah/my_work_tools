defmodule MWTClientWeb.SandboxSetupSshTest do
  @moduledoc """
  The Setup page and the SSH entry Zed connects with. The SSH config read is
  application config, so these tests take turns.
  """
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.Msb

  setup %{conn: conn} do
    context = sign_in(conn)
    saved = Application.get_env(:mwt_client, Msb)
    config = Path.join(System.tmp_dir!(), "ssh-config-#{System.unique_integer([:positive])}")
    Application.put_env(:mwt_client, Msb, Keyword.put(saved, :ssh_config, config))

    on_exit(fn ->
      Application.put_env(:mwt_client, Msb, saved)
      File.rm(config)
    end)

    Map.put(context, :config, config)
  end

  defp entry(command), do: "Host mwt-sandbox\n  ProxyCommand #{command} ssh serve vm --stdio\n"

  test "warns when the SSH entry reaches the VM through another launcher", %{
    conn: conn,
    config: config
  } do
    File.write!(config, entry("/home/me/.mwt_client/bin/msb"))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/setup")
    assert has_element?(view, "#connect-ssh-stale", "/home/me/.mwt_client/bin/msb")
  end

  test "says nothing when the entry runs this identity's launcher, or there is none", %{
    conn: conn,
    username: username,
    config: config
  } do
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/setup")
    refute has_element?(view, "#connect-ssh-stale")

    File.write!(config, entry(Msb.launcher(username)))
    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/setup")
    refute has_element?(view, "#connect-ssh-stale")
    assert has_element?(view, "#connect-ssh-config", Msb.launcher(username))
  end
end
