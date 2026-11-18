defmodule MWTClient.Sandbox.EgressBoundsTest do
  @moduledoc """
  How much of MWT the VM can hold through the proxy (QA L7): connections
  at once, and how long a head may take to arrive, however slowly it
  trickles.

  The cap is read from the application's config at each connection, so
  these tests take turns with nothing else changing it.
  """
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Egress
  alias MWTClient.Sandbox.Egress.Connection

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("bounds")
    saved = Application.get_env(:mwt_client, Egress)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:mwt_client, Egress, saved),
        else: Application.delete_env(:mwt_client, Egress)
    end)

    Enum.find_value(1..200, fn _ ->
      Sandbox.snapshot(username).proxy.listening? || (Process.sleep(10) && nil)
    end)

    %{username: username}
  end

  defp open(username) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Egress.path(username)}, 0, [:binary, active: false])

    socket
  end

  # A connection the proxy served: its CONNECT to an address MWT always
  # refuses is answered 403.
  defp served?(username) do
    socket = open(username)
    :ok = :gen_tcp.send(socket, "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
    answer = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    match?({:ok, "HTTP/1.1 403" <> _}, answer)
  end

  defp held(username) do
    Registry.count_match(MWTClient.Sandbox.Connections, username, :_)
  end

  test "the proxy holds so many connections at once; one more is closed, and logged", %{
    username: username
  } do
    Application.put_env(:mwt_client, Egress, max_connections: 3)

    # Three that never finish their head.
    slow =
      for _ <- 1..3 do
        socket = open(username)
        :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n")
        socket
      end

    assert Enum.find_value(1..200, fn _ -> held(username) == 3 || (Process.sleep(10) && nil) end)

    refute served?(username)
    refute served?(username)
    assert held(username) == 3

    # One closes; its place is free.
    :gen_tcp.close(hd(slow))
    assert Enum.find_value(1..200, fn _ -> held(username) == 2 || (Process.sleep(10) && nil) end)
    assert served?(username)

    _ = :sys.get_state(MWTClient.Vault.Store.whereis(Sandbox.Server, username))

    refused =
      for %{outcome: :blocked, summary: "Too many connections" <> _} <- Sandbox.events(username),
          do: :refused

    # Said once, however many were refused.
    assert refused == [:refused]
  end

  describe "a head trickled a byte at a time" do
    setup %{username: username} do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)

      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        Connection.run(client, username, head_within: 400)
      end)

      %{port: port}
    end

    test "is cut when its time is up, though every byte came within the idle time", %{
      port: port
    } do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\n")
      started = System.monotonic_time(:millisecond)

      trickled =
        Enum.reduce_while(1..30, :open, fn _, _ ->
          Process.sleep(100)

          case :gen_tcp.send(socket, "x") do
            :ok ->
              case :gen_tcp.recv(socket, 0, 0) do
                {:error, :timeout} -> {:cont, :open}
                _closed -> {:halt, :closed}
              end

            {:error, _closed} ->
              {:halt, :closed}
          end
        end)

      assert trickled == :closed
      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end
end
