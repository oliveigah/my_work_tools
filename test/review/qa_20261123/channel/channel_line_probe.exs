defmodule MWTClient.QAProbes.Channel.ChannelLineProbeTest do
  @moduledoc """
  QA probes on the channel's framing: an ask's line past 64 KiB, and what
  an MCP message MWT refuses answers to.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox.Channel

  defp connect(username) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Channel.socket_path(username)}, 0, [:binary, active: false])

    socket
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  defp ask(username, data) do
    socket = connect(username)
    :ok = :gen_tcp.send(socket, data)
    read_all(socket)
  end

  test "an ask whose line is over 64 KiB", context do
    reason = String.duplicate("a", 70_000)

    line =
      Jason.encode!(%{command: "request", grant: "commands", reason: reason, wait: 0}) <> "\n"

    answer = ask(context.username, line)
    IO.puts("70 KB request: #{inspect(String.slice(answer, 0, 200))}")
  end

  test "a long --reason through the mwt command", context do
    reason = String.duplicate("why ", 17_000)

    {output, status} =
      mwt(context, ["run", "commands", "--reason", reason, "--wait", "0", "--", "true"])

    IO.puts(
      "68 KB reason via mwt run: status=#{status} output=#{inspect(String.slice(output, 0, 200))}"
    )
  end

  test "an MCP message over 2 MB is answered without its id", context do
    big = String.duplicate("x", 2_100_000)

    message =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 42,
        method: "tools/call",
        params: %{name: "create_note", arguments: %{title: "t", body: big}}
      })

    answer = ask(context.username, ~s({"command":"mcp"}\n) <> message <> "\n")
    IO.puts("2.1 MB MCP message: #{inspect(answer)}")
    assert "0\n" <> json = answer
    assert %{"id" => 42} = Jason.decode!(json)
  end
end
