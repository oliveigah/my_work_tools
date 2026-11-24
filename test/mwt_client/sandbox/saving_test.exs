defmodule MWTClient.Sandbox.SavingTest do
  @moduledoc """
  What the sandbox writes to disk without a clean stop to write it, as
  when `cargo tauri dev` restarts MWT.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Server
  alias MWTClient.Sandbox.Server.State
  alias MWTClient.Vault.Store

  setup do
    identity = MWTClient.VaultHelpers.unlocked_identity("saving")
    base = Path.join(System.tmp_dir!(), "saving-#{System.unique_integer([:positive])}")
    for name <- ~w(one two), do: File.mkdir_p!(Path.join(base, name))
    on_exit(fn -> File.rm_rf!(base) end)
    Map.merge(identity, %{base: base, pid: Store.whereis(Server, identity.username)})
  end

  defp shares_on_disk(%{username: username, key: key}) do
    saved = State.restore(username, key)
    Enum.map(saved.settings.shares, & &1.path)
  end

  # As a reload of the server's code in development leaves it: gen_server
  # skipped the :flush, and the timer that sent it is gone.
  defp lose_save(pid) do
    :sys.replace_state(pid, fn state ->
      if state.flush, do: Process.cancel_timer(state.flush)
      state
    end)
  end

  # The server's next :flush, once handled.
  defp await_save(pid) do
    :erlang.trace(pid, true, [:receive])
    assert_receive {:trace, ^pid, :receive, :flush}, 2_000
    :erlang.trace(pid, false, [:receive])
    _ = :sys.get_state(pid)
  end

  test "a file grant saved before they were gone is dropped as MWT starts, with its value",
       context do
    # As an MWT from before 2026-11-18 saved one.
    kube = %MWTClient.Sandbox.Grant{
      id: "kube",
      name: "Kubeconfig",
      kind: :file,
      purpose: "The staging cluster",
      path: "/mnt/mwt/files/kubeconfig"
    }

    :sys.replace_state(context.pid, fn state ->
      state = %{
        state
        | grants: state.grants ++ [kube],
          values: Map.put(state.values, "kube", "k")
      }

      :ok = State.persist(state)
      state
    end)

    saved = State.restore(context.username, context.key)
    refute Enum.any?(saved.grants, &(&1.id == "kube"))
    refute Map.has_key?(saved.values, "kube")
    assert saved.dropped_files == ["Kubeconfig"]

    # Started again from that, it says so once, and saves the grants without it.
    ref = Process.monitor(context.pid)

    ExUnit.CaptureLog.capture_log(fn ->
      GenServer.cast(context.pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, _, _crash}
    end)

    _ = :sys.get_state(Store.supervisor(context.username))
    assert Store.whereis(Server, context.username) not in [nil, context.pid]

    assert Enum.any?(
             Sandbox.events(context.username),
             &(&1.summary =~ "Removed, with the values you saved: Kubeconfig")
           )

    assert State.restore(context.username, context.key).dropped_files == []
  end

  test "a grant saved with checks loses them as MWT starts, and the log names them", context do
    # As an MWT from before 2026-11-24 saved one: checks were a field.
    github =
      Map.put(
        %MWTClient.Sandbox.Grant{
          id: "gh-checked",
          name: "GitHub, checked",
          kind: :token,
          purpose: "Read",
          hosts: ["api.github.com"]
        },
        :checks,
        [%{id: "check-1", name: "the key can't push", script: "true", on: [:enable], gates: true}]
      )

    :sys.replace_state(context.pid, fn state ->
      state = %{state | grants: state.grants ++ [github]}
      :ok = State.persist(state)
      state
    end)

    saved = State.restore(context.username, context.key)
    grant = Enum.find(saved.grants, &(&1.id == "gh-checked"))
    refute Map.has_key?(grant, :checks)
    assert saved.dropped_checks == [{"GitHub, checked", ["the key can't push"]}]

    ref = Process.monitor(context.pid)

    ExUnit.CaptureLog.capture_log(fn ->
      GenServer.cast(context.pid, :no_handler_matches_this)
      assert_receive {:DOWN, ^ref, :process, _, _crash}
    end)

    _ = :sys.get_state(Store.supervisor(context.username))

    assert Enum.any?(
             Sandbox.events(context.username),
             &(&1.summary =~
                 "Checks removed, which no longer run: GitHub, checked: the key can't push")
           )

    assert State.restore(context.username, context.key).dropped_checks == []
  end

  test "a change whose save got lost is saved with the next one", context do
    %{username: username, base: base, pid: pid} = context
    one = Path.join(base, "one")
    two = Path.join(base, "two")

    {:ok, _} = Sandbox.add_share(username, one)
    lose_save(pid)
    {:ok, _} = Sandbox.add_share(username, two)
    await_save(pid)

    assert Enum.sort(shares_on_disk(context)) == [one, two]
  end

  test "with no change after it, the sweep saves it", context do
    %{username: username, base: base, pid: pid} = context
    one = Path.join(base, "one")

    {:ok, _} = Sandbox.add_share(username, one)
    lose_save(pid)
    send(pid, :sweep)
    await_save(pid)

    assert shares_on_disk(context) == [one]
  end
end
