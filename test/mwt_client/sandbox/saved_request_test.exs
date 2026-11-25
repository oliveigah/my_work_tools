defmodule MWTClient.Sandbox.SavedRequestTest do
  @moduledoc """
  A request action's template: what it may hold, and the request a call
  builds from it, each value encoded for where it goes.
  """
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.{Grant, Param, SavedRequest}

  doctest SavedRequest

  # A request action with its credential attached.
  @github %Grant{
    id: "github-repo",
    name: "GitHub: a repository",
    kind: :request,
    credential: "github",
    preset: "github"
  }

  defp params!(text) do
    {:ok, params} = Param.parse(text)
    params
  end

  defp template(attrs) do
    Map.merge(
      %{
        method: "GET",
        url: "https://api.github.com/repos/$REPO",
        headers: [{"Authorization", "Bearer {token}"}],
        body: nil
      },
      attrs
    )
  end

  defp errors(attrs, params \\ "REPO: word: the repository"),
    do: SavedRequest.errors(template(attrs), params!(params), @github)

  test "a good template has no errors" do
    assert errors(%{}) == %{}

    assert errors(
             %{
               method: "POST",
               url: "https://api.github.com/repos/${REPO}/issues?per_page=$N",
               body: ~s({"title": "$TITLE", "labels": ["bug"], "milestone": "$N"})
             },
             "REPO: word: r\nTITLE: text: t\nN: number: n"
           ) == %{}
  end

  describe "the URL" do
    test "goes over HTTPS to a host written out, on its usual port" do
      for {url, says} <- [
            {"", "Write the URL"},
            {"http://api.github.com/repos/$REPO", "HTTPS only"},
            {"https://*.githubusercontent.com/$REPO", "Write the host out in full"},
            {"https://api.github.com:8443/$REPO", "usual HTTPS port"},
            {"https://user:pass@api.github.com/$REPO", "Leave the user and password out"},
            {"https://api.github.com/$REPO#top", "Leave out the # part"}
          ] do
        assert %{url: message} = errors(%{url: url}), url
        assert message =~ says, url
      end

      # Any host: reaching it is a network grant's to give, on each call.
      assert errors(%{url: "https://raw.githubusercontent.com/$REPO/main/README.md"}) == %{}
      assert errors(%{url: "https://evil.example/$REPO"}) == %{}
      assert errors(%{url: "https://api.github.com:443/repos/$REPO"}) == %{}
    end

    test "never takes a parameter in the host" do
      for url <- ["https://$REPO/x", "https://api.$REPO.com/x", "https://api.github.com$REPO/x"] do
        assert %{url: message} = errors(%{url: url}), url
        assert message =~ "The host is fixed", url
      end
    end

    test "names only parameters it has" do
      assert %{url: message} = errors(%{url: "https://api.github.com/repos/$REPO/$OTHER"})
      assert message =~ "OTHER isn't a parameter"
    end
  end

  describe "the headers" do
    test "are fixed, carry the token somewhere, and leave what the client writes alone" do
      assert %{headers: message} = errors(%{headers: [{"Accept", "application/json"}]})
      assert message =~ "Say where the token goes"

      assert %{headers: message} =
               errors(%{headers: [{"Authorization", "Bearer {token}"}, {"X-Repo", "$REPO"}]})

      assert message =~ "Headers are fixed"

      assert %{headers: message} =
               errors(%{headers: [{"Authorization", "Bearer {token}"}, {"Host", "evil.example"}]})

      assert message =~ "MWT writes Host itself"

      assert %{headers: _} = errors(%{headers: [{"Bad Name", "{token}"}]})
    end

    test "may carry the ID token and a signed JWT of a Google credential that makes them" do
      google = %Grant{
        id: "pm-policies",
        name: "PM: policies",
        kind: :request,
        credential: "pm",
        preset: "google",
        signs_as: ["agent@p.iam.gserviceaccount.com"]
      }

      check = fn headers, over ->
        SavedRequest.errors(
          %{
            method: "GET",
            url: "https://pm.example.run.app/policies",
            headers: headers,
            body: nil
          },
          [],
          over
        )
      end

      both = [{"Authorization", "Bearer {signed_jwt}"}, {"X-User-Assertion", "{id_token}"}]
      assert check.(both, google) == %{}

      assert check.(
               [{"Authorization", "Bearer {signed_jwt:agent@p.iam.gserviceaccount.com}"}],
               google
             ) ==
               %{}

      assert %{headers: message} =
               check.(
                 [{"Authorization", "Bearer {signed_jwt:other@p.iam.gserviceaccount.com}"}],
                 google
               )

      assert message =~ "isn't an account the action signs as"

      two = %{google | signs_as: ["a@p.iam.gserviceaccount.com", "b@p.iam.gserviceaccount.com"]}
      assert %{headers: message} = check.([{"Authorization", "Bearer {signed_jwt}"}], two)
      assert message =~ "name one"

      # GitHub's makes neither.
      assert %{headers: message} = check.([{"X-User", "{id_token}"}], @github)
      assert message =~ "Google login"
    end
  end

  describe "the body" do
    test "is JSON, with each parameter a whole value, never a key or part of a text" do
      params = "REPO: word: r\nTITLE: text: t"
      post = %{method: "POST"}

      assert %{body: message} = errors(Map.put(post, :body, "{not json"), params)
      assert message =~ "The body is JSON"

      assert %{body: message} = errors(Map.put(post, :body, ~s({"title": "Fix: $TITLE"})), params)
      assert message =~ "a whole value"

      assert %{body: message} =
               errors(
                 Map.put(post, :body, ~S<{"query": "query { repository(name: \"$TITLE\") }"}>),
                 params
               )

      assert message =~ "a whole value"

      assert %{body: message} = errors(Map.put(post, :body, ~s({"$TITLE": "x"})), params)
      assert message =~ "can't be a key"

      assert %{method: message} = errors(%{body: ~s({"a": 1})}, params)
      assert message =~ "A GET sends no body"
    end
  end

  test "every parameter is used, in the URL or the body" do
    assert %{params: message} = errors(%{}, "REPO: word: r\nPR: number: p")
    assert message =~ "doesn't use PR"
  end

  test "it sends with a credential" do
    assert %{credential: _} =
             SavedRequest.errors(template(%{}), params!("REPO: word: r"), %{
               @github
               | credential: nil
             })

    assert %{credential: _} = SavedRequest.errors(template(%{}), params!("REPO: word: r"), nil)
  end

  describe "a call's request" do
    defp grant(attrs) do
      struct(
        %Grant{
          id: "req",
          name: "req",
          kind: :request,
          credential: "github",
          method: "GET",
          headers: [{"Authorization", "Bearer {token}"}]
        },
        attrs
      )
    end

    test "puts a word in the path keeping its slashes, and encodes the rest" do
      g =
        grant(%{
          url: "https://api.github.com/repos/$REPO/issues?q=$Q&state=$STATE",
          params: params!("REPO: word: r\nQ: text: q\nSTATE: open|closed: s")
        })

      call =
        SavedRequest.build(g, [{"REPO", "oliveigah/klife"}, {"Q", "a b&c=d/e"}, {"STATE", "open"}])

      assert call.url ==
               "https://api.github.com/repos/oliveigah/klife/issues?q=a%20b%26c%3Dd%2Fe&state=open"

      assert call.host == "api.github.com"
      assert call.headers == [{"Authorization", "Bearer {token}"}]
    end

    test "encodes text whole in the path, so it stays one segment" do
      g = grant(%{url: "https://api.github.com/search/$Q", params: params!("Q: text: q")})

      assert SavedRequest.build(g, [{"Q", "../../admin x"}]).url ==
               "https://api.github.com/search/..%2F..%2Fadmin%20x"
    end

    test "puts values in the body as JSON values: text as a string, a number as a number" do
      g =
        grant(%{
          method: "POST",
          url: "https://api.github.com/repos/$REPO/issues",
          body: ~s({"title": "$TITLE", "milestone": "${N}", "labels": ["$TITLE"]}),
          params: params!("REPO: word: r\nTITLE: text: t\nN: number: n")
        })

      title = ~s(Hi", "admin": true, "x": ")
      call = SavedRequest.build(g, [{"REPO", "o/r"}, {"TITLE", title}, {"N", "7"}])

      assert Jason.decode!(call.body) == %{
               "title" => title,
               "milestone" => 7,
               "labels" => [title]
             }
    end

    test "as text shows each value by what it is" do
      shown =
        SavedRequest.shown_value(
          "Bearer {signed_jwt} {id_token} {signed_jwt:a@p.iam.gserviceaccount.com}",
          "PM"
        )

      assert shown ==
               "Bearer [a JWT signed as PM's account] [PM's ID token] [a JWT signed as a@p.iam.gserviceaccount.com]"
    end

    test "as text shows the token as the grant's name, never a value" do
      g = grant(%{url: "https://api.github.com/repos/$REPO", params: params!("REPO: word: r")})
      text = g |> SavedRequest.build([{"REPO", "o/r"}]) |> SavedRequest.text("GitHub")

      assert text ==
               "GET https://api.github.com/repos/o/r\nAuthorization: Bearer [GitHub's token]"
    end
  end

  describe "a call's answer" do
    @call %{
      method: "GET",
      url: "https://api.github.com/repos/o/r/contents/big",
      host: "api.github.com",
      headers: [{"authorization", "Bearer {token}"}],
      body: nil
    }

    test "is kept to its first 256 KiB, the value written out even across the cut" do
      keep = 256 * 1024
      # The value starts just before the cut and ends after it.
      body = :binary.copy("a", keep - 3) <> "real-value" <> :binary.copy("b", 1024 * 1024)
      Req.Test.stub(SavedRequest, &Plug.Conn.send_resp(&1, 200, body))

      run = SavedRequest.send(@call, "real-value", "GitHub", 30)

      assert run.exit == 0 and run.status == 200
      assert byte_size(run.output) == keep
      refute run.output =~ "real"
      assert String.ends_with?(run.output, "aaa[Gi")

      assert run.bytes ==
               byte_size(body) - byte_size("real-value") + byte_size("[GitHub's token]")

      assert run.cut == run.bytes - keep
    end

    test "is read no further than kept: a body told in chunks counts what came" do
      Req.Test.stub(SavedRequest, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..64, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, :binary.copy("x", 16 * 1024))
          conn
        end)
      end)

      run = SavedRequest.send(@call, "real-value", "GitHub", 30)
      assert byte_size(run.output) == 256 * 1024
      # It stopped at the chunk past what it keeps: 17 of 64 came.
      assert run.bytes == 17 * 16 * 1024
      assert run.cut == run.bytes - 256 * 1024
    end

    test "puts each value in its header and writes each out of the answer" do
      call = %{
        @call
        | headers: [{"authorization", "Bearer {signed_jwt}"}, {"x-user-assertion", "{id_token}"}]
      }

      Req.Test.stub(SavedRequest, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer jwt-real-0123"]
        assert Plug.Conn.get_req_header(conn, "x-user-assertion") == ["id-real-0123"]
        Plug.Conn.send_resp(conn, 200, "echo jwt-real-0123 id-real-0123")
      end)

      run =
        SavedRequest.send(
          call,
          %{token: "ya29.real", id_token: "id-real-0123", jwts: %{one: "jwt-real-0123"}},
          "PM",
          30
        )

      assert run.output == "echo [a JWT signed as PM's account] [PM's ID token]"
    end

    test "small answers come back whole" do
      Req.Test.stub(SavedRequest, &Plug.Conn.send_resp(&1, 404, ~s({"token":"real-value"})))
      run = SavedRequest.send(@call, "real-value", "GitHub", 30)
      assert run.exit == 22 and run.status == 404
      assert run.output == ~s({"token":"[GitHub's token]"})
      assert run.cut == 0 and run.bytes == byte_size(run.output)
    end
  end

  describe "a call built for MWT's proxy" do
    test "holds a placeholder of its own where each value goes, never the value" do
      call = %{
        method: "POST",
        url: "https://pm.example.run.app/policies",
        host: "pm.example.run.app",
        headers: [
          {"Authorization", "Bearer {token}"},
          {"X-User-Assertion", "{id_token}"},
          {"X-Proof", "{signed_jwt}"}
        ],
        body: ~s({"a": 1})
      }

      {built, swaps} =
        SavedRequest.build(
          call,
          %{token: "tok-real", id_token: "id-real", jwts: %{one: "jwt-real"}},
          "PM"
        )

      assert [token, id_token, jwt] = swaps
      assert %{label: "PM", value: "tok-real", within: ["authorization"]} = token
      assert %{label: "PM's ID token", value: "id-real", within: ["x-user-assertion"]} = id_token
      assert %{value: "jwt-real", within: ["x-proof"]} = jwt

      assert {"Authorization", "Bearer " <> placeholder} =
               List.keyfind(built.headers, "Authorization", 0)

      assert placeholder == token.placeholder and String.starts_with?(placeholder, "mwt-fixed-")
      refute inspect(built) =~ "real"

      # What the service needs to read it: its type, and a client's name.
      assert {"content-type", "application/json"} in built.headers
      assert {"user-agent", "MWT"} in built.headers
    end
  end
end
