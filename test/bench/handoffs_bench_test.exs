defmodule MWTClient.HandoffsBenchTest do
  @moduledoc """
  Times the Handoffs page's list and search over thousands of handoffs
  kept for good (`MWTClient.Sandbox.HandoffRecords`), most of them
  archived, their notes cut from this repository's own documents so the
  words are spread as in real ones.

  Excluded from the suite; run it with

      mix test test/bench/handoffs_bench_test.exs --only bench

  and size it with `BENCH_HANDOFFS`. Aimed at: under 100 ms a search, but
  for the rare one that has nothing to narrow it (a word of 2 letters
  alone, over every archived handoff); 2 s for anything reasonable. The
  LiveView timings include `Phoenix.LiveViewTest` applying each patch.
  """
  use MWTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox.{Handoff, HandoffRecords}
  alias MWTClient.Search

  @moduletag :bench
  @moduletag timeout: :infinity

  @count String.to_integer(System.get_env("BENCH_HANDOFFS", "10000"))
  @hard_limit_ms 2_000

  setup %{conn: conn} do
    :rand.seed(:exsss, {1, 2, 3})
    sign_in(conn)
  end

  test "handoffs", %{conn: conn, username: username} do
    IO.puts("\n=== Handoffs: #{@count}, three a day, the last 30 days' in view ===")
    corpus = corpus()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    handoffs = for id <- 1..@count, do: handoff(id, @count, now, corpus)
    text = handoffs |> Enum.map(&byte_size(Handoff.search_text(&1))) |> Enum.sum()
    IO.puts("search text: #{div(text, 1024 * 1024)} MiB")

    time("keep every one", fn ->
      handoffs |> Enum.chunk_every(1_000) |> Enum.each(&HandoffRecords.import(username, &1))
    end)

    queries = [
      {"the list", ""},
      {"a rare word", "cookie"},
      {"a common word", "the"},
      {"two words", "landing branch"},
      {"no match", "zzqxv"},
      {"#id", "#4242"},
      {"a short word", "vm"},
      {"a short word and a long", "vm landing"}
    ]

    window = {DateTime.add(now, -180, :day), DateTime.add(now, -90, :day)}

    for {label, term} <- queries,
        {scope, archived?, {from, to}} <- [
          {"last 30 days", false, {nil, nil}},
          {"with the archived", true, {nil, nil}},
          {"archived, 90 days", true, window}
        ] do
      query = %{
        half: :done,
        terms: Search.terms(term),
        archived?: archived?,
        from: from,
        to: to,
        page: 1,
        per_page: 20,
        now: now
      }

      ms = median("#{label} (#{scope})", 5, fn -> HandoffRecords.page(username, query) end)
      assert ms < @hard_limit_ms
    end

    {:ok, view, _html} =
      time("mount the list", fn -> live(conn, ~p"/tools/sandbox/handoffs?filter=closed") end)

    for params <- [
          %{"term" => "landing branch"},
          %{"term" => "vm"},
          %{"term" => "landing branch", "archived" => "true"},
          %{"term" => "vm", "archived" => "true"}
        ] do
      median("search event #{inspect(params)}", 5, fn ->
        view |> form("#handoff-search", params) |> render_change()
      end)
    end
  end

  defp corpus do
    root = Path.expand("../..", __DIR__)

    (Path.wildcard(Path.join(root, "docs/**/*.md")) ++
       Path.wildcard(Path.join(root, "priv/sandbox/**/*.md")))
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp cut(corpus, length) do
    at = :rand.uniform(byte_size(corpus) - length - 1)
    corpus |> binary_part(at, length) |> String.replace_invalid()
  end

  # Notes mostly 1 to 4 KB, one in 20 long; three handoffs a day, the
  # newest now, nearly all landed.
  defp handoff(id, count, now, corpus) do
    at = DateTime.add(now, -div((count - id) * 86_400, 3), :second)

    length =
      if :rand.uniform(20) == 1,
        do: 8_000 + :rand.uniform(8_000),
        else: 1_000 + :rand.uniform(3_000)

    %Handoff{
      id: id,
      title: cut(corpus, 60),
      agent: "claude",
      thread: "Thread #{id}",
      project: Enum.random(~w(my_work_tools klife ume_credit_system monorepo-python)),
      repo: "/home/me/app",
      onto: "main",
      base_branch: "main",
      source: %{folder: "/work/app/.git", top: "/work/app.wt/slot-1", branch: "task-#{id}"},
      head: String.duplicate("a", 40),
      opened_at: at,
      updated_at: at,
      status: if(:rand.uniform(30) == 1, do: :closed, else: :accepted),
      body: cut(corpus, length),
      timeline: [%{at: at, kind: :opened, text: "claude handed it off"}]
    }
  end

  defp time(label, fun) do
    {us, result} = :timer.tc(fun)
    IO.puts("#{label}: #{Float.round(us / 1000, 1)} ms")
    result
  end

  defp median(label, runs, fun) do
    times = for _ <- 1..runs, do: elem(:timer.tc(fun), 0)
    ms = Float.round(Enum.at(Enum.sort(times), div(runs, 2)) / 1000, 1)
    IO.puts("#{label}: #{ms} ms")
    ms
  end
end
