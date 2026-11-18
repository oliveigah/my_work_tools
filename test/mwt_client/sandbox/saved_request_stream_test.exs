defmodule MWTClient.Sandbox.SavedRequestStreamTest do
  # A real server, past Req.Test, which collects a whole answer before Req
  # sees it: the service's address is application config, so this test
  # runs alone.
  use ExUnit.Case, async: false

  alias MWTClient.Sandbox.SavedRequest

  setup do
    saved = Application.get_env(:mwt_client, SavedRequest)
    Application.delete_env(:mwt_client, SavedRequest)
    on_exit(fn -> Application.put_env(:mwt_client, SavedRequest, saved) end)

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    server = spawn_link(fn -> answer_without_end(listen) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    %{port: port}
  end

  # Reads a request's head, then sends a chunked body that never ends,
  # until the client goes.
  defp answer_without_end(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :ok = :inet.setopts(socket, packet: :http_bin)
    head(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
    chunk = :binary.copy("x", 64 * 1024)
    frame = [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]
    Stream.repeatedly(fn -> :gen_tcp.send(socket, frame) end) |> Enum.find(&(&1 != :ok))
  end

  defp head(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, _line} -> head(socket)
    end
  end

  test "an answer without end is read to what is kept, then left", %{port: port} do
    call = %{
      method: "GET",
      url: "http://127.0.0.1:#{port}/endless",
      host: "127.0.0.1",
      headers: [{"authorization", "Bearer {token}"}],
      body: nil
    }

    {us, run} = :timer.tc(fn -> SavedRequest.send(call, "real-value", "Test", 30) end)

    assert run.exit == 0
    assert byte_size(run.output) == 256 * 1024
    assert run.cut > 0
    assert us < 10_000_000, "it took #{div(us, 1000)} ms"
  end
end
