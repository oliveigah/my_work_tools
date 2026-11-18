defmodule MWTClient.Storage.Backups do
  @moduledoc """
  Copies of an identity's databases, made on demand from the Storage
  page, in `backups/<time>/` of its folder: `library.db` and `journal.db`
  as `VACUUM INTO` writes them, compact and encrypted with the same keys,
  and the `vault.json` whose password opens them. The `backups` retention
  rule keeps the newest few (`MWTClient.Storage.Retention`).

  A copy is written aside and moved into place, so a backup cut short
  never looks like one.
  """

  alias MWTClient.Accounts
  alias MWTClient.Storage
  alias MWTClient.Storage.Database
  alias MWTClient.Storage.Retention
  alias MWTClient.Storage.Usage

  @type backup :: %{name: String.t(), at: DateTime.t(), bytes: non_neg_integer()}

  @doc "Where an identity's backups are."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Accounts.store_path(username, "backups")

  @doc "The backups there are, the newest first."
  @spec list(String.t()) :: [backup()]
  def list(username) do
    case File.ls(dir(username)) do
      {:ok, names} ->
        for name <- names,
            {:ok, at} <- [at(name)],
            do: %{name: name, at: at, bytes: Usage.folder_bytes(Path.join(dir(username), name))}

      {:error, _reason} ->
        []
    end
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  @doc """
  Backs both databases up now, then keeps as many backups as the rule
  says. Returns the new one.
  """
  @spec create(String.t(), DateTime.t()) :: {:ok, backup()} | {:error, String.t()}
  def create(username, now \\ DateTime.utc_now()) do
    name = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    final = Path.join(dir(username), name)
    partial = final <> ".part"
    File.rm_rf!(partial)
    File.mkdir_p!(partial)

    try do
      for database <- Database.names() do
        into = Path.join(partial, Path.basename(Database.path(username, database)))
        quoted = "'" <> String.replace(into, "'", "''") <> "'"
        Storage.run(username, database, & &1.query!("VACUUM INTO #{quoted}"))
      end

      File.cp!(Accounts.store_path(username, "vault.json"), Path.join(partial, "vault.json"))
      File.rm_rf!(final)
      File.rename!(partial, final)
      trim(username, Retention.rule(username, "backups"))
      {:ok, %{name: name, at: DateTime.truncate(now, :second), bytes: Usage.folder_bytes(final)}}
    rescue
      error ->
        File.rm_rf(partial)
        {:error, Exception.message(error)}
    end
  end

  @doc "Keeps the newest `:count` backups (`nil` keeps them all). Returns how many went."
  @spec trim(String.t(), map()) :: non_neg_integer()
  def trim(_username, %{count: nil}), do: 0

  def trim(username, %{count: count}) do
    gone = username |> list() |> Enum.drop(count)
    for backup <- gone, do: File.rm_rf!(Path.join(dir(username), backup.name))
    length(gone)
  end

  @doc "Deletes every backup."
  @spec delete_all(String.t()) :: :ok
  def delete_all(username) do
    File.rm_rf!(dir(username))
    :ok
  end

  defp at(
         <<y::binary-4, m::binary-2, d::binary-2, "T", hh::binary-2, mm::binary-2, ss::binary-2,
           "Z">>
       ) do
    case DateTime.from_iso8601("#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}Z") do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp at(_name), do: :error
end
