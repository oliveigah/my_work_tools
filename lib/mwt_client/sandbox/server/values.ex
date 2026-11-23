defmodule MWTClient.Sandbox.Server.Values do
  @moduledoc """
  The real values, at the one place they leave the vault: fetching a grant's
  value, stored or minted by your command, and answering the proxy with
  what to replace in the request (each placeholder with its value, in the
  carriers it travels in) and in its answer (the value with its
  placeholder), or with a refusal. The proxy's driver for the request's
  protocol does the replacing (`MWTClient.Sandbox.Egress.Driver`).

  A value is put into a request only here, after
  `MWTClient.Sandbox.Policy` or your decision let that request through. Runs
  in the server's process (`MWTClient.Sandbox.Server.State`).
  """

  alias MWTClient.Sandbox.{
    CredentialEndpoint,
    Describe,
    Gate,
    Grant,
    HostRun,
    Made,
    Placeholder,
    Policy,
    SavedRequest,
    Secrets
  }

  alias MWTClient.Sandbox.Server.{Firewall, State}

  @mint_fresh_ms 10 * 60_000
  # How long MWT waits for a credential endpoint it sends a request to for
  # the VM, in seconds.
  @endpoint_timeout 30

  @doc """
  What happens to a request once its grant lets it through: one to a
  credential endpoint the grant takes is answered by MWT (`answer/4`);
  any other goes out with the real values in it (`forward/4`).
  """
  def let_through(state, grant, %{endpoint: _ask} = request, from),
    do: answer(state, grant, request, from)

  def let_through(state, grant, request, from), do: forward(state, grant, request, from)

  @doc """
  Answers the proxy with the real values to put in the request
  (`replace/1`) and what to look for (`scan/3`): the grant's own value,
  fetched (minted when it has to be) when its placeholder is there, in its
  carriers; each value made from it (`MWTClient.Sandbox.Made`) whose
  placeholder is there, in that value's carriers. A request carrying only
  made values doesn't fetch the grant's.
  """
  def forward(state, grant, request, from) do
    made = carried_made(state, request)
    own? = Placeholder.in?(request.headers, grant.placeholder)
    id_token? = Enum.any?(made, &(&1.source == :id_token))

    if made_stale = Enum.find(made, &(not Made.covered?(&1, state.grants, State.now()))) do
      {event, _observation, answer} = refusal({:made_stale, made_stale}, request)
      GenServer.reply(from, answer)
      State.log(state, event)
    else
      # The grant's own value when its placeholder is there, and its ID
      # token when a placeholder for it is: both from its mint, which runs
      # at most once for the two.
      with_value_if(state, grant, request.host, own? or id_token?, fn state, result ->
        id_token = if id_token?, do: id_token(state, grant, request.host)

        if id_token? and match?({:ok, _}, result) and is_nil(id_token) do
          GenServer.reply(
            from,
            deny(
              503,
              "mwt_no_value",
              "#{grant.name}'s mint gave no ID token: it must print one beside its value.",
              grant
            )
          )

          State.log(state, request_event(request, grant, :refused, "No ID token minted"))
        else
          result = if own?, do: result, else: with_result(result, nil)
          put_values(state, grant, request, from, result, made, id_token)
        end
      end)
    end
  end

  defp with_value_if(state, grant, host, true, k), do: with_value(state, grant, host, k)
  defp with_value_if(state, _grant, _host, false, k), do: k.(state, {:ok, nil})

  # A fetch that went well stands for `value`; one that failed stays a
  # failure, said as it is.
  defp with_result({:ok, _fetched}, value), do: {:ok, value}
  defp with_result(failed, _value), do: failed

  # The ID token the grant's mint printed with the value at hand, or nil.
  defp id_token(state, grant, host) do
    case Map.get(state, :id_tokens, %{})[mint_key(grant, host)] do
      {id_token, _until} -> id_token
      nil -> nil
    end
  end

  defp put_values(state, grant, request, from, result, made, id_token) do
    with_live(state, grant, request, from, result, fn state, grant, value ->
      own =
        if value, do: [{grant.name, grant.placeholder, value, Grant.carriers(grant)}], else: []

      made_values =
        for m <- made do
          real = if m.source == :id_token, do: id_token, else: m.value
          {m.name, m.placeholder, real, m.carriers}
        end

      values = own ++ made_values

      GenServer.reply(
        from,
        {:forward, replace(values), scan(state, request.host, grant)}
      )

      State.used(state, grant.id)
    end)
  end

  # The values made from a grant that the request's headers carry, as MWT
  # holds them: with their real values.
  defp carried_made(state, request) do
    for {placeholder, made} <- Map.get(state, :made, %{}),
        Placeholder.in?(request.headers, placeholder),
        do: made
  end

  @doc """
  Answers a request to a credential endpoint for its grant
  (`MWTClient.Sandbox.CredentialEndpoint`): the grant's value fetched, MWT
  sends the request itself, in a task, and `answered/3` answers the proxy
  once it is back.
  """
  def answer(state, grant, %{endpoint: %{kind: :refresh}} = request, from) do
    with_value(state, grant, request.host, fn state, result ->
      with_live(state, grant, request, from, result, fn state, grant, _value ->
        now = State.now()
        expires_in = kept_seconds(state, grant, request.host)
        id_token = id_token(state, grant, request.host)
        {made, json} = CredentialEndpoint.refreshed(grant, id_token, expires_in, now)

        state =
          if made,
            do: Map.update(state, :made, %{made.placeholder => made}, &Made.put(&1, made, now)),
            else: state

        # Published before the VM hears of it, so a request carrying the
        # new placeholder at once finds it.
        state = Gate.publish(state)
        GenServer.reply(from, {:answer, 200, json})

        summary =
          if made,
            do: "#{grant.name}'s login refreshed, with an ID token · answered by MWT",
            else: "#{grant.name}'s login refreshed · answered by MWT"

        state
        |> State.used(grant.id)
        |> State.log(request_event(request, grant, :swapped, summary))
      end)
    end)
  end

  def answer(state, grant, %{endpoint: ask} = request, from) do
    with_value(state, grant, request.host, fn state, result ->
      with_live(state, grant, request, from, result, fn state, grant, value ->
        call = CredentialEndpoint.call(ask)

        state
        |> State.used(grant.id)
        |> State.task({:endpoint, from, grant.id, request}, fn ->
          SavedRequest.send(call, value, grant.name, @endpoint_timeout)
        end)
      end)
    end)
  end

  @doc """
  What came back from a credential endpoint MWT sent a request to for the
  VM (`answer/4`): what it made is kept, the view the proxy decides from
  is published with it before the VM hears of it (so a request carrying
  its placeholder at once finds it), and the proxy answers the VM itself.
  """
  def answered(state, {:endpoint, from, grant_id, request}, result) do
    grant = Enum.find(state.grants, &(&1.id == grant_id))
    now = State.now()

    case grant && CredentialEndpoint.answered(grant, request.endpoint, result, now) do
      {:ok, made, json} ->
        state =
          state
          |> Map.update(:made, %{made.placeholder => made}, &Made.put(&1, made, now))
          |> Gate.publish()

        GenServer.reply(from, {:answer, 200, json})

        State.log(
          state,
          request_event(request, grant, :swapped, "#{made.name} · answered by MWT")
        )

      {:error, status, json} ->
        GenServer.reply(from, {:answer, status, json})

        State.log(
          state,
          request_event(request, grant, :refused, "Signing for #{grant.name} failed (#{status})")
        )

      nil ->
        GenServer.reply(from, deny(403, "mwt_grant_off", "The grant was removed.", nil))
        state
    end
  end

  # Calls `k` with the grant as it is and the value, once the value is at
  # hand and the grant still lets the request go; otherwise answers the
  # proxy with why not, and logs it.
  defp with_live(state, grant, request, from, result, k) do
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
        k.(state, grant, value)

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
  What the proxy looks for around a request: `out`, every real value and
  the placeholder of every grant that doesn't list `host`, in what the VM
  sends after the head; and `grant`, the id of the grant whose values the
  request carries, which the connection is held under (nil for none).
  """
  def scan(state, host, grant \\ nil),
    do: %{out: out(state, host), grant: grant && grant.id}

  @doc """
  What to replace for the values that went in, each `{name, placeholder,
  value, carriers}` (`MWTClient.Sandbox.Egress.Driver`): in the request,
  each placeholder with its value, in its carriers only; in the answer,
  each form the value goes by (as it is, quoted, escaped) with its
  placeholder. `replace([])` replaces nothing.
  """
  def replace(values) do
    request =
      for {name, placeholder, value, carriers} <- values,
          do: %{label: {:value, name}, from: placeholder, to: value, within: carriers}

    answer =
      for {name, placeholder, value, _carriers} <- values,
          do: %{label: {:value, name}, from: Secrets.forms(value), to: placeholder}

    %{request: request, answer: answer}
  end

  # What the rest of a request to `host` must not carry: any real value, and
  # the placeholder of a grant that doesn't list the host.
  defp out(state, host) do
    elsewhere =
      for %Grant{kind: :token, placeholder: placeholder} = grant <- state.grants,
          is_binary(placeholder),
          not Policy.host_listed?(host, grant.hosts),
          do: {{:placeholder, grant.name}, [placeholder]}

    made_elsewhere =
      for {placeholder, made} <- Map.get(state, :made, %{}),
          not Policy.host_listed?(host, made.hosts),
          do: {{:placeholder, made.name}, [placeholder]}

    Secrets.new(value_forms(state) ++ elsewhere ++ made_elsewhere)
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
  def value_forms(state) do
    own = for {grant, value} <- values(state), do: {{:value, grant.name}, Secrets.forms(value)}

    made =
      for {_placeholder, %Made{value: value} = made} <- Map.get(state, :made, %{}),
          is_binary(value),
          do: {{:value, made.name}, Secrets.forms(value)}

    id_tokens =
      for {key, {id_token, _until}} <- Map.get(state, :id_tokens, %{}),
          id = if(is_tuple(key), do: elem(key, 0), else: key),
          %Grant{} = grant <- [Enum.find(state.grants, &(&1.id == id))],
          do: {{:value, "#{grant.name}'s ID token"}, Secrets.forms(id_token)}

    own ++ made ++ id_tokens
  end

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

        keep_ms = grant.keep_minutes && grant.keep_minutes * 60_000

        # How the grant made its value as this mint began: a mint that
        # ends after an edit changed that keeps nothing (`Machine.finished/3`).
        made = Grant.how_made(grant)

        state
        |> State.task({:mint, key}, fn -> command |> mint(variables) |> kept_at_most(keep_ms) end)
        |> Map.update!(:minting, &Map.put(&1, key, [k]))
        |> Map.update(:mint_made, %{key => made}, &Map.put(&1, key, made))
    end
  end

  defp with_value(state, _grant, _host, k), do: k.(state, {:error, :no_value})

  # How many seconds MWT keeps the value at hand for `host`: what a client
  # refreshing a login is told it lasts, so it refreshes before MWT would
  # mint again. A stored value lasts as long as the hour a refresh says.
  defp kept_seconds(state, grant, host) do
    case state.minted[mint_key(grant, host)] do
      {_value, until} -> max(div(until - System.monotonic_time(:millisecond), 1_000), 1)
      nil -> 3_600
    end
  end

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
    case MWTClient.Executable.cmd("timeout", ["30", "bash", "-lc", command],
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
  A mint's result kept no longer than `keep_ms`, the grant's own limit
  (`Grant.keep_minutes`), when it has one: a service may refuse a token
  long before it expires.

      iex> MWTClient.Sandbox.Server.Values.kept_at_most({:ok, %{value: "v"}, 1_740_000}, 240_000)
      {:ok, %{value: "v"}, 240000}
      iex> MWTClient.Sandbox.Server.Values.kept_at_most({:ok, %{value: "v"}, 60_000}, 240_000)
      {:ok, %{value: "v"}, 60000}
      iex> MWTClient.Sandbox.Server.Values.kept_at_most({:ok, %{value: "v"}, 600_000}, nil)
      {:ok, %{value: "v"}, 600000}
  """
  def kept_at_most({:ok, value, fresh_ms}, keep_ms) when is_integer(keep_ms),
    do: {:ok, value, min(fresh_ms, keep_ms)}

  def kept_at_most(result, _keep_ms), do: result

  @doc """
  What a mint command printed, read: `{:ok, minted, fresh_ms}`, where
  `minted` holds the `value` and, when the command printed one beside it,
  the `id_token` (`MWTClient.Sandbox.CredentialEndpoint`), both kept as
  long; or why not. It reads the bare value (kept 10 minutes), MWT's own
  JSON (`value`, `id_token`, `expires_in` seconds), or what `gcloud config
  config-helper --format=json` prints (`credential.access_token`,
  `credential.id_token`, `credential.token_expiry`), so a login's ID token
  needs no reshaping on your machine. A value with an expiry is kept until
  a minute before it.

      iex> MWTClient.Sandbox.Server.Values.minted("ya29.abc")
      {:ok, %{value: "ya29.abc", id_token: nil}, 600000}
      iex> MWTClient.Sandbox.Server.Values.minted(~s({"value": "ya29.abc", "expires_in": 1800}))
      {:ok, %{value: "ya29.abc", id_token: nil}, 1740000}
      iex> MWTClient.Sandbox.Server.Values.minted(~s({"value": "ya29.abc", "id_token": "eyJ.x.y"}))
      {:ok, %{value: "ya29.abc", id_token: "eyJ.x.y"}, 600000}
      iex> helper = ~s({"credential": {"access_token": "ya29.abc", "id_token": "eyJ.x.y", "token_expiry": "2026-11-22T01:30:00Z"}})
      iex> MWTClient.Sandbox.Server.Values.minted(helper, ~U[2026-11-22 01:00:00Z])
      {:ok, %{value: "ya29.abc", id_token: "eyJ.x.y"}, 1740000}
      iex> MWTClient.Sandbox.Server.Values.minted(~s({"expires_in": 1800}))
      {:error, "the command printed JSON with no \\"value\\""}
  """
  def minted(output, now \\ DateTime.utc_now())

  def minted("", _now), do: {:error, "the command printed nothing"}

  def minted("{" <> _ = output, now) do
    case Jason.decode(output) do
      {:ok, %{"value" => value} = object} when is_binary(value) and value != "" ->
        {:ok, %{value: value, id_token: text_or_nil(object["id_token"])},
         fresh(object["expires_in"])}

      {:ok, %{"credential" => %{"access_token" => value} = credential}}
      when is_binary(value) and value != "" ->
        seconds =
          with expiry when is_binary(expiry) <- credential["token_expiry"],
               {:ok, at, _offset} <- DateTime.from_iso8601(expiry),
               do: DateTime.diff(at, now)

        {:ok, %{value: value, id_token: text_or_nil(credential["id_token"])}, fresh(seconds)}

      {:ok, %{}} ->
        {:error, "the command printed JSON with no \"value\""}

      _not_json ->
        {:ok, %{value: output, id_token: nil}, @mint_fresh_ms}
    end
  end

  def minted(token, _now), do: {:ok, %{value: token, id_token: nil}, @mint_fresh_ms}

  defp fresh(seconds) when is_integer(seconds) and seconds > 0, do: max(seconds - 60, 0) * 1_000
  defp fresh(_none), do: @mint_fresh_ms

  defp text_or_nil(text) when is_binary(text) and text != "", do: text
  defp text_or_nil(_none), do: nil

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
  def refusal({:not_a_carrier, grant, headers, carriers}, request) do
    summary =
      "#{grant.name} placeholder in #{Enum.join(headers, ", ")}, " <>
        "not a header it travels in · refused"

    {request_event(request, grant, :refused, summary), nil,
     deny(
       403,
       "mwt_not_a_carrier",
       "#{grant.name}'s placeholder is in #{Enum.join(headers, ", ")}. MWT puts its real " <>
         "value only in #{Enum.join(carriers, ", ")}, and refuses a request " <>
         "with the placeholder anywhere else. Send it as the tool normally does, or ask " <>
         "the user to add the header to the grant.",
       grant
     )}
  end

  def refusal(:internet_off, request) do
    {%{
       outcome: :blocked,
       summary: "The Internet is off, and no grant on lists #{request.host} · refused",
       host: request.host,
       port: Map.get(request, :port, 443),
       method: request.method,
       path: request.path,
       exchange_id: Map.get(request, :exchange)
     }, nil,
     deny(
       403,
       "mwt_grant_off",
       "The Internet is off, and no grant that is on lists #{request.host}. " <>
         "Ask for it with: mwt request internet --reason \"...\"",
       nil
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

  def refusal({:made_elsewhere, made}, request) do
    summary = "#{made.name} sent to #{request.host} · blocked"

    {request_event(request, %{id: made.grant_id}, :violation, summary),
     {:leak, made.name, request.host, :request},
     deny(
       403,
       "mwt_placeholder_blocked",
       "#{made.name} may go only to #{Enum.join(made.hosts, ", ")}.",
       nil
     )}
  end

  def refusal({:made_stale, made}, request) do
    what = if made, do: made.name, else: "A JWT placeholder MWT wrote"

    {request_event(
       request,
       %{id: made && made.grant_id},
       :refused,
       "#{what}, no longer held · refused"
     ), nil,
     deny(
       403,
       "mwt_placeholder_expired",
       "#{what} is one MWT no longer holds: it expired, its grant no longer signs as its " <>
         "account or lists its host, or MWT restarted since it was made. Sign again: the " <>
         "tool's next sign-in does.",
       nil
     )}
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

  def refusal({:host_blocked, grant, entry}, request) do
    {request_event(
       request,
       grant,
       :blocked,
       MWTClient.Sandbox.Gate.blocked_words(grant, entry, request.host)
     ), nil,
     deny(
       403,
       "mwt_host_blocked",
       "#{request.host} is blocked on #{grant.name} (#{entry}): the user set it so, and MWT " <>
         "refuses every request to it. Asking for a grant won't change that; tell the user " <>
         "if you need it.",
       grant
     )}
  end

  def refusal({:plain_http, grant}, request) do
    {request_event(
       request,
       grant,
       :refused,
       "#{grant.name} placeholder over plain HTTP to #{request.host} · refused"
     ), nil,
     deny(
       403,
       "mwt_plain_http",
       "This request is plain HTTP, and carries #{grant.name}'s placeholder. Over plain HTTP " <>
         "nothing proves which host gets the request, so MWT puts no real value in one. " <>
         "Use https://#{request.host}.",
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
      port: Map.get(request, :port, 443),
      grant_id: grant.id,
      method: request.method,
      path: request.path,
      exchange_id: Map.get(request, :exchange)
    }
  end
end
