defmodule MWTClient.Sandbox.SlotSummaryRecords do
  @moduledoc """
  The entries in an active slot timeline, kept in the identity's encrypted
  library. The VM's branch identifies the task by a token. Once a handoff
  ends, a later handoff of that branch uses a new group of entries.
  """

  alias MWTClient.Storage
  alias MWTClient.Storage.Values

  @doc "Appends an entry to the given task's timeline."
  def append(username, project, task, group, entry) do
    Storage.run(username, :library, fn repo ->
      repo.query!(
        """
        INSERT INTO slot_summary_entries (project, task, handoff_group, at, kind, title, detail)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          project,
          task,
          group,
          Values.time(entry.at),
          Atom.to_string(entry.kind),
          entry.title,
          entry.detail
        ]
      )
    end)

    :ok
  end

  @doc "The entries for this task and handoff group, oldest first."
  def list(_username, _project, nil, _group), do: []

  def list(username, project, task, group) do
    Storage.run(username, :library, fn repo ->
      repo.query!(
        """
        SELECT at, kind, title, detail FROM slot_summary_entries
        WHERE project = ? AND task = ? AND handoff_group = ?
        ORDER BY id
        """,
        [project, task, group]
      ).rows
    end)
    |> Enum.map(fn [at, kind, title, detail] ->
      %{at: Values.from_time(at), kind: kind(kind), title: title, detail: detail}
    end)
  end

  defp kind("status"), do: :status
  defp kind("prompt"), do: :prompt
end
