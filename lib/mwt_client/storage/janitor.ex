defmodule MWTClient.Storage.Janitor do
  @moduledoc """
  Applies an identity's retention rules (`MWTClient.Storage.Retention`) to
  what its databases and folder hold: a minute after it unlocks, then
  every hour, and when the Storage page asks (`sweep/1`).

  Each kind is applied by the module that keeps it, in batches, so a sweep
  never holds a database for long. The pages it frees are reused by what
  is written next; Compact gives them back to the disk. The VM's rules are
  applied by the sandbox, when it takes a snapshot or builds an image.

  One process per unlocked identity, started by `MWTClient.Storage` after
  the journal's writer.
  """

  use GenServer

  require Logger

  alias MWTClient.HttpClient.Resources
  alias MWTClient.Storage.Backups
  alias MWTClient.Storage.Journal
  alias MWTClient.Storage.Legacy
  alias MWTClient.Storage.Retention
  alias MWTClient.Vault.Store
  alias MWTClient.Versions

  @first_ms 60_000
  @every_ms 3_600_000

  @doc false
  def start_link(opts) do
    username = Keyword.fetch!(opts, :username)
    GenServer.start_link(__MODULE__, username, name: Store.via(__MODULE__, username))
  end

  @doc """
  Applies every rule now, and returns how many things each kind lost, by
  its key.
  """
  @spec sweep(String.t()) :: %{String.t() => non_neg_integer()}
  def sweep(username), do: GenServer.call(Store.via(__MODULE__, username), :sweep, :infinity)

  @doc "The kinds a sweep applies: every kind but the VM's."
  @spec kinds() :: [String.t()]
  def kinds,
    do: ~w(note_versions diagram_versions flashcard_versions image_layer_versions http_history
           http_bodies agent_activity backups legacy)

  @impl true
  def init(username) do
    case every_ms() do
      nil -> :ok
      _every -> Process.send_after(self(), :sweep, @first_ms)
    end

    {:ok, %{username: username, last: nil}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    removed = sweep_now(state.username)
    {:reply, removed, %{state | last: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_now(state.username)
    if every = every_ms(), do: Process.send_after(self(), :sweep, every)
    {:noreply, %{state | last: DateTime.utc_now()}}
  end

  defp sweep_now(username) do
    now = DateTime.utc_now()
    rules = Retention.rules(username)

    Map.new(kinds(), fn key ->
      removed =
        try do
          apply_rule(username, key, Map.fetch!(rules, key), now)
        rescue
          error ->
            Logger.error("could not apply the #{key} retention rule: #{Exception.message(error)}",
              user: username,
              system: :storage
            )

            0
        end

      {key, removed}
    end)
  end

  defp apply_rule(username, "note_versions", rule, now),
    do: Versions.thin(username, "notes", rule, now)

  defp apply_rule(username, "diagram_versions", rule, now),
    do: Versions.thin(username, "diagrams", rule, now)

  defp apply_rule(username, "flashcard_versions", rule, now),
    do: Versions.thin(username, "flashcards", rule, now)

  defp apply_rule(username, "image_layer_versions", rule, now),
    do: Versions.thin(username, "image_layers", rule, now)

  defp apply_rule(username, "http_history", rule, now), do: Resources.trim(username, rule, now)

  defp apply_rule(username, "http_bodies", rule, now),
    do: Resources.drop_bodies(username, rule, now)

  defp apply_rule(username, "agent_activity", rule, now), do: Journal.trim(username, rule, now)
  defp apply_rule(username, "backups", rule, _now), do: Backups.trim(username, rule)
  defp apply_rule(username, "legacy", rule, now), do: Legacy.trim(username, rule, now)

  # Off in tests, which sweep when they mean to.
  defp every_ms do
    :mwt_client |> Application.get_env(__MODULE__, []) |> Keyword.get(:every_ms, @every_ms)
  end
end
