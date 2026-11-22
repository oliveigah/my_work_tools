defmodule MWTClient.Storage.Migrations.LibraryHandoffs do
  @moduledoc """
  `library.db`, version 2: the agent sandbox's handoffs, every one ever
  handed off (`MWTClient.Sandbox.HandoffRecords`).

  They were part of the `sandbox` document, capped at the latest 100, so
  that writing the document after any change of the sandbox stayed cheap.
  Kept for good, they grow without end, so each is a row of its own,
  written alone when it changes.

  `handoffs` holds what the list picks rows and orders them by: whether it
  waits for you, when it changed last (handed off, landed, closed), its
  project and branch. `handoff_records` holds the handoff itself, a term,
  and its search text, indexed as the notes' are (`LibraryItems`):
  FTS5 with the trigram tokenizer over text the app normalizes.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE handoffs (
      seq INTEGER PRIMARY KEY,
      id INTEGER NOT NULL UNIQUE,
      project TEXT NOT NULL,
      branch TEXT NOT NULL,
      waiting INTEGER NOT NULL,
      opened_at INTEGER NOT NULL,
      changed_at INTEGER NOT NULL
    ) STRICT
    """)

    # A half of the list, newest first, and the archived line, by date.
    execute("CREATE INDEX handoffs_list ON handoffs (waiting, changed_at)")
    # The latest handoff of a branch, for the slot that holds it.
    execute("CREATE INDEX handoffs_branch ON handoffs (project, branch, id)")

    execute("""
    CREATE TABLE handoff_records (
      seq INTEGER PRIMARY KEY REFERENCES handoffs (seq) ON DELETE CASCADE,
      record BLOB NOT NULL,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    # As `LibraryItems` makes the notes' index, written out again here: a
    # migration, once shipped, must not change with code it borrows.
    execute("""
    CREATE VIRTUAL TABLE handoff_search USING fts5(
      search_text,
      content = 'handoff_records',
      content_rowid = 'seq',
      tokenize = 'trigram case_sensitive 1'
    )
    """)

    execute("""
    CREATE TRIGGER handoff_records_search_insert AFTER INSERT ON handoff_records BEGIN
      INSERT INTO handoff_search (rowid, search_text) VALUES (new.seq, new.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER handoff_records_search_delete AFTER DELETE ON handoff_records BEGIN
      INSERT INTO handoff_search (handoff_search, rowid, search_text)
      VALUES ('delete', old.seq, old.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER handoff_records_search_update AFTER UPDATE OF search_text ON handoff_records
    WHEN old.search_text IS NOT new.search_text BEGIN
      INSERT INTO handoff_search (handoff_search, rowid, search_text)
      VALUES ('delete', old.seq, old.search_text);
      INSERT INTO handoff_search (rowid, search_text) VALUES (new.seq, new.search_text);
    END
    """)
  end

  def down do
    for table <- ~w(handoff_search handoff_records handoffs), do: execute("DROP TABLE #{table}")
  end
end
