defmodule MWTClient.Storage.Migrations.JournalEvents do
  @moduledoc """
  `journal.db`, version 2: agent activity, one row per event, as
  `MWTClient.Storage.Journal` writes them.

  `seq` is the order they were recorded in, which the activity log reads
  them by; `id` is the event's own, which a page holds to ask for what
  came before it. `at` is microseconds since 1970, UTC. `outcome` is what
  happened (`MWTClient.Sandbox.Event`), and the rest what MWT knew of it:
  the grant, where it went, how much it carried, how long it took, and
  the agent and thread that asked, as they claimed, when it came from one.
  `search_text` is what the log's word filter looks in, lowercased by the
  app.

  Indexed for the questions the log asks: by time, by outcome, by thread
  and by grant, each newest first.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE events (
      seq INTEGER PRIMARY KEY,
      id TEXT NOT NULL UNIQUE,
      at INTEGER NOT NULL,
      outcome TEXT NOT NULL,
      summary TEXT NOT NULL,
      grant_id TEXT,
      host TEXT,
      port INTEGER,
      method TEXT,
      path TEXT,
      up INTEGER,
      down INTEGER,
      ms INTEGER,
      agent TEXT,
      thread_id TEXT,
      thread TEXT,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX events_at ON events (at)")
    execute("CREATE INDEX events_outcome ON events (outcome, seq)")
    execute("CREATE INDEX events_thread ON events (thread_id, seq) WHERE thread_id IS NOT NULL")
    execute("CREATE INDEX events_grant ON events (grant_id, seq) WHERE grant_id IS NOT NULL")
  end

  def down do
    execute("DROP TABLE events")
  end
end
