defmodule MWTClient.Sandbox.InboundTest do
  @moduledoc """
  What `MWTClient.Sandbox.Inbound` finds in what MWT moves into the VM:
  each shape, and the near miss next to it; real values in every form;
  and that a finding never carries the text it matched.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Inbound, Secrets}

  doctest Inbound

  defp token(n), do: String.duplicate("aB3", n) |> binary_part(0, n)

  @hits [
    {"a GitHub token", "ghp_" <> String.duplicate("x", 36)},
    {"a GitHub token", "github_pat_" <> String.duplicate("x", 60)},
    {"a GitLab token", "glpat-" <> String.duplicate("x", 20)},
    {"a Slack token", "xoxb-1234-5678-" <> String.duplicate("x", 24)},
    {"an OpenAI or Anthropic key", "sk-ant-api03-" <> String.duplicate("x", 80)},
    {"a Stripe key", "sk_live_" <> String.duplicate("x", 24)},
    {"an AWS access key", "AKIAIOSFODNN7EXAMPLE"},
    {"a Google API key", "AIza" <> String.duplicate("x", 35)},
    {"a Google access token", "ya29.a0AfH6SM" <> String.duplicate("x.", 20)},
    {"an npm token", "npm_" <> String.duplicate("x", 36)},
    {"a PyPI token", "pypi-" <> String.duplicate("x", 60)},
    {"a Hugging Face token", "hf_" <> String.duplicate("x", 34)},
    {"a private key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA"},
    {"a private key", "-----BEGIN RSA PRIVATE KEY-----"},
    {"a JWT",
     "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"}
  ]

  @misses [
    # Too short after the prefix.
    "ghp_" <> String.duplicate("x", 10),
    "AKIA1234",
    # In the middle of a word.
    "risk-" <> String.duplicate("x", 40),
    "xghp_" <> String.duplicate("x", 36),
    # Lowercase where only capitals and digits count.
    "AKIAiosfodnn7example",
    # Not a key's block.
    "-----BEGIN CERTIFICATE-----\nMIIB",
    "-----BEGIN PUBLIC KEY-----",
    # Two segments are not a JWT.
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0",
    "eyJ.short.x",
    # Words that start like prefixes.
    "the task-list is long and has many entries in it",
    "skipped sk- because"
  ]

  test "each shape is found, alone and in the middle of a line, on its line" do
    for {name, text} <- @hits do
      assert {:found, [%{what: {:shape, ^name}, line: 1}]} = Inbound.check(text, nil),
             "missed #{name}: #{text}"

      assert {:found, [%{what: {:shape, ^name}, line: 3}]} =
               Inbound.check("first\nsecond\nexport VALUE=#{text} # set\n", nil)
    end
  end

  test "near misses are not findings" do
    for text <- @misses do
      assert Inbound.check(text, nil) == :ok, "found something in #{inspect(text)}"
    end
  end

  test "a grant's placeholder is not a credential" do
    placeholder = "ghp_" <> token(40)
    assert {:found, _} = Inbound.check("x #{placeholder}", nil)
    assert :ok = Inbound.check("x #{placeholder}", nil, [placeholder])
  end

  test "real values are found in every form, with the grant's name" do
    value = "s3cr3t/value+with=chars"
    secrets = Secrets.new([{{:value, "Stripe"}, Secrets.forms(value)}])

    for form <- Secrets.forms(value) do
      assert {:found, [%{what: {:value, "Stripe"}, line: 2}]} =
               Inbound.check("ok\nvalue: #{form}\n", secrets)
    end

    assert Inbound.check("nothing here", secrets) == :ok
  end

  test "a finding never carries the text it matched" do
    value = "realvalue0123456789abcdef"
    secrets = Secrets.new([{{:value, "GitHub"}, Secrets.forms(value)}])
    text = Enum.map_join(@hits, "\n", &elem(&1, 1)) <> "\n" <> value

    {:found, findings} = Inbound.check(text, secrets)
    assert length(findings) == length(@hits) + 1
    shown = inspect(findings) <> Enum.map_join(findings, &Inbound.words/1)
    refute shown =~ value

    for {_name, hit} <- @hits do
      refute shown =~ binary_part(hit, 0, min(byte_size(hit), 20))
    end
  end

  test "at most twenty findings, one per line and thing" do
    many = Enum.map_join(1..50, "\n", fn _ -> "ghp_" <> token(36) end)
    assert {:found, findings} = Inbound.check(many, nil)
    assert length(findings) == 20
    assert Enum.map(findings, & &1.line) == Enum.to_list(1..20)

    twice = "ghp_#{token(36)} ghp_#{token(36)}"
    assert {:found, [_one]} = Inbound.check(twice, nil)
  end

  test "scrub writes out every grant's value, each as its own name" do
    secrets =
      Secrets.new([
        {{:value, "GitHub"}, Secrets.forms("ghp_0123456789abcdefXYZ")},
        {{:value, "Stripe"}, Secrets.forms("sk_live_abc/def+ghi0123")}
      ])

    text = "a=ghp_0123456789abcdefXYZ b=sk_live_abc%2Fdef%2Bghi0123 c"

    assert Inbound.scrub(text, secrets) == "a=[GitHub's token] b=[Stripe's token] c"
    assert Inbound.scrub(text, nil) == text
  end

  describe "a file" do
    setup do
      path = Path.join(System.tmp_dir!(), "inbound-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "is looked through whole, a window at a time, with lines counted from its start",
         %{path: path} do
      # Cut by the end of the first window, on the line after 4095 lines.
      lines = String.duplicate(String.duplicate("x", 1023) <> "\n", 4 * 1024 - 1)
      gap = String.duplicate("y", 4 * 1024 * 1024 - 20 - byte_size(lines) - 1) <> " "
      File.write!(path, lines <> gap <> "ghp_" <> String.duplicate("x", 36) <> "\nlast\n")

      assert {:found, [%{what: {:shape, "a GitHub token"}, line: 4096}]} =
               Inbound.check_file(path, nil)

      secrets = Secrets.new([{{:value, "GitHub"}, Secrets.forms("tok_real_value_0123456789")}])
      File.write!(path, "a\nb\nthe tok_real_value_0123456789\n")
      assert {:found, [%{what: {:value, "GitHub"}, line: 3}]} = Inbound.check_file(path, secrets)
    end

    test "a clean one, or none", %{path: path} do
      File.write!(path, "nothing here\n")
      assert :ok = Inbound.check_file(path, nil)
      assert {:error, :enoent} = Inbound.check_file(path <> ".gone", nil)
    end
  end
end
