defmodule MWTClient.Sandbox.ActionChannelTest do
  @moduledoc """
  Actions end to end, through the `mwt` command in the VM: called by id,
  a request action sent by MWT, and grants and actions edited after.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.Grant

  describe "an action, called by id" do
    defp action(context, attrs \\ %{}) do
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

    test "is an action over your machine, with a switch of its own", context do
      grant = action(context)

      assert Grant.resource(grant) == :machine and Grant.action?(grant)

      assert [
               %{name: "WORD", schema: %{"format" => "word"}},
               %{name: "TIMES", schema: %{"type" => "integer"}}
             ] = grant.params

      assert grant.state == :off

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

    test "a call is checked before it waits: every value given, known, over MWT's floor and of its schema",
         context do
      grant = action(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      for {args, says} <- [
            {["WORD=hello"], "TIMES is missing"},
            {["WORD=hello", "TIMES=3", "EXTRA=1"], "It has no parameter EXTRA"},
            {["WORD=hello", "TIMES=three"], "TIMES isn't of its type"},
            {["WORD=hello world", "TIMES=3"], "WORD doesn't keep to its schema"},
            {["WORD=--help", "TIMES=3"], "WORD can't be that: it starts with -"},
            {["WORD=../../etc/passwd", "TIMES=3"], "WORD can't be that: it goes up a folder"},
            {["WORD=/etc/passwd", "TIMES=3"], "WORD doesn't keep to its schema"},
            {["WORD=$(id)", "TIMES=3"], "WORD doesn't keep to its schema"},
            {["WORD=a;id", "TIMES=3"], "WORD doesn't keep to its schema"}
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
        action(context, %{
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
      grant = action(context)
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
      action(context)
      assert {output, 122} = mwt(context, ["call", "say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "say is off"
      assert output =~ "mwt request say"
    end

    test "takes an id, never a command or a name", context do
      grant = action(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)

      # A call sends no text.
      assert {output, 122} =
               mwt(context, ["call", "say", "--reason", "r", "--", "echo", "mine"])

      assert output =~ "a call sends no command"

      # The id commands of the agent's own went under is no fixed call: a
      # command the agent writes is run, not called.
      assert {output, 122} = mwt(context, ["call", "commands", "--reason", "r"])
      assert output =~ ~s[mwt run --reason "..." -- COMMAND]

      # Its name, in another case, names nothing.
      assert {output, 122} = mwt(context, ["call", "Say", "WORD=a", "TIMES=1", "--reason", "r"])
      assert output =~ "No fixed call has the id Say"
    end

    test "an ad-hoc command with an action's exact text still waits, like any other", context do
      grant = action(context, %{"name" => "plain", "script" => "echo plain", "params" => ""})
      {:ok, _} = Sandbox.set_start(context.username, grant.id, :auto)

      asking =
        Task.async(fn ->
          mwt(context, ["run", "--reason", "r", "--", "echo plain"], cd: context.project)
        end)

      # Never recognised as the action: a card, with a hint naming it.
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

  describe "a request action" do
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
              "preset" => "request_action",
              "credential" => "github",
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
    # The service: it answers with what it got, and with the token itself
    # when asked to (`echo: true`), as a service that echoes what it was
    # sent would.
    defp service(context, status \\ 200, echo \\ false) do
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
        |> Plug.Conn.send_resp(
          status,
          if(echo, do: ~s({"number": 7, "echo": "#{@value}"}), else: ~s({"number": 7}))
        )
      end)

      # The request goes out from a task of the identity's server.
      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))
    end

    test "is sent by MWT with the real value, once you approve its exact request; the VM gets the answer",
         context do
      grant = github(context)
      sub = pr_view(context)
      assert sub.credential == grant.id and sub.kind == :request and sub.state == :off
      # The token grant stays off: the action has a switch of its own.
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

      # The answer comes back.
      assert output =~ "HTTP 200 from api.github.com"
      assert output =~ ~s({"number": 7})

      # A call's lines are its own, among the credentials' uses.
      summaries =
        Enum.map(Sandbox.events(context.username, %{group: "credentials"}), & &1.summary)

      assert Enum.any?(summaries, &(&1 =~ "HTTP 200"))
      refute Enum.any?(summaries, &(&1 =~ @value))

      # It went through MWT's proxy, as the VM's own requests do: its line
      # in the log is labelled as the fixed call's.
      assert Enum.any?(
               Sandbox.events(context.username, %{limit: 50}),
               &(&1.summary =~ "Fixed call · pr view" and &1.grant_id == sub.id)
             )
    end

    test "keeps no record of its host's address that a connection of the VM's could use",
         context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {_output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=7", "--reason", "r"],
                 stderr: false
               )

      assert_received {:sent, "GET", "/repos/o/r/pulls/7", _, _, _}

      # Resolved by this machine for the call's own connection only: what
      # MWT's DNS answered the VM is all a network grant naming the host
      # opens (`Gate.answered/5`).
      refute Enum.any?(
               MWTClient.Sandbox.Gate.answered_map(context.username),
               fn {_ip, names} -> "api.github.com" in names end
             )

      # A host the firewall trusts still goes: its address is MWT's own
      # answer, not a name the VM claims.
      :ok = Sandbox.firewall_set(context.username, {:list, :trusted, "api.github.com"})

      assert {_output, 0} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=8", "--reason", "r"],
                 stderr: false
               )

      assert_received {:sent, "GET", "/repos/o/r/pulls/8", _, _, _}
    end

    test "an answer that echoes the token is cut, as the VM's own requests' are", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context, 200, true)

      assert {output, code} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=7", "--reason", "r"])

      assert code != 0
      assert output =~ "MWT cut the answer: it held GitHub's real value"
      refute output =~ @value
    end

    test "sends the ID token its credential's mint printed, where its headers say", context do
      mint =
        ~s(echo '{"value": "ya29.real0123456789", "id_token": "idtok-real-0123456789", "expires_in": 1800}')

      # A Google credential: its mint prints an ID token beside the token.
      {:ok, google} =
        Sandbox.create_grant(context.username, %{
          "kind" => "token",
          "preset" => "google",
          "name" => "PM",
          "purpose" => "Policy management, as me",
          "hosts" => "pm.example.run.app",
          "env" => "PM_TOKEN",
          "signs_as" => "agent@p.iam.gserviceaccount.com",
          "source" => "minted",
          "mint" => mint
        })

      {:ok, sub} =
        Sandbox.create_grant(context.username, %{
          "kind" => "request",
          "preset" => "request_action",
          "credential" => google.id,
          "name" => "policies",
          "purpose" => "Lists the policies",
          "method" => "GET",
          "url" => "https://pm.example.run.app/policies",
          "headers" => "Authorization: Bearer {token}\nX-User-Assertion: {id_token}"
        })

      {:ok, _} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
      test = self()

      Req.Test.stub(SavedRequest, fn conn ->
        send(test, {:assertion, Plug.Conn.get_req_header(conn, "x-user-assertion")})
        Plug.Conn.send_resp(conn, 200, "listed")
      end)

      :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

      asking = Task.async(fn -> mwt(context, ["call", sub.id, "--reason", "list them"]) end)
      approval = command(context.username)
      assert approval.script =~ "X-User-Assertion: [PM's ID token]"
      :ok = Sandbox.decide(context.username, approval.id, {:run, :send})
      assert {output, 0} = Task.await(asking, 10_000)
      assert_received {:assertion, ["idtok-real-0123456789"]}
      assert output =~ "listed"
      refute output =~ "idtok-real"
    end

    test "another grant's value in an answer is cut, in every form, as the agent's own are; a key in it waits",
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

      # The call carried GitHub's value, not Hex's: every answer is looked
      # through for every value MWT holds, and one coming back cuts it
      # and isolates the VM.
      assert {output, code} =
               mwt(context, ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"])

      assert code != 0
      assert output =~ "MWT cut the answer: it held Hex's real value"
      refute output =~ encoded
      refute output =~ other
      assert Sandbox.firewall(context.username).firewall.isolated != nil
      Sandbox.firewall_release(context.username, false)

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

    test "goes by itself for its credential, and by its host's network as the agent's own request would",
         context do
      grant = github(context)
      sub = pr_view(context)
      service(context)
      call = ["call", "pr-view", "REPO=o/r", "PR=3", "--reason", "r"]

      # The action off, a token grant over its credential auto-approving
      # gives nothing: open use of a credential is never a fixed call's.
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :all)
      assert {output, code} = mwt(context, call)
      assert code in [121, 122]
      assert output =~ "mwt request pr-view"
      refute_received {:sent, _, _, _, _, _}

      # The action auto-approving, the Internet's grant on: it goes unasked.
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      assert {_output, 0} = mwt(context, call, stderr: false)
      assert Sandbox.snapshot(context.username).waiting == []
      assert_received {:sent, "GET", "/repos/o/r/pulls/3", "", ["Bearer " <> @value], ""}

      # With the Internet's grant off, the agent couldn't send it, and
      # nor can the call: refused, unsent, naming the grant to ask for.
      {:ok, _} = Sandbox.turn_off(context.username, "internet")
      assert {output, code} = mwt(context, call)
      assert code in [121, 122]
      assert output =~ "mwt request internet"
      refute_received {:sent, _, _, _, _, _}

      # A grant over just its host lets it out again, as it would the
      # agent's own request.
      {:ok, api} =
        Sandbox.create_grant(context.username, %{
          "kind" => "network",
          "network" => "internet",
          "name" => "GitHub's API",
          "purpose" => "The API host",
          "destinations" => "api.github.com"
        })

      {:ok, _} = Sandbox.turn_on(context.username, api.id, 60, :all)
      assert {_output, 0} = mwt(context, call, stderr: false)
      assert_received {:sent, "GET", "/repos/o/r/pulls/3", "", _, ""}

      # The Internet locked, refused, unsent.
      :ok = Sandbox.lock(context.username, {:network, "internet"})
      assert {_output, code} = mwt(context, call)
      assert code in [121, 122]
      refute_received {:sent, _, _, _, _, _}
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
      assert output =~ "Q can't be that: it starts with -"
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

    test "stays under its credential, and goes, whatever becomes of the token grant over it",
         context do
      grant = github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)
      call = ["call", "pr-view", "REPO=o/r", "PR=1", "--reason", "r"]

      # The grant edited to list another host only: the action gives the
      # credential's use itself.
      {:ok, _} =
        Sandbox.update_grant(context.username, grant.id, %{
          "name" => "GitHub",
          "purpose" => "The GitHub API",
          "hosts" => "github.com",
          "env" => "GH_TOKEN"
        })

      assert {_output, 0} = mwt(context, call, stderr: false)

      # Removed, the grant leaves its credential, its value and its actions.
      :ok = Sandbox.delete_grant(context.username, grant.id)
      assert Enum.any?(Sandbox.snapshot(context.username).grants, &(&1.id == sub.id))
      assert {_output, 0} = mwt(context, call, stderr: false)
      assert_received {:sent, "GET", "/repos/o/r/pulls/1", "", ["Bearer " <> @value], ""}
    end

    test "a template that could let a value move the token, or send it in the clear, is refused",
         context do
      github(context)

      for {attrs, field, says} <- [
            {%{"url" => "https://$HOST/x", "params" => "HOST: word: h"}, :url, "host is fixed"},
            {%{"url" => "http://api.github.com/x", "params" => ""}, :url, "HTTPS only"},
            {%{"headers" => "Accept: application/json"}, :headers, "Say where the token goes"},
            {%{"headers" => "Authorization: Bearer {token}\nX-Pr: $PR"}, :headers, "fixed"},
            {%{"credential" => "nope"}, :credential, "pick one"}
          ] do
        assert {:error, errors} =
                 Sandbox.create_grant(
                   context.username,
                   Map.merge(
                     %{
                       "kind" => "request",
                       "credential" => "github",
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

    test "an agent proposes one over its token grant's credential; accepting it answers with its id",
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
      assert %Grant{kind: :request, method: "GET", credential: "github"} = sub
      assert Grant.to_review?(sub)

      # Without --header, the headers the service expects, the token in place.
      assert {"Authorization", "Bearer {token}"} in sub.headers

      {:ok, _} = Sandbox.review(context.username, sub.id, {60, :ask}, sub.proposal.revision)
      assert {output, 0} = Task.await(asking)
      assert output =~ "accepted it as pr-view"
      assert output =~ "mwt call pr-view REPO=… PR=…"

      # A proposal that would send the token in the clear never waits.
      assert {output, 1} =
               mwt(context, [
                 "propose",
                 "github",
                 "--name",
                 "x",
                 "--for",
                 "y",
                 "--url",
                 "http://api.github.com/collect",
                 "--reason",
                 "r"
               ])

      assert output =~ "HTTPS only"
    end

    test "a call whose host's network grant asks waits on one card naming that grant", context do
      github(context)
      call = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, call.id, :auto)
      {:ok, _} = Sandbox.set_except(context.username, "internet", "api.github.com")

      {:ok, api} =
        Sandbox.create_grant(context.username, %{
          "kind" => "network",
          "network" => "internet",
          "name" => "GitHub's API host",
          "purpose" => "The API host",
          "destinations" => "api.github.com"
        })

      {:ok, _} = Sandbox.turn_on(context.username, api.id, 60, :ask)

      ask = %{
        grant: call.id,
        script: nil,
        values: %{"REPO" => "o/r", "PR" => "3"},
        dir: nil,
        reason: "r",
        agent: "claude"
      }

      {:ok, card} = Server.call(context.username, {:call, ask})

      # The call goes without asking; the host's grant asks: one card, for
      # both, and *Allow for a while* can go on each.
      assert [%{id: id}] = Sandbox.snapshot(context.username).waiting
      assert id == card.id
      assert card.also == [api.id]
      assert {"Also asking", "GitHub's API host"} in card.facts
      :ok = Sandbox.decide(context.username, card.id, :decline)
    end
  end

  describe "editing" do
    test "keeps an action's id, state and start, and checks the change as when it was added",
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

      assert %{id: "say", name: "shout", start: :auto, state: :on} = edited
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
      assert {:error, :built_in} = Sandbox.update_grant(context.username, "internet", %{})
      assert {:error, :not_found} = Sandbox.update_grant(context.username, "nope", %{})
    end

    test "a token grant keeps its placeholder and value; its credential's fields stay the credential's",
         context do
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
      # How tools find it is its credential's, edited on its own.
      assert edited.env == ["API_TOKEN"]
      assert Sandbox.snapshot(context.username).values[grant.id] == true
    end
  end
end
