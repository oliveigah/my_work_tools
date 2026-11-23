defmodule MWTClient.QAProbes.CrashBlastRadiusTest do
  # Probe: how far a crash of the sandbox server reaches when it repeats.
  # The per-identity stores live under a DynamicSupervisor partition with
  # the default intensity (3 restarts in 5 s).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MWTClient.Sandbox.Server
  alias MWTClient.Vault.{Keyring, Store}

  setup do
    MWTClient.VaultHelpers.unlocked_identity("blastprobe")
  end

  test "four crashes of the sandbox server in a row", %{username: username} do
    keyring = Store.whereis(Keyring, username)
    assert is_pid(keyring)
    keyring_ref = Process.monitor(keyring)

    capture_log(fn ->
      for n <- 1..4 do
        pid = wait_for(fn -> Store.whereis(Server, username) end)
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        IO.puts("crash #{n}: server #{inspect(pid)} killed")
        Process.sleep(50)
      end

      Process.sleep(500)
    end)

    keyring_alive? = Process.alive?(keyring)
    server_now = Store.whereis(Server, username)
    unlocked? = Store.open?(username)

    IO.puts(
      "after 4 crashes: keyring alive=#{keyring_alive?} server=#{inspect(server_now)} unlocked?=#{unlocked?}"
    )

    refute_received {:DOWN, ^keyring_ref, _, _, _}
    assert keyring_alive?, "the identity's keyring went down with the sandbox server"
  end

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end
end
