defmodule MWTClient.Storage.Migrations.JournalEventDetails do
  @moduledoc """
  `journal.db`, version 4: what an event says when its line opens
  (`MWTClient.Sandbox.EventDetails`), kept with it (docs/storage.md).

  `events.detailed` is 1 for an event that has details, so a page knows to
  read them when the line opens; events from before have none, and 0.
  `events_details` holds them once per event, as a compressed term
  (`MWTClient.Storage.Values.term/1`), at most 16 KiB of words before
  compression. Read only when an event is opened. A trigger removes them
  with their event, so retention, clearing and the size the activity takes
  cover them too (the table's name starts with `events`).
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE events ADD COLUMN detailed INTEGER NOT NULL DEFAULT 0")

    execute("""
    CREATE TABLE events_details (
      event_id TEXT PRIMARY KEY,
      details BLOB NOT NULL
    ) STRICT, WITHOUT ROWID
    """)

    execute("""
    CREATE TRIGGER events_details_gone AFTER DELETE ON events
    WHEN old.detailed = 1
    BEGIN
      DELETE FROM events_details WHERE event_id = old.id;
    END
    """)
  end

  def down do
    execute("DROP TRIGGER events_details_gone")
    execute("DROP TABLE events_details")
    execute("ALTER TABLE events DROP COLUMN detailed")
  end
end
