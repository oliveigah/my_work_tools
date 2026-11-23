defmodule MWTClient.QAProbes.FirewallUI.WatchCostTest do
  @moduledoc "Probe: what one observation costs the firewall's watch, one process for all of them."
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Gate, Watch}

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-watch")
  end

  test "observations per second", %{username: username} do
    for i <- 1..10 do
      {:ok, grant} =
        Sandbox.create_grant(username, %{
          "kind" => "token",
          "preset" => "github",
          "name" => "G#{i}",
          "purpose" => "p",
          "hosts" => "api#{i}.example.com",
          "env" => "T#{i}",
          "value" => "ghp_value_#{i}_0123456789abcdef"
        })

      {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    end

    view = Gate.view(username)

    IO.puts(
      "\nview words: #{:erts_debug.flat_size(view)} (#{div(:erts_debug.flat_size(view) * 8, 1024)} KiB copied per observation)"
    )

    {us, _} =
      :timer.tc(fn ->
        for i <- 1..5_000,
            do:
              Watch.observe(
                username,
                {:upload, "h#{rem(i, 50)}.example.org", 443, 262_144, 300_000},
                :infinity
              )
      end)

    IO.puts("tunnel reports: #{div(us, 5_000)} µs each, #{div(5_000 * 1_000_000, max(us, 1))}/s")

    {us, _} =
      :timer.tc(fn ->
        for i <- 1..5_000,
            do:
              Watch.observe(
                username,
                {:lookup, "n#{i}.example#{rem(i, 200)}.org", view.placeholders}
              )
      end)

    IO.puts("lookups: #{div(us, 5_000)} µs each")
  end
end
