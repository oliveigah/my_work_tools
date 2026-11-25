defmodule MWTClient.Sandbox.Event do
  @moduledoc """
  One line of the activity log. It never holds a real credential value.

  `outcome` says what happened:

    * `:tunnel` - passed through as bytes, unread
    * `:read` - a request MWT read, which went out as the VM sent it: no
      credential in it, nothing to ask
    * `:read_failed` - a connection that failed for MWT reading it: the
      VM's client refused MWT's certificate, so nothing went out. You can
      list the host among those MWT doesn't read
      (`MWTClient.Sandbox.Firewall.add_unread/2`)
    * `:lookup` - a name the VM looked up (`MWTClient.Sandbox.Dns`)
    * `:swapped` - a placeholder was swapped for the real value
    * `:allowed`, `:denied`, `:timed_out` - an approval was decided or gave up
    * `:refused` - a placeholder arrived while its grant was off
    * `:blocked` - a destination MWT always refuses, or a network grant is off
    * `:violation` - a placeholder headed for a host its grant does not list
    * `:grant` - a grant was turned on or off
    * `:vm` - the VM started, stopped or was recreated
    * `:command` - a command an agent asked to run on the host: run,
      declined, stopped, ended, its output sent or kept. Never its output.
    * `:call` - a call of a request action: asked, sent through MWT's
      proxy, answered. The request it sent has a line of its own.
    * `:project` - a repository became a project or stopped being one, its
      settings changed, or its mirror kept stray edits or failed
    * `:handoff` - an agent handed work off or updated it, or you accepted
      it, saved it as a branch, sent it back, closed or reopened it
    * `:tool` - an agent in the VM used one of MWT's tools: read, added or
      changed a note, a diagram, a flash card or an HTTP request
    * `:firewall` - MWT's firewall found something (`MWTClient.Sandbox.Firewall`),
      isolated the VM, was released, or its settings changed
    * `:lost` - events the journal couldn't keep, how many and from when
      to when: a row it writes itself (`MWTClient.Storage.Journal`)

  `agent`, `thread_id` and `thread` (its title) say who asked, as the
  agent claimed it, for what came from one: an ask, a tool call, a host
  command, a handoff. Nil for traffic, which no thread signs.

  `exchange_id` ties the events of a request MWT read to what it carried
  and what came back (`MWTClient.Sandbox.Exchange`), kept apart in the
  journal; `exchange` holds it once a page has read it, and is never
  written with the event.

  `details` is what the event says when its line opens
  (`MWTClient.Sandbox.EventDetails`): given when it is logged, kept apart
  in the journal like an exchange, and read back only when a page opens
  the line. `detailed?` says it has some, so a page knows to read them;
  read back from the journal, `details` is nil until then.

  Events are kept in the identity's `journal.db` (`row/1`,
  `MWTClient.Storage.Journal`) and read back by
  `MWTClient.Sandbox.Activity`.
  """

  alias MWTClient.Sandbox.EventDetails
  alias MWTClient.Storage.Values

  @enforce_keys [:id, :at, :outcome, :summary]
  defstruct [
    :id,
    :at,
    :outcome,
    :summary,
    :grant_id,
    :host,
    :port,
    :method,
    :path,
    :up,
    :down,
    :ms,
    :agent,
    :thread_id,
    :thread,
    :exchange_id,
    :exchange,
    :details,
    :decision,
    detailed?: false
  ]

  @type outcome ::
          :tunnel
          | :read
          | :read_failed
          | :lookup
          | :swapped
          | :allowed
          | :denied
          | :timed_out
          | :refused
          | :blocked
          | :violation
          | :grant
          | :vm
          | :command
          | :call
          | :project
          | :handoff
          | :tool
          | :firewall
          | :lost

  @type t :: %__MODULE__{
          id: String.t(),
          at: DateTime.t(),
          outcome: outcome(),
          summary: String.t(),
          grant_id: String.t() | nil,
          host: String.t() | nil,
          port: non_neg_integer() | nil,
          method: String.t() | nil,
          path: String.t() | nil,
          up: non_neg_integer() | nil,
          down: non_neg_integer() | nil,
          ms: non_neg_integer() | nil,
          agent: String.t() | nil,
          thread_id: String.t() | nil,
          thread: String.t() | nil,
          exchange_id: String.t() | nil,
          exchange: MWTClient.Sandbox.Exchange.t() | :none | nil,
          decision: MWTClient.Sandbox.Decision.t() | nil,
          details: MWTClient.Sandbox.EventDetails.t() | nil,
          detailed?: boolean()
        }

  @outcomes ~w(tunnel read read_failed lookup swapped allowed denied timed_out refused blocked violation grant vm
               command call project handoff tool firewall lost)a

  @groups %{
    "traffic" => [:read, :tunnel],
    "credentials" => [:swapped, :allowed, :denied, :timed_out, :refused, :call],
    "blocked" => [:blocked, :violation, :read_failed],
    "lookups" => [:lookup],
    "changes" => [:grant, :vm, :project, :handoff, :tool],
    "commands" => [:command],
    "firewall" => [:firewall]
  }

  @doc """
  Who asked, as an event's attributes: an agent's name and the thread it
  claimed (`t:MWTClient.Sandbox.Approval.thread/0`), either nil.
  """
  @spec asked_by(String.t() | nil, map() | nil) :: map()
  def asked_by(agent, thread) do
    %{
      agent: agent,
      thread_id: thread && Map.get(thread, :id),
      thread: thread && Map.get(thread, :title)
    }
  end

  @doc "A fresh event id: random, so no two are alike across restarts, safe in a DOM id."
  @spec new_id() :: String.t()
  def new_id, do: "event-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc """
  What the log's word filter looks in: the summary, host, path and method,
  and the start of the details (`MWTClient.Sandbox.EventDetails.search_text/1`),
  lowercased.
  """
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{} = event) do
    [event.summary, event.host, event.path, event.method]
    |> Enum.join(" ")
    |> String.downcase()
    |> then(&Enum.join([&1, EventDetails.search_text(event.details)], " "))
    |> String.trim_trailing()
  end

  @doc "The details to keep with the event: none when it has nothing to say."
  @spec details(t()) :: EventDetails.t() | nil
  def details(%__MODULE__{details: [_ | _] = details}), do: details
  def details(%__MODULE__{}), do: nil

  @doc "The event as a row of the journal (`MWTClient.Storage.Journal.record/2`)."
  @spec row(t()) :: MWTClient.Storage.Journal.row()
  def row(%__MODULE__{} = event) do
    %{
      id: event.id,
      at: Values.time(event.at),
      outcome: Atom.to_string(event.outcome),
      summary: event.summary,
      grant_id: event.grant_id,
      host: event.host,
      port: event.port,
      method: event.method,
      path: event.path,
      up: event.up,
      down: event.down,
      ms: event.ms,
      agent: event.agent,
      thread_id: event.thread_id,
      thread: event.thread,
      exchange_id: event.exchange_id,
      detailed: if(details(event), do: 1, else: 0),
      search_text: search_text(event),
      decided_by: event.decision && Atom.to_string(event.decision.by),
      card_id: event.decision && event.decision[:card],
      decision: event.decision && Values.term(event.decision)
    }
  end

  @doc "The columns `from_row/1` reads, in its order."
  @spec columns() :: [String.t()]
  def columns,
    do: ~w(id at outcome summary grant_id host port method path up down ms agent thread_id thread
         exchange_id detailed decision)

  @doc "An event read back from the journal, its columns as `columns/0` lists them."
  @spec from_row(list()) :: t()
  def from_row(
        [id, at, outcome, summary, grant_id, host, port, method, path, up, down, ms] ++
          [agent, thread_id, thread, exchange_id, detailed, decision]
      ) do
    %__MODULE__{
      id: id,
      at: Values.from_time(at),
      outcome: outcome(outcome),
      summary: summary,
      grant_id: grant_id,
      host: host,
      port: port,
      method: method,
      path: path,
      up: up,
      down: down,
      ms: ms,
      agent: agent,
      thread_id: thread_id,
      thread: thread,
      exchange_id: exchange_id,
      detailed?: detailed == 1,
      decision: decision && Values.from_term(decision)
    }
  end

  @doc """
  The outcome a journal row names. Only the outcomes this build knows: a
  newer build's comes back as a change of a grant, rather than as an atom
  made from what was read.
  """
  @spec outcome(String.t()) :: outcome()
  def outcome(name), do: Enum.find(@outcomes, :grant, &(Atom.to_string(&1) == name))

  @doc "The filter groups the activity page offers, and the outcomes in each."
  @spec groups() :: %{String.t() => [outcome()]}
  def groups, do: @groups

  @doc """
  Whether `event` passes the activity filters: `:group` (a key of `groups/0`,
  or `"all"`), `:grant` (an id, or `""`), `:thread` (an id, or `""`) and
  `:q` (words to look for).
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = event, filters) do
    outcomes = Map.get(@groups, Map.get(filters, :group, "all"))
    grant = Map.get(filters, :grant, "")
    thread = Map.get(filters, :thread, "")
    term = filters |> Map.get(:q, "") |> String.trim() |> String.downcase()

    (is_nil(outcomes) or event.outcome in outcomes) and
      (grant == "" or event.grant_id == grant) and
      (thread == "" or event.thread_id == thread) and
      (term == "" or String.contains?(search_text(event), term))
  end
end
