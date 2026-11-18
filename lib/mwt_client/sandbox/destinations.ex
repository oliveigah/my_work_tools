defmodule MWTClient.Sandbox.Destinations do
  @moduledoc """
  Where the VM's connections may go.

  Microsandbox resolves names itself and hands MWT an IP and a port, so every
  check here is on addresses:

    * **refused** - loopback, link-local, cloud metadata, unspecified,
      multicast, the reserved `240.0.0.0/4`, and every address of this
      machine's own interfaces. Reaching them reaches MWT and whatever else
      listens here. Only a network grant naming the exact address and port
      opens one (a database tunnel on loopback, say).
    * **private** - RFC 1918, carrier-grade NAT, unique-local and site-local
      IPv6: your LAN and your VPN. Also `198.18.0.0/15`, the pool local
      proxies (Clash, sing-box) hand out as fake addresses and map anywhere,
      and NAT64 prefixes a network chose itself. And whatever is in this
      machine's own networks (`MWTClient.Sandbox.Routes.networks/0`), in
      any range: a LAN numbered from public space, a neighbour's global IPv6
      address on your LAN's prefix, a VPN's public-numbered network.
      Allowed while a network grant that lists them is on.
    * **public** - everything else; passed through.

  An IPv6 address that carries an IPv4 one (mapped, SIIT, IPv4-compatible,
  NAT64's `64:ff9b::/96`, 6to4's `2002::/16`) is judged as the stricter of
  the two: on a host that translates it, it reaches the IPv4 address inside.

  A network grant lists destinations, one per entry, as `ADDRESS[:PORTS]`:
  an IP, a CIDR range or a host name, and optionally comma-separated ports.
  `10.20.0.0/16:443,5432`, `git.corp.internal:443`, `127.0.0.1:5433`,
  `[fd00::5]:22`. Anything after `#` is a note.
  """

  import Bitwise

  @type ip :: :inet.ip_address()
  @type spec :: %{
          source: String.t(),
          match: {:cidr, ip(), non_neg_integer()} | {:host, String.t()} | {:names, String.t()},
          ports: :any | [:inet.port_number()]
        }

  @refused [
    {{127, 0, 0, 0}, 8},
    {{0, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    # IETF protocol assignments, Oracle Cloud's metadata (192.0.0.192) among
    # them.
    {{192, 0, 0, 0}, 24},
    # Alibaba Cloud's metadata, inside carrier-grade NAT.
    {{100, 100, 100, 200}, 32},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    # AWS's IPv6 metadata, inside unique-local.
    {{0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254}, 128},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @private [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{100, 64, 0, 0}, 10},
    {{198, 18, 0, 0}, 15},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
    # NAT64 for a network's own use (RFC 8215): where it leads is theirs.
    {{0x0064, 0xFF9B, 0x0001, 0, 0, 0, 0, 0}, 48}
  ]

  @strictness %{public: 0, private: 1, refused: 2}

  @doc "The ranges refused whatever the grants, as text."
  @spec refused_ranges() :: [String.t()]
  def refused_ranges, do: Enum.map(@refused, fn {ip, bits} -> "#{:inet.ntoa(ip)}/#{bits}" end)

  @doc "This machine's own addresses, read from its network interfaces."
  @spec host_addresses() :: [ip()]
  def host_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces, {:addr, addr} <- opts, uniq: true, do: addr

      {:error, _} ->
        []
    end
  end

  @doc """
  Whether `ip` is refused, private or public. `own` defaults to
  `host_addresses/0`; `networks` are this machine's own networks
  (`MWTClient.Sandbox.Routes.networks/0`), in which no address is public.

      iex> lan = [{{0x2A02, 0x8108, 1, 2, 0, 0, 0, 0}, 64}]
      iex> MWTClient.Sandbox.Destinations.classify({0x2A02, 0x8108, 1, 2, 0, 0, 0, 5}, [], lan)
      :private
      iex> MWTClient.Sandbox.Destinations.classify({0x2A02, 0x8108, 1, 3, 0, 0, 0, 5}, [], lan)
      :public
  """
  @spec classify(ip(), [ip()], [{ip(), non_neg_integer()}]) :: :refused | :private | :public
  def classify(ip, own \\ host_addresses(), networks \\ []) do
    ip = unmap(ip)
    own = Enum.map(own, &unmap/1)

    case embedded(ip) do
      nil ->
        class(ip, own, networks)

      inside ->
        Enum.max_by([class(ip, own, networks), class(inside, own, networks)], &@strictness[&1])
    end
  end

  defp class(ip, own, networks) do
    cond do
      ip in own -> :refused
      Enum.any?(@refused, fn {net, bits} -> in_range?(ip, net, bits) end) -> :refused
      Enum.any?(@private, fn {net, bits} -> in_range?(ip, net, bits) end) -> :private
      Enum.any?(networks, fn {net, bits} -> in_range?(ip, net, bits) end) -> :private
      true -> :public
    end
  end

  # The IPv4 address an IPv6 one carries, where a translator on the way
  # would deliver it: SIIT (`::ffff:0:a.b.c.d`), IPv4-compatible
  # (`::a.b.c.d`), NAT64 (`64:ff9b::a.b.c.d`) and 6to4 (`2002:AABB:CCDD::`).
  # Mapped addresses are unmapped before.
  defp embedded({0, 0, 0, 0, 0xFFFF, 0, high, low}), do: ipv4(high, low)
  defp embedded({0, 0, 0, 0, 0, 0, high, low}), do: ipv4(high, low)
  defp embedded({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: ipv4(high, low)
  defp embedded({0x2002, high, low, _, _, _, _, _}), do: ipv4(high, low)
  defp embedded(_ip), do: nil

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  @doc "Parses one destination of a network grant."
  @spec parse(String.t()) :: {:ok, spec()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    source = text |> String.split("#", parts: 2) |> hd() |> String.trim()

    with {address, ports} <- split_ports(source),
         {:ok, ports} <- parse_ports(ports),
         {:ok, match} <- parse_address(address) do
      {:ok, %{source: source, match: match, ports: ports}}
    else
      {:error, message} -> {:error, "#{text}: #{message}"}
    end
  end

  @doc "Parses every destination, keeping the first error."
  @spec parse_all([String.t()]) :: {:ok, [spec()]} | {:error, String.t()}
  def parse_all(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case parse(text) do
        {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  @doc """
  Whether a destination covers `ip` and `port`. Host names are resolved with
  `resolve`, which defaults to this machine's resolver, so VPN names resolve
  the way they do for you.
  """
  @spec matches?(spec(), ip(), :inet.port_number(), (String.t() -> [ip()]), map() | nil) ::
          boolean()
  def matches?(%{match: match, ports: ports}, ip, port, resolve \\ &resolve/1, answered \\ nil) do
    port_ok? = ports == :any or port in ports

    port_ok? and
      case {match, answered} do
        {{:cidr, net, bits}, _} ->
          in_range?(unmap(ip), net, bits)

        # A name opens only an address MWT answered for it, or for a name
        # under it (`*.`): never one the VM typed by hand.
        {{kind, pattern}, %{} = answered} when kind in [:host, :names] ->
          answered |> Map.get(unmap(ip), []) |> Enum.any?(&name_covers?(kind, pattern, &1))

        # With nothing answered to go by (a snapshot from before names were
        # bound), a name is resolved here, as it was.
        {{:host, name}, nil} ->
          unmap(ip) in Enum.map(resolve.(name), &unmap/1)

        {{:names, _pattern}, nil} ->
          false
      end
  end

  @doc """
  Whether a destination's name covers `name`: itself, or, `*.` written,
  every name under it.

      iex> MWTClient.Sandbox.Destinations.name_covers?(:names, "corp.example", "db.corp.example")
      true
      iex> MWTClient.Sandbox.Destinations.name_covers?(:host, "corp.example", "db.corp.example")
      false
  """
  @spec name_covers?(:host | :names, String.t(), String.t()) :: boolean()
  def name_covers?(:host, name, other), do: String.downcase(other) == name

  def name_covers?(:names, suffix, other) do
    other = String.downcase(other)
    other == suffix or String.ends_with?(other, "." <> suffix)
  end

  @doc "Whether a destination names exactly this address, as opening a refused one needs."
  @spec exact?(spec(), ip()) :: boolean()
  def exact?(%{match: {:cidr, net, bits}}, ip), do: bits == address_bits(ip) and unmap(ip) == net
  def exact?(_spec, _ip), do: false

  @doc "Every address `name` resolves to here."
  @spec resolve(String.t()) :: [ip()]
  def resolve(name) do
    charlist = String.to_charlist(name)

    for family <- [:inet, :inet6],
        {:ok, addrs} <- [:inet.getaddrs(charlist, family)],
        addr <- addrs,
        do: addr
  end

  @doc "Parses the address part of a CONNECT target."
  @spec parse_ip(String.t()) :: {:ok, ip()} | :error
  def parse_ip(text) do
    case text
         |> String.trim_leading("[")
         |> String.trim_trailing("]")
         |> String.to_charlist()
         |> :inet.parse_address() do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp split_ports("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, ""] -> {address, nil}
      [address, ":" <> ports] -> {address, ports}
      _ -> {:error, "unclosed ["}
    end
  end

  defp split_ports(source) do
    case String.split(source, ":") do
      [address] -> {address, nil}
      [address, ports] -> {address, ports}
      _ipv6 -> {source, nil}
    end
  end

  defp parse_ports(nil), do: {:ok, :any}

  defp parse_ports(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {port, ""} when port in 1..65_535 -> {:cont, {:ok, acc ++ [port]}}
        _ -> {:halt, {:error, "#{part} is not a port"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "no ports after :"}
      result -> result
    end
  end

  defp parse_address(""), do: {:error, "no address"}

  defp parse_address(address) do
    case String.split(address, "/") do
      [ip_text, bits_text] ->
        with {:ok, ip} <- parse_ip(ip_text),
             {bits, ""} <- Integer.parse(bits_text),
             true <- bits in 0..address_bits(ip) do
          {:ok, {:cidr, mask(ip, bits), bits}}
        else
          _ -> {:error, "not a valid range"}
        end

      [single] ->
        case parse_ip(single) do
          {:ok, ip} ->
            {:ok, {:cidr, ip, address_bits(ip)}}

          :error ->
            {kind, name} =
              case single do
                "*." <> rest -> {:names, rest}
                name -> {:host, name}
              end

            if Regex.match?(
                 ~r/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/,
                 name
               ),
               do: {:ok, {kind, String.downcase(name)}},
               else: {:error, "not an address or a host name"}
        end

      _ ->
        {:error, "not a valid range"}
    end
  end

  @doc "An IPv4 address mapped into IPv6 (`::ffff:a.b.c.d`), as the IPv4 address it carries; any other as it is."
  @spec unmap(ip()) :: ip()
  def unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: ipv4(high, low)
  def unmap(ip), do: ip

  defp address_bits(ip) when tuple_size(ip) == 4, do: 32
  defp address_bits(ip) when tuple_size(ip) == 8, do: 128

  defp in_range?(ip, net, bits) when tuple_size(ip) == tuple_size(net),
    do: mask(ip, bits) == mask(net, bits)

  defp in_range?(_ip, _net, _bits), do: false

  defp mask(ip, bits) do
    {size, width} = if tuple_size(ip) == 4, do: {32, 8}, else: {128, 16}
    value = ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
    masked = value &&& (1 <<< size) - 1 - ((1 <<< (size - bits)) - 1)

    for(
      shift <- (div(size, width) - 1)..0//-1,
      do: masked >>> (shift * width) &&& (1 <<< width) - 1
    )
    |> List.to_tuple()
  end
end
