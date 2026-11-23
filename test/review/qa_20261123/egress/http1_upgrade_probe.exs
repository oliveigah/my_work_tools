defmodule MWTClient.QaProbes.Egress.Http1UpgradeTest do
  @moduledoc """
  QA probe: a request with an Upgrade header the host doesn't take (it
  answers 200, not 101). What the VM sends after it goes up unjudged?
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Egress.Driver.Http1

  @ctx %{
    transport: :tcp,
    name: "api.example.com",
    ip: {93, 184, 216, 34},
    port: 443,
    under: "internet",
    tls?: true,
    alpn: "http/1.1",
    first: :vm,
    linked?: false,
    why: :every_host,
    limit: 65_536,
    started: 0,
    options: []
  }

  test "a second request after an Upgrade the host ignores goes up without a verdict" do
    {[{:read, :vm, _}], http} = Http1.init(@ctx)

    first =
      "GET / HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: foo\r\nConnection: keep-alive, Upgrade\r\n\r\n"

    {[{:judge, request} | _], http} = Http1.handle_data(:vm, first, http)
    {actions, http} = Http1.handle_verdict(request.id, {:allow, %{request: [], answer: []}}, http)
    head = for {:write, :host, b} <- actions, into: "", do: IO.iodata_to_binary(b)

    {_actions, http} =
      Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok", http)

    second = "DELETE /repos/o/r HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
    {actions, _http} = Http1.handle_data(:vm, second, http)
    up = for {:send, :host, b} <- actions, into: "", do: IO.iodata_to_binary(b)

    IO.puts(
      "\n[probe] head MWT wrote keeps: #{inspect(Regex.run(~r/connection: [^\r]*/, head))}; " <>
        "second request judged: #{Enum.any?(actions, &match?({:judge, _}, &1))}; sent up: #{inspect(String.slice(up, 0, 25))}"
    )

    assert up == second
    refute Enum.any?(actions, &match?({:judge, _}, &1))
  end
end
