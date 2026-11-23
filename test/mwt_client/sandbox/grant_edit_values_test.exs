defmodule MWTClient.Sandbox.GrantEditValuesTest do
  @moduledoc """
  An edit applies to the next use: one that changes how a token grant's
  value is made drops what MWT minted the old way, and what it made from
  it; one that changes only its words keeps them.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server

  setup do
    dir = Path.join(System.tmp_dir!(), "grant-edit-values-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> MWTClient.TestFolders.remove!(dir) end)
    MWTClient.VaultHelpers.unlocked_identity("grant-edit-values") |> Map.put(:dir, dir)
  end

  defp request(grant) do
    %{
      host: "api.example.com",
      method: "GET",
      path: "/user",
      headers: [{"authorization", "Bearer #{grant.placeholder}"}],
      body: ""
    }
  end

  defp sent(username, grant) do
    {:forward, replace, _scan} = Server.call(username, {:authorize, request(grant)}, 15_000)
    replace.request |> Enum.map(& &1.to) |> List.first()
  end

  # Mints one value per run, and counts its runs in `dir`.
  defp mint(dir, account), do: ~s(echo x >> #{dir}/runs; echo "token-of-#{account}-0123456789")

  defp edit(username, grant, attrs) do
    Sandbox.update_grant(
      username,
      grant.id,
      Map.merge(
        %{"name" => "Cloud", "purpose" => "Cloud APIs", "hosts" => "api.example.com"},
        attrs
      )
    )
  end

  defp runs(dir), do: dir |> Path.join("runs") |> File.read!() |> String.split() |> length()

  test "the next request after the mint is edited carries the new command's value",
       %{username: username, dir: dir} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Cloud",
        "purpose" => "Cloud APIs",
        "hosts" => "api.example.com",
        "source" => "minted",
        "mint" => mint(dir, "deployer")
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    assert sent(username, grant) == "token-of-deployer-0123456789"

    {:ok, _} = edit(username, grant, %{"mint" => mint(dir, "reader")})
    assert sent(username, grant) == "token-of-reader-0123456789"

    # How long it keeps one is how it is made too.
    {:ok, _} = edit(username, grant, %{"mint" => mint(dir, "reader"), "keep_minutes" => "4"})
    assert sent(username, grant) == "token-of-reader-0123456789"
    assert runs(dir) == 3
  end

  test "a mint under way as the mint is edited keeps nothing, and the next one mints anew",
       %{username: username, dir: dir} do
    go = Path.join(dir, "go")
    # Counts its run, then waits for `go` before it prints.
    slow =
      ~s(echo x >> #{dir}/runs; while [ ! -e #{go} ]; do sleep 0.02; done; ) <>
        ~s(echo "token-of-deployer-0123456789")

    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Cloud",
        "purpose" => "Cloud APIs",
        "hosts" => "api.example.com",
        "source" => "minted",
        "mint" => slow
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    asked = Task.async(fn -> Server.call(username, {:authorize, request(grant)}, 15_000) end)

    # The mint has begun: its count, read raw, as a program elsewhere
    # writes it (no message tells this test).
    began = fn began ->
      case MWTClient.Files.read(Path.join(dir, "runs")) do
        {:ok, _} ->
          :ok

        {:error, :enoent} ->
          receive do
          after
            10 -> began.(began)
          end
      end
    end

    began.(began)
    {:ok, _} = edit(username, grant, %{"mint" => mint(dir, "reader")})
    File.write!(go, "")

    assert {:deny, 503, body} = Task.await(asked, 15_000)
    assert body =~ "mwt_no_value"
    refute body =~ "token-of-deployer"

    assert sent(username, grant) == "token-of-reader-0123456789"
    assert runs(dir) == 2
  end

  test "an edit of its words alone keeps what was minted", %{username: username, dir: dir} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "token",
        "name" => "Cloud",
        "purpose" => "Cloud APIs",
        "hosts" => "api.example.com",
        "source" => "minted",
        "mint" => mint(dir, "deployer")
      })

    {:ok, _} = Sandbox.turn_on(username, grant.id, 60, :all)
    assert sent(username, grant) == "token-of-deployer-0123456789"

    {:ok, _} =
      edit(username, grant, %{"purpose" => "Google APIs", "mint" => mint(dir, "deployer")})

    assert sent(username, grant) == "token-of-deployer-0123456789"
    assert runs(dir) == 1
  end
end
