defmodule MWTClient.Storage.Migrations.JournalDecisions do
  @moduledoc """
  `journal.db`, version 5: who or what decided each action
  (`MWTClient.Sandbox.Decision`), for the activity log's audit.

    * `events.decided_by` - `you`, `allowance`, `grant`, `refused` or
      `timeout`, or NULL for a line that isn't an action's decision; what
      the activity log's *Decided by* filters on;
    * `events.decision` - the whole decision, a compressed term
      (`MWTClient.Storage.Values.term/1`): whether it went through, the
      grant and the state it was in, the allowance and where it came from,
      the card, why it was refused;
    * `events.card_id` - the card it traces back to;
    * `events_cards` - each card you decided, or that timed out, kept whole
      with what was chosen on it, read-only.

  A card goes when no line names it any more
  (`MWTClient.Storage.Journal.trim/3`), and with a Clear; its table's name
  starts with `events`, so the size the activity takes counts it.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE events ADD COLUMN decided_by TEXT")
    execute("ALTER TABLE events ADD COLUMN decision BLOB")
    execute("ALTER TABLE events ADD COLUMN card_id TEXT")
    execute("CREATE INDEX events_card_id ON events (card_id) WHERE card_id IS NOT NULL")

    execute("""
    CREATE TABLE events_cards (
      id TEXT PRIMARY KEY,
      at INTEGER NOT NULL,
      card BLOB NOT NULL
    ) STRICT, WITHOUT ROWID
    """)
  end

  def down do
    execute("DROP TABLE events_cards")
    execute("DROP INDEX events_card_id")
    execute("ALTER TABLE events DROP COLUMN card_id")
    execute("ALTER TABLE events DROP COLUMN decision")
    execute("ALTER TABLE events DROP COLUMN decided_by")
  end
end
