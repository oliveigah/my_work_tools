defmodule MWTClient.ToolCallers do
  @moduledoc """
  Callers of MWT's tools (`MWTClient.MCP.Tools`) for tests of the tools
  themselves, not of the grants that decide them
  (`MWTClient.Sandbox.MwtTools`): every call goes ahead.
  """

  alias MWTClient.MCP.Caller

  @base_url "http://127.0.0.1:12995"

  @doc "Where the items the tools return open, in these tests."
  def base_url, do: @base_url

  @doc "An agent in the VM whose grants allow every call, with what it claims."
  @spec allowed(String.t(), map()) :: Caller.t()
  def allowed(username, claims \\ %{}),
    do: %Caller{username: username, base_url: @base_url, gate: fn _use -> :ok end, claims: claims}
end
