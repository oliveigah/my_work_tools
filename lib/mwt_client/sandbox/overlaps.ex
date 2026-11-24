defmodule MWTClient.Sandbox.Overlaps do
  @moduledoc """
  Which grants over the same resource may cover the same use, worked out
  from their scopes every time it is asked: nobody declares a link, so
  none can be missing or stale.

  Of grants over one resource that cover a use, the most permissive
  counts (`MWTClient.Sandbox.Policy.most_permissive/1`): turning one off
  doesn't stop a use another still gives. So every grant's page lists the
  grants it overlaps, and `mwt grants` lists them under it.

  Two grants overlap when some use of their resource could be covered by
  both:

    * two token grants over the same credential whose hosts meet: equal
      hosts, a host under the other's `*.` entry, or one `*.` entry under
      another;
    * two network grants over the same network whose destinations meet,
      the one over all of it meeting every one over part of it.

  Grants over different resources never overlap: a use that goes through
  both needs each (a token grant and the network grant of its host).

  What can't be told from the scopes is marked *may overlap*, with why: a
  name and an address range meet only if the name resolves into the
  range, which DNS decides when the use is made.
  """

  alias MWTClient.Sandbox.{Destinations, Grant}

  @typedoc "One overlap of a grant with another: what they share, and whether it is only possible."
  @type t :: %{grant: Grant.t(), shared: String.t(), may?: boolean()}

  @doc """
  The grants `grant` overlaps among `grants`, each with what they share.

      iex> alias MWTClient.Sandbox.{Grant, Overlaps}
      iex> all = %Grant{id: "all", name: "Google", kind: :token, credential: "g", hosts: ["*.googleapis.com"]}
      iex> gcs = %Grant{id: "gcs", name: "Storage", kind: :token, credential: "g", hosts: ["storage.googleapis.com"]}
      iex> gh = %Grant{id: "gh", name: "GitHub", kind: :token, credential: "gh", hosts: ["api.github.com"]}
      iex> [%{grant: %{id: "all"}, shared: shared, may?: false}] = Overlaps.of(gcs, [all, gcs, gh])
      iex> shared
      "storage.googleapis.com"
  """
  @spec of(Grant.t(), [Grant.t()]) :: [t()]
  def of(%Grant{} = grant, grants) do
    for other <- grants,
        other.id != grant.id,
        overlap = overlap(grant, other),
        do: Map.put(overlap, :grant, other)
  end

  # Token grants over the same credential: where their hosts meet.
  defp overlap(%Grant{kind: :token} = a, %Grant{kind: :token} = b) do
    if Grant.credential_id(a) == Grant.credential_id(b) do
      case shared_hosts(a.hosts, b.hosts) do
        [] -> nil
        hosts -> %{shared: Enum.join(hosts, ", "), may?: false}
      end
    end
  end

  # Network grants over the same network: the Internet's over all of it
  # meets every one over some of its hosts.
  defp overlap(%Grant{kind: :network} = a, %Grant{kind: :network} = b) do
    cond do
      Grant.resource(a) != Grant.resource(b) ->
        nil

      Grant.internet?(a) or Grant.internet?(b) ->
        other = if Grant.internet?(a), do: b, else: a

        case names(other) do
          [] -> nil
          names -> %{shared: Enum.join(names, ", "), may?: false}
        end

      true ->
        destinations_meet(specs(a), specs(b))
    end
  end

  defp overlap(_a, _b), do: nil

  @doc """
  Where two host lists meet: each host one names that the other covers,
  the narrower of two wildcards that nest.

      iex> MWTClient.Sandbox.Overlaps.shared_hosts(["*.googleapis.com"], ["storage.googleapis.com", "github.com"])
      ["storage.googleapis.com"]
      iex> MWTClient.Sandbox.Overlaps.shared_hosts(["*.googleapis.com"], ["*.storage.googleapis.com"])
      ["*.storage.googleapis.com"]
  """
  @spec shared_hosts([String.t()], [String.t()]) :: [String.t()]
  def shared_hosts(a, b) do
    for x <- a, y <- b, meet = meet(String.downcase(x), String.downcase(y)), uniq: true, do: meet
  end

  defp meet(same, same), do: same
  defp meet("*." <> s1 = w1, "*." <> s2 = w2), do: narrower_wild(s1, w1, s2, w2)
  defp meet("*." <> suffix, host), do: if(under?(host, suffix), do: host)
  defp meet(host, "*." <> suffix), do: if(under?(host, suffix), do: host)
  defp meet(_a, _b), do: nil

  defp narrower_wild(s1, w1, s2, w2) do
    cond do
      under?(s2, s1) -> w2
      under?(s1, s2) -> w1
      true -> nil
    end
  end

  defp under?(host, suffix), do: host == suffix or String.ends_with?(host, "." <> suffix)

  defp names(network) do
    for %{match: {kind, pattern}} <- specs(network), kind in [:host, :names] do
      if kind == :names, do: "*." <> pattern, else: pattern
    end
  end

  defp destinations_meet(a, b) do
    exact =
      for %{match: {k1, p1}} <- a,
          %{match: {k2, p2}} <- b,
          k1 in [:host, :names] and k2 in [:host, :names],
          meet = meet(wild(k1, p1), wild(k2, p2)),
          uniq: true,
          do: meet

    ranges_meet =
      for %{match: {:cidr, n1, b1}, source: s1} <- a,
          %{match: {:cidr, n2, b2}, source: s2} <- b,
          ranges_meet?(n1, b1, n2, b2),
          uniq: true,
          do: if(b1 >= b2, do: s1, else: s2)

    name_range? =
      (Enum.any?(a, &name?/1) and Enum.any?(b, &range?/1)) or
        (Enum.any?(a, &range?/1) and Enum.any?(b, &name?/1))

    cond do
      exact ++ ranges_meet != [] ->
        %{shared: Enum.join(exact ++ ranges_meet, ", "), may?: false}

      name_range? ->
        %{
          shared: "names and address ranges",
          may?: true,
          why: "if the names resolve into the ranges"
        }

      true ->
        nil
    end
  end

  defp wild(:names, pattern), do: "*." <> pattern
  defp wild(:host, pattern), do: pattern

  defp name?(%{match: {kind, _}}), do: kind in [:host, :names]
  defp name?(_range), do: false
  defp range?(%{match: {:cidr, _, _}}), do: true
  defp range?(_spec), do: false

  defp ranges_meet?(n1, b1, n2, b2) when tuple_size(n1) == tuple_size(n2) do
    bits = min(b1, b2)
    prefix(n1, bits) == prefix(n2, bits)
  end

  defp ranges_meet?(_n1, _b1, _n2, _b2), do: false

  defp prefix(ip, bits) do
    size = if tuple_size(ip) == 4, do: 8, else: 16

    whole =
      ip
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc -> acc * Bitwise.bsl(1, size) + part end)

    total = tuple_size(ip) * size
    Bitwise.bsr(whole, total - bits)
  end

  defp specs(%Grant{destinations: destinations}) do
    case Destinations.parse_all(destinations) do
      {:ok, specs} -> specs
      {:error, _} -> []
    end
  end

  @doc """
  What an overlap means now, in a line: where one of the two is on and the
  other off, the one on gives what they share there.
  """
  @spec words(Grant.t(), t(), DateTime.t()) :: String.t()
  def words(%Grant{} = grant, %{grant: other} = overlap, now) do
    where =
      if overlap.may?,
        do: "may overlap at #{overlap.shared} (#{overlap[:why]})",
        else: "overlaps at #{overlap.shared}"

    "#{other.name} #{where}" <>
      case {Grant.state_at(grant, now), Grant.state_at(other, now)} do
        {:off, :on} -> ": #{other.name} is on, and gives it there while #{grant.name} is off"
        {:on, :off} -> ": #{grant.name} is on, and gives it there while #{other.name} is off"
        _same -> ""
      end
  end
end
