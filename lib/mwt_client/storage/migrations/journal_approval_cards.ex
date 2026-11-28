defmodule MWTClient.Storage.Migrations.JournalApprovalCards do
  @moduledoc "The cards that can be reopened from the sandbox's decision history."

  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE events_approvals ADD COLUMN card BLOB",
      "ALTER TABLE events_approvals DROP COLUMN card"
    )
  end
end
