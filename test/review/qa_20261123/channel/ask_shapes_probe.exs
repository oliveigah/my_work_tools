defmodule MWTClient.QAProbes.Channel.AskShapesProbeTest do
  @moduledoc """
  QA probe, guarantee 16: nothing the VM sends makes the sandbox fail. Each
  command of the channel, with fields of every shape JSON allows, through
  the real socket; the sandbox server and the channel must be the same
  processes afterwards, and each ask answered. `propose` is left out: its
  crash is known (threat model review of 2026-11-21).
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox.{Channel, Server}
  alias MWTClient.Vault.Store

  defp ask(username, line) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Channel.socket_path(username)}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(socket, line <> "\n")
    read_all(socket, "")
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _closed} -> acc
    end
  end

  @odd [nil, 0, -1, 1.5, true, [], ["a"], %{}, %{"a" => 1}, "", "x", String.duplicate("y", 300)]

  @commands %{
    "run" =>
      ~w(grant script dir timeout reason agent thread thread_id folder wait suggest_save save_for),
    "call" => ~w(grant values timeout reason wait),
    "request" => ~w(grant need minutes reason wait),
    "wait" => ~w(id wait),
    "why" => ~w(target),
    "ports" => ~w(report),
    "sync" => ~w(path),
    "vm" => ~w(id),
    "project" => ~w(cwd thread_id),
    "worktree" => ~w(action cwd name from slot thread_id),
    "handoffs" => ~w(cwd),
    "handoff" => ~w(stage cwd title onto head body reason)
  }

  test "every command, every odd field, answered, with the server still standing", context do
    server = Store.whereis(Server, context.username)
    channel = Store.whereis(Channel, context.username)
    ref = Process.monitor(server)

    unanswered =
      for {command, fields} <- @commands,
          field <- fields,
          value <- @odd,
          # A run with a real script would wait for the user: keep them quick.
          base = %{"command" => command, "wait" => 0, "reason" => "r", "grant" => "commands"},
          line = Jason.encode!(Map.put(base, field, value)),
          answer = ask(context.username, line),
          answer == "" do
        {command, field, value}
      end

    IO.puts("asks left unanswered: #{inspect(Enum.take(unanswered, 20))} (#{length(unanswered)})")

    refute_received {:DOWN, ^ref, :process, _, _}
    assert Store.whereis(Server, context.username) == server
    assert Store.whereis(Channel, context.username) == channel
    assert unanswered == []
  end
end
