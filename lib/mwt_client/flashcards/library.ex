defmodule MWTClient.Flashcards.Library do
  @moduledoc """
  Owns one identity's flash cards and how its sessions run.

  They are kept in the identity's `library.db` (`MWTClient.Storage`),
  encrypted on disk with the rest of it: a row of `flashcards` per card,
  searched through a trigram index (`MWTClient.Search.where/4`), and the
  settings as a document. Every function takes the username they belong
  to.

  Reads run in the process that asks, straight from the database, so none
  waits behind a write; lists, tags and counts read neither backs nor
  search text. Writes go through this process, one per unlocked identity,
  started by `MWTClient.Vault.Store`: each change is one transaction, made
  durable before it returns, with the version it may keep; and this
  process remembers who changed each card last, which the version rule
  asks.

  This module is the only way in, for the flash cards page and for agents
  writing cards through MCP. Every change is broadcast, once written, to
  the processes that `subscribe/1`, all but the one that made it, so a
  page shows cards an agent wrote without asking.

  Tags are matched without regard to case, and a card written with a
  tag already in use takes the spelling in use, so "MWT_client" and
  "mwt_client" stay one tag.

  Every change to a card's front, back, tags or source counts up its
  `version`, and may keep what it replaced as a version to restore
  (`MWTClient.Versions`). Answering a card is not such a change.

  At its first start with an identity whose cards are still in
  `flashcards.bin`, from before `library.db`, it imports them, their
  versions and the settings, then moves the files into `legacy/`
  (`MWTClient.Storage.Legacy`).
  """

  use GenServer

  alias MWTClient.Accounts
  alias MWTClient.Flashcards.Card
  alias MWTClient.Flashcards.Schedule
  alias MWTClient.Flashcards.Settings
  alias MWTClient.Search
  alias MWTClient.Storage
  alias MWTClient.Storage.Documents
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Values
  alias MWTClient.Vault.Store
  alias MWTClient.Versions

  @kind "flashcards"
  @legacy_file "flashcards.bin"
  @settings "flashcards.settings"

  # What every read asks for, and what lists, tags, counts and picks read:
  # the same less the back and the search text, which they never show.
  @light ~w(id front tags source box due_at reviewed_at reviews lapses removed_at created_at
            updated_at version)
  @full @light ++ ~w(back search_text)

  @typedoc """
  Which cards a session or a list picks from: those holding `tags`, any
  one of them or, with `match: :all`, every one (no tags means every card),
  written within the last `days` days (nil means any time), and, for lists,
  holding every word of `query`. Cards removed from the deck are left out,
  unless `removed: true`, which keeps only them.
  """
  @type scope :: %{
          optional(:tags) => [String.t()],
          optional(:match) => :any | :all,
          optional(:days) => pos_integer() | nil,
          optional(:query) => String.t(),
          optional(:removed) => boolean()
        }

  @type summary :: %{
          id: String.t(),
          front: String.t(),
          tags: [String.t()],
          source: String.t() | nil,
          box: non_neg_integer(),
          due_at: DateTime.t(),
          reviews: non_neg_integer(),
          lapses: non_neg_integer(),
          removed_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc "A tag with how many cards hold it and how many of those are due."
  @type tag :: %{name: String.t(), cards: non_neg_integer(), due: non_neg_integer()}

  @typedoc """
  Sent to subscribers when a card changes, naming it, `:all` when every card
  was replaced at once, as by an import, or `:settings`.
  """
  @type message :: {:flashcards_changed, String.t() | :all | :settings}

  @doc "Starts the library for one unlocked identity."
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, opts, name: Store.via(__MODULE__, username))
  end

  @doc "Subscribes the caller to the `t:message/0`s of changes made by others."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MWTClient.PubSub, topic(username))

  @doc "Summaries of the cards in `scope`, the newest written first."
  @spec list(String.t(), scope()) :: [summary()]
  def list(username, scope \\ %{}) do
    username
    |> in_scope(scope, DateTime.utc_now(), Map.get(scope, :query, ""))
    |> Enum.map(&summary/1)
  end

  @doc "One card."
  @spec get(String.t(), String.t()) :: {:ok, Card.t()} | :error
  def get(username, id) do
    case cards(username, @full, "WHERE id = ?", [id]) do
      [card] -> {:ok, card}
      [] -> :error
    end
  end

  @doc "Every card, the oldest change first."
  @spec all(String.t()) :: [Card.t()]
  def all(username), do: cards(username, @full, "ORDER BY updated_at, seq", [])

  @doc """
  Writes new cards, each a map of `:front`, `:back`, `:tags` and
  `:source`, the first two required.

  All are checked first, and none is written unless all are fine; the error
  lists `{index, errors}` for each one that isn't. A card saying what a card
  already here says (`Card.same?/2`), or one earlier in the same call, is not
  written again: it comes back as `{:existing, card}`, so asking twice for
  the same cards writes them once. One that says what a card removed from
  the deck says comes back as `{:removed, card}`, and stays out.
  """
  @spec create(String.t(), [map()]) ::
          {:ok, [{:created | :existing | :removed, Card.t()}]}
          | {:error, [{non_neg_integer(), [{atom(), String.t()}]}]}
  def create(username, cards) when is_list(cards) do
    checked =
      cards
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} ->
        {index, attrs |> Map.put_new(:front, "") |> Map.put_new(:back, "") |> Card.validate()}
      end)

    case for({index, {:error, errors}} <- checked, do: {index, errors}) do
      [] -> call(username, {:create, for({_index, {:ok, attrs}} <- checked, do: attrs)})
      invalid -> {:error, invalid}
    end
  end

  @doc """
  Changes an existing card's `:front`, `:back`, `:tags` or `:source`;
  the others stay as they are. How well it is remembered is kept.

  Options: `:by`, who changes it (`t:MWTClient.Versions.by/0`, you by
  default), and `:version`, the version the change was based on. A card
  whose version is another by now is left as it is and comes back as
  `{:stale, card}`.
  """
  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, Card.t()} | {:stale, Card.t()} | :error | {:error, [{atom(), String.t()}]}
  def update(username, id, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    case Card.validate(attrs) do
      {:ok, attrs} -> call(username, {:update, id, attrs, opts})
      error -> error
    end
  end

  @doc "The versions kept of a card, the newest first."
  @spec versions(String.t(), String.t()) :: [Versions.Version.t()]
  def versions(username, id), do: username |> Versions.open(@kind) |> Versions.list(id)

  @doc """
  Makes the version numbered `number` of a card its front, back, tags and
  source again, keeping how well it is remembered. What it replaces is
  kept as a version, so a restore is undone the same way.
  """
  @spec restore_version(String.t(), String.t(), integer()) :: {:ok, Card.t()} | :error
  def restore_version(username, id, number), do: call(username, {:restore_version, id, number})

  @doc "Deletes one card for good."
  @spec delete(String.t(), String.t()) :: :ok | :error
  def delete(username, id), do: call(username, {:delete, id})

  @doc """
  Takes a card out of the deck, as not worth remembering. It is kept, out
  of sessions and lists, until it is restored or deleted. Removing a card
  removed already keeps when it first was.
  """
  @spec remove(String.t(), String.t()) :: {:ok, Card.t()} | :error
  def remove(username, id) do
    now = DateTime.utc_now()
    call(username, {:removed, id, now, now})
  end

  @doc "Puts a removed card back in the deck, as it was."
  @spec restore(String.t(), String.t()) :: {:ok, Card.t()} | :error
  def restore(username, id), do: call(username, {:removed, id, nil, DateTime.utc_now()})

  @doc "Keeps an answer to a card, moving it as `MWTClient.Flashcards.Schedule.answer/3` says."
  @spec review(String.t(), String.t(), Schedule.grade(), DateTime.t()) :: {:ok, Card.t()} | :error
  def review(username, id, grade, now \\ DateTime.utc_now()) do
    call(username, {:review, id, grade, now})
  end

  @doc """
  Every tag the cards in `scope` hold, with how many of them hold it, the
  one on most cards first. With no scope, every tag in the deck.
  """
  @spec tags(String.t(), scope()) :: [tag()]
  def tags(username, scope \\ %{}) do
    now = DateTime.utc_now()

    username
    |> in_scope(scope, now, "")
    |> Enum.flat_map(fn card -> Enum.map(card.tags, &{&1, Card.due?(card, now)}) end)
    |> Enum.group_by(fn {name, _due?} -> String.downcase(name) end)
    |> Enum.map(fn {_key, [{name, _due?} | _rest] = uses} ->
      %{name: name, cards: length(uses), due: Enum.count(uses, &elem(&1, 1))}
    end)
    |> Enum.sort_by(&{-&1.cards, String.downcase(&1.name)})
  end

  @doc "How many cards `scope` holds, and how many of them are due."
  @spec count(String.t(), scope()) :: %{cards: non_neg_integer(), due: non_neg_integer()}
  def count(username, scope) do
    now = DateTime.utc_now()
    cards = in_scope(username, scope, now, "")
    %{cards: length(cards), due: Enum.count(cards, &Card.due?(&1, now))}
  end

  @doc """
  The cards a session of `size` in `scope` asks, as `Schedule.pick/4` picks
  them, filling with cards not yet due as the settings say.
  """
  @spec pick(String.t(), scope(), pos_integer()) :: [Card.t()]
  def pick(username, scope, size) do
    now = DateTime.utc_now()

    picked =
      username
      |> in_scope(scope, now, "")
      |> Schedule.pick(size, settings(username).fill, now)
      |> Enum.map(& &1.id)

    # Picked from what a list reads; asked with everything they hold.
    full =
      username
      |> cards(@full, "WHERE id IN (SELECT value FROM json_each(?))", [Jason.encode!(picked)])
      |> Map.new(&{&1.id, &1})

    for id <- picked, {:ok, card} <- [Map.fetch(full, id)], do: card
  end

  @doc "How sessions run."
  @spec settings(String.t()) :: Settings.t()
  def settings(username) do
    case Documents.get(username, @settings) do
      # Rebuilt through the struct, for settings kept by an earlier build.
      {:ok, settings} -> struct(Settings, Map.from_struct(settings))
      :none -> %Settings{}
    end
  end

  @doc "Changes how sessions run, as `Settings.change/2` reads `attrs`."
  @spec put_settings(String.t(), map() | Settings.t()) :: {:ok, Settings.t()}
  def put_settings(username, %Settings{} = settings), do: call(username, {:settings, settings})

  def put_settings(username, attrs) when is_map(attrs) do
    call(username, {:change_settings, attrs})
  end

  @doc """
  Replaces every card with what `fun` returns when given them all, oldest
  change first. It runs in this process, so no change can land in between.
  """
  @spec rewrite(String.t(), ([Card.t()] -> [Card.t()])) :: :ok
  def rewrite(username, fun) when is_function(fun, 1) do
    GenServer.call(Store.via(__MODULE__, username), {:rewrite, fun}, :infinity)
  end

  defp call(username, request), do: GenServer.call(Store.via(__MODULE__, username), request)

  defp cards(username, columns, rest, params) do
    Storage.run(username, :library, &select(&1, columns, rest, params))
  end

  defp select(repo, columns, rest, params) do
    %{rows: rows} =
      repo.query!("SELECT #{Enum.join(columns, ", ")} FROM flashcards #{rest}", params)

    for row <- rows, do: card(Enum.zip(columns, row))
  end

  defp card(fields) do
    Enum.reduce(fields, %Card{}, fn
      {"id", id}, card -> %{card | id: id}
      {"front", front}, card -> %{card | front: front}
      {"back", back}, card -> %{card | back: back}
      {"tags", tags}, card -> %{card | tags: Values.from_strings(tags)}
      {"source", source}, card -> %{card | source: source}
      {"box", box}, card -> %{card | box: box}
      {"due_at", at}, card -> %{card | due_at: Values.from_time(at)}
      {"reviewed_at", at}, card -> %{card | reviewed_at: Values.from_time(at)}
      {"reviews", reviews}, card -> %{card | reviews: reviews}
      {"lapses", lapses}, card -> %{card | lapses: lapses}
      {"removed_at", at}, card -> %{card | removed_at: Values.from_time(at)}
      {"created_at", at}, card -> %{card | created_at: Values.from_time(at)}
      {"updated_at", at}, card -> %{card | updated_at: Values.from_time(at)}
      {"version", version}, card -> %{card | version: version}
      {"search_text", text}, card -> %{card | search_text: text}
    end)
  end

  defp fetch(repo, id) do
    case select(repo, @full, "WHERE id = ?", [id]) do
      [card] -> {:ok, card}
      [] -> :error
    end
  end

  # The cards of `scope`, read as lists read them, the newest written
  # first: removed or not, how recent and the words in SQL, the tags,
  # matched without regard to case, here.
  defp in_scope(username, scope, now, query) do
    removed = if Map.get(scope, :removed, false), do: "NOT NULL", else: "NULL"

    {since, since_params} =
      case Map.get(scope, :days) do
        nil -> {"1", []}
        days -> {"created_at >= ?", [Values.time(DateTime.add(now, -days, :day))]}
      end

    {matching, search_params} =
      Search.where("flashcards.seq", "flashcard_search", "flashcards", Search.terms(query))

    tags = Map.get(scope, :tags, [])
    match = Map.get(scope, :match, :any)

    username
    |> cards(
      @light,
      """
      WHERE removed_at IS #{removed} AND #{since} AND #{matching}
      ORDER BY created_at DESC, seq DESC
      """,
      since_params ++ search_params
    )
    |> Enum.filter(&Card.tagged?(&1, tags, match))
  end

  @impl true
  def init(opts) do
    username = Keyword.fetch!(opts, :username)
    versions = Versions.open(username, @kind)
    import_legacy(username, Keyword.fetch!(opts, :key), versions)
    {:ok, %{username: username, versions: versions}}
  end

  @impl true
  def handle_call({:create, attrs}, from, state) do
    now = DateTime.utc_now()

    write(state, from, fn repo ->
      here = repo |> select(@full, "", []) |> Map.new(&{&1.id, &1})

      # Cards earlier in the call count as in use, for both spellings and repeats.
      {results, _cards} =
        Enum.map_reduce(attrs, here, fn attrs, cards ->
          attrs = Map.update(attrs, :tags, [], &respell(&1, spellings(Map.values(cards))))

          case Enum.find(Map.values(cards), &Card.same?(&1, attrs)) do
            nil ->
              card = stored(Card.new(Map.put(attrs, :created_at, now)))
              put(repo, card)
              {{:created, card}, Map.put(cards, card.id, card)}

            %Card{removed_at: nil} = existing ->
              {{:existing, existing}, cards}

            removed ->
              {{:removed, removed}, cards}
          end
        end)

      changed =
        cond do
          not Enum.any?(results, &match?({:created, _card}, &1)) -> nil
          length(results) == 1 -> elem(hd(results), 1).id
          true -> :all
        end

      {{:ok, results}, state, changed}
    end)
  end

  def handle_call({:update, id, attrs, opts}, from, state) do
    expected = Keyword.get(opts, :version)

    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, card} ->
          attrs =
            if Map.has_key?(attrs, :tags) do
              others = select(repo, ~w(tags), "WHERE id != ?", [id])
              Map.update!(attrs, :tags, &respell(&1, spellings(others)))
            else
              attrs
            end

          # A change already made, sent again, is no change.
          if expected not in [nil, card.version] and Card.update(card, attrs) != card,
            do: {{:stale, card}, state, nil},
            else: change(repo, card, attrs, state, Keyword.get(opts, :by, :you), :edit)

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:restore_version, id, number}, from, state) do
    write(state, from, fn repo ->
      with {:ok, card} <- fetch(repo, id),
           {:ok, version} <- Versions.fetch(state.versions, id, number) do
        attrs = Map.take(version.content, [:front, :back, :tags, :source])
        change(repo, card, attrs, state, :you, :restore)
      else
        :error -> {:error, state, nil}
      end
    end)
  end

  def handle_call({:delete, id}, from, state) do
    write(state, from, fn repo ->
      case repo.query!("DELETE FROM flashcards WHERE id = ? RETURNING seq", [id]).rows do
        [] -> {:error, state, nil}
        [_deleted] -> {:ok, %{state | versions: Versions.forget(state.versions, id)}, id}
      end
    end)
  end

  def handle_call({:removed, id, removed_at, now}, from, state) do
    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, %Card{removed_at: nil} = card} when removed_at != nil ->
          put_removed(repo, card, removed_at, now, state)

        {:ok, %Card{removed_at: %DateTime{}} = card} when removed_at == nil ->
          put_removed(repo, card, nil, now, state)

        {:ok, card} ->
          {{:ok, card}, state, nil}

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:review, id, grade, now}, from, state) do
    write(state, from, fn repo ->
      case fetch(repo, id) do
        {:ok, card} ->
          card = stored(Schedule.answer(card, grade, now))
          put(repo, card)
          {{:ok, card}, state, id}

        :error ->
          {:error, state, nil}
      end
    end)
  end

  def handle_call({:change_settings, attrs}, from, state) do
    write(state, from, fn _repo ->
      keep_settings(Settings.change(settings(state.username), attrs), state)
    end)
  end

  def handle_call({:settings, settings}, from, state) do
    write(state, from, fn _repo -> keep_settings(settings, state) end)
  end

  def handle_call({:rewrite, fun}, from, state) do
    write(state, from, fn repo ->
      cards =
        repo
        |> select(@full, "ORDER BY updated_at, seq", [])
        |> fun.()
        |> Map.new(&{&1.id, stored(&1)})

      ids = Map.keys(cards)

      repo.query!("DELETE FROM flashcards WHERE id NOT IN (SELECT value FROM json_each(?))", [
        Jason.encode!(ids)
      ])

      for {_id, card} <- cards, do: put(repo, card)
      {:ok, %{state | versions: Versions.keep_only(state.versions, ids)}, :all}
    end)
  end

  # Runs `fun` in one transaction, which answers `{reply, state, changed}`,
  # and tells subscribers of what `changed`, if anything, once written.
  defp write(state, from, fun) do
    {reply, state, changed} = Storage.transaction(state.username, :library, fun)
    if changed, do: broadcast(state, from, changed)
    {:reply, reply, state}
  end

  defp keep_settings(%Settings{} = settings, state) do
    if settings == settings(state.username) do
      {{:ok, settings}, state, nil}
    else
      :ok = Documents.put(state.username, @settings, settings)
      {{:ok, settings}, state, :settings}
    end
  end

  defp change(repo, card, attrs, state, by, how) do
    case Card.update(card, attrs) do
      ^card ->
        {{:ok, card}, state, nil}

      updated ->
        before = %{
          version: card.version,
          content: Map.take(card, [:front, :back, :tags, :source]),
          saved_at: card.updated_at
        }

        state = %{state | versions: Versions.changed(state.versions, card.id, before, by, how)}
        updated = stored(%{updated | version: card.version + 1})
        put(repo, updated)
        {{:ok, updated}, state, card.id}
    end
  end

  # Removing and restoring keep the card's place in lists, which go by when
  # it was written, and its answers. It counts as changed, so an import
  # carries the removal, or the return, to another installation.
  defp put_removed(repo, card, removed_at, now, state) do
    card = stored(%{card | removed_at: removed_at, updated_at: now})
    put(repo, card)
    {{:ok, card}, state, card.id}
  end

  defp put(repo, %Card{} = card) do
    repo.query!(
      """
      INSERT INTO flashcards (id, front, tags, source, box, due_at, reviewed_at, reviews, lapses,
                              removed_at, created_at, updated_at, version, back, search_text)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET
        front = excluded.front, tags = excluded.tags, source = excluded.source,
        box = excluded.box, due_at = excluded.due_at, reviewed_at = excluded.reviewed_at,
        reviews = excluded.reviews, lapses = excluded.lapses, removed_at = excluded.removed_at,
        created_at = excluded.created_at, updated_at = excluded.updated_at,
        version = excluded.version, back = excluded.back, search_text = excluded.search_text
      """,
      [
        card.id,
        card.front,
        Values.strings(card.tags),
        card.source,
        card.box,
        Values.time(card.due_at),
        Values.time(card.reviewed_at),
        card.reviews,
        card.lapses,
        Values.time(card.removed_at),
        Values.time(card.created_at),
        Values.time(card.updated_at),
        card.version,
        card.back,
        card.search_text
      ]
    )

    :ok
  end

  # As a read gives it back, so what a write answers is what a read will.
  defp stored(%Card{} = card) do
    %{
      card
      | due_at: Values.stored_time(card.due_at),
        reviewed_at: Values.stored_time(card.reviewed_at),
        removed_at: Values.stored_time(card.removed_at),
        created_at: Values.stored_time(card.created_at),
        updated_at: Values.stored_time(card.updated_at)
    }
  end

  defp summary(card) do
    Map.take(card, [
      :id,
      :front,
      :tags,
      :source,
      :box,
      :due_at,
      :reviews,
      :lapses,
      :removed_at,
      :created_at,
      :updated_at
    ])
  end

  # The spelling each tag in use has, by its lowercase form.
  defp spellings(cards) do
    for card <- cards, tag <- card.tags, into: %{} do
      {String.downcase(tag), tag}
    end
  end

  defp respell(tags, spellings) do
    tags
    |> Enum.map(&Map.get(spellings, String.downcase(&1), &1))
    |> Enum.uniq_by(&String.downcase/1)
  end

  # Everyone but the caller, who has the answer to its own call already.
  defp broadcast(state, {caller, _tag}, id) do
    Phoenix.PubSub.broadcast_from(
      MWTClient.PubSub,
      caller,
      topic(state.username),
      {:flashcards_changed, id}
    )
  end

  defp topic(username), do: "flashcards:" <> Accounts.id(username)

  # The cards and settings kept in `flashcards.bin` before `library.db`,
  # with the cards' versions, in one transaction. A card already here is
  # kept as it is, as is its history, and so are settings already here,
  # so an import cut short is safe to make again.
  defp import_legacy(username, key, versions) do
    case Legacy.read(username, @legacy_file, key, :flashcards) do
      {:ok, %{cards: cards, settings: settings}} when is_list(cards) ->
        Storage.transaction(username, :library, fn repo ->
          {imported, failed} =
            Legacy.each_record(repo, cards, fn card ->
              card = stored(upgrade(card))
              if insert_new(repo, card), do: {:ok, card.id}, else: :skip
            end)

          Legacy.keep_failed(username, @legacy_file, key, failed, :flashcards)
          Versions.import_legacy(versions, key, imported)

          if Documents.get(username, @settings) == :none,
            do: :ok = Documents.put(username, @settings, settings)
        end)

        Legacy.retire(username, @legacy_file)

      {:ok, _other} ->
        Legacy.set_aside(username, @legacy_file, :flashcards)

      :none ->
        :ok
    end

    Legacy.retire(username, Versions.legacy_dir(@kind))
  end

  defp insert_new(repo, card) do
    case repo.query!("SELECT 1 FROM flashcards WHERE id = ?", [card.id]).rows do
      [] -> put(repo, card) == :ok
      [_here] -> false
    end
  end

  # Rebuilt through the struct, so a card kept by a build whose struct had
  # fewer fields comes back with this build's defaults for the ones it lacks.
  defp upgrade(card), do: Card.with_search_text(struct(Card, Map.from_struct(card)))
end
