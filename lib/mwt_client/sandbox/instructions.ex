defmodule MWTClient.Sandbox.Instructions do
  @moduledoc """
  What agents in the VM are told: what every task needs, in every session
  (`priv/sandbox/agents.md`): where to work, how a project's slots and
  handoffs go, that access comes only from MWT's grants, and their own
  memory; what only some tasks need, in guides they read when that text
  sends them there (`guides/0`); and which grants exist right now
  (`grants/2`). How the user likes to work with agents is their own text,
  not a fact of the VM (`Settings`, `way_of_working`), joining the
  instructions only when they wrote one.

  The standing text is kept short on purpose: Claude Code and Codex load
  it, whole, into every session, subagent and approval review, and a rule
  every task needs is followed less often among pages that only some do.

  The instructions reach Claude Code and Codex through their global files in
  the VM's Home, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, as a block
  (`block/0`) that a script run in the VM after every boot puts there. The
  rest of each file is left alone. Agents may edit the block meanwhile; the
  next boot undoes it. The same script puts the `/handoff` command
  (`priv/sandbox/handoff-command.md`) in each agent's own commands folder.
  """

  alias MWTClient.Sandbox.{Destinations, Grant, Param, Presets}

  @begin "<!-- mwt:begin · MWT rewrites this block before every start; write below it -->"
  @finish "<!-- mwt:end -->"
  @home_files [".claude/CLAUDE.md", ".codex/AGENTS.md"]

  @doc """
  The standing instructions, as Markdown: how to work in the VM, and after
  it, with `way_of_working: text`, the user's own text on how they like to
  work with agents, under a heading of MWT's that says whose it is. An
  empty text adds nothing.
  """
  @spec text(keyword()) :: String.t()
  def text(opts \\ []) do
    agents = priv("agents.md")

    case String.trim(opts[:way_of_working] || "") do
      "" -> agents
      way -> agents <> "\n" <> way_of_working_section(way)
    end
  end

  defp way_of_working_section(way) do
    """
    ## The user's way of working

    The user wrote this for the agents in this VM: how they like to work with
    you, their own taste rather than a rule of the VM.

    #{way}
    """
  end

  @doc "MWT's example of a way of working, for the user to start from."
  @spec way_of_working_example() :: String.t()
  def way_of_working_example, do: priv("way-of-working-example.md")

  @doc """
  The guides, by topic: what only some tasks need, which agents read when
  the standing text sends them there (`mwt help TOPIC`, from
  `/mnt/mwt/guides/TOPIC.md`), rather than carry in every session. Each is
  `priv/sandbox/guides/TOPIC.md`.
  """
  @spec guides() :: %{String.t() => String.t()}
  def guides do
    dir = Path.join([:code.priv_dir(:mwt_client), "sandbox", "guides"])

    for file <- File.ls!(dir), Path.extname(file) == ".md", into: %{} do
      {Path.rootname(file), MWTClient.Files.read!(Path.join(dir, file))}
    end
  end

  defp priv(file),
    do: MWTClient.Files.read!(Path.join([:code.priv_dir(:mwt_client), "sandbox", file]))

  @doc "The files in Home that carry the block, relative to Home."
  @spec home_files() :: [String.t()]
  def home_files, do: @home_files

  @doc """
  The standing instructions as the block the VM puts in `home_files/0`
  itself, after every boot (`priv/sandbox/mwt-boot`, at `/mnt/mwt/bin`). MWT
  writes it to `/mnt/mwt/agents-block.md` and never into the VM's Home.
  Takes the options of `text/1`.
  """
  @spec block(keyword()) :: String.t()
  def block(opts \\ []), do: put_block("", text(opts))

  @doc """
  `content` with MWT's block holding `text`: replaced where it was, or put at
  the top.

      iex> MWTClient.Sandbox.Instructions.put_block("mine\\n", "theirs") =~ ~r/^<!-- mwt:begin.*theirs\\n<!-- mwt:end -->\\n\\nmine\\n$/s
      true
  """
  @spec put_block(String.t(), String.t()) :: String.t()
  def put_block(content, text) do
    block = @begin <> "\n" <> String.trim(text) <> "\n" <> @finish <> "\n"

    case :binary.match(content, @begin) do
      {start, _} ->
        rest = binary_part(content, start, byte_size(content) - start)

        case :binary.match(rest, @finish) do
          {stop, length} ->
            after_block =
              binary_part(rest, stop + length, byte_size(rest) - stop - length)
              |> String.replace_prefix("\n", "")

            binary_part(content, 0, start) <> block <> after_block

          :nomatch ->
            binary_part(content, 0, start) <> block
        end

      :nomatch ->
        if String.trim(content) == "", do: block, else: block <> "\n" <> content
    end
  end

  @doc """
  Every grant and its state at `now`, for agents: `/mnt/mwt/grants.md`, and
  what `mwt grants` prints. Each says what it is for, in the user's words,
  and how to use it. Never a value.
  """
  @spec grants([Grant.t()], DateTime.t()) :: String.t()
  def grants(grants, now) do
    # By the resource each mediates, in the order they come: its grants,
    # then its actions.
    resources = grants |> Enum.map(&Grant.resource/1) |> Enum.uniq()

    body =
      if grants == [],
        do: "No grants yet.",
        else:
          Enum.map_join(resources, "\n\n", fn resource ->
            {actions, tops} =
              grants
              |> Enum.filter(&(Grant.resource(&1) == resource))
              |> Enum.split_with(&Grant.action?/1)

            blocks =
              Enum.map(tops, fn grant ->
                grant_block(grant, now) <> overlap_line(grant, grants)
              end)

            Enum.join(blocks ++ [action_block(resource, actions, now)], "\n\n")
            |> String.trim()
          end)

    """
    # Grants, as of #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC

    Written by MWT whenever a grant changes. To use one that is off, ask the
    user with: mwt request GRANT_ID --reason "what you are about to do"
    For access no grant gives: mwt request --need "what, and for which host" --reason "why",
    or, when you know what it takes, propose the grant (read mwt help propose first).
    One proposed and not yet reviewed stays off until the user accepts it on its page.

    Each grant gives uses of one resource (a credential, a network, host
    commands, MWT's tools); an off grant gives nothing. A use of yours
    needs a grant that is on over every resource it goes through: your
    request with a credential needs a grant over the credential listing its
    host and one over the network the host is on. It runs unasked only if
    each lets it through unasked. A locked resource, or a host its network blocks,
    refuses whatever the grants say. A credential is used through mwt exec
    CREDENTIAL. When a use fails (a bare 403, permission denied), run mwt
    why --recent.

    An action is one fixed use, which MWT builds and carries out for you
    when you call it by its id, with a value for each parameter:
    mwt call ID NAME=value --reason "why now"
    Its request goes out as yours would. Look for one before anything else:
    it may run without asking. To run something on the user's machine that
    no action does, propose one when you will need it again (mwt help
    propose). Otherwise, while Commands agents write is on, you may ask to
    run a command you write, and the user approves every run: read
    mwt help run first, send the smallest command that gets what you need,
    and work on its output here in the VM.

    #{body}
    """
  end

  # The grants a grant may cover the same uses as, the Internet's left out:
  # it overlaps every token grant, and says so in the rule above.
  defp overlap_line(grant, grants) do
    others =
      grant
      |> MWTClient.Sandbox.Overlaps.of(Enum.reject(grants, &Grant.action?/1))
      |> Enum.reject(&Grant.internet?(&1.grant))

    case others do
      [] ->
        ""

      others ->
        "\n- overlaps: " <>
          Enum.map_join(others, "; ", fn o ->
            "`#{o.grant.id}` at #{o.shared}" <> if(o.may?, do: " (maybe)", else: "")
          end)
    end
  end

  # A resource's actions: how to call each, its state, what it is for, and
  # each parameter in a line.
  defp action_block(_resource, [], _now), do: ""

  defp action_block(resource, actions, now) do
    lines =
      Enum.map_join(actions, "\n", fn grant ->
        params =
          Enum.map_join(grant.params, fn param ->
            "\n    - #{Param.describe(param)}"
          end)

        "  - `#{Grant.signature(grant)}` · #{state(grant, now)}" <>
          if(Grant.auto_approved?(grant, now), do: ", runs without asking", else: "") <>
          " · #{one_line(grant.purpose)}" <> params
      end)

    """
    Actions over #{resource_words(resource)}, #{actions_words(resource)} (add --reason "why now"; the user approves every call, unless the line says it runs without asking):
    #{lines}\
    """
  end

  defp actions_words({:credential, _id}),
    do:
      "requests MWT builds and sends for you through its proxy with its real value, each also needing a grant over the network of its host, as yours would; the answer's body comes back, its HTTP status on stderr, exit 0 for 2xx and 22 otherwise"

  defp actions_words(_resource), do: "the user's own scripts, each in a folder they chose"

  defp resource_words({:credential, id}), do: "the credential `#{id}`"
  defp resource_words({:network, id}), do: "the network `#{id}`"
  defp resource_words(:machine), do: "host commands, on the user's machine"
  defp resource_words(:mwt), do: "MWT's tools"

  defp grant_block(grant, now) do
    only =
      case grant.attributes || %{} do
        empty when map_size(empty) == 0 ->
          []

        attributes ->
          [
            "- only: #{MWTClient.Sandbox.Attributes.words(attributes)}" <>
              if(grant.covers_unread == false,
                do: "; a request MWT can't read these of isn't covered",
                else: "; a request MWT can't read these of is covered"
              )
          ]
      end

    Enum.join(
      [
        "## #{grant.name}",
        "- id: `#{grant.id}` · #{Presets.type_name(grant)} over #{resource_words(Grant.resource(grant))} · #{state(grant, now)}",
        "- for: #{one_line(grant.purpose)}",
        "- " <> usage(grant)
      ] ++ only ++ ["- " <> approval(grant)],
      "\n"
    )
  end

  @doc "How an agent uses a grant, in one line."
  @spec usage(Grant.t()) :: String.t()
  def usage(%Grant{kind: :token} = grant) do
    holders =
      Enum.map(grant.env, &"$#{&1}") ++
        Enum.map(grant.file_env, &"the file $#{&1} names") ++
        ["#{Grant.token_file(grant)}"]

    git =
      case Grant.git_hosts(grant) do
        [] ->
          ""

        hosts ->
          " Within that command, git over HTTPS to #{Enum.join(hosts, ", ")} gets it from MWT's credential helper."
      end

    presents =
      case grant.presents do
        %{metadata: %{project: project}} ->
          " Within that command a cloud metadata server (GCE_METADATA_HOST) serves it as project #{project}'s default credentials: don't set credentials yourself."

        _none ->
          ""
      end

    login =
      if Grant.login_placeholder(grant),
        do:
          " Within that command GOOGLE_APPLICATION_CREDENTIALS names a Google login file " <>
            "(#{Grant.login_file(grant)}) whose refresh MWT answers, with an ID token when the " <>
            "grant's mint gives one, which goes in the " <>
            "#{Enum.join(Grant.id_token_carriers(grant), " or ")} header.",
        else: ""

    signs =
      case grant.signs_as do
        [] ->
          ""

        accounts ->
          " Within that command, signJwt as #{Enum.join(accounts, ", ")} " <>
            "(iamcredentials.googleapis.com) is answered by MWT with a placeholder JWT, " <>
            "which goes only to the host its aud names, in the Authorization header."
      end

    "use: run mwt exec #{Grant.credential_id(grant)} -- COMMAND here in the VM: it speaks as " <>
      "the credential #{Grant.credential_id(grant)}, and decides nothing; this grant gives its " <>
      "requests to its hosts, which also need a grant over their network. " <>
      "Only that command and its children get #{Enum.join(holders, ", ")}. " <>
      "These hold placeholders, worthless outside MWT. Send it as the tool normally sends " <>
      "this token, only to #{Enum.join(grant.hosts, ", ")}, in the " <>
      "#{Enum.join(Grant.carriers(grant), " or ")} header; MWT swaps in the real value there " <>
      "and refuses it in any other header." <>
      git <> presents <> login <> signs
  end

  def usage(%Grant{kind: :mwt, tools: :git_fetch}),
    do:
      "use: git fetch host-origin (or remote-origin), git ls-remote and git pull in a project's clone; mwt worktree new fetches first. Off, they fail."

  def usage(%Grant{kind: :mwt, tools: :git_fetch_remote}),
    do:
      "use: nothing to do: git fetch remote-origin brings the remote's branches fresh while it is on, as the user's machine last fetched them while off."

  def usage(%Grant{kind: :mwt, tools: :git_handoff}),
    do: "use: mwt handoff, once the user asks for it. Off, nothing is handed off."

  def usage(%Grant{kind: :mwt, tools: :share_sync}),
    do:
      "use: mwt sync [PATH] brings the read-only copies of the user's shared folders up to date (PATH: only the one holding it), and waits for it. Off, they stay as the user last synced them."

  def usage(%Grant{kind: :mwt, tools: :workspace}),
    do:
      "use: mwt sync (or mwt sync $MWT_WORKSPACE/from-vm) copies what you left in $MWT_WORKSPACE/from-vm onto the user's machine, and waits for it. Off, nothing of it goes there."

  def usage(%Grant{kind: :mwt, tools: tools}) do
    "use: MWT's MCP server, mwt mcp, already set up for Claude Code and Codex in this VM: the " <>
      case tools do
        :read ->
          "list_* and get_* tools for notes, diagrams and flash cards. HTTP requests can't be read from the VM."

        :create ->
          "create_* tools and import_http_request. They add; nothing already there changes. " <>
            "Save an HTTP sample only when the user asks for one."

        :change ->
          "update_* tools, with the version get_* returned. The user sees each change as a diff."
      end
  end

  def usage(%Grant{kind: :network, internet: true} = grant),
    do:
      "use: any public address, directly, but the hosts the user blocked (mwt_host_blocked)" <>
        except_words(grant) <>
        ". Off, only what other grants over the Internet list is reached, and DNS answers only " <>
        "their names: a connection refused or a name not found may mean this is off."

  # One over part of a network.
  def usage(%Grant{kind: :network, scope: [_ | _]} = grant) do
    hosts = Enum.map_join(grant.scope, ", ", &String.trim_leading(&1, "*."))

    "use: #{hosts} and the names under it on the network #{grant.network}" <>
      except_words(grant) <>
      ", directly: it gives those beside the network's other grants, the most permissive counting."
  end

  def usage(%Grant{kind: :network, except: [_ | _] = except} = grant),
    do:
      usage(%{grant | except: []}) <>
        " It leaves out #{Enum.join(except, ", ")} and the names under them: only a grant naming them gives them."

  def usage(%Grant{kind: :network} = grant) do
    names? =
      Enum.any?(grant.destinations, &match?({:ok, %{match: {_, _}}}, Destinations.parse(&1)))

    "use: connect directly to #{Enum.join(grant.destinations, ", ")}. Nothing to hold." <>
      if(names?,
        do: " Its names resolve only while it is on: look them up after it turns on, not before.",
        else: ""
      ) <>
      if(grant.anchor,
        do:
          " It goes only through the user's #{grant.anchor}: while that is down, it opens nothing.",
        else: ""
      )
  end

  def usage(%Grant{kind: :request} = grant) do
    params = Enum.map_join(grant.params, &(" " <> Param.describe(&1) <> "."))

    ~s[use: #{Grant.signature(grant)} --reason "why now". MWT builds #{grant.method} #{grant.url} and sends it through its proxy, putting the token in on the way out, and gives you the answer: its body on stdout, its HTTP status on stderr; exit 0 for 2xx, 22 otherwise. An answer that echoes the token is cut.] <>
      params <> openness_words(grant)
  end

  def usage(%Grant{kind: :agent_commands}),
    do:
      ~s[use: mwt run --reason "what it does, and why it must run there" -- COMMAND runs a command you write on the user's machine, as them, once they approve it. The last resort: read mwt help run first.]

  def usage(%Grant{kind: :command} = grant) do
    params = Enum.map_join(grant.params, &(" " <> Param.describe(&1) <> "."))

    ~s[use: #{Grant.signature(grant)} --reason "why now". It runs the user's own script on their machine; you send no command.] <>
      params <> openness_words(grant)
  end

  # How open a fixed call is, for agents too: a value it can turn into
  # code is said, so nothing reads it as narrower than it is.
  defp openness_words(grant) do
    case MWTClient.Sandbox.Openness.grade(grant) do
      %{grade: :narrow} -> ""
      %{grade: grade} -> " How open: #{MWTClient.Sandbox.Openness.words(grade)}."
      nil -> ""
    end
  end

  defp approval(%Grant{kind: :agent_commands}),
    do: "uses: the user approves every run, always; none is handed a credential's value"

  defp approval(%Grant{kind: :command} = grant) do
    if Grant.auto_approved?(grant),
      do: "uses: every run goes through without asking for now",
      else: "uses: the user approves every run"
  end

  defp approval(%Grant{} = grant) do
    what =
      case grant.kind do
        :network -> "connection"
        :mwt -> "call"
        _request -> "request"
      end

    # MWT asks about each request it reads on a network grant, and about
    # a connection it can't read as a whole.
    what =
      if grant.kind == :network,
        do: "request MWT reads, or connection it can't read,",
        else: what

    cond do
      not Grant.on?(grant) ->
        "uses: each #{what} waits for the user's approval once on"

      Enum.any?(grant.allowances, &(&1.pattern == :all)) and grant.kind == :network ->
        "uses: everything through it goes without asking for now; one with a credential also needs that credential's grant"

      Enum.any?(grant.allowances, &(&1.pattern == :all)) ->
        "uses: every #{what} goes through for now"

      true ->
        "uses: each #{what} waits for the user's approval (it can hang for minutes)"
    end
  end

  defp state(%Grant{proposal: %{reviewed_at: nil} = proposal}, _now),
    do:
      "off, proposed by #{proposal.agent} and not reviewed yet: the user must accept it on its page before anything turns it on"

  defp state(%Grant{state: :on, expires_at: %DateTime{} = at}, now) do
    minutes = max(div(DateTime.diff(at, now), 60), 0)
    "on until #{Calendar.strftime(at, "%H:%M")} UTC (#{minutes} min left)"
  end

  defp state(%Grant{state: :on} = grant, now) do
    if Grant.on?(grant, now),
      do: "on until the user turns it off",
      else: state(Grant.put_down(grant), now)
  end

  defp state(%Grant{}, _now), do: "off: it gives nothing; ask for it to be turned on"

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

  # The hosts a network grant leaves out, which only a grant over them
  # gives (`Grant.except`).
  defp except_words(%Grant{except: [_ | _] = except}),
    do:
      ", nor #{Enum.join(except, ", ")} and the names under them, which it leaves out: " <>
        "only a grant naming them gives them"

  defp except_words(%Grant{}), do: ""
end
