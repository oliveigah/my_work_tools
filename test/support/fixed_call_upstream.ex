defmodule MWTClient.FixedCallUpstream do
  @moduledoc """
  The service a fixed call reaches in tests. A fixed call goes through
  MWT's proxy (`MWTClient.Sandbox.Egress.FixedCall`), which connects to
  the service over TLS; here that connection reaches a server on the
  loopback, which answers the one request it gets with the `Req.Test`
  stub of `MWTClient.Sandbox.SavedRequest`, as tests stub the service
  (`Req.Test.stub(MWTClient.Sandbox.SavedRequest, ...)`).

  `config/test.exs` points `MWTClient.Sandbox.Egress.FixedCall`'s
  `:upstream` at `upstream/1`. The server runs in a task of the
  connection's, so the stub a test allowed for the sandbox's server is
  found through `$callers`.
  """

  alias MWTClient.Sandbox.CertificateAuthority, as: CA

  @doc "The proxy's `:upstream` for `username`'s fixed calls: the stub's server."
  def upstream(_username) do
    fn target ->
      leaf = CA.leaf(CA.new("Fixed call upstream"), target.name || "localhost")

      {:ok, listen} =
        :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, ip: {127, 0, 0, 1}])

      {:ok, {_ip, port}} = :ssl.sockname(listen)
      {:ok, _pid} = Task.start(fn -> serve(listen, target.name) end)
      :ssl.connect(~c"127.0.0.1", port, verify: :verify_none, active: false, mode: :binary)
    end
  end

  defp serve(listen, host) do
    with {:ok, socket} <- :ssl.transport_accept(listen, 5_000),
         {:ok, socket} <- :ssl.handshake(socket, 5_000),
         {:ok, method, path, headers, body} <- read(socket, "") do
      {:ok, response} =
        Req.request(
          plug: {Req.Test, MWTClient.Sandbox.SavedRequest},
          method: method,
          url: "https://#{host}#{path}",
          headers: headers,
          body: body,
          retry: false,
          redirect: false,
          decode_body: false,
          compressed: false
        )

      answer =
        for {name, values} <- response.headers,
            name not in ["content-length", "transfer-encoding", "connection"],
            value <- List.wrap(values),
            do: [name, ": ", value, "\r\n"]

      :ssl.send(socket, [
        "HTTP/1.1 #{response.status} Answer\r\n",
        answer,
        "content-length: #{byte_size(response.body)}\r\nconnection: close\r\n\r\n",
        response.body
      ])

      :ssl.close(socket)
    end

    :ssl.close(listen)
  end

  defp read(socket, read) do
    case :binary.split(read, "\r\n\r\n") do
      [head, rest] ->
        [request_line | lines] = String.split(head, "\r\n")
        [method, path | _] = String.split(request_line, " ")

        headers =
          for line <- lines,
              [name, value] <- [String.split(line, ":", parts: 2)],
              do: {String.downcase(String.trim(name)), String.trim(value)}

        length =
          case List.keyfind(headers, "content-length", 0) do
            {_, value} -> String.to_integer(value)
            nil -> 0
          end

        with {:ok, body} <- body(socket, rest, length) do
          headers = Enum.reject(headers, &(elem(&1, 0) in ["content-length", "host"]))
          {:ok, method, path, headers, body}
        end

      [_partial] ->
        with {:ok, more} <- :ssl.recv(socket, 0, 5_000), do: read(socket, read <> more)
    end
  end

  defp body(_socket, read, length) when byte_size(read) >= length,
    do: {:ok, binary_part(read, 0, length)}

  defp body(socket, read, length) do
    with {:ok, more} <- :ssl.recv(socket, 0, 5_000), do: body(socket, read <> more, length)
  end
end
