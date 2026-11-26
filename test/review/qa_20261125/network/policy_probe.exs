defmodule MWTClient.QaProbes.Network.PolicyProbeTest do
  @moduledoc """
  QA 2026-11-25, network and credential path, pure decisions
  (`MWTClient.Sandbox.Policy.decide/3`). Each test states a guarantee of
  docs/grant_mental_model.md (points 1, 5, 6, Q5) or of "Guarantees to
  test" and tries to break it. A test that fails shows the guarantee
  failing; the others document that it holds.

  The world: GitHub's credential (`github`), with an open grant over it
  (`gh-token`, kind :token) and a fixed call over it (`pr-view`, kind
  :request, to api.github.com); the Internet's grant; grants over part of
  the Internet naming one host.
  """
  use MWTClient.PolicyCase, async: true

  alias MWTClient.Sandbox.HostLimits

  @host "api.github.com"

  ## The world

  defp token(attrs \\ []) do
    struct!(
      %Grant{
        id: "gh-token",
        name: "GitHub",
        kind: :token,
        credential: "github",
        state: :on,
        placeholder: @placeholder,
        hosts: [@host],
        allowances: [allowance(:all, nil)]
      },
      attrs
    )
  end

  defp hex(attrs) do
    struct!(
      %Grant{
        id: "hex-token",
        name: "Hex",
        kind: :token,
        credential: "hex",
        state: :on,
        placeholder: @other_placeholder,
        hosts: ["hex.pm", @host],
        allowances: [allowance(:all, nil)]
      },
      attrs
    )
  end

  # A fixed call over GitHub's credential. It carries the credential's
  # fields (`Credential.attach/2`), its placeholder among them.
  defp action(attrs \\ []) do
    struct!(
      %Grant{
        id: "pr-view",
        name: "pr view",
        kind: :request,
        credential: "github",
        state: :on,
        placeholder: @placeholder,
        method: "GET",
        url: "https://api.github.com/repos/$REPO/pulls/$PR",
        headers: [{"Authorization", "Bearer {token}"}],
        allowances: [allowance(:all, nil)]
      },
      attrs
    )
  end

  defp internet(attrs \\ []),
    do: struct!(%{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}, attrs)

  # A grant over part of the Internet naming `host`, asking by default.
  defp part(host, attrs \\ []) do
    struct!(
      %Grant{
        id: "part-" <> host,
        name: "Just " <> host,
        kind: :network,
        network: "internet",
        state: :on,
        scope: [host],
        destinations: [host],
        allowances: []
      },
      attrs
    )
  end

  defp req(host, headers, opts \\ []) do
    %{
      host: host,
      method: Keyword.get(opts, :method, "GET"),
      path: Keyword.get(opts, :path, "/repos/o/r/pulls/1"),
      headers: headers,
      body: Keyword.get(opts, :body, ""),
      under: Keyword.get(opts, :under, "internet")
    }
    |> then(fn r ->
      if opts[:plain?], do: Map.merge(r, %{plain?: true, ip: "1.2.3.4"}), else: r
    end)
  end

  defp bearer(placeholder \\ @placeholder), do: [{"authorization", "Bearer " <> placeholder}]

  defp decide(grants, use, extra \\ %{}),
    do: grants |> snapshot() |> Map.merge(extra) |> Policy.decide(use, @now)

  defp call, do: {:call, %{grant: "pr-view"}}

  defp blocked(host) do
    {:ok, limits} = HostLimits.put(HostLimits.new(), host, true)
    %{limits: %{"internet" => limits}}
  end

  ## G1: off gives nothing; every resource; most permissive; refuse > ask > yes

  describe "G1: grants" do
    test "an open credential grant that is off gives nothing, whatever else is on" do
      for off <- [token(state: :off), token(expires_at: @earlier)] do
        assert {:refuse, {:grant_off, %{id: "gh-token"}}} =
                 decide([off, internet(), action()], {:request, req(@host, bearer())})
      end
    end

    test "a use carrying a credential needs an on grant over its network too" do
      # The Internet off, nothing else over it: refused, never let out.
      assert {:refuse, {:grant_off, %{id: "internet"}}} =
               decide([token(), internet(state: :off)], {:request, req(@host, bearer())})

      # No grant over the network at all.
      assert {:refuse, {:outside, _}} = decide([token()], {:request, req(@host, bearer())})
    end

    test "within one resource the most permissive on grant counts" do
      asking = token(id: "gh-ask", allowances: [])
      auto = token(id: "gh-auto")

      for grants <- [[asking, auto, internet()], [auto, asking, internet()]] do
        assert {:allow, %{id: "gh-auto"}, _, _} =
                 decide(grants, {:request, req(@host, bearer())})
      end
    end

    test "across resources: a refusal beats an ask beats a yes; one card names every grant that asks" do
      except = internet(except: [@host])

      # The credential auto, the network's grant over the host asks: asks.
      assert {:ask, %{id: "part-api.github.com"}, about} =
               decide([token(), except, part(@host)], {:request, req(@host, bearer())})

      assert about.asking == ["part-api.github.com"]
      assert about.through == ["gh-token"]

      # Both ask: one card, the credential's, naming both.
      assert {:ask, %{id: "gh-token"}, about} =
               decide(
                 [token(allowances: []), except, part(@host)],
                 {:request, req(@host, bearer())}
               )

      assert Enum.sort(about.asking) == ["gh-token", "part-api.github.com"]

      # The credential asks, the network refuses (its grant over the host off).
      assert {:refuse, {:grant_off, %{id: "part-api.github.com"}}} =
               decide(
                 [token(allowances: []), except, part(@host, state: :off)],
                 {:request, req(@host, bearer())}
               )
    end
  end

  ## G2: locks and host limits refuse whatever the grants say

  describe "G2: locks and limits" do
    test "a locked credential refuses the agent's own request and the fixed call, all auto" do
      locks = %{locks: %{{:credential, "github"} => true}}

      assert {:refuse, {:locked, {:credential, "github"}, _}} =
               decide([token(), action(), internet()], {:request, req(@host, bearer())}, locks)

      assert {:refuse, {:locked, {:credential, "github"}, _}} =
               decide([token(), action(), internet()], call(), locks)
    end

    test "a locked network refuses connections, requests and the fixed call to a host on it" do
      locks = %{locks: %{{:network, "internet"} => true}}
      grants = [token(), action(), internet(), part(@host, allowances: [allowance(:all, nil)])]

      assert {:refuse, {:locked, {:network, "internet"}, _}} =
               decide(grants, {:request, req(@host, bearer())}, locks)

      assert {:refuse, {:locked, {:network, "internet"}, _}} =
               decide(grants, {:request, req(@host, [])}, locks)

      assert {:refuse, {:locked, {:network, "internet"}, _}} = decide(grants, call(), locks)

      assert {:refuse, {:locked, {:network, "internet"}, _}} =
               decide(grants, {:connection, {140, 82, 112, 3}, 443}, locks)
    end

    test "a host the network blocks is refused for the fixed call and the agent's own, all auto" do
      grants = [token(), action(), internet(), part(@host, allowances: [allowance(:all, nil)])]

      for use <- [call(), {:request, req(@host, bearer())}, {:request, req(@host, [])}] do
        assert {:refuse, {:host_blocked, "internet", "api.github.com"}} =
                 decide(grants, use, blocked(@host)),
               inspect(use)
      end

      # A domain above it blocks it too; with a trailing dot and in capitals.
      for host <- ["API.GitHub.com", "api.github.com."] do
        assert {:refuse, {:host_blocked, _, _}} =
                 decide(grants, {:request, req(host, [])}, blocked("github.com"))
      end
    end
  end

  ## G3: a fixed call covers its credential in its own request only, and
  ## goes out as the agent's own would

  describe "G3: fixed calls" do
    test "the agent's own request carrying the placeholder is refused while only the fixed call is on" do
      # The open grant off, the call on and auto-approving.
      assert {:refuse, {:grant_off, %{id: "gh-token"}}} =
               decide(
                 [token(state: :off), action(), internet()],
                 {:request, req(@host, bearer())}
               )
    end

    test "the call itself, by id, goes unasked with the open grant off" do
      assert {:allow, %{id: "pr-view"}, _, _} =
               decide([token(state: :off), action(), internet()], call())
    end

    test "PROBE: a placeholder of a credential only fixed calls are over is refused, not passed on as it is" do
      # An agent that held the placeholder while an open grant was over
      # the credential (it was removed since), or got it any other way,
      # sends it to a host no grant over the credential lists. The value
      # never goes (nothing swaps it), but guarantee 4 says a placeholder
      # going where its credential's grants don't send it is refused and
      # logged: here it is let through, unseen.
      answer = decide([action(), internet()], {:request, req("paste.example", bearer())})

      assert match?({:refuse, _}, answer),
             "expected a refusal (wrong_host), got #{inspect(kind(answer))}: the placeholder of a " <>
               "credential with only fixed calls over it is unknown to Policy (it reads only :token grants)"
    end

    test "the call needs the network grant the agent's own request would need" do
      # The Internet off and nothing else over the host: refused.
      assert {:refuse, {:grant_off, %{id: "internet"}}} =
               decide([action(), internet(state: :off)], call())

      # The Internet leaving the host out, no grant over it: refused.
      assert {:refuse, {:excepted, %{id: "internet"}, "api.github.com"}} =
               decide([action(), internet(except: [@host])], call())

      # ... a grant over the host decides: asking, the call asks; auto, it goes.
      assert {:ask, _, about} = decide([action(), internet(except: [@host]), part(@host)], call())
      assert "part-api.github.com" in about.asking

      assert {:allow, %{id: "pr-view"}, _, _} =
               decide(
                 [
                   action(),
                   internet(except: [@host]),
                   part(@host, allowances: [allowance(:all, nil)])
                 ],
                 call()
               )

      # The Internet's grant itself asking (not auto-approving): the call asks.
      assert {:ask, _, _} = decide([action(), internet(allowances: [])], call())
    end

    test "for every network setting, the call is let out no more than the agent's own request would be" do
      settings = [
        [internet()],
        [internet(state: :off)],
        [internet(allowances: [])],
        [internet(except: [@host])],
        [internet(except: ["github.com"]), part(@host)],
        [internet(except: [@host]), part(@host, allowances: [allowance(:all, nil)])],
        [internet(except: [@host]), part(@host, state: :off)],
        [internet(state: :off), part(@host)],
        [internet(state: :off), part(@host, allowances: [allowance(:all, nil)])]
      ]

      extras = [%{}, blocked(@host), %{locks: %{{:network, "internet"} => true}}]
      rank = fn answer -> %{pass: 2, allow: 2, ask: 1}[kind(answer)] || 0 end

      for network <- settings, extra <- extras do
        own = decide([token() | network], {:request, req(@host, bearer())}, extra)
        fixed = decide([action() | network], call(), extra)

        assert rank.(fixed) <= rank.(own),
               "the call went further (#{inspect(kind(fixed))}) than the agent's own request " <>
                 "(#{inspect(kind(own))}) with #{inspect(Enum.map(network, &{&1.id, &1.state, &1.except}))} #{inspect(extra)}"
      end
    end

    test "an allowance on the network grant goes by what it was made for: a call's from its card, a request's from the request's" do
      # docs/grant_mental_model.md Q5: a call goes out as the agent's own
      # request would. Its network's say is asked about the call (pattern
      # "call pr-view"), not the request MWT builds from it: an allowance
      # made on the call's card (which, since this QA, goes on the network
      # grant that asked too) lets the next call out; one made for the
      # agent's own request to the same endpoint doesn't, so the call asks
      # there. Stricter than the agent's, never looser: kept by choice.
      own = allowance("GET api.github.com/repos/o/r/pulls/1 · in authorization", nil)
      network = [internet(except: [@host]), part(@host, allowances: [own])]

      assert {:allow, _, _, _} = decide([token() | network], {:request, req(@host, bearer())})
      assert kind(decide([action() | network], call())) == :ask

      from_card = allowance("call pr-view", nil)
      network = [internet(except: [@host]), part(@host, allowances: [from_card])]
      assert kind(decide([action() | network], call())) in [:allow, :pass]
    end
  end

  ## G5: placeholder hygiene

  describe "G5: placeholders" do
    test "to a host no grant over its credential lists: refused in a header, the path or the body" do
      grants = [token(), internet()]

      for {headers, opts} <- [
            {bearer(), []},
            {[], [path: "/x?token=" <> @placeholder]},
            {[], [path: "/" <> @placeholder]},
            {[], [method: "POST", body: ~s({"t":"#{@placeholder}"})]}
          ] do
        assert {:refuse, {:wrong_host, %{id: "gh-token"}}} =
                 decide(grants, {:request, req("paste.example", headers, opts)}),
               inspect({headers, opts})
      end
    end

    test "PROBE: a placeholder percent-encoded in the path or a form body is refused like one as it is" do
      grants = [token(), internet()]
      encoded = URI.encode(@placeholder, fn _ -> false end)
      half = String.replace(@placeholder, "_", "%5F")

      for {path, body} <- [
            {"/x?t=" <> encoded, ""},
            {"/x?t=" <> half, ""},
            {"/x", "t=" <> half}
          ] do
        answer =
          decide(
            grants,
            {:request, req("paste.example", [], path: path, body: body, method: "POST")}
          )

        assert match?({:refuse, {:wrong_host, _}}, answer),
               "#{inspect({path, body})} went as #{inspect(kind(answer))}: only the placeholder as it " <>
                 "is is looked for in the path and the body (Policy moved?)"
      end
    end

    test "never over plain HTTP, even to a listed host" do
      assert {:refuse, {:plain_http, _}} =
               decide([token(), internet()], {:request, req(@host, bearer(), plain?: true)})

      assert {:refuse, {:plain_http, _}} =
               decide(
                 [token(), internet()],
                 {:request, req(@host, [], plain?: true, path: "/?t=" <> @placeholder)}
               )
    end

    test "two credentials in one request are refused, both hosts listed" do
      headers = bearer() ++ [{"x-hex", @other_placeholder}]

      assert {:refuse, :multiple_grants} =
               decide(
                 [token(), hex(carriers: ["x-hex"]), internet()],
                 {:request, req(@host, headers)}
               )
    end

    test "a placeholder in a header that isn't a carrier is refused" do
      assert {:refuse, {:not_a_carrier, _, ["x-api-key"], ["authorization"]}} =
               decide(
                 [token(), internet()],
                 {:request, req(@host, [{"x-api-key", @placeholder}])}
               )
    end
  end

  ## G7: an allowance covers what its pattern says, no more

  describe "G7: allowances" do
    # Allow similar, any id (`Allowance.widen/1`) on DELETE of one webhook.
    defp any_hook,
      do: allowance("DELETE api.github.com/repos/o/r/hooks/* · in authorization", nil)

    test "the widened allowance covers another webhook's id" do
      grants = [token(allowances: [any_hook()]), internet()]
      use = {:request, req(@host, bearer(), method: "DELETE", path: "/repos/o/r/hooks/42")}
      assert {:allow, _, _, _} = decide(grants, use)

      # Not another method, nor a longer path.
      for {method, path} <- [
            {"PATCH", "/repos/o/r/hooks/42"},
            {"DELETE", "/repos/o/r/hooks/42/x"}
          ] do
        assert {:ask, _, _} =
                 decide(grants, {:request, req(@host, bearer(), method: method, path: path)})
      end
    end

    test "PROBE: a * segment never stands for . or .., which the service reads as going up" do
      grants = [token(allowances: [any_hook()]), internet()]

      # DELETE /repos/o/r/hooks/.. is DELETE /repos/o/r once the path is
      # normalised (RFC 3986 5.2.4; curl does it unless --path-as-is):
      # deleting the repository under an allowance for its webhooks.
      paths = [
        "/repos/o/r/hooks/..",
        "/repos/o/r/hooks/%2e%2e",
        "/repos/o/r/hooks/%2E.",
        "/repos/o/r/hooks/.",
        "/repos/o/r/hooks/"
      ]

      let_through =
        for path <- paths,
            answer =
              decide(grants, {:request, req(@host, bearer(), method: "DELETE", path: path)}),
            # Asked, or refused outright (a value never goes into a path
            # its host may read as another): neither lets it through.
            kind(answer) in [:pass, :allow],
            do: {path, kind(answer)}

      assert let_through == [],
             "let through unasked by the allowance #{any_hook().pattern}: #{inspect(let_through)} " <>
               "(Allowance.wild_covers?/2 lets * match any segment, and Describe keeps the path as sent)"
    end

    test "an exact allowance covers only its method, endpoint and carrier" do
      exact = allowance("GET api.github.com/repos/o/r/pulls/1 · in authorization", nil)
      grants = [token(allowances: [exact]), internet()]

      assert {:allow, _, _, _} = decide(grants, {:request, req(@host, bearer())})

      for {opts, headers} <- [
            {[method: "DELETE"], bearer()},
            {[path: "/repos/o/r/pulls/2"], bearer()},
            {[path: "/repos/o/r/pulls/1/merge"], bearer()}
          ] do
        answer = decide(grants, {:request, req(@host, headers, opts)})

        assert kind(answer) in [:ask, {:refuse, :not_a_carrier}],
               "#{inspect(opts)} went: #{inspect(kind(answer))}"
      end
    end
  end
end
