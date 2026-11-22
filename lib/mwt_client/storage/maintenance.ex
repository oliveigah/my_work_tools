defmodule MWTClient.Storage.Maintenance do
  @moduledoc """
  What the Storage page does to an identity's databases on demand:
  compact them, check them, and clear one kind of what they keep.
  Backups are `MWTClient.Storage.Backups`; the rules,
  `MWTClient.Storage.Retention`.
  """

  alias MWTClient.HttpClient.Resources
  alias MWTClient.Storage
  alias MWTClient.Storage.Backups
  alias MWTClient.Storage.Database
  alias MWTClient.Storage.Journal
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Usage

  @versions %{
    "note_versions" => "notes",
    "diagram_versions" => "diagrams",
    "flashcard_versions" => "flashcards"
  }

  @doc """
  Rewrites both databases without their free pages (`VACUUM`), giving the
  space back to the disk. Writes wait meanwhile. Returns each database's
  bytes before and after.

  The rewrite's temporary copy goes to a file, encrypted as the database
  is (SQLite3 Multiple Ciphers encrypts temporary files), not to memory:
  there, `VACUUM` held the whole database decrypted, 322 MB of memory for
  a 392 MB file, where a file kept it under 10 MB.
  """
  @spec compact(String.t()) :: %{Database.name() => {non_neg_integer(), non_neg_integer()}}
  def compact(username) do
    :ok = Journal.flush(username)

    Map.new(Database.names(), fn name ->
      before = Usage.file_bytes(username, name)

      Storage.run(username, name, fn repo ->
        # One connection for all three: the setting is the connection's.
        repo.checkout(fn ->
          repo.query!("PRAGMA temp_store = FILE")

          try do
            repo.query!("VACUUM")
          after
            repo.query!("PRAGMA temp_store = DEFAULT")
          end

          repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
        end)
      end)

      {name, {before, Usage.file_bytes(username, name)}}
    end)
  end

  @doc """
  Checks both databases (`PRAGMA quick_check`): `:ok`, or what SQLite
  found wrong, by database.
  """
  @spec check(String.t()) :: %{Database.name() => :ok | {:error, [String.t()]}}
  def check(username) do
    Map.new(Database.names(), fn name ->
      rows = Storage.run(username, name, & &1.query!("PRAGMA quick_check").rows)

      case List.flatten(rows) do
        ["ok"] -> {name, :ok}
        problems -> {name, {:error, problems}}
      end
    end)
  end

  @doc "The kinds `clear/2` clears: every kind with a rule but the VM's."
  @spec clearable() :: [String.t()]
  def clearable,
    do: ~w(note_versions diagram_versions flashcard_versions http_history http_bodies
           agent_activity backups legacy)

  @doc """
  Removes everything of one kind (`clearable/0`), as its rule would if it
  kept nothing. Notes, diagrams, cards and HTTP samples stay, as always.
  """
  @spec clear(String.t(), String.t()) :: :ok
  def clear(username, key) when is_map_key(@versions, key) do
    Storage.run(username, :library, fn repo ->
      repo.query!("DELETE FROM versions WHERE kind = ?", [Map.fetch!(@versions, key)])
    end)

    :ok
  end

  def clear(username, "http_history") do
    _removed = Resources.trim(username, %{days: 0, gb: nil}, later())
    :ok
  end

  def clear(username, "http_bodies") do
    _removed = Resources.drop_bodies(username, %{days: 0}, later())
    :ok
  end

  def clear(username, "agent_activity") do
    :ok = Journal.flush(username)
    Storage.run(username, :journal, & &1.query!("DELETE FROM events_exchanges"))
    Storage.run(username, :journal, & &1.query!("DELETE FROM events_details"))
    Storage.run(username, :journal, & &1.query!("DELETE FROM events"))
    :ok
  end

  def clear(username, "backups"), do: Backups.delete_all(username)
  def clear(username, "legacy"), do: Legacy.delete_all(username)

  # Past everything kept, to the second.
  defp later, do: DateTime.add(DateTime.utc_now(), 1, :second)
end
