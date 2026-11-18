defmodule MWTClient.Sandbox.Placeholder do
  @moduledoc """
  A token grant's placeholder in a request's headers: finding it, and putting
  the real value in its place.

  The two are one module so they can't disagree: what `carrier/3` finds is
  what `swap/4` replaces. A placeholder is long and random, so a plain
  substring is unambiguous. It is looked for in each header as sent, and
  inside a `Basic` credential (the scheme in any case), which is how git and
  `curl -u` send a password.

  The real value goes only into the grant's **carriers**, the headers it
  travels in (`authorization` unless the grant names others). Anywhere else
  a service may copy a header into its answer, and the value would come
  back to the VM: `outside/3` names the headers that carry the placeholder
  where it doesn't belong, so the request can be refused instead. Headers
  only: a placeholder in a URL or a body goes out as it is.
  """

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Whether some header, any header, carries `placeholder`: what a request to
  a host the grant doesn't list is checked for.

      iex> MWTClient.Sandbox.Placeholder.in?([{"authorization", "Bearer mwt_x"}], "mwt_x")
      true

      iex> basic = "basic " <> Base.encode64("git:mwt_x")
      iex> MWTClient.Sandbox.Placeholder.in?([{"x-other", basic}], "mwt_x")
      true

      iex> MWTClient.Sandbox.Placeholder.in?([{"accept", "*/*"}], "mwt_x")
      false
  """
  @spec in?(headers(), String.t() | nil) :: boolean()
  def in?(headers, placeholder) when is_binary(placeholder),
    do: Enum.any?(headers, &holds?(&1, placeholder))

  def in?(_headers, nil), do: false

  @doc """
  The first of `carriers` that carries `placeholder`, or nil.

      iex> MWTClient.Sandbox.Placeholder.carrier([{"authorization", "token mwt_x"}], "mwt_x", ["authorization"])
      "authorization"

      iex> MWTClient.Sandbox.Placeholder.carrier([{"user-agent", "mwt_x"}], "mwt_x", ["authorization"])
      nil
  """
  @spec carrier(headers(), String.t(), [String.t()]) :: String.t() | nil
  def carrier(headers, placeholder, carriers) do
    Enum.find_value(headers, fn {name, _} = header ->
      if name in carriers and holds?(header, placeholder), do: name
    end)
  end

  @doc """
  The headers, other than `carriers`, that carry `placeholder`: each a
  place the real value must never be put.

      iex> headers = [{"authorization", "token mwt_x"}, {"user-agent", "mwt_x"}]
      iex> MWTClient.Sandbox.Placeholder.outside(headers, "mwt_x", ["authorization"])
      ["user-agent"]
  """
  @spec outside(headers(), String.t(), [String.t()]) :: [String.t()]
  def outside(headers, placeholder, carriers) do
    for {name, _} = header <- headers,
        name not in carriers,
        holds?(header, placeholder),
        uniq: true,
        do: name
  end

  @doc """
  The headers with `value` wherever `placeholder` was in one of `carriers`.
  Other headers are left as they are.

      iex> MWTClient.Sandbox.Placeholder.swap([{"authorization", "Bearer mwt_x"}], "mwt_x", "real", ["authorization"])
      [{"authorization", "Bearer real"}]

      iex> MWTClient.Sandbox.Placeholder.swap([{"x-echo", "mwt_x"}], "mwt_x", "real", ["authorization"])
      [{"x-echo", "mwt_x"}]
  """
  @spec swap(headers(), String.t(), String.t(), [String.t()]) :: headers()
  def swap(headers, placeholder, value, carriers) do
    Enum.map(headers, fn
      {name, header} = untouched ->
        if name in carriers, do: {name, swapped(header, placeholder, value)}, else: untouched
    end)
  end

  defp swapped(header, placeholder, value) do
    case basic(header) do
      {scheme, decoded} ->
        if String.contains?(decoded, placeholder),
          do: scheme <> " " <> Base.encode64(String.replace(decoded, placeholder, value)),
          else: String.replace(header, placeholder, value)

      nil ->
        String.replace(header, placeholder, value)
    end
  end

  @doc """
  What a header holds once a `Basic` credential in it is decoded, the
  scheme in any case; nil for any other header.

      iex> MWTClient.Sandbox.Placeholder.decoded("BASIC " <> Base.encode64("git:x"))
      "git:x"
  """
  @spec decoded(String.t()) :: String.t() | nil
  def decoded(header) do
    case basic(header) do
      {_scheme, decoded} -> decoded
      nil -> nil
    end
  end

  defp holds?({_name, header}, placeholder),
    do:
      String.contains?(header, placeholder) or
        String.contains?(decoded(header) || "", placeholder)

  defp basic(value) do
    with [scheme, encoded] <- String.split(value, " ", parts: 2),
         "basic" <- String.downcase(scheme),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)) do
      {scheme, decoded}
    else
      _ -> nil
    end
  end
end
