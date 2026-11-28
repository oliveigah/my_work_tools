defmodule MWTClient.Sandbox.SlotSummariesTest do
  use MWTClient.HandoffsCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{Channel, Handoff, HandoffRecords, Handoffs, Projects}

  test "the CLI records prompts and updates and keeps each handoff's own entries",
       %{username: username, base: base} = context do
    assert {:ok, _} = Sandbox.update_settings(username, %{"timeline_recording" => true})
    {_project, tree} = project_with_worktree(context)
    run = cli(context, tree)
    thread = "same-thread"

    assert {_, 0} = run.(["summary", ~s(Chose the "compact" layout.)])
    assert {_, 1} = run.(["summary", "Two\nlines"])
    long = String.duplicate("Recorded a decision and its rationale. ", 25) <> "Done."
    assert {_, 0} = run.(["summary", long])

    file = Path.join(base, "prompt details.txt")

    detail =
      "Keep the slot timeline compact and include critical context.\n\n" <>
        String.duplicate("Supporting context that stays in the detail. ", 1600)

    File.write!(file, detail)

    assert {_, 1} = run.(["summary", "--prompt", "Keep the compact timeline"])
    assert {_, 0} = run.(["summary", "--prompt", "Keep the compact timeline", "--details", file])
    assert {_, 0} = run.(["summary", "Recorded the requirements", "--details", file])

    git(tree, [
      "config",
      "--add",
      "branch.fix.mwt-summary-0",
      "2025-01-01T12:00:00Z An older update."
    ])

    for line <- ["Implemented the timeline.", "Checked the slot view.", "Ready for review."] do
      assert :ok = append(username, tree, thread, line)
    end

    assert git(tree, ["status", "--porcelain"]) == ""
    assert {:ok, %{slots: [_, %{summary: entries}]}} = Projects.slots(username, "app")

    assert lines(entries) == [
             "An older update.",
             ~s(Chose the "compact" layout.),
             long,
             "Keep the compact timeline",
             "Recorded the requirements",
             "Implemented the timeline.",
             "Checked the slot view.",
             "Ready for review."
           ]

    assert [
             %{kind: :status, detail: ""},
             _,
             _,
             %{kind: :prompt, detail: prompt},
             %{kind: :status, detail: update}
             | _
           ] = entries

    assert prompt == detail
    assert update == prompt

    commit(tree, [{"a.txt", "updated\n"}], "First handoff")
    assert {0, _} = Channel.answer("handoff", ask(tree, %{"thread_id" => thread}), username)
    assert {:ok, %{summary: ^entries}} = HandoffRecords.get(username, 1)

    assert :ok = append(username, tree, thread, "Adjusted spacing.")
    assert {:ok, %{summary: ^entries}} = HandoffRecords.get(username, 1)
    assert {0, _} = Channel.answer("handoff", ask(tree, %{"thread_id" => thread}), username)

    assert {:ok, %{summary: revised}} = HandoffRecords.get(username, 1)
    assert lines(revised) == lines(entries) ++ ["Adjusted spacing."]

    # The branch stays because it holds a commit beyond the handoff.
    commit(tree, [{"a.txt", "follow-up\n"}], "Start the follow-up")
    assert {:ok, _closed} = Handoffs.close(username, 1)
    assert {:ok, %{slots: [_, %{branch: "fix", summary: []}]}} = Projects.slots(username, "app")

    assert :ok = append(username, tree, thread, "Started the follow-up.")
    assert {0, _} = Channel.answer("handoff", ask(tree, %{"thread_id" => thread}), username)

    assert {:ok,
            %{thread_id: ^thread, summary: [%{kind: :status, title: "Started the follow-up."}]}} =
             HandoffRecords.get(username, 2)

    assert {:ok, %{thread_id: ^thread, summary: ^revised} = first} =
             HandoffRecords.get(username, 1)

    at = first.opened_at

    :ok =
      HandoffRecords.put(username, %{first | summary: [%{at: at, text: "An older snapshot."}]})

    assert {:ok,
            %Handoff{
              summary: [%{at: ^at, kind: :status, title: "An older snapshot.", detail: ""}]
            }} =
             HandoffRecords.get(username, 1)
  end

  test "a free slot or a slot held by another thread refuses an update",
       %{username: username, mirror: mirror} = context do
    assert {:ok, _} = Sandbox.update_settings(username, %{"timeline_recording" => true})
    {_project, tree} = project_with_worktree(context)

    assert {:ok, _, _, :already, _, _} =
             Projects.take_slot(username, tree, :resume, "fix", thread: "holder")

    assert {:error, _} = append(username, mirror, "holder", "Free slot.")
    assert {:error, {:not_your_slot, _}} = append(username, tree, "another", "Other slot.")

    assert {1, _} =
             Channel.answer(
               "summary",
               %{"cwd" => tree, "thread_id" => "holder", "text" => "Bad path", "details" => 42},
               username
             )

    assert :ok = append(username, tree, "holder", "One update.")

    assert {:ok, %{slots: [_, %{summary: [%{title: "One update."}]}]}} =
             Projects.slots(username, "app")
  end

  test "a structured timeline follows its branch to another slot",
       %{username: username, mirror: mirror} = context do
    {_project, first} = project_with_worktree(context)
    {:ok, "slot-2"} = Projects.add_slot(username, "app")
    second = slot(mirror, 2)
    thread = "moving-thread"

    assert {:ok, _, _, :already, _, _} =
             Projects.take_slot(username, first, :resume, "fix", thread: thread)

    assert :ok = Sandbox.set_timeline_override(username, thread, "on")

    tasks =
      for title <- ["One update.", "Another update."] do
        Task.async(fn -> append(username, first, thread, title) end)
      end

    assert Task.await_many(tasks) == [:ok, :ok]
    commit(first, [{"a.txt", "modified\n"}], "Keep this task branch")
    assert {:ok, _, _, _} = Projects.free_slot(username, first, nil)

    assert {:ok, _, _, :resumed, _, _} =
             Projects.take_slot(username, second, :resume, "fix", thread: thread)

    assert {:ok, %{slots: [_, %{summary: []}, %{summary: entries}]}} =
             Projects.slots(username, "app")

    assert Enum.sort(lines(entries)) == ["Another update.", "One update."]
    assert :ok = append(username, second, thread, "Recorded after moving.")
  end

  test "the live default and thread overrides control recording and agent guidance",
       %{username: username} = context do
    {_project, cwd} = project_with_worktree(context)
    thread = "timeline-thread"
    ask = %{"cwd" => cwd, "thread_id" => thread}

    assert {:ok, _, _, :already, _, _} =
             Projects.take_slot(username, cwd, :resume, "fix", thread: thread)

    assert {0, words} = Channel.answer("project", ask, username)
    refute words =~ "mwt help timeline"

    assert {1, "Timeline recording is off" <> _} =
             Channel.answer(
               "summary",
               Map.merge(ask, %{
                 "text" => "Ignored",
                 "details" => "missing.md"
               }),
               username
             )

    assert :ok = Sandbox.set_timeline_override(username, thread, "on")
    assert {0, words} = Channel.answer("project", ask, username)
    assert words =~ "mwt help timeline"
    assert :ok = append(username, cwd, thread, "Recorded with the override.")

    assert {:ok, _} = Sandbox.update_settings(username, %{"timeline_recording" => true})
    assert :ok = Sandbox.set_timeline_override(username, thread, "off")
    assert {:error, :timeline_disabled} = append(username, cwd, nil, "Never saved.")

    assert :ok = Sandbox.set_timeline_override(username, thread, "default")
    assert :ok = append(username, cwd, thread, "Recorded with the default.")
    assert {:ok, %{slots: [_, %{summary: entries}]}} = Projects.slots(username, "app")
    assert lines(entries) == ["Recorded with the override.", "Recorded with the default."]
  end

  defp append(username, cwd, thread, text) do
    MWTClient.Sandbox.SlotSummaries.append(username, %{
      "cwd" => cwd,
      "thread_id" => thread,
      "text" => text
    })
  end

  defp lines(entries), do: Enum.map(entries, & &1.title)
end
