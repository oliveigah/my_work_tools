defmodule MWTClient.Sandbox.ScriptRuns do
  @moduledoc """
  What a shell script runs, read from its text: each command it starts,
  past the wrappers in front of it, with the code it hands a shell or an
  interpreter and the files it runs, in the folder it runs in at that
  point. One reader for what decides, the files MWT pins
  (`MWTClient.Sandbox.Pins`), and for what warns, a card's hints
  (`MWTClient.Sandbox.HostCommand`) and a fixed call's grade
  (`MWTClient.Sandbox.Openness`), so the three agree.

  It reads the shell's grammar as bash does, for what matters here:

    * words with their quotes (`'…'`, `"…"`, `$'…'`) and backslashes, and
      what the shell expands (`$X`, `${X}`, `$(…)`, backticks, `~`,
      wildcards, `{a,b}`) kept apart from literal text: a path is known
      only when nothing in it is expanded (`literal?`);
    * commands split at `;`, `&`, `&&`, `||`, `|`, new lines, `( … )`,
      `{ …; }`, `if`/`while`/`for`/`case`, and the ones inside `$(…)`,
      backticks and `<(…)`, which run too; here-documents are text;
    * wrappers skipped with their own options, as each takes them: `env`
      (and `VAR=value`), `exec`, `command`, `builtin`, `nohup`, `time`,
      `nice`, `timeout`, `sudo`, `doas`, `xargs`, `stdbuf`, `ionice`,
      `chrt`, `setsid`, `flock`, `watch`; `find -exec` runs a command too;
    * shells and interpreters with their own options: `sh -c` (bundled
      too, `-lc`), `python -c` (`-Ic`), `node -e`/`-p`, `perl -e`/`-E`,
      `ruby -e`, `php -r` are code, not files, and `python -m` a module;
      shell code given as literal text (`bash -c '…'`, `eval`, `trap`,
      `watch`, a here-document fed to a shell) is read in turn; `source
      x`, `. x`; a file fed to a shell on stdin (`bash < x`, `cat x | sh`);
    * `cd` (and `pushd`) moves where later relative paths are, up to the
      end of the subshell, pipeline part or background job it is in. A
      `cd` whose failure doesn't stop what follows (no `&&`, no `|| exit`,
      no `set -e`) is marked unsure: the folder may not be there.

  Its premise: it reads text, and where it can't tell what runs it says
  so rather than guess: a variable in the command or in a file's path (a
  word that isn't `literal?`), a `cd` to a variable or to `-`, shell code
  built from a variable, a shell's stdin that isn't a file, a wrapper's
  options from a variable (`files/1`'s `:unread`). What it can't see at
  all: what a file it runs does in turn, functions and aliases the shell
  already has, `PATH` and `CDPATH`, and tools that run commands they're
  given in a way it doesn't know (`make`, `parallel`, `tmux`, `ssh` runs
  elsewhere).
  """

  @typedoc """
  A piece of a word: literal text, quoted (`:lit`) or not (`:bare`, where
  wildcards expand), a variable (`:var`, quoted or not), any other
  expansion (`:expansion`, with the variables it reads), a command
  substitution (`:subst`) or process substitution (`:proc`) with its
  script, `~` or `~user` (`:tilde`), or text a wrapper replaces
  (`:other`, `{}` for `find -exec` and `xargs -I`).
  """
  @type part ::
          {:lit, String.t()}
          | {:bare, String.t()}
          | {:var, String.t(), boolean()}
          | {:expansion, String.t(), [String.t()], boolean()}
          | {:subst, String.t(), boolean()}
          | {:proc, String.t()}
          | {:tilde, String.t()}
          | {:other, String.t()}

  @typedoc """
  One word, its quotes removed: its `parts`; its `text` as the script
  writes it, expansions in their own form (`$X`, `$(…)`); whether it is
  `literal?`, nothing in it expanded; the variables it reads (`vars`,
  inside substitutions too) and those it reads outside double quotes
  (`bare`), where the shell splits and globs them; and the scripts of the
  substitutions in it (`inner`), which run.
  """
  @type word :: %{
          parts: [part()],
          text: String.t(),
          literal?: boolean(),
          vars: [String.t()],
          bare: [String.t()],
          inner: [String.t()]
        }

  @typedoc """
  The folder a command runs in, from the one the script starts in: each
  `cd` since, with whether its failure stops what follows (`sure?`), or
  `:home` for a bare `cd`; `:unknown` after one MWT can't follow.
  """
  @type folder :: [{:cd, word(), boolean()} | :home] | :unknown

  @typedoc """
  What a command reads on stdin: a file (`< x`), text (`<<< x`, a
  here-document) or what the commands before it in a pipe write.
  """
  @type stdin :: nil | {:file, word()} | {:text, word()} | {:pipe, [command()]}

  @typedoc """
  One command the script starts:

    * `words`: what runs and its arguments, past wrappers and `VAR=value`;
      empty when nothing runs (a wrapper alone, `for …`, `[[ … ]]`);
    * `all`: every word as written, wrappers and assignments included;
    * `through`: the wrappers and the code it runs behind (`sudo`,
      `find -exec`, `bash -c`);
    * `assigns`: the variables it sets for what it runs (`VAR=value`);
    * `code`: text it runs as code: `{:shell, how, word}` for shell code
      (`bash -c`, `eval`, `trap`, `watch`), `{:other, how, word}` for an
      interpreter's (`python3 -c`);
    * `files`: the files it runs: what runs, when it is a path or holds a
      variable; the script a shell or an interpreter is given; the file
      it sources;
    * `stdin_code`: the shell or interpreter that runs as code what it
      reads on `stdin`, or nil;
    * `args_from`: where `xargs` reads the arguments it adds;
    * `unread`: why what it runs can't be told, or nil;
    * `folder`: where it runs.
  """
  @type command :: %{
          words: [word()],
          all: [word()],
          through: [String.t()],
          assigns: [{String.t(), word()}],
          code: [{:shell | :other, String.t(), word()}],
          files: [word()],
          stdin_code: String.t() | nil,
          stdin: stdin(),
          args_from: stdin(),
          unread: String.t() | nil,
          folder: folder()
        }

  @typedoc """
  What a script runs that isn't on `PATH`: a file, as the script names
  it (shown in the folder it runs in), with its word and folder to find
  it by; or something that runs files MWT can't tell (`:unread`), with
  why, said to complete "Runs …, ".
  """
  @type entry :: {:file, String.t(), word(), folder()} | {:unread, String.t(), String.t()}

  @shells ~w(sh bash zsh dash ksh mksh ash yash posh)
  @keywords ~w(if then else elif fi do done while until ! { } esac in)
  # Programs that name what they run: a path into the machine's own
  # folders is that program, as its name found on PATH is, and an upgrade
  # changes it. Not pinned.
  @system ~w(/usr/bin/ /usr/sbin/ /bin/ /sbin/ /usr/lib/ /usr/libexec/ /nix/store/ /run/current-system/)
  # Deeper than this, code in code in code…: said, not read.
  @max_depth 8

  # Each wrapper's options as getopt reads them: letters that take a
  # value (`arg`, the next word or the rest of the bundle), letters that
  # take only the rest of their bundle (`attached`), long names that take
  # the next word (`long`), options after which nothing runs (`none`,
  # `long_none`), and how many words it takes before the command (`pos`).
  # An option a wrapper has that isn't here reads as a flag.
  @wrappers %{
    "nohup" => %{},
    "setsid" => %{},
    "builtin" => %{},
    "exec" => %{arg: "a"},
    "command" => %{none: "vV"},
    "time" => %{arg: "fo", long: ~w(format output)},
    "nice" => %{arg: "n", long: ~w(adjustment), numeric?: true},
    "timeout" => %{arg: "ks", long: ~w(kill-after signal), pos: 1},
    "stdbuf" => %{arg: "ioe", long: ~w(input output error)},
    "ionice" => %{
      arg: "cnpPu",
      long: ~w(class classdata pid pgid uid),
      none: "pPu",
      long_none: ~w(pid pgid uid)
    },
    "chrt" => %{
      arg: "TPD",
      long: ~w(sched-runtime sched-period sched-deadline),
      none: "pm",
      long_none: ~w(pid max),
      pos: 1
    },
    "sudo" => %{
      arg: "aCcDgpRrTtUu",
      long:
        ~w(user group chdir close-from login-class prompt role type command-timeout other-user host chroot),
      none: "eKlVvh",
      long_none: ~w(edit list validate version remove-timestamp help)
    },
    "doas" => %{arg: "Cu"},
    "env" => %{arg: "uCS", long: ~w(unset chdir split-string)},
    "xargs" => %{
      arg: "aEdILnPs",
      attached: "eil",
      long: ~w(arg-file delimiter max-args max-procs max-chars process-slot-var)
    },
    "flock" => %{arg: "wEc", long: ~w(timeout wait conflict-exit-code command)},
    "watch" => %{arg: "n", attached: "d", long: ~w(interval)}
  }

  @doc """
  The commands `script` starts, those inside substitutions and inside
  shell code it gives as literal text included, in the order they appear.

      iex> alias MWTClient.Sandbox.ScriptRuns
      iex> for c <- ScriptRuns.commands("FOO=1 sudo -u ci timeout 30 ./deploy.sh prod | tee log"),
      ...>   do: {Enum.map(c.words, & &1.text), c.through}
      [{["./deploy.sh", "prod"], ["sudo", "timeout"]}, {["tee", "log"], []}]
  """
  @spec commands(String.t()) :: [command()]
  def commands(script) when is_binary(script) do
    {commands, _state} = read(script, %{folder: [], errexit: false}, 0)
    commands
  end

  @doc """
  What `script` runs that isn't on `PATH`, in order, each once: each file
  (`{:file, shown, word, folder}`), and what runs files MWT can't tell
  (`{:unread, shown, why}`).

      iex> alias MWTClient.Sandbox.ScriptRuns
      iex> for {kind, shown, _, _} <- ScriptRuns.files("cd app && ./deploy.sh; bash -e ci/x.sh"), do: {kind, shown}
      [{:file, "app/deploy.sh"}, {:file, "app/ci/x.sh"}]
      iex> ScriptRuns.files(~s(bash -c "$CMD"))
      [{:unread, "bash -c $CMD", "shell code built from a variable"}]
  """
  @spec files(String.t()) :: [entry()]
  def files(script) when is_binary(script) do
    script |> commands() |> Enum.flat_map(&entries/1) |> Enum.uniq()
  end

  @doc """
  A word's value, given the values of the variables MWT knows (`~` is
  `HOME`'s): `{:ok, text}`, or `:error` when anything else in it is
  expanded.

      iex> alias MWTClient.Sandbox.ScriptRuns
      iex> [%{words: [_, word]}] = ScriptRuns.commands(~s(bash "$MWT_WORKSPACE/to-vm/x.sh"))
      iex> ScriptRuns.value(word, %{"MWT_WORKSPACE" => "/ws"})
      {:ok, "/ws/to-vm/x.sh"}
      iex> ScriptRuns.value(word, %{})
      :error
  """
  @spec value(word(), %{String.t() => String.t()}) :: {:ok, String.t()} | :error
  def value(%{parts: parts}, vars) do
    Enum.reduce_while(parts, {:ok, ""}, fn part, {:ok, done} ->
      case part_value(part, vars) do
        {:ok, text} -> {:cont, {:ok, done <> text}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp part_value({:lit, text}, _vars), do: {:ok, text}

  defp part_value({:bare, text}, _vars),
    do: if(glob?(text) or brace?(text), do: :error, else: {:ok, text})

  defp part_value({:var, name, _quoted}, vars), do: known(vars, name)
  defp part_value({:tilde, ""}, vars), do: known(vars, "HOME")
  defp part_value(_part, _vars), do: :error

  defp known(vars, name) do
    case Map.get(vars, name) do
      value when is_binary(value) -> {:ok, value}
      _unknown -> :error
    end
  end

  @doc "Whether a word names a path from where the command runs, rather than from `/`, `~` or a variable."
  @spec relative?(word()) :: boolean()
  def relative?(%{parts: [first | _]} = word) do
    match?({kind, _} when kind in [:lit, :bare], first) and
      not String.starts_with?(word.text, ["/", "~"])
  end

  def relative?(_word), do: true

  # ── Reading: tokens, then commands, then what each runs ─────────────

  defp read(_script, state, depth) when depth > @max_depth,
    do: {[unread(state, "code nested deeper than MWT reads")], state}

  defp read(script, state, depth) do
    {tokens, bodies} = lex(script)
    {items, _rest} = parse_items(tokens, fn _ -> false end)
    walk_items(items, state, %{bodies: bodies, depth: depth})
  end

  defp unread(state, why) do
    %{record(context(state.folder, nil, []), []) | unread: why}
  end

  # ── Lexer: words, operators, redirections, here-document bodies ─────

  defp lex(text) do
    state = %{tokens: [], parts: nil, bodies: %{}, pending: [], delim: nil, refs: 0}
    state = scan(state, text)
    {Enum.reverse(state.tokens), state.bodies}
  end

  @operators ~w(;;& ;; ;& ; && &>> &> & || |& | <<< <<- << <& <> < >> >& >| > \( \))
  @redirections ~w(&>> &> <<< <<- << <& <> < >> >& >|) ++ [">"]

  defp scan(state, ""), do: end_word(state)
  defp scan(state, "\\\n" <> rest), do: scan(state, rest)

  defp scan(state, "\\" <> rest) do
    case next_char(rest) do
      {char, rest} -> state |> add({:lit, char}) |> scan(rest)
      nil -> state |> add({:lit, "\\"}) |> scan("")
    end
  end

  defp scan(state, "'" <> rest) do
    {text, rest} = until(rest, "'")
    state |> add({:lit, text}) |> scan(rest)
  end

  defp scan(state, "$'" <> rest) do
    {text, rest} = ansi(rest, "")
    state |> add({:lit, text}) |> scan(rest)
  end

  defp scan(state, "$\"" <> rest), do: scan(state, "\"" <> rest)

  defp scan(state, "\"" <> rest) do
    {parts, rest} = quoted(rest, [], :double)
    parts |> Enum.reduce(add(state, {:lit, ""}), &add(&2, &1)) |> scan(rest)
  end

  defp scan(state, "$" <> rest) do
    {part, rest} = dollar(rest, false)
    state |> add(part) |> scan(rest)
  end

  defp scan(state, "`" <> rest) do
    {inner, rest} = backtick(rest, "")
    state |> add({:subst, inner, false}) |> scan(rest)
  end

  defp scan(%{parts: nil} = state, "#" <> rest) do
    case :binary.split(rest, "\n") do
      [_comment, rest] -> scan(state, "\n" <> rest)
      [_comment] -> scan(state, "")
    end
  end

  defp scan(state, <<char, rest::binary>>) when char in [?\s, ?\t, ?\r],
    do: state |> end_word() |> scan(rest)

  defp scan(state, "\n" <> rest) do
    {state, rest} = state |> end_word() |> push({:op, "\n"}) |> bodies(rest)
    scan(state, rest)
  end

  defp scan(state, <<dir, "(", rest::binary>>) when dir in [?<, ?>] do
    {inner, rest} = balanced(rest, ?(, ?))
    state |> add({:proc, inner}) |> scan(rest)
  end

  defp scan(state, "(" <> rest) do
    if assigning?(state) do
      # An array: NAME=( … ), one word.
      {inner, rest} = balanced(rest, ?(, ?))
      state |> add({:expansion, "(" <> inner <> ")", names(inner), false}) |> scan(rest)
    else
      operator(state, "(", rest)
    end
  end

  defp scan(state, text) do
    case Enum.find(@operators, &String.starts_with?(text, &1)) do
      nil ->
        {char, rest} = next_char(text)
        state |> add({:bare, char}) |> scan(rest)

      op ->
        operator(state, op, binary_part(text, byte_size(op), byte_size(text) - byte_size(op)))
    end
  end

  defp operator(state, op, rest) when op in @redirections do
    # `2>&1`: the digits before it are a descriptor, not a word.
    state =
      case state.parts do
        [{:bare, digits}] -> if digits =~ ~r/\A\d+\z/, do: %{state | parts: nil}, else: state
        _other -> state
      end

    state = state |> end_word() |> push({:redir, op})
    state = if op in ["<<", "<<-"], do: %{state | delim: op}, else: state
    scan(state, rest)
  end

  defp operator(state, op, rest), do: state |> end_word() |> push({:op, op}) |> scan(rest)

  defp assigning?(%{parts: [{:bare, text}]}), do: text =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\+?=\z/
  defp assigning?(_state), do: false

  defp next_char(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp next_char(<<byte, rest::binary>>), do: {<<byte>>, rest}
  defp next_char(""), do: nil

  defp until(text, stop) do
    case :binary.split(text, stop) do
      [before, rest] -> {before, rest}
      [before] -> {before, ""}
    end
  end

  defp push(state, token), do: %{state | tokens: [token | state.tokens]}

  defp add(%{parts: [{kind, done} | parts]} = state, {kind, text}) when kind in [:lit, :bare],
    do: %{state | parts: [{kind, done <> text} | parts]}

  defp add(state, part), do: %{state | parts: [part | state.parts || []]}

  defp end_word(%{parts: nil} = state), do: state

  defp end_word(%{delim: nil} = state),
    do: push(%{state | parts: nil}, {:word, word(Enum.reverse(state.parts))})

  # A here-document's delimiter: quoted in any part, its body is literal.
  defp end_word(state) do
    parts = Enum.reverse(state.parts)
    delim = Enum.map_join(parts, &part_text/1)
    expands? = Enum.all?(parts, &match?({:bare, _}, &1))
    pending = state.pending ++ [{state.refs, delim, state.delim == "<<-", expands?}]

    %{state | parts: nil, delim: nil, pending: pending, refs: state.refs + 1}
    |> push({:heredoc, state.refs})
  end

  # Here-documents' bodies, after the line their redirections are on.
  defp bodies(%{pending: []} = state, rest), do: {state, rest}

  defp bodies(%{pending: [{ref, delim, strip?, expands?} | pending]} = state, rest) do
    {lines, rest} = body_lines(rest, delim, strip?, [])
    state = %{state | pending: pending, bodies: Map.put(state.bodies, ref, {lines, expands?})}
    bodies(state, rest)
  end

  defp body_lines(text, delim, strip?, done) do
    {line, rest} =
      case :binary.split(text, "\n") do
        [line, rest] -> {line, rest}
        [line] -> {line, nil}
      end

    line = if strip?, do: String.trim_leading(line, "\t"), else: line

    cond do
      line == delim -> {done |> Enum.reverse() |> Enum.join("\n"), rest || ""}
      rest == nil -> {[line | done] |> Enum.reverse() |> Enum.join("\n"), ""}
      true -> body_lines(rest, delim, strip?, [line | done])
    end
  end

  # Inside double quotes (`:double`, up to the closing one) or a
  # here-document that expands (`:body`, to the end): only `$`, backticks
  # and backslashes before them, `\` and new lines act.
  defp quoted("", parts, _mode), do: {Enum.reverse(parts), ""}
  defp quoted("\"" <> rest, parts, :double), do: {Enum.reverse(parts), rest}
  defp quoted("\\\n" <> rest, parts, mode), do: quoted(rest, parts, mode)

  defp quoted(<<"\\", char, rest::binary>>, parts, mode) when char in [?$, ?`, ?", ?\\],
    do: quoted(rest, lit(parts, <<char>>), mode)

  defp quoted("$" <> rest, parts, mode) do
    {part, rest} = dollar(rest, true)
    quoted(rest, [part | parts] |> merge(), mode)
  end

  defp quoted("`" <> rest, parts, mode) do
    {inner, rest} = backtick(rest, "")
    quoted(rest, [{:subst, inner, true} | parts], mode)
  end

  defp quoted(text, parts, mode) do
    {char, rest} = next_char(text)
    quoted(rest, lit(parts, char), mode)
  end

  defp lit([{:lit, done} | parts], text), do: [{:lit, done <> text} | parts]
  defp lit(parts, text), do: [{:lit, text} | parts]

  defp merge([{:lit, b}, {:lit, a} | parts]), do: [{:lit, a <> b} | parts]
  defp merge(parts), do: parts

  # After a `$`: what it expands, and the text after it.
  defp dollar("((" <> rest, quoted?) do
    {inner, rest} = arithmetic(rest, 0, "")
    {{:expansion, "$((" <> inner <> "))", arith_names(inner), quoted?}, rest}
  end

  defp dollar("(" <> rest, quoted?) do
    {inner, rest} = balanced(rest, ?(, ?))
    {{:subst, inner, quoted?}, rest}
  end

  defp dollar("{" <> rest, quoted?) do
    {inner, rest} = balanced(rest, ?{, ?})

    if inner =~ ~r/\A([A-Za-z_][A-Za-z0-9_]*|[0-9]|[@*#?$!-])\z/,
      do: {{:var, inner, quoted?}, rest},
      else: {{:expansion, "${" <> inner <> "}", param_names(inner), quoted?}, rest}
  end

  defp dollar(<<char, _::binary>> = text, quoted?)
       when char in ?A..?Z or char in ?a..?z or char == ?_ do
    [name] = Regex.run(~r/\A[A-Za-z_][A-Za-z0-9_]*/, text)
    {{:var, name, quoted?}, binary_part(text, byte_size(name), byte_size(text) - byte_size(name))}
  end

  defp dollar(<<char, rest::binary>>, quoted?) when char in ~c"0123456789@*#?$!-",
    do: {{:var, <<char>>, quoted?}, rest}

  defp dollar(text, true), do: {{:lit, "$"}, text}
  defp dollar(text, false), do: {{:bare, "$"}, text}

  # The text up to the bracket closing one already open, skipping quotes
  # and escapes; all of it when none closes.
  defp balanced(text, open, close), do: balanced(text, open, close, 1, [])

  defp balanced("", _open, _close, _depth, done),
    do: {done |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp balanced(<<"\\", char::utf8, rest::binary>>, open, close, depth, done),
    do: balanced(rest, open, close, depth, [<<"\\", char::utf8>> | done])

  defp balanced(<<quote, rest::binary>>, open, close, depth, done) when quote in [?', ?", ?`] do
    {inside, rest} = skip_quote(rest, quote, "")
    balanced(rest, open, close, depth, [<<quote>> <> inside | done])
  end

  defp balanced(<<char, rest::binary>>, open, close, depth, done) do
    cond do
      char == close and depth == 1 -> {done |> Enum.reverse() |> IO.iodata_to_binary(), rest}
      char == close -> balanced(rest, open, close, depth - 1, [<<char>> | done])
      char == open -> balanced(rest, open, close, depth + 1, [<<char>> | done])
      true -> balanced(rest, open, close, depth, [<<char>> | done])
    end
  end

  defp skip_quote("", _quote, done), do: {done, ""}

  defp skip_quote(<<"\\", char::utf8, rest::binary>>, quote, done) when quote != ?',
    do: skip_quote(rest, quote, done <> <<"\\", char::utf8>>)

  defp skip_quote(<<char, rest::binary>>, quote, done) when char == quote,
    do: {done <> <<char>>, rest}

  defp skip_quote(<<char, rest::binary>>, quote, done),
    do: skip_quote(rest, quote, done <> <<char>>)

  defp arithmetic("", _depth, done), do: {done, ""}
  defp arithmetic("))" <> rest, 0, done), do: {done, rest}
  defp arithmetic("(" <> rest, depth, done), do: arithmetic(rest, depth + 1, done <> "(")
  defp arithmetic(")" <> rest, depth, done), do: arithmetic(rest, depth - 1, done <> ")")

  defp arithmetic(<<char, rest::binary>>, depth, done),
    do: arithmetic(rest, depth, done <> <<char>>)

  defp backtick("", done), do: {done, ""}
  defp backtick("`" <> rest, done), do: {done, rest}

  defp backtick(<<"\\", char, rest::binary>>, done) when char in [?`, ?\\, ?$],
    do: backtick(rest, done <> <<char>>)

  defp backtick(<<char, rest::binary>>, done), do: backtick(rest, done <> <<char>>)

  # `$'…'`: its escapes, as bash reads them; one it doesn't know stays.
  @ansi %{?n => "\n", ?t => "\t", ?r => "\r", ?a => "\a", ?b => "\b", ?e => "\e", ?E => "\e"}
  @ansi Map.merge(@ansi, %{?f => "\f", ?v => "\v", ?\\ => "\\", ?' => "'", ?" => "\"", ?? => "?"})

  defp ansi("", done), do: {done, ""}
  defp ansi("'" <> rest, done), do: {done, rest}

  defp ansi(<<"\\x", rest::binary>>, done) do
    case Regex.run(~r/\A[0-9A-Fa-f]{1,2}/, rest) do
      [hex] -> ansi(drop(rest, hex), done <> <<String.to_integer(hex, 16)>>)
      nil -> ansi(rest, done <> "\\x")
    end
  end

  defp ansi(<<"\\", digit, _::binary>> = text, done) when digit in ?0..?7 do
    [octal] = Regex.run(~r/\A[0-7]{1,3}/, binary_part(text, 1, byte_size(text) - 1))
    ansi(drop(text, "\\" <> octal), done <> <<rem(String.to_integer(octal, 8), 256)>>)
  end

  defp ansi(<<"\\", char, rest::binary>>, done) when is_map_key(@ansi, char),
    do: ansi(rest, done <> Map.fetch!(@ansi, char))

  defp ansi(<<char, rest::binary>>, done), do: ansi(rest, done <> <<char>>)

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  # The variables an expansion's text reads: a name after `$` or `${`.
  # For a substitution's script too: a scan of its text rather than a
  # read of it, so a word costs its length however deep substitutions
  # nest. It counts `'$X'` as read, which only makes a warning louder.
  defp names(text) do
    ~r/\$\{?[!#]?([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp param_names(inner) do
    lead =
      Regex.run(~r/\A[!#]?([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/, inner, capture: :all_but_first)

    Enum.uniq((lead || []) ++ names(inner))
  end

  # In arithmetic a bare name is a variable too.
  defp arith_names(text),
    do: ~r/[A-Za-z_][A-Za-z0-9_]*/ |> Regex.scan(text) |> List.flatten() |> Enum.uniq()

  # ── Words ────────────────────────────────────────────────────────────

  defp word(parts) do
    parts = tilde(parts)
    inner = Enum.flat_map(parts, &part_inner/1)
    inner_vars = Enum.flat_map(inner, &names/1)

    %{
      parts: parts,
      text: Enum.map_join(parts, &part_text/1),
      literal?: Enum.all?(parts, &literal_part?/1),
      vars: Enum.uniq(Enum.flat_map(parts, &part_vars/1) ++ inner_vars),
      bare:
        Enum.uniq(
          Enum.flat_map(parts, fn
            {:var, name, false} -> [name]
            {:expansion, _text, names, false} -> names
            {:subst, inner, false} -> names(inner)
            _part -> []
          end)
        ),
      inner: inner
    }
  end

  # `~` or `~user` unquoted at the start, up to the first `/`.
  defp tilde([{:bare, "~" <> rest} | parts]) do
    case :binary.split(rest, "/") do
      [user, path] -> [{:tilde, user}, {:bare, "/" <> path} | parts]
      [user] when parts == [] -> [{:tilde, user}]
      [_user] -> [{:bare, "~" <> rest} | parts]
    end
  end

  defp tilde(parts), do: parts

  defp part_text({kind, text}) when kind in [:lit, :bare, :other], do: text
  defp part_text({:var, name, _quoted}), do: "$" <> name
  defp part_text({:expansion, text, _names, _quoted}), do: text
  defp part_text({:subst, inner, _quoted}), do: "$(" <> inner <> ")"
  defp part_text({:proc, inner}), do: "<(" <> inner <> ")"
  defp part_text({:tilde, user}), do: "~" <> user

  defp literal_part?({:lit, _text}), do: true
  defp literal_part?({:bare, text}), do: not glob?(text) and not brace?(text)
  defp literal_part?(_part), do: false

  defp part_vars({:var, name, _quoted}), do: [name]
  defp part_vars({:expansion, _text, names, _quoted}), do: names
  defp part_vars({:tilde, ""}), do: ["HOME"]
  defp part_vars(_part), do: []

  defp part_inner({:subst, inner, _quoted}), do: [inner]
  defp part_inner({:proc, inner}), do: [inner]
  defp part_inner(_part), do: []

  # Unquoted, `*`, `?` and a `[…]` expand to file names.
  defp glob?(text), do: String.contains?(text, ["*", "?"]) or text =~ ~r/\[[^\]]*\]/
  defp brace?(text), do: text =~ ~r/\{[^{}\s]*(,|\.\.)[^{}\s]*\}/

  defp body_word(body) do
    {parts, _rest} = quoted(body, [], :body)
    word([{:lit, ""} | parts] |> merge_all())
  end

  defp merge_all(parts) do
    parts
    |> Enum.reduce([], fn
      {:lit, b}, [{:lit, a} | done] -> [{:lit, a <> b} | done]
      part, done -> [part | done]
    end)
    |> Enum.reverse()
  end

  # A word read from text a wrapper builds (`watch`'s command, `eval`'s
  # arguments): the words joined with spaces.
  defp joined([]), do: word([{:lit, ""}])

  defp joined(words) do
    words
    |> Enum.map(& &1.parts)
    |> Enum.intersperse([{:lit, " "}])
    |> List.flatten()
    |> merge_all()
    |> word()
  end

  # A word with text a wrapper replaces in it (`{}`): never literal.
  defp taint(word, mark) do
    if String.contains?(word.text, mark),
      do: %{word | parts: word.parts ++ [{:other, ""}], literal?: false},
      else: word
  end

  # The literal text a word starts with, and the word past its first `n`
  # bytes: an option's attached value (`-cCODE`, `--file=x`).
  defp lead(%{parts: parts}) do
    parts
    |> Enum.take_while(&match?({kind, _} when kind in [:lit, :bare], &1))
    |> Enum.map_join(&elem(&1, 1))
  end

  defp past(%{parts: parts}, n), do: parts |> past_parts(n) |> word()

  defp past_parts(parts, 0), do: parts

  defp past_parts([{kind, text} | parts], n) when kind in [:lit, :bare] do
    if byte_size(text) <= n,
      do: past_parts(parts, n - byte_size(text)),
      else: [{kind, binary_part(text, n, byte_size(text) - n)} | parts]
  end

  defp past_parts(parts, _n), do: parts

  defp literal(%{literal?: true, text: text}), do: text
  defp literal(_word), do: nil

  # ── Parser: lists, and-or lists, pipelines, commands ────────────────

  defp parse_items(tokens, stop?), do: parse_items(tokens, stop?, [])

  defp parse_items([], _stop?, items), do: {Enum.reverse(items), []}

  defp parse_items([{:op, op} | rest], stop?, items) when op in [";", "\n", "&", ")"] do
    if op == ")" and stop?.([{:op, op} | rest]),
      do: {Enum.reverse(items), [{:op, op} | rest]},
      else: parse_items(rest, stop?, items)
  end

  defp parse_items(tokens, stop?, items) do
    if stop?.(tokens) do
      {Enum.reverse(items), tokens}
    else
      case parse_and_or(tokens) do
        {[], [_skipped | rest]} ->
          parse_items(rest, stop?, items)

        {and_or, rest} ->
          {term, rest} =
            case rest do
              [{:op, term} | rest] when term in [";", "\n", "&"] -> {term, rest}
              rest -> {nil, rest}
            end

          parse_items(rest, stop?, [{and_or, term} | items])
      end
    end
  end

  defp parse_and_or(tokens) do
    case parse_pipeline(tokens) do
      {[], rest} ->
        {[], rest}

      {pipeline, [{:op, op} | rest]} when op in ["&&", "||"] ->
        {more, rest} = rest |> skip_lines() |> parse_and_or()
        {[{pipeline, op} | more], rest}

      {pipeline, rest} ->
        {[{pipeline, nil}], rest}
    end
  end

  defp parse_pipeline(tokens) do
    case parse_command(tokens) do
      {nil, rest} ->
        {[], rest}

      {command, [{:op, op} | rest]} when op in ["|", "|&"] ->
        {more, rest} = rest |> skip_lines() |> parse_pipeline()
        {[command | more], rest}

      {command, rest} ->
        {[command], rest}
    end
  end

  defp skip_lines([{:op, "\n"} | rest]), do: skip_lines(rest)
  defp skip_lines(tokens), do: tokens

  defp parse_command([{:op, "("} | rest]) do
    {items, rest} = parse_items(rest, &match?([{:op, ")"} | _], &1))

    rest =
      case rest do
        [{:op, ")"} | rest] -> rest
        rest -> rest
      end

    {redirs, rest} = parse_redirs(rest, [])
    {{:subshell, items, redirs}, rest}
  end

  defp parse_command([{:word, %{literal?: true, text: "case"}} | rest]), do: parse_case(rest)
  defp parse_command(tokens), do: parse_simple(tokens, [], [])

  defp parse_simple([{:word, word} | rest], words, redirs),
    do: parse_simple(rest, [word | words], redirs)

  defp parse_simple([{:redir, op}, {:word, word} | rest], words, redirs),
    do: parse_simple(rest, words, [{op, word} | redirs])

  defp parse_simple([{:redir, op}, {:heredoc, ref} | rest], words, redirs),
    do: parse_simple(rest, words, [{op, {:heredoc, ref}} | redirs])

  defp parse_simple([{:redir, _op} | rest], words, redirs), do: parse_simple(rest, words, redirs)

  defp parse_simple([{:heredoc, _ref} | rest], words, redirs),
    do: parse_simple(rest, words, redirs)

  # `name() { …; }`: a function's name is no command; its body follows.
  defp parse_simple([{:op, "("}, {:op, ")"} | rest], [_name], []),
    do: {{:simple, [], []}, rest}

  defp parse_simple(tokens, [], []), do: {nil, tokens}

  defp parse_simple(tokens, words, redirs),
    do: {{:simple, Enum.reverse(words), Enum.reverse(redirs)}, tokens}

  defp parse_redirs([{:redir, op}, {:word, word} | rest], redirs),
    do: parse_redirs(rest, [{op, word} | redirs])

  defp parse_redirs([{:redir, op}, {:heredoc, ref} | rest], redirs),
    do: parse_redirs(rest, [{op, {:heredoc, ref}} | redirs])

  defp parse_redirs(tokens, redirs), do: {Enum.reverse(redirs), tokens}

  # `case WORD in PATTERN) LIST ;; … esac`: the patterns are no commands.
  defp parse_case(tokens) do
    {subject, rest} = Enum.split_while(tokens, &(not match?({:word, %{text: "in"}}, &1)))
    rest = Enum.drop(rest, 1)
    {branches, rest} = case_branches(rest, [])
    subject = for {:word, word} <- subject, do: word
    {{:case, subject, branches}, rest}
  end

  defp case_branches(tokens, branches) do
    case Enum.drop_while(tokens, &match?({:op, op} when op in [";", "\n"], &1)) do
      [] ->
        {Enum.reverse(branches), []}

      [{:word, %{text: "esac"}} | rest] ->
        {Enum.reverse(branches), rest}

      tokens ->
        tokens = Enum.drop_while(tokens, &(&1 == {:op, "("}))
        {_pattern, rest} = Enum.split_while(tokens, &(&1 != {:op, ")"}))

        stop? = fn
          [{:op, op} | _] -> op in [";;", ";&", ";;&"]
          [{:word, %{text: "esac"}} | _] -> true
          _tokens -> false
        end

        {items, rest} = parse_items(Enum.drop(rest, 1), stop?)

        rest =
          case rest do
            [{:op, op} | rest] when op in [";;", ";&", ";;&"] -> rest
            rest -> rest
          end

        case_branches(rest, [items | branches])
    end
  end

  # ── Walking: what runs, where, in what order ─────────────────────────

  defp walk_items(items, state, env) do
    Enum.reduce(items, {[], state}, fn {and_or, term}, {done, state} ->
      {commands, after_it} = walk_and_or(and_or, state, env)
      # A job in the background runs in a subshell: its `cd` stays there.
      {done ++ commands, if(term == "&", do: state, else: after_it)}
    end)
  end

  defp walk_and_or([], state, _env), do: {[], state}

  defp walk_and_or([{pipeline, op} | more], state, env) do
    # A `cd` is sure when what follows runs only if it worked.
    sure? = state.errexit or op == "&&" or (op == "||" and exits?(more))
    {commands, state} = walk_pipeline(pipeline, state, env, sure?)
    {rest, state} = walk_and_or(more, state, env)
    {commands ++ rest, state}
  end

  defp exits?([{[{:simple, [word | _], _} | _], _op} | _]),
    do: literal(word) in ["exit", "return"]

  defp exits?(_more), do: false

  defp walk_pipeline([command], state, env, sure?),
    do: walk_command(command, state, env, nil, sure?)

  # Each part of a pipe runs in a subshell: no `cd` in one outlives it.
  defp walk_pipeline(commands, state, env, sure?) do
    {done, _before} =
      Enum.reduce(commands, {[], nil}, fn command, {done, before} ->
        {these, _state} = walk_command(command, state, env, before && {:pipe, before}, sure?)
        {done ++ these, these}
      end)

    {done, state}
  end

  defp walk_command({:subshell, items, _redirs}, state, env, _stdin, _sure?) do
    {commands, _inside} = walk_items(items, state, env)
    {commands, state}
  end

  defp walk_command({:case, subject, branches}, state, env, _stdin, _sure?) do
    syntax = record(context(state.folder, nil, subject), [])
    inner = Enum.flat_map(subject, &inner_commands(&1, state, env))

    Enum.reduce(branches, {[syntax | inner], state}, fn items, {done, state} ->
      {commands, state} = walk_items(items, state, env)
      {done ++ commands, state}
    end)
  end

  defp walk_command({:simple, [], []}, state, _env, _stdin, _sure?), do: {[], state}

  defp walk_command({:simple, words, redirs}, state, env, piped, sure?) do
    stdin = stdin_of(redirs, env) || piped
    {command, effect, also} = unwrap(words, context(state.folder, stdin, words))

    # Substitutions run wherever they are: in a word, a redirection's
    # target, a here-document that expands.
    targets = for {_op, %{} = word} <- redirs, do: word

    bodies =
      for {op, {:heredoc, _ref} = heredoc} <- redirs,
          {:text, word} <- [stdin_of([{op, heredoc}], env)],
          do: word

    inner = Enum.flat_map(words ++ targets ++ bodies, &inner_commands(&1, state, env))
    runs = Enum.flat_map([command | also], &[&1 | code_commands(&1, state, env)])
    {evaluated, state} = effect(effect, command, state, env, sure?)
    {runs ++ evaluated ++ inner, state}
  end

  defp inner_commands(word, state, env) do
    Enum.flat_map(word.inner, fn script ->
      {commands, _state} = read(script, state, env.depth + 1)
      commands
    end)
  end

  # Shell code a command gives as literal text, read in turn: in the
  # folder it runs in, the folder it moves to staying in there. `eval`'s
  # is read as its effect, in the same shell.
  defp code_commands(command, state, env) do
    from_code =
      for {:shell, how, word} <- command.code, how != "eval", word.literal? do
        {commands, _state} =
          read(word.text, %{state | folder: command.folder, errexit: false}, env.depth + 1)

        behind(commands, command.through ++ [how])
      end

    from_stdin =
      case {command.stdin_code, command.stdin} do
        {how, {:text, word}} when is_binary(how) and word.literal? ->
          {commands, _state} =
            read(word.text, %{state | folder: command.folder, errexit: false}, env.depth + 1)

          [behind(commands, command.through ++ [how])]

        _other ->
          []
      end

    List.flatten(from_code ++ from_stdin)
  end

  # What a command's code runs is behind it, and behind how it runs it
  # (`watch` is both the wrapper and how: said once).
  defp behind(commands, through) do
    through = Enum.dedup(through)
    Enum.map(commands, &%{&1 | through: through ++ &1.through})
  end

  defp effect(nil, _command, state, _env, _sure?), do: {[], state}

  defp effect({:cd, step}, _command, state, _env, sure?),
    do: {[], %{state | folder: step(state.folder, step, sure?)}}

  defp effect(:cd_unknown, _command, state, _env, _sure?), do: {[], %{state | folder: :unknown}}
  defp effect({:errexit, on?}, _command, state, _env, _sure?), do: {[], %{state | errexit: on?}}

  defp effect({:eval, word}, command, state, env, _sure?) do
    if word.literal? do
      {commands, state} = read(word.text, state, env.depth + 1)
      {behind(commands, command.through ++ ["eval"]), state}
    else
      {[], state}
    end
  end

  defp step(:unknown, _step, _sure?), do: :unknown
  defp step(_folder, :home, _sure?), do: [:home]
  defp step(folder, word, sure?), do: folder ++ [{:cd, word, sure?}]

  defp stdin_of(redirs, env) do
    Enum.reduce(redirs, nil, fn
      {"<", word}, _stdin ->
        {:file, word}

      {"<<<", word}, _stdin ->
        {:text, word}

      {op, {:heredoc, ref}}, _stdin when op in ["<<", "<<-"] ->
        case Map.get(env.bodies, ref, {"", false}) do
          {body, true} -> {:text, body_word(body)}
          {body, false} -> {:text, word([{:lit, body}])}
        end

      _other, stdin ->
        stdin
    end)
  end

  # ── Unwrapping: past assignments, keywords and wrappers ──────────────

  defp context(folder, stdin, all) do
    %{through: [], assigns: [], folder: folder, stdin: stdin, args_from: nil, all: all}
  end

  defp record(context, words) do
    %{
      words: words,
      all: context.all,
      through: context.through,
      assigns: context.assigns,
      code: [],
      files: [],
      stdin_code: nil,
      stdin: context.stdin,
      args_from: context.args_from,
      unread: nil,
      folder: context.folder
    }
  end

  defp unwrap([], context), do: {record(context, []), nil, []}

  defp unwrap([word | rest] = words, context) do
    text = literal(word)

    cond do
      assignment(word) != nil ->
        unwrap(rest, %{context | assigns: context.assigns ++ [assignment(word)]})

      text in @keywords ->
        unwrap(rest, context)

      text == "function" ->
        unwrap(rest |> Enum.drop(1) |> Enum.drop_while(&(literal(&1) in ["{", "()"])), context)

      # Words that aren't a command: a loop's list, a test.
      text in ["for", "select", "[[", "(("] ->
        {record(context, []), nil, []}

      wrapper_name(text) != nil ->
        name = wrapper_name(text)
        wrapper(name, rest, %{context | through: context.through ++ [name]})

      true ->
        program(word, rest, record(context, words))
    end
  end

  defp assignment(%{parts: [{:bare, lead} | _]} = word) do
    case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)\+?=/, lead) do
      [prefix, name] -> {name, past(word, byte_size(prefix))}
      nil -> nil
    end
  end

  defp assignment(_word), do: nil

  # A wrapper by its name, or by its path in the machine's folders
  # (`/usr/bin/env`); `./env` is a file of that name.
  defp wrapper_name(nil), do: nil

  defp wrapper_name(text) do
    name = Path.basename(text)

    if Map.has_key?(@wrappers, name) and (name == text or String.starts_with?(text, "/")),
      do: name
  end

  defp wrapper(name, args, context) do
    spec = Map.fetch!(@wrappers, name)
    args = if name == "env", do: Enum.drop_while(args, &(literal(&1) == "-")), else: args

    case options(args, spec) do
      {:unread, why} ->
        {%{record(context, []) | unread: why}, nil, []}

      {:ok, opts, rest} ->
        cond do
          Enum.any?(opts, &none?(&1, spec)) -> {record(context, []), nil, []}
          true -> after_options(name, opts, rest, context, spec)
        end
    end
  end

  defp none?({opt, _value}, spec) when byte_size(opt) == 1,
    do: String.contains?(Map.get(spec, :none, ""), opt)

  defp none?({opt, _value}, spec), do: opt in Map.get(spec, :long_none, [])

  defp opt(opts, keys), do: Enum.find_value(opts, fn {key, value} -> key in keys && value end)
  defp opt?(opts, keys), do: Enum.any?(opts, fn {key, _} -> key in keys end)

  defp after_options("env", opts, rest, context, _spec) do
    context = chdir(context, opt(opts, ["C", "chdir"]))

    case opt(opts, ["S", "split-string"]) do
      nil ->
        unwrap(rest, context)

      %{literal?: true, text: text} ->
        {tokens, _bodies} = lex(text)
        unwrap(for({:word, word} <- tokens, do: word) ++ rest, context)

      _variable ->
        {%{record(context, []) | unread: "with a command line built from a variable (env -S)"},
         nil, []}
    end
  end

  defp after_options("sudo", opts, rest, context, _spec) do
    context = chdir(context, opt(opts, ["D", "chdir"]))

    cond do
      opt?(opts, ["R", "chroot"]) ->
        {%{record(context, []) | unread: "in another root folder (sudo -R)"}, nil, []}

      rest == [] and opt?(opts, ["s", "i", "shell", "login"]) ->
        {%{record(context, []) | stdin_code: "sudo -s"}, nil, []}

      true ->
        unwrap(rest, context)
    end
  end

  defp after_options("doas", opts, rest, context, _spec) do
    if rest == [] and opt?(opts, ["s"]),
      do: {%{record(context, []) | stdin_code: "doas -s"}, nil, []},
      else: unwrap(rest, context)
  end

  # xargs runs its command with arguments it reads on stdin, its own
  # stdin elsewhere; `-I R` puts them where R is.
  defp after_options("xargs", opts, rest, context, _spec) do
    mark =
      case Enum.find(opts, fn {key, _} -> key in ["I", "i", "replace"] end) do
        {"I", %{text: mark}} -> mark
        {_key, %{text: mark}} when mark != "" -> mark
        {_key, _none} -> "{}"
        nil -> nil
      end

    rest = if mark, do: Enum.map(rest, &taint(&1, mark)), else: rest
    context = %{context | args_from: context.stdin, stdin: nil}
    unwrap(rest, context)
  end

  defp after_options("flock", opts, rest, context, _spec) do
    case {opt(opts, ["c", "command"]), rest} do
      {%{} = code, _rest} ->
        {%{record(context, []) | code: [{:shell, "flock -c", code}]}, nil, []}

      {nil, [_file, flag, code | _]} ->
        if literal(flag) in ["-c", "--command"],
          do: {%{record(context, []) | code: [{:shell, "flock -c", code}]}, nil, []},
          else: unwrap(Enum.drop(rest, 1), context)

      {nil, [_file | command]} ->
        unwrap(command, context)

      {nil, []} ->
        {record(context, []), nil, []}
    end
  end

  # watch runs its words, joined, with `sh -c`, but with `-x`.
  defp after_options("watch", opts, rest, context, _spec) do
    cond do
      opt?(opts, ["x", "exec"]) -> unwrap(rest, context)
      rest == [] -> {record(context, []), nil, []}
      true -> {%{record(context, []) | code: [{:shell, "watch", joined(rest)}]}, nil, []}
    end
  end

  defp after_options(_name, _opts, rest, context, spec) do
    rest = Enum.drop(rest, Map.get(spec, :pos, 0))
    unwrap(rest, context)
  end

  defp chdir(context, nil), do: context
  defp chdir(context, word), do: %{context | folder: step(context.folder, word, true)}

  # A wrapper's options, as getopt reads them up to its first operand:
  # `{:ok, [{name, value}], rest}`, or `{:unread, why}` for options that
  # come from a variable.
  defp options(args, spec), do: options(args, spec, [])

  defp options([], _spec, opts), do: {:ok, Enum.reverse(opts), []}

  defp options([word | rest] = args, spec, opts) do
    lead = lead(word)

    cond do
      word.literal? and word.text == "--" ->
        {:ok, Enum.reverse(opts), rest}

      String.starts_with?(lead, "--") ->
        long(word, lead, rest, spec, opts)

      String.starts_with?(lead, "-") and lead != "-" ->
        short(word, String.slice(lead, 1..-1//1), 1, rest, spec, opts)

      # `-$FLAGS`: options MWT can't read.
      lead == "-" and not word.literal? ->
        {:unread, "with options built from a variable"}

      true ->
        {:ok, Enum.reverse(opts), args}
    end
  end

  defp long(word, lead, rest, spec, opts) do
    case String.split(lead, "=", parts: 2) do
      ["--" <> name, _value] ->
        options(rest, spec, [{name, past(word, byte_size(name) + 3)} | opts])

      ["--" <> _name] when not word.literal? ->
        {:unread, "with options built from a variable"}

      ["--" <> name] ->
        cond do
          name not in Map.get(spec, :long, []) -> options(rest, spec, [{name, nil} | opts])
          rest == [] -> {:ok, Enum.reverse([{name, nil} | opts]), []}
          true -> options(tl(rest), spec, [{name, hd(rest)} | opts])
        end
    end
  end

  # One bundle of letters (`-xvf`), from its `at`-th byte.
  defp short(word, "", _at, rest, spec, opts) do
    if word.literal?,
      do: options(rest, spec, opts),
      else: {:unread, "with options built from a variable"}
  end

  defp short(word, <<letter, more::binary>>, at, rest, spec, opts) do
    letter = <<letter>>

    cond do
      Map.get(spec, :numeric?, false) and letter =~ ~r/\d/ ->
        options(rest, spec, opts)

      String.contains?(Map.get(spec, :arg, ""), letter) ->
        # Its value: the rest of the bundle, or the next word.
        if more != "" or not word.literal? do
          options(rest, spec, [{letter, past(word, at + 1)} | opts])
        else
          case rest do
            [value | rest] -> options(rest, spec, [{letter, value} | opts])
            [] -> {:ok, Enum.reverse([{letter, nil} | opts]), []}
          end
        end

      String.contains?(Map.get(spec, :attached, ""), letter) ->
        value = if more == "", do: nil, else: past(word, at + 1)
        options(rest, spec, [{letter, value} | opts])

      true ->
        short(word, more, at + 1, rest, spec, [{letter, nil} | opts])
    end
  end

  # ── What a program runs ──────────────────────────────────────────────

  defp program(word, args, command) do
    name = word |> literal() |> then(&(&1 && Path.basename(&1)))
    command = %{command | files: program_file(word)}

    cond do
      name in @shells -> shell(command, name, args)
      name in ["source", "."] -> sourced(command, args)
      name == "eval" -> eval(command, args)
      name == "trap" -> trap(command, args)
      name in ["cd", "pushd"] -> cd(command, args)
      name == "popd" -> {command, :cd_unknown, []}
      name == "set" -> {command, errexit(args), []}
      name == "find" -> find(command, args)
      name == "su" -> su(command, args)
      name in ~w(export declare typeset local readonly) -> exported(command, args)
      interpreter(name) != nil -> interpreted(command, interpreter(name), name, args)
      true -> {command, nil, []}
    end
  end

  # What runs is a file when it is a path, or holds a variable; a path
  # into the machine's own folders is a program, as its name is.
  defp program_file(word) do
    cond do
      not word.literal? -> [word]
      String.starts_with?(word.text, @system) -> []
      String.contains?(word.text, "/") -> [word]
      true -> []
    end
  end

  defp interpreter(nil), do: nil

  defp interpreter(name) do
    cond do
      name =~ ~r/\A(python|pypy)(\d+(\.\d+)?)?\z/ -> :python
      name in ["node", "nodejs"] -> :node
      name =~ ~r/\Aperl(\d+(\.\d+)*)?\z/ -> :perl
      name =~ ~r/\Aruby(\d+(\.\d+)*)?\z/ -> :ruby
      name =~ ~r/\Aphp(\d+(\.\d+)*)?\z/ -> :php
      true -> nil
    end
  end

  defp sourced(command, [file | _]), do: {%{command | files: command.files ++ [file]}, nil, []}
  defp sourced(command, []), do: {command, nil, []}

  defp eval(command, []), do: {command, nil, []}

  defp eval(command, args) do
    code = joined(args)
    {%{command | code: [{:shell, "eval", code}]}, {:eval, code}, []}
  end

  defp trap(command, args) do
    case Enum.drop_while(args, &(literal(&1) in ["-p", "-l", "--"])) do
      [action, _signal | _] ->
        if literal(action) in ["-", ""],
          do: {command, nil, []},
          else: {%{command | code: [{:shell, "trap", action}]}, nil, []}

      _reset ->
        {command, nil, []}
    end
  end

  defp cd(command, args) do
    case Enum.drop_while(args, &(literal(&1) in ["-L", "-P", "-e", "-@", "--"])) do
      [] -> {command, {:cd, :home}, []}
      [%{literal?: true, text: "-"} | _] -> {command, :cd_unknown, []}
      [%{literal?: true, text: "+" <> _} | _] -> {command, :cd_unknown, []}
      [target | _] -> {command, {:cd, target}, []}
    end
  end

  defp errexit(args) do
    texts = Enum.map(args, &literal/1)

    Enum.find_value(Enum.with_index(texts), fn {text, i} ->
      cond do
        text in ["-o", "+o"] and Enum.at(texts, i + 1) == "errexit" -> {:errexit, text == "-o"}
        is_binary(text) and text =~ ~r/\A-[a-zA-Z]*e/ -> {:errexit, true}
        is_binary(text) and text =~ ~r/\A\+[a-zA-Z]*e/ -> {:errexit, false}
        true -> nil
      end
    end)
  end

  # find's `-exec CMD … ;` (or `+`) runs CMD with each file found where
  # `{}` is; `-execdir` in each one's folder.
  defp find(command, args) do
    also = find_execs(args, command, [])
    {command, nil, also}
  end

  defp find_execs([], _command, also), do: also

  defp find_execs([word | rest], command, also) do
    case literal(word) do
      action when action in ["-exec", "-execdir", "-ok", "-okdir"] ->
        {words, rest} = Enum.split_while(rest, &(literal(&1) not in [";", "+"]))
        words = Enum.map(words, &taint(&1, "{}"))
        folder = if action in ["-execdir", "-okdir"], do: :unknown, else: command.folder

        context = %{
          context(folder, nil, words)
          | through: command.through ++ ["find " <> action]
        }

        {run, _effect, more} = unwrap(words, context)
        find_execs(Enum.drop(rest, 1), command, also ++ [run | more])

      _other ->
        find_execs(rest, command, also)
    end
  end

  defp su(command, args) do
    case options(args, %{
           arg: "cgGsw",
           long: ~w(command group supp-group shell whitelist-environment)
         }) do
      {:ok, opts, _rest} ->
        case opt(opts, ["c", "command"]) do
          nil -> {command, nil, []}
          code -> {%{command | code: [{:shell, "su -c", code}]}, nil, []}
        end

      {:unread, why} ->
        {%{command | unread: why}, nil, []}
    end
  end

  defp exported(command, args) do
    assigns = for word <- args, assignment(word) != nil, do: assignment(word)
    {%{command | assigns: command.assigns ++ assigns}, nil, []}
  end

  # A shell's options, as bash takes them: `-c` anywhere in a bundle
  # makes the first operand code; `-s`, or no operand, reads stdin; `-o`
  # and `-O` take a word; `--rcfile` and `--init-file` a file.
  defp shell(command, name, args) do
    case shell_args(args, :file) do
      {:code, code} -> {%{command | code: [{:shell, name <> " -c", code}]}, nil, []}
      {:file, file} -> {%{command | files: command.files ++ [file]}, nil, []}
      :stdin -> {%{command | stdin_code: name}, nil, []}
      :none -> {command, nil, []}
      {:unread, why} -> {%{command | unread: why}, nil, []}
    end
  end

  @shell_flags ~w(--norc --noprofile --login --posix --restricted --verbose --noediting --debugger
    --dump-strings --dump-po-strings --help --version --pretty-print --wordexp)

  defp shell_args([], :code), do: :none
  defp shell_args([], _mode), do: :stdin

  defp shell_args([word | rest], mode) do
    lead = lead(word)

    cond do
      word.literal? and word.text in ["--", "-"] ->
        shell_operand(rest, mode)

      word.literal? and word.text in ["--rcfile", "--init-file", "--emulate"] ->
        shell_args(Enum.drop(rest, 1), mode)

      word.literal? and word.text in @shell_flags ->
        shell_args(rest, mode)

      String.starts_with?(lead, "--") ->
        {:unread, "with an option of #{word.text} MWT doesn't know"}

      lead =~ ~r/\A[-+][A-Za-z]/ and not word.literal? ->
        {:unread, "with options built from a variable"}

      word.literal? and word.text =~ ~r/\A[-+][A-Za-z]+\z/ ->
        shell_bundle(String.slice(word.text, 1..-1//1), rest, mode)

      true ->
        shell_operand([word | rest], mode)
    end
  end

  defp shell_bundle("", rest, mode), do: shell_args(rest, mode)
  defp shell_bundle("c" <> more, rest, _mode), do: shell_bundle(more, rest, :code)
  defp shell_bundle("s" <> more, rest, :code), do: shell_bundle(more, rest, :code)
  defp shell_bundle("s" <> more, rest, _mode), do: shell_bundle(more, rest, :stdin)

  defp shell_bundle(<<letter, more::binary>>, rest, mode) when letter in [?o, ?O],
    do: shell_bundle(more, Enum.drop(rest, 1), mode)

  defp shell_bundle(<<_flag, more::binary>>, rest, mode), do: shell_bundle(more, rest, mode)

  defp shell_operand([], :code), do: :none
  defp shell_operand([], _mode), do: :stdin
  defp shell_operand([code | _], :code), do: {:code, code}
  defp shell_operand(_args, :stdin), do: :stdin
  defp shell_operand([file | _], :file), do: {:file, file}

  # Interpreters' options, each as its own manual has them: which letters
  # make code (`code`), name a module rather than a file (`module`), take
  # the next word or the rest of the bundle (`arg`), or only the rest of
  # the bundle (`attached`); long options that take the next word
  # (`long`), and those that are code (`long_code`).
  @interpreters %{
    python: %{code: "c", module: "m", arg: "WX", long: ~w(check-hash-based-pycs)},
    node: %{
      code: "ep",
      preload: "r",
      arg: "C",
      long:
        ~w(input-type env-file env-file-if-exists title conditions inspect-port redirect-warnings icu-data-dir openssl-config tls-cipher-list diagnostic-dir report-dir report-directory report-filename report-signal heapsnapshot-signal secure-heap secure-heap-min unhandled-rejections watch-path dns-result-order experimental-default-type disable-warning localstorage-file test-reporter test-reporter-destination test-name-pattern test-skip-pattern),
      long_code: ~w(eval print),
      long_preload: ~w(require import loader experimental-loader)
    },
    perl: %{code: "eE", arg: "IMm", attached: "l0iFxdDC", many?: true},
    ruby: %{
      code: "e",
      preload: "r",
      arg: "IE",
      chdir: "C",
      attached: "Fx0iWTK",
      long: ~w(encoding external-encoding internal-encoding),
      many?: true
    },
    php: %{code: "rBRE", file: "fF", arg: "dczSt", many?: true}
  }

  defp interpreted(command, kind, name, args) do
    spec = Map.fetch!(@interpreters, kind)

    case interpreter_args(args, spec, %{code: nil, files: [], module?: false, chdir: nil}) do
      {:unread, why} ->
        {%{command | unread: why}, nil, []}

      {found, operand} ->
        command = %{command | files: command.files ++ found.files}

        command =
          if found.chdir,
            do: %{command | folder: step(command.folder, found.chdir, true)},
            else: command

        cond do
          found.code ->
            {%{command | code: [{:other, name <> " " <> found.code.how, found.code.word}]}, nil,
             []}

          found.module? ->
            {command, nil, []}

          found.files != [] and kind == :php ->
            {command, nil, []}

          operand == :stdin ->
            {%{command | stdin_code: name}, nil, []}

          true ->
            {%{command | files: command.files ++ [operand]}, nil, []}
        end
    end
  end

  defp interpreter_args([], _spec, found), do: {found, :stdin}

  defp interpreter_args([word | rest], spec, found) do
    lead = lead(word)

    cond do
      word.literal? and word.text == "-" ->
        {found, :stdin}

      word.literal? and word.text == "--" ->
        {found, if(rest == [] or found.code, do: :stdin, else: hd(rest))}

      String.starts_with?(lead, "--") ->
        interpreter_long(word, lead, rest, spec, found)

      String.starts_with?(lead, "-") and lead != "-" ->
        interpreter_bundle(word, String.slice(lead, 1..-1//1), 1, rest, spec, found)

      lead == "-" and not word.literal? ->
        {:unread, "with options built from a variable"}

      # Past the first operand, options are the program's own.
      found.code != nil or found.module? ->
        {found, :stdin}

      true ->
        {found, word}
    end
  end

  defp interpreter_long(word, lead, rest, spec, found) do
    {name, value, rest} =
      case String.split(lead, "=", parts: 2) do
        ["--" <> name, _value] ->
          {name, past(word, byte_size(name) + 3), rest}

        ["--" <> name] ->
          if name in (Map.get(spec, :long, []) ++
                        Map.get(spec, :long_code, []) ++ Map.get(spec, :long_preload, [])),
             do: {name, List.first(rest), Enum.drop(rest, 1)},
             else: {name, nil, rest}
      end

    cond do
      name in Map.get(spec, :long_code, []) and value ->
        done(%{found | code: %{how: "--" <> name, word: value}}, rest, spec)

      name in Map.get(spec, :long_preload, []) and value ->
        interpreter_args(rest, spec, preload(found, value))

      true ->
        interpreter_args(rest, spec, found)
    end
  end

  # Code ends the options, but where an interpreter takes several (`-e`).
  defp done(found, rest, spec) do
    if Map.get(spec, :many?, false),
      do: interpreter_args(rest, spec, found),
      else: {found, :stdin}
  end

  defp preload(found, value) do
    if value.literal? and not String.contains?(value.text, "/"),
      do: found,
      else: %{found | files: found.files ++ [value]}
  end

  defp interpreter_bundle(word, "", _at, rest, spec, found) do
    if word.literal?,
      do: interpreter_args(rest, spec, found),
      else: {:unread, "with options built from a variable"}
  end

  defp interpreter_bundle(word, <<letter, more::binary>>, at, rest, spec, found) do
    letter = <<letter>>
    takes? = fn key -> String.contains?(Map.get(spec, key, ""), letter) end
    attached = if more != "" or not word.literal?, do: past(word, at + 1)

    cond do
      # It takes the rest of its bundle, whatever that is.
      takes?.(:attached) ->
        interpreter_args(rest, spec, found)

      takes?.(:module) ->
        {%{found | module?: true}, :stdin}

      Enum.any?([:code, :file, :preload, :chdir, :arg], takes?) ->
        {value, rest} =
          if attached, do: {attached, rest}, else: {List.first(rest), Enum.drop(rest, 1)}

        cond do
          value == nil -> {found, :stdin}
          takes?.(:code) -> done(%{found | code: %{how: "-" <> letter, word: value}}, rest, spec)
          takes?.(:file) -> interpreter_args(rest, spec, %{found | files: found.files ++ [value]})
          takes?.(:preload) -> interpreter_args(rest, spec, preload(found, value))
          takes?.(:chdir) -> interpreter_args(rest, spec, %{found | chdir: value})
          true -> interpreter_args(rest, spec, found)
        end

      true ->
        interpreter_bundle(word, more, at + 1, rest, spec, found)
    end
  end

  # ── What runs that isn't on PATH ─────────────────────────────────────

  defp entries(command) do
    files =
      for file <- command.files, do: {:file, shown(file, command.folder), file, command.folder}

    unread =
      if command.unread,
        do: [{:unread, shown_command(command), command.unread}],
        else: []

    code =
      for {:shell, how, word} <- command.code, not word.literal? do
        {:unread, how <> " " <> word.text, "shell code built from a variable"}
      end

    files ++ unread ++ code ++ stdin_entries(command)
  end

  defp stdin_entries(%{stdin_code: nil}), do: []

  defp stdin_entries(%{stdin_code: how, stdin: stdin, args_from: args_from} = command) do
    case stdin do
      {:file, word} ->
        [{:file, shown(word, command.folder), word, command.folder}]

      {:text, %{literal?: true}} ->
        []

      {:text, _word} ->
        [{:unread, how, "fed code built from a variable"}]

      {:pipe, [producer | _]} ->
        piped(how, producer)

      {:pipe, []} ->
        [{:unread, how, "fed code another command writes"}]

      nil when args_from != nil ->
        [{:unread, how, "given the files it runs by xargs"}]

      nil ->
        []
    end
  end

  # What a pipe feeds a shell: the files `cat` reads, code downloaded, or
  # what any other command writes.
  defp piped(how, %{words: [program | args]} = producer) do
    case program |> literal() |> then(&(&1 && Path.basename(&1))) do
      "cat" ->
        case Enum.reject(args, &String.starts_with?(&1.text, "-")) do
          [] ->
            [{:unread, "cat | " <> how, "fed code cat reads on its own stdin"}]

          files ->
            for file <- files, do: {:file, shown(file, producer.folder), file, producer.folder}
        end

      tool when tool in ["curl", "wget"] ->
        [{:unread, "#{tool} | #{how}", "fed code it downloads"}]

      _other ->
        [{:unread, "#{program.text} | #{how}", "fed as code what #{program.text} writes"}]
    end
  end

  defp piped(how, _producer), do: [{:unread, how, "fed code another command writes"}]

  defp shown_command(%{words: [], through: through}), do: Enum.join(through, " ")
  defp shown_command(%{words: words}), do: Enum.map_join(words, " ", & &1.text)

  # A file as the script names it, from the folder the script starts in:
  # `cd app && ./x.sh` runs app/x.sh.
  defp shown(word, folder) when is_list(folder) do
    if relative?(word) do
      base =
        Enum.reduce(folder, "", fn
          :home, _base -> "~"
          {:cd, cd, _sure?}, base -> if relative?(cd), do: join(base, cd.text), else: cd.text
        end)

      join(base, word.text)
    else
      word.text
    end
  end

  defp shown(word, :unknown), do: word.text

  defp join("", path), do: path
  defp join(base, "./" <> path), do: join(base, path)
  defp join(base, path), do: Path.join(base, path)
end
