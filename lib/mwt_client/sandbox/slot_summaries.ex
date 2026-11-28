defmodule MWTClient.Sandbox.SlotSummaries do
  @moduledoc """
  The user prompts and agent updates of a worktree slot. The branch's
  Git configuration holds a task identifier, so its timeline follows it
  between slots. The text is kept in the encrypted library. Each handoff
  keeps its own snapshot, including after the branch is pruned.
  """

  alias MWTClient.Sandbox.{
    Handoff,
    HandoffRecords,
    Project,
    Projects,
    Secrets,
    Server,
    Settings,
    Shown,
    Slots,
    SlotSummaryRecords
  }

  alias MWTClient.Storage

  @type entry :: %{
          at: DateTime.t(),
          kind: :status | :prompt,
          title: String.t(),
          detail: String.t()
        }

  @key_pattern "^branch[.].*[.]mwt-summary-(id|[0-9]+)$"

  @claim ~S"""
  set -e
  path=$1 branch=$2 thread=$3 key=$4 token=$5
  test "$(git -C "$path" symbolic-ref -q HEAD)" = "refs/heads/$branch"
  holder=$(git -C "$path" config --get "branch.$branch.mwt-thread" ||
    git -C "$path" config --get "branch.$branch.mwt-review-thread" || true)
  test "$holder" = "$thread"
  if current=$(git -C "$path" config --local --get "$key"); then
    printf '%s' "$current"
  else
    git -C "$path" config --local "$key" "$token"
    printf '%s' "$token"
  fi
  """

  @snapshot ~S"""
  git --git-dir="$1" config --local --null --get "$2"
  status=$?
  if [ "$status" -eq 1 ]; then printf '\000'
  elif [ "$status" -ne 0 ]; then exit "$status"; fi
  git --git-dir="$1" config --local --null --get-all "$3"
  status=$?
  test "$status" -eq 0 || test "$status" -eq 1
  """

  @detail ~S"""
  set -e
  cd "$1"
  test -f "$2"
  cat -- "$2"
  """

  @doc "Adds an agent status update or contextualized user prompt to the calling slot."
  def append(username, ask) do
    cwd = Shown.text(ask["cwd"])

    with {:ok, kind} <- kind(ask["kind"]),
         {:ok, title} <- title(ask["text"]),
         {:ok, project, {:worktree, top}, guest} <- Projects.locate(username, cwd),
         latest = &HandoffRecords.latest(username, project.name, &1),
         {:ok, look} <- Slots.look(project, guest, latest),
         {:ok, slot} <- active_slot(Slots.slot_at(look, top), ask["thread_id"]),
         thread = if(ask["thread_id"] in [nil, ""], do: thread(slot), else: ask["thread_id"]),
         true <- enabled?(username, thread) or {:error, :timeline_disabled},
         {:ok, detail} <- detail(guest, cwd, kind, ask["details"]),
         :ok <- check_text(username, title, detail),
         {:ok, token} <- claim(username, project, guest, slot) do
      entry = %{at: DateTime.utc_now(), kind: kind, title: title, detail: detail}
      Server.call(username, {:record_summary, thread, project, slot.branch, token, entry})
    end
  end

  @doc "The default recording choice, as it applies to threads with no override."
  def default_enabled?(settings), do: Settings.timeline_enabled?(settings, nil)

  @doc "Whether recording is enabled for this thread at the moment."
  def enabled?(username, thread), do: Server.call(username, {:timeline_enabled, thread})

  @doc "The thread recorded for the slot's task or review, if known."
  def thread(slot), do: slot[:thread] || slot[:review_thread]

  @doc false
  # The server serializes writes with changes to the live recording setting.
  def persist(username, project, branch, token, entry) do
    Storage.transaction(username, :library, fn _repo ->
      group = username |> HandoffRecords.latest(project.name, branch) |> group()
      SlotSummaryRecords.append(username, Project.id(project), token, group, entry)
    end)
  end

  defp claim(username, project, guest, slot) do
    # The first writes of a branch must agree on its ID. Git's config lock
    # guards the file, and this lock guards the read and write as a pair.
    lock = {__MODULE__, username, Project.id(project), slot.branch}

    :global.trans({lock, self()}, fn ->
      generated = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      case guest.exec.([
             "sh",
             "-c",
             @claim,
             "mwt-summary",
             slot.path,
             slot.branch,
             thread(slot) || "",
             key(slot.branch, "id"),
             generated
           ]) do
        {:ok, value} ->
          case token(value) do
            nil -> {:error, "MWT couldn't read the slot's timeline ID."}
            token -> {:ok, token}
          end

        {:error, _} ->
          {:error, "MWT couldn't save the summary. Check that you're still in your slot."}
      end
    end)
  end

  defp active_slot(%{branch: branch, free?: false} = slot, thread) when is_binary(branch) do
    if Slots.holder(%{slot | thread: thread(slot)}, thread) == :another,
      do: {:error, {:not_your_slot, slot}},
      else: {:ok, slot}
  end

  defp active_slot(_slot, _thread),
    do: {:error, "Run mwt summary from a worktree slot holding your task or review."}

  defp kind(kind) when kind in [nil, "", "status"], do: {:ok, :status}
  defp kind("prompt"), do: {:ok, :prompt}
  defp kind(_other), do: {:error, "Use an update or a user prompt for the summary entry."}

  defp title(value) do
    text = value |> Shown.text() |> String.trim()

    if text == "" or String.contains?(text, "\n"),
      do: {:error, "Give the summary a non-empty title on one line."},
      else: {:ok, text}
  end

  defp detail(_guest, _cwd, :status, path) when path in ["", nil], do: {:ok, ""}

  defp detail(_guest, _cwd, :prompt, path) when path in ["", nil],
    do: {:error, "Record the user's prompt in a file and pass it with --details FILE."}

  defp detail(guest, cwd, kind, path) when is_binary(path) do
    case guest.exec.(["sh", "-c", @detail, "mwt-summary", cwd, path]) do
      {:ok, content} ->
        text = Shown.text(content)

        case {kind, String.trim(text)} do
          {:prompt, ""} -> {:error, "Give the user's prompt some detail in the file."}
          {:status, ""} -> {:ok, ""}
          _ -> {:ok, text}
        end

      {:error, reason} ->
        {:error, "MWT couldn't read the summary details: " <> Shown.text(reason)}
    end
  end

  defp detail(_guest, _cwd, _kind, _path),
    do: {:error, "Give --details a readable file in the VM."}

  defp check_text(username, title, detail) do
    secrets = Server.call(username, :secrets)

    if Secrets.find(secrets, title) || Secrets.find(secrets, detail),
      do: {:error, "The summary contains a credential value."},
      else: :ok
  end

  @doc "The Git config pattern used to read task IDs and legacy summaries with the slot list."
  def key_pattern, do: @key_pattern

  @doc "Reads the NUL-separated config records alongside the slots."
  def config(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce(%{}, fn record, values ->
      case String.split(record, "\n", parts: 2) do
        [key, value] -> Map.update(values, key, [value], &[value | &1])
        _ -> values
      end
    end)
    |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  @doc "The active slot timeline, including any waiting handoff's saved entries."
  def for_slot(
        username,
        project,
        %{free?: false, branch: branch, handoff: handoff},
        config,
        secrets
      )
      when is_binary(branch) do
    current_group = group(handoff)
    task = config |> Map.get(key(branch, "id"), []) |> List.last() |> token()
    live = SlotSummaryRecords.list(username, Project.id(project), task, current_group)
    legacy = Map.get(config, key(branch, current_group), [])
    entries(live, legacy, waiting(handoff), secrets)
  end

  def for_slot(_username, _project, _slot, _config, _secrets), do: []

  @doc "Reads the entries to save on the handoff at submission."
  def snapshot(username, project, guest, source, existing) do
    previous = existing || HandoffRecords.latest(username, project.name, source.branch)
    group = group(previous)

    with {:ok, output} <-
           guest.exec.([
             "sh",
             "-c",
             @snapshot,
             "mwt-summary",
             source.folder,
             key(source.branch, "id"),
             key(source.branch, group)
           ]),
         [id, values] <- :binary.split(output, <<0>>) do
      live = SlotSummaryRecords.list(username, Project.id(project), token(id), group)
      secrets = Server.call(username, :secrets)
      {:ok, group, entries(live, String.split(values, <<0>>, trim: true), existing, secrets)}
    else
      _ -> {:error, "MWT couldn't read the task's summary for this handoff."}
    end
  end

  @doc "Upgrades a summary saved before entries had a kind and detail."
  def upgrade(%{at: at, text: text}), do: %{at: at, kind: :status, title: text, detail: ""}
  def upgrade(entry), do: entry

  # Once a handoff ends, a later handoff of the same branch gets its own
  # updates. A revision reads the same group as the original submission.
  defp group(nil), do: 0

  defp group(handoff),
    do: if(Handoff.waiting?(handoff), do: handoff.summary_group, else: handoff.id)

  defp key(branch, group), do: "branch.#{branch}.mwt-summary-#{group}"

  defp token(text) when is_binary(text),
    do: if(Regex.match?(~r/\A[0-9a-f]{32}\z/, text), do: text)

  defp token(_other), do: nil

  defp waiting(nil), do: nil
  defp waiting(handoff), do: if(Handoff.waiting?(handoff), do: handoff)

  defp entries(live, values, handoff, secrets) do
    saved = if handoff, do: handoff.summary, else: []

    legacy =
      for value <- values,
          [stamp, line] <- [String.split(value, " ", parts: 2)],
          {:ok, at, _offset} <- [DateTime.from_iso8601(stamp)],
          {:ok, text} <- [title(line)],
          do: upgrade(%{at: at, text: text})

    (saved ++ legacy ++ live)
    |> Enum.map(fn entry ->
      %{
        entry
        | title: Secrets.replace(secrets, entry.title, "[withheld]"),
          detail: Secrets.replace(secrets, entry.detail, "[withheld]")
      }
    end)
    |> Enum.uniq()
    |> Enum.sort_by(& &1.at, DateTime)
  end
end
