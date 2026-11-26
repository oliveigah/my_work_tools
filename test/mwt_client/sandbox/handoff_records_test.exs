defmodule MWTClient.Sandbox.HandoffRecordsTest do
  @moduledoc """
  Every handoff, kept for good in `library.db`: written and read back,
  the latest of a branch, and the list's pages, its halves, its search,
  the archived line and the days asked for.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Handoff, HandoffRecords, Server}
  alias MWTClient.Search
  alias MWTClient.Storage.Documents
  alias MWTClient.Vault.Store

  @now ~U[2026-11-22 12:00:00Z]

  setup do
    MWTClient.VaultHelpers.unlocked_identity("records")
  end

  defp handoff(id, fields \\ []) do
    struct!(
      %Handoff{
        id: id,
        title: "Task #{id}",
        agent: "claude",
        project: "app",
        repo: "/home/me/app",
        onto: "main",
        base_branch: "main",
        source: %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "task-#{id}"},
        head: String.duplicate("a", 40),
        opened_at: DateTime.add(@now, -1, :day),
        body: "Done.",
        timeline: [%{at: @now, kind: :opened, text: "claude handed it off"}]
      },
      fields
    )
  end

  # Landed `days` before now.
  defp landed(id, days, fields \\ []) do
    at = DateTime.add(@now, -days, :day)
    handoff(id, [status: :accepted, opened_at: at, updated_at: at] ++ fields)
  end

  defp page(username, query) do
    HandoffRecords.page(
      username,
      Map.merge(
        %{
          half: :waiting,
          terms: [],
          archived?: false,
          from: nil,
          to: nil,
          page: 1,
          per_page: 20,
          now: @now
        },
        query
      )
    )
  end

  defp ids(%{handoffs: handoffs}), do: Enum.map(handoffs, & &1.id)

  test "a handoff comes back as it was kept, and as it was changed last", %{username: username} do
    kept = handoff(1, body: "First notes.")
    :ok = HandoffRecords.put(username, kept)
    assert {:ok, ^kept} = HandoffRecords.get(username, 1)

    changed = %{kept | status: :closed, body: "Second notes.", updated_at: @now}
    :ok = HandoffRecords.put(username, changed)
    assert {:ok, ^changed} = HandoffRecords.get(username, 1)
    assert :error = HandoffRecords.get(username, 2)

    # What it is searched by follows: the old words find it no more.
    assert ids(page(username, %{half: :done, terms: ["second"]})) == [1]
    assert ids(page(username, %{half: :done, terms: ["first"]})) == []
  end

  test "an import keeps what is kept already, so one cut short can run again", %{
    username: username
  } do
    :ok = HandoffRecords.put(username, handoff(1, status: :closed))
    :ok = HandoffRecords.import(username, [handoff(1), handoff(2)])

    assert {:ok, %{status: :closed}} = HandoffRecords.get(username, 1)
    assert {:ok, %{status: :open}} = HandoffRecords.get(username, 2)
    assert HandoffRecords.ids(username) == [1, 2]
    assert HandoffRecords.max_id(username) == 2
  end

  test "the latest of a branch, and those waiting", %{username: username} do
    branch = %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "fix"}
    :ok = HandoffRecords.put(username, landed(1, 2, source: branch))
    :ok = HandoffRecords.put(username, handoff(2, source: branch, status: :withdrawn))
    :ok = HandoffRecords.put(username, handoff(3, project: "other", source: branch))

    assert %{id: 2} = HandoffRecords.latest(username, "app", "fix")
    assert %{id: 3} = HandoffRecords.latest(username, "other", "fix")
    assert HandoffRecords.latest(username, "app", "nothing") == nil
    assert username |> HandoffRecords.waiting() |> Enum.map(& &1.id) |> Enum.sort() == [2, 3]
  end

  # The older MWT kept it as waiting, which it still is.
  test "one an older MWT sent back to its thread reads as open", %{username: username} do
    :ok = HandoffRecords.put(username, handoff(1, status: :sent_back))
    assert {:ok, %Handoff{status: :open}} = HandoffRecords.get(username, 1)
  end

  test "landed or closed a month ago, one is archived; one waiting never is", %{
    username: username
  } do
    :ok = HandoffRecords.put(username, landed(1, 29))
    :ok = HandoffRecords.put(username, landed(2, 31))
    :ok = HandoffRecords.put(username, landed(3, 400, status: :closed))
    # Waiting for you since long ago: still in view.
    :ok = HandoffRecords.put(username, handoff(4, opened_at: DateTime.add(@now, -90, :day)))

    refute HandoffRecords.archived?(landed(1, 29), @now)
    assert HandoffRecords.archived?(landed(2, 31), @now)
    refute HandoffRecords.archived?(handoff(4, opened_at: DateTime.add(@now, -90, :day)), @now)

    without = page(username, %{half: :done})
    assert ids(without) == [1]
    assert %{waiting: 1, done: 1} = without

    with_archived = page(username, %{half: :done, archived?: true})
    assert ids(with_archived) == [1, 2, 3]
    assert %{waiting: 1, done: 3} = with_archived

    # What an agent in the project is told of: the same line.
    assert username |> HandoffRecords.current("app", @now) |> Enum.map(& &1.id) == [4, 1]
  end

  test "with the archived, the days asked for bound when each changed last", %{
    username: username
  } do
    for {id, days} <- [{1, 10}, {2, 45}, {3, 60}, {4, 90}],
        do: :ok = HandoffRecords.put(username, landed(id, days))

    within = fn from, to ->
      page(username, %{half: :done, archived?: true, from: from, to: to}) |> ids()
    end

    assert within.(DateTime.add(@now, -70, :day), DateTime.add(@now, -40, :day)) == [2, 3]
    assert within.(DateTime.add(@now, -50, :day), nil) == [1, 2]
    assert within.(nil, DateTime.add(@now, -50, :day)) == [3, 4]
    # Days alone don't bring archived ones back: only asked with them.
    assert page(username, %{half: :done, from: DateTime.add(@now, -70, :day)}) |> ids() == [1]
  end

  test "a page at a time, newest first, both halves counted with the same words", %{
    username: username
  } do
    for id <- 1..45 do
      body = if rem(id, 3) == 0, do: "the redis pool", else: "the vm"

      :ok =
        HandoffRecords.put(
          username,
          landed(id, 0, body: body, updated_at: DateTime.add(@now, id, :second))
        )
    end

    :ok = HandoffRecords.put(username, handoff(46, body: "redis in the vm"))

    first = page(username, %{half: :done})
    assert ids(first) == Enum.to_list(45..26//-1)
    assert %{page: 1, pages: 3, waiting: 1, done: 45} = first

    last = page(username, %{half: :done, page: 9})
    assert %{page: 3} = last
    assert ids(last) == Enum.to_list(5..1//-1)

    # A word of 3 letters or more goes through the index; a shorter one
    # is read in the rows the rest leaves; both mean the same.
    redis = page(username, %{half: :done, terms: Search.terms("REDIS  pool")})
    assert %{waiting: 0, done: 15, pages: 1} = redis
    assert ids(redis) == Enum.to_list(45..3//-3)

    vm = page(username, %{half: :done, terms: ["vm"]})
    assert %{waiting: 1, done: 30} = vm

    assert %{waiting: 1, done: 0} = page(username, %{terms: ["redis", "vm"]})
    assert ids(page(username, %{terms: ["#46"]})) == [46]
  end

  describe "in the sandbox" do
    test "every handoff is kept, and those waiting come back when MWT starts", %{
      username: username,
      key: key
    } do
      for id <- 1..105 do
        status = if id in [7, 104], do: :open, else: :accepted
        :ok = Server.call(username, {:put_handoff, handoff(id, status: status), "kept"})
      end

      assert length(HandoffRecords.ids(username)) == 105

      :ok = Store.close(username)
      :ok = Store.open(username, key)

      assert username
             |> MWTClient.Sandbox.snapshot()
             |> Map.fetch!(:waiting_handoffs)
             |> Enum.map(& &1.id)
             |> Enum.sort() ==
               [7, 104]

      # Its record no longer holds them; the numbers go on past the last.
      {:ok, saved} = Documents.get(username, "sandbox")
      refute Map.has_key?(saved, :handoffs)
      assert Server.call(username, :next_handoff_id) == 106
    end

    test "a server running from before moves the handoffs it holds when its code changes", %{
      username: username
    } do
      pid = Store.whereis(Server, username)

      before =
        pid
        |> :sys.get_state()
        |> Map.delete(:waiting_handoffs)
        |> Map.put(:handoffs, [handoff(1), landed(2, 3)])
        |> Map.put(:code, :older)

      now = Server.State.current(before)

      refute Map.has_key?(now, :handoffs)
      assert Enum.map(now.waiting_handoffs, & &1.id) == [1]
      assert HandoffRecords.ids(username) == [1, 2]
    end
  end
end
