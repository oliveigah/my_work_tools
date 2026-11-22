defmodule MWTClient.Sandbox.PolicyRequestsInTimeTest do
  @moduledoc """
  The rules of `MWTClient.Sandbox.Policy` for a request over time: only
  while its grant is on, allowed only in time, and time only takes away, checked for every
  combination of the small world `MWTClient.PolicyCase` holds. A test here
  is a sentence that must hold for all of them, so a failure prints the one
  combination that breaks it.
  """
  use MWTClient.PolicyCase, async: true

  describe "a request" do
    test "is let through or asked about only while its grant is on by the clock" do
      for one <- request_cases(), one.carrier != :none, not one.on? do
        assert match?({:refuse, _}, decide_request(one)), inspect(one)
      end
    end

    test "is allowed only by an allowance of its grant that is in time and covers it" do
      for one <- request_cases() do
        case decide_request(one) do
          {:allow, grant, allowance, about} ->
            assert grant == one.grant
            assert allowance in one.grant.allowances
            assert allowance.pattern in [:all, about.pattern]
            assert is_nil(allowance.until) or DateTime.compare(@now, allowance.until) == :lt

          _other ->
            :ok
        end
      end
    end

    test "that isn't allowed now isn't allowed later either: time only takes away" do
      for one <- request_cases(), kind(decide_request(one)) != :allow do
        for later <- [@later, DateTime.add(@later, 400, :day)] do
          refute kind(decide_request(one, later)) == :allow, inspect(one)
        end
      end
    end
  end
end
