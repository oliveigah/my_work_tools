defmodule MWTClient.Sandbox.Grant do
  @moduledoc """
  One piece of access the VM can be given, and taken back from, on the spot.

  Three types, none tied to a provider, one for subgrants and one for
  MWT's own tools:

    * `:token` - a secret that travels in HTTP requests: an API key, a bearer
      token, git's password. `mwt exec GRANT -- COMMAND` supplies the
      placeholder in `env` variables, or the token file path in `file_env`,
      only to that command. When `git` is set, its credential helper answers
      for that selected grant's `hosts`. Ordinary VM processes receive no
      credential exports. MWT swaps the real value on requests to `hosts`,
      only in its `carriers`: the headers it travels in (`carriers/1`).
    * `:network` - reachability to `destinations`; nothing to hold. One is
      built in, the Internet (`internet/0`, `internet: true`): every public
      address, enabled on startup unless you choose otherwise. With it
      disabled, the VM reaches only what other grants list.
    * `:command` - nothing to hold: while it is on, agents may ask MWT to
      run a command on your machine. With a `script`, a saved command: only
      that text, in `dir`; its runs can be auto-approved. With none, Ask to
      run commands, the escape hatch: any text they send. Every identity
      has it, built in (`ask_to_run/0`) and off, and it always asks:
      turning it on only lets agents ask, and you approve every run.
    * `:request` - a subgrant of a token grant: one HTTP request MWT sends
      itself with that grant's real value (`method`, `url`, `headers`,
      `body`; see `MWTClient.Sandbox.SavedRequest`).
    * `:mwt` - MWT's own tools (notes, diagrams, flash cards, HTTP
      requests) for agents in the VM, through `mwt mcp`: nothing to hold.
      Three are built in, one for each of the `tools` they open: `:read`,
      `:create` and `:change` (`mwt_tools/0`,
      `MWTClient.Sandbox.MwtTools`).

  A grant with a `parent` is a **subgrant**: one fixed use of that grant,
  which MWT carries out when an agent calls it by id with a value for each
  of its `params` (`MWTClient.Sandbox.Param`). A saved command is a
  subgrant of Ask to run commands. It has a switch of its own, apart from
  its parent's.

  `minutes` is how long it was last turned on for, or `:until_off`: the
  duration its row shows as chosen while it is on.

  `start` is the state it is put in when MWT starts: `:off` (disabled),
  `:on` (enabled until turned off, every use asks) or `:auto` (enabled
  until turned off, every use goes through). Between starts its switch,
  duration and approval mode change it like any grant.

  `proposal` says an agent proposed it (`mwt propose`,
  `MWTClient.Sandbox.Proposal`): who, from which thread, why, and when;
  nil for one you made. MWT saves a proposed grant at once, off and
  disabled on startup, to review: until you accept it on its page
  (`reviewed_at`), nothing turns it on, an agent's ask included, and it
  can't start enabled (`to_review?/1`).

  `purpose` is the user's own words for what the grant is for. Agents read it
  to find the grant they need, so every grant has one. `preset` remembers
  which preset filled the form; nothing depends on it. What a preset gave
  beyond the form is copied here when the grant is made: its `icon`, the
  `request_headers` its request subgrants start from, and the
  `cli_tools` it serves (`gh`), which a command's card names.

  Every use of an `on` grant waits for the user unless one of its
  `allowances` covers it. See `MWTClient.Sandbox.Allowance`.

  `confined`, for a command subgrant, runs it in a bubble on your machine
  (`MWTClient.Sandbox.Confine`): no home of yours, your tools read-only,
  its folder read-only unless `writes_dir`, and the real values of the
  token grants it names in `with`, under the variables the VM sees
  placeholders in. Not confined, it runs as you, as before.

  `checks` are scripts of yours that say it still holds
  (`MWTClient.Sandbox.Check`): a gating one that fails keeps it off.
  `held_by` is never saved: what the VM is shown of a grant a check holds
  off says why (`MWTClient.Sandbox.Server.State.live_grants/1`).

  `resolver` and `anchor`, for a network grant, are its private network:
  the DNS server that answers the names it lists (`address` or
  `address:port`; nil is this machine's own), and the network interface
  its addresses are reached through (`wg0`, `tun0`; nil is wherever this
  machine routes them). With an anchor, a connection under the grant
  leaves only through that interface, and while it is down the grant opens
  nothing (`MWTClient.Sandbox.Routes`). A destination may be a name,
  `db.corp.example:5432`, or every name under one, `*.corp.example:443`: it
  opens only the addresses MWT's DNS answered for it
  (`MWTClient.Sandbox.Dns`).

  `host_rules`, for a network grant, the Internet included, are hosts
  whose uses go otherwise than the grant's own approval mode says
  (`MWTClient.Sandbox.HostRules`): each entry `:ask` (every request MWT
  reads there waits for you, and a connection it can't read is asked about
  as one), `:auto` (each goes through) or `:block` (each is refused). So
  the Internet can let everything through but a few hosts you check, or
  ask about everything but a few you let through, and refuse some
  outright. An entry is a name, never an address, and covers every name
  under it; the one naming a host most exactly speaks.

  `presents`, for a token grant, names the presentations `mwt exec` runs for it (`native/mwt_present`), each with
  its few settings: `%{metadata: %{project: "…", email: "…"}}`, a cloud
  metadata server on loopback for the command's lifetime; `%{login:
  %{refresh: placeholder, header: "…"}}`, a Google login file
  (`login_file/1`) whose refresh token is a placeholder of its own, made
  once, which MWT answers for at Google's token endpoint
  (`MWTClient.Sandbox.CredentialEndpoint`), and the header the ID token it
  hands out travels in (empty: the grant's carriers).

  `signs_as`, for a token grant, lists the service accounts whose
  `signJwt` MWT answers itself (`MWTClient.Sandbox.CredentialEndpoint`):
  it signs with the grant's real value and hands the VM a placeholder for
  the signed JWT, which goes only to the host its `aud` names. Empty, a
  request to sign is a credential endpoint like any other, which the
  firewall refuses.

  `mint_per`, for a minted token grant, says whether one value serves all
  its hosts (`:grant`) or each host gets its own (`:host`): the mint
  command is told `MWT_HOST`, and each value is kept apart.

  `keep_minutes`, for a minted token grant, is the longest a value it
  minted is kept before it is minted again, whatever the mint says of its
  expiry; nil keeps it as the mint says (`Values.minted/1`).

  `reach`, for a token grant, is who may wield its value: `:vm`, through
  `mwt exec` and its placeholder, or `:subgrants`, only the requests MWT
  sends for its subgrants: the VM gets no placeholder, no variable and no
  file for it, and there is nothing of it to turn on (`subgrants_only?/1`).

  `ceiling` is whether it always asks (`ceiling/1`): `:ask`, every use
  waits for you and is allowed once, no allowance or Auto-approve covering
  one; `:allow`, allowances as you choose.

  See `docs/agent_sandbox.md` for the whole model.
  """

  alias MWTClient.Sandbox.{Allowance, EventDetails, Param}

  @enforce_keys [:id, :name, :kind]
  defstruct [
    :id,
    :name,
    :kind,
    :preset,
    :expires_at,
    :placeholder,
    :path,
    :script,
    :dir,
    :last_used_at,
    :minutes,
    :parent,
    :method,
    :url,
    :body,
    :tools,
    :proposal,
    purpose: "",
    state: :off,
    start: :off,
    ceiling: :allow,
    reach: :vm,
    params: [],
    confined: false,
    with: [],
    writes_dir: false,
    mint_per: :grant,
    keep_minutes: nil,
    signs_as: [],
    presents: %{},
    resolver: nil,
    anchor: nil,
    icon: nil,
    request_headers: nil,
    cli_tools: [],
    checks: [],
    held_by: nil,
    headers: [],
    source: :stored,
    env: [],
    file_env: [],
    git: false,
    internet: false,
    hosts: [],
    carriers: [],
    destinations: [],
    host_rules: [],
    allowances: [],
    uses: 0
  ]

  @type kind :: :token | :network | :command | :request | :mwt
  @type source :: :stored | {:minted, String.t()}

  @typedoc "The state a grant is put in when MWT starts; `:auto` is enabled and auto-approved."
  @type start :: :off | :on | :auto

  @typedoc "The most automation a grant accepts: always asks, or allowances as you choose."
  @type ceiling :: :ask | :allow

  @typedoc """
  Who proposed a grant, when an agent did: the agent's name, its thread
  (`MWTClient.Sandbox.Approval.thread/1`), why, for how many minutes it
  asked to have it on, when, and when you reviewed it on its page (nil
  until then).
  """
  @type proposal :: %{
          agent: String.t(),
          thread: map() | nil,
          reason: String.t(),
          minutes: pos_integer(),
          at: DateTime.t(),
          reviewed_at: DateTime.t() | nil
        }

  @typedoc """
  What a network grant does with the uses of the hosts an entry covers
  (`host_rules`): ask you about each, let each through, or refuse each.
  """
  @type host_action :: :ask | :auto | :block

  @typedoc "One entry of a network grant's host list (`MWTClient.Sandbox.HostRules`)."
  @type host_rule :: %{host: String.t(), action: host_action()}

  @typedoc "Who may wield a token grant's value: the VM, or only its subgrants."
  @type reach :: :vm | :subgrants

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          kind: kind(),
          preset: atom() | String.t() | nil,
          purpose: String.t(),
          state: :on | :off,
          expires_at: DateTime.t() | nil,
          placeholder: String.t() | nil,
          path: String.t() | nil,
          script: String.t() | nil,
          dir: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          minutes: pos_integer() | :until_off | nil,
          parent: String.t() | nil,
          start: start(),
          ceiling: ceiling(),
          reach: reach(),
          params: [Param.t()],
          confined: boolean(),
          with: [String.t()],
          writes_dir: boolean(),
          mint_per: :grant | :host,
          keep_minutes: pos_integer() | nil,
          signs_as: [String.t()],
          presents: %{
            optional(:metadata) => %{project: String.t(), email: String.t()},
            optional(:login) => %{refresh: String.t(), header: String.t()}
          },
          resolver: String.t() | nil,
          anchor: String.t() | nil,
          icon: String.t() | nil,
          request_headers: String.t() | nil,
          cli_tools: [String.t()],
          checks: [MWTClient.Sandbox.Check.t()],
          held_by: String.t() | nil,
          method: String.t() | nil,
          url: String.t() | nil,
          headers: [{String.t(), String.t()}],
          body: String.t() | nil,
          tools:
            :read
            | :create
            | :change
            | :git_fetch
            | :git_fetch_remote
            | :git_handoff
            | :share_sync
            | :workspace
            | nil,
          proposal: proposal() | nil,
          source: source(),
          env: [String.t()],
          file_env: [String.t()],
          git: boolean(),
          internet: boolean(),
          hosts: [String.t()],
          carriers: [String.t()],
          destinations: [String.t()],
          host_rules: [host_rule()],
          allowances: [Allowance.t()],
          uses: non_neg_integer()
        }

  @kinds [:token, :network, :command, :request, :mwt]

  @doc "Every type a grant can have."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @default_carriers ["authorization"]

  @doc """
  The headers a token grant's real value travels in, lowercase: those it
  names, or `authorization`. MWT puts the value nowhere else.

      iex> MWTClient.Sandbox.Grant.carriers(%MWTClient.Sandbox.Grant{id: "g", name: "G", kind: :token})
      ["authorization"]
  """
  @spec carriers(t()) :: [String.t()]
  def carriers(%__MODULE__{carriers: []}), do: @default_carriers
  def carriers(%__MODULE__{carriers: carriers}), do: carriers

  @doc "Whether an agent proposed the grant (`mwt propose`), reviewed since or not."
  @spec proposed?(t()) :: boolean()
  def proposed?(%__MODULE__{proposal: proposal}), do: is_map(proposal)

  @doc """
  Whether an agent proposed the grant and you haven't reviewed it yet: it
  stays off, and only enabling it from its page turns it on.
  """
  @spec to_review?(t()) :: boolean()
  def to_review?(%__MODULE__{proposal: %{reviewed_at: nil}}), do: true
  def to_review?(%__MODULE__{}), do: false

  @doc """
  Whether the grant is on at `now`. One past its `expires_at` is not, even
  while its `state` still says `:on`: the clock decides, not a timer.
  """
  @spec on?(t(), DateTime.t()) :: boolean()
  def on?(grant, now \\ DateTime.utc_now())
  def on?(%__MODULE__{state: :on, expires_at: nil}, _now), do: true
  def on?(%__MODULE__{state: :on, expires_at: at}, now), do: DateTime.compare(now, at) == :lt
  def on?(%__MODULE__{}, _now), do: false

  @doc """
  Whether a grant is a saved command: a command grant with a script of
  yours, which agents run by name. One without is Ask to run commands, the escape
  hatch, where agents write the text.
  """
  @spec saved_command?(t()) :: boolean()
  def saved_command?(%__MODULE__{kind: :command, script: script}), do: is_binary(script)
  def saved_command?(%__MODULE__{}), do: false

  @doc """
  Whether a grant is a subgrant: one fixed use of its `parent`, called by
  id.
  """
  @spec subgrant?(t()) :: boolean()
  def subgrant?(%__MODULE__{parent: parent}), do: is_binary(parent)

  @doc """
  Whether a grant takes subgrants: Ask to run commands does, as commands of
  yours; a token grant does, as requests MWT sends with its value.
  """
  @spec takes_subgrants?(t()) :: boolean()
  def takes_subgrants?(%__MODULE__{kind: :token, parent: nil}), do: true
  def takes_subgrants?(%__MODULE__{} = grant), do: ask_to_run?(grant)

  @doc "The subgrants of `grant` among `grants`."
  @spec subgrants([t()], t()) :: [t()]
  def subgrants(grants, %__MODULE__{id: id}), do: Enum.filter(grants, &(&1.parent == id))

  @doc """
  The states a grant can be put in when MWT starts. Enabled and
  auto-approved (`:auto`) only where uses can be auto-approved: not Ask to
  run commands, whose every run asks. One to review only starts disabled.
  """
  @spec starts(t()) :: [start()]
  def starts(%__MODULE__{proposal: %{reviewed_at: nil}}), do: [:off]
  def starts(%__MODULE__{kind: :token, reach: :subgrants}), do: [:off]

  def starts(%__MODULE__{} = grant),
    do: if(auto_approvable?(grant), do: [:off, :on, :auto], else: [:off, :on])

  @doc """
  How an agent calls a subgrant, without the reason: its id, then each
  parameter as `NAME=…`.

      iex> alias MWTClient.Sandbox.{Grant, Param}
      iex> Grant.signature(%Grant{id: "gh-repo-view", name: "gh repo view", kind: :command,
      ...>   params: [%Param{name: "REPO_NAME", shape: :word, about: "the repository"}]})
      "mwt call gh-repo-view REPO_NAME=…"
  """
  @spec signature(t()) :: String.t()
  def signature(%__MODULE__{id: id, params: params}),
    do: Enum.join(["mwt call #{id}" | Enum.map(params, &"#{&1.name}=…")], " ")

  @ask_to_run_id "commands"
  @ask_to_run_name "Ask to run commands"
  @ask_to_run_purpose "The escape hatch: lets agents ask to run a command they write on this machine, for a job no other grant does. You approve every run."

  @doc """
  Ask to run commands, the escape hatch, as MWT makes it: built in, off,
  with its own id, name and words. While it is on, agents may ask to run a
  command they wrote; every run waits for you.
  """
  @spec ask_to_run() :: t()
  def ask_to_run,
    do: %__MODULE__{
      id: @ask_to_run_id,
      name: @ask_to_run_name,
      kind: :command,
      purpose: @ask_to_run_purpose,
      state: :off
    }

  @doc """
  The id Ask to run commands had before it was built in under its own,
  when it was called Any command. Agents that still use it are answered as
  if they used the new one, and told it.
  """
  @spec former_ask_to_run_id() :: String.t()
  def former_ask_to_run_id, do: "any-command"

  @doc """
  Whether a grant is Ask to run commands, the escape hatch: a command grant
  with no script, where agents write the text. Built in, one per identity.
  """
  @spec ask_to_run?(t()) :: boolean()
  def ask_to_run?(%__MODULE__{kind: :command, script: nil}), do: true
  def ask_to_run?(%__MODULE__{}), do: false

  @doc """
  Whether its uses can be auto-approved: every use going through without
  asking while it stays on. Token, network, saved command and request
  grants, unless their ceiling is `:ask`; Ask to run commands always asks.
  """
  @spec auto_approvable?(t()) :: boolean()
  def auto_approvable?(%__MODULE__{} = grant),
    do: approvable_kind?(grant) and ceiling(grant) != :ask

  defp approvable_kind?(%__MODULE__{kind: kind}) when kind in [:token, :network, :request, :mwt],
    do: true

  defp approvable_kind?(%__MODULE__{} = grant), do: saved_command?(grant)

  @ceilings [:ask, :allow]

  @doc """
  The ceilings a grant can take. The Internet never always asks: only
  `:allow` (it can ask each time, and its host list can ask about hosts).
  Ask to run commands always does: `[:ask]`. Every other grant and
  subgrant may always ask, or not.

      iex> alias MWTClient.Sandbox.Grant
      iex> Grant.ceilings(Grant.internet())
      [:allow]
      iex> Grant.ceilings(Grant.ask_to_run())
      [:ask]
  """
  @spec ceilings(t()) :: [ceiling()]
  def ceilings(%__MODULE__{internet: true}), do: [:allow]

  def ceilings(%__MODULE__{} = grant),
    do: if(ask_to_run?(grant), do: [:ask], else: @ceilings)

  @doc """
  The ceiling a grant has: the one it was given, or, when it can't take
  that one, the one it can.

      iex> alias MWTClient.Sandbox.Grant
      iex> Grant.ceiling(%{Grant.internet() | ceiling: :ask})
      :allow
      iex> Grant.ceiling(%Grant{id: "t", name: "T", kind: :token})
      :allow
  """
  @spec ceiling(t()) :: ceiling()
  def ceiling(%__MODULE__{ceiling: wanted} = grant) do
    takes = ceilings(grant)
    if wanted in takes, do: wanted, else: List.last(takes)
  end

  @doc """
  Whether a token grant's value is only for its subgrants: the VM gets
  nothing of it, and there is nothing to turn on. Its subgrants each have
  a switch of their own.
  """
  @spec subgrants_only?(t()) :: boolean()
  def subgrants_only?(%__MODULE__{kind: :token, reach: :subgrants}), do: true
  def subgrants_only?(%__MODULE__{}), do: false

  @doc """
  Whether every use goes through without asking at `now`: it is on, and an
  allowance for every use covers it (`Auto-approve`).
  """
  @spec auto_approved?(t(), DateTime.t()) :: boolean()
  def auto_approved?(%__MODULE__{} = grant, now \\ DateTime.utc_now()) do
    auto_approvable?(grant) and on?(grant, now) and
      Enum.any?(grant.allowances, &(&1.pattern == :all and not Allowance.ended?(&1, now)))
  end

  @mwt_tools [
    %{
      tools: :read,
      id: "mwt-read",
      name: "MWT: read",
      start: :auto,
      purpose:
        "Lets agents in the VM read your notes, diagrams and flash cards in MWT, through mwt mcp. " <>
          "Never HTTP requests: from the VM those are only added."
    },
    %{
      tools: :create,
      id: "mwt-create",
      name: "MWT: create",
      start: :auto,
      purpose:
        "Lets agents in the VM add notes, diagrams, flash cards and, when you ask for one, HTTP request samples " <>
          "in MWT, through mwt mcp. It changes nothing already there."
    },
    %{
      tools: :change,
      id: "mwt-change",
      name: "MWT: change",
      start: :on,
      purpose:
        "Lets agents in the VM change notes, diagrams and flash cards already in MWT, yours included, through mwt mcp. " <>
          "Each change shows as a diff, and what it replaces is kept as a version you can restore."
    },
    %{
      tools: :git_fetch,
      id: "git-fetch",
      name: "Git: fetch from your repositories",
      start: :auto,
      purpose:
        "Lets the VM's project clones fetch from origin, your repository on this machine: its committed branches and tags; " <>
          "and from upstream, your repository's own remote branches, as this machine has them. It only reads."
    },
    %{
      tools: :git_fetch_remote,
      id: "git-fetch-remote",
      name: "Git: fetch from your remotes",
      start: :auto,
      purpose:
        "Before the VM reads upstream, this machine fetches your repository's own remote into MWT's store, never into your repository, " <>
          "with your credentials, without prompting, at most once a minute. The VM never sees a credential or chooses the remote."
    },
    %{
      tools: :git_handoff,
      id: "git-handoff",
      name: "Git: hand off",
      start: :auto,
      purpose:
        "Lets agents send their work back with mwt handoff: an exact commit, into MWT's review store, never into your repository. " <>
          "You review it and decide where it lands."
    },
    %{
      tools: :share_sync,
      id: "share-sync",
      name: "Shared folders: sync",
      start: :auto,
      purpose:
        "Lets agents bring the VM's read-only copies of your shared folders up to date with mwt sync, as you would with Sync. " <>
          "Only what you shared, from this machine into the VM: nothing goes back."
    },
    %{
      tools: :workspace,
      id: "workspace",
      name: "Workspace: write to your machine",
      start: :auto,
      purpose:
        "Lets the workspace's from-vm folder, which agents write in the VM, be copied into ~/mwt-vm/from-vm on this machine, " <>
          "read-only here, at each sync of your shared folders. Only files and folders, nothing executable, no name starting with a dot, " <>
          "at most 1 GiB. Off, nothing of the VM comes here; what came already stays."
    }
  ]

  @doc """
  MWT's own tools for agents in the VM, as MWT makes them: grants, built
  in, each enabled on startup. For notes, diagrams and cards, through mwt
  mcp: reading and creating are auto-approved, changing asks each time.
  For the projects' Git (`git_tools?/1`): fetching from your repositories,
  fetching from their remotes on this machine, and handing off, all
  auto-approved; landing is never a grant, it is yours. And syncing your
  shared folders' copies, auto-approved too, and copying the workspace's
  `from-vm/` onto this machine (`MWTClient.Sandbox.CopyBack`), the one
  way the VM writes onto your disk without a handoff you land.
  """
  @spec mwt_tools() :: [t()]
  def mwt_tools do
    for tool <- @mwt_tools do
      %__MODULE__{
        id: tool.id,
        name: tool.name,
        kind: :mwt,
        tools: tool.tools,
        purpose: tool.purpose,
        start: tool.start,
        state: :off
      }
    end
  end

  @internet_id "internet"
  @internet_purpose "Every public address on the internet. Off, the VM reaches only what other grants list, and DNS answers only their names."

  @doc """
  The Internet, as MWT makes it: a network grant, built in, for every
  public address. It is enabled on startup, as the VM had before it was a
  grant (2026-11-17), and is never asked for each connection: an approval
  could show only an address. Private and reserved addresses are never
  its: they need network grants of their own.
  """
  @spec internet() :: t()
  def internet,
    do: %__MODULE__{
      id: @internet_id,
      name: "Internet",
      kind: :network,
      internet: true,
      purpose: @internet_purpose,
      start: :auto,
      state: :off
    }

  @doc "Whether a grant is the Internet, built in."
  @spec internet?(t()) :: boolean()
  def internet?(%__MODULE__{internet: internet}), do: internet == true

  @doc """
  How a grant's uses are approved when it is turned on and nobody said:
  `:ask`, each waits for you; for the Internet `:all`, since everything an
  agent fetches goes through it and asking about each would stop the agent
  at once. Its host list asks about the hosts you choose
  (`host_rules`).
  """
  @spec default_uses(t()) :: :ask | :all
  def default_uses(%__MODULE__{} = grant), do: if(internet?(grant), do: :all, else: :ask)

  @doc "Whether a grant is one of MWT's own tools, built in."
  @spec mwt_tools?(t()) :: boolean()
  def mwt_tools?(%__MODULE__{kind: kind}), do: kind == :mwt

  @doc "Whether a grant is one of MWT's own tools for the projects' Git."
  @spec git_tools?(t()) :: boolean()
  def git_tools?(%__MODULE__{kind: :mwt, tools: tools}),
    do: tools in [:git_fetch, :git_fetch_remote, :git_handoff]

  def git_tools?(%__MODULE__{}), do: false

  @doc "Whether a grant is built in: never removed, its words MWT's."
  @spec built_in?(t()) :: boolean()
  def built_in?(%__MODULE__{} = grant),
    do: ask_to_run?(grant) or mwt_tools?(grant) or internet?(grant)

  @doc "Where the VM finds a token grant's placeholder as a file."
  @spec token_file(t()) :: String.t()
  def token_file(%__MODULE__{id: id}), do: "/mnt/mwt/tokens/" <> id

  @doc "Where the VM finds a grant's Google login file, under `mwt exec`."
  @spec login_file(t()) :: String.t()
  def login_file(%__MODULE__{id: id}), do: "/mnt/mwt/logins/#{id}.json"

  @doc "The placeholder standing for a grant's login in its login file, or nil."
  @spec login_placeholder(t()) :: String.t() | nil
  def login_placeholder(%__MODULE__{presents: %{login: %{refresh: refresh}}}), do: refresh
  def login_placeholder(_grant), do: nil

  @doc """
  The headers a grant's ID token travels in: the one its login names, or
  the grant's own carriers.
  """
  @spec id_token_carriers(t()) :: [String.t()]
  def id_token_carriers(%__MODULE__{presents: %{login: %{header: header}}}) when header != "",
    do: [header]

  def id_token_carriers(grant), do: carriers(grant)

  @doc """
  A new placeholder for a login's refresh token, shaped as Google's are
  (`1//`), long and random.
  """
  @spec new_login_placeholder() :: String.t()
  def new_login_placeholder,
    do: "1//mwt" <> Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

  @doc "The hosts git's credential helper answers for: the exact ones, when `git` is set."
  @spec git_hosts(t()) :: [String.t()]
  def git_hosts(%__MODULE__{kind: :token, git: true, hosts: hosts}),
    do: Enum.reject(hosts, &String.starts_with?(&1, "*."))

  def git_hosts(%__MODULE__{}), do: []

  @doc """
  Brings a grant saved by an older MWT up to date. Before 2026-11-12 a grant
  had a `recipe` (`:github`, `:hex`, `:google`, `:token`, `:network`,
  `:database`, `:file`) and the type `:http`, and its rules decided which
  requests went through. Rules are gone: every use asks.
  """
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved) do
    fields = Map.delete(saved, :__struct__)
    recipe = fields[:recipe]

    {env, file_env} =
      if recipe == :google,
        do: {[], fields[:env] || []},
        else: {fields[:env] || [], fields[:file_env] || []}

    upgraded = %{
      id: fields[:id],
      kind: if(fields[:kind] == :http, do: :token, else: fields[:kind]),
      preset: fields[:preset] || if(recipe in [:github, :hex, :google, :database], do: recipe),
      purpose: fields[:purpose] || old_purpose(recipe),
      env: env,
      file_env: file_env,
      git: Map.get(fields, :git, recipe == :github),
      carriers: fields[:carriers] || [],
      allowances:
        for(%{} = allowance <- fields[:allowances] || [], do: Allowance.upgrade(allowance)),
      params: for(%{} = param <- fields[:params] || [], do: Param.upgrade(param)),
      checks:
        for(%{} = check <- fields[:checks] || [], do: MWTClient.Sandbox.Check.upgrade(check)),
      held_by: nil,
      mint_per: if(fields[:mint_per] == :host, do: :host, else: :grant),
      # What the presets that were Elixir before 2026-11-17 gave: copied
      # onto the grant once, as a preset file's are now.
      icon: fields[:icon] || old_preset(preset_id(fields, recipe), :icon),
      request_headers:
        fields[:request_headers] || old_preset(preset_id(fields, recipe), :request_headers),
      cli_tools: fields[:cli_tools] || old_preset(preset_id(fields, recipe), :tools) || [],
      presents: if(is_map(fields[:presents]), do: fields[:presents], else: %{}),
      start: if(fields[:start] in [:on, :auto], do: fields[:start], else: :off),
      # "YOLO may not open it" (`:auto`) is gone: such a grant now always
      # asks, the nearer of the two left. YOLO itself is gone (2026-11-18):
      # what it could open now just takes allowances (`:allow`).
      ceiling:
        case fields[:ceiling] do
          :auto -> :ask
          :ask -> :ask
          _yolo_or_none -> :allow
        end,
      proposal: upgrade_proposal(fields[:proposal]),
      reach: if(fields[:reach] == :subgrants, do: :subgrants, else: :vm)
    }

    struct(__MODULE__, Map.merge(fields, upgraded))
  end

  defp upgrade_proposal(%{} = proposal),
    do:
      Map.merge(
        %{agent: "An agent", thread: nil, reason: "", minutes: 60, at: nil, reviewed_at: nil},
        Map.delete(proposal, :__struct__)
      )

  defp upgrade_proposal(_none), do: nil

  defp preset_id(fields, recipe),
    do: fields[:preset] || if(recipe in [:github, :hex, :google, :database], do: recipe)

  @old_presets %{
    github: %{
      icon: "git-branch",
      request_headers:
        "Authorization: Bearer {token}\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28",
      tools: ["gh"]
    },
    hex: %{
      icon: "hero-cube",
      request_headers: "Authorization: {token}\nAccept: application/json",
      tools: ["mix hex"]
    },
    google: %{icon: "hero-cloud", request_headers: nil, tools: ["gcloud", "gsutil", "bq"]},
    database: %{icon: "hero-circle-stack", request_headers: nil, tools: []}
  }

  defp old_preset(preset, key) when is_atom(preset),
    do: @old_presets |> Map.get(preset, %{}) |> Map.get(key)

  defp old_preset(_preset, _key), do: nil

  defp old_purpose(:github), do: "GitHub: gh, git over HTTPS and the GitHub API."
  defp old_purpose(:hex), do: "Hex: publishing and private packages."
  defp old_purpose(:google), do: "Google Cloud: gcloud and Google APIs."
  defp old_purpose(:database), do: "A database, through a tunnel on the user's machine."
  defp old_purpose(_recipe), do: ""
  ## Details

  @doc """
  The grant as it is, for an event that names it
  (`MWTClient.Sandbox.EventDetails`): what it opens and how, its state,
  what it allows without asking, how much it was used. Never its value.
  An agent's proposal is set apart, in its words.
  """
  @spec details(t()) :: EventDetails.t()
  def details(%__MODULE__{} = grant) do
    EventDetails.safely("a grant", fn ->
      EventDetails.new([
        EventDetails.section(
          "The grant, then",
          [{"Grant", {:link, grant.name, "/tools/sandbox/grants/#{grant.id}"}}] ++
            described(grant) ++
            [
              {"Allowed without asking", {:list, Enum.map(grant.allowances, &allowance_words/1)}},
              {"Uses", grant.uses > 0 && grant.uses},
              {"Last used", grant.last_used_at && time_words(grant.last_used_at)}
            ]
        ),
        proposal_details(grant.proposal)
      ])
    end)
  end

  @doc """
  What an edit changed, each setting before and after
  (`MWTClient.Sandbox.EventDetails`), `[]` when none shows a difference.
  """
  @spec changes(t(), t()) :: EventDetails.t()
  def changes(%__MODULE__{} = before, %__MODULE__{} = now) do
    EventDetails.safely("a grant's edit", fn ->
      EventDetails.new([EventDetails.changes(described(before), described(now))])
    end)
  end

  # Every setting worth saying, each a text, a script ({:code, _}) or a
  # list; nil or empty for one the grant doesn't have.
  defp described(grant) do
    [
      {"Name", grant.name},
      {"Type", kind_words(grant.kind)},
      {"For", grant.purpose},
      {"State", state_words(grant)},
      {"When MWT starts", start_words(grant.start)},
      {"Always ask me", grant.ceiling == :ask && "on"},
      {"Only for its subgrants", grant.reach == :subgrants && "yes"},
      {"Hosts", {:list, grant.hosts}},
      {"Destinations", {:list, grant.destinations}},
      {"Host list",
       {:list, Enum.map(grant.host_rules || [], &"#{&1.host}: #{host_action_words(&1.action)}")}},
      {"Variables", {:list, grant.env}},
      {"File variables", {:list, grant.file_env}},
      {"Placeholder headers", {:list, grant.carriers}},
      {"Git credentials", grant.git && "for its hosts"},
      {"Internet", grant.internet && "open"},
      {"Value", source_words(grant.source)},
      {"Script", {:code, grant.script}},
      {"Folder", grant.dir},
      {"Writes in its folder", grant.writes_dir && "yes"},
      {"Confined", grant.confined && "yes"},
      {"Request", Enum.join(Enum.reject([grant.method, grant.url], &is_nil/1), " ")},
      {"Request headers", {:list, Enum.map(grant.headers, fn {name, _value} -> name end)}},
      {"Body", {:code, grant.body}},
      {"Parameters", {:list, Enum.map(grant.params, & &1.name)}},
      {"MWT tools", grant.tools && Atom.to_string(grant.tools)},
      {"Command-line tools", {:list, grant.cli_tools}},
      {"Checks", {:list, Enum.map(grant.checks, &"#{&1.name}: #{check_words(&1.on)}")}},
      {"Under", grant.parent && {:link, grant.parent, "/tools/sandbox/grants/#{grant.parent}"}},
      {"Preset", grant.preset && to_string(grant.preset)}
    ]
  end

  defp host_action_words(:ask), do: "Ask"
  defp host_action_words(:auto), do: "Auto-approve"
  defp host_action_words(:block), do: "Block"
  defp host_action_words(other), do: to_string(other)

  defp kind_words(:token), do: "Token: placeholders MWT swaps for the value"
  defp kind_words(:network), do: "Network: destinations opened"
  defp kind_words(:command), do: "Command: a script run on your machine"
  defp kind_words(:request), do: "Request: sent by MWT with a token's value"
  defp kind_words(:mwt), do: "MWT's tools"
  defp kind_words(_other), do: nil

  defp state_words(%{state: :on, expires_at: nil}), do: "on, until turned off"
  defp state_words(%{state: :on, expires_at: at}), do: "on, until #{time_words(at)}"
  defp state_words(%{state: :off}), do: "off"

  defp start_words(:off), do: "off"
  defp start_words(:on), do: "on, each use asks"
  defp start_words(:auto), do: "on, auto-approved"
  defp start_words(_other), do: nil

  defp source_words({:minted, how}), do: "minted by MWT (#{how})"
  defp source_words(_stored), do: nil

  defp allowance_words(%Allowance{pattern: :all} = allowance),
    do: "every use" <> until_words(allowance.until)

  defp allowance_words(%Allowance{pattern: pattern} = allowance),
    do: "uses like “#{pattern}”" <> until_words(allowance.until)

  defp until_words(nil), do: ", while the grant is on"
  defp until_words(until), do: ", until #{time_words(until)}"

  defp check_words(on),
    do: Enum.map_join(on, ", ", &if(&1 == :enable, do: "when turned on", else: "daily"))

  defp proposal_details(nil), do: nil

  defp proposal_details(proposal) do
    thread = proposal.thread || %{}

    EventDetails.agent("Proposed by the agent", [
      {"Agent", proposal.agent},
      {"Why", proposal.reason},
      {"For how long", proposal.minutes && "#{proposal.minutes} min"},
      {"Thread", Map.get(thread, :title)},
      {"Proposed at", proposal.at && time_words(proposal.at)},
      {"Reviewed at", proposal.reviewed_at && time_words(proposal.reviewed_at)}
    ])
  end

  defp time_words(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
end
