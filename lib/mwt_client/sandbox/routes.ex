defmodule MWTClient.Sandbox.Routes do
  @moduledoc """
  Which network interface this machine sends to an address through: what
  a network grant with a way out of its own (`Grant.anchor`, `wg0`,
  `tun0`) is checked against. A VPN that is down leaves its addresses to
  the default route, often a LAN using the same private range; then the
  grant opens nothing, instead of reaching whatever answers there.

  Asked of the system (`ip -j route get ADDRESS` on Linux, `route -n get
  ADDRESS` on macOS) and kept a few seconds, in a table beside the network
  path's view (`MWTClient.Sandbox.Gate`): a connection never waits on
  the sandbox's server for it. A route that can't be read is no route:
  the anchored grant opens nothing.

  A connection under an anchored grant is also bound to that interface
  (`options/1`, Linux's `SO_BINDTODEVICE`), so a route that changes after
  the check still can't take it elsewhere.

  It also knows this machine's own networks (`networks/0`): what its main
  routing tables send somewhere more specific than the default route. An
  address in one of them is never public (`MWTClient.Sandbox.Destinations`),
  whatever range it is in.
  """

  @table __MODULE__
  @kept_ms 3_000

  @doc false
  # Made by `MWTClient.Sandbox.Gate`, whose process lives as long as MWT.
  def table, do: @table

  @doc "The interface this machine routes `ip` through now, or nil."
  @spec via(:inet.ip_address()) :: String.t() | nil
  def via(ip) do
    now = System.monotonic_time(:millisecond)

    case lookup(ip) do
      {interface, at} when now - at < @kept_ms ->
        interface

      _none_or_old ->
        interface = read(ip)

        try do
          :ets.insert(@table, {ip, {interface, now}})
        rescue
          ArgumentError -> :ok
        end

        interface
    end
  end

  defp lookup(ip) do
    case :ets.lookup(@table, ip) do
      [{_ip, kept}] -> kept
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp read(ip) do
    address = ip |> :inet.ntoa() |> to_string()

    case :os.type() do
      {:unix, :linux} -> run("ip", ["-j", "route", "get", address], &linux/1)
      {:unix, :darwin} -> run("route", ["-n", "get", address], &bsd/1)
      _other -> nil
    end
  end

  defp run(command, args, parse) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> parse.(output)
      _failed -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  This machine's own networks, as `{address, prefix length}`: the routes of
  its main IPv4 and IPv6 tables more specific than a default (`/8` and
  longer for IPv4, `/16` and longer for IPv6). Those are its LANs, the
  on-link IPv6 prefix that gives its neighbours global addresses included,
  and what a VPN routes. Broader routes are defaults split in parts, as
  OpenVPN's `0.0.0.0/1` and `128.0.0.0/1` are. Read with `ip -j route` on
  Linux and kept a few seconds; none elsewhere, or when it can't be read.
  """
  @spec networks() :: [{:inet.ip_address(), non_neg_integer()}]
  def networks do
    now = System.monotonic_time(:millisecond)

    case lookup(:networks) do
      {networks, at} when now - at < @kept_ms ->
        networks

      _none_or_old ->
        networks = read_networks()

        try do
          :ets.insert(@table, {:networks, {networks, now}})
        rescue
          ArgumentError -> :ok
        end

        networks
    end
  end

  defp read_networks do
    case :os.type() do
      {:unix, :linux} ->
        for family <- ["-4", "-6"],
            network <-
              run("ip", ["-j", family, "route", "show", "table", "main"], &routes/1) || [],
            do: network

      _other ->
        []
    end
  end

  @doc """
  The networks in what `ip -j route show` printed (`networks/0`).

      iex> MWTClient.Sandbox.Routes.routes(~s([{"dst":"default","gateway":"192.168.1.1","dev":"wlan0"},{"dst":"192.168.1.0/24","dev":"wlan0"},{"dst":"203.0.113.0/24","dev":"tun0"},{"dst":"10.8.0.1","dev":"tun0"},{"dst":"0.0.0.0/1","dev":"tun0"}]))
      [{{192, 168, 1, 0}, 24}, {{203, 0, 113, 0}, 24}, {{10, 8, 0, 1}, 32}]

      iex> MWTClient.Sandbox.Routes.routes(~s([{"dst":"2a02:8108:1:2::/64","dev":"wlan0"},{"dst":"fe80::/64","dev":"wlan0"},{"dst":"2000::/3","dev":"wg0"},{"dst":"default","dev":"wlan0"}]))
      [{{10754, 33032, 1, 2, 0, 0, 0, 0}, 64}, {{65152, 0, 0, 0, 0, 0, 0, 0}, 64}]
  """
  @spec routes(String.t()) :: [{:inet.ip_address(), non_neg_integer()}]
  def routes(output) do
    case Jason.decode(output) do
      {:ok, routes} when is_list(routes) ->
        for %{"dst" => dst} <- routes, network = network(dst), network != nil, do: network

      _other ->
        []
    end
  end

  defp network("default"), do: nil

  defp network(dst) do
    {address, bits} =
      case String.split(dst, "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :host}
      end

    with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)) do
      most = if tuple_size(ip) == 4, do: 32, else: 128
      least = if tuple_size(ip) == 4, do: 8, else: 16

      case bits do
        :host -> {ip, most}
        {bits, ""} when bits >= least and bits <= most -> {ip, bits}
        _broad_or_bad -> nil
      end
    else
      _not_an_address -> nil
    end
  end

  @doc """
  The interface in what `ip -j route get` printed, or nil.

      iex> MWTClient.Sandbox.Routes.linux(~s([{"dst":"10.8.0.4","dev":"wg0","prefsrc":"10.8.0.2"}]))
      "wg0"
      iex> MWTClient.Sandbox.Routes.linux("RTNETLINK answers: Network is unreachable")
      nil
  """
  @spec linux(String.t()) :: String.t() | nil
  def linux(output) do
    case Jason.decode(output) do
      {:ok, [%{"dev" => dev} | _]} when is_binary(dev) -> dev
      _other -> nil
    end
  end

  @doc """
  The interface in what macOS's `route -n get` printed, or nil.

      iex> MWTClient.Sandbox.Routes.bsd("   route to: 10.8.0.4\\ndestination: 10.8.0.0\\n  interface: utun4\\n")
      "utun4"
  """
  @spec bsd(String.t()) :: String.t() | nil
  def bsd(output) do
    case Regex.run(~r/^\s*interface:\s*(\S+)\s*$/m, output) do
      [_, interface] -> interface
      nil -> nil
    end
  end

  @doc """
  The socket options that keep a connection on `anchor`: none without one,
  or where the system can't bind a socket to an interface (only Linux
  can; elsewhere the route checked just before is what holds).
  """
  @spec options(String.t() | nil) :: keyword()
  def options(nil), do: []

  def options(anchor) do
    case :os.type() do
      {:unix, :linux} -> [bind_to_device: anchor]
      _other -> []
    end
  end
end
