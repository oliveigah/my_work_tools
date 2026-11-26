defmodule MWTClient.QaProbes.Network.FixedCallPipelineProbeTest do
  @moduledoc """
  QA 2026-11-25, the network and credential path through the sandbox's
  server and the `mwt` command, end to end but for the service, which
  `Req.Test` stands in for behind MWT's proxy
  (`MWTClient.FixedCallUpstream`).

    * G2: a lock or a host the network blocks refuses a fixed call, unsent.
    * G3: the agent's own request carrying the credential's placeholder is
      refused while only a fixed call over it is on; one card for a call
      whose network grant asks, naming that grant.
    * G4: the call's line in the log is labelled as a fixed call; a
      refused call leaves a line too.
    * G7: *Allow similar, any id* on one card covers no more than its
      pattern says, through the server.
  """
  use MWTClient.MwtCommandCase, async: true

  alias MWTClient.Sandbox
  alias MWTClient.Sandbox.{SavedRequest, Server}
  alias MWTClient.Vault.Store

  @value "ghp_real_value_qa_0123456789"

  defp github(context, attrs \\ %{}) do
    {:ok, grant} =
      Sandbox.create_grant(
        context.username,
        Map.merge(
          %{
            "kind" => "token",
            "preset" => "github",
            "name" => "GitHub",
            "purpose" => "The GitHub API",
            "hosts" => "api.github.com, github.com",
            "env" => "GH_TOKEN",
            "prefix" => "ghp_",
            "source" => "stored",
            "value" => @value
          },
          attrs
        )
      )

    grant
  end

  defp pr_view(context) do
    {:ok, grant} =
      Sandbox.create_grant(context.username, %{
        "kind" => "request",
        "preset" => "request_action",
        "credential" => "github",
        "name" => "pr view",
        "purpose" => "Shows a pull request",
        "method" => "GET",
        "url" => "https://api.github.com/repos/$REPO/pulls/$PR",
        "headers" => SavedRequest.default_headers(:github),
        "params" => "REPO: word: the repository\nPR: number: the pull request"
      })

    grant
  end

  defp service(context) do
    test = self()

    Req.Test.stub(SavedRequest, fn conn ->
      send(test, {:sent, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 200, ~s({"number": 7}))
    end)

    :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))
  end

  @call ["call", "pr-view", "REPO=o/r", "PR=3", "--reason", "qa"]

  defp own_request(placeholder, method \\ "GET", path \\ "/repos/o/r/pulls/3") do
    %{
      host: "api.github.com",
      method: method,
      path: path,
      headers: [{"authorization", "Bearer " <> placeholder}],
      body: ""
    }
  end

  defp summaries(username), do: Enum.map(Sandbox.events(username, %{limit: 200}), & &1.summary)

  describe "G2: locks and blocked hosts refuse a fixed call" do
    test "the credential locked: refused, unsent", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      :ok = Sandbox.lock(context.username, {:credential, "github"})
      assert {_output, code} = mwt(context, @call)
      assert code != 0
      refute_received {:sent, _, _}
    end

    test "the host blocked on the Internet's limits: refused, unsent; unblocked, it goes",
         context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      {:ok, _} = Sandbox.limits_set(context.username, "internet", {:put, "github.com", true})
      assert {output, code} = mwt(context, @call)
      assert code != 0, output
      refute_received {:sent, _, _}

      {:ok, _} = Sandbox.limits_set(context.username, "internet", {:remove, "github.com"})
      assert {_output, 0} = mwt(context, @call, stderr: false)
      assert_received {:sent, "/repos/o/r/pulls/3", ["Bearer " <> @value]}
    end

    test "the host left out of the Internet's grant: refused with no grant over it", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      {:ok, _} = Sandbox.set_except(context.username, "internet", "api.github.com")
      assert {_output, code} = mwt(context, @call)
      assert code != 0
      refute_received {:sent, _, _}
    end

    test "isolated: refused, unsent", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      :ok = Sandbox.firewall_isolate(context.username)
      assert {_output, code} = mwt(context, @call)
      assert code != 0
      refute_received {:sent, _, _}
    end

    test "a card approved after its network was locked meanwhile: refused, unsent", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
      service(context)

      asking = Task.async(fn -> mwt(context, @call) end)
      card = command(context.username)
      :ok = Sandbox.lock(context.username, {:network, "internet"})
      :ok = Sandbox.decide(context.username, card.id, {:run, :send})
      assert {_output, code} = Task.await(asking, 10_000)
      assert code != 0
      refute_received {:sent, _, _}
    end

    test "PROBE: a fixed call refused before it is built leaves a line in the activity log",
         context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      :ok = Sandbox.lock(context.username, {:credential, "github"})
      {:ok, _} = Sandbox.limits_set(context.username, "internet", {:put, "github.com", true})
      before = summaries(context.username)

      assert {_output, code} = mwt(context, @call)
      assert code != 0

      new = summaries(context.username) -- before

      assert Enum.any?(new, &(&1 =~ "pr view" or &1 =~ "pr-view")),
             "a call refused for a lock or a blocked host is logged nowhere: #{inspect(new)} " <>
               "(Server's refused_values/3 logs only refused values)"
    end
  end

  describe "G3: the call covers its credential in its own request only" do
    test "the agent's own request with the placeholder is refused while only the call is on",
         context do
      grant = github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      # The open grant is off: the call goes, the agent's own doesn't.
      assert {:deny, 403, body} =
               Server.call(context.username, {:authorize, own_request(grant.placeholder)})

      assert body =~ "mwt_grant_off"
      refute body =~ @value
    end

    test "PROBE: one card for a call whose network grant asks, naming that grant", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)
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

      asking = Task.async(fn -> mwt(context, @call, stderr: false) end)
      card = command(context.username)

      # One card: the call's.
      assert [_one] =
               Enum.filter(Sandbox.snapshot(context.username).waiting, &(&1.status == :waiting))

      shown = inspect({card.title, card.facts, card.warnings, card.hints})
      named? = String.contains?(shown, "GitHub's API host")

      :ok = Sandbox.decide(context.username, card.id, {:run, :send})
      assert {_output, 0} = Task.await(asking, 10_000)
      assert_received {:sent, "/repos/o/r/pulls/3", _}

      assert named?,
             "the call asked because GitHub's API host asks (the call itself auto-approves), " <>
               "and its card doesn't say so: #{shown}"
    end
  end

  describe "G4: the log" do
    test "the request goes through the proxy, its line labelled as the fixed call's", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)
      service(context)

      assert {_output, 0} = mwt(context, @call, stderr: false)

      line =
        Enum.find(
          Sandbox.events(context.username, %{limit: 50}),
          &(&1.summary =~ "Fixed call · pr view" and &1.grant_id == sub.id and
              &1.host == "api.github.com")
        )

      assert line
      # What let it: the action's own Auto-approve.
      assert %{by: :allowance, grant: id} = line.decision
      assert id == sub.id

      refute Enum.any?(summaries(context.username), &(&1 =~ @value))
    end

    test "an answer echoing the value, split or escaped, is cut: no byte of it reaches the agent",
         context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.set_start(context.username, sub.id, :auto)

      for body <- [
            ~s({"seen": "#{@value}"}),
            ~s({"seen": "Bearer #{@value}"}),
            String.duplicate("x", 70_000) <> @value
          ] do
        Req.Test.stub(SavedRequest, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
        :ok = Req.Test.allow(SavedRequest, self(), Store.whereis(Server, context.username))

        assert {output, code} = mwt(context, @call)
        assert code != 0
        assert output =~ "MWT cut the answer"
        refute output =~ "ghp_real"

        # An echo isolates the VM, as for its own requests: released for the next.
        assert Sandbox.firewall(context.username).firewall.isolated != nil
        Sandbox.firewall_release(context.username, false)
      end
    end

    test "a call you approved on its card: its line says you decided", context do
      github(context)
      sub = pr_view(context)
      {:ok, _} = Sandbox.turn_on(context.username, sub.id, 60, :ask)
      service(context)

      asking = Task.async(fn -> mwt(context, @call, stderr: false) end)
      card = command(context.username)
      :ok = Sandbox.decide(context.username, card.id, {:run, :send})
      assert {_output, 0} = Task.await(asking, 10_000)

      line =
        Enum.find(
          Sandbox.events(context.username, %{limit: 50}),
          &(&1.summary =~ "Fixed call · pr view")
        )

      assert %{by: :you, card: card_id} = line.decision
      assert card_id == card.id
    end
  end

  describe "G7: Allow similar, any id" do
    test "PROBE: an allowance for DELETE of a webhook by id doesn't let DELETE …/hooks/.. go with the value",
         context do
      grant = github(context)
      {:ok, _} = Sandbox.turn_on(context.username, grant.id, 60, :ask)
      username = context.username

      # One webhook deleted, on a card: allowed similar, any id.
      first =
        Task.async(fn ->
          Server.call(
            username,
            {:authorize, own_request(grant.placeholder, "DELETE", "/repos/o/r/hooks/123")},
            :infinity
          )
        end)

      card = waiting(username, &(&1.kind == :request))
      :ok = Sandbox.decide(username, card.id, {:allow, :ids, :grant})
      assert {:forward, _, _} = Task.await(first)

      # Another id goes unasked, as allowed.
      assert {:forward, _, _} =
               Server.call(
                 username,
                 {:authorize, own_request(grant.placeholder, "DELETE", "/repos/o/r/hooks/456")}
               )

      # `..` is the repository itself once the path is normalised.
      answer =
        Task.async(fn ->
          Server.call(
            username,
            {:authorize, own_request(grant.placeholder, "DELETE", "/repos/o/r/hooks/..")},
            :infinity
          )
        end)

      result = Task.yield(answer, 1_000)
      held = Enum.filter(Sandbox.snapshot(username).waiting, &(&1.kind == :request))
      Enum.each(held, &Sandbox.decide(username, &1.id, :deny))
      result = result || Task.await(answer)

      refute match?({:ok, {:forward, _, _}}, result),
             "DELETE /repos/o/r/hooks/.. went unasked, with GitHub's real value, under the " <>
               "allowance for DELETE api.github.com/repos/o/r/hooks/*"
    end
  end
end
