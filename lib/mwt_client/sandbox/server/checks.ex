defmodule MWTClient.Sandbox.Server.Checks do
  @moduledoc """
  A grant's checks in the sandbox server's state (`MWTClient.Sandbox.Check`
  says what one is): running them, keeping how each went last, and acting
  on a gating one that fails.

    * **When:** a grant's `:enable` checks run as it turns on (by you, an
      agent's ask, or its start setting); its `:daily`
      ones once a day while it is on (`due/1`, on the server's sweep); and
      all of them when you ask, or as one is added.
    * **Until a gating check passes, the grant is paused**
      (`failing/1`): `MWTClient.Sandbox.Policy` refuses every use. One that
      fails turns the grant off, refuses what waited on
      it, and tells you.
    * **Each runs confined** (`MWTClient.Sandbox.Confine`) in a folder of
      its own, for at most a minute, with the grant's own real value when
      it is a token grant, in the variables the VM sees its placeholder
      in. Its output, the first 4 KiB, is for you only.

  Runs in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Notifications
  alias MWTClient.Sandbox.{Check, Grant, HostRun, Scratch}
  alias MWTClient.Sandbox.Server.{Approvals, State, Values}

  @timeout 60
  @output 4 * 1024

  @doc "The grants a gating check holds off now, each with why, in the words the agent hears."
  @spec failing(map()) :: %{String.t() => String.t()}
  def failing(state) do
    state.grants
    |> Check.failing(Map.get(state, :checks, %{}), DateTime.utc_now())
    |> Map.new(fn {id, name} -> {id, "its check “#{name}” doesn't hold"} end)
  end

  @doc "How a grant's check went last, or nil."
  def result(state, grant_id, check_id),
    do: Map.get(Map.get(state, :checks, %{}), {grant_id, check_id})

  @doc "Whether a check is running now."
  def running?(state, grant_id, check_id),
    do: MapSet.member?(Map.get(state, :checking, MapSet.new()), {grant_id, check_id})

  @doc """
  Runs `grant`'s checks: those that run `:enable`, or `:all`. One already
  running isn't started again.
  """
  def run(state, %Grant{checks: []}, _which), do: state

  def run(state, %Grant{} = grant, which) do
    checks =
      Enum.filter(grant.checks, fn check ->
        (which == :all or which in check.on) and not running?(state, grant.id, check.id)
      end)

    Enum.reduce(checks, state, &start(&2, grant, &1))
  end

  @doc "Runs the `:enable` checks of every grant in `ids` that has any."
  def run_enable(state, ids) do
    state.grants
    |> Enum.filter(&(&1.id in ids and &1.checks != []))
    |> Enum.reduce(state, &run(&2, &1, :enable))
  end

  @doc "Runs the daily checks that are due, of the grants that are on."
  def due(state) do
    now = DateTime.utc_now()

    for grant <- state.grants,
        Grant.on?(grant, now),
        check <- grant.checks,
        Check.due?(check, result(state, grant.id, check.id), now),
        not running?(state, grant.id, check.id),
        reduce: state do
      state -> start(state, grant, check)
    end
  end

  # A token grant's check gets its value first, as a confined command does.
  defp start(state, %Grant{kind: :token} = grant, check) do
    state = mark(state, grant, check)

    Values.fetch(state, grant, fn state, result ->
      case result do
        {:ok, value} ->
          launch(state, grant, check, [{grant, value}])

        {:error, :no_value} ->
          finished(state, {grant.id, check.id}, failed("#{grant.name} has no value yet"))

        {:error, message} ->
          finished(state, {grant.id, check.id}, failed("minting failed: #{message}"))
      end
    end)
  end

  defp start(state, grant, check), do: state |> mark(grant, check) |> launch(grant, check, [])

  defp mark(state, grant, check),
    do:
      Map.update(
        state,
        :checking,
        MapSet.new([{grant.id, check.id}]),
        &MapSet.put(&1, {grant.id, check.id})
      )

  defp failed(message), do: %{exit: nil, output: "", error: message}

  defp launch(state, grant, check, pairs) do
    values =
      for {with, value} <- pairs, name <- with.env, do: {name, value}

    paths = for {with, _value} <- pairs, name <- with.file_env, do: {name, Grant.token_file(with)}
    carried = for {{_with, value}, n} <- Enum.with_index(pairs, 1), do: {"MWT_FILE_#{n}", value}

    files =
      for {{with, _value}, n} <- Enum.with_index(pairs, 1),
          do: {"MWT_FILE_#{n}", Grant.token_file(with)}

    reads = Map.get(state.settings, :confine_reads)

    State.task(state, {:check, grant.id, check.id}, fn ->
      Scratch.with_dir("mwt-check", fn dir ->
        HostRun.run(
          %{
            script: check.script,
            dir: dir,
            timeout: @timeout,
            confine: %{
              writes: true,
              reads: reads,
              path: nil,
              values: values ++ paths ++ carried,
              files: files
            }
          },
          fn _group -> :ok end
        )
      end)
    end)
  end

  @doc """
  Takes how a check went: kept, logged, and, for a gating check that
  failed, the grant turned off and you told.
  """
  def finished(state, {grant_id, check_id}, result) do
    state = Map.update(state, :checking, MapSet.new(), &MapSet.delete(&1, {grant_id, check_id}))
    grant = Enum.find(state.grants, &(&1.id == grant_id))
    check = grant && Enum.find(grant.checks, &(&1.id == check_id))

    if is_nil(check) do
      state
    else
      ok? = is_nil(result[:error]) and result[:exit] == 0

      output =
        case result[:error] do
          nil -> result[:output] || ""
          error -> "It couldn't run: " <> error
        end

      kept = %{
        at: State.now(),
        ok?: ok?,
        exit: result[:exit],
        output: binary_part(output, 0, min(byte_size(output), @output))
      }

      state =
        state
        |> Map.update(
          :checks,
          %{{grant_id, check_id} => kept},
          &Map.put(&1, {grant_id, check_id}, kept)
        )
        |> State.log(%{
          outcome: :grant,
          summary:
            "#{grant.name}: check “#{check.name}” " <>
              if(ok?, do: "holds", else: "failed (#{exit_words(result)})"),
          grant_id: grant.id
        })

      state =
        if not ok? and check.gates,
          do: hold_off(state, grant, check),
          else: state

      state |> State.write_inbox() |> State.changed()
    end
  end

  defp exit_words(%{error: error}) when is_binary(error), do: "it couldn't run"
  defp exit_words(%{exit: exit}), do: "exit #{exit}"

  # A gating check failed: off, what waited refused, and you told.
  defp hold_off(state, grant, check) do
    state =
      if grant.state == :on do
        state
        |> Approvals.settle_waiting(grant.id, :grant_off)
        |> State.replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
        |> State.log(%{
          outcome: :grant,
          summary: "#{grant.name} turned off: its check “#{check.name}” failed",
          grant_id: grant.id
        })
      else
        state
      end

    Notifications.notify(state.username, {:sandbox_check, grant.id}, %{
      kind: "sandbox.grant",
      summary: "#{grant.name} is paused",
      body: "Its check “#{check.name}” failed. Its page has the output.",
      open: "/tools/sandbox/grants/#{grant.id}"
    })

    state
  end

  @doc "Adds a check to a grant, from a form's fields, and runs it at once."
  def add(state, %Grant{} = grant, attrs) do
    case Check.new(attrs, "check-" <> State.unique()) do
      {:ok, check} ->
        updated = %{grant | checks: grant.checks ++ [check]}

        state =
          state
          |> State.replace_grant(updated)
          |> State.log(%{
            outcome: :grant,
            summary: "#{grant.name}: check “#{check.name}” added",
            grant_id: grant.id
          })
          |> run(updated, :all)
          |> State.write_inbox()
          |> State.changed()

        {:ok, state}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Removes a check from a grant, and what it last said."
  def remove(state, %Grant{} = grant, check_id) do
    case Enum.find(grant.checks, &(&1.id == check_id)) do
      nil ->
        state

      check ->
        state
        |> State.replace_grant(%{grant | checks: List.delete(grant.checks, check)})
        |> Map.update(:checks, %{}, &Map.delete(&1, {grant.id, check_id}))
        |> State.log(%{
          outcome: :grant,
          summary: "#{grant.name}: check “#{check.name}” removed",
          grant_id: grant.id
        })
        |> State.write_inbox()
        |> State.changed()
    end
  end
end
