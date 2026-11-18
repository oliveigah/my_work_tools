defmodule MWTClient.Storage.Migrations.LibraryItems do
  @moduledoc """
  `library.db`, version 1: notes, diagrams, flash cards, their versions,
  and the small documents kept whole (docs/storage.md).

  Every item has an `id`, the one MWT has always given it, and a `seq`,
  the row's own number, which the search index points at. Times are
  microseconds since 1970, UTC (`MWTClient.Storage.Values`).

  Notes and diagrams keep what a list shows apart from what only an open
  item needs, so a list reads a few hundred bytes an item, never a body
  or the elements. A card is small enough to keep in one row.

  Each kind's search index is an FTS5 table using the trigram tokenizer
  over the item's `search_text`, which the app already normalizes, so the
  index folds nothing itself (`case_sensitive 1`). Triggers keep it in
  step with the rows, in the transaction that writes them.
  """

  use Ecto.Migration

  @searchable [
    note_texts: :note_search,
    diagram_contents: :diagram_search,
    flashcards: :flashcard_search
  ]

  def up do
    execute("""
    CREATE TABLE notes (
      seq INTEGER PRIMARY KEY,
      id TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      excerpt TEXT,
      done_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      version INTEGER NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX notes_updated_at ON notes (updated_at)")

    execute("""
    CREATE TABLE note_texts (
      seq INTEGER PRIMARY KEY REFERENCES notes (seq) ON DELETE CASCADE,
      body TEXT NOT NULL,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    execute("""
    CREATE TABLE diagrams (
      seq INTEGER PRIMARY KEY,
      id TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      element_count INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      version INTEGER NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX diagrams_updated_at ON diagrams (updated_at)")

    # The elements are one term per diagram, as the editor sends them.
    execute("""
    CREATE TABLE diagram_contents (
      seq INTEGER PRIMARY KEY REFERENCES diagrams (seq) ON DELETE CASCADE,
      elements BLOB NOT NULL,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    # Tags are a JSON array, the spelling as written.
    execute("""
    CREATE TABLE flashcards (
      seq INTEGER PRIMARY KEY,
      id TEXT NOT NULL UNIQUE,
      front TEXT NOT NULL,
      tags TEXT NOT NULL,
      source TEXT,
      box INTEGER NOT NULL,
      due_at INTEGER NOT NULL,
      reviewed_at INTEGER,
      reviews INTEGER NOT NULL,
      lapses INTEGER NOT NULL,
      removed_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      version INTEGER NOT NULL,
      back TEXT NOT NULL,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX flashcards_created_at ON flashcards (created_at)")

    for {table, index} <- @searchable, do: search_index(table, index)

    # `content` is the item's content term, compressed; `content_hash`
    # tells one version from the next without reading it.
    execute("""
    CREATE TABLE versions (
      seq INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      item_id TEXT NOT NULL,
      version INTEGER NOT NULL,
      content BLOB NOT NULL,
      content_hash BLOB NOT NULL,
      saved_at INTEGER NOT NULL,
      replaced_at INTEGER NOT NULL,
      replaced_by BLOB NOT NULL,
      how TEXT NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX versions_item ON versions (kind, item_id, seq)")
    execute("CREATE INDEX versions_replaced_at ON versions (kind, replaced_at)")

    execute("""
    CREATE TABLE documents (
      name TEXT PRIMARY KEY,
      term BLOB NOT NULL,
      updated_at INTEGER NOT NULL
    ) STRICT
    """)
  end

  def down do
    for {_table, index} <- @searchable, do: execute("DROP TABLE #{index}")

    for table <- ~w(documents versions flashcards diagram_contents diagrams note_texts notes),
        do: execute("DROP TABLE #{table}")
  end

  # An external-content index: the text stays in `table` only, and the
  # triggers hand the index what a row held before a change, as FTS5 needs
  # to take it out.
  defp search_index(table, index) do
    execute("""
    CREATE VIRTUAL TABLE #{index} USING fts5(
      search_text,
      content = '#{table}',
      content_rowid = 'seq',
      tokenize = 'trigram case_sensitive 1'
    )
    """)

    execute("""
    CREATE TRIGGER #{table}_search_insert AFTER INSERT ON #{table} BEGIN
      INSERT INTO #{index} (rowid, search_text) VALUES (new.seq, new.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER #{table}_search_delete AFTER DELETE ON #{table} BEGIN
      INSERT INTO #{index} (#{index}, rowid, search_text)
      VALUES ('delete', old.seq, old.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER #{table}_search_update AFTER UPDATE OF search_text ON #{table}
    WHEN old.search_text IS NOT new.search_text BEGIN
      INSERT INTO #{index} (#{index}, rowid, search_text)
      VALUES ('delete', old.seq, old.search_text);
      INSERT INTO #{index} (rowid, search_text) VALUES (new.seq, new.search_text);
    END
    """)
  end
end
