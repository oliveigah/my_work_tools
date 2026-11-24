defmodule MWTClient.Sandbox.Adapter.Bearer do
  @moduledoc """
  Any token in `Authorization`, or in headers you name, Basic credentials
  included: Hex, a datalake's token, anything simple
  (`MWTClient.Sandbox.Adapter`). A mint prints the bare value, kept 10
  minutes, or MWT's JSON: `value`, `id_token`, `expires_in` seconds.
  """

  @behaviour MWTClient.Sandbox.Adapter

  @mint_fresh_ms 10 * 60 * 1000

  @impl true
  def id, do: :bearer

  @impl true
  def name, do: "Bearer token"

  @impl true
  def read_mint("", _now), do: {:error, "the command printed nothing"}

  def read_mint("{" <> _ = output, _now) do
    case Jason.decode(output) do
      {:ok, %{"value" => value} = object} when is_binary(value) and value != "" ->
        {:ok, %{value: value, id_token: text_or_nil(object["id_token"])},
         fresh(object["expires_in"])}

      {:ok, %{}} ->
        {:error, "the command printed JSON with no \"value\""}

      _not_json ->
        {:ok, %{value: output, id_token: nil}, @mint_fresh_ms}
    end
  end

  def read_mint(token, _now), do: {:ok, %{value: token, id_token: nil}, @mint_fresh_ms}

  @impl true
  def implied_hosts(_credential), do: []

  @impl true
  def env(_credential), do: []

  @impl true
  def attributes(_request), do: %{}

  @doc """
  How long a value that says it lasts `seconds` stays fresh: until a minute
  before it ends, or 10 minutes when it says nothing.
  """
  @spec fresh(term()) :: non_neg_integer()
  def fresh(seconds) when is_integer(seconds) and seconds > 60, do: (seconds - 60) * 1000
  def fresh(seconds) when is_integer(seconds), do: 0
  def fresh(_unknown), do: @mint_fresh_ms

  defp text_or_nil(text) when is_binary(text) and text != "", do: text
  defp text_or_nil(_other), do: nil
end
