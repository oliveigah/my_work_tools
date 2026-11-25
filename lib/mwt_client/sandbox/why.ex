defmodule MWTClient.Sandbox.Why do
  @moduledoc """
  `mwt why HOST[:PORT]`: which grant covers a destination, and why the VM
  doesn't reach it now. An agent that hits a refused connection or a name
  not found learns from one command which grant to ask for, instead of
  reading `mwt grants` and matching by hand.

  Pure. It answers from what MWT already holds (the grants, the
  firewall) through `MWTClient.Sandbox.Policy`, the same rules a
  connection meets, and resolves a name only when some grant names it: a
  name no grant covers is never looked up.

  What it says, a line each:

    * the firewall isolated the VM, or blocks the destination;
    * a token grant lists the name: MWT reads connections to it, and a
      request carrying its placeholder needs it on; reaching the host is
      the Internet's grant's to give, never the token grant's;
    * a network grant covers it, and is off (how to ask for it), or lists
      another port; a name it lists, which MWT answers only while the
      grant is on; its way out isn't connected (a VPN that is down);
    * a network blocks it (`MWTClient.Sandbox.HostLimits`), a grant
      leaves it out (`Grant.except`), or a grant over part of a network
      names it, on or off;
    * the Internet opens it, or is off; or the address is private or
      reserved, which the Internet never opens;
    * no grant covers it, and how to ask for access.
  """

  alias MWTClient.Sandbox.{Destinations, Firewall, Grant, Policy}

  @typedoc """
  What it reads: a policy snapshot (with `answered`, the addresses MWT's
  DNS answered for names network grants list), the firewall, whether the
  VM is isolated, the clock, and optionally `route`, the interface this
  machine routes an address through (`MWTClient.Sandbox.Routes.via/1`).
  """
  @type world :: %{
          required(:snapshot) => Policy.snapshot(),
          required(:firewall) => Firewall.t(),
          required(:isolated) => boolean(),
          required(:now) => DateTime.t(),
          optional(:route) => (Destinations.ip() -> String.t() | nil)
        }

  @doc """
  The answer for `target` (`HOST`, `HOST:PORT`, `[V6]:PORT` or a URL), as
  text for the agent; `{:error, message}` when it names no destination.

      iex> alias MWTClient.Sandbox.{Firewall, Policy, Why}
      iex> world = %{snapshot: Policy.snapshot([]) |> Map.put(:own, []), firewall: Firewall.new(),
      ...>   isolated: false, now: ~U[2026-11-17 12:00:00Z]}
      iex> {:ok, text} = Why.explain("10.1.2.3:5432", world)
      iex> text =~ "10.1.2.3:5432: not reached now"
      true
      iex> Why.explain("not a host!", world)
      {:error, "Name a host or an address, with a port if you know it: mwt why HOST[:PORT]"}
  """
  @spec explain(String.t(), world()) :: {:ok, String.t()} | {:error, String.t()}
  def explain(target, world) do
    case parse(target) do
      {:ok, host, port} ->
        {reached?, lines} = lines(host, port, world)
        shown = "#{show(host)}:#{port || 443}"
        head = "#{shown}: #{if reached?, do: "reached now", else: "not reached now"}"
        assumed = if port, do: [], else: ["- No port given: port 443 is assumed."]
        {:ok, Enum.join([head | assumed ++ lines], "\n") <> "\n"}

      :error ->
        {:error, "Name a host or an address, with a port if you know it: mwt why HOST[:PORT]"}
    end
  end

  ## Reading the target

  @doc false
  def parse(target) do
    text = target |> to_string() |> String.trim()

    {text, scheme_port} =
      case Regex.run(~r{\A([a-zA-Z][a-zA-Z0-9+.-]*)://(.*)\z}s, text) do
        [_, scheme, rest] -> {rest, if(String.downcase(scheme) == "http", do: 80, else: 443)}
        nil -> {text, nil}
      end

    authority = text |> String.split(["/", "?", "#"], parts: 2) |> hd()

    with {:ok, host, port} <- split(authority),
         {:ok, host} <- host(host) do
      {:ok, host, port || scheme_port}
    end
  end

  defp split("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, ""] ->
        {:ok, "[" <> address <> "]", nil}

      [address, ":" <> port] ->
        with {:ok, port} <- port(port), do: {:ok, "[" <> address <> "]", port}

      _ ->
        :error
    end
  end

  defp split(authority) do
    case String.split(authority, ":") do
      [host] -> {:ok, host, nil}
      [host, port] -> with {:ok, port} <- port(port), do: {:ok, host, port}
      _ipv6 -> {:ok, authority, nil}
    end
  end

  defp port(text) do
    case Integer.parse(text) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> :error
    end
  end

  defp host(text) do
    case Destinations.parse_ip(text) do
      {:ok, ip} ->
        {:ok, ip}

      :error ->
        name = text |> String.downcase() |> String.trim_trailing(".")

        if name =~ ~r/\A[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*\z/ and
             byte_size(name) <= 253,
           do: {:ok, name},
           else: :error
    end
  end

  defp show(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: "[#{:inet.ntoa(ip)}]"
  defp show(ip) when is_tuple(ip), do: "#{:inet.ntoa(ip)}"
  defp show(name), do: name

  ## The answer

  defp lines(_host, _port, %{isolated: true}) do
    {false,
     [
       "- MWT's firewall isolated this VM: nothing it sends leaves through MWT until the user releases it. They have been told."
     ]}
  end

  defp lines(host, port, world) do
    blocked = blocked(host, world.firewall)
    {listed_blocked?, listed} = host_lists(host, world)

    {reached?, lines} =
      if is_binary(host), do: name(host, port, world), else: address(host, port, world)

    {reached? and blocked == [] and not listed_blocked?, blocked ++ listed ++ lines}
  end

  # A name a network blocks (`MWTClient.Sandbox.HostLimits`), whatever its
  # grants say; and the grants over part of a network naming it, each
  # giving it beside the network's other grants, the most permissive
  # counting.
  defp host_lists(name, world) when is_binary(name) do
    name = String.downcase(name)
    limits = Map.get(world.snapshot, :limits, %{})

    blocked =
      for {network, limits} <- limits,
          MWTClient.Sandbox.HostLimits.blocked?(limits, name),
          # A network blocking by default speaks only for its own names.
          limits.default != :blocked or MWTClient.Sandbox.HostLimits.rule(limits, name) != nil,
          do:
            "- The network #{network} blocks it: every request there is refused, mwt_host_blocked. The user set it so: asking for a grant won't change it. Don't work around it; tell the user if you need it."

    parts =
      for %Grant{kind: :network} = grant <- world.snapshot.grants,
          MWTClient.Sandbox.Network.part?(grant),
          names?(grant, name) do
        if Grant.on?(grant, world.now),
          do:
            "- #{label(grant)} gives it and is on, as its approval says; the most permissive of the network's grants counts.",
          else: "- #{label(grant)} would give it, and is off. " <> ask(grant)
      end

    # A grant leaving it out (`Grant.except`) gives it nothing: with no
    # other grant on naming it, it isn't reached.
    excepting =
      for %Grant{kind: :network} = grant <- world.snapshot.grants,
          Grant.on?(grant, world.now),
          entry = MWTClient.Sandbox.Network.excepted(grant, [name]),
          do: {grant, entry}

    named_on? =
      Enum.any?(world.snapshot.grants, fn g ->
        g.kind == :network and MWTClient.Sandbox.Network.part?(g) and Grant.on?(g, world.now) and
          names?(g, name) and is_nil(MWTClient.Sandbox.Network.excepted(g, [name]))
      end)

    left_out =
      for {grant, entry} <- excepting,
          do:
            "- #{label(grant)} leaves it out (#{entry}), as the user set it: it gives it nothing. " <>
              if(named_on?,
                do: "A grant naming it gives it instead, as its approval says.",
                else:
                  "Only a grant over the host itself gives it: ask for one (mwt request --need \"...\") if the task needs it."
              )

    {blocked != [] or (excepting != [] and not named_on?), blocked ++ left_out ++ parts}
  end

  defp host_lists(_address, _world), do: {false, []}

  defp blocked(host, firewall) do
    name = show(host)

    if firewall.enabled and not Firewall.trusted?(firewall, name) and
         Firewall.listed?(name, firewall.blocked) and
         Firewall.action(firewall, :blocked_service) != :off,
       do: [
         "- MWT's firewall blocks it: it is on the list of blocked services (paste sites, file drops, tunnels). Don't work around it; tell the user if you need it."
       ],
       else: []
  end

  # A name: token grants that list it, network grants that name it. Only
  # then is it looked up, for the addresses a network grant may cover.
  defp name(name, port, world) do
    tokens =
      Enum.filter(
        grants(world, :token),
        &Policy.host_listed?(name, MWTClient.Sandbox.Adapter.hosts(&1))
      )

    networks = Enum.filter(grants(world, :network), &names?(&1, name))

    token_lines = Enum.map(tokens, &token_line(&1, world))

    cond do
      # Left out by the Internet's grant: said by `host_lists/2`.
      tokens == [] and networks == [] and internet_excepts?(world, name) ->
        {false, []}

      tokens == [] and networks == [] ->
        {internet_on?(world),
         [
           "- No grant names #{name}. MWT doesn't look it up for you here. If it is public, " <>
             internet_words(world) <>
             " If it is on a private network, a network grant must list it: " <>
             ~s(mwt request --need "#{name}:#{port || 443}, and what it is" --reason "why")
         ]}

      networks == [] ->
        # A token grant's host is read by MWT; reaching it is the
        # Internet's grant's to give, not the token grant's.
        {internet_on?(world), token_lines}

      true ->
        {reached?, network_lines} =
          case addresses(name, world) do
            [] ->
              {false, Enum.map(networks, &unanswered(&1, name, world))}

            [ip | _] ->
              address(ip, port, world, name)
          end

        {reached? or tokens != [], token_lines ++ network_lines}
    end
  end

  defp names?(grant, name) do
    Enum.any?(specs(grant), fn
      %{match: {kind, pattern}} -> Destinations.name_covers?(kind, pattern, name)
      _cidr -> false
    end)
  end

  # The addresses a covered name stands for: those MWT's DNS answered for
  # it and still holds. A snapshot without them (no DNS in between)
  # resolves it here.
  defp addresses(name, world) do
    case Map.get(world.snapshot, :answered) do
      nil ->
        world.snapshot.resolve.(name)

      answered ->
        for {ip, names} <- answered, name in names, do: ip
    end
  end

  defp unanswered(grant, name, world) do
    cond do
      not Map.has_key?(world.snapshot, :answered) ->
        "- #{label(grant)} lists #{name}, but it doesn't resolve here now."

      live(grant, world) ->
        "- #{label(grant)} lists #{name}, and is on, but MWT hasn't answered it yet: look it up now (it resolves only while the grant is on), then connect."

      true ->
        "- #{label(grant)} lists #{name}, and is off: MWT answers its names only while it is on, so it doesn't resolve now. " <>
          ask(grant)
    end
  end

  defp token_line(grant, world) do
    "- #{label(grant)} lists it: MWT reads connections to it, and " <>
      cond do
        not internet_on?(world) ->
          "it gives no way there: if it is public, " <> internet_words(world)

        live(grant, world) ->
          "a request carrying its placeholder goes through it (it is on; run the tool with mwt exec #{Grant.credential_id(grant)} -- COMMAND)."

        true ->
          "a request carrying its placeholder needs it on: #{ask(grant)}"
      end
  end

  # An address, or one a covered name resolved to (`name`).
  defp address(ip, port, world, name \\ nil) do
    class = Destinations.classify(ip, world.snapshot.own, Map.get(world.snapshot, :networks, []))
    port = port || 443
    networks = grants(world, :network) |> Enum.reject(&Grant.internet?/1)

    answered = Map.get(world.snapshot, :answered)

    # The interface this machine routes the address through, when a grant
    # has a way out of its own.
    via =
      if Enum.any?(networks, & &1.anchor),
        do: Map.get(world, :route, fn _ -> nil end).(ip)

    snapshot = Map.put(world.snapshot, :via, via)

    covering =
      for grant <- networks,
          spec <- specs(grant),
          Destinations.matches?(%{spec | ports: :any}, ip, port, snapshot.resolve, answered),
          class != :refused or Destinations.exact?(spec, ip) or
            match?({kind, _} when kind in [:host, :names], spec.match),
          do: {grant, spec}

    reached? =
      case Policy.decide(snapshot, {:connection, ip, port}, world.now) do
        {:refuse, _reason} -> false
        _allow_or_ask -> true
      end

    shown = name || show(ip)

    lines =
      Enum.map(covering, fn {grant, spec} ->
        cond do
          spec.ports != :any and port not in spec.ports ->
            "- #{label(grant)} covers #{shown} as #{spec.source}, but not port #{port}: it opens #{Enum.join(spec.ports, ", ")}."

          live(grant, world) and grant.anchor != nil and via != grant.anchor ->
            "- #{label(grant)} covers #{shown} as #{spec.source}, and is on, but its network isn't connected: " <>
              "it goes only through the user's #{grant.anchor}, which doesn't reach #{show(ip)} now (a VPN that is down?). " <>
              "It opens nothing until it is back: tell the user."

          live(grant, world) ->
            "- #{label(grant)} covers #{shown} as #{spec.source}, and is on" <>
              if(Grant.auto_approved?(grant, world.now),
                do: ".",
                else: ": each connection may wait for the user's approval."
              )

          true ->
            "- #{label(grant)} covers #{shown} as #{spec.source}, and is off: #{ask(grant)}"
        end
      end)

    lines =
      case {class, covering} do
        {:public, []} ->
          ["- #{show(ip)} is a public address: " <> internet_words(world)]

        {:private, []} ->
          [
            "- #{show(ip)} is a private address (a LAN or a VPN). The Internet grant never opens one; no network grant lists it. Ask for access: " <>
              ~s(mwt request --need "#{shown}:#{port}, and what it is" --reason "why")
          ]

        {:refused, []} ->
          [
            "- #{show(ip)} is this machine, loopback or a reserved range: only a network grant naming exactly this address opens it, and none does. Ask for access: " <>
              ~s(mwt request --need "#{shown}:#{port}, and what it is" --reason "why")
          ]

        {_class, _covering} ->
          lines
      end

    {reached?, lines}
  end

  defp internet_words(world) do
    case Enum.find(world.snapshot.grants, &Grant.internet?/1) do
      nil ->
        "no grant opens the Internet."

      internet ->
        cond do
          live(internet, world) ->
            "the Internet grant opens it, and is on."

          true ->
            "the Internet grant would open it, and is off: #{ask(internet)}"
        end
    end
  end

  defp internet_excepts?(world, name) do
    case Enum.find(world.snapshot.grants, &Grant.internet?/1) do
      nil -> false
      internet -> MWTClient.Sandbox.Network.excepted(internet, [name]) != nil
    end
  end

  defp internet_on?(world) do
    case Enum.find(world.snapshot.grants, &Grant.internet?/1) do
      nil -> false
      internet -> live(internet, world)
    end
  end

  defp grants(world, kind),
    do: Enum.filter(world.snapshot.grants, &(&1.kind == kind and not Grant.action?(&1)))

  defp live(grant, world), do: Grant.on?(grant, world.now)

  defp label(grant), do: "#{grant.name} (#{kind_words(grant)} `#{grant.id}`)"

  defp kind_words(%Grant{kind: :token}), do: "token grant"
  defp kind_words(%Grant{kind: :network}), do: "network grant"
  defp kind_words(_grant), do: "grant"

  defp ask(grant),
    do: ~s(ask for it with mwt request #{grant.id} --reason "what you are about to do".)

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end
end
