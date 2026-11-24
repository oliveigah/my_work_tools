defmodule MWTClient.Sandbox.Server.Firewall do
  @moduledoc """
  The firewall in the sandbox server's state (`MWTClient.Sandbox.Firewall`
  decides): each observation a sensor reports, logged and acted on;
  isolating the VM, on a finding or because you did, and releasing it.

  `observe/2` answers the sensor: `:pass` (nothing, or an alert), `:block`
  (refuse this one use), `:isolate` (the VM was just isolated), or
  `:isolated` (it already was). Anything but `:pass` means: refuse.

  Isolating locks every resource the VM reaches through MWT, its networks,
  its credentials and your machine, and changes no grant: the incident is
  recorded and saved, every connection the proxy holds is closed
  (`MWTClient.Sandbox.Connections`), every approval waiting is refused,
  every command running on this machine is stopped, port forwarding stops,
  and you are notified, unless you isolated it yourself. From then on the
  proxy, DNS, the agent channel, MWT's tools and every decision
  (`MWTClient.Sandbox.Policy`, `:isolated`) refuse the VM until you
  release it. The VM keeps running.

  Isolating locks each resource as the isolation's (`Server.Locks`), beside
  any lock of yours; releasing ends the isolation's locks only, so what you
  locked stays locked, and every grant is as you left it, for the time it
  has left, since none changed. It also starts over what the
  incident was counted on, in the watch and here, so the next connection
  or lookup isn't isolated again on bytes or names from before it.
  """

  require Logger

  alias MWTClient.Notifications
  alias MWTClient.Sandbox.{EventDetails, Firewall, Gate, Watch}
  alias MWTClient.Sandbox.Server.{Approvals, Forwarding, HostRuns, Locks, State}

  @connections MWTClient.Sandbox.Connections

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

  @doc """
  What the Firewall page shows of the server's state: the firewall, how
  much it refused while isolated, and what releasing turns back on. Its
  findings are events of the journal, which the page reads itself
  (`MWTClient.Sandbox.Activity`): a journal held by a long write (a
  retention delete, a Clear) then keeps the page waiting, never this
  server and every decision behind it.
  """
  def view(state) do
    %{
      firewall: of(state),
      refused: Map.get(state, :firewall_refused, 0) + Gate.refused_count(state.username)
    }
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

        {:list, list, text} when is_atom(list) ->
          with true <- list in Firewall.lists() || {:error, :bad_change},
               {:ok, changed} <- Firewall.set_list(firewall, list, text) do
            {:ok, changed, "Firewall: #{list} list changed (#{length(Map.get(changed, list))})"}
          end

        {:reset_list, list} when is_atom(list) ->
          if list in Firewall.lists(),
            do:
              {:ok, Map.put(firewall, list, Firewall.default_list(list)),
               "Firewall: #{list} list back to MWT's"},
            else: {:error, :bad_change}

        _other ->
          {:error, :bad_change}
      end

    case result do
      {:ok, changed, summary} ->
        state =
          state
          |> State.change(:firewall, fn _ -> changed end)
          |> State.log(%{
            outcome: :firewall,
            summary: summary,
            details: [
              EventDetails.changes(settings(firewall), settings(changed))
              | Enum.map(Firewall.lists(), &list_changes(&1, firewall, changed))
            ]
          })
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
        port: finding.port,
        details: [
          rule_details(finding.rule),
          EventDetails.section("What it saw", [
            {"Seen", finding.summary},
            {"Destination",
             finding.host && "#{finding.host}#{finding.port && ":#{finding.port}"}"},
            {"What MWT did", words(finding.action)}
          ])
        ]
      })

    if finding.action == :alert, do: notify_alert(state, finding), else: state
  end

  # A rule as the Firewall page says it, for an event about it.
  defp rule_details(nil), do: nil

  defp rule_details(rule) do
    case Enum.find(Firewall.rules(), &(&1.id == rule)) do
      nil ->
        nil

      found ->
        EventDetails.section("The rule", [
          {"Rule", found.name},
          {"It catches", found.text}
        ])
    end
  end

  # The switch and each rule's action, for an edit's before and after.
  defp settings(firewall) do
    [{"Firewall", if(firewall.enabled, do: "on", else: "off")}] ++
      for rule <- Firewall.rules(), do: {rule.name, to_string(Firewall.action(firewall, rule.id))}
  end

  # A list's entries added and taken off, rather than the whole list twice.
  defp list_changes(list, before, now) do
    old = Map.get(before, list) || []
    new = Map.get(now, list) || []

    EventDetails.section("The #{list} list", [
      {"Added", {:list, new -- old}},
      {"Taken off", {:list, old -- new}}
    ])
  end

  # An event the isolation kept, in a line.
  defp event_line(%{at: at, summary: summary} = event) do
    host = Map.get(event, :host)

    "#{Calendar.strftime(at, "%H:%M:%S")} #{Map.get(event, :outcome)} " <>
      if(host, do: "#{host} · ", else: "") <> summary
  end

  defp event_line(other), do: inspect(other)

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
        "incident-" <> State.unique()
      )

    incident = firewall.isolated
    Gate.count_refused_from_zero(state.username)

    state
    |> State.change(:firewall, fn _ -> firewall end)
    |> Map.put(:firewall_refused, 0)
    |> Locks.lock_all(:isolation)
    |> close_connections()
    |> refuse_waiting(incident)
    |> stop_commands(incident)
    |> Forwarding.sync()
    |> State.log(%{
      outcome: :firewall,
      summary:
        "VM isolated by #{Firewall.isolated_by(incident)} · nothing it sends leaves through MWT until you release it",
      details: [
        incident.rule && rule_details(incident.rule),
        EventDetails.section("The isolation", [
          {"By", Firewall.isolated_by(incident)},
          {"Seen", incident.summary},
          {"Destination",
           incident.host && "#{incident.host}#{incident.port && ":#{incident.port}"}"},
          {"Locked", "every network, credential and your machine; no grant changed"}
        ]),
        EventDetails.section("Just before", [
          {"Events", {:list, Enum.map(Enum.take(incident.events, 15), &event_line/1)}}
        ])
      ]
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
  Ends the isolation and the isolation's locks; with `trust?`, the
  incident's destination joins the trusted list. Your own locks stay.
  """
  def release(state, trust?) do
    case of(state) do
      %Firewall{isolated: nil} ->
        {:error, state}

      %Firewall{isolated: incident} = firewall ->
        released = Firewall.release(firewall, State.now(), trust?)
        entry = trust? && Firewall.trust_entry(incident)
        trusted = if entry, do: ", #{entry} trusted from now on", else: ""

        # What it was counted on starts over before the mark goes: the
        # watch answers what already waits there as isolated, then judges
        # from zero.
        rule = incident.rule
        key = Map.get(incident, :key)
        :ok = Watch.forget(state.username, rule, key)
        Notifications.withdraw(state.username, {:sandbox_firewall, :isolated})
        Gate.untrip(state.username)

        state =
          state
          |> Map.update(:firewall_watch, nil, &(&1 && Firewall.forget(&1, rule, key)))
          |> State.change(:firewall, fn _ -> released end)
          |> Map.put(:firewall_refused, 0)
          |> Locks.unlock_all(:isolation)
          |> Forwarding.sync()
          |> State.log(%{
            outcome: :firewall,
            summary: "Released by you#{trusted}",
            details: [
              EventDetails.section("The isolation released", [
                {"Isolated at", Calendar.strftime(incident.at, "%Y-%m-%d %H:%M:%S UTC")},
                {"For", EventDetails.duration(DateTime.diff(State.now(), incident.at, :second))},
                {"By", Firewall.isolated_by(incident)},
                {"Seen", incident.summary},
                {"Trusted from now on", entry || nil}
              ])
            ]
          })
          |> State.write_inbox()
          |> State.saved()

        {:ok, state}
    end
  end

  @doc "Withdraws the alert notification: you have seen the Firewall page."
  def seen(state) do
    Notifications.withdraw(state.username, {:sandbox_firewall, :alert})
    state
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

  defp stop_commands(state, incident),
    do: HostRuns.stop_running(state, state.approvals, isolated_words(incident))

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
