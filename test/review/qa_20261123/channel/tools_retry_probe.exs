defmodule MWTClient.QAProbes.Channel.ToolsRetryProbeTest do
  @moduledoc """
  QA probe: an addition through MWT's tools that asks (mwt-create set to Ask
  each time, or past the hour's limit), sent again by the agent while its
  card waits. Spec: "The same call sent again joins its card"; one card,
  one decision.
  """
  use ExUnit.Case, async: true

  alias MWTClient.MCP.Tools
  alias MWTClient.Notes.Library, as: Notes
  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, MwtTools}

  @claims %{agent: "codex", thread: "Notes", thread_id: nil, folder: "/work/x"}

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-tools-retry")
  end

  defp call(username, name, args, wait_ms) do
    {:ok, result} = Tools.call(name, args, MwtTools.caller(username, @claims, wait_ms: wait_ms))
    result
  end

  defp eventually(fun, tries \\ 300) do
    case fun.() do
      nil when tries > 0 -> Process.sleep(10) && eventually(fun, tries - 1)
      other -> other
    end
  end

  test "an addition sent again while it waits is made twice on one decision", %{
    username: username
  } do
    {:ok, _} = Sandbox.set_mode(username, "mwt-create", :ask)
    args = %{"title" => "Release checklist", "body" => "1. tag"}

    first = call(username, "create_note", args, 50)
    IO.puts("first call: #{hd(first["content"])["text"]}")
    [_, id] = Regex.run(~r/as ask (tool-[a-z0-9]+)/, hd(first["content"])["text"])

    second = call(username, "create_note", args, 50)
    IO.puts("second call: #{hd(second["content"])["text"]}")

    [card] = Sandbox.snapshot(username).waiting
    IO.puts("cards waiting: 1, retries: #{card.retries}")

    :ok = Sandbox.decide(username, id, :allow_once)

    _ =
      eventually(fn ->
        case Notes.list(username) do
          [_, _] = two -> two
          _ -> nil
        end
      end)

    Process.sleep(300)
    notes = Notes.list(username)
    IO.puts("notes made on one decision: #{length(notes)}")
    IO.puts("mwt wait: #{inspect(Channel.answer("wait", %{"id" => id, "wait" => 0}, username))}")
    assert length(notes) == 1
  end
end
