defmodule MWTClient.Sandbox.Approval do
  @moduledoc """
  Something that waits for your decision, or until it gives up. Four types:

    * **activation** (`kind: :activation`) - an agent in the VM asks for a
      grant to be turned on (`grant_id`), or for access no grant gives yet
      (`need`). `minutes` is how long it asked for, `reason` its own words.
    * **use** - a request carrying a grant's placeholder (`kind: :request`),
      held by the proxy, or a connection through a network grant
      (`kind: :connection`).
    * **command** (`kind: :command`) - an agent asks to run `script` on the
      host, in `dir`, for at most `timeout` seconds. It waits twice when you
      choose to see the output first: for your go-ahead (`stage: :run`), and
      once it ran, for you to release the output (`stage: :output`). `run`
      holds how the run went (`t:run/0`). `script_from` says whose text it
      is: the agent's, through Ask to run commands, or the grant's, a saved command.
      Through Ask to run commands, `suggest_save` is the name the agent suggests
      saving it under and `save_for` what it would be for, in words for any
      time it runs (the `reason` is for this run), and `saved_as` the saved
      command that runs the same text, once you saved it or when one
      already did. A call of a subgrant by id carries `values`: one for
      each of its parameters, checked, in their order; the script reads
      them as environment variables.

    * **tool** (`kind: :tool`) - an agent in the VM calls one of MWT's own
      tools through a grant that asks (`MWTClient.Sandbox.MwtTools`):
      changing a note, a diagram or a flash card, or, past the hour's
      limit, adding one. `tool` says what (`t:tool/0`); `applied`, once
      allowed, how the change went, for `mwt wait`. A use like requests,
      it is let through by allowances: *Allow similar* covers changes to
      the same item.

  A call of a request subgrant is a command approval too, with `call`: the
  request MWT sends with its token grant's value, built from your template
  and the agent's values (`MWTClient.Sandbox.SavedRequest`), shown in full
  as text in `script`. Its run's `status` is the answer's HTTP status.

  A command is carried out only as it was asked. `definition` is a digest
  of its grant's definition then (`Grant.definition/1`), and `confine` how
  a saved command runs, as its card says: `%{confined: _, with: _,
  writes_dir: _}`, nil for one that runs as you. A run checks the grant
  still allows it, under the same definition, before anything runs
  (`MWTClient.Sandbox.Server.HostRuns.still/2`); a card whose grant
  changed meanwhile is refused (`decision: :changed`), never run with the
  old script under the new grant.

  An activation with a `proposal` is an agent proposing a subgrant: the
  grant it would sit under (`parent`), its `name`, what it is for
  (`purpose`), its `params`, and what it does: for a command (`kind:
  :command`) the `script`, the folder (`dir`) and the `hints` MWT worked
  out; for a request (`kind: :request`) its `method`, `url`, `headers` and
  `body`. Saving it answers the ask.

  `agent` and `thread` say who asked (`t:thread/0`), as the asking process
  told it: claims, so they help you tell asks apart and prove nothing.

  `facts` are what MWT worked out itself. `claims` are text the agent wrote,
  such as commit messages; they are shown apart and never taken as facts.
  `hints` (commands only) are what MWT guessed from a command's text, shown
  as hints. `pattern` is what "allow similar" would let through. `join` is
  what a second ask must share to wait on this approval instead of getting
  one of its own: for a request, a digest of everything MWT read of it
  (every header and the body included); for a call of MWT's tools, of the
  whole call; so only a retry of the very same use joins (`digest/1`).
  `request` is the request exactly as MWT received it, kept in memory
  only, for the full view and copying (`MWTClient.Sandbox.RequestView`).
  """

  alias MWTClient.Sandbox.EventDetails

  @enforce_keys [:id, :kind, :title, :requested_at, :deadline]
  defstruct [
    :id,
    :kind,
    :grant_id,
    :title,
    :method,
    :host,
    :path,
    :pattern,
    :join,
    :request,
    :agent,
    :thread,
    :minutes,
    :need,
    :reason,
    :script,
    :dir,
    :timeout,
    :run,
    :suggest_save,
    :save_for,
    :saved_as,
    :proposal,
    :call,
    :tool,
    :applied,
    :requested_at,
    :deadline,
    :decided_at,
    :decision,
    :host_entry,
    :definition,
    :confine,
    stage: :run,
    script_from: :agent,
    values: [],
    facts: [],
    claims: [],
    hints: [],
    retries: 0,
    status: :waiting
  ]

  @type kind :: :activation | :request | :connection | :command | :tool

  @typedoc """
  A call of one of MWT's tools that waits for you: which `tool`, the
  `kind` of item, its `id` and `title`, and for a change its content
  `from` what it is to what it would be (dropped once decided, to keep the
  history small), with `words` saying what changes.
  """
  @type tool :: %{
          tool: String.t(),
          kind: :note | :diagram | :card | :http | nil,
          id: String.t() | nil,
          title: String.t() | nil,
          from: map() | nil,
          to: map() | nil,
          words: String.t() | nil
        }
  @type status :: :waiting | :allowed | :denied | :timed_out

  @typedoc "How long an allowance or a grant lasts: minutes, or while the grant stays on."
  @type duration :: pos_integer() | :grant | :until_off

  @typedoc "Where a command's output goes when it ends: back to the agent, or to you first."
  @type output :: :send | :review

  @type decision ::
          :allow_once
          | {:allow, :similar | :all, pos_integer() | :grant}
          | :deny
          | :deny_and_turn_off
          | {:turn_on, pos_integer() | :until_off, :ask | :all}
          | {:set_up, String.t()}
          | :decline
          | :simpler
          | :grant_off
          | :changed
          | :isolated
          | {:run, output()}
          | :auto
          | :send_output
          | :keep_output

  @typedoc """
  The agent thread an ask came from: its `title` (as the agent shows it),
  its `id`, and the `folder` the agent works in. Any of them may be nil.
  """
  @type thread :: %{
          title: String.t() | nil,
          id: String.t() | nil,
          folder: String.t() | nil
        }

  @type request :: %{
          host: String.t(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @typedoc """
  A command's run: `:running` until it ends, then `:done` with its `exit`
  status and `output` (the first and last 32 KiB; `cut` bytes between them
  were dropped). `stopped` is set when you stopped it, `timed_out` when it
  hit its limit. `output_to` is where the output goes.
  """
  @type run :: %{
          state: :running | :done,
          output_to: output(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          exit: integer() | nil,
          output: binary(),
          bytes: non_neg_integer(),
          cut: non_neg_integer(),
          stopped: boolean(),
          timed_out: boolean(),
          error: String.t() | nil
        }

  @typedoc "A subgrant as an agent proposes it."
  @type proposal :: %{
          kind: :command | :request,
          parent: String.t(),
          parent_name: String.t(),
          name: String.t(),
          purpose: String.t(),
          script: String.t() | nil,
          dir: String.t() | nil,
          method: String.t() | nil,
          url: String.t() | nil,
          headers: [{String.t(), String.t()}] | nil,
          body: String.t() | nil,
          params: [MWTClient.Sandbox.Param.t()],
          hints: [String.t()]
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          grant_id: String.t() | nil,
          title: String.t(),
          method: String.t() | nil,
          host: String.t() | nil,
          path: String.t() | nil,
          pattern: String.t() | nil,
          request: request() | nil,
          agent: String.t() | nil,
          thread: thread() | nil,
          minutes: pos_integer() | nil,
          need: String.t() | nil,
          reason: String.t() | nil,
          script: String.t() | nil,
          dir: String.t() | nil,
          timeout: pos_integer() | nil,
          run: run() | nil,
          suggest_save: String.t() | nil,
          save_for: String.t() | nil,
          saved_as: String.t() | nil,
          proposal: proposal() | nil,
          call: MWTClient.Sandbox.SavedRequest.call() | nil,
          definition: binary() | nil,
          confine: %{confined: boolean(), with: [String.t()], writes_dir: boolean()} | nil,
          tool: tool() | nil,
          applied: {:ok | :error, String.t()} | nil,
          values: [{String.t(), String.t()}],
          script_from: :agent | :grant,
          stage: :run | :output,
          requested_at: DateTime.t(),
          deadline: DateTime.t(),
          decided_at: DateTime.t() | nil,
          decision: decision() | nil,
          facts: [{String.t(), String.t()}],
          claims: [{String.t(), String.t()}],
          hints: [String.t()],
          retries: non_neg_integer(),
          status: status()
        }

  @doc """
  The thread an ask names (`:thread`, `:thread_id`, `:folder`), trimmed and
  cut to size, or nil when it names none.
  """
  @spec thread(map()) :: thread() | nil
  def thread(ask) do
    thread = %{
      title: claim(ask, :thread, 200),
      id: claim(ask, :thread_id, 80),
      folder: claim(ask, :folder, 1_000)
    }

    if Enum.all?(Map.values(thread), &is_nil/1), do: nil, else: thread
  end

  @doc """
  Where an ask came from, in a line: the thread's title (or the start of its
  id) and its folder, with your home folder as `~`. Nil when it named none.
  """
  @spec asked_from(t(), String.t() | nil) :: String.t() | nil
  def asked_from(approval, home \\ System.user_home())

  def asked_from(%__MODULE__{thread: %{} = thread}, home) do
    name =
      cond do
        thread.title -> "“#{thread.title}”"
        thread.id -> "thread #{String.slice(thread.id, 0, 8)}"
        true -> nil
      end

    folder = thread.folder && "in " <> short_folder(thread.folder, home)
    [name, folder] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  def asked_from(%__MODULE__{}, _home), do: nil

  @doc "`folder` with `home` written as `~`."
  @spec short_folder(String.t(), String.t() | nil) :: String.t()
  def short_folder(folder, home \\ System.user_home())

  def short_folder(folder, home) when is_binary(home) and home not in ["", "/"] do
    cond do
      folder == home -> "~"
      String.starts_with?(folder, home <> "/") -> "~" <> String.replace_prefix(folder, home, "")
      true -> folder
    end
  end

  def short_folder(folder, _home), do: folder

  defp claim(ask, key, limit) do
    case Map.get(ask, key) do
      text when is_binary(text) ->
        text
        |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
        |> MWTClient.Sandbox.Shown.text()
        |> String.trim()
        |> String.slice(0, limit)
        |> case do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  @doc """
  A SHA-256 digest of a term, the same for equal terms (maps included).
  Asks join a waiting approval on it, so it must hold only for the very
  same ask: the VM chooses what goes in, and a short hash
  (`:erlang.phash2/1` has 27 bits) lets it find two different asks that
  share one in milliseconds.
  """
  @spec digest(term()) :: binary()
  def digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  @doc "`digest/1` as text, for patterns."
  @spec digest_text(term()) :: String.t()
  def digest_text(term), do: term |> digest() |> Base.encode16(case: :lower)

  @doc """
  Whether this is a use of a grant (a request, a connection, or a call of
  MWT's tools) rather than an ask.
  """
  @spec use?(t()) :: boolean()
  def use?(%__MODULE__{kind: kind}), do: kind in [:request, :connection, :tool]

  @doc "Whether this is a command still running on the host."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{kind: :command, run: %{state: :running}}), do: true
  def running?(%__MODULE__{}), do: false

  @doc """
  Whether the agent that asked has its final answer. For a command that ran,
  that is once its output may go back, or was kept; for everything else,
  once you decided or it gave up.
  """
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{status: :waiting}), do: false

  def final?(%__MODULE__{kind: :command, status: :allowed, run: %{state: :running}}),
    do: false

  def final?(%__MODULE__{}), do: true
  ## Details

  @doc """
  What an event about this approval says when its line opens
  (`MWTClient.Sandbox.EventDetails`): what was asked and how it was
  decided (`how`, in words), the command and how it ran, the tool call or
  the subgrant proposed, what MWT worked out, and apart, what the agent
  wrote. Never a command's output: only its size and what was found in it.
  """
  @spec details(t(), String.t() | nil) :: MWTClient.Sandbox.EventDetails.t()
  def details(%__MODULE__{} = approval, how) do
    EventDetails.safely("an approval", fn ->
      EventDetails.new([
        ask_section(approval, how),
        command_section(approval),
        run_section(approval.run),
        tool_section(approval.tool),
        proposal_section(approval.proposal),
        EventDetails.section("What MWT worked out", shown_facts(approval.facts || [])),
        agent_section(approval)
      ])
    end)
  end

  defp ask_section(approval, how) do
    EventDetails.section("The ask", [
      {"Kind", kind_words(approval)},
      {"What", approval.title},
      {"Request", request_line(approval)},
      {"Access asked for", approval.need},
      {"For how long", approval.minutes && "#{approval.minutes} min"},
      {"Allow similar covers", approval.pattern},
      {"Asked at", time_words(approval.requested_at)},
      {"Waited", waited_words(approval)},
      {"Decided", how}
    ])
  end

  defp kind_words(%{kind: :activation, proposal: %{}}), do: "A subgrant proposed"
  defp kind_words(%{kind: :activation}), do: "A grant to turn on, or access to set up"
  defp kind_words(%{kind: :request}), do: "A request carrying a grant's placeholder"
  defp kind_words(%{kind: :connection}), do: "A connection through a network grant"
  defp kind_words(%{kind: :tool}), do: "A call of MWT's tools"
  defp kind_words(%{kind: :command, call: %{}}), do: "A request subgrant, sent by MWT"
  defp kind_words(%{kind: :command}), do: "A command on your machine"

  defp request_line(%{kind: kind, method: method, host: host, path: path})
       when kind in [:request, :connection] and is_binary(host),
       do: Enum.join(Enum.reject([method, host <> (path || "")], &is_nil/1), " ")

  defp request_line(_approval), do: nil

  defp command_section(%{kind: :command} = approval) do
    EventDetails.section(if(approval.call, do: "Request", else: "Command"), [
      {if(approval.call, do: "As sent", else: "Script"), {:code, approval.script}},
      {"Folder", approval.dir},
      {"Time limit", approval.timeout && "#{approval.timeout} s"},
      {"Whose text",
       if(approval.script_from == :grant,
         do: "a saved command of the grant",
         else: "the agent's, through Ask to run commands"
       )},
      {"Saved command", approval.saved_as},
      {"Values",
       {:list, Enum.map(approval.values || [], fn {name, value} -> "#{name}=#{value}" end)}},
      {"What MWT guessed", {:list, approval.hints || []}}
    ])
  end

  defp command_section(_approval), do: nil

  defp run_section(nil), do: nil

  # A run as it was kept, older ones with fewer of its keys.
  defp run_section(run) do
    started = Map.get(run, :started_at)
    finished = Map.get(run, :finished_at)
    findings = Map.get(run, :findings) || []
    cut = Map.get(run, :cut) || 0

    EventDetails.section("How it ran", [
      {"Started", time_words(started)},
      {"Ended", time_words(finished)},
      {"Took", started && finished && "#{DateTime.diff(finished, started, :second)} s"},
      {"Exit", Map.get(run, :exit)},
      {"HTTP status", Map.get(run, :status)},
      {"Output",
       Map.get(run, :state) == :done &&
         "#{Map.get(run, :bytes) || 0} bytes" <> if(cut > 0, do: ", #{cut} not kept", else: "")},
      {"Output goes to", output_words(Map.get(run, :output_to))},
      {"Stopped", Map.get(run, :stopped) && "by you"},
      {"Time limit", Map.get(run, :timed_out) && "hit"},
      {"Couldn't start", Map.get(run, :error)},
      {"Found in its output", {:list, Enum.map(findings, &MWTClient.Sandbox.Inbound.words/1)}}
    ])
  end

  defp output_words(:send), do: "the agent"
  defp output_words(:review), do: "you, before the agent"
  defp output_words(_other), do: nil

  defp tool_section(nil), do: nil

  defp tool_section(tool) do
    kind = Map.get(tool, :kind)

    EventDetails.section("MWT tool", [
      {"Tool", Map.get(tool, :tool)},
      {"Item", is_atom(kind) && kind && Atom.to_string(kind)},
      {"Title", Map.get(tool, :title)},
      {"Item id", Map.get(tool, :id)},
      {"What changes", Map.get(tool, :words)}
    ])
  end

  defp proposal_section(nil), do: nil

  # Decided, a proposal keeps only a few of its keys (`settle/3`).
  defp proposal_section(proposal) do
    get = &Map.get(proposal, &1)

    EventDetails.section("Subgrant proposed", [
      {"Name", get.(:name)},
      {"Under", get.(:parent_name)},
      {"For", get.(:purpose)},
      {"Script", {:code, get.(:script)}},
      {"Folder", get.(:dir)},
      {"Request", Enum.join(Enum.reject([get.(:method), get.(:url)], &is_nil/1), " ")},
      {"Headers", {:list, Enum.map(get.(:headers) || [], fn {name, _value} -> name end)}},
      {"Body", {:code, get.(:body)}},
      {"Parameters", {:list, Enum.map(get.(:params) || [], & &1.name)}},
      {"What MWT guessed", {:list, get.(:hints) || []}}
    ])
  end

  # The facts the ask's own rows already say are left out.
  defp shown_facts(facts),
    do: Enum.reject(facts, fn {label, _value} -> label in ["Grant", "Script", "Request"] end)

  defp agent_section(approval) do
    thread = approval.thread || %{}

    EventDetails.agent(
      "In the agent's words",
      [
        {"Agent", approval.agent},
        {"Why", approval.reason},
        {"Thread", Map.get(thread, :title)},
        {"Working in", Map.get(thread, :folder)},
        {"Would save it as", approval.suggest_save},
        {"Saved, it would be for", approval.save_for}
      ] ++ (approval.claims || [])
    )
  end

  defp waited_words(%{requested_at: asked} = approval) do
    seconds = DateTime.diff(approval.decided_at || DateTime.utc_now(), asked, :second)
    if seconds < 120, do: "#{seconds} s", else: "#{div(seconds, 60)} min"
  end

  defp time_words(nil), do: nil
  defp time_words(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
end
