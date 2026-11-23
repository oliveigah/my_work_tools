defmodule MWTClient.QaProbes.Grants.MintPerHostFanoutTest do
  @moduledoc """
  Probe: a grant minted per host (`Grant.mint_per`) with a `*.` host keeps
  one value per host name. The VM picks the name. How many mint commands
  run at once on this machine when it sends requests to many names?
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup do
    dir = Path.join(System.tmp_dir!(), "qa-mint-fanout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> MWTClient.TestFolders.remove!(dir) end)
    MWTClient.VaultHelpers.unlocked_identity("qa-mint-fanout") |> Map.put(:dir, dir)
  end

  test "each new name the VM sends to starts another mint, with nothing bounding them",
       %{username: username, dir: dir} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Run",
        "purpose" => "Cloud Run services behind IAP",
        "hosts" => "*.run.example",
        "source" => "minted",
        "mint_per" => "host",
        "mint" => ~s(touch "#{dir}/$MWT_HOST"; sleep 3; echo "id-token-for-$MWT_HOST-0000")
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)

    n = 40

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          Server.call(
            username,
            {:authorize,
             %{
               host: "svc-#{i}.run.example",
               method: "GET",
               path: "/",
               headers: [{"authorization", "Bearer #{grant.placeholder}"}],
               body: ""
             }},
            30_000
          )
        end)
      end

    Process.sleep(1_500)
    running = dir |> File.ls!() |> length()
    IO.inspect(running, label: "mint commands started within 1.5 s, of #{n} names")

    results = Task.await_many(tasks, 30_000)
    assert Enum.all?(results, &match?({:forward, _, _}, &1))
    assert running == n

    minted = :sys.get_state(MWTClient.Vault.Store.whereis(Server, username)).minted
    IO.inspect(map_size(minted), label: "values kept for the grant")
  end
end
