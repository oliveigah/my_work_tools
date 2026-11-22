defmodule MWTClient.Sandbox.DriverTest do
  @moduledoc """
  Picking the driver for a call (`MWTClient.Sandbox.Egress.Driver`): by the
  protocol settled in TLS, or by its first bytes, the drivers asked in
  order; and why a call isn't read, in words for the log.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver
  alias MWTClient.Sandbox.Egress.Driver.{Http1, Raw}
  alias MWTClient.SandboxLineDriver

  @drivers [SandboxLineDriver, Http1, Raw]
  @plain %{transport: :tcp, tls?: false}
  @tls %{transport: :tcp, tls?: true}

  test "the first driver to claim the bytes takes the call, and Raw anything left" do
    assert Driver.pick("TINY GET /users\n", @plain, @drivers) == {:ok, SandboxLineDriver}
    assert Driver.pick("GET / HTTP/1.1\r\n", @tls, @drivers) == {:ok, Http1}

    # Plain HTTP, and anything on UDP, is no driver's yet.
    assert Driver.pick("GET / HTTP/1.1\r\n", @plain, @drivers) == {:ok, Raw}
    assert Driver.pick("GET / HTTP/1.1\r\n", %{@tls | transport: :udp}, @drivers) == {:ok, Raw}
    assert Driver.pick("GET / HTTP/1.1\r\n", @plain, [Http1]) == :none
  end

  test "a driver asking for more holds the pick, until no more will come" do
    assert Driver.pick("TI", @plain, @drivers) == :more
    assert Driver.pick("TI", @plain, @drivers, true) == {:ok, Raw}
    assert Driver.pick("TINY ", @plain, @drivers) == {:ok, SandboxLineDriver}

    # Asked after the one that takes it, it doesn't.
    assert Driver.pick("TI", @plain, [Raw, SandboxLineDriver]) == {:ok, Raw}
  end

  test "the protocols offered in TLS are the drivers', and the one settled picks its driver" do
    assert Driver.alpn(@drivers) == ["http/1.1"]
    assert Driver.for_alpn("http/1.1", @drivers) == Http1
    assert Driver.for_alpn("h2", @drivers) == nil
    assert Driver.for_alpn(nil, @drivers) == nil
  end

  test "why, in words for the log, the VM's protocol names only as visible text" do
    assert Driver.why(:h2_only) =~ "only HTTP/2"
    assert Driver.why(:listed) =~ "set it as Not read"

    assert Driver.why({:protocols, ["imap", "x\ny"]}) ==
             "the client offered imap, a protocol unnamed, which MWT doesn't read"
  end
end
