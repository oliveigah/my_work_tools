defmodule MWTClient.Sandbox.Share do
  @moduledoc """
  A folder of yours that MWT offers the VM: the git working trees in it as
  projects, the rest copied into the VM at the same path
  (`MWTClient.Sandbox.FolderSync`). Nothing of it is mounted, and the VM
  never writes to it.
  """

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}

  @doc "A share as stored by an older MWT, which also had a mode, as one now."
  @spec upgrade(map()) :: t()
  def upgrade(%{path: path}), do: %__MODULE__{path: path}
end
