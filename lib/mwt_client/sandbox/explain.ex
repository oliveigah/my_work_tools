defmodule MWTClient.Sandbox.Explain do
  @moduledoc """
  Why a use of the VM's was, or would be, refused or asked about, for the
  agent to find out from MWT and tell you what to change, instead of
  guessing: `mwt why URL`, `mwt why --recent`, `mwt why ID`.

  Most tools hide MWT's answer (a client library turns a refusal into
  "403 Forbidden"), so the explanation doesn't depend on the tool passing
  it on: the agent asks for it.

  Pure. A dry run is the very decision a request would meet
  (`MWTClient.Sandbox.Policy.decide/3`), from the grants as they are: it
  sends nothing, waits on no one, makes no card, and is no use of any
  grant. It never looks up a name, so a name built to carry data reaches
  no DNS server through it.

  What an explanation holds is built from a list of what may be shown,
  never by leaving things out of the activity log:

    * the VM's own uses: method, host, port, path and query, as the VM sent
      them, made safe to show (`MWTClient.Sandbox.Shown`);
    * each grant's say, by its name and id, and why: its state, an
      allowance in force for this use, Always ask me;
    * locks, by what they lock; whether the VM is isolated;
    * the decision.

  It never holds a real value or a placeholder (a credential shows by its
  name), a body, a header's value, a command's output, the firewall's
  workings (which rule saw what), or anything but this VM's own uses.
  """

  alias MWTClient.Sandbox.{
    Allowance,
    Approval,
    Describe,
    Destinations,
    Event,
    Grant,
    Policy,
    Shown
  }

  @typedoc """
  What an explanation reads: the policy snapshot the network path decides
  from, whether the VM is isolated, and the clock.
  """
  @type world :: %{
          required(:snapshot) => Policy.snapshot(),
          required(:isolated) => boolean(),
          required(:now) => DateTime.t()
        }

  @recent 50

  @failed ~w(refused blocked violation denied timed_out)a

  @doc """
  How a request to `url` would be decided now, carrying the credential
  named `credential` (its id) or none: each grant with a say and what it
  says, the locks, the decision, and what would change it. Sends nothing.
  """
  @spec request(String.t(), String.t() | nil, String.t() | nil, world()) ::
          {:ok, String.t()} | {:error, String.t()}
  def request(url, method, credential, world) do
    method = method |> blank_to(nil) |> Kernel.||("GET") |> String.upcase()

    with {:ok, target} <- parse_url(url),
         {:ok, over} <- credential_grants(credential, world) do
      request = build(target, method, over, world)

      {:ok,
       "Dry run, with the grants as they are now: nothing was sent, no card was made, " <>
         "no grant was used.\n" <> explain(request, over, world)}
    end
  end

  @doc """
  The last decisions on the VM's uses, newest first, at most #{@recent}:
  refused, blocked, denied, timed out, and the cards still waiting, each
  with its id for `mwt why ID`. Only those since `since` (the VM's start),
  when given.
  """
  @spec recent([Event.t()], [Approval.t()], [Grant.t()], DateTime.t() | nil) :: String.t()
  def recent(events, waiting, grants, since \\ nil) do
    names = Map.new(grants, &{&1.id, &1.name})

    waiting_lines =
      for %Approval{kind: kind} = approval <- waiting,
          kind in [:request, :connection],
          do: {approval.requested_at, waiting_line(approval, names)}

    event_lines =
      for %Event{outcome: outcome, host: host} = event <- events,
          outcome in @failed,
          is_binary(host),
          is_nil(since) or DateTime.compare(event.at, since) != :lt,
          do: {event.at, event_line(event, names)}

    lines =
      (waiting_lines ++ event_lines)
      |> Enum.sort_by(&elem(&1, 0), {:desc, DateTime})
      |> Enum.take(@recent)
      |> Enum.map(&elem(&1, 1))

    case lines do
      [] ->
        "Nothing refused, asked about or timed out since this VM started."

      lines ->
        Enum.join(
          [
            "The last decisions on this VM's requests, newest first. mwt why ID explains one."
            | lines
          ],
          "\n"
        )
    end
  end

  @doc """
  One decision by its id (`recent/4`), explained as a dry run would decide
  the same use now: its method, host and path, with the credential it
  carried.
  """
  @spec decision(Event.t() | Approval.t() | nil, world()) ::
          {:ok, String.t()} | {:error, String.t()}
  def decision(nil, _world),
    do: {:error, "No decision by that id among this VM's. mwt why --recent lists them."}

  def decision(%Approval{request: %{} = request} = approval, world) do
    over = over_request(request, world)

    {:ok,
     "#{approval.id}: #{Shown.text(approval.title || "")}, #{status_words(approval)}.\n" <>
       explain(request, over, world)}
  end

  def decision(%Approval{} = approval, _world),
    do: {:ok, "#{approval.id}: #{Shown.text(approval.title || "")}, #{status_words(approval)}."}

  def decision(%Event{host: host} = event, world) when is_binary(host) do
    case recorded(event) do
      nil ->
        replayed(event, world)

      text ->
        {:ok,
         "#{event.id}: #{outcome_words(event.outcome)} at #{time(event.at)}. As decided then:\n" <>
           text}
    end
  end

  def decision(%Event{} = event, _world),
    do: {:ok, "#{event.id}: #{outcome_words(event.outcome)} at #{time(event.at)}."}

  @doc """
  A request's decision as it is made, in the words `mwt why ID` gives back:
  kept with its event (`record_section/1`), so the answer is what decided
  then, not the decision made again with the grants as they are later.
  Built from what `world` held at the decision; pure, as the rest.
  """
  @spec record(map(), world()) :: String.t()
  def record(request, world) do
    request = Map.merge(%{port: nil, plain?: false, path: "/", under: nil}, request)
    explain(request, over_request(request, world), world)
  end

  @record_title "The decision, as made"

  @doc "The event's section that keeps `record/2`'s words."
  @spec record_section(String.t()) :: map()
  def record_section(text),
    do: MWTClient.Sandbox.EventDetails.section(@record_title, [{"Decided", {:code, text}}])

  defp recorded(%Event{details: details}) when is_list(details) do
    Enum.find_value(details, fn
      %{title: @record_title, rows: rows} ->
        Enum.find_value(rows, fn
          {"Decided", {:code, text}} -> text
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp recorded(_event), do: nil

  # An event kept without its decision (one from before decisions were
  # kept): decided again now, from the grants as they are, as a dry run
  # that sends nothing and makes no card. Said so, so nobody takes it for
  # what decided then.
  defp replayed(%Event{host: host} = event, world) do
    over =
      case Enum.find(world.snapshot.grants, &(&1.id == event.grant_id)) do
        %Grant{kind: :token} = grant -> grants_over(Grant.credential_id(grant), world)
        _ -> []
      end

    target = %{
      scheme: "https",
      host: host,
      port: event.port || 443,
      path: event.path || "/"
    }

    request = build(target, event.method || "GET", over, world)

    {:ok,
     "#{event.id}: #{outcome_words(event.outcome)} at #{time(event.at)}. Its decision wasn't kept; " <>
       "a dry run with the grants as they are now (nothing sent, no card):\n" <>
       explain(request, over, world)}
  end

  ## Explaining one request

  defp explain(request, over, world) do
    decision = Policy.decide(world.snapshot, {:request, request}, world.now)
    credential = credential_says(request, over, world)
    network = network_says(request, world)
    locks = lock_lines(request, over, world)

    [
      "#{request.method} #{scheme(request)}://#{show_host(request)}#{Shown.text(request.path)}" <>
        credential_words(over),
      if(world.isolated,
        do: "The VM is isolated: everything is refused until the user releases it."
      ),
      if(locks != [], do: Enum.join(["Locks:" | locks], "\n")),
      credential && section(credential),
      section(network),
      "Decision: " <> decision_words(decision, world),
      changes(decision, says(credential) ++ says(network), over, world)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp says(nil), do: []
  defp says(%{says: says}), do: says

  # One resource the request goes through, with what each grant over it
  # covering the request says.
  defp section(%{title: title, says: says, empty: empty}) do
    lines = if says == [], do: ["  - " <> empty], else: Enum.map(says, &"  - #{&1.line}")
    Enum.join([title | lines], "\n")
  end

  # The credential the request carries: each grant over it listing the
  # host. Nil when it carries none.
  defp credential_says(_request, [], _world), do: nil

  defp credential_says(request, over, world) do
    covering =
      Enum.filter(over, &Policy.host_listed?(request.host, MWTClient.Sandbox.Adapter.hosts(&1)))

    about = Describe.request(request)

    %{
      title:
        "The credential #{credential_name(over)}: a grant over it that is on and lists the host gives it; the most permissive counts.",
      says: Enum.map(covering, &say(&1, about, world)),
      empty: "no grant over it lists #{request.host}: its value doesn't go there"
    }
  end

  # The network the request goes through: what it blocks, and each grant
  # over it covering the host, over all of it or naming it.
  defp network_says(request, world) do
    network = network_of(request, world)
    host = String.downcase(request.host)
    limits = world.snapshot |> Map.get(:limits, %{}) |> Map.get(network)
    about = Describe.request(request)

    blocked =
      if limits && MWTClient.Sandbox.HostLimits.blocked?(limits, host),
        do: [
          %{
            grant: nil,
            say: :blocked,
            line:
              "the user blocked #{host} on this network: refused whatever the grants say (mwt_host_blocked)"
          }
        ],
        else: []

    {covering, left_out} =
      for(
        %Grant{kind: :network} = g <- world.snapshot.grants,
        MWTClient.Sandbox.Network.id_of(g) == network,
        not MWTClient.Sandbox.Network.part?(g) or names?(g, host),
        do: g
      )
      |> Enum.split_with(&is_nil(MWTClient.Sandbox.Network.excepted(&1, [host])))

    # A grant that leaves the host out has no say: another grant over the
    # host gives it, on its own terms.
    left_out =
      for g <- left_out,
          do: %{
            grant: g,
            say: :excepted,
            line:
              "#{label(g)}: nothing, it leaves out #{MWTClient.Sandbox.Network.excepted(g, [host])}, as the user set it"
          }

    %{
      title:
        "The network #{network}: a grant over it that is on and covers the host gives it; the most permissive counts.",
      says: blocked ++ Enum.map(covering, &say(&1, about, world)) ++ left_out,
      empty: "no grant over it covers #{host}"
    }
  end

  # The network a request goes through: the one its connection went under,
  # or the Internet.
  defp network_of(request, world) do
    case Enum.find(world.snapshot.grants, &(&1.id == request.under and &1.kind == :network)) do
      %Grant{} = grant -> MWTClient.Sandbox.Network.id_of(grant)
      nil -> "internet"
    end
  end

  defp names?(grant, host) do
    case Destinations.parse_all(grant.destinations) do
      {:ok, specs} ->
        Enum.any?(specs, fn
          %{match: {kind, pattern}} when kind in [:host, :names] ->
            Destinations.name_covers?(kind, pattern, host)

          _range ->
            false
        end)

      _ ->
        false
    end
  end

  defp say(grant, about, world) do
    now = world.now

    {say, why} =
      cond do
        not Grant.on?(grant, now) ->
          {nil, "off: it gives nothing"}

        Enum.any?(grant.allowances, &Allowance.covers?(&1, :all, now)) ->
          {:yes, "on, auto-approved"}

        Enum.any?(grant.allowances, &Allowance.covers?(&1, about.pattern, now)) ->
          {:yes, "on, an allowance lets uses like this through"}

        true ->
          {:ask, "on, asking each time"}
      end

    words = %{yes: "yes", ask: "ask", nil: "nothing"}
    %{grant: grant, say: say, line: "#{label(grant)}: #{words[say]}, #{why}"}
  end

  defp lock_lines(request, over, world) do
    locks = Map.get(world.snapshot, :locks, %{})

    credential =
      case over do
        [grant | _] -> [{:credential, Grant.credential_id(grant)}]
        [] -> []
      end

    network =
      case Enum.find(world.snapshot.grants, &(&1.id == request.under and &1.kind == :network)) do
        %Grant{} = grant -> [{:network, MWTClient.Sandbox.Network.id_of(grant)}]
        nil -> []
      end

    for resource <- credential ++ network,
        Map.has_key?(locks, resource) do
      # The isolation's lock alone ends as the user releases the VM.
      case MWTClient.Sandbox.Server.Locks.holders(locks, resource) do
        [:isolation] ->
          "  - #{resource_words(resource)} is locked by the isolation: it ends as the user releases the VM."

        _yours ->
          "  - " <> MWTClient.Sandbox.Resource.locked_words(resource)
      end
    end
  end

  defp resource_words({:credential, id}), do: "The credential #{id}"
  defp resource_words({:network, id}), do: "The network #{id}"
  defp resource_words(:machine), do: "The user's machine"
  defp resource_words(:mwt), do: "MWT's tools"

  defp decision_words(:pass, _world), do: "goes through."

  defp decision_words({:allow, grant, _allowance, _about}, _world),
    do: "goes through#{if grant.kind == :token, do: ", with #{grant.name}'s value", else: ""}."

  defp decision_words({:ask, _grant, about}, world) do
    names = about |> Map.get(:asking, []) |> Enum.map_join(", ", &grant_name(&1, world))
    "waits for the user, on one card for #{names}."
  end

  defp decision_words({:refuse, reason}, _world), do: "refused: #{refusal_words(reason)}."

  defp refusal_words({:grant_off, grant}),
    do: "#{grant.name} (#{grant.id}) would give it, and is off"

  defp refusal_words({:locked, resource, _grant}),
    do: MWTClient.Sandbox.Resource.locked_words(resource)

  defp refusal_words({:uncovered, grant}),
    do:
      "no grant over its credential covers it: #{grant.name} covers only #{MWTClient.Sandbox.Attributes.words(grant.attributes || %{})}"

  defp refusal_words({:wrong_host, grant}), do: "#{grant.name}'s value doesn't go to that host"

  defp refusal_words({:not_a_carrier, grant, _, _}),
    do: "not in a header #{grant.name}'s value travels in"

  defp refusal_words({:plain_http, _grant}), do: "plain HTTP carries no value: use https://"

  defp refusal_words({:host_blocked, network, :default}),
    do: "the network #{network} reaches only the hosts the user listed, and not this one"

  defp refusal_words({:host_blocked, network, entry}),
    do: "the user blocked #{entry} on the network #{network}"

  defp refusal_words(:internet_off),
    do: "no grant that is on covers this public host: the Internet's grant is off"

  defp refusal_words({:excepted, %Grant{} = grant, entry}),
    do: "#{grant.name} leaves out #{entry}, and no other grant that is on covers that host"

  defp refusal_words({:outside, %Grant{} = grant}),
    do: "no grant over #{grant.name}'s network covers that host"

  defp refusal_words({:outside, network}),
    do: "no grant over the network #{network} covers that host"

  defp refusal_words(:multiple_grants), do: "it carries two credentials' placeholders"
  defp refusal_words(other), do: other |> inspect() |> Shown.text()

  # What would change the result, as things the agent can do or ask for.
  defp changes({:refuse, {:locked, _resource, _grant}}, _says, _over, _world),
    do: "To change it: tell the user; only they can unlock it, and asking won't."

  defp changes(_decision, _says, _over, %{isolated: true}),
    do: "To change it: tell the user what you were doing; only they release the VM."

  defp changes(decision, says, over, world) do
    lines =
      Enum.flat_map(says, fn
        %{grant: %Grant{} = g, say: nil} ->
          [
            "#{g.name} would give it, and is off: ask for it (mwt request #{g.id} --reason \"...\")."
          ]

        %{say: :blocked} ->
          [
            "The user blocked this host: asking for a grant changes nothing. Don't work around it; tell the user if you need it."
          ]

        %{grant: %Grant{} = g, say: :excepted} ->
          [
            "#{g.name} leaves this host out, as the user set it: only a grant over the host itself gives it. Ask for one (mwt request --need \"...\") if the task needs it."
          ]

        %{grant: %Grant{} = g, say: :ask} ->
          ["#{g.name} asks: the user decides on its card, or lets uses like this through."]

        _ ->
          []
      end) ++
        case decision do
          {:refuse, {:grant_off, g}} ->
            if Enum.any?(says, &(&1.grant == g)),
              do: [],
              else: [
                "#{g.name} would give it, and is off: ask for it (mwt request #{g.id} --reason \"...\")."
              ]

          {:refuse, {:wrong_host, _}} ->
            [
              "No grant over #{credential_name(over)} lists this host: propose one (mwt help propose) if the task needs it."
            ]

          _ ->
            []
        end

    _ = world

    case lines do
      [] -> nil
      lines -> Enum.join(["To change it:" | Enum.map(lines, &"  - #{&1}")], "\n")
    end
  end

  ## Building the request

  defp parse_url(url) do
    case URI.parse(String.trim(url || "")) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

        {:ok,
         %{
           scheme: scheme,
           host: String.downcase(host),
           port: uri.port || if(scheme == "https", do: 443, else: 80),
           path: path
         }}

      _other ->
        {:error,
         "Name a URL, as https://host/path, a host, or a decision's id (mwt why --recent)."}
    end
  end

  defp credential_grants(nil, _world), do: {:ok, []}
  defp credential_grants("", _world), do: {:ok, []}

  defp credential_grants(id, world) do
    case grants_over(id, world) do
      [] ->
        {:error,
         "No credential #{Shown.text(id)}. mwt grants lists the credentials, by the id mwt exec takes."}

      over ->
        {:ok, over}
    end
  end

  defp grants_over(id, world) do
    for %Grant{kind: :token} = g <- world.snapshot.grants,
        Grant.credential_id(g) == id,
        do: g
  end

  # The token grants over the credential whose placeholder a held request
  # carries; its headers are read here only to find which one, and never
  # shown.
  defp over_request(request, world) do
    headers = Map.get(request, :headers, [])

    case Enum.find(world.snapshot.grants, fn g ->
           g.kind == :token and is_binary(g.placeholder) and
             Enum.any?(Grant.placeholders(g), fn p ->
               Enum.any?(headers, fn {_name, value} -> String.contains?(value, p) end)
             end)
         end) do
      %Grant{} = grant -> grants_over(Grant.credential_id(grant), world)
      nil -> []
    end
  end

  # The request as the VM would send it: the credential's placeholder in
  # its first carrier, under the network grant that names its host, or the
  # Internet's. Built here only to be decided: never shown, never sent.
  defp build(target, method, over, world) do
    headers =
      case over do
        [grant | _] ->
          carrier = grant |> Grant.carriers() |> hd()

          value =
            if carrier == "authorization",
              do: "Bearer " <> grant.placeholder,
              else: grant.placeholder

          [{carrier, value}]

        [] ->
          []
      end

    %{
      host: target.host,
      port: target.port,
      method: method,
      path: target.path,
      headers: headers,
      body: "",
      plain?: target.scheme == "http",
      under: under(target, world)
    }
  end

  # The network grant whose destinations name the host, or the Internet's
  # for a public one. A name no grant names isn't looked up.
  defp under(target, world) do
    grants = world.snapshot.grants

    named =
      Enum.find(grants, fn
        %Grant{kind: :network, internet: false, destinations: destinations} ->
          case Destinations.parse_all(destinations) do
            {:ok, specs} ->
              Enum.any?(specs, fn
                %{match: {kind, pattern}, ports: ports} when kind in [:host, :names] ->
                  Destinations.name_covers?(kind, pattern, target.host) and
                    (ports == :any or target.port in ports)

                _range ->
                  false
              end)

            _ ->
              false
          end

        _other ->
          false
      end)

    case named || Enum.find(grants, &Grant.internet?/1) do
      %Grant{id: id} -> id
      nil -> nil
    end
  end

  ## Words

  defp credential_words([]), do: ", carrying no credential"
  defp credential_words(over), do: ", carrying the credential #{credential_name(over)}"

  defp credential_name([grant | _]), do: Grant.credential_id(grant)
  defp credential_name([]), do: "none"

  defp label(%Grant{kind: :network} = grant), do: "#{grant.name} (network, #{grant.id})"
  defp label(%Grant{} = grant), do: "#{grant.name} (#{grant.id})"

  defp grant_name(id, world) do
    case Enum.find(world.snapshot.grants, &(&1.id == id)) do
      %Grant{name: name} -> name
      nil -> id
    end
  end

  defp scheme(%{plain?: true}), do: "http"
  defp scheme(_request), do: "https"

  defp show_host(%{host: host} = request) do
    plain? = Map.get(request, :plain?, false)
    port = Map.get(request, :port)
    default = if plain?, do: 80, else: 443
    if port in [nil, default], do: host, else: "#{host}:#{port}"
  end

  defp waiting_line(approval, names) do
    asking = approval |> Approval.grant_ids() |> Enum.map_join(", ", &Map.get(names, &1, &1))

    "#{approval.id}  #{time(approval.requested_at)}  waiting  #{Shown.text(approval.title || "")}  · asks #{asking}"
  end

  defp event_line(event, names) do
    use =
      "#{event.method || ""} #{event.host}#{if event.port not in [nil, 443, 80], do: ":#{event.port}", else: ""}#{Shown.text(event.path || "")}"
      |> String.trim()

    grant =
      if event.grant_id, do: "  · #{Map.get(names, event.grant_id, event.grant_id)}", else: ""

    "#{event.id}  #{time(event.at)}  #{outcome_words(event.outcome)}  #{use}#{grant}"
  end

  defp outcome_words(:refused), do: "refused"
  defp outcome_words(:blocked), do: "blocked"
  defp outcome_words(:violation), do: "refused (sent where it doesn't go)"
  defp outcome_words(:denied), do: "denied by the user"
  defp outcome_words(:timed_out), do: "timed out, nobody decided"
  defp outcome_words(other), do: to_string(other)

  defp status_words(%Approval{status: :waiting}), do: "waiting for the user"
  defp status_words(%Approval{status: :allowed}), do: "allowed by the user"
  defp status_words(%Approval{status: :denied}), do: "denied"
  defp status_words(%Approval{status: :timed_out}), do: "timed out"

  defp time(nil), do: "-"
  defp time(at), do: Calendar.strftime(at, "%H:%M:%S")

  defp blank_to(nil, other), do: other
  defp blank_to("", other), do: other
  defp blank_to(value, _other), do: value
end
