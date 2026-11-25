defmodule MWTClient.Sandbox.ParamSchema do
  @moduledoc """
  A fixed call's parameters as one JSON Schema (2020-12), checked by
  `JSV`: an object whose properties are the parameters, each with what it
  is (`description`) and what its values may be (`type`, `format`, `enum`,
  `pattern`, `minimum`…), the way an MCP tool says its input. One standard
  everyone knows, agents included, rather than a language of MWT's.

      {
        "type": "object",
        "properties": {
          "REPO": {"description": "the repository, as owner/name",
                   "type": "string", "format": "word", "pattern": "^oliveigah/"},
          "PR": {"description": "the pull request", "type": "integer", "minimum": 1}
        }
      }

  What MWT holds a schema to, as its premises, refused as you write it:

    * the properties are the parameters, in order, at most #{8}; each name
      a parameter's (`MWTClient.Sandbox.Param`), and each with a
      `description`; every one is required (no `required` leaving one
      out), and no other is accepted;
    * a parameter's `type` is `string` (or none), `integer`, `number` or
      `boolean`: a value is one argument or one variable, never a list or
      an object;
    * a parameter's schema reads nothing outside itself: `$ref` only to
      `#…`, no `$id` or `$schema`; at most #{2048} bytes as JSON;
    * formats are checked: the standard ones (`date`, `date-time`,
      `email`, `uri`…) and MWT's `word` (`MWTClient.Sandbox.ParamSchema.Formats`);
      an unknown one is refused.

  What it can't loosen: MWT's own floor (`MWTClient.Sandbox.Param.check/2`)
  goes first, whatever the schema says. Each value is then checked
  against its parameter's schema in a process of its own, unlinked, at
  most #{1000} ms and #{8} MiB (`check/2`): a schema whose checks fan out
  fails the call instead of holding MWT; `pattern`s run with JSV's
  backtracking budget.

  Pure, but for that process.
  """

  alias MWTClient.Sandbox.Param

  @max_params 8
  @max_bytes 2048
  # How much work one value's check may do, in reductions: a parameter's
  # check takes a few thousand (6,000 for a word, building its schema
  # included), and a schema whose checks fan out does some 60 million a
  # second. Work, not time: a check waiting on a busy machine, or on code
  # loading, does none, and a valid value is never refused for it.
  @max_reductions 10_000_000
  # How often the work done is looked at, and how long a check may wait
  # in all, busy machine or not, before it is given up on.
  @poll_ms 20
  @backstop_ms 30_000
  # In words: 8 MiB on a 64-bit machine.
  @max_heap_words 1_000_000
  @types ["string", "integer", "number", "boolean"]
  @top ~w(type properties required additionalProperties description title)

  @typedoc "A parameter's schema: a JSON Schema, as JSON decodes it."
  @type t :: map()

  @doc """
  The parameters a call's schema text defines, in order; empty text, none.
  `{:ok, params}`, or why it can't be one.

      iex> alias MWTClient.Sandbox.ParamSchema
      iex> {:ok, [repo, pr]} = ParamSchema.parse(~s({"properties": {
      ...>   "REPO": {"description": "the repository", "type": "string", "format": "word"},
      ...>   "PR": {"description": "the pull request", "type": "integer", "minimum": 1}}}))
      iex> {repo.name, repo.about, pr.schema}
      {"REPO", "the repository", %{"type" => "integer", "minimum" => 1}}
      iex> ParamSchema.parse(~s({"properties": {"PR": {"type": "integer"}}}))
      {:error, "PR: say what it is, in its description."}
  """
  @spec parse(String.t() | nil) :: {:ok, [Param.t()]} | {:error, String.t()}
  def parse(text) do
    case String.trim(to_string(text || "")) do
      "" ->
        {:ok, []}

      text ->
        with {:ok, %Jason.OrderedObject{} = schema} <- decode(text),
             {:ok, properties} <- properties(schema),
             :ok <- required(schema, properties) do
          properties
          |> Enum.reduce_while({:ok, []}, fn {name, property}, {:ok, done} ->
            case param(name, property) do
              {:ok, param} -> {:cont, {:ok, done ++ [param]}}
              {:error, message} -> {:halt, {:error, message}}
            end
          end)
          |> case do
            {:ok, params} when length(params) > @max_params ->
              {:error,
               "At most #{@max_params} parameters. One that needs more is more than one call."}

            result ->
              result
          end
        end
    end
  end

  defp decode(text) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = schema} ->
        {:ok, schema}

      {:ok, _other} ->
        {:error,
         ~s(Write the parameters as a JSON Schema object: {"type": "object", "properties": {…}}.)}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "It isn't JSON: " <> Exception.message(error)}
    end
  end

  defp properties(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    cond do
      (key = Enum.find(keys, &(&1 not in @top))) != nil ->
        {:error,
         "#{key} isn't for the call's schema: its parameters go under properties, each with its own rules."}

      not Enum.member?([nil, "object"], plain(lookup(values, "type"))) ->
        {:error, ~s(The call's schema is an object: "type": "object", or none.)}

      true ->
        case lookup(values, "properties") do
          %Jason.OrderedObject{values: properties} -> {:ok, properties}
          nil -> {:ok, []}
          _other -> {:error, "properties is an object: each parameter's name, and its schema."}
        end
    end
  end

  # Every parameter is given on every call: a `required` leaving one out
  # would say otherwise.
  defp required(%Jason.OrderedObject{values: values}, properties) do
    names = Enum.map(properties, &elem(&1, 0))

    case plain(lookup(values, "required")) do
      nil ->
        :ok

      list when is_list(list) ->
        case names -- list do
          [] ->
            :ok

          left ->
            {:error,
             "Every parameter is required: #{Enum.join(left, ", ")} too, or leave required out."}
        end

      _other ->
        {:error, "required is a list of the parameters' names."}
    end
  end

  defp lookup(values, key), do: Enum.find_value(values, fn {k, v} -> if k == key, do: v end)

  # A parameter from its name and schema, held to the premises.
  defp param(name, property) do
    with :ok <- Param.name_error(name),
         %{} = schema <- plain(property) || :not_object,
         {:ok, about} <- description(name, schema),
         schema = Map.drop(schema, ["description"]),
         :ok <- valid(name, schema) do
      {:ok, %Param{name: name, about: about, schema: schema}}
    else
      :not_object -> {:error, ~s(#{name}: its schema is an object, such as {"type": "integer"}.)}
      {:error, message} -> {:error, message}
      _other -> {:error, ~s(#{name}: its schema is an object, such as {"type": "integer"}.)}
    end
  end

  defp description(name, schema) do
    case schema["description"] do
      text when is_binary(text) and text != "" ->
        {:ok, text |> String.trim() |> String.slice(0, 200)}

      _none ->
        {:error, "#{name}: say what it is, in its description."}
    end
  end

  @doc """
  Whether `schema` can be a parameter's: `:ok`, or why not, naming it.
  Also checks what comes from a file, as it loads.
  """
  @spec valid(String.t(), t()) :: :ok | {:error, String.t()}
  def valid(name, schema) do
    cond do
      not is_map(schema) ->
        {:error, ~s(#{name}: its schema is an object, such as {"type": "integer"}.)}

      byte_size(Jason.encode!(schema)) > @max_bytes ->
        {:error, "#{name}: its schema is at most #{@max_bytes} bytes."}

      (key = reaching(schema)) != nil ->
        {:error, "#{name}: #{key} may only point within its own schema (#/$defs/…)."}

      Map.has_key?(schema, "type") and schema["type"] not in @types ->
        {:error,
         "#{name}: its type is string, integer, number or boolean: a value is one argument, never a list or an object."}

      true ->
        case build(schema) do
          {:ok, _root} -> :ok
          {:error, words} -> {:error, "#{name}: it isn't a JSON Schema MWT can use: " <> words}
        end
    end
  end

  # The first key that reaches outside the schema: a `$ref` or
  # `$dynamicRef` not starting with `#`, an `$id`, or a `$schema`; at any
  # depth.
  defp reaching(%{} = map) do
    Enum.find_value(map, fn
      {key, value} when key in ["$ref", "$dynamicRef"] and is_binary(value) ->
        if String.starts_with?(value, "#"), do: nil, else: key

      {key, _value} when key in ["$ref", "$dynamicRef", "$id", "$schema"] ->
        key

      {_key, value} ->
        reaching(value)
    end)
  end

  defp reaching(list) when is_list(list), do: Enum.find_value(list, &reaching/1)
  defp reaching(_scalar), do: nil

  defp build(schema) do
    case JSV.build(schema,
           formats: [__MODULE__.Formats | JSV.default_format_validator_modules()]
         ) do
      {:ok, root} -> {:ok, root}
      {:error, %JSV.BuildError{reason: reason}} -> {:error, inspect(reason)}
      {:error, other} -> {:error, inspect(other)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Ordered objects as plain maps, at any depth: what JSV reads.
  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other

  @doc """
  A value as its schema sees it: a JSON number for an `integer` or
  `number`, `true` or `false` for a `boolean`, the text otherwise; `:error`
  when the text isn't one.

      iex> alias MWTClient.Sandbox.ParamSchema
      iex> {ParamSchema.typed(%{"type" => "integer"}, "42"), ParamSchema.typed(%{"type" => "integer"}, "4x")}
      {{:ok, 42}, :error}
      iex> ParamSchema.typed(%{"type" => "number"}, "-12.50")
      {:ok, -12.5}
      iex> ParamSchema.typed(%{}, "oliveigah/klife")
      {:ok, "oliveigah/klife"}
  """
  @spec typed(t(), String.t()) :: {:ok, term()} | :error
  def typed(%{"type" => "integer"}, value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  def typed(%{"type" => "number"}, value) do
    case Float.parse(value) do
      {number, ""} ->
        {:ok, if(number == trunc(number) and not (value =~ "."), do: trunc(number), else: number)}

      _other ->
        :error
    end
  end

  def typed(%{"type" => "boolean"}, value) when value in ["true", "false"],
    do: {:ok, value == "true"}

  def typed(%{"type" => "boolean"}, _value), do: :error
  def typed(_schema, value), do: {:ok, value}

  @doc """
  Whether a typed value keeps to its parameter's schema: `:ok`, or what is
  wrong, in words for the agent. Checked in a process of its own, with at
  most #{@max_reductions} reductions of work and 8 MiB: one that runs out
  of either fails.

      iex> MWTClient.Sandbox.ParamSchema.check(%{"maximum" => 10}, 11)
      {:error, "value 11 is higher than maximum 10"}
      iex> MWTClient.Sandbox.ParamSchema.check(%{"format" => "word"}, "../etc")
      {:error, "value does not respect the 'word' format (\\"it isn't a word\\")"}
  """
  @spec check(t(), term()) :: :ok | {:error, String.t()}
  def check(schema, data) do
    caller = self()
    ref = make_ref()

    # Monitored, never linked: killed for its memory, it takes nothing
    # with it, the sandbox's server that asks included.
    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false})
        send(caller, {ref, verdict(schema, data)})
      end)

    await(pid, monitor, ref, System.monotonic_time(:millisecond) + @backstop_ms)
  end

  defp await(pid, monitor, ref, give_up_at) do
    receive do
      {^ref, verdict} ->
        Process.demonitor(monitor, [:flush])
        verdict

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, "its schema took too much to check"}
    after
      @poll_ms ->
        worked =
          case Process.info(pid, :reductions) do
            {:reductions, reductions} -> reductions
            nil -> 0
          end

        if worked > @max_reductions or System.monotonic_time(:millisecond) > give_up_at,
          do: stop(pid, monitor, ref),
          else: await(pid, monitor, ref, give_up_at)
    end
  end

  defp stop(pid, monitor, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])

    receive do
      {^ref, _late} -> :ok
    after
      0 -> :ok
    end

    {:error, "its schema took too long to check"}
  end

  defp verdict(schema, data) do
    with {:ok, root} <- build(schema),
         {:ok, _data} <- JSV.validate(data, root) do
      :ok
    else
      {:error, %JSV.ValidationError{} = error} -> {:error, first_message(error)}
      {:error, _build} -> {:error, "its schema can't be read"}
    end
  catch
    {JSV.Helpers.RegexExt, :budget_exhausted} -> {:error, "its pattern took too long to check"}
  end

  # The first message of what JSV found wrong, the deepest cause first.
  defp first_message(error) do
    error
    |> JSV.normalize_error()
    |> messages()
    |> List.first("it doesn't keep to its schema")
  end

  defp messages(%{details: details}) when is_list(details),
    do: Enum.flat_map(details, &messages/1)

  defp messages(%{errors: errors}) when is_list(errors),
    do:
      Enum.flat_map(errors, fn
        %{details: [_ | _]} = error -> messages(error)
        %{message: message} -> [message]
        _other -> []
      end)

  defp messages(_other), do: []

  @doc """
  What a parameter's values may be, in a few words, for you and for
  agents: what its type and format say, then what the usual keywords say,
  the rest as JSON.

      iex> alias MWTClient.Sandbox.ParamSchema
      iex> ParamSchema.words(%{"type" => "integer", "minimum" => 1, "maximum" => 10})
      "an integer, from 1 to 10"
      iex> ParamSchema.words(%{"type" => "string", "enum" => ["a", "b"]})
      "one of: a, b"
      iex> ParamSchema.words(%{"type" => "string", "format" => "word", "pattern" => "^oliveigah/"})
      "a word (letters, digits and _ . - @ : +, in parts joined by /), matching ^oliveigah/"
  """
  @spec words(t()) :: String.t()
  def words(schema) do
    kind =
      cond do
        is_list(schema["enum"]) ->
          "one of: " <> Enum.map_join(schema["enum"], ", ", &show/1)

        Map.has_key?(schema, "const") ->
          "exactly #{show(schema["const"])}"

        schema["format"] == "word" ->
          "a word (letters, digits and _ . - @ : +, in parts joined by /)"

        schema["format"] == "date" ->
          "a date, YYYY-MM-DD"

        schema["format"] == "date-time" ->
          "a time, RFC 3339 (2026-11-17T12:00:00Z)"

        is_binary(schema["format"]) ->
          "text in the #{schema["format"]} format"

        schema["type"] == "integer" ->
          "an integer"

        schema["type"] == "number" ->
          "a number"

        schema["type"] == "boolean" ->
          "true or false"

        true ->
          "text"
      end

    said =
      [
        range(schema["minimum"], schema["maximum"]),
        schema["exclusiveMinimum"] && "over #{schema["exclusiveMinimum"]}",
        schema["exclusiveMaximum"] && "under #{schema["exclusiveMaximum"]}",
        schema["multipleOf"] && "a multiple of #{schema["multipleOf"]}",
        schema["pattern"] && "matching #{schema["pattern"]}",
        schema["minLength"] && "at least #{schema["minLength"]} characters",
        schema["maxLength"] && "at most #{schema["maxLength"]} characters"
      ]
      |> Enum.filter(&is_binary/1)

    known =
      ~w(type format minimum maximum exclusiveMinimum exclusiveMaximum multipleOf enum const pattern minLength maxLength title)

    rest = Map.drop(schema, known)

    Enum.join([kind | said], ", ") <>
      if(map_size(rest) == 0, do: "", else: ", and " <> Jason.encode!(rest))
  end

  defp range(nil, nil), do: nil
  defp range(min, nil), do: "at least #{min}"
  defp range(nil, max), do: "at most #{max}"
  defp range(min, max), do: "from #{min} to #{max}"

  defp show(value) when is_binary(value), do: value
  defp show(value), do: Jason.encode!(value)

  @doc """
  The call's schema as the form shows it: pretty JSON, each parameter in
  order with its description first; empty for a call with none.
  """
  @spec text([Param.t()]) :: String.t()
  def text([]), do: ""

  def text(params) do
    properties =
      Jason.OrderedObject.new(
        for param <- params do
          rest = param.schema |> Enum.sort_by(fn {key, _} -> {key != "type", key} end)
          {param.name, Jason.OrderedObject.new([{"description", param.about} | rest])}
        end
      )

    Jason.encode!(
      Jason.OrderedObject.new([{"type", "object"}, {"properties", properties}]),
      pretty: true
    )
  end
end
