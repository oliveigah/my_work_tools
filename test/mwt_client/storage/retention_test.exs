defmodule MWTClient.Storage.RetentionTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Storage
  alias MWTClient.Storage.Retention
  alias MWTClient.Versions

  setup do
    unlocked_identity()
  end

  test "every kind starts at its default, and one changed changes only it", %{username: username} do
    assert Retention.rule(username, "http_history") == %{days: 90, gb: nil}
    assert Retention.rule(username, "agent_activity") == %{days: 180, gb: 5}
    assert Retention.rule(username, "backups") == %{count: 5}

    assert Retention.rule(username, "note_versions") ==
             %{every_days: 90, daily_days: 365, monthly: true, most: 100}

    assert {:ok, %{every_days: 30}} =
             Retention.put(username, "note_versions", %{"every_days" => "30"})

    assert Retention.rule(username, "note_versions").every_days == 30
    assert Retention.rule(username, "diagram_versions").every_days == 90
    assert Retention.changed?(username, "note_versions")
    refute Retention.changed?(username, "diagram_versions")

    :ok = Retention.reset(username, "note_versions")
    refute Retention.changed?(username, "note_versions")
  end

  test "a limit can be off, and a value that isn't one changes nothing", %{username: username} do
    assert {:ok, %{days: nil, gb: 2}} =
             Retention.put(username, "http_history", %{"days" => "", "gb" => "2"})

    assert {:error, [days: "must be a whole number", gb: "must be 1 or more, or off"]} =
             Retention.put(username, "http_history", %{"days" => "soon", "gb" => "0"})

    assert Retention.rule(username, "http_history") == %{days: nil, gb: 2}

    assert {:ok, %{monthly: false}} =
             Retention.put(username, "note_versions", %{"monthly" => "false"})

    # A limit the kind doesn't have is not read.
    assert {:ok, %{count: 5}} = Retention.put(username, "backups", %{"days" => "3"})
    refute Map.has_key?(Retention.rule(username, "backups"), :days)
  end

  test "rules read in a few words" do
    assert Retention.describe(%{days: 90, gb: nil}) == "90 days"
    assert Retention.describe(%{days: 180, gb: 5}) == "180 days · at most 5 GB"
    assert Retention.describe(%{count: 3}) == "the newest 3"
    assert Retention.describe(%{days: nil}) == "kept until you remove it"
    assert Retention.describe(%{days: nil}, "as long as their entry") == "as long as their entry"

    assert Retention.describe(%{every_days: 90, daily_days: 365, monthly: true, most: 100}) ==
             "every one for 90 days, then one a day until 365 days, then one a month, at most 100 an item"
  end

  describe "versions" do
    @day 86_400_000_000
    # Noon, so a few minutes either side stay in one day, and one month.
    @now ~U[2026-06-15 12:00:00.000000Z]

    # Versions of one item, `ages` days before `@now`, one each.
    defp versions_aged(username, item, ages) do
      versions = Versions.open(username, "notes")

      for {age, n} <- Enum.with_index(ages, 1) do
        before = %{version: n, content: %{body: "#{item} #{n}"}, saved_at: DateTime.utc_now()}
        Versions.changed(versions, item, before, {:agent, :local}, :edit)

        Storage.run(username, :library, fn repo ->
          repo.query!(
            "UPDATE versions SET replaced_at = ? WHERE item_id = ? AND version = ?",
            [DateTime.to_unix(@now, :microsecond) - round(age * @day), item, n]
          )
        end)
      end
    end

    defp kept(username, item),
      do: username |> Versions.open("notes") |> Versions.list(item) |> Enum.map(& &1.version)

    test "every one while recent, then one a day, then one a month", %{username: username} do
      # Two today, two on day 100, two on day 100.5 (the same day for some
      # hours, so a third day), and two of the same month long ago.
      ages = [0, 0.1, 100, 100.01, 400, 400.01]
      versions_aged(username, "n", ages)

      rule = %{every_days: 90, daily_days: 365, monthly: true, most: nil}
      removed = Versions.thin(username, "notes", rule, @now)

      assert removed == 2
      assert kept(username, "n") == [6, 4, 2, 1]
    end

    test "past the daily ones, none when monthly is off", %{username: username} do
      versions_aged(username, "n", [0, 400, 401])
      rule = %{every_days: 90, daily_days: 365, monthly: false, most: nil}

      Versions.thin(username, "notes", rule, @now)
      assert kept(username, "n") == [1]
    end

    test "at most so many of one item, as each is kept and as the janitor thins", %{
      username: username
    } do
      {:ok, _rule} = Retention.put(username, "note_versions", %{"most" => "3"})
      versions_aged(username, "n", [0, 0, 0, 0, 0])
      assert kept(username, "n") == [5, 4, 3]

      versions_aged(username, "m", [0, 0])
      Versions.thin(username, "notes", %{every_days: nil, most: 1}, @now)
      assert kept(username, "m") == [2]
    end

    test "with every one kept for good, nothing is thinned", %{username: username} do
      versions_aged(username, "n", [1_000, 2_000])
      rule = %{every_days: nil, daily_days: 365, monthly: false, most: nil}

      assert Versions.thin(username, "notes", rule, @now) == 0
      assert kept(username, "n") == [2, 1]
    end
  end
end
