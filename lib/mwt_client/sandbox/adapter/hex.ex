defmodule MWTClient.Sandbox.Adapter.Hex do
  @moduledoc """
  Hex's API keys (`MWTClient.Sandbox.Adapter`): `mix hex` sends the key as
  the whole `Authorization` value, with no scheme. Its values are read as
  any bearer token's (`MWTClient.Sandbox.Adapter.Bearer`); it is an adapter
  of its own so a Hex credential is offered Hex's grant presets, not every
  token's.
  """

  @behaviour MWTClient.Sandbox.Adapter

  alias MWTClient.Sandbox.Adapter.Bearer

  @impl true
  def id, do: :hex

  @impl true
  def name, do: "Hex"

  @impl true
  def read_mint(output, now), do: Bearer.read_mint(output, now)

  @impl true
  def implied_hosts(_credential), do: []

  @impl true
  def env(_credential), do: []

  @impl true
  def attributes(_request), do: %{}
end
