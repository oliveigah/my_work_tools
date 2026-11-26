defmodule MWTClient.Sandbox.Param do
  @moduledoc """
  One parameter of a fixed call: what an agent fills in when it calls it
  by id (`mwt call ID NAME=value`). See "Parameters" in
  `docs/agent_sandbox.md`.

  A parameter has a `name`, in capitals; `about`, a line saying what it
  is, for you and for agents; and a `schema`, the JSON Schema its values
  keep to (`MWTClient.Sandbox.ParamSchema`): the call's parameters are one
  JSON Schema object, each a property of it.

  Before its schema, every value meets MWT's own floor, whatever the
  schema says (`check/2`): given and not blank, nothing in it that doesn't
  show, at most 4 KiB, never an option (no leading `-`, but for a number)
  and never up a folder (no part between `/` or `\\` that is `.` or `..`,
  percent-encoded or not). Then
  it is typed by its schema's `type` and checked against the schema.

  `NAME: shape: what it is`, a line each, is a shorthand for a schema,
  which agents use in `--param` (`parse/1`): `word` (MWT's `word`
  format), `number` (an integer, 0 or more), `decimal` (a number), `date`,
  `time` (`date-time`), `text` (a string), or `a|b|c` (one of them).

  A command reads its parameters as environment variables: the script
  runs exactly as saved, and a value never becomes part of its text. So a
  name can't be one programs read from the environment (`env_reader/1`)
  or this machine's environment has (`reserved?/1`), and every parameter
  has to appear in the script
  (`unused/2`): a value reaches a tool only where the script shows it go.

  Pure, apart from `reserved?/1` reading MWT's own environment and
  `MWTClient.Sandbox.ParamSchema.check/2`'s process.
  """

  alias MWTClient.Sandbox.{ParamSchema, Shown}

  @enforce_keys [:name, :about, :schema]
  defstruct [:name, :about, :schema]

  @type t :: %__MODULE__{name: String.t(), about: String.t(), schema: ParamSchema.t()}

  @typedoc "What is wrong with a call's values, for the agent."
  @type problem ::
          {:missing, t()}
          | {:unknown, String.t()}
          | {:hidden, t(), [String.t()]}
          | {:floor, t(), String.t()}
          | {:type, t()}
          | {:rule, t(), String.t()}

  @max_params 8
  @max_value 4096
  @max_about 200

  @name ~r/\A[A-Z][A-Z0-9_]{0,39}\z/
  @shapes %{
    "word" => %{"type" => "string", "format" => "word"},
    "number" => %{"type" => "integer", "minimum" => 0},
    "decimal" => %{"type" => "number"},
    "date" => %{"type" => "string", "format" => "date"},
    "time" => %{"type" => "string", "format" => "date-time"},
    "text" => %{"type" => "string"}
  }

  # Names programs read from the environment, by who reads them. A
  # command's values reach it as environment variables, so a value under
  # one of these reaches every program the script starts, not only where
  # the script shows `$NAME` go: `PYTHONPATH` makes python load code from
  # where the agent says, `HTTPS_PROXY` sends curl's traffic through it.
  # No list is whole: a name this machine's environment has is refused
  # too (`reserved?/1`), and the rest is the name's own risk.
  @read_from_env [
    {"the shell", ~w(IFS PATH HOME ENV CDPATH PS1 PS2 PS3 PS4 SHELL SHELLOPTS BASHOPTS GLOBIGNORE
        PROMPT_COMMAND HISTFILE INPUTRC MAIL MAILPATH PWD OLDPWD ZDOTDIR FPATH TMOUT),
     ~w(BASH_ ZSH_)},
    {"the loader", [], ~w(LD_ DYLD_)},
    {"the C library",
     ~w(LANG LANGUAGE TZ TMPDIR GCONV_PATH LOCPATH NLSPATH HOSTALIASES RES_OPTIONS LOCALDOMAIN USER LOGNAME),
     ~w(LC_ MALLOC_ GLIBC_)},
    {"git", [], ~w(GIT_)},
    {"ssh", [], ~w(SSH_)},
    {"python", [], ~w(PYTHON PIP_ VIRTUAL_ENV)},
    {"node", ~w(NODE_OPTIONS NODE_PATH NODE_EXTRA_CA_CERTS), ~w(NODE_ NPM_CONFIG_ YARN_)},
    {"perl", ~w(PERLLIB PERL5LIB PERL5OPT PERL5DB), ~w(PERL_)},
    {"ruby", ~w(RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE), ~w(RUBY_ BUNDLE_)},
    {"java", ~w(JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS JAVA_HOME CLASSPATH MAVEN_OPTS GRADLE_OPTS),
     []},
    {"build tools",
     ~w(MAKEFLAGS CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS RUSTFLAGS RUSTC_WRAPPER GOFLAGS GOPATH
        GOPROXY GOROOT GOBIN GOOS GOARCH GOTOOLCHAIN GOPRIVATE GONOSUMDB), ~w(CARGO_ RUSTUP_)},
    {"kubectl", ~w(KUBECONFIG), ~w(KUBECTL_)},
    {"docker", [], ~w(DOCKER_ BUILDKIT_ COMPOSE_)},
    {"cloud tools", ~w(GITHUB_TOKEN GITHUB_ENTERPRISE_TOKEN), ~w(GH_ AWS_ CLOUDSDK_ AZURE_ TF_)},
    {"HTTP and TLS clients",
     ~w(SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE CURL_HOME REQUESTS_CA_BUNDLE OPENSSL_CONF WGETRC),
     []},
    {"programs that find their files by it", [], ~w(XDG_)},
    {"terminal programs",
     ~w(TERM TERMINFO EDITOR VISUAL PAGER MANPAGER BROWSER LESS LESSOPEN LESSCLOSE DISPLAY),
     ~w(SUDO_)},
    {"MWT", [], ~w(MWT_)}
  ]

  @doc "The most parameters a call takes."
  @spec max() :: pos_integer()
  def max, do: @max_params

  @doc """
  Parameters from the shorthand, one a line, as agents write them in
  `--param`: `NAME: shape: what it is`. The shape is `word`, `number`,
  `decimal`, `date`, `time`, `text`, or values joined by `|`; left empty,
  a word. Each becomes the schema the moduledoc says.

      iex> MWTClient.Sandbox.Param.parse("REPO: word: owner/name of the repository")
      {:ok, [%MWTClient.Sandbox.Param{name: "REPO", about: "owner/name of the repository",
        schema: %{"type" => "string", "format" => "word"}}]}

      iex> MWTClient.Sandbox.Param.parse("TARGET: staging|production: where it deploys")
      {:ok, [%MWTClient.Sandbox.Param{name: "TARGET", about: "where it deploys",
        schema: %{"type" => "string", "enum" => ["staging", "production"]}}]}

      iex> MWTClient.Sandbox.Param.parse("repo: word: the repository")
      {:error, "repo: a name is in capitals, like REPO_NAME: letters, digits and underscores."}
  """
  @spec parse(String.t() | [String.t()] | nil) :: {:ok, [t()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}
  def parse(text) when is_binary(text), do: text |> String.split("\n") |> parse()

  def parse(lines) when is_list(lines) do
    lines =
      lines |> Enum.map(&(&1 |> Shown.text() |> String.trim())) |> Enum.reject(&(&1 == ""))

    with {:ok, params} <- each(lines, &read_line/1),
         :ok <- distinct(params) do
      if length(params) > @max_params,
        do:
          {:error,
           "At most #{@max_params} parameters. One that needs more is more than one call."},
        else: {:ok, params}
    end
  end

  defp each(lines, fun) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, done} ->
      case fun.(line) do
        {:ok, param} -> {:cont, {:ok, done ++ [param]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp read_line(line) do
    {name, shape, about} =
      case String.split(line, ":", parts: 3) do
        [name, shape, about] ->
          {String.trim(name), String.trim(shape), String.trim(about)}

        # Two parts are a name and what it is, unless the second is a shape.
        [name, rest] ->
          if Map.has_key?(@shapes, String.trim(rest)),
            do: {String.trim(name), String.trim(rest), ""},
            else: {String.trim(name), "", String.trim(rest)}

        [name] ->
          {String.trim(name), "", ""}
      end

    with :ok <- name_error(name) do
      cond do
        about == "" ->
          {:error, "#{name}: say what it is, after the shape: #{name}: word: what it is."}

        true ->
          with {:ok, schema} <- shape(name, shape) do
            {:ok,
             %__MODULE__{name: name, about: String.slice(about, 0, @max_about), schema: schema}}
          end
      end
    end
  end

  defp shape(_name, ""), do: {:ok, @shapes["word"]}

  defp shape(name, shape) do
    cond do
      Map.has_key?(@shapes, shape) ->
        {:ok, @shapes[shape]}

      not String.contains?(shape, "|") ->
        {:error,
         "#{name}: #{shape} is no shape. Use word, number, decimal, date, time, text, or the values it may take, as a|b|c."}

      true ->
        values = shape |> String.split("|") |> Enum.map(&String.trim/1)

        if Enum.any?(values, &(&1 == "" or String.starts_with?(&1, "-"))),
          do:
            {:error, "#{name}: each value of a list is some text that doesn't start with a dash."},
          else: {:ok, %{"type" => "string", "enum" => Enum.uniq(values)}}
    end
  end

  defp distinct(params) do
    case params |> Enum.map(& &1.name) |> Enum.frequencies() |> Enum.find(&(elem(&1, 1) > 1)) do
      nil -> :ok
      {name, _times} -> {:error, "#{name} is there twice."}
    end
  end

  @doc """
  Why `name` can't be a parameter's, or `:ok`: capitals, digits and
  underscores, and nothing the environment already gives a meaning to.

      iex> MWTClient.Sandbox.Param.name_error("PYTHONPATH")
      {:error, "PYTHONPATH already means something to python, which reads it from the environment: every program the script starts would see the value. Pick another name."}
  """
  @spec name_error(String.t()) :: :ok | {:error, String.t()}
  def name_error(name) do
    cond do
      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error,
         "#{Shown.text(to_string(name))}: a name is in capitals, like REPO_NAME: letters, digits and underscores."}

      (who = env_reader(name)) != nil ->
        {:error,
         "#{name} already means something to #{who}, which reads it from the environment: " <>
           "every program the script starts would see the value. Pick another name."}

      System.get_env(name) != nil ->
        {:error,
         "#{name} already means something on this machine, whose environment has it. Pick another name."}

      true ->
        :ok
    end
  end

  @doc """
  Whether `name` already means something: to a program that reads it from
  the environment (`env_reader/1`), or to this machine, whose environment
  has it.
  """
  @spec reserved?(String.t()) :: boolean()
  def reserved?(name), do: env_reader(name) != nil or System.get_env(name) != nil

  @doc """
  Who reads `name` from the environment, in a few words, or nil: the
  shell, the loader, git, python… and any `…_PROXY`, which HTTP clients
  take as where to send their traffic.

      iex> MWTClient.Sandbox.Param.env_reader("HTTPS_PROXY")
      "HTTP clients"
      iex> MWTClient.Sandbox.Param.env_reader("REPO")
      nil
  """
  @spec env_reader(String.t()) :: String.t() | nil
  def env_reader(name) when is_binary(name) do
    if String.ends_with?(name, "_PROXY") do
      "HTTP clients"
    else
      Enum.find_value(@read_from_env, fn {who, names, prefixes} ->
        (name in names or String.starts_with?(name, prefixes)) && who
      end)
    end
  end

  @doc """
  The parameters `script` doesn't read: those it names neither as `$NAME`
  nor as `${NAME}`.

      iex> alias MWTClient.Sandbox.Param
      iex> {:ok, params} = Param.parse(["REPO: word: the repository", "PR: number: the pull request"])
      iex> params |> Param.unused(~s(gh pr view "$PR")) |> Enum.map(& &1.name)
      ["REPO"]
  """
  @spec unused([t()], String.t()) :: [t()]
  def unused(params, script), do: Enum.reject(params, &(places(script, &1.name) != []))

  @doc """
  What deserves a second look in how `script` reads its parameters, worked
  out from its text: one that can hold spaces, read outside double quotes;
  one inside single quotes, where the shell leaves it as it is. Hints, not
  a review.

      iex> alias MWTClient.Sandbox.Param
      iex> {:ok, params} = Param.parse("TITLE: text: the title")
      iex> Param.hints(params, "gh issue create --title $TITLE")
      ["$TITLE can hold spaces, and is read outside double quotes: the shell would split it into several arguments. Write \\"$TITLE\\"."]
  """
  @spec hints([t()], String.t()) :: [String.t()]
  def hints(params, script) do
    Enum.flat_map(params, fn param ->
      places = places(script, param.name)

      [
        :single in places &&
          "$#{param.name} is inside single quotes, where the shell leaves it as it is: " <>
            "the value isn't used there.",
        (:bare in places and may_space?(param.schema)) &&
          "$#{param.name} can hold spaces, and is read outside double quotes: the shell " <>
            "would split it into several arguments. Write \"$#{param.name}\"."
      ]
      |> Enum.filter(&is_binary/1)
    end)
  end

  @splits MapSet.new(~c" \t\n\v\f\r*?[")

  # Whether a value of its schema, read bare, may be split or globbed:
  # whether it may hold a space or `*`, `?`, `[`. A word can't; nor can a
  # number, nor a pattern's whose text proves it
  # (`MWTClient.Sandbox.ParamSchema.pattern_reach/1`); anything else may.
  defp may_space?(%{"enum" => values}) when is_list(values), do: Enum.any?(values, &splits?/1)
  defp may_space?(%{"const" => value}), do: splits?(value)
  defp may_space?(%{"format" => "word"}), do: false
  defp may_space?(%{"type" => type}) when type in ["integer", "number", "boolean"], do: false

  defp may_space?(%{"pattern" => pattern}) when is_binary(pattern) do
    case ParamSchema.pattern_reach(pattern) do
      {:ok, reach} -> not MapSet.disjoint?(reach.chars, @splits)
      :unknown -> true
    end
  end

  defp may_space?(_schema), do: true

  defp splits?(value), do: is_binary(value) and value =~ ~r/[\s*?\[]/

  @doc """
  Where `script` reads the parameter `name` (`$NAME` or `${NAME}`): each
  time, `:bare`, in `:double` quotes or in `:single` ones. For hints and
  warnings (`hints/2`, `MWTClient.Sandbox.Openness`), never for deciding.

      iex> MWTClient.Sandbox.Param.places(~s(echo $A "$A" '$A'), "A")
      [:bare, :double, :single]
  """
  @spec places(String.t(), String.t()) :: [:bare | :double | :single]
  def places(script, name), do: scan(script, name, :bare, [])

  @doc """
  Whether a value of `schema`, read bare, may be split or globbed by the
  shell: whether it may hold a space or `*`, `?`, `[`. Text may; a word,
  a number, one of a list without them, or a pattern's whose text proves
  it can't (`MWTClient.Sandbox.ParamSchema.pattern_reach/1`) may not.
  """
  @spec spaces?(map()) :: boolean()
  def spaces?(schema), do: may_space?(schema)

  # Where a script reads `$NAME` or `${NAME}`: `:bare`, in `:double` quotes
  # or in `:single` ones. Quotes are followed as bash does for the common
  # cases (a backslash escapes outside single quotes); here-documents and
  # `$'…'` are not, since this only feeds hints and the "is it read at all"
  # check, where a single-quoted mention counts as read.

  defp scan("", _name, _quote, found), do: Enum.reverse(found)

  defp scan("\\" <> rest, name, quote, found) when quote != :single,
    do: skip(rest, name, quote, found)

  defp scan("'" <> rest, name, :bare, found), do: scan(rest, name, :single, found)
  defp scan("'" <> rest, name, :single, found), do: scan(rest, name, :bare, found)
  defp scan("\"" <> rest, name, :bare, found), do: scan(rest, name, :double, found)
  defp scan("\"" <> rest, name, :double, found), do: scan(rest, name, :bare, found)

  defp scan("$" <> rest, name, quote, found) do
    cond do
      String.starts_with?(rest, "{" <> name <> "}") ->
        scan(
          binary_part(rest, byte_size(name) + 2, byte_size(rest) - byte_size(name) - 2),
          name,
          quote,
          [quote | found]
        )

      String.starts_with?(rest, name) and not continues?(rest, name) ->
        scan(binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name)), name, quote, [
          quote | found
        ])

      true ->
        scan(rest, name, quote, found)
    end
  end

  defp scan(<<_char::utf8, rest::binary>>, name, quote, found), do: scan(rest, name, quote, found)
  defp scan(<<_byte, rest::binary>>, name, quote, found), do: scan(rest, name, quote, found)

  defp skip(<<_char::utf8, rest::binary>>, name, quote, found), do: scan(rest, name, quote, found)
  defp skip(rest, name, quote, found), do: scan(rest, name, quote, found)

  # `$REPO_NAME` is not a use of `$REPO`.
  defp continues?(rest, name) do
    case binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name)) do
      <<char, _::binary>> when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ ->
        true

      _other ->
        false
    end
  end

  @doc """
  Checks the values of a call against the parameters: every parameter
  given, none unknown, each over MWT's floor, of its type, and keeping to
  its schema. Answers the values, as given, in the parameters' order, or
  what is wrong first.

      iex> alias MWTClient.Sandbox.Param
      iex> {:ok, params} = Param.parse("REPO: word: the repository")
      iex> Param.check(params, %{"REPO" => "oliveigah/klife"})
      {:ok, [{"REPO", "oliveigah/klife"}]}
      iex> {:error, {:floor, %Param{name: "REPO"}, _}} = Param.check(params, %{"REPO" => "--web"})
      iex> {:error, {:floor, %Param{name: "REPO"}, _}} = Param.check(params, %{"REPO" => "../other"})
      iex> Param.check(params, %{"REPO" => "a/b", "EXTRA" => "1"})
      {:error, {:unknown, "EXTRA"}}
  """
  @spec check([t()], map() | nil) :: {:ok, [{String.t(), String.t()}]} | {:error, problem()}
  def check(params, values) do
    values = if is_map(values), do: values, else: %{}
    names = MapSet.new(params, & &1.name)

    case Enum.find(Map.keys(values), &(not MapSet.member?(names, &1))) do
      nil ->
        Enum.reduce_while(params, {:ok, []}, fn param, {:ok, done} ->
          case value(param, Map.get(values, param.name)) do
            {:ok, value} -> {:cont, {:ok, done ++ [{param.name, value}]}}
            {:error, problem} -> {:halt, {:error, problem}}
          end
        end)

      unknown ->
        {:error, {:unknown, unknown |> Shown.text() |> String.slice(0, 60)}}
    end
  end

  defp value(param, value) when value in [nil, ""], do: {:error, {:missing, param}}

  defp value(param, value) when is_binary(value) do
    typed = ParamSchema.typed(param.schema, value)

    cond do
      Shown.hidden(value) != [] ->
        {:error, {:hidden, param, Shown.hidden(value)}}

      (why = floor(value, typed)) != nil ->
        {:error, {:floor, param, why}}

      typed == :error ->
        {:error, {:type, param}}

      true ->
        case ParamSchema.check(param.schema, elem(typed, 1)) do
          :ok -> {:ok, value}
          {:error, why} -> {:error, {:rule, param, why}}
        end
    end
  end

  defp value(param, _other), do: {:error, {:type, param}}

  # MWT's floor, whatever the schema says: why a value can't be any
  # parameter's, or nil.
  defp floor(value, typed) do
    cond do
      byte_size(value) > @max_value ->
        "it is over 4 KiB"

      String.trim(value) == "" ->
        "it is blank"

      String.starts_with?(String.trim_leading(value), "-") and not number?(typed) ->
        "it starts with -, as an option does"

      up_a_folder?(value) ->
        "it goes up a folder (. or ..)"

      true ->
        nil
    end
  end

  # A part of a path that is `.` or `..`, between `/` or `\`, which some
  # servers and Windows read as `/`; percent-encoded too (`%2e%2e`, `%5c`,
  # `%252e`), since a value can go into a URL that a server decodes once
  # or twice more.
  defp up_a_folder?(value) do
    value
    |> percent_decoded(3)
    |> :binary.split(["/", "\\"], [:global])
    |> Enum.any?(&(String.trim(&1) in [".", ".."]))
  end

  defp percent_decoded(value, 0), do: value

  defp percent_decoded(value, times) do
    decoded =
      Regex.replace(~r/%([0-9A-Fa-f]{2})/, value, fn _all, hex ->
        <<String.to_integer(hex, 16)>>
      end)

    if decoded == value, do: value, else: percent_decoded(decoded, times - 1)
  end

  defp number?({:ok, number}) when is_number(number), do: true
  defp number?(_typed), do: false

  @doc "What is wrong with a call's values, in words for the agent."
  @spec explain(problem()) :: String.t()
  def explain({:missing, param}),
    do: "#{param.name} is missing: give it as #{param.name}=value. #{describe(param)}"

  def explain({:unknown, name}), do: "It has no parameter #{name}."

  def explain({:floor, param, why}),
    do: "#{param.name} can't be that: #{why}. #{describe(param)}"

  def explain({:type, param}), do: "#{param.name} isn't of its type. #{describe(param)}"

  def explain({:rule, param, why}),
    do: "#{param.name} doesn't keep to its schema: #{why}. #{describe(param)}"

  def explain({:hidden, param, what}),
    do:
      "#{param.name} holds what doesn't show (#{Enum.join(what, ", ")}), so it would not be " <>
        "what the user reads. Send it without."

  @doc """
  A parameter in a line, for agents and for a card: its name, what a
  value may be, and what it is.

      iex> {:ok, [count]} = MWTClient.Sandbox.ParamSchema.parse(~s({"properties": {"COUNT":
      ...>   {"description": "how many", "type": "integer", "minimum": 1, "maximum": 10}}}))
      iex> MWTClient.Sandbox.Param.describe(count)
      "COUNT is an integer, from 1 to 10. It is: how many"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = param),
    do: "#{param.name} is #{ParamSchema.words(param.schema)}. It is: #{param.about}"

  @doc """
  Brings a parameter saved by an older MWT up to date: one with a shape
  (and a rule, 2026-11-25) takes the schema they make; a schema from a
  file is held to what one written in the form is, and one that isn't
  leaves its parameter text, its floor alone.
  """
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved) do
    # Saved as a struct of an older MWT's: its fields, as a plain map.
    saved = Map.delete(saved, :__struct__)
    name = saved[:name]
    about = saved[:about] || ""

    schema =
      case saved do
        %{schema: %{} = schema} -> schema
        %{shape: shape} -> Map.merge(old_shape(shape), saved[:rule] || %{})
        _none -> %{"type" => "string"}
      end

    schema =
      case ParamSchema.valid(to_string(name), schema) do
        :ok -> schema
        {:error, _} -> %{"type" => "string"}
      end

    %__MODULE__{name: name, about: about, schema: schema}
  end

  defp old_shape({:one_of, values}), do: %{"type" => "string", "enum" => values}

  defp old_shape(shape) when is_atom(shape),
    do: Map.get(@shapes, Atom.to_string(shape), %{"type" => "string"})

  defp old_shape(_other), do: %{"type" => "string"}
end
