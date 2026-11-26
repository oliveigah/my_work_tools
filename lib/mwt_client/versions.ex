defmodule MWTClient.Versions do
  @moduledoc """
  Earlier versions of one library's items, so a change you regret is undone
  by restoring one, whoever made it: you, or an agent.

  Notes, diagrams and flash cards each keep theirs through one of these,
  held in the library's own process, which is the only one changing its
  items; so does your layer of the VM's image
  (`MWTClient.Sandbox.LayerVersions`), through the sandbox's. That process tells it of every change to what a version keeps
  (`changed/5`), with the item as it was before, and it decides whether to
  keep that as a version:

    * always before a change by an agent, and before a restore;
    * for your own editing, at most once per item per 10 minutes, since
      notes and diagrams save as you type. The first edit after someone
      else's change is kept too, so what an agent wrote is never lost to
      your next keystroke.

  They are rows of `versions` in `library.db` (`MWTClient.Storage`),
  written in the transaction of the change they record, so a change and
  the version it replaced are kept together or not at all. A version the
  same as the newest one kept is not kept twice.

  How many are kept is each kind's retention rule
  (`MWTClient.Storage.Retention`): every one for a while, then one a day,
  then one a month, never more than a number per item. That number holds
  as each is kept; the rest `thin/4` applies, as the janitor runs. Who
  made the last change, and when a version was last kept, are known only
  while the library runs: after a restart, the first edit keeps one.
  """

  require Logger

  alias MWTClient.Accounts
  alias MWTClient.Storage
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Retention
  alias MWTClient.Storage.Values
  alias MWTClient.Vault
  alias MWTClient.Versions.Version

  @quiet_ms 10 * 60 * 1000
  @kinds ~w(notes diagrams flashcards image_layers)
  @day_us 86_400_000_000

  @enforce_keys [:username, :kind]
  defstruct [:username, :kind, recent: %{}]

  @typedoc """
  Who made a change: you, in MWT; an agent in the VM, with what it
  claimed about itself (`agent`, `thread`), as claims label a version and
  prove nothing; or MWT itself, when an update moved what you had
  (`:mwt`). `{:agent, :local}`, an agent on this machine, is only in
  versions kept from when MWT's tools were open to them.
  """
  @type by ::
          :you
          | :mwt
          | {:agent, :local}
          | {:agent, :vm, %{agent: String.t() | nil, thread: String.t() | nil}}

  @typedoc "An item before a change: its version number, content and when it was saved."
  @type before :: %{version: pos_integer(), content: map(), saved_at: DateTime.t()}

  @type t :: %__MODULE__{
          username: String.t(),
          kind: String.t(),
          recent: %{String.t() => %{by: by(), kept: integer() | nil}}
        }

  @doc """
  The versions of one identity's `kind`: `\"notes\"`, `\"diagrams\"`,
  `\"flashcards\"` or `\"image_layers\"`.
  """
  @spec open(String.t(), String.t()) :: t()
  def open(username, kind) when kind in @kinds, do: %__MODULE__{username: username, kind: kind}

  @doc """
  Tells of a change to the item `id`, made `by` someone, `how` (`:edit` or
  `:restore`), with the item as it was `before`. Keeps that as a version
  when the rules above say so. Call it inside the transaction that writes
  the change (`MWTClient.Storage.transaction/3`).
  """
  @spec changed(t(), String.t(), before(), by(), :edit | :restore) :: t()
  def changed(%__MODULE__{} = versions, id, before, by, how) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(versions.recent, id)

    if keep?(last, by, how, now) do
      keep(versions, id, %Version{
        version: before.version,
        content: before.content,
        saved_at: before.saved_at,
        replaced_at: DateTime.utc_now(),
        replaced_by: by,
        how: how
      })

      %{versions | recent: Map.put(versions.recent, id, %{by: by, kept: now})}
    else
      %{versions | recent: Map.put(versions.recent, id, %{last | by: by})}
    end
  end

  defp keep?(_last, _by, :restore, _now), do: true
  defp keep?(_last, by, _how, _now) when by != :you, do: true

  defp keep?(%{by: :you, kept: kept}, :you, :edit, now) when is_integer(kept),
    do: now - kept >= @quiet_ms

  defp keep?(_last, _by, _how, _now), do: true

  defp keep(versions, id, %Version{} = version) do
    hash = hash(version.content)

    Storage.transaction(versions.username, :library, fn repo ->
      newest =
        repo.query!(
          "SELECT content_hash FROM versions WHERE kind = ?1 AND item_id = ?2 ORDER BY seq DESC LIMIT 1",
          [versions.kind, id]
        )

      if newest.rows != [[hash]] do
        insert(repo, versions.kind, id, version, hash)

        case Retention.rule(versions.username, rule_key(versions.kind)).most do
          nil ->
            :ok

          most ->
            repo.query!(
              """
              DELETE FROM versions WHERE kind = ?1 AND item_id = ?2 AND seq <= (
                SELECT seq FROM versions WHERE kind = ?1 AND item_id = ?2
                ORDER BY seq DESC LIMIT 1 OFFSET ?3
              )
              """,
              [versions.kind, id, most]
            )
        end
      end
    end)
  end

  @doc "The key of `kind`'s retention rule: `\"notes\"` keeps by `\"note_versions\"`."
  @spec rule_key(String.t()) :: String.t()
  def rule_key("notes"), do: "note_versions"
  def rule_key("diagrams"), do: "diagram_versions"
  def rule_key("flashcards"), do: "flashcard_versions"
  def rule_key("image_layers"), do: "image_layer_versions"

  @doc """
  Thins the versions of `kind` (`\"notes\"`) of `username` by `rule`
  (`MWTClient.Storage.Retention`), as of `now`: every one newer than
  `:every_days`; then the newest of each item's day until `:daily_days`;
  then the newest of each item's month, when `:monthly`, or none; and
  never more than `:most` of one item. Returns how many went.
  """
  @spec thin(String.t(), String.t(), map(), DateTime.t()) :: non_neg_integer()
  def thin(username, kind, rule, now) when kind in @kinds do
    now = Values.time(now)
    every = rule[:every_days] && now - rule.every_days * @day_us
    # One a day can't start before every one stops.
    daily = every && rule[:daily_days] && now - max(rule.daily_days, rule.every_days) * @day_us

    Storage.transaction(username, :library, fn repo ->
      by_day =
        if every do
          # One a day, from `daily` (or from the start) up to `every`.
          removed(
            repo.query!(
              """
              DELETE FROM versions WHERE kind = ?1 AND replaced_at < ?2 AND replaced_at >= ?3
              AND seq NOT IN (
                SELECT max(seq) FROM versions
                WHERE kind = ?1 AND replaced_at < ?2 AND replaced_at >= ?3
                GROUP BY item_id, replaced_at / ?4
              )
              """,
              [kind, every, daily || 0, @day_us]
            )
          )
        else
          0
        end

      by_month =
        cond do
          daily == nil ->
            0

          rule[:monthly] ->
            removed(
              repo.query!(
                """
                DELETE FROM versions WHERE kind = ?1 AND replaced_at < ?2
                AND seq NOT IN (
                  SELECT max(seq) FROM versions WHERE kind = ?1 AND replaced_at < ?2
                  GROUP BY item_id, strftime('%Y-%m', replaced_at / 1000000, 'unixepoch')
                )
                """,
                [kind, daily]
              )
            )

          true ->
            removed(
              repo.query!("DELETE FROM versions WHERE kind = ?1 AND replaced_at < ?2", [
                kind,
                daily
              ])
            )
        end

      by_count =
        case rule[:most] do
          nil ->
            0

          most ->
            removed(
              repo.query!(
                """
                DELETE FROM versions WHERE seq IN (
                  SELECT seq FROM (
                    SELECT seq, row_number() OVER (PARTITION BY item_id ORDER BY seq DESC) AS n
                    FROM versions WHERE kind = ?1
                  ) WHERE n > ?2
                )
                """,
                [kind, most]
              )
            )
        end

      by_day + by_month + by_count
    end)
  end

  defp removed(%{num_rows: rows}), do: rows

  defp hash(content), do: :crypto.hash(:sha256, :erlang.term_to_binary(content, [:deterministic]))

  defp insert(repo, kind, id, %Version{} = version, hash) do
    repo.query!(
      """
      INSERT INTO versions
        (kind, item_id, version, content, content_hash, saved_at, replaced_at, replaced_by, how)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        kind,
        id,
        version.version,
        Values.term(version.content),
        {:blob, hash},
        Values.time(version.saved_at),
        Values.time(version.replaced_at),
        Values.term(version.replaced_by),
        Atom.to_string(version.how)
      ]
    )
  end

  @columns "version, content, saved_at, replaced_at, replaced_by, how"

  @doc "The versions kept of the item `id`, the newest first."
  @spec list(t(), String.t()) :: [Version.t()]
  def list(%__MODULE__{} = versions, id) do
    Storage.run(versions.username, :library, fn repo ->
      repo.query!(
        "SELECT #{@columns} FROM versions WHERE kind = ? AND item_id = ? ORDER BY seq DESC",
        [versions.kind, id]
      ).rows
    end)
    |> Enum.map(&version/1)
  end

  @doc "The version numbered `number` of the item `id`."
  @spec fetch(t(), String.t(), integer()) :: {:ok, Version.t()} | :error
  def fetch(%__MODULE__{} = versions, id, number) do
    Storage.run(versions.username, :library, fn repo ->
      repo.query!(
        """
        SELECT #{@columns} FROM versions WHERE kind = ? AND item_id = ? AND version = ?
        ORDER BY seq DESC LIMIT 1
        """,
        [versions.kind, id, number]
      ).rows
    end)
    |> case do
      [row] -> {:ok, version(row)}
      [] -> :error
    end
  end

  defp version([number, content, saved_at, replaced_at, replaced_by, how]) do
    %Version{
      version: number,
      content: Values.from_term(content),
      saved_at: Values.from_time(saved_at),
      replaced_at: Values.from_time(replaced_at),
      replaced_by: Values.from_term(replaced_by),
      how: if(how == "restore", do: :restore, else: :edit)
    }
  end

  @doc """
  Forgets every version of the item `id`, as when it is deleted. Call it
  inside the transaction that deletes the item.
  """
  @spec forget(t(), String.t()) :: t()
  def forget(%__MODULE__{} = versions, id) do
    Storage.run(versions.username, :library, fn repo ->
      repo.query!("DELETE FROM versions WHERE kind = ? AND item_id = ?", [versions.kind, id])
    end)

    %{versions | recent: Map.delete(versions.recent, id)}
  end

  @doc """
  Forgets the versions of every item but `ids`, as when an import replaced
  them all. Call it inside the transaction that replaces them.
  """
  @spec keep_only(t(), [String.t()]) :: t()
  def keep_only(%__MODULE__{} = versions, ids) do
    Storage.run(versions.username, :library, fn repo ->
      repo.query!(
        "DELETE FROM versions WHERE kind = ? AND item_id NOT IN (SELECT value FROM json_each(?))",
        [versions.kind, Jason.encode!(ids)]
      )
    end)

    %{versions | recent: Map.take(versions.recent, ids)}
  end

  @doc """
  The folder, under the identity's, where versions of `kind` were kept
  before `library.db`, one sealed file per item.
  """
  @spec legacy_dir(String.t()) :: String.t()
  def legacy_dir(kind) when kind in @kinds, do: Path.join("versions", kind)

  @doc """
  Imports the versions kept before `library.db` of the items `ids`, sealed
  with the password's `key`, inside the transaction that imports the
  items. Files of items not among them, deleted since, are left behind.
  """
  @spec import_legacy(t(), Vault.key(), [String.t()]) :: :ok
  def import_legacy(%__MODULE__{} = versions, key, ids) do
    dir = Accounts.store_path(versions.username, legacy_dir(versions.kind))

    Storage.run(versions.username, :library, fn repo ->
      failed =
        for id <- ids,
            path = Path.join(dir, file_name(id)),
            {:ok, blob} <- [File.read(path)],
            reduce: [] do
          failed ->
            case Vault.open(key, blob) do
              # Kept the newest first: written the oldest first, as kept since.
              {:ok, list} when is_list(list) ->
                {_done, more} =
                  Legacy.each_record(repo, Enum.reverse(list), fn %Version{} = version ->
                    insert(repo, versions.kind, id, version, hash(version.content))
                    {:ok, version.version}
                  end)

                failed ++ Enum.map(more, fn {version, why} -> {{id, version}, why} end)

              _unreadable ->
                Logger.warning(
                  "versions at #{path} could not be decrypted, and were not imported",
                  user: versions.username,
                  system: :versions
                )

                failed
            end
        end

      Legacy.keep_failed(versions.username, legacy_dir(versions.kind), key, failed, :versions)
    end)
  end

  @doc "Who made a change, in words, starting with a capital."
  @spec who(by()) :: String.t()
  def who(:you), do: "You"
  def who(:mwt), do: "MWT"
  def who({:agent, :local}), do: "An agent on this machine"
  def who({:agent, :vm, %{agent: agent}}) when is_binary(agent), do: "#{agent} in the VM"
  def who({:agent, :vm, _claims}), do: "An agent in the VM"

  @doc "Whether a change was made by an agent."
  @spec agent?(by()) :: boolean()
  def agent?({:agent, _where}), do: true
  def agent?({:agent, _where, _claims}), do: true
  def agent?(_by), do: false

  # The file an item's versions were kept in: a digest of its id, so no
  # id could name a path of its own.
  defp file_name(id),
    do: Base.url_encode64(:crypto.hash(:sha256, id), padding: false) <> ".bin"
end
