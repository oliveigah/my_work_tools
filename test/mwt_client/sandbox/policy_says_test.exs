defmodule MWTClient.Sandbox.PolicySaysTest do
  @moduledoc """
  One decision for a request, by the grants over each resource it goes
  through: the network its connection went under, and the credential
  whose placeholder it carries. Each resource needs a grant that is on
  and covers it; within one, the most permissive counts
  (`Policy.most_permissive/1`); across them, it goes unasked only if each
  lets it through, and when several ask, one card answers for all
  (`Policy.all_of/1`). A grant that is off has no say.
  """
  use MWTClient.PolicyCase, async: true

  @states [:auto, :ask, :off]

  defp token(state, id \\ "datalake") do
    put(
      %Grant{
        id: id,
        name: "Datalake",
        kind: :token,
        credential: "datalake",
        placeholder: @placeholder,
        hosts: ["internal.example.com"]
      },
      state
    )
  end

  defp network(state, id \\ "prod", scope \\ nil) do
    put(
      %Grant{
        id: id,
        name: "Prod gateway",
        kind: :network,
        network: "prod",
        scope: scope,
        destinations: scope || ["internal.example.com:443", "other.example.com:443"]
      },
      state
    )
  end

  defp put(grant, :auto), do: %{grant | state: :on, allowances: [allowance(:all, nil)]}
  defp put(grant, :ask), do: %{grant | state: :on, allowances: []}
  defp put(grant, :off), do: Grant.put_down(%{grant | state: :on})

  defp request(carrier?) do
    headers =
      if carrier?,
        do: [{"authorization", "Bearer " <> @placeholder}],
        else: []

    %{
      host: "internal.example.com",
      port: 443,
      method: "GET",
      path: "/datalake/v1/rows",
      headers: headers,
      body: "",
      under: "prod"
    }
  end

  defp decide(grants, carrier? \\ true),
    do: Policy.decide(snapshot(grants), {:request, request(carrier?)}, @now)

  describe "a request through a network, carrying a credential's placeholder" do
    test "needs a grant on over each, and goes unasked only if both let it through" do
      for net <- @states, tok <- @states do
        decision = decide([network(net), token(tok)])

        expected =
          cond do
            tok == :off -> {:refuse, :grant_off}
            net == :off -> {:refuse, :grant_off}
            :ask in [net, tok] -> :ask
            true -> :allow
          end

        assert kind(decision) == expected,
               "network #{net}, token #{tok}: #{inspect(decision)}"
      end
    end

    test "names on one card every grant that asks, the token grant first" do
      {:ask, grant, about} = decide([network(:ask), token(:ask)])

      assert grant.id == "datalake"
      assert about.asking == ["datalake", "prod"]
      assert about.through == []
    end

    test "asks for the network grant alone when the token grant lets it through" do
      {:ask, grant, about} = decide([network(:ask), token(:auto)])

      assert grant.id == "prod"
      assert about.asking == ["prod"]
      assert about.through == ["datalake"]
      assert about.credential == "datalake"
    end

    test "goes with the token grant's value when both let it through" do
      {:allow, grant, _allowance, about} = decide([network(:auto), token(:auto)])

      assert grant.id == "datalake"
      assert about.through == ["prod"]
    end
  end

  describe "within one resource" do
    test "the most permissive grant that is on counts: grants only give" do
      for one <- @states, other <- @states do
        tokens = [token(one), token(other, "datalake-rows")]
        decision = decide([network(:auto) | tokens])

        expected =
          cond do
            :auto in [one, other] -> :allow
            :ask in [one, other] -> :ask
            true -> {:refuse, :grant_off}
          end

        assert kind(decision) == expected, "#{one}, #{other}: #{inspect(decision)}"

        # Over the network: one over all of it, one over the host.
        nets = [network(one), network(other, "prod-internal", ["internal.example.com:443"])]
        assert kind(decide([token(:auto) | nets])) == expected, "#{one}, #{other}"
      end
    end

    test "a grant over part of the network gives only the hosts it names" do
      part = network(:auto, "prod-other", ["other.example.com:443"])

      assert {:refuse, {:grant_off, %Grant{id: "prod"}}} =
               decide([network(:off), part, token(:auto)])

      assert {:ask, %Grant{id: "prod"}, _} = decide([network(:ask), part, token(:auto)])
    end
  end

  describe "a request through a network, with no placeholder" do
    test "is the network's alone: off has no say, so nothing gives it" do
      for net <- @states do
        decision = decide([network(net), token(:auto)], false)

        expected =
          case net do
            :off -> {:refuse, :grant_off}
            :ask -> :ask
            :auto -> :allow
          end

        assert kind(decision) == expected, "network #{net}: #{inspect(decision)}"
      end
    end
  end

  describe "a grant's state" do
    test "is on while its time lasts, then off" do
      grant = %{token(:ask) | expires_at: @later}
      assert Grant.state_at(grant, @now) == :on
      assert Grant.state_at(grant, DateTime.add(@later, 1, :second)) == :off
    end

    test "put down, it is off and keeps no time or allowance" do
      grant = %{token(:auto) | expires_at: @later}
      assert %Grant{state: :off, expires_at: nil, allowances: []} = Grant.put_down(grant)
    end
  end

  doctest MWTClient.Sandbox.Policy, only: [most_permissive: 1, all_of: 1]
  doctest MWTClient.Sandbox.Approval, only: [grant_ids: 1]
end
