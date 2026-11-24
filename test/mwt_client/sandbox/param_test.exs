defmodule MWTClient.Sandbox.ParamTest do
  @moduledoc """
  An action's parameters: how they are written, which values each shape
  takes, and what a script must do with them.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Param

  doctest Param

  defp params!(text) do
    {:ok, params} = Param.parse(text)
    params
  end

  describe "a word" do
    test "is a name, a version, or parts joined by slashes" do
      for value <- ~w(klife oliveigah/klife v1.2.0 feature/login-v2 lib/app.ex user@host a:b a+b
                      .github/workflows _private 42) do
        assert Param.fits?(:word, value), value
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
        refute Param.fits?(:word, value), inspect(value)
      end
    end
  end

  test "a number is digits only" do
    assert Param.fits?(:number, "0") and Param.fits?(:number, "123456789012345678")

    for value <- ["", "-1", "1.5", "1e3", " 1", "0x10", "1234567890123456789"],
        do: refute(Param.fits?(:number, value), value)
  end

  test "a list takes its own values and nothing else" do
    shape = {:one_of, ["staging", "production"]}
    assert Param.fits?(shape, "staging")
    for value <- ["Staging", "staging ", "dev", ""], do: refute(Param.fits?(shape, value))
  end

  test "text is anything that isn't empty and doesn't start with a dash" do
    assert Param.fits?(:text, "Fix the login page; see #12 & \"quotes\" $(not run)")
    assert Param.fits?(:text, "two\nlines")

    for value <- ["", "   ", "-m", " --force", String.duplicate("a", 4097)],
        do: refute(Param.fits?(:text, value), inspect(value))
  end

  describe "a call's values" do
    setup do
      %{params: params!("REPO: word: the repository\nPR: number: the pull request")}
    end

    test "come back in the parameters' order", %{params: params} do
      assert Param.check(params, %{"PR" => "12", "REPO" => "o/r"}) ==
               {:ok, [{"REPO", "o/r"}, {"PR", "12"}]}
    end

    test "are refused when one is missing, unknown, of another shape, or hides something",
         %{params: params} do
      assert {:error, {:missing, %Param{name: "PR"}}} = Param.check(params, %{"REPO" => "o/r"})
      assert {:error, {:missing, %Param{name: "REPO"}}} = Param.check(params, nil)

      assert {:error, {:unknown, "BRANCH"}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => "1", "BRANCH" => "x"})

      assert {:error, {:shape, %Param{name: "PR"}}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => "one"})

      assert {:error, {:shape, %Param{name: "PR"}}} =
               Param.check(params, %{"REPO" => "o/r", "PR" => 1})

      hidden = "o/r" <> <<0x200B::utf8>>

      assert {:error, {:hidden, %Param{name: "REPO"}, ["U+200B"]}} =
               Param.check(params, %{"REPO" => hidden, "PR" => "1"})
    end

    test "each refusal says what the parameter takes", %{params: [repo, _pr]} do
      assert Param.explain({:shape, repo}) =~ "REPO is a word"
      assert Param.explain({:shape, repo}) =~ "It is: the repository"
      assert Param.explain({:missing, repo}) =~ "REPO=value"
    end

    test "an action with none takes none" do
      assert Param.check([], %{}) == {:ok, []}
      assert Param.check([], nil) == {:ok, []}
      assert {:error, {:unknown, "A"}} = Param.check([], %{"A" => "b"})
    end
  end

  describe "parameters as you write them" do
    test "round-trip through their lines" do
      text = "REPO: word: the repository\nTARGET: staging|production: where\nNOTE: text: a note"
      assert text |> params!() |> Enum.map_join("\n", &Param.line/1) == text
    end

    test "a name is in capitals and means nothing else already" do
      for name <- ~w(PATH HOME IFS LD_PRELOAD GIT_DIR BASH_ENV SSH_AUTH_SOCK MWT_X LC_ALL) do
        assert {:error, message} = Param.parse("#{name}: word: x")
        assert message =~ "already means something", name
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
    assert {:ok, [%Param{shape: :date}, %Param{shape: :time}, %Param{shape: :decimal}]} =
             Param.parse("DAY: date: the day\nAT: time: when\nAMOUNT: decimal: how much")

    assert Param.fits?(:date, "2026-11-17")
    refute Param.fits?(:date, "2026-02-30")
    refute Param.fits?(:date, "2026-11-17T00:00:00Z")
    assert Param.fits?(:time, "2026-11-17T12:00:00Z")
    assert Param.fits?(:time, "2026-11-17T12:00:00.123-03:00")
    refute Param.fits?(:time, "2026-11-17 noon")
    refute Param.fits?(:time, "2026-11-17T25:00:00Z")
    assert Param.fits?(:decimal, "-12.50")
    assert Param.fits?(:decimal, "7")
    refute Param.fits?(:decimal, "1e9")
    refute Param.fits?(:decimal, "12.")
    assert Param.shape_words(:date) =~ "YYYY-MM-DD"
  end
end
