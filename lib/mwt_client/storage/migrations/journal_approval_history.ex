defmodule MWTClient.Storage.Migrations.JournalApprovalHistory do
  @moduledoc "The recent decisions shown in the sandbox's Approvals page."

  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE events_approvals (
        seq INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        at INTEGER NOT NULL,
        approval BLOB NOT NULL
      ) STRICT
      """,
      "DROP TABLE events_approvals"
    )
  end
end
