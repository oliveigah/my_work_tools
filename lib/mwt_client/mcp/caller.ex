defmodule MWTClient.MCP.Caller do
  @moduledoc """
  Who calls MWT's tools: an agent in the VM, through `mwt mcp` on the
  agent channel (`MWTClient.Sandbox.Channel`). It holds no token: being in
  the VM is all its call proves, and `gate` decides each call by the
  grants (`MWTClient.Sandbox.MwtTools`).

  `claims` are what the agent says about itself (`agent`, `thread`,
  `thread_id`, `folder`): labels for versions and approval cards, never
  taken as facts. `base_url` opens items in MWT on this machine.
  """

  @enforce_keys [:username, :base_url, :gate]
  defstruct [:username, :base_url, :gate, claims: %{}]

  @typedoc """
  What a tool call asks: which grant it uses (`:read`, `:create` or
  `:change`), the `tool`, and for a change the item it changes and how
  (`MWTClient.Sandbox.MwtTools`).
  """
  @type use :: map()

  @type t :: %__MODULE__{
          username: String.t(),
          base_url: String.t(),
          gate: (use() -> :ok | {:error, String.t()}),
          claims: %{optional(atom()) => String.t() | nil}
        }

  @doc "Who made a change, as its version says (`t:MWTClient.Versions.by/0`)."
  @spec by(t()) :: MWTClient.Versions.by()
  def by(%__MODULE__{claims: claims}),
    do: {:agent, :vm, %{agent: claims[:agent], thread: claims[:thread]}}
end
