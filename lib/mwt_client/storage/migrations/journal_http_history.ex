defmodule MWTClient.Storage.Migrations.JournalHttpHistory do
  @moduledoc """
  `journal.db`, version 1: the HTTP client's history (docs/storage.md).

  Each entry is a row of each of three tables, sharing its `id`, the
  history id the client has always shown, given in order and never given
  twice (`AUTOINCREMENT`), even after the history is cleared:

    * `http_requests`, what a list shows: when, how long, the
      description and tags, the method and URL, the status (0 for a
      sample never sent, 599 for a request that failed) and the size of
      the response body;
    * `http_request_details`, what an open entry shows but its response
      body: the metadata, the request and the response's outline, as
      terms, and the search text;
    * `http_responses`, the whole response, as a term.

  So a list never reads a request or a response, and opening an entry
  reads its body only when asked to. The search index is an FTS5 table
  using the trigram tokenizer over the search text, which the client
  normalizes itself; triggers keep it in step with the details.

  This migration must not change once shipped, so its search index is
  made here, not by a helper another migration could change.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE http_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      completed_at INTEGER NOT NULL,
      duration_ms INTEGER,
      description TEXT,
      tags TEXT NOT NULL,
      method TEXT NOT NULL,
      url TEXT NOT NULL,
      status INTEGER NOT NULL,
      response_bytes INTEGER NOT NULL
    ) STRICT
    """)

    execute("CREATE INDEX http_requests_completed_at ON http_requests (completed_at)")

    execute("""
    CREATE TABLE http_request_details (
      id INTEGER PRIMARY KEY REFERENCES http_requests (id) ON DELETE CASCADE,
      metadata BLOB NOT NULL,
      request BLOB NOT NULL,
      outline BLOB NOT NULL,
      search_text TEXT NOT NULL
    ) STRICT
    """)

    execute("""
    CREATE TABLE http_responses (
      id INTEGER PRIMARY KEY REFERENCES http_requests (id) ON DELETE CASCADE,
      response BLOB NOT NULL
    ) STRICT
    """)

    execute("""
    CREATE VIRTUAL TABLE http_request_search USING fts5(
      search_text,
      content = 'http_request_details',
      content_rowid = 'id',
      tokenize = 'trigram case_sensitive 1'
    )
    """)

    execute("""
    CREATE TRIGGER http_request_details_search_insert AFTER INSERT ON http_request_details BEGIN
      INSERT INTO http_request_search (rowid, search_text) VALUES (new.id, new.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER http_request_details_search_delete AFTER DELETE ON http_request_details BEGIN
      INSERT INTO http_request_search (http_request_search, rowid, search_text)
      VALUES ('delete', old.id, old.search_text);
    END
    """)

    execute("""
    CREATE TRIGGER http_request_details_search_update AFTER UPDATE OF search_text
    ON http_request_details WHEN old.search_text IS NOT new.search_text BEGIN
      INSERT INTO http_request_search (http_request_search, rowid, search_text)
      VALUES ('delete', old.id, old.search_text);
      INSERT INTO http_request_search (rowid, search_text) VALUES (new.id, new.search_text);
    END
    """)
  end

  def down do
    execute("DROP TABLE http_request_search")

    for table <- ~w(http_responses http_request_details http_requests),
        do: execute("DROP TABLE #{table}")
  end
end
