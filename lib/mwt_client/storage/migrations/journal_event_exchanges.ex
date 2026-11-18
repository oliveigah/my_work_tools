defmodule MWTClient.Storage.Migrations.JournalEventExchanges do
  @moduledoc """
  `journal.db`, version 3: what a request MWT read carried, and what came
  back to the VM (`MWTClient.Sandbox.Exchange`), kept with the request's
  events (docs/storage.md).

  An event of such a request names its exchange (`events.exchange_id`);
  `events_exchanges` holds the exchange once per event that names it, as a
  compressed term (`MWTClient.Storage.Values.term/1`): the request's head
  and the start of its body, the response's head and the start of its
  body. Read only when an event is opened. A trigger removes it with its
  event, so retention, clearing and the size the activity takes cover it
  too (its name starts with `events`).
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE events ADD COLUMN exchange_id TEXT")

    execute("CREATE INDEX events_exchange ON events (exchange_id) WHERE exchange_id IS NOT NULL")

    execute("""
    CREATE TABLE events_exchanges (
      event_id TEXT PRIMARY KEY,
      exchange BLOB NOT NULL
    ) STRICT, WITHOUT ROWID
    """)

    execute("""
    CREATE TRIGGER events_exchange_gone AFTER DELETE ON events
    WHEN old.exchange_id IS NOT NULL
    BEGIN
      DELETE FROM events_exchanges WHERE event_id = old.id;
    END
    """)
  end

  def down do
    execute("DROP TRIGGER events_exchange_gone")
    execute("DROP TABLE events_exchanges")
    execute("DROP INDEX events_exchange")
    execute("ALTER TABLE events DROP COLUMN exchange_id")
  end
end
