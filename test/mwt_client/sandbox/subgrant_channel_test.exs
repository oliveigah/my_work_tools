defmodule MWTClient.Sandbox.SubgrantChannelTest do
  @moduledoc """
  Subgrants end to end, through the `mwt` command in the VM: called by id,
  a request subgrant sent by MWT, and grants and subgrants edited after.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Grant

  describe "a subgrant, called by id" do
    defp subgrant(context, attrs \\ %{}) do
      {:ok, grant} =
        Sandbox.create_grant(
          context.username,
          Map.merge(
            %{
              "kind" => "command",
              "name" => "say",
              "purpose" => "Says a word and a number of times",
              "script" => ~s(echo "said: $WORD x$TIMES"),
              "params" => "WORD: word: what to say\nTIMES: number: how many times",
              "dir" => context.project
            },
            attrs
          )
        )

      grant
    end

    test "is a subgrant of Ask to run commands, with a switch of its own", context do
      grant = subgrant(context)
      built_in = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)

      assert grant.parent == built_in.id and Grant.subgrant?(grant)
      assert [%{name: "WORD", shape: :word}, %{name: "TIMES", shape: :number}] = grant.params
      assert grant.state == :off

      # Its grant off, it still runs once it is on itself.
      {:ok, _} = Sandbox.turn_off(context.username, built_in.id)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "say", "WORD=feature/login", "TIMES=3", "--reason", "try it"],
            stderr: false
          )
        end)

      approval = command(context.username)
      # The script is yours, as saved; all the agent chose is the values.
      assert approval.script == ~s(echo "said: $WORD x$TIMES")
      assert approval.script_from == :grant
      assert approval.values == [{"WORD", "feature/login"}, {"TIMES", "3"}]
      assert approval.title =~ "WORD=feature/login TIMES=3"

      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      # It read them as variables.
      assert {"said: feature/login x3\n", 0} = Task.await(asking)
    end

    test "a call is checked before it waits: every value given, known, and of its shape",
         context do
      grant = subgrant(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      for {args, says} <- [
            {["WORD=hello"], "TIMES is missing"},
            {["WORD=hello", "TIMES=3", "EXTRA=1"], "It has no parameter EXTRA"},
            {["WORD=hello", "TIMES=three"], "TIMES isn't of its shape"},
            {["WORD=hello world", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=--help", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=../../etc/passwd", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=/etc/passwd", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=$(id)", "TIMES=3"], "WORD isn't of its shape"},
            {["WORD=a;id", "TIMES=3"], "WORD isn't of its shape"}
          ] do
        assert {output, 122} = mwt(context, ["call", "say"] ++ args ++ ["--reason", "r"])
        assert output =~ says, inspect(args)
        assert output =~ "mwt call say WORD=… TIMES=…"
      end

      # Nothing ran, and nothing waits.
      snapshot = Sandbox.snapshot(context.username)
      assert snapshot.waiting == [] and snapshot.history == []
    end

    test "a value never becomes part of the script, whatever it holds", context do
      marker = Path.join(context.project, "pwned")

      grant =
        subgrant(context, %{
          "name" => "note",
          "script" => ~s(echo "note: $NOTE"),
          "params" => "NOTE: text: the note"
        })

      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      value = ~s[x"; touch #{marker}; echo "$(touch #{marker}) `touch #{marker}`]

      assert {output, 0} =
               mwt(context, ["call", "note", "NOTE=" <> value, "--reason", "r"], stderr: false)

      # Printed as it was sent, and run as nothing.
      assert output == "note: " <> value <> "\n"
      refute File.exists?(marker)
    end

    test "always on runs without a card, with its values in the log", context do
      grant = subgrant(context)
      {:ok, grant} = Sandbox.set_start(context.username, grant.id, :auto)
      assert grant.state == :on and grant.start == :auto and Grant.auto_approved?(grant)

      assert {"said: hi x2\n", 0} =
               mwt(context, ["call", "say", "WORD=hi", "TIMES=2", "--reason", "r"], stderr: false)

      assert Sandbox.snapshot(context.username).waiting == []

      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "commands"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "WORD=hi TIMES=2" and &1 =~ "auto-approved"))
    end

    test "off, it is refused, and says how to ask for it", context do
      subgrant(context)
      assert {output, 122} = mwt(context, ["call", "say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "say is off"
      assert output =~ "mwt request say"
    end

    test "takes an id, never a command or a name", context do
      grant = subgrant(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      # A call sends no text.
      assert {output, 122} =
               mwt(context, ["call", "say", "--reason", "r", "--", "echo", "mine"])

      assert output =~ "a call sends no command"

      # Ask to run commands is no subgrant, and takes no values.
      assert {output, 122} = mwt(context, ["call", "commands", "--reason", "r"])
      assert output =~ "commands is no subgrant"

      # Its name, in another case, names nothing.
      assert {output, 122} = mwt(context, ["call", "Say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "No subgrant has the id Say"
    end

    test "an ad-hoc command with a subgrant's exact text still waits, like any other", context do
      grant = subgrant(context, %{"name" => "plain", "script" => "echo plain", "params" => ""})
      {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)

      asking =
        Task.async(fn ->
          mwt(context, ["run", "commands", "--reason", "r", "--", "echo plain"],
            cd: context.project
          )
        end)

      # Never recognised as the subgrant: a card, with a hint naming it.
      approval = command(context.username)
      assert approval.script_from == :agent and approval.status == :waiting
      :ok = Sandbox.decide(context.username, approval.id, :decline)
      assert {_output, 121} = Task.await(asking)
    end

    test "a parameter must be read by the script, and can't take a name that means something",
         context do
      for {params, script, says} <- [
            {"WORD: word: a word", "echo fixed", "doesn't read WORD"},
            {"PATH: word: a path", ~s(echo "$PATH"), "already means something"},
            {"GIT_SSH_COMMAND: text: x", ~s(git fetch "$GIT_SSH_COMMAND"), "already means"},
            {"word: word: lowercase", ~s(echo "$word"), "in capitals"},
            {"WORD: sentence: x", ~s(echo "$WORD"), "is no shape"},
            {"WORD: word", ~s(echo "$WORD"), "say what it is"},
            {"WORD: word: a\nWORD: number: b", ~s(echo "$WORD"), "there twice"}
          ] do
        assert {:error, %{params: message}} =
                 Sandbox.create_grant(context.username, %{
                   "kind" => "command",
                   "name" => "bad",
                   "purpose" => "Bad",
                   "script" => script,
                   "params" => params,
                   "dir" => context.project
                 })

        assert message =~ says, params
      end
    end
  end

  describe "a request subgrant" do
    alias MWTClient.Sandbox.{SavedRequest, Server}
    alias MWTClient.Vault.Store

    @value "ghp_real_value_123"

    defp github(context) do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "preset" => "github",
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "api.github.com, github.com",
          "env" => "GH_TOKEN",
          "prefix" => "ghp_",
          "source" => "stored",
          "value" => @value
        })

      grant
    end

    defp pr_view(context, attrs \\ %{}) do
      {:ok, grant} =
        Sandbox.create_grant(
          context.username,
          Map.merge(
            %{
              "kind" => "request",
              "preset" => "request_subgrant",
              "parent" => "github",
              "name" => "pr view",
              "purpose" => "Shows a pull request",
              "method" => "GET",
              "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
              "headers" => SavedRequest.default_headers(:github),
              "params" => "REPO: word: the repository\nPR: number: the pull request"
            },
            attrs
          )
        )

      grant
    end

    # Answers as the service would, and tells the test what it got.
    defp service(context, status \\ 200) do
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(test, {
          :sent,
          conn.method,
          conn.request_path,
          conn.query_string,
          Plug.Conn.get_req_header(conn, "authorization"),
          body
        })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, ~s({"number": 7, "echo": "#{@value}"}))
      end)

      # The request goes out from a task of the identity's server.
      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))
    end

    test "is sent by MWT with the real value, once you approve its exact request; the VM gets the answer",
         context do
      grant = github(context)
      sub = pr_view(context)
      assert sub.parent == grant.id and sub.kind == :request and sub.state == :off
      # The token grant stays off: the subgrant has a switch of its own.
      {:ok, _} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
      service(context)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "pr-view", "REPO=oliveigah/klife", "PR=7", "--reason", "review"])
        end)

      approval = command(context.username)
      # Unless the agent gives one, a request's own time limit.
      assert approval.timeout == elem(SavedRequest.timeouts(), 0)
      # The card shows the request as it will go, the token by name.
      assert approval.script =~ "GET https://api.github.com/repos/oliveigah/klife/pulls/7"
      assert approval.script =~ "Authorization: Bearer [GitHub's token]"
      refute approval.script =~ @value
      assert approval.values == [{"REPO", "oliveigah/klife"}, {"PR", "7"}]
      assert {"Request", "Yours, saved as pr view"} in approval.facts

      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking)

      assert_received {:sent, "GET", "/repos/oliveigah/klife/pulls/7", "", ["Bearer " <> @value],
                       ""}

      # The answer comes back, the value written out of it.
      assert output =~ "HTTP 200 from api.github.com"
      assert output =~ ~s({"number": 7, "echo": "[GitHub's token]"})
      refute output =~ @value

      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "commands"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "HTTP 200"))
      refute Enum.any?(summaries, &(&1 =~ @value))
    end

    test "another grant's value is written out of an answer in every form; a key in it waits",
         context do
      github(context)
      other = "other/real+value0123456"

      {:ok, _} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "Hex",
          "purpose" => "Packages",
          "hosts" => "hex.pm",
          "value" => other
        })

      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      encoded = URI.encode_www_form(other)

      Req.Test.stub(SavedRequest, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"a": "#{encoded}", "b": "#{other}"}))
      end)

      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

      assert {output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"],
                 stderr: false
               )

      assert output =~ ~s({"a": "[Hex's token]", "b": "[Hex's token]"})
      refute output =~ encoded

      # Something shaped like a key holds the answer for you.
      Req.Test.stub(SavedRequest, fn conn ->
        Plug.Conn.send_resp(conn, 200, "-----BEGIN RSA PRIVATE KEY-----\nMIIE")
      end)

      asking =
        Task.async(fn ->
          mwt(context, ["call", "pr-view", "REPO=o/r", "PR=2", "--reason", "r"], stderr: false)
        end)

      card = output_card(context.username)
      assert [%{what: {:shape, "a private key"}, line: 1}] = card.run.findings
      :ok = Sandbox.decide(context.username, card.id, :send_output)
      assert {output, 0} = Task.await(asking, 10_000)
      assert output =~ "PRIVATE KEY"
    end

    test "goes through with a grant only its subgrants use, which the VM can't ask for",
         context do
      grant = github(context)

      {:ok, _} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "api.github.com, github.com",
          "reach" => "subgrants"
        })

      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=3", "--reason", "r"],
                 stderr: false
               )

      assert output =~ ~s("number": 7)
      assert_received {:sent, "GET", "/repos/o/r/pulls/3", "", ["Bearer " <> @value], ""}

      {output, 1} = mwt(context, ["request", grant.id, "--reason", "push"])
      assert output =~ "is only for its subgrants"

      {output, 0} = mwt(context, ["grants"])
      assert output =~ "for its subgrants only"
      assert output =~ "use: only through its subgrants"
    end

    test "a call to a credential endpoint is refused before it waits or runs", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "add key",
          "method" => "POST",
          "url" => "https://api.github.com/user/keys",
          "params" => ""
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        send(test, :sent) && Plug.Conn.send_resp(conn, 201, "")
      end)

      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

      assert {output, status} = mwt(context, ["call", sub.id, "--reason", "r"])
      assert status != 0
      assert output =~ "api.github.com is a credential endpoint"
      refute_received :sent
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "an answer other than 2xx exits 22, with its body", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context, 404)

      assert {output, 22} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"])

      assert output =~ "HTTP 404"
      # Always on: no card.
      assert Sandbox.snapshot(context.username).waiting == []
    end

    test "values go in encoded, and of their shape, or not at all", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "search",
          "url" => "https://api.github.com/search/issues?q=$Q",
          "params" => "Q: text: what to look for"
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {_output, 0} =
               mwt(context, ["call", "search", "Q=is:open repo:a/b&admin=1", "--reason", "r"])

      assert_received {:sent, "GET", "/search/issues", "q=is%3Aopen%20repo%3Aa%2Fb%26admin%3D1",
                       _, _}

      assert {output, 122} = mwt(context, ["call", "search", "Q=-x", "--reason", "r"])
      assert output =~ "Q isn't of its shape"
      refute_received {:sent, _, _, _, _, _}
    end

    test "puts a value in a JSON body as a value, never as JSON", context do
      github(context)

      sub =
        pr_view(context, %{
          "name" => "comment",
          "method" => "POST",
          "url" => "https://api.github.com/repos/$REPO/issues/$PR/comments",
          "body" => ~s({"body": "$TEXT"}),
          "params" => "REPO: word: r\nPR: number: p\nTEXT: text: the comment"
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context, 201)
      text = ~s(hi", "admin": true, "x": ")

      assert {_output, 0} =
               mwt(context, [
                 "call",
                 "comment",
                 "REPO=o/r",
                 "PR=3",
                 "TEXT=" <> text,
                 "--reason",
                 "r"
               ])

      assert_received {:sent, "POST", "/repos/o/r/issues/3/comments", "", _, body}
      assert Jason.decode!(body) == %{"body" => text}
    end

    test "is refused when its token grant no longer lists the host, and goes with its grant",
         context do
      grant = github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      # The grant edited to send its token elsewhere only.
      {:ok, _} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "github.com",
          "env" => "GH_TOKEN"
        })

      assert {output, 122} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"])

      assert output =~ "no longer lists the host"

      :ok = Sandbox.delete_grant(context.username, grant.id)
      refute Enum.any?(Sandbox.snapshot(context.username).grants, &(&1.id == sub.id))
    end

    test "a template that could send the token elsewhere, or let a value move it, is refused",
         context do
      github(context)

      for {attrs, field, says} <- [
            {%{"url" => "https://evil.example/x"}, :url, "sends its token only to"},
            {%{"url" => "https://$HOST/x", "params" => "HOST: word: h"}, :url, "host is fixed"},
            {%{"url" => "http://api.github.com/x", "params" => ""}, :url, "HTTPS only"},
            {%{"headers" => "Accept: application/json"}, :headers, "Say where the token goes"},
            {%{"headers" => "Authorization: Bearer {token}\nX-Pr: $PR"}, :headers, "fixed"},
            {%{"parent" => "commands"}, :parent, "under a token grant"}
          ] do
        assert {:error, errors} =
                 Sandbox.create_grant(
                   context.username,
                   Map.merge(
                     %{
                       "kind" => "request",
                       "parent" => "github",
                       "name" => "x",
                       "purpose" => "x",
                       "method" => "GET",
                       "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
                       "headers" => "Authorization: Bearer {token}",
                       "params" => "REPO: word: r\nPR: number: p"
                     },
                     attrs
                   )
                 )

        assert errors[field] =~ says, inspect(attrs)
      end
    end

    test "an agent proposes one under its token grant; accepting it answers with its id",
         context do
      github(context)

      asking =
        Task.async(fn ->
          mwt(context, [
            "propose",
            "github",
            "--name",
            "pr view",
            "--for",
            "Shows a pull request",
            "--param",
            "REPO:word:the repository",
            "--param",
            "PR:number:the pull request",
            "--method",
            "GET",
            "--url",
            "https://api.github.com/repos/$REPO/pulls/$PR",
            "--reason",
            "review"
          ])
        end)

      ask = waiting(context.username, &(&1.kind == :activation))
      assert %{kind: :request, parent_name: "GitHub"} = ask.proposal

      sub = Enum.find(Sandbox.snapshot(context.username).grants, &(&1.id == ask.grant_id))
      assert %Grant{kind: :request, method: "GET", parent: "github"} = sub
      assert Grant.to_review?(sub)

      # Without --header, the headers the service expects, the token in place.
      assert {"Authorization", "Bearer {token}"} in sub.headers

      {:ok, _} = Sandbox.review(context.username, sub.id, {60, :ask})
      assert {output, 0} = Task.await(asking)
      assert output =~ "accepted it as pr-view"
      assert output =~ "mwt call pr-view REPO=… PR=…"

      # A proposal that would send the token elsewhere never waits.
      assert {output, 1} =
               mwt(context, [
                 "propose",
                 "github",
                 "--name",
                 "x",
                 "--for",
                 "y",
                 "--url",
                 "https://evil.example/collect",
                 "--reason",
                 "r"
               ])

      assert output =~ "sends its token only to"
    end
  end

  describe "editing" do
    test "keeps a subgrant's id, state and start, and checks the change as when it was added",
         context do
      {:ok, sub} =
        Sandbox.create_grant(context.username, %{
          "kind" => "command",
          "name" => "say",
          "purpose" => "Says a word",
          "script" => ~s(echo "$WORD"),
          "params" => "WORD: word: what to say",
          "dir" => context.project
        })

      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      {:ok, edited} =
        Sandbox.update_grant(context.username, sub.id, %{
          "name" => "shout",
          "purpose" => "Says a word, loudly",
          "script" => ~s(echo "$WORD!"),
          "params" => "WORD: word: what to say",
          "dir" => context.project
        })

      assert %{id: "say", name: "shout", start: :auto, state: :on, parent: "commands"} = edited
      assert edited.script == ~s(echo "$WORD!")
      assert Grant.auto_approved?(edited)

      assert {"said!\n", 0} =
               mwt(context, ["call", "say", "WORD=said", "--reason", "r"], stderr: false)

      assert {:error, %{params: message}} =
               Sandbox.update_grant(context.username, sub.id, %{
                 "name" => "shout",
                 "purpose" => "x",
                 "script" => "echo fixed",
                 "params" => "WORD: word: what to say",
                 "dir" => context.project
               })

      assert message =~ "doesn't read WORD"
      built_in = Enum.find(Sandbox.snapshot(context.username).grants, &Grant.ask_to_run?/1)
      assert {:error, :built_in} = Sandbox.update_grant(context.username, built_in.id, %{})
      assert {:error, :not_found} = Sandbox.update_grant(context.username, "nope", %{})
    end

    test "a token grant keeps its placeholder and value", context do
      {:ok, grant} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "name" => "API",
          "purpose" => "An API",
          "hosts" => "api.example.com",
          "env" => "API_TOKEN",
          "source" => "stored",
          "value" => "secret"
        })

      {:ok, edited} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "Example API",
          "purpose" => "The example API",
          "hosts" => "api.example.com, uploads.example.com",
          "env" => "API_TOKEN, EXAMPLE_TOKEN"
        })

      assert edited.id == grant.id and edited.placeholder == grant.placeholder
      assert edited.hosts == ["api.example.com", "uploads.example.com"]
      assert edited.env == ["API_TOKEN", "EXAMPLE_TOKEN"]
      assert Sandbox.snapshot(context.username).values[grant.id] == true
    end
  end
end
