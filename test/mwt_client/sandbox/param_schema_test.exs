defmodule MWTClient.Sandbox.ParamSchemaTest do
  @moduledoc """
  A fixed call's parameters as one JSON Schema
  (`MWTClient.Sandbox.ParamSchema`): written as an object whose
  properties are the parameters, held to its premises (each said what it
  is, every one required, one value each, nothing outside itself), and
  each value checked in a bounded process of its own after MWT's floor.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Param, ParamSchema}

  doctest ParamSchema
  doctest MWTClient.Sandbox.ParamSchema.Formats

  defp parse!(properties) do
    {:ok, params} =
      ParamSchema.parse(Jason.encode!(%{"type" => "object", "properties" => properties}))

    params
  end

  test "values keep to their schema, after MWT's floor: the agent hears why one doesn't" do
    params =
      ParamSchema.parse(~s({"type": "object", "properties": {
        "COUNT": {"description": "how many", "type": "integer", "minimum": 1, "maximum": 10},
        "TARGET": {"description": "where", "type": "string", "enum": ["staging", "production"]},
        "REPO": {"description": "the repository", "type": "string", "format": "word",
                 "pattern": "^oliveigah/[a-z0-9-]+$"},
        "TITLE": {"description": "the title", "type": "string", "maxLength": 12},
        "DRY": {"description": "only say what it would do", "type": "boolean"}}}))
      |> elem(1)

    assert Enum.map(params, & &1.name) == ~w(COUNT TARGET REPO TITLE DRY)

    good = %{
      "COUNT" => "3",
      "TARGET" => "staging",
      "REPO" => "oliveigah/klife",
      "TITLE" => "Fix login",
      "DRY" => "true"
    }

    assert {:ok, values} = Param.check(params, good)
    # Given to the script or the request as they came.
    assert {"COUNT", "3"} in values

    for {name, bad, kind, words} <- [
          {"COUNT", "11", :rule, "higher than maximum 10"},
          {"COUNT", "0", :rule, "lower than minimum 1"},
          {"COUNT", "three", :type, nil},
          {"TARGET", "prod", :rule, "one of the enum values"},
          {"REPO", "evil/klife", :rule, "pattern"},
          {"REPO", "oliveigah/k;rm", :rule, "word"},
          {"TITLE", "A title longer than twelve", :rule, "length"},
          {"DRY", "yes", :type, nil}
        ] do
      assert {:error, problem} = Param.check(params, Map.put(good, name, bad))
      assert elem(problem, 0) == kind and elem(problem, 1).name == name, inspect(problem)
      if words, do: assert(elem(problem, 2) =~ words)
    end

    # MWT's floor goes first, whatever the schema says.
    for bad <- ["--upload-pack=evil", "../klife", "a/./b"] do
      assert {:error, {:floor, %Param{name: "TITLE"}, _}} =
               Param.check(params, Map.put(good, "TITLE", bad))
    end
  end

  test "agents read each parameter in words: what it is and what its values may be" do
    [count] =
      parse!(%{
        "COUNT" => %{
          "description" => "how many",
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 10
        }
      })

    assert Param.describe(count) == "COUNT is an integer, from 1 to 10. It is: how many"
  end

  test "a schema that can't be one, or reaches outside itself, is refused as you write it" do
    property = fn schema ->
      Jason.encode!(%{"properties" => %{"REPO" => Map.put(schema, "description", "r")}})
    end

    for {text, words} <- [
          {"[1]", "JSON Schema object"},
          {"{not json", "isn't JSON"},
          {~s({"type": "array"}), "is an object"},
          {~s({"items": {}}), "items isn't for the call's schema"},
          {~s({"properties": {"repo": {"description": "r"}}}), "capitals"},
          {~s({"properties": {"PATH": {"description": "r"}}}), "already means something"},
          {~s({"properties": {"REPO": {"type": "string"}}}), "say what it is"},
          {~s({"properties": {"REPO": 3}}), "its schema is an object"},
          {~s({"properties": {"A": {"description": "a"}, "B": {"description": "b"}}, "required": ["A"]}),
           "Every parameter is required: B"},
          {property.(%{"type" => "array"}), "string, integer, number or boolean"},
          {property.(%{"$ref" => "https://example.com/s.json"}), "$ref may only point within"},
          {property.(%{"$ref" => "jsv:module:Elixir.Inspect.Opts"}),
           "$ref may only point within"},
          {property.(%{"$id" => "https://example.com/x"}), "$id may only point within"},
          {property.(%{"not" => %{"$schema" => "x"}}), "$schema"},
          {property.(%{"type" => "string", "format" => "no-such-format"}),
           "isn't a JSON Schema MWT can use"},
          {property.(%{"enum" => Enum.map(1..400, &"value-#{&1}")}), "at most 2048 bytes"},
          {Jason.encode!(%{"properties" => Map.new(1..9, &{"P#{&1}", %{"description" => "p"}})}),
           "At most 8"}
        ] do
      assert {:error, message} = ParamSchema.parse(text)
      assert message =~ words, "#{text}: #{message}"
    end

    # Within itself, a $ref is fine; empty, no parameters.
    assert [%Param{name: "REPO"}] =
             parse!(%{
               "REPO" => %{
                 "description" => "r",
                 "$defs" => %{"mine" => %{"pattern" => "^o/"}},
                 "$ref" => "#/$defs/mine"
               }
             })

    assert {:ok, []} = ParamSchema.parse("  ")
  end

  test "a schema whose checks fan out is stopped, and the process that asked goes on" do
    # Each level checks the next twice: 2^26 checks, from under 2 KiB.
    defs =
      Map.new(0..25, fn level ->
        next = %{"$ref" => "#/$defs/d#{level + 1}"}
        {"d#{level}", %{"allOf" => [next, next]}}
      end)
      |> Map.put("d26", %{"minLength" => 1})

    fanning = %{"$defs" => defs, "$ref" => "#/$defs/d0"}
    assert [_param] = parse!(%{"REPO" => Map.put(fanning, "description", "r")})
    {:links, before} = Process.info(self(), :links)

    assert {:error, why} = ParamSchema.check(fanning, "x")
    assert why =~ "its schema took too"
    assert {:links, ^before} = Process.info(self(), :links)
  end

  test "parameters saved with a shape and a rule, or brought from a file, are checked as they load" do
    old = %{name: "COUNT", shape: :number, about: "how many", rule: %{"maximum" => 10}}

    assert %Param{schema: %{"type" => "integer", "minimum" => 0, "maximum" => 10}} =
             Param.upgrade(old)

    # As saved: a struct of the older MWT's, whose fields these were.
    saved = Map.put(old, :__struct__, Param)
    assert %Param{name: "COUNT", schema: %{"maximum" => 10}} = Param.upgrade(saved)

    listed = %{name: "TARGET", shape: {:one_of, ["a", "b"]}, about: "where"}
    assert %Param{schema: %{"enum" => ["a", "b"]}} = Param.upgrade(listed)

    reaching = %{name: "R", about: "r", schema: %{"$ref" => "https://example.com/s.json"}}
    assert Param.upgrade(reaching).schema == %{"type" => "string"}
  end

  test "the schema as the form shows it: each parameter in order, its description first" do
    params = Param.parse("REPO: word: the repository\nCOUNT: number: how many") |> elem(1)
    text = ParamSchema.text(params)
    assert text =~ ~r/"REPO": \{\s+"description": "the repository",\s+"type": "string"/
    assert {:ok, ^params} = ParamSchema.parse(text)
    assert ParamSchema.text([]) == ""
  end
end
