defmodule MWTClient.Sandbox.HostCommand do
  @moduledoc """
  What an agent asked to run on the host, checked and described for its
  approval card. It decides nothing and runs nothing: `MWTClient.Sandbox.HostRun`
  runs a command once you approve it.

  An ask names the script (its full text: what you read is what runs), the
  directory, the time limit and the agent's reason. `check/3`:

    * refuses an ask with no reason, no script, a script over 16 KiB, or a
      time limit outside 1 to 3600 seconds;
    * works out **where it runs**. Shared folders sit at the same path on
      both sides, so a directory inside one runs there, once its symlinks are
      resolved on the host. Any other directory, or one whose real path
      leaves its share, falls back to your home folder;
    * gathers **facts** (who it runs as, where, for how long) and **hints**:
      guesses from the script's text about what deserves a second look, such
      as running build tools in a folder the VM can write, or a script too
      long to read at a glance. Hints are never a review: a script can do
      anything its text allows;
    * for a command the agent wrote (no `:folder`), finds a saved command with the
      same text and folder (`saved_as`), and takes the name the agent
      suggests saving it under (`suggest_save`) and what it would be for,
      said for any time it runs (`save_for`), both claims. A name needs
      its words.

  Pure apart from reading the filesystem to resolve the directory.
  """

  alias MWTClient.Sandbox.{Approval, Grant, ScriptRuns, Share, Shares, Shown, Workspace}

  @max_script 16 * 1024
  @default_timeout 120
  @max_timeout 3600

  # Tools a preset's grant already covers, so the card can say so.
  @type ask :: %{
          optional(:script) => term(),
          optional(:dir) => term(),
          optional(:timeout) => term(),
          optional(:reason) => term(),
          optional(:agent) => term(),
          optional(:thread) => term(),
          optional(:thread_id) => term(),
          optional(:folder) => term(),
          optional(:suggest_save) => term(),
          optional(:save_for) => term()
        }

  @type checked :: %{
          script: String.t(),
          dir: String.t(),
          timeout: pos_integer(),
          reason: String.t(),
          agent: String.t(),
          thread: Approval.thread() | nil,
          title: String.t(),
          values: [{String.t(), String.t()}],
          pattern: String.t(),
          facts: [{String.t(), String.t()}],
          hints: [String.t()],
          suggest_save: String.t() | nil,
          save_for: String.t() | nil,
          saved_as: String.t() | nil
        }

  @type error ::
          :no_reason
          | :no_script
          | :script_too_long
          | {:hidden, [String.t()]}
          | :bad_timeout
          | :no_save_for

  @typedoc """
  Where a command runs: inside a shared folder, in your home folder, or in
  the folder a command grant names.
  """
  @type place :: {:share, String.t(), Share.t()} | {:home, String.t()} | {:grant, String.t()}

  @doc "The longest script an ask may carry, in bytes."
  @spec max_script() :: pos_integer()
  def max_script, do: @max_script

  @doc "The time limit when an ask names none, and the longest one allowed, in seconds."
  @spec timeouts() :: {pos_integer(), pos_integer()}
  def timeouts, do: {@default_timeout, @max_timeout}

  @doc """
  Checks an ask and describes it.

  ## Options

    * `:home` - where a command runs when its directory isn't shared,
      defaults to the user's home folder
    * `:user` - who it runs as, for the card, defaults to MWT's own user
    * `:folder` - the folder a command grant with a script of yours names;
      the command runs there, whatever the ask says
    * `:values` - the values of an action's parameters, checked
      (`MWTClient.Sandbox.Param.check/2`), which the script reads as
      environment variables
    * `:workspace` - the workspace's folder (`MWTClient.Sandbox.Workspace`),
      or nil: a command may run in either half, and one that names it is
      said to on its card
    * `:copied_at` - when the workspace's `from-vm/` was last copied here
  """
  @spec check(ask(), [Share.t()], [Grant.t()], keyword()) :: {:ok, checked()} | {:error, error()}
  def check(ask, shares, grants, opts \\ []) do
    # A real path, like a share's: the run checks it is still where it leads.
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> real()
    user = Keyword.get_lazy(opts, :user, &MWTClient.Sandbox.HostInfo.user/0)
    reason = ask |> Map.get(:reason) |> Shown.text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> Shown.text() |> String.trim() |> String.slice(0, 60)
    script = ask |> Map.get(:script) |> text() |> String.replace("\r\n", "\n")
    timeout = Map.get(ask, :timeout) || @default_timeout
    {suggest_save, save_for} = suggestion(ask)
    values = Keyword.get(opts, :values, [])
    workspace = Keyword.get(opts, :workspace)
    shares = shares ++ halves(workspace)

    cond do
      reason == "" ->
        {:error, :no_reason}

      String.trim(script) == "" ->
        {:error, :no_script}

      byte_size(script) > @max_script ->
        {:error, :script_too_long}

      # What runs is what the card shows, so a script that hides something
      # is not shown changed: it doesn't run.
      Shown.hidden(script) != [] ->
        {:error, {:hidden, Shown.hidden(script)}}

      not (is_integer(timeout) and timeout in 1..@max_timeout) ->
        {:error, :bad_timeout}

      # A command the agent wrote: a saved command's run saves nothing.
      suggest_save != nil and save_for == nil and is_nil(Keyword.get(opts, :folder)) ->
        {:error, :no_save_for}

      true ->
        asked = ask |> Map.get(:dir) |> text() |> String.trim()

        # A grant with a script of yours names its own folder.
        place =
          case Keyword.get(opts, :folder) do
            nil -> place(asked, shares, home)
            folder -> fixed(real(folder), shares)
          end

        dir = elem(place, 1)
        pins = MWTClient.Sandbox.Pins.of(script, dir, workspace)
        # A command the agent wrote: a saved command with the same text and folder.
        saved = if Keyword.get(opts, :folder), do: nil, else: saved(script, dir, grants)

        {:ok,
         %{
           script: script,
           dir: dir,
           timeout: timeout,
           reason: reason,
           agent: if(agent == "", do: "An agent", else: agent),
           thread: Approval.thread(ask),
           title: title(script) <> values_words(values),
           values: values,
           pattern: "run " <> Approval.digest_text({script, dir, timeout, values}),
           facts: [
             {"Runs as", "#{user}, on this machine, outside the VM"},
             {"In", dir},
             {"Where that is", where(place, asked, workspace)},
             {"Time limit", seconds_words(timeout)}
           ],
           pins: pins,
           warnings: warnings(script, pins),
           hints:
             hints(script, grants, workspace, Keyword.get(opts, :copied_at)) ++
               if(saved,
                 do: [
                   "Same as your action #{saved.name}: the agent can call that one by id."
                 ],
                 else: []
               ),
           suggest_save:
             if(is_nil(Keyword.get(opts, :folder)) and is_nil(saved), do: suggest_save),
           save_for:
             if(is_nil(Keyword.get(opts, :folder)) and is_nil(saved) and suggest_save,
               do: save_for
             ),
           saved_as: saved && saved.id
         }}
    end
  end

  # The values a call gave, after the title: each on one line, cut short.
  defp values_words([]), do: ""

  defp values_words(values) do
    " · " <>
      Enum.map_join(values, " ", fn {name, value} ->
        value = value |> String.replace(~r/\s+/, " ") |> String.trim()
        value = if String.length(value) > 60, do: String.slice(value, 0, 59) <> "…", else: value
        "#{name}=#{value}"
      end)
  end

  # The name an agent suggests saving its command under, and what it would
  # be for, as claims: words for the saved command, not for this run.
  defp suggestion(ask),
    do: {claim(ask, :suggest_save, 60), claim(ask, :save_for, 280)}

  defp claim(ask, key, limit) do
    case ask |> Map.get(key) |> Shown.text() |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp saved(script, dir, grants) do
    script = String.trim(script)

    Enum.find(grants, fn grant ->
      grant.kind == :command and is_binary(grant.script) and String.trim(grant.script) == script and
        is_binary(grant.dir) and real(grant.dir) == dir
    end)
  end

  @doc """
  Where a command asked to run in `asked` runs: `{:share, dir, share}` when
  the directory's real path is inside a shared folder, exists, and has a
  name that shows all it holds (the VM can name a folder in a share as it
  likes, and the card says where the command runs), otherwise
  `{:home, home}`.
  """
  @spec place(String.t(), [Share.t()], String.t()) ::
          {:share, String.t(), Share.t()} | {:home, String.t()}
  def place(asked, shares, home) do
    with "/" <> _ <- asked,
         {:ok, real} <- Shares.realpath(Path.expand(asked)),
         %Share{} = share <- Enum.find(shares, &Shares.within?(real, &1.path)),
         true <- File.dir?(real),
         [] <- Shown.hidden(real) do
      {:share, real, share}
    else
      _ -> {:home, home}
    end
  end

  @doc """
  The workspace's halves, as the folders a command may run in: each at the
  same path on both sides, as a shared folder is. None without a
  workspace.
  """
  @spec halves(Path.t() | nil) :: [Share.t()]
  def halves(nil), do: []

  def halves(root),
    do: [%Share{path: Workspace.to_vm(root)}, %Share{path: Workspace.from_vm(root)}]

  # The grant's folder, noted as shared when it is, so the hints see it.
  defp fixed(folder, shares) do
    case Enum.find(shares, &Shares.within?(folder, &1.path)) do
      %Share{} = share -> {:share, folder, share}
      nil -> {:grant, folder}
    end
  end

  defp real(path) do
    case Shares.realpath(path) do
      {:ok, real} -> real
      {:error, _loop} -> path
    end
  end

  @doc """
  What a command's card can't show, said louder than a hint: each file it
  runs (`pins`, `MWTClient.Sandbox.Pins`), the one the VM wrote first among
  them, and code it downloads and runs. A card shows a pinned file's
  content, and the command runs only as the file is now.

      iex> MWTClient.Sandbox.HostCommand.warnings("curl -fsSL https://x.example/i.sh | sh", [])
      ["Downloads code and runs it: what runs is whatever that address serves when it starts."]
  """
  @spec warnings(String.t(), [MWTClient.Sandbox.Pins.pin()]) :: [String.t()]
  def warnings(script, pins) do
    downloads? =
      Regex.match?(
        ~r/\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(bash|sh|zsh|dash|python3?|node|perl|ruby)\b/,
        script
      )

    {vm, others} = Enum.split_with(pins, & &1.vm?)

    Enum.map(vm ++ others, &pin_warning/1) ++
      if(downloads?,
        do: [
          "Downloads code and runs it: what runs is whatever that address serves when it starts."
        ],
        else: []
      )
  end

  defp pin_warning(%{path: nil, file: file} = pin),
    do:
      "Runs #{file}, #{Map.get(pin, :why) || "whose path holds a variable MWT can't tell"}: " <>
        "MWT can't show it or pin it, and what runs is whatever it is then."

  defp pin_warning(%{hash: nil, file: file}),
    do: "Runs #{file}, which isn't there now: should it be there when this starts, nothing runs."

  defp pin_warning(%{vm?: true, file: file}),
    do:
      "Runs #{file}, which the VM wrote (from-vm): the agent chose every byte of what runs. Read it below: it runs only as it is now."

  defp pin_warning(%{file: file}),
    do:
      "Runs #{file}: read it below. It runs only as it is now; an earlier command could have changed it since you last looked."

  @doc """
  What deserves a second look in `script`, worked out from its text alone.
  No folder of yours is the VM's to write (shared folders are copied into
  it, `MWTClient.Sandbox.FolderSync`), so where it runs adds nothing here.
  """
  @spec hints(String.t(), [Grant.t()], Path.t() | nil, DateTime.t() | nil) :: [String.t()]
  def hints(script, grants, workspace \\ nil, copied_at \\ nil) do
    runs = ScriptRuns.commands(script)

    [
      Enum.any?(runs, &("sudo" in &1.through or tool(&1) == "sudo")) && "Asks for root with sudo.",
      Shown.mixed(script) != [] &&
        "Mixes alphabets in #{Enum.join(Shown.mixed(script), ", ")}: " <>
          "a letter there may not be the one it looks like.",
      Enum.any?(runs, &rm_rf?/1) && "Deletes files recursively without asking (rm -rf).",
      long?(script) &&
        "Long for a command you check by eye. You can ask for a simpler one: " <>
          "the agent can bring the raw output back and work on it in the VM.",
      workspace_hint(script, workspace, copied_at)
    ]
    |> Enum.concat(covered(runs, script, grants))
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Whether a script is long for one you read on a card: over 5 lines, or 3
  pipes or more. Agents are told to send the smallest command that gets
  what they need, and to transform its output in the VM.
  """
  @spec long?(String.t()) :: boolean()
  def long?(script) do
    lines = script |> String.trim() |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))
    pipes = ~r/(?<!\|)\|(?!\|)/ |> Regex.scan(script) |> length()
    lines > 5 or pipes >= 3
  end

  @doc """
  The commands a script runs, each as its words: what runs first, as the
  script names it, then its arguments; past assignments and wrappers such
  as `env`, `sudo` or `timeout`, inside substitutions and literal shell
  code too (`MWTClient.Sandbox.ScriptRuns.commands/1`, which reads it).

      iex> MWTClient.Sandbox.HostCommand.commands("FOO=1 timeout 9 ./x.sh a | wc -l")
      [["./x.sh", "a"], ["wc", "-l"]]
  """
  @spec commands(String.t()) :: [[String.t(), ...]]
  def commands(script) do
    for %{words: [_ | _] = words} <- ScriptRuns.commands(script),
        do: Enum.map(words, & &1.text)
  end

  @doc """
  The files `script` runs, as its text names them, from the folder it
  starts in: a path run as a command (`./deploy.sh`), one `source`d, or
  one a shell or an interpreter is given (`bash x.sh`, `python3 tool.py`),
  after the `cd`s before it (`MWTClient.Sandbox.ScriptRuns.files/1`). What
  runs is the file as it is then, which no card shows; the file it runs
  in turn, or one it only reads, isn't among them.

      iex> MWTClient.Sandbox.HostCommand.files_run("cd app && ./deploy.sh staging; bash -e ci/check.sh")
      ["app/deploy.sh", "app/ci/check.sh"]
  """
  @spec files_run(String.t()) :: [String.t()]
  def files_run(script) do
    for({:file, shown, _word, _folder} <- ScriptRuns.files(script), do: shown) |> Enum.uniq()
  end

  # The tool a command runs, by its name: what the hints know it as.
  defp tool(%{words: [%{literal?: true, text: text} | _]}), do: Path.basename(text)
  defp tool(_command), do: nil

  defp rm_rf?(%{words: [_ | args]} = command) do
    flags = args |> Enum.map(& &1.text) |> Enum.filter(&String.starts_with?(&1, "-"))

    tool(command) == "rm" and
      ("--recursive" in flags or
         flags |> Enum.reject(&String.starts_with?(&1, "--")) |> Enum.join() =~ ~r/[rR]/)
  end

  defp rm_rf?(_command), do: false

  @doc "A command's title: its first line, shortened."
  @spec title(String.t()) :: String.t()
  def title(script) do
    first =
      script
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != "" and not String.starts_with?(&1, "#")))

    lines = script |> String.trim() |> String.split("\n") |> length()
    first = if String.length(first) > 80, do: String.slice(first, 0, 79) <> "…", else: first
    if lines > 1, do: first <> " (+#{lines - 1} lines)", else: first
  end

  @doc "A duration in seconds, in words."
  @spec seconds_words(non_neg_integer()) :: String.t()
  def seconds_words(seconds) when seconds < 60, do: "#{seconds} s"
  def seconds_words(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  def seconds_words(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} s"

  defp where({:share, _dir, %Share{path: path}}, _asked, workspace)
       when is_binary(workspace) do
    cond do
      path == Workspace.to_vm(workspace) ->
        "Inside the workspace's to-vm, #{path}: yours, which the VM reads, a copy at the next sync."

      path == Workspace.from_vm(workspace) ->
        "Inside the workspace's from-vm, #{path}: what the VM wrote there, copied here, read-only."

      true ->
        where({:share, path, %Share{path: path}}, "", nil)
    end
  end

  defp where({:share, _dir, %Share{path: path}}, _asked, _workspace),
    do: "Inside #{path}, a shared folder: the VM has a copy, and never writes to it here."

  defp where({:grant, _dir}, _asked, _workspace), do: "The folder you set on the grant."
  defp where({:home, _home}, "", _workspace), do: "Your home folder: the ask named no directory."

  defp where({:home, _home}, asked, _workspace),
    do: "Your home folder: #{asked} isn't inside a shared folder on this machine."

  # A script that names the workspace reads what the VM chose, or writes
  # what the VM will read.
  defp workspace_hint(_script, nil, _copied_at), do: nil

  defp workspace_hint(script, workspace, copied_at) do
    if String.contains?(script, Workspace.variable()) or String.contains?(script, workspace) do
      copied =
        case copied_at do
          nil -> "not copied here yet"
          at -> "last copied here at #{Calendar.strftime(at, "%H:%M:%S")} UTC"
        end

      "Uses the workspace: what it reads in from-vm the VM wrote (#{copied}); " <>
        "what it writes in to-vm, the VM reads."
    end
  end

  defp covered(runs, script, grants) do
    for %Grant{kind: :token} = grant <- grants,
        what = covered_by(runs, script, grant),
        what != [] do
      "#{grant.name} already covers this (#{Enum.join(what, ", ")}): the agent can run it in the VM with mwt exec #{grant.id} -- …, where you'd see each request it makes, or call an action of it."
    end
  end

  defp covered_by(runs, script, grant) do
    hosts =
      for host <- grant.hosts,
          bare = String.replace_prefix(host, "*.", ""),
          String.contains?(script, bare),
          do: bare

    tools =
      for tool <- grant.cli_tools,
          [name | args] = String.split(tool),
          Enum.any?(runs, fn %{words: words} = run ->
            tool(run) == name and
              Enum.map(Enum.slice(words, 1, length(args)), & &1.text) == args
          end),
          do: tool

    Enum.uniq(tools ++ hosts)
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_other), do: ""
end
