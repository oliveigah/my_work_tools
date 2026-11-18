defmodule MWTClient.Sandbox.ChannelBoundsTest do
  # Any process in the VM can connect to the channel, as often as it likes:
  # what it can hold of MWT through it is bounded. The MCP deadline is
  # application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox.Channel

  setup do
    saved = Application.get_env(:mwt_client, Channel)
    Application.put_env(:mwt_client, Channel, mcp_read_ms: 500)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:mwt_client, Channel, saved),
        else: Application.delete_env(:mwt_client, Channel)
    end)

    MWTClient.VaultHelpers.unlocked_identity("channel-bounds")
  end

  defp connect(username) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Channel.socket_path(username)}, 0, [:binary, active: false])

    socket
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp ask(username, line) do
    socket = connect(username)
    :ok = :gen_tcp.send(socket, line)
    read_all(socket)
  end

  defp grants(username), do: ask(username, ~s({"command":"grants"}\n))

  defp eventually(check, tries \\ 300) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("it never happened")
      true -> Process.sleep(10) && eventually(check, tries - 1)
    end
  end

  test "connections past the most served at once are closed unanswered", %{username: username} do
    idle = for _ <- 1..Channel.max_connections(), do: connect(username)

    # Each idle one waits for its ask; one more isn't served at all.
    eventually(fn -> grants(username) == "" end)

    Enum.each(idle, &:gen_tcp.close/1)
    eventually(fn -> String.starts_with?(grants(username), "0\n") end)
  end

  test "MCP messages are read a few at a time, each whole within its time", %{
    username: username
  } do
    # Each sends the start of a large message and stops: it holds a place
    # to be read in, until its time is up.
    slow =
      for _ <- 1..8 do
        socket = connect(username)
        :ok = :gen_tcp.send(socket, ~s({"command":"mcp"}\n))

        :ok =
          :gen_tcp.send(
            socket,
            ~s({"jsonrpc":"2.0","id":1,"params":") <> :binary.copy("x", 100_000)
          )

        socket
      end

    message = ~s({"jsonrpc":"2.0","id":7,"method":"ping"}\n)

    eventually(fn ->
      ask(username, ~s({"command":"mcp"}\n) <> message) ==
        "1\nMWT is reading 8 MCP messages from this VM already. Try again.\n"
    end)

    for socket <- slow,
        do: assert(read_all(socket) == "1\nMWT got no whole MCP message in time.\n")

    assert "0\n" <> answer = ask(username, ~s({"command":"mcp"}\n) <> message)
    assert %{"id" => 7, "result" => %{}} = Jason.decode!(answer)
  end

  test "a message sent a byte at a time doesn't keep its place past its time", %{
    username: username
  } do
    socket = connect(username)
    :ok = :gen_tcp.send(socket, ~s({"command":"mcp"}\n{"jsonrpc"))
    started = System.monotonic_time(:millisecond)

    trickle =
      Task.async(fn ->
        Enum.reduce_while(1..100, :ok, fn _, :ok ->
          Process.sleep(50)
          if :gen_tcp.send(socket, " ") == :ok, do: {:cont, :ok}, else: {:halt, :closed}
        end)
      end)

    assert read_all(socket) == "1\nMWT got no whole MCP message in time.\n"
    assert System.monotonic_time(:millisecond) - started < 2_000
    Task.shutdown(trickle, :brutal_kill)
  end
end
