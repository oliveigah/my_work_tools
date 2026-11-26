defmodule MWTClient.Sandbox.PolicyRequestsTest do
  @moduledoc """
  The rules of `MWTClient.Sandbox.Policy` for a request: the one answer
  each gets, the hosts it may go to, and no placeholder, checked for every
  combination of the small world `MWTClient.PolicyCase` holds. A test here
  is a sentence that must hold for all of them, so a failure prints the one
  combination that breaks it.
  """
  use MWTClient.PolicyCase, async: true

  describe "a request" do
    test "gets the one answer the rules give, in every combination" do
      cases = request_cases()
      assert length(cases) > 20_000

      for one <- cases do
        expected =
          cond do
            one.carrier == :none -> :pass
            one.carrier == :two and not one.both_listed? -> {:refuse, :wrong_host}
            one.carrier == :two -> {:refuse, :multiple_grants}
            not one.listed? -> {:refuse, :wrong_host}
            # Off, its grant has no say, where the value goes included.
            not one.on? -> {:refuse, :grant_off}
            one.carrier == :other_header -> {:refuse, :not_a_carrier}
            covered?(one.grant.allowances, one.pattern, @now) -> :allow
            true -> :ask
          end

        assert kind(decide_request(one)) == expected, "wrong answer for #{inspect(one)}"
      end
    end

    test "with a placeholder never goes to a host its grant doesn't list" do
      for one <- request_cases(), one.carrier != :none, not one.listed? do
        assert match?({:refuse, _}, decide_request(one)), inspect(one)
      end
    end

    test "with no placeholder passes whatever the grants are" do
      for one <- request_cases(), one.carrier == :none do
        assert decide_request(one) == :pass
      end
    end

    test "goes through its network too: with no grant on over it, it is refused whatever its credential says" do
      for one <- Enum.take_every(request_cases(), 7),
          not match?({:refuse, _}, decide_request(one)),
          internet <- [nil, Grant.internet()] do
        grants = [one.grant, other_token_grant() | List.wrap(internet)]
        answer = Policy.decide(snapshot(grants), {:request, one.request}, @now)

        # Off, the Internet's grant has no say: it only names what to ask for.
        expected =
          if internet,
            do: {:refuse, {:grant_off, internet}},
            else: {:refuse, {:outside, "internet"}}

        assert answer == expected, inspect(one)
      end
    end

    test "with the Internet asking, goes unasked only where both let it through, on one card" do
      asking = %{internet_on() | allowances: []}

      for one <- Enum.take_every(request_cases(), 7), one.carrier == :bearer do
        alone = decide_request(one)
        grants = [one.grant, other_token_grant(), asking]
        answer = Policy.decide(snapshot(grants), {:request, one.request}, @now)

        case alone do
          :pass ->
            :ok

          {:refuse, _} ->
            assert answer == alone

          {:allow, _grant, _allowance, _about} ->
            assert {:ask, %Grant{internet: true}, about} = answer
            assert about.asking == ["internet"]
            assert about.through == [one.grant.id]
            assert about.credential == one.grant.id

          {:ask, _grant, _about} ->
            assert {:ask, %Grant{id: "github"}, about} = answer
            assert about.asking == ["github", "internet"]
        end
      end
    end

    test "gets the same answer whatever grants of other types exist" do
      others = [
        %Grant{
          id: "lan",
          name: "GitHub",
          kind: :network,
          state: :on,
          destinations: ["0.0.0.0/0"]
        },
        %Grant{
          id: "shell",
          name: "shell",
          kind: :command,
          state: :on,
          allowances: [allowance(:all, nil)]
        }
      ]

      for one <- Enum.take_every(request_cases(), 7) do
        assert kind(decide_request(one, @now, others)) == kind(decide_request(one))
      end
    end
  end

  describe "where a placeholder may be read" do
    defp github(attrs \\ []) do
      struct!(
        %Grant{
          id: "gh",
          name: "GitHub",
          kind: :token,
          credential: "github",
          state: :on,
          placeholder: @placeholder,
          hosts: ["api.github.com"],
          allowances: [allowance(:all, nil)]
        },
        attrs
      )
    end

    # A fixed call over the same credential: it knows its placeholder
    # (`Credential.attach/2`) and lists no host the agent's requests go to.
    defp fixed_call do
      %Grant{
        id: "pr-view",
        name: "pr view",
        kind: :request,
        credential: "github",
        state: :on,
        placeholder: @placeholder,
        method: "GET",
        url: "https://api.github.com/repos/$REPO/pulls/$PR",
        allowances: [allowance(:all, nil)]
      }
    end

    defp on_internet, do: %{Grant.internet() | state: :on, allowances: [allowance(:all, nil)]}

    defp to(host, opts) do
      {:request,
       %{
         host: host,
         method: Keyword.get(opts, :method, "GET"),
         path: Keyword.get(opts, :path, "/"),
         headers: Keyword.get(opts, :headers, []),
         body: Keyword.get(opts, :body, "")
       }}
    end

    defp decide(grants, use), do: grants |> snapshot() |> Policy.decide(use, @now)

    test "percent-encoded, in the path, the query or a form body, it is the placeholder itself" do
      all = URI.encode(@placeholder, fn _ -> false end)
      underscores = String.replace(@placeholder, "_", "%5F")
      twice = String.replace(@placeholder, "_", "%255F")

      for {path, body} <- [
            {"/x?t=" <> all, ""},
            {"/" <> underscores, ""},
            {"/x?t=" <> twice, ""},
            {"/x", "t=" <> underscores},
            {"/x", "a=%zz&t=" <> underscores}
          ] do
        assert {:refuse, {:wrong_host, %{id: "gh"}}} =
                 decide([github(), on_internet()], to("paste.example", path: path, body: body)),
               inspect({path, body})
      end

      # To a host its grant lists, as any placeholder outside a carrier.
      assert :pass =
               decide(
                 [github(), on_internet()],
                 to("api.github.com", path: "/x?t=" <> underscores)
               )
    end

    test "of a credential only fixed calls are over, it goes nowhere: refused as moved, wherever" do
      bearer = [{"authorization", "Bearer " <> @placeholder}]

      for {host, opts} <- [
            {"paste.example", [headers: bearer]},
            {"api.github.com", [headers: bearer]},
            {"paste.example", [path: "/?t=" <> @placeholder]},
            {"paste.example", [body: @placeholder]}
          ] do
        assert {:refuse, {:wrong_host, %{id: "pr-view"}}} =
                 decide([fixed_call(), on_internet()], to(host, opts)),
               inspect({host, opts})
      end

      # An open grant over it lists the host: its own rules, as before.
      assert {:allow, %{id: "gh"}, _, _} =
               decide(
                 [fixed_call(), github(), on_internet()],
                 to("api.github.com", headers: bearer)
               )

      # Over plain HTTP, refused as any placeholder is.
      assert {:refuse, {:plain_http, %{id: "pr-view"}}} =
               decide(
                 [fixed_call(), on_internet()],
                 {:request,
                  %{
                    host: "api.github.com",
                    method: "GET",
                    path: "/?t=" <> @placeholder,
                    headers: [],
                    body: "",
                    plain?: true,
                    ip: "1.2.3.4"
                  }}
               )
    end

    test "with a value to put in, a path its host may read as another is refused" do
      bearer = [{"authorization", "Bearer " <> @placeholder}]
      grant = github(attributes: %{"github.repository" => ["o/r"]})

      for path <- [
            "/repos/o/r/../../x/y/pulls/1",
            "/repos/o/r/%2e%2e/%2E%2E/x/y",
            "/repos/o/r%2F..%2F..%2Fx%2Fy/pulls",
            "/repos/o/r/./pulls",
            "/repos/o/r/..\\..\\x",
            "/repos/o/r/%5C"
          ] do
        assert {:refuse, {:ambiguous_path, %{id: "gh"}}} =
                 decide([grant, on_internet()], to("api.github.com", path: path, headers: bearer)),
               path
      end

      # Plain, or dots in the query or inside a name: as before.
      for path <- ["/repos/o/r/pulls/1?path=../x", "/repos/o/r/contents/a..b", "/repos/o/r//x"] do
        assert {:allow, _, _, _} =
                 decide([grant, on_internet()], to("api.github.com", path: path, headers: bearer)),
               path
      end

      # With no placeholder, nothing goes in: its network decides.
      assert :pass = decide([grant, on_internet()], to("api.github.com", path: "/a/../b"))
    end

    test "an allowance's * stands for one segment naming a thing, never a level" do
      any_hook = allowance("DELETE api.github.com/repos/o/r/hooks/* · in authorization", nil)

      assert Allowance.covers?(
               any_hook,
               "DELETE api.github.com/repos/o/r/hooks/42 · in authorization",
               @now
             )

      for segment <- ["..", ".", "", "%2e%2e", "%2E.", ".%2e", "%252e%252e", "a%2Fb", "a%5cb"] do
        refute Allowance.covers?(
                 any_hook,
                 "DELETE api.github.com/repos/o/r/hooks/#{segment} · in authorization",
                 @now
               ),
               segment
      end
    end
  end
end
