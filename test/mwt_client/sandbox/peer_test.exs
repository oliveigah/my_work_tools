defmodule MWTClient.Sandbox.PeerTest do
  @moduledoc """
  Only processes of the VM's bubble get in through its sockets. Another
  program running as you that connects to one is closed unanswered, and
  said in the activity log: otherwise it would be the VM to MWT, with its
  network, the credentials its grants put in, and its agent channel.

  Each test says nothing of this BEAM counts as a bubble
  (`StandIns.put_peer_roots/2`), so only what `bubble.pid` names does; the
  BEAM's own parent stands in for a bubble it descends from.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Bubble, Channel, Dns, Egress, Peer, Sockets}
  alias MWTClient.StandIns

  setup do
    %{username: username} = MWTClient.VaultHelpers.unlocked_identity("peer")
    StandIns.put_peer_roots(username, [])
    Sockets.ensure_host!(username)

    assert Enum.find_value(1..200, fn _ ->
             Sandbox.snapshot(username).proxy.listening? || (Process.sleep(10) && nil)
           end)

    %{username: username}
  end

  defp beam, do: List.to_integer(:os.getpid())

  defp parent_of_beam do
    {:ok, %{parent: parent}} = Peer.process(beam())
    {:ok, %{started: started}} = Peer.process(parent)
    {parent, started}
  end

  defp bubble!(username, text),
    do: File.write!(Sockets.host_path(username, "bubble.pid"), text)

  defp connect(path, options \\ []) do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false] ++ options)
    socket
  end

  # Whether the proxy answered a CONNECT to an address MWT always refuses
  # (403), rather than closing unanswered.
  defp proxy_answers?(username) do
    socket = connect(Egress.path(username))
    _ = :gen_tcp.send(socket, "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
    answer = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
    match?({:ok, "HTTP/1.1 403" <> _}, answer)
  end

  defp refusals(username, socket_name) do
    _ = :sys.get_state(MWTClient.Vault.Store.whereis(Sandbox.Server, username))

    for %{outcome: :blocked, summary: summary} <- Sandbox.events(username),
        String.starts_with?(
          summary,
          "A program outside the VM connected to the VM's #{socket_name},"
        ),
        do: summary
  end

  test "a program outside the bubble is closed unanswered on each socket, and said once a minute",
       %{username: username} do
    refute proxy_answers?(username)
    refute proxy_answers?(username)

    dns = connect(Dns.path(username), packet: 2)
    question = <<0x1234::16, 0x0100::16, 1::16, 0::48, 7, "example", 3, "com", 0, 1::16, 1::16>>
    _ = :gen_tcp.send(dns, question)
    assert {:error, _} = :gen_tcp.recv(dns, 0, 2_000)

    channel = connect(Channel.socket_path(username))
    _ = :gen_tcp.send(channel, ~s({"command": "grants"}\n))
    assert {:error, _} = :gen_tcp.recv(channel, 0, 2_000)

    # Each says which program it was, by the name it gave itself.
    assert [proxy] = refusals(username, "proxy")
    assert proxy =~ "beam.smp (process #{beam()})"
    assert [_] = refusals(username, "DNS")
    assert [_] = refusals(username, "agent channel")
  end

  test "a process the bubble's first process started is let in, however deep", %{
    username: username
  } do
    {parent, started} = parent_of_beam()
    bubble!(username, "#{parent} #{started}\n")

    assert Peer.inside?(username, beam())
    assert proxy_answers?(username)
    assert refusals(username, "proxy") == []
  end

  test "a process given the bubble's id after it ended doesn't pass for it", %{
    username: username
  } do
    {parent, started} = parent_of_beam()

    # Started at another time than the bubble did.
    bubble!(username, "#{parent} #{String.to_integer(started) + 1}\n")
    refute Peer.inside?(username, beam())
    refute proxy_answers?(username)

    # Written by an MWT before the time was: nothing passes for it.
    bubble!(username, "#{parent}\n")
    refute Peer.inside?(username, beam())

    # The bubble's process ended.
    File.rm!(Sockets.host_path(username, "bubble.pid"))
    refute Peer.inside?(username, beam())
  end

  test "the bubble's launcher writes its process id and the time it started", %{
    username: username
  } do
    dir = Sockets.host_dir(username)
    pid_file = Path.join(dir, "launcher.pid")
    seccomp = Path.join(dir, "launcher.seccomp")
    File.write!(seccomp, "")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        args: ["-c", Bubble.launcher(), "mwt-bubble", "sleep", "30"],
        env: [
          {~c"MWT_PIDFILE", String.to_charlist(pid_file)},
          {~c"MWT_LOG", String.to_charlist(Path.join(dir, "launcher.log"))},
          {~c"MWT_SECCOMP", String.to_charlist(seccomp)}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"]) end)

    text =
      Enum.find_value(1..200, fn _ ->
        case File.read(pid_file) do
          {:ok, text} when text != "" -> text
          _ -> Process.sleep(10) && nil
        end
      end)

    # The shell that became the program it ran: same id, same start.
    assert [pid, started] = String.split(text)
    assert String.to_integer(pid) == os_pid
    assert {:ok, %{started: ^started}} = Peer.process(os_pid)
  end
end
