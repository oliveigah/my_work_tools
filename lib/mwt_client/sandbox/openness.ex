defmodule MWTClient.Sandbox.Openness do
  @moduledoc """
  How open a fixed call is: what the values an agent gives can make it
  do, read from its template and its parameters' schemas. A fixed call
  is only as narrow as its template is for every value its schema
  allows, and one can be open use in disguise while it still looks
  fixed: its page, the cards it raises and `mwt grants` say its grade.

    * `:narrow` - each value only picks among what the template names: one
      of a list, a number, a date, yes or no, or a pattern's whose text
      proves it holds no space, no character the shell acts on, no `/`,
      no `..` and no leading `-`;
    * `:wide` - a value reaches anything of a kind: any name or path (a
      word), any text as one argument;
    * `:open` - a value can become code or a command. In a command (read
      by `MWTClient.Sandbox.ScriptRuns`, behind any wrapper, in a brace
      group, a function or literal shell code): the command run or its
      folder, the file a shell or an interpreter runs, code for a shell
      (`eval`, `sh -c`, `trap`, `watch`, fed on stdin or in `<<<`) or an
      interpreter (`python -c`, `node -e`/`-p`, `perl -e`/`-E`), awk's
      program, a sed script, what `xargs` turns into arguments, a command
      on another machine or in a container (`ssh`, `kubectl exec`,
      `docker run`), a variable programs read from the environment
      (`LD_PRELOAD=$P`), or text read outside double quotes, which the
      shell splits and globs. In a request: a query the service runs, or
      the whole body.

  Beside the grade, the files a command runs (`./deploy.sh`): it is only
  as narrow as they are, and they can change after you saved it.

  Its premise: it reads text and guesses, so it can miss what makes a
  call open. It only warns: it never lets anything through, and never
  makes a call ask (Q8).
  """

  alias MWTClient.Sandbox.{Grant, HostCommand, Param, ParamSchema, ScriptRuns}

  @type grade :: :narrow | :wide | :open
  @type t :: %{grade: grade(), why: [String.t()], files: [String.t()]}

  # What a value read bare must not hold to stay narrow: what the shell
  # splits on or acts on, and a path's separators.
  @unsafe MapSet.new(~c" \t\n\v\f\r|&;<>()$`\\\"'*?[]#~{}!/")

  @doc """
  The grade of a fixed call: a saved command or a request action. Nil
  for any other grant.

      iex> alias MWTClient.Sandbox.{Grant, Openness, Param}
      iex> {:ok, params} = Param.parse("POD: word: the pod")
      iex> Openness.grade(%Grant{id: "l", name: "L", kind: :command, script: ~s(kubectl logs "$POD"), params: params}).grade
      :wide
      iex> {:ok, params} = Param.parse("ARGS: text: what to pass")
      iex> Openness.grade(%Grant{id: "k", name: "K", kind: :command, script: "kubectl $ARGS", params: params}).grade
      :open
  """
  @spec grade(Grant.t()) :: t() | nil
  def grade(%Grant{kind: :command, script: script, params: params}) when is_binary(script) do
    runs = ScriptRuns.commands(script)
    verdicts = Enum.map(params, &command_param(&1, runs))
    combine(verdicts, HostCommand.files_run(script))
  end

  def grade(%Grant{kind: :request} = grant) do
    verdicts = Enum.map(grant.params, &request_param(&1, grant))
    combine(verdicts, [])
  end

  def grade(%Grant{}), do: nil

  @doc "The grade in a word."
  @spec words(grade()) :: String.t()
  def words(:narrow), do: "Narrow"
  def words(:wide), do: "Wide"
  def words(:open), do: "Open"

  @doc "What a grade means, in a line."
  @spec meaning(grade()) :: String.t()
  def meaning(:narrow), do: "each value only picks among what the template names."

  def meaning(:wide),
    do:
      "a value can reach anything of a kind; the call is as narrow as the token or the script behind it."

  def meaning(:open),
    do:
      "a value can become code or a command: it is open use with extra steps, whatever it looks like."

  defp combine(verdicts, files) do
    grade = Enum.max_by([:narrow | Enum.map(verdicts, &elem(&1, 0))], &rank/1)
    why = for {g, reason} <- verdicts, g != :narrow, rank(g) == rank(grade), do: reason
    %{grade: grade, why: why, files: files}
  end

  defp rank(:narrow), do: 0
  defp rank(:wide), do: 1
  defp rank(:open), do: 2

  # A saved command's parameter: where the script reads it, and what its
  # schema lets through.
  defp command_param(%Param{name: name} = param, runs) do
    reads = "$#{name}"

    case Enum.find_value(runs, &code_position(&1, name)) do
      nil ->
        if Enum.any?(runs, &bare?(&1, name)) and Param.spaces?(param.schema),
          do:
            {:open,
             "#{reads} is read outside double quotes and can hold spaces or wildcards: the shell splits it into several arguments, options included, and globs it."},
          else: by_schema(param, reads)

      where ->
        {:open, "#{reads} #{where}."}
    end
  end

  defp bare?(run, name), do: Enum.any?(run.all, &(name in &1.bare))

  # Where a parameter becomes code or the command in one command the
  # script runs, in words, or nil.
  defp code_position(run, name) do
    in? = fn word -> name in word.vars end
    behind = if run.through == [], do: "", else: " (behind #{Enum.join(run.through, ", ")})"

    cond do
      run.unread != nil and Enum.any?(run.all, in?) ->
        "is in a command MWT can't read: #{run.unread}"

      match?([_ | _], run.words) and in?.(hd(run.words)) ->
        "is the command that runs, or its folder" <> behind

      Enum.any?(run.files, in?) ->
        "picks the file that runs" <> behind

      (code = Enum.find(run.code, fn {_kind, _how, word} -> in?.(word) end)) != nil ->
        code_words(code) <> behind

      run.stdin_code != nil and fed?(run.stdin, in?) ->
        "is fed to #{run.stdin_code} as code" <> behind

      fed?(run.args_from, in?) ->
        "becomes arguments xargs splits and gives #{Enum.map_join(run.words, " ", & &1.text)}"

      (set = Enum.find(run.assigns, fn {var, word} -> in?.(word) and Param.env_reader(var) end)) !=
          nil ->
        {var, _word} = set
        "sets #{var}, which #{Param.env_reader(var)} reads from the environment" <> behind

      true ->
        tool_position(run, in?)
    end
  end

  defp code_words({:shell, how, _word}), do: "is run by the shell as code (#{how})"

  defp code_words({:other, how, _word}),
    do: "is run as #{how |> String.split() |> hd()} code (#{how})"

  # Whether what a command reads holds the parameter: text given on
  # stdin, or anything the commands piped into it say.
  defp fed?({:text, word}, in?), do: in?.(word)
  defp fed?({:pipe, commands}, in?), do: Enum.any?(commands, &Enum.any?(&1.all, in?))
  defp fed?(_stdin, _in?), do: false

  # Tools that run what they are given, by their own grammar.
  defp tool_position(%{words: [program | args]} = run, in?) do
    name = if program.literal?, do: Path.basename(program.text)

    sub =
      Enum.find_value(args, &((&1.literal? and not String.starts_with?(&1.text, "-")) && &1.text))

    cond do
      name == "ssh" and Enum.any?(args, in?) ->
        "runs as a command on another machine (ssh)"

      name in ["kubectl", "oc"] and sub in ["run", "debug"] and Enum.any?(args, in?) ->
        "runs as a command in a container (#{name} #{sub})"

      name in ["kubectl", "oc"] and sub in ["exec", "attach"] and container_command?(args, in?) ->
        "runs as a command in a container (#{name} #{sub})"

      name in ["docker", "podman", "nerdctl"] and sub in ["run", "exec", "create"] and
          Enum.any?(args, in?) ->
        "runs as a command in a container (#{name} #{sub})"

      name in ["awk", "gawk", "mawk", "nawk"] and Enum.any?(awk_program(args), in?) ->
        "is awk program text, which can run commands"

      name in ["sed", "gsed"] and sed_runs?(args, run, in?) ->
        "is a sed script or what it runs, which can run commands (e)"

      true ->
        nil
    end
  end

  defp tool_position(_run, _in?), do: nil

  # After `--`, kubectl exec's command; with none, anywhere.
  defp container_command?(args, in?) do
    case Enum.split_while(args, &(not (&1.literal? and &1.text == "--"))) do
      {_before, [_dashes | command]} -> Enum.any?(command, in?)
      {all, []} -> Enum.any?(all, in?)
    end
  end

  # awk's program: `-f FILE`'s file, `-e`/`--source` text, or the first
  # operand.
  defp awk_program(args), do: awk_program(args, [])

  defp awk_program([], found), do: found

  defp awk_program([%{literal?: true, text: flag}, value | rest], found)
       when flag in ["-f", "-e", "--source", "--file", "-E"],
       do: awk_program(rest, [value | found])

  defp awk_program([%{literal?: true, text: flag}, _value | rest], found)
       when flag in ["-F", "-v", "--assign", "--field-separator"],
       do: awk_program(rest, found)

  defp awk_program([%{literal?: true, text: "--"}, program | _], []), do: [program]

  defp awk_program([word | rest], found) do
    cond do
      word.literal? and String.starts_with?(word.text, "-") -> awk_program(rest, found)
      found == [] -> [word]
      true -> found
    end
  end

  # sed's script holds the value, or a script that runs what it reads
  # (`e`) is given it as a file or on stdin.
  defp sed_runs?(args, run, in?) do
    {scripts, operands} = sed_args(args, [], [])

    Enum.any?(scripts, in?) or
      (Enum.any?(scripts, &(&1.literal? and sed_executes?(&1.text))) and
         (Enum.any?(operands, in?) or fed?(run.stdin, in?)))
  end

  defp sed_args([], scripts, operands), do: {scripts, Enum.reverse(operands)}

  defp sed_args([%{literal?: true, text: flag}, script | rest], scripts, operands)
       when flag in ["-e", "--expression", "-f", "--file"],
       do: sed_args(rest, [script | scripts], operands)

  defp sed_args([%{literal?: true, text: flag}, _n | rest], scripts, operands)
       when flag in ["-l", "--line-length"],
       do: sed_args(rest, scripts, operands)

  defp sed_args([word | rest], scripts, operands) do
    cond do
      word.literal? and String.starts_with?(word.text, "-") -> sed_args(rest, scripts, operands)
      scripts == [] and operands == [] -> sed_args(rest, [word], operands)
      true -> sed_args(rest, scripts, [word | operands])
    end
  end

  # An `e` command, or the `e` flag of an `s` command: GNU sed runs the
  # text as a shell command.
  defp sed_executes?(script),
    do: script =~ ~r/(^|[;\n{}])\s*e(\s|;|$)/ or script =~ ~r/s(.).*\1.*\1[gpiImMw0-9]*e/

  # A request action's parameter: the whole body, or a query the service
  # runs, is open; anything else by its schema.
  defp request_param(%Param{name: name} = param, grant) do
    reads = "$#{name}"
    body = String.trim(grant.body || "")

    cond do
      body in [reads, "${#{name}}", ~s("#{reads}")] ->
        {:open, "#{reads} is the whole body: the request can be anything the endpoint takes."}

      Regex.match?(~r/"query"\s*:\s*"[^"]*\$\{?#{name}\b/, body) ->
        {:open, "#{reads} is a query the service runs."}

      true ->
        by_schema(param, reads)
    end
  end

  defp by_schema(%Param{schema: schema}, reads) do
    cond do
      Map.has_key?(schema, "enum") or Map.has_key?(schema, "const") ->
        {:narrow, nil}

      schema["type"] in ["integer", "number", "boolean"] ->
        {:narrow, nil}

      schema["format"] in ["date", "date-time"] ->
        {:narrow, nil}

      narrow_pattern?(schema["pattern"]) ->
        {:narrow, nil}

      schema["format"] == "word" ->
        {:wide, "#{reads} can be any name or path below where it is used."}

      Map.has_key?(schema, "pattern") ->
        {:wide,
         "#{reads} can be any text its pattern lets through, as one argument: the pattern doesn't show it keeps to names."}

      true ->
        {:wide, "#{reads} can be any text, as one argument."}
    end
  end

  # A pattern is narrow only when its text proves a value can't hold what
  # the shell or a path acts on, start as an option, or go up a folder;
  # anything it can't read proves nothing. MWT's floor refuses a leading
  # `-` and `..` already: this asks the pattern for them too, so a grade
  # never rests on another check.
  defp narrow_pattern?(pattern) when is_binary(pattern) do
    case ParamSchema.pattern_reach(pattern) do
      {:ok, reach} ->
        MapSet.disjoint?(reach.chars, @unsafe) and not MapSet.member?(reach.first, ?-) and
          not reach.dot_dot?

      :unknown ->
        false
    end
  end

  defp narrow_pattern?(_none), do: false
end
