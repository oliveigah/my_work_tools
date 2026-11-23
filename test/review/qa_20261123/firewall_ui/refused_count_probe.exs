defmodule MWTClient.QAProbes.FirewallUI.RefusedCountTest do
  @moduledoc """
  Probe: while isolated, the isolation card's "N refused since" counts the
  monitor's own process samples (MWT reading the VM every 5 s), though
  the VM sent nothing.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup do
    MWTClient.VaultHelpers.unlocked_identity("qa-refused")
  end

  test "monitor samples count as things refused while isolated", %{username: username} do
    :ok = Sandbox.firewall_isolate(username)
    before = Sandbox.firewall(username).refused

    for _ <- 1..12 do
      Server.cast(username, {:processes, [%{pid: 1, name: "init", cpu: 0.1}]})
    end

    after_count = Sandbox.firewall(username).refused
    IO.puts("\nrefused before: #{before}, after 12 monitor samples (one minute): #{after_count}")
    assert after_count == before + 12
  end
end
