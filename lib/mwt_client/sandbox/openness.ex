defmodule MWTClient.Sandbox.Openness do
  @moduledoc """
  How open a fixed call is: what the values an agent gives can make it
  do, read from its template and its parameters' schemas
  (docs/grant_mental_model.md, "How open a fixed call is"). A fixed call
  is only as narrow as its template is for every value its schema
  allows, and one can be open use in disguise while it still looks
  fixed: its page, the cards it raises and `mwt grants` say its grade.

    * `:narrow` - each value only picks among what the template names: one
      of a list, a number, a date, yes or no, a pattern's;
    * `:wide` - a value reaches anything of a kind: any name or path (a
      word), any text as one argument;
    * `:open` - a value can become code or a command: the command run, a
      shell's or an interpreter's code, a command on another machine or in
      a container, or text read outside double quotes, which the shell
      splits into several arguments, options included; in a request, a
      query the service runs, or the whole body.

  Beside the grade, the files a command runs (`./deploy.sh`): it is only
  as narrow as they are, and they can change after you saved it.

  Its premise: it reads text and guesses, so it can miss what makes a
  call open. It only warns: it never lets anything through, and never
  makes a call ask (Q8).
  """

  alias MWTClient.Sandbox.{Grant, HostCommand, Param}

  @type grade :: :narrow | :wide | :open
  @type t :: %{grade: grade(), why: [String.t()], files: [String.t()]}

  @shells ~w(bash sh zsh dash ksh fish)
  @interpreters ~w(python python3 node perl ruby php)

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
    commands = HostCommand.commands(script)
    verdicts = Enum.map(params, &command_param(&1, script, commands))
    files = HostCommand.files_run(script)
    combine(verdicts, files)
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
  defp command_param(%Param{name: name} = param, script, commands) do
    reads = "$#{name}"

    case Enum.find_value(commands, &code_position(&1, name)) do
      nil ->
        if :bare in Param.places(script, name) and Param.spaces?(param.schema),
          do:
            {:open,
             "#{reads} is read outside double quotes and can hold spaces: the shell splits it into several arguments, options included."},
          else: by_schema(param, reads)

      where ->
        {:open, "#{reads} #{where}."}
    end
  end

  # Where a parameter in one command's words becomes code, in words, or nil.
  defp code_position([first | args] = words, name) do
    mentions? = fn word -> word =~ ~r/\$\{?#{name}\b/ end

    cond do
      mentions?.(first) ->
        "is the command that runs"

      not Enum.any?(words, mentions?) ->
        nil

      first in ["eval", "source", "."] ->
        "is run by the shell as code (#{first})"

      first in @shells and "-c" in args ->
        "is run by the shell as code (#{first} -c)"

      first in @interpreters and Enum.any?(args, &(&1 in ["-c", "-e"])) ->
        "is run as #{first} code"

      first == "ssh" ->
        "runs as a command on another machine (ssh)"

      first in ["kubectl", "docker", "podman"] and "exec" in args ->
        "runs as a command in a container (#{first} exec)"

      first == "find" and Enum.any?(args, &(&1 in ["-exec", "-execdir"])) ->
        "is run by find -exec"

      true ->
        nil
    end
  end

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

      Map.has_key?(schema, "pattern") ->
        {:narrow, nil}

      schema["format"] == "word" ->
        {:wide, "#{reads} can be any name or path below where it is used."}

      true ->
        {:wide, "#{reads} can be any text, as one argument."}
    end
  end
end
