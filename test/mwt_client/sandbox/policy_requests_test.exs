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
end
