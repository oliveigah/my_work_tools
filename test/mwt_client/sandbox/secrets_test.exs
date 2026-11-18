defmodule MWTClient.Sandbox.SecretsTest do
  @moduledoc """
  What MWT looks for in bytes passing through it (`Secrets`), and the
  stream that looks chunk by chunk (`Egress.Scanner`): a form split across
  chunks is found, and holding, none of it is let through first.
  """
  use ExUnit.Case, async: true

  doctest MWTClient.Sandbox.Secrets

  alias MWTClient.Sandbox.Egress.Scanner
  alias MWTClient.Sandbox.Secrets

  @value "ghp_0123456789abcdefABCDEF"

  defp secrets, do: Secrets.new([{{:value, "GitHub"}, Secrets.forms(@value)}])

  # Feeds `chunks` one by one: the bytes let through, and what was found.
  defp stream(scanner, chunks) do
    Enum.reduce_while(chunks, {"", scanner}, fn chunk, {out, scanner} ->
      case Scanner.feed(scanner, chunk) do
        {:ok, bytes, scanner} -> {:cont, {out <> bytes, scanner}}
        {:found, label} -> {:halt, {out, {:found, label}}}
      end
    end)
  end

  test "nothing long enough to look for is nothing to look for" do
    assert Secrets.new([]) == nil
    assert Secrets.new([{{:value, "Short"}, ["abc"]}]) == nil
    assert Secrets.find(nil, @value) == nil
    assert %Secrets{} = Secrets.new([{{:value, "Short"}, ["abcdefgh"]}], 8)
  end

  test "a value is found as it is, JSON-escaped and percent-encoded" do
    value = "ya29.a0/AbC+dEf=gHiJkLmNoP"
    secrets = Secrets.new([{{:value, "Google"}, Secrets.forms(value)}])

    for quoted <- [
          value,
          String.replace(value, "/", "\\/"),
          URI.encode_www_form(value),
          Jason.encode!(%{"token" => value})
        ] do
      assert Secrets.find(secrets, "seen: " <> quoted) == {:value, "Google"}, quoted
    end
  end

  test "each form keeps the label of its entry" do
    secrets =
      Secrets.new([
        {{:value, "GitHub"}, [@value]},
        {{:placeholder, "Hex"}, ["mwt_placeholder_0123456789"]}
      ])

    assert Secrets.find(secrets, "a mwt_placeholder_0123456789") == {:placeholder, "Hex"}
    assert Secrets.find(secrets, "b " <> @value) == {:value, "GitHub"}
  end

  test "it never prints what it holds" do
    refute inspect(secrets()) =~ @value
    refute inspect(Scanner.new(secrets())) =~ @value
    refute inspect(%{state: secrets()}, limit: :infinity, printable_limit: :infinity) =~ "0123"
  end

  test "a form split across chunks, at any point, is found" do
    data = "HTTP body before " <> @value <> " and after"

    for at <- 1..(byte_size(data) - 1) do
      <<first::binary-size(at), second::binary>> = data

      assert {_out, {:found, {:value, "GitHub"}}} =
               stream(Scanner.new(secrets()), [first, second])
    end
  end

  test "holding, no byte of the value goes before it is found" do
    data = ~s({"echo":") <> @value <> ~s("})

    for at <- 1..(byte_size(data) - 1) do
      <<first::binary-size(at), second::binary>> = data

      {out, {:found, _}} = stream(Scanner.new(secrets(), hold: true), [first, second])

      refute String.contains?(out, binary_part(@value, 0, 1) <> binary_part(@value, 1, 1)),
             "the start of the value went at #{at}: #{inspect(out)}"
    end
  end

  test "holding, what isn't the value goes, and what was held goes on release" do
    scanner = Scanner.new(secrets(), hold: true)
    assert {:ok, "plain text, ", scanner} = Scanner.feed(scanner, "plain text, ghp_01")
    assert Scanner.held?(scanner)
    assert {"ghp_01", scanner} = Scanner.release(scanner)
    refute Scanner.held?(scanner)

    # What would complete it after a release is still found.
    assert {:found, {:value, "GitHub"}} =
             Scanner.feed(scanner, binary_part(@value, 6, byte_size(@value) - 6))
  end

  test "without holding, every byte goes at once and is only looked at" do
    scanner = Scanner.new(secrets())
    assert {:ok, "x ghp_01", scanner} = Scanner.feed(scanner, "x ghp_01")
    refute Scanner.held?(scanner)
    assert {:found, _} = Scanner.feed(scanner, binary_part(@value, 6, byte_size(@value) - 6))
  end

  test "a scanner for nothing lets everything through" do
    assert {:ok, @value, _} = Scanner.feed(Scanner.new(nil, hold: true), @value)
  end

  test "partial ends are found in big chunks without looking at all of them" do
    big = :binary.copy("g", 1_000_000)
    # Every byte could start the value, but only the last few can be its start.
    assert Secrets.partial(secrets(), big) == 1
    assert Secrets.partial(secrets(), big <> "hp_01") == 6
  end
end
