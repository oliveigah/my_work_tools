defmodule MWTClient.QaProbes.Network.FixedCallValuesProbeTest do
  @moduledoc """
  QA 2026-11-25, G6: a fixed call's values. MWT's floor and the schema
  are checked before anything is built (`Param.check/2`); what passes is
  put into the URL's path or query, or a JSON body, encoded
  (`SavedRequest.build/2`), so it can't change the host, add path
  segments, query keys, headers or body keys. A refusal names the
  parameter, never the value. Also what a template (yours, or an agent's
  proposal) may name as its host (`SavedRequest.errors/3`).

  Pure: no server, no network.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Param, SavedRequest}

  @host "api.example.com"

  defp action(url, params, attrs \\ []) do
    {:ok, params} = Param.parse(params)

    struct!(
      %Grant{
        id: "act",
        name: "act",
        kind: :request,
        credential: "cred",
        method: "GET",
        url: url,
        headers: [{"Authorization", "Bearer {token}"}],
        params: params
      },
      attrs
    )
  end

  # The values that try to leave their place.
  @hostile [
    "/",
    "a/b",
    "?x=1",
    "&admin=1",
    "#frag",
    "%2F",
    "%2e%2e",
    "@evil.example",
    "evil.example:443@",
    "a\r\nX-Injected: 1",
    "a\nX-Injected: 1",
    "a b",
    "\\\\evil.example\\x",
    "ａｐｉ／ｘ",
    "a" <> <<0x2215::utf8>> <> "b",
    ~s(", "admin": true, "x": "),
    "$TITLE",
    "${OTHER}",
    "{token}"
  ]

  # What FixedCall writes on the wire for `built`: the request line.
  defp wire_target(built) do
    uri = URI.parse(built.url)
    (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
  end

  defp segments(path), do: path |> String.split("?") |> hd() |> String.split("/")

  test "a text value in the path stays one segment, under the template's host, in visible ASCII" do
    grant = action("https://#{@host}/repos/o/r/issues/$TITLE/comments", "TITLE: text: a title")
    template = segments("/repos/o/r/issues/x/comments")

    for value <- @hostile do
      case Param.check(grant.params, %{"TITLE" => value}) do
        {:ok, values} ->
          built = SavedRequest.build(grant, values)
          uri = URI.parse(built.url)
          assert uri.host == @host and uri.userinfo == nil and uri.port == 443, inspect(value)
          assert uri.fragment == nil and uri.query == nil, inspect(value)
          assert length(segments(uri.path)) == length(template), inspect({value, uri.path})
          assert wire_target(built) =~ ~r/\A[\x21-\x7e]+\z/, inspect(value)
          assert built.headers == grant.headers

        {:error, _problem} ->
          :refused_before_built
      end
    end
  end

  test "a word value in the path only goes deeper: its / kept, no other part of the URL reached" do
    grant = action("https://#{@host}/repos/$REPO/pulls", "REPO: word: owner/name")

    for value <- @hostile ++ ["o/r", "o/r/../../x", "o/./r", "o//r", "a@b:c+d"] do
      case Param.check(grant.params, %{"REPO" => value}) do
        {:ok, values} ->
          built = SavedRequest.build(grant, values)
          uri = URI.parse(built.url)
          assert uri.host == @host and uri.userinfo == nil and uri.query == nil, inspect(value)
          parts = uri.path |> String.split("/") |> Enum.drop(2) |> Enum.drop(-1)
          refute Enum.any?(parts, &(&1 in ["", ".", ".."])), inspect({value, uri.path})

        {:error, _problem} ->
          :refused_before_built
      end
    end
  end

  test "a value in the query is one value of its key: no key added" do
    grant = action("https://#{@host}/search?q=$Q&per_page=5", "Q: text: what to look for")

    for value <- @hostile do
      case Param.check(grant.params, %{"Q" => value}) do
        {:ok, values} ->
          built = SavedRequest.build(grant, values)
          uri = URI.parse(built.url)
          assert uri.host == @host and uri.fragment == nil, inspect(value)
          query = URI.decode_query(uri.query)
          assert Map.keys(query) |> Enum.sort() == ["per_page", "q"], inspect({value, uri.query})
          assert query["q"] == value and query["per_page"] == "5"

        {:error, _problem} ->
          :refused_before_built
      end
    end
  end

  test "a value in the body is the whole string value: no key added, the JSON's shape kept" do
    grant =
      action(
        "https://#{@host}/repos/o/r/issues",
        "TITLE: text: a title\nN: number: how many",
        method: "POST",
        body: ~s({"title": "$TITLE", "labels": ["$TITLE"], "count": "$N", "fixed": "keep"})
      )

    for value <- @hostile do
      case Param.check(grant.params, %{"TITLE" => value, "N" => "3"}) do
        {:ok, values} ->
          built = SavedRequest.build(grant, values)
          body = Jason.decode!(built.body)

          assert body == %{"title" => value, "labels" => [value], "count" => 3, "fixed" => "keep"},
                 inspect(value)

        {:error, _problem} ->
          :refused_before_built
      end
    end

    # A number parameter takes a number, never JSON.
    for bad <- [~s(1, "admin": true), "1e3", "-1", "0x10", "1.5"] do
      assert {:error, _} = Param.check(grant.params, %{"TITLE" => "t", "N" => bad}), bad
    end
  end

  test "MWT's floor: blank, an option, up a folder, what doesn't show; the refusal names the parameter, not the value" do
    {:ok, params} = Param.parse("T: text: anything")

    for value <- [
          "",
          "   ",
          "-rf",
          "  --help",
          "..",
          "a/../b",
          "./x",
          "a\rb",
          "a" <> <<0x202E::utf8>> <> "b",
          "a" <> <<0x200B::utf8>> <> "b",
          "a" <> <<0>> <> "b",
          <<0xFF, 0xFE>>
        ] do
      assert {:error, problem} = Param.check(params, %{"T" => value}), inspect(value)
      words = Param.explain(problem)
      assert words =~ "T"

      unless String.trim(value) in ["", "..", "-rf"],
        do: refute(String.contains?(words, value), inspect({value, words}))
    end
  end

  test "PROBE: the floor's \"never up a folder\" holds for a backslash, which some services read as /" do
    # A text value goes into a path segment encoded, `\` as %5C. IIS and
    # servers behind it, and some proxies, read %5C (or `\`) as `/`, so
    # `..\..\admin` goes up two folders there. The floor only splits on
    # `/` (Param.floor/2).
    {:ok, params} = Param.parse("T: text: anything")

    passed =
      for value <- ["..\\..\\admin", "..\\x", "x\\..\\..\\y"],
          match?({:ok, _}, Param.check(params, %{"T" => value})),
          do: value

    assert passed == [],
           "these pass MWT's floor and reach a URL path as ..%5C..: #{inspect(passed)}"
  end

  test "a template's host is fixed: no parameter, user, port or fragment there" do
    for url <- [
          "https://$HOST/x",
          "https://api.$HOST.com/x",
          "https://#{@host}$P/x",
          "https://#{@host}:$PORT/x",
          "https://u:$P@#{@host}/x",
          "https://evil.example\\@#{@host}/x",
          "https://#{@host}#$P",
          "https://#{@host}:8443/x",
          "http://#{@host}/x"
        ] do
      errors =
        SavedRequest.errors(
          %{method: "GET", url: url, headers: [{"Authorization", "Bearer {token}"}]},
          elem(Param.parse("P: text: p\nHOST: text: h\nPORT: number: p"), 1),
          %Grant{id: "c", name: "c", kind: :request, credential: "c"}
        )

      assert Map.has_key?(errors, :url), inspect(url)
    end
  end

  test "PROBE: a template's host written in two alphabets is refused or flagged, as a command's text is" do
    # An agent may propose a fixed call (`mwt propose`). Its URL's host
    # is where the credential's value goes, whatever hosts the open grant
    # over the credential lists. A host mixing alphabets (a Cyrillic
    # `Ь` for `b`) reads as GitHub on the proposal page. A command's
    # card says "Mixes alphabets" (HostCommand.hints); a request
    # action's URL isn't checked (SavedRequest.url_error/2).
    lookalike = "https://api.githu" <> <<0x042C::utf8>> <> ".com/user"
    {:ok, params} = Param.parse("")

    errors =
      SavedRequest.errors(
        %{method: "GET", url: lookalike, headers: [{"Authorization", "Bearer {token}"}]},
        params,
        %Grant{id: "c", name: "c", kind: :request, credential: "c"}
      )

    assert Map.has_key?(errors, :url),
           "#{lookalike} is accepted as a fixed call's URL, with no word about its alphabets: #{inspect(errors)}"
  end
end
