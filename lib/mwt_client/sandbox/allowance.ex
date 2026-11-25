defmodule MWTClient.Sandbox.Allowance do
  @moduledoc """
  A standing yes on one grant: uses it covers go through without asking,
  until `until`, or until the grant turns off when `until` is nil.

  `pattern` is what it covers:

    * `:all` - every use of the grant;
    * a string - uses like one you approved: the same method and endpoint
      (`MWTClient.Sandbox.Describe`), or the same address and port for a
      connection. A `*` in its path stands for any one segment: *Allow
      similar, any id* widens the endpoint's ids (`widen/1`), so one
      allowance covers a REST resource whatever its ids.

  `origin` is where it came from, for the activity log's audit
  (`MWTClient.Sandbox.Decision`): `%{kind: :auto}`, you turned the grant on
  with Auto-approve or set it so; `:start`, its start setting as MWT
  started; `:card`, your choice on the card `card`; `:you`, every use
  allowed from the grant's page; `:mwt`, a rule of MWT's own. `at` is
  when. Nil for one from before origins were kept.
  """

  @enforce_keys [:id, :pattern]
  defstruct [:id, :pattern, :until, :origin]

  @type origin :: %{
          required(:kind) => :auto | :start | :card | :you | :mwt,
          optional(:card) => String.t() | nil,
          optional(:at) => DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          pattern: String.t() | :all,
          until: DateTime.t() | nil,
          origin: origin() | nil
        }

  @doc """
  Whether this allowance covers a use with this pattern at `now`. One past
  its `until` covers nothing: the clock decides, not a timer, so an
  allowance also ends across a restart or a suspend.
  """
  @spec covers?(t(), String.t(), DateTime.t()) :: boolean()
  def covers?(%__MODULE__{} = allowance, pattern, now \\ DateTime.utc_now()) do
    not ended?(allowance, now) and
      (allowance.pattern in [:all, pattern] or wild_covers?(allowance.pattern, pattern))
  end

  @doc """
  A request's pattern with each segment of its path that looks like an id
  (digits, a UUID, long hex, a long token) as `*`, or nil when none does.

      iex> MWTClient.Sandbox.Allowance.widen("GET api.github.com/repos/o/r/pulls/3 · in authorization")
      "GET api.github.com/repos/o/r/pulls/* · in authorization"
      iex> MWTClient.Sandbox.Allowance.widen("GET api.github.com/user")
      nil
  """
  @spec widen(String.t() | nil) :: String.t() | nil
  def widen(pattern) when is_binary(pattern) do
    with [head | rest] <- String.split(pattern, " · "),
         [method, target] <- String.split(head, " ", parts: 2),
         [host | segments] <- String.split(target, "/") do
      widened = Enum.map(segments, &if(id?(&1), do: "*", else: &1))

      if widened != segments,
        do: Enum.join(["#{method} #{Enum.join([host | widened], "/")}" | rest], " · ")
    else
      _ -> nil
    end
  end

  def widen(_pattern), do: nil

  defp id?(segment) do
    Regex.match?(~r/\A\d+\z/, segment) or
      Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, segment) or
      Regex.match?(~r/\A[0-9a-f]{12,}\z/i, segment) or
      (Regex.match?(~r/\A[A-Za-z0-9_-]{20,}\z/, segment) and Regex.match?(~r/\d/, segment))
  end

  # A pattern with `*` segments covers one whose every other part is the
  # same, and whose path has a segment where each `*` is.
  defp wild_covers?(wild, pattern) when is_binary(wild) and is_binary(pattern) do
    String.contains?(wild, "*") and
      case {String.split(wild, " · "), String.split(pattern, " · ")} do
        {[w | w_rest], [p | p_rest]} when w_rest == p_rest ->
          w_parts = String.split(w, "/")
          p_parts = String.split(p, "/")

          length(w_parts) == length(p_parts) and
            Enum.all?(Enum.zip(w_parts, p_parts), fn {a, b} -> a == "*" or a == b end)

        _ ->
          false
      end
  end

  defp wild_covers?(_wild, _pattern), do: false

  @doc "Whether the allowance's time has run out at `now`."
  @spec ended?(t(), DateTime.t()) :: boolean()
  def ended?(allowance, now \\ DateTime.utc_now())
  def ended?(%__MODULE__{until: nil}, _now), do: false
  def ended?(%__MODULE__{until: until}, now), do: DateTime.compare(now, until) != :lt

  @doc false
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))
end
