defmodule MWTClient.Sandbox.MwtTools do
  @moduledoc """
  MWT's own tools (`MWTClient.MCP.Tools`), as agents in the VM reach them:
  through `mwt mcp`, an MCP server on stdio that carries each message over
  the agent channel (`MWTClient.Sandbox.Channel`). Nothing in the VM holds
  a token for them: being in the VM is all a call proves, and three
  built-in grants decide it (`MWTClient.Sandbox.Grant.mwt_tools/0`):

    * `mwt-read` - `list_*` and `get_*`; enabled on startup, auto-approved;
    * `mwt-create` - `create_*` and `import_http_request`; enabled on startup, auto-approved.
      From the VM, past 200 items or 50 MB added in an hour, each one
      asks, whatever the allowances, so an agent in a loop can't fill the
      disk;
    * `mwt-change` - `update_*`, on an item of yours or an agent's; enabled
      on startup, asking each time. Its card shows the change as a diff, and
      *Allow similar* covers changes to the same item.

  A call that asks waits up to 50 seconds for you, under Codex's default
  limit of 60 for a tool call. Then the agent hears it is still waiting,
  with the ask's id: allowed later, the change is still made here, as it
  was sent (and refused if the item changed meanwhile), and `mwt wait ID`
  tells the agent how it went.
  """

  alias MWTClient.MCP.Caller
  alias MWTClient.Sandbox.{Approval, Server}

  @wait_ms 50_000
  @hold_seconds 30 * 60
  @create_items 200
  @create_bytes 50 * 1024 * 1024

  @typedoc """
  A call as the gate sees it: which grant it needs (`:read`, `:create`,
  `:change`), the `tool`, the `kind` of item, its `id` and `title`, for a
  change its content `from` and `to`, for an addition its size in
  `bytes`, the `args` it was called with, and `apply`, which makes it:
  run when it is allowed after the agent stopped waiting. A call joins one
  already waiting only when all of it is the same, its arguments and
  claims included: one decision lets each joined call make its own change,
  so each must be the change the card shows.
  """
  @type use :: %{
          required(:grant) =>
            :read
            | :create
            | :change
            | :git_fetch
            | :git_fetch_remote
            | :git_handoff
            | :share_sync,
          required(:tool) => String.t(),
          optional(:kind) => :note | :diagram | :card | :http | nil,
          optional(:id) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:from) => map() | nil,
          optional(:to) => map() | nil,
          optional(:bytes) => non_neg_integer(),
          optional(:args) => map(),
          optional(:apply) => (-> term()),
          optional(:claims) => map()
        }

  @doc "How long a call that asks waits for you before it gives up."
  def hold_seconds, do: @hold_seconds

  @doc "What agents in the VM may add in an hour before each addition asks."
  def create_limit, do: %{items: @create_items, bytes: @create_bytes}

  @doc """
  The caller for an agent in the VM, with what it claimed about itself
  (`agent`, `thread`, `thread_id`, `folder`). `wait_ms` is how long a call
  that asks waits for you before the agent hears it is still waiting.
  """
  @spec caller(String.t(), map(), keyword()) :: Caller.t()
  def caller(username, claims, opts \\ []) do
    wait_ms = Keyword.get(opts, :wait_ms, @wait_ms)

    %Caller{
      username: username,
      base_url: base_url(),
      from: :vm,
      claims: claims,
      gate: &authorize(username, Map.put(&1, :claims, claims), wait_ms)
    }
  end

  @doc "Where MWT opens on this machine, for the links tools return."
  def base_url, do: MWTClientWeb.Endpoint.url()

  @doc """
  Decides one call from the VM by its grant: `:ok` to go ahead, or what
  the agent hears instead.
  """
  @spec authorize(String.t(), use(), pos_integer()) :: :ok | {:error, String.t()}
  def authorize(username, use, wait_ms \\ @wait_ms) do
    case Server.call(username, {:tool, Map.delete(use, :apply)}) do
      :ok -> :ok
      {:error, message} -> {:error, message}
      {:ask, id} -> wait(username, id, use, wait_ms)
    end
  end

  defp wait(username, id, use, wait_ms) do
    apply = use[:apply]

    case Server.call(username, {:await, id, wait_ms}, wait_ms + 5_000) do
      {:ok, %Approval{status: :allowed}, _grant} ->
        :ok

      {:ok, %Approval{status: :timed_out}, _grant} ->
        {:error, "The user didn't answer in time. Nothing changed."}

      {:ok, %Approval{}, _grant} ->
        {:error,
         "The user declined this. Nothing changed. Don't ask again for the same thing unless they say so."}

      {:pending, _approval} when is_function(apply, 0) ->
        later(username, id, apply)

        {:error,
         "Still waiting for the user, as ask #{id}. If they allow it, MWT makes it as you sent it, " <>
           "unless the item changed meanwhile: `mwt wait #{id}` says how it went. Don't send it again."}

      {:pending, _approval} ->
        {:error,
         "Still waiting for the user, as ask #{id}. Call again once they allowed it: `mwt wait #{id}` says when."}

      {:error, :not_found} ->
        {:error, "The ask is gone. Nothing changed."}
    end
  catch
    :exit, _reason -> {:error, "MWT is locked or closing. Nothing changed."}
  end

  # Allowed after the agent stopped waiting: made here, as it was sent, and
  # how it went kept on the ask for `mwt wait`.
  defp later(username, id, apply) do
    Task.Supervisor.start_child(MWTClient.Sandbox.TaskSupervisor, fn ->
      ms = @hold_seconds * 1000

      try do
        case Server.call(username, {:await, id, ms}, ms + 5_000) do
          {:ok, %Approval{status: :allowed}, _grant} ->
            Server.cast(username, {:tool_applied, id, outcome(apply.())})

          _declined_or_gone ->
            :ok
        end
      catch
        :exit, _locked -> :ok
      end
    end)
  end

  defp outcome({:ok, %{"isError" => false, "structuredContent" => data}}),
    do: {:ok, made(data)}

  defp outcome({:ok, %{"isError" => true, "content" => [%{"text" => text} | _]}}),
    do: {:error, text}

  defp outcome(_other), do: {:error, "It could not be made."}

  defp made(%{version: version}), do: "Made: it is version #{version} now."
  defp made(_data), do: "Made."

  @doc """
  What an approval shows and an allowance matches, for a use: its `title`,
  and its `pattern`. Changes to one item are alike; so are all reads, and
  all additions.
  """
  @spec about(use()) :: %{title: String.t(), pattern: String.t()}
  def about(%{grant: :change} = use),
    do: %{
      title: "Change #{noun(use[:kind])}#{titled(use[:title])}",
      pattern: "change #{use[:kind]} #{use[:id]}"
    }

  def about(%{grant: :create} = use),
    do: %{title: "Add #{a(noun(use[:kind]))}#{titled(use[:title])}", pattern: "create"}

  def about(%{grant: :read} = use), do: %{title: "Read with #{use.tool}", pattern: "read"}

  def about(%{grant: :git_fetch} = use),
    do: %{title: "Fetch #{use[:title] || "a project"}", pattern: "git fetch"}

  def about(%{grant: :git_fetch_remote} = use),
    do: %{
      title: "Fetch #{use[:title] || "a project"}'s remote, on your machine",
      pattern: "git fetch remote"
    }

  def about(%{grant: :git_handoff} = use),
    do: %{title: "Hand off #{use[:title] || "work"}", pattern: "git handoff"}

  def about(%{grant: :share_sync} = use),
    do: %{title: "Sync #{use[:title] || "your shared folders"}", pattern: "sync"}

  @doc "What a change does, in a line, or nil."
  @spec words(use()) :: String.t() | nil
  def words(%{grant: :change, kind: :note, from: from, to: to}) do
    lines = MWTClient.Versions.Diff.lines(from.body, to.body)
    out = Enum.count(lines, &match?({:del, _}, &1))
    in_ = Enum.count(lines, &match?({:ins, _}, &1))

    [
      from.title != to.title && "title changed",
      (out > 0 or in_ > 0) && "#{in_} #{plural(in_, "line")} in, #{out} out"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  def words(%{grant: :change, kind: :diagram, from: from, to: to}) do
    [
      from.title != to.title && "title changed",
      MWTClient.Versions.Diff.elements_words(
        MWTClient.Versions.Diff.elements(from.elements, to.elements)
      )
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  def words(%{grant: :change, kind: :card, from: from, to: to}) do
    case MWTClient.Versions.Diff.fields(from, to, [:front, :back, :tags, :source]) do
      [] -> nil
      changes -> Enum.map_join(changes, ", ", fn {field, _, _} -> "#{field} changed" end)
    end
  end

  def words(%{grant: :create, bytes: bytes}), do: "#{max(div(bytes, 1024), 1)} KB"
  def words(_use), do: nil

  defp noun(:note), do: "note"
  defp noun(:diagram), do: "diagram"
  defp noun(:card), do: "flash card"
  defp noun(:cards), do: "flash cards"
  defp noun(:http), do: "HTTP sample"
  defp noun(_other), do: "item"

  defp a("flash cards"), do: "flash cards"
  defp a(noun), do: "a " <> noun

  defp titled(nil), do: ""
  defp titled(""), do: ""
  defp titled(title), do: " “#{String.slice(title, 0, 120)}”"

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
