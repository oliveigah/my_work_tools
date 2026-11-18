defmodule MWTClient.Sandbox.Server.Firewall do
  @moduledoc """
  The firewall in the sandbox server's state (`MWTClient.Sandbox.Firewall`
  decides): each observation a sensor reports, logged and acted on;
  isolating the VM, on a finding or because you did, and releasing it.

  `observe/2` answers the sensor: `:pass` (nothing, or an alert), `:block`
  (refuse this one use), `:isolate` (the VM was just isolated), or
  `:isolated` (it already was). Anything but `:pass` means: refuse.

  Isolating, at once: the incident is recorded and saved, every connection
  the proxy holds is closed (`MWTClient.Sandbox.Connections`), every
  approval waiting is refused, every command running on this machine is
  stopped, every grant turns off, port forwarding stops, and you are
  notified, unless you isolated it yourself. From then on the proxy, DNS,
  the agent channel and MWT's tools refuse the VM until you release it.
  The VM keeps running.

  Releasing turns back on the grants that were on when it was isolated,
  as they were, for the time they have left (`restore_grants/2`): the
  incident keeps them, so a release after MWT restarted does too.
  """

  require Logger

  alias MWTClient.Notifications
  alias MWTClient.Sandbox.{Activity, Allowance, Approval, Firewall, Gate, Grant}
  alias MWTClient.Sandbox.Server.{Approvals, Forwarding, HostRuns, State}

  @connections MWTClient.Sandbox.Connections
  @kill_after_ms 5_000

  @doc "The firewall as the state holds it; a state from before it has a new one."
  def of(state), do: Map.get(state, :firewall) || Firewall.new()

  @doc "Whether the VM is isolated."
  def isolated?(state), do: Firewall.isolated?(of(state))

  @doc """
  Checks what a sensor saw: `{verdict, state}`, the verdict one of
  `:pass`, `:block`, `:isolate` or `:isolated`.
  """
  def observe(state, observation) do
    firewall = of(state)

    if Firewall.isolated?(firewall) do
      {:isolated, refused(state)}
    else
      now = System.monotonic_time(:millisecond)
      watch = Map.get(state, :firewall_watch) || Firewall.watch()
      {watch, findings} = Firewall.check(firewall, watch, observation, now)
      state = Enum.reduce(findings, Map.put(state, :firewall_watch, watch), &found(&2, &1))

      case Firewall.worst(findings) do
        nil -> {:pass, state}
        %{action: :alert} -> {:pass, state}
        %{action: :block} -> {:block, state}
        %{action: :isolate} = finding -> {:isolate, isolate(state, finding)}
      end
    end
  end

  @doc "Counts one more thing refused while isolated, for the incident's card; not logged."
  def refused(state), do: Map.update(state, :firewall_refused, 1, &(&1 + 1))

  @doc "Drops what is past every window; on the server's sweep."
  def prune(state) do
    case Map.get(state, :firewall_watch) do
      nil ->
        state

      watch ->
        %{state | firewall_watch: Firewall.prune(watch, System.monotonic_time(:millisecond))}
    end
  end

  @doc "What the Firewall page shows."
  def view(state) do
    %{
      firewall: of(state),
      refused: Map.get(state, :firewall_refused, 0) + Gate.refused_count(state.username),
      findings: findings(state),
      # What releasing turns back on, by name.
      restorable: restorable(state)
    }
  end

  # From the journal. A page can do without them; the server can't do
  # without itself, so a journal that can't be read now shows none.
  defp findings(state) do
    Activity.logged(state.username, %{group: "firewall", limit: 50})
  rescue
    error ->
      Logger.warning("could not read the firewall's findings: #{Exception.message(error)}",
        user: state.username,
        system: :sandbox
      )

      []
  catch
    :exit, _reason -> []
  end

  @doc "Changes a setting: the switch, a rule's action or a list."
  def set(state, change) do
    firewall = of(state)

    result =
      case change do
        {:enabled, enabled?} when is_boolean(enabled?) ->
          {:ok, Firewall.set_enabled(firewall, enabled?),
           "Firewall #{if enabled?, do: "on", else: "off"}"}

        {:action, rule, action} ->
          with {:ok, changed} <- Firewall.set_action(firewall, rule, action) do
            rule = Enum.find(Firewall.rules(), &(to_string(&1.id) == to_string(rule))).id

            {:ok, changed,
             "Firewall: #{Firewall.rule_name(rule)} set to #{Firewall.action(changed, rule)}"}
          end

        {:list, list, text} when list in [:trusted, :blocked, :protected, :mints] ->
          with {:ok, changed} <- Firewall.set_list(firewall, list, text) do
            {:ok, changed, "Firewall: #{list} list changed (#{length(Map.get(changed, list))})"}
          end

        {:reset_list, list} when list in [:trusted, :blocked, :protected, :mints] ->
          {:ok, Map.put(firewall, list, Firewall.default_list(list)),
           "Firewall: #{list} list back to MWT's"}

        _other ->
          {:error, :bad_change}
      end

    case result do
      {:ok, changed, summary} ->
        state =
          state
          |> State.change(:firewall, fn _ -> changed end)
          |> State.log(%{outcome: :firewall, summary: summary})
          |> State.changed()

        {:ok, state}

      error ->
        {error, state}
    end
  end

  ## Isolating

  @doc "Logs a finding, and notifies an alert: the server's own, or what the watch sent."
  def found(state, finding) do
    state =
      State.log(state, %{
        outcome: :firewall,
        summary:
          "#{Firewall.rule_name(finding.rule)} · #{finding.summary} · #{words(finding.action)}",
        host: finding.host,
        port: finding.port
      })

    if finding.action == :alert, do: notify_alert(state, finding), else: state
  end

  defp words(:isolate), do: "VM isolated"
  defp words(:block), do: "blocked"
  defp words(:alert), do: "alert"

  @doc """
  Isolates the VM at once: on `finding`, or because you did (`:you`, the
  switch on the Firewall page). The same isolation either way; only you
  aren't notified of your own.
  """
  def isolate(state, cause) do
    Logger.warning("sandbox VM isolated by #{by_words(cause)}", system: :sandbox)

    # Marked first, so nothing the network path decides from now on passes,
    # then every connection closed.
    Gate.trip(state.username, cause)

    firewall =
      Firewall.isolate(
        of(state),
        cause,
        State.recent_events(state),
        State.now(),
        "incident-" <> State.unique(),
        grants_on(state)
      )

    incident = firewall.isolated
    Gate.count_refused_from_zero(state.username)

    state
    |> State.change(:firewall, fn _ -> firewall end)
    |> Map.put(:firewall_refused, 0)
    |> close_connections()
    |> refuse_waiting(incident)
    |> stop_commands(incident)
    |> grants_off(incident)
    |> Forwarding.sync()
    |> State.log(%{
      outcome: :firewall,
      summary:
        "VM isolated by #{Firewall.isolated_by(incident)} · nothing it sends leaves through MWT until you release it"
    })
    |> notify_isolated(incident)
    |> State.write_inbox()
    |> State.saved()
  end

  @doc "Isolates the VM because you did: `{:error, state}` when it already is."
  def isolate_by_you(state) do
    if isolated?(state), do: {:error, state}, else: {:ok, isolate(state, :you)}
  end

  defp by_words(:you), do: "the user"
  defp by_words(%{rule: rule}), do: "the firewall: #{rule}"

  @doc """
  Ends the isolation; with `trust?`, the incident's destination joins the
  trusted list. The grants that were on as it began are on again
  (`restore_grants/2`).
  """
  def release(state, trust?) do
    case of(state) do
      %Firewall{isolated: nil} ->
        {:error, state}

      %Firewall{isolated: incident} = firewall ->
        released = Firewall.release(firewall, State.now(), trust?)

        trusted =
          if trust? and incident.host, do: ", #{incident.host} trusted from now on", else: ""

        Notifications.withdraw(state.username, {:sandbox_firewall, :isolated})
        Gate.untrip(state.username)

        state =
          state
          |> State.change(:firewall, fn _ -> released end)
          |> Map.put(:firewall_refused, 0)
          |> Forwarding.sync()
          |> State.log(%{outcome: :firewall, summary: "Released by you#{trusted}"})
          |> restore_grants(Map.get(incident, :grants_on, []))
          |> State.write_inbox()
          |> State.saved()

        {:ok, state}
    end
  end

  @doc """
  The grants that were on as the VM was isolated, turned on again as they
  were: their end, duration and allowances, Auto-approve included. One
  whose time ran out meanwhile, one removed, one already on again, and one
  to review stay as they are. Each runs its `:enable` checks, as turning
  it on does.
  """
  def restore_grants(state, grants_on) do
    now = State.now()

    restored =
      for %{id: id} = was <- grants_on,
          %Grant{} = grant <- [Enum.find(state.grants, &(&1.id == id))],
          not Grant.on?(grant, now),
          not Grant.to_review?(grant),
          not Grant.subgrants_only?(grant),
          is_nil(was.expires_at) or DateTime.compare(was.expires_at, now) == :gt do
        %{
          grant
          | state: :on,
            expires_at: was.expires_at,
            minutes: was.minutes,
            allowances: Enum.reject(was.allowances || [], &Allowance.ended?(&1, now))
        }
      end

    if restored == [] do
      state
    else
      Enum.each(restored, &State.schedule_expiry/1)

      restored
      |> Enum.reduce(state, &State.replace_grant(&2, &1))
      |> State.log(%{
        outcome: :grant,
        summary: "Turned back on after the release: #{Enum.map_join(restored, ", ", & &1.name)}"
      })
      |> MWTClient.Sandbox.Server.Checks.run_enable(Enum.map(restored, & &1.id))
    end
  end

  @doc "What releasing would turn back on now, by name (`restore_grants/2`)."
  def restorable(state) do
    case of(state) do
      %Firewall{isolated: %{} = incident} ->
        now = State.now()

        for %{id: id} = was <- Map.get(incident, :grants_on, []),
            %Grant{} = grant <- [Enum.find(state.grants, &(&1.id == id))],
            not Grant.to_review?(grant),
            is_nil(was.expires_at) or DateTime.compare(was.expires_at, now) == :gt,
            do: grant.name

      _other ->
        []
    end
  end

  # The grants on now, as releasing would bring them back.
  defp grants_on(state) do
    now = State.now()

    for grant <- state.grants, Grant.on?(grant, now) do
      %{
        id: grant.id,
        expires_at: grant.expires_at,
        minutes: grant.minutes,
        allowances: grant.allowances
      }
    end
  end

  @doc "Withdraws the alert notification: you have seen the Firewall page."
  def seen(state) do
    Notifications.withdraw(state.username, {:sandbox_firewall, :alert})
    state
  end

  @doc """
  Every grant that is on, turned off: when the VM is isolated, and when MWT
  starts with it isolated.
  """
  def all_off(grants) do
    Enum.map(grants, fn
      %Grant{state: :on} = grant -> %{grant | state: :off, expires_at: nil, allowances: []}
      grant -> grant
    end)
  end

  @doc "Every connection the proxy holds for `username`, closed."
  def close_connections(state) do
    for {pid, _} <- connections(state.username), pid != self(), do: Process.exit(pid, :kill)
    state
  end

  defp connections(username) do
    Registry.lookup(@connections, username)
  rescue
    # Code reloaded into an MWT started before the registry: nothing to close.
    ArgumentError -> []
  end

  defp refuse_waiting(state, incident) do
    state.approvals
    |> Enum.filter(&(&1.status == :waiting))
    |> Enum.reduce(state, fn approval, acc ->
      acc
      |> Approvals.settle(approval, :denied, :isolated)
      |> Approvals.answer_waiters(approval, {:deny, :isolated})
      |> State.log(Approvals.event_for(approval, :refused, isolated_words(incident)))
    end)
  end

  defp isolated_words(incident), do: "the VM was isolated by #{Firewall.isolated_by(incident)}"

  defp stop_commands(state, incident) do
    state.approvals
    |> Enum.filter(&Approval.running?/1)
    |> Enum.reduce(state, fn approval, acc ->
      Process.send_after(self(), {:kill_command, approval.id}, @kill_after_ms)

      acc
      |> State.replace_approval(%{approval | run: %{approval.run | stopped: true}})
      |> HostRuns.stop_group(approval.id, "TERM")
      |> State.log(HostRuns.command_event(approval, "stopped: " <> isolated_words(incident)))
    end)
  end

  defp grants_off(state, incident) do
    names = for %Grant{state: :on} = grant <- state.grants, do: grant.name

    if names == [] do
      state
    else
      state
      |> State.change(:grants, &all_off(&1.grants))
      |> State.log(%{
        outcome: :grant,
        summary: "Turned off, #{isolated_words(incident)}: #{Enum.join(names, ", ")}"
      })
    end
  end

  # You know of your own isolation.
  defp notify_isolated(state, %{by: :you}), do: state

  defp notify_isolated(state, incident) do
    Notifications.notify(state.username, {:sandbox_firewall, :isolated}, %{
      kind: "sandbox.firewall",
      summary: "Agent sandbox isolated: #{Firewall.rule_name(incident.rule)}",
      body:
        incident.summary <>
          "\nNothing the VM sends leaves through MWT until you release it on the Firewall page.",
      open: "/tools/sandbox/firewall"
    })

    state
  end

  defp notify_alert(state, finding) do
    Notifications.notify(state.username, {:sandbox_firewall, :alert}, %{
      kind: "sandbox.firewall",
      summary: "Agent sandbox firewall: #{Firewall.rule_name(finding.rule)}",
      body: finding.summary <> "\nLet through; the Firewall page has what it saw.",
      open: "/tools/sandbox/firewall"
    })

    state
  end
end
