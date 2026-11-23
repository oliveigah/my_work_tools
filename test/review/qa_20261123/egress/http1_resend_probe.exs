defmodule MWTClient.QaProbes.Egress.Http1ResendTest do
  @moduledoc """
  QA probe: a kept link that fails under a write. The spec sends the
  request again only when doing it twice changes nothing (GET, HEAD,
  OPTIONS, PUT, DELETE, whole body held); any other gets 502. What does
  the driver do with a large POST whose link fails mid-body?
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

  defp up(actions),
    do:
      for(
        {tag, :host, bytes} <- actions,
        tag in [:send, :write],
        into: "",
        do: IO.iodata_to_binary(bytes)
      )

  @allow {:allow, %{request: [], answer: []}}

  test "a POST on a kept link that fails mid-body is sent again, its middle lost" do
    {[{:read, :vm, _}], http} = Http1.init(@ctx)

    # A first request keeps the link.
    get = "GET /a HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
    {[{:judge, first} | _], http} = Http1.handle_data(:vm, get, http)
    {_actions, http} = Http1.handle_verdict(first.id, @allow, http)

    {_actions, http} =
      Http1.handle_data(:host, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n", http)

    # A large POST on the same link.
    total = 200_000
    head = "POST /upload HTTP/1.1\r\nHost: api.example.com\r\ncontent-length: #{total}\r\n\r\n"
    start = :binary.copy("A", 70_000)
    {[{:judge, post} | _], http} = Http1.handle_data(:vm, head <> start, http)
    {actions, http} = Http1.handle_verdict(post.id, @allow, http)
    refute Enum.any?(actions, &match?({:connect, _}, &1))
    first_sent = byte_size(up(actions))

    # The middle of the body goes on the kept link...
    {actions, http} = Http1.handle_data(:vm, :binary.copy("B", 50_000), http)
    middle_sent = byte_size(up(actions))

    # ...which then fails under a write.
    {actions, http} = Http1.handle_closed(:host, {:send_failed, :closed}, http)
    again = up(actions)

    # The rest of the body follows on the new link.
    {actions, _http} = Http1.handle_data(:vm, :binary.copy("C", total - 70_000 - 50_000), http)
    rest = up(actions)

    new_link = again <> rest
    [_, body] = String.split(new_link, "\r\n\r\n", parts: 2)

    IO.puts(
      "\n[probe] old link took #{first_sent} + #{middle_sent} bytes; then " <>
        "#{inspect(Enum.filter(actions, &match?({:connect, _}, &1)))} " <>
        "new link: #{String.slice(again, 0, 20)}... body #{byte_size(body)} of #{total} bytes, " <>
        "B bytes in it: #{length(:binary.matches(body, "B"))}"
    )

    assert String.starts_with?(again, "POST /upload")
    assert byte_size(body) < total
  end
end
