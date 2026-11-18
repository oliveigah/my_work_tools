defmodule MWTClient.Git.Snapshot do
  @moduledoc "The repository state needed to populate the branch list and commit graph."

  alias MWTClient.Git.Branch
  alias MWTClient.Git.Commit
  alias MWTClient.Git.Operation
  alias MWTClient.Git.Repository
  alias MWTClient.Git.Tag

  @enforce_keys [:repository, :detached?, :branches, :commits]
  defstruct [
    :repository,
    :head,
    :current_branch,
    :operation,
    detached?: false,
    branches: [],
    tags: [],
    commits: []
  ]

  @type t :: %__MODULE__{
          repository: Repository.t(),
          head: String.t() | nil,
          current_branch: String.t() | nil,
          operation: Operation.t() | nil,
          detached?: boolean(),
          branches: [Branch.t()],
          tags: [Tag.t()],
          commits: [Commit.t()]
        }
end
