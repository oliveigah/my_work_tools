defmodule MWTClient.Storage.Migrations.LibrarySlotSummaries do
  @moduledoc "Structured entries in the active timelines of worktree slots."

  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE slot_summary_entries (
        id INTEGER PRIMARY KEY,
        project TEXT NOT NULL,
        task TEXT NOT NULL,
        handoff_group INTEGER NOT NULL,
        at INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('status', 'prompt')),
        title TEXT NOT NULL,
        detail TEXT NOT NULL
      ) STRICT
      """,
      "DROP TABLE slot_summary_entries"
    )

    create(index(:slot_summary_entries, [:project, :task, :handoff_group, :id]))
  end
end
