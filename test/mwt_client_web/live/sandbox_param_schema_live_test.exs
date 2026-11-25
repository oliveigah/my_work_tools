defmodule MWTClientWeb.SandboxParamSchemaLiveTest do
  @moduledoc """
  A fixed call's parameters on its page: one JSON Schema in its settings,
  each parameter shown in words, one that can't be refused as you save
  it, and a call breaking it refused and logged without its value.
  """
  use MWTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MWTClient.Sandbox

  setup %{conn: conn} do
    sign_in(conn, "schema-live")
  end

  @schema ~s({"type": "object", "properties": {
    "TARGET": {"description": "where it goes", "type": "string", "enum": ["staging", "production"]},
    "REPLICAS": {"description": "how many", "type": "integer", "minimum": 1, "maximum": 10}}})

  test "a saved command's parameters: one schema, shown in words, a broken one refused",
       %{conn: conn, username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "deploy",
        "purpose" => "Deploys a build",
        "script" => ~s(./deploy "$TARGET" "$REPLICAS"),
        "schema" => @schema,
        "dir" => System.tmp_dir!()
      })

    assert [%{name: "TARGET", schema: %{"enum" => _}}, %{name: "REPLICAS"}] = grant.params

    {:ok, view, _html} = live(conn, ~p"/tools/sandbox/grants/#{grant.id}")
    assert has_element?(view, "#grant-param-schema-TARGET", "one of: staging, production")
    assert has_element?(view, "#grant-param-schema-REPLICAS", "an integer, from 1 to 10")
    assert has_element?(view, "#grant-schema", "\"maximum\": 10")
    # Where it runs, beside the script.
    assert has_element?(view, "#grant-script-where", "Runs on host")
    # How open: each value picks among what the template names, and it
    # runs a file, which can change after it was saved.
    assert has_element?(view, "#grant-openness-grade", "Narrow")
    assert has_element?(view, "#grant-openness-files", "./deploy")

    view
    |> form("#grant-settings-form",
      grant: %{schema: String.replace(@schema, ~s("type": "integer"), ~s("type": "array"))}
    )
    |> render_change()

    view |> form("#grant-settings-form") |> render_submit()
    assert has_element?(view, "#grant-schema-box", "string, integer, number or boolean")

    # Agents read them in mwt grants.
    [saved] = Enum.filter(Sandbox.snapshot(username).grants, &(&1.id == grant.id))

    assert MWTClient.Sandbox.Instructions.usage(saved) =~
             "REPLICAS is an integer, from 1 to 10"

    {:ok, _} = Sandbox.turn_on(username, grant.id, :until_off, :ask)

    # A call breaking the schema: refused before anything runs, the agent
    # told why, and a line in the log naming the parameter, never the value.
    assert {:error, {:values, _grant, {:rule, %{name: "REPLICAS"}, why}}} =
             MWTClient.Sandbox.Server.call(
               username,
               {:request_command,
                %{
                  grant: grant.id,
                  script: nil,
                  values: %{"TARGET" => "staging", "REPLICAS" => "4242"},
                  reason: "scale"
                }}
             )

    assert why =~ "higher than maximum 10"

    assert [event | _] =
             Enum.filter(Sandbox.events(username, %{limit: 20}), &(&1.outcome == :refused))

    assert event.summary ==
             "Call of deploy · refused before anything ran: REPLICAS isn't an integer, from 1 to 10"
  end

  test "agents' NAME: shape: what it is lines still make a call, as the schema they stand for",
       %{username: username} do
    {:ok, grant} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "view",
        "purpose" => "Views a repository",
        "script" => ~s(gh repo view "$REPO"),
        "params" => "REPO: word: the repository",
        "dir" => System.tmp_dir!()
      })

    assert [%{schema: %{"type" => "string", "format" => "word"}}] = grant.params

    assert {:error, %{params: "Give the parameters once" <> _}} =
             Sandbox.create_grant(username, %{
               "kind" => "command",
               "name" => "view twice",
               "purpose" => "Views a repository",
               "script" => ~s(gh repo view "$REPO"),
               "params" => "REPO: word: the repository",
               "schema" => ~s({"properties": {"REPO": {"description": "r"}}}),
               "dir" => System.tmp_dir!()
             })
  end
end
