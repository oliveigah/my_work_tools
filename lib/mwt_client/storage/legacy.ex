defmodule MWTClient.Storage.Legacy do
  @moduledoc """
  The files an identity's data was kept in before its databases:
  `notes.bin` and the other sealed stores, and `versions/` (docs/storage.md).

  Each app imports its own the first time it starts with a build that keeps
  its data in a database: it reads the file with `read/4`, writes what it
  holds in one transaction, record by record (`each_record/3`: one that
  doesn't fit is kept aside, `keep_failed/5`, and never stops the unlock),
  and only then moves the file into `legacy/` with `retire/2`. A file still in place is one whose import never
  finished, so it is imported again at the next unlock, and each app's
  import keeps what its database holds already.
  """

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault

  @folder "legacy"
  @failures "storage.not_imported"

  @doc "Where an identity's retired files are kept."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Accounts.store_path(username, @folder)

  @doc """
  The term sealed in `file`, one of `username`'s files, opened with the
  password's `key`. `:none` when there is no such file. A file that won't
  open is set aside as `<file>.<time>.corrupt`, as the stores always did,
  and is `:none` too: the key was proven by the verifier, so it is
  damaged, not locked.
  """
  @spec read(String.t(), String.t(), Vault.key(), atom()) :: {:ok, term()} | :none
  def read(username, file, key, system) do
    path = Accounts.store_path(username, file)

    case File.read(path) do
      {:ok, blob} ->
        case Vault.open(key, blob) do
          {:ok, term} ->
            {:ok, term}

          :error ->
            set_aside(username, file, system)
            :none
        end

      {:error, _reason} ->
        :none
    end
  end

  @doc """
  Sets `file` aside as `<file>.<time>.corrupt`: one that won't decrypt,
  or holds what its app can't read. Timestamped, so a second failure can't
  overwrite what the first kept.
  """
  @spec set_aside(String.t(), String.t(), atom()) :: :ok
  def set_aside(username, file, system) do
    path = Accounts.store_path(username, file)
    corrupt = "#{path}.#{System.system_time(:second)}.corrupt"

    Logger.warning("#{path} could not be read; kept as #{corrupt}",
      user: username,
      system: system
    )

    _ = File.rename(path, corrupt)
    :ok
  end

  @doc """
  Runs `fun` on each of `records`, inside the import's transaction, each in
  a savepoint of its own: one that raises (an old record that doesn't fit
  the tables) is rolled back alone and set aside, and the others go on, so
  no record can stop an unlock. `fun` answers `{:ok, value}` for a record
  written, or `:skip`. Returns the values, and the records that failed
  with why.
  """
  @spec each_record(module(), [term()], (term() -> {:ok, term()} | :skip)) ::
          {[term()], [{term(), String.t()}]}
  def each_record(repo, records, fun) do
    {done, failed} =
      Enum.reduce(records, {[], []}, fn record, {done, failed} ->
        repo.query!("SAVEPOINT import_record")

        try do
          result = fun.(record)
          repo.query!("RELEASE import_record")

          case result do
            {:ok, value} -> {[value | done], failed}
            :skip -> {done, failed}
          end
        rescue
          error ->
            repo.query!("ROLLBACK TO import_record")
            repo.query!("RELEASE import_record")
            {done, [{record, Exception.message(error)} | failed]}
        end
      end)

    {Enum.reverse(done), Enum.reverse(failed)}
  end

  @doc """
  Keeps the records of `file` that `each_record/3` couldn't import, sealed
  with the password's `key` as the file was, in
  `legacy/<file>.not-imported-<time>`, and counts them for the Storage
  page (`failures/1`). Nothing when none failed.
  """
  @spec keep_failed(String.t(), String.t(), Vault.key(), [{term(), String.t()}], atom()) :: :ok
  def keep_failed(_username, _file, _key, [], _system), do: :ok

  def keep_failed(username, file, key, failed, system) do
    name = "#{String.replace(file, "/", "-")}.not-imported-#{System.os_time(:second)}"
    :ok = File.mkdir_p(dir(username))

    :ok =
      File.write(Path.join(dir(username), name), Vault.seal(key, Enum.map(failed, &elem(&1, 0))))

    [{_record, why} | _rest] = failed

    Logger.warning(
      "#{length(failed)} records of #{file} could not be imported (the first: #{String.slice(why, 0, 200)}); kept as legacy/#{name}",
      user: username,
      system: system
    )

    failures = Map.put(failures(username), file, %{count: length(failed), kept: name, why: why})
    :ok = Documents.put(username, @failures, failures)
  end

  @doc """
  What could not be imported, by the file it came from: how many records,
  the file under `legacy/` they are kept in, and why the first failed.
  """
  @spec failures(String.t()) :: %{String.t() => map()}
  def failures(username) do
    case Documents.get(username, @failures) do
      {:ok, failures} -> failures
      :none -> %{}
    end
  end

  @doc """
  Moves `name`, a file or folder of `username`'s (`"notes.bin"`,
  `"versions/notes"`), to the same place under `legacy/`, once what it
  held is in a database. One retired before keeps its place; the newer
  is named for when it came.
  """
  @spec retire(String.t(), String.t()) :: :ok
  def retire(username, name) do
    from = Accounts.store_path(username, name)
    to = Path.join(dir(username), name)

    if File.exists?(from) do
      to = if File.exists?(to), do: "#{to}.#{System.os_time(:millisecond)}", else: to
      :ok = File.mkdir_p(Path.dirname(to))
      :ok = File.rename(from, to)
      # Dated by when it retired, which the `legacy` rule counts from.
      :ok = File.touch(to)
      # A folder it was in, as `versions/`, goes once it is empty.
      if Path.dirname(name) != ".", do: File.rmdir(Path.dirname(from))
    end

    :ok
  end

  @doc """
  Applies the `legacy` retention rule (`MWTClient.Storage.Retention`) as
  of `now`: what retired before `:days` ago goes. Returns how many went.
  """
  @spec trim(String.t(), map(), DateTime.t()) :: non_neg_integer()
  def trim(_username, %{days: nil}, _now), do: 0

  def trim(username, %{days: days}, now) do
    cutoff = DateTime.to_unix(now) - days * 86_400

    retired(username)
    |> Enum.filter(fn path ->
      match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix))
    end)
    |> Enum.map(&File.rm_rf!/1)
    |> length()
  end

  @doc "Deletes everything retired."
  @spec delete_all(String.t()) :: :ok
  def delete_all(username) do
    File.rm_rf!(dir(username))
    :ok
  end

  # What retired, one by one: the files, and each kind's versions folder.
  defp retired(username) do
    versions = Path.join(dir(username), "versions")

    Path.wildcard(Path.join(dir(username), "*"))
    |> Enum.reject(&(&1 == versions))
    |> Kernel.++(Path.wildcard(Path.join(versions, "*")))
  end
end
