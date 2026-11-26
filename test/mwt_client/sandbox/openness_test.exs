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

  defp patterned(script, pattern) do
    {:ok, params} =
      MWTClient.Sandbox.ParamSchema.parse(
        Jason.encode!(%{"properties" => %{"P" => %{"description" => "p", "pattern" => pattern}}})
      )

    Openness.grade(%Grant{id: "c", name: "C", kind: :command, script: script, params: params})
  end

  test "a pattern is narrow only when its text proves the value keeps to names" do
    for pattern <- [
          "^[a-z0-9]+$",
          "^v[0-9]+(\\.[0-9]+)*$",
          "^(staging|prod)$",
          "^[A-Z]+_[0-9]{1,4}$"
        ] do
      assert %{grade: :narrow} = patterned("deploy $P", pattern), pattern
    end

    # Space, a wildcard, a slash, two dots, a leading dash, or a pattern
    # anchored at one end, or one it can't read: no proof.
    for pattern <- [
          "^[a-z ]+$",
          "^[a-z*]+$",
          "^[a-z/]+$",
          "^[a-z.]+$",
          "^[a-z-]+$",
          "^v1",
          "^(?i)[a-z]+$",
          "^.+$"
        ] do
      assert %{grade: grade} = patterned(~s(deploy "$P"), pattern)
      assert grade == :wide, pattern
    end

    # Read bare, one that may hold a space or a wildcard is open.
    assert %{grade: :open} = patterned("deploy $P", "^[a-z ]+$")
    assert %{grade: :open} = patterned("rm $P", "^[a-z*?]+$")
  end

  test "code reached past wrappers, bundles, pipes and tools is open, and says where" do
    for {script, words} <- [
          {~s(timeout 60 sudo -u ci bash -lc "$CMD"), "(bash -c) (behind timeout, sudo)"},
          {~s(echo "$CMD" | sh), "is fed to sh as code"},
          {~s(sh <<EOF\n$CMD\nEOF), "is fed to sh as code"},
          {~s(echo "$CMD" | xargs rm), "becomes arguments xargs splits"},
          {~s("$CMD/deploy.sh"), "is the command that runs, or its folder"},
          {~s(python3 "$CMD"), "picks the file that runs"},
          {~s(LD_PRELOAD="$CMD" ls), "sets LD_PRELOAD, which the loader reads"},
          {~s(awk -F, "$CMD" data.csv), "awk program text"},
          {~s(sed "$CMD" f), "sed script"},
          {~s(printf '%s' "$CMD" | sed 's/.*/&/e'), "sed script or what it runs"},
          {~s(kubectl run x --image="$CMD"), "in a container (kubectl run)"},
          {~s(bash -c 'eval "$CMD"'), "(eval) (behind bash -c)"},
          {~s(trap "$CMD" EXIT), "(trap)"}
        ] do
      assert %{grade: :open, why: [why]} = command(script, "CMD: text: what"), script
      assert why =~ words, "#{script}: #{why}"
    end

    # Where it is only an argument, it stays wide.
    for script <- [
          ~s(kubectl exec -n "$CMD" web -- ls),
          ~s(awk '{print $1}' "$CMD"),
          ~s(sed 's/a/b/' "$CMD"),
          ~s(bash -c 'echo "$CMD"'),
          ~s(X="$CMD" ./run.sh)
        ] do
      assert %{grade: :wide} = command(script, "CMD: text: what"), script
    end
  end

  test "any other grant has no grade" do
    assert Openness.grade(%Grant{id: "t", name: "T", kind: :token}) == nil
  end
end
