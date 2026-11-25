defmodule MWTClient.Sandbox.OpennessTest do
  @moduledoc """
  How open a fixed call is (`MWTClient.Sandbox.Openness`): narrow when
  each value only picks among what the template names, wide when it can
  reach anything of a kind, open when it can become code or a command.
  A warning, never a decision.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, HostCommand, Openness, Param}

  doctest Openness
  doctest HostCommand, only: [files_run: 1]

  defp command(script, lines) do
    {:ok, params} = Param.parse(lines)
    Openness.grade(%Grant{id: "c", name: "C", kind: :command, script: script, params: params})
  end

  defp request(url, body, lines) do
    {:ok, params} = Param.parse(lines)

    Openness.grade(%Grant{
      id: "r",
      name: "R",
      kind: :request,
      method: "POST",
      url: url,
      body: body,
      params: params
    })
  end

  test "a saved command whose values only pick among what it names is narrow" do
    assert %{grade: :narrow, why: []} = command("echo hi", "")

    assert %{grade: :narrow} =
             command(
               ~s(./deploy "$TARGET" "$REPLICAS" "$DAY"),
               "TARGET: staging|production: where\nREPLICAS: number: how many\nDAY: date: when"
             )
  end

  test "a word or text read as one argument is wide, and says which" do
    assert %{grade: :wide, why: [why]} = command(~s(gh pr view "$REPO"), "REPO: word: the repo")
    assert why =~ "$REPO can be any name or path"

    assert %{grade: :wide, why: [why]} =
             command(~s(gh issue create --title "$TITLE"), "TITLE: text: the title")

    assert why =~ "any text, as one argument"
  end

  test "a value that can become code or a command is open, wherever the shell runs it" do
    for {script, words} <- [
          {"$CMD --version", "is the command that runs"},
          {~s(eval "$CMD"), "run by the shell as code (eval)"},
          {~s(bash -c "$CMD"), "(bash -c)"},
          {~s(python3 -c "$CMD"), "python3 code"},
          {~s(ssh deploy@box "$CMD"), "another machine"},
          {~s(kubectl exec -it web -- "$CMD"), "in a container"},
          {~s(find . -exec "$CMD" {} \\;), "find -exec"},
          # Bare, text splits into several arguments: options included.
          {"kubectl $CMD", "splits it into several arguments"}
        ] do
      assert %{grade: :open, why: [why]} = command(script, "CMD: text: what to run"), script
      assert why =~ words, script
    end

    # A word read bare can't split: it stays wide.
    assert %{grade: :wide} = command("gh repo view $REPO", "REPO: word: the repo")
  end

  test "the worst value decides, and its reasons are the ones said" do
    assert %{grade: :open, why: [why]} =
             command(
               ~s(gh pr view "$REPO" && $CMD),
               "REPO: word: the repo\nCMD: text: anything"
             )

    assert why =~ "$CMD"
  end

  test "a command that runs a file says which: it is only as narrow as the file" do
    assert %{files: ["./deploy.sh"]} = command("./deploy.sh staging", "")
  end

  test "a request is open when a value is its whole body or a query the service runs" do
    assert %{grade: :open} =
             request("https://api.example.com/graphql", ~s({"query": "$Q"}), "Q: text: the query")

    assert %{grade: :open} = request("https://api.example.com/x", "$BODY", "BODY: text: the body")

    assert %{grade: :wide} =
             request(
               "https://api.github.com/repos/$REPO/issues",
               ~s({"title": "$T"}),
               "REPO: word: r\nT: text: t"
             )

    assert %{grade: :narrow} =
             request("https://api.example.com/pulls/$PR", nil, "PR: number: the pull request")
  end

  test "any other grant has no grade" do
    assert Openness.grade(%Grant{id: "t", name: "T", kind: :token}) == nil
  end
end
