defmodule MWTClient.Sandbox.Server.Values do
  @moduledoc """
  The real values, at the one place they leave the vault: fetching a grant's
  value, stored or minted by your command, and answering the proxy with the
  request's headers carrying it, or with a refusal.

  A value is put into a request only here, after
  `MWTClient.Sandbox.Policy` or your decision let that request through. Runs
  in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{Describe, Grant, HostRun, Placeholder, Policy, Secrets}
  alias MWTClient.Sandbox.Server.{Firewall, State}

  @mint_fresh_ms 10 * 60_000
  # The shortest value looked for in the answer to the request it went in:
  # that one value only, so a shorter one than anywhere else.
  @echo_shortest 8

  @doc """
  Fetches the value, then answers the proxy with the headers carrying it,
  in the grant's carriers only, and what to look for (`scan/5`).
  """
  def forward(state, grant, request, from) do
    with_value(state, grant, request.host, fn state, result ->
      case {result, still(state, grant, request)} do
        {_result, :isolated} ->
          GenServer.reply(from, isolated())
          state

        {_result, :off} ->
          GenServer.reply(
            from,
            deny(
              403,
              "mwt_grant_off",
              "#{grant.name} turned off while its value was fetched. Ask for it with: " <>
                "mwt request #{grant.id} --reason \"...\"",
              grant
            )
          )

          State.log(
            state,
            request_event(
              request,
              grant,
              :refused,
              "#{grant.name} turned off while its value was fetched · not sent"
            )
          )

        {{:ok, value}, {:ok, grant}} ->
          headers =
            Placeholder.swap(request.headers, grant.placeholder, value, Grant.carriers(grant))

          GenServer.reply(
            from,
            {:forward, headers, scan(state, request.host, grant, value, headers)}
          )

          State.used(state, grant.id)

        {{:error, :no_value}, _live} ->
          GenServer.reply(
            from,
            deny(503, "mwt_no_value", "#{grant.name} has no value yet.", grant)
          )

          State.log(
            state,
            request_event(request, grant, :refused, "#{grant.name} has no value set")
          )

        {{:error, message}, _live} ->
          GenServer.reply(
            from,
            deny(502, "mwt_mint_failed", "Could not mint a token for #{grant.name}.", grant)
          )

          State.log(state, request_event(request, grant, :refused, "Minting failed: #{message}"))
      end
    end)
  end

  # The grant as it is when its value is at hand, which a mint makes
  # later than the decision: `{:ok, grant}` while it still lets this
  # request go (on, by the clock, and listing its host), `:off`
  # once it doesn't, `:isolated` while the firewall holds the VM. A value
  # never goes out after the grant's turn-off was taken (QA M6).
  defp still(state, %Grant{id: id}, request) do
    grant = Enum.find(state.grants, &(&1.id == id))

    cond do
      Firewall.isolated?(state) -> :isolated
      is_nil(grant) -> :off
      not Grant.on?(grant, State.now()) -> :off
      not Policy.host_listed?(request.host, grant.hosts) -> :off
      true -> {:ok, grant}
    end
  end

  @doc """
  What the proxy looks for around a request: `out`, every real value, in
  what the VM sends after the head; `echo`, the forms `value` left in (as
  it is, quoted, and as the carrier MWT wrote, such as a Basic
  credential's base64), in the answer, where `placeholder` replaces it;
  and `grant`, the id of the grant whose value it carries, which the
  connection is held under. With no value in the request, only `out`.
  """
  def scan(state, host), do: %{out: out(state, host), echo: nil, placeholder: nil, grant: nil}

  def scan(state, host, grant, value, headers) do
    written =
      for {name, header} <- headers,
          name in Grant.carriers(grant),
          not String.contains?(header, value),
          String.contains?(Placeholder.decoded(header) || "", value),
          [_scheme, encoded] <- [String.split(header, " ", parts: 2)],
          do: String.trim(encoded)

    %{
      out: out(state, host),
      echo:
        Secrets.new([{{:value, grant.name}, Secrets.forms(value) ++ written}], @echo_shortest),
      placeholder: grant.placeholder,
      grant: grant.id
    }
  end

  # What the rest of a request to `host` must not carry: any real value, and
  # the placeholder of a grant that doesn't list the host.
  defp out(state, host) do
    elsewhere =
      for %Grant{kind: :token, placeholder: placeholder} = grant <- state.grants,
          is_binary(placeholder),
          not Policy.host_listed?(host, grant.hosts),
          do: {{:placeholder, grant.name}, [placeholder]}

    Secrets.new(value_forms(state) ++ elsewhere)
  end

  @doc """
  Every token grant's real value at hand, stored or minted, on or off, as
  what to look for where none belongs; nil when there is none (or none
  long enough). A file grant's value is the VM's already, so it isn't.
  """
  def secrets(state), do: state |> value_forms() |> Secrets.new()

  @doc """
  Every token grant's real value at hand, as `{{:value, grant_name},
  forms}`, the value as it is first (`Secrets.forms/1`).
  """
  def value_forms(state),
    do: for({grant, value} <- values(state), do: {{:value, grant.name}, Secrets.forms(value)})

  @doc """
  The name of the grant whose real value is in what the VM wrote, or nil:
  each text as it is, and a Basic credential in it decoded.
  """
  def carried(state, texts) do
    case secrets(state) do
      nil ->
        nil

      secrets ->
        Enum.find_value(texts, fn text ->
          case Secrets.find(secrets, text) ||
                 Secrets.find(secrets, Placeholder.decoded(text) || "") do
            {:value, name} -> name
            nil -> nil
          end
        end)
    end
  end

  # Every value at hand, as {grant, value}: its stored one, or each it
  # minted, one per host for a grant minted per host.
  defp values(state) do
    stored = state.values || %{}
    minted = Map.get(state, :minted) || %{}

    for %Grant{kind: :token, id: id} = grant <- state.grants,
        value <- grant_values(stored, minted, id),
        do: {grant, value}
  end

  defp grant_values(stored, minted, id) do
    case Map.get(stored, id) do
      value when is_binary(value) ->
        [value]

      _none ->
        for {key, {value, _until}} <- minted, minted_for?(key, id), is_binary(value), do: value
    end
  end

  defp minted_for?(id, id), do: true
  defp minted_for?({id, _host}, id) when is_binary(id), do: true
  defp minted_for?(_key, _id), do: false

  @doc """
  Calls `k` with the state and `{:ok, value}` once the grant's value is at
  hand (minting it first when it is minted and not fresh), or with
  `{:error, :no_value}` or `{:error, message}`.
  """
  def fetch(state, grant, k), do: with_value(state, grant, nil, k)

  @doc "As `fetch/3`, for the value a request to `host` carries: a grant minted per host mints one for it."
  def fetch(state, grant, host, k), do: with_value(state, grant, host, k)

  defp with_value(state, %Grant{source: :stored} = grant, _host, k) do
    case Map.fetch(state.values || %{}, grant.id) do
      {:ok, value} when is_binary(value) -> k.(state, {:ok, value})
      _ -> k.(state, {:error, :no_value})
    end
  end

  defp with_value(state, %Grant{source: {:minted, command}} = grant, host, k) do
    key = mint_key(grant, host)
    now = System.monotonic_time(:millisecond)

    case {state.minted[key], state.minting[key]} do
      {{value, until}, _} when until > now ->
        k.(state, {:ok, value})

      {_, [_ | _] = waiting} ->
        %{state | minting: Map.put(state.minting, key, waiting ++ [k])}

      _none ->
        variables =
          [{"MWT_GRANT", grant.id}] ++
            if(grant.mint_per == :host and is_binary(host), do: [{"MWT_HOST", host}], else: [])

        state
        |> State.task({:mint, key}, fn -> mint(command, variables) end)
        |> Map.update!(:minting, &Map.put(&1, key, [k]))
    end
  end

  defp with_value(state, _grant, _host, k), do: k.(state, {:error, :no_value})

  @doc """
  Where a minted value is kept: under the grant's id, or, for a grant
  minted per host (`Grant.mint_per`), under `{id, host}`.
  """
  def mint_key(%Grant{id: id, mint_per: :host}, host) when is_binary(host),
    do: {id, String.downcase(host)}

  def mint_key(%Grant{id: id}, _host), do: id

  # The command is told which grant, and, minted per host, which host its
  # value is for. It prints the bare value, or a JSON object with `value`
  # and, when it knows, `expires_in` seconds: kept until a minute before
  # then, or for 10 minutes.
  defp mint(command, variables) do
    case System.cmd("timeout", ["30", "bash", "-lc", command],
           stderr_to_stdout: false,
           env: HostRun.home_env() ++ variables
         ) do
      {output, 0} ->
        output |> String.trim() |> minted()

      {_output, status} ->
        {:error, "the command exited with #{status}"}
    end
  end

  @doc """
  What a mint command printed, read: `{:ok, value, fresh_ms}`, or why not.

      iex> MWTClient.Sandbox.Server.Values.minted("ya29.abc")
      {:ok, "ya29.abc", 600000}
      iex> MWTClient.Sandbox.Server.Values.minted(~s({"value": "ya29.abc", "expires_in": 1800}))
      {:ok, "ya29.abc", 1740000}
      iex> MWTClient.Sandbox.Server.Values.minted(~s({"expires_in": 1800}))
      {:error, "the command printed JSON with no \\"value\\""}
  """
  def minted(""), do: {:error, "the command printed nothing"}

  def minted("{" <> _ = output) do
    case Jason.decode(output) do
      {:ok, %{"value" => value} = object} when is_binary(value) and value != "" ->
        fresh =
          case object["expires_in"] do
            seconds when is_integer(seconds) and seconds > 0 -> max(seconds - 60, 0) * 1_000
            _none -> @mint_fresh_ms
          end

        {:ok, value, fresh}

      {:ok, %{}} ->
        {:error, "the command printed JSON with no \"value\""}

      _not_json ->
        {:ok, output, @mint_fresh_ms}
    end
  end

  def minted(token), do: {:ok, token, @mint_fresh_ms}

  @doc """
  The proxy's refusal of a request: a status, and a JSON body with the reason and the grant's name.
  """
  def deny(status, code, message, grant) do
    body =
      Jason.encode!(%{
        error: message,
        code: code,
        grant: grant && grant.name,
        by: "MWT agent sandbox"
      })

    {:deny, status, body}
  end

  @doc """
  The proxy's answer to a request holding a real value, which nothing in
  the VM should have.
  """
  def value_blocked do
    deny(
      403,
      "mwt_value_blocked",
      "This request holds a real credential, which nothing in the VM should have. " <>
        "It did not go out. The user has been told.",
      nil
    )
  end

  @doc """
  A request `MWTClient.Sandbox.Policy` refused, as `{event, observation,
  answer}`: what the log says (or nil), what the firewall hears (or nil),
  and the proxy's answer. The same wherever it was decided.
  """
  def refusal({:not_a_carrier, grant, headers}, request) do
    summary =
      "#{grant.name} placeholder in #{Enum.join(headers, ", ")}, " <>
        "not a header it travels in · refused"

    {request_event(request, grant, :refused, summary), nil,
     deny(
       403,
       "mwt_not_a_carrier",
       "#{grant.name}'s placeholder is in #{Enum.join(headers, ", ")}. MWT puts its real " <>
         "value only in #{Enum.join(Grant.carriers(grant), ", ")}, and refuses a request " <>
         "with the placeholder anywhere else. Send it as the tool normally does, or ask " <>
         "the user to add the header to the grant.",
       grant
     )}
  end

  def refusal(:multiple_grants, _request) do
    {nil, nil,
     deny(403, "mwt_multiple_grants", "One request may carry one grant's placeholder.", nil)}
  end

  def refusal({:wrong_host, grant}, request) do
    summary = "#{grant.name} placeholder sent to #{request.host} · blocked"

    {request_event(request, grant, :violation, summary),
     {:leak, grant.name, request.host, :request},
     deny(403, "mwt_placeholder_blocked", "#{grant.name} may not go to #{request.host}.", grant)}
  end

  def refusal({:subgrants_only, grant}, request) do
    {request_event(
       request,
       grant,
       :refused,
       "#{grant.name} placeholder · its value is only for its subgrants"
     ), nil,
     deny(
       403,
       "mwt_subgrants_only",
       "#{grant.name}'s value is only for its subgrants, requests MWT sends itself: " <>
         "mwt call ID. mwt grants lists them under #{grant.name}.",
       grant
     )}
  end

  def refusal({:check_failing, grant, why}, request) do
    {request_event(request, grant, :refused, "#{grant.name} paused: #{why}"), nil,
     deny(
       403,
       "mwt_check_failing",
       "#{grant.name} is paused: #{why}. Tell the user; " <>
         "asking for the grant won't help until that changes.",
       grant
     )}
  end

  def refusal({:grant_off, grant}, request) do
    title = Describe.request(request).title

    {request_event(request, grant, :refused, "#{title} · #{grant.name} is off"), nil,
     deny(
       403,
       "mwt_grant_off",
       "#{grant.name} is off. Ask for it with: mwt request #{grant.id} --reason \"...\"",
       grant
     )}
  end

  @doc """
  The proxy's answer to a request that would have carried `grant`'s value
  to a credential endpoint on the firewall's list (`entry`).
  """
  def minting(grant, host, entry) do
    deny(
      403,
      "mwt_credential_endpoint",
      "#{host} is a credential endpoint (#{entry}): its answer would be a new credential in the VM, " <>
        "so MWT doesn't send #{grant.name}'s value there. If the user needs it, they can take it off " <>
        "the firewall's list of credential endpoints.",
      grant
    )
  end

  @doc """
  The proxy's answer to a request while the firewall holds the VM isolated.
  It says what happened, never which rule fired.
  """
  def isolated do
    deny(
      403,
      "mwt_isolated",
      "MWT's firewall isolated this VM: nothing it sends leaves until the user releases it. The user has been told.",
      nil
    )
  end

  @doc """
  The log's event for a request that carried a grant's placeholder.
  """
  def request_event(request, grant, outcome, summary) do
    %{
      outcome: outcome,
      summary: summary,
      host: request.host,
      port: 443,
      grant_id: grant.id,
      method: request.method,
      path: request.path,
      exchange_id: Map.get(request, :exchange)
    }
  end
end
