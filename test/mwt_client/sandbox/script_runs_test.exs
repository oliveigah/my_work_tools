defmodule MWTClient.Sandbox.ScriptRunsTest do
  @moduledoc """
  What a shell script runs, read from its text (`MWTClient.Sandbox.ScriptRuns`):
  the reader pins decide with and the hints and the grade warn with. Each
  test is a form the shell reads one way and a naive split another.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.ScriptRuns

  doctest ScriptRuns

  # Each command as its words, and what it runs behind.
  defp runs(script),
    do: for(run <- ScriptRuns.commands(script), do: {texts(run.words), run.through})

  defp texts(words), do: Enum.map(words, & &1.text)

  # The files as shown, and why for what can't be told.
  defp files(script) do
    for entry <- ScriptRuns.files(script) do
      case entry do
        {:file, shown, _word, _folder} -> shown
        {:unread, shown, why} -> {shown, why}
      end
    end
  end

  describe "words" do
    test "quotes and backslashes are removed; what expands is kept apart" do
      [%{words: [_x, a, b, c, d]}] = ScriptRuns.commands(~S(x "./a b" 'c$X' \$Y "$Z/w"))
      assert {a.text, a.literal?} == {"./a b", true}
      assert {b.text, b.literal?} == {"c$X", true}
      assert {c.text, c.literal?} == {"$Y", true}
      assert {d.text, d.literal?, d.vars, d.bare} == {"$Z/w", false, ["Z"], []}
    end

    test "a variable read bare, in a substitution, or in arithmetic is read" do
      [%{all: [_echo, word]} | _] = ScriptRuns.commands(~S[echo $A"$B"$(printf %s "$C")$((D+1))])
      assert Enum.sort(word.vars) == ["A", "B", "C", "D"]
      assert "A" in word.bare and "C" in word.bare
      refute "B" in word.bare
    end

    test "wildcards, braces and ~user are expansions; ~ is the home" do
      for script <- ["./*.sh", "./{a,b}.sh", "~bob/x.sh"] do
        assert [%{words: [word]}] = ScriptRuns.commands(script)
        refute word.literal?, script
      end

      [%{words: [home]}] = ScriptRuns.commands("~/bin/x")
      assert ScriptRuns.value(home, %{"HOME" => "/h"}) == {:ok, "/h/bin/x"}
    end
  end

  describe "commands" do
    test "split at every separator, here-documents left as text" do
      assert runs("a; b && c || d | e & f\ng") ==
               Enum.map(~w(a b c d e f g), &{[&1], []})

      assert runs("cat <<'EOF'\n./not-run.sh\nEOF\n./run.sh") == [
               {["cat"], []},
               {["./run.sh"], []}
             ]
    end

    test "substitutions, process substitutions and backticks run too" do
      assert {["./a.sh"], []} in runs("echo $(./a.sh) `./b.sh` <(./c.sh)")
      assert {["./b.sh"], []} in runs("echo $(./a.sh) `./b.sh` <(./c.sh)")
      assert {["./c.sh"], []} in runs("echo $(./a.sh) `./b.sh` <(./c.sh)")
    end

    test "wrappers are skipped with their own options" do
      for {script, through} <- [
            {"env -i -u X A=1 ./x.sh", ["env"]},
            {"nice -n 5 ./x.sh", ["nice"]},
            {"nice -10 ./x.sh", ["nice"]},
            {"timeout -k 5 -s KILL 30 ./x.sh", ["timeout"]},
            {"sudo -u deploy -E ./x.sh", ["sudo"]},
            {"sudo --user=deploy ./x.sh", ["sudo"]},
            {"stdbuf -oL ./x.sh", ["stdbuf"]},
            {"ionice -c 3 ./x.sh", ["ionice"]},
            {"chrt -f 10 ./x.sh", ["chrt"]},
            {"flock /tmp/l ./x.sh", ["flock"]},
            {"exec -a name ./x.sh", ["exec"]},
            {"command ./x.sh", ["command"]},
            {"nohup time -p ./x.sh", ["nohup", "time"]},
            {"/usr/bin/env ./x.sh", ["env"]}
          ] do
        assert runs(script) == [{["./x.sh"], through}], script
      end

      # A file named like a wrapper is that file.
      assert runs("./env ./x.sh") == [{["./env", "./x.sh"], []}]
      # Some run nothing.
      assert [{[], ["command"]}] = runs("command -v ./x.sh")
      assert [{[], ["sudo"]}] = runs("sudo -v")
    end

    test "find -exec, xargs and watch run commands" do
      assert {["./x.sh", "{}"], ["find -exec"]} in runs(
               ~S(find . -name '*.log' -exec ./x.sh {} \;)
             )

      assert {["./x.sh"], ["xargs"]} in runs("ls | xargs -n 1 ./x.sh")

      assert [%{code: [{:shell, "watch", %{text: "ls -l"}}]}, %{through: ["watch"]}] =
               ScriptRuns.commands("watch -n 5 ls -l")
    end

    test "brace groups, functions, if and case hold commands; their keywords aren't" do
      assert {["./a.sh"], []} in runs("{ ./a.sh; }")
      assert {["./b.sh"], []} in runs("f() { ./b.sh; }; f")
      assert {["./c.sh"], []} in runs("if [ -x ./c.sh ]; then ./c.sh; fi")
      script = ~S[case "$1" in start|go) ./d.sh;; *) echo no;; esac]
      assert {["./d.sh"], []} in runs(script)
      refute Enum.any?(runs(script), fn {words, _} -> "*" in words or "start|go" in words end)
    end

    test "literal shell code is read in turn, behind what runs it" do
      assert {["./x.sh"], ["sudo", "bash -c"]} in runs("sudo bash -lc 'cd sub && ./x.sh'")
      assert {["./y.sh"], ["eval"]} in runs("eval './y.sh'")
      assert {["./z.sh"], ["bash"]} in runs("bash <<EOF\n./z.sh\nEOF")
    end
  end

  describe "files" do
    test "the forms a file runs in, as the script names them" do
      for {script, file} <- [
            {"./x.sh", "./x.sh"},
            {"scripts/deploy.sh staging", "scripts/deploy.sh"},
            {"/opt/app/x.sh", "/opt/app/x.sh"},
            {~s("./x.sh" a), "./x.sh"},
            {"bash --norc -o pipefail x.sh", "x.sh"},
            {"bash -e -- x.sh", "x.sh"},
            {"sh -x x.sh", "x.sh"},
            {"source x.sh", "x.sh"},
            {". ./x.sh", "./x.sh"},
            {"python3 -W ignore -X dev x.py", "x.py"},
            {"python3 -uB x.py", "x.py"},
            {"node --inspect x.js", "x.js"},
            {"node --env-file .env x.js", "x.js"},
            {"perl -I lib -w x.pl", "x.pl"},
            {"ruby -I lib -rjson x.rb", "x.rb"},
            {"bash < x.sh", "x.sh"},
            {"cat x.sh | sh", "x.sh"},
            {"cat x.sh | sudo bash -s", "x.sh"}
          ] do
        assert files(script) == [file], script
      end
    end

    test "code, modules and the machine's own programs are no files" do
      for script <- [
            "bash -c 'echo hi'",
            "sh -ec 'true'",
            "python3 -c 'print(1)' x.py",
            "python3 -m http.server",
            "node -e '1' x.js",
            "node -pe '1'",
            "perl -E 'say 1' x.pl",
            "ruby -e 'p 1' x.rb",
            "/usr/bin/make all",
            "echo ./x.sh",
            "cd ./sub",
            "ssh box ./x.sh"
          ] do
        assert files(script) == [], script
      end
    end

    test "a cd moves where later files are, up to the end of its subshell or pipe" do
      assert files("cd sub && ./a.sh; ./b.sh") == ["sub/a.sh", "sub/b.sh"]
      assert files("(cd sub && ./a.sh); ./b.sh") == ["sub/a.sh", "./b.sh"]
      assert files("cd sub | true; ./b.sh") == ["./b.sh"]
      assert files("cd sub & ./b.sh") == ["./b.sh"]
      assert files("cd /opt && cd app && ./x.sh") == ["/opt/app/x.sh"]
      assert files("bash -c 'cd sub && ./a.sh'; ./b.sh") == ["sub/a.sh", "./b.sh"]
      assert files("eval 'cd sub'; ./a.sh") == ["sub/a.sh"]
      assert files("cd; ./a.sh") == ["~/a.sh"]

      # Whether a failing cd stops what follows: the folder is marked.
      [{:file, _, _, [{:cd, _, sure?}]}] = ScriptRuns.files("cd sub; ./a.sh")
      refute sure?

      for script <- ["cd sub && ./a.sh", "cd sub || exit 1\n./a.sh", "set -eu\ncd sub\n./a.sh"] do
        [{:file, _, _, [{:cd, _, sure?}]}] = ScriptRuns.files(script)
        assert sure?, script
      end

      [{:file, _, _, :unknown}] = ScriptRuns.files("cd - && ./a.sh")
    end

    test "what runs files MWT can't tell is said, with why" do
      assert files(~s(sh -c "$P")) == [{"sh -c $P", "shell code built from a variable"}]
      assert files(~s(bash <<< "$P")) == [{"bash", "fed code built from a variable"}]
      assert files("echo ./x.sh | sh") == [{"echo | sh", "fed as code what echo writes"}]
      assert files("curl -s https://x | sh") == [{"curl | sh", "fed code it downloads"}]
      assert files("ls | xargs bash") == [{"bash", "given the files it runs by xargs"}]
      assert files(~s(sudo -"$F" ./x.sh)) == [{"sudo", "with options built from a variable"}]
      # A variable where the command goes is what runs.
      assert files(~s(sudo $FLAGS ./x.sh)) == ["$FLAGS"]

      assert [{:file, "./x.sh", _, _}, {:file, "{}", word, _}] =
               ScriptRuns.files(~S(find . -exec ./x.sh {} \; -exec {} \;))

      refute word.literal?
    end
  end
end
