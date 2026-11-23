defmodule MWTClient.QAProbes.Channel.ScriptBytesProbeTest do
  @moduledoc """
  QA probes: a script holding bytes that don't show, through the real mwt
  command. Spec ("Asking"): "A script holding anything that doesn't show (a
  control character, ..., bytes that aren't UTF-8) is refused before it
  waits for you, and the agent is told which"; 122 is "The ask was wrong".
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox

  test "a script with a byte that isn't UTF-8", context do
    {output, status} =
      mwt(context, ["run", "commands", "--reason", "r", "--wait", "0"],
        input: "echo caf" <> <<0xE9>> <> "\n"
      )

    IO.puts("latin-1 script: status=#{status} output=#{inspect(output)}")
    assert status == 122
    assert output =~ "UTF-8" or output =~ "don't show"
  end

  test "a script with a control character", context do
    {output, status} =
      mwt(context, ["run", "commands", "--reason", "r", "--wait", "0"],
        input: "printf '\e[31mred\e[0m'\n"
      )

    waiting = Sandbox.snapshot(context.username).waiting
    IO.puts("ESC script: status=#{status} output=#{inspect(output)}")
    IO.puts("cards: #{inspect(Enum.map(waiting, & &1.script))}")
    assert status == 122
  end

  test "a call value that isn't UTF-8", context do
    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "command",
        "name" => "echo it",
        "purpose" => "Echoes a word",
        "script" => ~S[printf '%s' "$WORD"],
        "dir" => context.project,
        "params" => "WORD:text:a word"
      })

    {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)

    {output, status} =
      mwt(context, ["call", grant.id, "WORD=caf" <> <<0xE9>>, "--reason", "r", "--wait", "0"])

    IO.puts("latin-1 value: status=#{status} output=#{inspect(output)}")
    assert status == 122
  end
end
