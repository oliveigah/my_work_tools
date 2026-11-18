defmodule MWTClient.Storage.Documents do
  @moduledoc """
  Small state an app keeps whole, as one term under a name, in the
  `documents` table of `library.db` (docs/storage.md): the sandbox's
  grants, projects and handoffs, MCP access, agent threads, the flash
  cards' settings. Each is read whole when its app starts and written
  whole after a change, as it was in a sealed file of its own.

  `load/5` also brings in the file the document was kept in before
  `library.db`, once.

  A write that fails (a full disk) comes back as an error, for the app to
  report as it reported a file it couldn't write. Inside a transaction
  (`MWTClient.Storage.transaction/3`) both are part of it.
  """

  alias MWTClient.Storage
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Values

  @doc "The document `name` of `username`, if there is one."
  @spec get(String.t(), String.t()) :: {:ok, term()} | :none
  def get(username, name) do
    Storage.run(username, :library, fn repo ->
      repo.query!("SELECT term FROM documents WHERE name = ?", [name]).rows
    end)
    |> case do
      [[term]] -> {:ok, Values.from_term(term)}
      [] -> :none
    end
  end

  @doc "Keeps `term` as the document `name` of `username`, in place of what was."
  @spec put(String.t(), String.t(), term()) :: :ok | {:error, Exception.t()}
  def put(username, name, term) do
    blob = Values.term(term)

    writing(fn ->
      Storage.run(username, :library, fn repo ->
        repo.query!(
          """
          INSERT INTO documents (name, term, updated_at) VALUES (?, ?, ?)
          ON CONFLICT (name) DO UPDATE SET term = excluded.term, updated_at = excluded.updated_at
          """,
          [name, blob, Values.time(DateTime.utc_now())]
        )
      end)
    end)
  end

  @doc "Forgets the document `name` of `username`; one that isn't there is fine."
  @spec delete(String.t(), String.t()) :: :ok | {:error, Exception.t()}
  def delete(username, name) do
    writing(fn ->
      Storage.run(username, :library, & &1.query!("DELETE FROM documents WHERE name = ?", [name]))
    end)
  end

  @doc """
  The document `name` of `username`, for an app starting: `get/2`, or,
  the first time, what `file` held, sealed with the password's `key`
  before `library.db`. That is written as the document, and the file
  moves into `legacy/` (`MWTClient.Storage.Legacy`).

  A file found beside a document is one whose move never finished, or one
  put back by hand: it is the newer of the two, and replaces the document.
  `:none` when there is neither, or the file can't be read; it is then set
  aside as `<file>.<time>.corrupt`.
  """
  @spec load(String.t(), String.t(), String.t(), MWTClient.Vault.key(), atom()) ::
          {:ok, term()} | :none
  def load(username, name, file, key, system) do
    case Legacy.read(username, file, key, system) do
      {:ok, term} ->
        :ok = put(username, name, term)
        Legacy.retire(username, file)
        {:ok, term}

      :none ->
        get(username, name)
    end
  end

  defp writing(fun) do
    fun.()
    :ok
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, error}
  end
end
