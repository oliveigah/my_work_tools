defmodule MWTClient.Sandbox.Check do
  @moduledoc """
  A check of a grant: a script of yours, run on this machine, whose exit 0
  says the grant still holds. MWT can't know what a credential can do, or
  whether what a grant depends on is there; you do, once, when you set it
  up, and a check says it again.

  One mechanism, two uses: a precondition ("the VPN is up") and a fence
  ("this value still can't do X").

    * `name` is what the agent hears when it fails, so you write it as the
      message: "the VPN is up";
    * `on`, when it runs: `:enable`, before the grant turns on (or as MWT
      starts it), `:daily`, once a day while it is on;
      and whenever you ask;
    * `gates`: a failing one keeps the grant off, and turns
      it off if it was on. One that doesn't gate only tells you.

  It runs confined (`MWTClient.Sandbox.Confine`), with the grant's own real
  value when the grant is a token grant. Its output is for you only.

  Pure: `failing/3` says which grants a gating check holds off, from the
  last results (`t:result/0`), which the server keeps
  (`MWTClient.Sandbox.Server.Checks`).
  """

  alias MWTClient.Sandbox.Shown

  @enforce_keys [:id, :name, :script]
  defstruct [:id, :name, :script, on: [:enable, :daily], gates: true]

  @type when_ :: :enable | :daily
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          script: String.t(),
          on: [when_()],
          gates: boolean()
        }

  @typedoc "How a check went the last time it ran."
  @type result :: %{
          at: DateTime.t(),
          ok?: boolean(),
          exit: integer() | nil,
          output: String.t()
        }

  @max_script 4 * 1024
  @max_name 120
  @fresh_seconds 25 * 60 * 60

  @doc """
  A check from a form's fields, or what is wrong with it.

      iex> {:ok, check} = MWTClient.Sandbox.Check.new(%{"name" => "the VPN is up", "script" => "ping -c1 -W2 10.0.0.1"}, "c1")
      iex> {check.name, check.on, check.gates}
      {"the VPN is up", [:enable, :daily], true}
      iex> MWTClient.Sandbox.Check.new(%{"name" => "", "script" => "true"}, "c2")
      {:error, "Name it as the message an agent reads when it fails: \\"the VPN is up\\"."}
  """
  @spec new(map(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs, id) do
    name = attrs |> Map.get("name") |> to_string() |> Shown.text() |> String.trim()

    script =
      attrs |> Map.get("script") |> to_string() |> String.replace("\r\n", "\n") |> String.trim()

    on =
      for {key, at} <- [{"enable", :enable}, {"daily", :daily}],
          Map.get(attrs, key, "true") in ["true", "on", true],
          do: at

    cond do
      name == "" ->
        {:error, "Name it as the message an agent reads when it fails: \"the VPN is up\"."}

      String.length(name) > @max_name ->
        {:error, "Keep the name under #{@max_name} characters."}

      script == "" ->
        {:error, "Write the script: exit 0 means the grant still holds."}

      byte_size(script) > @max_script ->
        {:error, "The script is over #{div(@max_script, 1024)} KiB."}

      Shown.hidden(script) != [] ->
        {:error, "The script has characters that don't show. Paste it without them."}

      on == [] ->
        {:error, "Say when it runs: before the grant turns on, once a day, or both."}

      true ->
        {:ok,
         %__MODULE__{
           id: id,
           name: name,
           script: script,
           on: on,
           gates: Map.get(attrs, "gates", "true") in ["true", "on", true]
         }}
    end
  end

  @doc """
  The grants a gating check holds off at `now`, each with why, in the
  words the agent hears: one that never ran, failed last, or, running
  daily, hasn't run in over a day. `results` is keyed by `{grant_id,
  check_id}`.

      iex> alias MWTClient.Sandbox.{Check, Grant}
      iex> check = %Check{id: "c", name: "the VPN is up", script: "true"}
      iex> grant = %Grant{id: "lan", name: "LAN", kind: :network, checks: [check]}
      iex> now = ~U[2026-11-17 12:00:00Z]
      iex> Check.failing([grant], %{}, now)
      %{"lan" => "the VPN is up (not checked yet)"}
      iex> Check.failing([grant], %{{"lan", "c"} => %{at: now, ok?: false, exit: 1, output: ""}}, now)
      %{"lan" => "the VPN is up"}
      iex> Check.failing([grant], %{{"lan", "c"} => %{at: now, ok?: true, exit: 0, output: ""}}, now)
      %{}
  """
  @spec failing([MWTClient.Sandbox.Grant.t()], map(), DateTime.t()) :: %{String.t() => String.t()}
  def failing(grants, results, now) do
    for grant <- grants,
        why = Enum.find_value(grant.checks, &holds_off(&1, results[{grant.id, &1.id}], now)),
        why != nil,
        into: %{},
        do: {grant.id, why}
  end

  defp holds_off(%__MODULE__{gates: false}, _result, _now), do: nil
  defp holds_off(%__MODULE__{name: name}, nil, _now), do: "#{name} (not checked yet)"
  defp holds_off(%__MODULE__{name: name}, %{ok?: false}, _now), do: name

  defp holds_off(%__MODULE__{name: name, on: on}, %{at: at}, now) do
    if :daily in on and DateTime.diff(now, at) > @fresh_seconds,
      do: "#{name} (not checked for over a day)",
      else: nil
  end

  @doc "Whether a check that runs daily is due at `now`: it last ran over a day ago, or never."
  @spec due?(t(), result() | nil, DateTime.t()) :: boolean()
  def due?(%__MODULE__{on: on}, result, now) do
    :daily in on and (is_nil(result) or DateTime.diff(now, result.at) >= 24 * 60 * 60)
  end

  @doc false
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))
end
