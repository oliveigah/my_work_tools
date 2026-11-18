defmodule MWTClient.Sandbox.AgentThread do
  @moduledoc """
  One agent thread MWT has seen through `mwt-acp` (`MWTClient.Sandbox.AgentThreads`):
  a thread of an MWT agent in Zed's agent panel.

  `id` is the thread's ACP session id: Claude Code's session id or Codex's
  thread id, the id `mwt` sends from inside the thread. `open?` and
  `working?` are live; the rest is the record MWT keeps across restarts,
  `said` holding the last things MWT said in the thread, the oldest first.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :agent,
    :folder,
    :title,
    :opened_at,
    :last_active_at,
    open?: false,
    working?: false,
    said: []
  ]

  @type said :: %{at: DateTime.t(), from: String.t(), text: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          agent: String.t() | nil,
          folder: String.t() | nil,
          title: String.t() | nil,
          opened_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          open?: boolean(),
          working?: boolean(),
          said: [said()]
        }

  @doc "The agent's name as Zed lists it."
  @spec agent_name(t() | String.t() | nil) :: String.t()
  def agent_name(%__MODULE__{agent: agent}), do: agent_name(agent)
  def agent_name("claude-acp"), do: "Claude (MWT)"
  def agent_name("codex-acp"), do: "Codex (MWT)"
  def agent_name(nil), do: "An MWT agent"
  def agent_name(agent), do: agent

  @doc "Where the thread is, in a few words: open and working or idle, or closed."
  @spec state_words(t()) :: String.t()
  def state_words(%__MODULE__{open?: false}), do: "closed"
  def state_words(%__MODULE__{working?: true}), do: "open, working"
  def state_words(%__MODULE__{}), do: "open, idle"
end
