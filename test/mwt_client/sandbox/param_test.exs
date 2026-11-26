defmodule MWTClient.Sandbox.ParamTest do
  @moduledoc """
  A fixed call's parameters: how they are written (a JSON Schema, or
  `NAME: shape: what it is` lines), MWT's floor under every value, which
  values each shorthand takes, and what a script must do with them.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Param, ParamSchema}

  doctest Param

  defp params!(text) do
    {:ok, params} = Param.parse(text)
    params
  end

  # Whether a value fits a parameter of the shorthand `shape`.
  defp fits?(shape, value) do
    [param] = params!("P: #{shape}: a parameter")
    match?({:ok, _}, Param.check([param], %{"P" => value}))
  end

  describe "a word" do
    test "is a name, a version, or parts joined by slashes" do
      for value <- ~w(klife oliveigah/klife v1.2.0 feature/login-v2 lib/app.ex user@host a:b a+b
                      .github/workflows _private 42) do
        assert fits?("word", value), value
      end
    end

    test "never reads as an option, goes up or to the root, or holds what the shell acts on" do
      for value <- [
            "-v",
            "--web",
            "/etc/passwd",
            "../up",
            "a/../b",
            "a/./b",
            "a//b",
            "a/",
            "..",
            ".",
            "a b",
            "a\tb",
            "a\nb",
            "a;b",
            "a|b",
            "a&b",
            "$(id)",
            "`id`",
            "$HOME",
            "a*",
            "a?",
            "[ab]",
            "{a,b}",
            "~",
            "a'b",
            "a\"b",
            "a\\b",
            "a>b",
            "a<b",
            "a#b",
            "a!b",
            "a=b",
            "",
            String.duplicate("a", 201)
          ] do
        refute fits?("word", value), inspect(value)
      end
    end
  end

  test "a number is a whole number, 0 or more" do
    assert fits?("number", "0") and fits?("number", "123456789012345678")

    for value <- ["", "-1", "1.5", "1e3", " 1", "0x10", "one"],
        do: refute(fits?("number", value), value)
  end

  test "a list takes its own values and nothing else" do
    assert fits?("staging|production", "staging")

    for value <- ["Staging", "staging ", "dev", ""],
        do: refute(fits?("staging|production", value))
  end

  test "text is anything that isn't blank, doesn't start with a dash and doesn't go up a folder" do
    assert fits?("text", "Fix the login page; see #12 & \"quotes\" $(not run)")
    assert fits?("text", "two\nlines")
    assert fits?("text", "v1..v2 and a/b")

    for value <- [
          "",
          "   ",
          "-m",
          " --force",
          "../etc/passwd",
          "a/../b",
          "..\\..\\admin",
          "x\\..\\y",
          "%2e%2e/admin",
          "a/%2E%2E%5Cb",
          "%252e%252e",
          String.duplicate("a", 4097)
        ],
        do: refute(fits?("text", value), inspect(value))

    # A backslash or a percent sign elsewhere is text.
    assert fits?("text", "C:\\Users\\me and 50% off")
  end

  test "a value read bare splits or globs, unless its schema proves it can't" do
    for {schema, splits?} <- [
          {%{"type" => "string"}, true},
          {%{"type" => "string", "format" => "word"}, false},
          {%{"type" => "integer"}, false},
          {%{"enum" => ["a b", "c"]}, true},
          {%{"enum" => ["a", "c"]}, false},
          {%{"pattern" => "^[a-z0-9-]+$"}, false},
          {%{"pattern" => "^[a-z ]+$"}, true},
          {%{"pattern" => "^[a-z*]+$"}, true},
          {%{"pattern" => "^[a-z]"}, true}
        ] do
      assert Param.spaces?(schema) == splits?, inspect(schema)
    end
  end

  test "a negative number is no option" do
    [amount] = params!("AMOUNT: decimal: how much")
    assert {:ok, [{"AMOUNT", "-12.50"}]} = Param.check([amount], %{"AMOUNT" => "-12.50"})
  end

  describe "a call's values" do
    setup do
      %{params: params!("REPO: word: the repository\nPR: number: the pull request")}
    end

    test "come back in the parameters' order", %{params: params} do
      assert Param.check(params, %{"PR" => "12", "REPO" => "o/r"}) ==
               {:ok, [{"REPO", "o/r"}, {"PR", "12"}]}
    end

    test "are refused when one is missing, unknown, of another type, or hides something",
         %{params: params} do
      assert {:error, {:missing, %Param{name: "PR"}}} = Param.check(params, %{"REPO" => "o/r"})
      assert {:error, {:missing, %Param{name: "REPO"}}} = Param.check(params, nil)

      assert {:error, {:unknown, "BRANCH"}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => "1", "BRANCH" => "x"})

      assert {:error, {:type, %Param{name: "PR"}}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => "one"})

      assert {:error, {:type, %Param{name: "PR"}}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => 1})

      hidden = "o/r" <> <<0x200B::utf8>>

      assert {:error, {:hidden, %Param{name: "REPO"}, ["U+200B"]}} =
               Param.check(params, %{"REPO" => hidden, "PR" => "1"})
    end

    test "each refusal says what the parameter takes", %{params: [repo, _pr]} do
      assert Param.explain({:type, repo}) =~ "REPO is a word"
      assert Param.explain({:type, repo}) =~ "It is: the repository"
      assert Param.explain({:missing, repo}) =~ "REPO=value"
    end

    test "an action with none takes none" do
      assert Param.check([], %{}) == {:ok, []}
      assert Param.check([], nil) == {:ok, []}
      assert {:error, {:unknown, "A"}} = Param.check([], %{"A" => "b"})
    end
  end

  describe "parameters as you write them" do
    test "lines make a schema, which round-trips through its text" do
      params =
        params!(
          "REPO: word: the repository\nTARGET: staging|production: where\nNOTE: text: a note"
        )

      assert {:ok, ^params} = params |> ParamSchema.text() |> ParamSchema.parse()
    end

    test "a name is in capitals and means nothing else already" do
      for name <-
            ~w(PATH HOME IFS LD_PRELOAD GIT_DIR BASH_ENV SSH_AUTH_SOCK MWT_X LC_ALL
                     PYTHONPATH PYTHONSTARTUP NODE_OPTIONS PERL5OPT RUBYOPT KUBECONFIG DOCKER_HOST
                     HTTPS_PROXY NO_PROXY XDG_CONFIG_HOME SSL_CERT_FILE TMPDIR GCONV_PATH AWS_PROFILE) do
        assert {:error, message} = Param.parse("#{name}: word: x")
        assert message =~ "already means something", name
      end

      assert {:error, message} = Param.parse("KUBECONFIG: word: x")
      assert message =~ "to kubectl, which reads it from the environment"

      for name <- ~w(REPO PR NAMESPACE TARGET POD TITLE BRANCH TAG IMAGE HOST NOTE) do
        assert {:ok, _} = Param.parse("#{name}: word: x"), name
      end

      for name <- ["repo", "Repo", "1A", "A-B", "A B", ""] do
        assert {:error, _message} = Param.parse("#{name}: word: x"), name
      end
    end

    test "at most eight, each once, each said what it is" do
      nine = Enum.map_join(1..9, "\n", &"P#{&1}: word: parameter #{&1}")
      assert {:error, "At most 8" <> _} = Param.parse(nine)
      assert {:error, "A is there twice."} = Param.parse("A: word: x\nA: number: y")
      assert {:error, message} = Param.parse("A: word")
      assert message =~ "say what it is"
    end
  end

  describe "how a script reads them" do
    test "a parameter it doesn't name is unused; one in single quotes counts as named" do
      params = params!("A: word: a\nB: word: b\nAB: word: ab")
      assert params |> Param.unused(~s(echo "$A" ${AB})) |> Enum.map(& &1.name) == ["B"]
      # $AB is not a use of $A.
      assert params |> Param.unused(~s(echo "$AB")) |> Enum.map(& &1.name) == ["A", "B"]
      assert Param.unused(params, "echo '$A' $B $AB") == []
    end

    test "hints at text read bare, and at a parameter the shell would leave as it is" do
      params = params!("TITLE: text: the title\nREPO: word: the repository")

      assert Param.hints(params, ~s(gh issue create -R "$REPO" --title "$TITLE")) == []
      # A word holds no spaces: bare is fine.
      assert Param.hints(params, ~s(gh issue create -R $REPO --title "$TITLE")) == []

      assert [hint] = Param.hints(params, ~s(gh issue create -R "$REPO" --title $TITLE))
      assert hint =~ "$TITLE can hold spaces"

      assert [hint] = Param.hints(params, ~s(gh issue create -R '$REPO' --title "$TITLE"))
      assert hint =~ "$REPO is inside single quotes"

      # An escaped quote doesn't open one.
      assert Param.hints(params, ~s(echo \\"x "$TITLE" "$REPO")) == []
    end
  end

  test "dates, times and decimals" do
    assert {:ok, [day, at, amount]} =
             Param.parse("DAY: date: the day\nAT: time: when\nAMOUNT: decimal: how much")

    assert day.schema == %{"type" => "string", "format" => "date"}
    assert at.schema == %{"type" => "string", "format" => "date-time"}
    assert amount.schema == %{"type" => "number"}

    assert fits?("date", "2026-11-17")
    refute fits?("date", "2026-02-30")
    refute fits?("date", "2026-11-17T00:00:00Z")
    assert fits?("time", "2026-11-17T12:00:00Z")
    assert fits?("time", "2026-11-17T12:00:00.123-03:00")
    refute fits?("time", "2026-11-17 noon")
    refute fits?("time", "2026-11-17T25:00:00Z")
    assert fits?("decimal", "-12.50")
    assert fits?("decimal", "7")
    refute fits?("decimal", "12.x")
    assert ParamSchema.words(day.schema) =~ "YYYY-MM-DD"
  end
end
