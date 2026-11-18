defmodule MWTClient.Sandbox.Param do
  @moduledoc """
  One parameter of a subgrant: what an agent fills in when it calls the
  subgrant by id (`mwt call ID NAME=value`). See "Grants and subgrants" in
  `docs/agent_sandbox.md`.

  A parameter has a `name`, in capitals; a `shape`, which says what a value
  may be; and `about`, a line saying what it is, for you and for agents.

  | Shape              | A value is                                                    |
  | ------------------ | ------------------------------------------------------------- |
  | `:word`            | letters, digits and `_ . - @ : +`, in parts joined by `/`; no part is `.` or `..`, and it starts with none of `/` or `-` |
  | `:number`          | digits only                                                   |
  | `{:one_of, list}`  | one of the values you listed                                  |
  | `:date`            | a date, `YYYY-MM-DD`                                          |
  | `:time`            | a time, RFC 3339: `2026-11-17T12:00:00Z`, or with an offset   |
  | `:decimal`         | a number, with a sign and a fraction if it has them: `-12.50` |
  | `:text`            | anything that shows, not starting with `-`                    |


  A command subgrant reads its parameters as environment variables: the
  script runs exactly as saved, and a value never becomes part of its
  text. So a name can't be one the environment already gives a meaning to
  (`reserved?/1`), and every parameter has to appear in the script
  (`unused/2`): a value reaches a tool only where the script shows it go.

  Pure, apart from `reserved?/1` reading MWT's own environment.
  """

  alias MWTClient.Sandbox.Shown

  @enforce_keys [:name, :shape, :about]
  defstruct [:name, :shape, :about]

  @type shape ::
          :word
          | :number
          | :date
          | :time
          | :decimal
          | :text
          | {:one_of, [String.t(), ...]}
  @type t :: %__MODULE__{name: String.t(), shape: shape(), about: String.t()}

  @typedoc "What is wrong with a call's values, for the agent."
  @type problem ::
          {:missing, t()}
          | {:unknown, String.t()}
          | {:shape, t()}
          | {:hidden, t(), [String.t()]}

  @max_params 8
  @max_word 200
  @max_text 4096
  @max_about 200

  @name ~r/\A[A-Z][A-Z0-9_]{0,39}\z/
  @part ~r/\A[A-Za-z0-9_.@:+-]+\z/
  @number ~r/\A[0-9]{1,18}\z/
  @date ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  @time ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?([Zz]|[+-][0-9]{2}:[0-9]{2})\z/
  @decimal ~r/\A-?[0-9]{1,18}(\.[0-9]{1,18})?\z/
  @shapes ~w(word number date time decimal text)

  # Names the shell, the loader and git give a meaning to. Others are the
  # machine's to say: a name its environment has is refused too.
  @reserved ~w(IFS PATH HOME ENV PS4 SHELLOPTS BASHOPTS CDPATH GLOBIGNORE PROMPT_COMMAND
    EDITOR VISUAL PAGER TERM TMPDIR TZ LANG USER SHELL PWD OLDPWD)
  @reserved_prefixes ~w(BASH_ LD_ DYLD_ GIT_ SSH_ LC_ MWT_)

  @doc "The most parameters a subgrant takes."
  @spec max() :: pos_integer()
  def max, do: @max_params

  @doc """
  Parameters from text, one a line, as you write them in the form and
  agents in `--param`: `NAME: shape: what it is`. The shape is `word`,
  `number`, `text`, or values joined by `|`; left empty, a word.

      iex> MWTClient.Sandbox.Param.parse("REPO: word: owner/name of the repository")
      {:ok, [%MWTClient.Sandbox.Param{name: "REPO", shape: :word, about: "owner/name of the repository"}]}

      iex> MWTClient.Sandbox.Param.parse("TARGET: staging|production: where it deploys")
      {:ok, [%MWTClient.Sandbox.Param{name: "TARGET", shape: {:one_of, ["staging", "production"]}, about: "where it deploys"}]}

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
           "At most #{@max_params} parameters. One that needs more is more than one subgrant."},
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
          if String.trim(rest) in @shapes,
            do: {String.trim(name), String.trim(rest), ""},
            else: {String.trim(name), "", String.trim(rest)}

        [name] ->
          {String.trim(name), "", ""}
      end

    cond do
      not Regex.match?(@name, name) ->
        {:error,
         "#{name}: a name is in capitals, like REPO_NAME: letters, digits and underscores."}

      reserved?(name) ->
        {:error,
         "#{name} already means something on this machine or to the shell. Pick another name."}

      about == "" ->
        {:error, "#{name}: say what it is, after the shape: #{name}: word: what it is."}

      true ->
        with {:ok, shape} <- shape(name, shape) do
          {:ok, %__MODULE__{name: name, shape: shape, about: String.slice(about, 0, @max_about)}}
        end
    end
  end

  defp shape(_name, shape) when shape in ["", "word"], do: {:ok, :word}
  defp shape(_name, "number"), do: {:ok, :number}
  defp shape(_name, "date"), do: {:ok, :date}
  defp shape(_name, "time"), do: {:ok, :time}
  defp shape(_name, "decimal"), do: {:ok, :decimal}
  defp shape(_name, "text"), do: {:ok, :text}

  defp shape(name, list) do
    values = list |> String.split("|") |> Enum.map(&String.trim/1)

    cond do
      not String.contains?(list, "|") ->
        {:error,
         "#{name}: #{list} is no shape. Use word, number, date, time, decimal, text, or the values it may take, as a|b|c."}

      Enum.any?(values, &(&1 == "" or String.starts_with?(&1, "-"))) ->
        {:error, "#{name}: each value of a list is some text that doesn't start with a dash."}

      true ->
        {:ok, {:one_of, Enum.uniq(values)}}
    end
  end

  defp distinct(params) do
    case params |> Enum.map(& &1.name) |> Enum.frequencies() |> Enum.find(&(elem(&1, 1) > 1)) do
      nil -> :ok
      {name, _times} -> {:error, "#{name} is there twice."}
    end
  end

  @doc """
  Whether `name` already means something: to the shell, the loader or git,
  or to this machine, whose environment has it.
  """
  @spec reserved?(String.t()) :: boolean()
  def reserved?(name) do
    name in @reserved or Enum.any?(@reserved_prefixes, &String.starts_with?(name, &1)) or
      System.get_env(name) != nil
  end

  @doc """
  A parameter as a line, the way `parse/1` reads it.

      iex> MWTClient.Sandbox.Param.line(%MWTClient.Sandbox.Param{name: "PR", shape: :number, about: "the pull request"})
      "PR: number: the pull request"
  """
  @spec line(t()) :: String.t()
  def line(%__MODULE__{} = param), do: "#{param.name}: #{shape_name(param.shape)}: #{param.about}"

  @doc "A shape as it is written: `word`, `number`, `date`, `time`, `decimal`, `text`, or `a|b|c`."
  @spec shape_name(shape()) :: String.t()
  def shape_name({:one_of, values}), do: Enum.join(values, "|")
  def shape_name(shape), do: Atom.to_string(shape)

  @doc "What a value of a shape may be, in a line, for you and for agents."
  @spec shape_words(shape()) :: String.t()
  def shape_words(:word),
    do:
      "a word: letters, digits and _ . - @ : +, in parts joined by /; no spaces, no .. and no leading / or -"

  def shape_words(:number), do: "a number: digits only"
  def shape_words(:date), do: "a date: YYYY-MM-DD"
  def shape_words(:time), do: "a time, RFC 3339: 2026-11-17T12:00:00Z, or with an offset"
  def shape_words(:decimal), do: "a decimal: digits, a leading - and a fraction if it has them"
  def shape_words(:text), do: "text: anything that shows, not starting with a dash"
  def shape_words({:one_of, values}), do: "one of: " <> Enum.join(values, ", ")

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
        (:bare in places and spaces?(param.shape)) &&
          "$#{param.name} can hold spaces, and is read outside double quotes: the shell " <>
            "would split it into several arguments. Write \"$#{param.name}\"."
      ]
      |> Enum.filter(&is_binary/1)
    end)
  end

  defp spaces?(:text), do: true
  defp spaces?({:one_of, values}), do: Enum.any?(values, &(&1 =~ ~r/[\s*?\[]/))
  defp spaces?(_shape), do: false

  # Where a script reads `$NAME` or `${NAME}`: `:bare`, in `:double` quotes
  # or in `:single` ones. Quotes are followed as bash does for the common
  # cases (a backslash escapes outside single quotes); here-documents and
  # `$'…'` are not, since this only feeds hints and the "is it read at all"
  # check, where a single-quoted mention counts as read.
  defp places(script, name), do: scan(script, name, :bare, [])

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
  given, none unknown, each value of its shape and showing all it holds.
  Answers the values in the parameters' order, or what is wrong first.

      iex> alias MWTClient.Sandbox.Param
      iex> {:ok, params} = Param.parse("REPO: word: the repository")
      iex> Param.check(params, %{"REPO" => "oliveigah/klife"})
      {:ok, [{"REPO", "oliveigah/klife"}]}
      iex> {:error, {:shape, %Param{name: "REPO"}}} = Param.check(params, %{"REPO" => "--web"})
      iex> {:error, {:shape, %Param{name: "REPO"}}} = Param.check(params, %{"REPO" => "../other"})
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
    cond do
      Shown.hidden(value) != [] -> {:error, {:hidden, param, Shown.hidden(value)}}
      fits?(param.shape, value) -> {:ok, value}
      true -> {:error, {:shape, param}}
    end
  end

  defp value(param, _other), do: {:error, {:shape, param}}

  @doc """
  Whether `value` is of `shape`.

      iex> MWTClient.Sandbox.Param.fits?(:word, "feature/login-v2")
      true

      iex> MWTClient.Sandbox.Param.fits?(:word, "a b")
      false

      iex> MWTClient.Sandbox.Param.fits?(:number, "42")
      true

      iex> MWTClient.Sandbox.Param.fits?({:one_of, ["staging", "production"]}, "dev")
      false

      iex> MWTClient.Sandbox.Param.fits?(:text, "-rf /")
      false
  """
  @spec fits?(shape(), String.t()) :: boolean()
  def fits?(:word, value) do
    parts = String.split(value, "/")

    byte_size(value) <= @max_word and not String.starts_with?(value, "-") and
      Enum.all?(parts, &(Regex.match?(@part, &1) and &1 not in [".", ".."]))
  end

  def fits?(:number, value), do: Regex.match?(@number, value)

  def fits?(:date, value),
    do: Regex.match?(@date, value) and match?({:ok, _}, Date.from_iso8601(value))

  def fits?(:time, value) do
    Regex.match?(@time, value) and
      match?(
        {:ok, _, _},
        value
        |> String.replace(~r/[t ]/, "T", global: false)
        |> String.upcase()
        |> DateTime.from_iso8601()
      )
  end

  def fits?(:decimal, value), do: Regex.match?(@decimal, value)
  def fits?({:one_of, values}, value), do: value in values

  def fits?(:text, value),
    do:
      byte_size(value) <= @max_text and String.trim(value) != "" and
        not String.starts_with?(String.trim_leading(value), "-")

  @doc "What is wrong with a call's values, in words for the agent."
  @spec explain(problem()) :: String.t()
  def explain({:missing, param}),
    do: "#{param.name} is missing: give it as #{param.name}=value. #{describe(param)}"

  def explain({:unknown, name}), do: "It has no parameter #{name}."

  def explain({:shape, param}), do: "#{param.name} isn't of its shape. #{describe(param)}"

  def explain({:hidden, param, what}),
    do:
      "#{param.name} holds what doesn't show (#{Enum.join(what, ", ")}), so it would not be " <>
        "what the user reads. Send it without."

  @doc """
  A parameter in a line, for agents and for a card: its name, what a value
  may be, and what it is.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = param),
    do: "#{param.name} is #{shape_words(param.shape)}. It is: #{param.about}"

  @doc "Brings parameters saved by an older MWT up to date."
  @spec upgrade(map()) :: t()
  def upgrade(%{} = saved), do: struct(__MODULE__, Map.delete(saved, :__struct__))
end
