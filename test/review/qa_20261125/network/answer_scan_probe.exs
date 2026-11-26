defmodule MWTClient.QaProbes.Network.AnswerScanProbeTest do
  @moduledoc """
  QA 2026-11-25, point 13 of docs/grant_mental_model.md: "A credential's
  real value never reaches anything the agent wrote, on any channel ...
  what MWT sends back (answers, output, tool results) is scanned, and
  never carries one", and "What MWT sees": on a host it reads, MWT "cuts
  the connection if one of your values comes back".

  Through the proxy, over TCP and TLS, as the VM's own requests go
  (harness as `EgressLeaksTest`'s). The service answers with a real value
  MWT holds: the one MWT put in the request is cut (the guarantee as
  tested today, "Guarantees to test" 19); this probes another one.

  Scenario: GitHub's token and Stripe's key are both in MWT. The agent
  reads a service's config through GitHub's grant (a service returning
  secrets it keeps: Heroku config vars, Vercel env, Secret Manager), and
  the answer holds Stripe's key.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.CertificateAuthority, as: CA
  alias MWTClient.Sandbox.Egress.Tcp

  @github "ghp_REAL_GITHUB_VALUE_0123456789"
  @stripe "sk_live_REAL_STRIPE_VALUE_0123456789"

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("qa-answer-scan")
    upstream = start_upstream()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    options = [
      upstream: fn _host ->
        :ssl.connect(~c"127.0.0.1", upstream, verify: :verify_none, active: false, mode: :binary)
      end
    ]

    spawn_link(fn -> accept(listen, username, options) end)
    [{:Certificate, ca, _}] = username |> Sandbox.ca_pem() |> :public_key.pem_decode()
    %{username: username, proxy: port, ca: ca}
  end

  defp accept(listen, username, options) do
    {:ok, client} = :gen_tcp.accept(listen)
    pid = spawn(fn -> receive do: (:go -> Tcp.run(client, username, options)) end)
    :gen_tcp.controlling_process(client, pid)
    send(pid, :go)
    accept(listen, username, options)
  end

  defp start_upstream do
    leaf = CA.leaf(CA.new(), "upstream.test")

    {:ok, listen} =
      :ssl.listen(0, CA.ssl_options(leaf) ++ [active: false, mode: :binary, reuseaddr: true])

    {:ok, {_, port}} = :ssl.sockname(listen)
    spawn_link(fn -> serve(listen) end)
    port
  end

  # Answers by the path: the value it names, in its body.
  defp serve(listen) do
    {:ok, socket} = :ssl.transport_accept(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.handshake(socket)
      {:ok, got} = :ssl.recv(socket, 0, 5_000)
      [_, path] = Regex.run(~r/\A[A-Z]+ ([^ ]+) /, got)

      body =
        case path do
          "/stripe" -> ~s({"STRIPE_SECRET_KEY":"#{@stripe}"})
          "/github" -> ~s({"token":"#{@github}"})
          _ -> "{}"
        end

      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
          body
      )

      :ssl.close(socket)
    end)

    serve(listen)
  end

  defp https(%{proxy: proxy, ca: ca}, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", proxy, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, "CONNECT 140.82.112.3:443 HTTP/1.1\r\nHost: 140.82.112.3:443\r\n\r\n")

    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0, 5_000)

    {:ok, tls} =
      :ssl.connect(socket,
        verify: :verify_peer,
        cacerts: [ca],
        server_name_indication: ~c"api.github.com",
        active: false,
        mode: :binary
      )

    :ok = :ssl.send(tls, request)
    MWTClient.SandboxProxy.read_answer(tls, :ssl)
  end

  defp grants(username) do
    {:ok, github} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "preset" => "github",
        "name" => "GitHub",
        "purpose" => "The GitHub API",
        "hosts" => "api.github.com",
        "env" => "GH_TOKEN",
        "value" => @github
      })

    {:ok, github} = Sandbox.turn_on(username, github.id, 60, :all)

    {:ok, _stripe} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Stripe",
        "purpose" => "Refunds report",
        "hosts" => "api.stripe.com",
        "env" => "STRIPE_KEY",
        "value" => @stripe
      })

    github
  end

  defp get(path, headers),
    do:
      "GET #{path} HTTP/1.1\r\nHost: api.github.com\r\n" <>
        Enum.map_join(headers, &(&1 <> "\r\n")) <> "\r\n"

  test "the value MWT put in the request, echoed, is cut (holds today)", context do
    github = grants(context.username)
    answer = https(context, get("/github", ["Authorization: Bearer #{github.placeholder}"]))
    refute answer =~ @github
  end

  test "PROBE: another credential's real value in the answer to the agent's own request is cut",
       context do
    github = grants(context.username)
    answer = https(context, get("/stripe", ["Authorization: Bearer #{github.placeholder}"]))

    refute answer =~ @stripe,
           "Stripe's real value reached the VM in the answer to a request carrying GitHub's " <>
             "placeholder: only the values MWT put in a request are looked for in its answer " <>
             "(Driver.Http1.echo/2, replace.answer). Answer: #{inspect(answer)}"
  end

  test "PROBE: a real value in the answer to a request on a read host that carried none is cut",
       context do
    grants(context.username)
    answer = https(context, get("/github", []))

    refute answer =~ @github,
           "GitHub's real value reached the VM in the answer to a request MWT read (its host " <>
             "is a token grant's) that carried no placeholder. Answer: #{inspect(answer)}"
  end
end
