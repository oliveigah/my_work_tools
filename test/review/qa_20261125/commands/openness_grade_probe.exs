defmodule MWTClient.QAProbes.Commands.OpennessGradeTest do
  @moduledoc """
  Probe: the grade of a saved command (`MWTClient.Sandbox.Openness`) against
  docs/grant_mental_model.md, "How open a fixed call is": a parameter is
  Open in `eval`, `bash -c`, `sh -c`, `python -c`, `node -e`,
  `ssh HOST "$P"`, `kubectl exec … -- $P`, `xargs`, `find -exec`, the
  command's first word, or read bare, where the shell splits and globs it.

  The dangerous direction is a template graded lower than it is (Wide or
  Narrow for one that is open use with extra steps): the page, the card and
  `mwt grants` then say it is "as narrow as the token or the script behind
  it". Each template here takes a value that becomes code or the command;
  a failing test is a template the grade calls less than Open.

  The last test checks Q8: the grade never changes whether a call asks.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Openness, Param}

  defp grade(script, params \\ "P: text: what to run") do
    {:ok, params} = Param.parse(params)
    Openness.grade(%Grant{id: "g", name: "G", kind: :command, script: script, params: params})
  end

  defp assert_open(script, params \\ "P: text: what to run") do
    %{grade: grade, why: why} = grade(script, params)

    assert grade == :open,
           "#{inspect(script)} is graded #{grade} (#{inspect(why)}), but its value becomes code or the command"
  end

  describe "what the doc lists, as written: holds" do
    test "eval, bash -c, sh -c, python -c, node -e" do
      assert_open(~s(eval "$P"))
      assert_open(~s(bash -c "$P"))
      assert_open(~s(sh -c "$P"))
      assert_open(~s(python3 -c "$P"))
      assert_open(~s(node -e "$P"))
    end

    test "ssh HOST \"$P\", kubectl exec -- $P, find -exec" do
      assert_open(~s(ssh build.lan "$P"))
      assert_open(~s(kubectl exec web-0 -- $P))
      assert_open(~s(find . -name x -exec "$P" {} +))
    end

    test "the command's first word, quoted or braced; env/exec wrappers" do
      assert_open(~s("$P" --help))
      assert_open(~s(${P} --help))
      assert_open(~s(env "$P" --help))
      assert_open(~s(exec "$P"))
    end

    test "a text value read bare" do
      assert_open(~s(kubectl $P))
    end
  end

  describe "the same, written a little differently: graded lower" do
    # xargs is in the doc's list, but `HostCommand.commands/1` drops it as a
    # wrapper, so nothing looks at what it runs.
    test "xargs runs what it reads from the value" do
      assert_open(~s(printf '%s\\n' "$P" | xargs -I{} sh -c '{}'))
      assert_open(~s(echo "$P" | xargs rm))
    end

    # Piped into a shell: the value is the shell's code.
    test "the value piped into a shell" do
      assert_open(~s(echo "$P" | sh))
      assert_open(~s(printf '%s' "$P" | bash))
      assert_open(~s(bash <<< "$P"))
    end

    # Flags bundled with -c: `"-c" in args` misses `-lc`, `-ec`, `-xc`.
    test "bash -lc / sh -ec" do
      assert_open(~s(bash -lc "$P"))
      assert_open(~s(sh -ec "$P"))
    end

    # A wrapper that isn't on the list hides the command after it.
    test "timeout, sudo, nice -n, watch in front" do
      assert_open(~s(timeout 60 bash -c "$P"))
      assert_open(~s(sudo "$P"))
      assert_open(~s(sudo -u deploy bash -c "$P"))
      assert_open(~s(nice -n 10 sh -c "$P"))
      assert_open(~s(watch -n 5 "$P"))
    end

    # The command's first word is a path holding the value: `command_name/1`
    # keeps only its basename, so the value isn't seen there. A text value
    # can be an absolute path (the floor refuses only `-` and `..`): the
    # workspace's from-vm, which the VM writes.
    test "the value is the directory of the command run" do
      assert_open(~s("$P/deploy.sh" staging))
      assert_open(~s($P/bin/tool --version))
    end

    test "inside a brace group or a function" do
      assert_open(~s({ eval "$P"; }))
      assert_open(~s<f() { eval "$P"; }; f>)
    end

    test "trap, awk, sed's e, perl -E, python3 -Ic, node -p" do
      assert_open(~s(trap "$P" EXIT; true))
      assert_open(~s(awk "$P" /etc/hostname))
      assert_open(~s(perl -E "$P"))
      assert_open(~s(python3 -Ic "$P"))
      assert_open(~s(node -p "$P"))
    end

    test "docker run IMAGE \"$P\" runs it in a container, as kubectl exec does" do
      assert_open(~s(docker run --rm alpine "$P"))
    end

    # The doc: "read bare, where the shell splits and globs it". A word can
    # hold no space, so only splitting is looked at; a pattern'd value can
    # hold `*`, which globs.
    test "a value read bare that may hold glob characters" do
      schema =
        ~s({"properties": {"P": {"description": "files", "type": "string", "pattern": "^[a-z*?]+$"}}})

      {:ok, params} = MWTClient.Sandbox.ParamSchema.parse(schema)

      %{grade: grade} =
        Openness.grade(%Grant{
          id: "g",
          name: "G",
          kind: :command,
          script: "rm $P",
          params: params
        })

      assert grade == :open, "rm $P with P matching ^[a-z*?]+$ is graded #{grade}"
    end
  end

  describe "a pattern counts as Narrow, whatever it lets through" do
    defp with_pattern(script, pattern) do
      schema =
        Jason.encode!(%{
          "properties" => %{
            "P" => %{"description" => "it", "type" => "string", "pattern" => pattern}
          }
        })

      {:ok, params} = MWTClient.Sandbox.ParamSchema.parse(schema)
      Openness.grade(%Grant{id: "g", name: "G", kind: :command, script: script, params: params})
    end

    # `Param.spaces?/1` says no pattern'd value holds a space, so the bare
    # read isn't looked at, and `by_schema/2` calls any pattern Narrow.
    test "kubectl $P, with a pattern that allows spaces and dashes, is graded Narrow" do
      %{grade: grade} = with_pattern("kubectl $P", "^[a-z0-9 ./-]+$")
      # "delete pods --all" keeps to it, and the floor (no leading -) too.
      assert grade == :open, "kubectl $P (pattern ^[a-z0-9 ./-]+$) is graded #{grade}"
    end

    test "gh api \"$P\" with the pattern ^.+$ is graded Narrow" do
      %{grade: grade} = with_pattern(~s(gh api "$P"), "^.+$")
      assert grade != :narrow, "a value that may be any text is graded #{grade}"
    end
  end

  describe "text values a tool reads as more than data (beyond the doc's list)" do
    # Not in the doc's list: noted, graded Wide ("any text, as one argument").
    test "git -c and make VAR=" do
      assert %{grade: :wide} = grade(~s(git -c "$P" log -1))
      assert %{grade: :wide} = grade(~s(make "$P"))
    end
  end

  test "Q8: an Open grade doesn't make a saved command ask (pure policy)" do
    {:ok, params} = Param.parse("P: text: what to run")
    now = ~U[2026-11-25 12:00:00Z]

    grant = %Grant{
      id: "open-one",
      name: "Open one",
      kind: :command,
      script: ~s(bash -c "$P"),
      dir: "/tmp",
      params: params,
      state: :on,
      allowances: [%MWTClient.Sandbox.Allowance{id: "a", pattern: :all, until: nil}]
    }

    assert %{grade: :open} = Openness.grade(grant)

    snapshot = %{grants: [grant, Grant.agent_commands()], own: [], resolve: fn _ -> [] end}

    assert {:allow, ^grant, _allowance, _about} =
             MWTClient.Sandbox.Policy.decide(snapshot, {:command, %{grant: "open-one"}}, now)
  end
end
