defmodule MWTClient.MCP.Caller do
  @moduledoc """
  Who calls MWT's tools, and how they reach them.

    * `from: :local` - an agent on this machine, through `/mcp` with the
      identity's token (`MWTClientWeb.Plugs.MCP`).
    * `from: :vm` - an agent in the VM, through `mwt mcp` on the agent
      channel (`MWTClient.Sandbox.Channel`). It holds no token: being in the
      VM is all its call proves, and `gate` decides each call by the
      grants (`MWTClient.Sandbox.MwtTools`).

  `claims` are what an agent in the VM says about itself (`agent`,
  `thread`, `thread_id`, `folder`): labels for versions and approval cards,
  never taken as facts. `base_url` opens items in MWT on this machine.
  """

  @enforce_keys [:username, :base_url, :from]
  defstruct [:username, :base_url, :from, :gate, claims: %{}]

  @typedoc """
  What a tool call from the VM asks: which grant it uses (`:read`,
  `:create` or `:change`), the `tool`, and for a change the item it
  changes and how (`MWTClient.Sandbox.MwtTools`).
  """
  @type use :: map()

  @type t :: %__MODULE__{
          username: String.t(),
          base_url: String.t(),
          from: :local | :vm,
          gate: (use() -> :ok | {:error, String.t()}) | nil,
          claims: %{optional(atom()) => String.t() | nil}
        }

  @doc "An agent on this machine, through `/mcp`."
  @spec local(String.t(), String.t()) :: t()
  def local(username, base_url),
    do: %__MODULE__{username: username, base_url: base_url, from: :local}

  @doc "Who made a change, as its version says (`t:MWTClient.Versions.by/0`)."
  @spec by(t()) :: MWTClient.Versions.by()
  def by(%__MODULE__{from: :local}), do: {:agent, :local}

  def by(%__MODULE__{from: :vm, claims: claims}),
    do: {:agent, :vm, %{agent: claims[:agent], thread: claims[:thread]}}
end
