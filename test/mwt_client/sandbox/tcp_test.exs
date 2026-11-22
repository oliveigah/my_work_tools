defmodule MWTClient.Sandbox.TcpTest do
  @moduledoc """
  How MWT can read a TCP connection, from its first bytes
  (`MWTClient.Sandbox.Egress.Tcp`): a ClientHello's host name and
  protocols, as a real client writes them and as the VM could bend them.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Tcp

  # A ClientHello with these extensions, in this order.
  defp hello(extensions) do
    body = IO.iodata_to_binary(extensions)
    hello = <<3, 3, 0::256, 0, 2::16, 0x13, 0x01, 1, 0, byte_size(body)::16, body::binary>>
    handshake = <<1, byte_size(hello)::24, hello::binary>>
    <<0x16, 3, 1, byte_size(handshake)::16, handshake::binary>>
  end

  defp sni(name) do
    entry = <<0, byte_size(name)::16, name::binary>>
    <<0::16, byte_size(entry) + 2::16, byte_size(entry)::16, entry::binary>>
  end

  defp alpn(protocols) do
    list = for p <- protocols, into: "", do: <<byte_size(p), p::binary>>
    <<16::16, byte_size(list) + 2::16, byte_size(list)::16, list::binary>>
  end

  # An extension MWT doesn't read (supported_versions), to skip over.
  @other <<43::16, 3::16, 2, 3, 4>>

  # What Erlang's own client sends, to be sure of real bytes.
  defp real_hello(options) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      _ = :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none] ++ options, 1_000)
    end)

    {:ok, socket} = :gen_tcp.accept(listen, 5_000)
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    data
  end

  test "a ClientHello's name and protocols, wherever its extensions put them" do
    assert Tcp.first(hello([sni("API.Example.com"), @other, alpn(["h2", "http/1.1"])])) ==
             {:tls, %{name: "api.example.com", alpn: ["h2", "http/1.1"]}}

    assert Tcp.first(hello([alpn(["http/1.1"]), @other, sni("example.com")])) ==
             {:tls, %{name: "example.com", alpn: ["http/1.1"]}}

    assert Tcp.first(hello([@other])) == {:tls, %{name: nil, alpn: nil}}

    # As a real client writes it.
    assert {:tls, %{name: "api.example.com", alpn: ["h2", "http/1.1"]}} =
             Tcp.first(
               real_hello(
                 server_name_indication: ~c"api.example.com",
                 alpn_advertised_protocols: ["h2", "http/1.1"]
               )
             )

    assert {:tls, %{name: nil, alpn: nil}} =
             Tcp.first(real_hello(server_name_indication: :disable))
  end

  test "the first bytes are TLS, nothing, or anything else" do
    assert Tcp.first("") == :silent
    assert Tcp.first("GET / HTTP/1.1\r\n\r\n") == :other
    assert Tcp.first("SSH-2.0-OpenSSH_9.6\r\n") == :other
    assert Tcp.first(<<0x16, 3, 1, 0, 5, 1, 2>>) == :other
  end

  test "MWT reads TLS that names a host and offers HTTP/1.1 or nothing; else says why not" do
    readable = fn extensions -> Tcp.readable(Tcp.first(hello(extensions))) end

    assert readable.([sni("example.com")]) == :ok
    assert readable.([sni("example.com"), alpn(["h2", "http/1.1"])]) == :ok
    assert readable.([sni("example.com"), alpn(["http/1.1"])]) == :ok
    assert readable.([sni("example.com"), alpn(["h2"])]) == {:no, :h2_only}
    assert readable.([sni("example.com"), alpn(["imap"])]) == {:no, {:protocols, ["imap"]}}
    assert readable.([alpn(["http/1.1"])]) == {:no, :no_name}
    assert Tcp.readable(:silent) == {:no, :silent}
    assert Tcp.readable(:other) == {:no, :not_tls}
  end
end
