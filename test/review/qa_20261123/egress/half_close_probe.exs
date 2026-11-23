defmodule MWTClient.QaProbes.Egress.HalfCloseTest do
  @moduledoc """
  QA probe: a tunnelled connection whose client half-closes (shutdown of
  its write side once it sent its request, as `nc -N` or a client that
  signals the end of its input does). Does the host's answer still reach
  it?
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Tcp

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("qa-half-close")

    {:ok, host} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, host_port} = :inet.port(host)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(host)
      got = read_to_eof(socket, "")
      :gen_tcp.send(socket, "reply to #{byte_size(got)} bytes\n")
      :gen_tcp.close(socket)
    end)

    options = [
      upstream_tcp: fn _target ->
        :gen_tcp.connect(~c"127.0.0.1", host_port, [:binary, active: false])
      end
    ]

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      pid = spawn(fn -> receive(do: (:go -> Tcp.run(client, username, options))) end)
      :gen_tcp.controlling_process(client, pid)
      send(pid, :go)
      Process.sleep(:infinity)
    end)

    %{proxy: port}
  end

  defp read_to_eof(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_to_eof(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  test "the client half-closes after its request: the host's reply never reaches it", %{
    proxy: proxy
  } do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "CONNECT 93.184.216.34:7000 HTTP/1.1\r\n\r\n")
    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.send(socket, "query: something, not HTTP\n")
    Process.sleep(300)
    :ok = :gen_tcp.shutdown(socket, :write)
    reply = read_to_eof(socket, "")
    IO.puts("\n[probe] what came back after the half-close: #{inspect(reply)}")
    assert reply == ""
  end
end
